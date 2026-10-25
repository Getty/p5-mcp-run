# CLAUDE.md

MCP-Run offers two products:

1. **mcp-run-bash** (primary) – A stdio MCP server with a `run` tool that
   executes shell commands via `bash -c` and returns compressed output through
   30+ command-specific filters. For Claude Desktop, `.mcp.json` and other MCP
   clients. This is the main product.
2. **mcp-run-compress** (bonus) – A Claude Code hook that applies the same
   compression pipeline to Claude Code's built-in Bash tool.
   Compresses in PostToolUse; PreToolUse only handles Co-Authored-By and the
   `no-compress` marker.
   Handy: thanks to the Docker image (`raudssus/mcp-run-compress`) the hook can
   also be installed without a Perl toolchain on the host.

## Project structure

```
p5-mcp-run/
├── bin/
│   ├── mcp-run-bash       # MCP stdio server (PRIMARY)
│   └── mcp-run-compress   # PostToolUse compression + PreToolUse hook + installer (BONUS)
├── lib/
│   └── MCP/
│       ├── Run.pm         # Base server with run tool
│       └── Run/
│           ├── Bash.pm    # bash -c execution via IPC::Open3
│           └── Compress.pm # Filter pipeline (30+ filters)
├── t/                     # Tests
├── dist.ini               # [@Author::GETTY] + [@Author::GETTY::Docker]
└── Dockerfile             # Multi-stage build
```

## Key Commands

```bash
prove -l t              # Tests
prove -l t/10-bash.t    # Single test
dzil build              # Build distribution
dzil test               # Test with dzil
```

## mcp-run-bash (primary)

Entry point: `mcp-run-bash` or `MCP::Run::Bash->run_stdio`.

**Env vars:**
| Variable | Default | Description |
|----------|---------|-------------|
| `MCP_RUN_ALLOWED_COMMANDS` | all | Comma-separated whitelist |
| `MCP_RUN_WORKING_DIRECTORY` | cwd | Default working directory |
| `MCP_RUN_TIMEOUT` | 30 | Timeout in seconds. Integer 1..2147483647, otherwise startup aborts (no silent default) |
| `MCP_RUN_COMPRESS` | module: 0, bin: 1 | Enable compression (bin/mcp-run-bash default: 1) |
| `MCP_RUN_TOOL_NAME` | run | Name of the MCP tool |

**Compression:** `compress: true` in the tool call or `MCP_RUN_COMPRESS=1`. The
original command is passed through to `$compressor->compress()`, so
command-specific filters (ls, git, make, …) apply in MCP server mode.

**Tool Schema:**
```json
{ "command": "ls -la", "working_directory": "/tmp", "timeout": 10, "compress": false }
```

## mcp-run-compress (bonus)

Claude Code hook for the built-in Bash tool. Applies the same compression
pipeline to Claude Code's Bash output. Installable standalone via Docker
(`raudssus/mcp-run-compress`) — no Perl needed on the host.

**Two hooks, one command.** `--install-claude` registers `mcp-run-compress
--hook` on two events; the script dispatches on `hook_event_name`:
- **PostToolUse** compresses, via `hookSpecificOutput.updatedToolOutput`. The
  command is not touched.
- **PreToolUse** only does what has to happen *before* execution:
  Co-Authored-By and the `no-compress` marker.

The `--b64` rewrite and `--filter-files` are **gone**, and with them the
hardcoded 1800s timeout and the Docker pipe snippet.

**Modes** (they only choose the command line in settings.json; the code is the same):
- `native` (default): `mcp-run-compress --hook`
- `docker`: `docker run --rm -i --network none ... --hook`

**Env vars:**
| Variable | Default | Description |
|----------|---------|-------------|
| `MCP_RUN_COMPRESS_INSTALL_MODE` | native | native or docker |
| `MCP_RUN_COMPRESS_IMAGE` | raudssus/mcp-run-compress:latest | Docker image (pinned in image) |
| `MCP_RUN_COMPRESS_MAX_BYTES` | 29000 | Upper bound for the replaced output. Above it the harness persists the output and shows the model a 2 KB preview — worse than not compressing at all. Only applies when there is a raw file to point to |
| `MCP_RUN_COMPRESS_NO_CO_AUTHORED` | - | Disable Co-Authored-By |
| `CO_AUTHORED_BY` | - | Replacement for Co-Authored-By (validated: words + optional `<mail@host>`, otherwise no trailer) |
| `ANTHROPIC_MODEL` | - | Fallback for CO_AUTHORED_BY |

