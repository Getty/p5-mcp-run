use Test::More;
use lib 'lib';
use MCP::Run::Compress;
use File::Temp qw(tempdir);
use File::Basename qw(dirname);
use File::Spec;

subtest 'compress ls -la' => sub {
  my $c = MCP::Run::Compress->new;

  my $input = <<'OUTPUT';
total 24
drwxr-xr-x  14 getty getty  4096 Apr 24 02:32 .
drwxr-xr-x  22 getty getty  4096 Apr 24 00:29 ..
drwxr-xr-x   7 getty getty  4096 Apr 24 02:28 .git
-rw-r--r--   1 getty getty   246 Mar 12 04:03 .gitignore
drwxr-xr-x  14 getty getty  4096 Apr 24 02:32 .build
drwxr-xr-x   2 getty getty  4096 Mar 25 20:10 .claude
Device: 801h/2049d      Inode: 1234567     Links: 1
 Birth: 2024-01-01 00:00:00.000000000 +0000
OUTPUT

  my ($out, $err) = $c->compress('ls -la', $input, '');
  note "OUTPUT: $out";

  unlike($out, qr/Device:/, 'Device stripped');
  unlike($out, qr/Inode:/, 'Inode stripped');
  unlike($out, qr/Birth:/, 'Birth stripped');
  unlike($out, qr/total\s+\d+/, 'total stripped');
  like($out, qr/\.gitignore/, '.gitignore kept');

  done_testing;
};

