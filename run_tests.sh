#!/usr/bin/env bash
# Amiga Retroplay - automated test suite
#
# Runs the real scripts end to end against a mock Retroplay "server" (a local
# folder), with mock archive tools, wget and curl - no network, no real
# archives, nothing outside a temporary folder is touched. Works with
# macOS's stock bash 3.2 as well as Linux (merge.sh itself needs bash 4+;
# on macOS install it with: brew install bash).
#
#   tests/run_tests.sh            run everything
#   tests/run_tests.sh -v         also show each script's output
#
# Exit status: 0 if every test passed, 1 otherwise.

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1
PASS=0; FAIL=0; FAILED_NAMES=""

ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES
  - $1"; printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/retroplay_tests.XXXXXX")"
trap 'rm -rf "$T"' EXIT
ROOT="$T/retroplay"; SERVER="$T/server"; MOCK="$T/mockbin"
mkdir -p "$ROOT" "$SERVER" "$MOCK"
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
cp "$REPO"/*.sh "$ROOT"/
chmod +x "$ROOT"/*.sh

# ---------------------------------------------------------------- mocks ---
# Archive tools: "extract" an archive into the current folder as
# <Name>/ + <Name>.info, where <Name> is the archive name without its
# version field - so two versions of a game extract to the SAME folder, just
# like real Retroplay archives. Each call is logged; an archive whose name
# contains the text in $MOCK/fail_pattern fails.
cat > "$MOCK/lha" << 'EOF'
#!/usr/bin/env bash
arc=""; for a in "$@"; do case "$a" in *.lha|*.LHA|*.lzx|*.zip) arc="$a";; esac; done
[ -n "$arc" ] || exit 0
stem="${arc##*/}"; stem="${stem%.*}"
pat="$(cat "$(dirname "$0")/fail_pattern" 2>/dev/null)"
[ -n "$pat" ] && case "$stem" in *"$pat"*) exit 1;; esac
slow="$(cat "$(dirname "$0")/slow_pattern" 2>/dev/null)"
[ -n "$slow" ] && case "$stem" in *"$slow"*) sleep 8;; esac
echo "$stem" >> "$(dirname "$0")/extract_calls"
IFS=_ read -r -a f <<< "$stem"; name=""; ver=""
for t in "${f[@]}"; do case "$t" in v[0-9]*) ver="$t";; *) name="${name:+${name}_}$t";; esac; done
mkdir -p "$name"; echo "$stem" > "$name/$ver.txt"; touch "$name.info"
EOF
for t in 7z unar unlzx; do cp "$MOCK/lha" "$MOCK/$t"; done
# wget: "mirrors" the matching mock-server folder into the current folder
# (copies anything not present locally) and logs that it was called.
ROOT_P="$(cd "$ROOT" && pwd -P)"   # physical path (e.g. macOS /var -> /private/var)
cat > "$MOCK/wget" << EOF
#!/usr/bin/env bash
echo called >> "$MOCK/wget_calls"
rel="\$(pwd -P)"; rel="\${rel#$ROOT_P/}"
[ -d "$SERVER/\$rel" ] || exit 0
( cd "$SERVER/\$rel" && find . -type f ) | while IFS= read -r f; do
    [ -e "\$f" ] || { mkdir -p "\$(dirname "\$f")"; cp "$SERVER/\$rel/\$f" "\$f"; }
