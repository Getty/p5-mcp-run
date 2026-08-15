# MCP-Run

A stdio MCP server (`mcp-run-bash`) that exposes a `run` tool: it executes
shell commands via `bash -c` and returns exit code, stdout, and stderr —
optionally passed through 30+ command-specific filters (`ls`, `git`, `make`,
`cargo`, `cpanm`, `kubectl`, `terraform`, …) so the LLM sees the essence
instead of 900 lines of noise.

Plug it into Claude Desktop, `.mcp.json`, or any MCP client.

As a **bonus**, the same compression pipeline ships as a standalone Claude
Code hook (`mcp-run-compress`) that filters the output of Claude Code's
built-in Bash tool. It compresses in `PostToolUse`, so the command itself is
never rewritten. The hook is fully usable on its own via Docker — no Perl
needed on the host.

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

## Bonus: Claude Code hook (mcp-run-compress)

Same compression pipeline, installed as a Claude Code hook so it filters
the output of the built-in `Bash` tool.

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
`~/.claude/skills/`. Prefix any command with `no-compress ` to get raw
output for that one call.

### Two hooks, and why

`--install-claude` registers the same command on two events:

- **PostToolUse** does the compression. It receives the command's output
  and replaces it with the filtered version. The command itself is never
  touched.
- **PreToolUse** does the two things that have to happen *before* the
  command runs: the Co-Authored-By trailer on `git commit`, and turning
  `no-compress <cmd>` into `<cmd>` plus a trailing marker comment. The
  marker is needed because PostToolUse only ever sees the rewritten
  command — strip the prefix without leaving a trace and the compressing
  hook can no longer tell that you asked it to stay out.

Earlier versions compressed by rewriting the Bash command into
`mcp-run-compress --b64 <base64>`. That is gone, and with it a hardcoded
1800-second timeout, the base64 round-trip, and — in Docker mode — a
host-side snippet that captured output into temp files and lost all of it
whenever `docker run` failed. Upgrading is just `--install-claude` again;
it adds the missing hook and replaces entries that name the removed flags.

### Three things it does not do

- **A command that exits non-zero is not compressed.** Claude Code raises
  `PostToolUseFailure` there instead, and that event ignores any
  replacement output. This is the one place the old rewrite did better,
  and it is the noisiest output there is — a failing build. There is no
  known way around it from a hook.
- **Background commands** (`run_in_background`) have produced no output
  yet when the hook runs, so they pass through untouched.
- **Two PostToolUse hooks do not chain.** Each one is handed the original
  output, and whichever answers last wins — silently. Another hook of
  yours that replaces Bash output will simply switch compression off.

### Large output

Claude Code caps the output a hook is handed at 30 KB and writes the full
text to a file alongside it. The hook reads that file, so compression sees
everything, and the compressed result names the file's path in case you
want the original.

The replacement is subject to the same cap, which is the one number worth
knowing: compress 100 KB down to 40 KB and the harness will file *that*
away too and show the model a 2 KB preview — worse than not compressing at
all. `MCP_RUN_COMPRESS_MAX_BYTES` (default 29000) keeps the result under
the line, trimming the middle with a visible marker rather than quietly.

In Docker mode the hook cannot read the file: it lives under `~/.claude`,
and the only mountable directory above it holds every project's
transcripts. There it compresses the 30 KB it was given and names the path
without reading it.

### Which install mode gets written

`bin/mcp-run-compress` reads `MCP_RUN_COMPRESS_INSTALL_MODE`:

- unset / `native` → hook command is `mcp-run-compress --hook`
- `docker` → hook command is `docker run --rm -i --network none … --hook`

Both run the same code — JSON in on stdin, JSON out. The mode only picks
the command string written into `settings.json`. The Docker image bakes
`ENV MCP_RUN_COMPRESS_INSTALL_MODE=docker`, so any `--install-claude` run
*inside* the container writes the Docker-mode hook automatically; a native
`cpanm` install leaves the var unset. No detection heuristic; the image
marks itself.

The image also bakes `MCP_RUN_COMPRESS_IMAGE=raudssus/mcp-run-compress:<version>`,
so the hook is pinned to the exact version that installed it. Upgrades are
explicit: `docker pull … && … --install-claude` again.

## Environment variables

| Var                              | Purpose                                                    |
|----------------------------------|------------------------------------------------------------|
| `MCP_RUN_ALLOWED_COMMANDS`       | Comma-separated whitelist for `mcp-run-bash`               |
| `MCP_RUN_WORKING_DIRECTORY`      | Default cwd for `mcp-run-bash`                             |
| `MCP_RUN_TIMEOUT`                | Default timeout (seconds) for `mcp-run-bash`. Whole seconds, 1 to 2147483647. Anything else aborts the start with a message naming the value, rather than quietly substituting a default the user never asked for |
| `MCP_RUN_COMPRESS`               | `0`/`false`/`no`/`off` disables compression in `mcp-run-bash` (default: enabled). `1`/`true`/`yes`/`on` forces it on. Case-insensitive. Overridable per-call via the tool's `compress` argument. |
| `MCP_RUN_TOOL_NAME`              | Registered MCP tool name (default `run`)                   |
| `MCP_RUN_COMPRESS_INSTALL_MODE`  | `native` (default) or `docker`. The shipped Docker image bakes `docker`; native Perl installs leave it unset. Overrides both the hook command `mcp-run-compress --install-claude` writes and the rewrite `--hook` emits. |
| `MCP_RUN_COMPRESS_IMAGE`         | Image ref for docker-mode hook. Pinned to `:<version>` in image |
| `MCP_RUN_COMPRESS_MAX_BYTES`     | Cap on the replaced output, default 29000. Above the harness' own ~30 KB limit it files the replacement away and shows a 2 KB preview instead, so the cap trims the middle with a visible marker first. Only applies when a raw file exists to point at |
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
