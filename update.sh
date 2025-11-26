#!/bin/bash

# Requirements: bash, wget

IFS=$'\n'

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

# Calculate max width needed for progress messages
maxlen=0
for dir in "${dirs[@]}"; do
    msg="Checking for updates in: $dir"
    [ ${#msg} -gt $maxlen ] && maxlen=${#msg}
done

for dir in "${dirs[@]}"
do
    mkdir -p "$dir" > /dev/null || exit 1

    # Print padded initial progress message before download
    printf "%-${maxlen}s" "Checking for updates in: $dir"

    # Record all existing files before download, sorted
    find "$dir" -type f | sort > before.txt

    pushd "$dir" > /dev/null || exit 1

    dirtemp="Commodore_Amiga_-_${dir//\//_-_}"
    dirpath="${dirtemp// /_}"

    # Make sure wget is installed; if not, print warning
    if ! command -v wget > /dev/null; then
        echo "Error: wget not found. Please install wget before running this script."
        exit 2
    fi

    wget -q --mirror -np -nH --cut-dirs=2 "ftp://ftp:amiga@grandis.nu/Retroplay%20WHDLoad%20Packs/$dirpath" > /dev/null

    popd > /dev/null || exit 1

    # Record all files after download, sorted
    find "$dir" -type f | sort > after.txt

    # Identify new files and count them
    new_files=0
    while read nf; do
        if [ -n "$nf" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $nf" >> "$logfile"
            new_files=$((new_files + 1))
        fi
    done < <(comm -13 before.txt after.txt)

    # Move cursor to start of line and re-print with count, lined up
    printf "\r%-${maxlen}s | %d new files\n" "Checking for updates in: $dir" "$new_files"

    rm -f before.txt after.txt
done

# Format elapsed time: hours:minutes:seconds
hh=$((SECONDS/3600))
mm=$(((SECONDS%3600)/60))
ss=$((SECONDS%60))

printf "Elapsed time: %02d:%02d:%02d\n" "$hh" "$mm" "$ss"
logpath="$(cd "$(dirname "$logfile")" && pwd)"
echo "See $logpath/$logfile for details"
