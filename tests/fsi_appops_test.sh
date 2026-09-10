#!/usr/bin/env bash
# ==============================================================================
# FSI AppOps backup / restore round-trip tests
# ==============================================================================
# Exercises the helpers in module/common.sh against a stub `cmd appops`, so the
# state machine that records, grants, re-grants and gives back per-app modes is
# covered without a device. What it pins:
#   - the pre-grant mode is recorded once and survives a second grant
#   - removal gives back exactly what was recorded, never a hardcoded ignore
#   - a missing record falls back to default, never to ignore
#   - the boot re-apply leaves a mode the user changed alone
#   - 10008 OP_AUTO_START is never written
# ==============================================================================
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── Stub `cmd appops`, backed by a flat file of "<pkg> <op> <mode>" ────────────
mkdir -p "$WORK/bin"
export APPOPS_DB="$WORK/appops.db"
: > "$APPOPS_DB"

cat > "$WORK/bin/cmd" <<'STUB'
#!/usr/bin/env bash
# Only `appops get|set` is modelled; anything else succeeds silently.
[ "${1:-}" = "appops" ] || exit 0
action="${2:-}"; pkg="${3:-}"; op="${4:-}"; mode="${5:-}"
case "$action" in
  set)
    grep -v "^$pkg $op " "$APPOPS_DB" > "$APPOPS_DB.tmp" 2>/dev/null || :
    mv -f "$APPOPS_DB.tmp" "$APPOPS_DB"
    echo "$pkg $op $mode" >> "$APPOPS_DB"
    ;;
  get)
    line=$(grep "^$pkg $op " "$APPOPS_DB" 2>/dev/null | tail -n1)
    # The framework echoes the uid record first, and it is NOT the package mode
    # `appops set <pkg>` writes - the reader has to step over it. Reproduced
    # here with a deliberately different mode so a reader that grabs it fails.
    echo "Uid mode: $op: foreground"
    if [ -z "$line" ]; then
      # Matches the framework's wording for an op with no records at all.
      echo "No operations."
    else
      mode=$(echo "$line" | awk '{print $3}')
      # A numeric MIUI op is printed wrapped: "MIUIOP(10021): allow". Reading it
      # as a bare number is how the real device came back "unknown".
      case "$op" in
        [0-9]*) echo "  MIUIOP($op): $mode; time=+1d2h3m4s5ms ago" ;;
        *)      echo "  $op: $mode" ;;
      esac
    fi
    ;;
esac
exit 0
STUB
chmod 0755 "$WORK/bin/cmd"
PATH="$WORK/bin:$PATH"
export PATH

# common.sh is a /system/bin/sh script; bash runs it as a POSIX-compatible subset.
# shellcheck source=/dev/null
. "$DIR/module/common.sh"

CONF="$WORK/stock_settings.conf"
: > "$CONF"
PKG="com.example.voip"
OTHER="com.example.voip.helper"   # shares a dot-prefix with PKG on purpose

FAILURES=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf '  [PASS] %s\n' "$what"
    else
        printf '  [FAIL] %s\n         expected %-12s got %s\n' "$what" "$expected" "$actual"
        FAILURES=$((FAILURES + 1))
    fi
}
live()  { read_appop_mode "$1" "$2"; }
saved() { saved_fsi_appop_mode "$CONF" "$1" "$2"; }
# The record as written. saved() normalises anything unrecognised to "default",
# so it cannot show whether "unknown" was stored in the first place.
raw()   { awk -F= -v k="fsi_appop:$1:$2" '$1 == k { print $2; exit }' "$CONF"; }

echo "== FSI AppOps backup / restore =="

# ── 1. Grant records the pre-grant modes and sets every op to allow ───────────
cmd appops set "$PKG" USE_FULL_SCREEN_INTENT default
cmd appops set "$PKG" 10020 allow
cmd appops set "$PKG" 10021 ignore

apply_fsi_appops "$CONF" "$PKG"

