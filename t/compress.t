use Test::More;
use lib 'lib';
use MCP::Run::Compress;
use File::Temp qw(tempdir);

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

done_testing;
