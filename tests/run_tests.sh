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
run_out() { ( cd "$ROOT" && "$@" ) 2>/dev/null; }
# Fixture setup: a failure here is a broken test environment, not a failed
# test - stop immediately with a clear setup error.
setup() { "$@" || { echo "SETUP ERROR (test fixture could not be created): $*" >&2; exit 3; }; }
# acfg KEY VALUE - change one setting in the test's retroplay.conf
acfg() { grep -v "^$1=" "$ROOT/retroplay.conf" > "$ROOT/.c.tmp"; printf '%s=%s\n' "$1" "$2" >> "$ROOT/.c.tmp"; mv "$ROOT/.c.tmp" "$ROOT/retroplay.conf"; }
section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/retroplay_tests.XXXXXX")"
trap 'rm -rf "$T"' EXIT
ROOT="$T/retroplay"; SERVER="$T/server"; MOCK="$T/mockbin"
mkdir -p "$ROOT" "$SERVER" "$MOCK"
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
export RP_RETRY_WAIT=0          # no pauses between download retries in tests
cp "$REPO"/*.sh "$REPO"/to_ilbm.py "$ROOT"/
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
# A hostile archive: one member climbs four folders up (../../../../), the
# way a tampered download could try to write beside the collections.
evil="$(cat "$(dirname "$0")/evil_pattern" 2>/dev/null)"
[ -n "$evil" ] && case "$stem" in *"$evil"*) echo pwned > "../../../../ESCAPED_$stem" ;; esac
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
# simulated server-side failure (503) for any archive matching this pattern
pat="\$(cat "$MOCK/art_503" 2>/dev/null)"
if [ -n "\$pat" ]; then
    case "\$name" in *"\$pat"*)
        echo "curl: (22) The requested URL returned error: 503" >&2; exit 22 ;;
    esac
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
# the first artwork file of any priority (iGame.iff, igame1.iff, igame2.iff)
# whichever artwork file a game ended up with (iGame.iff / igame1.iff / igame2.iff:
# which one depends on ART_ORDER, so tests must not assume the first)
art_file() { cat "$1"/iGame.iff "$1"/igame1.iff "$1"/igame2.iff 2>/dev/null | head -1; }
has_art()  { [ -n "$(art_file "$1")" ]; }
art_in() { cat "$ROOT/build/$1"/iGame.iff "$ROOT/build/$1"/igame1.iff "$ROOT/build/$1"/igame2.iff 2>/dev/null | head -1; }
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
acfg STATE_BACKUP '"yes"'      # off by default; this section tests the feature itself
server_add WHDLoad/Games/Q/QueuedGame_v1.0.lha
run q_upd ./update.sh
run q_rtg ./all.sh --skip-update --variants rtg          # takes a backup; aga/ecs keep QueuedGame queued
check "rolling state backups are kept" '[ -n "$(ls "$ROOT"/.retroplay_backups/state-*.tgz 2>/dev/null)" ]'
rm -rf "$ROOT/.retroplay"
run restore ./all.sh --skip-update --variants aga; st=$?
check "lost state folder is restored, and its queued download still gets installed" \
  '[ "$st" -eq 0 ] && grep -q "restored it from" "$T/restore.log" && [ -n "$(game retro_aga QueuedGame)" ]'
run drain ./all.sh --skip-update
acfg STATE_BACKUP '"no"'

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
cp "$REPO"/*.sh "$REPO"/to_ilbm.py "$REPO"/retroplay.conf.example "$S"/ 2>/dev/null; chmod +x "$S"/*.sh
for d in /usr/bin /bin; do for f in "$d"/*; do n="${f##*/}"
    case "$n" in lha|7z|7za|unar|lsar|unlzx|wget|curl|unzip|flock|detox|locale|locale-gen|crontab|apt-get|dpkg-query|sudo) continue ;; esac
    [ -e "$SB/$n" ] || ln -s "$f" "$SB/$n"; done; done
printf '#!/bin/sh\n[ "$1" = x ] && printf "#include <stdio.h>\\nint main(void){puts(\\"unlzx test build\\");return 0;}\\n" > unlzx.c\nexit 0\n' > "$SM/stub_lha"
# the unlzx source is fetched as plain C now; anything else is a stub file
cat > "$SM/stub_curl" << 'CURLEOF'
#!/bin/sh
o=""; p=""; for a in "$@"; do [ "$p" = "-o" ] && o="$a"; p="$a"; done
[ -n "$o" ] || exit 0
case "$*" in
  *unlzx.c.gz*) exit 22 ;;                      # pretend Aminet is unreachable
  *unlzx.c*) printf '/* unlzx */\n#include <stdio.h>\nint main(void){puts("unlzx test build");return 0;}\n' > "$o" ;;
  *) echo archive > "$o" ;;
esac
exit 0
CURLEOF
printf '#!/bin/sh\nexit 0\n' > "$SM/stub_generic"
cat > "$SM/apt-get" << EOF
#!/usr/bin/env bash
echo "apt-get \$*" >> "$SM/apt_calls"
# the real apt-get takes options before the verb (e.g. -o DPkg::Lock::Timeout)
case " \$* " in *" install "*) ;; *) exit 0 ;; esac
for p in "\$@"; do
  case "\$p" in install|-y|-qq|-o|DPkg::Lock::Timeout=*) continue ;; esac
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
        RP_LOCALE_GEN_FILE="$SM/locale.gen" RP_INSTALL_BIN="$IB" RP_UNLZX_URL="http://mock/unlzx.c" \
        bash ./setup.sh --yes --no-cron ) < /dev/null > "$T/$1.log" 2>&1
}
setup_run setup1
check "missing tools installed with one apt-get call, and recorded for uninstalling" \
  '[ "$(grep -c "install -y" "$SM/apt_calls")" -eq 1 ] && grep -q "apt:lhasa" "$S/.retroplay_installed_deps.log" && grep -q "apt:p7zip-full" "$S/.retroplay_installed_deps.log"'
check "unlzx downloaded, compiled, installed and recorded" \
  '[ "$("$IB/unlzx")" = "unlzx test build" ] && grep -q "source-build:$IB/unlzx" "$S/.retroplay_installed_deps.log"'
check "the missing locale was enabled" 'grep -qx "en_US ISO-8859-1" "$SM/locale.gen"'
check "retroplay.conf created with the default variants (the same five all.sh builds)" \
  'grep -qx "VARIANTS=\"aga ecs rtg aga-laced ecs-laced\"" "$S/retroplay.conf"'
check "...and the artwork packs those variants need" \
  'grep -qx "ARTWORK_PACKS=\"AGA ECS RTG AGA_Laced ECS_Laced\"" "$S/retroplay.conf"'
check "setup says what five collections cost before it asks" \
  'grep -q "five times the" "$ROOT/setup.sh"'
calls_before="$(wc -l < "$SM/apt_calls")"
setup_run setup2
check "running it again changes nothing (no new installs)" '[ "$(wc -l < "$SM/apt_calls")" -eq "$calls_before" ] && grep -q "retroplay.conf already exists" "$T/setup2.log"'


section "29. Artwork: the published archives, mapped into the right folders"
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
  'has_art "$ROOT/artwork/iGame_AGA/lores/Covers/Games/A" && has_art "$ROOT/artwork/iGame_AGA/lores/Screens/Games/A" && has_art "$ROOT/artwork/iGame_AGA/lores/Titles/Games/A"'
run artlaced ./artwork_sync.sh --sync --for aga-laced --for rtg --yes; st=$?
check "laced and RTG go to their own folders" \
  '[ "$st" -eq 0 ] && has_art "$ROOT/artwork/iGame_AGA/laced/Covers/Games/A" && has_art "$ROOT/artwork/iGame_RTG/Covers/Games/A" && [ ! -e "$ROOT/artwork/iGame_RTG/lores" ]'
check "archives are cached in downloads/artwork_archive, not in the artwork folders" \
  '[ -f "$ROOT/downloads/artwork_archive/IGame_Covers_AGA_LoRes.lha" ] && [ -z "$(find "$ROOT/artwork" -name "*.lha" | head -1)" ]'
: > "$MOCK/art_downloads"
run artagain ./artwork_sync.sh --sync --for aga --yes; st=$?
check "nothing new upstream: no downloads, exit 2" '[ "$st" -eq 2 ] && [ ! -s "$MOCK/art_downloads" ]'
run artall ./artwork_sync.sh --sync --all-artwork --yes
check "--all-artwork installs every flavour, including TinyLauncher" \
  'has_art "$ROOT/artwork/iGame_ECS/laced/Titles/Games/A" && has_art "$ROOT/artwork/iGame_ECS/lores/Covers/Games/A" && [ -d "$ROOT/artwork/TinyLauncher" ]'

section "30. Artwork: updates, refusals, local changes and rollback"
printf 'A\nIGame_Covers_AGA_LoRes.lha\nnewer\n' > "$ARTSRC/IGame_Covers_AGA_LoRes.lha"
run artupd ./artwork_sync.sh --sync --for aga --yes; st=$?
check "a newer archive for the tool's own pack installs straight over the old one" \
  '[ "$st" -eq 0 ] && has_art "$ROOT/artwork/iGame_AGA/lores/Covers/Games/A"'
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
# iGame_AGA/ECS/RTG belong to the tool: always replaced, no backup kept
echo "will be replaced" > "$ROOT/artwork/iGame_RTG/Covers/STALE.txt"
printf 'A\nIGame_Covers_RTG.lha\nnewer\n' > "$ARTSRC/IGame_Covers_RTG.lha"
run artowned ./artwork_sync.sh --sync --for rtg --yes
check "the tool's own packs are replaced outright, not called 'changed by you'" \
  '! grep -q "left alone" "$T/artowned.log" && ! grep -q "changed" "$T/artowned.log" && [ ! -e "$ROOT/artwork/iGame_RTG/Covers/STALE.txt" ]'
check "...and no backup is kept for them" \
  '[ -z "$(ls -d "$ROOT/.retroplay/artwork/backups/iGame_RTG_Covers"/*/ 2>/dev/null)" ]'
# TinyLauncher is the tool's too: replaced, not protected
mkdir -p "$ROOT/artwork/TinyLauncher"; echo stale > "$ROOT/artwork/TinyLauncher/STALE.txt"
printf 'B\nTinyLauncher.lha\nnewer\n' > "$ARTSRC/TinyLauncher.lha"
run artTL ./artwork_sync.sh --sync --tinylauncher --yes
check "TinyLauncher is replaced outright too, with no backup" \
  '[ ! -e "$ROOT/artwork/TinyLauncher/STALE.txt" ] && ! grep -q "left alone" "$T/artTL.log" && [ -z "$(ls -d "$ROOT/.retroplay/artwork/backups/TinyLauncher"/*/ 2>/dev/null)" ]'
# a pack of your own IS still protected
mkdir -p "$ROOT/artwork/iGame_art"; echo mine > "$ROOT/artwork/iGame_art/MY_NOTES.txt"
run artlocal ./artwork_sync.sh --sync --set art --yes
check "a pack of your own is still left alone" '[ -f "$ROOT/artwork/iGame_art/MY_NOTES.txt" ]'
run artroll ./artwork_sync.sh --rollback iGame_art --yes; st=$?
check "rollback still works for a pack that keeps backups" \
  '{ [ "$st" -eq 0 ] || [ "$st" -eq 2 ]; } && [ -d "$ROOT/artwork/iGame_art" ]'
run artverify ./artwork_sync.sh --verify --all-artwork
check "verify reports and changes nothing" 'grep -q "Artwork check" "$T/artverify.log" && has_art "$ROOT/artwork/iGame_RTG/Covers/Games/A"'

section "31. Scheduled run: artwork first, one lock, safe failure policies"
acfg ARTWORK_SYNC '"auto"'
printf 'B\nIGame_Covers_AGA_LoRes.lha\nfixed for the cron test\n' > "$ARTSRC/IGame_Covers_AGA_LoRes.lha"
rm -f "$ROOT/.retroplay/artwork_last_check"; : > "$ROOT/logs/all_cron.log"
run cronart ./all.sh --cron --skip-update --variants aga; st=$?
check "the cron run completes - one lock, no deadlock" '[ "$st" -eq 0 ] || [ "$st" -eq 2 ]'
check "artwork is checked before the collection pipeline" \
  'a="$(grep -n "  Artwork: " "$ROOT/logs/all_cron.log" | head -1 | cut -d: -f1)"
   p="$(grep -n "\] Plan" "$ROOT/logs/all_cron.log" | head -1 | cut -d: -f1)"
   [ -n "$a" ] && [ -n "$p" ] && [ "$a" -lt "$p" ]'
rm -f "$ROOT/.retroplay/artwork_last_check"
printf 'CORRUPT\nIGame_Screens_AGA_LoRes.lha\nbroken\n' > "$ARTSRC/IGame_Screens_AGA_LoRes.lha"
acfg ARTWORK_FAILURE_POLICY '"warn-and-continue"'
run cronwarn ./all.sh --cron --skip-update --variants aga; st=$?
check "artwork failure (warn-and-continue): the collection sync still runs" '[ "$st" -eq 0 ] || [ "$st" -eq 2 ]'
check "...and the previous artwork is kept" 'has_art "$ROOT/artwork/iGame_AGA/lores/Screens/Games/A"'
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
cp "$REPO"/*.sh "$REPO"/to_ilbm.py "$REPO"/retroplay.conf.example "$OLD"/; chmod +x "$OLD"/*.sh
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
cp "$REPO"/*.sh "$REPO"/to_ilbm.py "$REPO"/retroplay.conf.example "$SUB/scripts"/; chmod +x "$SUB/scripts"/*.sh
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
rm -rf "$ROOT/downloads/artwork_archive"      # force a real fetch for this check
run artdefault2 ./artwork_sync.sh --sync --yes; st=$?
check "with no --for, both flavours AND TinyLauncher are fetched" \
  '[ "$st" -eq 0 ] && [ "$(grep "_Laced" "$MOCK/art_downloads" | sort -u | grep -c .)" -eq 6 ] && [ "$(grep "_LoRes" "$MOCK/art_downloads" | sort -u | grep -c .)" -eq 6 ] && grep -q "download TinyLauncher.lha" "$MOCK/art_downloads"'
check "the Laced folders are created alongside lores" \
  'has_art "$ROOT/artwork/iGame_AGA/laced/Covers/Games/A" && has_art "$ROOT/artwork/iGame_ECS/laced/Titles/Games/A" && [ -d "$ROOT/artwork/iGame_AGA/lores" ]'
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
  'grep -q "Found 4 game(s) to check for artwork" "$T/mergereal.log"'
check "AGA build uses the lores artwork, Screens first (the default order)" \
  '[ "$(art_file "$MG/build/retro_aga/WHDLoad/Games/S/Superfrog")" = "AGA-lores-Screens" ]'
check "fallbacks still work (RTG pack, then the art pack)" \
  'has_art "$MG/build/retro_aga/WHDLoad/Games/Z/Zool" && [ "$(art_file "$MG/build/retro_aga/WHDLoad/Games/A/Apidya")" = ART-Apidya ]'
check "only the game with no artwork anywhere is reported missing" \
  '[ "$(grep -c . "$MG/missing.txt")" -eq 1 ] && grep -q Nothing "$MG/missing.txt"'
find "$MG/build/retro_aga" -name 'iGame*.iff' -delete    # merge never overwrites existing artwork
( cd "$MG" && bash merge.sh --aga-laced -d build/retro_aga > /dev/null 2>&1 )
check "--aga-laced uses the laced artwork" '[ "$(art_file "$MG/build/retro_aga/WHDLoad/Games/S/Superfrog")" = "AGA-laced-Screens" ]'

section "35. Saved backups can be cleared at the end of a hands-on run"
run nobk ./all.sh --skip-update --variants aga; st=$?
check "an unattended run never asks about deleting backups" \
  '{ [ "$st" -eq 0 ] || [ "$st" -eq 2 ]; } && ! grep -q "Delete them?" "$T/nobk.log"'


section "36. Only real games are looked up (drawers and version wrappers)"
GD="$T/gamedirs"; setup mkdir -p "$GD"
cp "$ROOT/merge.sh" "$ROOT/lib.sh" "$GD/"
mkgame() {   # a WHDLoad game: folder + icon + slave
    setup mkdir -p "$GD/build/retro_aga/WHDLoad/$1"; touch "$GD/build/retro_aga/WHDLoad/$1.info"; echo s > "$GD/build/retro_aga/WHDLoad/$1/game.slave"
}
mkdrawer() { setup mkdir -p "$GD/build/retro_aga/WHDLoad/$1"; touch "$GD/build/retro_aga/WHDLoad/$1.info"; }   # drawer WITH an icon, as archives ship
mkart() { setup mkdir -p "$GD/artwork/iGame_AGA/lores/Covers/Games/$2/$1"; echo "art-$1" > "$GD/artwork/iGame_AGA/lores/Covers/Games/$2/$1/iGame.iff"; }
mkgame Games/E/Elvira;            mkdrawer Games/E/Elvira/Maps
mkgame Games/O/Obitus;            mkdrawer Games/O/Obitus/MapsFr; mkdrawer Games/O/Obitus/MapsFr/CATACOMBES
mkgame Games/S/SimCity;           setup mkdir -p "$GD/build/retro_aga/WHDLoad/Games/S/SimCity/data"
mkgame Languages/German/Games/E/ElviraDe;  mkdrawer Languages/German/Games/E/ElviraDe/Maps
mkgame NTSC/Games/B/BardsTaleNTSC
# version wrapper: only the game folder inside, no files of its own
mkdrawer "Games/M/Might&Magic3_v1.2_2346"; mkgame "Games/M/Might&Magic3_v1.2_2346/Might&Magic3"
for a in Elvira:E Obitus:O SimCity:S ElviraDe:E BardsTaleNTSC:B; do mkart "${a%%:*}" "${a##*:}"; done
mkart "Might&Magic3" M
( cd "$GD" && bash merge.sh --aga -d build/retro_aga --report-missing missing.txt ) > "$T/gamedirs.log" 2>&1
check "drawers inside a game (Maps, MapsFr/CATACOMBES, data) are not games" \
  'grep -q "Found 6 game(s)" "$T/gamedirs.log"'
check "nothing is wrongly reported as having no artwork" '[ ! -s "$GD/missing.txt" ]'
check "a version wrapper resolves to the game inside it, so its artwork is found" \
  'has_art "$GD/build/retro_aga/WHDLoad/Games/M/Might&Magic3_v1.2_2346/Might&Magic3" && [ ! -e "$GD/build/retro_aga/WHDLoad/Games/M/Might&Magic3_v1.2_2346/iGame.iff" ]'
check "games sorted into Languages/ and NTSC/ are still found" \
  'has_art "$GD/build/retro_aga/WHDLoad/Languages/German/Games/E/ElviraDe" && has_art "$GD/build/retro_aga/WHDLoad/NTSC/Games/B/BardsTaleNTSC"'
check "no artwork is put inside a drawer" '[ ! -e "$GD/build/retro_aga/WHDLoad/Games/E/Elvira/Maps/iGame.iff" ]'


section "37. Artwork found despite capitalisation and older flat layouts"
CS="$T/caseflat"; setup mkdir -p "$CS"
cp "$ROOT/merge.sh" "$ROOT/lib.sh" "$CS/"
g() { setup mkdir -p "$CS/build/retro_aga/WHDLoad/Games/$2/$1"; touch "$CS/build/retro_aga/WHDLoad/Games/$2/$1.info"; echo s > "$CS/build/retro_aga/WHDLoad/Games/$2/$1/g.slave"; }
g SuperSkidmarks S; g Zool Z; g Apidya A
# pack spells it in capitals; the collection does not
setup mkdir -p "$CS/artwork/iGame_AGA/lores/Covers/Games/S/SUPERSKIDMARKS"
echo caps > "$CS/artwork/iGame_AGA/lores/Covers/Games/S/SUPERSKIDMARKS/iGame.iff"
# artwork installed the older flat way, only for Zool
setup mkdir -p "$CS/artwork/iGame_AGA/Covers/Games/Z/Zool"
echo flat > "$CS/artwork/iGame_AGA/Covers/Games/Z/Zool/iGame.iff"
( cd "$CS" && bash merge.sh --aga -d build/retro_aga --report-missing missing.txt ) > "$T/caseflat.log" 2>&1
check "a pack folder spelled with different capitals is still matched" \
  '[ "$(art_file "$CS/build/retro_aga/WHDLoad/Games/S/SuperSkidmarks")" = caps ]'
check "artwork installed the older flat way is still used" \
  '[ "$(art_file "$CS/build/retro_aga/WHDLoad/Games/Z/Zool")" = flat ]'
check "a game with no artwork anywhere is the only one reported" \
  '[ "$(grep -c . "$CS/missing.txt")" -eq 1 ] && grep -q Apidya "$CS/missing.txt"'
( cd "$CS" && bash merge.sh --aga -d build/retro_aga --why SuperSkidmarks ) > "$T/why.log" 2>&1
check "--why explains where it looked and what is on disk" \
  'grep -q "Sets tried, in order" "$T/why.log" && grep -q "SUPERSKIDMARKS" "$T/why.log"'


section "38. The 'artwork not installed' message is specific and reassuring"
AM="$T/artmsg"; setup mkdir -p "$AM/none"
sed -n '/^# Artwork check - the same one/,/^fi$/p' "$ROOT/update.sh" > "$AM/block.sh"
artmsg() {   # artmsg <artwork root> <ARTWORK_SYNC>
    # the block calls rp_artwork_missing, so it needs lib.sh loaded
    { echo 'SCRIPT_DIR="'"$ROOT"'"; . "$SCRIPT_DIR/lib.sh"; rp_load_config >/dev/null 2>&1'
      echo 'RP_ARTWORK_ROOT="'"$1"'"; RP_ARTWORK_SYNC="'"$2"'"; RP_VARIANTS="aga aga-laced ecs ecs-laced rtg"'
      echo 'RP_ARTWORK_SOURCE_URL="http://mock/WHDLoad_Images"'
      cat "$AM/block.sh"; } > "$AM/run.sh"
    bash "$AM/run.sh"
}
artmsg "$AM/none" ask > "$AM/ask.log" 2>&1
check "it names each missing pack and flavour, not a vague list" \
  'grep -q "iGame_AGA/lores" "$AM/ask.log" && grep -q "iGame_AGA/laced" "$AM/ask.log" && grep -q "iGame_ECS/lores" "$AM/ask.log" && grep -q "iGame_RTG" "$AM/ask.log"'
check "it says they will be downloaded for you, and how to do it now" \
  'grep -q "Don.t worry" "$AM/ask.log" && grep -q -- "--artwork-sync" "$AM/ask.log"'
check "it no longer sends you to a forum thread" '! grep -q "eab.abime.net" "$AM/ask.log"'
artmsg "$AM/none" auto > "$AM/auto.log" 2>&1
check "it says all.sh fetches them before building" \
  'grep -q "before it builds" "$AM/auto.log"'
for p in iGame_AGA/lores/Covers iGame_AGA/laced/Covers iGame_ECS/lores/Screens iGame_ECS/laced/Screens iGame_RTG/Titles; do setup mkdir -p "$AM/full/$p"; done
artmsg "$AM/full" auto > "$AM/full.log" 2>&1
check "nothing is said once the artwork is installed" '[ ! -s "$AM/full.log" ]'
for p in iGame_AGA/Covers iGame_ECS/Covers iGame_RTG/Covers; do setup mkdir -p "$AM/flat/$p"; done
artmsg "$AM/flat" auto > "$AM/flat.log" 2>&1
check "artwork installed the older flat way counts as present" '[ ! -s "$AM/flat.log" ]'


section "39. The state backup stays small (artwork copies are not tarred)"
acfg STATE_BACKUP '"yes"'
setup mkdir -p "$ROOT/.retroplay/artwork/backups/iGame_AGA_lores_Covers/20260101-000000/Games/A"
dd if=/dev/zero of="$ROOT/.retroplay/artwork/backups/iGame_AGA_lores_Covers/20260101-000000/Games/A/big.iff" bs=1024 count=4096 2>/dev/null
setup mkdir -p "$ROOT/.retroplay/stage/leftover"
dd if=/dev/zero of="$ROOT/.retroplay/stage/leftover/big2.bin" bs=1024 count=4096 2>/dev/null
rm -f "$ROOT"/.retroplay_backups/state-*.tgz
run bkslim ./all.sh --skip-update --variants aga
newest="$(ls -1 "$ROOT"/.retroplay_backups/state-*.tgz 2>/dev/null | sort | tail -1)"
check "a backup is still made" '[ -n "$newest" ]'
check "it does not contain the artwork backups or the staging folder" \
  '! tar -tzf "$newest" | grep -q "artwork/backups" && ! tar -tzf "$newest" | grep -q "stage/leftover"'
check "it still contains the queue and build markers" \
  'tar -tzf "$newest" | grep -q ".retroplay/complete"'
check "so it stays small (well under a megabyte)" '[ "$(wc -c < "$newest")" -lt 1000000 ]'
rm -rf "$ROOT/.retroplay/artwork/backups/iGame_AGA_lores_Covers" "$ROOT/.retroplay/stage/leftover"
check "step 1 says what it is doing rather than sitting silent" \
  'grep -q "checking the output folder is there" "$T/bkslim.log" && grep -q "tidying leftovers" "$T/bkslim.log"'
acfg STATE_BACKUP '"no"'


section "40. .retroplay is tidied each run, keeping only what matters"
ST="$ROOT/.retroplay"
# leftovers from an interrupted run, plus old artwork backups
setup mkdir -p "$ST/stage/src_old" "$ST/artwork/work/iGame_AGA_lores_Covers.999" "$ST/artwork_changed"
dd if=/dev/zero of="$ST/stage/src_old/junk.bin" bs=1024 count=2048 2>/dev/null
: > "$ST/artwork_changed/iGame_AGA_lores_Covers"
: > "$ST/artwork/remote_cache/.listing.raw.999"
for n in 1 2 3 4; do setup mkdir -p "$ST/artwork/backups/iGame_AGA_lores_Covers/2026010$n-000000"; done
: > "$ST/queue/retro_empty.list"
printf '2\tWHDLoad/Games/G/GoneAway_v1.0.lha\n' > "$ST/extract_attempts.list"
# things that MUST survive
: > "$ST/complete/keepme"; printf 'WHDLoad/Games/K/Keep_v1.0.lha\n' > "$ST/queue/retro_keep.list"
setup mkdir -p "$ST/artwork/manifests"; : > "$ST/artwork/manifests/iGame_AGA_lores_Covers.meta"
run tidy ./all.sh --skip-update --variants aga
check "staging and work leftovers are removed" \
  '[ ! -e "$ST/stage" ] && [ ! -e "$ST/artwork/work/iGame_AGA_lores_Covers.999" ] && [ ! -e "$ST/artwork/remote_cache/.listing.raw.999" ]'
check "old artwork backups are trimmed to ARTWORK_KEEP_BACKUPS" \
  '[ "$(ls -1d "$ST"/artwork/backups/iGame_AGA_lores_Covers/*/ 2>/dev/null | grep -c .)" -le 2 ]'
