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
# Works from tests/ (the documented location) or from the project root.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$HERE/all.sh" ]; then REPO="$HERE"; else REPO="$(cd "$HERE/.." && pwd)"; fi
if [ ! -f "$REPO/all.sh" ] || [ ! -f "$REPO/lib.sh" ]; then
    echo "ERROR: can't find the scripts (all.sh and lib.sh) next to this test runner or one folder up." >&2
    echo "       Run it from a complete checkout: tests/run_tests.sh" >&2
    exit 2
fi
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1
PASS=0; FAIL=0; FAILED_NAMES=""

ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES
  - $1"; printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# Fixture setup: a failure here is a broken test environment, not a failed
# test - stop immediately with a clear setup error.
setup() { "$@" || { echo "SETUP ERROR (test fixture could not be created): $*" >&2; exit 3; }; }
section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/retroplay_tests.XXXXXX")"
trap 'rm -rf "$T"' EXIT
ROOT="$T/retroplay"; SERVER="$T/server"; MOCK="$T/mockbin"
mkdir -p "$ROOT" "$SERVER" "$MOCK"
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
export RP_RETRY_WAIT=0          # no pauses between download retries in tests
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
arc=""; for a in "$@"; do case "$a" in *.lha|*.LHA|*.lzx|*.zip|*.part) arc="$a";; esac; done
[ -n "$arc" ] || exit 0
# "lha t <archive>" = integrity test: fails only for archives marked CORRUPT
if [ "${1:-}" = "t" ]; then grep -q CORRUPT "$arc" 2>/dev/null && exit 1; exit 0; fi
case "${arc##*/}" in
    [Ii][Gg]ame_*.lha|TinyLauncher.lha)
        layout="$(sed -n 1p "$arc")"; pack="$(sed -n 2p "$arc")"; pack="${pack%.lha}"
        case "$layout" in
            # one wrapping folder named like the archive, holding the categories
            A) mkdir -p "$pack/Games/A"; echo "$pack art" > "$pack/Games/A/iGame.iff" ;;
            # category folders straight at the top
            B) mkdir -p Games/A Demos/B; echo "$pack art" > Games/A/iGame.iff; echo d > Demos/B/iGame.iff ;;
            BAD) mkdir -p RandomStuff; echo x > RandomStuff/file ;;
            CORRUPT) exit 1 ;;
        esac
        exit 0 ;;
esac
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
rel="\$(pwd -P)"; rel="\${rel#$ROOT_P/}"; rel="\${rel#downloads/}"
[ -d "$SERVER/\$rel" ] || exit 0
log=""; prev=""; for a in "\$@"; do case "\$prev" in -a|-o) log="\$a";; esac; prev="\$a"; done
( cd "$SERVER/\$rel" && find . -type f ) | while IFS= read -r f; do
    f="\${f#./}"
    # new, or re-published on the server (content differs): download it
    if [ ! -e "\$f" ] || ! cmp -s "$SERVER/\$rel/\$f" "\$f"; then
        mkdir -p "\$(dirname "\$f")"
        pp="\$(cat "$MOCK/partial_pattern" 2>/dev/null)"
        # simulated interrupted transfer: a truncated file, no "->" log line
        if [ -n "\$pp" ]; then case "\$f" in *"\$pp"*) head -c 3 "$SERVER/\$rel/\$f" > "\$f"; touch "$MOCK/.interrupted"; continue ;; esac; fi
        cp "$SERVER/\$rel/\$f" "\$f"
        # simulated corrupt download - only the FIRST time this file is fetched
        cp_pat="\$(cat "$MOCK/corrupt_once" 2>/dev/null)"
        if [ -n "\$cp_pat" ] && [ ! -e "$MOCK/.corrupted_\${f##*/}" ]; then
            case "\$f" in *"\$cp_pat"*) echo CORRUPT > "\$f"; touch "$MOCK/.corrupted_\${f##*/}" ;; esac
        fi
        [ -e "$MOCK/nolog" ] && continue      # simulate an unreadable wget log
        [ -n "\$log" ] && echo "2026-01-01 00:00:00 URL: ftp://mock/\$f [1] -> \"\$f\" [1]" >> "\$log"
    fi
done
# (the loop above runs in a subshell, so its result is passed back via a file)
if [ -e "$MOCK/.interrupted" ]; then rm -f "$MOCK/.interrupted"; exit 4; fi
exit "\$(cat "$MOCK/wget_exit" 2>/dev/null || echo 0)"
EOF
# curl: records notifications; returns an empty listing for --dry-run.
ARTSRC="$T/artsrc"; mkdir -p "$ARTSRC"
# Mock artwork source using the real published names. Each "archive" is a
# text file: line 1 = internal layout (A = one wrapping folder, B = category
# folders at the top, BAD = unexpected, CORRUPT = fails its check), line 2 =
# the archive name.
art_archive() { printf '%s\n%s\n' "$2" "$1" > "$ARTSRC/$1"; }
for sec in Covers Screens Titles; do
    art_archive "IGame_${sec}_AGA_Laced.lha" A
    art_archive "IGame_${sec}_AGA_LoRes.lha" B
    art_archive "IGame_${sec}_ECS_Laced.lha" A
    art_archive "IGame_${sec}_ECS_LoRes.lha" B
    art_archive "IGame_${sec}_RTG.lha" A
done
art_archive TinyLauncher.lha B
echo "notes" > "$ARTSRC/README.txt"
echo "A" > "$ARTSRC/unrelated.lha"
echo "zip" > "$ARTSRC/ignored.zip"
cat > "$MOCK/curl" << EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "-d" ] && { echo "notify \$*" >> "$MOCK/notifications"; exit 0; }; done
url=""; out=""; prev=""
for a in "\$@"; do
    case "\$prev" in -o) out="\$a" ;; esac
    case "\$a" in http*|ftp*) url="\$a" ;; esac
    prev="\$a"
done
[ -n "\$url" ] || exit 0
name="\${url##*/}"
if [ -z "\$name" ]; then
    echo "<html><body><pre>"
    for f in "$ARTSRC"/*; do
        b="\${f##*/}"
        printf '<a href="%s">%s</a>  2026-09-21 18:42  %s\n' "\$b" "\$b" "\$(wc -c < "\$f" | tr -d ' ')"
    done
    echo "</pre></body></html>"
    exit 0
fi
[ -f "$ARTSRC/\$name" ] || exit 22
echo "download \$name" >> "$MOCK/art_downloads"
if [ -n "\$out" ]; then cp "$ARTSRC/\$name" "\$out"; else cat "$ARTSRC/\$name"; fi
EOF
cat > "$MOCK/crontab" << EOF
#!/usr/bin/env bash
# (read stdin fully before writing: the real crontab does too, and writing
# straight to the file would truncate it while the other side still reads)
case "\$1" in
  -l) cat "$T/crontab.txt" 2>/dev/null ;;
  -)  tmp="\$(mktemp)"; cat > "\$tmp"; mv "\$tmp" "$T/crontab.txt" ;;
