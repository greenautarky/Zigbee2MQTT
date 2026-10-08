#!/usr/bin/env bash
# Self-test for the GA linkquality default in common/rootfs/docker-entrypoint.sh.
# Runs the LIVE entrypoint (never a copy of its logic) with bashio stubbed and a
# fake `node` that reports what Zigbee2MQTT would receive, in three cases:
#   1. fresh data dir          -> seeded configuration.yaml carries the override
#   2. existing config, no key -> override supplied via ZIGBEE2MQTT_CONFIG_DEVICE_OPTIONS
#   3. owner's device_options  -> left alone, env NOT set, loud warning logged
# Usage: test-entrypoint-device-options.sh [path/to/docker-entrypoint.sh]
set -uo pipefail   # no -e: every check must run and report

ENTRYPOINT="${1:-$(cd "$(dirname "$0")/.." && pwd)/rootfs/docker-entrypoint.sh}"
[ -f "$ENTRYPOINT" ] || { echo "FAIL: entrypoint not found: $ENTRYPOINT"; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0; checks=0

mkdir -p "$WORK/bin" "$WORK/app"
cat > "$WORK/bin/node" <<'NODE'
#!/usr/bin/env bash
echo "NODE_ENV_DEVICE_OPTIONS=${ZIGBEE2MQTT_CONFIG_DEVICE_OPTIONS-<unset>}"
NODE
chmod +x "$WORK/bin/node"

cat > "$WORK/stubs.sh" <<'STUBS'
bashio::config() { [ "$1" = data_path ] && echo "$TEST_DATA"; return 0; }
bashio::config.require() { :; }
bashio::config.true() { return 1; }
bashio::config.has_value() { return 1; }
bashio::config.is_empty() { return 0; }
bashio::fs.file_exists() { [ -f "$1" ]; }
bashio::var.has_value() { return 1; }
bashio::services() { :; }
bashio::exit.nok() { echo "EXIT_NOK $*"; exit 1; }
bashio::log.info() { echo "INFO $*"; }
bashio::log.warning() { echo "WARNING $*"; }
bashio::log.debug() { :; }
bashio::log.blue() { :; }
STUBS

run() {  # $1 = data dir
    # Drop the bashio shebang, point `cd /app` at a scratch dir; everything else is live.
    { cat "$WORK/stubs.sh"; sed -e '1d' -e "s#^cd /app\$#cd '$WORK/app'#" "$ENTRYPOINT"; } > "$WORK/run.sh"
    TEST_DATA="$1" PATH="$WORK/bin:$PATH" bash "$WORK/run.sh" 2>&1
}
check() {  # $1 = description, $2 = condition result (0 ok)
    checks=$((checks+1))
    if [ "$2" -eq 0 ]; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi
}
has_override() {  # parse YAML/JSON for real, not by grep
    python3 -I -c '
import sys, json
try:
    import yaml; d = yaml.safe_load(open(sys.argv[1]))
except ImportError:
    sys.exit(2)
v = (((d or {}).get("device_options") or {}).get("homeassistant") or {}).get("linkquality") or {}
sys.exit(0 if v.get("enabled_by_default") is True else 1)' "$1"
}
EXPECT='{"homeassistant":{"linkquality":{"enabled_by_default":true}}}'

# 1 — fresh
D1="$WORK/fresh"; out="$(run "$D1")"
[ -f "$D1/configuration.yaml" ]; check "fresh: configuration.yaml seeded" $?
has_override "$D1/configuration.yaml"; check "fresh: seed has device_options.homeassistant.linkquality.enabled_by_default=true" $?

# 2 — existing config without device_options (pre-2.12.1-7 seed)
D2="$WORK/existing"; mkdir -p "$D2"
printf 'version: 4\nhomeassistant:\n  enabled: true\n' > "$D2/configuration.yaml"
before="$(cat "$D2/configuration.yaml")"
out="$(run "$D2")"
env_val="$(sed -n 's/^NODE_ENV_DEVICE_OPTIONS=//p' <<<"$out")"
python3 -I -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1])==json.loads(sys.argv[2]) else 1)' "$env_val" "$EXPECT" 2>/dev/null
check "existing: ZIGBEE2MQTT_CONFIG_DEVICE_OPTIONS carries the override (got: $env_val)" $?
[ "$before" = "$(cat "$D2/configuration.yaml")" ]; check "existing: configuration.yaml not rewritten by the entrypoint" $?

# 3 — owner's own device_options
D3="$WORK/owner"; mkdir -p "$D3"
printf 'version: 4\ndevice_options:\n  legacy: false\n' > "$D3/configuration.yaml"
out="$(run "$D3")"
grep -q '^NODE_ENV_DEVICE_OPTIONS=<unset>$' <<<"$out"; check "owner: env NOT set over an existing device_options block" $?
grep -q '^WARNING .*linkquality' <<<"$out"; check "owner: missing linkquality override is logged as WARNING" $?

echo "checks=$checks fails=$fails"
[ "$checks" -gt 0 ] || { echo "FAIL: zero checks ran"; exit 1; }
[ "$fails" -eq 0 ]
