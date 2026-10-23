#!/usr/bin/env bash
# One-command launcher: REA MCP server + on-demand Android emulator with a
# self-expiring timer. No clone, no compose.
#
# Run with no arguments it is what an MCP client (Claude Code) launches: it pulls
# the REA image if missing, joins a private Docker network and execs `rea mcp`
# over stdio. STDOUT IS THE MCP PROTOCOL there, so only the final `docker run`
# writes to stdout; every message goes to stderr.
#
# The Android emulator is NOT started at launch. Whoever needs it (you, or Claude
# through a Bash call) asks for it with a time limit, and it removes itself when
# the time is up:
#
#   rea-mcp android start [--ttl 30m]   start (or re-arm) the emulator for a while
#   rea-mcp android wait  [--timeout S] block until Android booted and adb sees it
#   rea-mcp android status              running? how long is left?
#   rea-mcp android stop                stop it now
#
#   rea-mcp --pull           pre-download the REA and emulator images
#   rea-mcp --install-skill  teach Claude Code these commands (~/.claude/skills)
#   rea-mcp --stop           same as `android stop`
#   rea-mcp --help
#
# --ttl takes 90s, 30m, 2h or a bare number of minutes. Running `start` again
# restarts the countdown from now ("extend"). A hard cap applies to every request.
#
# Settings (environment variables, all optional):
#   REA_IMAGE                 default ghcr.io/theol-git/rea-agent-ghidra:6.7.0-linux-amd64
#   REA_ANDROID               auto (default: on when /dev/kvm exists) | 1 | 0
#   REA_ANDROID_DEFAULT_TTL   default 30m
#   REA_ANDROID_MAX_TTL       default 4h  (upper bound for any --ttl)
#   ANDROID_EMULATOR_IMAGE    default budtmo/docker-android:emulator_13.0
#   ANDROID_EMULATOR_DEVICE   default "Samsung Galaxy S10"
#   REA_TARGETS_DIR           default ~/.rea-agent/targets (mounted read-only at /targets)
#   REA_WORK_DIR              default ~/.rea-agent/work    (mounted at /work)
#   REA_PROJECT_MOUNT         ro (default) | rw | off: the folder the client was started in
#                             is mounted at the SAME absolute path inside the container
#   REA_PROJECT_DIR           mount this folder instead of the current one
#   ANDROID_NOVNC_PORT        default 6080 (published on 127.0.0.1 only)
set -euo pipefail

REA_IMAGE="${REA_IMAGE:-ghcr.io/theol-git/rea-agent-ghidra:6.7.0-linux-amd64}"
ANDROID_IMAGE="${ANDROID_EMULATOR_IMAGE:-budtmo/docker-android:emulator_13.0}"
ANDROID_DEVICE="${ANDROID_EMULATOR_DEVICE:-Samsung Galaxy S10}"
ANDROID_CONTAINER="${ANDROID_EMULATOR_CONTAINER_NAME:-rea-android-emulator}"
ANDROID_VOLUME="${ANDROID_EMULATOR_VOLUME:-rea-android-emulator-data}"
NOVNC_PORT="${ANDROID_NOVNC_PORT:-6080}"
NETWORK="${REA_NETWORK:-rea-android}"
BASE_DIR="${REA_HOME_DIR:-$HOME/.rea-agent}"
TARGETS_DIR="${REA_TARGETS_DIR:-$BASE_DIR/targets}"
WORK_DIR="${REA_WORK_DIR:-$BASE_DIR/work}"
DEFAULT_TTL="${REA_ANDROID_DEFAULT_TTL:-30m}"
MAX_TTL="${REA_ANDROID_MAX_TTL:-4h}"
POLL="${REA_ANDROID_POLL:-15}"
EXPIRES_FILE="$BASE_DIR/android.expires"
WATCHDOG_PID="$BASE_DIR/android.watchdog.pid"
DOCKER="${DOCKER:-docker}"
ADB_TARGET="android-emulator:5555"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"