esac
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
server_add() { setup mkdir -p "$SERVER/$(dirname "$1")"; echo "archive $1" > "$SERVER/$1" || setup false "write $1"; }
art() {   # art <SET> <Section> <Game>
    mkdir -p "$ROOT/artwork/iGame_$1/$2/Games/${3:0:1}/$3"
    echo "$1-$3" > "$ROOT/artwork/iGame_$1/$2/Games/${3:0:1}/$3/iGame.iff"
    echo "$1-$3-data" > "$ROOT/artwork/iGame_$1/$2/Games/${3:0:1}/$3/iGame.data"
}
for s in AGA ECS RTG; do for g in Alpha Gamma_De Rise Rise_AGA Zool_AGA Beta; do art "$s" Covers "$g"; done; done
mkdir -p "$ROOT/artwork/iGame_art"
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
art_in() { cat "$ROOT/build/$1"/iGame.iff "$ROOT/$1"/igame1.iff 2>/dev/null | head -1; }
game() { find "$ROOT/build/$1" -type d -name "$2" 2>/dev/null | head -1; }

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
  'case "$g" in */Languages/German/*) [ "$(art_in "${g#$ROOT/build/}")" = AGA-Gamma_De ];; *) false;; esac'
check "all three builds marked complete" '[ -f "$ROOT/.retroplay/complete/retro_aga" ] && [ -f "$ROOT/.retroplay/complete/retro_ecs" ] && [ -f "$ROOT/.retroplay/complete/retro_rtg" ]'
check "a run report was written" '[ -n "$(ls "$ROOT"/reports/*.txt 2>/dev/null)" ]'

section "2. Update: new version of a game + an HD_Loaders-only download"
: > "$MOCK/extract_calls"
server_add WHDLoad/Games/A/Alpha_v1.1.lha
server_add HD_Loaders/Games/H/Hdgame_v1.0.lha
run update ./all.sh; st=$?
check "all.sh exits 0" '[ "$st" -eq 0 ]'
check "superseded Alpha_v1.0 quarantined in old/, not deleted" \
  '[ -n "$(find "$ROOT/downloads/old" -name Alpha_v1.0.lha)" ] && [ ! -e "$ROOT/downloads/WHDLoad/Games/A/Alpha_v1.0.lha" ]'
check "new batch extracted once for all variants (2 archives, 2 extractions)" '[ "$(grep -c . "$MOCK/extract_calls")" -eq 2 ]'
check "old version's files replaced, not left behind" \
  '[ -f "$ROOT/build/retro_aga/WHDLoad/Games/A/Alpha/v1.1.txt" ] && [ ! -e "$ROOT/build/retro_aga/WHDLoad/Games/A/Alpha/v1.0.txt" ]'
check "updated game still has its artwork" '[ "$(art_in retro_ecs/WHDLoad/Games/A/Alpha)" = ECS-Alpha ]'
check "HD_Loaders-only content handled (no 'No WHDLoad directory' failure)" '[ -n "$(game retro_rtg Hdgame)" ]'
check "dated batch folder kept in new_aga/" '[ "$(find "$ROOT/build/new_aga" -mindepth 1 -maxdepth 1 -type d | grep -c .)" -eq 1 ]'
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
check "extraction failure reported with exit 5 (integrity)" '[ "$st" -eq 5 ]'
check "the download stays queued" 'grep -q Broken "$ROOT/.retroplay/queue/retro_aga.list" 2>/dev/null'
check "a failure notification was sent" 'grep -q "FAILED" "$MOCK/notifications" 2>/dev/null || grep -q "retroplay-test" "$MOCK/notifications" 2>/dev/null'
rm -f "$MOCK/fail_pattern"
run recover ./all.sh; st=$?
check "next run (nothing new on the server) still processes it" '[ "$st" -eq 0 ] && [ -n "$(game retro_aga Broken)" ]'
check "and then clears the queue" '[ ! -e "$ROOT/.retroplay/queue/retro_aga.list" ]'

section "6. An interrupted full build is redone, not mistaken for finished"
echo "$ROOT/build/retro_rtg" > "$ROOT/.retroplay/building/retro_rtg"
rm -rf "$ROOT/build/retro_rtg/WHDLoad/Games/B"
run resume ./all.sh --skip-update; st=$?
check "rtg rebuilt in full (exit 0)" '[ "$st" -eq 0 ] && [ -n "$(game retro_rtg Beta)" ]'
check "marked complete again" '[ ! -e "$ROOT/.retroplay/building/retro_rtg" ] && [ -f "$ROOT/.retroplay/complete/retro_rtg" ]'

section "7. --rebuild (via ecs.sh) skips the update and rebuilds only ECS"
: > "$MOCK/wget_calls"
touch "$ROOT/build/retro_ecs/SENTINEL" "$ROOT/build/retro_aga/SENTINEL"
run rebuild ./ecs.sh --rebuild; st=$?
check "exit 0" '[ "$st" -eq 0 ]'
check "update skipped (wget never called)" '[ ! -s "$MOCK/wget_calls" ]'
check "retro_ecs rebuilt from scratch" '[ ! -e "$ROOT/build/retro_ecs/SENTINEL" ] && [ -n "$(game retro_ecs Alpha)" ]'
check "retro_ecs still without AGA/CD32" '[ -z "$(game retro_ecs Zool_AGA)" ] && [ -z "$(game retro_ecs Rise_AGA_HD)" ]'
check "retro_aga untouched" '[ -e "$ROOT/build/retro_aga/SENTINEL" ]'
: > "$MOCK/wget_calls"
run rebuild_all ./all.sh --rebuild --variants aga; st=$?
check "all.sh --rebuild works too, without updating" '[ "$st" -eq 0 ] && [ ! -s "$MOCK/wget_calls" ] && [ ! -e "$ROOT/build/retro_aga/SENTINEL" ]'
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
check "exit 4 (prerequisite) with a clear message" '[ "$st" -eq 4 ] && grep -q "not enough" "$T/nospace.log"'
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
    check "second instance refused (exit 4) while the first holds the lock" '[ "$st" -eq 4 ] && grep -q "already running" "$T/locked.log"'
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
    rm -f "$ROOT/logs/all_cron.log"
    ( cd "$ROOT" && env -i HOME="$T/home" TMPDIR="$TMPDIR" PATH="$SYSBIN" \
        bash ./all.sh --cron --skip-update --force --variants aga ) < /dev/null > /dev/null 2>&1
}
rm -f "$ROOT/.retroplay/user_path"
cronrun; st=$?
check "control: with nothing remembered, cron can't find the tools (exit 1)" \
  '[ "$st" -eq 1 ] && grep -q "Still missing" "$ROOT/logs/all_cron.log"'
check "...and the log explains why and how to fix it" 'grep -q "unattended run" "$ROOT/logs/all_cron.log"'
run installcron ./install_cron.sh; st=$?
check "install_cron.sh installs the --cron entry and remembers this PATH" \
  '[ "$st" -eq 0 ] && grep -q -- "all.sh --cron" "$T/crontab.txt" && [ -s "$ROOT/.retroplay/user_path" ]'
cronrun; st=$?
check "the cron run now finds every tool and succeeds" '[ "$st" -eq 0 ] && ! grep -q "Still missing" "$ROOT/logs/all_cron.log"'

