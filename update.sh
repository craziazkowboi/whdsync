#!/bin/bash

# Amiga Retroplay - Update Script
#
# WHAT THIS SCRIPT DOES:
#   Mirrors the configured set of WHDLoad/HD_Loaders/JST directories from
#   the Retroplay FTP server, keeping only what's changed since last time
#   (wget --mirror skips anything already up to date). It then works out
#   exactly which files were newly added this run (by diffing a directory
#   listing taken before the download against one taken after), logs each
#   new file with a timestamp to update.log, and prints a per-directory and
#   grand-total count of new files.
#
#   This is the "check for updates" step of the pipeline - it does not
#   extract, merge artwork, or sort anything; that's extract.sh, merge.sh
#   and sort.sh respectively. quick.sh and start.sh --auto both call this
#   script first, before moving on to those later steps.
#
# Requirements: bash, wget

OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"

# ----- wget dependency check, with an offer to auto-install if missing -----
if ! command -v wget >/dev/null 2>&1; then
    echo "wget is not installed (required to download update archives)."
    if [ -t 0 ]; then
        if [[ "$OS_TYPE" == "darwin" ]]; then
            printf 'Install it now via Homebrew (brew install wget)? [y/N] '
        else
            printf 'Install it now via apt (sudo apt install wget)? [y/N] '
        fi
        read -r reply
        case "$reply" in
            [Yy]*)
                if [[ "$OS_TYPE" == "darwin" ]]; then
                    brew install wget
                else
                    sudo apt-get update && sudo apt-get install -y wget
                fi
                ;;
        esac
    fi
    if ! command -v wget >/dev/null 2>&1; then
        echo "Error: wget not found. Please install wget before running this script."
        exit 2
    fi
fi

# Check for iGame / TinyLauncher artwork directories in current directory.
# This is only a heads-up, not a hard requirement of THIS script (update.sh
# only downloads WHDLoad/HD_Loaders/JST content) - it's here because if
# these are missing, the later merge.sh step in the same pipeline run will
# have nothing to merge, and it's more useful to warn about that now than
# to let the user discover it after a long download.
required_art_dirs=(
  "iGame_art"
  "iGame_ECS"
  "iGame_RTG"
  "iGame_AGA"
  "TinyLauncher"
)

missing_art=0
for d in "${required_art_dirs[@]}"; do
  if [ ! -d "./$d" ]; then
    missing_art=1
    break
  fi
done

if [ "$missing_art" -ne 0 ]; then
  echo "One or more iGame/TinyLauncher artwork directories (iGame_art, iGame_ECS, iGame_RTG, iGame_AGA, TinyLauncher) are missing in the directory where this script is run."
  echo "iGame artwork packs can be downloaded from:"
  echo "  https://eab.abime.net/showthread.php?t=106096"
  echo
  # Uncomment the next line if you want to force setting up artwork before running:
  # exit 1
fi

dirs=(
    "HD_Loaders/Games"
    "JST/Games"
    # "WHDLoad/Games/Beta & Unreleased"
    "WHDLoad/Magazines"
    "WHDLoad/Demos"
    "WHDLoad/Games"
)
SECONDS=0
logfile="update.log"
: > "$logfile"
failed_dirs=()
total_new_files=0   # grand total across every directory, printed in the final summary
pruned_count=0      # superseded archives removed (see loop below for the logic)