log() { printf '[rea-mcp] %s\n' "$*" >&2; }
say() { printf '%s\n' "$*"; }
d() { "$DOCKER" "$@"; }

usage() {
  cat >&2 <<'EOF'
rea-mcp: REA MCP server + on-demand Android emulator (self-expiring)

  rea-mcp                              run the MCP server (what the client launches)
  rea-mcp android start [--ttl 30m]    start or re-arm the emulator for a limited time
  rea-mcp android wait  [--timeout S]  wait until Android booted and adb sees it
  rea-mcp android status               running? time left?
  rea-mcp android stop                 stop it now
  rea-mcp --pull                       pre-download the images (large)
  rea-mcp --install-skill              install a Claude Code skill for these commands
  rea-mcp --stop                       same as `android stop`

--ttl: 90s, 30m, 2h, or a bare number of minutes. `start` again restarts the
countdown. Defaults/limits: REA_ANDROID_DEFAULT_TTL (30m), REA_ANDROID_MAX_TTL (4h).
See the header of this script for every setting.
EOF
}

android_enabled() {
  case "${REA_ANDROID:-auto}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
    *) [ -e /dev/kvm ] ;;
  esac
}

pull_if_missing() {
  if ! d image inspect "$1" >/dev/null 2>&1; then
    log "pulling $1 (first run only; large download) ..."
    d pull "$1" >&2
  fi
}