section "13. Temporary folders are always cleaned up"
check "no extract_tmp.* left behind by any run above" '[ -z "$(find "$ROOT" -name "extract_tmp.*")" ]'
check "no sort.sh or quick.sh temp folders left" \
  '[ -z "$(find "$TMPDIR" -name "sort_compliance.*")" ] && [ ! -e "$ROOT/.temp_new_archives" ]'
check "no engine work/staging folders left" '[ ! -e "$ROOT/.retroplay_work" ] && [ ! -e "$ROOT/.retroplay/stage" ]'
echo SlowGame > "$MOCK/slow_pattern"
mkdir -p "$ROOT/downloads/WHDLoad/Games/S"; mkdir -p "$ROOT/downloads/WHDLoad/Games/S"; echo x > "$ROOT/downloads/WHDLoad/Games/S/SlowGame_v1.0.lha"
( cd "$ROOT/downloads" && exec bash "$ROOT/extract.sh" -u -d "$T/intr_out" ) < /dev/null > "$T/intr.log" 2>&1 &
xp=$!
sleep 3
kill -TERM "$xp" 2>/dev/null; wait "$xp" 2>/dev/null
check "extract.sh stopped mid-extraction still removes its temp folder" \
  '[ -z "$(find "$ROOT/downloads" -maxdepth 1 -name "extract_tmp.*")" ]'
rm -f "$MOCK/slow_pattern" "$ROOT/downloads/WHDLoad/Games/S/SlowGame_v1.0.lha"
sh -c 'exit 0' & deadpid=$!; wait "$deadpid"
mkdir -p "$ROOT/downloads/extract_tmp.dead" "$ROOT/downloads/extract_tmp.legacy" "$ROOT/downloads/extract_tmp.live"
echo "$deadpid" > "$ROOT/downloads/extract_tmp.dead/.owner_pid"; echo "$$" > "$ROOT/downloads/extract_tmp.live/.owner_pid"
run sweep sh -c "cd downloads && bash ../extract.sh -u -d \"$T/sweep_out\""
check "leftovers from killed runs are swept up on the next run" \
  '[ ! -e "$ROOT/downloads/extract_tmp.dead" ] && [ ! -e "$ROOT/downloads/extract_tmp.legacy" ]'
check "a temp folder whose run is still going is left alone" '[ -d "$ROOT/downloads/extract_tmp.live" ]'
rm -rf "$ROOT/downloads/extract_tmp.live"


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
check "retro_aga holds only WHDLoad/HD_Loaders/JST at the top" 'layout_ok "$ROOT/build/retro_aga"'
check "games are in retro_aga/WHDLoad/..., not under a copied absolute path" \
  '[ -d "$ROOT/build/retro_aga/WHDLoad/Games/A/Alpha" ] && ! (cd "$ROOT/build/retro_aga" && find . | grep -qF "${T#/}")'
server_add WHDLoad/Games/E/Epsilon_v1.0.lha
( cd "$T/linkedroot" && ./all.sh --variants aga ) < /dev/null > "$T/linked_inc.log" 2>&1; st=$?
latest="$(ls -1d "$ROOT"/build/new_aga/*/ 2>/dev/null | sort | tail -1)"
check "update via that path: new_aga batch has the right layout too" \
  '[ "$st" -eq 0 ] && layout_ok "${latest%/}" && [ -d "${latest}WHDLoad/Games/E/Epsilon" ]'
mkdir -p "$T/ext/WHDLoad/Games/A" "$T/proj2"; echo x > "$T/ext/WHDLoad/Games/A/Alpha_v1.0.lha"
cp "$ROOT/extract.sh" "$ROOT/lib.sh" "$T/proj2/"; ln -s "$T/ext/WHDLoad" "$T/proj2/WHDLoad"
( cd "$T/proj2" && bash ./extract.sh -u -d "$T/ext_out" ) < /dev/null > "$T/ext.log" 2>&1
check "WHDLoad symlinked to another drive extracts into dest/WHDLoad/..." \
  'layout_ok "$T/ext_out" && [ -d "$T/ext_out/WHDLoad/Games/A/Alpha" ]'
mkdir -p "$ROOT/build/retro_ecs/Users/someone"
run doctor_layout ./doctor.sh; st=$?
check "doctor.sh spots a folder in the wrong place and explains the fix" \
  '[ "$st" -eq 1 ] && grep -q "retro_ecs/Users" "$T/doctor_layout.log" && grep -q "just run ./all.sh" "$T/doctor_layout.log"'
rm -rf "$ROOT/build/retro_ecs/Users"


section "15. iGame_art and other packs match a game folder anywhere inside them"
M="$T/anyart"; mkdir -p "$M"; cp "$ROOT/merge.sh" "$ROOT/lib.sh" "$M/"
mkart() { mkdir -p "$M/artwork/$1"; echo "$2" > "$M/artwork/$1/iGame.iff"; }
mkart "iGame_art/Misc/Some/Deep/Omega" "art-Omega"                 # no section in its path
mkart "iGame_art/Odd/Titles/X/Lambda" "art-Lambda-title"           # section revealed by the path
mkart "iGame_art/Covers/Games/M/Mu" "art-Mu-standard"              # standard location...
mkart "iGame_art/Misc/Mu" "art-Mu-stray"                           # ...beats a stray duplicate
mkart "iGame_AGA/Extras/Zeta" "aga-Zeta-nonstandard"               # AGA must NOT be searched this way
mkart "iGame_CD32/foo/bar/Kappa" "cd32-Kappa"                      # custom pack, any depth
mkdir -p "$M/artwork/iGame_AGA/Covers/Games/A/Anchor"; echo "aga-Anchor" > "$M/artwork/iGame_AGA/Covers/Games/A/Anchor/iGame.iff"
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


section "16. Leftover Users/... folders are healed automatically"
mkdir -p "$ROOT/build/retro_aga/Users/Dwight/Downloads/Amiga/WHDLoad/Games/A/Alpha"
mkdir -p "$ROOT/build/new_aga/2026-01-01_000000/Users/Dwight/Downloads/Amiga/WHDLoad"
run heal_dry ./all.sh --skip-update --variants aga --dry-run; st=$?
check "dry run explains it will rebuild, and which batch it would remove" \
  'grep -q "wrong place (Users)" "$T/heal_dry.log" && grep -q "Would remove build/new_aga/2026-01-01_000000" "$T/heal_dry.log"'
run heal ./all.sh --skip-update --variants aga; st=$?
check "the run rebuilds retro_aga (exit 0)" '[ "$st" -eq 0 ]'
check "retro_aga now holds only WHDLoad/HD_Loaders/JST" '[ -z "$(rp_layout_problems "$ROOT/build/retro_aga")" ]'
check "games are back in place WITH artwork and sorted" \
  '[ "$(art_in retro_aga/WHDLoad/Games/A/Alpha)" = AGA-Alpha ] && [ -n "$(game retro_aga/WHDLoad/AGA Zool_AGA)" ]'
check "the broken new_aga batch was removed" '[ ! -e "$ROOT/build/new_aga/2026-01-01_000000" ]'

