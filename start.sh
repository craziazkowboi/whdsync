#!/usr/bin/env bash
# retroplay-suite: 2026.09.22   (every script in the set must carry the same stamp)

# Amiga Retroplay Archive Minimal CLI Dispatcher
# Copyright (c) 2025 Craziazkowboi
# License: Creative Commons BY‑NC 4.0 International
#
# WHAT THIS SCRIPT DOES:
#   The main entry point for the whole toolkit - a single command line (or
#   interactive menu, if run with no options) that runs whichever of
#   update.sh / extract.sh / merge.sh / sort.sh / quick.sh you need,
#   forwarding the right options to each. --auto runs all four of the
#   first scripts in sequence (a full collection refresh); the other
#   single-word actions (--update/--extract/--merge/--sort/--quick) run
#   just one step, for when you only need to redo part of the pipeline.
#
#   Every option this script accepts is really just collected here and
#   then handed off to the relevant sub-script - see build_merge_args,
#   build_sort_args, build_extract_args and build_quick_args further down
#   for exactly which options go where.

script_start_time=$(date +%s)

# Resolve to this script's own directory and work from there, regardless of
# where the caller's shell happened to be (previously this used bare "./x.sh"
# calls that only worked if you'd already cd'ed into the scripts' folder).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared helpers (retroplay.conf settings, dependency tracking, pending
# queues, disk-space checks...) live in lib.sh, next to this script.
if [ ! -f "$SCRIPT_DIR/lib.sh" ]; then
    echo "ERROR: lib.sh is missing from $SCRIPT_DIR - it ships with these scripts." >&2
    exit 1
fi
. "$SCRIPT_DIR/lib.sh"
rp_load_config
cd "$SCRIPT_DIR" || { echo "ERROR: cannot cd to script directory: $SCRIPT_DIR" >&2; exit 1; }
NEW_DIR="${SCRIPT_DIR}/new"

ulimit -n 16384

# DO NOT set -e here - we need to parse options first
set -uo pipefail

version="1.2.4 macOS 10.15.7 Compatible (no color)"

ACTION=""
MERGE_OPT=""
SET_OPT=""
SORT_OPT=""
DEST_OPT=""
ART_ORDER_OPT=""
DEMO_ART_OPT=""
MENU_DEST_OVERRIDE=""
DEBUG_MODE=0
NO_DETOX=0
SKIPCHK_OPT=0
SKIP_VARIANT_SORT_OPT=0
ONLY_MISSING_OPT=0
SKIP_UPDATE=0
CLEAN_OPT=0
REBUILD_OPT=0        # --rebuild: rebuild from downloaded archives, no update check
FORCE_OPT=0          # --force: also run the artwork gap-fill on up-to-date variants
REPORT_MISSING_OPT=""  # --report-missing FILE (passed to merge.sh)
DETOX_EXPLICIT=""    # "yes"/"no" when --detox/--no-detox was given
DELEGATED_AUTO=0
AUTO_EXIT=0
NOTHING_NEW_FALLBACK=0

# Basic environment / colors (no color for now)
OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"
RED=""
NC=""

# Prompts to auto-install a missing tool via the platform's package manager.
# Returns 0 if the tool is available afterwards, 1 otherwise. Declines
# automatically (no prompt hang) if stdin isn't a terminal.
offer_install_pkg() {
  local tool_name="$1" apt_pkg="$2" brew_pkg="$3" reply
  if [ ! -t 0 ]; then
    echo "  (no terminal attached to answer a prompt - skipping auto-install of $tool_name)"
    return 1
  fi
  if [[ "$OS_TYPE" == "darwin" ]]; then
    printf '%s is missing. Install it now via Homebrew (brew install %s)? [y/N] ' "$tool_name" "$brew_pkg"
  else
    printf '%s is missing. Install it now via apt (sudo apt install %s)? [y/N] ' "$tool_name" "$apt_pkg"
  fi
  read -r reply
  case "$reply" in
    [Yy]*)
      if [[ "$OS_TYPE" == "darwin" ]]; then
        local _had=0; pkg_already_installed brew "$brew_pkg" && _had=1
        brew install "$brew_pkg" && [ "$_had" -eq 0 ] && record_installed_dep "brew" "$brew_pkg"
      else
        local _had=0; pkg_already_installed apt "$apt_pkg" && _had=1
        sudo apt-get update && sudo apt-get install -y "$apt_pkg" && [ "$_had" -eq 0 ] && record_installed_dep "apt" "$apt_pkg"
      fi
      ;;
    *)
      return 1
      ;;
  esac
  command -v "$tool_name" >/dev/null 2>&1
}