done
exit 0
EOF
# curl: records notifications; returns an empty listing for --dry-run.
cat > "$MOCK/curl" << EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "-d" ] && { echo "notify \$*" >> "$MOCK/notifications"; exit 0; }; done
exit 0
EOF
cat > "$MOCK/crontab" << EOF
#!/usr/bin/env bash
case "\$1" in -l) cat "$T/crontab.txt" 2>/dev/null ;; -) cat > "$T/crontab.txt" ;; esac
EOF
printf '#!/bin/sh\n[ "$1" = "-a" ] && printf "C.UTF-8\\nC.utf8\\nen_US.ISO-8859-1\\nen_US.iso88591\\n"\nexit 0\n' > "$MOCK/locale"
printf '#!/bin/sh\n[ "$1" = "-V" ] && echo "detox 3.0.1"\nexit 0\n' > "$MOCK/detox"
chmod +x "$MOCK"/*
export PATH="$MOCK:$PATH"

# Run every script with the SAME bash that is running this test suite, so
# "/bin/bash tests/run_tests.sh" on a Mac really tests macOS's bash 3.2
# (the scripts start with "#!/usr/bin/env bash", which would otherwise pick
# up Homebrew's newer bash). merge.sh relaunches itself under bash 4+ on
# its own, exactly as it does on a real Mac.
mkdir -p "$T/thisbash"; ln -sf "$BASH" "$T/thisbash/bash"; export PATH="$T/thisbash:$PATH"
echo "Testing with bash $BASH_VERSION ($BASH)"

# -------------------------------------------------------------- fixtures ---
server_add() { mkdir -p "$SERVER/$(dirname "$1")"; echo "archive $1" > "$SERVER/$1"; }
art() {   # art <SET> <Section> <Game>
    mkdir -p "$ROOT/iGame_$1/$2/Games/${3:0:1}/$3"
    echo "$1-$3" > "$ROOT/iGame_$1/$2/Games/${3:0:1}/$3/iGame.iff"
    echo "$1-$3-data" > "$ROOT/iGame_$1/$2/Games/${3:0:1}/$3/iGame.data"
}
for s in AGA ECS RTG; do for g in Alpha Gamma_De Rise Rise_AGA Zool_AGA Beta; do art "$s" Covers "$g"; done; done
mkdir -p "$ROOT/iGame_art"
cat > "$ROOT/retroplay.conf" << 'EOF'
NTFY_TOPIC=retroplay-test
KEEP_NEW_BATCHES=3
MIN_FREE_MB=1
EOF

run() {   # run <logname> <command...>  (from ROOT; output to log; returns exit status)
    local log="$T/$1.log"; shift
    ( cd "$ROOT" && "$@" ) < /dev/null > "$log" 2>&1
    local st=$?
    [ "$VERBOSE" -eq 1 ] && sed 's/^/      | /' "$log"
    return "$st"
}
calls_for() { grep -c "^$1\$" "$MOCK/extract_calls" 2>/dev/null || true; }
art_in() { cat "$ROOT/$1"/iGame.iff "$ROOT/$1"/igame1.iff 2>/dev/null | head -1; }
game() { find "$ROOT/$1" -type d -name "$2" 2>/dev/null | head -1; }

# ================================================================= tests ===
section "lib.sh: version-aware archive matching (the pruning rules)"
SCRIPT_DIR="$ROOT"; . "$ROOT/lib.sh"
k() { rp_archive_version_key "$1" | cut -d'|' -f1; }
check "AGA / CD32 / plain releases of one game are different files" \
  '[ "$(k RiseOfTheRobots_v1.1_AGA_HD_JOTD_1763.lha)" != "$(k RiseOfTheRobots_v1.1_CD32_HD_JOTD.lha)" ] && [ "$(k RiseOfTheRobots_v1.1_CD32_HD_JOTD.lha)" != "$(k RiseOfTheRobots_v1.1_HD_JOTD_1365.lha)" ]'
check "68040 and non-68040 builds are different files" \
  '[ "$(k OutRunAmigaEdition_v0.9.3_AGA_HD_68040_Reassembler.lha)" != "$(k OutRunAmigaEdition_v0.9.3_AGA_HD_Reassembler.lha)" ]'
check "a real version bump matches" '[ "$(k X_v1.1_AGA_1763.lha)" = "$(k X_v1.2_AGA_1763.lha)" ]'
check "1.10 > 1.9 > 1.1, and 1.11 > 1.10" \
  '[ "$(rp_version_cmp 1.10 1.9)" = 1 ] && [ "$(rp_version_cmp 1.9 1.1)" = 1 ] && [ "$(rp_version_cmp 1.11 1.10)" = 1 ]'
check "1.1.1 > 1.1 and 1.01a > 1.01" '[ "$(rp_version_cmp 1.1.1 1.1)" = 1 ] && [ "$(rp_version_cmp 1.01a 1.01)" = 1 ]'
check "AGA tag matches whole fields only (Agamemnon is not AGA)" \
  'rp_archive_has_tag Rise_v1_AGA_HD.lha AGA,CD32 && ! rp_archive_has_tag Agamemnon_v1.0.lha AGA,CD32'

section "1. First run: full build of AGA, ECS and RTG"
for a in WHDLoad/Games/A/Alpha_v1.0.lha WHDLoad/Games/G/Gamma_v1.0_De.lha WHDLoad/Games/B/Beta_v1.0.lha \
         HD_Loaders/Games/R/Rise_v1.1_AGA_HD.lha HD_Loaders/Games/R/Rise_v1.1_CD32_HD.lha HD_Loaders/Games/R/Rise_v1.1_HD.lha; do
    server_add "$a"; done
run first ./all.sh; st=$?
check "all.sh exits 0" '[ "$st" -eq 0 ]'
check "every archive extracted exactly once (6 archives, 6 extractions)" \
  '[ "$(grep -c . "$MOCK/extract_calls")" -eq 6 ] && [ "$(sort "$MOCK/extract_calls" | uniq -d | grep -c .)" -eq 0 ]'
check "retro_ecs has NO AGA or CD32 releases" '[ -z "$(game retro_ecs Rise_AGA_HD)" ] && [ -z "$(game retro_ecs Rise_CD32_HD)" ]'
check "retro_ecs still has the plain release" '[ -n "$(game retro_ecs Rise_HD)" ]'
check "retro_aga and retro_rtg DO have the AGA and CD32 releases" \
  '[ -n "$(game retro_aga Rise_AGA_HD)" ] && [ -n "$(game retro_aga Rise_CD32_HD)" ] && [ -n "$(game retro_rtg Rise_AGA_HD)" ]'
check "each variant got its own artwork" \
  '[ "$(art_in retro_aga/WHDLoad/Games/A/Alpha)" = AGA-Alpha ] && [ "$(art_in retro_ecs/WHDLoad/Games/A/Alpha)" = ECS-Alpha ] && [ "$(art_in retro_rtg/WHDLoad/Games/A/Alpha)" = RTG-Alpha ]'
g="$(game retro_aga Gamma_De)"
check "German release sorted into Languages/ BEFORE merge, and still got artwork" \
  'case "$g" in */Languages/German/*) [ "$(art_in "${g#$ROOT/}")" = AGA-Gamma_De ];; *) false;; esac'
check "all three builds marked complete" '[ -f "$ROOT/.retroplay/complete/retro_aga" ] && [ -f "$ROOT/.retroplay/complete/retro_ecs" ] && [ -f "$ROOT/.retroplay/complete/retro_rtg" ]'
check "a run report was written" '[ -n "$(ls "$ROOT"/reports/*.txt 2>/dev/null)" ]'

section "2. Update: new version of a game + an HD_Loaders-only download"
: > "$MOCK/extract_calls"
server_add WHDLoad/Games/A/Alpha_v1.1.lha
server_add HD_Loaders/Games/H/Hdgame_v1.0.lha
run update ./all.sh; st=$?
check "all.sh exits 0" '[ "$st" -eq 0 ]'
check "superseded Alpha_v1.0 quarantined in old/, not deleted" \
  '[ -n "$(find "$ROOT/old" -name Alpha_v1.0.lha)" ] && [ ! -e "$ROOT/WHDLoad/Games/A/Alpha_v1.0.lha" ]'
check "new batch extracted once for all variants (2 archives, 2 extractions)" '[ "$(grep -c . "$MOCK/extract_calls")" -eq 2 ]'
check "old version's files replaced, not left behind" \
  '[ -f "$ROOT/retro_aga/WHDLoad/Games/A/Alpha/v1.1.txt" ] && [ ! -e "$ROOT/retro_aga/WHDLoad/Games/A/Alpha/v1.0.txt" ]'
check "updated game still has its artwork" '[ "$(art_in retro_ecs/WHDLoad/Games/A/Alpha)" = ECS-Alpha ]'
check "HD_Loaders-only content handled (no 'No WHDLoad directory' failure)" '[ -n "$(game retro_rtg Hdgame)" ]'
check "dated batch folder kept in new_aga/" '[ "$(find "$ROOT/new_aga" -mindepth 1 -maxdepth 1 -type d | grep -c .)" -eq 1 ]'
check "queues emptied after success" '[ -z "$(ls "$ROOT/.retroplay/queue/" 2>/dev/null)" ]'

section "3. AGA-only update is left out of ECS"
server_add WHDLoad/Games/Z/Zool_v1.0_AGA.lha
run agaonly ./all.sh; st=$?
check "all.sh exits 0" '[ "$st" -eq 0 ]'
check "retro_aga and retro_rtg got Zool_AGA" '[ -n "$(game retro_aga Zool_AGA)" ] && [ -n "$(game retro_rtg Zool_AGA)" ]'
check "retro_ecs did not" '[ -z "$(game retro_ecs Zool_AGA)" ]'
check "ECS queue still cleared (nothing left pending forever)" '[ ! -e "$ROOT/.retroplay/queue/retro_ecs.list" ]'

section "4. Nothing new"
run nothing ./all.sh; st=$?
check "exit code 2 when there's nothing to do" '[ "$st" -eq 2 ]'

section "5. A failed run is picked up again by the next one"
: > "$MOCK/notifications"
echo Broken > "$MOCK/fail_pattern"
server_add WHDLoad/Games/B/Broken_v1.0.lha
run failing ./all.sh; st=$?
check "failure reported with exit 1" '[ "$st" -eq 1 ]'
check "the download stays queued" 'grep -q Broken "$ROOT/.retroplay/queue/retro_aga.list" 2>/dev/null'
check "a failure notification was sent" 'grep -q "FAILED" "$MOCK/notifications" 2>/dev/null || grep -q "retroplay-test" "$MOCK/notifications" 2>/dev/null'
rm -f "$MOCK/fail_pattern"
run recover ./all.sh; st=$?
check "next run (nothing new on the server) still processes it" '[ "$st" -eq 0 ] && [ -n "$(game retro_aga Broken)" ]'
check "and then clears the queue" '[ ! -e "$ROOT/.retroplay/queue/retro_aga.list" ]'

section "6. An interrupted full build is redone, not mistaken for finished"
echo "$ROOT/retro_rtg" > "$ROOT/.retroplay/building/retro_rtg"
rm -rf "$ROOT/retro_rtg/WHDLoad/Games/B"
run resume ./all.sh --skip-update; st=$?
check "rtg rebuilt in full (exit 0)" '[ "$st" -eq 0 ] && [ -n "$(game retro_rtg Beta)" ]'
check "marked complete again" '[ ! -e "$ROOT/.retroplay/building/retro_rtg" ] && [ -f "$ROOT/.retroplay/complete/retro_rtg" ]'

section "7. --rebuild (via ecs.sh) skips the update and rebuilds only ECS"
: > "$MOCK/wget_calls"
touch "$ROOT/retro_ecs/SENTINEL" "$ROOT/retro_aga/SENTINEL"
run rebuild ./ecs.sh --rebuild; st=$?
check "exit 0" '[ "$st" -eq 0 ]'
check "update skipped (wget never called)" '[ ! -s "$MOCK/wget_calls" ]'
check "retro_ecs rebuilt from scratch" '[ ! -e "$ROOT/retro_ecs/SENTINEL" ] && [ -n "$(game retro_ecs Alpha)" ]'
check "retro_ecs still without AGA/CD32" '[ -z "$(game retro_ecs Zool_AGA)" ] && [ -z "$(game retro_ecs Rise_AGA_HD)" ]'
check "retro_aga untouched" '[ -e "$ROOT/retro_aga/SENTINEL" ]'
: > "$MOCK/wget_calls"
run rebuild_all ./all.sh --rebuild --variants aga; st=$?
check "all.sh --rebuild works too, without updating" '[ "$st" -eq 0 ] && [ ! -s "$MOCK/wget_calls" ] && [ ! -e "$ROOT/retro_aga/SENTINEL" ]'
: > "$MOCK/wget_calls"
( cd "$ROOT" && printf '7\n' | ./start.sh --rtg ) > "$T/menu7.log" 2>&1; st=$?
check "start.sh menu option 7 = rebuild without update" '[ "$st" -eq 0 ] && [ ! -s "$MOCK/wget_calls" ]'

section "8. --dry-run changes nothing"
server_add WHDLoad/Games/D/Delta_v1.0.lha
snap() { ( cd "$ROOT" && find . -path ./reports -prune -o -print | sort; cat .retroplay/queue/* 2>/dev/null ) | cksum; }
before="$(snap)"
run dryrun ./all.sh --dry-run --skip-update; st=$?
check "dry run exits 0 and shows the plan" '[ "$st" -eq 0 ] && grep -q "Plan" "$T/dryrun.log"'
check "nothing on disk changed" '[ "$(snap)" = "$before" ]'

section "9. Not enough disk space: stops safely"
echo "MIN_FREE_MB=99999999" >> "$ROOT/retroplay.conf"
run nospace ./all.sh; st=$?
check "exit 1 with a clear message" '[ "$st" -eq 1 ] && grep -q "not enough" "$T/nospace.log"'
check "collection untouched and download still queued" \
  '[ -n "$(game retro_aga Alpha)" ] && grep -q Delta "$ROOT/.retroplay/queue/retro_aga.list"'
sed -i.bak '/MIN_FREE_MB=99999999/d' "$ROOT/retroplay.conf"

section "10. Scripts work when run from another directory"
( cd / && "$ROOT/aga.sh" --skip-update ) < /dev/null > "$T/elsewhere.log" 2>&1; st=$?
check "aga.sh from / processes the queued Delta (exit 0)" '[ "$st" -eq 0 ] && [ -n "$(game retro_aga Delta)" ]'

section "11. Overlapping runs are refused"
FLOCK="$(command -v flock 2>/dev/null)"
if [ -z "$FLOCK" ] && command -v brew >/dev/null 2>&1; then   # macOS: keg-only util-linux
    p="$(brew --prefix util-linux 2>/dev/null)"; [ -x "$p/bin/flock" ] && FLOCK="$p/bin/flock"
fi
if [ -n "$FLOCK" ]; then
    ( exec 9>"$ROOT/.all.lock"; "$FLOCK" 9; sleep 4 ) & holder=$!
    sleep 1
    run locked ./all.sh --skip-update; st=$?
    wait "$holder"
    check "second instance exits 1 while the first holds the lock" '[ "$st" -eq 1 ] && grep -q "already running" "$T/locked.log"'
else
    echo "  (skipped: flock not installed)"
fi


section "12. Nightly (cron) run finds tools despite cron's minimal PATH"
# A stand-in for the system folders cron sees: everything in /usr/bin and
# /bin EXCEPT the archive tools, which here live only in the mock folder -
# like unlzx living in ~/bin or /usr/local/bin on a real system.
SYSBIN="$T/sysbin"; mkdir -p "$SYSBIN"
for d in /usr/bin /bin; do
    for f in "$d"/*; do
        n="${f##*/}"
        case "$n" in lha|7z|7za|unar|lsar|unlzx|wget|detox|locale|crontab) continue ;; esac
        [ -e "$SYSBIN/$n" ] || ln -s "$f" "$SYSBIN/$n"
    done
