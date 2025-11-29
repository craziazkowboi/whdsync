#!/usr/bin/env bash

# Amiga Retroplay iGame Artwork Merger
# macOS 10.15.7+ | Debian 12 | Debian 13 | Raspberry Pi Compatible
# Version: 1.6.0-adaptive-a314 (Priority-ordered merge with flexible section names)

BAR_WIDTH=40
DEBUG=0
processed=0
CUSTOM=0
ART_PRIORITY="Screens,Covers,Titles" # default order

# Progress update step (tuned later per platform)
PROGRESS_STEP=100

# Platform hint (optional override, e.g. --a314)
PLATFORM_HINT=""

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
    for ((i=0; i < whole; i++)); do bar+="${progchars}"; done
    if [ "$partialblock" -gt 0 ]; then bar+="${progchars[$partialblock]}"; fi

    left=$(( width - ${#bar} ))
    for ((i=0; i < left; i++)); do bar+="${progchars}"; done

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IGAME_ECS_SRC="$SCRIPT_DIR/iGame_ECS"
IGAME_AGA_SRC="$SCRIPT_DIR/iGame_AGA"
IGAME_RTG_SRC="$SCRIPT_DIR/iGame_RTG"
TINYLAUNCHER_SRC="$SCRIPT_DIR/TinyLauncher"
DEFAULT_DEST="$SCRIPT_DIR/retro"
ART_SRC="$IGAME_ECS_SRC"
DEST=""

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

# ----- argument parsing -----

while [ $# -gt 0 ]; do
    case "$1" in
        --custom) CUSTOM=1; shift ;;
        --ecs) ART_SRC="$IGAME_ECS_SRC"; shift ;;
        --aga) ART_SRC="$IGAME_AGA_SRC"; shift ;;
        --rtg) ART_SRC="$IGAME_RTG_SRC"; shift ;;
        -d|--destination) DEST="$2"; shift 2 ;;
        --art-order) ART_PRIORITY="$2"; shift 2 ;;
        --a314) PLATFORM_HINT="a314"; shift ;;
        --debug) DEBUG=1; shift ;;
        -h|--help)
            echo
            echo "Amiga Retroplay iGame Artwork Merger"
            echo "Version: 1.6.0-adaptive-a314 (Priority-ordered merge)"
            echo "Usage: $(basename "$0") [--custom] [--ecs|--aga|--rtg] [-d DEST] [--art-order ORDER] [--debug]"
            echo
            echo "Options:"
            echo "  --custom          Show interactive menu to select artwork set"
            echo "  --ecs             Use iGame_ECS source (default)"
            echo "  --aga             Use iGame_AGA source"
            echo "  --rtg             Use iGame_RTG source"
            echo "  -d, --destination Set destination directory (default: ./retro)"
            echo "  --art-order       Set merge priority order (default: Screens,Covers,Titles)"
            echo "                    Example: --art-order \"Screens,Covers,Titles\""
            echo "                    Comma-separated list: Screens,Covers,Titles or any other order"
            echo "                    First:  copy as-is (used by iGame)"
            echo "                    Second: iGame.iff -> igame1.iff (not used by iGame)"
            echo "                    Third:  iGame.iff -> igame2.iff (not used by iGame)"
            echo "  --a314            Hint: running on A314 (lower parallelism, fewer updates)"
            echo "  --debug           Enable debug output to trace artwork matching"
            echo
            echo "Platforms: macOS 10.15.7+ | Debian 12/13 | Raspberry Pi"
            echo "Merges artwork from Screens/Screen/Titles/Title/Covers/Cover hierarchies and TinyLauncher."
            echo "Supports singular and plural section/category names."
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ "$CUSTOM" -eq 1 ]; then
    show_artwork_menu
fi

DEST="${DEST:-$DEFAULT_DEST}"
DEST="${DEST%/}"

# Parse section priority order
IFS=',' read -r -a ART_ORDER <<< "$ART_PRIORITY"