check "attempt counts for archives that no longer exist are dropped" \
  '! grep -qs GoneAway "$ST/extract_attempts.list"'
check "empty queue files are cleared away" '[ ! -e "$ST/queue/retro_empty.list" ]'
check "the queue, build markers and artwork manifests all survive" \
  '[ -f "$ST/queue/retro_keep.list" ] && [ -f "$ST/complete/keepme" ] && [ -f "$ST/artwork/manifests/iGame_AGA_lores_Covers.meta" ]'
check "it says how much it freed" 'grep -q "tidied .retroplay" "$T/tidy.log"'


section "41. Backups, artwork refresh, re-download check and the PFS reminder"
# --- .retroplay is no longer backed up ---
rm -f "$ROOT"/.retroplay_backups/state-*.tgz 2>/dev/null
run nobackup ./all.sh --skip-update --variants aga
check "the state folder is not backed up any more" \
  '[ -z "$(ls "$ROOT"/.retroplay_backups/state-*.tgz 2>/dev/null)" ]'
acfg STATE_BACKUP '"yes"'
run withbackup ./all.sh --skip-update --variants aga
check "STATE_BACKUP=\"yes\" brings the rolling copies back" \
  '[ -n "$(ls "$ROOT"/.retroplay_backups/state-*.tgz 2>/dev/null)" ]'
acfg STATE_BACKUP '"no"'

# --- refreshing artwork already in the collection ---
RF="$T/refresh"; setup mkdir -p "$RF"
cp "$ROOT/merge.sh" "$ROOT/lib.sh" "$RF/"
setup mkdir -p "$RF/build/retro_aga/WHDLoad/Games/E/Elvira" "$RF/artwork/iGame_AGA/lores/Covers/Games/E/Elvira"
touch "$RF/build/retro_aga/WHDLoad/Games/E/Elvira.info"; echo s > "$RF/build/retro_aga/WHDLoad/Games/E/Elvira/g.slave"
setup mkdir -p "$RF/artwork/iGame_AGA/lores/Screens/Games/E/Elvira"
echo new-iff  > "$RF/artwork/iGame_AGA/lores/Screens/Games/E/Elvira/iGame.iff"
echo new-data > "$RF/artwork/iGame_AGA/lores/Screens/Games/E/Elvira/iGame.data"
echo old-iff  > "$RF/build/retro_aga/WHDLoad/Games/E/Elvira/iGame.iff"
echo old-data > "$RF/build/retro_aga/WHDLoad/Games/E/Elvira/iGame.data"
( cd "$RF" && bash merge.sh --aga -d build/retro_aga ) > /dev/null 2>&1
check "a normal merge refreshes both the .iff and the .data" \
  '[ "$(art_file "$RF/build/retro_aga/WHDLoad/Games/E/Elvira")" = new-iff ] && [ "$(cat "$RF/build/retro_aga/WHDLoad/Games/E/Elvira/iGame.data" 2>/dev/null)" = new-data ]'
echo older-again > "$RF/build/retro_aga/WHDLoad/Games/E/Elvira/iGame.data"
( cd "$RF" && bash merge.sh --aga -d build/retro_aga --refresh-artwork ) > /dev/null 2>&1
check "--refresh-artwork works on merge.sh too" \
  '[ "$(cat "$RF/build/retro_aga/WHDLoad/Games/E/Elvira/iGame.data")" = new-data ]'
( cd "$RF" && bash merge.sh --aga -d build/retro_aga ) > "$T/mergemode.log" 2>&1
check "merge says which mode it is in and how many files it wrote" \
  'grep -q "Mode: refreshing" "$T/mergemode.log" && grep -q "Artwork files refreshed:" "$T/mergemode.log"'
( cd "$RF" && bash merge.sh --aga -d build/retro_aga --only-missing ) > "$T/mergegap.log" 2>&1
check "--only-missing says it is filling gaps only" 'grep -q "Mode: filling gaps only" "$T/mergegap.log"'

# --- an archive already downloaded is not fetched again ---
: > "$MOCK/art_downloads"
run artagain2 ./artwork_sync.sh --sync --for rtg --yes
check "nothing is downloaded when the cached archives match the source" \
  '[ ! -s "$MOCK/art_downloads" ]'
rm -rf "$ROOT/.retroplay/artwork/manifests"     # state lost, but the archives are still here
: > "$MOCK/art_downloads"
run artcached ./artwork_sync.sh --sync --for rtg --yes
check "even with no record of them, matching archives are reused not re-downloaded" \
  'grep -q "already downloaded and unchanged" "$T/artcached.log" && [ ! -s "$MOCK/art_downloads" ]'

# --- the PFS warning ---
acfg FILESYSTEM '"pfs"'
run pfsmsg ./all.sh --skip-update --variants aga
check "a PFS build ends with the setfnsize warning" \
  'grep -q "setfnsize <drive:> 107" "$T/pfsmsg.log" && grep -q "CAN CORRUPT THAT PARTITION" "$T/pfsmsg.log"'
check "...and nothing else follows it (it is the last thing on screen)" \
  '! tail -n +"$(grep -n "setfnsize <drive:> 107" "$T/pfsmsg.log" | cut -d: -f1)" "$T/pfsmsg.log" | grep -qE "Summary|saved as reports"'
# and with a run that does print a summary
echo stale > "$ROOT/build/retro_aga/WHDLoad/Games/A/Alpha/iGame.data"
run pfsorder ./all.sh --skip-update --variants aga --refresh-artwork
check "after a summary, the warning still comes last" \
  'grep -q "Summary" "$T/pfsorder.log" && [ "$(grep -n "setfnsize <drive:> 107" "$T/pfsorder.log" | cut -d: -f1)" -gt "$(grep -n "Summary" "$T/pfsorder.log" | tail -1 | cut -d: -f1)" ]'
acfg FILESYSTEM '"ffs"'
run ffsmsg ./all.sh --skip-update --variants aga
check "an FFS build does not show it" '! grep -q "setfnsize" "$T/ffsmsg.log"'
acfg FILESYSTEM '"pfs"'


section "42. --refresh-artwork works from all.sh and start.sh, with messages"
# a game the gap-fill would skip, whose artwork has since changed
G2="$ROOT/build/retro_aga/WHDLoad/Games/A/Alpha"
echo stale > "$G2/iGame.iff"; echo stale > "$G2/iGame.data"
setup mkdir -p "$ROOT/artwork/iGame_AGA/lores/Covers/Games/A/Alpha"
echo fresh > "$ROOT/artwork/iGame_AGA/lores/Covers/Games/A/Alpha/iGame.iff"
echo freshdata > "$ROOT/artwork/iGame_AGA/lores/Covers/Games/A/Alpha/iGame.data"
run refreshall ./all.sh --skip-update --variants aga --refresh-artwork; st=$?
check "all.sh --refresh-artwork runs and says what it is doing" \
  '{ [ "$st" -eq 0 ] || [ "$st" -eq 2 ]; } && grep -q "refreshing artwork for retro_aga" "$T/refreshall.log"'
check "...and every game is refreshed, not just the ones missing artwork" \
  '[ "$(art_file "$G2")" = fresh ] && [ "$(cat "$G2/iGame.data" 2>/dev/null)" = freshdata ]'
check "...and it reports how many files it wrote" 'grep -q "Artwork files refreshed:" "$T/refreshall.log"'
echo stale2 > "$G2/iGame.data"
run refreshstart ./start.sh --merge --aga --refresh-artwork --dest "$ROOT/build/retro_aga"; st=$?
check "start.sh --merge --refresh-artwork does the same" \
  '[ "$st" -eq 0 ] && [ "$(cat "$G2/iGame.data")" = freshdata ]'


section "43. Artwork found elsewhere is converted to IFF and installed"
# A stand-in for whatever you plug in: writes a picture for known games only.
cat > "$MOCK/findart" << 'EOF'
#!/usr/bin/env bash
game="$1"; out="$2"
case "$game" in
    *NoSuchGame*) exit 1 ;;                       # nothing found
    *NotAPicture*) echo "this is not an image" > "$out"; exit 0 ;;
esac
python3 -c "
from PIL import Image
im = Image.new('RGB', (600, 400))
for x in range(600):
    for y in range(0, 400, 40): im.putpixel((x, y), (x % 256, y % 256, 128))
im.save('$out')
" 2>/dev/null || exit 1
EOF
chmod +x "$MOCK/findart"
if ! python3 -c 'import PIL' 2>/dev/null; then
    echo "  (skipped: python3-pil is not installed here)"
else
    FA="$T/fetch"; setup mkdir -p "$FA/build/retro_aga/WHDLoad/Games/N/NoArtGame" "$FA/artwork/iGame_AGA/lores/Covers/Games/R/Ref"
    cp "$ROOT"/*.sh "$REPO/to_ilbm.py" "$FA/"
    touch "$FA/build/retro_aga/WHDLoad/Games/N/NoArtGame.info"
    # a reference iff, so what we add matches the artwork already in use
    python3 -c "from PIL import Image; Image.new('RGB',(320,128),(1,2,3)).save('$T/ref.png')"
    python3 "$REPO/to_ilbm.py" "$T/ref.png" "$FA/artwork/iGame_AGA/lores/Covers/Games/R/Ref/iGame.iff" --width 320 --height 128 --planes 8 >/dev/null 2>&1
    printf 'WHDLoad/Games/N/NoArtGame\nWHDLoad/Games/X/NoSuchGame\nWHDLoad/Games/Y/NotAPicture\n' > "$FA/missing.txt"
    cat > "$FA/retroplay.conf" << EOF
ARTWORK_FETCH="yes"
ARTWORK_FETCH_COMMAND="$MOCK/findart"
ARTWORK_FETCH_LIMIT=10
EOF
    ( cd "$FA" && ./artwork_fetch.sh --list missing.txt --variant retro_aga --dest build/retro_aga ) > "$T/fetch.log" 2>&1
    check "it says what it is doing, game by game" \
      'grep -q "NoArtGame: searching" "$T/fetch.log" && grep -q "found - converted and installed" "$T/fetch.log"'
    check "a game it cannot find is reported, not silently skipped" 'grep -q "nothing found" "$T/fetch.log"'
    check "something that is not a picture is rejected" 'grep -q "not an image" "$T/fetch.log"'
    check "the result is a real IFF ILBM, matching the artwork already in use" \
      'has_art "$FA/artwork/iGame_art/NoArtGame" && [ "$(head -c 4 "$FA/artwork/iGame_art/NoArtGame/iGame.iff")" = FORM ] && python3 -c "
import sys; sys.path.insert(0, \"$ROOT\")
from to_ilbm import read_bmhd
w,h,p = read_bmhd(\"$FA/artwork/iGame_art/NoArtGame/iGame.iff\")
sys.exit(0 if (w,h,p) == (320,128,8) else 1)"'
    check "it is installed into the collection as well" 'has_art "$FA/build/retro_aga/WHDLoad/Games/N/NoArtGame"'
    check "and saved in your own pack, which artwork updates never overwrite" \
      '[ -d "$FA/artwork/iGame_art/NoArtGame" ]'
    check "the totals are reported" \
      'grep -q "Artwork found and installed: 1" "$T/fetch.log" && grep -q "Still without artwork:       2" "$T/fetch.log"'
    # Counts reach all.sh through a key=value file, never by grepping the
    # console text: rewording a message must not change a reported figure.
    cat > "$FA/retroplay.conf" << EOF
ARTWORK_FETCH="yes"
ARTWORK_FETCH_COMMAND="$MOCK/findart"
ARTWORK_FETCH_LIMIT=10
EOF
    sed 's/Artwork found and installed:/Pictures we managed to dig up:/' "$FA/artwork_fetch.sh" > "$FA/artwork_fetch_reworded.sh"
    chmod +x "$FA/artwork_fetch_reworded.sh"
    ( cd "$FA" && RP_RESULT_FILE="$T/fetch_result" ./artwork_fetch_reworded.sh --list missing.txt --variant retro_aga --dest build/retro_aga ) > "$T/fetch2.log" 2>&1
    check "the counts come from a result file, not from the wording" \
      'grep -qx "found=1" "$T/fetch_result" && grep -qx "failed=2" "$T/fetch_result" && grep -q "Pictures we managed" "$T/fetch2.log"'
    check "...and all.sh reads that file rather than the child's output" \
      '! grep -q "sed -n .s/.*Artwork found and installed" "$ROOT/all.sh" && grep -q "RP_RESULT_FILE=" "$ROOT/all.sh"'

    # off by default
    printf 'ARTWORK_FETCH="no"\n' > "$FA/retroplay.conf"
    ( cd "$FA" && ./artwork_fetch.sh --list missing.txt --variant retro_aga --dest build/retro_aga ) > "$T/fetchoff.log" 2>&1
    check "it does nothing unless you turn it on" '! grep -q "Looking for artwork" "$T/fetchoff.log"'
fi


section "44. Running the leaf scripts by hand finds the right collection"
DC="$T/defaultdest"; setup mkdir -p "$DC"
cp "$ROOT"/*.sh "$REPO/to_ilbm.py" "$DC/"
setup mkdir -p "$DC/build/retro_aga/WHDLoad/Games/A/Alpha" "$DC/artwork/iGame_AGA/lores/Covers/Games/A/Alpha"
touch "$DC/build/retro_aga/WHDLoad/Games/A/Alpha.info"; echo s > "$DC/build/retro_aga/WHDLoad/Games/A/Alpha/g.slave"
echo art > "$DC/artwork/iGame_AGA/lores/Covers/Games/A/Alpha/iGame.iff"
( cd "$DC" && bash merge.sh --refresh-artwork ) > "$T/dd_merge.log" 2>&1; st=$?
check "merge.sh with no --dest uses the collection that is there" \
  '[ "$st" -eq 0 ] && grep -q "Using collection: retro_aga" "$T/dd_merge.log" && has_art "$DC/build/retro_aga/WHDLoad/Games/A/Alpha"'
( cd "$DC" && bash sort.sh --no-detox ) > "$T/dd_sort.log" 2>&1; st=$?
check "sort.sh with no --dest does the same" \
  '[ "$st" -eq 0 ] && grep -q "Using collection: retro_aga" "$T/dd_sort.log"'
setup mkdir -p "$DC/build/retro_ecs/WHDLoad" "$DC/build/retro_rtg/WHDLoad"
( cd "$DC" && bash merge.sh --ecs --refresh-artwork ) > "$T/dd_ecs.log" 2>&1
check "naming a variant picks that collection (--ecs -> retro_ecs)" 'grep -q "Using collection: retro_ecs" "$T/dd_ecs.log"'
( cd "$DC" && bash sort.sh --no-detox ) > "$T/dd_many.log" 2>&1; st=$?
check "with several collections and no hint, it says so instead of guessing" \
  '[ "$st" -eq 4 ] && grep -q "more than one collection here" "$T/dd_many.log" && grep -q "retro_rtg" "$T/dd_many.log"'
rm -rf "$DC/build"
( cd "$DC" && bash sort.sh --no-detox ) > "$T/dd_none.log" 2>&1; st=$?
check "with no collection at all, it says to build one first" \
  '[ "$st" -eq 4 ] && grep -q "build one first" "$T/dd_none.log"'
check "nothing is created beside the scripts any more" '[ ! -e "$DC/retro" ] && [ ! -e "$DC/new" ]'


section "45. retroplay.conf is found where you run from, then above"
CFG="$T/cfgsearch"; setup mkdir -p "$CFG/scripts"
cp "$ROOT"/*.sh "$REPO/to_ilbm.py" "$CFG/scripts/"
conf_used() { ( cd "$CFG/scripts" && bash -c 'SCRIPT_DIR="'"$CFG/scripts"'"; RP_INVOKED_FROM="'"$CFG/scripts"'"; . ./lib.sh; rp_load_config; rp_conf_in_use; echo; echo "aga=$(rp_art_order_for aga) rtg=$(rp_art_order_for rtg)"' ); }
printf 'ART_ORDER="Titles,Screens,Covers"\n' > "$CFG/scripts/retroplay.conf"
check "a conf beside the scripts is used" 'conf_used | grep -q "scripts/retroplay.conf" && conf_used | grep -q "aga=Titles,Screens,Covers"'
rm -f "$CFG/scripts/retroplay.conf"; printf 'ART_ORDER="Covers,Titles,Screens"\n' > "$CFG/retroplay.conf"
check "otherwise the one in the folder above" 'conf_used | grep -q "$CFG/retroplay.conf" && conf_used | grep -q "aga=Covers,Titles,Screens"'
rm -f "$CFG/retroplay.conf"
check "with none, it says so and uses the defaults" \
  'conf_used | grep -q "not in use" && conf_used | grep -q "aga=Screens,Covers,Titles"'
check "the built-in defaults are Screens,Covers,Titles and RTG Covers,Screens,Titles" \
  'conf_used | grep -q "aga=Screens,Covers,Titles rtg=Covers,Screens,Titles"'
run cfgwarn ./doctor.sh
check "--status shows which settings file is in use" 'run st ./start.sh --status; grep -q "Settings:" "$T/st.log"'
check "every script prints its version and release at the start" \
  'rel="$(sed -n "s/^RP_RELEASE=\"\([^\"]*\)\".*/\1/p" "$ROOT/lib.sh")"; [ -n "$rel" ] &&
   { grep -q "release $rel" "$T/st.log" || ./all.sh --status 2>&1 | grep -q "release $rel"; }'