# Offers to build detox 3.0.1 from source on Linux/A314, using the exact
# commands this script already documents as manual instructions.
offer_build_detox() {
  local reply
  if [ ! -t 0 ]; then
    echo "  (no terminal attached to answer a prompt - skipping auto-build of detox)"
    return 1
  fi
  printf 'Build and install detox 3.0.1 from source now? [y/N] '
  read -r reply
  case "$reply" in
    [Yy]*) : ;;
    *) return 1 ;;
  esac
  local build_dir
  build_dir="$(mktemp -d)" || return 1

  # If a detox binary already exists where `make install` will put it (e.g.
  # an older pre-3.0 version the user installed themselves), it gets
  # upgraded in place - but it was NOT originally installed by these
  # scripts, so it must not be tracked for the uninstaller to delete later.
  local detox_preexisted=0
  [ -e /usr/local/bin/detox ] && detox_preexisted=1

  # Only install build-dependency packages that are genuinely missing -
  # checked individually via dpkg, since blindly apt-installing the whole
  # list would make it look like THIS script installed something (e.g.
  # gcc, make) that was actually already on the system beforehand, which
  # the uninstaller would then wrongly remove later.
  local build_deps=(git autoconf automake bison flex gcc make pkg-config)
  local deps_to_install=()
  local dep
  for dep in "${build_deps[@]}"; do
    pkg_already_installed apt "$dep" || deps_to_install+=("$dep")
  done

  (
    set -e
    if [ ${#deps_to_install[@]} -gt 0 ]; then
        sudo apt-get update
        sudo apt-get install -y "${deps_to_install[@]}"
    fi
    cd "$build_dir"
    wget -q https://github.com/dharple/detox/releases/download/v3.0.1/detox-3.0.1.tar.gz
    tar xzf detox-3.0.1.tar.gz
    cd detox-3.0.1
    ./configure
    make
    sudo make install
  )
  local build_status=$?
  rm -rf "$build_dir"
  if [ "$build_status" -eq 0 ]; then
    for dep in "${deps_to_install[@]+"${deps_to_install[@]}"}"; do
        record_installed_dep "apt" "$dep"
    done
    # `make install` for this package's Makefile puts the binary at
    # /usr/local/bin/detox - tracked as source-build (a plain file path)
    # since there's no package manager entry for uninstall_deps.sh to
    # remove it through.
    if [ "$detox_preexisted" -eq 0 ] && [ -x /usr/local/bin/detox ]; then
        record_installed_dep "source-build" "/usr/local/bin/detox"
    fi
  fi
  [ "$build_status" -eq 0 ] && command -v detox >/dev/null 2>&1
}

# ----- Tool dependency check (lha, 7z, unar detox) -----
missing=()
for tool in lha 7z unar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing+=("$tool")
    fi
done

if [ ${#missing[@]} -ne 0 ]; then
    echo "Missing tools: ${missing[*]}"
    still_missing=()
    for tool in "${missing[@]}"; do
        case "$tool" in
            lha)  apt_pkg="lhasa";      brew_pkg="lha" ;;
            7z)   apt_pkg="p7zip-full"; brew_pkg="p7zip" ;;
            unar) apt_pkg="unar";       brew_pkg="unar" ;;
        esac
        if offer_install_pkg "$tool" "$apt_pkg" "$brew_pkg"; then
            echo "  $tool is now available."
        else
            still_missing+=("$tool")
        fi
    done
    if [ ${#still_missing[@]} -ne 0 ]; then
        echo
        echo "Still missing: ${still_missing[*]}"
        if [ ! -t 0 ]; then
            echo "Note: this is an unattended run (e.g. cron), which starts with a minimal PATH."
            echo "If the tool works in your terminal, run ./install_cron.sh again from that"
            echo "terminal (or any script once, interactively) so its folder is remembered."
        fi

        if [[ "$OS_TYPE" == "darwin" ]]; then
            echo "Install via Homebrew (macOS): brew install ${still_missing[*]}"
            echo "Also: brew install coreutils (for greadlink)"
        else
            apt_names=()
            for t in "${still_missing[@]}"; do
                case "$t" in
                    lha) apt_names+=("lhasa") ;;
                    7z)  apt_names+=("p7zip-full") ;;
                    *)   apt_names+=("$t") ;;
                esac
            done
            echo "Or via apt (Linux): sudo apt install ${apt_names[*]}"
        fi
        exit 4
    fi
fi

