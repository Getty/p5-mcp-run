package MCP::Run::Bash;
our $VERSION = '0.107';
use Mojo::Base 'MCP::Run', -signatures;

# ABSTRACT: MCP server that executes commands via bash

=head1 SYNOPSIS

    use MCP::Run::Bash;

    my $server = MCP::Run::Bash->new(
        allowed_commands  => ['ls', 'cat', 'grep'],
        working_directory => '/var/data',
        timeout           => 30,
    );
    $server->run;

=head1 DESCRIPTION

Concrete L<MCP::Run> subclass that executes commands by invoking
C<bash -c $command> via L<IPC::Open3>. Captures stdout and stderr separately,
enforces a per-command timeout using C<alarm>, and returns the exit code.

When a C<working_directory> is specified (either as a server default or
passed per-invocation), it is prepended to the command as
C<cd '$dir' && $command> before being handed to bash.

The command runs in its own process group, so a timeout reaches the whole
process tree and not just the bash that was started. On timeout the process
group is sent C<SIGTERM>, escalated to C<SIGKILL> if it is still alive after
a two second grace period, and the exit code is set to C<124> (matching the
convention used by GNU C<timeout(1)>).

A command killed by a signal reports C<128 + signal number>, the same
convention a shell uses: a build killed by the OOM killer comes back as
C<137>, not as a successful C<0>.

=cut

use IPC::Open3;
use IO::Select;
use Symbol 'gensym';
use POSIX        ':sys_wait_h';
use Errno        'EINTR';
use Scalar::Util 'looks_like_number';

# Grace period (seconds) between SIGTERM and SIGKILL when a command times
# out, plus the poll interval used while waiting for the child to go away.
# Without the escalation a child that ignores SIGTERM blocks the server for
# as long as it feels like running.
use constant TERM_GRACE => 2;
use constant REAP_POLL  => 0.05;

# Last resort when neither the per-call timeout nor the server default is a
# usable positive number. Mirrors the MCP::Run timeout attribute default: a
# command must never run unbounded, that would pin the server indefinitely.
use constant FALLBACK_TIMEOUT => 30;

# alarm() hands its argument to a C unsigned int, and 2**31-1 is the largest
# value that arrives intact. Above it alarm() either warns about a negative
# argument or - from 2**32 on - quietly sets no alarm at all, which is the
# unbounded command all over again, only without a trace. Measured, not
# assumed; Inf gets here too, since it passes for a positive number.
use constant MAX_TIMEOUT => 2**31 - 1;

has name => 'mcp-run-bash';

=attr name

Server name reported to the MCP client in C<serverInfo>. Defaults to
C<mcp-run-bash>, overriding the C<PerlServer> default inherited from
L<MCP::Server>. Pass C<name> to the constructor to identify as something else.

=cut

has version => $VERSION;

=attr version

Server version reported to the MCP client in C<serverInfo>. Defaults to this
distribution's version, overriding the C<1.0.0> default inherited from
L<MCP::Server>.

=cut

sub execute ($self, $command, $working_directory, $timeout) {
  my $full_command = $command;
  if (defined $working_directory && length $working_directory) {
    my $escaped = $working_directory;
    $escaped =~ s/'/'\\''/g;
    $full_command = "cd '$escaped' && $command";
  }

  $timeout = $self->_effective_timeout($timeout);

  my ($stdout, $stderr) = ('', '');
  my ($exit_code, $error);

  eval {
    my $err = gensym;

    # open3 with '-' forks without exec'ing and returns 0 in the child, which
    # lets the child put itself into its own process group *before* exec.
    # Doing that from the parent loses a race: open3 only returns once the
    # child has exec'd, and setpgid() on an already exec'd child fails with
    # EACCES, leaving the command in our own group where it cannot be
    # signalled as a group.
    my $pid = open3(my $in, my $out, $err, '-');
    unless ($pid) {
      eval { setpgrp(0, 0) };    # best effort: not available everywhere
      exec 'bash', '-c', $full_command
        or print STDERR "mcp-run-bash: exec of bash failed: $!\n";
      POSIX::_exit(127);         # must never return into the parent program
    }
    close $in;

    my $select = IO::Select->new($out, $err);
    my $timed_out = 0;

    # The command has its own process group now, so a group kill aimed at us
    # no longer reaches it. Forward the termination signals ourselves, or a
    # cancelled run would leave the command behind after we are gone. Signals
    # the embedding program handles or ignores itself are left alone: how a
    # Mojo server shuts down is its decision, not ours.
    my @forward = grep { _signal_unclaimed($_) } qw(HUP INT TERM);
    local @SIG{@forward} = map {
      my $signal = $_;
      sub { _terminate($pid); $SIG{$signal} = 'DEFAULT'; kill $signal, $$ };
    } @forward;

    local $SIG{ALRM} = sub { $timed_out = 1; die "alarm\n" };
    alarm($timeout);

    my $status;
    eval {
      while ($select->count) {
        my @ready = $select->can_read;
        # can_read comes back empty when a signal interrupted the select, not
        # only at end of output. Looping on the handle count instead of on
        # can_read keeps that from cutting the output short; a select that
        # keeps failing is bounded by the alarm above.
        next unless @ready;
        for my $fh (@ready) {
          my $buf;
          my $bytes = sysread($fh, $buf, 4096);
          if (!defined $bytes) {
            # A signal interrupting the read is not end of output; treating
            # EINTR as EOF would silently truncate what the command wrote.
            next if $! == EINTR;
            $select->remove($fh);
            next;
          }
          if (!$bytes) {
            $select->remove($fh);
            next;
          }
          if ($fh == $out) { $stdout .= $buf }
          else             { $stderr .= $buf }
        }
      }

      # Reaped under the alarm on purpose: a command that closes its output
      # and keeps running - 'exec >/dev/null 2>&1; sleep 300' - reaches this
      # point immediately, and an unguarded waitpid would let it outrun its
      # timeout by as much as it liked.
      waitpid($pid, 0);
      $status = $?;
    };

    alarm(0);

    if ($timed_out) {
      _terminate($pid);
      $exit_code = 124;
      $error     = "Command timed out after ${timeout}s";
    }
    elsif (defined $status) {
      # A signalled child carries the signal number in the low byte and zero
      # in the high byte, so $? >> 8 alone would report success. Use the
      # shell convention instead.
      $exit_code = ($status & 127) ? 128 + ($status & 127) : $status >> 8;
    }

    close $out;
    close $err;
  };

  if ($@ && !defined $exit_code) {
    $exit_code = 1;
    $error     = "$@";
    chomp $error;
  }

  chomp $stdout;
  chomp $stderr;

  return { exit_code => $exit_code, stdout => $stdout, stderr => $stderr, (defined $error ? (error => $error) : ()) };
}