# The release is read from lib.sh rather than written into the test, so the
# next version bump cannot leave a test quietly pinned to the old number.
check "the release number is the one the changelog is about" \
  'rel="$(sed -n "s/^RP_RELEASE=\"\([^\"]*\)\".*/\1/p" "$ROOT/lib.sh")";
   head -5 "$REPO/CHANGELOG.md" | grep -q "^## $rel "'

section "46. Missing artwork is spotted for every pack, and fetched first"
ART2="$T/artmissing"; setup mkdir -p "$ART2"
check "an empty pack folder does not count as installed" \
  'RP_ARTWORK_ROOT="$ART2" RP_VARIANTS="aga ecs rtg" bash -c "SCRIPT_DIR=\"$ROOT\"; . \"$ROOT/lib.sh\"; rp_load_config >/dev/null; RP_ARTWORK_ROOT=\"$ART2\"; mkdir -p \"$ART2/iGame_AGA\"; rp_artwork_missing aga ecs rtg" | grep -q "iGame_AGA/lores"'
check "all three are reported, not just one" \
  '[ "$(bash -c "SCRIPT_DIR=\"$ROOT\"; . \"$ROOT/lib.sh\"; rp_load_config >/dev/null; RP_ARTWORK_ROOT=\"$ART2\"; rp_artwork_missing aga ecs rtg" | grep -c .)" -eq 3 ]'
for p in iGame_AGA/lores/Covers iGame_ECS/lores/Screens iGame_RTG/Titles; do setup mkdir -p "$ART2/$p"; done
check "once installed, nothing is reported missing" \
  '[ -z "$(bash -c "SCRIPT_DIR=\"$ROOT\"; . \"$ROOT/lib.sh\"; rp_load_config >/dev/null; RP_ARTWORK_ROOT=\"$ART2\"; rp_artwork_missing aga ecs rtg")" ]'


section "47. Progress bar style, summary table and setup reruns"
# the drawn bar itself (rp_bar); rp_progress_line only draws it on a terminal
check "the progress bar is ASCII on Linux and blocks on macOS" \
  'bash -c "SCRIPT_DIR=$ROOT; . $ROOT/lib.sh; RP_PROGRESS_STYLE=ascii; rp_set_bar_style; rp_bar 8 16" | grep -q "#" &&
   bash -c "SCRIPT_DIR=$ROOT; . $ROOT/lib.sh; RP_PROGRESS_STYLE=smooth; rp_set_bar_style; rp_bar 8 16" | grep -qv "#####"'
setup mkdir -p "$T/styledir"; printf 'PROGRESS_STYLE="smooth"\n' > "$T/styledir/retroplay.conf"
check "PROGRESS_STYLE in the config is honoured (blocks, not #)" \
  'bash -c "SCRIPT_DIR=$ROOT; RP_INVOKED_FROM=$T/styledir; . $ROOT/lib.sh; rp_load_config >/dev/null 2>&1; rp_progress_line 8 16 X" | grep -q "50%" &&
   ! bash -c "SCRIPT_DIR=$ROOT; RP_INVOKED_FROM=$T/styledir; . $ROOT/lib.sh; rp_load_config >/dev/null 2>&1; rp_bar 8 16" | grep -q "#"'
# a log is not a terminal: the artwork bar degrades the way rp_progress does
check "artwork progress is a plain timestamped line in a log, not a drawn bar" \
  'out="$(bash -c "SCRIPT_DIR=$ROOT; . $ROOT/lib.sh; RP_PROGRESS_STYLE=ascii; rp_set_bar_style; rp_progress_line 8 16 Artwork")";
   case "$out" in *"Artwork: 50% (8/16)"*) ;; *) false ;; esac &&
   case "$out" in *"#"*) false ;; *) true ;; esac'
run tbl ./all.sh --skip-update --variants aga --refresh-artwork
check "the summary lists each collection with games, size, time and artwork" \
  'grep -q "Collection" "$T/tbl.log" && grep -qE "retro_aga +[0-9]+ +[0-9]+ +[0-9]+:[0-9][0-9]:[0-9][0-9] +(Screens|Covers|Titles)" "$T/tbl.log"'
check "...and the overall time is still shown" 'grep -q "Total time:" "$T/tbl.log"'
# an interrupted setup starts clean next time
SU="$T/setupagain"; setup mkdir -p "$SU"
cp "$ROOT"/*.sh "$REPO/to_ilbm.py" "$REPO/retroplay.conf.example" "$SU/"
printf 'wrote_conf\n' > "$SU/.retroplay_setup_state"        # as if interrupted
printf 'VARIANTS="half written"\n' > "$SU/retroplay.conf"
( cd "$SU" && env PATH="$MOCK:$PATH" RP_SETUP_OS=linux ./setup.sh --yes --no-cron ) > "$T/setupagain.log" 2>&1
check "a part-finished setup is cleared before starting again" \
  'grep -q "previous setup didn.t finish" "$T/setupagain.log" && ! grep -q "half written" "$SU/retroplay.conf"'


section "48. Release check (report only) and artwork priority per variant"
UC="$T/updchk"; setup mkdir -p "$UC/bin"
cat > "$UC/bin/curl" << 'EOF'
#!/bin/sh
case "$*" in
  *newer*) echo '{"tag_name":"v9.9"}' ;;
  *junk*)  echo '{"tag_name":"v1.0; rm -rf /"}' ;;
  *older*) echo '{"tag_name":"v0.1"}' ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$UC/bin/curl"
upd() { PATH="$UC/bin:$PATH" bash -c "SCRIPT_DIR=$ROOT; . $ROOT/lib.sh; rp_load_config >/dev/null 2>&1; RP_UPDATE_CHECK_URL='$1'; rm -f \"\$RP_STATE_DIR/update_last_check\"; rp_check_for_update force" 2>&1; }
check "a newer release is reported, with the address and the commands" \
  'upd https://api/newer | grep -q "A newer release is available: 9.9" && upd https://api/newer | grep -q "releases"'
check "nothing is downloaded or run - it only prints" \
  '! upd https://api/newer | grep -qi "unzip -o whdsync.zip &&.*executed" && [ ! -e "$ROOT/whdsync.zip" ]'
check "a tag containing shell commands is ignored" '[ -z "$(upd https://api/junk)" ]'
check "an older release says nothing" '[ -z "$(upd https://api/older)" ]'
check "a non-HTTPS address is refused outright" '[ -z "$(upd http://api/newer)" ]'
check "UPDATE_CHECK=no turns it off" \
  '[ -z "$(PATH="$UC/bin:$PATH" bash -c "SCRIPT_DIR=$ROOT; . $ROOT/lib.sh; rp_load_config >/dev/null 2>&1; RP_UPDATE_CHECK=no; RP_UPDATE_CHECK_URL=https://api/newer; rp_check_for_update force")" ]'

AP="$T/artprio"; setup mkdir -p "$AP"
cp "$ROOT"/*.sh "$REPO/to_ilbm.py" "$AP/"
for f in lores laced; do for sec in Covers Screens Titles; do
    setup mkdir -p "$AP/artwork/iGame_AGA/$f/$sec/Games/S/Superfrog"
    echo "AGA-$f-$sec" > "$AP/artwork/iGame_AGA/$f/$sec/Games/S/Superfrog/iGame.iff"
done; done
for sec in Covers Screens Titles; do
    setup mkdir -p "$AP/artwork/iGame_RTG/$sec/Games/S/Superfrog"
    echo "RTG-$sec" > "$AP/artwork/iGame_RTG/$sec/Games/S/Superfrog/iGame.iff"
done
for v in aga rtg; do
    setup mkdir -p "$AP/build/retro_$v/WHDLoad/Games/S/Superfrog"
    touch "$AP/build/retro_$v/WHDLoad/Games/S/Superfrog.info"; echo s > "$AP/build/retro_$v/WHDLoad/Games/S/Superfrog/g.slave"
done
prio() {   # prio <variant> [extra options]
    local v="$1"; shift
    rm -f "$AP/build/retro_${v%%-*}/WHDLoad/Games/S/Superfrog"/iGame*.iff
    ( cd "$AP" && bash merge.sh --"$v" -d "build/retro_${v%%-*}" "$@" ) > /dev/null 2>&1
    cat "$AP/build/retro_${v%%-*}/WHDLoad/Games/S/Superfrog/iGame.iff" 2>/dev/null
}
check "the default order is Screens, Covers, Titles" '[ "$(prio aga)" = "AGA-lores-Screens" ]'
check "RTG uses Covers, Screens, Titles" '[ "$(prio rtg)" = "RTG-Covers" ]'
check "laced follows the default order too" '[ "$(prio aga-laced)" = "AGA-laced-Screens" ]'
printf 'ART_ORDER="Titles,Covers,Screens"\nART_ORDER_RTG="Covers,Titles,Screens"\n' > "$AP/retroplay.conf"
check "a config in the folder you run from overrides both" \
  '[ "$(prio aga)" = "AGA-lores-Titles" ] && [ "$(prio rtg)" = "RTG-Covers" ]'
rm -f "$AP/retroplay.conf"
check "--art overrides everything, including for RTG" '[ "$(prio rtg --art Screens,Covers,Titles)" = "RTG-Screens" ]'


section "49. Version identity, bash contract and dependency policy"
check "one canonical version from both entry points" \
  '[ "$(run_out ./all.sh --version)" = "$(run_out ./start.sh --version)" ] && run_out ./all.sh --version | grep -q "whdsync"'
check "no old per-script version numbers remain" \
  '! grep -rqE "1\.8\.0-fallback|3\.0\.0-ultimate|1\.4\.0-bash32" "$ROOT"/*.sh'
check "a missing bash 4 is reported before anything is downloaded" \
  'bash -c "SCRIPT_DIR=$ROOT; . $ROOT/lib.sh; rp_find_bash4 >/dev/null" && echo ok | grep -q ok'
check "every package-install site is behind the explicit opt-in" \
  'for f in all.sh update.sh extract.sh; do
     grep -q "rp_may_install_tools" "$ROOT/$f" || exit 1
   done'
# behavioural: a run with a tool missing must not call the package manager
setup mkdir -p "$T/noinst/bin"
printf "#!/bin/sh\necho CALLED >> %s/noinst/calls\n" "$T" > "$T/noinst/bin/apt-get"
printf "#!/bin/sh\necho CALLED >> %s/noinst/calls\n" "$T" > "$T/noinst/bin/brew"
printf "#!/bin/sh\nexit 1\n" > "$T/noinst/bin/wget"        # wget "missing" (fails)
chmod +x "$T/noinst/bin"/*
: > "$T/noinst/calls"
( cd "$ROOT" && PATH="$T/noinst/bin:$MOCK:$PATH" ./update.sh --dry-run ) > "$T/noinst.log" 2>&1
check "a run never calls the package manager by itself" '[ ! -s "$T/noinst/calls" ]'
check "...and never stops at an install prompt" '! grep -q "\[y/N\]" "$T/noinst.log"'
check "start.sh says how to fix missing tools instead of installing them" \
  'grep -q "Run ./setup.sh to install everything" "$ROOT/start.sh" && grep -q -- "--install-missing-tools" "$ROOT/start.sh"'
check "the config is parsed, never sourced" \
  '! grep -nE "^\s*(\.|source) .*retroplay\.conf" "$ROOT"/*.sh'
check "no eval anywhere in the suite" \
  '( for f in "$ROOT"/*.sh; do
        sed -e "s/[[:space:]]#.*$//" -e "s/^[[:space:]]*#.*$//" "$f" | grep -qw eval && exit 1
     done; exit 0 )'


section "50. A failed artwork download is never recorded as up to date"
# The Retroplay artwork host sometimes answers 503. When that happens the pack
# must keep its previous state: nothing written to .retroplay saying it is
# current, and the next run must try again instead of waiting out the 24 hour
# interval.
ART_ST="$ROOT/.retroplay/artwork"
COVERS_MAN="$ART_ST/manifests/iGame_AGA_lores_Covers.meta"
acfg ARTWORK_SYNC '"auto"'
acfg ARTWORK_FAILURE_POLICY '"warn-and-continue"'
rm -f "$MOCK/art_503"
run art503pre ./artwork_sync.sh --sync --for aga --yes
check "(setting the scene) the AGA artwork installs and is recorded as current" \
  '[ -s "$COVERS_MAN" ] && grep -q "^remote_size=" "$COVERS_MAN"'
man_before="$(cksum < "$COVERS_MAN")"
# the source republishes that pack, so an update is now due...
printf 'B\nIGame_Covers_AGA_LoRes.lha\nrepublished, so an update is due\n' > "$ARTSRC/IGame_Covers_AGA_LoRes.lha"
rm -f "$ROOT/.retroplay/artwork_last_check"
printf 'Covers_AGA_LoRes' > "$MOCK/art_503"       # ...but the host answers 503
: > "$MOCK/art_downloads"
run art503 ./all.sh --skip-update --variants aga; st=$?
check "the run carries on and says the previous artwork was kept" \
  '{ [ "$st" -eq 0 ] || [ "$st" -eq 2 ]; } && grep -q "previous artwork was kept" "$T/art503.log"'
check "the pack is NOT stamped as checked - the next run tries again" \
  '[ ! -f "$ROOT/.retroplay/artwork_last_check" ]'
check "...and that pack's record in .retroplay still says what it said before" \
  '[ -s "$COVERS_MAN" ] && [ "$(cksum < "$COVERS_MAN")" = "$man_before" ]'
check "the failure is recorded, naming the archive" \
  '[ -f "$ART_ST/last_failure" ] && grep -q "IGame_Covers_AGA_LoRes.lha" "$ART_ST/last_failure"'
run art503st ./artwork_sync.sh --status --for aga
check "--artwork-status shows it as still to do, not as up to date" \
  'grep -q "Last failure" "$T/art503st.log" && grep -q "try again" "$T/art503st.log"'
# the source comes back
rm -f "$MOCK/art_503"; : > "$MOCK/art_downloads"
run art503ok ./all.sh --skip-update --variants aga; st=$?
check "the very next run retries the failed pack straight away" \
  '{ [ "$st" -eq 0 ] || [ "$st" -eq 2 ]; } && grep -q "download IGame_Covers_AGA_LoRes.lha" "$MOCK/art_downloads"'
check "now that it worked, it is stamped as checked and the failure is cleared" \
  '[ -f "$ROOT/.retroplay/artwork_last_check" ] && [ ! -f "$ART_ST/last_failure" ]'
: > "$MOCK/art_downloads"
run art503skip ./all.sh --skip-update --variants aga
check "a second run inside the interval does not re-check" '[ ! -s "$MOCK/art_downloads" ]'
acfg ARTWORK_SYNC '"no"'


section "51. unlzx builds from source on compilers that reject old C"
# unlzx.c calls mkdir() and getopt() without including their headers. GCC 14
# (Raspberry Pi OS trixie) and current clang make that a hard error, so
# setup.sh adds the headers before compiling. The compiler here is a stand-in
# that fails exactly the way GCC 14 does, so the test needs no toolchain.
UB="$T/unlzxbuild"; setup mkdir -p "$UB"
cat > "$UB/unlzx.c" << 'EOF'
/* stands in for the Aminet unlzx.c: 1990s C, no sys/stat.h, no unistd.h */
#include <stdio.h>
int main(int argc, char **argv) { getopt(argc, argv, "x"); mkdir("d", 0777); return 0; }
EOF
cat > "$UB/withheaders.c" << 'EOF'
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
int main(int argc, char **argv) { getopt(argc, argv, "x"); mkdir("d", 0777); return 0; }
EOF
cat > "$UB/cc" << 'EOF'
#!/bin/sh
# stand-in for GCC 14: an implicit declaration is an error that -w cannot hide
src=""; out=""; prev=""; permissive=0
for a in "$@"; do
    case "$prev" in -o) out="$a" ;; esac
    case "$a" in -fpermissive|-Wno-implicit-function-declaration) permissive=1 ;; *.c) src="$a" ;; esac
    prev="$a"
done
[ -e "${CC_ALWAYS_FAIL:-/nonexistent}" ] && { echo "$src:1:1: error: cannot compile this at all" >&2; exit 1; }
if [ "$permissive" -eq 0 ] && [ -n "$src" ]; then
    if grep -q 'mkdir(' "$src" && ! grep -q '<sys/stat.h>' "$src"; then
        echo "$src:651:5: error: implicit declaration of function 'mkdir'" >&2; exit 1; fi
    if grep -q 'getopt(' "$src" && ! grep -q '<unistd.h>' "$src"; then
        echo "$src:1228:19: error: implicit declaration of function 'getopt'" >&2; exit 1; fi
fi
printf '#!/bin/sh\necho "unlzx test build"\n' > "$out"; chmod +x "$out"
EOF
chmod +x "$UB/cc"
cat > "$UB/drive.sh" << EOF
#!/usr/bin/env bash
set -u
note() { printf '%s\n' "\$*"; }
bad()  { printf 'ERROR: %s\n' "\$*"; }
eval "\$(awk '/^build_unlzx\\(\\)/,/^}\$/' "$ROOT/setup.sh")"
tmp="\$(mktemp -d)"
if build_unlzx "$UB/cc" "\$1" "\$tmp"; then echo "BUILD-OK"; "\$tmp/unlzx"; else echo "BUILD-FAILED"; fi
rm -rf "\$tmp"
EOF
chmod +x "$UB/drive.sh"
( cd "$UB" && ./cc -O2 -w -o "$UB/plain" "$UB/unlzx.c" ) > "$T/unlzx_plain.log" 2>&1; st=$?
check "the stand-in compiler really does reject the old source (as the Pi 400 did)" \
  '[ "$st" -ne 0 ] && grep -q "implicit declaration of function .mkdir" "$T/unlzx_plain.log"'
( cd "$UB" && ./drive.sh "$UB/unlzx.c" ) > "$T/unlzx_build.log" 2>&1
check "setup.sh still builds unlzx by adding the headers the source leaves out" \
  'grep -q "BUILD-OK" "$T/unlzx_build.log" && grep -q "unlzx test build" "$T/unlzx_build.log"'
check "...and says so, so the user knows what happened" \
  'grep -q "headers the old unlzx source leaves out" "$T/unlzx_build.log"'
( cd "$UB" && ./drive.sh "$UB/withheaders.c" ) > "$T/unlzx_ok.log" 2>&1
check "a source that already has its headers builds unchanged, with no note" \
  'grep -q "BUILD-OK" "$T/unlzx_ok.log" && ! grep -q "headers the old unlzx source" "$T/unlzx_ok.log"'
: > "$UB/alwaysfail"
( cd "$UB" && CC_ALWAYS_FAIL="$UB/alwaysfail" ./drive.sh "$UB/unlzx.c" ) > "$T/unlzx_bad.log" 2>&1
check "a source that cannot build fails clearly and shows the compiler's message" \
  'grep -q "BUILD-FAILED" "$T/unlzx_bad.log" && grep -q "compiling unlzx failed" "$T/unlzx_bad.log" && grep -q "cannot compile this at all" "$T/unlzx_bad.log"'
check "...and says the rest of the suite still works without it" \
  'grep -q "lzx archives will be skipped" "$T/unlzx_bad.log"'


section "52. Settings that are used as numbers, and listing timeouts"
# A setting used in arithmetic or in a -mmin test must be checked: unchecked,
# ARTWORK_CHECK_INTERVAL_HOURS="soon" silently became 0 and turned the daily
# artwork check into an every-run check.
NUMDIR="$T/numcfg"; setup mkdir -p "$NUMDIR"
numcfg() { printf '%s\n' "$1" > "$NUMDIR/retroplay.conf"; }
numval() {   # numval <setting> ; prints "<warned?> <value>"
    bash -c "SCRIPT_DIR=\"$ROOT\"; RP_INVOKED_FROM=\"$NUMDIR\"; . \"$ROOT/lib.sh\";
             rp_load_config >/dev/null 2>&1
             printf '%s %s\n' \"\$(printf '%s' \"\$RP_CONFIG_WARNINGS\" | grep -c \"$1\")\" \"\$(eval printf '%s' \\\"\\\$RP_$1\\\")\""
}
for setting in ARTWORK_CHECK_INTERVAL_HOURS:24 ARTWORK_KEEP_BACKUPS:2 ARTWORK_FETCH_LIMIT:25 STATE_BACKUP_MAX_MB:50; do
    name="${setting%%:*}"; want="${setting##*:}"
    numcfg "$name=\"soon\""
    check "$name: a value that is not a number warns and falls back to $want" \
      '[ "$(numval "$name")" = "1 '"$want"'" ]'
