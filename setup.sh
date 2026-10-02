#!/usr/bin/env bash
# retroplay-suite: 2026.10.03.1   (every script in the set must carry the same stamp)
# Remember where the user ran this from, before any cd: retroplay.conf is
# looked for there first (see lib.sh).
RP_INVOKED_FROM="${RP_INVOKED_FROM:-$PWD}"; export RP_INVOKED_FROM
# Amiga Retroplay - one-step setup
#
# Installs everything the scripts need and sets them up, then runs doctor.sh.
# Safe to run again at any time: every step checks first and only does what's
# missing. Anything it installs is recorded, so uninstall_deps.sh can remove
# exactly that later (and never something you already had).
#
#   ./setup.sh              interactive: asks a few questions
#   ./setup.sh --yes        no questions: sensible defaults
#   ./setup.sh --dry-run    show what would be done, change nothing
#   --cron / --no-cron      install (or skip) the nightly 2am run without asking

set -u -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1
if [ ! -f "$SCRIPT_DIR/lib.sh" ]; then
    echo "ERROR: lib.sh is missing from $SCRIPT_DIR - download the complete set of scripts." >&2
    exit 4
fi
. "$SCRIPT_DIR/lib.sh"
rp_load_config
RP_ALLOW_TOOL_INSTALL=1; export RP_ALLOW_TOOL_INSTALL   # setup is where installing belongs
rp_banner "setup.sh"

ASSUME_YES=0; DRY=0; CRON_CHOICE=ask
for a in "$@"; do
    case "$a" in
        --yes|-y)  ASSUME_YES=1 ;;
        --dry-run) DRY=1 ;;
        --cron)    CRON_CHOICE=yes ;;
        --no-cron) CRON_CHOICE=no ;;
        --quiet|--verbose|--no-color|--no-colour|--color=*|--colour=*)
            rp_common_opt "$a" >/dev/null ;;
        -h|--help) sed -n '4,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $a (try --help)" >&2; exit 4 ;;
    esac
done

OS="${RP_SETUP_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
PROBLEMS=0
# Colours through lib.sh's one decision, so NO_COLOR, --color and "output is
# being redirected to a file" are honoured here exactly as everywhere else.
# These used to be raw escape sequences, which meant a piped setup log came
# out full of control characters.
step() { printf '\n%s== %s%s\n' "$RP_C_HEAD" "$*" "$RP_C_OFF"; }
ok()   { printf '  %s✓%s %s\n' "$RP_C_OK" "$RP_C_OFF" "$*"; }
note() { printf '  %s!%s %s\n' "$RP_C_WARN" "$RP_C_OFF" "$*"; }
bad()  { PROBLEMS=$((PROBLEMS + 1)); printf '  %s✗%s %s\n' "$RP_C_ERR" "$RP_C_OFF" "$*"; }
run()  { echo "  + $*"; [ "$DRY" -eq 1 ] || "$@"; }
# ask <question> <default> -> answer (the default when --yes or unattended)
ask() {
    local reply
    if [ "$ASSUME_YES" -eq 1 ] || [ "$DRY" -eq 1 ] || ! [ -t 0 ]; then printf '%s' "$2"; return; fi
    printf '  %s [%s]: ' "$1" "$2" >&2
    read -r reply
    printf '%s' "${reply:-$2}"
}
yes_to() { case "$(ask "$1 (y/n)" "$2")" in [Yy]*) return 0 ;; *) return 1 ;; esac; }

# An interrupted setup leaves half-written settings behind. Starting again
# should start clean: anything THIS script wrote (the config it created, the
# nightly job it added, its own state) is undone first. Tools already
# installed are left alone - removing those is uninstall_deps.sh's job.
SETUP_STATE="$RP_BASE_DIR/.retroplay_setup_state"
if [ -f "$SETUP_STATE" ] && [ "$DRY" -eq 0 ]; then
    # the file lists what was done, one per line, ending with "complete"
    if ! grep -qx 'complete' "$SETUP_STATE" 2>/dev/null; then
        echo "A previous setup didn't finish. Clearing what it wrote and starting again."
        grep -q '^wrote_conf$' "$SETUP_STATE" 2>/dev/null && rm -f "$RP_CONF_FILE" && echo "  removed the part-written retroplay.conf"
        grep -q '^wrote_cron$' "$SETUP_STATE" 2>/dev/null && { ./install_cron.sh --disable --yes >/dev/null 2>&1; echo "  removed the nightly job it had added"; }
        rm -f "$SETUP_STATE"
    fi