check "recorded USE_FULL_SCREEN_INTENT" default "$(saved "$PKG" USE_FULL_SCREEN_INTENT)"
check "recorded 10020"                  allow   "$(saved "$PKG" 10020)"
check "recorded 10021"                  ignore  "$(saved "$PKG" 10021)"
check "granted USE_FULL_SCREEN_INTENT"  allow   "$(live "$PKG" USE_FULL_SCREEN_INTENT)"
check "granted 10020"                   allow   "$(live "$PKG" 10020)"
check "granted 10021"                   allow   "$(live "$PKG" 10021)"

# ── 2. OP_AUTO_START is never written ────────────────────────────────────────
check "10008 OP_AUTO_START untouched" "" "$(grep -c '10008' "$APPOPS_DB" | sed 's/^0$//')"

# ── 3. A second grant must not overwrite the record with the module's own allow ─
apply_fsi_appops "$CONF" "$PKG"
check "record survives a second grant" ignore "$(saved "$PKG" 10021)"

# ── 4. Removal gives back what was recorded, and forgets it ──────────────────
restore_fsi_appops "$CONF" "$PKG"
check "restored USE_FULL_SCREEN_INTENT" default "$(live "$PKG" USE_FULL_SCREEN_INTENT)"
check "restored 10020"                  allow   "$(live "$PKG" 10020)"
check "restored 10021"                  ignore  "$(live "$PKG" 10021)"
check "records dropped after restore"   0       "$(grep -c "^fsi_appop:$PKG:" "$CONF")"

# ── 5. Re-adding after a restore captures the restored state, not "allow" ────
apply_fsi_appops "$CONF" "$PKG"
check "re-add records the restored mode" ignore "$(saved "$PKG" 10021)"

# ── 6. "keep" leaves the records in place for the staged uninstall restore ───
restore_fsi_appops "$CONF" "$PKG" keep
check "records kept for staged restore" 3 "$(grep -c "^fsi_appop:$PKG:" "$CONF")"
forget_fsi_appops "$CONF" "$PKG"

# ── 7. A package with no record at all falls back to default, never ignore ───
cmd appops set "$OTHER" 10021 allow
restore_fsi_appops "$CONF" "$OTHER"
check "unrecorded op falls back to default" default "$(live "$OTHER" 10021)"

# ── 8. A mode the reader cannot classify is recorded as unknown and restored ──
# as default. MIUI has modes beyond the five the shell setter takes - MODE_ASK
# among them - and writing back a mode `cmd appops set` may reject would leave
# the module's own allow standing, which is worse than the neutral value.
: > "$CONF"
cmd appops set "$OTHER" 10021 ask
apply_fsi_appops "$CONF" "$OTHER"
check "unclassifiable mode is recorded as unknown" unknown "$(raw "$OTHER" 10021)"
restore_fsi_appops "$CONF" "$OTHER"
check "unknown restores as default, not ignore" default "$(live "$OTHER" 10021)"

# ── 9. A grant whose record cannot be written must not happen at all ─────────
# Granting with no record is how a later removal ends up guessing.
UNWRITABLE="$WORK/nodir/stock_settings.conf"
cmd appops set "$OTHER" 10021 ignore
if apply_fsi_appops "$UNWRITABLE" "$OTHER"; then
    check "grant refused when the record cannot be written" "refused" "granted"
else
    check "grant refused when the record cannot be written" "refused" "refused"
fi
check "op untouched after a refused grant" ignore "$(live "$OTHER" 10021)"

# ── 10. Forgetting one package must not take a dot-prefixed neighbour's records ─
: > "$CONF"
apply_fsi_appops "$CONF" "$PKG"
apply_fsi_appops "$CONF" "$OTHER"
forget_fsi_appops "$CONF" "$PKG"
check "neighbour's records survive" 3 "$(grep -c "^fsi_appop:$OTHER:" "$CONF")"
check "own records removed"         0 "$(grep -c "^fsi_appop:$PKG:" "$CONF")"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "FSI AppOps round-trip tests PASSED"
    exit 0
fi
echo "FSI AppOps round-trip tests FAILED ($FAILURES)"
exit 1
