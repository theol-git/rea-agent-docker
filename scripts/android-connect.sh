#!/usr/bin/env bash
# Connect the adb client inside a running REA container to the Android
# emulator sidecar (compose.android.yml) and wait until Android has booted.
#
#   scripts/android-connect.sh [--container NAME] [--target HOST:PORT] [--timeout SECONDS]
#
# Defaults: container rea-agent-ghidra, target android-emulator:5555, 600 s.
# `make android-connect ENGINE=ghidra|hopper|ida|all` passes the right container.
#
# Safe to re-run: `adb connect` is idempotent. Run it again after restarting
# either container, because the adb server inside the REA container forgets
# its connections when that container restarts.
set -euo pipefail

container="rea-agent-ghidra"
target="${ANDROID_EMULATOR_HOST:-android-emulator}:${ANDROID_EMULATOR_ADB_PORT:-5555}"
timeout=600
docker_bin="${DOCKER:-docker}"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --container) container="${2:?--container needs a value}"; shift 2 ;;
    --target)    target="${2:?--target needs a value}"; shift 2 ;;
    --timeout)   timeout="${2:?--timeout needs a value}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! "$docker_bin" inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q true; then
  echo "container '$container' is not running (start it first, e.g. 'make up-ghidra')" >&2
  exit 1
fi

adb() { "$docker_bin" exec "$container" adb "$@"; }

echo "waiting for $target (up to ${timeout}s; the first boot is slow) ..."
deadline=$(( $(date +%s) + timeout ))
connected=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  out="$(adb connect "$target" 2>&1 || true)"
  if grep -qE '^(connected|already connected) to' <<<"$out"; then
    connected=1
    break
  fi
  sleep 5
done
if [ "$connected" -ne 1 ]; then
  echo "could not connect to $target within ${timeout}s. Last adb output:" >&2
  echo "$out" >&2
  echo "check: docker logs rea-android-emulator   (and that /dev/kvm exists on the host)" >&2
  exit 1
fi
echo "adb: $out"

echo "waiting for Android to finish booting ..."
while [ "$(date +%s)" -lt "$deadline" ]; do
  boot="$(adb -s "$target" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r[:space:]' || true)"
  if [ "$boot" = "1" ]; then
    echo "emulator ready:"
    adb devices
    exit 0
  fi
  sleep 5
done

echo "connected, but Android did not report sys.boot_completed=1 within ${timeout}s" >&2
exit 1