fi
[ "$DRY" -eq 1 ] || { mkdir -p "$(dirname "$SETUP_STATE")" 2>/dev/null; : > "$SETUP_STATE"; }
setup_note() { [ "$DRY" -eq 1 ] || printf '%s\n' "$1" >> "$SETUP_STATE"; }

echo "Amiga Retroplay setup - $SCRIPT_DIR"
[ "$DRY" -eq 1 ] && echo "(dry run: nothing will be changed)"

# ---------------------------------------------------------------- 1. packages
step "1. Package manager"
PM=""
if [ "$OS" = "darwin" ]; then
    if command -v brew >/dev/null 2>&1; then PM=brew; ok "Homebrew"
    else
        bad "Homebrew is needed on macOS. Install it from https://brew.sh (one command), then run ./setup.sh again."
        exit 4
    fi
elif command -v apt-get >/dev/null 2>&1; then PM=apt; ok "apt"
else
    note "no apt-get or brew found - tools must be installed by hand (see README); continuing with the other steps"
fi

# ------------------------------------------------------------------- 2. tools
step "2. Tools"
# command | apt package | brew package
TOOLS="wget|wget|wget
lha|lhasa|lha
7z|p7zip-full|p7zip
unar|unar|unar
unzip|unzip|unzip
curl|curl|curl
flock|util-linux|util-linux"
want_pkgs=""
while IFS='|' read -r cmd apt brew; do
    [ -n "$cmd" ] || continue
    if command -v "$cmd" >/dev/null 2>&1; then ok "$cmd"; continue; fi
    if [ "$cmd" = "flock" ] && [ "$PM" = "brew" ]; then
        p="$(brew --prefix util-linux 2>/dev/null)"
        [ -n "$p" ] && [ -x "$p/bin/flock" ] && { ok "flock (Homebrew util-linux)"; continue; }
    fi
    if [ "$PM" = "apt" ]; then pkg="$apt"; else pkg="$brew"; fi
    note "$cmd is missing - will install '$pkg'"
    want_pkgs="$want_pkgs $pkg"
done <<< "$TOOLS"
if [ "$PM" = "brew" ]; then
    bash4=""
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        [ -x "$b" ] && "$b" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null && bash4="$b"
    done
    if [ -n "$bash4" ]; then ok "bash 4+ for merge.sh ($bash4)"; else note "bash 4+ is missing (merge.sh needs it) - will install 'bash'"; want_pkgs="$want_pkgs bash"; fi
fi

install_pkgs() {   # installs the missing packages; records only ones that weren't installed before
    local p pre=""
    [ -n "$want_pkgs" ] || return 0
    for p in $want_pkgs; do pkg_already_installed "$PM" "$p" && pre="$pre $p"; done
    if [ "$PM" = "apt" ]; then
        # A fresh Pi runs packagekitd / unattended-upgrades in the background,
        # which holds the dpkg lock for the first few minutes. Waiting for it
        # is right; failing with "Could not get lock" is not. apt can wait by
        # itself (DPkg::Lock::Timeout), and older apt gets a manual wait.
        local waited=0
        while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
            [ "$waited" -eq 0 ] && note "another package manager is busy (usually the Pi's own updater) - waiting up to 5 minutes"
            [ "$waited" -ge 300 ] && { bad "the package lock is still held after 5 minutes. Try again shortly, or: sudo systemctl stop packagekit"; return 1; }
            sleep 10; waited=$((waited + 10))
            printf '  ...waiting (%ds)\r' "$waited"
        done
        [ "$waited" -gt 0 ] && echo "  the lock is free now, carrying on            "
        run sudo apt-get -o DPkg::Lock::Timeout=300 update -qq \
            && run sudo apt-get -o DPkg::Lock::Timeout=300 install -y $want_pkgs || return 1
    elif [ "$PM" = "brew" ]; then
        run brew install $want_pkgs || return 1
    else
        return 1
    fi
    [ "$DRY" -eq 1 ] && return 0
    for p in $want_pkgs; do
        case " $pre " in *" $p "*) ;; *) record_installed_dep "$PM" "$p" ;; esac
    done
}
if [ -n "$want_pkgs" ]; then
    if [ -z "$PM" ]; then bad "please install:$want_pkgs"
    elif install_pkgs; then ok "installed:$want_pkgs"
    else bad "installing$want_pkgs failed - see the messages above"; fi
