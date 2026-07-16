# GreenAutarky armv7 self-build — maintenance notes

**Why this fork exists and what to watch when bumping Zigbee2MQTT for the
iHost (armv7) fleet.** Read this before changing the version pin.

## The core reason we self-build

Upstream `zigbee2mqtt/hassio-zigbee2mqtt` **dropped the 32-bit builds
(armv7 / armhf / i386) after `2.6.3-1`**. There is no upstream armv7 image for
any later tag — verified 2026-07-16:

```
docker manifest inspect ghcr.io/zigbee2mqtt/zigbee2mqtt-armv7:2.7.0   -> missing
docker manifest inspect ghcr.io/zigbee2mqtt/zigbee2mqtt-armv7:2.9.0   -> missing
docker manifest inspect ghcr.io/zigbee2mqtt/zigbee2mqtt-armv7:2.12.0  -> missing
docker manifest inspect ghcr.io/zigbee2mqtt/zigbee2mqtt-armv7:2.12.1  -> missing
ghcr.io/zigbee2mqtt/zigbee2mqtt-armv7:2.6.3-1                         -> EXISTS (last one)
```

The iHost (Rockchip) is **armv7**, so from 2.7 onward the fleet can only get a
newer Z2M if **we build it ourselves**. That is what this fork does.

## What the self-build is

- Branch: **`ga-build/z2m-2.12.1-armv7`** (build config lives here).
- `common/Dockerfile`, `common/build.yaml`, `.github/workflows/publish.yaml`
  — a trimmed copy of the upstream add-on build, extended for armv7.
- CI publishes `ghcr.io/greenautarky/ga_zigbee2mqtt-{arch}:{version}` for
  **aarch64, amd64, armv7**. Version comes from `zigbee2mqtt/config.json`.
- armv7 builds via **qemu-arm emulation** on a normal `ubuntu-latest` runner
  (native arm64 runner for aarch64; qemu of *arm64* SIGILLs, qemu of *arm32*
  is stable — see the matrix comments in `publish.yaml`).
- armv7 base image is our one divergence: **`armv7-base:3.21`** (Node 22).
  aarch64/amd64 track upstream's `3.22`. Keep these in lockstep on every bump;
  only move armv7 off 3.21 after a green armv7 CI run.

The **build** of 2.12.1 for armv7 succeeds. Runtime status is **unresolved** —
see below (and do NOT trust standalone `docker run` to settle it).

## Runtime status on armv7 — UNRESOLVED (2026-07-16), NOT proven broken

The evidence is mixed and the current fleet pin stays at **2.6.3-1** out of
caution, but "2.12 doesn't run on armv7" is **not established**:

- **FOR it working:** on 2026-07-07, `ga_zigbee2mqtt-armv7:2.12.1-1` ran on a
  real armv7 canary (K0) **via the normal Supervisor add-on path** — MQTT
  auto-binding connected, the ember coordinator came up (EmberZNet 8.0.2,
  `/dev/ttyS4`), and real paired Zigbee devices reported (Sonoff TRVZB). So
  2.12 CAN run on armv7.
- **AGAINST / open:** a later build `2.12.1-2` (which added the
  `NODE_COMPILE_CACHE` warm-up bake below) was reported not to come up healthy
  on a canary — but that observation is **confounded** by the config-v5
  migration trap (next section) and by an **invalid test method** (below). It is
  NOT clean evidence of a 2.12 runtime hang.

### ⚠️ Standalone `docker run` is NOT a valid way to test this add-on

Hand-running the image outside the Supervisor lifecycle **cannot** exercise
Z2M: the HA add-on `cont-init` reads its config (`data_path`, mqtt binding, …)
from the **Supervisor API**, and a standalone container is refused:

```
ERROR: Unable to access the API, forbidden
ERROR: Failed to get addon config from Supervisor API
FATAL: Please set a value for the 'data_path' option.
```

The `SUPERVISOR_TOKEN` only authorises API calls from the container Supervisor
itself started; a hand-launched container gets `forbidden` and the entrypoint
FATALs before Z2M starts. So any "it never binds :8099 standalone" result says
nothing about Z2M on armv7 — it never got to run. **Only the Supervisor path
(`ha addons update`/install to the pinned version) is a valid test.**