# ----- unlzx check and detailed help -----
if ! command -v unlzx >/dev/null 2>&1; then
    echo "'unlzx' is not installed or not in PATH."
    echo "unlzx is required to extract LZX archives used by Retroplay sets."
    echo "It has no standard apt/brew package, so it can't be auto-installed -"
    echo "it must be downloaded from Aminet and built from source:"
    echo
    echo "You can download unlzx from Aminet (Amiga archive site):"
    echo "  https://aminet.net/package/util/arc/unlzx"
    echo
    echo "Build hints (gcc) for modern systems:"
    echo
    echo "On macOS (with Xcode CLI tools and Homebrew):"
    echo "  # Ensure you have a working gcc/clang toolchain"
    echo "  # Then from the extracted unlzx source directory:"
    echo "  gcc -O2 -std=c99 -Wall -Wextra -o unlzx unlzx.c"
    echo "  strip unlzx"
    echo "  # Finally place it somewhere on your PATH, e.g.:"
    echo "  sudo mv unlzx /usr/local/bin/"
    echo
    echo "On Linux (Debian/Ubuntu-style):"
    echo "  sudo apt-get install build-essential"
    echo "  # Then from the extracted unlzx source directory:"
    echo "  gcc -O2 -pipe -fomit-frame-pointer -std=c99 -Wall -Wextra -o unlzx unlzx.c"
    echo "  strip unlzx"
    echo "  sudo mv unlzx /usr/local/bin/"
    echo
    echo "After installation, ensure 'unlzx' is on your PATH and re-run this script."
    exit 1
fi
# ----- Detox version check (Debian/A314 only) -----
# This gate runs before normal option parsing (further below), so do a quick
# pre-scan of the raw arguments for --no-detox here rather than moving the
# whole dependency-check block after parsing.
_no_detox_requested=0
[ "$RP_USE_DETOX" = "no" ] && _no_detox_requested=1      # retroplay.conf default
for _a in "$@"; do
    case "$(printf '%s' "$_a" | tr '[:upper:]' '[:lower:]')" in
        --no-detox) _no_detox_requested=1 ;;
        --detox)    _no_detox_requested=0 ;;
    esac
done

if [ "$_no_detox_requested" -eq 1 ]; then
    :   # detox not wanted (--no-detox, or USE_DETOX=no in retroplay.conf)
elif [[ "$OS_TYPE" != "darwin" ]]; then
  detox_ok=0
  if command -v detox >/dev/null 2>&1; then
    DETOX_VER_RAW="$(detox -V 2>/dev/null || true)"
    DETOX_VER="$(printf '%s\n' "$DETOX_VER_RAW" | sed -n 's/[^0-9]*\([0-9]\+\.[0-9]\+\).*/\1/p')"
    if [ -n "$DETOX_VER" ] && ! awk "BEGIN{exit !($DETOX_VER < 3.0)}"; then
        detox_ok=1
    fi
  fi

  if [ "$detox_ok" -eq 0 ]; then
    if [ -n "${DETOX_VER_RAW:-}" ]; then
      echo "Detected detox version '$DETOX_VER_RAW' (need 3.0 or greater)."
    else
      echo "detox not found on this Debian/A314 system."
    fi
    if offer_build_detox; then
      echo "  detox is now available."
    else
      echo "Install Detox 3.0.1 manually with:"
      echo "  sudo apt install -y git autoconf automake bison flex gcc make pkg-config"
      echo "  wget https://github.com/dharple/detox/releases/download/v3.0.1/detox-3.0.1.tar.gz"
      echo "  tar xzf detox-3.0.1.tar.gz"
      echo "  cd detox-3.0.1"
      echo "  ./configure"
      echo "  make"
      echo "  sudo make install"
      echo "  detox -V"
      echo "Or skip detox entirely with --no-detox."
      exit 1
    fi
  fi
fi

# Error handler to show which command failed
error_handler() {
  local line_no=$1
  local exit_code=$2
  echo
  echo "ERROR: Script failed at line $line_no with exit code $exit_code"
  echo "Last action: $ACTION"
  echo
  exit "$exit_code"
}

