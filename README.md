# MCP-Run

MCP server that exposes a command execution tool via the [Model Context Protocol](https://modelcontextprotocol.io).

Subclasses [MCP::Server](https://metacpan.org/pod/MCP::Server) and registers a `run` tool that accepts a command string, executes it, and returns stdout, stderr, and the exit code.

## Installation

    cpanm MCP::Run

## Synopsis

```perl
use MCP::Run::Bash;

my $server = MCP::Run::Bash->new(
    allowed_commands  => ['ls', 'cat', 'grep', 'find'],
    working_directory => '/var/data',
    timeout           => 60,
);

$server->to_stdio;
```

## Classes

- **MCP::Run** — Abstract base class. Registers the MCP tool, validates against `allowed_commands`, and delegates to `execute()`.
- **MCP::Run::Bash** — Concrete implementation. Runs commands via `bash -c` using `IPC::Open3`. Captures stdout/stderr separately. Enforces timeouts with `alarm` (exit code 124, matching GNU `timeout(1)`).

## Attributes

| Attribute | Default | Description |
|-----------|---------|-------------|
| `allowed_commands` | `undef` (all) | ArrayRef whitelist of permitted command names (first word) |
| `working_directory` | `undef` (cwd) | Default working directory |
| `timeout` | `30` | Default timeout in seconds |
| `tool_name` | `run` | Name of the registered MCP tool |
| `tool_description` | ... | Description of the registered MCP tool |

## MCP Tool Schema

The registered tool accepts:

```json
{
  "command": "ls -la",
  "working_directory": "/tmp",
  "timeout": 10
}
```

Only `command` is required. `working_directory` and `timeout` override the server defaults per invocation.

## Author

Torsten Raudssus <torsten@raudssus.de>

## License

This is free software; you can redistribute it and/or modify it under the same terms as the Perl 5 programming language system itself.
