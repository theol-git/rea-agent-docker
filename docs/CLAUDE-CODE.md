# Using rea-agent with Claude Code (CLI)

Claude Code spawns REA's MCP server by running `docker exec -i <container> rea mcp`.
The analysis tools therefore run inside the container; Claude Code itself stays on
your host. Nothing to install on the host except Docker and the `claude` CLI.

## Quickest path: one command, emulator included, no clone

[`scripts/rea-mcp.sh`](../scripts/rea-mcp.sh) is a launcher Claude Code can run
directly. On each start it pulls the images if missing, starts the Android
emulator when the host has `/dev/kvm`, joins both on a private Docker network,
`adb connect`s the REA container to the emulator, and serves REA over MCP. You
need Docker and nothing else (no clone, no compose, no `make`).

```bash
# Option A (recommended): download the launcher once, pin what you run
mkdir -p ~/.local/bin ~/.rea-agent/targets
curl -fsSL https://raw.githubusercontent.com/theol-git/rea-agent-docker/main/scripts/rea-mcp.sh \
  -o ~/.local/bin/rea-mcp && chmod +x ~/.local/bin/rea-mcp
rea-mcp --pull                                   # one-time download of both images (~8 GB + emulator)
claude mcp add rea --scope user -- ~/.local/bin/rea-mcp

# Option B: nothing stored locally; the script is fetched at every launch
claude mcp add rea --scope user -- bash -c \
  'eval "$(curl -fsSL https://raw.githubusercontent.com/theol-git/rea-agent-docker/main/scripts/rea-mcp.sh)"'
```

Option B executes whatever is on `main` each time you start Claude Code, and
needs network. Replace `main` with a commit SHA to pin it. The first launch also
has to download the images, which takes longer than Claude Code's default MCP
startup timeout; either run `rea-mcp --pull` first (Option A) or start once with
`MCP_TIMEOUT=1800000 claude` (Option B).

Then drop files in `~/.rea-agent/targets/` and ask for them as `/targets/<file>`.
Results and Ghidra's workspace go to `~/.rea-agent/work/`.

How it behaves:

- **The emulator stays up between sessions** so Android only boots once. Watch it
  at <http://127.0.0.1:6080>. Stop it with `rea-mcp --stop` (its data volume is
  kept). It uses RAM until you do.
- **No `/dev/kvm`:** the emulator is skipped and REA runs for static analysis only
  (a note goes to stderr). Force it on or off with `REA_ANDROID=1` / `REA_ANDROID=0`.
- **Every session is a fresh REA container** (`--rm`); only `~/.rea-agent/work` persists.
- **Settings** (images, Android version, device, folders, viewer port) are
  environment variables, listed by `rea-mcp --help`. Set them when registering:
  `claude mcp add rea --scope user -e REA_ANDROID=1 -- ~/.local/bin/rea-mcp`.
- Logs go to stderr because stdout carries the MCP protocol. adb is connected in
  the background shortly after each launch (the emulator can still be booting);
  to check by hand: `docker ps --filter name=rea-mcp` for the container name, then
  `docker exec <name> adb devices`.

Sections 1–6 below are the compose-based setup, for when you want to build the
image yourself or run the stack long-lived.

## 1. Start the container

```bash
git clone https://github.com/theol-git/rea-agent-docker && cd rea-agent-docker
cp .env.example .env                         # set REA_UID / REA_GID to `id -u` / `id -g`
docker compose pull                          # or: make build-ghidra
docker compose --profile ghidra up -d rea-ghidra
docker compose exec rea-ghidra rea doctor --json     # must report healthy
```

Pick the engine you use; only the container name changes below:

| Engine | Start | Container name |
| --- | --- | --- |
| Ghidra (recommended default, also fine for APK/Android work) | `make up-ghidra` | `rea-agent-ghidra` |
| Ghidra + Hopper | `docker compose up -d` | `rea-agent` |
| Hopper | `make up-hopper` | `rea-agent-hopper` |
| IDA (bring your own) | `make up-ida` | `rea-agent-ida` |

Optional — Android emulator for dynamic work on APKs
([ANDROID-EMULATOR.md](ANDROID-EMULATOR.md)):

```bash
make android-up
make android-connect ENGINE=ghidra
```

## 2. Register REA with Claude Code

```bash
claude mcp add rea --scope user -- docker exec -i rea-agent-ghidra rea mcp
```

Everything after `--` is the command Claude Code runs. Scopes:

