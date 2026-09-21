#!/usr/bin/env bash

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
FORCE_REBUILD=0   # set only by menu option 7: rebuild unconditionally,
                  # without even checking update.log's content first (the
                  # whole point of that option is "just rebuild from
                  # whatever's on disk now" - unlike --skip-update on its
                  # own, which still checks update.log so all.sh's
                  # variant-chaining can tell whether anything was new).
CLEAN_OPT=0
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
        brew install "$brew_pkg"
      else
        sudo apt-get update && sudo apt-get install -y "$apt_pkg"
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
  (
    set -e
    sudo apt-get update
    sudo apt-get install -y git autoconf automake bison flex gcc make pkg-config
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
        exit 1
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
for _a in "$@"; do
    [ "$_a" = "--no-detox" ] && _no_detox_requested=1 && break
done

if [ "$_no_detox_requested" -eq 1 ]; then
    echo "Skipping detox dependency check (--no-detox given)."
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
      DEST_OPT="$2"
      shift 2
      ;;
    --art)
      ART_ORDER_OPT="$2"
      shift 2
      ;;
    --demo-art)
      DEMO_ART_OPT="$2"
      shift 2
      ;;
    --no-detox)
      NO_DETOX=1
      shift
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
      exit 1
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
  echo "Select an action:"
  echo "  1) Auto (update, extract, merge, sort, clean)"
  echo "  2) Update only"
  echo "  3) Extract only"
  echo "  4) Merge artwork"
  echo "  5) Sort languages"
  echo "  6) Quick (process new files)"
  echo "  7) Full rebuild, skip update (update already ran, or use option 1 instead)"
  echo "  0) Exit"
  echo

  printf "Enter choice [0-7]: "
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
      SKIP_UPDATE=1
      FORCE_REBUILD=1
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
      exit 1
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
  if ! locale -a | grep -qi "$ascii_locale"; then
    missing_locales="$ascii_locale"
  fi

  if ! locale -a | grep -qi "$latin1_locale"; then
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
  # Derive the per-variant output directory (retro_aga/retro_ecs/retro_rtg/
  # etc.) from whichever artwork option was chosen, unless the user gave an
  # explicit --dest. This is what makes each variant build directly into
  # its own named directory instead of always writing to a plain "retro"
  # that something else has to rename afterward.
  case "$MERGE_OPT" in
    --aga)    VARIANT_SUFFIX="aga" ;;
    --ecs)    VARIANT_SUFFIX="ecs" ;;
    --rtg)    VARIANT_SUFFIX="rtg" ;;
    --aga-laced) VARIANT_SUFFIX="aga_laced" ;;
    --ecs-laced) VARIANT_SUFFIX="ecs_laced" ;;
    *)
      if [ -n "$SET_OPT" ]; then
        VARIANT_SUFFIX="$(printf '%s' "$SET_OPT" | tr '[:upper:]' '[:lower:]')"
      else
        VARIANT_SUFFIX=""
      fi
      ;;
  esac
  if [ -z "$DEST_OPT" ]; then
    if [ -n "$VARIANT_SUFFIX" ]; then
      DEST_OPT="retro_$VARIANT_SUFFIX"
    else
      DEST_OPT="retro"
    fi
  fi

  # --clean removes any existing output for this variant and forces a full
  # rebuild, exactly like every --auto run used to behave. Without --clean,
  # an existing output directory is updated incrementally (new downloads
  # only, plus a gap-fill artwork pass) instead of being fully rebuilt.
  if [ "$CLEAN_OPT" -eq 1 ] && [ -e "$DEST_OPT" ]; then
    echo "Removing existing '$DEST_OPT' (--clean given)..."
    rm -rf "$DEST_OPT"
  fi
  INCREMENTAL=0
  [ "$CLEAN_OPT" -ne 1 ] && [ -d "$DEST_OPT" ] && INCREMENTAL=1

  if [ "$INCREMENTAL" -eq 1 ]; then
    TOTAL_STEPS=5
  else
    TOTAL_STEPS=3
  fi
  [ "$SKIP_UPDATE" -eq 0 ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))

  # update.sh signals its outcome via exit code (see update.sh itself for
  # the full rationale): 0 = new files found, continue as normal; 2 =
  # nothing new anywhere, nothing to process; 3 = a wget error occurred and
  # "0 new" can't be trusted. Capturing the status this way (as the
  # condition of an `if`) is what keeps `set -e` from treating a non-zero
  # exit as a crash before we get a chance to look at which case it is.
  # --skip-update (used when a caller like all.sh has already run
  # update.sh itself this pass) reads the existing update.log instead of
  # running update.sh again.
  if [ "$FORCE_REBUILD" -eq 1 ]; then
    update_status=0
  elif [ "$SKIP_UPDATE" -eq 1 ]; then
    if [ ! -s "$SCRIPT_DIR/update.log" ] || [ "$(grep -c '^' "$SCRIPT_DIR/update.log" 2>/dev/null || echo 0)" -eq 0 ]; then
      update_status=2
    else
      update_status=0
    fi
  elif run_step "update.sh" ./update.sh; then
    update_status=0
  else
    update_status=$?
  fi

  if [ "$update_status" -eq 3 ]; then
    echo
    echo "Stopping: update.sh reported a wget error (see above). Not continuing" >&2
    echo "with extract/merge/sort." >&2
    exit 1
  elif [ "$update_status" -eq 2 ]; then
    echo
    echo "Nothing new to process - handing off to start.sh's menu instead of a full rebuild."
    # Carry the current variant selection through the re-exec, so the
    # fallback menu (and anything chosen from it, e.g. "full rebuild") acts
    # on the SAME variant this run was building - exec starts a genuinely
    # fresh process, so without this, --aga/--set/--dest/etc. would all be
    # silently lost and the menu would fall back to whatever the defaults
    # happen to be.
    fallback_args=(--nothing-new-fallback)
    [ -n "$MERGE_OPT" ] && fallback_args+=("$MERGE_OPT")
    [ -n "$SET_OPT" ] && fallback_args+=(--set "$SET_OPT")
    [ -n "$DEST_OPT" ] && fallback_args+=(--dest "$DEST_OPT")
    [ -n "$ART_ORDER_OPT" ] && fallback_args+=(--art "$ART_ORDER_OPT")
    [ -n "$DEMO_ART_OPT" ] && fallback_args+=(--demo-art "$DEMO_ART_OPT")
    [ "$NO_DETOX" -eq 1 ] && fallback_args+=(--no-detox)
    [ "$DEBUG_MODE" -eq 1 ] && fallback_args+=(--debug)
    exec ./start.sh "${fallback_args[@]}"
  elif [ "$update_status" -ne 0 ]; then
    echo
    echo "Stopping: update.sh failed unexpectedly (exit $update_status)." >&2
    exit "$update_status"
  fi

  if [ "$INCREMENTAL" -eq 0 ]; then
    # ----- Full / clean rebuild: exactly the original --auto behaviour -----
    build_extract_args
    run_step "extract.sh" ./extract.sh "${extract_args[@]+"${extract_args[@]}"}"

    build_merge_args
    run_step "merge.sh" ./merge.sh "${merge_args[@]+"${merge_args[@]}"}"

    build_sort_args
    run_step "sort.sh" ./sort.sh "${sort_args[@]+"${sort_args[@]}"}"
  else
    # ----- Incremental update into an existing $DEST_OPT -----
    # Stage just the newly downloaded files (the same technique quick.sh
    # uses: copy exactly the paths named in update.log, preserving their
    # relative layout, into a SOURCE-only temp dir), extract THAT into a
    # SEPARATE output staging dir, then merge/sort just that small batch,
    # merge its result into the existing output, then a light
    # "--only-missing" artwork pass over the whole thing catches anything
    # pre-existing that's still missing artwork (e.g. from an earlier
    # interrupted run) without re-touching everything that's already merged.
    #
    # The source and output staging dirs MUST be different directories:
    # extract.sh scans its current directory for archives and writes
    # results to wherever -d points - if those were the same directory,
    # the original .lha files would end up sitting alongside (and get
    # merged/duplicated together with) the extracted output.
    TEMP_SRC_DIR="$SCRIPT_DIR/.staging_src_$$"
    STAGING_DIR="$SCRIPT_DIR/.staging_out_$$"
    rm -rf "$TEMP_SRC_DIR" "$STAGING_DIR"
    mkdir -p "$TEMP_SRC_DIR" "$STAGING_DIR"

    STEP_NUM=$((STEP_NUM + 1))
    echo
    echo "===== Step $STEP_NUM of $TOTAL_STEPS: staging new downloads ====="
    staged_any=0
    if [ -f "$SCRIPT_DIR/update.log" ]; then
      while IFS= read -r logline; do
        filepath=$(printf '%s\n' "$logline" | sed 's/^[0-9-]* [0-9:]* //')
        [ -f "$filepath" ] || continue
        relpath="${filepath#./}"
        destpath="$TEMP_SRC_DIR/$relpath"
        mkdir -p "$(dirname "$destpath")"
        cp -f "$filepath" "$destpath" 2>/dev/null && staged_any=1
      done < "$SCRIPT_DIR/update.log"
    fi

    if [ "$staged_any" -eq 0 ]; then
      echo "Nothing to stage - update.log had no readable entries."
      rm -rf "$TEMP_SRC_DIR" "$STAGING_DIR"
    else
      _real_dest="$DEST_OPT"
      DEST_OPT="$STAGING_DIR"

      build_extract_args
      STEP_NUM=$((STEP_NUM + 1))
      echo
      echo "===== Step $STEP_NUM of $TOTAL_STEPS: extract.sh (new files) ====="
      (cd "$TEMP_SRC_DIR" && bash "$SCRIPT_DIR/extract.sh" "${extract_args[@]+"${extract_args[@]}"}")
      rm -rf "$TEMP_SRC_DIR"

      build_merge_args
      run_step "merge.sh (new files)" ./merge.sh "${merge_args[@]+"${merge_args[@]}"}"

      build_sort_args
      run_step "sort.sh (new files)" ./sort.sh "${sort_args[@]+"${sort_args[@]}"}"

      DEST_OPT="$_real_dest"

      echo
      echo "Merging newly processed files into $DEST_OPT..."
      mkdir -p "$DEST_OPT"
      cp -a "$STAGING_DIR/." "$DEST_OPT/"
    fi

    build_merge_args
    run_step "merge.sh (fill missing artwork)" ./merge.sh "${merge_args[@]+"${merge_args[@]}"}" --only-missing

    if [ -d "$STAGING_DIR" ]; then
      new_dir_name="new_${VARIANT_SUFFIX:-all}"
      rm -rf "$new_dir_name"
      mv "$STAGING_DIR" "$new_dir_name"
      echo "New-files duplicate: $new_dir_name"
    fi
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
if [ "${RETROPLAY_ALL_SH:-}" != "1" ]; then
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

exit 0