done
cp "$MOCK/locale" "$SYSBIN/locale"
cronrun() {
    rm -f "$ROOT/all_cron.log"
    ( cd "$ROOT" && env -i HOME="$T/home" TMPDIR="$TMPDIR" PATH="$SYSBIN" \
        bash ./all.sh --cron --skip-update --force --variants aga ) < /dev/null > /dev/null 2>&1
}
rm -f "$ROOT/.retroplay/user_path"
cronrun; st=$?
check "control: with nothing remembered, cron can't find the tools (exit 1)" \
  '[ "$st" -eq 1 ] && grep -q "Still missing" "$ROOT/all_cron.log"'
check "...and the log explains why and how to fix it" 'grep -q "unattended run" "$ROOT/all_cron.log"'
run installcron ./install_cron.sh; st=$?
check "install_cron.sh installs the --cron entry and remembers this PATH" \
  '[ "$st" -eq 0 ] && grep -q -- "all.sh --cron" "$T/crontab.txt" && [ -s "$ROOT/.retroplay/user_path" ]'
cronrun; st=$?
check "the cron run now finds every tool and succeeds" '[ "$st" -eq 0 ] && ! grep -q "Still missing" "$ROOT/all_cron.log"'

section "13. Temporary folders are always cleaned up"
check "no extract_tmp.* left behind by any run above" '[ -z "$(find "$ROOT" -name "extract_tmp.*")" ]'
check "no sort.sh or quick.sh temp folders left" \
  '[ -z "$(find "$TMPDIR" -name "sort_compliance.*")" ] && [ ! -e "$ROOT/.temp_new_archives" ]'
