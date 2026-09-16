#!/usr/bin/env bash
# ==============================================================================
# AOT cache survival tests
# ==============================================================================
# ART Service's nightly BackgroundDexoptJob unlinks every /data/dalvik-cache
# artifact it did not produce - the module's compiled odex included. These
# tests pin the defence in module/common.sh against a fake dalvik-cache tree:
#   - compile_aot_cache archives exactly what it published, with a manifest
#   - the archive shares inodes with dalvik-cache (hard link, no copy)
#   - after a "cleanup" every name comes back, still the same inode
#   - restore never touches a name that is present, and is idempotent
#   - a cross-filesystem archive falls back to a copy and still restores
#   - forget removes both the archive and the dalvik-cache names it lists
#   - the archive is swapped atomically; an interrupted swap still restores
# ==============================================================================
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${SHM:-}" ] && rm -rf "$SHM"' EXIT

export DALVIK_CACHE_ROOT="$WORK/dalvik-cache"
ISA="arm64"
DC="$DALVIK_CACHE_ROOT/$ISA"
mkdir -p "$DC" "$WORK/bin" "$WORK/mod"

# ── Stubs: the compile path needs a dex2oat, getprop and pidof ────────────────
cat > "$WORK/bin/dex2oat64" <<'STUB'
#!/usr/bin/env bash
# Writes the requested oat file and its vdex; content is the dex-location so
# a restored artifact can be checked against what was compiled.
oat=""; loc=""
for a in "$@"; do
  case "$a" in
    --oat-file=*) oat="${a#--oat-file=}" ;;
    --dex-location=*) loc="${a#--dex-location=}" ;;
  esac
