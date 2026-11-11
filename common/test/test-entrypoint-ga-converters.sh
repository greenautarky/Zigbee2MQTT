#!/usr/bin/env bash
# Self-test for install_ga_converters in common/rootfs/docker-entrypoint.sh (Odoo #1934).
# Runs the LIVE entrypoint (bashio stubbed, fake node) against the LIVE
# common/ga-converters directory and asserts:
#   1. fresh data dir           -> every shipped converter installed, byte-identical
#   2. second start             -> idempotent: nothing rewritten, no "installed" line
#   3. outdated GA copy         -> replaced by the shipped version
#   4. owner's same-named file  -> kept byte-identical, WARNING logged
#   5. owner's other converter  -> untouched
#   6. GA file no longer shipped -> removed; an unmarked file of the same kind stays
#   7. image without the source -> WARNING, start continues
# Usage: test-entrypoint-ga-converters.sh [path/to/docker-entrypoint.sh] [path/to/ga-converters]
set -uo pipefail   # no -e: every check must run and report

here="$(cd "$(dirname "$0")" && pwd)"
ENTRYPOINT="${1:-$here/../rootfs/docker-entrypoint.sh}"
SRC="${2:-$here/../ga-converters}"
[ -f "$ENTRYPOINT" ] || { echo "FAIL: entrypoint not found: $ENTRYPOINT"; exit 1; }
shipped=( "$SRC"/*.mjs )
[ -e "${shipped[0]}" ] || { echo "FAIL: no *.mjs converter in $SRC — nothing to test"; exit 1; }
MARKER='// GA-MANAGED external converter'
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0; checks=0

mkdir -p "$WORK/bin" "$WORK/app"
printf '#!/usr/bin/env bash\necho NODE_STARTED\n' > "$WORK/bin/node"; chmod +x "$WORK/bin/node"
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
run() {  # $1 data dir, $2 converter source dir
    { cat "$WORK/stubs.sh"; sed -e '1d' -e "s#^cd /app\$#cd '$WORK/app'#" "$ENTRYPOINT"; } > "$WORK/run.sh"
    TEST_DATA="$1" GA_CONVERTER_SRC="$2" PATH="$WORK/bin:$PATH" bash "$WORK/run.sh" 2>&1
}
# Callers capture rc=$? BEFORE calling check: a $(...) inside the description is
# expanded first and would reset $? to 0 — a check that can never fail.
check() { checks=$((checks+1)); if [ "$2" -eq 0 ]; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }

for f in "${shipped[@]}"; do
    head -1 "$f" | grep -qF "$MARKER"; rc=$?; check "shipped $(basename "$f") carries the GA-MANAGED marker on line 1" "$rc"
done

# 1 — fresh
D="$WORK/fresh"; out="$(run "$D" "$SRC")"
grep -q '^NODE_STARTED$' <<<"$out"; rc=$?; check "fresh: Zigbee2MQTT is still started" "$rc"
n=0; for f in "${shipped[@]}"; do
    cmp -s "$f" "$D/external_converters/$(basename "$f")"; rc=$?; check "fresh: $(basename "$f") installed byte-identical" "$rc"; n=$((n+1))
done
[ "$n" -ge 1 ]; rc=$?; check "fresh: at least one converter was inspected ($n)" "$rc"

# 2 — second start is idempotent
f0="$D/external_converters/$(basename "${shipped[0]}")"
m1="$(stat -c %Y.%i "$f0")"; sleep 1
out="$(run "$D" "$SRC")"
[ "$m1" = "$(stat -c %Y.%i "$f0")" ]; rc=$?; check "second start: file not rewritten (mtime+inode unchanged)" "$rc"
! grep -q 'GA converter installed' <<<"$out"; rc=$?; check "second start: no 'installed' log line" "$rc"

# 3 — outdated GA copy is replaced
printf '%s — old version\nexport default {};\n' "$MARKER" > "$f0"
out="$(run "$D" "$SRC")"
cmp -s "${shipped[0]}" "$f0"; rc=$?; check "outdated GA copy replaced by the shipped version" "$rc"
grep -q "INFO GA converter installed: $(basename "$f0")" <<<"$out"; rc=$?; check "outdated GA copy: replacement logged" "$rc"

# 4 + 5 — owner's files
D4="$WORK/owner"; mkdir -p "$D4/external_converters"
own="$D4/external_converters/$(basename "${shipped[0]}")"
printf '// my own converter\nexport default {};\n' > "$own"; ownsum="$(sha256sum < "$own")"
printf '// another converter of mine\nexport default {};\n' > "$D4/external_converters/mine.mjs"; minesum="$(sha256sum < "$D4/external_converters/mine.mjs")"
out="$(run "$D4" "$SRC")"
[ "$ownsum" = "$(sha256sum < "$own")" ]; rc=$?; check "owner: same-named file without marker kept byte-identical" "$rc"
grep -q "^WARNING GA converter $(basename "$own") NOT installed" <<<"$out"; rc=$?; check "owner: refusal logged as WARNING" "$rc"
[ "$minesum" = "$(sha256sum < "$D4/external_converters/mine.mjs")" ]; rc=$?; check "owner: other converter untouched" "$rc"

# 6 — GA file no longer shipped is removed, unmarked file stays
printf '%s — retired\nexport default {};\n' "$MARKER" > "$D/external_converters/ga-retired.mjs"
printf '// unmarked\nexport default {};\n' > "$D/external_converters/keep-me.mjs"
out="$(run "$D" "$SRC")"
[ ! -e "$D/external_converters/ga-retired.mjs" ]; rc=$?; check "retired GA converter removed" "$rc"
grep -q 'INFO GA converter removed (no longer shipped): ga-retired.mjs' <<<"$out"; rc=$?; check "retired GA converter: removal logged" "$rc"
[ -e "$D/external_converters/keep-me.mjs" ]; rc=$?; check "unmarked file not in the image is kept" "$rc"

# 7 — source missing in the image
out="$(run "$WORK/nosrc" "$WORK/does-not-exist")"
grep -q '^WARNING GA converters: .* is missing from the image' <<<"$out"; rc=$?; check "missing source: WARNING logged" "$rc"
grep -q '^NODE_STARTED$' <<<"$out"; rc=$?; check "missing source: Zigbee2MQTT still starts" "$rc"

echo "checks=$checks fails=$fails"
[ "$checks" -gt 0 ] || { echo "FAIL: zero checks ran"; exit 1; }
[ "$fails" -eq 0 ]
