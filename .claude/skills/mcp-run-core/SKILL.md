---
name: mcp-run-core
description: Load before editing p5-mcp-run — the mcp-run-bash server, the IPC::Open3 execution, the command allowlist, the MCP protocol contract.
user-invocable: false
model: inherit
---

# mcp-run-core

MCP-Run offers two products from one codebase:

1. **`mcp-run-bash`** (primary) — stdio MCP server with a `run` tool that
   executes shell commands via `bash -c` and returns compressed output through
   30+ command-specific filters.
2. **`mcp-run-compress`** (bonus) — Claude Code hook that applies the same
   compression pipeline to Claude Code's built-in Bash tool.

This skill covers the server side — execution, protocol, env vars. Pipeline, hook,
filters and the compression env vars are in `mcp-run-compress`.

## Vocabulary

| Term | Meaning |
|------|---------|
| **tool** | The MCP tool `run`, registered via `MCP::Run` |
| **filter** | A single compression stage in `MCP::Run::Compress` |
| **stage** | A position in the 11-stage pipeline |
| **wire format** | JSON over stdio (MCP protocol) — the only I/O variant |
| **hook** | Two hooks for Claude Code's Bash tool: PreToolUse (Co-Authored-By, `no-compress` marker), PostToolUse (compression) |
| **marker** | `\n# mcp-run-compress: no-compress`, appended by PreToolUse, read by PostToolUse — PostToolUse only sees the *rewritten* command |
| **transform_command** | Co-Authored-By manipulation (hook) — related to but ≠ compress |

## Layer Map

```
bin/mcp-run-bash       # Stdio MCP server, primary
bin/mcp-run-compress   # Pre+PostToolUse hook + installer, bonus (compression in PostToolUse)
lib/MCP/Run.pm         # Base server, registers the `run` tool
lib/MCP/Run/Bash.pm    # bash -c via IPC::Open3
lib/MCP/Run/Compress.pm        # Filter pipeline + 30+ command filters
lib/MCP/Run/Compress/Filters.pm # Filter definitions with POD
```

`MCP::Run::Bash` inherits `format_result` from `MCP::Run`. Compression is only active
when `$compress` is true and the caller passes `$command` through — when overriding
in subclasses `$command` **must** be passed on, otherwise the
command-specific filters do not apply.

## Core invariants

- **`allowed_commands` is NOT a sandbox.** It only checks the first word of the raw
  command — `bash -c 'rm -rf /'` with `allowed_commands => ['bash']` runs.
  Real sandboxing is a separate discussion; do not try to "fix" it.
- **`working_directory` is set via `chdir` in the child process** (k42), not
  as a `cd '$dir' &&` prefix: a prefix let chain members after `;`, `&` or a
  newline run in the caller's cwd. If the `chdir` fails, the child reports it
  through a close-on-exec pipe and the command never starts (exit 1, error text).
- **Timeout → exit 124.** Same convention as GNU `timeout(1)`. Do not invent your own
  exit codes.
- **MCP >= 0.15 is mandatory** (cpanfile pin, deliberately without compatibility switches).
  Since 0.15 the protocol revision is part of *every* request: `params._meta` needs
  `protocolVersion` (checked against `MCP::Constants::SUPPORTED_VERSIONS`) and
  `clientCapabilities`, otherwise `MCP::Server::_check_meta` rejects **before** dispatch
  with `Missing protocol version`. Whoever builds a bare
  `MCP::Server::Context` in a test bypasses the transport and lands in the modern path —
  then seemingly unrelated subtests fall over at the same time, and the one real
  cause hides behind four symptoms. There `initialize` is called
  `server/discover`, and `serverInfo` lives in `result._meta`. Never hardcode the revision,
  always pull it from `MCP::Constants`.
- **Real stdio clients go through `MCP::Server::Legacy`** (classic
  `initialize` handshake, `_check_meta` skipped) — that is why the
  protocol break was purely a test problem. MCP documents this path as
  temporary, though; when it goes away, clients with the classic handshake lose access
  to `mcp-run-bash` (karr #7, open product question).
- **`serverInfo` comes from class defaults, not from the bin script.**
  `MCP::Run::Bash` sets `name`/`version` and thereby overrides the
  `MCP::Server` defaults (`PerlServer`/`1.0.0`). Identity belongs in the class
  so library users get it too — not in `bin/mcp-run-bash`.

## MCP server env vars

| Var | Default | Meaning |
|-----|---------|---------|
| `MCP_RUN_ALLOWED_COMMANDS` | all | Comma whitelist |
| `MCP_RUN_WORKING_DIRECTORY` | cwd | Default working directory |
| `MCP_RUN_TIMEOUT` | 30 | Seconds |
| `MCP_RUN_COMPRESS` | bin: 1, module: 0 | Compression active |
| `MCP_RUN_TOOL_NAME` | run | Name of the MCP tool |

## Test layout & traps

```
t/00-load.t          # Load tests
t/05-base.t          # Base class
t/10-bash.t          # bash -c, allowlist, validator, timeout, format_result
t/20-integration.t   # MCP lifecycle (server/discover, tools/list, tools/call)
                     # + protocol contract: missing _meta / old revision
t/50-bash-bin.t      # bin/mcp-run-bash as a subprocess over real stdio
                     # (legacy handshake): compression on/off, serverInfo identity
```

The compression tests: `mcp-run-compress`.

**Negative assertions alone do not catch a dead server.** In `t/50-bash-bin.t`
`unlike $text, qr/drwxr-xr-x/` and `unlike $text, qr/total \d+/` passed *empty*
on the broken build — an empty result contains no permissions column either.
What carries the test is the positive assertion (`like ... qr/^- README\.md$/m`)
paired with an `MCP_RUN_COMPRESS=0` run that must keep the raw listing.
Only this pairing prevents a crash from being "fixed" by silently switching off
compression. Always pair them like this when writing filter tests.

**`prove -l t/` is non-recursive** and skips anything in subdirs — all
tests live directly under `t/`, but get used to `prove -lr t/` anyway,
because as soon as someone creates subdirs (e.g. `t/live/`), they would otherwise be
silently skipped. **Trap:** "tests green" is wrong if subdir tests were silently
filtered out.

## Release

`dist.ini` uses `[@Author::GETTY]` for the complete release: `GitHub::CreateRelease`
creates the GitHub release (CPAN tarball as asset, ChangeLog notes), and the
`[@Author::GETTY::Docker / compress]` subsection builds and pushes the Docker image
(`raudssus/mcp-run-compress`, `target=compress`, `build_arg=MCP_RUN_VERSION=%v`).
No more `maint/release-after.pl` — the bundle plugins do everything. Needs
`~/.github-identity` and `docker login`. Multi-arch is not wired (`Docker::API`
builds single-arch). The procedure is in `getty-perl-release-author-getty` and
`perl-release-dist-ini`.

## Conventions

- Style, Moose patterns, module loading, cpanfile pinning: skill `getty-perl-core`
- Mojo::Base (attributes, defaults, lazy `sub {}`, roles) — the whole distribution
  is built on it: skill `perl-mojo`
- Bundle/POD/Changes/{{$NEXT}} conventions: skill `getty-perl-release-author-getty`
- dist.ini plugins: skill `perl-release-dist-ini`
- MCP server setup (`MCP::Server`, `$server->tool()`): skill `perl-mcp`

These skills are non-negotiable — apply them silently.