done
numcfg 'ARTWORK_CHECK_INTERVAL_HOURS="6"'
check "a valid number is kept as given" '[ "$(numval ARTWORK_CHECK_INTERVAL_HOURS)" = "0 6" ]'
numcfg 'ARTWORK_CHECK_INTERVAL_HOURS="soon"'
check "...so the daily artwork check is not turned into an every-run check" \
  'bash -c "SCRIPT_DIR=\"$ROOT\"; RP_INVOKED_FROM=\"$NUMDIR\"; . \"$ROOT/lib.sh\"; rp_load_config >/dev/null 2>&1; echo \$(( RP_ARTWORK_CHECK_INTERVAL_HOURS * 60 ))" | grep -qx 1440'

# A listing is a few KB. update.sh checks five folders, so a 120s timeout each
# meant ten minutes of silence before --dry-run said anything.
LT="$T/listtimeout"; setup mkdir -p "$LT"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s/curl_args"\nexit 0\n' "$LT" > "$LT/curl"
chmod +x "$LT/curl"
( PATH="$LT:$PATH" bash -c "SCRIPT_DIR=\"$ROOT\"; . \"$ROOT/lib.sh\"; rp_fetch_listing http://mock/list" ) >/dev/null 2>&1
check "the listing fetch gives up in a minute, not two, and caps the connect" \
  'grep -q -- "--connect-timeout 15" "$LT/curl_args" && grep -q -- "-m 60" "$LT/curl_args"'
( PATH="$LT:$PATH" bash -c "SCRIPT_DIR=\"$ROOT\"; . \"$ROOT/lib.sh\"; RP_LISTING_TIMEOUT=5 RP_CONNECT_TIMEOUT=2 rp_fetch_listing http://mock/list" ) >/dev/null 2>&1
check "...and both timeouts can be overridden" \
  'grep -q -- "--connect-timeout 2" "$LT/curl_args" && grep -q -- "-m 5" "$LT/curl_args"'

section "53. Output levels, colour and the stderr rule"
# --quiet: errors and the final result only. A no-op run should say almost
# nothing, but must never swallow a warning or an error.
run q1 ./all.sh --skip-update --variants aga --quiet
check "--quiet keeps a normal run to a handful of lines" '[ "$(grep -c . "$T/q1.log")" -lt 6 ]'
check "--quiet still prints the result" 'grep -qiE "up to date|finished|done|nothing" "$T/q1.log"'
( cd "$ROOT" && ./all.sh --variants nosuchvariant --quiet ) > "$T/q2.out" 2> "$T/q2.err"; st=$?
check "--quiet still prints errors, and on stderr" \
  '[ "$st" -ne 0 ] && [ -s "$T/q2.err" ] && grep -q "ERROR" "$T/q2.err" && ! grep -q "ERROR" "$T/q2.out"'
run v1 ./all.sh --skip-update --variants aga --verbose
check "--verbose says more than --quiet" '[ "$(grep -c . "$T/v1.log")" -gt "$(grep -c . "$T/q1.log")" ]'
check "--verbose is not --debug" '! grep -q "\[debug\]" "$T/v1.log"'

# Colour: one rule for the whole suite. NO_COLOR follows the published
# convention (any non-empty value), and --color=always wins over the terminal
# test so "| less -R" works.
esc() {   # esc <env assignments...> ; true when colour escapes are emitted
    ( cd "$ROOT" && env SCRIPT_DIR="$ROOT" "$@" bash -c '. "$SCRIPT_DIR/lib.sh"; rp_set_colours; printf "%sx%s" "$RED" "$NC"' ) \
        | od -c | grep -q '033'
}
check "--color=always gives colour even when piped" 'esc RP_COLOR=always'
check "--color=never gives none, terminal or not" '! esc RP_COLOR=never RP_FORCE_TTY=1'
check "on a terminal, colour is on by default" 'esc RP_FORCE_TTY=1'
check "NO_COLOR=1 turns colour off on a terminal" '! esc RP_FORCE_TTY=1 NO_COLOR=1'
check "NO_COLOR=true does too - any value, not just 1" '! esc RP_FORCE_TTY=1 NO_COLOR=true'
check "piped output has no colour without being asked" '! esc RP_COLOR=auto'
check "the leaf scripts use the same decision, not their own" \
  '! grep -q "NO_COLOR\" = \"1\"" "$ROOT/extract.sh" "$ROOT/merge.sh" &&
   grep -q "^rp_set_colours" "$ROOT/extract.sh" && grep -q "^rp_set_colours" "$ROOT/merge.sh"'

section "54. One run at a time: the stage scripts honour the same lock"
# all.sh has always taken a lock. Now the stage scripts take the SAME one when
# a person runs them by hand, so an interactive ./merge.sh cannot work on a
# collection a nightly build is halfway through.
LK="$ROOT/.all.lock"
rm -rf "$LK.d" "$LK.info"
if [ -n "$FLOCK" ]; then
    ( exec 9>"$LK"; "$FLOCK" 9; sleep 300 ) & holder=$!
    sleep 1
    run lockmerge ./merge.sh --aga --dest "$ROOT/build/retro_aga"; st=$?
    check "merge.sh run by hand is refused while a build holds the lock" \
      '[ "$st" -eq 4 ] && grep -q "already running" "$T/lockmerge.log"'
    check "...and it says how to clear a lock that is really stale" \
      'grep -q -- "--unlock-stale" "$T/lockmerge.log"'
    run lockupd ./update.sh; st=$?
    check "update.sh is refused too" '[ "$st" -eq 4 ]'
    # A stage started BY all.sh must NOT refuse - the parent holds the lock.
    ( cd "$ROOT" && RP_CHILD=1 ./sort.sh --pfs --dest "$ROOT/build/retro_aga" --called-from-all ) \
        > "$T/lockchild.log" 2>&1; st=$?
    check "a stage started by all.sh is not refused (the parent holds it)" '[ "$st" -ne 4 ]'
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    sleep 1
    run lockfree ./merge.sh --aga --dest "$ROOT/build/retro_aga"; st=$?
    check "once the build finishes, running it by hand works again" '[ "$st" -ne 4 ]'
else
    echo "  (skipped: flock not installed)"
fi

# A worker orphaned by a killed run must not keep the lock held: it inherits
# the lock's file descriptor unless the fork closes it, and every later run
# would then be refused for ever.
rm -rf "$LK.d" "$LK.info"
if [ -n "$FLOCK" ]; then
    ( cd "$ROOT" && ./extract.sh -u -d "$T/lockorph" >/dev/null 2>&1 ) &
    ekill=$!
    sleep 1; kill -9 "$ekill" 2>/dev/null; wait "$ekill" 2>/dev/null
    st=1; n=0
    while [ "$n" -lt 20 ]; do
        if ( exec 9>"$LK"; "$FLOCK" -n 9 ); then st=0; break; fi
        sleep 1; n=$((n + 1))
    done
    check "a killed run leaves no worker holding the lock" '[ "$st" -eq 0 ]'
fi

section "55. --unlock-stale reports before it removes anything"
# The orphan test above deliberately kills a run mid-flight; anything it left
# running would write the lock record again under us.
pkill -f "$ROOT/extract.sh" 2>/dev/null || true
pkill -f 'extract\.sh -u -d' 2>/dev/null || true
sleep 2
rm -rf "$LK.d" "$LK.info"
run unlocknone ./start.sh --unlock-stale
check "with no lock in place it says so and changes nothing" \
  'grep -qi "no lock" "$T/unlocknone.log" && [ ! -e "$LK.d" ]'
# A lock folder whose owner is alive: never removed. The stand-in run must
# look like one - a process running all.sh - because a PID that is alive but
# running something else is (correctly) taken for a recycled number.
bash -c 'exec -a all.sh sleep 6' & live=$!
sleep 0.3
mkdir -p "$LK.d"
printf 'pid=%s\nhost=%s\nstarted=now\nrun_id=t\ncommand=all.sh --sync\n' "$live" "$(hostname 2>/dev/null || uname -n)" > "$LK.info"
run unlocklive ./start.sh --unlock-stale; st=$?
check "a lock whose run is still alive is reported, not removed" \
  '[ "$st" -eq 4 ] && [ -e "$LK.d" ] && grep -q "still running" "$T/unlocklive.log"'
check "...and it shows the holder and the exact lock path" \
  'grep -q "all.sh --sync" "$T/unlocklive.log" && grep -q ".all.lock" "$T/unlocklive.log"'
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
# A lock from another machine: never removed, however old.
printf 'pid=1\nhost=someothermachine\nstarted=now\nrun_id=t\ncommand=all.sh\n' > "$LK.info"
run unlockhost ./start.sh --unlock-stale; st=$?
check "a lock taken on another machine is left alone" \
  '[ "$st" -eq 4 ] && [ -e "$LK.d" ] && grep -q "someothermachine" "$T/unlockhost.log"'
# A lock left by a run that no longer exists here: removed, unattended.
deadpid="$( ( exec sh -c 'echo $$' ) )"; sleep 0.2
printf 'pid=%s\nhost=%s\nstarted=now\nrun_id=t\ncommand=all.sh --sync\n' "$deadpid" "$(hostname 2>/dev/null || uname -n)" > "$LK.info"
run unlockstale ./start.sh --unlock-stale; st=$?
check "a lock left by a run that is gone is removed" \
  '[ "$st" -eq 0 ] && [ ! -e "$LK.d" ] && [ ! -e "$LK.info" ]'
rm -rf "$LK.d" "$LK.info"


section "56. Each collection records what it is, and can explain itself"
MAN="$ROOT/.retroplay/manifest"
run manbuild ./all.sh --skip-update --variants aga
check "a finished collection writes a manifest" '[ -s "$MAN/retro_aga" ]'
check "...with the counts, the settings and the version that built it" \
  'grep -q "^game_count=" "$MAN/retro_aga" && grep -q "^size_kb=" "$MAN/retro_aga" &&
   grep -q "^art_order=" "$MAN/retro_aga" && grep -q "^config_fingerprint=" "$MAN/retro_aga" &&
   grep -q "^suite_version=" "$MAN/retro_aga"'
check "--status shows the game count from it, without walking the tree" \
  'run_out ./start.sh --status | grep -qE "retro_aga:.*[0-9]+ games"'
run whyb ./start.sh --why-build aga
check "--why-build says the state, the artwork and whether anything is queued" \
  'grep -q "retro_aga" "$T/whyb.log" && grep -qi "queue" "$T/whyb.log" && grep -qi "artwork" "$T/whyb.log"'
check "...and that the settings have not changed since it was built" \
  'grep -q "unchanged since it was built" "$T/whyb.log"'
fp_before="$(sed -n 's/^config_fingerprint=//p' "$MAN/retro_aga")"
acfg ART_ORDER '"Titles,Covers,Screens"'
run whyb2 ./start.sh --why-build aga
check "changing the artwork order is noticed" 'grep -q "has changed since this was built" "$T/whyb2.log"'
acfg NTFY_TOPIC '"somethingelse"'
run whyb3 ./start.sh --why-build aga
acfg ART_ORDER '"Screens,Covers,Titles"'
run whyb4 ./start.sh --why-build aga
check "...but changing a notification topic is not a reason to rebuild" \
  'grep -q "unchanged since it was built" "$T/whyb4.log" &&
   [ "$(sed -n "s/^config_fingerprint=//p" "$MAN/retro_aga")" = "$fp_before" ]'
# A collection from an older release has no manifest: that is "no details",
# never "needs rebuilding".
mv "$MAN/retro_aga" "$T/manifest.saved"
run whyold ./start.sh --why-build aga
check "a collection built by an older version reads as built, details unknown" \
  'grep -q "no record kept" "$T/whyold.log" && grep -q "not a reason to rebuild" "$T/whyold.log" &&
   ! grep -q "has changed since this was built" "$T/whyold.log"'
mv "$T/manifest.saved" "$MAN/retro_aga"
run whyb5 ./start.sh --why-build zzz
check "--why-build for a variant that was never built says so" 'grep -qi "not built yet" "$T/whyb5.log"'
run whyspace ./start.sh --why-space
check "--why-space shows the drive, what is free and what is using it" \
  'grep -q "Free now" "$T/whyspace.log" && grep -q "retro_aga" "$T/whyspace.log" && grep -q "MIN_FREE_MB" "$T/whyspace.log"'

section "57. Failed archives can be listed and retried"
printf '3\tWHDLoad/Games/Z/Zeta_v1.0.lha\n' > "$ROOT/.retroplay/extract_attempts.list"
run showfail ./start.sh --show-failed
check "--show-failed lists the archives that were set aside" \
  'grep -q "Zeta_v1.0.lha" "$T/showfail.log" && grep -q "3x" "$T/showfail.log"'
check "...and the games left without artwork" 'grep -qi "without artwork" "$T/showfail.log"'
run retryfail ./start.sh --retry-failed
check "--retry-failed clears the count so they are tried again" \
  '[ ! -s "$ROOT/.retroplay/extract_attempts.list" ] && grep -q "tries them again" "$T/retryfail.log"'
run retryempty ./start.sh --retry-failed
check "...and says so plainly when there is nothing set aside" \
  'grep -qi "nothing has been set aside" "$T/retryempty.log"'

section "58. The preview builds a batch and leaves the collection alone"
server_add WHDLoad/Games/P/Preview_v1.0.lha

run prev ./start.sh --preview-new --aga; st=$?
latestp="$(ls -1d "$ROOT"/build/new_aga/*/ 2>/dev/null | sort | tail -1)"
check "the preview run finishes" '[ "$st" -eq 0 ] || [ "$st" -eq 2 ]'
check "the new game is in the dated batch" '[ -d "${latestp}WHDLoad/Games/P/Preview" ]'
check "the batch says in plain words that it is not a collection" \
  '[ -f "${latestp}PREVIEW_ONLY.txt" ] && grep -q "NOT a collection" "${latestp}PREVIEW_ONLY.txt"'
check "the collection itself was not changed" '[ ! -d "$ROOT/build/retro_aga/WHDLoad/Games/P/Preview" ]'
check "the archive stays queued, so an ordinary run still installs it" \
  'grep -q "Preview_v1.0.lha" "$ROOT/.retroplay/queue/retro_aga.list"'
check "the batch carries the machine-readable preview marker" \
  'grep -q "^preview=1" "${latestp}.preview_marker"'
check "a preview does not stamp the untouched collection's manifest as a preview" \
  '! grep -q "^kind=preview" "$ROOT/.retroplay/manifest/retro_aga" 2>/dev/null'
run prevthen ./start.sh --sync --aga; st=$?
check "...and the next ordinary run does install it" \
  '{ [ "$st" -eq 0 ] || [ "$st" -eq 2 ]; } && [ -d "$ROOT/build/retro_aga/WHDLoad/Games/P/Preview" ]'
# The next run's "remove batches with the wrong layout" sweep used to take the
# preview's own PREVIEW_ONLY.txt for debris and delete the whole batch.
check "...and it leaves the preview batch alone, readme and all" \
  '[ -d "${latestp}WHDLoad/Games/P/Preview" ] && [ -f "${latestp}PREVIEW_ONLY.txt" ] &&
   ! grep -q "Removed .*wrong folder layout" "$T/prevthen.log"'
check "a PREVIEW_ONLY.txt without the marker is still reported as out of place" \
  '( d="$T/fakeprev"; mkdir -p "$d/WHDLoad"; : > "$d/PREVIEW_ONLY.txt";
     [ "$(cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; rp_layout_problems \"$d\"")" = "PREVIEW_ONLY.txt" ] )'
run quickdep ./quick.sh --help
check "quick.sh still works and points at the new name" \
  'grep -q -- "--preview-new" "$T/quickdep.log"'
check "...and says it is deprecated rather than failing" \
  'grep -qi "replaced by" "$T/quickdep.log"'

section "59. Help is grouped, and every old option still works"
run helpshort ./start.sh --help
check "the everyday commands come first and fit on a screen" \
  '[ "$(grep -c . "$T/helpshort.log")" -lt 50 ] && grep -q "^Everyday" "$T/helpshort.log"'
check "the advanced options are grouped, not listed one by one" \
  'grep -q "^Advanced" "$T/helpshort.log" && grep -q -- "--help advanced" "$T/helpshort.log"'
run helplong ./start.sh --help advanced
check "--help advanced explains each of them" \
  '[ "$(grep -c . "$T/helplong.log")" -gt "$(grep -c . "$T/helpshort.log")" ] &&
   grep -q -- "--preview-new" "$T/helplong.log" && grep -q -- "--skip-variant-sort" "$T/helplong.log"'
check "the diagnosis commands are in the help" \
  'grep -q -- "--why-build" "$T/helpshort.log" && grep -q -- "--show-failed" "$T/helpshort.log" &&
   grep -q -- "--unlock-stale" "$T/helpshort.log"'


section "60. Stage timings, and how many things to do at once"
# Give it something to do: the "nothing to do" path exits before the summary.
server_add WHDLoad/Games/T/Timed_v1.0.lha
run timedupd ./all.sh --variants aga
run timed ./all.sh --variants aga --force
check "the report says where the time went, stage by stage" \
  'grep -q "Time per stage" "$T/timed.log" && grep -qE "^  preflight +[0-9]+" "$T/timed.log" &&
   grep -qE "^  update +[0-9]+" "$T/timed.log" && grep -qE "^  build +[0-9]+" "$T/timed.log"'
check "...and the saved report keeps them too" \
  'grep -q "Time per stage" "$(ls -1 "$ROOT"/reports/*.txt | grep -v _no_artwork | sort | tail -1)"'
# JOBS: auto must keep exactly what each stage worked out for itself.
run jobsauto ./extract.sh -u -d "$T/jobs_out" --debug
auto_jobs="$(sed -n 's/.*using \([0-9]*\) parallel extraction job.*/\1/p' "$T/jobsauto.log" | head -1)"
check "with no setting, the job count is whatever it always was" '[ -n "$auto_jobs" ]'
run jobs1 ./extract.sh -u -d "$T/jobs_out1" --jobs 1
check "--jobs 1 really runs one at a time" 'grep -q "using 1 parallel extraction job" "$T/jobs1.log"'
acfg EXTRACT_JOBS '"2"'
run jobscfg ./extract.sh -u -d "$T/jobs_out2"
check "EXTRACT_JOBS in retroplay.conf is honoured" 'grep -q "using 2 parallel extraction job" "$T/jobscfg.log"'
run jobsover ./extract.sh -u -d "$T/jobs_out3" --jobs 3
check "...and --jobs beats the config" 'grep -q "using 3 parallel extraction job" "$T/jobsover.log"'
acfg EXTRACT_JOBS '"nonsense"'
run jobsbad ./extract.sh -u -d "$T/jobs_out4"
check "a job count that is not a number warns and carries on" \
  'grep -qi "not a whole number" "$T/jobsbad.log" && grep -q "using $auto_jobs parallel extraction job" "$T/jobsbad.log"'
acfg EXTRACT_JOBS '"auto"'
run jobsnoval ./extract.sh -u -d "$T/jobs_out5" --jobs; st=$?
check "--jobs with no value fails cleanly" '[ "$st" -eq 4 ]'


section "61. --aga-laced and --ecs-laced really use the laced artwork"
# The flavour folders (iGame_AGA/laced, iGame_AGA/lores) were mapped onto the
# set names AFTER the command line had already been resolved, so --aga-laced
# asked for a key that did not exist yet: it always reported "not found" and
# quietly built from the fallback chain instead. It also named the scripts
# folder rather than the artwork folder in that message.
mkdir -p "$ROOT/artwork/iGame_AGA/laced/Covers/Games/L/Laced" \
         "$ROOT/artwork/iGame_ECS/laced/Covers/Games/L/Laced" \
         "$ROOT/build/lacedtest/WHDLoad/Games/L/Laced"
echo "AGA-LACED-ART" > "$ROOT/artwork/iGame_AGA/laced/Covers/Games/L/Laced/iGame.iff"
echo "ECS-LACED-ART" > "$ROOT/artwork/iGame_ECS/laced/Covers/Games/L/Laced/iGame.iff"
touch "$ROOT/build/lacedtest/WHDLoad/Games/L/Laced.info"
run mlaced ./merge.sh --aga-laced -d "$ROOT/build/lacedtest" --art Covers,Screens,Titles
check "--aga-laced picks iGame_AGA/laced, not the fallback chain" \
  'grep -q "Selected artwork source: .*iGame_AGA/laced" "$T/mlaced.log"'
check "...and the game gets the laced artwork" \
  'grep -q "AGA-LACED-ART" "$ROOT/build/lacedtest/WHDLoad/Games/L/Laced/iGame.iff"'
run mlacede ./merge.sh --ecs-laced -d "$ROOT/build/lacedtest" --art Covers,Screens,Titles
check "--ecs-laced picks iGame_ECS/laced too" \
  'grep -q "Selected artwork source: .*iGame_ECS/laced" "$T/mlacede.log"'
# The message when a set really is missing must name the artwork folder.
run mnoset ./merge.sh --set Nonexistent -d "$ROOT/build/lacedtest"
check "a set that is not there names the artwork folder, not the scripts folder" \
  'grep -q "artwork" "$T/mnoset.log" && ! grep -q "found under: $ROOT\$" "$T/mnoset.log"'
check "...and says how to fetch it" 'grep -q -- "--artwork-sync" "$T/mnoset.log"'

section "62. No locale warnings on a machine without en_AU"
# extract.sh used to export LANG/LC_ALL=en_AU.UTF-8 outright. setup.sh
# generates C.UTF-8 and en_US.ISO-8859-1, so on a Pi set up exactly as
# documented every subprocess printed "setlocale: cannot change locale",
# two lines per archive, through the progress bar. The Latin-1 extraction
# passes asked for en_AU.ISO-8859-1 for the same reason, so that fallback
# was running under the wrong locale.
check "extract.sh no longer forces a locale before it knows what exists" \
  '! grep -qE "^export (LANG|LC_ALL)=\"\\$\{(LANG|LC_ALL):-en_AU" "$ROOT/extract.sh"'
check "the Latin-1 passes use whichever Latin-1 locale is generated" \
  '! grep -q "LC_ALL=en_AU.ISO-8859-1" "$ROOT/extract.sh" && grep -q "RP_LC_LATIN1" "$ROOT/extract.sh"'
( cd "$ROOT" && env -u LANG -u LC_ALL ./extract.sh -u -d "$T/locale_out" ) > "$T/locale.log" 2>&1 || true
check "a run with no locale set prints no setlocale warnings" \
  '! grep -qi "cannot change locale" "$T/locale.log"'
check "...and still extracts" '[ -n "$(find "$T/locale_out" -name "*.info" 2>/dev/null | head -1)" ]'
# rp_pick_locale itself
check "rp_pick_locale returns one the machine has" \
  '[ -n "$(cd "$ROOT" && bash -c "SCRIPT_DIR=. . ./lib.sh; rp_pick_locale zz_ZZ.UTF-8 C.UTF-8 C.utf8 C")" ]'
check "...and nothing at all when none of them exist" \
  '[ -z "$(cd "$ROOT" && bash -c "SCRIPT_DIR=. . ./lib.sh; rp_pick_locale zz_ZZ.UTF-8 qq_QQ.ISO-8859-9" 2>/dev/null)" ] && [ -n "$(cd "$ROOT" && bash -c "SCRIPT_DIR=. . ./lib.sh; rp_pick_locale qq_QQ.X C.UTF-8" 2>/dev/null)" ]'


section "63. Strict mode, temp files and the IFF converter"
# set -u is on for the pipeline scripts (NOT -e: this pipeline tolerates
# non-zero from some commands on purpose and checks the codes itself).
check "the pipeline scripts run under set -u" \
  '( for f in all.sh extract.sh merge.sh update.sh start.sh; do
        grep -qE "^set -u" "$ROOT/$f" || exit 1; done )'