# Option parsing (Bash 3.2/macOS compatible)
while [ $# -gt 0 ]; do
  opt_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$opt_lc" in
    -h|--help)
      echo
      echo "Amiga Retroplay Archive Minimal CLI Dispatcher"
      echo "Version: ${version}"
      echo
      echo "Usage: $(basename "$0") [options]"
      echo
      echo "Options (case-insensitive - --AGA and --aga both work):"
      echo "  -h, --help            Show this help and exit."
      echo "  --auto                Run full automation: update, extract, merge, sort."
      echo "  --update              Only update archives."
      echo "  --extract             Only extract archives."
      echo "  --merge               Only merge artwork."
      echo "  --sort                Only sort languages."
      echo "  --quick               Only process new files (quick.sh)."
      echo "  --ecs                 Run merge.sh with --ecs."
      echo "  --aga                 Run merge.sh with --aga."
      echo "  --rtg                 Run merge.sh with --rtg."
      echo "  --ecs-laced           Run merge.sh with --ecs-laced (matches iGame_ECS_Laced)."
      echo "  --aga-laced           Run merge.sh with --aga-laced (matches iGame_AGA_Laced)."
      echo "  --set [name]          Run merge.sh with --set NAME (any iGame_NAME directory)."
      echo "  --ffs                 Run sort.sh with --ffs (FFS filename limits)."
      echo "  --pfs                 Run sort.sh with --pfs (PFS filename limits, default)."
      echo "  --dest [path]         Set custom destination directory."
      echo "  --art [order]         Set merge priority order for non-demos (e.g., Screens,Covers,Titles)."
      echo "  --demo-art [order]    Set merge priority order for demos (e.g., Titles,Screens,Covers)."
      echo "  --no-detox            Skip detox entirely - the startup dependency check and"
      echo "                        the pre-clean step in sort.sh."
      echo "  --skipchk             Run sort.sh with --skipchk (skip the Amiga filesystem"
      echo "                        compliance check entirely)."
      echo "  --skip-variant-sort   Run sort.sh with --skip-variant-sort (skip moving games"
      echo "                        into CD32/AGA/NTSC/MT32/CDTV and language subfolders -"
      echo "                        for when that reorganization was already done earlier"
      echo "                        on a shared base tree)."
      echo "  --rebuild             Rebuild from the archives already downloaded, without"
      echo "                        checking for updates (with --auto's variant options)."
      echo "  --clean               With --auto: check for updates, then rebuild from scratch."
      echo "  --skip-update         With --auto: don't download; process what's already queued."
      echo "  --force               With --auto: also fill in missing artwork when up to date."
      echo "  --detox               Use detox even if retroplay.conf says USE_DETOX=no."
      echo "  --report-missing FILE With --merge: list games that got no artwork in FILE."
      echo "  --doctor              Check the setup and explain how to fix any problems."
      echo "  --status              Show the last run, each variant's state, drive and schedule."
      echo "  --test-notify         Send a test notification (ntfy/email from retroplay.conf)."
      echo "  --debug               Enable debug output (also passed to extract.sh/merge.sh)."
      echo "  --exit                Exit immediately."
      echo
      exit 0
      ;;
    --auto)
      ACTION="auto"
      shift
      ;;
    --update)
      ACTION="update"
      shift
      ;;
    --extract)
      ACTION="extract"
      shift
      ;;
    --merge)
      ACTION="merge"
      shift
      ;;
    --sort)
      ACTION="sort"
      shift
      ;;
    --quick)
      ACTION="quick"
      shift
      ;;
    --ecs)
      MERGE_OPT="--ecs"
      shift
      ;;
    --aga)
      MERGE_OPT="--aga"
      shift
      ;;
    --rtg)
      MERGE_OPT="--rtg"
      shift
      ;;
    --ecs-laced)
      MERGE_OPT="--ecs-laced"
      shift
      ;;
    --aga-laced)
      MERGE_OPT="--aga-laced"
      shift
      ;;
    --set)
      rp_require_option_value "$1" "$#" "${2-}"
      SET_OPT="$2"
      shift 2
      ;;
    --ffs)
      SORT_OPT="--ffs"
      shift
      ;;
    --pfs)
      SORT_OPT="--pfs"
      shift
      ;;
    -d|--dest)
      rp_require_option_value "$1" "$#" "${2-}"
      DEST_OPT="$2"
      shift 2
      ;;
    --art)
      rp_require_option_value "$1" "$#" "${2-}"
      ART_ORDER_OPT="$2"
      shift 2
      ;;
    --demo-art)
      rp_require_option_value "$1" "$#" "${2-}"
      DEMO_ART_OPT="$2"
      shift 2
      ;;
    --no-detox)
      NO_DETOX=1
      DETOX_EXPLICIT=no
      shift
      ;;
    --detox)
      NO_DETOX=0
      DETOX_EXPLICIT=yes
      shift
      ;;
    --rebuild)
      ACTION="auto"
      REBUILD_OPT=1
      shift
      ;;
    --force)
      FORCE_OPT=1
      shift
      ;;
    --report-missing)
      rp_require_option_value "$1" "$#" "${2-}"
      REPORT_MISSING_OPT="$2"
      shift 2
      ;;
    --doctor)
      exec "$SCRIPT_DIR/doctor.sh"
      ;;
    --status)
      rp_print_status
      exit 0
      ;;
    --test-notify)
      rp_test_notify
      exit $?
      ;;
    --skipchk)
      SKIPCHK_OPT=1
      shift
      ;;
    --skip-variant-sort)
      SKIP_VARIANT_SORT_OPT=1
      shift
      ;;
    --only-missing)
      ONLY_MISSING_OPT=1
      shift
      ;;
    --debug)
      DEBUG_MODE=1
      shift
      ;;
    --exit)
      exit 0
      ;;
    --skip-update)
      SKIP_UPDATE=1
      shift
      ;;
    --clean)
      CLEAN_OPT=1
      shift
      ;;
    --nothing-new-fallback)
      # Internal only (not in --help): used when --auto's own update.sh call
      # found nothing new. Shows the same interactive menu, but exiting it
      # without a real choice (timeout or blank/0) propagates exit code 2
      # instead of 0, so a caller further up (e.g. all.sh) can still tell
      # "nothing new" apart from "did something" even after this handoff.
      NOTHING_NEW_FALLBACK=1
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 4
      ;;
  esac
