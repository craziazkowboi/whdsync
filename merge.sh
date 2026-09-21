#!/usr/bin/env bash

# Amiga Retroplay - Artwork Merger
#
# WHAT THIS SCRIPT DOES:
#   For every WHDLoad game/magazine/demo directory under DEST/WHDLoad, finds
#   the best available iGame-style icon artwork (iGame.iff + its paired
#   .data file) and copies it in, falling back through TinyLauncher
#   screenshots if no iGame artwork exists at all.
#
#   "Best available" is not just one folder - it's an ordered FALLBACK
#   CHAIN of artwork sets (see the "Artwork fallback chain" section further
#   down), so a game missing artwork in your preferred set (say, AGA) can
#   still pick it up from a lower-priority set (AGA_Laced, then the generic
#   iGame_art pool, then ECS, etc.) rather than being left with nothing.
#
#   This is the "merge artwork" step of the pipeline, run after extract.sh
#   has put game files in place and before sort.sh organizes everything by
#   variant/language. quick.sh and start.sh --auto both call this script.
#
# MAJOR PHASES IN THIS FILE, IN ORDER:
#   1. Discover every iGame_* (or IGame_*, case-insensitive) directory next
#      to this script - these are the available "artwork sets".
#   2. Parse command-line options and resolve which set (or --custom pick,
#      or --set NAME) the user actually asked for.
#   3. Build the fallback chain for that selection (see below).
#   4. Index every source in that chain ONCE up front into one big lookup
#      table, so per-game matching is a fast in-memory lookup, not a fresh
#      filesystem search for every single game.
#   5. Walk every WHDLoad subdirectory, find its best match via the chain,
#      copy the artwork across (or fall back to TinyLauncher), and report.
#
# This script's artwork-set indexing uses associative arrays and other
# Bash 4+ features. macOS ships Bash 3.2 by default, so auto-upgrade to a
# newer Bash if one is available (e.g. via Homebrew), or fail clearly.
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    for _cand in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [ -x "$_cand" ]; then
            exec "$_cand" "$0" "$@"
        fi
    done
    echo "ERROR: This script requires Bash 4.0 or newer (found ${BASH_VERSION:-an unknown version})." >&2
    echo "macOS ships an old Bash 3.2 by default. Install a modern one with:" >&2
    echo "  brew install bash" >&2
    echo "then re-run this script - it will be detected and used automatically." >&2
    exit 1
fi
unset _cand

# Amiga Retroplay iGame Artwork Merger
# macOS 10.15.7+ | Debian 12 | Debian 13 | Raspberry Pi Compatible
# Version: 1.8.0-fallback-chain (Priority-ordered merge, dynamic artwork sets, tier fallback)

BAR_WIDTH=40
NO_COLOR="${NO_COLOR:-0}"

if [ "$NO_COLOR" = "1" ] || [ ! -t 1 ]; then
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; NC="";
else
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m';
  BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m';
fi
DEBUG=0
processed=0
CUSTOM=0
REPORT_MISSING=""  # --report-missing FILE: append each game that got no artwork
ONLY_MISSING=0   # --only-missing: skip any target that already has an
                 # iGame.iff-family file AND a .data file - used for a
                 # cheap "fill gaps" pass over an existing collection
                 # rather than a full re-merge of everything.
GAME_ART_PRIORITY="Screens,Covers,Titles"       # default order for non-demos
DEMO_ART_PRIORITY="Titles,Screens,Covers"  # default order for demos
DEMO_ART_OVERRIDE=0                        # set to 1 if --demo-art is used


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
  # Fill all completed cells with a full block
  for ((i=0; i < whole; i++)); do bar+="${progchars[8]}"; done

  # Add one partial cell if needed
  if [ "$partialblock" -gt 0 ] && [ "$whole" -lt "$width" ]; then
    bar+="${progchars[$partialblock]}"
    left=$(( width - whole - 1 ))
  else
    left=$(( width - whole ))
  fi

  # Pad the rest with spaces
  for ((i=0; i < left; i++)); do bar+=" "; done

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

# Settings from retroplay.conf (via the shared lib.sh), if present.
RP_STRUCTURED_ART_SETS="AGA ECS RTG"
if [ -f "$SCRIPT_DIR/lib.sh" ]; then
    . "$SCRIPT_DIR/lib.sh"
    rp_load_config
fi
# Artwork sets matched ONLY by the standard Covers|Screens|Titles/<Games|
# Demos|Magazines>/<letter>/<game> layout. Every other set (iGame_art,
# custom packs, ...) ALSO matches a game folder anywhere inside it.
STRUCTURED_SETS=" $(printf '%s' "$RP_STRUCTURED_ART_SETS" | tr '[:lower:]' '[:upper:]') "