done
[ -n "$oat" ] || exit 1
printf 'oat:%s\n' "$loc" > "$oat"
printf 'vdex:%s\n' "$loc" > "${oat%.dex}.vdex"
exit 0
STUB
cat > "$WORK/bin/getprop" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in ro.bionic.arch) echo arm64 ;; *) echo "" ;; esac
STUB
cat > "$WORK/bin/pidof" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
for t in chcon restorecon; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/$t"
done
chmod 0755 "$WORK/bin"/*
PATH="$WORK/bin:$PATH"
export PATH

# shellcheck source=/dev/null
. "$DIR/module/common.sh"

FAILURES=0
# check <what> <expected> <actual>: prints PASS/FAIL and counts the failures.
check() {
    local what="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf '  [PASS] %s\n' "$what"
    else
        printf '  [FAIL] %s\n         expected %-12s got %s\n' "$what" "$expected" "$actual"
        FAILURES=$((FAILURES + 1))
    fi
}
# ino <path>: the inode number, or "none" when the path does not exist.
ino() { stat -c %i "$1" 2>/dev/null || echo "none"; }

echo "== AOT cache survival =="

# ── 1. compile_aot_cache publishes into dalvik-cache and archives the same set ─
mkdir -p "$WORK/fw/system/framework" "$WORK/fw/system_ext/framework" "$WORK/fw/apex/x/javalib"
STAGED_SVC="$WORK/mod/services.jar";      : > "$STAGED_SVC"
STAGED_MIUI="$WORK/mod/miui-services.jar"; : > "$STAGED_MIUI"
TARGET_SVC="$WORK/fw/system/framework/services.jar";          : > "$TARGET_SVC"
TARGET_MIUI="$WORK/fw/system_ext/framework/miui-services.jar"; : > "$TARGET_MIUI"
DOWNSTREAM="$WORK/fw/apex/x/javalib/service-x.jar";           : > "$DOWNSTREAM"
STANDALONE="$WORK/fw/apex/x/javalib/service-standalone.jar";  : > "$STANDALONE"
export SYSTEMSERVERCLASSPATH="$TARGET_SVC:$TARGET_MIUI:$DOWNSTREAM"
export STANDALONE_SYSTEMSERVER_JARS="$STANDALONE"
export BOOTCLASSPATH=""   # common.sh reads it unguarded; the device shell has no set -u

CACHE="$WORK/mod/cache"
compile_aot_cache "$STAGED_SVC" "$TARGET_SVC" "$STAGED_MIUI" "$TARGET_MIUI" "$CACHE"
check "compile_aot_cache succeeds against the stub" 0 "$?"

# name_of <jar path>: the dalvik-cache name ART derives from a jar location.
name_of() { echo "$1" | sed 's|^/||; s|/|@|g'; }
SVC_DEX="$DC/$(name_of "$TARGET_SVC")@classes.dex"
MIUI_DEX="$DC/$(name_of "$TARGET_MIUI")@classes.dex"
DOWN_DEX="$DC/$(name_of "$DOWNSTREAM")@classes.dex"
STAND_DEX="$DC/$(name_of "$STANDALONE")@classes.dex"

check "published artifacts in dalvik-cache" 8 "$(ls "$DC" | wc -l)"
check "manifest lists every published file" 8 "$(grep -c '' "$CACHE/$ISA/$AOT_CACHE_MANIFEST")"
check "manifest names match dalvik-cache" "$(ls "$DC" | sort)" "$(sort "$CACHE/$ISA/$AOT_CACHE_MANIFEST")"
check "archive is a hard link (same inode)" "$(ino "$SVC_DEX")" "$(ino "$CACHE/$ISA/$(basename "$SVC_DEX")")"
check "downstream artifact archived too"    "$(ino "$DOWN_DEX")" "$(ino "$CACHE/$ISA/$(basename "$DOWN_DEX")")"
check "standalone artifact archived too"    "$(ino "$STAND_DEX")" "$(ino "$CACHE/$ISA/$(basename "$STAND_DEX")")"

# ── 2. The nightly cleanup takes everything; restore puts it all back ────────
SVC_INO_BEFORE="$(ino "$SVC_DEX")"
rm -f "$DC"/*
check "cleanup emptied dalvik-cache" 0 "$(ls "$DC" | wc -l)"

check "restore reports every artifact" 8 "$(restore_aot_cache "$CACHE" "$ISA")"
check "dalvik-cache repopulated"       8 "$(ls "$DC" | wc -l)"
check "restored name is the original inode" "$SVC_INO_BEFORE" "$(ino "$SVC_DEX")"
check "restored content is what was compiled" "oat:$TARGET_MIUI" "$(cat "$MIUI_DEX")"
check "vdex restored alongside" "vdex:$TARGET_MIUI" "$(cat "${MIUI_DEX%.dex}.vdex")"

# ── 3. Idempotent, and a present name is never overwritten ───────────────────
check "second restore does nothing" 0 "$(restore_aot_cache "$CACHE" "$ISA")"
echo "someone else's" > "$DOWN_DEX.tmp" && mv -f "$DOWN_DEX.tmp" "$DOWN_DEX"
check "present name with foreign content stays" 0 "$(restore_aot_cache "$CACHE" "$ISA")"
check "foreign content untouched" "someone else's" "$(cat "$DOWN_DEX")"

# ── 4. Partial loss: only the missing names come back ────────────────────────
rm -f "$SVC_DEX" "${SVC_DEX%.dex}.vdex"
check "partial restore counts only the missing pair" 2 "$(restore_aot_cache "$CACHE" "$ISA")"
check "dalvik-cache complete again" 8 "$(ls "$DC" | wc -l)"

# ── 5. Cross-filesystem archive: copy fallback still restores ────────────────
SHM=""
if [ -d /dev/shm ] && [ -w /dev/shm ] && [ "$(stat -c %d /dev/shm)" != "$(stat -c %d "$WORK")" ]; then
    SHM="$(mktemp -d -p /dev/shm)"
    archive_aot_cache "$SHM/cache" "$ISA" "$SVC_DEX" "${SVC_DEX%.dex}.vdex"
    check "cross-fs archive falls back to a copy" 2 "$(grep -c '' "$SHM/cache/$ISA/$AOT_CACHE_MANIFEST")"
    check "copy is a different inode" 1 "$([ "$(ino "$SVC_DEX")" != "$(ino "$SHM/cache/$ISA/$(basename "$SVC_DEX")")" ] && echo 1 || echo 0)"
    rm -f "$SVC_DEX" "${SVC_DEX%.dex}.vdex"
    check "cross-fs restore copies back" 2 "$(restore_aot_cache "$SHM/cache" "$ISA")"
    check "copied content intact" "oat:$TARGET_SVC" "$(cat "$SVC_DEX")"
else
    echo "  [SKIP] cross-filesystem fallback: no second filesystem available here"
fi

# ── 6. A missing or empty manifest restores nothing, quietly ─────────────────
check "no manifest -> 0" 0 "$(restore_aot_cache "$WORK/nowhere" "$ISA")"

# ── 7. forget removes the archive and the names it listed ────────────────────
forget_aot_cache "$CACHE" "$ISA"
check "archive directory gone" 1 "$([ ! -d "$CACHE" ] && echo 1 || echo 0)"
check "dalvik-cache names gone" 0 "$(ls "$DC" | wc -l)"

# ── 8. compile without a cache dir archives nothing (old behaviour intact) ───
compile_aot_cache "$STAGED_SVC" "$TARGET_SVC" "$STAGED_MIUI" "$TARGET_MIUI"
check "compile without cache_dir still publishes" 8 "$(ls "$DC" | wc -l)"
check "and creates no archive" 1 "$([ ! -d "$CACHE" ] && echo 1 || echo 0)"
check "no archive requested, no warning" "" "${AOT_ARCHIVE_WARNING:-}"
check "a complete archive raises no warning either" "" "$(compile_aot_cache "$STAGED_SVC" "$TARGET_SVC" "$STAGED_MIUI" "$TARGET_MIUI" "$CACHE" >/dev/null; echo "$AOT_ARCHIVE_WARNING")"
rm -rf "$CACHE"

# ── 9. An archive that cannot be written is reported, and the compile stands ─
# Failing the compile would make the callers wipe a cache that works until the
# first cleanup; the right outcome is a working cache plus a loud warning that
# it will not survive the night.
BLOCKED="$WORK/blocked"
: > "$BLOCKED"                       # a file where the cache directory should go
compile_aot_cache "$STAGED_SVC" "$TARGET_SVC" "$STAGED_MIUI" "$TARGET_MIUI" "$BLOCKED/cache"
check "compile still succeeds when the archive cannot be created" 0 "$?"
check "artifacts are still published" 8 "$(ls "$DC" | wc -l)"
check "warning names the shortfall" "archived 0 of 8 artifacts under $BLOCKED/cache/$ISA" "$AOT_ARCHIVE_WARNING"
check "nothing to restore from a failed archive" 0 "$(restore_aot_cache "$BLOCKED/cache" "$ISA")"

# ── 10. The archive is replaced atomically, and an interrupted swap recovers ─
# archive_aot_cache builds <isa>.tmp.<pid>, writes the manifest last, moves the
# old archive to <isa>.old and renames the new one into place. Whatever the
# interruption leaves behind, restore must find a usable archive.
compile_aot_cache "$STAGED_SVC" "$TARGET_SVC" "$STAGED_MIUI" "$TARGET_MIUI" "$CACHE"
check "clean swap leaves no staging directory" 0 "$(ls -d "$CACHE/$ISA".tmp.* 2>/dev/null | wc -l)"
check "clean swap leaves no .old directory"    0 "$([ -d "$CACHE/$ISA.old" ] && echo 1 || echo 0)"
check "no partial manifest in the archive"     0 "$([ -e "$CACHE/$ISA/$AOT_CACHE_MANIFEST.part" ] && echo 1 || echo 0)"
# Rebuild over an existing archive: the previous inodes are replaced, nothing else is left.
OLD_INO="$(ino "$CACHE/$ISA/$(basename "$SVC_DEX")")"
compile_aot_cache "$STAGED_SVC" "$TARGET_SVC" "$STAGED_MIUI" "$TARGET_MIUI" "$CACHE"
check "rebuild over an existing archive succeeds" 8 "$(grep -c '' "$CACHE/$ISA/$AOT_CACHE_MANIFEST")"
check "rebuild replaced the archived inode" 1 "$([ "$OLD_INO" != "$(ino "$CACHE/$ISA/$(basename "$SVC_DEX")")" ] && echo 1 || echo 0)"
check "rebuild leaves no .old directory" 0 "$([ -d "$CACHE/$ISA.old" ] && echo 1 || echo 0)"

# (a) interrupted while staging: a half-built .tmp next to an intact archive
mkdir -p "$CACHE/$ISA.tmp.999"
echo junk > "$CACHE/$ISA.tmp.999/$(basename "$SVC_DEX")"
rm -f "$DC"/*
check "stale staging dir is ignored, intact archive restores" 8 "$(restore_aot_cache "$CACHE" "$ISA")"
check "stale staging dir is discarded" 0 "$(ls -d "$CACHE/$ISA".tmp.* 2>/dev/null | wc -l)"
check "restored content came from the real archive" "oat:$TARGET_SVC" "$(cat "$SVC_DEX")"

# (b) interrupted between the two renames: only <isa>.old exists
mv "$CACHE/$ISA" "$CACHE/$ISA.old"
rm -f "$DC"/*
check "archive recovered from .old" 8 "$(restore_aot_cache "$CACHE" "$ISA")"
check ".old renamed back into place" 1 "$([ -s "$CACHE/$ISA/$AOT_CACHE_MANIFEST" ] && [ ! -d "$CACHE/$ISA.old" ] && echo 1 || echo 0)"
check "dalvik-cache complete after recovery" 8 "$(ls "$DC" | wc -l)"

# (c) a leftover .old next to a complete archive is simply dropped
mkdir -p "$CACHE/$ISA.old"; echo stale > "$CACHE/$ISA.old/$AOT_CACHE_MANIFEST"
check "complete archive wins over a leftover .old" 0 "$(restore_aot_cache "$CACHE" "$ISA")"
check "leftover .old removed" 0 "$([ -d "$CACHE/$ISA.old" ] && echo 1 || echo 0)"

# ── 11. Every recorded path counts towards the expected total ────────────────
# A publish that lost its vdex must show up as a shortfall; skipping missing
# paths on both sides of the tally would hide it.
archive_aot_cache "$CACHE" "$ISA" "$SVC_DEX" "${SVC_DEX%.dex}.vdex" "$DC/never-published@classes.vdex"
check "missing recorded path is a shortfall" 1 "$?"
check "expected counts every recorded path" 3 "$AOT_ARCHIVE_EXPECTED"
check "archived counts only what exists" 2 "$AOT_ARCHIVED"

# ── 12. Recovery keeps .old until a complete archive is in place ─────────────
compile_aot_cache "$STAGED_SVC" "$TARGET_SVC" "$STAGED_MIUI" "$TARGET_MIUI" "$CACHE"
mv "$CACHE/$ISA" "$CACHE/$ISA.old"
mkdir -p "$CACHE/$ISA"                          # canonical exists but has no manifest
rm -f "$DC"/*
check "manifest-less canonical dir is replaced by .old" 8 "$(restore_aot_cache "$CACHE" "$ISA")"
check ".old consumed after successful recovery" 0 "$([ -d "$CACHE/$ISA.old" ] && echo 1 || echo 0)"
# An .old that is itself unusable is left alone rather than deleted on a guess.
rm -rf "$CACHE/$ISA"
mkdir -p "$CACHE/$ISA.old"; : > "$CACHE/$ISA.old/$AOT_CACHE_MANIFEST"
check "nothing restorable -> 0" 0 "$(restore_aot_cache "$CACHE" "$ISA")"
check "unusable .old is not deleted when nothing replaces it" 1 "$([ -d "$CACHE/$ISA.old" ] && echo 1 || echo 0)"
rm -rf "$CACHE"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "AOT cache survival tests PASSED"
    exit 0
fi
echo "AOT cache survival tests FAILED ($FAILURES)"
exit 1
