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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Always work from this script's own directory: the mirrored archive
# folders (HD_Loaders/, JST/, WHDLoad/) and update.log must live next to
# the other scripts, which is where start.sh/quick.sh/extract.sh look for
# them. Without this, running update.sh from another directory would start
# mirroring the whole archive there, and write an update.log that none of
# the other scripts would ever see.
cd "$SCRIPT_DIR" || { echo "ERROR: cannot cd to script directory: $SCRIPT_DIR" >&2; exit 1; }

# Shared helpers (retroplay.conf settings, dependency tracking, pending
# queues, disk-space checks...) live in lib.sh, next to this script.
if [ ! -f "$SCRIPT_DIR/lib.sh" ]; then
    echo "ERROR: lib.sh is missing from $SCRIPT_DIR - it ships with these scripts." >&2
    exit 1
fi
. "$SCRIPT_DIR/lib.sh"
rp_load_config

DRY_RUN=0
for _arg in "$@"; do
    case "$_arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--dry-run]"
            echo "  Mirrors the Retroplay WHDLoad packs from the FTP server, logs new"
            echo "  files to update.log and queues them for processing."
            echo "  --dry-run  Ask the server what WOULD be downloaded, without downloading."
            echo "Exit codes: 0 = new files, 2 = nothing new, 3 = server/network error."
            exit 0 ;;
        *) echo "Unknown option: $_arg (try --help)" >&2; exit 1 ;;
    esac
done
unset _arg

FTP_BASE="ftp://ftp:amiga@grandis.nu/Retroplay%20WHDLoad%20Packs"

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
                    _had=0; pkg_already_installed brew wget && _had=1
                    brew install wget && [ "$_had" -eq 0 ] && record_installed_dep "brew" "wget"
                else
                    _had=0; pkg_already_installed apt wget && _had=1
                    sudo apt-get update && sudo apt-get install -y wget && [ "$_had" -eq 0 ] && record_installed_dep "apt" "wget"
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
# Remote name for a local directory: "WHDLoad/Games" is published as
# "Commodore_Amiga_-_WHDLoad_-_Games" (spaces to underscores, "/" to "_-_").
remote_dir_for() {
    local t="Commodore_Amiga_-_${1//\//_-_}"
    printf '%s' "${t// /_}"
}

# Lists file names in one remote FTP directory (one per line). Uses curl's
# plain name listing when available, otherwise parses the HTML index wget
# builds for FTP directories.
remote_list() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsS -l -m 120 "$1/" 2>/dev/null | tr -d '\r'
    else
        wget -q -T 120 -O - "$1/" 2>/dev/null | \
            grep -o 'href="[^"]*"' | sed 's/^href="//; s/"$//; s|/$||; s|.*/||'
    fi
}

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run: asking the server what would be downloaded (nothing is changed)."
    echo "This compares file NAMES only, so it's an estimate: a file that was"
    echo "re-published under the same name wouldn't show up here."
    echo
    dry_total=0; dry_failed=0
    for dir in "${dirs[@]}"; do
        url="$FTP_BASE/$(remote_dir_for "$dir")"
        top="$(remote_list "$url")"
        if [ -z "$top" ]; then
            printf '  %-20s could not read the server listing\n' "$dir"
            dry_failed=1; continue
        fi
        missing=0; examples=""
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            case "$entry" in
                .|..) continue ;;
                *.lha|*.LHA|*.lzx|*.LZX|*.zip|*.ZIP) files="$entry"; sub="" ;;
                *) sub="$entry"; files="$(remote_list "$url/$sub")" ;;
            esac
            while IFS= read -r fname; do
                case "$fname" in *.lha|*.LHA|*.lzx|*.LZX|*.zip|*.ZIP) ;; *) continue ;; esac
                if [ -n "$sub" ]; then rel="$dir/$sub/$fname"; else rel="$dir/$fname"; fi
                if [ ! -e "$rel" ]; then
                    missing=$((missing + 1))
                    [ "$missing" -le 5 ] && examples="$examples      $rel
