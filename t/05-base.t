use strict;
use warnings;
use Test::More;

use MCP::Run;

subtest 'base class execute dies' => sub {
  my $server = MCP::Run->new(name => 'TestServer');
  eval { $server->execute('echo hi', undef, 10) };
  like $@, qr/must be implemented by a subclass/, 'base class execute dies';
};

subtest 'default attributes' => sub {
  my $server = MCP::Run->new(name => 'TestServer');
  is $server->timeout, 30, 'default timeout is 30';
  is $server->tool_name, 'run', 'default tool_name is run';
  is $server->allowed_commands, undef, 'default allowed_commands is undef';
  is $server->working_directory, undef, 'default working_directory is undef';
};

done_testing;
