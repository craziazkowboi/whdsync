#!/usr/bin/env bash
# retroplay-suite: 2026.11.15.1   (every script in the set must carry the same stamp)
# Remember where the user ran this from, before any cd: retroplay.conf is
# looked for there first (see lib.sh).
RP_INVOKED_FROM="${RP_INVOKED_FROM:-$PWD}"; export RP_INVOKED_FROM
set -uo pipefail

# Amiga Retroplay - Dependency Uninstaller
#
# WHAT THIS SCRIPT DOES:
#   Removes ONLY the specific tools that this suite of scripts (start.sh,
#   extract.sh, sort.sh, update.sh, all.sh) itself auto-installed on your
#   behalf when you answered "y" to one of their install prompts - never
#   anything that was already present on your system before that. Nothing
#   here guesses; it works entirely from a tracking file
#   (.retroplay_installed_deps.log, in the main folder - the one above
#   scripts/ if you use that layout) that each script appends to at the
#   exact moment an install it offered actually succeeds. If that file
#   doesn't mention a package, this script will not touch it, no matter
#   how it got onto your system.
#
#   Every removal is confirmed individually before it happens (skipped
#   automatically with --yes, for scripted/unattended cleanup), and
#   --dry-run lists what would be removed without changing anything.

OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The tracking file lives in the MAIN folder - the one holding artwork/,
# build/ and downloads/ - which is where lib.sh writes it (RP_BASE_DIR). When
# the scripts sit in a scripts/ subfolder that is the folder above this one.
# This used to look beside the scripts only, so after setup.sh had tidied
# them into scripts/ it reported "nothing to uninstall" while the real list
# sat one folder up, untouched. Same rule as lib.sh, kept in step by hand
# because this script deliberately does not load lib.sh: it must still work
# when the rest of the set is broken or half removed.
case "$SCRIPT_DIR" in
    */scripts) BASE_DIR="${SCRIPT_DIR%/scripts}" ;;
    *)         BASE_DIR="$SCRIPT_DIR" ;;
esac
DEP_TRACK_FILE="$BASE_DIR/.retroplay_installed_deps.log"
# A list written beside the scripts (by hand-copied scripts, or any layout
# where the two folders differ) is read as well and folded into the main one,
# so nothing that was recorded can be stranded in either place.
LEGACY_TRACK_FILE=""
if [ "$SCRIPT_DIR" != "$BASE_DIR" ] && [ -s "$SCRIPT_DIR/.retroplay_installed_deps.log" ]; then
    LEGACY_TRACK_FILE="$SCRIPT_DIR/.retroplay_installed_deps.log"
fi

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
            exit 4
            ;;
    esac
done

if [ ! -s "$DEP_TRACK_FILE" ] && [ -z "$LEGACY_TRACK_FILE" ]; then
    echo "Nothing to uninstall: $DEP_TRACK_FILE is missing or empty."
    echo "That means these scripts haven't auto-installed anything on this"
    echo "system yet (or it's already been cleaned up by a previous run of"
    echo "this uninstaller)."
    exit 0
fi

echo "Reading tracked installs from: $DEP_TRACK_FILE"
[ -n "$LEGACY_TRACK_FILE" ] && echo "                          and: $LEGACY_TRACK_FILE"
echo

# Read into an array up front (rather than looping directly over the file)
# since removal further down rewrites the tracking file after each
# successful item, and iterating a live file while rewriting it partway
# through is exactly the kind of thing that skips or repeats lines.
tracked_lines=()
for _tf in "$DEP_TRACK_FILE" "$LEGACY_TRACK_FILE"; do
    [ -n "$_tf" ] && [ -f "$_tf" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        # The same entry in both files is one install, removed once.
        _dup=0
        for _seen in "${tracked_lines[@]+"${tracked_lines[@]}"}"; do
            [ "$_seen" = "$line" ] && { _dup=1; break; }
        done
        [ "$_dup" -eq 0 ] && tracked_lines+=("$line")
    done < "$_tf"
done
unset _tf _dup _seen

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
# Also done when there are two lists, even if nothing was removed: what is
# left is written to the main one and the stray copy goes.
if [ "${#removed_lines[@]}" -gt 0 ] || [ -n "$LEGACY_TRACK_FILE" ]; then
    remaining=()
    for line in "${tracked_lines[@]}"; do
        is_removed=0
        for removed in "${removed_lines[@]+"${removed_lines[@]}"}"; do
            [ "$line" = "$removed" ] && is_removed=1 && break
        done
        [ "$is_removed" -eq 0 ] && remaining+=("$line")
    done

    if [ "${#remaining[@]}" -eq 0 ]; then
        rm -f -- "$DEP_TRACK_FILE"
    else
        printf '%s\n' "${remaining[@]}" > "$DEP_TRACK_FILE"
    fi
    [ -n "$LEGACY_TRACK_FILE" ] && rm -f -- "$LEGACY_TRACK_FILE"
fi

echo
echo "Done. Removed ${#removed_lines[@]} of ${#tracked_lines[@]} tracked item(s)."
if [ "$skipped_any" -eq 1 ]; then
    echo "Some items were skipped or failed - re-run this script to retry them."
fi