# Decide which TinyLauncher SCR index becomes iGame.iff based on first art-order entry
primary_section="${ART_ORDER[0]}"
case "$primary_section" in
    Covers)  tl_primary_index=0 ;; # iGame.iff from _SCR0
    Titles)  tl_primary_index=1 ;; # iGame.iff from _SCR1
    Screens) tl_primary_index=2 ;; # iGame.iff from _SCR2
    *)       tl_primary_index=0 ;; # sensible default
esac

# -----------------------------------------------------------------------------
# Artwork index: pre-scan ART_SRC once and map game name -> directory by section
# -----------------------------------------------------------------------------

declare -A IGAME_INDEX_BY_SECTION # key: "Section|GameName" -> directory path

generate_art_index_for_source() {
    local src_root="$1"
    local sec category dir_prefix sec_name cat_name base_path game_dir game_name key

    # Clear any existing index
    IGAME_INDEX_BY_SECTION=()

    for sec in "${ART_ORDER[@]}"; do
        # Allow singular/plural section names
        case "$sec" in
            Screens) section_variants=(Screens Screen) ;;
            Covers)  section_variants=(Covers Cover) ;;
            Titles)  section_variants=(Titles Title) ;;
            *)       section_variants=("$sec") ;;
        esac

        for category in Games Magazines Demos; do
            case "$category" in
                Games)     category_variants=(Games Game) ;;
                Magazines) category_variants=(Magazines Magazine) ;;
                Demos)     category_variants=(Demos Demo) ;;
            esac

            for dir_prefix in {A..Z} {0..9}; do
                for sec_name in "${section_variants[@]}"; do
                    for cat_name in "${category_variants[@]}"; do
                        base_path="$src_root/$sec_name/$cat_name/$dir_prefix"
                        [ -d "$base_path" ] || continue

                        # One non-recursive level: children are expected to be game dirs
                        while IFS= read -r -d '' game_dir; do
                            game_name="$(basename "$game_dir")"
                            key="$sec|$game_name"
                            # Only keep the first hit per section+game
                            if [ -z "${IGAME_INDEX_BY_SECTION[$key]+_}" ]; then
                                IGAME_INDEX_BY_SECTION["$key"]="$game_dir"
                            fi
                        done < <(find "$base_path" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
                    done
                done
            done
        done
    done
}

debug_log "Script directory: $SCRIPT_DIR"
debug_log "Artwork source: $ART_SRC"
debug_log "Destination: $DEST"
debug_log "Art merge order: ${ART_ORDER[*]}"

if [ ! -d "$ART_SRC" ]; then
    echo "ERROR: Source artwork directory not found: $ART_SRC"
    exit 1
fi

# Build artwork index for primary source tree to avoid per-game find calls
generate_art_index_for_source "$ART_SRC"

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

# Basic platform tuning for progress and parallelism
UNAME_OUT="$(uname 2>/dev/null || echo Unknown)"
case "$UNAME_OUT" in
    Darwin)
        PROGRESS_STEP=100
        ;;
    Linux)
        PROGRESS_STEP=100
        ;;
    *)
        PROGRESS_STEP=100
        ;;
esac

# Basic platform tuning for progress and parallelism
UNAME_OUT="$(uname 2>/dev/null || echo Unknown)"
case "$UNAME_OUT" in
    Darwin)
        PROGRESS_STEP=100
        ;;
    Linux)
        PROGRESS_STEP=100
        ;;
    *)
        PROGRESS_STEP=100
        ;;
esac

# Optional manual hint: --a314 slows down I/O, so be gentler
if [ "$PLATFORM_HINT" = "a314" ]; then
    max_parallel=2
    PROGRESS_STEP=500
fi

# ----- Pi Zero 2W / A314 detection -----
# 1) Detect Raspberry Pi Zero 2W and reduce parallelism for slow I/O
if [ -r /sys/firmware/devicetree/base/model ] && \
   grep -q "Raspberry Pi Zero 2 W" /sys/firmware/devicetree/base/model 2>/dev/null; then
    max_parallel=2
    PROGRESS_STEP=500
