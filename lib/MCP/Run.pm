package MCP::Run;
our $VERSION = '0.003';
use Mojo::Base 'MCP::Server', -signatures;

# ABSTRACT: MCP server with a command execution tool

=head1 SYNOPSIS

    use MCP::Run::Bash;

    my $server = MCP::Run::Bash->new(
        allowed_commands  => ['ls', 'cat', 'grep'],
        working_directory => '/var/data',
        timeout           => 60,
    );
    $server->to_stdio;

=head1 DESCRIPTION

Base class for MCP servers that expose a command execution tool. Subclasses
L<MCP::Server> and registers a C<run> tool via the MCP protocol when
instantiated. Subclasses must implement L</execute> to provide the actual
execution mechanism.

The registered tool accepts a C<command> string, an optional
C<working_directory>, and an optional C<timeout>. The tool returns a text
result containing the exit code, stdout, and stderr of the executed command.

See L<MCP::Run::Bash> for a concrete implementation using
C<bash -c>.

=cut

has allowed_commands  => sub { undef };

=attr allowed_commands

ArrayRef of command names (first words) that are permitted to run. When set,
any command whose first word is not in this list is rejected with an error
result. Defaults to C<undef>, which allows all commands.

    my $server = My::MCPServer->new(
        allowed_commands => ['ls', 'cat', 'grep'],
    );

=cut

has working_directory => sub { undef };

=attr working_directory

Default working directory for command execution. Can be overridden per
invocation via the C<working_directory> argument passed to the MCP tool.
Defaults to C<undef>, which leaves the working directory unchanged.

=cut

has timeout           => 30;

=attr timeout

Default timeout in seconds for command execution. Can be overridden per
invocation via the C<timeout> argument passed to the MCP tool. Defaults to
C<30>.

=cut

has tool_name         => 'run';

=attr tool_name

Name of the MCP tool registered by this server. Defaults to C<run>.

=cut

has tool_description  => sub {
  my $self = shift;
  my $base = 'Execute a command and return stdout, stderr, and exit code';
  if ($self->compress) {
    $base .= '. Output is compressed for token efficiency - set compress:false in arguments if you need full detail';
  }
  return $base;
};

=attr tool_description

Description of the MCP tool registered by this server. Defaults to
C<Execute a command and return stdout, stderr, and exit code>.

=cut

has compress          => 0;

=attr compress

Enable output compression for LLM efficiency. When enabled, command output
is passed through a filter pipeline that removes noise, truncates lines,
and limits output. Can be set at server construction time or per-tool-call
via the C<compress> argument.

    my $server = MCP::Run::Bash->new(compress => 1);
    # Or per call: { command => 'ls -la', compress => 1 }

=cut

sub new ($class, %args) {
  my $self = $class->SUPER::new(%args);
  $self->_register_run_tool;
  return $self;
}

sub _register_run_tool ($self) {
  my $server = $self;
  $self->tool(
    name         => $self->tool_name,
    description  => $self->tool_description,
    input_schema => {
      type       => 'object',
      properties => {
        command           => { type => 'string',  description => 'The command to execute' },
        working_directory => { type => 'string',  description => 'Working directory for the command' },
        timeout           => { type => 'integer', description => 'Timeout in seconds' },
        compress          => { type => 'boolean', description => 'Compress output for LLM efficiency' },
      },
      required => ['command'],
    },
    code => sub ($tool, $args) { $server->_handle_run($tool, $args) },
  );
}

sub _handle_run ($self, $tool, $args) {
  my $command = $args->{command};

  if (my $allowed = $self->allowed_commands) {
    my ($first_word) = $command =~ /^\s*(\S+)/;
    unless ($first_word && grep { $_ eq $first_word } @$allowed) {
      return $tool->text_result("Command not allowed: $first_word", 1);
    }
  }

  my $wd      = $args->{working_directory} // $self->working_directory;
  my $timeout = $args->{timeout}           // $self->timeout;
  my $compress = $args->{compress}         // $self->compress;

  my $result = $self->execute($command, $wd, $timeout);
  return $self->format_result($tool, $result, $compress);
}

sub run_stdio ($class_or_self, %args) {
  my $self = ref $class_or_self ? $class_or_self : $class_or_self->new(%args);
  $self->to_stdio;
  return $self;
}

=method run_stdio

    MCP::Run::Bash->run_stdio(%args);
    $server->run_stdio;

Convenience wrapper that constructs the server (when called as a class
method) and hands it to L<MCP::Server/to_stdio>. Intended as the one-liner
entry point for C<bin/> scripts.

=cut

sub execute ($self, $command, $working_directory, $timeout) {
  die "execute() must be implemented by a subclass";
}

=method execute

    my $result = $self->execute($command, $working_directory, $timeout);

Abstract method that subclasses must implement. Executes C<$command> in
C<$working_directory> (may be C<undef>) with the given C<$timeout> in seconds.

Must return a hashref with the following keys:

=over

=item * C<exit_code> - Integer exit code of the process.

=item * C<stdout> - Captured standard output as a string.

=item * C<stderr> - Captured standard error as a string.

=item * C<error> - Optional. A string describing an execution-level error (e.g. timeout or spawn failure).

=back

See L<MCP::Run::Bash> for the reference implementation.

=cut

sub format_result ($self, $tool, $result, $compress = undef) {
  my $exit_code = $result->{exit_code} // -1;
  my $stdout    = $result->{stdout}    // '';
  my $stderr    = $result->{stderr}    // '';
  my $error     = $result->{error};

  $compress //= $self->compress;

  if ($compress) {
    (my $compressor) = $self->_get_compressor;
    ($stdout, $stderr) = $compressor->compress('', $stdout, $stderr);
  }

  my $text = "Exit code: $exit_code\n";
  $text .= "\n=== STDOUT ===\n$stdout\n" if length $stdout;
  $text .= "\n=== STDERR ===\n$stderr\n" if length $stderr;
  $text .= "\n=== ERROR ===\n$error\n"   if defined $error;

  my $is_error = $exit_code != 0 ? 1 : 0;
  return $tool->text_result($text, $is_error);
}

my $_compressor;

sub _get_compressor ($self) {
  $_compressor //= MCP::Run::Compress->new;
  return $_compressor;
}

=method format_result

    my $mcp_result = $self->format_result($tool, $result);

Formats the hashref returned by L</execute> into an MCP tool result. Produces
a text block showing the exit code, stdout, and stderr (each section only
included when non-empty). Sets the MCP error flag when the exit code is
non-zero.

Override this method in a subclass to change the output format.

=cut

=seealso

=over

=item * L<MCP::Run::Bash> - Concrete implementation using C<bash -c>

=back

=cut

1;