TINYLAUNCHER_SRC="$SCRIPT_DIR/TinyLauncher"
DEFAULT_DEST="$SCRIPT_DIR/retro"
ART_SRC=""
SET_OPT=""
DEST=""

# -----------------------------------------------------------------------------
# Artwork SET discovery: any directory named "iGame_<something>" directly
# under SCRIPT_DIR is a selectable artwork set - not just ECS/AGA/RTG.
# This lets people drop in iGame_CD32, iGame_NTSC, iGame_MyPack, etc. and have
# it show up automatically, with no code changes needed here.
# -----------------------------------------------------------------------------
declare -a IGAME_SET_NAMES=()   # display names, in discovery order
declare -A IGAME_SET_DIR=()     # NAME (uppercased) -> full directory path

shopt -s nullglob
for _igdir in "$SCRIPT_DIR"/[Ii][Gg]ame_*/; do
    _igdir="${_igdir%/}"
    [ -d "$_igdir" ] || continue
    _igbase="$(basename "$_igdir")"
    _igname="${_igbase#[Ii][Gg]ame_}"
    [ -z "$_igname" ] && continue
    _igkey="${_igname^^}"
    # keep the first match if two directories somehow map to the same key
    if [ -z "${IGAME_SET_DIR[$_igkey]+_}" ]; then
        IGAME_SET_NAMES+=("$_igname")
        IGAME_SET_DIR["$_igkey"]="$_igdir"
    fi
done
shopt -u nullglob
unset _igdir _igbase _igname _igkey

# Resolve a requested set name (any case) to ART_SRC. Returns 1 if not found.
# On success also records the uppercased key in SELECTED_SET_KEY, used to
# build the artwork fallback chain later.
SELECTED_SET_KEY=""
resolve_art_set() {
    local key="${1^^}"
    if [ -n "${IGAME_SET_DIR[$key]+_}" ]; then
        ART_SRC="${IGAME_SET_DIR[$key]}"
        SELECTED_SET_KEY="$key"
        return 0
    fi
    return 1
}

# Prefer ECS for backward compatibility; otherwise take whatever was found first.
default_art_set() {
    resolve_art_set "ECS" && return 0
    [ "${#IGAME_SET_NAMES[@]}" -gt 0 ] && resolve_art_set "${IGAME_SET_NAMES[0]}"
}

show_artwork_menu() {
    echo
    echo "=========================================="
    echo "Select iGame Artwork Set"
    echo "=========================================="

    if [ "${#IGAME_SET_NAMES[@]}" -eq 0 ]; then
        echo "No iGame_* artwork directories found in: $SCRIPT_DIR"
        echo "=========================================="
        exit 1
    fi

    local i=1
    for name in "${IGAME_SET_NAMES[@]}"; do
        echo "$i) $name"
        i=$((i + 1))
    done
    echo "=========================================="
    echo
    echo "No input within 30 seconds will default to: ${IGAME_SET_NAMES[0]}"
    echo

    if read -t 30 -p "Enter your choice (1-${#IGAME_SET_NAMES[@]}): " choice; then
        :
    else
        echo    # ensure newline after timeout
        echo "No selection made, defaulting to ${IGAME_SET_NAMES[0]}."
        choice="1"
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#IGAME_SET_NAMES[@]}" ]; then
        local picked="${IGAME_SET_NAMES[$((choice - 1))]}"
        resolve_art_set "$picked"
        echo "Selected: $picked"
    else
        echo "Invalid choice. Defaulting to ${IGAME_SET_NAMES[0]}."
        resolve_art_set "${IGAME_SET_NAMES[0]}"
    fi
}

# ----- argument parsing -----