# 2) Fallback: detect A314 device node or /proc entry
elif [ -e /proc/a314 ] || ls /dev/a314* >/dev/null 2>&1; then
    max_parallel=2
    PROGRESS_STEP=500
fi

echo "=========================================="
echo "Amiga Retroplay iGame Artwork Merger"
echo "Version: 1.6.0-adaptive-a314"
echo "=========================================="
echo "Platform: $(uname)"
echo "Detected CPU core(s): $CORES"
echo "Parallel job limit: $max_parallel"
echo "Destination directory: $DEST"
echo "Selected artwork source: $ART_SRC"
echo "Section merge order: ${ART_ORDER[*]}"
[ -d "$TINYLAUNCHER_SRC" ] && echo "TinyLauncher source: $TINYLAUNCHER_SRC"
[ "$DEBUG" -eq 1 ] && echo "Debug mode: ENABLED"
echo "=========================================="
echo

whdload_path="$DEST/WHDLoad"
whdload_dirs=()
while IFS= read -r -d '' dir; do
    whdload_dirs+=("$dir")
done < <(find "$whdload_path" -mindepth 1 -maxdepth 4 -type d -print0 2>/dev/null)

total_dirs="${#whdload_dirs[@]}"
[ "$total_dirs" -eq 0 ] && { echo "ERROR: No game subdirectories found under WHDLoad."; exit 1; }

start_time="$(date +%s)"

echo "Found $total_dirs WHDLoad subdirectories to merge."
echo

ERROR_LOG="/tmp/artwork_merger_errors.$$"
IGAMEECS_LOG="/tmp/artwork_merger_igameecs.$$"
TINYLAUNCHER_LOG="/tmp/artwork_merger_tinylauncher.$$"

: > "$ERROR_LOG"
: > "$IGAMEECS_LOG"
: > "$TINYLAUNCHER_LOG"

trap 'echo -e "\nAborted by user. Cleaning up..."; pkill -P $$; rm -f "$ERROR_LOG" "$IGAMEECS_LOG" "$TINYLAUNCHER_LOG"; exit 130' INT

merge_targets=()
while IFS= read -r -d '' dir; do
    merge_targets+=("$dir")
done < <(find "$whdload_path" -maxdepth 4 -type d -print0 2>/dev/null)

total_targets="${#merge_targets[@]}"

shopt -s nullglob

