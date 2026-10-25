# MCP-Run House Rules

The shared house rules come from skilletor — bundle `getty-cpan-dist@getty`: engineering
discipline, the delegation lock, the publish gate, karr coordination, CPAN release. They load
as `.claude/rules/.local.*.md`; if they are missing, run `skilletor sync` and publish nothing
until they load. This file adds what is true only here, and wins where it differs.

## What this repo is

MCP server with a command execution tool — two products (`MCP::Run::Bash` and the compression
hook) sharing one codebase but shipping independently. Read first: exports, immediate callers
and the `MCP::Run`/`MCP::Run::Bash`/`MCP::Run::Compress` triad — "looks orthogonal" is
dangerous across two products sharing one codebase.

## Agent team

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `mcp-run-worker` (default) |
| Commits, `Changes`, card → done, pre-release audit | `mcp-run-release-manager` |
| Read-only research, audit, gap analysis | `mcp-run-worker` ("read-only, change nothing") |

Behavior-relevant = runtime behavior, the MCP tool wire-format contract, IPC::Open3
execution, the `allowed_commands` / `validator` gates, timeout handling, the compression
pipeline, the hook (PostToolUse compression + PreToolUse Co-Authored-By), tests, performance.
Pure prose docs and `Changes` notes are not.

## Release

`dzil release` also builds and pushes the Docker image (`raudssus/mcp-run-compress`): a Docker
Hub push falls under the publish gate like the CPAN upload.

## Deviations from the house rules

Single distribution — one board, no cross-repo handoff. The public tracker includes CPAN RT
besides GitHub issues.

## Hazards and specifics — reference, don't restate

Two products share one codebase but ship independently; the sharp edges that follow live in
skill `mcp-run-core`, briefed into every `mcp-run-*` agent — the `allowed_commands`
non-sandbox, the `working_directory` as `cd '$dir' && ...`, the two intentional compression
defaults, PostToolUse compression, the hook's no-permission rule, `format_result` threading
`$command`. The orchestrating agent delegates behaviour-relevant work to them.

## Perl specifics — reference, don't restate

Module loading, Moo patterns, cpanfile pinning: skill `getty-perl-core`. `[@Author::GETTY]`
bundle (bumps `$VERSION` and tags on release), POD, `{{$NEXT}}`: skill
`getty-perl-release-author-getty`. dist.ini mechanics: `perl-release-dist-ini`. MCP server
setup: `perl-mcp`.