# "90s" | "30m" | "2h" | "45" (minutes)  ->  seconds on stdout
parse_ttl() {
  local v="$1" n u
  [[ "$v" =~ ^[0-9]+[smh]?$ ]] || return 1
  n="${v%[smh]}"; u="${v#"$n"}"
  case "$u" in
    s) echo $((10#$n)) ;;
    h) echo $((10#$n * 3600)) ;;
    *) echo $((10#$n * 60)) ;;
  esac
}

human() { # seconds -> "1h05m", "12m30s", "40s"
  local s=$1
  if   [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif [ "$s" -ge 60 ];   then printf '%dm%02ds' $((s / 60)) $((s % 60))
  else printf '%ds' "$s"; fi
}

emulator_running() {
  [ "$(d inspect -f '{{.State.Running}}' "$ANDROID_CONTAINER" 2>/dev/null || true)" = "true" ]
}

# Remove an emulator whose time is up. Called on every invocation, so even if the
# background watchdog died (reboot, killed) a stale emulator cannot outlive the
# next time anything runs.
reap_expired() {
  [ -f "$EXPIRES_FILE" ] || return 0
  local exp; exp="$(cat "$EXPIRES_FILE" 2>/dev/null || echo 0)"
  if [ "$(date +%s)" -ge "${exp:-0}" ]; then
    d rm -f "$ANDROID_CONTAINER" >/dev/null 2>&1 || true
    rm -f "$EXPIRES_FILE"
    log "emulator time limit reached: removed $ANDROID_CONTAINER"
  fi
}

rea_containers() { d ps --filter name=rea-mcp- --format '{{.Names}}' 2>/dev/null || true; }

# ---- hidden workers (run detached) -----------------------------------------
watchdog() {
  while :; do
    if ! emulator_running; then rm -f "$EXPIRES_FILE" "$WATCHDOG_PID"; exit 0; fi
    local exp; exp="$(cat "$EXPIRES_FILE" 2>/dev/null || echo 0)"
    if [ "$(date +%s)" -ge "${exp:-0}" ]; then
      d rm -f "$ANDROID_CONTAINER" >/dev/null 2>&1 || true
      rm -f "$EXPIRES_FILE" "$WATCHDOG_PID"
      exit 0
    fi
    sleep "$POLL"
  done
}

connect_loop() { # connect_loop CONTAINER
  local c="$1" _
  for _ in $(seq 1 120); do
    if d exec "$c" adb connect "$ADB_TARGET" 2>/dev/null | grep -qE '^(already )?connected'; then
      return 0
    fi
    sleep 5
  done
}

detach() { # detach CMD... : run fully detached from the caller's stdio/session
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid "$@" </dev/null >/dev/null 2>&1 &
  else
    nohup "$@" </dev/null >/dev/null 2>&1 &
  fi
}

require_file_self() {
  [ -f "$SELF" ] || { log "android commands need the script on disk (not piped/eval'd): see docs/CLAUDE-CODE.md, option A"; exit 1; }
}

# ---- android subcommands -----------------------------------------------------
android_start() {
  local ttl="$DEFAULT_TTL"
  while [ $# -gt 0 ]; do
    case "$1" in
      --ttl) ttl="${2:?--ttl needs a value, e.g. 30m}"; shift 2 ;;
      *) log "unknown argument: $1"; exit 2 ;;
    esac
  done
  require_file_self
  android_enabled || { log "Android disabled or /dev/kvm missing (REA_ANDROID=${REA_ANDROID:-auto})"; exit 1; }
  local secs max
  secs="$(parse_ttl "$ttl")" || { log "bad --ttl '$ttl' (use 90s, 30m, 2h or minutes)"; exit 2; }
  max="$(parse_ttl "$MAX_TTL")" || { log "bad REA_ANDROID_MAX_TTL '$MAX_TTL'"; exit 2; }
  [ "$secs" -ge 30 ] || secs=30
  if [ "$secs" -gt "$max" ]; then
    log "requested $(human "$secs") exceeds the limit; using $(human "$max") (REA_ANDROID_MAX_TTL)"
    secs="$max"
  fi

  mkdir -p "$BASE_DIR"
  if ! d image inspect "$ANDROID_IMAGE" >/dev/null 2>&1; then
    log "emulator image not downloaded yet; downloading in the background"
    detach "$DOCKER" pull "$ANDROID_IMAGE"
    say "PULLING: the emulator image ($ANDROID_IMAGE) is downloading (several GB)."
    say "Run 'rea-mcp android start --ttl $ttl' again in a few minutes."
    exit 0
  fi

  d network inspect "$NETWORK" >/dev/null 2>&1 || d network create "$NETWORK" >/dev/null
  if ! emulator_running; then
    d rm -f "$ANDROID_CONTAINER" >/dev/null 2>&1 || true
    d run -d --name "$ANDROID_CONTAINER" \
      --network "$NETWORK" --network-alias android-emulator \
      --device /dev/kvm \
      -p "127.0.0.1:$NOVNC_PORT:6080" \
      -e "EMULATOR_DEVICE=$ANDROID_DEVICE" -e WEB_VNC=true \
      -v "$ANDROID_VOLUME:/home/androidusr" \
      "$ANDROID_IMAGE" >/dev/null
  fi

  echo $(( $(date +%s) + secs )) > "$EXPIRES_FILE"
  local pid=""
  [ -f "$WATCHDOG_PID" ] && pid="$(cat "$WATCHDOG_PID" 2>/dev/null || true)"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    detach "$SELF" __watchdog
    sleep 0.2
    pgrep -f "$SELF __watchdog" 2>/dev/null | head -1 > "$WATCHDOG_PID" || true
  fi
  local c
  for c in $(rea_containers); do detach "$SELF" __connect "$c"; done

  say "STARTED: emulator runs for $(human "$secs") (until $(date -d "@$(( $(date +%s) + secs ))" +%H:%M 2>/dev/null || echo later)); viewer http://127.0.0.1:$NOVNC_PORT"
  say "First boot takes a few minutes: run 'rea-mcp android wait' before using adb."
}

android_status() {
  if emulator_running; then
    local exp left
    exp="$(cat "$EXPIRES_FILE" 2>/dev/null || echo 0)"; left=$(( exp - $(date +%s) ))
    if [ "$left" -gt 0 ]; then say "RUNNING: $(human "$left") left (viewer http://127.0.0.1:$NOVNC_PORT)"
    else say "RUNNING: time limit reached, being removed"; fi
  else
    say "STOPPED"
  fi
}

android_wait() {
  local timeout=600
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="${2:?--timeout needs seconds}"; shift 2 ;;
      *) log "unknown argument: $1"; exit 2 ;;
    esac
  done
  emulator_running || { say "STOPPED: start it first with 'rea-mcp android start --ttl 30m'"; exit 1; }
  local deadline=$(( $(date +%s) + timeout )) c boot
  while [ "$(date +%s)" -lt "$deadline" ]; do
    for c in $(rea_containers); do
      if d exec "$c" adb connect "$ADB_TARGET" 2>/dev/null | grep -qE '^(already )?connected'; then
        boot="$(d exec "$c" adb -s "$ADB_TARGET" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r[:space:]' || true)"
        if [ "$boot" = "1" ]; then
          say "READY: Android booted; container $c sees it as $ADB_TARGET"
          d exec "$c" adb devices
          exit 0
        fi
      fi
    done
    [ -n "$(rea_containers)" ] || { say "NO REA CONTAINER: the rea MCP server is not running (start Claude Code with it registered)"; exit 1; }
    emulator_running || { say "STOPPED: the emulator went away (time limit?)"; exit 1; }
    sleep 5
  done
  say "TIMEOUT: Android did not report boot within ${timeout}s; try again or check 'docker logs $ANDROID_CONTAINER'"
  exit 1
}

android_stop() {
  d rm -f "$ANDROID_CONTAINER" >/dev/null 2>&1 || true
  rm -f "$EXPIRES_FILE"
  say "STOPPED: emulator removed (its data volume '$ANDROID_VOLUME' is kept)"
}

install_skill() {
  local dir="$HOME/.claude/skills/rea-android-emulator"
  mkdir -p "$dir"
  cat > "$dir/SKILL.md" <<'EOF'
---
name: rea-android-emulator
description: Start, wait for and stop the Android emulator next to the REA MCP server, with a time limit. Use when an analysis needs a running Android device (install/run an APK, dynamic analysis, Frida, traffic capture) and `adb devices` shows nothing.
---

The emulator is NOT running by default. It costs RAM, so start it only when the
task needs a device, ask for the shortest time that is enough, and stop it when
done. It removes itself when the time is up.

Commands (run with the Bash tool; `rea-mcp` is normally ~/.local/bin/rea-mcp):

1. `rea-mcp android start --ttl 30m` starts it. `--ttl` accepts 90s, 30m, 2h; the
   hard limit is 4h by default. Pick the time the task needs plus a margin
   (15-60m is typical). If it answers PULLING, the image is still downloading:
   wait a few minutes and run it again.
2. `rea-mcp android wait` blocks until Android has booted and adb sees the device
   from the REA container (first boot takes minutes; if the Bash call times out,
   run it again).
3. Use the device through the REA MCP tools; adb is already pointed at it
   (`android-emulator:5555`). The folder Claude Code was started in is visible
   to REA at the same absolute path (read-only by default), and so is /targets, so
   `adb install <project path>/app.apk` works from inside the REA container.
4. Running low on time? `rea-mcp android start --ttl 30m` again restarts the
   countdown from now.
5. `rea-mcp android status` shows what is left; `rea-mcp android stop` ends it
   immediately. Stop it when the dynamic work is finished.

Do not leave it running between tasks, and do not ask for more time than needed.
EOF
  say "installed $dir/SKILL.md (restart Claude Code to load it)"
}

# ---- dispatch ----------------------------------------------------------------
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  __watchdog) watchdog; exit 0 ;;
  __connect) connect_loop "${2:?container}"; exit 0 ;;
  --install-skill) install_skill; exit 0 ;;
  --pull)
    d pull "$REA_IMAGE" >&2
    android_enabled && d pull "$ANDROID_IMAGE" >&2
    log "images ready"
    exit 0 ;;
  --stop) android_stop; exit 0 ;;
  android)
    shift
    reap_expired
    sub="${1:-status}"; [ $# -eq 0 ] || shift
    case "$sub" in
      start) android_start "$@" ;;
      wait) android_wait "$@" ;;
      status) android_status ;;
      stop) android_stop ;;
      *) log "unknown android command: $sub"; usage; exit 2 ;;
    esac
    exit 0 ;;
  "") ;;
  *) log "unknown argument: $1"; usage; exit 2 ;;