check "no engine work/staging folders left" '[ ! -e "$ROOT/.retroplay_work" ] && [ ! -e "$ROOT/.retroplay/stage" ]'
echo SlowGame > "$MOCK/slow_pattern"
mkdir -p "$ROOT/WHDLoad/Games/S"; echo x > "$ROOT/WHDLoad/Games/S/SlowGame_v1.0.lha"
( cd "$ROOT" && exec bash ./extract.sh -u -d "$T/intr_out" ) < /dev/null > "$T/intr.log" 2>&1 &
xp=$!
sleep 3
kill -TERM "$xp" 2>/dev/null; wait "$xp" 2>/dev/null
check "extract.sh stopped mid-extraction still removes its temp folder" \
  '[ -z "$(find "$ROOT" -maxdepth 1 -name "extract_tmp.*")" ]'
rm -f "$MOCK/slow_pattern" "$ROOT/WHDLoad/Games/S/SlowGame_v1.0.lha"
sh -c 'exit 0' & deadpid=$!; wait "$deadpid"
mkdir -p "$ROOT/extract_tmp.dead" "$ROOT/extract_tmp.legacy" "$ROOT/extract_tmp.live"
echo "$deadpid" > "$ROOT/extract_tmp.dead/.owner_pid"; echo "$$" > "$ROOT/extract_tmp.live/.owner_pid"
run sweep bash ./extract.sh -u -d "$T/sweep_out"
check "leftovers from killed runs are swept up on the next run" \
  '[ ! -e "$ROOT/extract_tmp.dead" ] && [ ! -e "$ROOT/extract_tmp.legacy" ]'