fi

# ------------------------------------------------------------------ 3. unlzx
step "3. unlzx (for .lzx archives - built from source)"
# The C source directly - no archive to unpack, so lha is not needed here.
UNLZX_URLS="${RP_UNLZX_URL:-http://aminet.net/misc/unix/unlzx.c.gz https://raw.githubusercontent.com/nhoudelot/unlzx/master/unlzx.c}"
# unlzx.c is 1990s C. It calls mkdir(), getopt(), exit() and friends without
# including the headers that declare them, which older compilers allowed with
# a warning. GCC 14 and clang 16 turn an implicit declaration into an ERROR,
# so a plain build fails on a current Raspberry Pi OS or Xcode:
#     error: implicit declaration of function 'mkdir'
#     error: implicit declaration of function 'getopt'
# Adding the missing headers ahead of the source fixes it properly; the
# permissive compiler flags below are only a fallback for anything else the
# old source trips over. The unpatched source is tried last, so a copy that
# already has its includes can never be made worse by the prelude.
build_unlzx() {   # <compiler> <source file> <temp dir>; leaves <temp dir>/unlzx
    local cc="$1" src="$2" tmp="$3" patched="$3/unlzx_patched.c" log="$3/build.log" f added=0
    if ! grep -q '<sys/stat.h>' "$src" 2>/dev/null || ! grep -q '<unistd.h>' "$src" 2>/dev/null; then added=1; fi
    {
        # Declarations the original source relies on but never includes.
        printf '%s\n' \
            '#include <sys/types.h>' \
            '#include <sys/stat.h>' \
            '#include <unistd.h>' \
            '#include <stdio.h>' \
            '#include <stdlib.h>' \
            '#include <string.h>' \
            '#include <time.h>'
        cat "$src"
    } > "$patched" 2>/dev/null || patched="$src"

    : > "$log"
    for f in "$patched::-O2 -w" \
             "$patched::-O2 -w -std=gnu89" \
             "$patched::-O2 -w -fpermissive" \
             "$patched::-O2 -w -Wno-implicit-function-declaration -Wno-implicit-int -Wno-int-conversion -Wno-incompatible-pointer-types" \
             "$src::-O2 -w" \
             "$src::-O2 -w -std=gnu89"; do
        local file="${f%%::*}" flags="${f#*::}"
        [ -f "$file" ] || continue
        rm -f "$tmp/unlzx"
        # shellcheck disable=SC2086
        if "$cc" $flags -o "$tmp/unlzx" "$file" >>"$log" 2>&1 && [ -x "$tmp/unlzx" ]; then
            if [ "$file" != "$src" ] && [ "$added" -eq 1 ]; then
                note "  added the C headers the old unlzx source leaves out (mkdir, getopt)"
            fi
            return 0
        fi
    done
    bad "compiling unlzx failed"
    note "  the compiler said:"
    sed -n '1,12p' "$log" 2>/dev/null | sed 's/^/      /'
    note "  .lzx archives will be skipped until unlzx is installed; everything else works."
    return 1
}