esac

# ---- MCP mode ------------------------------------------------------------------
if ! d info >/dev/null 2>&1; then
  log "cannot talk to Docker (is it running, and is your user allowed to use it?)"
  exit 1
fi

mkdir -p "$TARGETS_DIR" "$WORK_DIR"
reap_expired
pull_if_missing "$REA_IMAGE"

# The folder the MCP client (Claude Code) was started in, mounted at the same
# absolute path so that paths Claude passes to REA tools resolve unchanged.
project_args=()
setup_project_mount() {
  local mode="${REA_PROJECT_MOUNT:-ro}" explicit="${REA_PROJECT_DIR:-}" dir home_real
  case "$mode" in
    off|0|no|false) return 0 ;;
    ro|rw) ;;
    *) log "REA_PROJECT_MOUNT must be ro, rw or off (got '$mode'); using ro"; mode=ro ;;
  esac
  dir="$(cd "${explicit:-$PWD}" 2>/dev/null && pwd -P)" || {
    log "project folder '${explicit:-$PWD}' not found; not mounting it"; return 0; }
  case "$dir" in
    *[,:]*|*$'\n'*) log "project path contains ',' ':' or a newline; not mounting it: $dir"; return 0 ;;
    /|/bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/lib|/lib/*|/lib32|/lib32/*|/lib64|/lib64/*|\
    /opt|/opt/*|/proc|/proc/*|/root|/root/*|/run|/run/*|/sbin|/sbin/*|/sys|/sys/*|/usr|/usr/*|\
    /var|/var/*|/work|/work/*|/targets|/targets/*)
      log "refusing to mount system or reserved folder: $dir"; return 0 ;;
  esac
  if [ -z "$explicit" ]; then
    # Started in $HOME or above it: mounting that would hand ~/.ssh, ~/.claude and
    # every other secret to a container that analyses untrusted binaries.
    home_real="$(cd "$HOME" 2>/dev/null && pwd -P || echo "$HOME")"
    if [ "$dir" = "$home_real" ] || [[ "$home_real/" == "$dir"/* ]]; then
      log "started in your home folder or above ($dir): not mounting it. Start Claude Code inside a project folder, or set REA_PROJECT_DIR."
      return 0
    fi
  fi
  if [ "$mode" = "ro" ]; then project_args=(-v "$dir:$dir:ro"); else project_args=(-v "$dir:$dir"); fi
  log "project folder available to REA at the same path ($mode): $dir"
}
setup_project_mount

name="rea-mcp-$$"
run_args=(run --rm -i --init --shm-size=1g
  --user "$(id -u):$(id -g)"
  -e REA_ENTRYPOINT_DOCTOR=0
  -v "$TARGETS_DIR:/targets:ro"
  -v "$WORK_DIR:/work"
  ${project_args[@]+"${project_args[@]}"}
  --name "$name")

if android_enabled; then
  # Join the private network so `android start` can reach the emulator later.
  d network inspect "$NETWORK" >/dev/null 2>&1 || d network create "$NETWORK" >/dev/null
  run_args+=(--network "$NETWORK")
  # An emulator that is already up (started earlier, still within its time).
  if emulator_running && [ -f "$SELF" ]; then detach "$SELF" __connect "$name"; fi
else
  log "Android off (no /dev/kvm, or REA_ANDROID=0): static analysis only"
fi

exec "$DOCKER" "${run_args[@]}" "$REA_IMAGE" rea mcp