for dest_sub in "${merge_targets[@]}"; do
    [ -z "$dest_sub" ] && exit 0

    dest_name="$(basename "$dest_sub")"
    debug_log "Processing target: $dest_name -> $dest_sub"

    igameecs_found=0
    tinylauncher_found=0

    best_section=""
    best_dir=""

    # Find best matching section/dir from index
    for section in "${ART_ORDER[@]}"; do
        key="$section|$dest_name"
        if [ -n "${IGAME_INDEX_BY_SECTION[$key]+_}" ]; then
            best_section="$section"
            best_dir="${IGAME_INDEX_BY_SECTION[$key]}"
            break
        fi
    done

    if [ -n "$best_dir" ] && [ -d "$best_dir" ]; then
        # Determine priority index (0,1,2) for chosen section
        priority_idx=-1
        for i in "${!ART_ORDER[@]}"; do
            if [ "${ART_ORDER[$i]}" = "$best_section" ]; then
                priority_idx="$i"
                break
            fi
        done

        debug_log "INDEX: $dest_name -> $best_section -> $best_dir"

        files=("$best_dir"/*)
        if [ ${#files[@]} -gt 0 ] && [ -e "${files}" ]; then
            debug_log " Copying ${#files[@]} files from $best_section (priority $priority_idx) to $dest_sub/"
            for f in "${files[@]}"; do
                [ -f "$f" ] || continue
                base="$(basename "$f")"
                dest_file="$dest_sub/$base"

                # Apply priority-based renaming for iGame.iff
                if [ "$base" = "iGame.iff" ] || [ "$base" = "igame.iff" ]; then
                    case "$priority_idx" in
                        0) dest_file="$dest_sub/iGame.iff" ;;
                        1) dest_file="$dest_sub/igame1.iff" ;;
                        2) dest_file="$dest_sub/igame2.iff" ;;
                    esac
                fi

                debug_log " -> $base -> $(basename "$dest_file")"

                if cp -f "$f" "$dest_file" 2>/dev/null; then
                    igameecs_found=1
                else
                    echo "ERROR copying $best_section for $dest_name from $f" >> "$ERROR_LOG"
                fi
            done
            echo "$best_section $dest_name: ${#files[@]} files" >> "$IGAMEECS_LOG"
        fi
    fi

    # TinyLauncher processing (fallback only if no iGame artwork was found)
    if [ -d "$TINYLAUNCHER_SRC" ] && [ "$igameecs_found" -eq 0 ]; then
        for subdir in Game Demo Magazine Beta; do
            search_dir="$TINYLAUNCHER_SRC/$subdir"
            [ ! -d "$search_dir" ] && continue

            debug_log "Checking TinyLauncher $subdir: $search_dir"
            tl_src=""

            for ext in iff IFF; do
                candidate="$search_dir/${dest_name}_SCR${tl_primary_index}.${ext}"
                if [ -f "$candidate" ]; then
                    debug_log " FOUND TinyLauncher candidate: $(basename "$candidate")"
                    tl_src="$candidate"
                    break
                fi
            done

            if [ -n "$tl_src" ]; then
                dest_file="$dest_sub/iGame.iff"
                debug_log " Copying TinyLauncher -> $dest_file"

                if cp -f "$tl_src" "$dest_file" 2>/dev/null; then
                    tinylauncher_found=1
                    echo "1" >> "$TINYLAUNCHER_LOG"
                else
                    echo "ERROR: Failed to copy TinyLauncher artwork for '$dest_name' from '$tl_src'" >> "$ERROR_LOG"
                fi
                break
            fi
        done
    fi

    if [ "$igameecs_found" -eq 0 ] && [ "$tinylauncher_found" -eq 0 ]; then
        debug_log "NO ARTWORK FOUND for $dest_name"
    fi

    wait_for_job_slot "$max_parallel"

    processed=$((processed + 1))
    if (( processed % PROGRESS_STEP == 0 || processed == total_targets )); then
        progress_bar "$processed" "$total_targets" "$BAR_WIDTH"
    fi
done

wait
shopt -u nullglob

# Ensure final progress bar at 100% (in case last step missed the modulus)
if (( total_targets > 0 )); then
    progress_bar "$total_targets" "$total_targets" "$BAR_WIDTH"
    printf "\n"
fi

printf "\n"

if [ -s "$ERROR_LOG" ]; then errors=$(wc -l < "$ERROR_LOG" | tr -d ' '); else errors=0; fi
if [ -s "$IGAMEECS_LOG" ]; then igameecs_count=$(wc -l < "$IGAMEECS_LOG" | tr -d ' '); else igameecs_count=0; fi
if [ -s "$TINYLAUNCHER_LOG" ]; then tinylauncher_count=$(wc -l < "$TINYLAUNCHER_LOG" | tr -d ' '); else tinylauncher_count=0; fi

elapsed=$(( $(date +%s) - start_time ))
fmt_time="$(format_elapsed_time "$elapsed")"

echo "=========================================="
echo "MERGE REPORT"
echo "=========================================="
echo "Destination: $DEST"
echo "Artwork Source: $ART_SRC"
echo "Section order: ${ART_ORDER[*]}"
echo "Elapsed Time: $fmt_time"
echo "------------------------------------------"
echo "iGame artwork merged: $igameecs_count"
echo "TinyLauncher screenshots: $tinylauncher_count"
echo "Copy errors: $errors"
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

rm -f "$ERROR_LOG" "$IGAMEECS_LOG" "$TINYLAUNCHER_LOG"

echo
echo "Merge complete."