while [ $# -gt 0 ]; do
    opt_lc="${1,,}"
    case "$opt_lc" in
        --custom) CUSTOM=1; shift ;;
        --ecs) SET_OPT="ECS"; shift ;;
        --aga) SET_OPT="AGA"; shift ;;
        --rtg) SET_OPT="RTG"; shift ;;
        --ecs-laced) SET_OPT="ECS_LACED"; shift ;;
        --aga-laced) SET_OPT="AGA_LACED"; shift ;;
        --set)
            if [ -z "${2:-}" ]; then
                echo "Error: --set requires a NAME argument (matching an iGame_NAME directory)" >&2
                exit 1
            fi
            SET_OPT="$2"
            shift 2
            ;;
        -d|--dest) DEST="$2"; shift 2 ;;
        --art)
        GAME_ART_PRIORITY="$2"
        shift 2
        ;;
    --demo-art)
        DEMO_ART_PRIORITY="$2"
        DEMO_ART_OVERRIDE=1
        shift 2
        ;; 
        --a314) PLATFORM_HINT="a314"; shift ;;
        --only-missing) ONLY_MISSING=1; shift ;;
        --report-missing) REPORT_MISSING="$2"; shift 2 ;;
        --debug) DEBUG=1; shift ;;
        -h|--help)
            echo
            echo "Amiga Retroplay iGame Artwork Merger"
            echo "Version: 1.8.0-fallback-chain (Priority-ordered merge, dynamic artwork sets, tier fallback)"
            echo "Usage: $(basename "$0") [--custom] [--ecs|--aga|--rtg|--ecs-laced|--aga-laced|--set NAME] [-d DEST] [--art ORDER] [--debug]"
            echo
            echo "Artwork sets:"
            echo "  Any directory named iGame_<NAME> next to this script is a usable artwork"
            echo "  set - not just ECS/AGA/RTG. Drop in iGame_CD32, iGame_MyPack, etc. and it"
            echo "  is picked up automatically; no code changes needed."
            if [ "${#IGAME_SET_NAMES[@]}" -gt 0 ]; then
                echo "  Sets found here: ${IGAME_SET_NAMES[*]}"
            else
                echo "  No iGame_* directories were found here."
            fi
            echo
            echo "Options:"
            echo "  --custom          Show interactive menu listing every discovered set"
            echo "  --ecs             Shortcut for --set ECS (default if present)"
            echo "  --aga             Shortcut for --set AGA"
            echo "  --rtg             Shortcut for --set RTG"
            echo "  --ecs-laced       Shortcut for --set ECS_LACED (matches iGame_ECS_Laced)"
            echo "  --aga-laced       Shortcut for --set AGA_LACED (matches iGame_AGA_Laced)"
            echo "  --set NAME        Use the iGame_NAME directory as the artwork source"
            echo "                    (case-insensitive, e.g. --set cd32 matches iGame_CD32)"
            echo " -d, --dest Set destination directory (default: ./retro)"
            echo " --art Set merge priority order for non-demos (default: Screens,Covers,Titles)"
            echo "       Example: --art \"Screens,Covers,Titles\""
            echo " --demo-art Set merge priority order for Demos (default: Titles,Screens,Covers)"
            echo " --only-missing Skip games that already have artwork (gap-fill mode)"
            echo " --report-missing FILE  Append each game that got no artwork to FILE"
            echo "       Example: --demo-art \"Titles,Screens,Covers\""
            echo "  --a314            Hint: running on A314 (lower parallelism, fewer updates)"
            echo "  --only-missing    Skip any target that already has an iGame.iff-family file"
            echo "                    AND a .data file - a cheap pass to fill gaps in an existing"
            echo "                    collection (e.g. from an earlier interrupted run) rather"
            echo "                    than re-checking everything that's already merged."
            echo "  --debug           Enable debug output to trace artwork matching"
            echo
            echo "Artwork fallback chain:"
            echo "  If a game has no artwork in the selected/requested set, these sets are"
            echo "  tried next, in order, before giving up on iGame artwork for that game:"
            echo "    --rtg       : RTG -> AGA_Laced -> AGA -> iGame_art -> ECS_Laced -> ECS"
            echo "    --aga       : AGA -> iGame_art -> ECS"
            echo "    --aga-laced : AGA_Laced -> AGA -> iGame_art -> ECS"
            echo "    --ecs       : ECS -> iGame_art"
            echo "    --ecs-laced : ECS_Laced -> ECS -> iGame_art"
            echo "    --set/--custom (anything else): the chosen set -> iGame_art"
            echo "  TinyLauncher is tried after all of the above, then any other"
            echo "  discovered iGame_* directory not already covered."
            echo
            echo "Platforms: macOS 10.15.7+ | Debian 12/13 | Raspberry Pi"
            echo "Merges artwork from Screens/Screen/Titles/Title/Covers/Cover hierarchies and TinyLauncher."
            echo "Supports singular and plural section/category names."
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done
unset opt_lc

if [ "$CUSTOM" -eq 1 ]; then
    show_artwork_menu
elif [ -n "$SET_OPT" ]; then
    if ! resolve_art_set "$SET_OPT"; then
        echo "NOTE: No iGame_$SET_OPT directory found under: $SCRIPT_DIR"
        echo "Will still try the artwork fallback chain (see --help) for a match."
        SELECTED_SET_KEY="${SET_OPT^^}"
        ART_SRC=""
    fi
else
    if ! default_art_set; then
        echo "ERROR: No iGame_* artwork directories found under: $SCRIPT_DIR"
        exit 1
    fi
fi

# DEST can be set via -d/--dest or forwarded from start.sh
DEST="${DEST:-$DEFAULT_DEST}"
DEST="${DEST%/}"