done
unset opt_lc

# If no action was specified via CLI, show interactive menu
if [ -z "$ACTION" ]; then
  echo
  echo "Amiga Retroplay Archive Minimal CLI Dispatcher"
  echo "Version: ${version}"
  echo
  rp_print_status short
  echo
  echo "Select an action:"
  echo "  1) Auto (update, extract, merge, sort, clean)"
  echo "  2) Update only"
  echo "  3) Extract only"
  echo "  4) Merge artwork"
  echo "  5) Sort languages"
  echo "  6) Quick (process new files)"
  echo "  7) Rebuild from downloaded archives (no update check)"
  echo "  8) Check setup (doctor)"
  echo "  9) Show full status"
  echo " 10) Send a test notification"
  echo "  0) Exit"
  echo

  printf "Enter choice [0-10]: "
  # 3-minute timeout: if this menu is here because --auto's own update.sh
  # found nothing new (NOTHING_NEW_FALLBACK), don't wait forever for a
  # human who isn't there - and propagate that "nothing happened" outcome
  # as exit code 2 (matching update.sh's own convention) rather than a
  # plain 0, so a caller like all.sh can still tell this apart from a run
  # that actually did something.
  if ! read -t 180 -r menu_choice; then
    echo
    echo "No input received within 3 minutes."
    if [ "$NOTHING_NEW_FALLBACK" -eq 1 ]; then
      exit 2
    fi
    echo "Exiting."
    exit 0
  fi

  case "$menu_choice" in
    1)
      ACTION="auto"
      ;;
    2)
      ACTION="update"
      ;;
    3)
      ACTION="extract"
      ;;
    4)
      ACTION="merge"
      ;;
    5)
      ACTION="sort"
      ;;
    6)
      ACTION="quick"
      ;;
    7)
      ACTION="auto"
      REBUILD_OPT=1
      ;;
    8)
      exec "$SCRIPT_DIR/doctor.sh"
      ;;
    9)
      rp_print_status
      exit 0
      ;;
    10)
      rp_test_notify
      exit $?
      ;;
    0|"")
      echo "Exiting."
      if [ "$NOTHING_NEW_FALLBACK" -eq 1 ]; then
        exit 2
      fi
      exit 0
      ;;
    *)
      echo "Invalid choice: $menu_choice"
      exit 4
      ;;
  esac
fi

# NOW enable strict mode after parsing options and menu
set -e

# Set error trap
trap 'error_handler ${LINENO} $?' ERR

# ----- Locale check for ASCII & Latin-1 -----
ascii_locale="C.utf8"
latin1_locale="en_US.iso88591"
missing_locales=""

# Only check locales if not running on macOS
if [ "$(uname -s)" != "Darwin" ]; then
  # locale -a spells the same locale differently depending on the system
  # (C.utf8 / C.UTF-8, en_US.iso88591 / en_US.ISO-8859-1), so compare
  # case-insensitively with dashes removed - the same way doctor.sh does.
  _norm_locales="$(locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '-')"
  if ! printf '%s\n' "$_norm_locales" | grep -qx "c.utf8"; then
    missing_locales="$ascii_locale"
  fi

  if ! printf '%s\n' "$_norm_locales" | grep -qx "en_us.iso88591"; then
    if [ -n "$missing_locales" ]; then
      missing_locales="$missing_locales, $latin1_locale"
    else
      missing_locales="$latin1_locale"
    fi
  fi

  if [ -n "$missing_locales" ]; then
    echo "Dependency check:"
    echo "Missing locales: $missing_locales"
    echo
    echo "To install these locales:"
    echo "For Debian/Ubuntu:"
    echo "  1. Edit /etc/locale.gen and uncomment/add:"
    echo "     C.UTF-8 UTF-8"
    echo "     en_US ISO-8859-1"
    echo "  2. Run:"
    echo "     sudo locale-gen"
    echo "     sudo dpkg-reconfigure locales"
    echo "For other Linux distributions:"
    echo "  - Refer to your system's locale documentation"
    echo "  - Make sure language packs are installed and regenerate locales"
    exit 1
  fi
