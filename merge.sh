#!/usr/bin/env bash

# Amiga Retroplay iGame Artwork Merger
# Debian 12/13 A314-Compatible Edition (Text-Only Progress)
# Version: 1.5.0-adaptive-a314

BAR_WIDTH=40
DEBUG=0
processed=0
CUSTOM=0

progress_bar() {
    local current="${1:-0}" total="${2:-1}" width="${3:-40}"
    if [[ "$(uname)" = "Darwin" ]]; then
        local percent barlen whole partialfrac partialblock left bar
        local progchars=(' ' '▏' '▎' '▍' '▌' '▋' '▊' '▉' '█')
        (( total > 0 )) && percent=$(( 100 * current / total )) || percent=0
        barlen=$(awk "BEGIN{printf \"%.2f\", ($width * $current) / $total}")
        whole=${barlen%.*}
        partialfrac="0.${barlen#*.}"
        partialblock=$(awk "BEGIN{print int(${partialfrac}*8+0.5)}")
        bar=""
        for ((i=0; i<whole; i++)); do bar="${bar}${progchars[8]}"; done
        if (( whole < width )); then
            bar="${bar}${progchars[partialblock]}"
            left=$(( width - whole - 1 ))
        else
            left=0
        fi
        for ((i=0; i<left; i++)); do bar="${bar}${progchars[0]}"; done
        printf "\rProgress: %3d%% [%-${width}s] %d/%d" "$percent" "$bar" "$current" "$total"
    else
        local percent filled empty bar
        (( total > 0 )) && percent=$(( 100 * current / total )) || percent=0
        filled=$(( width * current / total )); (( filled < 0 )) && filled=0
        empty=$(( width - filled ))
        bar=$(printf "%${filled}s" | tr ' ' '#')
        bar="${bar}$(printf "%${empty}s" | tr ' ' '-')"
        printf "\rProgress: %3d%% [%-${width}s] %d/%d" "$percent" "$bar" "$current" "$total"
    fi
    tput el 2>/dev/null || true
}

format_elapsed_time() {
    local t="$1"
    printf '%d:%02d:%02d' $((t/3600)) $(((t%3600)/60)) $((t%60))
}

wait_for_job_slot() {
    local max_jobs="$1" job_count
    while true; do
        job_count=$(jobs -r | wc -l | tr -d ' ')
        [ "$job_count" -lt "$max_jobs" ] && break
        sleep 0.1
    done
}

debug_log() {
    if [ "$DEBUG" -eq 1 ]; then
        echo "[DEBUG] $*" >&2
    fi
}

show_artwork_menu() {
    echo
    echo "=========================================="
    echo "Select iGame Artwork Set"
    echo "=========================================="
    echo "1) ECS (Enhanced Chip Set)"
    echo "2) AGA (Advanced Graphics Architecture)"
    echo "3) RTG (Retargetable Graphics)"
    echo "=========================================="
    echo
    echo "No input within 30 seconds will default to: ECS"
    echo

    # read with timeout, default to ECS if no input
    if read -t 30 -p "Enter your choice (1-3): " choice; then
        :
    else
        echo    # ensure newline after timeout
        echo "No selection made, defaulting to ECS."
        choice="1"
    fi

    case "$choice" in
        1) ART_SRC="$IGAME_ECS_SRC"; echo "Selected: ECS" ;;
        2) ART_SRC="$IGAME_AGA_SRC"; echo "Selected: AGA" ;;
        3) ART_SRC="$IGAME_RTG_SRC"; echo "Selected: RTG" ;;
        *) echo "Invalid choice. Defaulting to ECS."; ART_SRC="$IGAME_ECS_SRC" ;;
    esac
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IGAME_ECS_SRC="$SCRIPT_DIR/iGame_ECS"
IGAME_AGA_SRC="$SCRIPT_DIR/iGame_AGA"
IGAME_RTG_SRC="$SCRIPT_DIR/iGame_RTG"
TINYLAUNCHER_SRC="$SCRIPT_DIR/TinyLauncher"
DEFAULT_DEST="$SCRIPT_DIR/retro"
ART_SRC="$IGAME_ECS_SRC"
DEST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --custom) CUSTOM=1; shift ;;
        --ecs) ART_SRC="$IGAME_ECS_SRC"; shift ;;
        --aga) ART_SRC="$IGAME_AGA_SRC"; shift ;;
        --rtg) ART_SRC="$IGAME_RTG_SRC"; shift ;;
        -d|--destination) DEST="${2:-}"; shift 2 ;;
        --debug) DEBUG=1; shift ;;
        -h|--help)
            echo
            echo "Amiga Retroplay iGame Artwork Merger"
            echo "Version: 1.5.0-adaptive-a314 (Text-only, no GUI)"
            echo "Usage: $(basename "$0") [--custom] [--ecs|--aga|--rtg] [-d DEST] [--debug]"
            echo
            echo "Options:"
            echo " --custom Show interactive menu to select artwork set"
            echo " --ecs Use iGame_ECS source (default)"
            echo " --aga Use iGame_AGA source"
            echo " --rtg Use iGame_RTG source"
            echo " -d, --destination Set destination directory (default: ./retro)"
            echo " --debug Enable debug output to trace artwork matching"
            echo
            echo "Debian 12/13/A314/MacOSX compatible."
            echo "Merges artwork from Screens/Titles/Covers hierarchies and TinyLauncher."
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ "$CUSTOM" -eq 1 ]; then
    show_artwork_menu
