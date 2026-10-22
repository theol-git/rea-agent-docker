#!/usr/bin/env bash
# One-command launcher: REA MCP server + Android emulator, no clone, no compose.
#
# Meant to be what an MCP client (Claude Code) runs. It
#   1. pulls the REA image if it is missing,
#   2. starts the Android emulator sidecar if /dev/kvm exists (and leaves it
#      running between sessions, so Android only boots once),
#   3. joins both on a private Docker network (the emulator is `android-emulator`),
#   4. adb-connects the REA container to the emulator in the background,
#   5. execs `rea mcp` over stdio.
#
# STDOUT IS THE MCP PROTOCOL. Nothing here may print to stdout except the final
# `docker run`; every message below goes to stderr.
#
#   scripts/rea-mcp.sh            run the MCP server (what the client launches)
#   scripts/rea-mcp.sh --pull     pre-download both images (avoids a client timeout)
#   scripts/rea-mcp.sh --stop     stop and remove the emulator and its network
#   scripts/rea-mcp.sh --help
#
# Settings (environment variables, all optional):
#   REA_IMAGE            default ghcr.io/alexmi256/rea-agent-ghidra:6.7.0-linux-amd64
#   REA_ANDROID          auto (default: on when /dev/kvm exists) | 1 | 0
#   ANDROID_EMULATOR_IMAGE   default budtmo/docker-android:emulator_13.0
#   ANDROID_EMULATOR_DEVICE  default "Samsung Galaxy S10"
#   REA_TARGETS_DIR      default ~/rea-targets  (mounted read-only at /targets)
#   REA_WORK_DIR         default ~/rea-work     (mounted at /work)
#   ANDROID_NOVNC_PORT   default 6080 (published on 127.0.0.1 only)
set -euo pipefail

REA_IMAGE="${REA_IMAGE:-ghcr.io/alexmi256/rea-agent-ghidra:6.7.0-linux-amd64}"
ANDROID_IMAGE="${ANDROID_EMULATOR_IMAGE:-budtmo/docker-android:emulator_13.0}"
ANDROID_DEVICE="${ANDROID_EMULATOR_DEVICE:-Samsung Galaxy S10}"
ANDROID_CONTAINER="${ANDROID_EMULATOR_CONTAINER_NAME:-rea-android-emulator}"
ANDROID_VOLUME="${ANDROID_EMULATOR_VOLUME:-rea-android-emulator-data}"
NOVNC_PORT="${ANDROID_NOVNC_PORT:-6080}"
NETWORK="${REA_NETWORK:-rea-android}"
TARGETS_DIR="${REA_TARGETS_DIR:-$HOME/rea-targets}"
WORK_DIR="${REA_WORK_DIR:-$HOME/rea-work}"
DOCKER="${DOCKER:-docker}"
ADB_TARGET="android-emulator:5555"

log() { printf '[rea-mcp] %s\n' "$*" >&2; }
usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' >&2; }
d() { "$DOCKER" "$@"; }

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

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --stop)
    d rm -f "$ANDROID_CONTAINER" >&2 2>/dev/null || true
    d network rm "$NETWORK" >&2 2>/dev/null || true
    log "emulator stopped (its data volume '$ANDROID_VOLUME' is kept)"
    exit 0 ;;
  --pull)
    d pull "$REA_IMAGE" >&2
    android_enabled && d pull "$ANDROID_IMAGE" >&2
    log "images ready"
    exit 0 ;;
  "") ;;
  *) log "unknown argument: $1"; usage; exit 2 ;;
esac

if ! d info >/dev/null 2>&1; then
  log "cannot talk to Docker (is it running, and is your user allowed to use it?)"
  exit 1
fi

mkdir -p "$TARGETS_DIR" "$WORK_DIR"
pull_if_missing "$REA_IMAGE"

run_args=(run --rm -i --init --shm-size=1g
  --user "$(id -u):$(id -g)"
  -e REA_ENTRYPOINT_DOCTOR=0
  -v "$TARGETS_DIR:/targets:ro"
  -v "$WORK_DIR:/work")

name="rea-mcp-$$"
run_args+=(--name "$name")

if android_enabled; then
  pull_if_missing "$ANDROID_IMAGE"
  d network inspect "$NETWORK" >/dev/null 2>&1 || d network create "$NETWORK" >/dev/null
  state="$(d inspect -f '{{.State.Running}}' "$ANDROID_CONTAINER" 2>/dev/null || echo missing)"
  case "$state" in
    true) ;;
    false) log "starting existing emulator container"; d start "$ANDROID_CONTAINER" >/dev/null ;;
    *)
      log "creating the Android emulator (first boot takes minutes; viewer: http://127.0.0.1:$NOVNC_PORT)"
      d run -d --name "$ANDROID_CONTAINER" \
        --network "$NETWORK" --network-alias android-emulator \
        --device /dev/kvm \
        -p "127.0.0.1:$NOVNC_PORT:6080" \
        -e "EMULATOR_DEVICE=$ANDROID_DEVICE" -e WEB_VNC=true \
        -v "$ANDROID_VOLUME:/home/androidusr" \
        "$ANDROID_IMAGE" >/dev/null ;;
  esac
  run_args+=(--network "$NETWORK")

  # Connect adb once the REA container exists and the emulator answers.
  # Detached from stdio so it can never touch the MCP stream.
  (
    for _ in $(seq 1 120); do
      if d exec "$name" adb connect "$ADB_TARGET" 2>/dev/null | grep -qE '^(already )?connected'; then
        exit 0
      fi
      sleep 5
    done
  ) </dev/null >/dev/null 2>&1 &
else
  log "Android emulator off (no /dev/kvm, or REA_ANDROID=0): static analysis only"
fi

exec "$DOCKER" "${run_args[@]}" "$REA_IMAGE" rea mcp
