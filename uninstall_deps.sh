#!/usr/bin/env bash
set -uo pipefail

# Amiga Retroplay - Dependency Uninstaller
#
# WHAT THIS SCRIPT DOES:
#   Removes ONLY the specific tools that this suite of scripts (start.sh,
#   extract.sh, sort.sh, update.sh, all.sh) itself auto-installed on your
#   behalf when you answered "y" to one of their install prompts - never
#   anything that was already present on your system before that. Nothing
#   here guesses; it works entirely from a tracking file
#   (.retroplay_installed_deps.log) that each script appends to at the
#   exact moment an install it offered actually succeeds. If that file
#   doesn't mention a package, this script will not touch it, no matter
#   how it got onto your system.
#
#   Every removal is confirmed individually before it happens (skipped
#   automatically with --yes, for scripted/unattended cleanup), and
#   --dry-run lists what would be removed without changing anything.

OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEP_TRACK_FILE="$SCRIPT_DIR/.retroplay_installed_deps.log"

ASSUME_YES=0
DRY_RUN=0

print_help() {
    echo "Amiga Retroplay - Dependency Uninstaller"
    echo
    echo "Usage: $(basename "$0") [--yes] [--dry-run] [-h|--help]"
    echo
    echo "Removes only the tools this suite of scripts itself installed for you"
    echo "(tracked in .retroplay_installed_deps.log) - never anything that was"
    echo "already on your system before these scripts touched anything."
    echo
    echo "Options:"
    echo "  --yes, -y     Remove everything tracked without asking per item"
    echo "                (still skipped entirely if the tracking file is empty"
    echo "                or missing - there is never anything to force-remove"
    echo "                beyond what's actually listed there)."
    echo "  --dry-run     List what would be removed and how, without removing"
    echo "                anything or modifying the tracking file."
    echo "  -h, --help    Show this help message."
    echo
    echo "After a successful removal, that entry is deleted from"
    echo "$DEP_TRACK_FILE so re-running this script later never tries to"
    echo "remove the same thing twice."
}

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y) ASSUME_YES=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) print_help; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

if [ ! -s "$DEP_TRACK_FILE" ]; then
    echo "Nothing to uninstall: $DEP_TRACK_FILE is missing or empty."
    echo "That means these scripts haven't auto-installed anything on this"
    echo "system yet (or it's already been cleaned up by a previous run of"
    echo "this uninstaller)."
    exit 0
fi

echo "Reading tracked installs from: $DEP_TRACK_FILE"
echo

# Read into an array up front (rather than looping directly over the file)
# since removal further down rewrites the tracking file after each
# successful item, and iterating a live file while rewriting it partway
# through is exactly the kind of thing that skips or repeats lines.
tracked_lines=()
while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && tracked_lines+=("$line")
done < "$DEP_TRACK_FILE"

if [ "${#tracked_lines[@]}" -eq 0 ]; then
    echo "Nothing to uninstall: the tracking file has no entries."
    exit 0
fi

removed_lines=()
skipped_any=0

for line in "${tracked_lines[@]}"; do
    method="${line%%:*}"
    name="${line#*:}"

    case "$method" in
        apt)
            action_desc="remove the apt package '$name' (sudo apt-get remove -y $name)"
            ;;
        brew)
            action_desc="uninstall the Homebrew package '$name' (brew uninstall $name)"
            ;;
        source-build)
            action_desc="delete the file '$name' (installed by a from-source build)"
            ;;
        *)
            echo "Skipping unrecognized tracking entry: $line" >&2
            skipped_any=1
            continue
            ;;
    esac

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] Would $action_desc"
        continue
    fi

    proceed=0
    if [ "$ASSUME_YES" -eq 1 ]; then
        proceed=1
    elif [ -t 0 ]; then
        printf 'Would %s. Proceed? [y/N] ' "$action_desc"
        read -r reply
        case "$reply" in
            [Yy]*) proceed=1 ;;
            *) proceed=0 ;;
        esac
    else
        echo "No terminal attached and --yes not given - skipping: $action_desc" >&2
        skipped_any=1
        continue
    fi

    if [ "$proceed" -ne 1 ]; then
        echo "Skipped: $name"
        skipped_any=1
        continue
    fi

    success=0
    case "$method" in
        apt)
            if [[ "$OS_TYPE" == "darwin" ]]; then
                echo "ERROR: tracking entry '$line' is an apt package, but this is macOS - skipping." >&2
                skipped_any=1
                continue
            fi
            if sudo apt-get remove -y "$name"; then
                success=1
            fi
            ;;
        brew)
            if brew uninstall "$name"; then
                success=1
            fi
            ;;
        source-build)
            if sudo rm -f -- "$name"; then
                success=1
            fi
            ;;
    esac

    if [ "$success" -eq 1 ]; then
        echo "Removed: $name"
        removed_lines+=("$line")
    else
        echo "Failed to remove: $name (left in the tracking file for a retry)" >&2
        skipped_any=1
    fi
done

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "Dry run complete - nothing was actually removed."
    exit 0
fi

# Rewrite the tracking file with only the lines that were NOT successfully
# removed (failures and skips stay, so a later run can retry them).
if [ "${#removed_lines[@]}" -gt 0 ]; then
    remaining=()
    for line in "${tracked_lines[@]}"; do
        is_removed=0
        for removed in "${removed_lines[@]}"; do
            [ "$line" = "$removed" ] && is_removed=1 && break
        done
        [ "$is_removed" -eq 0 ] && remaining+=("$line")
    done

    if [ "${#remaining[@]}" -eq 0 ]; then
        rm -f -- "$DEP_TRACK_FILE"
    else
        printf '%s\n' "${remaining[@]}" > "$DEP_TRACK_FILE"
    fi
fi

echo
echo "Done. Removed ${#removed_lines[@]} of ${#tracked_lines[@]} tracked item(s)."
if [ "$skipped_any" -eq 1 ]; then
    echo "Some items were skipped or failed - re-run this script to retry them."
fi