fi

# ----- Helper function: Check if subscript exists -----
check_script() {
  local script_path="$1"
  if [ ! -f "$script_path" ]; then
    echo "ERROR: Required script not found: $script_path"
    echo "Script directory: $SCRIPT_DIR"
    exit 1
  fi
  if [ ! -x "$script_path" ]; then
    echo "ERROR: Script is not executable: $script_path"
    echo "Run: chmod +x $script_path"
    exit 1
  fi
}

# ----- Helper function: Run subscript with debug output -----
# Resolves the script name against SCRIPT_DIR so this works no matter what
# directory the caller's shell was in when start.sh was invoked.
run_sub() {
  local script_rel="$1"
  shift
  local script_path="$SCRIPT_DIR/${script_rel#./}"

  if [ "$DEBUG_MODE" -eq 1 ]; then
    echo "[DEBUG] Running: $script_path $*"
  fi

  check_script "$script_path"

  "$script_path" "$@"
}

# Build the merge.sh argument list from whatever the user specified.
#
# NOTE: every one of these ends with `return 0`. Under `set -e`, a bare
# statement like `[ -n "$X" ] && arr+=(...)` makes the *whole function*
# return non-zero whenever that particular test is false - and since these
# are called as plain statements (not inside an `if`), that would abort the
# entire script right there. `return 0` guarantees a clean exit status
# regardless of which of the conditionals above it matched.
#
build_merge_args() {
  merge_args=()
  [ -n "$MERGE_OPT" ] && merge_args+=("$MERGE_OPT")
  [ -n "$SET_OPT" ] && merge_args+=(--set "$SET_OPT")
  [ -n "$ART_ORDER_OPT" ] && merge_args+=(--art "$ART_ORDER_OPT")
  [ -n "$DEMO_ART_OPT" ] && merge_args+=(--demo-art "$DEMO_ART_OPT")
  [ -n "$DEST_OPT" ] && merge_args+=(-d "$DEST_OPT")
  [ "$ONLY_MISSING_OPT" -eq 1 ] && merge_args+=(--only-missing)
  [ -n "$REPORT_MISSING_OPT" ] && merge_args+=(--report-missing "$REPORT_MISSING_OPT")
  [ "$DEBUG_MODE" -eq 1 ] && merge_args+=(--debug)
  return 0
}

# Build the sort.sh argument list. sort.sh tolerates an empty SORT_OPT.
build_sort_args() {
  sort_args=()
  [ -n "$SORT_OPT" ] && sort_args+=("$SORT_OPT")
  [ -n "$DEST_OPT" ] && sort_args+=(--dest "$DEST_OPT")
  [ "$NO_DETOX" -eq 1 ] && sort_args+=(--no-detox)
  [ "$SKIPCHK_OPT" -eq 1 ] && sort_args+=(--skipchk)
  [ "$SKIP_VARIANT_SORT_OPT" -eq 1 ] && sort_args+=(--skip-variant-sort)
  return 0
}

# Build the extract.sh argument list.
build_extract_args() {
  extract_args=()
  [ -n "$DEST_OPT" ] && extract_args+=(-d "$DEST_OPT")
  [ "$DEBUG_MODE" -eq 1 ] && extract_args+=(--debug)
  return 0
}

# Build the quick.sh argument list, forwarding every option it understands.
build_quick_args() {
  quick_args=()
  [ -n "$MERGE_OPT" ] && quick_args+=("$MERGE_OPT")
  [ -n "$SET_OPT" ] && quick_args+=(--set "$SET_OPT")
  [ -n "$ART_ORDER_OPT" ] && quick_args+=(--art "$ART_ORDER_OPT")
  [ -n "$DEMO_ART_OPT" ] && quick_args+=(--demo-art "$DEMO_ART_OPT")
  [ -n "$DEST_OPT" ] && quick_args+=(-d "$DEST_OPT")
  [ "$NO_DETOX" -eq 1 ] && quick_args+=(--no-detox)
  return 0
}

# Main dispatcher logic
#
# Announce progress as "Step N of TOTAL: scriptname" before running each
# sub-script, so it's clear how far through a multi-script run (like
# --auto's update -> extract -> merge -> sort) things are. TOTAL_STEPS
# depends on which ACTION was chosen - --auto runs 4 sub-scripts, every
# other single action runs exactly 1.
# Standalone --sort / --merge use the retroplay.conf defaults when no option
# was given (--auto passes only what was given explicitly - all.sh applies
# the config itself).
if [ "$ACTION" != "auto" ]; then
  [ -z "$SORT_OPT" ] && SORT_OPT="--$RP_FILESYSTEM"
  [ -z "$ART_ORDER_OPT" ] && ART_ORDER_OPT="$RP_ART_ORDER"
  [ -z "$DEMO_ART_OPT" ] && DEMO_ART_OPT="$RP_DEMO_ART_ORDER"
