#!/usr/bin/env bash
# retroplay-suite: 2026.09.22   (every script in the set must carry the same stamp)
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

ASSUME_YES=0; DRY=0; CRON_CHOICE=ask
for a in "$@"; do
    case "$a" in
        --yes|-y)  ASSUME_YES=1 ;;
        --dry-run) DRY=1 ;;
        --cron)    CRON_CHOICE=yes ;;
        --no-cron) CRON_CHOICE=no ;;
        -h|--help) sed -n '4,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $a (try --help)" >&2; exit 4 ;;
    esac
done

OS="${RP_SETUP_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
PROBLEMS=0
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
note() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { PROBLEMS=$((PROBLEMS + 1)); printf '  \033[31m✗\033[0m %s\n' "$*"; }
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
        run sudo apt-get update -qq && run sudo apt-get install -y $want_pkgs || return 1
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
UNLZX_URLS="${RP_UNLZX_URL:-https://aminet.net/util/arc/unlzx.lha http://aminet.net/util/arc/unlzx.lha}"
install_unlzx() {
    local cc="" url tmp src dest_dir
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
    command -v lha >/dev/null 2>&1 || { bad "lha is needed to unpack the unlzx source"; return 1; }
    [ "$DRY" -eq 1 ] && { echo "  + download unlzx.lha from Aminet, compile with $cc, install it"; return 0; }
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/unlzx_build.XXXXXX")" || return 1
    for url in $UNLZX_URLS; do
        if command -v curl >/dev/null 2>&1; then curl -fsSL -m 120 -o "$tmp/unlzx.lha" "$url" && break
        else wget -q -T 120 -O "$tmp/unlzx.lha" "$url" && break; fi
    done
    [ -s "$tmp/unlzx.lha" ] || { rm -rf "$tmp"; bad "couldn't download unlzx from Aminet (network?)"; return 1; }
    ( cd "$tmp" && lha x unlzx.lha >/dev/null 2>&1 )
    src="$(find "$tmp" -name 'unlzx.c' | head -1)"
    [ -n "$src" ] || { rm -rf "$tmp"; bad "the downloaded unlzx archive has no unlzx.c"; return 1; }
    "$cc" -O2 -w -o "$tmp/unlzx" "$src" || { rm -rf "$tmp"; bad "compiling unlzx failed"; return 1; }
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
    variants="$(ask "Which variants to build (aga ecs rtg aga-laced ecs-laced)" "aga ecs rtg")"
    out="$(ask "Where should the collection go (a folder, e.g. a USB drive; '.' = here)" ".")"
    if [ "$out" != "." ] && [ ! -d "$out" ]; then
        note "$out doesn't exist - using this folder for now (change OUTPUT_ROOT in retroplay.conf later)"
        out="."
    fi
    topic="$(ask "ntfy topic for failure notifications (blank = none)" "")"
    if [ "$DRY" -eq 1 ]; then echo "  + write retroplay.conf (VARIANTS=\"$variants\", OUTPUT_ROOT=\"$out\")"
    else
        awk -v v="$variants" -v o="$out" -v t="$topic" '
            /^VARIANTS=/    { print "VARIANTS=\"" v "\""; next }
            /^OUTPUT_ROOT=/ { print "OUTPUT_ROOT=\"" o "\""; next }
            /^NTFY_TOPIC=/  { print "NTFY_TOPIC=\"" t "\""; next }
            { print }' "$SCRIPT_DIR/retroplay.conf.example" > "$RP_CONF_FILE" \
            && ok "created retroplay.conf (variants: $variants; output: $out)"
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
step "6. Nightly update"
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
        elif ./install_cron.sh > /dev/null 2>&1; then ok "nightly run installed (2am)"
        else bad "installing the nightly run failed - try ./install_cron.sh"; fi
    else
        ok "skipped (run ./install_cron.sh any time)"
    fi
fi

# ----------------------------------------------------------------- 7. check
step "8. Checking everything"
if [ "$DRY" -eq 1 ]; then echo "  + ./doctor.sh"; exit 0; fi
./doctor.sh; dst=$?
echo
if [ "$PROBLEMS" -eq 0 ] && [ "$dst" -eq 0 ]; then
    echo "Setup complete. Next: ./all.sh  (the first run downloads and builds everything)"
    exit 0
fi
echo "Setup finished with problems - see above. Fix them and run ./setup.sh again (it's safe to repeat)."
exit 4