**Bypass:**
- `no-compress <cmd>` – PreToolUse strips the prefix and appends
  `\n# mcp-run-compress: no-compress`; PostToolUse reads the marker.
  Necessary because PostToolUse **only sees the rewritten command**
- Background commands have no output yet when the hook runs

**Three limits, all deliberate:**
- Commands with exit ≠ 0 are **not** compressed at all — there
  `PostToolUseFailure` fires, and it ignores `updatedToolOutput` (karr #24)
- Background commands, see above
- Two PostToolUse hooks do not chain: each sees the original, the one that
  answers last wins — silently

## Architecture

**MCP::Run** (lib/MCP/Run.pm):
- Registers the `run` tool
- Checks `allowed_commands` and `validator`
- Calls `execute` (subclass) and `format_result($tool, $result, $compress, $command)`

**MCP::Run::Bash** (lib/MCP/Run/Bash.pm):
- `execute()` via `IPC::Open3` as `bash -c`
- `IO::Select` for stdout/stderr
- `alarm` for timeout → exit 124
- Inherits `format_result()` from `MCP::Run`

**MCP::Run::Compress** (lib/MCP/Run/Compress.pm):
- 11-stage filter pipeline: filter_stderr, strip_ansi, collapse_cr, match_output, transform, strip_lines, keep_lines, truncate, head/tail, max_lines, on_empty
- `collapse_cr` runs unconditionally, not per filter attribute: per line it
  reduces the `\r`-separated segments to the last non-empty one, so it mirrors
  what the terminal shows. Without this stage progress bars (cargo, npm,
  docker, pip, wget) would pass through untrimmed — to `split /\n/` they are
  **one** line, and 28 of the 48 filters set no `truncate_lines_at`
- 30+ command-specific filters (ls, git, make, kubectl, cargo, cpanm, etc.)
- `_parse_command()` for git-style subcommands

## Testing Notes

**Present:**
- `t/00-load.t` – Load tests
- `t/05-base.t` – Base class
- `t/10-bash.t` – Bash execution, allowlist, validator, timeout, format_result
- `t/20-integration.t` – MCP lifecycle (server/discover, tools/list, tools/call) plus protocol contract: requests without `params._meta` or with an unsupported protocol revision are rejected
- `t/compress.t` – Compression tests
- `t/30-no-warnings.t` – Regression: Compress.pm warnings (transform returning undef, undef inputs)
- `t/40-compress-bin.t` – `bin/mcp-run-compress`: `--hook` on both events (PostToolUse compression incl. `persistedOutputPath`, byte cap with marker, background pass-through; PreToolUse Co-Authored-By and `no-compress` marker), `--install-claude` incl. migration of old 0.106 installations, fail-open on a broken `@INC`
- `t/50-bash-bin.t` – `bin/mcp-run-bash` as a subprocess over real stdio (legacy handshake): compression on/off, `serverInfo` identity, `MCP_RUN_TIMEOUT` validation. Covers the path real clients take — exactly where the compress load error slipped through
- `t/60-filters-doc.t` – Drift guard: compares the `=item` entries in `Filters.pm` against the registered filter table, in both directions. Exists because `Filters.pm` is pure documentation, loaded by no code, and therefore drifted apart unnoticed for years

**Two tests that pin down a rule instead of a behavior:** the
equivalence test in `t/compress.t` (107 commands × 16 output shapes × 4
stderr variants) insists that `compress()` and `process()` are the same
pipeline — it is the safeguard that keeps the two from drifting apart again.
And the collision test next to it insists that per command at most one
output-shaping filter of each kind matches; whoever adds a colliding filter
gets a failure asking them to set an explicit precedence rule. Both run over
several `PERL_HASH_SEED` values, otherwise they would be green by chance.

## Troubleshooting

**Hook is not called:**
1. Check `~/.claude/settings.json` – there must be **two** entries for Bash,
   PostToolUse (compression) and PreToolUse (Co-Authored-By,
   `no-compress`). If the PostToolUse entry is missing, it is an installation
   from before the rework: run `mcp-run-compress --install-claude` again
2. Claude Code only reads hook changes in a new session
3. Does `docker ps` show containers? (in docker mode)
4. Logs: test `docker run --rm -i raudssus/mcp-run-compress --hook` manually

**Output is uncompressed although the hook runs:** three expected reasons
before you go looking – the command ran with exit ≠ 0 (there
`PostToolUseFailure` fires, see karr #24), it was a background command, or
**another** PostToolUse hook on Bash answers after us and silently wins.

**Compression does not work in MCP mode:**
- Set `compress: true` in the tool call
- `MCP_RUN_COMPRESS=1` as env var
- Check: `format_result` is called with `$command` (lib/MCP/Run.pm)

## Release

```bash
dzil release
```

`[@Author::GETTY]` does the release: `GitHub::CreateRelease` creates the GitHub release
(CPAN tarball as asset, ChangeLog notes) and `[@Author::GETTY::Docker / compress]`
builds and pushes the Docker image (`raudssus/mcp-run-compress`, `MCP_RUN_VERSION` build arg,
`compress` stage — only the compress hook, not the mcp-run-bash runtime). Needs
`~/.github-identity` and `docker login`. `dzil build`/`dzil test` build the image
too (dev loop `prove -lr t/` unaffected).

## Links

- README.md – User documentation
- lib/MCP/Run/Compress/Filters.pm – All filters with POD
- dist.ini – [@Author::GETTY] config

## Sharp Edges (for developers)

The developer invariants and traps (no-sandbox `allowed_commands`,
`working_directory` as `chdir` in the child process (missing directory = error without execution), the byte cap, PostToolUse compression and
the hook's permission boundary, the two intentional compression defaults,
`format_result` threading, MCP >= 0.15 and the `MCP::Server::Legacy` path, the
compile-time `use` of `MCP::Run::Compress`, `serverInfo` identity) have their single
source of truth in skill `mcp-run-core` — briefed into every `mcp-run-*` agent.
Do not duplicate them here; go there for details.

## Further runner ideas

`MCP::Run::Bash` is currently the only `execute()` implementation. The
architecture allows adding further runners as `MCP::Run` subclasses —
each implements `execute($command, $wd, $timeout)` and returns the same
hashref (`exit_code`, `stdout`, `stderr`, optionally `error`).

| Idea | Purpose | Effort |
|---|---|---|
| `MCP::Run::Shell` | Choose any shell (zsh, fish, dash) instead of bash | small — copy Bash.pm almost 1:1, only the binary changes |
| `MCP::Run::Python` | `python -c $command` as an alternative, with the same compression setup | small — subclass that calls Python instead of `bash -c` |
| `MCP::Run::REPL` | Keeps a long-running interpreter process (bash / python / node), answers individual snippets — no restart per tool call | medium — bidirectional pipes, history, restart strategy |
| `MCP::Run::SSH` | `ssh user@host $command` with key-based auth | medium — auth setup, `known_hosts` handling, hop-by-hop timeout |
| `MCP::Run::Docker` | `docker exec <container> $command` — already similar to the Docker rewrite in the compress hook, but as its own MCP tool | medium — container lifecycle, image pinning, no-network flag |
| `MCP::Run::kubectl` | `kubectl exec <pod> -- $command` for cluster debugging | medium — pod selection, container spec, token refresh |
| `MCP::Run::Local` | Sandboxed variant (no bash -c, but an allowlist of binaries + arguments) | large — a real sandbox, not first-word match |

Every subclass gets for free: compression pipeline, Co-Authored-By override
(for git commands), `allowed_commands`/`validator`, `format_result`.
Compression only needs to be active if the runner itself produces output;
for SSH/kubectl the filter stays the same because `command` is passed on.

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself —
the delegation lock and the publish gate are shared house rules (skilletor bundle
`getty-cpan-dist@getty`); lanes and hazards are in `.claude/rules/mcp-run-rules.md`.

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `mcp-run-worker` |
| Commits, `Changes`, card → done, pre-release audit | `mcp-run-release-manager` |

The agent carries its skills via `briefing.skills` (see `.claude/agents/`); the main
agent delegates rather than loading them. Skill sources live under `.claude/skills/`.
The karr board (`refs/karr/*`) is the internal coordination channel.