# Parse section priority order (non-demos baseline)
IFS=',' read -r -a ART_ORDER <<< "$GAME_ART_PRIORITY"

# Decide which TinyLauncher SCR index becomes iGame.iff based on first art entry
primary_section="${ART_ORDER[0]}"
case "$primary_section" in
    Covers)  tl_primary_index=0 ;; # iGame.iff from _SCR0
    Titles)  tl_primary_index=1 ;; # iGame.iff from _SCR1
    Screens) tl_primary_index=2 ;; # iGame.iff from _SCR2
    *)       tl_primary_index=0 ;; # sensible default
esac

# -----------------------------------------------------------------------------
# Artwork fallback chain: when the requested/selected set doesn't have a
# match for a given game, these are the other iGame_* sets (and finally
# TinyLauncher) to try instead, in order. TINYLAUNCHER is a sentinel handled
# separately below, not an iGame_* directory.
# -----------------------------------------------------------------------------
case "$SELECTED_SET_KEY" in
    RTG)
        FALLBACK_CHAIN=(RTG AGA_LACED AGA ART ECS_LACED ECS TINYLAUNCHER)
        ;;
    AGA)
        FALLBACK_CHAIN=(AGA ART ECS TINYLAUNCHER)
        ;;
    AGA_LACED)
        FALLBACK_CHAIN=(AGA_LACED AGA ART ECS TINYLAUNCHER)
        ;;
    ECS)
        FALLBACK_CHAIN=(ECS ART TINYLAUNCHER)
        ;;
    ECS_LACED)
        FALLBACK_CHAIN=(ECS_LACED ECS ART TINYLAUNCHER)
        ;;
    "")
        # Nothing selected at all (shouldn't normally happen - default_art_set
        # always sets SELECTED_SET_KEY on success)
        FALLBACK_CHAIN=(ART TINYLAUNCHER)
        ;;
    *)
        # A custom --set NAME or an interactive --custom pick outside the
        # named tiers above: try it, then the generic pool, then TinyLauncher.
        FALLBACK_CHAIN=("$SELECTED_SET_KEY" ART TINYLAUNCHER)
        ;;
esac

# The chain templates use the literal placeholder "ART" for the generic
# artwork pool - but not everyone names that folder exactly "iGame_art"
# (e.g. "iGame_Art_Pack"). If no directory maps to the exact key "ART",
# fall back to the first discovered set whose key STARTS WITH "ART" and
# use that instead, so a differently-named generic pool still fills the
# same slot rather than the placeholder silently matching nothing.
if [ -z "${IGAME_SET_DIR[ART]+_}" ]; then
    _art_resolved=""
    for _fbname in "${IGAME_SET_NAMES[@]}"; do
        _fbkey="${_fbname^^}"
        case "$_fbkey" in
            ART*) _art_resolved="$_fbkey"; break ;;
        esac
    done
    if [ -n "$_art_resolved" ]; then
        for _lci in "${!FALLBACK_CHAIN[@]}"; do
            [ "${FALLBACK_CHAIN[$_lci]}" = "ART" ] && FALLBACK_CHAIN[$_lci]="$_art_resolved"
        done
        unset _lci
    fi
    unset _art_resolved
fi

# Append any other discovered iGame_* sets not already in the chain, so a
# fresh iGame_MyPack directory is still tried as a last resort even though
# nothing above knows its name in advance.
for _fbname in "${IGAME_SET_NAMES[@]}"; do
    _fbkey="${_fbname^^}"
    _fbalready=0
    for _fbc in "${FALLBACK_CHAIN[@]}"; do
        [ "$_fbc" = "$_fbkey" ] && _fbalready=1 && break
    done
    [ "$_fbalready" -eq 0 ] && FALLBACK_CHAIN+=("$_fbkey")
done
unset _fbname _fbkey _fbalready _fbc

debug_log "Artwork fallback chain: ${FALLBACK_CHAIN[*]}"

# -----------------------------------------------------------------------------
# Artwork index: pre-scan every source in the fallback chain once, so
# per-game lookups are pure associative-array hits with no filesystem I/O.
# Key: "SRC|Section|GameName" -> directory path (SRC is a FALLBACK_CHAIN
# entry like RTG, AGA_LO, ART, or a custom set name).
# -----------------------------------------------------------------------------

declare -A IGAME_INDEX

