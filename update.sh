#!/bin/bash
# retroplay-suite: 2026.09.22   (every script in the set must carry the same stamp)

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
        *) echo "Unknown option: $_arg (try --help)" >&2; exit 4 ;;
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
        exit 4   # a missing tool is a setup problem - NOT "nothing new" (exit 2)
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
rp_restore_state_if_lost
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
    find -H "$dir" -type f | sort > before.txt

    pushd "$dir" > /dev/null || exit 1

    # The remote WHDLoad pack path mirrors our local directory name, just
    # with spaces turned to underscores and a "Commodore_Amiga_-_" prefix,
    # and "/" swapped for "_-_" (e.g. "WHDLoad/Games" -> ..._-_WHDLoad_-_Games).
    dirpath="$(remote_dir_for "$dir")"

    # --mirror recurses and only re-fetches files that changed on the
    # server (by size/date), so re-running this is safe and cheap when
    # nothing new has been published. -np/-nH/--cut-dirs=2 keep the local
    # layout flat instead of recreating the whole remote path structure.
    # -nv logs one line per file wget finishes writing; that log (not just
    # the before/after listing) is what tells us which files are new OR were
    # re-published under the same name - and which ones actually completed.
    # Transient failures are retried with a growing pause.
    dl_log="$SCRIPT_DIR/.wget_download.log"
    : > "$dl_log"
    attempt=1
    while :; do
        wget -nv -a "$dl_log" --mirror -np -nH --cut-dirs=2 --tries=3 --waitretry=10 \
             --timeout=60 "$FTP_BASE/$dirpath" > /dev/null 2>&1
        wget_status=$?
        [ "$wget_status" -eq 0 ] && break
        [ "$attempt" -ge "$RP_DOWNLOAD_RETRIES" ] && break
        printf '\r%-*s | download problem (wget exit %d), retrying (%d of %d)...\n' \
            "$maxlen" "Checking for updates in: $dir" "$wget_status" "$((attempt + 1))" "$RP_DOWNLOAD_RETRIES"
        sleep $(( attempt * ${RP_RETRY_WAIT:-30} ))
        attempt=$((attempt + 1))
    done

    popd > /dev/null || exit 1

    # Snapshot again AFTER downloading, so the before/after diff below
    # shows exactly what the mirror added.
    find -H "$dir" -type f | sort > after.txt

    # `comm -13` prints lines that are ONLY in the second file (after.txt),
    # i.e. genuinely new since the "before" snapshot - exactly the files
    # this run added, regardless of how many already existed.
    # Files wget reports as completely written (relative to the scripts' folder).
    sed -n 's/.* -> "\([^"]*\)".*/\1/p' "$dl_log" | sed 's|^\./||' | grep -v '\.listing$' \
        | sed "s|^|$dir/|" | sort -u > wget_done.txt
    if [ "$wget_status" -eq 0 ]; then
        # New files (listing diff) plus anything re-published under the same name.
        { comm -13 before.txt after.txt; cat wget_done.txt; } | sort -u > new_list.txt
    else
        # The transfer failed part-way: trust only files wget confirmed as
        # complete. A partial file is re-downloaded - and queued - next run.
        cp wget_done.txt new_list.txt
    fi

    # Guard: files clearly arrived but wget's log yielded nothing readable
    # (e.g. a different wget version's log format). New files are still
    # found from the listing, but re-published ones could be missed - say so.
    comm_n="$(comm -13 before.txt after.txt | grep -c .)"
    done_n="$(grep -c . wget_done.txt)"
    if [ "$wget_status" -eq 0 ] && [ "${comm_n:-0}" -gt 0 ] && [ "${done_n:-0}" -eq 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING: couldn't read wget's download log - files re-published under the same name may be missed" >> "$logfile"
        [ -n "${wget_log_warned:-}" ] || echo "Warning: couldn't read wget's download log (a different wget version?) - re-published files may be missed." >&2
        wget_log_warned=1
    fi

    # Test new downloads straight away, so a corrupt one is fetched again in
    # THIS run rather than failing extraction for several nights first.
    # VERIFY_DOWNLOADS: yes, no, or auto (= only batches of up to 100 files,
    # so a huge first download isn't slowed down - extraction checks those).
    verify_n="$(grep -c . new_list.txt)"; verify_n="${verify_n:-0}"
    if [ "$verify_n" -gt 0 ] && { [ "$RP_VERIFY_DOWNLOADS" = "yes" ] || { [ "$RP_VERIFY_DOWNLOADS" = "auto" ] && [ "$verify_n" -le 100 ]; }; }; then
        : > bad.txt
        while IFS= read -r nf; do
            [ -f "$nf" ] || continue
            rp_test_archive "$nf" || { printf '%s\n' "$nf" >> bad.txt; rm -f "$nf"; }
        done < new_list.txt
        if [ -s bad.txt ]; then
            sed "s|^|$(date '+%Y-%m-%d %H:%M:%S') CORRUPT download, fetching it again: |" bad.txt >> "$logfile"
            pushd "$dir" > /dev/null || exit 1
            wget -nv -a "$dl_log" --mirror -np -nH --cut-dirs=2 --tries=3 --waitretry=10 \
                 --timeout=60 "$FTP_BASE/$dirpath" > /dev/null 2>&1
            popd > /dev/null || exit 1
            : > gone.txt
            while IFS= read -r nf; do
                if [ ! -f "$nf" ]; then
                    printf '%s\n' "$nf" >> gone.txt       # re-download failed: next run
                elif rp_test_archive "$nf"; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') re-downloaded OK: $nf" >> "$logfile"
                else
                    # Corrupt again - likely corrupt on the server. Kept and
                    # queued: extraction retries it and reports it by name.
                    echo "$(date '+%Y-%m-%d %H:%M:%S') STILL CORRUPT after re-downloading (server copy?): $nf" >> "$logfile"
                fi
            done < bad.txt
            if [ -s gone.txt ]; then
                grep -vxF -f gone.txt new_list.txt > new_list.tmp || true
                mv new_list.tmp new_list.txt
            fi
            rm -f gone.txt
        fi
        rm -f bad.txt
    fi
    # Everything below works on the whole batch at once - one timestamp, one
    # queue update and one retirement pass per folder - instead of several
    # processes per archive (a first download of thousands of archives used
    # to take minutes here; on a Pi Zero much longer).
    grep -v '^$' new_list.txt > new_list.tmp 2>/dev/null; mv new_list.tmp new_list.txt
    new_files="$(grep -c . new_list.txt 2>/dev/null)"; new_files="${new_files:-0}"
    if [ "$new_files" -gt 0 ]; then
        ts="$(date '+%Y-%m-%d %H:%M:%S')"
        sed "s|^|$ts |" new_list.txt >> "$logfile"

        # Queue them for every finished output folder; each stays queued
        # until that folder has actually absorbed it (see lib.sh).
        rp_queue_new_archives new_list.txt

        # Came back after being quarantined? Then the server still offers it:
        # exempt it from pruning, so it isn't re-downloaded and retired again
        # every run.
        exempt_file="$(rp_prune_exempt_file)"
        : > exempt_add.txt
        while IFS= read -r nf; do
            set -- old/*/"$nf"
            if [ -e "$1" ] && ! grep -qxF "$nf" "$exempt_file" 2>/dev/null; then
                printf '%s\n' "$nf" >> exempt_add.txt
                echo "$ts KEPT (server still offers it, no longer pruned): $nf" >> "$logfile"
            fi
        done < new_list.txt
        if [ -s exempt_add.txt ]; then
            rp_state_init
            { cat "$exempt_file" 2>/dev/null; cat exempt_add.txt; } | rp_atomic_write "$exempt_file"
        fi

        # Retire superseded archives. An archive is only an older version of
        # a new one when their names are IDENTICAL apart from the version
        # field AND its version is strictly lower (1.10 > 1.9 > 1.1) - so
        # _AGA / _CD32 / _HD / _68040 releases of a game are separate files
        # and never touched. Retired archives are quarantined in old/.
        sed 's|/[^/]*$||' new_list.txt | sort -u | while IFS= read -r gd; do
            find -H "$gd" -maxdepth 1 -type f \( -iname "*.lha" -o -iname "*.lzx" -o -iname "*.zip" \) 2>/dev/null
        done > folder_archives.txt
        : > "$exempt_file.check"; [ -f "$exempt_file" ] && cp "$exempt_file" "$exempt_file.check"
        rp_find_superseded "$exempt_file.check" new_list.txt folder_archives.txt > retire.txt
        rm -f "$exempt_file.check"
        while IFS="$(printf '\t')" read -r old_archive old_ver new_ver new_path; do
            [ -f "$old_archive" ] || continue
            q_dest="old/$(date '+%Y-%m-%d')/$old_archive"
            mkdir -p "${q_dest%/*}"
            if mv "$old_archive" "$q_dest"; then
                echo "$ts QUARANTINED (v$old_ver superseded by v$new_ver $new_path): $old_archive -> $q_dest" >> "$logfile"
                pruned_count=$((pruned_count + 1))
            fi
        done < retire.txt
        rm -f exempt_add.txt folder_archives.txt retire.txt
    fi

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

    rm -f before.txt after.txt wget_done.txt new_list.txt "$dl_log"
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