check "...and none of them turn on errexit, which would abort a partial build" \
  '! grep -qE "^set -e|^set -[a-z]*e[a-z]* " "$ROOT/all.sh" "$ROOT/extract.sh" "$ROOT/merge.sh" "$ROOT/update.sh"'
# (written as a fixed-string grep for the FIX, not the bug: naming the old
# variable inside an eval'd check would expand it and trip set -u)
check "the OS name is read from /etc/os-release, not left empty" \
  'grep -qF "_osr PRETTY_NAME" "$ROOT/extract.sh"'
run osname ./extract.sh -u -d "$T/osname_out"
check "...so the banner names the system instead of printing nothing" \
  '! grep -qE "^Operating System: *$" "$T/osname.log"'
# merge.sh used to put its logs at a guessable /tmp path
check "merge.sh makes a private temp folder instead of /tmp/artwork_merger_*" \
  '! sed -e "s/[[:space:]]#.*$//" -e "s/^[[:space:]]*#.*$//" "$ROOT/merge.sh" | grep -q "/tmp/artwork_merger" &&
   grep -q "mktemp -d" "$ROOT/merge.sh"'
run mtemp ./merge.sh --aga -d "$ROOT/build/retro_aga"
check "...and leaves nothing behind when it finishes" \
  '[ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "whdsync_merge.*" 2>/dev/null | head -1)" ]'
# rp_fetch: a short connect timeout, but a long overall one for big packs
check "downloads give up quickly on a dead host" \
  'grep -q "connect-timeout" "$ROOT/lib.sh"'
check "...but still allow time for a pack of hundreds of megabytes" \
  'grep -qE "RP_FETCH_TIMEOUT:-1800" "$ROOT/lib.sh"'
# Logs get a timestamp; terminals do not.
check "a redirected line carries the date and time" \
  '(cd "$ROOT" && bash -c "SCRIPT_DIR=. . ./lib.sh; rp_info hello") 2>&1 |
     grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} hello$"'

section "64. to_ilbm.py: argument handling and failure paths"
if python3 -c 'import PIL' >/dev/null 2>&1; then
    python3 - "$T/in.png" <<'PYGEN'
import sys
from PIL import Image
Image.new("RGB", (640, 480), (120, 30, 200)).save(sys.argv[1])
PYGEN
    ( cd "$ROOT" && python3 to_ilbm.py "$T/in.png" "$T/out.iff" --width 320 --height 128 --planes 8 ) > "$T/ilbm.log" 2>&1; st=$?
    check "it writes an IFF ILBM and exits 0" \
      '[ "$st" -eq 0 ] && [ -s "$T/out.iff" ] &&
       [ "$(head -c 4 "$T/out.iff")" = "FORM" ] &&
       [ "$(dd if="$T/out.iff" bs=1 skip=8 count=4 2>/dev/null)" = "ILBM" ]'
    ( cd "$ROOT" && python3 to_ilbm.py "$T/in.png" "$T/out2.iff" --like "$T/out.iff" ) >/dev/null 2>&1; st=$?
    check "--like copies the size and depth of artwork already installed" \
      '[ "$st" -eq 0 ] && [ -s "$T/out2.iff" ] &&
       [ "$(wc -c < "$T/out.iff")" -gt 100 ]'
    ( cd "$ROOT" && python3 to_ilbm.py "$T/nope.png" "$T/x.iff" ) > "$T/ilbm_miss.log" 2>&1; st=$?
    check "a missing picture fails with 1 and says which file" \
      '[ "$st" -eq 1 ] && grep -q "no such image" "$T/ilbm_miss.log"'
    echo "not an image" > "$T/junk.bin"
    ( cd "$ROOT" && python3 to_ilbm.py "$T/junk.bin" "$T/x.iff" ) > "$T/ilbm_junk.log" 2>&1; st=$?
    check "something that is not a picture fails with 1, not a traceback" \
      '[ "$st" -eq 1 ] && ! grep -q "Traceback" "$T/ilbm_junk.log"'
    ( cd "$ROOT" && python3 to_ilbm.py "$T/in.png" "$T/x.iff" --like "$T/junk.bin" ) > "$T/ilbm_like.log" 2>&1; st=$?
    check "--like pointed at something that is not an IFF fails cleanly" \
      '[ "$st" -eq 1 ] && ! grep -q "Traceback" "$T/ilbm_like.log"'
    ( cd "$ROOT" && python3 to_ilbm.py "$T/in.png" "$T/nodir/x.iff" ) > "$T/ilbm_dest.log" 2>&1; st=$?
    check "a destination folder that does not exist says so, not 'no such image'" \
      '[ "$st" -eq 1 ] && grep -q "cannot write" "$T/ilbm_dest.log"'
    ( cd "$ROOT" && python3 to_ilbm.py "$T/in.png" "$T/x.iff" --planes 99 ) > "$T/ilbm_planes.log" 2>&1; st=$?
    check "an impossible bitplane count is refused" \
      '[ "$st" -eq 1 ] && grep -q "between 1 and 8" "$T/ilbm_planes.log"'
    ( cd "$ROOT" && python3 to_ilbm.py ) > "$T/ilbm_noargs.log" 2>&1; st=$?
    check "no arguments prints the usage argparse builds" \
      '[ "$st" -eq 2 ] && grep -qi "usage:" "$T/ilbm_noargs.log"'
else
    echo "  (skipped: python3 with Pillow is not installed)"
fi


section "65. Bash 3.2 stays possible everywhere except merge.sh"
# merge.sh is allowed bash 4 (it re-execs itself under it). Everything else
# has to run on macOS's stock bash 3.2, and the way that breaks is silent:
# ${x^^} expands to nothing rather than failing. This is a grep with comments
# and here-documents stripped, so a comment ABOUT the feature does not trip it.
bash4_hits() {   # bash4_hits <file>  -> prints offending lines, if any
    sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' "$1" |
        grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*(\^\^|,,)|declare -A|local -A|\breadarray\b|\bmapfile\b|wait -n'
}
b4_bad=""
for f in "$ROOT"/*.sh; do
    case "${f##*/}" in merge.sh) continue ;; esac
    [ -n "$(bash4_hits "$f")" ] && b4_bad="$b4_bad ${f##*/}"
done
check "no bash 4+ feature outside merge.sh" '[ -z "$b4_bad" ]'
check "merge.sh is the one exception, and re-execs under bash 4" \
  'grep -q "declare -A" "$ROOT/merge.sh" && grep -q "BASH_VERSINFO" "$ROOT/merge.sh" &&
   grep -qE "^ *exec " "$ROOT/merge.sh"'
# ...and the check itself has to work, or it proves nothing.
printf 'x=${foo^^}\n' > "$T/b4probe.sh"
check "the check would actually catch one" '[ -n "$(bash4_hits "$T/b4probe.sh")" ]'
printf '# a comment mentioning ${foo^^} and declare -A\n' > "$T/b4comment.sh"
check "...and does not trip over a comment that mentions one" \
  '[ -z "$(bash4_hits "$T/b4comment.sh")" ]'

section "66. Interrupting a run stops the whole tree, not just its children"
# pkill -P $$ reaches direct children only: the lha/wget a worker launched
# would carry on writing after Ctrl-C. kill 0 would be worse - it signals the
# process group, so a finishing extract.sh would take all.sh down with it.
check "no script signals its whole process group" \
  '( for f in "$ROOT"/*.sh; do
        sed -e "s/[[:space:]]#.*$//" -e "s/^[[:space:]]*#.*$//" "$f" | grep -q "kill 0" && exit 1
     done; exit 0 )'
check "the stage scripts reap the tree instead" \
  '( for f in extract.sh merge.sh sort.sh artwork_sync.sh artwork_fetch.sh; do
        grep -q "rp_reap_children" "$ROOT/$f" || exit 1; done )'
cat > "$T/reap.sh" <<REAPEOF
#!/usr/bin/env bash
SCRIPT_DIR="$ROOT"
. "$ROOT/lib.sh"
cleanup() { rp_reap_children; }
trap cleanup EXIT
( bash -c 'sleep 4242' ) &
sleep 1
exit 0
REAPEOF
chmod +x "$T/reap.sh"
"$T/reap.sh" >/dev/null 2>&1
sleep 2
check "a grandchild of an interrupted run does not survive it" \
  '[ "$(pgrep -f "sleep 4242" 2>/dev/null | grep -c . )" -eq 0 ]'

section "67. Nothing damaged reaches the collection"
check "a zero-length archive is never treated as valid" \
  ': > "$T/empty.lha"; ! (cd "$ROOT" && bash -c "SCRIPT_DIR=. . ./lib.sh; rp_test_archive \"$T/empty.lha\"")'
check "...and a real one still passes" \
  'printf "B\nx.lha\n" > "$T/ok.lha"; (cd "$ROOT" && bash -c "SCRIPT_DIR=. . ./lib.sh; rp_test_archive \"$T/ok.lha\"")'
check "an IFF shorter than its own header is rejected, not installed" \
  'grep -q "came out empty" "$ROOT/artwork_fetch.sh" && grep -qE "lt 32" "$ROOT/artwork_fetch.sh"'
check "a picture too small to be one is rejected before conversion" \
  'grep -q "too small to be one" "$ROOT/artwork_fetch.sh"'
check "the reason a conversion failed outlives the temp folder" \
  'grep -q "artwork_fetch.log" "$ROOT/artwork_fetch.sh"'
check ".lzx is verified with unlzx, not only when lsar happens to be there" \
  'grep -q "unlzx -v" "$ROOT/lib.sh"'

section "68. The crontab is edited by exact text, never by pattern"
check "both marker names are matched" \
  'grep -q "retroplay-all-sh" "$ROOT/install_cron.sh" && grep -q "whdsync-all-sh" "$ROOT/install_cron.sh"'
check "every crontab filter uses -F (plain text, not a regex)" \
  '! grep -nE "grep +-v +\"" "$ROOT/install_cron.sh" && grep -q "grep -v -F" "$ROOT/install_cron.sh"'
check "it never filters on the bare word whdsync, which would eat other lines" \
  '! grep -nE "grep +-v.*[\"'"'"']whdsync[\"'"'"']" "$ROOT/install_cron.sh"'
printf '0 5 * * * /usr/bin/backup.sh\n30 2 * * * cd /x && ./all.sh --cron # retroplay-all-sh-cron\n' > "$T/crontab.txt"
run cronre ./install_cron.sh --time 03:30 --yes
check "re-running it leaves exactly one of our lines, and the user's own line alone" \
  '[ "$(grep -c "retroplay-all-sh" "$T/crontab.txt")" -eq 1 ] &&
   grep -q "backup.sh" "$T/crontab.txt"'

section "69. A mirrored symlink can never point outside downloads/"
check "wget is asked to fetch the file rather than copy the link, when it can" \
  'grep -q -- "--retr-symlinks" "$ROOT/update.sh"'
mkdir -p "$T/symroot/inside/deep" "$T/symoutside"
echo secret > "$T/symoutside/secret.txt"
echo real   > "$T/symroot/inside/real.lha"
ln -sf "$T/symoutside/secret.txt" "$T/symroot/escape.lha"
ln -sf inside/real.lha "$T/symroot/stays.lha"
ln -sf /nowhere/at/all "$T/symroot/broken.lha"
( cd "$ROOT" && bash -c "SCRIPT_DIR=. . ./lib.sh; rp_prune_escaping_symlinks '$T/symroot'" ) >/dev/null 2>&1
check "a link pointing outside is removed" '[ ! -e "$T/symroot/escape.lha" ]'
check "a link that stays inside is left alone" '[ -L "$T/symroot/stays.lha" ]'
check "a dangling link is removed too" '[ ! -e "$T/symroot/broken.lha" ]'
check "what the link pointed at is never touched" '[ -s "$T/symoutside/secret.txt" ]'
check "the sweep runs after every mirror pass" 'grep -q "rp_prune_escaping_symlinks" "$ROOT/update.sh"'

section "70. The Latin-1 locale reaches the extractor's subshell"
# extract_archive runs inside `timeout bash -c ...` - a fresh bash, which sees
# exported variables only. Without the export the Latin-1 passes silently ran
# with no locale at all on every machine that has `timeout`.
check "the chosen locales are exported, not just set" \
  'grep -qE "^export RP_LC_LATIN1 RP_LC_UTF8" "$ROOT/extract.sh"'
check "...and the function that uses them is exported too" \
  'grep -q "export -f extract_archive" "$ROOT/extract.sh"'


