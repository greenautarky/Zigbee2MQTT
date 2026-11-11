#!/usr/bin/env bash
# Self-test for the GA external converters (Odoo #1934).
# Installs the zigbee-herdsman-converters version that the PINNED Zigbee2MQTT release
# locks (read from zigbee2mqtt/config.json -> upstream pnpm-lock.yaml), stages the LIVE
# common/ga-converters/*.mjs next to it (byte-identical, checked), runs the tests.
#   GA_SKIP_CONVERTERS=1 bash run.sh   -> red proof: same tests without the converters (must fail)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
addon_version="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$repo/zigbee2mqtt/config.json")"
z2m="${addon_version%-*}"
[ -n "$z2m" ] || { echo "FAIL: could not read the Z2M version"; exit 1; }
lock="$(curl -fsSL -m 60 "https://raw.githubusercontent.com/Koenkk/zigbee2mqtt/${z2m}/pnpm-lock.yaml")" \
  || { echo "FAIL: could not fetch the pnpm-lock.yaml of Zigbee2MQTT ${z2m}"; exit 1; }
zhc="$(sed -n 's/^  zigbee-herdsman-converters@\([0-9][^:]*\):$/\1/p' <<<"$lock" | head -1)"
[ -n "$zhc" ] || { echo "FAIL: zigbee-herdsman-converters version not found in the Z2M ${z2m} lockfile"; exit 1; }
echo "Zigbee2MQTT ${z2m} locks zigbee-herdsman-converters@${zhc}"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
(cd "$work" && npm init -y >/dev/null && npm install --silent --no-audit --no-fund --ignore-scripts "zigbee-herdsman-converters@${zhc}" >/dev/null)
mkdir -p "$work/stage"
n=0
for f in "$repo"/common/ga-converters/*.mjs; do
  [ -e "$f" ] || continue
  cp "$f" "$work/stage/"; cmp -s "$f" "$work/stage/$(basename "$f")" || { echo "FAIL: staged copy of $f differs"; exit 1; }
  n=$((n+1))
done
[ "$n" -gt 0 ] || { echo "FAIL: no converter in common/ga-converters"; exit 1; }
cp "$here/converters.test.mjs" "$work/"
cd "$work"   # ESM resolution of zigbee-herdsman-converters starts here
GA_STAGE="$work/stage" GA_FIXTURES="$here/fixtures.json" node --test "$work/converters.test.mjs"