section "17. A mix of old and new scripts is refused"
cp "$ROOT/extract.sh" "$T/extract.sh.good"
sed -i.bak '/^# retroplay-suite:/d' "$ROOT/extract.sh"
run mixed ./all.sh --skip-update; st=$?
check "all.sh refuses to run and names the out-of-date script" \
  '[ "$st" -eq 4 ] && grep -q "extract.sh (older version)" "$T/mixed.log"'
run mixed_doc ./doctor.sh; st=$?
check "doctor.sh reports it too" '[ "$st" -eq 1 ] && grep -q "extract.sh (older version)" "$T/mixed_doc.log"'
cp "$T/extract.sh.good" "$ROOT/extract.sh"; rm -f "$ROOT/extract.sh.bak"
run mixed_ok ./all.sh --skip-update; st=$?
check "with the complete set restored it runs again" '[ "$st" -eq 0 ] || [ "$st" -eq 2 ]'


section "18. Leftover temp folders from older versions don't break sorting"
setup mkdir -p "$TMPDIR/sort_compliance.OLDVER1"          # no .owner_pid, as older versions left them
mkdir -p "$T/sortfix/WHDLoad/Games/A/Alpha_AGA"; touch "$T/sortfix/WHDLoad/Games/A/Alpha_AGA.info"
run sortfix bash ./sort.sh --no-detox -d "$T/sortfix"; st=$?
check "sort.sh succeeds despite an ownerless leftover (it used to crash under set -e)" '[ "$st" -eq 0 ]'
check "...and removes the leftover" '[ ! -e "$TMPDIR/sort_compliance.OLDVER1" ]'


section "19. A corrupt archive doesn't block the rest, and is retried then re-fetched"
echo BadGame > "$MOCK/fail_pattern"
server_add WHDLoad/Games/G/GoodGame_v1.0.lha; server_add WHDLoad/Games/B/BadGame_v1.0.lha
run partial1 ./all.sh --variants aga; st=$?
check "run completes the good archive but reports the failure (exit 5)" '[ "$st" -eq 5 ] && [ -n "$(game retro_aga GoodGame)" ]'
check "the corrupt one stays queued, the good one doesn't" \
  'grep -q BadGame "$ROOT/.retroplay/queue/retro_aga.list" && ! grep -q GoodGame "$ROOT/.retroplay/queue/retro_aga.list"'
run partial2 ./all.sh --variants aga --skip-update
run partial3 ./all.sh --variants aga --skip-update; st=$?
check "after 3 failed attempts it's moved to old/corrupt-<date>/ and dropped from the queue" \
  '[ "$st" -eq 5 ] && [ -n "$(find "$ROOT/downloads/old" -path "*corrupt-*" -name BadGame_v1.0.lha)" ] && ! grep -qs BadGame "$ROOT/.retroplay/queue/retro_aga.list"'
check "the report says what happened" 'grep -q "GAVE UP on WHDLoad/Games/B/BadGame_v1.0.lha" "$T/partial3.log"'
rm -f "$MOCK/fail_pattern"
run partial4 ./all.sh --variants aga; st=$?
check "next update downloads a fresh copy, which then installs fine" '[ "$st" -eq 0 ] && [ -n "$(game retro_aga BadGame)" ]'

section "20. Re-published and partially downloaded files"
echo "republished content" > "$SERVER/WHDLoad/Games/G/GoodGame_v1.0.lha"
run republish ./all.sh --variants aga; st=$?
check "a file re-published under the same name is downloaded AND processed" \
  '[ "$st" -eq 0 ] && grep -q "GoodGame_v1.0.lha" "$ROOT/logs/update.log" && [ -n "$(find "$ROOT/build/new_aga" -type d -name GoodGame)" ]'
echo PartGame > "$MOCK/partial_pattern"
server_add WHDLoad/Games/P/PartGame_v1.0.lha
run partdl ./all.sh --variants aga; st=$?
check "an interrupted download stops the run as a network problem (exit 3)" '[ "$st" -eq 3 ]'
check "...and the partial file is NOT queued as if complete" '! grep -qs PartGame "$ROOT/.retroplay/queue/retro_aga.list"'
rm -f "$MOCK/partial_pattern"
run partdl2 ./all.sh --variants aga; st=$?
check "next run re-downloads it in full and installs it" '[ "$st" -eq 0 ] && [ -n "$(game retro_aga PartGame)" ]'

section "21. A refused second run says who holds the lock"
if [ -n "$FLOCK" ]; then
    echo SlowGame > "$MOCK/slow_pattern"; mkdir -p "$ROOT/downloads/WHDLoad/Games/S"; echo x > "$ROOT/downloads/WHDLoad/Games/S/SlowGame_v1.0.lha"
    ( cd "$ROOT" && ./all.sh --rebuild --variants aga ) < /dev/null > "$T/holder.log" 2>&1 & hp=$!
    sleep 3
    run locked2 ./all.sh --skip-update; st=$?
    wait "$hp"
    check "second run refused (exit 4) and names the holder's PID and command" \
      '[ "$st" -eq 4 ] && grep -q "Held by: pid=$hp" "$T/locked2.log" && grep -q "command=all.sh --rebuild --variants aga" "$T/locked2.log"'
    check "the lock record is removed when the holder finishes" '[ ! -e "$ROOT/.all.lock.info" ]'
    rm -f "$MOCK/slow_pattern" "$ROOT/downloads/WHDLoad/Games/S/SlowGame_v1.0.lha"
else
    echo "  (skipped: flock not installed)"
fi


section "22. Output drive not mounted: refuse instead of rebuilding onto the SD card"
USB="$T/usb"; setup mkdir -p "$USB"
cp "$ROOT/retroplay.conf" "$T/conf.bak"; echo "OUTPUT_ROOT=\"$USB\"" >> "$ROOT/retroplay.conf"
run usb1 ./all.sh --skip-update --variants aga; st=$?
check "first use: builds on the drive and marks it" '[ "$st" -eq 0 ] && [ -s "$USB/.retroplay_output" ] && [ -d "$USB/build/retro_aga/WHDLoad" ]'
mv "$USB" "$T/usb_unplugged"; mkdir -p "$USB"          # empty mount point = drive not mounted
run usb2 ./all.sh --skip-update --variants aga; st=$?
check "drive 'unplugged': refused (exit 4) and nothing written to the empty mount point" \
  '[ "$st" -eq 4 ] && [ -z "$(ls -A "$USB")" ] && grep -q "not mounted" "$T/usb2.log"'
rmdir "$USB"
run usb3 ./all.sh --skip-update --variants aga; st=$?
check "mount point missing entirely: refused (exit 4), not created" '[ "$st" -eq 4 ] && [ ! -e "$USB" ]'
mv "$T/usb_unplugged" "$USB"
run usb4 ./all.sh --skip-update --variants aga; st=$?
check "drive back: runs normally again" '[ "$st" -eq 0 ] || [ "$st" -eq 2 ]'
cp "$T/conf.bak" "$ROOT/retroplay.conf"

