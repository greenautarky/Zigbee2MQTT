#!/usr/bin/env bash
# Self-test for the GA herdsman patch (Odoo #1221).
# Installs the pinned zigbee-herdsman from npm, applies the LIVE
# common/herdsman-patch/apply-patch.js to it, and runs guard.test.js against
# the patched install.
#   GA_SKIP_PATCH=1 bash run.sh   -> red proof: same tests on UNPATCHED herdsman (must fail)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
version="$(sed -n 's/^const EXPECTED_VERSION = "\(.*\)";/\1/p' "$repo/common/herdsman-patch/apply-patch.js")"
[ -n "$version" ] || { echo "FAIL: could not read EXPECTED_VERSION from apply-patch.js"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
echo "installing zigbee-herdsman@$version into $work"
(cd "$work" && npm init -y >/dev/null && npm install --silent --no-audit --no-fund --ignore-scripts "zigbee-herdsman@$version" >/dev/null)
hm="$work/node_modules/zigbee-herdsman"

if [ "${GA_SKIP_PATCH:-0}" = "1" ]; then
  echo "GA_SKIP_PATCH=1: running against UNPATCHED herdsman (red proof)"
else
  node "$repo/common/herdsman-patch/apply-patch.js" "$hm"
fi

HERDSMAN_DIR="$hm" node --test "$here/guard.test.js"
