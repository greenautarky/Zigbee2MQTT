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

The **build** of 2.12.1 for armv7 succeeds. The problem is **runtime** (below).

## ⚠️ RUNTIME BLOCKER — Z2M 2.12.x does not run on armv7 (as of 2026-07-16)

A watchdog-free boot test of `ga_zigbee2mqtt-armv7:2.12.1-2` on real armv7
hardware (canary KIB-SON-00000006) showed:

- container **starts and stays running** for the full 8-minute observation,
- emits **zero log lines** to stdout,
- **never binds the web frontend on `:8099`** (health-check target).

So it is **not** a slow-start / watchdog-kill problem — the process hangs
silently very early, before it serves anything. Our two mitigations already in
`common/Dockerfile` help the *other* failure mode but do not fix this one:

1. `NODE_COMPILE_CACHE` + a build-time warm-up bake (V8 bytecode cache) —
   against slow Node module load.
2. `HEALTHCHECK ... --start-period=180s` — so a slow (but eventual) start is not
   killed by the Supervisor watchdog.

**Conclusion:** 2.12.x is not viable on armv7 yet; the fleet stays on
**2.6.3-1** for armv7. aarch64/amd64 are unaffected and can run 2.12.x.
Unfreezing armv7 needs upstream-level debugging of the early hang (profile the
Node startup on 32-bit ARM, find the module/call that never returns).

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
4. **Before rolling armv7:** run a watchdog-free boot test on ONE armv7 canary
   (does `:8099` ever bind? see the runtime blocker above). aarch64/amd64 can be
   rolled without this gate.
5. Roll via the add-on store pin (`vibe_addons` in `ha-operating-system`) — the
   iHost addon slug is `99f1cad4_ga_zigbee2mqtt`.

## Current state (2026-07-16)

| arch | Z2M version in fleet | notes |
|------|----------------------|-------|
| armv7 (iHost) | **2.6.3-1** | last upstream armv7 build; healthy. 2.12.x blocked by the runtime hang. |
| aarch64 / amd64 | free to move | not affected by the armv7 hang. |