fi

DEST="${DEST:-$DEFAULT_DEST}"
DEST="${DEST%/}"

debug_log "Script directory: $SCRIPT_DIR"
debug_log "Artwork source: $ART_SRC"
debug_log "Destination: $DEST"

if [ ! -d "$ART_SRC" ]; then
    echo "ERROR: Source artwork directory not found: $ART_SRC"
    exit 1
fi

if [ ! -d "$DEST/WHDLoad" ]; then
    echo "ERROR: No WHDLoad directory found at: $DEST/WHDLoad"
    exit 1
fi

CORES=""
if command -v nproc >/dev/null 2>&1; then
    CORES=$(nproc 2>/dev/null)
elif command -v getconf >/dev/null 2>&1; then
    CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
fi
if [ -z "$CORES" ] && command -v sysctl >/dev/null 2>&1; then
    CORES=$(sysctl -n hw.ncpu 2>/dev/null)
fi
CORES=${CORES:-2}
[ "$CORES" -gt 8 ] && CORES=8
max_parallel="$CORES"

echo "=========================================="
echo "Amiga Retroplay iGame Artwork Merger"
echo "Version: 1.5.0-adaptive-a314"
echo "=========================================="
echo "Platform: $(uname)"
echo "Detected CPU core(s): $CORES"
echo "Parallel job limit: $max_parallel"
echo "Destination directory: $DEST"
echo "Selected artwork source: $ART_SRC"
[ -d "$TINYLAUNCHER_SRC" ] && echo "TinyLauncher source: $TINYLAUNCHER_SRC"
[ "$DEBUG" -eq 1 ] && echo "Debug mode: ENABLED"
echo "=========================================="
echo

whdload_path="$DEST/WHDLoad"

whdload_dirs=()
while IFS= read -r -d '' dir; do whdload_dirs+=("$dir"); done < <(find "$whdload_path" -mindepth 1 -maxdepth 4 -type d -print0 2>/dev/null)
total_dirs="${#whdload_dirs[@]}"
[ "$total_dirs" -eq 0 ] && { echo "ERROR: No game subdirectories found under WHDLoad."; exit 1; }

start_time="$(date +%s)"
echo "Found $total_dirs WHDLoad subdirectories to merge."
echo

ERROR_LOG="/tmp/artwork_merger_errors.$$"
IGAMEECS_LOG="/tmp/artwork_merger_igameecs.$$"
TINYLAUNCHER_LOG="/tmp/artwork_merger_tinylauncher.$$"
NOMATCH_LOG="/tmp/artwork_merger_nomatch.$$"

: > "$ERROR_LOG"
: > "$IGAMEECS_LOG"
: > "$TINYLAUNCHER_LOG"
: > "$NOMATCH_LOG"

trap 'echo -e "\nAborted by user. Cleaning up..."; pkill -P $$; rm -f "$ERROR_LOG" "$IGAMEECS_LOG" "$TINYLAUNCHER_LOG" "$NOMATCH_LOG"; exit 130' INT

merge_targets=()
while IFS= read -r -d '' dir; do merge_targets+=("$dir"); done < <(find "$whdload_path" -maxdepth 4 -type d -print0 2>/dev/null)
total_targets="${#merge_targets[@]}"
shopt -s nullglob

