#!/usr/bin/env bash

# Amiga Retroplay Archive Minimal CLI Dispatcher
# Copyright (c) 2025 Craziazkowboi
# License: Creative Commons BY‑NC 4.0 International

script_start_time=$(date +%s)
ORIG_PWD=$(pwd)
ulimit -n 16384
set -euo pipefail
version="1.2.2 macOS 10.15.7 Compatible (no color)"

ACTION=""
MERGE_OPT=""
SORT_OPT=""
DEST_OPT=""
MENU_DEST_OVERRIDE=""

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
            echo "  -h, --help           Show this help and exit."
            echo "  --auto               Run full automation: update, extract, merge, sort."
            echo "  --update             Only update archives."
            echo "  --extract            Only extract archives."
            echo "  --merge              Only merge artwork."
            echo "  --sort               Only sort languages."
            echo "  --quick              Only process new files (quick.sh)."
            echo "  --ecs                Run merge.sh with --ecs."
            echo "  --aga                Run merge.sh with --aga."
            echo "  --rtg                Run merge.sh with --rtg."
            echo "  --ffs                Run sort.sh with --ffs."
            echo "  --pfs                Run sort.sh with --pfs."
            echo "  --dest [path]        Set custom destination directory."
            echo "  --exit               Exit immediately."
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
        --exit)
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

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
        echo " 1. Edit /etc/locale.gen and uncomment/add:"
        echo "    C.UTF-8 UTF-8"
        echo "    en_US ISO-8859-1"
        echo " 2. Run:"
        echo "    sudo locale-gen"
        echo "    sudo dpkg-reconfigure locales"
        echo "For other Linux distributions:"
        echo " - Refer to your system's locale documentation"
        echo " - Make sure language packs are installed and regenerate locales"
        exit 1
    fi
fi

# Main dispatcher logic (examples)
if [ "$ACTION" = "auto" ]; then
    ./update.sh
    ./extract.sh
    ./merge.sh $MERGE_OPT
    ./sort.sh $SORT_OPT --dest "${DEST_OPT:-}"
elif [ "$ACTION" = "update" ]; then
    ./update.sh
elif [ "$ACTION" = "extract" ]; then
    ./extract.sh
elif [ "$ACTION" = "merge" ]; then
    ./merge.sh $MERGE_OPT
elif [ "$ACTION" = "sort" ]; then
    ./sort.sh $SORT_OPT --dest "${DEST_OPT:-}"
elif [ "$ACTION" = "quick" ]; then
    ./quick.sh
fi

exit 0