check "a temp folder whose run is still going is left alone" '[ -d "$ROOT/extract_tmp.live" ]'
rm -rf "$ROOT/extract_tmp.live"


section "14. Folder layout stays retro_x/WHDLoad/... when paths are spelled differently"
# Reaching the folder through a symlink makes the working directory and the
# resolved paths differ - the same situation as macOS's ~/downloads vs
# ~/Downloads, which used to recreate Users/<you>/Downloads/Amiga/... inside
# retro_* and new_*.
ln -s "$ROOT" "$T/linkedroot"
layout_ok() {   # only WHDLoad / HD_Loaders / JST at the top of $1
    local e; for e in "$1"/*; do case "${e##*/}" in WHDLoad|HD_Loaders|JST) ;; *) return 1 ;; esac; done; return 0
}
( cd "$T/linkedroot" && ./all.sh --rebuild --variants aga ) < /dev/null > "$T/linked_full.log" 2>&1; st=$?
check "full build via a differently-spelled path succeeds" '[ "$st" -eq 0 ]'
check "retro_aga holds only WHDLoad/HD_Loaders/JST at the top" 'layout_ok "$ROOT/retro_aga"'
check "games are in retro_aga/WHDLoad/..., not under a copied absolute path" \
  '[ -d "$ROOT/retro_aga/WHDLoad/Games/A/Alpha" ] && ! (cd "$ROOT/retro_aga" && find . | grep -qF "${T#/}")'