section "71. A named variant resolves to its own collection, never to build/retro"
# ./merge.sh --aga-laced looked for build/retro_aga-laced (hyphen), never
# found it, and quietly fell back to build/retro - reporting "destination
# folder not found" on a machine that had three working collections.
mkdir -p "$T/coll/build/retro_aga" "$T/coll/build/retro_aga_laced" "$T/coll/build/retro_ecs"
dc() { ( cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; RP_BUILD_ROOT='$T/coll/build'; rp_default_collection '$1'" ) 2>/dev/null; }
check "the hyphen spelling finds the underscore folder" \
  '[ "$(dc aga-laced)" = "$T/coll/build/retro_aga_laced" ]'
check "the underscore spelling works too" \
  '[ "$(dc aga_laced)" = "$T/coll/build/retro_aga_laced" ]'
check "a plain variant still resolves" '[ "$(dc aga)" = "$T/coll/build/retro_aga" ]'
check "a variant with no collection yet resolves to nothing, not to another one" \
  '[ -z "$(dc rtg)" ]'
check "with no variant named and one collection, that one is used" \
  '[ "$(cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; RP_BUILD_ROOT=\"$T/coll/one\"; mkdir -p \"$T/coll/one/retro_rtg\"; rp_default_collection \"\"")" = "$T/coll/one/retro_rtg" ]'
check "merge.sh says which collection is missing instead of naming build/retro" \
  'grep -q "no collection for" "$ROOT/merge.sh"'

section "72. Stage options imply their stage; a bare variant still opens the menu"
check "--refresh-artwork on its own means the artwork merge" \
  'grep -q "ACTION=\"merge\"" "$ROOT/start.sh"'
check "a bare variant flag is documented as picking the collection, not a stage" \
  'grep -q "Work on retro_aga_laced" "$ROOT/start.sh"'
check "...and the menu says which collection it is about to work on" \
  'grep -q "Working on:" "$ROOT/start.sh"'
check "start.sh no longer claims --aga runs merge.sh" \
  '! grep -q "Run merge.sh with --aga" "$ROOT/start.sh"'

section "73. all.sh builds the laced variants, and aga/ecs take --laced"
check "the shipped default builds all five collections" \
  'grep -q "aga ecs rtg aga-laced ecs-laced" "$ROOT/lib.sh"'
check "the laced artwork packs are fetched by default too" \
  'grep -q "RP_ARTWORK_PACKS=\"AGA ECS RTG AGA_Laced ECS_Laced\"" "$ROOT/lib.sh"'
check "all.sh understands --laced and --all" \
  'grep -q -- "--laced)     WANT_LACED=1" "$ROOT/all.sh" && grep -q -- "--all)" "$ROOT/all.sh"'
check "aga.sh --laced asks for the laced variant" \
  'grep -q -- "--laced) VARIANT=\"--aga-laced\"" "$ROOT/aga.sh"'
check "ecs.sh --laced asks for the laced variant" \
  'grep -q -- "--laced) VARIANT=\"--ecs-laced\"" "$ROOT/ecs.sh"'
run agahelp ./aga.sh --help
check "./aga.sh --help is about aga.sh, not a build nobody asked for" \
  'grep -q "Usage: aga.sh" "$T/agahelp.log" && ! grep -q "start.sh --sync" "$T/agahelp.log"'
run rtghelp ./rtg.sh --help
check "./rtg.sh --help likewise" 'grep -q "Usage: rtg.sh" "$T/rtghelp.log"'
check "a run says how many collections it is about to build" \
  'grep -q "Collections this run:" "$ROOT/all.sh"'

section "74. The long silent pause in merge.sh says what it is doing"
check "the artwork scan announces itself before it starts" \
  'grep -q "Reading artwork" "$ROOT/merge.sh"'
check "each source reports how much it found" \
  'grep -q "artwork folders" "$ROOT/merge.sh"'
check "and the total, with how long it took" \
  'grep -q "Artwork index ready" "$ROOT/merge.sh"'
check "the destination is checked BEFORE the scan, not after it" \
  'code="$(sed -e "s/^[[:space:]]*#.*$//" "$ROOT/merge.sh")"
   d="$(printf "%s" "$code" | grep -n "ERROR: destination folder not found" | head -1 | cut -d: -f1)"
   r="$(printf "%s" "$code" | grep -n "rp_info \"Reading artwork" | head -1 | cut -d: -f1)"
   [ -n "$d" ] && [ -n "$r" ] && [ "$d" -lt "$r" ]'
check "one find per section and category, not one per letter of the alphabet" \
  '! grep -q "for dir_prefix in {A..Z} {0..9}" "$ROOT/merge.sh" && grep -q "mindepth 2 -maxdepth 2" "$ROOT/merge.sh"'
check "the lower-case index key is an expansion, not two forked processes" \
  '! grep -q "_lckey=\"\$(printf" "$ROOT/merge.sh"'
check "the platform-tuning block appears once, not twice" \
  '[ "$(grep -c "Basic platform tuning for progress and parallelism" "$ROOT/merge.sh")" -eq 1 ]'

section "75. Paths that pointed at the pre-migration layout"
check "TinyLauncher is looked for with the other artwork packs" \
  'grep -q "TINYLAUNCHER_SRC=\"\$RP_ARTWORK_ROOT/TinyLauncher\"" "$ROOT/merge.sh"'
check "...and the old spot still works for anyone who has not migrated" \
  'grep -q "SCRIPT_DIR/TinyLauncher" "$ROOT/merge.sh"'
check "update.sh --dry-run compares against the downloads folder" \
  'grep -q "RP_DOWNLOAD_ROOT/\$rel" "$ROOT/update.sh"'
check "sort.sh checks compliance on the collection it just sorted" \
  'grep -q "CHECK_ROOT=\"\$DEST\"" "$ROOT/sort.sh"'
check "...and does not reset the destination to build/retro halfway through" \
  '[ "$(grep -c "DEFAULT_DEST=\"\$RP_BUILD_ROOT/retro\"" "$ROOT/sort.sh")" -eq 0 ]'
check "merge errors land in logs/, where the run looks for them" \
  'grep -q "RP_LOG_ROOT/merge_errors.log" "$ROOT/merge.sh"'
check "sort logs land in logs/ too, not in whatever folder you started from" \
  'grep -q "LOGFILE=\"\$RP_LOG_ROOT/sort.log\"" "$ROOT/sort.sh"'
check "the pipeline gathers each stage's log into retroerror.log" \
  'grep -q "collect_stage_logs" "$ROOT/all.sh"'

section "76. Settings are read exactly as written"
cfg() { ( cd "$ROOT" && bash -c "SCRIPT_DIR=.; RP_INVOKED_FROM='$T/cfg'; . ./lib.sh; rp_load_config; printf '%s' \"\$$1\"" ) 2>/dev/null; }
mkdir -p "$T/cfg"
cat > "$T/cfg/retroplay.conf" << 'CFGEOF'
# a whole-line comment mentioning #hashes
NTFY_TOPIC="retro#build"
VARIANTS="aga ecs"          # a trailing comment
LOG_KEEP=6   # six of them
NTFY_SERVER='https://ntfy.sh/#x'
CFGEOF
check "a # inside a double-quoted value is kept" '[ "$(cfg RP_NTFY_TOPIC)" = "retro#build" ]'
check "a # inside a single-quoted value is kept" '[ "$(cfg RP_NTFY_SERVER)" = "https://ntfy.sh/#x" ]'
check "a trailing comment after a quoted value is dropped" '[ "$(cfg RP_VARIANTS)" = "aga ecs" ]'
check "a trailing comment after a bare value is dropped" '[ "$(cfg RP_LOG_KEEP)" = "6" ]'
printf 'UPDATE_CHECK_INTERVAL_HOURS=%s\n' "soon" > "$T/cfg/retroplay.conf"
check "a non-numeric update interval falls back to the default" '[ "$(cfg RP_UPDATE_CHECK_INTERVAL_HOURS)" = "24" ]'
printf 'UPDATE_CHECK_INTERVAL_HOURS=-5\n' > "$T/cfg/retroplay.conf"
check "a negative one does too" '[ "$(cfg RP_UPDATE_CHECK_INTERVAL_HOURS)" = "24" ]'
printf 'UPDATE_CHECK_INTERVAL_HOURS=0\n' > "$T/cfg/retroplay.conf"
check "zero is allowed and means every run" '[ "$(cfg RP_UPDATE_CHECK_INTERVAL_HOURS)" = "0" ]'
printf 'NICE=maybe\n' > "$T/cfg/retroplay.conf"
check "NICE only accepts auto or no" '[ "$(cfg RP_NICE)" = "auto" ]'
rm -f "$T/cfg/retroplay.conf"

section "77. Replacing a collection never leaves the drive without one"
rt() { ( cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; $*" ) 2>/dev/null; }
rm -rf "$T/rt"; mkdir -p "$T/rt/cand" "$T/rt/live"
echo new > "$T/rt/cand/f"; echo old > "$T/rt/live/f"
rt "rp_replace_tree '$T/rt/cand' '$T/rt/live' '$T/rt/bk/keep'"
check "the new tree is live" '[ "$(cat "$T/rt/live/f")" = "new" ]'
check "the old one is kept as the backup" '[ "$(cat "$T/rt/bk/keep/f")" = "old" ]'
check "no staging folders are left behind" \
  '[ -z "$(find "$T/rt" -maxdepth 1 -name "live.*" 2>/dev/null)" ]'
rm -rf "$T/rt2"; mkdir -p "$T/rt2/live"; echo old > "$T/rt2/live/f"
rt "rp_replace_tree '$T/rt2/missing' '$T/rt2/live' '$T/rt2/bk'"
check "a missing candidate changes nothing" '[ "$(cat "$T/rt2/live/f")" = "old" ]'
# The backup cannot be made (its parent is a file), but the swap must still
# finish - and the previous collection must NOT be deleted to hide that.
rm -rf "$T/rt3"; mkdir -p "$T/rt3/cand" "$T/rt3/live"
echo new > "$T/rt3/cand/f"; echo old > "$T/rt3/live/f"; : > "$T/rt3/blocked"
rt "rp_replace_tree '$T/rt3/cand' '$T/rt3/live' '$T/rt3/blocked/sub/keep'"
check "an unusable backup location does not stop the replacement" \
  '[ "$(cat "$T/rt3/live/f")" = "new" ]'
check "...and the previous collection is kept, not quietly deleted" \
  '[ -n "$(find "$T/rt3" -maxdepth 1 -name "live.previous.*" 2>/dev/null)" ]'
check "the candidate is staged beside the live folder before the swap" \
  'grep -q "inc=\"\$live.incoming" "$ROOT/lib.sh"'

section "78. BMHD is found wherever it sits in the IFF file"
python3 - "$T" << 'PYIFF'
import struct, sys, os
d = sys.argv[1]
def chunk(cid, p):
    out = cid + struct.pack(">I", len(p)) + p
    return out + (b"\x00" if len(p) & 1 else b"")
def bmhd(w, h, planes):
    return struct.pack(">HHhhBBBBHBBhh", w, h, 0, 0, planes, 0, 1, 0, 0, 10, 11, w, h)
def form(body): return b"FORM" + struct.pack(">I", 4 + len(body)) + b"ILBM" + body
open(os.path.join(d, "first.iff"), "wb").write(form(chunk(b"BMHD", bmhd(320, 128, 8))))
# BMHD pushed past the first 64 bytes by a leading ANNO chunk
open(os.path.join(d, "late.iff"), "wb").write(form(chunk(b"ANNO", b"x" * 120) + chunk(b"BMHD", bmhd(160, 64, 5))))
open(os.path.join(d, "none.iff"), "wb").write(form(chunk(b"ANNO", b"y" * 8)))
open(os.path.join(d, "cut.iff"), "wb").write(form(chunk(b"ANNO", b"z" * 200))[:40])
PYIFF
bm() { ( cd "$ROOT" && python3 -c "
import importlib.util, sys
s = importlib.util.spec_from_file_location('t', 'to_ilbm.py')
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
try: print('%dx%dx%d' % m.read_bmhd(sys.argv[1]))
except Exception as e: print('refused')
" "$1" ) 2>/dev/null; }
check "BMHD as the first chunk still reads" '[ "$(bm "$T/first.iff")" = "320x128x8" ]'
check "BMHD past the first 64 bytes is found" '[ "$(bm "$T/late.iff")" = "160x64x5" ]'
check "a file with no BMHD is refused, not guessed at" '[ "$(bm "$T/none.iff")" = "refused" ]'
check "a truncated file is refused without a traceback" '[ "$(bm "$T/cut.iff")" = "refused" ]'
check "the supported Python version is not in doubt (no X | None at runtime)" \
  '! grep -q "List\[str\] | None" "$ROOT/to_ilbm.py"'

section "79. The artwork search command may carry its own arguments"
check "it is split into an argument list, never run through a shell" \
  'grep -q "FETCH_CMD=(\$RP_ARTWORK_FETCH_COMMAND)" "$ROOT/artwork_fetch.sh"'
check "...and never through eval" '! grep -qE "^[^#]*\beval\b" "$ROOT/artwork_fetch.sh"'
check "the command is run from that array" 'grep -q "\"\${FETCH_CMD\[@\]}\"" "$ROOT/artwork_fetch.sh"'
check "an executable that is not on PATH is reported before anything is tried" \
  'grep -q "which is not an executable on PATH" "$ROOT/artwork_fetch.sh"'

section "80. Every script understands the same output options"
for s in update.sh extract.sh merge.sh sort.sh; do
  check "$s accepts --quiet, --verbose and --color" "grep -q 'rp_common_opt' \"\$ROOT/$s\""
done
run quietmerge ./merge.sh --quiet --nonsense-option
check "an unknown option is still refused after the common ones are handled" \
  '[ "$?" -ne 0 ] || grep -q "Unknown option" "$T/quietmerge.log"'
check "setup.sh takes its colours from the shared decision, not raw escapes" \
  '! grep -q "printf .\\\\n\\\\033\[1m== " "$ROOT/setup.sh" && grep -q "RP_C_HEAD" "$ROOT/setup.sh"'
check "start.sh no longer blanks the colours lib.sh just chose" \
  '! grep -qE "^RED=\"\"" "$ROOT/start.sh"'

section "81. Housekeeping without parsing ls output"
check "no script builds a file list out of ls" \
  '( for f in "$ROOT"/*.sh; do
       case "${f##*/}" in doctor.sh) continue ;; esac
       sed -e "s/[[:space:]]#.*$//" -e "s/^[[:space:]]*#.*$//" "$f" | grep -q "ls -1" && exit 1
     done; exit 0 )'
lsh() { ( cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; $*" ) 2>/dev/null; }
rm -rf "$T/ls"; mkdir -p "$T/ls"
for i in 1 2 3 4 5; do : > "$T/ls/state-2026010$i.tgz"; done
check "counting matches a glob" '[ "$(lsh "rp_count_matching \"$T/ls/state-*.tgz\"")" = "5" ]'
check "counting nothing gives zero, not an error" '[ "$(lsh "rp_count_matching \"$T/ls/none-*\"")" = "0" ]'
check "the newest is the last in shell order" \
  '[ "$(lsh "rp_newest_matching \"$T/ls/state-*.tgz\"")" = "$T/ls/state-20260105.tgz" ]'
lsh "rp_prune_oldest 2 \"$T/ls/state-*.tgz\""
check "pruning keeps exactly the newest few" '[ "$(lsh "rp_count_matching \"$T/ls/state-*.tgz\"")" = "2" ]'
check "...and the ones it keeps are the newest" '[ -e "$T/ls/state-20260105.tgz" ] && [ ! -e "$T/ls/state-20260101.tgz" ]'
check "the interactive artwork prompt reads with -r" \
  'grep -q "read -r -t 30 -p" "$ROOT/merge.sh"'

section "82. Unattended runs are gentle, interactive ones are not slowed down"
check "nice is only applied off a terminal" 'grep -q "\[ ! -t 1 \]" "$ROOT/lib.sh"'
check "extraction workers use the prefix" 'grep -q "NICE_PREFIX \$TIMEOUT_CMD" "$ROOT/extract.sh"'
check "NICE=no turns it off" \
  '[ -z "$(cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; RP_NICE=no; rp_nice_prefix")" ]'
check "a missing nice or ionice is not an error" \
  'grep -q "command -v ionice >/dev/null 2>&1 && ionice" "$ROOT/lib.sh" &&
   grep -q "command -v nice >/dev/null 2>&1" "$ROOT/lib.sh" &&
   ( cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; rp_nice_prefix" >/dev/null 2>&1 )'
check "the wait loop never busy-spins when sleep has no fractions" \
  'grep -q "rp_short_sleep" "$ROOT/lib.sh" && ! grep -qE "^[^#]*sleep 0\.1" "$ROOT/extract.sh" "$ROOT/merge.sh" "$ROOT/sort.sh"'

section "83. Package installs stay behind the explicit opt-in on every platform"
check "extract.sh checks the opt-in before the platform branch" \
  '[ "$(grep -n "rp_may_install_tools" "$ROOT/extract.sh" | head -1 | cut -d: -f1)" -lt "$(grep -n "OS_TYPE.*==.*darwin" "$ROOT/extract.sh" | head -1 | cut -d: -f1)" ]'
check "start.sh's helper checks it too" \
  'grep -q "rp_may_install_tools" "$ROOT/start.sh"'

section "84. Counting and numbering the user actually sees"
check "all.sh announces all five of the steps it counts" \
  '[ "$(grep -c "rp_step [1-5] \"\$TOTAL_STEPS\"" "$ROOT/all.sh")" -ge 5 ]'
check "setup.sh numbers its steps 1-9 with none repeated" \
  '[ "$(grep -o "step \"[0-9]\." "$ROOT/setup.sh" | sort -u | wc -l | tr -d " ")" = "$(grep -c "step \"[0-9]\." "$ROOT/setup.sh")" ]'
check "the schedule is read back from the crontab, not assumed to be 2am" \
  '! grep -q "every night at 2am" "$ROOT/lib.sh"'
check "merge.sh lists --only-missing once" \
  '[ "$(grep -c "echo \"  --only-missing " "$ROOT/merge.sh")" -eq 1 ]'
check "start.sh has no dead quick.sh dispatch left" \
  '! grep -q "build_quick_args" "$ROOT/start.sh" || ! grep -q "ACTION\" = \"quick\"" "$ROOT/start.sh"'


section "85. Each collection's reported time is its own work, not zero"
check "vstart is set before a variant's work, not only read" \
  '[ "$(grep -c "^[[:space:]]*vstart=\$SECONDS" "$ROOT/all.sh")" -ge 3 ]'
check "...once for each of the three places a collection is worked on" \
  '[ "$(grep -c "variant_row" "$ROOT/all.sh")" -ge 4 ]'
# A real run must now show a non-zero time for the collection it built.
check "the summary's Time column is filled in from real work" \
  'grep -q "rp_format_duration" "$ROOT/all.sh"'


section "86. doctor.sh reports on the folders the suite actually uses"
# A self-contained tree: a built collection, real downloads, laced artwork
# installed the way artwork_sync.sh installs it (inside its pack, not beside it).
DOC="$T/doc"; rm -rf "$DOC"; mkdir -p "$DOC"
cp "$REPO"/*.sh "$REPO"/to_ilbm.py "$DOC"/ 2>/dev/null
chmod +x "$DOC"/*.sh
mkdir -p "$DOC/build/retro_aga/WHDLoad/Games" \
         "$DOC/downloads/WHDLoad" "$DOC/downloads/old" \
         "$DOC/artwork/iGame_AGA/lores/Covers/Games/A" \
         "$DOC/artwork/iGame_AGA/laced/Covers/Games/A" \
         "$DOC/artwork/TinyLauncher" \
         "$DOC/.retroplay/complete"
echo keep > "$DOC/build/retro_aga/WHDLoad/Games/keep"
echo art  > "$DOC/artwork/iGame_AGA/laced/Covers/Games/A/iGame.iff"
head -c 9000000 /dev/zero > "$DOC/downloads/WHDLoad/big.lha"
printf 'VARIANTS="aga aga-laced rtg"\n' > "$DOC/retroplay.conf"
( cd "$DOC" && ./doctor.sh ) > "$T/doctor.log" 2>&1
sed -e 's/\x1b\[[0-9;]*m//g' "$T/doctor.log" > "$T/doctor.txt"
check "a built collection is reported as built, not as missing" \
  'grep -q "retro_aga: built" "$T/doctor.txt"'
check "...and one that really is missing still reads as not built" \
  'grep -q "retro_rtg: not built yet" "$T/doctor.txt"'
check "the downloads folder is measured, not the script folder" \
  '! grep -q "downloads use 0 MB" "$T/doctor.txt"'
check "laced artwork inside its pack counts as installed" \
  'grep -q "aga-laced: artwork installed" "$T/doctor.txt"'
check "...so it is not reported as a missing iGame_AGA_LACED folder" \
  '! grep -q "iGame_AGA_LACED" "$T/doctor.txt"'
check "a pack that really is absent is still reported" \
  'grep -q "for the .rtg. variant" "$T/doctor.txt"'
check "TinyLauncher in artwork/ is found" \
  'grep -q "TinyLauncher (last-resort screenshots)" "$T/doctor.txt"'
check "the artwork folder is named, not 'next to the scripts'" \
  '! grep -q "next to the scripts" "$T/doctor.txt"'
check "doctor changes nothing it reports on" \
  '[ ! -e "$DOC/HD_Loaders" ] && [ ! -e "$DOC/WHDLoad" ] && [ ! -d "$DOC/retro_aga" ]'

section "87. doctor.sh honours NO_COLOR and the shared colour decision"
( cd "$DOC" && NO_COLOR=1 ./doctor.sh ) > "$T/doctor_nc.log" 2>&1
check "NO_COLOR leaves no escape sequences in a saved report" \
  '! grep -q "$(printf "\033")" "$T/doctor_nc.log"'
( cd "$DOC" && ./doctor.sh --color=never ) > "$T/doctor_cn.log" 2>&1
check "--color=never does the same" '! grep -q "$(printf "\033")" "$T/doctor_cn.log"'
( cd "$DOC" && ./doctor.sh --nonsense ) > "$T/doctor_bad.log" 2>&1
check "an unknown option is still refused" \
  '[ "$?" -ne 0 ] || grep -q "Unknown option" "$T/doctor_bad.log"'
( cd "$DOC" && ./doctor.sh --help ) > "$T/doctor_help.log" 2>&1
check "--help still works and says it changes nothing" \
  'grep -q "Changes nothing" "$T/doctor_help.log"'
check "no raw escape sequences left in the source" \
  '! grep -q "printf .  .\\\\033\[32m" "$DOC/doctor.sh"'

section "88. doctor.sh reads the schedule back instead of assuming it"
mkdir -p "$T/docbin"
cat > "$T/docbin/crontab" << 'CRONEOF'
#!/usr/bin/env bash
[ "${1:-}" = "-l" ] && { cat "$(dirname "$0")/ct.txt" 2>/dev/null; exit 0; }
cat > "$(dirname "$0")/ct.txt"; exit 0
CRONEOF
chmod +x "$T/docbin/crontab"
for m in retroplay-all-sh-cron whdsync-all-sh-cron; do
  printf '45 3 * * * cd /x && ./all.sh --cron # %s\n' "$m" > "$T/docbin/ct.txt"
  ( cd "$DOC" && PATH="$T/docbin:$PATH" ./doctor.sh ) 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g' > "$T/doctor_$m.txt"
  check "the $m marker is recognised" 'grep -q "installed: 45 3" "$T/doctor_'"$m"'.txt"'
  check "...and the real time is reported, not 2am ($m)" \
    'grep -q "runs every night at 03:45" "$T/doctor_'"$m"'.txt"'
done
: > "$T/docbin/ct.txt"
( cd "$DOC" && PATH="$T/docbin:$PATH" ./doctor.sh ) 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g' > "$T/doctor_nocron.txt"
check "no entry reads as not installed" 'grep -q "not installed (optional)" "$T/doctor_nocron.txt"'

section "89. One rule for where each variant's artwork lives"
ad() { ( cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; rp_artwork_dir_for '$1'" ) 2>/dev/null; }
check "aga maps to its lores folder"        '[ "$(ad aga)" = "iGame_AGA/lores" ]'
check "aga-laced maps INSIDE the same pack" '[ "$(ad aga-laced)" = "iGame_AGA/laced" ]'
check "ecs-laced likewise"                  '[ "$(ad ecs-laced)" = "iGame_ECS/laced" ]'
check "rtg has no flavour folder"           '[ "$(ad rtg)" = "iGame_RTG" ]'
check "the folder spelling works too"       '[ "$(ad aga_laced)" = "iGame_AGA/laced" ]'
check "an unknown variant maps to nothing"  '[ -z "$(ad nonsense)" ]'
check "doctor and update.sh share the rule rather than each keeping a copy" \
  'grep -q "rp_artwork_installed" "$ROOT/doctor.sh" &&
   ! grep -q "iGame_\$(printf" "$ROOT/doctor.sh"'


section "90. A build works with macOS pgrep, and a failed stage says why"
# macOS's BSD pgrep leaves out its own ancestors, so asked for the children
# of a process that has none it exits 1. sort.sh runs under set -e, and that
# exit 1 in its cleanup trap turned a finished sort into "sorting failed" -
# on the Mac only, with nothing in the logs. This pgrep behaves like BSD's.
mkdir -p "$T/bsdbin"
cat > "$T/bsdbin/pgrep" << 'PGEOF'
#!/usr/bin/env bash
[ "${1:-}" = "-P" ] || exec /usr/bin/pgrep "$@"
ppid="$2"; anc=" $$ "; p=$$
while [ "${p:-1}" -gt 1 ]; do p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"; [ -n "$p" ] || break; anc="$anc$p "; done
out="$(ps -ax -o pid=,ppid= | awk -v pp="$ppid" '$2 == pp {print $1}' |
       while read -r c; do case "$anc" in *" $c "*) ;; *) echo "$c" ;; esac; done)"
[ -n "$out" ] && { echo "$out"; exit 0; }
exit 1
PGEOF
chmod +x "$T/bsdbin/pgrep"
check "the BSD-style pgrep really does exit 1 with no children (the trigger)" \
  '! "$T/bsdbin/pgrep" -P $$ >/dev/null'
run bsdsort env PATH="$T/bsdbin:$PATH" ./all.sh --rebuild --variants aga; st=$?
check "a full build succeeds with BSD pgrep semantics" '[ "$st" -eq 0 ]'
check "...and never reports that sorting failed" '! grep -qi "sorting.*failed" "$T/bsdsort.log"'
check "rp_child_pids returns 0 when a process has no children" \
  '( cd "$ROOT" && PATH="$T/bsdbin:$PATH" bash -c "set -e; SCRIPT_DIR=.; . ./lib.sh; rp_child_pids \$\$ >/dev/null" )'
# Judged by whether the cleanup REACHED ITS END, not by the exit status: bash
# 5 can exit 0 even when errexit cut an EXIT trap short (bash 3.2 on a Mac
# exits 1), so the status alone would pass on Linux with the bug still there.
# (A script file with a cleanup FUNCTION, as sort.sh has - the inline bash -c
# form does not trip it.)
rm -f "$T/reaped.marker"
cat > "$T/reapprobe.sh" << 'RPEOF'
set -euo pipefail
SCRIPT_DIR=.; . ./lib.sh
cleanup() { local st=$?; rp_reap_children; touch "$MARK"; exit "$st"; }
trap cleanup EXIT
echo "work done"
RPEOF
( cd "$ROOT" && MARK="$T/reaped.marker" PATH="$T/bsdbin:$PATH" bash "$T/reapprobe.sh" ) >/dev/null 2>&1; st=$?
check "a set -e cleanup trap runs to its end after reaping (BSD pgrep)" \
  '[ -e "$T/reaped.marker" ] && [ "$st" -eq 0 ]'
( cd "$ROOT" && PATH="$T/bsdbin:$PATH" RP_CHILD=1 bash ./sort.sh --dest "$ROOT/build/retro_aga" --skip-variant-sort --called-from-all ) > "$T/bsd_sortonly.log" 2>&1; st=$?
check "sort.sh itself exits 0 under BSD pgrep, as all.sh runs it" '[ "$st" -eq 0 ]'
check "sort.sh's cleanup cannot be cut short by errexit" \
  'sed -n "/^cleanup_sort()/,/^}/p" "$ROOT/sort.sh" | grep -q "set +e"'
check "an ordinary sort does not trip the new error trap" \
  '! grep -q "sort.sh stopped at line" "$T/bsdsort.log" "$T"/*.log 2>/dev/null'

# A stage that really does fail must say which, how, and where to look.
# sort.sh's own handler, lifted out and run against a command that fails.
mkdir -p "$T/failsort"
# trap_harness <file> - the first lines of a script that uses sort.sh's own
# handler and its own trap line, lifted out of sort.sh as they stand.
trap_harness() {
    {
        echo 'set -euo pipefail'
        echo "RP_LOG_ROOT='$T/failsort/logs'"
        sed -n '/^sort_stopped()/,/^}/p' "$ROOT/sort.sh"
        echo 'set -E'
        grep '^trap .sort_stopped' "$ROOT/sort.sh"
    } > "$1"
}
trap_harness "$T/failsort/real.sh"
echo 'ls /definitely/not/here >/dev/null' >> "$T/failsort/real.sh"
( cd "$ROOT" && bash "$T/failsort/real.sh" ) > "$T/failsort/out.log" 2>&1
check "a silent errexit now names the command that failed" \
  'grep -q "this command failed with exit" "$T/failsort/out.log" && grep -q "/definitely/not/here" "$T/failsort/out.log"'
check "...and records it in logs/sort.log for retroerror.log" \
  'grep -q "/definitely/not/here" "$T/failsort/logs/sort.log"'
check "a failed stage reports its exit status and where the details are" \
  'grep -q "failed with exit status" "$ROOT/all.sh" && grep -q "Details: \$RP_LOG_ROOT/retroerror.log" "$ROOT/all.sh"'
check "...and writes that into retroerror.log, not just the screen" \
  'sed -n "/^stage_failed()/,/^}/p" "$ROOT/all.sh" | grep -q "retroerror.log"'
check "no stage still fails with a bare message" \
  '! grep -q "fail \"sorting failed\"" "$ROOT/all.sh"'


section "91. Release 0.5 is what every script reports"
check "lib.sh says release 0.5" 'grep -q "^RP_RELEASE=\"0.5\"" "$ROOT/lib.sh"'
check "every script carries lib.sh's suite stamp" \
  'v="$(sed -n "s/^RP_SUITE_VERSION=\"\([^\"]*\)\"/\1/p" "$ROOT/lib.sh")";
   [ -n "$v" ] && [ -z "$(grep -L "^# retroplay-suite: $v " "$ROOT"/*.sh | grep -v "/lib.sh$")" ]'
run relver ./start.sh --version
check "--version reports it" 'grep -q "^whdsync 0.5 " "$T/relver.log"'

section "92. NOCOLOR is honoured like NO_COLOR, and --color=always still wins"
cl() { ( cd "$ROOT" && env "$@" RP_FORCE_TTY=1 bash -c 'SCRIPT_DIR=.; . ./lib.sh; rp_colour_on && echo on || echo off' ) 2>/dev/null; }
check "NOCOLOR=1 turns colour off on a terminal"    '[ "$(cl NOCOLOR=1)" = off ]'
check "NOCOLOR with any value does too"             '[ "$(cl NOCOLOR=yes)" = off ]'
check "--color=always overrides NOCOLOR (as no-color.org says a flag should)" \
  '[ "$(cl NOCOLOR=1 RP_COLOR=always)" = on ]'
check "--color=never beats a terminal"              '[ "$(cl RP_COLOR=never)" = off ]'

section "93. The lock record says which scripts took it"
( cd "$ROOT" && bash -c 'SCRIPT_DIR=.; . ./lib.sh; rp_load_config; RP_RUN_ID=t93; rp_lock_write_info "all.sh --cron"' ) 2>/dev/null
check "suite_version and release are recorded" \
  'grep -q "^suite_version=" "$ROOT/.all.lock.info" && grep -q "^release=0.5" "$ROOT/.all.lock.info"'
sed -i.bak 's/^pid=.*/pid=999999/' "$ROOT/.all.lock.info" && rm -f "$ROOT/.all.lock.info.bak"
run unl ./start.sh --unlock-stale
check "--unlock-stale shows it, one fact per line" \
  'grep -q "Scripts:  .*(release 0.5)" "$T/unl.log" && grep -q "PID:      999999" "$T/unl.log"'
check "...and removes a lock whose run is gone" '[ ! -f "$ROOT/.all.lock.info" ]'

section "94. Read-only commands work even when the archive tools are missing"
# --doctor exists to explain how to install missing tools; it used to refuse
# to run because they were missing. Same for --status, --plan, --why-*.
NOTOOLS="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$MOCK" | paste -sd: -)"
for c in --status --doctor "--why-build aga" --show-failed "--why-queued Alpha"; do
  ( cd "$ROOT" && PATH="$NOTOOLS" ./start.sh $c ) < /dev/null > "$T/notools.log" 2>&1
  check "start.sh $c is not blocked by the archive-tool check" '! grep -q "Still missing" "$T/notools.log"'
done
# lib.sh adds back the PATH an earlier interactive run remembered (so cron
# can find tools), and earlier sections here remembered one that holds the
# mock tools. Set it aside for this one check so the tools really are gone.
mv "$ROOT/.retroplay/user_path" "$T/user_path.save" 2>/dev/null
( cd "$ROOT" && PATH="$NOTOOLS" ./start.sh --sync --aga ) < /dev/null > "$T/notools_sync.log" 2>&1; st=$?
mv "$T/user_path.save" "$ROOT/.retroplay/user_path" 2>/dev/null
if ! PATH="$NOTOOLS" command -v lha >/dev/null 2>&1; then
  check "...while a real build still stops for a missing tool" '[ "$st" -eq 4 ] && grep -q "Still missing" "$T/notools_sync.log"'
fi

section "95. --help anywhere on the line is help, never a run"
: > "$MOCK/wget_calls"; : > "$MOCK/extract_calls"
run hlp1 ./aga.sh --rebuild --help
check "./aga.sh --rebuild --help shows help" 'grep -q "Usage: aga.sh" "$T/hlp1.log"'
check "...and builds nothing" '[ ! -s "$MOCK/wget_calls" ] && [ ! -s "$MOCK/extract_calls" ]'
run hlp2 ./start.sh --sync --help
check "./start.sh --sync --help shows help and builds nothing" \
  'grep -q "^Everyday" "$T/hlp2.log" && [ ! -s "$MOCK/extract_calls" ]'
run hlp3 ./start.sh --help advanced
check "--help advanced still takes its topic" '[ "$(grep -c . "$T/hlp3.log")" -gt 50 ]'

section "96. --why-queued explains one archive and changes nothing"
printf 'WHDLoad/Games/Z/Zool_v1.3_AGA_1234.lha\n' >> "$ROOT/.retroplay/queue/retro_aga.list"
before="$(cd "$ROOT/.retroplay" && find . -type f -exec cksum {} + 2>/dev/null | sort)"
run wq ./start.sh --why-queued zool
after="$(cd "$ROOT/.retroplay" && find . -type f -exec cksum {} + 2>/dev/null | sort)"
check "it finds the archive in the AGA queue" 'grep -q "retro_aga .*Zool_v1.3_AGA_1234.lha" "$T/wq.log"'
check "it says why ECS never queues an AGA release" 'grep -q "retro_ecs leaves out AGA releases" "$T/wq.log"'
check "nothing in the state folder changed" '[ "$before" = "$after" ]'
grep -vF "Zool_v1.3_AGA_1234.lha" "$ROOT/.retroplay/queue/retro_aga.list" > "$T/q.tmp"; cat "$T/q.tmp" > "$ROOT/.retroplay/queue/retro_aga.list"
run wq2 ./start.sh --why-queued NoSuchGame
check "an unknown archive is reported plainly" 'grep -q "not queued for any collection" "$T/wq2.log"'

section "97. The support bundle holds nothing private"
cp "$ROOT/retroplay.conf" "$T/conf.save"
cat >> "$ROOT/retroplay.conf" << 'SBEOF'
NTFY_TOPIC="sb-topic-77315"
NOTIFY_EMAIL="someone@example.com"
ARTWORK_FETCH_COMMAND="python3 /opt/find.py --key sk-SECRET-42"
NTFY_SERVER="https://me:pa55word@ntfy.example.com"
SBEOF
mkdir -p "$ROOT/logs"
printf '2026-10-01 notify to sb-topic-77315 failed from %s/x\n' "$HOME" >> "$ROOT/logs/update.log"
run sb ./start.sh --support-bundle; st=$?
bundle="$(ls -1 "$ROOT"/logs/whdsync-support-*.tar.gz 2>/dev/null | tail -1)"
rm -rf "$T/sbx"; mkdir -p "$T/sbx"; [ -n "$bundle" ] && tar -xzf "$bundle" -C "$T/sbx"
check "a bundle is written" '[ "$st" -eq 0 ] && [ -n "$bundle" ]'
check "it has the status, the doctor report and the settings" \
  'ls "$T"/sbx/*/status.txt "$T"/sbx/*/doctor.txt "$T"/sbx/*/retroplay.conf.txt >/dev/null 2>&1'
for secret in sb-topic-77315 someone@example.com sk-SECRET-42 /opt/find.py pa55word "$HOME/"; do
  check "it does not contain: $secret" '! grep -rqF -- "$secret" "$T/sbx"'
done
check "private settings are shown as hidden, not dropped" 'grep -q "^NTFY_TOPIC=\"<hidden>\"" "$T"/sbx/*/retroplay.conf.txt'
check "no game, archive or artwork file is in it" \
  '! tar -tzf "$bundle" | grep -qiE "\.(lha|lzx|zip|iff|info|slave)$"'
cp "$T/conf.save" "$ROOT/retroplay.conf"; rm -f "$ROOT"/logs/whdsync-support-*.tar.gz

section "98. Deleting backups is its own command, never a question at the end of a build"
check "all.sh no longer asks" '! grep -q "Delete them?" "$ROOT/all.sh"'
BK="$ROOT/.retroplay_backups"      # RP_BACKUP_DIR: $RP_BASE_DIR/.retroplay_backups
mkdir -p "$BK"; head -c 4096 /dev/zero > "$BK/state-20260101-000000.tgz"
run cb1 ./start.sh --clean-backups; st=$?
check "unattended and without --yes it refuses and deletes nothing" '[ "$st" -ne 0 ] && [ -f "$BK/state-20260101-000000.tgz" ]'
run cb2 ./start.sh --clean-backups --yes; st=$?
check "with --yes it deletes them" '[ "$st" -eq 0 ] && [ ! -e "$BK/state-20260101-000000.tgz" ]'

section "99. Manifests are versioned and travel with the collection"
run mf ./all.sh --rebuild --variants aga
check "the state manifest has a schema version" 'grep -q "^manifest_version=1" "$ROOT/.retroplay/manifest/retro_aga"'
check "the collection carries its own copy" 'grep -q "^variant=retro_aga" "$ROOT/build/retro_aga/.whdsync_manifest.conf"'
check "...which does not upset the layout rule" '[ -z "$(cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; rp_layout_problems \"$ROOT/build/retro_aga\"")" ]'

section "100. An interrupted pack swap is finished or undone, never left half-done"
RA="$T/recov/artwork/iGame_AGA/laced"; rm -rf "$T/recov"
mkdir -p "$RA/Covers.previous.999991/Games" "$RA/Covers.incoming.999991"; echo old > "$RA/Covers.previous.999991/Games/x"
( cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; rp_recover_replacements '$T/recov/artwork'" ) >/dev/null 2>&1
check "with the live pack gone, the previous one is put back" '[ "$(cat "$RA/Covers/Games/x" 2>/dev/null)" = old ]'
check "...and the half-staged one is removed" '[ ! -e "$RA/Covers.incoming.999991" ]'
mkdir -p "$RA/Screens" "$RA/Screens.previous.999992"; echo old > "$RA/Screens.previous.999992/f"
( cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; rp_recover_replacements '$T/recov/artwork'" ) >/dev/null 2>&1
check "with the new pack in place, the old copy is kept, not deleted" '[ -f "$RA/Screens.previous.999992/f" ]'
mkdir -p "$RA/Titles.incoming.$$"
( cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; rp_recover_replacements '$T/recov/artwork'" ) >/dev/null 2>&1
check "a run that is still going is left alone" '[ -d "$RA/Titles.incoming.$$" ]'
check "artwork_sync.sh takes the one run lock, not a private one" \
  'grep -q "rp_lock_for_stage \"artwork_sync.sh" "$ROOT/artwork_sync.sh" &&
   ! sed -e "s/[[:space:]]#.*$//" -e "s/^[[:space:]]*#.*$//" "$ROOT/artwork_sync.sh" | grep -q "artwork.lock"'
if [ -n "$FLOCK" ]; then
    rm -rf "$ROOT/.all.lock.d" "$ROOT/.all.lock.info"
    ( exec 9>"$ROOT/.all.lock"; "$FLOCK" 9; sleep 300 ) & holder=$!
    sleep 1
    run artlock ./artwork_sync.sh --sync; st=$?
    check "a hand-run artwork sync is refused while a build holds the lock" '[ "$st" -eq 4 ] && grep -q "already running" "$T/artlock.log"'
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
fi

section "101. Five phases, and where the build time went"
run ph ./all.sh --rebuild --variants aga
for n in "1/5] Preflight" "2/5] Updates" "3/5] Plan" "4/5] Build" "5/5] Finalise"; do
  check "the run announces [$n" 'grep -qF "[$n" "$T/ph.log"'
done
check "artwork is part of Updates, not a phase of its own" '! grep -q "\[Artwork\] checking" "$T/ph.log"'
check "the report says how long extract, sort, merge and install took" \
  'grep -q "Inside the build" "$T/ph.log" && grep -q "artwork merge" "$T/ph.log"'
check "no bare ===== banners are left in all.sh" '! grep -q "echo \"===== " "$ROOT/all.sh"'

section "102. The A314 GUI builds its command line safely"
GUI="$REPO/a314_retroplay_gui.c"
check "no strcpy or strcat into fixed buffers remain" '! grep -nE "(^|[^A-Za-z_])str(cpy|cat)\(" "$GUI"'
check "it sends the laced options start.sh actually has, not --ecs-lo/--aga-lo" \
  'grep -q -- "--aga-laced" "$GUI" && ! grep -q -- "-lo\"" "$GUI"'
check "it copies from the per-variant build folder, not the retired retro/" \
  'grep -q "PI_BUILD_SOURCE" "$GUI" && ! grep -q "PI_RETRO_SOURCE  \"" "$GUI"'
check "no C99 compound literal (the SAS/C build line must work)" '! grep -q "(struct TagItem\[\])" "$GUI"'
if command -v cc >/dev/null 2>&1; then
  { echo '#include <stdio.h>'; echo '#include <string.h>'; echo 'typedef short BOOL;'; echo '#define TRUE 1'; echo '#define FALSE 0'
    sed -n '/^BOOL CopyStr(char \*dst, const char \*src, int dstSize)$/,/^}/p' "$GUI"
    sed -n '/^BOOL AppendStr(/,/^}/p;/^BOOL JoinPath(/,/^}/p;/^BOOL IsSafeFieldText(/,/^}/p' "$GUI"
    cat << 'CEOF'
int main(void){ char b[8]; char big[64]; int bad=0;
  if (!CopyStr(b,"abc",sizeof b) || strcmp(b,"abc")) bad++;
  if (CopyStr(b,"abcdefghij",sizeof b) || strlen(b)!=7) bad++;
  strcpy(b,"ab"); if (AppendStr(b,"cdefghij",sizeof b) || strlen(b)!=7) bad++;
  if (!JoinPath("DH0:","G",big,sizeof big) || strcmp(big,"DH0:G")) bad++;
  if (JoinPath("DH0:a/long/path/here","Name",b,sizeof b)) bad++;
  if (!IsSafeFieldText("Work:WHDLoad/Games") || IsSafeFieldText("a\"b") || IsSafeFieldText("$(x)") || IsSafeFieldText("a*b")) bad++;
  return bad; }
CEOF
  } > "$T/gui_helpers.c"
  if cc -std=c99 -o "$T/gui_helpers" "$T/gui_helpers.c" 2>"$T/gui_cc.log"; then
    check "its bounded string helpers never overrun and refuse unsafe text" '"$T/gui_helpers"'
  else
    check "its string helpers compile" 'false'
  fi
else
  echo "  (skipped the GUI helper run: no C compiler)"
fi

section "103. setup.sh fetches the artwork the chosen variants use, and only that"
check "the packs are derived from the variants, not copied from the example" \
  'grep -q "aga-laced) packs=\"\$packs AGA_Laced\"" "$ROOT/setup.sh"'


section "104. An archive cannot write outside the folder it is unpacked into"
echo "Evil" > "$MOCK/evil_pattern"
server_add WHDLoad/Games/E/EvilGame_v1.0.lha
run evil ./all.sh --variants aga; st=$?
rm -f "$MOCK/evil_pattern"
check "the hostile archive is refused, with the reason" \
  'grep -rq "REFUSED: it has entries that climb out" "$ROOT/logs" "$T/evil.log" 2>/dev/null'
check "nothing it tried to write exists anywhere" \
  '[ -z "$(find "$ROOT" "$T" -name "ESCAPED_*" 2>/dev/null | head -1)" ]'
check "no unpacking folders are left behind" \
  '[ -z "$(find "$ROOT" -name ".whdsync_x.*" 2>/dev/null | head -1)" ]'
check "the rest of the run still finished (it is one failed archive, not a stop)" \
  '[ "$st" -eq 0 ] || [ "$st" -eq 5 ]'
check "the game it carried is not in the collection" '[ -z "$(game retro_aga EvilGame)" ]'
check "an ordinary archive in the same run still installs" '[ -n "$(game retro_aga Alpha)" ]'

section "105. Installing an update never leaves a game half-copied"
check "games are swapped in by rename, not deleted and re-copied" \
  'sed -n "/^rp_replace_and_copy()/,/^}/p" "$ROOT/lib.sh" | grep -q "incoming" &&
   ! sed -n "/^rp_replace_and_copy()/,/^}/p" "$ROOT/lib.sh" | grep -q "cp -a \"\$src/.\" \"\$dest/\""'
RC="$T/rac"; rm -rf "$RC"
mkg() { mkdir -p "$1/WHDLoad/Games/$2/$3"; echo "$4" > "$1/WHDLoad/Games/$2/$3/game.slave"; echo i > "$1/WHDLoad/Games/$2/$3.info"; }
mkg "$RC/live" A Alpha old; echo x > "$RC/live/WHDLoad/Games/A/Alpha/oldonly"; mkg "$RC/live" B Beta keep
mkg "$RC/batch" A Alpha new; mkg "$RC/batch" G Gamma new
( cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; rp_replace_and_copy '$RC/batch' '$RC/live'" ) >/dev/null 2>&1; st=$?
check "an update installs the new version, whole" \
  '[ "$st" -eq 0 ] && [ "$(cat "$RC/live/WHDLoad/Games/A/Alpha/game.slave")" = new ] && [ ! -e "$RC/live/WHDLoad/Games/A/Alpha/oldonly" ]'
check "new and untouched games are as they should be" \
  '[ -f "$RC/live/WHDLoad/Games/G/Gamma/game.slave" ] && [ "$(cat "$RC/live/WHDLoad/Games/B/Beta/game.slave")" = keep ]'
check "the batch is left intact for new_<variant>" '[ "$(cat "$RC/batch/WHDLoad/Games/A/Alpha/game.slave")" = new ]'
# Interrupted between "old -> .previous" and "new -> live":
G="$RC/live/WHDLoad/Games/A"; mv "$G/Alpha" "$G/Alpha.previous.999991"
mkdir -p "$G/Alpha.incoming.999991"; echo half > "$G/Alpha.incoming.999991/game.slave"
mkdir -p "$RC/state/installing"; : > "$RC/state/installing/retro_x"
( cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; RP_STATE_DIR='$RC/state'; rp_recover_collection retro_x '$RC/live'" ) >/dev/null 2>&1
check "cut mid-swap: the next run puts the whole previous game back" '[ "$(cat "$G/Alpha/game.slave")" = new ]'
check "...and removes the half-copied one" '[ ! -e "$G/Alpha.incoming.999991" ]'
check "...and clears its marker" '[ ! -e "$RC/state/installing/retro_x" ]'
check "the marker is written before games are swapped in and removed after" \
  'grep -q "installing/\$key" "$ROOT/all.sh" && grep -q "rp_recover_collection" "$ROOT/all.sh"'

section "106. Locks: record removed before release, stale locks broken safely, reused PIDs seen"
check "the record is removed while the lock is still held" \
  'sed -n "/^rp_lock_release()/,/^}/p" "$ROOT/lib.sh" | awk "/rm -f \"\\\$RP_LOCK_FILE.info\"/{r=NR} /exec 9>&-/{c=NR} END{exit !(r && c && r < c)}"'
check "a stale mkdir lock is broken by an atomic rename, not rm-then-mkdir" \
  'sed -n "/^rp_lock_take()/,/^}/p" "$ROOT/lib.sh" | grep -q "mv \"\$RP_LOCK_FILE.d\" \"\$RP_LOCK_FILE.d.stale"'
sleep 300 & other=$!
check "a PID now running something else does not keep a lock alive" \
  '! ( cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; rp_lock_owner_alive $other \"all.sh --cron\"" )'
check "...but with nothing recorded about the command, it is assumed alive" \
  '( cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; rp_lock_owner_alive $other \"\"" )'
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
# Many runs at once on the mkdir fallback: exactly one may ever hold it.
LKT="$T/lockrace"; rm -rf "$LKT"; mkdir -p "$LKT"
for n in 1 2 3 4 5 6 7 8; do
  ( cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; RP_LOCK_FILE='$LKT/.all.lock'; rp_flock_bin() { return 1; };
      if rp_lock_take \"race $n\"; then echo held >> '$LKT/holders'; sleep 2; rp_lock_release; fi" ) >/dev/null 2>&1 &
done
wait
check "eight runs racing for the mkdir lock: exactly one got it" '[ "$(grep -c held "$LKT/holders" 2>/dev/null)" = 1 ]'
check "...and it left nothing behind" '[ ! -e "$LKT/.all.lock.d" ] && [ ! -e "$LKT/.all.lock.info" ]'

section "107. Artwork archives: precise checks, and nothing escapes while unpacking"
check "a name with two dots is not refused any more" '! grep -q "name .\*\.\.\*." "$ROOT/artwork_sync.sh"'
check "links are still refused" 'grep -q -- "-type l -o .( -type f -links +1" "$ROOT/artwork_sync.sh"'
check "packs are unpacked several levels deep and checked for escapes" \
  'grep -q "stage=\"\$MY_WORK/j/j/j/x\"" "$ROOT/artwork_sync.sh" && grep -q "climb out of the folder" "$ROOT/artwork_sync.sh"'
check "the existing backup is only replaced once the new one is in place" \
  'sed -n "/^rp_replace_tree()/,/^}/p" "$ROOT/lib.sh" | grep -q "bk_tmp=\"\$backup.incoming"'

section "108. The licence is MIT, everywhere it is stated"
check "LICENSE is MIT" 'head -1 "$REPO/LICENSE" | grep -q "^MIT License"'
check "no script or document claims another licence" \
  '! grep -rIl -i "creative commons\|BY.NC" "$REPO"/*.sh "$REPO"/*.md "$REPO"/*.c "$REPO"/*.py 2>/dev/null | grep -v CHANGELOG.md'
check "start.sh points at it" 'grep -q "^# License: MIT - see LICENSE" "$REPO/start.sh"'


section "109. The collection swap survives being cut at every point"
SW="$T/swap/build"; rm -rf "$T/swap"
sw() { ( cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; $*" ) >/dev/null 2>&1; }
# cut before the first rename: live untouched, staged build discarded
mkdir -p "$SW/retro_aga" "$SW/.new_retro_aga"; echo old > "$SW/retro_aga/f"; echo new > "$SW/.new_retro_aga/f"
sw "rp_recover_swap '$SW/retro_aga'"
check "cut before the swap: the collection is untouched" '[ "$(cat "$SW/retro_aga/f")" = old ] && [ ! -e "$SW/.new_retro_aga" ]'
# cut between the two renames: previous collection back
rm -rf "$SW"; mkdir -p "$SW/.previous_retro_aga" "$SW/.new_retro_aga"; echo old > "$SW/.previous_retro_aga/f"
sw "rp_recover_swap '$SW/retro_aga'"
check "cut between the renames: the previous collection is put back" '[ "$(cat "$SW/retro_aga/f")" = old ]'
# cut before the old one was deleted: new stays
rm -rf "$SW"; mkdir -p "$SW/retro_aga" "$SW/.previous_retro_aga"; echo new > "$SW/retro_aga/f"; echo old > "$SW/.previous_retro_aga/f"
sw "rp_recover_swap '$SW/retro_aga'"
check "cut after the swap: the new collection stays, the old is cleared" '[ "$(cat "$SW/retro_aga/f")" = new ] && [ ! -e "$SW/.previous_retro_aga" ]'
# and the swap itself
rm -rf "$SW"; mkdir -p "$SW/retro_aga" "$SW/.new_retro_aga"; echo old > "$SW/retro_aga/f"; echo new > "$SW/.new_retro_aga/f"
sw "rp_swap_collection '$SW/retro_aga'"
check "an ordinary swap leaves exactly the new collection" \
  '[ "$(cat "$SW/retro_aga/f")" = new ] && [ ! -e "$SW/.new_retro_aga" ] && [ ! -e "$SW/.previous_retro_aga" ]'
check "recovery runs for every collection before anything else" \
  '[ "$(grep -n "rp_recover_swap \"\${V_DEST" "$ROOT/all.sh" | cut -d: -f1)" -lt "$(grep -n "^# 2. Decide what each variant needs" "$ROOT/all.sh" | cut -d: -f1)" ]'

section "110. Build time is only reported for a build that began"
check "build_seconds needs the build to have started" 'grep -q "BUILD_TIMER_STARTED\" -eq 1 \] && stage_end build_seconds" "$ROOT/all.sh"'
run nothingnew ./all.sh --skip-update --variants aga; st=$?
if [ "$st" -eq 2 ]; then
  check "a nothing-to-do run has no build time in its report" '! grep -q "^  build " "$T/nothingnew.log"'
fi

section "111. Automatic job counts: one rule, the same numbers, testable"
aj() { ( cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; rp_auto_jobs $*" ) 2>/dev/null; }
check "Pi Zero 2 W (4 cores, 512 MB): one extraction at a time" '[ "$(aj extract 4 524288)" = 1 ]'
check "1 GB: at most two"                                      '[ "$(aj extract 4 1048576)" = 2 ]'
check "plenty of memory: one per core"                         '[ "$(aj extract 4 4194304)" = 4 ]'
check "never more than 8 extractions, whatever the cores"      '[ "$(aj extract 32 33554432)" = 8 ]'
check "sort: three quarters of the cores, at least 2"          '[ "$(aj sort 1 4194304)" = 2 ] && [ "$(aj sort 8 4194304)" = 6 ]'
check "sort: at most 4 under 768 MB"                           '[ "$(aj sort 16 524288)" = 4 ]'
check "never below 1, even with nothing to go on"              '[ "$(aj extract 0 0)" -ge 1 ]'
check "an explicit setting still wins over auto" \
  '[ "$(cd "$ROOT" && bash -c "SCRIPT_DIR=.; . ./lib.sh; RP_EXTRACT_JOBS=3; rp_jobs extract 1" 2>/dev/null)" = 3 ]'
check "extract.sh and sort.sh use the shared rule" \
  'grep -q "rp_auto_jobs extract" "$ROOT/extract.sh" && grep -q "rp_auto_jobs sort" "$ROOT/sort.sh"'

section "112. The support bundle hides by default, not by guessing names"
printf 'VARIANTS="aga"\nNTFY_TOPIC="t-9917"\nWEIRDLY_NAMED="s3cr3t-v4lue"\n' > "$T/sbconf.conf"
( cd "$ROOT" && cp retroplay.conf "$T/conf.save2" && cp "$T/sbconf.conf" retroplay.conf ) 
run sb2 ./start.sh --support-bundle
b2="$(ls -1 "$ROOT"/logs/whdsync-support-*.tar.gz 2>/dev/null | tail -1)"
rm -rf "$T/sb2x"; mkdir -p "$T/sb2x"; [ -n "$b2" ] && tar -xzf "$b2" -C "$T/sb2x"
check "a setting it does not know is hidden even with an innocent name" '! grep -rq "s3cr3t-v4lue" "$T/sb2x"'
check "settings that say nothing private are still shown" 'grep -q "^VARIANTS=\"aga\"" "$T"/sb2x/*/retroplay.conf.txt'
cp "$T/conf.save2" "$ROOT/retroplay.conf"; rm -f "$ROOT"/logs/whdsync-support-*.tar.gz
printf '%s\n' "x?Token=abc123&p=1" "mail me@example.org" | ( cd "$ROOT" && bash -c 'SCRIPT_DIR=.; . ./lib.sh; RP_NTFY_TOPIC=""; rp_redact' ) > "$T/red.txt" 2>/dev/null
check "token=/key= style values are hidden anywhere" '! grep -q abc123 "$T/red.txt" && grep -q "Token=<hidden>" "$T/red.txt"'
check "e-mail addresses are hidden anywhere" '! grep -q "me@example.org" "$T/red.txt"'

section "113. The A314 GUI only sends options start.sh accepts"
for o in $(grep -o 'ADD(" --[a-z-]*' "$REPO/a314_retroplay_gui.c" | sed 's/ADD(" //' | sort -u); do
  check "start.sh accepts $o" "grep -qE -- '(^ *|\\|)$o(\\)|\\|)' \"\$ROOT/start.sh\""
done
check "the window fits itself to a small screen" 'grep -q "WA_AutoAdjust, TRUE" "$REPO/a314_retroplay_gui.c"'
check "Status and Check set-up never trigger the copy to the Amiga" \
  'grep -q "!IsChecked(GID_ACT_STATUS) && !IsChecked(GID_ACT_DOCTOR)" "$REPO/a314_retroplay_gui.c"'

section "114. The \"sort.sh stopped\" message is only shown when sort.sh stopped"
# macOS (bash 3.2) printed "ERROR: sort.sh stopped at line ..." once for every
# filename the check flagged, while the sort carried on and finished. bash 3.2
# runs the error trap inside a $(...) even when an `if` is testing it. The
# same thing happens on every bash when the status is collected by hand with
# errexit off, which is what this reproduces.
trap_harness "$T/failsort/quiet.sh"
cat >> "$T/failsort/quiet.sh" << 'EOF'
f() { echo "a problem with this name"; return 1; }
( set +e; r=$(f); st=$?; echo "worker saw $st" )
( set +e; f >/dev/null; echo "worker carried on" )
if r=$(f); then :; else echo "if saw $?"; fi
r=$(f) || true
echo "reached the end"
EOF
rm -rf "$T/failsort/logs"
( cd "$ROOT" && bash "$T/failsort/quiet.sh" ) > "$T/failsort/quiet.log" 2>&1; st=$?
check "a check that returns 'problem found' is not announced as a stop" \
  '[ "$st" -eq 0 ] && grep -q "reached the end" "$T/failsort/quiet.log" && ! grep -q "stopped at line" "$T/failsort/quiet.log"'
check "...the statuses still get through to the code that collects them" \
  'grep -q "worker saw 1" "$T/failsort/quiet.log" && grep -q "if saw 1" "$T/failsort/quiet.log"'
check "...and nothing is written to sort.log for retroerror.log to count" \
  '[ ! -s "$T/failsort/logs/sort.log" ]'
trap_harness "$T/failsort/bg.sh"
cat >> "$T/failsort/bg.sh" << 'EOF'
( ls /no/such/place/at/all >/dev/null 2>&1; echo "not reached" ) &
wait $! || true
echo "main carried on"
EOF
( cd "$ROOT" && bash "$T/failsort/bg.sh" ) > "$T/failsort/bg.log" 2>&1
check "a background step that really dies says so, and says it was a background step" \
  'grep -q "a background step of sort.sh stopped at line" "$T/failsort/bg.log" && ! grep -q "not reached" "$T/failsort/bg.log" && grep -q "main carried on" "$T/failsort/bg.log"'
check "the filename-check workers switch the trap off as well" \
  'sed -n "/compliance_progress_files+=/,/set +e/p" "$ROOT/sort.sh" | grep -q "trap - ERR"'
# The real thing: names that fail the check (one that can be fixed, one that
# cannot) go through sort.sh's parallel workers.
BN="$T/badnames"; mkdir -p "$BN/Games/A/Alpha"
: > "$BN/Games/A/Alpha.info"; : > "$BN/Games/A/Alpha/fine.txt"; : > "$BN/Games/A/Alpha/bad:name.txt"
: > "$BN/Games/A/Alpha/$(printf 'x%.0s' 1 2 3 4 5 6 7 8 9 10 11 12)$(printf 'y%.0s' $(seq 1 110)).dat"
( cd "$ROOT" && RP_CHILD=1 bash ./sort.sh --dest "$BN" --skip-variant-sort --called-from-all ) > "$T/badnames.log" 2>&1; st=$?
check "sort.sh finishes normally when names fail the check" \
  '[ "$st" -eq 0 ] && grep -q "Sort operation complete" "$T/badnames.log"'
check "...reporting them as a warning, with the count" \
  'grep -q "Found 1 filename(s) with Amiga compliance issues" "$T/badnames.log" && grep -q "Fixed 1 file(s)" "$T/badnames.log"'
check "...and never as an error that it stopped" \
  '! grep -q "stopped at line" "$T/badnames.log" && ! grep -q "stopped at line" "$ROOT/logs/sort.log" 2>/dev/null'
check "the list of names is still written for the user" \
  'grep -q "bad:name.txt" "$ROOT/logs/amiga_filename_issues.log"'
rm -f "$ROOT/logs/amiga_filename_issues.log" "$ROOT/logs/sort.log"

section "115. Small things from a real macOS run"
check "update.sh names its log once, not folder + full path" \
  'grep -q "^echo \"See \$logfile for details\"" "$ROOT/update.sh" && ! grep -q "logpath/\$logfile" "$ROOT/update.sh"'
check "...and what it prints is a file that exists" \
  'f="$(sed -n "s/^See \(.*\) for details$/\1/p" "$T"/*.log 2>/dev/null | tail -1)"; [ -n "$f" ] && [ "${f#/}" != "$f" ] && case "$f" in *//*) false ;; *) true ;; esac'
# The summary table: every row must put its numbers in the same columns,
# whatever the longest collection name is.
rep="$(ls -1 "$ROOT"/reports/*.txt 2>/dev/null | grep -v _no_artwork | tail -1)"
check "the run report has a collection table" '[ -n "$rep" ] && grep -q "^  Collection" "$rep"'
check "the table's name column is sized to the longest name" \
  'grep -q "namew=" "$ROOT/all.sh" && ! grep -q "%-14s %6s" "$ROOT/all.sh"'
printf 'retro_aga|5548|9817|0:02:46|Screens|built\nretro_aga_laced|5548|9842|0:03:01|Screens|built\n' > "$T/rows.txt"
sed -n '/^ *namew=/,/^                done$/p' "$ROOT/all.sh" > "$T/table.sh"
( VARIANT_ROWS="$(cat "$T/rows.txt")"; . "$T/table.sh" ) > "$T/table.txt" 2>&1
check "a 15-character name no longer pushes its row out of line" \
  '[ "$(awk "{ print index(\$0, \"5548\") }" "$T/table.txt" | grep -v "^0$" | sort -u | wc -l | tr -d " ")" = "1" ] && [ "$(grep -c 5548 "$T/table.txt")" = "2" ]'
check "the finished artwork bar is drawn once" \
  'grep -q "processed != total_targets" "$ROOT/merge.sh"'

section "116. The output-drive check goes by where the collections are, not only by a marker file"
# A Pi 400's nightly run refused with "missing its marker file ... probably
# not mounted" while the drive was mounted and full of collections.
USB2="$T/usb2"; setup mkdir -p "$USB2"
cp "$ROOT/retroplay.conf" "$T/conf.bak116"; echo "OUTPUT_ROOT=\"$USB2\"" >> "$ROOT/retroplay.conf"
run od1 ./all.sh --skip-update --variants aga; st=$?
check "set-up: a collection is built on the drive and the drive is marked" \
  '[ "$st" -eq 0 ] && [ -s "$USB2/.retroplay_output" ] && [ -d "$USB2/build/retro_aga/WHDLoad" ]'
mk1="$(cat "$USB2/.retroplay_output")"
# 1. The marker file is deleted (tidying up the drive); the collections are there.
rm -f "$USB2/.retroplay_output"
run od2 ./all.sh --skip-update --variants aga; st=$?
check "marker deleted, collections present: the run goes ahead" '[ "$st" -eq 0 ] || [ "$st" -eq 2 ]'
check "...the marker is put back as it was, and the run says so" \
  '[ "$(cat "$USB2/.retroplay_output" 2>/dev/null)" = "$mk1" ] && grep -q "marker file was missing" "$T/od2.log"'
# 2. Another copy of the scripts replaced the marker with its own (what
#    earlier versions did on their first run against a folder already in use).
echo "1700000000-999-1" > "$USB2/.retroplay_output"
run od3 ./all.sh --skip-update --variants aga; st=$?
check "marker replaced by another copy: the run goes ahead" '[ "$st" -eq 0 ] || [ "$st" -eq 2 ]'
check "...this copy takes up the marker that is there instead of fighting over it" \
  '[ "$(cat "$USB2/.retroplay_output")" = "1700000000-999-1" ] && grep -q "|1700000000-999-1$" "$ROOT/.retroplay/output_root_id" && grep -q "another copy of the scripts" "$T/od3.log"'
run od3b ./all.sh --skip-update --variants aga; st=$?
check "...and the next run is quiet about it" \
  '{ [ "$st" -eq 0 ] || [ "$st" -eq 2 ]; } && ! grep -q "output folder.s marker" "$T/od3b.log"'
# 3. A copy of the scripts using this folder for the first time must not
#    replace the marker - that is what locked the other copy out.
rm -f "$ROOT/.retroplay/output_root_id"
run od4 ./all.sh --skip-update --variants aga; st=$?
check "first use of a folder that already has a marker: the marker is kept" \
  '{ [ "$st" -eq 0 ] || [ "$st" -eq 2 ]; } && [ "$(cat "$USB2/.retroplay_output")" = "1700000000-999-1" ] && grep -q "|1700000000-999-1$" "$ROOT/.retroplay/output_root_id"'
# 4. Still refused when it really is not the drive: an empty mount point...
mv "$USB2" "$T/usb2_unplugged"; mkdir -p "$USB2"
run od5 ./all.sh --skip-update --variants aga; st=$?
check "empty mount point: still refused, nothing written to it" \
  '[ "$st" -eq 4 ] && [ -z "$(ls -A "$USB2")" ] && grep -q "not mounted" "$T/od5.log"'
check "...and the message says which filesystem that folder is really on" \
  'grep -q "^It is on .*, mounted at /" "$T/od5.log"'
check "...and no longer claims a marker is 'missing' when the folder is just empty" \
  'grep -q "has no marker file" "$T/od5.log" && grep -q "The folder is empty" "$T/od5.log"'
run od5d ./all.sh --skip-update --variants aga --dry-run; st=$?
check "a dry run refuses the empty mount point too, and writes nothing" '[ "$st" -eq 4 ] && [ -z "$(ls -A "$USB2")" ]'
# ...and a different drive mounted in its place (its own marker, none of our collections).
echo "1600000000-1-1" > "$USB2/.retroplay_output"; mkdir -p "$USB2/holiday_photos"
run od6 ./all.sh --skip-update --variants aga; st=$?
check "a different drive at the same mount point: refused, and described as that" \
  '[ "$st" -eq 4 ] && grep -q "from a different drive or a different copy" "$T/od6.log" && [ ! -e "$USB2/build" ] && [ "$(cat "$USB2/.retroplay_output")" = "1600000000-1-1" ]'
check "...with the way out spelled out" 'grep -q "delete .*output_root_id and run again" "$T/od6.log"'
rm -rf "$USB2"; mv "$T/usb2_unplugged" "$USB2"
# A first build that never finished has no build marker yet, but its folder
# is on the drive - that is still the drive.
mkdir -p "$T/complete.keep"; mv "$ROOT"/.retroplay/complete/* "$T/complete.keep/" 2>/dev/null
rm -f "$USB2/.retroplay_output"
run od6b ./all.sh --skip-update --variants aga --dry-run; st=$?
check "no finished build recorded, but retro_* is on the drive: accepted" \
  '[ "$st" -ne 4 ] && ! grep -q "has no marker file" "$T/od6b.log"'
check "...and a dry run still writes nothing" '[ ! -e "$USB2/.retroplay_output" ]'
mv "$T/complete.keep"/* "$ROOT/.retroplay/complete/" 2>/dev/null
echo "1700000000-999-1" > "$USB2/.retroplay_output"
# 5. A marker that is there but cannot be read (root reads any file, so a
#    folder stands in for "unreadable").
mv "$USB2/.retroplay_output" "$T/marker.keep"; mkdir "$USB2/.retroplay_output"
run od7 ./all.sh --skip-update --variants aga; st=$?
check "an unreadable marker is reported as a permissions problem, not as an unplugged drive" \
  '[ "$st" -eq 4 ] && grep -q "can.t be read by" "$T/od7.log" && ! grep -q "what a mount point looks like\|the drive is not mounted there" "$T/od7.log"'
rmdir "$USB2/.retroplay_output"; mv "$T/marker.keep" "$USB2/.retroplay_output"
run od8 ./all.sh --skip-update --variants aga; st=$?
check "drive back as it was: runs normally" '[ "$st" -eq 0 ] || [ "$st" -eq 2 ]'
run od9 ./start.sh --status
check "--status shows the output folder as available" 'grep -q "Output folder: $USB2" "$T/od9.log"'
cp "$T/conf.bak116" "$ROOT/retroplay.conf"

# ================================================================ summary ===
echo
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32mAll %d tests passed.\033[0m\n' "$PASS"
    exit 0
fi
printf '\033[31m%d of %d tests failed:\033[0m%s\n' "$FAIL" $((PASS + FAIL)) "$FAILED_NAMES"
echo "Re-run with -v to see each script's output."
exit 1