=method execute

    my $result = $self->execute($command, $working_directory, $timeout);

Implements L<MCP::Run/execute>. Runs C<$command> under C<bash -c>,
capturing stdout and stderr via L<IPC::Open3> and L<IO::Select>. If
C<$working_directory> is defined, prepends C<cd '$working_directory' &&> to
the command.

The timeout is enforced with C<alarm>. A C<$timeout> C<alarm> cannot act on
falls back to the server's C<timeout> attribute, and to C<30> seconds if that
is not usable either. C<0> deliberately does not mean "no timeout": an
unbounded command would occupy the server for as long as it runs. Rejected
are C<0>, negative values, C<undef>, non-numbers, C<NaN>, C<Inf>, and
anything above C<2**31-1> - past that C<alarm> stops being able to represent
the value and sets no alarm at all, in part without even warning.

Fractions are rounded to whole seconds, and never down to zero: C<alarm>
counts in seconds, so C<0.5> becomes one second rather than no timeout.

The timeout covers the whole command, not just the part of it that produces
output: a command that closes stdout and stderr and keeps running is timed
out like any other.

On expiry the command's process group is sent C<SIGTERM>; if it has not
exited within a two second grace period it is sent C<SIGKILL>. The exit code
is C<124> either way.

A command that exits normally reports its exit status. A command killed by a
signal reports C<128 + signal number> (C<137> for C<SIGKILL>, C<143> for
C<SIGTERM>), so a signalled command is never mistaken for a successful one.

While a command runs, C<SIGHUP>, C<SIGINT> and C<SIGTERM> are stopped on the
way past: the command is killed first and the signal is then re-raised with
its default action. Without that, a kill aimed at the process calling
C<execute> would leave the command running in its own process group. A signal
the calling program handles or ignores itself is left untouched - cleaning up
after the command is then the caller's business.

Returns a hashref with keys C<exit_code>, C<stdout>, C<stderr>, and
optionally C<error>.

Residual cases the process group does not cover: a descendant that leaves the
group on its own - a daemon calling C<setsid>, or anything started with
C<nohup ... &> that re-parents itself out - survives the kill, and on a
platform without C<setpgrp> only the bash itself is signalled, leaving its
children running. Both are reported as C<124> like any other timeout.

=cut

# Stop a timed out or cancelled command: SIGTERM the group, then SIGKILL it
# if the grace period passes without the child being reaped.
sub _terminate ($pid) {
  _signal_group($pid, 'TERM');
  return 1 if _reap_within_grace($pid);
  _signal_group($pid, 'KILL');
  waitpid($pid, 0);
  return 1;
}

# True while nothing but the default action is attached to the signal, i.e.
# while taking it over for the duration of a command takes nothing away.
sub _signal_unclaimed ($signal) {
  my $handler = $SIG{$signal};
  return !ref $handler && (!defined $handler || $handler eq 'DEFAULT');
}

# Signal the command's whole process group, falling back to the bare child
# when the group kill fails (setpgrp unsupported, or the child already gone).
sub _signal_group ($pid, $signal) {
  return kill($signal, -$pid) || kill($signal, $pid);
}

sub _reap_within_grace ($pid) {
  my $waited = 0;
  while ($waited < TERM_GRACE) {
    return 1 if waitpid($pid, WNOHANG) != 0;
    select undef, undef, undef, REAP_POLL;
    $waited += REAP_POLL;
  }
  return waitpid($pid, WNOHANG) != 0;
}

# Timeouts alarm() cannot act on fall back to the server default, and then to
# FALLBACK_TIMEOUT, rather than disabling the alarm.
sub _effective_timeout ($self, $timeout) {
  my ($usable) = grep { _usable_timeout($_) } $timeout, $self->timeout, FALLBACK_TIMEOUT;

  # alarm() counts whole seconds, so half a second would become alarm(0) -
  # switching the timeout off instead of firing at once. Round that up, and
  # truncate the rest the way alarm() would, so the timeout reported back is
  # the one that actually ran.
  return $usable < 1 ? 1 : int($usable);
}

sub _usable_timeout ($value) {
  return 0 unless defined $value && looks_like_number($value);
  return 0 if $value != $value;                          # NaN
  return 0 unless $value > 0 && $value <= MAX_TIMEOUT;    # Inf fails this too
  return 1;
}

=seealso

=over

=item * L<MCP::Run> - Base class defining the C<run> MCP tool

=back

=cut

1;