section "23. State backups, and automatic restore if the state folder is lost"
server_add WHDLoad/Games/Q/QueuedGame_v1.0.lha
run q_upd ./update.sh
run q_rtg ./all.sh --skip-update --variants rtg          # takes a backup; aga/ecs keep QueuedGame queued
check "rolling state backups are kept" '[ -n "$(ls "$ROOT"/.retroplay_backups/state-*.tgz 2>/dev/null)" ]'
rm -rf "$ROOT/.retroplay"
run restore ./all.sh --skip-update --variants aga; st=$?
check "lost state folder is restored, and its queued download still gets installed" \
  '[ "$st" -eq 0 ] && grep -q "restored it from" "$T/restore.log" && [ -n "$(game retro_aga QueuedGame)" ]'
run drain ./all.sh --skip-update

section "24. Artwork gap-fill runs only when artwork changed (or weekly)"
run gap0 ./all.sh --skip-update --variants ecs; st=$?
check "nothing changed: nothing to do (exit 2)" '[ "$st" -eq 2 ]'
sleep 1
setup mkdir -p "$ROOT/artwork/iGame_ECS/Covers/Games/E/Epsilon"; echo ECS-Epsilon > "$ROOT/artwork/iGame_ECS/Covers/Games/E/Epsilon/iGame.iff"
run gap1 ./all.sh --skip-update --variants ecs; st=$?
check "an artwork pack changed: gap-fill runs by itself and adds the new artwork" \
  '[ "$st" -eq 0 ] && grep -q "artwork packs changed" "$T/gap1.log" && [ "$(art_in retro_ecs/WHDLoad/Games/E/Epsilon)" = ECS-Epsilon ]'
run gap2 ./all.sh --skip-update --variants ecs; st=$?
check "...and not again until something changes (exit 2)" '[ "$st" -eq 2 ]'

section "25. Corrupt downloads are fetched again in the same run"
echo VerifyGame > "$MOCK/corrupt_once"; server_add WHDLoad/Games/V/VerifyGame_v1.0.lha
run verify ./all.sh --variants aga; st=$?
check "detected, re-downloaded and installed in one run" \
  '[ "$st" -eq 0 ] && grep -q "CORRUPT download, fetching it again: WHDLoad/Games/V/VerifyGame_v1.0.lha" "$ROOT/logs/update.log" && grep -q "re-downloaded OK" "$ROOT/logs/update.log" && [ -n "$(game retro_aga VerifyGame)" ]'
rm -f "$MOCK/corrupt_once"

section "26. An unreadable wget log is reported, not silently ignored"
touch "$MOCK/nolog"; server_add WHDLoad/Games/N/NoLogGame_v1.0.lha
run nolog ./all.sh --variants aga; st=$?
check "warning logged, and the new file is still processed" \
  '[ "$st" -eq 0 ] && grep -q "download log" "$ROOT/logs/update.log" && [ -n "$(game retro_aga NoLogGame)" ]'
rm -f "$MOCK/nolog"

section "27. Status view and test notification"
run status ./start.sh --status; st=$?
check "status shows the last run and each variant's state" \
  '[ "$st" -eq 0 ] && grep -q "Last run:" "$T/status.log" && grep -q "retro_aga: *built" "$T/status.log" && grep -q "Output folder:" "$T/status.log"'
: > "$MOCK/notifications"
run tn ./all.sh --test-notify; st=$?
check "test notification sent (exit 0)" '[ "$st" -eq 0 ] && grep -q "test notification" "$MOCK/notifications"'
cp "$ROOT/retroplay.conf" "$T/conf.bak"; grep -v NTFY_TOPIC "$T/conf.bak" > "$ROOT/retroplay.conf"
run tn2 ./start.sh --test-notify; st=$?
check "not configured: says how to set it up (exit 4)" '[ "$st" -eq 4 ] && grep -q "NTFY_TOPIC" "$T/tn2.log"'
cp "$T/conf.bak" "$ROOT/retroplay.conf"
( cd "$ROOT" && printf '9\n' | ./start.sh ) > "$T/menu9.log" 2>&1
check "the menu shows a status summary on top, and option 9 the full status" \
  '[ "$(grep -c "Amiga Retroplay status" "$T/menu9.log")" -ge 2 ] && grep -q "Nightly run:" "$T/menu9.log"'

section "28. setup.sh installs everything on a bare system, and is safe to repeat"
S="$T/setupbox"; SM="$T/setupmock"; IB="$T/installed"; SB="$T/setupsys"
setup mkdir -p "$S" "$SM" "$IB" "$SB" "$T/h"
cp "$REPO"/*.sh "$REPO"/retroplay.conf.example "$S"/ 2>/dev/null; chmod +x "$S"/*.sh
for d in /usr/bin /bin; do for f in "$d"/*; do n="${f##*/}"
    case "$n" in lha|7z|7za|unar|lsar|unlzx|wget|curl|unzip|flock|detox|locale|locale-gen|crontab|apt-get|dpkg-query|sudo) continue ;; esac
    [ -e "$SB/$n" ] || ln -s "$f" "$SB/$n"; done; done
printf '#!/bin/sh\n[ "$1" = x ] && printf "#include <stdio.h>\\nint main(void){puts(\\"unlzx test build\\");return 0;}\\n" > unlzx.c\nexit 0\n' > "$SM/stub_lha"
printf '#!/bin/sh\no=""; p=""; for a in "$@"; do [ "$p" = "-o" ] && o="$a"; p="$a"; done; [ -n "$o" ] && echo archive > "$o"; exit 0\n' > "$SM/stub_curl"
printf '#!/bin/sh\nexit 0\n' > "$SM/stub_generic"
cat > "$SM/apt-get" << EOF
#!/usr/bin/env bash
echo "apt-get \$*" >> "$SM/apt_calls"
[ "\$1" = install ] || exit 0
for p in "\$@"; do
  case "\$p" in install|-y|-qq) continue ;; esac
  echo "\$p" >> "$SM/installed_pkgs"
  case "\$p" in lhasa) c=lha ;; p7zip-full) c=7z ;; util-linux) c=flock ;; *) c="\$p" ;; esac
  cp "$SM/stub_\$c" "$IB/\$c" 2>/dev/null || cp "$SM/stub_generic" "$IB/\$c"; chmod +x "$IB/\$c"
