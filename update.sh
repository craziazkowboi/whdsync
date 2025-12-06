#!/bin/bash

# Requirements: bash, wget

# Check for iGame / TinyLauncher artwork directories in current directory
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