index_source() {
    local src_key="$1" src_root="$2"
    local sec category dir_prefix sec_name cat_name base_path game_dir game_name key

    for sec in Screens Covers Titles; do
        case "$sec" in
            Screens) section_variants=(Screens Screen) ;;
            Covers)  section_variants=(Covers Cover) ;;
            Titles)  section_variants=(Titles Title) ;;
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
                            game_name="${game_dir##*/}"
                            key="$src_key|$sec|$game_name"
                            # Only keep the first hit per source+section+game
                            if [ -z "${IGAME_INDEX[$key]+_}" ]; then
                                IGAME_INDEX["$key"]="$game_dir"
                            fi
                        done < <(find "$base_path" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
                    done
                done
            done
        done
    done
}

# For sets NOT in STRUCTURED_ART_SETS: additionally index every folder, at
# any depth, that holds an iGame.iff - matched by that folder's name. This
# only ADDS entries the standard index above didn't find, so a set laid out
# the standard way behaves exactly as before. If the match sits somewhere
# under a Covers/Screens/Titles folder it keeps that section's priority;
# otherwise it's filed as "Any", tried after every section for that set.
index_source_any() {
    local src_key="$1" src_root="${2%/}" f dir parent rel sec key added=0
    while IFS= read -r f; do
        dir="${f%/*}"
        [ "$dir" = "$src_root" ] && continue
        parent="${dir%/*}"
        rel="/${parent#"$src_root"}/"
        case "$rel" in
            */[Cc]overs/*|*/[Cc]over/*)   sec=Covers ;;
            */[Ss]creens/*|*/[Ss]creen/*) sec=Screens ;;
            */[Tt]itles/*|*/[Tt]itle/*)   sec=Titles ;;
            *) sec=Any ;;
        esac
        key="$src_key|$sec|${dir##*/}"
        if [ -z "${IGAME_INDEX[$key]+_}" ]; then
            IGAME_INDEX["$key"]="$dir"
            added=$((added + 1))
        fi
    done < <(find "$src_root" -type f -iname 'igame.iff' 2>/dev/null | sort)
    debug_log "  + $added extra match(es) found anywhere inside $src_root"
}

debug_log "Script directory: $SCRIPT_DIR"
debug_log "Primary artwork source: ${ART_SRC:-<none - relying on fallback chain>}"
debug_log "Destination: $DEST"
debug_log "Art merge order: ${ART_ORDER[*]}"

indexed_any_source=0
for _fbc in "${FALLBACK_CHAIN[@]}"; do
    [ "$_fbc" = "TINYLAUNCHER" ] && continue
    if [ -n "${IGAME_SET_DIR[$_fbc]+_}" ]; then
        index_source "$_fbc" "${IGAME_SET_DIR[$_fbc]}"
        case "$STRUCTURED_SETS" in
            *" $_fbc "*) ;;
            *) index_source_any "$_fbc" "${IGAME_SET_DIR[$_fbc]}" ;;
        esac
        indexed_any_source=1
        debug_log "Indexed artwork source: $_fbc -> ${IGAME_SET_DIR[$_fbc]}"
    fi
done
unset _fbc

if [ "$indexed_any_source" -eq 0 ] && [ ! -d "$TINYLAUNCHER_SRC" ]; then
    echo "ERROR: none of the artwork fallback chain's directories exist, and no"
    echo "TinyLauncher directory was found either: ${FALLBACK_CHAIN[*]}"
    exit 1
fi

if [ ! -d "$DEST/WHDLoad" ]; then
    # Not an error: artwork only applies to WHDLoad/, and a batch of new
    # downloads can legitimately contain only HD_Loaders or JST releases
    # (this used to stop the whole run with "No WHDLoad directory found").
    if [ -d "$DEST" ]; then
        echo "No WHDLoad folder in $DEST - nothing to add artwork to (only HD_Loaders/JST content)."
        exit 0
    fi
    echo "ERROR: destination folder not found: $DEST"
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

echo -e "${BOLD}==========================================${NC}"
echo -e "${BOLD} Amiga Retroplay iGame Artwork Merger ${NC}"
echo -e "${BOLD} Version: 1.8.0-fallback-chain ${NC}"
echo -e "${BOLD}==========================================${NC}"
echo -e "Platform: ${YELLOW}$(uname)${NC}"
echo -e "Detected CPU core(s): ${YELLOW}$CORES${NC}"
echo -e "Parallel job limit: ${YELLOW}$max_parallel${NC}"
echo -e "Destination directory: ${YELLOW}$DEST${NC}"
echo -e "Selected artwork source: ${YELLOW}${ART_SRC:-<none found - using fallback chain>}${NC}"
echo -e "Artwork fallback chain: ${YELLOW}${FALLBACK_CHAIN[*]}${NC}"
echo -e "Game/Mag art order: ${YELLOW}$GAME_ART_PRIORITY${NC}"
echo -e "Demo art order: ${YELLOW}$DEMO_ART_PRIORITY${NC}"
[ -d "$TINYLAUNCHER_SRC" ] && echo -e "TinyLauncher source: ${YELLOW}$TINYLAUNCHER_SRC${NC}"
[ "$DEBUG" -eq 1 ] && echo -e "${YELLOW}Debug mode: ENABLED${NC}"
echo -e "${BOLD}==========================================${NC}"
echo