done
EOF
printf '#!/bin/sh\nfor p in "$@"; do :; done; grep -qx "$p" "%s/installed_pkgs" 2>/dev/null && printf "install ok installed"\nexit 0\n' "$SM" > "$SM/dpkg-query"
printf '#!/bin/sh\nexec "$@"\n' > "$SM/sudo"
printf '#!/bin/sh\necho C.utf8\ngrep -qx "en_US ISO-8859-1" "%s/locale.gen" && echo en_US.iso88591\nexit 0\n' "$SM" > "$SM/locale"
printf '#!/bin/sh\nexit 0\n' > "$SM/locale-gen"
chmod +x "$SM"/*
printf '# C.UTF-8 UTF-8\n# en_US ISO-8859-1\n# en_US.UTF-8 UTF-8\n' > "$SM/locale.gen"
setup_run() {
    ( cd "$S" && env -i HOME="$T/h" TMPDIR="$TMPDIR" PATH="$IB:$SM:$SB" RP_SETUP_OS=linux \
        RP_LOCALE_GEN_FILE="$SM/locale.gen" RP_INSTALL_BIN="$IB" RP_UNLZX_URL="http://mock/unlzx.lha" \
        bash ./setup.sh --yes --no-cron ) < /dev/null > "$T/$1.log" 2>&1
}
setup_run setup1
check "missing tools installed with one apt-get call, and recorded for uninstalling" \
  '[ "$(grep -c "install -y" "$SM/apt_calls")" -eq 1 ] && grep -q "apt:lhasa" "$S/.retroplay_installed_deps.log" && grep -q "apt:p7zip-full" "$S/.retroplay_installed_deps.log"'
check "unlzx downloaded, compiled, installed and recorded" \
  '[ "$("$IB/unlzx")" = "unlzx test build" ] && grep -q "source-build:$IB/unlzx" "$S/.retroplay_installed_deps.log"'
check "the missing locale was enabled" 'grep -qx "en_US ISO-8859-1" "$SM/locale.gen"'
check "retroplay.conf created with the default variants" 'grep -qx "VARIANTS=\"aga ecs rtg\"" "$S/retroplay.conf"'
calls_before="$(wc -l < "$SM/apt_calls")"
setup_run setup2
check "running it again changes nothing (no new installs)" '[ "$(wc -l < "$SM/apt_calls")" -eq "$calls_before" ] && grep -q "retroplay.conf already exists" "$T/setup2.log"'


section "29. Artwork: the published archives, mapped into the right folders"
acfg() { grep -v "^$1=" "$ROOT/retroplay.conf" > "$ROOT/.c.tmp"; printf '%s=%s\n' "$1" "$2" >> "$ROOT/.c.tmp"; mv "$ROOT/.c.tmp" "$ROOT/retroplay.conf"; }
acfg ARTWORK_SOURCE_URL '"http://mock/WHDLoad_Images"'
acfg ARTWORK_LOCAL_CHANGE_POLICY '"keep-local"'
rm -rf "$ROOT/artwork/iGame_AGA" "$ROOT/artwork/iGame_ECS" "$ROOT/artwork/iGame_RTG" "$ROOT/artwork/TinyLauncher"
: > "$MOCK/art_downloads"
run artplan ./artwork_sync.sh --plan --all-artwork; st=$?
check "plan lists only the published IGame_*/TinyLauncher archives" \
  '[ "$st" -eq 0 ] && grep -q "IGame_Covers_AGA_Laced.lha" "$T/artplan.log" && grep -q "TinyLauncher.lha" "$T/artplan.log" && ! grep -q "unrelated.lha" "$T/artplan.log" && ! grep -q "ignored.zip" "$T/artplan.log"'
check "plan changes nothing and downloads nothing" '[ ! -e "$ROOT/artwork/iGame_AGA" ] && ! grep -q "download IGame" "$MOCK/art_downloads"'
run artaga ./artwork_sync.sh --sync --for aga --yes; st=$?
check "--for aga fetches only the three AGA LoRes archives" \
  '[ "$st" -eq 0 ] && [ "$(grep -c "download IGame_.*_AGA_LoRes" "$MOCK/art_downloads")" -eq 3 ] && ! grep -q "AGA_Laced" "$MOCK/art_downloads" && ! grep -q "_RTG" "$MOCK/art_downloads"'
check "...installed as artwork/iGame_AGA/lores/<Section>/<category>/..." \
  '[ -f "$ROOT/artwork/iGame_AGA/lores/Covers/Games/A/iGame.iff" ] && [ -f "$ROOT/artwork/iGame_AGA/lores/Screens/Games/A/iGame.iff" ] && [ -f "$ROOT/artwork/iGame_AGA/lores/Titles/Games/A/iGame.iff" ]'
run artlaced ./artwork_sync.sh --sync --for aga-laced --for rtg --yes; st=$?
check "laced and RTG go to their own folders" \
  '[ "$st" -eq 0 ] && [ -f "$ROOT/artwork/iGame_AGA/laced/Covers/Games/A/iGame.iff" ] && [ -f "$ROOT/artwork/iGame_RTG/Covers/Games/A/iGame.iff" ] && [ ! -e "$ROOT/artwork/iGame_RTG/lores" ]'
check "archives are cached in downloads/artwork_archive, not in the artwork folders" \
  '[ -f "$ROOT/downloads/artwork_archive/IGame_Covers_AGA_LoRes.lha" ] && [ -z "$(find "$ROOT/artwork" -name "*.lha" | head -1)" ]'
: > "$MOCK/art_downloads"
run artagain ./artwork_sync.sh --sync --for aga --yes; st=$?
check "nothing new upstream: no downloads, exit 2" '[ "$st" -eq 2 ] && [ ! -s "$MOCK/art_downloads" ]'
run artall ./artwork_sync.sh --sync --all-artwork --yes
check "--all-artwork installs every flavour, including TinyLauncher" \
  '[ -f "$ROOT/artwork/iGame_ECS/laced/Titles/Games/A/iGame.iff" ] && [ -f "$ROOT/artwork/iGame_ECS/lores/Covers/Games/A/iGame.iff" ] && [ -d "$ROOT/artwork/TinyLauncher" ]'

section "30. Artwork: updates, refusals, local changes and rollback"
printf 'A\nIGame_Covers_AGA_LoRes.lha\nnewer\n' > "$ARTSRC/IGame_Covers_AGA_LoRes.lha"
run artupd ./artwork_sync.sh --sync --for aga --yes; st=$?
check "a newer archive installs, keeping the old folder as a backup" \
  '[ "$st" -eq 0 ] && [ -n "$(find "$ROOT/.retroplay/artwork/backups/iGame_AGA_lores_Covers" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]'
cp "$ROOT/artwork/iGame_ECS/lores/Covers/Games/A/iGame.iff" "$T/ecs_before.iff"
cp "$ROOT/downloads/artwork_archive/IGame_Covers_ECS_LoRes.lha" "$T/ecs_cache_before.lha"
printf 'CORRUPT\nIGame_Covers_ECS_LoRes.lha\nbroken\n' > "$ARTSRC/IGame_Covers_ECS_LoRes.lha"
run artbad ./artwork_sync.sh --sync --for ecs --yes; st=$?
check "a corrupt download is refused and the installed artwork is untouched" \
  '[ "$st" -ne 0 ] && cmp -s "$T/ecs_before.iff" "$ROOT/artwork/iGame_ECS/lores/Covers/Games/A/iGame.iff"'
check "...and the good cached archive is kept, not replaced by the corrupt one" \
  'cmp -s "$T/ecs_cache_before.lha" "$ROOT/downloads/artwork_archive/IGame_Covers_ECS_LoRes.lha"'
printf 'BAD\nIGame_Covers_ECS_LoRes.lha\nlayout\n' > "$ARTSRC/IGame_Covers_ECS_LoRes.lha"
run artbadlayout ./artwork_sync.sh --sync --for ecs --yes; st=$?
check "an unexpected layout is refused, not guessed at" \
  '[ "$st" -ne 0 ] && cmp -s "$T/ecs_before.iff" "$ROOT/artwork/iGame_ECS/lores/Covers/Games/A/iGame.iff" && grep -q "unexpected layout" "$T/artbadlayout.log"'
