package MCP::Run::Compress;
our $VERSION = '0.002';
use Mojo::Base -base;

# ABSTRACT: Output compression for LLMs

=head1 SYNOPSIS

    use MCP::Run::Compress;

    my $compressor = MCP::Run::Compress->new;
    $compressor->register_filter(
      'command' => '^ls\b',
      'strip_lines_matching' => [qr(^\s*$), qr(^total\s+\d+)],
      'truncate_lines_at' => 120,
      'max_lines' => 50,
    );

    my ($compressed_stdout, $compressed_stderr) = $compressor->compress($command, $stdout, $stderr);

=head1 DESCRIPTION

Automatic output compression for LLM consumption. Applies command-specific
filters to reduce token count while preserving essential information.

=cut

use Text::Trim qw(trim);
use List::Util qw(max min);

has filters => sub { +{} };

sub register_filter {
  my $self = shift;
  my %args = @_;

  my $command = $args{command};
  delete $args{command};

  $self->filters->{$command} = {
    strip_ansi           => $args{strip_ansi}           // 0,
    strip_lines_matching => $args{strip_lines_matching} // [],
    keep_lines_matching  => $args{keep_lines_matching}  // [],
    truncate_lines_at   => $args{truncate_lines_at}    // 0,
    max_lines           => $args{max_lines}            // 0,
    tail_lines          => $args{tail_lines}           // 0,
    head_lines          => $args{head_lines}           // 0,
    on_empty            => $args{on_empty}            // '',
    replace             => $args{replace}             // [],
    match_output        => $args{match_output}         // [],
    filter_stderr       => $args{filter_stderr}       // 0,
    output_detect       => $args{output_detect}       // undef,
    transform           => $args{transform}           // undef,
  };

  return;
}