for dest_sub in "${merge_targets[@]}"; do
    [ -z "$dest_sub" ] && continue
    dest_name="$(basename "$dest_sub")"
    debug_log "Processing target: $dest_name -> $dest_sub"
    igameecs_found=0
    for section in Screens Titles Covers; do
        for category in Games Magazines Demos; do
            for dir_prefix in {A..Z} {0..9}; do
                search_dir="$ART_SRC/$section/$category/$dir_prefix/$dest_name"
                debug_log "Checking: $search_dir"
                if [ -d "$search_dir" ]; then
                    debug_log "FOUND directory: $search_dir"
                    case "$section" in
                        Screens)
                            files=("$search_dir"/*)
                            if [ ${#files[@]} -gt 0 ] && [ -e "${files[0]}" ]; then
                                debug_log " Copying ${#files[@]} files from Screens to $dest_sub/"
                                for f in "${files[@]}"; do
                                    debug_log " -> $(basename "$f")"
                                done
                                if cp -f "${files[@]}" "$dest_sub/" 2>/dev/null; then
                                    igameecs_found=1
                                    echo "Screens $category $dir_prefix/$dest_name: ${#files[@]} files" >> "$IGAMEECS_LOG"
                                else
                                    echo "ERROR copying Screens for $dest_name from $search_dir" >> "$ERROR_LOG"
                                fi
                            fi
                            ;;
                        Covers)
                            cover="$search_dir/iGame.iff"
                            debug_log " Checking for Covers file: $cover"
                            if [ -f "$cover" ]; then
                                debug_log " FOUND Covers file: $cover -> $dest_sub/igame1.iff"
                                if cp -f "$cover" "$dest_sub/igame1.iff" 2>/dev/null; then
                                    igameecs_found=1
                                    echo "Covers $category $dir_prefix/$dest_name: igame1.iff" >> "$IGAMEECS_LOG"
                                else
                                    echo "ERROR copying Covers for $dest_name from $cover" >> "$ERROR_LOG"
                                fi
                            fi
                            ;;
                        Titles)
                            debug_log " Checking for Titles files in $search_dir"
                            for title_file in "$search_dir"/*; do
                                if [ -f "$title_file" ]; then
                                    debug_log " FOUND Titles file: $(basename "$title_file") -> $dest_sub/igame2.iff"
                                    if cp -f "$title_file" "$dest_sub/igame2.iff" 2>/dev/null; then
                                        igameecs_found=1
                                        echo "Titles $category $dir_prefix/$dest_name: igame2.iff" >> "$IGAMEECS_LOG"
                                    else
                                        echo "ERROR copying Titles for $dest_name from $title_file" >> "$ERROR_LOG"
                                    fi
                                    break
                                fi
                            done
                            ;;
                    esac
                fi
            done
        done
    done
    tinylauncher_found=0
    if [ -d "$TINYLAUNCHER_SRC" ]; then
        for subdir in Game Demo Magazine Beta; do
            search_dir="$TINYLAUNCHER_SRC/$subdir"
            [ ! -d "$search_dir" ] && continue
            debug_log "Checking TinyLauncher $subdir: $search_dir"
            tinylauncher_files=()
            for ext in iff IFF; do
                for i in 0 1 2 3 4 5 6 7 8 9; do
                    pattern="$search_dir/${dest_name}_SCR${i}.${ext}"
                    if [ -f "$pattern" ]; then
                        debug_log " FOUND TinyLauncher: $(basename "$pattern")"
                        tinylauncher_files+=("$pattern")
                    fi
                done
            done
            if [ ${#tinylauncher_files[@]} -gt 0 ]; then
                debug_log " Copying ${#tinylauncher_files[@]} TinyLauncher files to $dest_sub/"
                if cp -f "${tinylauncher_files[@]}" "$dest_sub/" 2>/dev/null; then
                    tinylauncher_found=1
                    echo "1" >> "$TINYLAUNCHER_LOG"
                else
                    echo "ERROR: Failed to copy TinyLauncher artwork for '$dest_name'" >> "$ERROR_LOG"
                fi
                break
            fi
        done
    fi
    if [ $igameecs_found -eq 0 ] && [ $tinylauncher_found -eq 0 ]; then
        debug_log "NO ARTWORK FOUND for $dest_name"
        echo "1" >> "$NOMATCH_LOG"
    fi
    processed=$((processed + 1))
    progress_bar "$processed" "$total_targets" "$BAR_WIDTH"
    wait_for_job_slot "$max_parallel"
done

wait
shopt -u nullglob

printf "\n\n"

if [ -s "$ERROR_LOG" ]; then errors=$(wc -l < "$ERROR_LOG" | tr -d ' '); else errors=0; fi
if [ -s "$IGAMEECS_LOG" ]; then igameecs_count=$(wc -l < "$IGAMEECS_LOG" | tr -d ' '); else igameecs_count=0; fi
if [ -s "$TINYLAUNCHER_LOG" ]; then tinylauncher_count=$(wc -l < "$TINYLAUNCHER_LOG" | tr -d ' '); else tinylauncher_count=0; fi
if [ -s "$NOMATCH_LOG" ]; then nomatch_count=$(wc -l < "$NOMATCH_LOG" | tr -d ' '); else nomatch_count=0; fi

elapsed=$(( $(date +%s) - start_time ))
fmt_time="$(format_elapsed_time "$elapsed")"

echo "=========================================="
echo "MERGE REPORT"
echo "=========================================="
echo "Destination: $DEST"
echo "Artwork Source: $ART_SRC"
echo "Elapsed Time: $fmt_time"
echo "------------------------------------------"
echo "iGame artwork merged: $igameecs_count"
echo "TinyLauncher screenshots: $tinylauncher_count"
echo "Copy errors: $errors"
echo "Directories missing artwork: $nomatch_count"
echo "=========================================="
if [ $errors -ne 0 ]; then
    cp "$ERROR_LOG" "$SCRIPT_DIR/merge_errors.log"
    echo
    echo "ERROR: $errors errors occurred during merge."
    echo "See $SCRIPT_DIR/merge_errors.log for details."
fi
if [ "$DEBUG" -eq 1 ] && [ -s "$IGAMEECS_LOG" ]; then
    echo
    echo "--- iGame Artwork Details ---"
    cat "$IGAMEECS_LOG"
fi
rm -f "$ERROR_LOG" "$IGAMEECS_LOG" "$TINYLAUNCHER_LOG" "$NOMATCH_LOG"
echo
echo "Merge complete."
