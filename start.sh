#!/usr/bin/env bash

# Amiga Retroplay Archive Minimal CLI Dispatcher
# Copyright (c) 2025 Craziazkowboi
# License: Creative Commons BY‑NC 4.0 International

script_start_time=$(date +%s)
ORIG_PWD=$(pwd)
NEW_DIR="${ORIG_PWD}/new"

ulimit -n 16384

# DO NOT set -e here - we need to parse options first
set -uo pipefail

version="1.2.2 macOS 10.15.7 Compatible (no color)"

ACTION=""
MERGE_OPT=""
SORT_OPT=""
DEST_OPT=""
ART_ORDER_OPT=""
MENU_DEST_OVERRIDE=""
DEBUG_MODE=0

# Basic environment / colors (no color for now)
OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"
RED=""
NC=""

# ----- Tool dependency check (lha, 7z, unar detox) -----
missing=()
for tool in lha 7z unar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing+=("$tool")
    fi
done

if [ ${#missing[@]} -ne 0 ]; then
    echo "Missing tools: ${missing[*]}"
    if [[ "$OS_TYPE" == "darwin" ]]; then
        echo "Install via Homebrew (macOS): brew install lha p7zip unar detox"
        echo "Also: brew install coreutils (for greadlink)"
    else
        echo "Or via apt (Linux): sudo apt install lhasa p7zip-full unar"
    fi
    exit 1
fi

# ----- unlzx check and detailed help -----
if ! command -v unlzx >/dev/null 2>&1; then
    echo "ERROR: 'unlzx' is not installed or not in PATH."
    echo
    echo "unlzx is required to extract LZX archives used by Retroplay sets."
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
if [[ "$OS_TYPE" != "darwin" ]]; then
  if command -v detox >/dev/null 2>&1; then
    DETOX_VER_RAW="$(detox -V 2>/dev/null || true)"
    DETOX_VER="$(printf '%s\n' "$DETOX_VER_RAW" | sed -n 's/[^0-9]*\([0-9]\+\.[0-9]\+\).*/\1/p')"

    if [ -z "$DETOX_VER" ] || awk "BEGIN{exit !($DETOX_VER < 3.0)}"; then
      echo "Detected detox version '$DETOX_VER_RAW' (need 3.0 or greater)."
      echo "Install Detox 3.0.1 on Debian 12/A314 with:"
      echo "  sudo apt install -y git autoconf automake bison flex gcc make pkg-config"
      echo "  wget https://github.com/dharple/detox/releases/download/v3.0.1/detox-3.0.1.tar.gz"
      echo "  tar xzf detox-3.0.1.tar.gz"
      echo "  cd detox-3.0.1"
      echo "  ./configure"
      echo "  make"
      echo "  sudo make install"
      echo "  detox -V"
      exit 1
    fi
  else
    echo "detox not found on this Debian/A314 system."
    echo "Install Detox 3.0.1 with:"
    echo "  sudo apt install -y git autoconf automake bison flex gcc make pkg-config"
    echo "  wget https://github.com/dharple/detox/releases/download/v3.0.1/detox-3.0.1.tar.gz"
    echo "  tar xzf detox-3.0.1.tar.gz"
    echo "  cd detox-3.0.1"
    echo "  ./configure"
    echo "  make"
    echo "  sudo make install"
    echo "  detox -V"
    exit 1
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
      echo "  --ffs                 Run sort.sh with --ffs."
      echo "  --pfs                 Run sort.sh with --pfs."
      echo "  --dest [path]         Set custom destination directory."
      echo "  --art [order]   Set merge priority order (e.g., Screens,Covers,Titles)."
      echo "  --debug               Enable debug output."
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
    --ffs)
      SORT_OPT="--ffs"
      shift
      ;;
    --pfs)
      SORT_OPT="--pfs"
      shift
      ;;
    --dest)
      DEST_OPT="$2"
      shift 2
      ;;
    --art)
      ART_ORDER_OPT="$2"
      shift 2
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
  local script_name="$1"
  if [ ! -f "$script_name" ]; then
    echo "ERROR: Required script not found: $script_name"
    echo "Current directory: $(pwd)"
    exit 1
  fi
  if [ ! -x "$script_name" ]; then
    echo "ERROR: Script is not executable: $script_name"
    echo "Run: chmod +x $script_name"
    exit 1
  fi
}

# ----- Helper function: Run subscript with debug output -----
run_sub() {
  local script_name="$1"
  shift  # Remove script name, keep remaining args

  if [ "$DEBUG_MODE" -eq 1 ]; then
    echo "[DEBUG] Running: $script_name $*"
  fi

check_script "$script_name"
# If ACTION is 'quick', append -d "$NEW_DIR" to the call
if [ "$ACTION" = "quick" ]; then
"$script_name" "$@" -d "$NEW_DIR"
else
"$script_name" "$@"
fi

}

# Main dispatcher logic
if [ "$ACTION" = "auto" ]; then
  run_sub ./update.sh
  run_sub ./extract.sh
  run_sub ./merge.sh "$MERGE_OPT" --art "$ART_ORDER_OPT"
  run_sub ./sort.sh "$SORT_OPT" --dest "${DEST_OPT:-}"
elif [ "$ACTION" = "update" ]; then
  run_sub ./update.sh
elif [ "$ACTION" = "extract" ]; then
  run_sub ./extract.sh
elif [ "$ACTION" = "merge" ]; then
  run_sub ./merge.sh "$MERGE_OPT" --art "$ART_ORDER_OPT"
elif [ "$ACTION" = "sort" ]; then
  run_sub ./sort.sh "$SORT_OPT" --dest "${DEST_OPT:-}"
elif [ "$ACTION" = "quick" ]; then
  run_sub ./quick.sh
else
  echo
  echo "No valid action resolved. Use -h or --help to see available options."
  echo
  exit 1
fi

# ----- Post-run log handling -----

# Work in the directory the script was started from
cd "$ORIG_PWD" || true

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
