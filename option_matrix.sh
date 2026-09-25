#!/usr/bin/env bash
# Exhaustive option test: runs every script with every option (and many
# combinations) in a throwaway copy with mock tools and a mock server, and
# fails on unexpected exit codes or on ANY shell-level error in the output.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/rp_matrix.XXXXXX")"; if [ -n "${MATRIX_KEEP:-}" ]; then trap 'echo "KEPT $T"' EXIT; else trap 'rm -rf "$T"' EXIT; fi
ROOT="$T/r"; SERVER="$T/server"; MOCK="$T/mock"; mkdir -p "$ROOT" "$SERVER" "$MOCK" "$T/tmp"
export TMPDIR="$T/tmp"
cp "$REPO"/*.sh "$REPO"/retroplay.conf.example "$ROOT"/; chmod +x "$ROOT"/*.sh
cat > "$MOCK/lha" << 'M'
#!/usr/bin/env bash
arc=""; for a in "$@"; do case "$a" in *.lha|*.lzx|*.zip) arc="$a";; esac; done
[ -n "$arc" ] || exit 0
# "lha t <archive>" = integrity test: fails only for archives marked CORRUPT
if [ "${1:-}" = "t" ]; then grep -q CORRUPT "$arc" 2>/dev/null && exit 1; exit 0; fi
stem="${arc##*/}"; stem="${stem%.*}"; IFS=_ read -r -a f <<< "$stem"; n=""
for t in "${f[@]}"; do case "$t" in v[0-9]*) ;; *) n="${n:+${n}_}$t";; esac; done
mkdir -p "$n"; echo x > "$n/$n.slave"; touch "$n.info"
M
for t in 7z unar unlzx; do cp "$MOCK/lha" "$MOCK/$t"; done
ROOT_P="$(cd "$ROOT" && pwd -P)"
cat > "$MOCK/wget" << M
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "--spider" ] && exit 0; done
rel="\$(pwd -P)"; rel="\${rel#$ROOT_P/}"; rel="\${rel#downloads/}"
[ -d "$SERVER/\$rel" ] || exit 0
log=""; prev=""; for a in "\$@"; do case "\$prev" in -a|-o) log="\$a";; esac; prev="\$a"; done
( cd "$SERVER/\$rel" && find . -type f ) | while IFS= read -r f; do f="\${f#./}"
  if [ ! -e "\$f" ] || ! cmp -s "$SERVER/\$rel/\$f" "\$f"; then mkdir -p "\$(dirname "\$f")"; cp "$SERVER/\$rel/\$f" "\$f"
  [ -n "\$log" ] && echo "x URL: ftp://mock/\$f [1] -> \"\$f\" [1]" >> "\$log"; fi; done