"
                fi
            done <<< "$files"
        done <<< "$top"
        printf '  %-20s %d new file(s)\n' "$dir" "$missing"
        [ -n "$examples" ] && printf '%s' "$examples"
        [ "$missing" -gt 5 ] && echo "      ...and $((missing - 5)) more"
        dry_total=$((dry_total + missing))
    done
    echo
    echo "Would download about $dry_total file(s)."
    [ "$dry_failed" -eq 1 ] && exit 3
    [ "$dry_total" -eq 0 ] && exit 2
    exit 0
fi

# Folders built by older versions of these scripts are adopted now, so
# anything downloaded below gets queued for them too.
rp_adopt_configured_variants

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
    dirpath="$(remote_dir_for "$dir")"

    # --mirror recurses and only re-fetches files that changed on the
    # server (by size/date), so re-running this is safe and cheap when
    # nothing new has been published. -np/-nH/--cut-dirs=2 keep the local
    # layout flat instead of recreating the whole remote path structure.
    wget -q --mirror -np -nH --cut-dirs=2 "$FTP_BASE/$dirpath" > /dev/null
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
            # Queue it for every finished output folder; it stays queued
            # until that folder has actually absorbed it (see lib.sh).
            rp_queue_new_archive "$nf"

            # Prune superseded archives. An existing archive is only an
            # older version of the new one when their names are IDENTICAL
            # apart from the version field (see rp_archive_version_key in
            # lib.sh) AND its version is strictly lower (1.10 > 1.9 > 1.1).
            # So _AGA / _CD32 / _HD / _68040 releases of the same game are
            # separate files and are never touched, and an equal or newer
            # version is never removed. Pruned archives are quarantined in
            # old/, not deleted.
            new_kv="$(rp_archive_version_key "$nf")"
            exempt_file="$(rp_prune_exempt_file)"
            # Came back after being quarantined? Then the server still has
            # it - exempt it from pruning so it isn't re-downloaded and
            # removed again on every run.
            if ls old/*/"$nf" >/dev/null 2>&1 && ! grep -qxF "$nf" "$exempt_file" 2>/dev/null; then
                rp_state_init
                printf '%s\n' "$nf" >> "$exempt_file"
                echo "$(date '+%Y-%m-%d %H:%M:%S') KEPT (server still offers it, no longer pruned): $nf" >> "$logfile"
            fi
            if [ -n "$new_kv" ]; then
                new_key="${new_kv%|*}"; new_ver="${new_kv##*|}"
                game_dir="$(dirname "$nf")"
                while IFS= read -r -d '' old_archive; do
                    [ "$old_archive" != "$nf" ] || continue
                    old_kv="$(rp_archive_version_key "$old_archive")"
                    [ -n "$old_kv" ] && [ "${old_kv%|*}" = "$new_key" ] || continue
                    [ "$(rp_version_cmp "${old_kv##*|}" "$new_ver")" = "-1" ] || continue
                    grep -qxF "$old_archive" "$exempt_file" 2>/dev/null && continue
                    q_dest="old/$(date '+%Y-%m-%d')/$old_archive"
                    mkdir -p "$(dirname "$q_dest")"
                    if mv "$old_archive" "$q_dest"; then
                        echo "$(date '+%Y-%m-%d %H:%M:%S') QUARANTINED (v${old_kv##*|} superseded by v$new_ver $nf): $old_archive -> $q_dest" >> "$logfile"
                        pruned_count=$((pruned_count + 1))
                    fi
                done < <(find "$game_dir" -maxdepth 1 -type f \( -iname "*.lha" -o -iname "*.lzx" -o -iname "*.zip" \) -print0 2>/dev/null)
            fi
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

# Quarantine folders (one per day) are deleted after OLD_ARCHIVE_DAYS days.
if [ -d old ]; then
    find old -mindepth 1 -maxdepth 1 -type d -mtime +"$RP_OLD_ARCHIVE_DAYS" \
        -exec rm -rf {} + 2>/dev/null
fi

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
    echo "Superseded archives moved to old/: $pruned_count (see $logfile; kept for $RP_OLD_ARCHIVE_DAYS days)"
fi
printf "Elapsed time: %02d:%02d:%02d\n" "$hh" "$mm" "$ss"
logpath="$(cd "$(dirname "$logfile")" && pwd)"
echo "See $logpath/$logfile for details"
exit 0