install_unlzx() {
    local cc="" url out tmp src dest_dir
    for c in cc gcc clang; do command -v "$c" >/dev/null 2>&1 && { cc="$c"; break; }; done
    if [ -z "$cc" ]; then
        if [ "$PM" = "apt" ]; then
            pkg_already_installed apt gcc || { run sudo apt-get install -y gcc || return 1; [ "$DRY" -eq 1 ] || record_installed_dep apt gcc; }
            cc=gcc
        else
            bad "a C compiler is needed to build unlzx. On macOS run:  xcode-select --install   then ./setup.sh again"
            return 1
        fi
    fi
    [ "$DRY" -eq 1 ] && { echo "  + download the unlzx source, compile it with $cc, install it"; return 0; }
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/unlzx_build.XXXXXX")" || return 1
    src=""
    for url in $UNLZX_URLS; do
        case "$url" in
            *.gz)  out="$tmp/unlzx.c.gz" ;;
            *.lha) out="$tmp/unlzx.lha" ;;
            *)     out="$tmp/unlzx.c" ;;
        esac
        rp_fetch "$url" "$out" 2>/dev/null || continue
        [ -s "$out" ] || continue
        case "$out" in
            *.gz)  gunzip -f "$out" 2>/dev/null && src="$tmp/unlzx.c" ;;
            *.lha) ( cd "$tmp" && lha x unlzx.lha >/dev/null 2>&1 ); src="$(find "$tmp" -name 'unlzx.c' | head -1)" ;;
            *)     src="$out" ;;
        esac
        # make sure it really is the source and not an error page
        if [ -n "$src" ] && [ -s "$src" ] && grep -qi 'unlzx\|lzx' "$src" 2>/dev/null; then break; fi
        src=""
    done
    if [ -z "$src" ]; then
        rm -rf "$tmp"
        bad "couldn't download the unlzx source. Tried:$(printf '\n      %s' $UNLZX_URLS)"
        note "  .lzx archives will be skipped until unlzx is installed; everything else works."
        return 1
    fi
    build_unlzx "$cc" "$src" "$tmp" || { rm -rf "$tmp"; return 1; }
    if [ -n "${RP_INSTALL_BIN:-}" ]; then dest_dir="$RP_INSTALL_BIN"
    elif [ "$PM" = "brew" ] && [ -w "$(brew --prefix)/bin" ]; then dest_dir="$(brew --prefix)/bin"
    else dest_dir="/usr/local/bin"; fi
    if [ -e "$dest_dir/unlzx" ]; then rm -rf "$tmp"; note "$dest_dir/unlzx already exists - left alone"; return 0; fi
    if [ -w "$dest_dir" ]; then mkdir -p "$dest_dir" && cp "$tmp/unlzx" "$dest_dir/unlzx"
    else sudo mkdir -p "$dest_dir" && sudo cp "$tmp/unlzx" "$dest_dir/unlzx"; fi || { rm -rf "$tmp"; bad "installing unlzx to $dest_dir failed"; return 1; }
    rm -rf "$tmp"
    record_installed_dep source-build "$dest_dir/unlzx"
    ok "unlzx built and installed to $dest_dir"
}
if command -v unlzx >/dev/null 2>&1; then ok "unlzx"; else install_unlzx; fi

# ---------------------------------------------------------------- 4. locales
if [ "$OS" != "darwin" ]; then
    step "4. Locales"
    have="$(locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '-')"
    LG="${RP_LOCALE_GEN_FILE:-/etc/locale.gen}"
    need=""
    printf '%s\n' "$have" | grep -qx 'c.utf8'         || need="$need|C.UTF-8 UTF-8"
    printf '%s\n' "$have" | grep -qx 'en_us.iso88591' || need="$need|en_US ISO-8859-1"
    if [ -z "$need" ]; then ok "C.UTF-8 and en_US.ISO-8859-1"
    elif [ ! -f "$LG" ]; then bad "missing locales (${need#|}) and no $LG here - generate them with your system's locale tool"
    else
        IFS='|' read -r -a entries <<< "${need#|}"
        for e in "${entries[@]}"; do
            if grep -qx "# *$e" "$LG"; then run sudo sed -i.bak "s/^# *$e\$/$e/" "$LG" && run sudo rm -f "$LG.bak"
            elif ! grep -qx "$e" "$LG"; then echo "  + add '$e' to $LG"; [ "$DRY" -eq 1 ] || printf '%s\n' "$e" | sudo tee -a "$LG" >/dev/null; fi
        done
        if run sudo "${RP_LOCALE_GEN_CMD:-locale-gen}" >/dev/null; then ok "generated:${need//|/, }"
        else bad "locale-gen failed - see the messages above"; fi
    fi
