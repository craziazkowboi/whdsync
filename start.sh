#!/usr/bin/env bash

# Amiga Retroplay Archive Minimal CLI Dispatcher
# Copyright (c) 2025 Craziazkowboi
# License: Creative Commons BY‑NC 4.0 International

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

version="1.2.3 macOS 10.15.7 Compatible (no color)"

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
  case "$1" in
    -h|--help)
      echo
      echo "Amiga Retroplay Archive Minimal CLI Dispatcher"
      echo "Version: ${version}"
      echo
      echo "Usage: $(basename "$0") [options]"
      echo
      echo "Options:"
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
      echo "  --ecs-lo              Run merge.sh with --ecs-lo (matches iGame_ECS_Lo)."
      echo "  --aga-lo              Run merge.sh with --aga-lo (matches iGame_AGA_Lo)."
      echo "  --set [name]          Run merge.sh with --set NAME (any iGame_NAME directory)."
      echo "  --ffs                 Run sort.sh with --ffs (FFS filename limits)."
      echo "  --pfs                 Run sort.sh with --pfs (PFS filename limits, default)."
      echo "  --dest [path]         Set custom destination directory."
      echo "  --art [order]         Set merge priority order for non-demos (e.g., Screens,Covers,Titles)."
      echo "  --demo-art [order]    Set merge priority order for demos (e.g., Titles,Screens,Covers)."
      echo "  --no-detox            Skip detox entirely - the startup dependency check and"
      echo "                        the pre-clean step in sort.sh."
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
    --ecs-lo)
      MERGE_OPT="--ecs-lo"
      shift
      ;;
    --aga-lo)
      MERGE_OPT="--aga-lo"
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
    --debug)
      DEBUG_MODE=1
      shift
      ;;
    --exit)
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

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
  echo "  0) Exit"
  echo

  printf "Enter choice [0-6]: "
  read -r menu_choice

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
    0|"")
      echo "Exiting."
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
  [ "$DEBUG_MODE" -eq 1 ] && merge_args+=(--debug)
  return 0
}

# Build the sort.sh argument list. sort.sh tolerates an empty SORT_OPT.
build_sort_args() {
  sort_args=()
  [ -n "$SORT_OPT" ] && sort_args+=("$SORT_OPT")
  [ -n "$DEST_OPT" ] && sort_args+=(--dest "$DEST_OPT")
  [ "$NO_DETOX" -eq 1 ] && sort_args+=(--no-detox)
  return 0
}

# Build the extract.sh argument list.
build_extract_args() {
  extract_args=()
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
if [ "$ACTION" = "auto" ]; then
  build_extract_args
  run_sub ./update.sh
  run_sub ./extract.sh "${extract_args[@]}"

  build_merge_args
  run_sub ./merge.sh "${merge_args[@]}"

  build_sort_args
  run_sub ./sort.sh "${sort_args[@]}"

elif [ "$ACTION" = "merge" ]; then
  build_merge_args
  run_sub ./merge.sh "${merge_args[@]}"

elif [ "$ACTION" = "update" ]; then
  run_sub ./update.sh
elif [ "$ACTION" = "extract" ]; then
  build_extract_args
  run_sub ./extract.sh "${extract_args[@]}"
elif [ "$ACTION" = "sort" ]; then
  build_sort_args
  run_sub ./sort.sh "${sort_args[@]}"
elif [ "$ACTION" = "quick" ]; then
  build_quick_args
  run_sub ./quick.sh "${quick_args[@]}"
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

# Find candidate log files (adjust pattern if needed)
log_files=()
while IFS= read -r -d '' f; do
    log_files+=("$f")
done < <(find . -maxdepth 1 -type f -name "*.log" -print0 2>/dev/null)

# Delete 0‑byte log files and keep non‑empty ones for merging
non_empty_logs=()
for f in "${log_files[@]}"; do
    if [ ! -s "$f" ]; then
        rm -f -- "$f"
    else
        non_empty_logs+=("$f")
    fi
done

# Merge remaining logs into retroerror.log with section headers
retro_log="retroerror.log"
: > "$retro_log"
for f in "${non_empty_logs[@]}"; do
    {
        printf '===== %s =====\n' "$(basename "$f")"
        cat "$f"
        printf '\n\n'
    } >> "$retro_log"
done

# Delete all log files except the merged $retro_log in the start directory
if [ -s "$retro_log" ]; then
  for f in ./*.log; do
    [ "$f" = "./$retro_log" ] && continue
    [ -e "$f" ] || continue
    rm -f -- "$f"
  done
fi

# Ask user whether to view or delete the error log (default: view)
if [ -s "$retro_log" ]; then
    echo
    echo "Error log has been written to: $retro_log"
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
fi

exit 0