echo "my own note" > "$ROOT/artwork/iGame_RTG/Covers/MY_NOTES.txt"
printf 'A\nIGame_Covers_RTG.lha\nnewer\n' > "$ARTSRC/IGame_Covers_RTG.lha"
run artlocal ./artwork_sync.sh --sync --for rtg --yes
check "a folder you changed yourself is left alone (keep-local)" \
  '[ -f "$ROOT/artwork/iGame_RTG/Covers/MY_NOTES.txt" ] && grep -q "left alone" "$T/artlocal.log"'
run artroll ./artwork_sync.sh --rollback iGame_AGA/lores/Covers --yes; st=$?
check "rollback restores the previous version of one part" \
  '[ "$st" -eq 0 ] && [ -f "$ROOT/artwork/iGame_AGA/lores/Covers/Games/A/iGame.iff" ]'
run artverify ./artwork_sync.sh --verify --all-artwork
check "verify reports and changes nothing" 'grep -q "Artwork check" "$T/artverify.log" && [ -f "$ROOT/artwork/iGame_RTG/Covers/Games/A/iGame.iff" ]'

section "31. Scheduled run: artwork first, one lock, safe failure policies"
acfg ARTWORK_SYNC '"auto"'
printf 'B\nIGame_Covers_AGA_LoRes.lha\nfixed for the cron test\n' > "$ARTSRC/IGame_Covers_AGA_LoRes.lha"
rm -f "$ROOT/.retroplay/artwork_last_check"; : > "$ROOT/logs/all_cron.log"
run cronart ./all.sh --cron --skip-update --variants aga; st=$?
check "the cron run completes - one lock, no deadlock" '[ "$st" -eq 0 ] || [ "$st" -eq 2 ]'
check "artwork is checked before the collection pipeline" \
  '[ "$(grep -n "\[Artwork\]" "$ROOT/logs/all_cron.log" | head -1 | cut -d: -f1)" -lt "$(grep -n "Plan" "$ROOT/logs/all_cron.log" | head -1 | cut -d: -f1)" ]'
rm -f "$ROOT/.retroplay/artwork_last_check"
printf 'CORRUPT\nIGame_Screens_AGA_LoRes.lha\nbroken\n' > "$ARTSRC/IGame_Screens_AGA_LoRes.lha"
acfg ARTWORK_FAILURE_POLICY '"warn-and-continue"'
run cronwarn ./all.sh --cron --skip-update --variants aga; st=$?
check "artwork failure (warn-and-continue): the collection sync still runs" '[ "$st" -eq 0 ] || [ "$st" -eq 2 ]'
check "...and the previous artwork is kept" '[ -f "$ROOT/artwork/iGame_AGA/lores/Screens/Games/A/iGame.iff" ]'
rm -f "$ROOT/.retroplay/artwork_last_check"
acfg ARTWORK_FAILURE_POLICY '"fail"'
run cronfail ./all.sh --cron --skip-update --variants aga; st=$?
check "artwork failure (fail): stops before touching the collection (exit 5)" \
  '[ "$st" -eq 5 ] && grep -q "queues are untouched" "$ROOT/logs/all_cron.log"'
acfg ARTWORK_SYNC '"no"'


section "32. Tidy folder layout, log retention and the scripts/ folder"
check "everything lives in artwork/, build/, downloads/, logs/ and reports/" \
  '[ -d "$ROOT/artwork" ] && [ -d "$ROOT/build/retro_aga" ] && [ -d "$ROOT/downloads/WHDLoad" ] && [ -f "$ROOT/logs/update.log" ] && [ -n "$(ls "$ROOT/reports" 2>/dev/null)" ]'
check "nothing is left loose beside the scripts" \
  '[ ! -e "$ROOT/WHDLoad" ] && [ ! -e "$ROOT/retro_aga" ] && [ ! -e "$ROOT/update.log" ] && [ ! -e "$ROOT/iGame_AGA" ]'
check "artwork archives are cached under downloads/artwork_archive" \
  '[ -d "$ROOT/downloads/artwork_archive" ] && [ -z "$(find "$ROOT/artwork" -name "*.lha" | head -1)" ]'