fi

# ----------------------------------------------------------------- 5. config
step "5. Settings (retroplay.conf)"
if [ -f "$RP_CONF_FILE" ]; then ok "retroplay.conf already exists - left as it is"
else
    # The default matches what all.sh builds with no settings at all. Each
    # variant is a full collection of its own, so say what that costs before
    # asking - on an SD card or a Pi Zero, three is the sensible start, and
    # the laced ones can be added to VARIANTS later without redoing anything.
    note "Each variant is a complete collection: five of them take about five times the"
    note "space and merge time of one. On a small card, answer: aga ecs rtg"
    variants="$(ask "Which variants to build (aga ecs rtg aga-laced ecs-laced)" "aga ecs rtg aga-laced ecs-laced")"
    # Fetch the artwork packs the chosen variants use, and only those: a
    # laced collection built without its pack comes out identical to the
    # plain one, and a pack nobody builds from is a wasted download.
    packs=""
    for _v in $variants; do
        case "$(printf '%s' "$_v" | tr '[:upper:]' '[:lower:]')" in
            aga) packs="$packs AGA" ;;  ecs) packs="$packs ECS" ;;  rtg) packs="$packs RTG" ;;
            aga-laced) packs="$packs AGA_Laced" ;;  ecs-laced) packs="$packs ECS_Laced" ;;
        esac
    done
    packs="${packs# }"; unset _v
    out="$(ask "Where should the collection go (a folder, e.g. a USB drive; '.' = here)" ".")"
    if [ "$out" != "." ] && [ ! -d "$out" ]; then
        note "$out doesn't exist - using this folder for now (change OUTPUT_ROOT in retroplay.conf later)"
        out="."
    fi
    topic="$(ask "ntfy topic for failure notifications (blank = none)" "")"
    if [ "$DRY" -eq 1 ]; then echo "  + write retroplay.conf (VARIANTS=\"$variants\", ARTWORK_PACKS=\"$packs\", OUTPUT_ROOT=\"$out\")"
    else
        awk -v v="$variants" -v o="$out" -v t="$topic" -v p="$packs" '
            /^VARIANTS=/    { print "VARIANTS=\"" v "\""; next }
            /^ARTWORK_PACKS=/ { if (p != "") { print "ARTWORK_PACKS=\"" p "\""; next } }
            /^OUTPUT_ROOT=/ { print "OUTPUT_ROOT=\"" o "\""; next }
            /^NTFY_TOPIC=/  { print "NTFY_TOPIC=\"" t "\""; next }
            { print }' "$SCRIPT_DIR/retroplay.conf.example" > "$RP_CONF_FILE" \
            && { setup_note wrote_conf; ok "created retroplay.conf (variants: $variants; output: $out)"; }
    fi
fi

# ---------------------------------------------------------------- 6. artwork
step "6. Artwork packs"
if [ -x "$SCRIPT_DIR/artwork_sync.sh" ]; then
    _have=0
    for _v in $RP_ARTWORK_PACKS; do [ -d "$RP_ARTWORK_ROOT/iGame_$(printf '%s' "$_v" | tr '[:lower:]' '[:upper:]')" ] && _have=1; done
    if [ "$_have" -eq 1 ]; then ok "artwork already present in ${RP_ARTWORK_ROOT##*/}/"
    elif [ "$DRY" -eq 1 ]; then echo "  + ./artwork_sync.sh --sync --all-artwork"
    elif yes_to "Download the artwork packs now (a few hundred MB)?" "y"; then
        if ./artwork_sync.sh --sync --all-artwork --yes; then ok "artwork installed"
        else note "artwork could not be downloaded now - try later: ./start.sh --artwork-sync"; fi
    else
        ok "skipped - fetch it any time with ./start.sh --artwork-sync"
    fi