subtest 'compress stat' => sub {
  my $c = MCP::Run::Compress->new;

  my $input = <<'OUTPUT';
  File: main.rs
  Size: 12345           Blocks: 24         IO Block: 4096   regular file
Device: 801h/2049d      Inode: 1234567     Links: 1
Access: (0644/-rw-r--r--)  Uid: ( 1000/ patrick)   Gid: ( 1000/ patrick)
Access: 2026-03-10 12:00:00.000000000 +0100
Modify: 2026-03-10 11:00:00.000000000 +0100
Change: 2026-03-10 11:00:00.000000000 +0100
 Birth: 2026-03-09 10:00:00.000000000 +0100
OUTPUT

  my ($out, $err) = $c->compress('stat main.rs', $input, '');
  note "OUTPUT: $out";

  unlike($out, qr/Device:/, 'Device stripped');
  unlike($out, qr/Inode:/, 'Inode stripped');
  unlike($out, qr/Birth:/, 'Birth stripped');
  like($out, qr/Size: 12345/, 'Size kept');
  like($out, qr/Access: \(0644/, 'Mode kept');

  done_testing;
};

subtest 'compress make' => sub {
  my $c = MCP::Run::Compress->new;

  my $input = <<'OUTPUT';
make[1]: Entering directory '/home/user/project'
gcc -O2 foo.c
bar.c
make[1]: Leaving directory '/home/user/project'
Nothing to be done
OUTPUT

  my ($out, $err) = $c->compress('make', $input, '');
  note "OUTPUT: $out";

  unlike($out, qr/Entering directory/, 'Entering stripped');
  unlike($out, qr/Leaving directory/, 'Leaving stripped');
  unlike($out, qr/Nothing to be done/, 'Nothing stripped');
  like($out, qr/gcc/, 'gcc kept');
  like($out, qr/bar\.c/, 'bar.c kept');

  done_testing;
};

subtest 'compress grep' => sub {
  my $c = MCP::Run::Compress->new;

  my $input = <<'OUTPUT';
src/main.rs:sub main {
src/main.rs:  say "hello";
src/main.rs:}
lib/Foo.pm:sub bar {
lib/Foo.pm:  my $self = shift;
OUTPUT

  my ($out, $err) = $c->compress('grep -r hello .', $input, '');
  note "OUTPUT: $out";

  like($out, qr/src\/main\.rs/, 'file:line kept');
  like($out, qr/say "hello"/, 'match content kept');

  done_testing;
};

subtest 'compress df' => sub {
  my $c = MCP::Run::Compress->new;

  my $input = <<'OUTPUT';
Filesystem     1K-blocks   Used Available Use% Mounted on
/dev/sda1        4096000 123456   3972544   4% /
tmpfs            1024000   1024   1022976   1% /dev/shm
/dev/sdb1      209715200 7890120 201866080  20% /home
/dev/sdc1      524288000 1234567896 400831104  75% /data/very/long/path/that/exceeds/80/columns
OUTPUT

  my ($out, $err) = $c->compress('df -h', $input, '');
  note "OUTPUT: $out";

  unlike($out, qr/very\/long\/path\/that\/exceeds\/80\/columns/, 'long path truncated');
  like($out, qr/\/dev\/sda1/, 'filesystem kept');

  done_testing;
};

subtest 'compress git diff' => sub {
  my $c = MCP::Run::Compress->new;

  my $input = <<'OUTPUT';
diff --git a/lib/Foo.pm b/lib/Foo.pm
index 1234567..89abcdef 100644
--- a/lib/Foo.pm
+++ b/lib/Foo.pm
@@ -10,6 +10,8 @@ sub bar {
+use strict;
+use warnings;
   my $self = shift;
   return $self->{bar};
 }
OUTPUT

  my ($out, $err) = $c->compress('git diff', $input, '');
  note "OUTPUT: $out";

  unlike($out, qr/diff --git/, 'diff header stripped');
  unlike($out, qr/index /, 'index stripped');
  like($out, qr/\+use strict/, 'added line kept');

  done_testing;
};

subtest 'no compress for unknown command' => sub {
  my $c = MCP::Run::Compress->new;

  my $input = "some output\nwith lines\nand more";
  my ($out, $err) = $c->compress('unknown-command --flag', $input, '');
  is($out, $input, 'unknown command passes through unchanged');

  done_testing;
};

subtest 'max_lines truncation' => sub {
  my $c = MCP::Run::Compress->new;

  # Use find which has max_lines => 50 and minimal strip_lines_matching
  my @lines = map { "/path/to/file$_" } (1..60);
  my $input = join("\n", @lines);
  my ($out, $err) = $c->compress('find', $input, '');
  note "OUTPUT: $out";

  like($out, qr/more lines/, 'shows truncation notice');

  done_testing;
};

subtest 'on_empty fallback' => sub {
  my $c = MCP::Run::Compress->new;

  # Force whitespace-only content that gets stripped to empty
  my ($out, $err) = $c->compress('make', "   \n\n  \n", '');
  note "OUTPUT: $out";

  is($out, 'make: ok', 'on_empty message shown');

  done_testing;
};

subtest 'transform_command Co-Authored-By override' => sub {
  local $ENV{ANTHROPIC_MODEL} = 'MiniMax-M2.7';
  delete local $ENV{CO_AUTHORED_BY};
  delete local $ENV{MCP_RUN_COMPRESS_NO_CO_AUTHORED};

  my $c = MCP::Run::Compress->new;

  my $heredoc = qq{git commit -m "\$(cat <<EOF\nfix bug\n\nCo-Authored-By: Claude Opus <noreply\@anthropic.com>\nEOF\n)"};
  like $c->transform_command($heredoc), qr/Co-Authored-By: MiniMax-M2\.7\nEOF/, 'heredoc form replaced';

  my $no_signature = qq{git commit -m "fix bug"};
  my $signed = $c->transform_command($no_signature);
  like $signed, qr/Co-Authored-By: MiniMax-M2\.7/, 'signature added when missing';
  like $signed, qr/Co-Authored-By: MiniMax-M2\.7"\z/, 'signature stays inside the closing quote';

  my $multiline = qq{git commit -m "docs: rewrite README\nreferencing Manual::Migration"};
  my $multiline_signed = $c->transform_command($multiline);
  like $multiline_signed, qr/Co-Authored-By: MiniMax-M2\.7"\z/, 'multi-line message: signature stays inside the closing quote';
  unlike $multiline_signed, qr/"\s*\n\s*\n\s*Co-Authored-By/, 'multi-line message: no Co-Authored-By outside the quoted string';

  local $ENV{MCP_RUN_COMPRESS_NO_CO_AUTHORED} = 1;
  is $c->transform_command($heredoc), $heredoc, 'opt-out env disables transform';

  my $non_git = q{ls -l};
  delete local $ENV{MCP_RUN_COMPRESS_NO_CO_AUTHORED};
  is $c->transform_command($non_git), $non_git, 'non-git commands untouched';

  my $compound = qq{cd /tmp && git add foo && git commit -m "\$(cat <<'EOF'\nfix bug\n\nCo-Authored-By: Claude Opus <noreply\@anthropic.com>\nEOF\n)" && git log -1};
  like $c->transform_command($compound), qr/Co-Authored-By: MiniMax-M2\.7\nEOF/, 'compound command with git commit replaced';

  my $with_flags = qq{git -c user.email=x\@y -c user.name=Foo commit -m "fix\n\nCo-Authored-By: Claude Opus <noreply\@anthropic.com>"};
  like $c->transform_command($with_flags), qr/Co-Authored-By: MiniMax-M2\.7/, 'git -c flags between git and commit replaced';

  my $across_separator = q{git status; git log --grep=commit -m "fix"};
  is $c->transform_command($across_separator), $across_separator, 'pattern does not cross command separators';

  # Regression: the injected trailer must land in the commit MESSAGE, never
  # in a trailing quoted argument of a compound command. The old injection
  # targeted the last quote of the whole command line, so `... && git config
  # user.name "y"` had the trailer written into the config value.
  my $config_after = q{git commit -m "init" && git config user.name "Test User"};
  my $config_signed = $c->transform_command($config_after);
  like $config_signed, qr/init\n\nCo-Authored-By: MiniMax-M2\.7"/, 'compound: trailer inside commit message';
  like $config_signed, qr/config user\.name "Test User"$/, 'compound: trailing config value untouched';

  my $echo_after = q{git commit -m "init" && echo "done"};
  my $echo_signed = $c->transform_command($echo_after);
  like $echo_signed, qr/echo "done"$/, 'compound: trailing echo argument untouched';

  my $author_arg = q{git commit -m "done" --author "Foo Bar <f@b.c>"};
  my $author_signed = $c->transform_command($author_arg);
  like $author_signed, qr/--author "Foo Bar <f\@b\.c>"$/, 'trailing --author untouched';

  my $no_message = q{git commit --amend};
  is $c->transform_command($no_message), $no_message, 'no -m argument: no injection';

  # Regression: bundled short flags. `git commit -am "..."` contains no
  # literal `-m`, so a regex looking for one skipped the injection and the
  # trailer was silently dropped.
  my $bundled = q{git commit -am "init"};
  like $c->transform_command($bundled),
    qr/-am "init\n\nCo-Authored-By: MiniMax-M2\.7"\z/,
    'bundled -am: trailer inside the commit message';

  my $bundled_many = q{git commit -anm "init"};
  like $c->transform_command($bundled_many),
    qr/-anm "init\n\nCo-Authored-By: MiniMax-M2\.7"\z/,
    'bundled -anm: trailer inside the commit message';

  my $bundled_compound = q{git commit -am "init" && git config user.name "Test User"};
  my $bundled_compound_signed = $c->transform_command($bundled_compound);
  like $bundled_compound_signed, qr/-am "init\n\nCo-Authored-By: MiniMax-M2\.7"/,
    'bundled -am compound: trailer inside commit message';
  like $bundled_compound_signed, qr/config user\.name "Test User"$/,
    'bundled -am compound: trailing config value untouched';

  # The widened flag pattern must stay a flag pattern: bundles not ending
  # in `m` carry no message, and a `-m` inside an argument value is not an
  # argument boundary.
  my $bundle_no_m = q{git commit -av "init"};
  is $c->transform_command($bundle_no_m), $bundle_no_m,
    'bundled flags not ending in m: no injection';

  my $dash_m_in_path = q{git commit -F /tmp/msg-m "unrelated"};
  is $c->transform_command($dash_m_in_path), $dash_m_in_path,
    '-m inside an argument value is not the message flag';

  # Regression: replacing an existing Co-Authored-By line must not swallow
  # the closing quote when the trailer ends the -m "..." message. The old
  # s/Co-Authored-By: [^\n]+/.../g matched the quote too, leaving the shell
  # with an unterminated string.
  my $trailer_in_msg = qq{git commit -m "Fix bug\n\nCo-Authored-By: Claude <noreply\@anthropic.com>"};
  my $replaced = $c->transform_command($trailer_in_msg);
  like $replaced, qr/Co-Authored-By: MiniMax-M2\.7"/, 'replacement keeps the closing quote';
  unlike $replaced, qr/Co-Authored-By: Claude/, 'old trailer replaced';

  done_testing;
};

subtest 'Co-Authored-By value is validated before it reaches the shell' => sub {
  delete local $ENV{MCP_RUN_COMPRESS_NO_CO_AUTHORED};
  delete local $ENV{ANTHROPIC_MODEL};
  delete local $ENV{CO_AUTHORED_BY};

  my $c = MCP::Run::Compress->new;

  # Both code paths of the git-commit command_transform: the injection (no
  # trailer yet) and the replacement (trailer already present).
  my $inject  = q{git commit -m "harmless"};
  my $replace = qq{git commit -m "harmless\n\nCo-Authored-By: Claude <noreply\@anthropic.com>"};

  # What a Co-Authored-By trailer legitimately looks like must keep working.
  for my $ok (
    'claude-opus-5',
    'MiniMax-M2.7',
    'Claude Opus 5 <noreply@anthropic.com>',
    'us.anthropic.claude-opus-4-20250514-v1:0',
  ) {
    local $ENV{CO_AUTHORED_BY} = $ok;
    my $q = quotemeta $ok;
    like $c->transform_command($inject), qr/Co-Authored-By: $q"\z/,
      "accepted, injected: $ok";
    like $c->transform_command($replace), qr/Co-Authored-By: $q"\z/,
      "accepted, replaced: $ok";
  }

  # Anything that would turn the trailer into shell code is refused, and a
  # refusal means the command comes back untouched -- no half-written
  # trailer, no mangled commit message.
  my %rejected = (
    'closing double quote'   => 'evil" ; echo pwned ; echo "',
    'command substitution'   => 'evil $(echo pwned)',
    'backtick'               => 'evil `echo pwned`',
    'variable expansion'     => 'evil $HOME',
    'backslash'              => 'evil\\',
    'newline'                => "evil\necho pwned",
    'single quote'           => "O'Brien",
    'semicolon'              => 'evil; echo pwned',
    'leading space'          => ' evil',
  );
  for my $why (sort keys %rejected) {
    local $ENV{CO_AUTHORED_BY} = $rejected{$why};
    is $c->transform_command($inject), $inject,
      "rejected ($why): injection path leaves the command untouched";
    is $c->transform_command($replace), $replace,
      "rejected ($why): replacement path leaves the command untouched";
  }

  # The fallback variable goes through the same gate ...
  {
    delete local $ENV{CO_AUTHORED_BY};
    local $ENV{ANTHROPIC_MODEL} = 'evil" ; echo pwned ; echo "';
    is $c->transform_command($inject), $inject,
      'ANTHROPIC_MODEL is validated too';
  }

  # ... and an invalid explicit setting is refused instead of silently
  # falling back to the other variable.
  {
    local $ENV{CO_AUTHORED_BY}  = 'evil" ; echo pwned ; echo "';
    local $ENV{ANTHROPIC_MODEL} = 'claude-opus-5';
    is $c->transform_command($inject), $inject,
      'invalid CO_AUTHORED_BY does not fall back to ANTHROPIC_MODEL';
  }

  # The claim is not "the string differs" but "no foreign command runs".
  # Execute the rewritten command against a stub git inside a temp dir; the
  # marker only appears if the payload became shell code of its own.
  my $tmp    = tempdir(CLEANUP => 1);
  my $marker = "$tmp/pwned";
  open my $stub, '>', "$tmp/git" or die "cannot write git stub: $!";
  print $stub qq{#!/bin/sh\ntouch "$tmp/git-ran"\nexit 0\n};
  close $stub;
  chmod 0755, "$tmp/git";

  local $ENV{CO_AUTHORED_BY} = qq{evil" ; touch "$marker" ; echo "};
  my $rewritten = $c->transform_command($inject);
  {
    local $ENV{PATH} = "$tmp:$ENV{PATH}";
    system('bash', '-c', $rewritten);
  }
  ok -e "$tmp/git-ran", 'the rewritten command really ran (stub git was called)';
  ok !-e $marker, 'nothing but git ran: no foreign command from the payload';

  done_testing;
};

subtest 'carriage returns collapse to what the terminal actually shows' => sub {
  my $c = MCP::Run::Compress->new;

  # A progress bar the way cargo, npm, pip, docker and friends draw it:
  # thousands of states written over each other with \r, not a single
  # newline in the whole output. Every line-based stage of the pipeline is
  # blind to this -- for split(/\n/) it is one line.
  my $states = 3000;
  my $bar = join("\r", map {
    sprintf '[%-40s] %3d%% eta %ds', '#' x int($_ * 40 / $states), int($_ * 100 / $states), $states - $_
  } 1 .. $states) . "\r";  # bars usually end on a bare \r

  cmp_ok length($bar), '>', 150_000, 'fixture is a fat progress bar';
  is scalar(() = $bar =~ /\n/g), 0, 'fixture has no newline at all';

  # Filters without truncate_lines_at -- the 28 that had no defence at all.
  for my $command ('cargo build', 'make all', 'npm install', 'docker build .') {
    my ($out, $err) = $c->compress($command, $bar, '');
    cmp_ok length($out), '<', 200, "$command: bar collapsed instead of passed through";
    like $out, qr/100% eta 0s/, "$command: the state the user saw last is kept";
    unlike $out, qr/eta 2999s/, "$command: the first state is gone";
    unlike $out, qr/\r/, "$command: no carriage return left in the output";
  }

  # Progress goes to stderr just as often (pip, docker, wget, curl).
  {
    my ($out, $err) = $c->compress('pip install foo', '', $bar);
    my $both = "$out$err";
    cmp_ok length($both), '<', 200, 'stderr bar collapsed too';
    like $both, qr/100% eta 0s/, 'stderr: last state kept';
  }

  # process() is the second, hashref-shaped copy of the same pipeline.
  {
    my $r = $c->process('cargo build', $bar, '');
    cmp_ok length($r->{stdout}), '<', 200, 'process(): bar collapsed';
    like $r->{stdout}, qr/100% eta 0s/, 'process(): last state kept';
  }

  # Windows line endings are line endings, not a progress bar: \r\n must
  # not swallow the line in front of it.
  {
    my $crlf = "first line\r\nsecond line\r\nthird line\r\n";
    my ($out) = $c->compress('make all', $crlf, '');
    like $out, qr/^first line$/m,  'CRLF: first line survives';
    like $out, qr/^second line$/m, 'CRLF: second line survives';
    like $out, qr/^third line$/m,  'CRLF: third line survives';
    unlike $out, qr/\r/, 'CRLF: carriage returns removed';
  }

  # The last segment of a bar is usually empty (trailing bare \r); what the
  # user saw is the last non-empty one. And a bar that ends in \r\n must
  # still collapse the \r-separated states in front of it.
  {
    my ($out) = $c->compress('make all', "step 1\rstep 2\rstep 3\r", '');
    is $out, 'step 3', 'trailing bare \r does not blank the line';

    my ($mixed) = $c->compress('make all', "dl 10%\rdl 55%\rdl 100%\r\nunpacking done\n", '');
    is $mixed, "dl 100%\nunpacking done", 'bar ending in CRLF: states collapsed, next line intact';
  }

  # Nothing is taken away from output that has no \r: it must come through
  # the new stage byte-identical.
  {
    my $plain = "one\ntwo\nthree\n";
    my ($out) = $c->compress('make all', $plain, '');
    is $out, "one\ntwo\nthree", 'output without \r is untouched by the new stage';
  }

  done_testing;
};

subtest 'compress() and process() are the same pipeline' => sub {
  # karr #23: the eleven stages exist twice, once list-shaped and once
  # hashref-shaped. This subtest is the safety net for pulling them
  # together, and it is deliberately not two examples: a divergence in a
  # stage that rarely fires (on_empty, head/tail, match_output) is exactly
  # the kind that stays hidden. The corpus is the whole filter table
  # crossed with the output shapes the stages react to.
  local $ENV{CO_AUTHORED_BY} = 'claude-opus-5';
  delete local $ENV{ANTHROPIC_MODEL};
  delete local $ENV{MCP_RUN_COMPRESS_NO_CO_AUTHORED};

  my $c = MCP::Run::Compress->new;

  # One command per legacy (regex-keyed) filter, plus commands no filter
  # knows -- those take the early return, which is a pipeline path of its
  # own.
  my @commands = (
    'ls -la',
    'cat lib/Foo.pm',
    'cpanm Some::Module',
    'df -h',
    'find . -name "*.pm"',
    'git diff',
    'grep -rn needle .',
    'make all',
    'ps aux',
    'stat lib/Foo.pm',
    'git commit -m "fix bug"',
    qq{git commit -m "fix bug\n\nCo-Authored-By: Old One <a\@b.de>"},
    'shopify theme push',
    'bun install',
    'gradle build',
    'my-own-tool --go',
    'unknown-command --flag',
    '',
  );

  # ... and one derived from every parsed_command filter, straight from the
  # filter table, so a filter added later is covered without touching this
  # test.
  for my $key (sort keys %{$c->filters}) {
    next unless $key =~ /^parsed:/;
    my (undef, $program, $subcommand, $flagspec) = split /:/, $key, 4;
    my @flags = map {
      my ($name, $value) = split /=/, $_, 2;
      (defined $value && $value ne '1') ? "--$name=$value" : "--$name";
    } grep { length } split /,/, ($flagspec // '');
    push @commands, join ' ', grep { defined && length } $program, $subcommand, @flags;
  }

  # And every one of them again as a compound command. Two filters can match
  # one command, and since karr #25 the output filter and the command
  # rewrite are two independent decisions -- a corpus of only simple
  # commands cannot see either fact. That blind spot is exactly how #25
  # stayed hidden behind a 48-command sweep.
  push @commands, map { qq{$_ && git commit -m "fix"} } grep { length } @commands;

  # Guard against a corpus that quietly stops covering the table.
  my @uncovered = grep {
    my $key = $_;
    !grep { $_ =~ /$key/ } @commands;
  } grep { !/^parsed:/ } sort keys %{$c->filters};
  is scalar(@uncovered), 0, 'every regex filter is reached by the corpus'
    or diag "uncovered: @uncovered";

  my $bar = join("\r",
    map { sprintf '[%-20s] %3d%% eta %ds', '#' x int($_ / 15), int($_ / 3), 300 - $_ } 1 .. 300
  ) . "\r";

  my %outputs = (
    'undef'           => undef,
    'empty'           => '',
    'whitespace only' => "   \n\n  \n",
    'plain'           => "one\ntwo\nthree\n",
    'no trailing nl'  => "one\ntwo\nthree",
    'many lines'      => join("\n", map { "line $_ /path/to/file$_" } 1 .. 200),
    'long lines'      => ('x' x 400) . "\nshort\n" . ('y' x 250),
    'ansi'            => "\e[32mgreen\e[0m ok\n\e[1;31merror\e[0m bad\n",
    'progress bar'    => $bar,
    'crlf'            => "first\r\nsecond\r\nthird\r\n",
    'bar then text'   => "dl 10%\rdl 100%\r\nunpacking done\n",
    'ls listing'      => "total 24\ndrwxr-xr-x 14 getty getty 4096 Apr 24 02:32 .\n-rw-r--r--  1 getty getty 246 Mar 12 04:03 .gitignore\n",
    'git diff'        => "diff --git a/x b/x\nindex 1234567..89abcde 100644\n--- a/x\n+++ b/x\n\@\@ -1 +1,2 \@\@\n+use strict;\n done\n",
    'make noise'      => "make[1]: Entering directory '/x'\ngcc -O2 foo.c\nNothing to be done\n",
    'npm noise'       => "up to date, audited 231 packages in 2s\n\nfound 0 vulnerabilities\n",
    'high bytes'      => "caf\xc3\xa9\n\x00\x01binary-ish\n",
  );

  my %errors = (
    'no stderr'    => '',
    'undef stderr' => undef,
    'diagnostics'  => "warning: deprecated\nerror: boom\n",
    'stderr bar'   => $bar,
  );

  my $same = sub {
    my ($x, $y) = @_;
    return 1 if !defined $x && !defined $y;
    return 0 if !defined $x || !defined $y;
    return $x eq $y;
  };

  my ($compared, $effective, @divergences, @command_divergences) = (0, 0);
  for my $command (@commands) {
    # Depends on the command alone -- hoisted out of the output loops.
    my $expected_command = $c->transform_command($command);

    for my $oname (sort keys %outputs) {
      for my $ename (sort keys %errors) {
        my ($stdout, $stderr) = ($outputs{$oname}, $errors{$ename});

        my @list = $c->compress($command, $stdout, $stderr);
        my $hash = $c->process($command, $stdout, $stderr);

        $compared++;
        $effective++ if $list[0] ne ($stdout // '') || $list[1] ne ($stderr // '');

        # Decision 1 has exactly one rule since karr #25 -- transform_command
        # -- and process() must not have a second opinion about it.
        push @command_divergences, sprintf "command=<%s>: process() said <%s>", $command, $hash->{command}
          unless $hash->{command} eq $expected_command;

        next if $same->($list[0], $hash->{stdout}) && $same->($list[1], $hash->{stderr});
        push @divergences, sprintf
          "command=<%s> stdout=%s stderr=%s\n  compress: out=%s err=%s\n  process:  out=%s err=%s",
          $command, $oname, $ename,
          _show($list[0]), _show($list[1]),
          _show($hash->{stdout}), _show($hash->{stderr});
      }
    }
  }

  # The claim only means something if the matrix is broad AND actually
  # reaches the stages: an all-pass-through matrix would agree trivially.
  note sprintf "matrix: %d commands, %d comparisons, %d of them filtered", scalar(@commands), $compared, $effective;
  cmp_ok scalar(@commands), '>=', 80, 'corpus spans the whole filter table, plain and compound';
  cmp_ok $compared, '>', 4000, 'equivalence is checked over a broad matrix';
  cmp_ok $effective, '>', 500, 'the matrix really exercises the filters, not just pass-through';

  is scalar(@command_divergences), 0, 'process() reports exactly the command transform_command produces'
    or diag join "\n", @command_divergences[0 .. ($#command_divergences > 9 ? 9 : $#command_divergences)];

  is scalar(@divergences), 0, 'compress() and process() agree on every pair'
    or diag join "\n", @divergences[0 .. ($#divergences > 9 ? 9 : $#divergences)];

  # Two headline cases spelled out, so the subtest still says something
  # concrete when the aggregate count is all one reads.
  {
    my $input = "total 24\ndrwxr-xr-x 14 getty getty 4096 Apr 24 02:32 .\n";
    my @list = $c->compress('ls -la', $input, 'oops');
    my $hash = $c->process('ls -la', $input, 'oops');
    is_deeply [@list], [$hash->{stdout}, $hash->{stderr}], 'ls -la: identical result';
  }
  {
    my $input = "some output\nwith lines\n";
    my @list = $c->compress('my-own-tool --go', $input, 'oops');
    my $hash = $c->process('my-own-tool --go', $input, 'oops');
    is_deeply [@list], [$hash->{stdout}, $hash->{stderr}], 'unknown command: identical result';
  }

  done_testing;
};

subtest 'Co-Authored-By: detection and replacement agree on spelling' => sub {
  # karr #18: the detection was case-insensitive, the replacement in the
  # same branch was not. A lower- or upper-cased trailer entered the branch,
  # replaced nothing, and returned early -- so the injection below never ran
  # either and the commit came out with NO trailer at all. The property
  # under test is therefore not "the value is right" but "there is exactly
  # one trailer and it carries the new value".
  local $ENV{CO_AUTHORED_BY} = 'claude-opus-5';
  delete local $ENV{ANTHROPIC_MODEL};
  delete local $ENV{MCP_RUN_COMPRESS_NO_CO_AUTHORED};

  my $c = MCP::Run::Compress->new;

  for my $spelling ('Co-Authored-By:', 'co-authored-by:', 'CO-AUTHORED-BY:', 'Co-authored-by:', 'co-Authored-By:') {
    my $cmd = qq{git commit -m "fix bug\n\n$spelling alt <a\@b.de>"};
    my $got = $c->transform_command($cmd);

    my $count = () = $got =~ /Co-Authored-By:/gi;
    is $count, 1, "$spelling exactly one trailer";
    like $got, qr/\nCo-Authored-By: claude-opus-5"\z/,
      "$spelling replaced with the new value, canonical spelling, closing quote intact";
    unlike $got, qr/alt <a\@b\.de>/, "$spelling old trailer value gone";
  }

  # Same class of bug, same fix: the substitution is now its own condition,
  # so a shape the replacement does not reach can no longer swallow the
  # injection. git itself does not insist on the space after the colon.
  {
    my $cmd = qq{git commit -m "fix bug\n\nCo-Authored-By:alt <a\@b.de>"};
    my $got = $c->transform_command($cmd);
    my $count = () = $got =~ /Co-Authored-By:/gi;
    is $count, 1, 'no space after the colon: exactly one trailer';
    like $got, qr/\nCo-Authored-By: claude-opus-5"\z/, 'no space after the colon: normalized';
  }

  # The heredoc form is what Claude Code actually emits.
  {
    my $heredoc = qq{git commit -m "\$(cat <<EOF\nfix bug\n\nco-authored-by: Claude <noreply\@anthropic.com>\nEOF\n)"};
    like $c->transform_command($heredoc), qr/\nCo-Authored-By: claude-opus-5\nEOF/,
      'heredoc with a lower-cased trailer: replaced in place';
  }

  # The MCP path reaches the same transform through the pipeline.
  {
    my $r = $c->process(qq{git commit -m "fix\n\nco-authored-by: alt <a\@b.de>"}, '', '');
    like $r->{command}, qr/\nCo-Authored-By: claude-opus-5"\z/,
      'process(): the fix reaches the MCP path too';
  }

  # A refused value still means no rewrite at all -- for every spelling.
  {
    local $ENV{CO_AUTHORED_BY} = 'evil" ; echo pwned ; echo "';
    my $cmd = qq{git commit -m "fix\n\nco-authored-by: alt <a\@b.de>"};
    is $c->transform_command($cmd), $cmd, 'invalid value: lower-cased trailer left untouched too';
  }

  done_testing;
};

subtest 'progress bars of unknown commands collapse too' => sub {
  # karr #22: the collapse stage sat INSIDE the filtered part of the
  # pipeline, so a command no filter knows returned before reaching it and
  # its bar went through whole -- bun, gradle, deno, mise and every
  # self-written script draw bars and have no filter. \r overwrites are
  # presentation, not filtering: what we hand the model is what stood in
  # the terminal. Everything else about the pass-through stays untouched.
  my $c = MCP::Run::Compress->new;

  my $states = 3000;
  my $bar = join("\r", map {
    sprintf '[%-40s] %3d%% eta %ds', '#' x int($_ * 40 / $states), int($_ * 100 / $states), $states - $_
  } 1 .. $states) . "\r";
  cmp_ok length($bar), '>', 150_000, 'fixture is a fat progress bar';

  for my $command ('bun install', 'gradle build', 'deno task build', 'my-own-tool --go', 'pnpm dlx something') {
    my ($out, $err) = $c->compress($command, $bar, '');
    cmp_ok length($out), '<', 200, "$command: bar collapsed although no filter matches";
    like $out, qr/100% eta 0s/, "$command: the state the user saw last is kept";
    unlike $out, qr/\r/, "$command: no carriage return left";

    my ($eout, $eerr) = $c->compress($command, '', $bar);
    cmp_ok length($eerr), '<', 200, "$command: stderr bar collapsed too";

    my $r = $c->process($command, $bar, $bar);
    cmp_ok length($r->{stdout}), '<', 200, "$command: process() collapses stdout";
    cmp_ok length($r->{stderr}), '<', 200, "$command: process() collapses stderr";
  }

  # The pass-through contract for unknown commands is otherwise intact:
  # nothing is stripped, truncated or counted.
  {
    my $many = join("\n", map { "line $_ /path/to/file$_" } 1 .. 200) . "\n";
    my ($out, $err) = $c->compress('my-own-tool --go', $many, "warning: careful\n");
    is $out, $many, 'no filter: 200 lines pass through untouched, byte for byte';
    is $err, "warning: careful\n", 'no filter: stderr passes through untouched';
    unlike $out, qr/more lines/, 'no filter: nothing is truncated';
  }

  # Output without a \r comes back byte-identical, trailing newline included.
  {
    my $plain = "one\ntwo\nthree\n";
    my ($out) = $c->compress('my-own-tool --go', $plain, '');
    is $out, $plain, 'no filter, no \r: byte-identical, trailing newline kept';
  }

  # CRLF is a line ending, not a bar: every line survives the normalization.
  {
    my ($out) = $c->compress('my-own-tool --go', "first\r\nsecond\r\nthird\r\n", '');
    is $out, "first\nsecond\nthird\n", 'no filter: CRLF normalized, no line lost';
  }

  # A bar followed by real output keeps the real output.
  {
    my ($out) = $c->compress('bun install', "dl 10%\rdl 55%\rdl 100%\r\ndone in 2s\n", '');
    is $out, "dl 100%\ndone in 2s\n", 'no filter: states collapsed, the line after the bar intact';
  }

  done_testing;
};

subtest 'command rewrite and output filter are independent decisions' => sub {
  # karr #25: both decisions used to come out of one filter lookup, so a
  # compound command like `cat msg.txt && git commit -m "fix"` -- where the
  # anchored cat filter and the deliberately unanchored git-commit filter
  # both match -- got exactly one of the two, decided by Perl's per-process
  # hash order. Neither answer was right: the git-commit filter shapes no
  # output at all (it exists only for its command_transform), so winning
  # meant the cat output passed through raw, and losing meant no trailer.
  local $ENV{CO_AUTHORED_BY} = 'claude-opus-5';
  delete local $ENV{ANTHROPIC_MODEL};
  delete local $ENV{MCP_RUN_COMPRESS_NO_CO_AUTHORED};

  my $c = MCP::Run::Compress->new;

  # 150 lines with every tenth one blank: the cat filter strips blanks and
  # caps at 100 lines, so its notice is proof that it ran.
  my $input = join("\n", map { $_ % 10 ? "line $_ of the file" : '' } 1 .. 150) . "\n";
  my $compound = q{cat msg.txt && git commit -m "fix"};

  my $r = $c->process($compound, $input, '');
  like $r->{command}, qr/Co-Authored-By: claude-opus-5/, 'compound: the trailer is set';
  like $r->{stdout}, qr/more lines/, 'compound: and the cat filter shaped the output';
  unlike $r->{stdout}, qr/^\s*$/m, 'compound: blank lines stripped by the cat filter';

  my ($out) = $c->compress($compound, $input, '');
  is $out, $r->{stdout}, 'compound: compress() and process() still agree';

  # Neither decision may leak into the simple cases.
  {
    my $r = $c->process(q{git commit -m "fix"}, $input, '');
    like $r->{command}, qr/Co-Authored-By: claude-opus-5/, 'plain git commit: trailer set';
    is $r->{stdout}, $input, 'plain git commit: output passes through, it shapes nothing';
  }
  {
    my $r = $c->process('cat msg.txt', $input, '');
    like $r->{stdout}, qr/more lines/, 'plain cat: output filtered';
    is $r->{command}, 'cat msg.txt', 'plain cat: command untouched';
  }

  # The bug was invisible in-process: one hash order per process means one
  # answer per test run, and a green run proves nothing. Re-run the same
  # question in fresh processes with different seeds.
  my $lib = File::Spec->rel2abs(File::Spec->catdir(dirname($0), File::Spec->updir, 'lib'));
  my $child = <<'CHILD';
use MCP::Run::Compress;
my $c = MCP::Run::Compress->new;
my $input = join("\n", map { $_ % 10 ? "line $_ of the file" : '' } 1 .. 150) . "\n";
my $r = $c->process(q{cat msg.txt && git commit -m "fix"}, $input, '');
print join('|',
  ($r->{command} =~ /Co-Authored-By: claude-opus-5/ ? 'trailer' : 'no-trailer'),
  ($r->{stdout}  =~ /more lines/                    ? 'filtered' : 'raw'),
), "\n";
CHILD

  my %seen;
  for my $seed (0 .. 11) {
    local $ENV{PERL_HASH_SEED}    = $seed;
    local $ENV{PERL_PERTURB_KEYS} = 2;
    open my $fh, '-|', $^X, "-I$lib", '-e', $child
      or die "cannot run child for seed $seed: $!";
    my $line = <$fh>;
    close $fh;
    $line = "<no output>" unless defined $line;
    chomp $line;
    $seen{$line}++;
  }

  is scalar(keys %seen), 1, 'the answer no longer depends on the hash seed'
    or diag "seeds disagreed: " . join(', ', map { "$_ x$seen{$_}" } sort keys %seen);
  is_deeply [keys %seen], ['trailer|filtered'],
    'and in every process it is both: trailer set AND output filtered';

  done_testing;
};

subtest 'no two output-shaping filters compete for the same command' => sub {
  # The tie-break in _match_filter only resolves parsed_command against
  # legacy regex. Two legacy filters matching the same command would again
  # be decided by hash order, and there is no honest default answer -- so
  # this fails loudly instead, and whoever adds the colliding filter picks
  # an explicit precedence (karr #25).
  my $c = MCP::Run::Compress->new;

  my @shaping_attributes = qw(
    filter_stderr strip_ansi match_output transform
    strip_lines_matching keep_lines_matching truncate_lines_at
    head_lines tail_lines max_lines on_empty
  );
  my $shapes = sub {
    my ($filter) = @_;
    for my $attribute (@shaping_attributes) {
      my $value = $filter->{$attribute};
      next unless defined $value;
      return 1 if ref $value eq 'ARRAY' ? scalar(@$value) : $value;
    }
    return 0;
  };

  # A filter that neither shapes output nor rewrites the command is dead
  # config -- and it is also the invariant that lets _match_filter skip
  # non-shaping filters without losing anything.
  my @dead = grep { !$shapes->($c->filters->{$_}) && !$c->filters->{$_}{command_transform} }
    sort keys %{$c->filters};
  is scalar(@dead), 0, 'every registered filter either shapes output or transforms the command'
    or diag "does neither: @dead";

  # Commands: one per filter, plus the compound form that made #25 visible.
  my @programs = ('ls -la', 'cat f.txt', 'cpanm Some::Module', 'df -h', 'find . -name x',
    'git diff', 'grep -rn x .', 'make all', 'ps aux', 'stat f.txt');
  for my $key (sort keys %{$c->filters}) {
    next unless $key =~ /^parsed:/;
    my (undef, $program, $subcommand, $flagspec) = split /:/, $key, 4;
    my @flags = map {
      my ($name, $value) = split /=/, $_, 2;
      (defined $value && $value ne '1') ? "--$name=$value" : "--$name";
    } grep { length } split /,/, ($flagspec // '');
    push @programs, join ' ', grep { defined && length } $program, $subcommand, @flags;
  }
  my @commands = (@programs, map { qq{$_ && git commit -m "fix"} } @programs);
  cmp_ok scalar(@commands), '>=', 80, 'collision check spans the whole filter table, plain and compound';

  my @collisions;
  for my $command (@commands) {
    my $parsed = $c->_parse_command($command);
    # The real predicate, not a copy of it: a copy could not catch a table
    # that collides. undef stdout ignores output_detect on purpose -- two
    # filters that collide for the right output still collide.
    my @matching = grep {
      $shapes->($c->filters->{$_})
        && $c->_filter_matches($_, $c->filters->{$_}, $command, $parsed, undef)
    } sort keys %{$c->filters};

    for my $kind ('parsed', 'legacy') {
      my @same = grep { $kind eq 'parsed' ? /^parsed:/ : !/^parsed:/ } @matching;
      push @collisions, "<$command> $kind: @same" if @same > 1;
    }
  }

  is scalar(@collisions), 0, 'each command is claimed by at most one shaping filter per kind'
    or diag "give these an explicit precedence rule:\n" . join("\n", @collisions);

  done_testing;
};

sub _show {
  my ($value) = @_;
  return 'undef' unless defined $value;
  my $shown = length($value) > 120 ? substr($value, 0, 120) . '...' : $value;
  $shown =~ s/\n/\\n/g;
  $shown =~ s/\r/\\r/g;
  return "'$shown' (" . length($value) . " chars)";
}

done_testing;