| `--scope` | Stored in | Visible to |
| --- | --- | --- |
| `local` (default) | your user config, keyed to the current project | only you, only this project |
| `project` | `.mcp.json` in the project root | everyone using the repo (Claude Code asks each user to approve it) |
| `user` | your user config | only you, every project |

`--scope user` is the usual choice for a personal analysis box. The equivalent
`.mcp.json`, if you prefer a file (project scope):

```json
{
  "mcpServers": {
    "rea": {
      "command": "docker",
      "args": ["exec", "-i", "rea-agent-ghidra", "rea", "mcp"]
    }
  }
}
```

Check it:

```bash
claude mcp list          # rea should show as connected
claude mcp get rea
```

Inside a session, `/mcp` shows the same and lets you reconnect.

Remove it with `claude mcp remove rea`.

## 3. Raise the timeouts

Ghidra imports and auto-analyses a binary on the first query, which can take far
longer than Claude Code's defaults. The README/Hermes block uses 1800 s; the
Claude Code equivalent is two environment variables, in **milliseconds**:

```bash
export MCP_TIMEOUT=120000          # server startup
export MCP_TOOL_TIMEOUT=1800000    # a single tool call (30 min)
claude
```

Put them in your shell profile, or in Claude Code's settings under `env`, to make
them permanent. For very large targets also raise `REA_GHIDRA_STARTUP_TIMEOUT_MS`
in `config/rea.env` ([IMAGES.md](IMAGES.md)).

Large results can exceed Claude Code's MCP output limit; if you see truncation
warnings, raise `MAX_MCP_OUTPUT_TOKENS` or ask for narrower queries.

## 4. Install REA's workflow skill (recommended)

Use the copy bundled in the image: it matches the `rea-agents` version you run
(`npx skills add morluto/rea` installs repository `main` and may not).

```bash
mkdir -p ~/.claude/skills
docker cp rea-agent-ghidra:/usr/local/lib/node_modules/rea-agents/skills/reverse-engineer-anything \
  ~/.claude/skills/
ls ~/.claude/skills/reverse-engineer-anything/SKILL.md      # must exist
```

For a single project, copy it to `<project>/.claude/skills/` instead. Restart
`claude` so it is picked up.

## 5. Give it something to analyse

The container sees `./targets` read-only as `/targets` and writes to `./work`.
Claude Code runs on the host, so put files there and refer to the container path:

```bash
cp app.apk suspicious.elf targets/
claude
```

> Analyse `/targets/suspicious.elf` with REA: find where it checks the licence and
> decompile that function.

For an APK with the emulator running:

> Install `/targets/app.apk` on the emulator, launch it, and list the hosts it contacts.

## 6. Approving tool calls

REA tools appear to Claude Code as `mcp__rea__<tool>` and ask for approval like
any other tool. To pre-approve all of them for a project, add to
`.claude/settings.json`:

```json
{ "permissions": { "allow": ["mcp__rea"] } }
```

or run `claude --allowedTools "mcp__rea"`. Review that choice first: REA can run
processes, captures and (with the emulator) install apps — all inside containers,
but on whatever you put in `targets/`. Never analyse untrusted samples with
network access you are not prepared to expose.

## Optional: Streamable HTTP instead of `docker exec`

```bash
make http-up ENGINE=ghidra                   # publishes http://127.0.0.1:8811/mcp
claude mcp add --transport http rea --scope user http://127.0.0.1:8811/mcp
```

The stdio form above is the documented, verified path. The HTTP bridge is useful
when Claude Code cannot reach the Docker socket (remote host, another container).

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `claude mcp list` shows `rea` failed | `docker ps` — is `rea-agent-ghidra` running? Test the exact command by hand: `docker exec -i rea-agent-ghidra rea mcp` |
| `permission denied` on the Docker socket | Your user must be in the `docker` group (re-login) |
| Tool call times out during analysis | Raise `MCP_TOOL_TIMEOUT` (section 3) and `REA_GHIDRA_STARTUP_TIMEOUT_MS` |
| Wrong container name | Use the name from the table; if you changed it in `.env`, use that |
| Skill not found | `ls ~/.claude/skills/reverse-engineer-anything/SKILL.md`, then restart `claude` |
| `adb devices` empty | `make android-connect` again (see [ANDROID-EMULATOR.md](ANDROID-EMULATOR.md)) |
| Only one engine at a time | Don't run two engine containers against the same `./work` |