fi

case "$ACTION" in
  auto) TOTAL_STEPS=4 ;;
  *)    TOTAL_STEPS=1 ;;
esac
STEP_NUM=0

run_step() {
  local label="$1"
  shift
  STEP_NUM=$((STEP_NUM + 1))
  echo
  echo "===== Step $STEP_NUM of $TOTAL_STEPS: $label ====="
  run_sub "$@"
}

if [ "$ACTION" = "auto" ]; then
  # --auto (and --rebuild) run through all.sh - the pipeline engine - for
  # this one variant, so single-variant runs get exactly the same
  # protections as the full nightly run: queued downloads, resumable full
  # builds, disk-space checks, version-folder replacement, dated new_ batch
  # folders, the run report and the overlapping-run lock.
  engine_args=()
  case "$MERGE_OPT" in
    --aga|--ecs|--rtg|--aga-laced|--ecs-laced) engine_args+=("$MERGE_OPT") ;;
    *)
      if [ -n "$SET_OPT" ]; then engine_args+=(--set "$SET_OPT")
      else engine_args+=(--variants default); fi ;;
  esac
  [ -n "$DEST_OPT" ] && engine_args+=(--dest "$DEST_OPT")
  [ -n "$ART_ORDER_OPT" ] && engine_args+=(--art "$ART_ORDER_OPT")
  [ -n "$DEMO_ART_OPT" ] && engine_args+=(--demo-art "$DEMO_ART_OPT")
  [ -n "$SORT_OPT" ] && engine_args+=("$SORT_OPT")
  [ "$DETOX_EXPLICIT" = "no" ] && engine_args+=(--no-detox)
  [ "$DETOX_EXPLICIT" = "yes" ] && engine_args+=(--detox)
  [ "$DEBUG_MODE" -eq 1 ] && engine_args+=(--debug)
  [ "$CLEAN_OPT" -eq 1 ] && engine_args+=(--clean)
  [ "$SKIP_UPDATE" -eq 1 ] && engine_args+=(--skip-update)
  [ "$REBUILD_OPT" -eq 1 ] && engine_args+=(--rebuild)
  [ "$FORCE_OPT" -eq 1 ] && engine_args+=(--force)

  DELEGATED_AUTO=1
  if ./all.sh "${engine_args[@]}"; then AUTO_EXIT=0; else AUTO_EXIT=$?; fi
  [ "$AUTO_EXIT" -ne 0 ] && echo "Result: $(rp_exit_meaning "$AUTO_EXIT")"

  # Nothing new: offer the menu instead (interactive runs only).
  if [ "$AUTO_EXIT" -eq 2 ] && [ "$NOTHING_NEW_FALLBACK" -eq 0 ] && [ -t 0 ] \
     && [ "${RETROPLAY_ALL_SH:-}" != "1" ]; then
    echo
    echo "Nothing new to process - showing the menu instead."
    fallback_args=(--nothing-new-fallback)
    [ -n "$MERGE_OPT" ] && fallback_args+=("$MERGE_OPT")
    [ -n "$SET_OPT" ] && fallback_args+=(--set "$SET_OPT")
    [ -n "$DEST_OPT" ] && fallback_args+=(--dest "$DEST_OPT")
    [ -n "$ART_ORDER_OPT" ] && fallback_args+=(--art "$ART_ORDER_OPT")
    [ -n "$DEMO_ART_OPT" ] && fallback_args+=(--demo-art "$DEMO_ART_OPT")
    [ "$DETOX_EXPLICIT" = "no" ] && fallback_args+=(--no-detox)
    [ "$DEBUG_MODE" -eq 1 ] && fallback_args+=(--debug)
    exec ./start.sh "${fallback_args[@]}"
  fi

elif [ "$ACTION" = "merge" ]; then
  build_merge_args
  run_step "merge.sh" ./merge.sh "${merge_args[@]+"${merge_args[@]}"}"

elif [ "$ACTION" = "update" ]; then
  # Standalone --update: pass update.sh's own exit code straight through
  # rather than letting set -e's crash handler fire for its non-zero-but-
  # not-actually-broken outcomes (2 = nothing new, 3 = wget error) - its
  # own output already explains which case it was.
  if run_step "update.sh" ./update.sh; then
    update_status=0
  else
    update_status=$?
  fi
  exit "$update_status"
elif [ "$ACTION" = "extract" ]; then
  build_extract_args
  run_step "extract.sh" ./extract.sh "${extract_args[@]+"${extract_args[@]}"}"
elif [ "$ACTION" = "sort" ]; then
  build_sort_args
  run_step "sort.sh" ./sort.sh "${sort_args[@]+"${sort_args[@]}"}"