server_add WHDLoad/Games/E/Epsilon_v1.0.lha
( cd "$T/linkedroot" && ./all.sh --variants aga ) < /dev/null > "$T/linked_inc.log" 2>&1; st=$?
latest="$(ls -1d "$ROOT"/new_aga/*/ 2>/dev/null | sort | tail -1)"
check "update via that path: new_aga batch has the right layout too" \
  '[ "$st" -eq 0 ] && layout_ok "${latest%/}" && [ -d "${latest}WHDLoad/Games/E/Epsilon" ]'
mkdir -p "$T/ext/WHDLoad/Games/A" "$T/proj2"; echo x > "$T/ext/WHDLoad/Games/A/Alpha_v1.0.lha"
cp "$ROOT/extract.sh" "$ROOT/lib.sh" "$T/proj2/"; ln -s "$T/ext/WHDLoad" "$T/proj2/WHDLoad"
( cd "$T/proj2" && bash ./extract.sh -u -d "$T/ext_out" ) < /dev/null > "$T/ext.log" 2>&1
check "WHDLoad symlinked to another drive extracts into dest/WHDLoad/..." \
  'layout_ok "$T/ext_out" && [ -d "$T/ext_out/WHDLoad/Games/A/Alpha" ]'
mkdir -p "$ROOT/retro_ecs/Users/someone"
run doctor_layout ./doctor.sh; st=$?
check "doctor.sh spots a folder in the wrong place and explains the fix" \
  '[ "$st" -eq 1 ] && grep -q "retro_ecs/Users" "$T/doctor_layout.log" && grep -q -- "--rebuild" "$T/doctor_layout.log"'