whdload_path="$DEST/WHDLoad"
whdload_dirs=()
while IFS= read -r -d '' dir; do
    whdload_dirs+=( "$dir" )
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

# Temp files are removed however the script ends. Leftovers from earlier
# runs that were killed outright (their process no longer exists) are
# swept up here too.
for _tf in /tmp/artwork_merger_*.*; do
    [ -e "$_tf" ] || continue
    _pid="${_tf##*.}"
    case "$_pid" in *[!0-9]*|"") continue ;; esac
    kill -0 "$_pid" 2>/dev/null || rm -f -- "$_tf"
done
unset _tf _pid
trap 'rm -f "$ERROR_LOG" "$IGAMEECS_LOG" "$TINYLAUNCHER_LOG"' EXIT
trap 'echo -e "\nAborted. Cleaning up..."; pkill -P $$ 2>/dev/null; exit 130' INT TERM

merge_targets=()
while IFS= read -r -d '' dir; do
    base="${dir##*/}"

    # Skip known non-game helper directories
    case "$base" in
        data|Data|txt|TXT|info|Info|cfg|CFG)
            debug_log "Skipping helper directory: $dir"
            continue
            ;;
    esac

    merge_targets+=( "$dir" )
done < <(find "$whdload_path" -mindepth 1 -maxdepth 4 -type d -print0 2>/dev/null)

# Games that sort.sh has already moved into variant/language subfolders sit
# deeper than the 4 levels scanned above (e.g. WHDLoad/Languages/German/AGA/
# Games/S/SomeGame is 7 levels down) - this matters now that all.sh sorts
# BEFORE merging. Those are found by the WHDLoad drawer-icon convention:
# every extracted game directory "X" ships with an "X.info" icon beside it,
# which also cleanly excludes structural folders (AGA/, Languages/, S/ ...)
# and folders inside a game. The scan above is left exactly as it was, so
# nothing that used to get artwork can stop getting it.
while IFS= read -r -d '' _info; do
    _gd="${_info%.*}"
    [ -d "$_gd" ] && merge_targets+=( "$_gd" )
done < <(find "$whdload_path" -mindepth 5 -maxdepth 8 -type f -iname '*.info' -print0 2>/dev/null)
unset _info _gd

total_targets="${#merge_targets[@]}"