elif [ "$ACTION" = "quick" ]; then
  build_quick_args
  run_step "quick.sh" ./quick.sh "${quick_args[@]+"${quick_args[@]}"}"
else
  echo
  echo "No valid action resolved. Use -h or --help to see available options."
  echo
  exit 1
fi

# ----- Post-run log handling -----

# We never left SCRIPT_DIR (sub-scripts run as child processes, so their own
# internal `cd`s don't affect us) - this is just a defensive re-assertion.
cd "$SCRIPT_DIR" || true

# update.log is a useful standalone record of what was downloaded each run
# (not an error log), so it's handled separately from the error-log
# aggregation below: deleted only if genuinely empty, never merged away.
if [ -e "update.log" ] && [ ! -s "update.log" ]; then
    rm -f -- "update.log"
fi

# Candidate log files: an EXPLICIT list of the specific files the
# sub-scripts are known to produce, rather than a blanket "*.log" glob.
# A glob would also catch things that just happen to live in this same
# directory and end in .log but aren't ours to touch - most notably
# all_cron.log, which install_cron.sh sets up to accumulate cron output
# right here via `>>`; sweeping that into retroerror.log and deleting it
# would silently break the cron log the moment it existed.
retro_log="retroerror.log"
log_files=()
for f in extract_errors.log merge_errors.log sort.log amiga_filename_issues.log; do
    [ -f "$f" ] && log_files+=("./$f")
done

# Delete 0‑byte log files and keep non‑empty ones for merging
non_empty_logs=()
for f in "${log_files[@]+"${log_files[@]}"}"; do
    if [ ! -s "$f" ]; then
        rm -f -- "$f"
    else
        non_empty_logs+=("$f")
    fi
done

# Merge remaining logs into retroerror.log with section headers. Under
# all.sh (RETROPLAY_ALL_SH=1), don't truncate first - all.sh resets this
# file once at the very start of its own run, and each variant (aga/ecs/
# rtg) then appends its own section here in turn, so the whole all.sh run
# ends with ONE combined log covering all three variants, rather than
# each variant's start.sh wiping out what the previous variant just wrote.
if [ "${RETROPLAY_ALL_SH:-}" != "1" ] && [ "$DELEGATED_AUTO" -ne 1 ]; then
    : > "$retro_log"
fi
for f in "${non_empty_logs[@]+"${non_empty_logs[@]}"}"; do
    {
        printf '===== %s =====\n' "$(basename "$f")"
        cat "$f"
        printf '\n\n'
    } >> "$retro_log"
done

# Delete the individual logs now that they're consolidated into $retro_log
# (same explicit list as above - never touches all_cron.log or anything
# else that happens to share this directory).
if [ -s "$retro_log" ]; then
  for f in "${log_files[@]+"${log_files[@]}"}"; do
    [ -e "$f" ] || continue
    rm -f -- "$f"
  done
fi

# retroerror.log itself: if this run genuinely had nothing to report, don't
# leave a 0-byte file sitting around.
if [ -e "$retro_log" ] && [ ! -s "$retro_log" ]; then
    rm -f -- "$retro_log"
fi

# Ask user whether to view or delete the error log (default: view) - but
# only if there's actually a terminal to ask on, AND we're not running as
# part of an all.sh pass. Under cron (or any other non-interactive run),
# stdin is closed/redirected, so `read` would return immediately with an
# empty answer, defaulting to "view" and trying to launch `less` with no
# controlling terminal - which fails and, under set -e, would crash the
# whole script right at the finish line even though everything before
# this point genuinely succeeded. Under all.sh specifically, even a
# genuinely attached terminal is skipped deliberately: prompting here
# would stall the pipeline after variant 1 waiting on input before
# variant 2 (ecs.sh) even starts, which defeats the entire point of
# all.sh being able to run straight through unattended.
if [ -s "$retro_log" ]; then
    echo
    echo "Error log has been written to: $retro_log"
    if [ "${RETROPLAY_ALL_SH:-}" = "1" ]; then
        echo "(running as part of all.sh - leaving it in place for review once all variants finish; view it with: less $retro_log)"
    elif [ -t 0 ]; then
        printf "View error log, delete it, or skip? [V/d/s]: "
        read -r log_choice
        case "${log_choice:-V}" in
            [Vv])
                ${PAGER:-less} "$retro_log"
                ;;
            [Dd])
                rm -f -- "$retro_log"
                echo "Error log deleted."
                ;;
            *)
                echo "Leaving error log in place."
                ;;
        esac
    else
        echo "(no terminal attached - leaving it in place; view it with: less $retro_log)"
    fi
fi

exit "$AUTO_EXIT"
