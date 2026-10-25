---
name: mcp-run-compress
description: Load before changing the compression in p5-mcp-run — the 11-stage filter pipeline, the command filters, the PreToolUse/PostToolUse hook, the marker and the compression environment.
user-invocable: false
model: inherit
---

# mcp-run-compress — Pipeline, Hook, Filters

The compression half of MCP-Run: the filter pipeline in `MCP::Run::Compress`,
the Claude Code hook in `bin/mcp-run-compress` and the env vars that steer both.
The server, execution and the MCP protocol are covered in `mcp-run-core`.

## The 11-stage pipeline

`MCP::Run::Compress` filters in this order:

`filter_stderr → strip_ansi → collapse_cr → match_output → transform → strip_lines → keep_lines → truncate → head/tail → max_lines → on_empty`

`collapse_cr` is unconditional and has no filter attribute. Reason: to
`split /\n/` a progress bar is a single line, `max_lines` does not apply
there, and 28 of the 48 filters set no `truncate_lines_at` — without the
stage a 224 KB bar from `cargo build`, `make`, `npm install` and
`docker build` would pass through unchanged. The stage preserves identity when no
`\r` occurs (measured byte-identical across 56 command variants).

`_parse_command()` recognizes git-style subcommands so the 30+ command filters
(ls, git, make, kubectl, cargo, cpanm, …) can match. The filters themselves
live in `MCP::Run::Compress::Filters` (with POD).

## The hook

Two hooks for Claude Code's Bash tool:

- **PreToolUse** — appends the `no-compress` marker to the command and writes
  Co-Authored-By (`transform_command`).
- **PostToolUse** — compresses the output. The command is no longer
  rewritten; `--b64` and `--filter-files` no longer exist, and with them the
  hardcoded 1800s timeout and the Docker pipe snippet are gone.

**The hook makes no permission decision.** Permission is Claude Code's job.
That is why the `no-compress` marker is *appended* and not prepended: the first
word of the command is what Claude Code matches permission rules against.

**Three limits, all deliberate:**

- Commands with exit ≠ 0 are not compressed at all (there
  PostToolUseFailure fires and ignores `updatedToolOutput`, karr #24).
- Background commands have no output yet when the hook runs.
- Two PostToolUse hooks do not chain — each sees the original, the
  last one wins, silently.

**Bypass mechanisms** (do not remove, they are intentional):

- `no-compress <cmd>` — a single command without compression
- Background commands are not rewritten
- Commands that contain `mcp-run-compress` itself are not rewritten

## Invariants

- **`mcp-run-bash` compression default = ON** (bin/mcp-run-bash), but
  module attribute default = OFF (lib/MCP/Run.pm). Both defaults are intentional;
  do **not** align them.
- **`MCP::Run::Compress` is loaded at compile time** (`use` in lib/MCP/Run.pm),
  even though `_get_compressor` constructs lazily. Intent: a missing compress module
  should kill the server at **startup**, not at the first `tools/call`. Exactly
  that was missing until 0.105 and made every `tools/call` in the default configuration
  unusable. Do not turn it back into a `require` in the lazy loader.

## Hook env vars

| Var | Default | Meaning |
|-----|---------|---------|
| `MCP_RUN_COMPRESS_INSTALL_MODE` | native | native or docker |
| `MCP_RUN_COMPRESS_IMAGE` | raudssus/mcp-run-compress:latest | Docker image |
| `MCP_RUN_COMPRESS_MAX_BYTES` | 29000 | Cap on the replaced output; above it the harness persists the output and shows a 2 KB preview |
| `MCP_RUN_COMPRESS_NO_CO_AUTHORED` | — | Disable Co-Authored-By |
| `CO_AUTHORED_BY` | — | Replacement. Validated: words plus optional `<mail@host>`, otherwise the command is left unchanged |
| `ANTHROPIC_MODEL` | — | Fallback for CO_AUTHORED_BY, same restriction |

## Tests

```
t/compress.t          # Compression
t/30-no-warnings.t   # Regression: Compress.pm warnings (transform undef, undef inputs)
t/40-compress-bin.t  # bin/mcp-run-compress: --hook (PreToolUse + PostToolUse),
                     # --install-claude incl. migration of old installations,
                     # byte cap, background bypass, fail-open
t/60-filters-doc.t   # Filters.pm against the registered filter table (drift guard)
```

**Always pair filter tests** — the assertion trap is described in `mcp-run-core`.
