# MCP-Run

Claude Code `PreToolUse` hook that compresses `Bash` tool output with 30+
command-specific filters (`ls`, `git`, `make`, `cargo`, `cpanm`, `kubectl`,
`terraform`, …) so the LLM sees the essence — not 900 lines of noise. Prefix
a command with `no-compress ` to bypass the filter for one call.

Also ships `MCP::Run::Bash`, a stdio MCP server with the same compression,
for Claude Desktop and `.mcp.json`.

## Install with Docker (no Perl required)

```bash
docker run --rm \
    -v "$HOME:$HOME" -e HOME="$HOME" \
    raudssus/mcp-run-compress --install-claude
```

That's it. Patches `~/.claude/settings.json` and drops a bypass-skill into
`~/.claude/skills/`. Host only needs `bash`, `mktemp`, `base64`, `docker`.

## Install with Perl

```bash
cpanm MCP::Run
mcp-run-compress --install-claude
```

Same result, no Docker startup per Bash call.

## How the Docker install works

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
       --filter-files --cmd-b64 '<B64>' /in/stdout /in/stderr   # filter
  exit $__ec
}
```

Host bash runs on the host. Docker runs only the compression. No chroot,
no shared toolchain, no Perl on the host.

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

## Library use (MCP::Run::Bash)

```perl
use MCP::Run::Bash;

my $server = MCP::Run::Bash->new(
    allowed_commands  => ['ls', 'cat', 'grep', 'find'],
    working_directory => '/var/data',
    timeout           => 60,
);
$server->to_stdio;
```

Attributes: `allowed_commands` (whitelist, default: all), `working_directory`
(default: cwd), `timeout` (default: 30s), `tool_name` (default: `run`),
`tool_description`.

Tool input schema:

```json
{ "command": "ls -la", "working_directory": "/tmp", "timeout": 10 }
```

See `MCP::Run::Compress::Filters` for the preset filter catalog.

## Environment variables

| Var                              | Purpose                                                    |
|----------------------------------|------------------------------------------------------------|
| `MCP_RUN_ALLOWED_COMMANDS`       | Comma-separated whitelist for `mcp-run-bash`               |
| `MCP_RUN_WORKING_DIRECTORY`      | Default cwd for `mcp-run-bash`                             |
| `MCP_RUN_TIMEOUT`                | Default timeout (seconds) for `mcp-run-bash`               |
| `MCP_RUN_COMPRESS`               | `0` disables compression in `mcp-run-bash`                 |
| `MCP_RUN_TOOL_NAME`              | Registered MCP tool name (default `run`)                   |
| `MCP_RUN_COMPRESS_INSTALL_MODE`  | `native` (default) or `docker`. Baked to `docker` in image |
| `MCP_RUN_COMPRESS_IMAGE`         | Image ref for docker-mode hook. Pinned to `:<version>` in image |
| `MCP_RUN_COMPRESS_NO_CO_AUTHORED`| Set to any value to disable Co-Authored-By replacement      |
| `CO_AUTHORED_BY`                 | Replacement value for Co-Authored-By in git commits        |
| `ANTHROPIC_MODEL`                | Fallback for CO_AUTHORED_BY if not set                     |

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
  --target runtime \
  -t raudssus/mcp-run-compress:$VERSION \
  -t raudssus/mcp-run-compress:latest \
  MCP-Run-$VERSION
```

## Release (maintainer)

`dzil release` uploads to CPAN, then `maint/release-after.pl` creates the
matching GitHub release, `docker build`s, and `docker push`es both
`:VERSION` and `:latest` to Docker Hub.

```bash
dzil release
# extra build flags:
MCP_RUN_DOCKER_BUILD_ARGS='--platform linux/amd64,linux/arm64' dzil release
```

Needs `docker login` and `gh auth login`.

## License

Copyright (c) 2026 Torsten Raudssus. Same terms as Perl 5 itself.