### How to actually settle it (recommended next step)

1. Rebuild a **compile-cache-free** `2.12.1-3` (drop the warm-up bake — it is
   unproven and the prime suspect for any -2 regression; keep only the raised
   `--start-period`).
2. Pin the store (`vibe_addons/zigbee2mqtt`) to it and `ha addons update
   99f1cad4_ga_zigbee2mqtt` on ONE armv7 canary.
3. Judge health via the **Supervisor** (`ha addons info … state`, health-check),
   not a hand-run container. Mind the config-v5 trap when rolling back.

## 🪤 Config-migration trap — do NOT point 2.12.x at a 2.6.3-1 data dir

Z2M **migrates `configuration.yaml` from v4 → v5 on first 2.12 start**, very
early (before the frontend, so it happens even during the hang above). Once the
file is v5, **2.6.3-1 refuses to start**:

```
Error: Your configuration.yaml has an unsupported version 5, expected one of undefined,2,3,4.
```

This bit us: the blocker test ran 2.12.1 against the live addon's shared data
dir, silently upgraded the config to v5, and the 2.6.3-1 addon then crash-looped
(`Exited (1)`).

**Rollback:** Z2M writes `configuration_backup_v<old>.yaml` next to the config
before migrating. Restore it:

```sh
D=/mnt/data/supervisor/homeassistant/zigbee2mqtt   # z2m data dir on the iHost
cp "$D/configuration.yaml" "$D/configuration.yaml.v5-saved"   # keep the v5 aside
cp "$D/configuration_backup_v4.yaml" "$D/configuration.yaml"  # back to v4
ha addons restart 99f1cad4_ga_zigbee2mqtt
```

**Rule:** never test a newer Z2M against a data dir you intend to keep on
2.6.3-1. Use a throwaway `ZIGBEE2MQTT_DATA` dir, or expect to roll the config
back.

## How to bump the version (checklist)

1. Set the new version in `zigbee2mqtt/config.json` (`"version": "<x.y.z-N>"`).
2. If Z2M bumped its Alpine/Node base, update `common/build.yaml`
   (aarch64/amd64 → upstream's tag; **leave armv7 on the proven base**, move it
   only after a green armv7 CI run).
3. Push to `master` or a `ga-build/**` branch → CI builds+pushes all three
   arches to `ghcr.io/greenautarky/ga_zigbee2mqtt-{arch}:{version}`.
4. **Before rolling armv7:** update ONE armv7 canary via the **Supervisor path**
   (`ha addons update 99f1cad4_ga_zigbee2mqtt`) and judge health via `ha addons
   info … state` + the Supervisor health-check. Do NOT rely on a standalone
   `docker run` — it cannot authenticate to the Supervisor API and never runs
   Z2M (see the runtime-status section). aarch64/amd64 skip this gate.
5. Roll via the add-on store pin (`vibe_addons` in `ha-operating-system`) — the
   iHost addon slug is `99f1cad4_ga_zigbee2mqtt`.

## Current state (2026-07-16)

| arch | Z2M version in fleet | notes |
|------|----------------------|-------|
| armv7 (iHost) | **2.6.3-1** | last upstream armv7 build; healthy. 2.12.x runtime on armv7 is UNRESOLVED (2.12.1-1 ran on K0 07-07; -2 confounded) — re-validate via the Supervisor path with a compile-cache-free 2.12.1-3. |
| aarch64 / amd64 | free to move | not affected by the armv7 question. |

## The `NODE_COMPILE_CACHE` warm-up bake — treat as suspect

`common/Dockerfile` (added in 2.12.1-2) sets `NODE_COMPILE_CACHE` and runs a
build-time `node index.js` warm-up to bake a V8 bytecode cache. The intent was
faster startup, but it is **unproven on armv7** and is the prime suspect for any
2.12.1-2 regression vs the known-good 2.12.1-1. If a fresh Supervisor-path test
shows -2 misbehaving, drop the warm-up first and keep only the raised
`HEALTHCHECK --start-period`.