sub _build_default_filters {
  my $self = shift;

  # ls: ultra-compact for long listing - only keep type + filename
  $self->register_filter(
    command => '^ls\b',
    output_detect => qr(^[d-][rwx-]{9}.*\s+\d+\s+),
    strip_lines_matching => [
      qr(^\s*$),
      qr(^total\s+\d+),
      qr(^\s*Device:),
      qr(^\s*Inode:),
      qr(^\s*Birth:),
      qr(^/node_modules/),
      qr(^/\.git/),
      qr(^/\.target/),
      qr(^/\.next/),
      qr(^/\.nuxt/),
      qr(^/\.cache/),
      qr(^/__pycache__/),
      qr(^/\.DS_Store/),
      qr(^/vendor/bundle/),
    ],
    transform => sub {
      my ($line) = @_;
      if ($line =~ m{^([d-])[rwx-]{9}\s+\d+\s+\S+\s+\S+\s+\d+\s+\w+\s+\d+\s+[\d:]+\s+(.+)$}) {
        return $1 . " " . $2;
      }
      return $line;
    },
    truncate_lines_at => 100,
    max_lines => 50,
  );

  # stat: strip device/inode/birth (Linux)
  $self->register_filter(
    command => '^stat\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^\s*Device:),
      qr(^\s*Inode:),
      qr(^\s*Birth:),
    ],
    truncate_lines_at => 120,
    max_lines => 20,
  );

  # grep: truncate lines, group by file
  $self->register_filter(
    command => '^grep\b',
    truncate_lines_at => 150,
    max_lines => 100,
  );

  # make: strip entering/leaving directory
  $self->register_filter(
    command => '^make\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^make\[\d+\]:),
      qr(^Entering directory),
      qr(^Leaving directory),
      qr(Nothing to be done),
      qr(^make:\s+Nothing to be done),
    ],
    match_output => [
      { pattern => qr(^make\[\d+\]:.*?make\[\d+\]:), message => 'make: circular dependency detected' },
      { pattern => qr(^gcc.*?Error), message => 'make: compilation error' },
    ],
    max_lines => 50,
    on_empty => 'make: ok',
  );

  # git status: compact output
  $self->register_filter(
    command => '^git\s+status\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^On branch),
      qr(^Your branch is),
      qr(^Initial commit),
    ],
    max_lines => 30,
  );

  # git diff: keep only diff content
  $self->register_filter(
    command => '^git\s+diff\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^diff --git),
      qr(^index ),
      qr(^---\s+a/),
      qr(^\+\+\+\s+b/),
    ],
    truncate_lines_at => 150,
    max_lines => 200,
  );

  # cat: detect and filter code
  $self->register_filter(
    command => '^cat\b',
    strip_lines_matching => [qr(^\s*$)],
    truncate_lines_at => 500,
    max_lines => 100,
  );

  # find: strip permission denied, limit results
  $self->register_filter(
    command => '^find\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^find:.*permission denied),
    ],
    max_lines => 50,
  );

  # ps: compact output
  $self->register_filter(
    command => '^ps\b',
    strip_lines_matching => [
      qr(^\s*$),
    ],
    truncate_lines_at => 120,
    max_lines => 30,
  );

  # df: truncate wide columns
  $self->register_filter(
    command => '^df\b',
    strip_lines_matching => [qr(^\s*$)],
    truncate_lines_at => 80,
    max_lines => 20,
  );

  # docker ps: compact output
  $self->register_filter(
    command => '^docker\s+(ps|images)\b',
    strip_lines_matching => [qr(^\s*$)],
    truncate_lines_at => 120,
    max_lines => 30,
  );

  # terraform plan: strip refresh progress
  $self->register_filter(
    command => '^terraform\s+plan\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^Refreshing state\.\.\.),
      qr(^Terraform used the),
      qr(^tfe-outputs:),
    ],
    max_lines => 100,
  );

  # terraform apply: strip progress
  $self->register_filter(
    command => '^terraform\s+apply\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^Refreshing state\.\.\.),
      qr(^Terraform will perform),
      qr(^Proceeding with the following),
      qr(^tfe-outputs:),
    ],
    max_lines => 100,
  );

  # docker build: strip build progress
  $self->register_filter(
    command => '^docker\s+build\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^#\s*\d+\s+\[\s*\d+\s+/\s*\d+\]),
      qr(^Step \d+/\d+:),
    ],
    max_lines => 50,
  );

  # docker run: compact output
  $self->register_filter(
    command => '^docker\s+run\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^Unable to find image),
      qr(^Pulling from library/),
      qr(^Digest:),
      qr(^Status:),
    ],
    max_lines => 30,
  );

  # kubectl get: compact output
  $self->register_filter(
    command => '^kubectl\s+get\b',
    strip_lines_matching => [qr(^\s*$)],
    truncate_lines_at => 150,
    max_lines => 50,
  );

  # kubectl describe: strip noise
  $self->register_filter(
    command => '^kubectl\s+describe\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^Name:\s+\w+),
      qr(^Namespace:\s+\w+),
      qr(^Labels:\s*$),
      qr(^Annotations:\s*$/),
    ],
    truncate_lines_at => 200,
    max_lines => 100,
  );

  # cargo build: strip compile progress
  $self->register_filter(
    command => '^cargo\s+build\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^Compiling\s+\w+),
      qr(^Fresh\s+\w+),
      qr(^Finished\s+),
    ],
    max_lines => 50,
  );

  # cargo test: compact output
  $self->register_filter(
    command => '^cargo\s+test\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^Compiling\s+\w+),
      qr(^Running\s+/),
      qr(^test result:),
    ],
    max_lines => 100,
  );

  # cpanm: strip cpanm noise
  $self->register_filter(
    command => '^cpanm\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^--> ),
      qr(^OK$),
      qr(^FAIL$),
      qr(^Working on),
      qr(^Fetching),
      qr(^Configuring),
      qr(^Building and testing),
    ],
    match_output => [
      { pattern => qr{^\s*Successfully installed}, message => 'cpanm: ok' },
    ],
    max_lines => 30,
  );

  # npm install: strip noise
  $self->register_filter(
    command => '^npm\s+install\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^added\s+\d+\s+packages?),
      qr(^found\s+\d+\s+packages?),
      qr(^npm warn),
    ],
    max_lines => 30,
  );

  # yarn: similar to npm
  $self->register_filter(
    command => '^(yarn|pnpm)\s+(install|add)\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^Done in\s+),
      qr(^Resolving completed),
      qr(^Linking completed),
    ],
    max_lines => 30,
  );

  # pip install: strip progress
  $self->register_filter(
    command => '^pip\s+install\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^Collecting\s+),
      qr(^Downloading\s+),
      qr(^Installing collected packages:),
      qr(^Successfully installed),
    ],
    max_lines => 50,
  );

  # pytest: compact output
  $self->register_filter(
    command => '^pytest\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^=+.*=+$/),
      qr(^Coverage report:),
      qr(^HTML report:),
    ],
    truncate_lines_at => 150,
    max_lines => 100,
  );

  # curl: strip headers
  $self->register_filter(
    command => '^curl\b',
    filter_stderr => 1,
    strip_lines_matching => [
      qr(^\s*$),
      qr(^  % Total),
      qr(^  Resolving),
      qr(^Connected to),
      qr(^HTTP/\d[\d.]*\s+\d+),
    ],
    truncate_lines_at => 200,
    max_lines => 50,
  );

  # wget: strip progress
  $self->register_filter(
    command => '^wget\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^--\d{4}-\d{2}-\d{2}),
      qr(^Resolving),
      qr(^Connecting to),
      qr(^Length:\s+\d+),
      qr(^Saving to:),
      qr(^\d+%\s+\[),
    ],
    truncate_lines_at => 200,
    max_lines => 50,
  );

  # helm install: strip progress
  $self->register_filter(
    command => '^helm\s+(install|upgrade)\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^NAME:\s+\w+),
      qr(^NAMESPACE:\s+\w+),
      qr(^STATUS:\s+),
      qr(^REVISION:\s+\d+),
      qr(^NOTES:$),
    ],
    max_lines => 50,
  );

  # ansible-playbook: strip progress
  $self->register_filter(
    command => '^ansible-playbook\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^PLAY\s+\[),
      qr(^TASK\s+\[),
      qr(^RUNNING HANDLER),
      qr(^changed:\s+\[\d+\]),
      qr(^ok:\s+\[\d+\]),
      qr(^fatal:\s+\[\d+\]),
      qr(^PLAY RECAP),
    ],
    max_lines => 100,
  );

  # rsync: strip progress
  $self->register_filter(
    command => '^rsync\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^sent\s+\d+\s+bytes),
      qr(^received\s+\d+\s+bytes),
      qr(^total size is),
    ],
    max_lines => 30,
  );

  # iptables -L: compact
  $self->register_filter(
    command => '^iptables\s+-L\b',
    strip_lines_matching => [qr(^\s*$)],
    truncate_lines_at => 150,
    max_lines => 50,
  );

  # ping: strip progress
  $self->register_filter(
    command => '^ping\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^PING\s+),
      qr(^64 bytes from),
      qr(^---.*ping statistics---),
    ],
    max_lines => 20,
  );

  # git log: compact
  $self->register_filter(
    command => '^git\s+log\b',
    strip_lines_matching => [
      qr(^\s*$),
      qr(^commit\s+[a-f0-9]+),
      qr(^Author:\s+),
      qr(^Date:\s+),
    ],
    head_lines => 20,
    tail_lines => 10,
    max_lines => 30,
  );

  # git branch: compact
  $self->register_filter(
    command => '^git\s+branch\b',
    strip_lines_matching => [qr(^\s*$)],
    max_lines => 30,
  );

  # git stash: compact
  $self->register_filter(
    command => '^git\s+stash\b',
    strip_lines_matching => [qr(^\s*$)],
    max_lines => 30,
  );

  return;
}

