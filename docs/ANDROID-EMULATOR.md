# Android emulator sidecar

An optional [`budtmo/docker-android`](https://github.com/budtmo/docker-android)
container that runs next to the REA container, so REA's Android tooling (`adb`,
Apktool, jadx, Frida, mitmproxy) has a real device to talk to: install an APK,
run it, watch it, instrument it.

It is a **sidecar defined in `compose.android.yml`**, not part of the REA image.
The emulator needs `/dev/kvm`, several GB of RAM and its own Android SDK; folding
that into an image that is already ~8 GB would make every engine image heavier
and unusable on hosts without KVM. As a sidecar it joins the same Compose
network, so the REA container reaches it by name: `android-emulator:5555`.

```
        host (Linux, /dev/kvm)
 ┌────────────────────────────────────────────────────────┐
 │  compose network "rea-agent_default"                   │
 │                                                        │
 │  rea-agent-ghidra ── adb connect ──► android-emulator  │
 │   (REA, adb, jadx,        :5555       (budtmo, QEMU/KVM)│
 │    Frida, mitmdump)                   :6080 noVNC ──────┼──► http://127.0.0.1:6080
 └────────────────────────────────────────────────────────┘
```

## Requirements

- x86-64 Linux host with hardware virtualisation and a usable `/dev/kvm`.
  Check with `kvm-ok` (package `cpu-checker`) or `ls -l /dev/kvm`. Your user
  normally needs to be in the `kvm` group.
- Docker Compose v2.
- A few GB of free RAM and ~10 GB of disk for the image and emulator data.

Upstream documents Ubuntu hosts; the container itself only needs KVM passed
through, so other distributions are expected to work but are not what upstream
tests. macOS and Windows hosts have no KVM and need a Linux VM with nested
virtualisation.

## Start it

```bash
cp .env.example .env                    # if you have not already
make up-ghidra                          # the REA container (or: docker compose --profile ghidra up -d rea-ghidra)
make android-up                         # the emulator (first run pulls a large image)
make android-connect ENGINE=ghidra      # adb connect + wait for Android to finish booting
```

`make android-connect` runs [`scripts/android-connect.sh`](../scripts/android-connect.sh).
It retries `adb connect android-emulator:5555` from inside the REA container until
the emulator answers, then waits for `sys.boot_completed=1`. The first boot takes
minutes. Open <http://127.0.0.1:6080> to watch the screen.

Pick the container with `ENGINE=all|ghidra|hopper|ida` (default `all` →
`rea-agent`). If you renamed containers in `.env`, pass `CONTAINER=<name>`.

Run `make android-connect` again after restarting **either** container: the adb
server inside the REA container forgets its connections when it restarts.

## Use it

Anything in `./targets` is visible inside the REA container as `/targets`, so:

```bash
cp app.apk targets/
docker exec rea-agent-ghidra adb devices
docker exec rea-agent-ghidra adb install /targets/app.apk
docker exec rea-agent-ghidra adb shell pm list packages -3
```

From an MCP client (Claude Code, Codex, Hermes) just ask for it in plain words:
"install `/targets/app.apk` on the emulator, launch it and tell me which hosts it
contacts". REA's `adb` path is already configured (`REA_ADB_PATH`). For wiring
Claude Code to REA see [CLAUDE-CODE.md](CLAUDE-CODE.md).

## Configuration

All knobs are in `.env` (see `.env.example`):

| Variable | Default | Meaning |
| --- | --- | --- |
| `ANDROID_EMULATOR_IMAGE` | `budtmo/docker-android:emulator_13.0` | Android version is the image tag: `emulator_9.0` … `emulator_14.0` |
| `ANDROID_EMULATOR_DEVICE` | `"Samsung Galaxy S10"` | Device profile (`EMULATOR_DEVICE`). Quote values with spaces |
| `ANDROID_EMULATOR_CONTAINER_NAME` | `rea-android-emulator` | Container name |
| `ANDROID_EMULATOR_VOLUME` | `rea-android-emulator-data` | Named volume mounted at `/home/androidusr` so apps and data survive restarts |
| `ANDROID_NOVNC_BIND` / `ANDROID_NOVNC_PORT` | `127.0.0.1` / `6080` | Where the noVNC viewer is published |

The `budtmo/docker-android` README documents further settings in its own
"Custom Configurations" page; add them under `environment:` in
`compose.android.yml`.

## Security

- **adb is unauthenticated.** Anyone who can reach port 5555 can install and run
  code on the emulator. That is why the port is *not* published to the host: only
  containers on the Compose network can reach it. If you must use adb from the
  host, uncomment the `127.0.0.1:5555:5555` line in `compose.android.yml` — keep it
  on loopback.
- Keep `ANDROID_NOVNC_BIND` on `127.0.0.1` unless you put authentication in front.
- Treat the emulator as hostile ground when running untrusted APKs. Do not
  mount anything sensitive into it, and do not log in to real accounts on it.

## Stop and clean up

```bash
make android-down                                  # remove the container, keep the data volume
docker volume rm rea-android-emulator-data         # also drop the emulator's data
```

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `could not open /dev/kvm`, container exits at once | No KVM on the host, or no permission. `ls -l /dev/kvm`; add your user to `kvm`; enable VT-x/AMD-V in firmware; inside a VM enable nested virtualisation |
| `android-connect` times out | Emulator still booting (first start is slow) — raise `--timeout`; otherwise `docker logs rea-android-emulator` |
| `adb devices` empty in the REA container | The adb server restarted — run `make android-connect` again |
| `offline` device | Wait for boot to finish, then `docker exec <rea> adb reconnect` |
| Name `android-emulator` does not resolve | REA container is not on the same Compose project/network. Start both from this directory with the same project name (`rea-agent`) |

## Verification status

This overlay was checked statically: `docker compose config` accepts it with the
default and every engine profile, the Make targets expand correctly, and the
connect script passes `bash -n`. The emulator itself needs KVM and a multi-GB
image, so it has **not** been booted from this repository's CI or by the author
of the change. First run on your machine is the real test; if the emulator's
adb port or device setup differs from what is assumed here (adb on 5555), adjust
`ANDROID_EMULATOR_ADB_PORT` / `--target` in `scripts/android-connect.sh` and the
docs accordingly.

## Licence

`budtmo/docker-android` and the Android SDK/emulator components it contains keep
their own licences and terms; nothing from them is redistributed by this
repository — the image is pulled directly from Docker Hub. This project only
uses the free community `emulator_*` images, not the paid "pro" ones.
See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