# Calculate max width needed for progress messages
maxlen=0
for dir in "${dirs[@]}"; do
    msg="Checking for updates in: $dir"
    [ ${#msg} -gt $maxlen ] && maxlen=${#msg}
done

# One pass per configured directory: mirror it from the remote FTP server,
# then diff the file list from before/after that mirror to find out what's
# genuinely new (wget's own mirror mode doesn't tell us this directly).
for dir in "${dirs[@]}"
do
    mkdir -p "$dir" > /dev/null || exit 1

    # Print padded initial progress message before download
    printf "%-${maxlen}s" "Checking for updates in: $dir"

    # Snapshot of what's already on disk, BEFORE downloading anything, so
    # we can later tell "already had it" apart from "wget just fetched it".
    find "$dir" -type f | sort > before.txt

    pushd "$dir" > /dev/null || exit 1

    # The remote WHDLoad pack path mirrors our local directory name, just
    # with spaces turned to underscores and a "Commodore_Amiga_-_" prefix,
    # and "/" swapped for "_-_" (e.g. "WHDLoad/Games" -> ..._-_WHDLoad_-_Games).
    dirtemp="Commodore_Amiga_-_${dir//\//_-_}"
    dirpath="${dirtemp// /_}"

    # --mirror recurses and only re-fetches files that changed on the
    # server (by size/date), so re-running this is safe and cheap when
    # nothing new has been published. -np/-nH/--cut-dirs=2 keep the local
    # layout flat instead of recreating the whole remote path structure.
    wget -q --mirror -np -nH --cut-dirs=2 "ftp://ftp:amiga@grandis.nu/Retroplay%20WHDLoad%20Packs/$dirpath" > /dev/null
    wget_status=$?

    popd > /dev/null || exit 1

    # Snapshot again AFTER downloading, so the before/after diff below
    # shows exactly what the mirror added.
    find "$dir" -type f | sort > after.txt

    # `comm -13` prints lines that are ONLY in the second file (after.txt),
    # i.e. genuinely new since the "before" snapshot - exactly the files
    # this run added, regardless of how many already existed.
    new_files=0
    while IFS= read -r nf; do
        if [ -n "$nf" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $nf" >> "$logfile"
            new_files=$((new_files + 1))

            # Prune superseded archives: if a NEW archive just landed here,
            # any OTHER archive in the same directory for the SAME GAME is
            # an older release the server has since replaced with this one.
            #
            # IMPORTANT: this must match on game name, not just "same
            # directory" - Retroplay's actual layout buckets many different
            # games together by first letter (e.g. everything in
            # WHDLoad/Games/S/ is every S-game as flat files, not one
            # per-game folder), so "same directory" alone is nowhere near
            # enough - it would (and did) delete unrelated games that just
            # happen to start with the same letter as whatever was new.
            # The game name is taken as everything before the first
            # "_v<digit>" version marker in the filename (e.g.
            # "Superfrog_v1.9_0035.lha" -> "Superfrog"); a filename with no
            # such marker is its own whole name, matched only against
            # itself.
            game_dir="$(dirname "$nf")"
            new_base="$(basename "$nf")"
            new_base="${new_base%.*}"
            new_base="${new_base%%_[Vv][0-9]*}"
            while IFS= read -r -d '' old_archive; do
                if [ "$old_archive" != "$nf" ]; then
                    old_base="$(basename "$old_archive")"
                    old_base="${old_base%.*}"
                    old_base="${old_base%%_[Vv][0-9]*}"
                    if [ "$old_base" = "$new_base" ]; then
                        rm -f "$old_archive"
                        echo "$(date '+%Y-%m-%d %H:%M:%S') REMOVED (superseded by $nf): $old_archive" >> "$logfile"
                        pruned_count=$((pruned_count + 1))
                    fi
                fi
            done < <(find "$game_dir" -maxdepth 1 -type f \( -iname "*.lha" -o -iname "*.lzx" -o -iname "*.zip" \) -print0 2>/dev/null)
        fi
    done < <(comm -13 before.txt after.txt)

    # A failed wget with 0 "new files" looks identical to "already up to
    # date" unless we check its exit status - report the failure instead
    # of silently moving on.
    if [ "$wget_status" -ne 0 ]; then
        printf "\r%-${maxlen}s | wget FAILED (exit %d) - check network/server\n" "Checking for updates in: $dir" "$wget_status"
        failed_dirs+=("$dir")
    else
        # Move cursor to start of line and re-print with count, lined up
        printf "\r%-${maxlen}s | %d new files\n" "Checking for updates in: $dir" "$new_files"
        total_new_files=$((total_new_files + new_files))
    fi

    rm -f before.txt after.txt
done

# Format elapsed time: hours:minutes:seconds
hh=$((SECONDS/3600))
mm=$(((SECONDS%3600)/60))
ss=$((SECONDS%60))

# Exit code carries the outcome for a calling script (e.g. start.sh --auto)
# to react to, since these three cases call for different next steps:
#   3 = a wget error occurred - stop, don't trust "0 new" as meaningful,
#       and don't continue into extract/merge/sort.
#   2 = genuinely nothing new anywhere, no errors - nothing to process.
#   0 = at least one new file was found - proceed as normal.
# wget failures are checked FIRST and take priority over the "nothing new"
# case: a failed check means "0 new" there isn't trustworthy information,
# not a confirmed up-to-date state.
if [ "${#failed_dirs[@]}" -gt 0 ]; then
    echo
    echo "ERROR: wget failed for ${#failed_dirs[@]} director(y/ies):" >&2
    printf '  %s\n' "${failed_dirs[@]}" >&2
    echo "Check your network connection and re-run update.sh. Stopping - not" >&2
    echo "continuing with extract/merge/sort." >&2
    exit 3
fi

if [ "$total_new_files" -eq 0 ]; then
    echo
    echo "No new archives available for download.  If you only want to merge"
    echo "artwork/sort your archive, then try:"
    echo
    echo "start.sh - will give you a menu of options"
    echo "merge.sh - merge artwork only"
    echo "sort.sh  - sort your archive into categories"
    echo
    echo "Have a nice day :)"
    exit 2
fi

echo
echo "Total new files across all directories: $total_new_files"
if [ "$pruned_count" -gt 0 ]; then
    echo "Superseded archives removed: $pruned_count (see $logfile for which ones)"
fi
printf "Elapsed time: %02d:%02d:%02d\n" "$hh" "$mm" "$ss"
logpath="$(cd "$(dirname "$logfile")" && pwd)"
echo "See $logpath/$logfile for details"
exit 0