shopt -s nullglob
# Given best_dir/best_section/best_src already set (by searching
# IGAME_INDEX for the current dest_sub/dest_name), copies that source's
# artwork into dest_sub. Returns 0 if iGame.iff was actually found and
# copied there (the game is considered handled), 1 otherwise - in which
# case the caller should keep looking elsewhere (TinyLauncher, or any
# further fallback-chain entries) rather than treat this as done.
try_copy_matched_artwork() {
    [ -n "$best_dir" ] && [ -d "$best_dir" ] || return 1

    # 1) Copy all non-IFF artwork files from this section into the game dir
    #    Preserve original names; skip any that already exist.
    for f in "$best_dir"/*; do
        [ -f "$f" ] || continue
        base="${f##*/}"
        case "$base" in
            *:a314) continue ;;  # A314 bridge metadata sidecar file, not real artwork
        esac
        case "${base,,}" in
            *.iff) continue ;;  # handled separately below
        esac
        dest_file="$dest_sub/$base"
        if [ ! -e "$dest_file" ]; then
            debug_log " Non-IFF copy: $base -> ${dest_file##*/}"
            if ! cp -p "$f" "$dest_file" 2>/dev/null; then
                echo "ERROR copying non-IFF $best_section for $dest_name from $f" >> "$ERROR_LOG"
            fi
        fi
    done

    # 2) Handle the iGame.iff file according to priority index
    priority_idx=-1
    for i in "${!ART_ORDER[@]}"; do
        if [ "${ART_ORDER[$i]}" = "$best_section" ]; then
            priority_idx="$i"
            break
        fi
    done

    chosen_src_iff=""
    for f in "$best_dir"/*; do
        [ -f "$f" ] || continue
        base="${f##*/}"
        case "$base" in
            *:a314) continue ;;  # A314 bridge metadata sidecar file
        esac
        case "${base,,}" in
            igame.iff)
                chosen_src_iff="$f"
                break
                ;;
        esac
    done

    [ -z "$chosen_src_iff" ] && return 1

    base="${chosen_src_iff##*/}"
    dest_file="$dest_sub/$base"

    # Priority-based renaming for iGame.iff
    case "$priority_idx" in
        0) dest_file="$dest_sub/iGame.iff" ;;
        1) dest_file="$dest_sub/igame1.iff" ;;
        2) dest_file="$dest_sub/igame2.iff" ;;
    esac

    debug_log " iGame.iff copy: ${chosen_src_iff##*/} -> ${dest_file##*/}"

    if cp -f "$chosen_src_iff" "$dest_file" 2>/dev/null; then
        igameecs_found=1

        # 3) Paired .data handling: same stem as chosen_src_iff, only if missing in target
        src_stem="${chosen_src_iff%.*}"
        data_src="${src_stem}.data"
        if [ -f "$data_src" ]; then
            data_base="${data_src##*/}"
            data_dst="$dest_sub/$data_base"
            if [ ! -e "$data_dst" ]; then
                debug_log " Paired .data copy: $data_base -> ${data_dst##*/}"
                if ! cp -p "$data_src" "$data_dst" 2>/dev/null; then
                    echo "ERROR copying .data for $dest_name from $data_src" >> "$ERROR_LOG"
                fi
            else
                debug_log " Paired .data exists, skipping: $data_base"
            fi
        fi

        # Log iGame section usage (optional) – this drives igameecs_count
        files=( "$best_dir"/* )
        if [ ${#files[@]} -gt 0 ] && [ -e "${files[0]}" ]; then
            echo "$best_section $dest_name: ${#files[@]} files" >> "$IGAMEECS_LOG"
        fi
        return 0
    else
        echo "ERROR copying $best_section for $dest_name from $chosen_src_iff" >> "$ERROR_LOG"
        return 1
    fi
}

for dest_sub in "${merge_targets[@]}"; do
    [ -z "$dest_sub" ] && continue
    dest_name="${dest_sub##*/}"
    debug_log "Processing target: $dest_name -> $dest_sub"

    # --only-missing: skip this target entirely if it already has an
    # iGame.iff-family file (whichever priority slot it landed in) AND a
    # .data file - cheap early-out so a "fill gaps" pass doesn't redo the
    # (more expensive) fallback-chain lookup for everything that's already
    # merged, just for whatever's still actually missing.
    if [ "$ONLY_MISSING" -eq 1 ]; then
        has_iff=0
        has_data=0
        for _omf in "$dest_sub"/iGame.iff "$dest_sub"/igame1.iff "$dest_sub"/igame2.iff; do
            [ -f "$_omf" ] && has_iff=1 && break
        done
        for _omf in "$dest_sub"/*.data; do
            [ -f "$_omf" ] && has_data=1 && break
        done
        if [ "$has_iff" -eq 1 ] && [ "$has_data" -eq 1 ]; then
            debug_log "Skipping (already has artwork, --only-missing): $dest_name"
            processed=$((processed + 1))
            if (( processed % PROGRESS_STEP == 0 || processed == total_targets )); then
                progress_bar "$processed" "$total_targets" "$BAR_WIDTH"
            fi
            continue
        fi
    fi

    # Select artwork order for this directory
    # Default: non-demos use GAME_ART_PRIORITY; Demos use DEMO_ART_PRIORITY (unless overridden)
    if [[ "$dest_sub" == *"/Demos/"* ]]; then
        # Use demo-specific order (default Titles,Screens,Covers, or CLI override)
        IFS=',' read -r -a ART_ORDER <<< "$DEMO_ART_PRIORITY"
    else
        # Use standard game/mag order
        IFS=',' read -r -a ART_ORDER <<< "$GAME_ART_PRIORITY"
    fi

    # Decide TinyLauncher primary index based on first section for this directory
    primary_section="${ART_ORDER[0]}"
    case "$primary_section" in
        Covers) tl_primary_index=0 ;; # iGame.iff from _SCR0
        Titles) tl_primary_index=1 ;; # iGame.iff from _SCR1
        Screens) tl_primary_index=2 ;; # iGame.iff from _SCR2
        *)      tl_primary_index=0 ;; # sensible default
    esac

    igameecs_found=0
    tinylauncher_found=0

    best_section=""
    best_dir=""
    best_src=""

    # Walk the fallback chain in order; within each source, respect this
    # target's section priority (ART_ORDER). First hit anywhere wins.
    # (Obvious helper directories like data/txt/cfg were already filtered
    # out of merge_targets above, so every dest_sub here is worth checking
    # against both the iGame index and, below, TinyLauncher - a game that
    # only has TinyLauncher artwork and no iGame_* match must still reach
    # that check rather than being skipped early.)
    # Pass 1: everything explicitly listed BEFORE TinyLauncher in the
    # chain (the named tiers for whichever set was selected). Anything
    # appended after TINYLAUNCHER (other discovered iGame_* directories)
    # is deliberately NOT checked here - those are only tried in pass 2,
    # below, after TinyLauncher itself has already had its chance, to
    # match the intended priority order (named chain -> TinyLauncher ->
    # anything else).
    for _fbc in "${FALLBACK_CHAIN[@]}"; do
        [ "$_fbc" = "TINYLAUNCHER" ] && break
        for section in "${ART_ORDER[@]}" Any; do
            key="$_fbc|$section|$dest_name"
            if [ -n "${IGAME_INDEX[$key]+_}" ]; then
                best_section="$section"
                best_dir="${IGAME_INDEX[$key]}"
                best_src="$_fbc"
                break 2
            fi
        done
    done
    if [ -n "$best_src" ]; then
        debug_log "Matched $dest_name via $best_src ($best_section)"
    fi

    if try_copy_matched_artwork; then
        processed=$((processed + 1))
        if (( processed % PROGRESS_STEP == 0 || processed == total_targets )); then
            progress_bar "$processed" "$total_targets" "$BAR_WIDTH"
        fi
        continue
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
                    debug_log " FOUND TinyLauncher candidate: ${candidate##*/}"
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

                # We found one TinyLauncher match for this dest_name; stop checking other TL subdirs
                break
            fi
        done
    fi

    # Pass 2: still nothing after the named chain AND TinyLauncher - try
    # any OTHER discovered iGame_* directory (appended to FALLBACK_CHAIN
    # after TINYLAUNCHER). This is deliberately the LAST resort, tried
    # only once everything explicitly listed has already missed.
    if [ "$igameecs_found" -eq 0 ] && [ "$tinylauncher_found" -eq 0 ]; then
        best_section=""
        best_dir=""
        best_src=""
        _past_tl=0
        for _fbc in "${FALLBACK_CHAIN[@]}"; do
            if [ "$_past_tl" -eq 0 ]; then
                [ "$_fbc" = "TINYLAUNCHER" ] && _past_tl=1
                continue
            fi
            for section in "${ART_ORDER[@]}" Any; do
                key="$_fbc|$section|$dest_name"
                if [ -n "${IGAME_INDEX[$key]+_}" ]; then
                    best_section="$section"
                    best_dir="${IGAME_INDEX[$key]}"
                    best_src="$_fbc"
                    break 2
                fi
            done
        done
        unset _past_tl
        if [ -n "$best_src" ]; then
            debug_log "Matched $dest_name via $best_src ($best_section) [after TinyLauncher]"
        fi
        try_copy_matched_artwork
    fi

    if [ "$igameecs_found" -eq 0 ] && [ "$tinylauncher_found" -eq 0 ]; then
        debug_log "NO ARTWORK FOUND for $dest_name"
        # Only real game folders (those with a drawer icon beside them) are
        # reported, so structural folders like AGA/ or S/ never show up.
        if [ -n "$REPORT_MISSING" ] && [ -e "$dest_sub.info" ]; then
            printf '%s\n' "${dest_sub#"$DEST"/}" >> "$REPORT_MISSING"
        fi
    fi

    # Progress and counters for this dest_sub
    processed=$((processed + 1))
    if (( processed % PROGRESS_STEP == 0 || processed == total_targets )); then
        progress_bar "$processed" "$total_targets" "$BAR_WIDTH"
    fi
done

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

echo -e "${BOLD}=================== MERGE REPORT ===================${NC}"
echo "Destination: $DEST"
echo "Artwork Source: $ART_SRC"
echo "Game/Mag art order: $GAME_ART_PRIORITY"
echo "Demo art order: $DEMO_ART_PRIORITY"
echo "Elapsed Time: $fmt_time"
echo "iGame artwork merged: $igameecs_count"
echo "TinyLauncher screenshots: $tinylauncher_count"
echo "Copy errors: $errors"
echo -e "${BOLD}====================================================${NC}"

if [ $errors -ne 0 ]; then
  cp "$ERROR_LOG" "$SCRIPT_DIR/merge_errors.log"
  echo
  echo -e "${RED}ERROR: $errors errors occurred during merge.${NC}"
  echo -e "${YELLOW}See $SCRIPT_DIR/merge_errors.log for details.${NC}"
fi

if [ "$DEBUG" -eq 1 ] && [ -s "$IGAMEECS_LOG" ]; then
    echo
    echo "--- iGame Artwork Details ---"
    cat "$IGAMEECS_LOG"
fi

rm -f "$ERROR_LOG" "$IGAMEECS_LOG" "$TINYLAUNCHER_LOG"

echo
echo "Merge complete."
