# MCP-Run

A stdio MCP server (`mcp-run-bash`) that exposes a `run` tool: it executes
shell commands via `bash -c` and returns exit code, stdout, and stderr —
optionally passed through 30+ command-specific filters (`ls`, `git`, `make`,
`cargo`, `cpanm`, `kubectl`, `terraform`, …) so the LLM sees the essence
instead of 900 lines of noise.

Plug it into Claude Desktop, `.mcp.json`, or any MCP client.

As a **bonus**, the same compression pipeline ships as a standalone Claude
Code `PreToolUse` hook (`mcp-run-compress`) that filters output of Claude
Code's built-in Bash tool. The hook is fully usable on its own via Docker —
no Perl needed on the host.

## Install (Perl)

```bash
cpanm MCP::Run
```

Gives you `mcp-run-bash` (the MCP server) and `mcp-run-compress` (the hook
+ installer).

## Use as MCP server (mcp-run-bash)

```perl
use MCP::Run::Bash;

my $server = MCP::Run::Bash->new(
    allowed_commands  => ['ls', 'cat', 'grep', 'find'],
    working_directory => '/var/data',
    timeout           => 60,
);
$server->to_stdio;
```

Or run the binary directly — it reads config from environment variables and
speaks MCP over stdio:

```bash
mcp-run-bash
```

Attributes: `allowed_commands` (whitelist, default: all), `working_directory`
(default: cwd), `timeout` (default: 30s), `compress` (default: off in the
module, on in `bin/mcp-run-bash`), `tool_name` (default: `run`),
`tool_description`.

Tool input schema:

```json
{
  "command": "ls -la",
  "working_directory": "/tmp",
  "timeout": 10,
  "compress": false
}
```

When `compress` is enabled, the original command is fed into the filter
pipeline so command-specific rules (e.g. `git status`, `make`, `kubectl`)
match. See `MCP::Run::Compress::Filters` for the preset catalog.

Ahead of the command-specific rules the pipeline normalises two things
unconditionally: ANSI escapes are stripped, and carriage-return
overwrites are collapsed to the last state on each line. The second one
matters more than it sounds. A progress bar from cargo, npm, pip, docker
or wget contains no newlines at all — it is thousands of states written
over each other with `\r` — so to a line-based filter it is a *single*
line, which `max_lines` cannot shorten. Collapsing it to what actually
stayed on the screen turns a 224 KB bar into a couple of dozen bytes
without hiding anything the user would have seen.

## Bonus: PreToolUse hook for Claude Code (mcp-run-compress)

Same compression pipeline, but installed as a Claude Code hook so it
filters output of the built-in `Bash` tool.

### With Perl already installed

```bash
cpanm MCP::Run
mcp-run-compress --install-claude
```

### Without Perl, via Docker

```bash
docker run --rm \
    -v "$HOME:$HOME" -e HOME="$HOME" \
    raudssus/mcp-run-compress --install-claude
```

Patches `~/.claude/settings.json` and drops a bypass-skill into
`~/.claude/skills/`. Host only needs `bash`, `mktemp`, `base64`, `docker`.

Prefix any command with `no-compress ` to bypass the filter for one call.

### How the Docker install works

The hook needs two things from two different worlds:

- **Run the real Bash command** (`git status`, `dzil test`, …) with the
  host's cwd, env, and binaries.
- **Filter the output** — pure text processing, no host access needed.

So the hook splits them. The rewritten command runs the original
command on the host, captures stdout/stderr into temp files, then
mounts those into a container that compresses them:

```
{ __o=$(mktemp) && __e=$(mktemp) || exit 1
  trap 'rm -f "$__o" "$__e"' EXIT
  bash -c "$(printf %s '<B64>' | base64 -d)" >"$__o" 2>"$__e"   # host
  __ec=$?
  docker run --rm -v "$__o:/in/stdout:ro" -v "$__e:/in/stderr:ro" \
       raudssus/mcp-run-compress:<pinned> \
       --filter-files --cmd-b64 '<B64>' /in/stdout /in/stderr \
    || { echo "mcp-run-compress: compression unavailable, raw output" >&2
         cat "$__o"; cat "$__e" >&2; }                          # fallback
  exit $__ec
}
```

Host bash runs on the host. Docker runs only the compression. No chroot,
no shared toolchain, no Perl on the host.

The `||` branch matters more than it looks. Without it, anything that
stops `docker run` — daemon not started, image not pulled yet, registry
rate limit, user not in the `docker` group — takes the command's entire
output with it: stdout and stderr sit in the temp files, nothing prints
them, and the `trap` deletes them. The exit code still comes through
correctly, so a failed compression is indistinguishable from a command
that legitimately produced no output. With the fallback the mode
degrades to *uncompressed* instead of *silent*.

### Which install mode gets written

`bin/mcp-run-compress` reads `MCP_RUN_COMPRESS_INSTALL_MODE`:

- unset / `native` → hook is `mcp-run-compress --hook`, rewrites to
  `mcp-run-compress --b64 <…>` (in-process).