fi

# ---------------------------------------------------------------- 7. nightly
step "7. Nightly update"
if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "retroplay-all-sh"; then
    ok "nightly run already installed"
    # refresh it so it remembers this terminal's PATH and uses --cron
    [ "$DRY" -eq 1 ] || ./install_cron.sh > /dev/null 2>&1
else
    case "$CRON_CHOICE" in
        yes) do_cron=1 ;;
        no)  do_cron=0 ;;
        *)   if [ "$ASSUME_YES" -eq 1 ]; then do_cron=0; elif yes_to "Update automatically every night at 2am?" "y"; then do_cron=1; else do_cron=0; fi ;;
    esac
    if [ "$do_cron" -eq 1 ]; then
        if [ "$DRY" -eq 1 ]; then echo "  + ./install_cron.sh"
        elif ./install_cron.sh > /dev/null 2>&1; then setup_note wrote_cron; ok "nightly run installed (2am)"
        else bad "installing the nightly run failed - try ./install_cron.sh"; fi
    else
        ok "skipped (run ./install_cron.sh any time)"
    fi
fi

# ----------------------------------------------------------------- 7. check
# ------------------------------------------------------- 8. tidy the folder
# Only offered on a first run in a folder that holds nothing but the scripts.
TIDY_INTO_SCRIPTS=0
# Only when someone is there to answer: moving the scripts changes the
# layout, so it is never done unattended (--yes, cron, a script calling this).
if [ "$DRY" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ] && rp_is_interactive && [ "${SCRIPT_DIR##*/}" != "scripts" ]; then
    others=0
    for d in "$SCRIPT_DIR"/*/; do [ -d "$d" ] && others=$((others + 1)); done
    if [ "$others" -eq 0 ]; then
        step "8. Tidying up"
        if yes_to "Move the scripts into a scripts/ folder to keep this folder tidy?" "y"; then
            TIDY_INTO_SCRIPTS=1
            ok "will do that at the end (artwork/, build/, downloads/ stay here)"
        else
            ok "leaving the scripts where they are"
        fi
    fi
fi

step "9. Checking everything"
if [ "$DRY" -eq 1 ]; then echo "  + ./doctor.sh"; exit 0; fi
./doctor.sh; dst=$?
echo
finish_setup() {
    setup_note complete
    if [ "$TIDY_INTO_SCRIPTS" -eq 1 ]; then
        mkdir -p "$SCRIPT_DIR/scripts" || return 0
        for f in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/to_ilbm.py; do
            [ -f "$f" ] || continue
            mv "$f" "$SCRIPT_DIR/scripts/" 2>/dev/null
        done
        [ -d "$SCRIPT_DIR/tests" ] && mv "$SCRIPT_DIR/tests" "$SCRIPT_DIR/scripts/" 2>/dev/null
        echo
        echo "The scripts are now in: $SCRIPT_DIR/scripts"
        echo "Everything else (artwork/, build/, downloads/, logs/, retroplay.conf) stays in $SCRIPT_DIR."
        echo
        echo "Next:  cd \"$SCRIPT_DIR/scripts\" && ./all.sh"
    else
        echo "Next:  ./all.sh        (the first run downloads and builds everything)"
    fi
    echo "       ./start.sh --status   shows where things stand at any time"
}

if [ "$PROBLEMS" -eq 0 ] && [ "$dst" -eq 0 ]; then
    echo "Setup complete."
    finish_setup
    exit 0
fi
echo "Setup finished with problems - see above. Fix them and run ./setup.sh again (it's safe to repeat)."
finish_setup
exit 4