rm -rf "$ROOT/retro_ecs/Users"


section "15. iGame_art and other packs match a game folder anywhere inside them"
M="$T/anyart"; mkdir -p "$M"; cp "$ROOT/merge.sh" "$ROOT/lib.sh" "$M/"
mkart() { mkdir -p "$M/$1"; echo "$2" > "$M/$1/iGame.iff"; }
mkart "iGame_art/Misc/Some/Deep/Omega" "art-Omega"                 # no section in its path
mkart "iGame_art/Odd/Titles/X/Lambda" "art-Lambda-title"           # section revealed by the path
mkart "iGame_art/Covers/Games/M/Mu" "art-Mu-standard"              # standard location...
mkart "iGame_art/Misc/Mu" "art-Mu-stray"                           # ...beats a stray duplicate
mkart "iGame_AGA/Extras/Zeta" "aga-Zeta-nonstandard"               # AGA must NOT be searched this way
mkart "iGame_CD32/foo/bar/Kappa" "cd32-Kappa"                      # custom pack, any depth
mkdir -p "$M/iGame_AGA/Covers/Games/A/Anchor"; echo "aga-Anchor" > "$M/iGame_AGA/Covers/Games/A/Anchor/iGame.iff"
for g in Omega Lambda Mu Zeta Kappa Anchor; do
    mkdir -p "$M/retro/WHDLoad/Games/${g:0:1}/$g"; touch "$M/retro/WHDLoad/Games/${g:0:1}/$g.info"; done
( cd "$M" && bash merge.sh --aga --art Covers,Screens,Titles -d retro ) > "$T/anyart.log" 2>&1
g() { cat "$M/retro/WHDLoad/Games/${1:0:1}/$1/$2" 2>/dev/null; }
check "a game found only deep inside iGame_art gets that artwork" '[ "$(g Omega iGame.iff)" = art-Omega ]'
check "a Titles folder anywhere in the path keeps Titles priority (igame2.iff)" '[ "$(g Lambda igame2.iff)" = art-Lambda-title ]'
check "a custom pack (iGame_CD32) is searched at any depth too" '[ "$(g Kappa iGame.iff)" = cd32-Kappa ]'
check "the standard layout still wins over a stray copy elsewhere in the pack" '[ "$(g Mu iGame.iff)" = art-Mu-standard ]'
check "iGame_AGA is NOT searched outside its standard layout (unchanged)" '[ -z "$(ls "$M/retro/WHDLoad/Games/Z/Zeta/" 2>/dev/null)" ]'
check "iGame_AGA's standard layout works as before" '[ "$(g Anchor iGame.iff)" = aga-Anchor ]'
rm -f "$M"/retro/WHDLoad/Games/*/*/igame*.iff "$M"/retro/WHDLoad/Games/*/*/iGame.iff
echo 'STRUCTURED_ART_SETS="AGA ECS RTG ART"' > "$M/retroplay.conf"
( cd "$M" && bash merge.sh --aga -d retro ) > "$T/anyart2.log" 2>&1
check "STRUCTURED_ART_SETS in retroplay.conf can switch this off per pack" \
  '[ -z "$(g Omega iGame.iff)" ] && [ "$(g Kappa iGame.iff)" = cd32-Kappa ]'

# ================================================================ summary ===
echo
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32mAll %d tests passed.\033[0m\n' "$PASS"
    exit 0
fi
printf '\033[31m%d of %d tests failed:\033[0m%s\n' "$FAIL" $((PASS + FAIL)) "$FAILED_NAMES"
echo "Re-run with -v to see each script's output."
exit 1