M
printf '#!/bin/sh\nexit 0\n' > "$MOCK/curl"
printf '#!/bin/sh\n[ "$1" = "-a" ] && printf "C.UTF-8\\nen_US.ISO-8859-1\\n"\nexit 0\n' > "$MOCK/locale"
printf '#!/bin/sh\n[ "$1" = "-V" ] && echo "detox 3.0.1"\nexit 0\n' > "$MOCK/detox"
printf '#!/usr/bin/env bash\ncase "$1" in -l) cat "%s/ct" 2>/dev/null;; -) cat > "%s/ct";; esac\n' "$T" "$T" > "$MOCK/crontab"
chmod +x "$MOCK"/*; mkdir -p "$T/thisbash"; ln -sf "$BASH" "$T/thisbash/bash"
export PATH="$T/thisbash:$MOCK:$PATH"
add() { mkdir -p "$SERVER/$(dirname "$1")"; echo a > "$SERVER/$1"; }
for a in WHDLoad/Games/A/Alpha_v1.0.lha WHDLoad/Games/Z/Zool_v1.0_AGA.lha WHDLoad/Games/G/Gamma_v1.0_De.lha \
         WHDLoad/Demos/D/Demo_v1.0.lha WHDLoad/Magazines/M/Mag_v1.0.lha HD_Loaders/Games/R/Rise_v1.1_CD32_HD.lha JST/Games/J/Jst_v1.0.lha; do add "$a"; done
for s in AGA ECS RTG AGA_Laced ECS_Laced CD32 art; do mkdir -p "$ROOT/artwork/iGame_$s/Covers/Games/A/Alpha"; echo "$s" > "$ROOT/artwork/iGame_$s/Covers/Games/A/Alpha/iGame.iff"; done
mkdir -p "$ROOT/artwork/TinyLauncher/Game"
( cd "$ROOT" && ./update.sh ) > /dev/null 2>&1    # get archives on disk once

N=0; BAD=0; BADLIST=""
ERRPAT='unbound variable|command not found|bad substitution|syntax error|integer expression expected|too many arguments|unary operator expected|binary operator expected|No such file or directory|ambiguous redirect|Permission denied|bad array subscript|invalid option|not a valid identifier|cannot create|division by 0'
# t <expected-exit-codes (e.g. 0|2)> <description> <command...>
t() {
    local want="$1" desc="$2"; shift 2
    N=$((N + 1))
    [ -n "${MATRIX_MAX:-}" ] && [ "$N" -gt "$MATRIX_MAX" ] && return 0
    local log="$T/log_$N"
    ( cd "$ROOT" && "$@" ) < /dev/null > "$log" 2>&1
    local st=$? problem=""
    case "|$want|" in *"|$st|"*) ;; *) problem="exit $st (wanted $want)";; esac
    local err; err="$(grep -E "$ERRPAT" "$log" | grep -vE 'Unknown option|ERROR:|Removed|not found yet' | head -2)"
    [ -n "$err" ] && problem="${problem:+$problem; }shell error: $err"
    if [ -n "$problem" ]; then
        BAD=$((BAD + 1)); BADLIST="$BADLIST
  [$N] $desc: $*
       -> $problem  (log: see below)"
        echo "---- [$N] $desc ----"; tail -8 "$log" | sed 's/^/      /'
    fi
}
# Portable timeout (macOS has no `timeout`): kill the command after N seconds.
with_timeout() {
    local secs="$1"; shift
    "$@" & local pid=$! n=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1; n=$((n + 1))
        if [ "$n" -ge "$secs" ]; then kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; fi
    done
    wait "$pid"
}
tt() { local want="$1" desc="$2"; shift 2; t "$want" "$desc" with_timeout 25 "$@"; }

# Run only some sections: MATRIX_SECTIONS="1 2" tests/option_matrix.sh
SECTIONS="${MATRIX_SECTIONS:-1 2 3 4 5 6}"
sec() { case " $SECTIONS " in *" $1 "*) return 0 ;; esac; return 1; }

if sec 1; then
echo "== help and unknown options"
for s in all.sh start.sh extract.sh merge.sh sort.sh update.sh quick.sh doctor.sh uninstall_deps.sh setup.sh artwork_sync.sh artwork_fetch.sh; do
    tt "0" "$s --help" ./"$s" --help
    tt "1|4" "$s unknown option" ./"$s" --no-such-option
done
tt "0" "start.sh -h" ./start.sh -h
fi
if sec 2; then
echo "== every option that needs a value, given WITHOUT one (must fail cleanly, not hang or crash)"
for o in --dest --set --variants --variant --art --demo-art; do tt "1|4" "all.sh $o (no value)" ./all.sh "$o"; done
for o in --dest --set --art --demo-art --report-missing; do tt "1|4" "start.sh $o (no value)" ./start.sh "$o"; done
for o in -d --dest --exclude-tags --only-tags; do tt "1|4" "extract.sh $o (no value)" ./extract.sh "$o"; done
for o in -d --dest --set --art --demo-art --report-missing; do tt "1|4" "merge.sh $o (no value)" ./merge.sh "$o"; done
for o in -d --dest; do tt "1|4" "sort.sh $o (no value)" ./sort.sh "$o"; done
for o in -d --dest --set --art --demo-art; do tt "1|4" "quick.sh $o (no value)" ./quick.sh "$o"; done
fi
if sec 3; then
echo "== all.sh: variants x modes"
tt "0" "all.sh first full build" ./all.sh
for v in "" --aga --ecs --rtg --aga-laced --ecs-laced "--set CD32" "--variants aga,ecs" "--aga --ecs"; do
  for m in "" --skip-update --force --dry-run "--dry-run --skip-update" "--skip-update --force"; do
    # shellcheck disable=SC2086
    tt "0|2" "all.sh $v $m" ./all.sh $v $m
  done
done
tt "0" "all.sh --rebuild --aga --ffs --detox --debug" ./all.sh --rebuild --aga --ffs --detox --debug
tt "0" "all.sh --clean --ecs --pfs --no-detox" ./all.sh --clean --ecs --pfs --no-detox
tt "0" "all.sh --rebuild --aga --dest custom_out" ./all.sh --rebuild --aga --dest custom_out
tt "1|4" "all.sh --dest with two variants" ./all.sh --aga --ecs --dest x
tt "0" "all.sh --rebuild --art/--demo-art" ./all.sh --rebuild --rtg --art Screens,Titles,Covers --demo-art Covers,Titles,Screens
tt "0|2" "all.sh --cron --skip-update" ./all.sh --cron --skip-update
tt "0" "all.sh --AGA --REBUILD (case)" ./all.sh --AGA --REBUILD
fi
if sec 4; then
echo "== start.sh actions and menu"
# --merge with no destination correctly reports a setup problem (4)
for a in --update --extract --merge --sort --quick; do tt "0|2|4" "start.sh $a" ./start.sh $a; done
for a in "--auto --aga" "--auto --ecs --skip-update" "--rebuild --rtg" "--auto --set CD32 --skip-update" "--merge --aga --only-missing" "--sort --ffs --skipchk" "--sort --skip-variant-sort" "--merge --ecs --report-missing miss.txt" "--extract --dest xout"; do
  # shellcheck disable=SC2086
  tt "0|2|4" "start.sh $a" ./start.sh $a
done
for c in 0 1 2 3 4 5 6 7 8 9 10; do tt "0|1|2|4" "start.sh menu choice $c" sh -c "printf '$c\n0\n' | ./start.sh"; done
tt "1|4" "start.sh menu invalid choice" sh -c "printf 'x\n' | ./start.sh"
tt "0" "start.sh --exit" ./start.sh --exit
tt "0" "start.sh --status" ./start.sh --status
tt "0|3|4" "start.sh --test-notify" ./start.sh --test-notify
tt "0" "all.sh --status" ./all.sh --status
tt "0|3|4" "all.sh --test-notify" ./all.sh --test-notify
tt "0" "setup.sh --dry-run --yes" ./setup.sh --dry-run --yes
tt "0|2|3" "artwork_sync.sh --status" ./artwork_sync.sh --status
tt "0|2|3" "artwork_sync.sh --plan" ./artwork_sync.sh --plan
tt "0|2|3" "artwork_sync.sh --plan --for aga" ./artwork_sync.sh --plan --for aga
tt "0|2|3" "artwork_sync.sh --plan --all-artwork" ./artwork_sync.sh --plan --all-artwork
tt "1|4" "artwork_sync.sh --for (no value)" ./artwork_sync.sh --sync --for
tt "0|2|3|5" "artwork_sync.sh --verify" ./artwork_sync.sh --verify
tt "0|2|3|5" "start.sh --artwork-status" ./start.sh --artwork-status
tt "0|2|3|5" "start.sh --artwork-verify" ./start.sh --artwork-verify
tt "1|4" "artwork_sync.sh --set (no value)" ./artwork_sync.sh --sync --set
tt "1|4" "artwork_sync.sh --rollback (no value)" ./artwork_sync.sh --rollback
tt "1|4" "artwork_fetch.sh --list (no value)" ./artwork_fetch.sh --list
tt "1|2|4" "artwork_fetch.sh with no options" ./artwork_fetch.sh
tt "0|2" "start.sh --plan" ./start.sh --plan
tt "0|2" "start.sh --sync --skip-update" ./start.sh --sync --skip-update
tt "0" "setup.sh --dry-run --no-cron" ./setup.sh --dry-run --no-cron
tt "0|1" "start.sh --doctor" ./start.sh --doctor
fi
if sec 5; then
echo "== wrappers"
for w in aga ecs rtg; do tt "0|2" "$w.sh" ./$w.sh; tt "0" "$w.sh --rebuild" ./$w.sh --rebuild; tt "0|2" "$w.sh --skip-update --force" ./$w.sh --skip-update --force; done
fi
if sec 6; then
echo "== leaf scripts directly"
tt "0" "extract.sh -u -d x1" ./extract.sh -u -d x1
tt "0" "extract.sh --exclude-tags AGA,CD32" ./extract.sh -u -d x2 --exclude-tags AGA,CD32
tt "0" "extract.sh --only-tags AGA --debug" ./extract.sh -u -d x3 --only-tags AGA --debug
for v in --aga --ecs --rtg --aga-laced --ecs-laced "--set CD32" "--set art" --custom; do
  # shellcheck disable=SC2086
  tt "0" "merge.sh $v" ./merge.sh $v -d x1 --art Covers,Screens,Titles
done
tt "0" "merge.sh --a314 --only-missing --debug" ./merge.sh --aga --a314 --only-missing --debug -d x1
for o in "" --ffs --pfs --skipchk --no-detox --skip-variant-sort --custom "--ffs --skipchk --skip-variant-sort"; do
  # shellcheck disable=SC2086
  tt "0" "sort.sh $o" ./sort.sh -d x1 $o
done
tt "0|2" "update.sh" ./update.sh
tt "0|2|3" "update.sh --dry-run" ./update.sh --dry-run
for q in --aga --ecs --rtg "--ecs-laced --no-detox" "--set CD32" "--aga --skip-update" "--aga -d qout"; do
  # shellcheck disable=SC2086
  tt "0|2" "quick.sh $q" ./quick.sh $q
done
tt "0|1" "doctor.sh" ./doctor.sh
tt "0" "install_cron.sh" ./install_cron.sh
tt "0" "uninstall_deps.sh --dry-run" ./uninstall_deps.sh --dry-run
tt "0" "uninstall_deps.sh --yes (nothing tracked)" ./uninstall_deps.sh --yes
fi

echo
if [ "$BAD" -eq 0 ]; then echo "Option matrix: all $N runs OK"; exit 0; fi
echo "Option matrix: $BAD of $N runs had problems:$BADLIST"; exit 1