sub new {
  my $self = shift->SUPER::new(@_);
  $self->_build_default_filters;
  return $self;
}

sub compress {
  my ($self, $command, $stdout, $stderr) = @_;

  my $matched_filter;

  for my $key (keys %{$self->filters}) {
    my $filter = $self->filters->{$key};

    # Check if command matches
    unless ($command =~ /$key/) {
      next;
    }

    # Check output_detect if present - only apply filter if output matches
    if (my $detect = $filter->{output_detect}) {
      my @lines = split(/\n/, $stdout);
      my $has_match = grep { /$detect/ } @lines;
      unless ($has_match) {
        next;  # Skip this filter, try next one
      }
    }

    $matched_filter = $filter;
    last;  # Found matching filter
  }

  if (!$matched_filter) {
    return ($stdout, $stderr);
  }

  my ($out, $err) = ($stdout, $stderr // '');

  # Filter stderr into stdout if configured
  if ($matched_filter->{filter_stderr}) {
    $out .= "\n$err" if length $err;
    $err = '';
  }

  # Stage 1: Strip ANSI
  if ($matched_filter->{strip_ansi}) {
    $out =~ s/\x1b\[[0-9;]*[a-zA-Z]//g;
    $err =~ s/\x1b\[[0-9;]*[a-zA-Z]//g;
  }

  # Stage 2: Match output short-circuit
  for my $match (@{$matched_filter->{match_output}}) {
    if ($out =~ /$match->{pattern}/) {
      return ($match->{message}, $err);
    }
  }

  # Stage 3: Transform lines (if transform coderef provided)
  if ($matched_filter->{transform}) {
    $out = join("\n", map { $matched_filter->{transform}->($_) } split(/\n/, $out));
  }

  # Stage 4: Strip lines matching
  if (@{$matched_filter->{strip_lines_matching}}) {
    my @out_lines = split(/\n/, $out);
    @out_lines = grep {
      my $keep = 1;
      for my $pattern (@{$matched_filter->{strip_lines_matching}}) {
        if (/$pattern/) {
          $keep = 0;
          last;
        }
      }
      $keep;
    } @out_lines;
    $out = join("\n", @out_lines);
  }

  # Stage 5: Keep lines matching (if any)
  if (@{$matched_filter->{keep_lines_matching}}) {
    my @out_lines = split(/\n/, $out);
    @out_lines = grep {
      my $keep = 0;
      for my $pattern (@{$matched_filter->{keep_lines_matching}}) {
        if (/$pattern/) {
          $keep = 1;
          last;
        }
      }
      $keep;
    } @out_lines;
    $out = join("\n", @out_lines);
  }

  # Stage 6: Truncate lines at N chars
  if ($matched_filter->{truncate_lines_at} > 0) {
    my $max = $matched_filter->{truncate_lines_at};
    $out = join("\n", map { length $_ > $max ? substr($_, 0, $max) . '...' : $_ } split(/\n/, $out));
    $err = join("\n", map { length $_ > $max ? substr($_, 0, $max) . '...' : $_ } split(/\n/, $err)) if length $err;
  }

  # Stage 7: Head/Tail lines
  if ($matched_filter->{head_lines} > 0) {
    my @lines = split(/\n/, $out);
    my $head = $matched_filter->{head_lines};
    my $tail = $matched_filter->{tail_lines} // 0;
    my $omit = @lines - $head - $tail;
    if ($omit > 0 && $tail > 0) {
      $out = (join("\n", @lines[0..$head-1])) . "\n... $omit lines omitted ...\n" . (join("\n", @lines[-$tail..-1]));
    }
    elsif ($omit > 0) {
      $out = join("\n", @lines[0..min($head, @lines)-1]);
    }
  }
  elsif ($matched_filter->{tail_lines} > 0) {
    my @lines = split(/\n/, $out);
    $out = join("\n", @lines[-min($matched_filter->{tail_lines}, @lines)..-1]);
  }

  # Stage 8: Max lines
  if ($matched_filter->{max_lines} > 0) {
    my @out_lines = split(/\n/, $out);
    if (@out_lines > $matched_filter->{max_lines}) {
      $out = join("\n", @out_lines[0..$matched_filter->{max_lines}-1]) . "\n... " . (@out_lines - $matched_filter->{max_lines}) . " more lines ...";
    }
  }

  # Stage 9: On empty
  if (!length trim($out) && $matched_filter->{on_empty}) {
    $out = $matched_filter->{on_empty};
  }

  return ($out, $err);
}

1;

=head1 AUTHOR

Torsten Raudssus L<https://raudssus.de/>

=head1 COPYRIGHT

Copyright 2026 Torsten Raudssus

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