# migration from the old flat layout
OLD="$T/oldlayout"; setup mkdir -p "$OLD"
cp "$REPO"/*.sh "$REPO"/retroplay.conf.example "$OLD"/; chmod +x "$OLD"/*.sh
setup mkdir -p "$OLD/iGame_AGA/Covers" "$OLD/TinyLauncher" "$OLD/WHDLoad/Games/A" "$OLD/retro_aga/WHDLoad" "$OLD/new_aga" "$OLD/artwork_archive"
echo old > "$OLD/iGame_AGA/Covers/marker"; echo old > "$OLD/retro_aga/WHDLoad/marker"; : > "$OLD/update.log"
( cd "$OLD" && ./all.sh --skip-update --variants aga ) < /dev/null > "$T/migrate.log" 2>&1
check "an old flat folder is tidied up automatically, keeping the contents" \
  '[ -f "$OLD/artwork/iGame_AGA/Covers/marker" ] && [ -f "$OLD/build/retro_aga/WHDLoad/marker" ] && [ -d "$OLD/downloads/WHDLoad/Games/A" ] && [ -d "$OLD/downloads/artwork_archive" ] && [ -f "$OLD/logs/update.log" ]'
check "and it says so once" 'grep -q "Tidied the folder layout" "$T/migrate.log"'
# log retention
acfg LOG_RETENTION_DAYS 2
: > "$ROOT/logs/ancient.log"; touch -t 202001010000 "$ROOT/logs/ancient.log"
: > "$ROOT/logs/today.log"
run logprune ./all.sh --skip-update --variants aga
check "logs older than LOG_RETENTION_DAYS are deleted, recent ones kept" \
  '[ ! -e "$ROOT/logs/ancient.log" ] && [ -f "$ROOT/logs/today.log" ]'
acfg LOG_RETENTION_DAYS 0
: > "$ROOT/logs/ancient2.log"; touch -t 202001010000 "$ROOT/logs/ancient2.log"
run lognoprune ./all.sh --skip-update --variants aga
check "LOG_RETENTION_DAYS=0 keeps logs for ever" '[ -f "$ROOT/logs/ancient2.log" ]'
rm -f "$ROOT/logs/ancient2.log"; acfg LOG_RETENTION_DAYS 1
# scripts/ subfolder
SUB="$T/subfolder"; setup mkdir -p "$SUB/scripts"
cp "$REPO"/*.sh "$REPO"/retroplay.conf.example "$SUB/scripts"/; chmod +x "$SUB/scripts"/*.sh
setup mkdir -p "$SUB/downloads/WHDLoad/Games/A"
( cd "$SUB" && ./scripts/all.sh --skip-update --variants aga ) < /dev/null > "$T/subfolder.log" 2>&1
check "the scripts also work from a scripts/ subfolder, using the folder above" \
  '[ -d "$SUB/artwork" ] && [ -d "$SUB/logs" ] && [ ! -d "$SUB/scripts/artwork" ] && [ ! -d "$SUB/scripts/logs" ]'


section "33. Scheduling the nightly run"
run sched_show ./install_cron.sh --show; st=$?
check "--show reports the installed entry" '[ "$st" -eq 0 ] && grep -q "nightly run is installed" "$T/sched_show.log"'
run sched_dry ./install_cron.sh --time 04:30 --dry-run; st=$?
check "--dry-run prints the new entry and changes nothing" \
  '[ "$st" -eq 0 ] && grep -q "30 4 \* \* \*" "$T/sched_dry.log" && ! grep -q "30 4 " "$T/crontab.txt"'
run sched_time ./install_cron.sh --time 4:30; st=$?
check "--time installs at that hour (single-digit hours accepted)" \
  '[ "$st" -eq 0 ] && grep -q "^30 4 \* \* \*" "$T/crontab.txt" && [ "$(grep -c retroplay-all-sh "$T/crontab.txt")" -eq 1 ]'
run sched_bad ./install_cron.sh --time 25:00; st=$?
check "a silly time is refused (exit 4), leaving the entry alone" \
  '[ "$st" -eq 4 ] && grep -q "^30 4 " "$T/crontab.txt"'
echo "0 5 * * * echo someone elses job" >> "$T/crontab.txt"
run sched_off ./install_cron.sh --disable --yes; st=$?
check "--disable removes only our entry" \
  '[ "$st" -eq 0 ] && ! grep -q retroplay-all-sh "$T/crontab.txt" && grep -q "someone elses job" "$T/crontab.txt"'
run sched_off2 ./install_cron.sh --disable --yes; st=$?
check "--disable again says there is nothing to remove (exit 2)" '[ "$st" -eq 2 ]'
run sched_back ./install_cron.sh --yes
check "installing again restores it at the default time" 'grep -q "^0 2 \* \* \*" "$T/crontab.txt"'


section "34. Artwork: every flavour is fetched, and merge reads the real layout"
# put the source back to a good state (earlier sections deliberately broke some)
for sec in Covers Screens Titles; do
    art_archive "IGame_${sec}_AGA_Laced.lha" A; art_archive "IGame_${sec}_AGA_LoRes.lha" B
    art_archive "IGame_${sec}_ECS_Laced.lha" A; art_archive "IGame_${sec}_ECS_LoRes.lha" B
    art_archive "IGame_${sec}_RTG.lha" A
done
art_archive TinyLauncher.lha B
rm -rf "$ROOT/.retroplay/artwork/manifests"
: > "$MOCK/art_downloads"
rm -rf "$ROOT/artwork/iGame_AGA" "$ROOT/artwork/iGame_ECS" "$ROOT/artwork/iGame_RTG" "$ROOT/artwork/TinyLauncher"
run artdefault ./artwork_sync.sh --sync --yes; st=$?
check "with no --for, both flavours AND TinyLauncher are fetched" \
  '[ "$st" -eq 0 ] && [ "$(grep "_Laced" "$MOCK/art_downloads" | sort -u | grep -c .)" -eq 6 ] && [ "$(grep "_LoRes" "$MOCK/art_downloads" | sort -u | grep -c .)" -eq 6 ] && grep -q "download TinyLauncher.lha" "$MOCK/art_downloads"'
check "the Laced folders are created alongside lores" \
  '[ -f "$ROOT/artwork/iGame_AGA/laced/Covers/Games/A/iGame.iff" ] && [ -f "$ROOT/artwork/iGame_ECS/laced/Titles/Games/A/iGame.iff" ] && [ -d "$ROOT/artwork/iGame_AGA/lores" ]'
check "archives are cached in downloads/artwork_archive" \
  '[ -f "$ROOT/downloads/artwork_archive/IGame_Covers_AGA_Laced.lha" ] && [ ! -d "$ROOT/downloads/artwork_archives" ]'
run artplan2 ./artwork_sync.sh --plan; st=$?
check "--artwork-plan covers the Laced archives too" 'grep -q "IGame_Titles_ECS_Laced.lha" "$T/artplan2.log"'
# merge against the real structure: only real games, right flavour, fallbacks
MG="$T/mergereal"; setup mkdir -p "$MG"
cp "$ROOT/merge.sh" "$ROOT/lib.sh" "$MG/"
for fl in lores laced; do for sec in Covers Screens Titles; do
    setup mkdir -p "$MG/artwork/iGame_AGA/$fl/$sec/Games/S/Superfrog"
    echo "AGA-$fl-$sec" > "$MG/artwork/iGame_AGA/$fl/$sec/Games/S/Superfrog/iGame.iff"
done; done
setup mkdir -p "$MG/artwork/iGame_RTG/Covers/Games/Z/Zool"; echo RTG-Zool > "$MG/artwork/iGame_RTG/Covers/Games/Z/Zool/iGame.iff"
setup mkdir -p "$MG/artwork/iGame_art/Apidya"; echo ART-Apidya > "$MG/artwork/iGame_art/Apidya/iGame.iff"
for g in Superfrog Zool Apidya Nothing; do
    L="$(printf '%s' "$g" | cut -c1)"
    setup mkdir -p "$MG/build/retro_aga/WHDLoad/Games/$L/$g/data/save"
    touch "$MG/build/retro_aga/WHDLoad/Games/$L/$g.info"
done
( cd "$MG" && bash merge.sh --aga -d build/retro_aga --report-missing missing.txt ) > "$T/mergereal.log" 2>&1
check "only real games are counted - not category, letter or in-game folders" \
  'grep -q "Found 4 WHDLoad subdirectories" "$T/mergereal.log"'
check "AGA build uses the lores artwork" '[ "$(cat "$MG/build/retro_aga/WHDLoad/Games/S/Superfrog/iGame.iff")" = "AGA-lores-Covers" ]'
check "fallbacks still work (RTG pack, then the art pack)" \
  '[ -f "$MG/build/retro_aga/WHDLoad/Games/Z/Zool/iGame.iff" ] && [ "$(cat "$MG/build/retro_aga/WHDLoad/Games/A/Apidya/iGame.iff")" = ART-Apidya ]'
check "only the game with no artwork anywhere is reported missing" \
  '[ "$(grep -c . "$MG/missing.txt")" -eq 1 ] && grep -q Nothing "$MG/missing.txt"'
find "$MG/build/retro_aga" -name 'iGame*.iff' -delete    # merge never overwrites existing artwork
( cd "$MG" && bash merge.sh --aga-laced -d build/retro_aga > /dev/null 2>&1 )
check "--aga-laced uses the laced artwork" '[ "$(cat "$MG/build/retro_aga/WHDLoad/Games/S/Superfrog/iGame.iff")" = "AGA-laced-Covers" ]'

section "35. Saved backups can be cleared at the end of a hands-on run"
run nobk ./all.sh --skip-update --variants aga; st=$?
check "an unattended run never asks and keeps the backups" \
  '{ [ "$st" -eq 0 ] || [ "$st" -eq 2 ]; } && ! grep -q "Delete them?" "$T/nobk.log" && [ -d "$ROOT/.retroplay_backups" ]'

# ================================================================ summary ===
echo
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32mAll %d tests passed.\033[0m\n' "$PASS"
    exit 0
fi
printf '\033[31m%d of %d tests failed:\033[0m%s\n' "$FAIL" $((PASS + FAIL)) "$FAILED_NAMES"
echo "Re-run with -v to see each script's output."
exit 1