- `docker` → hook is `docker run … --hook`, rewrites to the host-side
  pipe-through snippet above.

The Docker image bakes `ENV MCP_RUN_COMPRESS_INSTALL_MODE=docker`, so
any `--install-claude` run *inside* the container writes the Docker-mode
hook automatically. A native `cpanm` install on the host leaves the var
unset. No detection heuristic; the image marks itself.

The image also bakes `MCP_RUN_COMPRESS_IMAGE=raudssus/mcp-run-compress:<version>`,
so the hook is pinned to the exact version that installed it. Upgrades
are explicit: `docker pull … && … --install-claude` again.

## Environment variables

| Var                              | Purpose                                                    |
|----------------------------------|------------------------------------------------------------|
| `MCP_RUN_ALLOWED_COMMANDS`       | Comma-separated whitelist for `mcp-run-bash`               |
| `MCP_RUN_WORKING_DIRECTORY`      | Default cwd for `mcp-run-bash`                             |
| `MCP_RUN_TIMEOUT`                | Default timeout (seconds) for `mcp-run-bash`               |
| `MCP_RUN_COMPRESS`               | `0`/`false`/`no`/`off` disables compression in `mcp-run-bash` (default: enabled). `1`/`true`/`yes`/`on` forces it on. Case-insensitive. Overridable per-call via the tool's `compress` argument. |
| `MCP_RUN_TOOL_NAME`              | Registered MCP tool name (default `run`)                   |
| `MCP_RUN_COMPRESS_INSTALL_MODE`  | `native` (default) or `docker`. The shipped Docker image bakes `docker`; native Perl installs leave it unset. Overrides both the hook command `mcp-run-compress --install-claude` writes and the rewrite `--hook` emits. |
| `MCP_RUN_COMPRESS_IMAGE`         | Image ref for docker-mode hook. Pinned to `:<version>` in image |
| `MCP_RUN_COMPRESS_NO_CO_AUTHORED`| Set to any value to disable Co-Authored-By replacement      |
| `CO_AUTHORED_BY`                 | Replacement value for Co-Authored-By in git commits. Must be a plain trailer value — words plus optional `<mail@host>`; anything else is rejected and no trailer is written |
| `ANTHROPIC_MODEL`                | Fallback for CO_AUTHORED_BY if not set. Same restriction    |

## Co-Authored-By replacement for git commits

When `mcp-run-compress` detects a `git commit` command, it can automatically add
or replace the `Co-Authored-By` line in the commit message. This is useful when
using Claude Code with different AI models to track which model was used.

**How it works:**

- If `CO_AUTHORED_BY` or `ANTHROPIC_MODEL` is set and the commit message
  already contains a `Co-Authored-By` line, it will be replaced with the value
  of that env var.
- If no `Co-Authored-By` line exists, it will be appended to the commit message.
- To disable this feature temporarily, set `MCP_RUN_COMPRESS_NO_CO_AUTHORED=1`.

**The value is validated, not escaped.** It has to look like a trailer value:
one or more words made of letters, digits and `. _ - + : /`, separated by
single spaces, optionally followed by `<mail@host>`. `claude-opus-5`,
`MiniMax-M2.7`, `Claude Opus 5 <noreply@anthropic.com>` and Bedrock-style ids
like `us.anthropic.claude-opus-4-20250514-v1:0` all pass.

Anything else — a quote, `$`, a backtick, a backslash, a newline — is
rejected, and the command is then left completely untouched: no trailer.
That is deliberate. The trailer is spliced *inside* the double-quoted `-m`
argument, so a value carrying a quote would end the string and turn the rest
into extra shell commands, and `$(…)` inside those quotes would simply run.
Rejecting is also better than escaping: a silently mangled trailer sits in a
real commit where nobody notices it, while a missing one is visible.

**Example:**

```bash
# Set the model identifier
export CO_AUTHORED_BY="MiniMax-M2.7"

# git commit will now automatically include:
# Co-Authored-By: MiniMax-M2.7

# To temporarily disable:
MCP_RUN_COMPRESS_NO_CO_AUTHORED=1 git commit -m "WIP"
```

## Build the Docker image locally

```bash
dzil build
VERSION=$(perl -Ilib -MMCP::Run -E 'say $MCP::Run::VERSION')
docker build \
  --build-arg MCP_RUN_VERSION=$VERSION \
  --target compress \
  -t raudssus/mcp-run-compress:$VERSION \
  -t raudssus/mcp-run-compress:latest \
  MCP-Run-$VERSION
```

## Release (maintainer)

`dzil release` uploads to CPAN. The `[@Author::GETTY]` bundle then publishes
the matching GitHub release (with the CPAN tarball attached) and builds and
pushes the Docker image `raudssus/mcp-run-compress` to Docker Hub, tagged
`:latest`, `:0` (major), and `:<VERSION>` (the bundle's `latest %V %v`).

```bash
dzil release
```

Needs `~/.github-identity` (for the GitHub release) and `docker login`.

## License

Copyright (c) 2026 Torsten Raudssus. Same terms as Perl 5 itself.
