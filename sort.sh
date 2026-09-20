#!/usr/bin/env bash

# Amiga Retroplay Archive Organizer & Sorter - Ultimate Edition
# Compatible: macOS, Linux, Debian 12/13, Amiga A314
# Version: 3.0.0-ultimate
#
# WHAT THIS SCRIPT DOES:
#   The last step of the pipeline. Once files are extracted (extract.sh)
#   and artwork is merged in (merge.sh), this script:
#     1. Optionally pre-cleans filenames with `detox` (external tool).
#     2. Sorts games into variant subfolders (CD32/AGA/NTSC/MT32/CDTV) and
#        language subfolders (French/German/etc.), based on suffixes in
#        each game's directory name - e.g. "SomeGame_AGA" moves under
#        WHDLoad/AGA/..., "SomeGame_De" moves under WHDLoad/Languages/German/.
#     3. Runs an Amiga filesystem compliance check over every file (illegal
#        characters, length limits for FFS/PFS), auto-fixing what it safely
#        can and logging what it can't.
#     4. Deletes directories left empty by all the moving above.
#   quick.sh and start.sh --auto both call this script as their final step.
#
# WHY PARALLEL JOBS: variant/language sorting and the compliance check can
# touch tens of thousands of files on a real collection, so both sorting
# passes run several directories at once via _start_job/wait_all_jobs
# rather than one at a time. See that section further down for how job
# failures (e.g. a job killed by the OS for using too much memory) are
# detected and reported, since a plain `wait` can't tell that apart from a
# clean finish.

set -euo pipefail

version="3.0.0-ultimate"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DEST="${DEST:-$SCRIPT_DIR/retro}"
DEST_OVERRIDE=""
DEST="$DEFAULT_DEST"
OS_TYPE="$(uname -s)"

# Detect if running on Raspberry Pi Zero 2W
IS_PI_ZERO2=false
if [[ "$OS_TYPE" != "Darwin" ]] && [ -r /proc/device-tree/model ]; then
    model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "")
    case "$model" in
        *"Raspberry Pi Zero 2 W"*)
            IS_PI_ZERO2=true
            ;;
    esac
fi

declare -a sort_summary=()
trap 'exit 130' INT TERM

BAR_WIDTH=50
processed=0
total_count=0
FS_TYPE="PFS"
FFS_LIMIT=30
PFS_LIMIT=107
MAX_FILENAME_LEN=$PFS_LIMIT
RUN_COMPLIANCE_CHECK=true
SKIP_DETOX=false
RUN_VARIANT_LANG_SORT=true

print_sort_help() {
    echo "Amiga Retroplay Archive Organizer & Sorter - Ultimate Edition"
    echo "Version: $version"
    echo ""
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -d, --dest [path]  Set custom destination directory (default: ./retro)"
    echo "  --ffs              Use FFS filesystem limits ($FFS_LIMIT character filenames)"
    echo "  --pfs              Use PFS filesystem limits ($PFS_LIMIT character filenames) [default]"
    echo "  --skipchk          Skip the Amiga filesystem compliance check entirely"
    echo "  --no-detox         Do not run detox, even if it's installed"
    echo "  --skip-variant-sort  Skip moving games into CD32/AGA/NTSC/MT32/CDTV and"
    echo "                     language subfolders. Useful when this reorganization"
    echo "                     has already been done on a shared base tree (e.g. by"
    echo "                     an earlier sort.sh pass before per-variant artwork"
    echo "                     was merged in) and only detox/compliance is wanted."
    echo "  --custom           Reserved for dispatcher integration (no-op here)"
    echo "  -h, --help         Show this help message"
    echo ""
    echo "Platform: macOS, Linux, Debian 12/13, Amiga A314 compatible"
    echo ""
    echo "Features:"
    echo "  • Parallel processing (auto-detects CPU cores)"
    echo "  • Adaptive progress bar (smooth Unicode on macOS, ASCII elsewhere)"
    echo "  • Amiga filesystem compliance checking with length-based auto-fix"
    echo "  • Progress updates every 1000 files during compliance check"
    echo "  • Detailed logging to sort.log and amiga_filename_issues.log"
    echo ""
}

# ----------------------------------------------------------------------------
# Single unified argument parser (this used to be two separate, conflicting
# loops - one that errored out on --ffs/--pfs/--skipchk before a second loop
# ever got to see them, and silently dropped --dest whenever the caller
# passed an empty placeholder argument, as start.sh does). An empty string
# argument (as start.sh passes when no --ffs/--pfs was chosen) is tolerated.
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    opt_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$opt_lc" in
        "")
            shift
            ;;
        -d|--dest)
            DEST_OVERRIDE="$2"
            shift 2
            ;;
        --custom)
            # Accept --custom from start.sh but no special behaviour needed here
            shift
            ;;
        --ffs)
            FS_TYPE="FFS"
            MAX_FILENAME_LEN=$FFS_LIMIT
            shift
            ;;
        --pfs)
            FS_TYPE="PFS"
            MAX_FILENAME_LEN=$PFS_LIMIT
            shift
            ;;
        --skipchk)
            RUN_COMPLIANCE_CHECK=false
            shift
            ;;
        --no-detox)
            SKIP_DETOX=true
            shift
            ;;
        --skip-variant-sort)
            RUN_VARIANT_LANG_SORT=false
            shift
            ;;
        -h|--help)
            print_sort_help
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done
unset opt_lc

# Use either CLI override, or default
DEST="${DEST_OVERRIDE:-$DEFAULT_DEST}"

LOGFILE="$(pwd)/sort.log"
AMIGA_ISSUES_LOG="$(pwd)/amiga_filename_issues.log"
: > "$AMIGA_ISSUES_LOG"

# Detect platform for progress bar selection

# ============================================================================
# SMOOTH UNICODE PROGRESS BAR (macOS GUI-optimized)
# ============================================================================
progress_bar_smooth() {
    local current="$1" total="$2" width="${3:-50}"
    local percent bar_len whole partial_frac partial_block left bar
    local prog_chars=(' ' '▏' '▎' '▍' '▌' '▋' '▊' '▉' '█')

    if [ "$total" -gt 0 ]; then
        percent=$((100 * current / total))
    else
        percent=0
    fi

    bar_len=$(awk "BEGIN{printf \"%.2f\", ($width * $current) / $total + 0 }")
    whole="${bar_len%.*}"
    partial_frac="0.${bar_len#*.}"
    partial_block=$(awk "BEGIN{print int(($partial_frac * 8) + 0.5)}")

    bar=""
    i=0
    while [ "$i" -lt "$whole" ]; do
        bar="${bar}█"
        i=$((i + 1))
    done

    if [ "$whole" -lt "$width" ]; then
        bar="${bar}${prog_chars[$partial_block]}"
        left=$((width - whole - 1))
    else
        left=0
    fi

    while [ "$left" -gt 0 ]; do
        bar="${bar} "
        left=$((left - 1))
    done

    printf "\r%3d%% [%-${width}s] %d/%d" "$percent" "$bar" "$current" "$total"
    tput el 2>/dev/null || true
}

# ============================================================================
# ASCII PROGRESS BAR (Debian/Linux/A314 compatible)
# ============================================================================
progress_bar_ascii() {
    local current="$1" total="$2" width="${3:-50}"
    local percent bar_len whole left bar

    if [ "$total" -gt 0 ]; then
        percent=$((100 * current / total))
    else
        percent=0
    fi

    bar_len=$((width * current / (total > 0 ? total : 1)))
    whole=$bar_len

    bar=""
    i=0
    while [ $i -lt "$whole" ]; do
        bar="${bar}#"
        i=$((i + 1))
    done

    left=$((width - whole))
    while [ $left -gt 0 ]; do
        bar="${bar}-"
        left=$((left - 1))
    done

    printf "\r%3d%% [%-${width}s] %d/%d" "$percent" "$bar" "$current" "$total"
}

# ============================================================================
# ADAPTIVE PROGRESS BAR WRAPPER
# ============================================================================
progress_bar() {
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        progress_bar_smooth "$@"
    else
        progress_bar_ascii "$@"
    fi
}

# ============================================================================
# FILENAME LENGTH HELPERS (FFS/PFS) – NO TRANSLITERATION
# ============================================================================
truncate_filename_preserve_ext() {
    local name=$1
    local maxlen=$2

    # If already within limit, return as-is
    if [ "${#name}" -le "$maxlen" ]; then
        printf '%s' "$name"
        return 0
    fi

    local base ext
    if [[ "$name" == *.* ]]; then
        base=${name%.*}
        ext=.${name##*.}
    else
        base=$name
        ext=
    fi

    local extlen=${#ext}
    local allow=$(( maxlen - extlen ))

    if [ "$allow" -lt 1 ]; then
        # Fallback: keep at least 1 char of base
        allow=1
    fi

    # Hard truncate base to allowed length
    base=${base:0:allow}
    printf '%s%s' "$base" "$ext"
}

# ============================================================================
# AMIGA FILESYSTEM COMPLIANCE CHECK (NO TRANSLITERATION)
# ============================================================================
check_path_compliance() {
    local filepath="$1"
    local filename="${filepath##*/}"
    local issues=()
    local needs_fix=false

    # Check for forbidden characters
    if [[ "$filename" == *:* ]]; then
        issues+=("contains colon (:) - not allowed")
        needs_fix=true
    fi

    if [[ "$filename" == */* ]]; then
        issues+=("contains forward slash (/) - not allowed in filenames")
        needs_fix=true
    fi

    # Check for trailing spaces
    if [[ "$filename" =~ [[:space:]]$ ]]; then
        issues+=("filename has trailing space - not recommended")
        needs_fix=true
    fi

    # Check for control characters
    if [[ "$filename" =~ [[:cntrl:]] ]]; then
        issues+=("contains control/non-printable characters - not recommended")
        needs_fix=true
    fi

    # Check filename length
    if [ ${#filename} -gt "$MAX_FILENAME_LEN" ]; then
        issues+=("filename exceeds $MAX_FILENAME_LEN chars (${FS_TYPE} limit): ${#filename} chars")
        needs_fix=true
    fi

    # Check path component lengths
    local IFS='/'
    for component in $filepath; do
        if [ -n "$component" ] && [ ${#component} -gt "$MAX_FILENAME_LEN" ]; then
            issues+=("path component exceeds $MAX_FILENAME_LEN chars (${FS_TYPE} limit): '$component' (${#component} chars)")
            needs_fix=true
            break
        fi
    done

    # Auto-fix only the length, by truncating, no transliteration
    if $needs_fix; then
        local dirpath
        dirpath=$(dirname "$filepath")

        local newfilename="$filename"

        # Apply truncation if length is the problem
        if [ ${#newfilename} -gt "$MAX_FILENAME_LEN" ]; then
            newfilename=$(truncate_filename_preserve_ext "$newfilename" "$MAX_FILENAME_LEN")
        fi

        if [ "$newfilename" != "$filename" ]; then
            # `mv -n` (no-clobber) is atomic: it refuses to overwrite an
            # existing target itself, rather than this code checking
            # existence first and moving second. That check-then-act gap
            # was previously fine only because compliance checking runs
            # sequentially - not something to depend on staying true.
            if mv -n "$filepath" "$dirpath/$newfilename" 2>/dev/null; then
                printf 'FIXED: %s -> %s\n' "$filename" "$newfilename"
                # Distinct status from "clean" (0) and "issues remain" (1)
                # so callers can tell a fix actually happened - both used
                # to return 0, so callers using `if ! ...; then` could
                # never actually reach this branch to count/report it.
                return 2
            fi
        fi
    fi

    # Report issues if any remain
    if [ ${#issues[@]} -gt 0 ]; then
        printf '%s\n' "${issues[@]}"
        return 1
    fi

    return 0
}

# ============================================================================
# PRE-CLEAN FILENAMES WITH DETOX (macOS/Linux)
# ============================================================================
# ============================================================================ 
# PRE-CLEAN FILENAMES WITH DETOX (macOS/Linux)
# ============================================================================
if [ "$SKIP_DETOX" = true ]; then
    echo "Skipping detox pre-clean (--no-detox given)."
elif command -v detox >/dev/null 2>&1; then
    echo "Pre-cleaning filenames with detox in: $DEST"
    detox -r -s utf_8 "$DEST" >/dev/null 2>&1
    echo "detox pre-clean complete."
elif [ -t 0 ]; then
    echo "detox is not installed (optional - used to pre-clean filenames)."
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        reply=""
        printf 'Install it now via Homebrew (brew install detox)? [y/N] '
        read -r reply
        case "$reply" in
            [Yy]*)
                brew install detox
                if command -v detox >/dev/null 2>&1; then
                    echo "Pre-cleaning filenames with detox in: $DEST"
                    detox -r -s utf_8 "$DEST" >/dev/null 2>&1
                    echo "detox pre-clean complete."
                else
                    echo "detox install did not succeed; skipping pre-clean."
                fi
                ;;
            *)
                echo "Skipping pre-clean."
                ;;
        esac
    else
        echo "On Linux/A314, detox needs building from source (run start.sh, which can"
        echo "offer to build it automatically) or use --no-detox to silence this prompt."
    fi
else
    echo "detox not found; skipping pre-clean (optional dependency)."
fi

# ============================================================================
# CPU CORE DETECTION (macOS/Linux/Debian compatible)
# ============================================================================
get_cpu_cores() {
    # Try Linux nproc first (Debian/Ubuntu/etc)
    if command -v nproc >/dev/null 2>&1; then
        local c
        c=$(nproc 2>/dev/null || echo "")
        if [ -n "$c" ] && [ "$c" -gt 0 ]; then
            echo "$c"
            return 0
        fi
    fi

    # Try macOS sysctl
    if command -v sysctl >/dev/null 2>&1; then
        local c
        c=$(sysctl -n hw.ncpu 2>/dev/null || echo "")
        if [ -n "$c" ] && [ "$c" -gt 0 ]; then
            echo "$c"
            return 0
        fi
    fi

    # Try Linux getconf fallback
    if command -v getconf >/dev/null 2>&1; then
        local c
        c=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo "")
        if [ -n "$c" ] && [ "$c" -gt 0 ]; then
            echo "$c"
            return 0
        fi
    fi

    # Final fallback
    echo 4
}

# Calculate optimal parallel jobs (75% of cores, capped at 16)
NUM_JOBS=$(( $(get_cpu_cores) * 3 / 4 ))
[ "$NUM_JOBS" -lt 2 ] && NUM_JOBS=2
[ "$NUM_JOBS" -gt 16 ] && NUM_JOBS=16

# Lightly cap on very low-memory devices too. These jobs just mv/cp files
# (much cheaper than extract.sh's decompression), so this is a smaller
# safety margin than extract.sh's - just enough to avoid piling on dozens
# of simultaneous file-move jobs on something like a Pi Zero 2W's 512MB.
_mem_kb=""
if [ -r /proc/meminfo ]; then
    _mem_kb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
elif command -v sysctl >/dev/null 2>&1; then
    _mem_bytes=$(sysctl -n hw.memsize 2>/dev/null)
    [ -n "$_mem_bytes" ] && _mem_kb=$((_mem_bytes / 1024))
fi
if [ -n "$_mem_kb" ] && [ "$_mem_kb" -gt 0 ] && [ "$_mem_kb" -lt 786432 ] && [ "$NUM_JOBS" -gt 4 ]; then
    NUM_JOBS=4
fi
unset _mem_kb _mem_bytes

# ============================================================================
# PARALLEL JOB MANAGEMENT
# ============================================================================
declare -a running_pids=()
declare -a running_descs=()
killed_job_descs=()

_start_job() {
    local desc="$*"
    "$@" &
    local pid=$!
    running_pids+=("$pid")
    running_descs+=("$desc")

    # Wait if job limit reached
    while [ "${#running_pids[@]}" -ge "$NUM_JOBS" ]; do
        [ ${#running_pids[@]} -eq 0 ] && break
        for i in "${!running_pids[@]}"; do
            if ! kill -0 "${running_pids[$i]}" 2>/dev/null; then
                # Job has already exited - reap it and check HOW it exited.
                # The previous version of this loop discarded the exit
                # status entirely (`|| true`), so a job killed outright
                # (e.g. by the OOM killer on a memory-constrained device)
                # was silently indistinguishable from one that finished
                # cleanly - the files it hadn't gotten to yet just stayed
                # unsorted with no warning anywhere.
                #
                # On macOS in particular, bash can lose track of a job's
                # PID between the `kill -0` check above and this `wait` -
                # showing up as "wait: pid N is not a child of this shell"
                # (exit status 127). That's not a real failure, just bash's
                # job table having already let go of a job that (almost
                # always) finished normally, so it's treated as such.
                #
                # This whole script runs under `set -e`, so `wait` must be
                # used as an `if` condition, never as a bare statement: a
                # bare `wait` for a job that exited non-zero for ANY
                # reason (killed, or just a normal error status) would
                # trigger errexit right here and silently kill this
                # entire script mid-sort, with everything not yet
                # processed just left where it was and no explanation
                # printed anywhere.
                local status
                if wait "${running_pids[$i]}" 2>/dev/null; then
                    status=0
                else
                    status=$?
                fi
                if [ "$status" -eq 127 ]; then
                    status=0
                fi
                if [ "$status" -ge 128 ]; then
                    local sig=$((status - 128))
                    echo "WARNING: background job killed (signal $sig): ${running_descs[$i]}" >&2
                    killed_job_descs+=("${running_descs[$i]}")
                fi
                unset 'running_pids[$i]'
                unset 'running_descs[$i]'
                running_pids=( "${running_pids[@]+"${running_pids[@]}"}" )
                running_descs=( "${running_descs[@]+"${running_descs[@]}"}" )
                break
            fi
        done
        sleep 0.1
    done
}

wait_all_jobs() {
    local i status sig
    if [ ${#running_pids[@]} -gt 0 ]; then
    for i in "${!running_pids[@]}"; do
        # See the matching comment in _start_job above re: macOS sometimes
        # already having reaped a finished job by the time we wait for it,
        # and re: why `wait` must be `if`-guarded rather than bare under
        # this script's `set -e`.
        if wait "${running_pids[$i]}" 2>/dev/null; then
            status=0
        else
            status=$?
        fi
        if [ "$status" -eq 127 ]; then
            status=0
        fi
        if [ "$status" -ge 128 ]; then
            sig=$((status - 128))
            echo "WARNING: background job killed (signal $sig): ${running_descs[$i]:-unknown}" >&2
            killed_job_descs+=("${running_descs[$i]:-unknown}")
        fi
    done
    fi
    running_pids=()
    running_descs=()
}

# (Argument parsing already happened in the single unified loop above.)

# Determine progress bar style message
if [[ "$OS_TYPE" == "Darwin" ]]; then
    PROGRESS_STYLE="Smooth Unicode (macOS detected)"
else
    PROGRESS_STYLE="ASCII (Linux/Debian/A314)"
fi

echo "Sorting script running in $DEST..."
echo "Platform: $OS_TYPE | CPU cores: $(get_cpu_cores) | Parallel jobs: $NUM_JOBS"
echo "Progress bar: $PROGRESS_STYLE"
echo "Filesystem type: $FS_TYPE (max filename length: $MAX_FILENAME_LEN)"

if [ "$RUN_COMPLIANCE_CHECK" = true ]; then
    echo "Compliance check: ENABLED (will auto-fix filenames)"
else
    echo "Compliance check: SKIPPED"
fi
echo

# ============================================================================
# DIRECTORY SETUP
# ============================================================================
SRC="$DEST/WHDLoad"
LANG_ROOT="$DEST/WHDLoad/Languages"

langs=(
    "French:Fr" "German:De" "Spanish:Es" "Italian:It" "Polish:Pl" "Czech:Cz" "Czech:Cs"
    "Dutch:Nl" "Danish:Dk" "Finnish:Fi" "Swedish:Sv" "Sweden:Se" "Norwegian:No" "Portuguese:Pt"
    "Hungarian:Hu" "Russian:Ru" "Greek:Gr" "Turkish:Tr" "Slovak:Sk" "Croatian:Hr" "Serbian:Sr"
    "Bulgarian:Bg" "Romanian:Ro" "Slovenian:Si" "Estonian:Et" "Latvian:Lv" "Lithuanian:Lt"
)

# ============================================================================
# MOVE AND TAG FUNCTION (with language detection)
# ============================================================================
move_and_tag() {
    local variant="$1"
    local src_dir="$2"
    local rel_path="${src_dir#$SRC/}"
    local language_found=""

    # Check for language suffix
    local name
    name="$(basename "$src_dir")"
    for entry in "${langs[@]}"; do
        local lang="${entry%%:*}"
        local code="${entry##*:}"
        # Case-sensitive, exact language code at end of basename
        if [[ "$name" =~ ${code}$ ]]; then
            language_found="$lang"
            break
        fi
    done

    local dest_path
    if [ -n "$language_found" ]; then
        dest_path="$LANG_ROOT/$language_found/$rel_path"
    else
        dest_path="$SRC/$variant/$rel_path"
    fi

    # Move .info file
    local info_file
    info_file="$(dirname "$src_dir")/$(basename "$src_dir").info"
    local new_info_file
    new_info_file="$(dirname "$dest_path")/$(basename "$dest_path").info"

    mkdir -p "$(dirname "$new_info_file")"

    if [ -e "$info_file" ] && [ ! -e "$new_info_file" ]; then
        mv "$info_file" "$new_info_file" > /dev/null 2>> "$LOGFILE"
    fi

    # Move directory
    mkdir -p "$(dirname "$dest_path")"
    if [ ! -e "$dest_path" ]; then
        mv "$src_dir" "$dest_path" > /dev/null 2>> "$LOGFILE"
    fi
}

# ============================================================================
# MOVE LANGUAGE FUNCTION
# ============================================================================
move_lang() {
    local lang="$1" code="$2" dir="$3" lang_dir="$4"
    local relpath="${dir#$SRC/}"
    local newpath="$lang_dir/$relpath"
    local info_file
    info_file="$(dirname "$dir")/$(basename "$dir").info"
    local new_info_path
    new_info_path="$(dirname "$newpath")/$(basename "$dir").info"

    mkdir -p "$(dirname "$new_info_path")"

    if [ -f "$info_file" ] && [ ! -e "$new_info_path" ]; then
        mv "$info_file" "$new_info_path" > /dev/null 2>> "$LOGFILE"
    fi

    mkdir -p "$(dirname "$newpath")"
    if [ ! -e "$newpath" ]; then
        mv "$dir" "$newpath" > /dev/null 2>> "$LOGFILE"
    fi
}

# ============================================================================
# VARIANT SORTING (CD32, AGA, NTSC, MT32, CDTV) - with parallel processing
# ============================================================================
variant_sort_strict() {
    local variant="$1"
    echo "Sorting $variant"
    local found_dirs=()

    for search_dir in "$SRC" "$SRC/Games" "$SRC/Demos" "$SRC/Magazines"; do
        if [ -d "$search_dir" ]; then
            while IFS= read -r -d '' dir; do
                local name
                name="$(basename "$dir")"

                case "$variant" in
                    CD32)
                        # Highest priority: exact end with _AGA_CD32
                        if [[ "$name" == *_AGA_CD32 ]]; then
                            found_dirs+=("$dir")
                        # Any appearance of CD32 in the name
                        elif [[ "$name" == *CD32* ]]; then
                            found_dirs+=("$dir")
                        fi
                        ;;
                    AGA)
                        # Exclude names ending with _AGA_CD32 (handled by CD32)
                        if [[ "$name" == *_AGA_CD32 ]]; then
                            :
                        elif [[ "$name" == *_AGA ]]; then
                            found_dirs+=("$dir")
                        elif echo "$name" | grep -Eq 'AGA[a-zA-Z]{2}$'; then
                            found_dirs+=("$dir")
                        elif echo "$name" | grep -Eq 'AGA([0-9][0-9]?MB)?$|AGA$|AGA_.*$' && \
                             ! echo "$name" | grep -Eq 'CD32AGA$'; then
                            found_dirs+=("$dir")
                        fi
                        ;;
                    NTSC|MT32|CDTV)
                        if echo "$name" | grep -Eq "${variant}$|${variant}[a-zA-Z]{2}$|${variant}_.*$"; then
                            found_dirs+=("$dir")
                        fi
                        ;;
                esac
            done < <(find "$search_dir" -mindepth 1 -maxdepth 2 -type d -print0 2>/dev/null || true)
        fi
    done

    sort_summary+=("$variant | ${#found_dirs[@]} found")
    [ ${#found_dirs[@]} -eq 0 ] && return 0

    local variant_total=${#found_dirs[@]}
    local variant_processed=0

    for src_dir in "${found_dirs[@]}"; do
        _start_job move_and_tag "$variant" "$src_dir"
        variant_processed=$((variant_processed + 1))
        progress_bar "$variant_processed" "$variant_total" "$BAR_WIDTH"
    done

    printf "\n"
    wait_all_jobs
}

## ============================================================================
# LANGUAGE SORTING - with parallel processing and progress bar
# ============================================================================
lang_sort() {
    echo "Sorting Languages (Be patient...)"

    # Determine source root: /retro/WHDLoad or /WHDLoad under custom destination
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    DEFAULT_DEST="$SCRIPT_DIR/retro"
    DEST="${DEST_OVERRIDE:-$DEFAULT_DEST}"

    SRC="$DEST/WHDLoad"

    # Build search list: all subdirs under WHDLoad except Languages
    variant_dirs=()
    for dir in "$SRC"/*; do
        [ -d "$dir" ] && [ "$(basename "$dir")" != "Languages" ] && variant_dirs+=("$dir")
    done

    # First pass: count total language directories to be moved
    local lang_total=0
    for entry in "${langs[@]}"; do
        local lang="${entry%%:*}"
        local code="${entry##*:}"
        local dir_matches=()
        for search_dir in "${variant_dirs[@]+"${variant_dirs[@]}"}"; do
            if [ -d "$search_dir" ]; then
                while IFS= read -r -d '' dir; do
                    local name
                    name="$(basename "$dir")"
                    # Case-sensitive, exact language code at end of basename
                    if [[ "$name" =~ ${code}$ ]]; then
                        dir_matches+=("$dir")
                    fi
                done < <(find "$search_dir" -mindepth 1 -maxdepth 2 -type d -print0 2>/dev/null || true)
            fi
        done
        lang_total=$((lang_total + ${#dir_matches[@]}))
    done

    # Second pass: actually move each language directory with progress
    local lang_processed=0
    for entry in "${langs[@]}"; do
        local lang="${entry%%:*}"
        local code="${entry##*:}"
        local lang_dir="$SRC/Languages/$lang"
        local dir_matches=()
        for search_dir in "${variant_dirs[@]+"${variant_dirs[@]}"}"; do
            if [ -d "$search_dir" ]; then
                while IFS= read -r -d '' dir; do
                    local name
                    name="$(basename "$dir")"
                    # Case-sensitive, exact language code at end of basename
                    if [[ "$name" =~ ${code}$ ]]; then
                        dir_matches+=("$dir")
                    fi
                done < <(find "$search_dir" -mindepth 1 -maxdepth 2 -type d -print0 2>/dev/null || true)
            fi
        done

        local total_items=${#dir_matches[@]}
        sort_summary+=("$lang | $total_items found")
        [ $total_items -eq 0 ] && continue

        mkdir -p "$lang_dir"

        for dir in "${dir_matches[@]}"; do
            _start_job move_lang "$lang" "$code" "$dir" "$lang_dir"
            lang_processed=$((lang_processed + 1))
            progress_bar "$lang_processed" "$lang_total" "$BAR_WIDTH"
        done
    done

    printf "\n"
    wait_all_jobs
    echo "Language sorting complete."
}

# ============================================================================
# MAIN SORTING OPERATIONS
# ============================================================================
if [ "$RUN_VARIANT_LANG_SORT" = true ]; then
    variant_sort_strict "CD32"
    variant_sort_strict "AGA"
    variant_sort_strict "NTSC"
    variant_sort_strict "MT32"
    variant_sort_strict "CDTV"
    lang_sort
fi

# The langs[] table has more than one code for some display names (e.g.
# "Czech:Cz" and "Czech:Cs"), so lang_sort's loop above appends a separate
# summary line per CODE, not per display name - without this merge step,
# "Czech" would show up twice with two different partial counts, which
# looks like a bug even though each line was individually correct. Merge
# any lines sharing the same name (first word before " | ") by summing
# their counts into one line, keeping first-seen order. Variant lines
# (CD32/AGA/NTSC/MT32/CDTV) pass through unchanged since their names never
# repeat.
merge_duplicate_summary_lines() {
    local -a names=() totals=()
    local line name count i found
    for line in "${sort_summary[@]+"${sort_summary[@]}"}"; do
        name="${line%% | *}"
        count="${line##* | }"
        count="${count% found}"
        found=0
        if [ ${#names[@]} -gt 0 ]; then
        for i in "${!names[@]}"; do
            if [ "${names[$i]}" = "$name" ]; then
                totals[$i]=$((totals[$i] + count))
                found=1
                break
            fi
        done
        fi
        if [ "$found" -eq 0 ]; then
            names+=("$name")
            totals+=("$count")
        fi
    done
    sort_summary=()
    if [ ${#names[@]} -gt 0 ]; then
    for i in "${!names[@]}"; do
        sort_summary+=("${names[$i]} | ${totals[$i]} found")
    done
    fi
}
merge_duplicate_summary_lines

echo
echo "======== SORTING SUMMARY ========"
for summary_line in "${sort_summary[@]+"${sort_summary[@]}"}"; do
    echo "$summary_line"
done
echo "================================="
echo

if [ "${#killed_job_descs[@]}" -gt 0 ]; then
    echo "WARNING: ${#killed_job_descs[@]} background sorting job(s) were killed mid-run"
    echo "(most likely out-of-memory on this device). Some files may not have been"
    echo "moved/sorted. Affected jobs:"
    printf '  %s\n' "${killed_job_descs[@]+"${killed_job_descs[@]}"}"
    echo "Re-running sort.sh is safe - already-sorted files are left alone."
    echo
fi

# ============================================================================
# AMIGA FILESYSTEM COMPLIANCE CHECK
# ============================================================================
if [ "$RUN_COMPLIANCE_CHECK" = true ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    DEFAULT_DEST="$SCRIPT_DIR/retro"

    # If -d/--dest was given, only check that path; otherwise behave as before.
    if [ -n "$DEST_OVERRIDE" ]; then
        CHECK_ROOT="$DEST_OVERRIDE"
    else
        CHECK_ROOT="${DEST_OVERRIDE:-$DEFAULT_DEST}"
    fi

    echo "Performing Amiga filesystem compliance check ($FS_TYPE: max $MAX_FILENAME_LEN chars) in: $CHECK_ROOT"
    echo

    # Collect the full file list once (NUL-delimited, so filenames with
    # spaces or unusual characters survive intact), then split it into
    # NUM_JOBS contiguous chunks so multiple worker processes can run
    # check_path_compliance concurrently - real-world collections have
    # been seen with 200k+ files, where a single-threaded scan is slow.
    # Safe to parallelize because check_path_compliance's rename uses
    # atomic `mv -n`: if two workers ever raced to truncate two different
    # long names down to the same result, the loser's rename simply fails
    # cleanly rather than clobbering the winner - that file is just left
    # for a later pass, not silently lost.
    all_files=()
    while IFS= read -r -d '' f; do
        case "$f" in
            *:a314) continue ;;  # A314 bridge metadata sidecar file, not a real file
        esac
        all_files+=("$f")
    done < <(find "$CHECK_ROOT" -type f ! -name '*:a314' -print0 2>/dev/null)

    total_files=${#all_files[@]}
    total_scanned=0
    files_fixed=0
    issues_found=0

    if [ "$total_files" -eq 0 ]; then
        echo "✓ No files to check."
    else
        compliance_tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/sort_compliance.XXXXXX")"

        chunk_size=$(( (total_files + NUM_JOBS - 1) / NUM_JOBS ))
        [ "$chunk_size" -lt 1 ] && chunk_size=1

        compliance_result_files=()
        compliance_issue_files=()
        compliance_progress_files=()
        compliance_pids=()

        idx=0
        chunk_num=0
        while [ "$idx" -lt "$total_files" ]; do
            chunk_num=$((chunk_num + 1))
            chunk_file="$compliance_tmpdir/chunk_$chunk_num"
            : > "$chunk_file"
            end=$((idx + chunk_size))
            [ "$end" -gt "$total_files" ] && end="$total_files"
            for (( j=idx; j<end; j++ )); do
                printf '%s\0' "${all_files[$j]}" >> "$chunk_file"
            done
            idx="$end"

            result_file="$compliance_tmpdir/result_$chunk_num"
            issue_file="$compliance_tmpdir/issues_$chunk_num"
            progress_file="$compliance_tmpdir/progress_$chunk_num"
            : > "$issue_file"
            echo 0 > "$progress_file"
            compliance_result_files+=("$result_file")
            compliance_issue_files+=("$issue_file")
            compliance_progress_files+=("$progress_file")

            (
                set +e   # see the note above the main check inside this
                         # loop: this worker has its own explicit status
                         # handling throughout, so errexit (inherited from
                         # the parent script's `set -e`) only creates risk
                         # here, with no benefit - disable it for the
                         # whole worker rather than auditing every single
                         # command in it for exemption from that risk.
                local_scanned=0
                local_fixed=0
                local_issues=0
                while IFS= read -r -d '' file; do
                    local_scanned=$((local_scanned + 1))
                    # Using the assignment as the `if` condition (rather
                    # than a bare `issues=$(...); status=$?`) matters here
                    # because this script runs under `set -e`: a bare
                    # assignment statement that fails would trigger
                    # errexit immediately, silently killing this whole
                    # background worker mid-chunk (with everything after
                    # that point in its chunk left completely unscanned).
                    # A command tested by `if` is exempt from errexit
                    # regardless of its exit status, so this form is safe.
                    if issues=$(check_path_compliance "$file" 2>&1); then
                        :
                    else
                        status=$?
                        if [ "$status" -eq 2 ]; then
                            local_fixed=$((local_fixed + 1))
                        elif [ "$status" -eq 1 ]; then
                            local_issues=$((local_issues + 1))
                            {
                                echo "$file"
                                while IFS= read -r issue; do
                                    echo " → $issue"
                                done <<< "$issues"
                            } >> "$issue_file"
                        fi
                    fi
                    if (( local_scanned % 200 == 0 )); then
                        echo "$local_scanned" > "$progress_file"
                    fi
                done < "$chunk_file"
                echo "$local_scanned" > "$progress_file"
                echo "$local_scanned $local_fixed $local_issues" > "$result_file"
            ) &
            compliance_pids+=("$!")
        done

        # Poll aggregate progress across all workers while they run.
        while :; do
            still_running=0
            for pid in "${compliance_pids[@]+"${compliance_pids[@]}"}"; do
                kill -0 "$pid" 2>/dev/null && still_running=1
            done
            sum=0
            for pf in "${compliance_progress_files[@]+"${compliance_progress_files[@]}"}"; do
                n=$(cat "$pf" 2>/dev/null) || n=0
                [ -n "$n" ] && sum=$((sum + n))
            done
            printf "\rScanned: %d/%d files" "$sum" "$total_files"
            [ "$still_running" -eq 0 ] && break
            sleep 0.5
        done
        printf "\r%-60s\n" " "

        for pid in "${compliance_pids[@]+"${compliance_pids[@]}"}"; do
            # `wait` must be `if`-guarded, not bare, under this script's
            # `set -e` - see _start_job's comment for why - and the 127
            # case (macOS job-table quirk) is treated as fine, not an
            # error, same as the other job-wait spots in this script.
            if wait "$pid" 2>/dev/null; then
                :
            else
                wstatus=$?
                [ "$wstatus" -eq 127 ] || true
            fi
        done

        for rf in "${compliance_result_files[@]+"${compliance_result_files[@]}"}"; do
            [ -f "$rf" ] || continue
            read -r rs rfx ri < "$rf" || true
            total_scanned=$((total_scanned + ${rs:-0}))
            files_fixed=$((files_fixed + ${rfx:-0}))
            issues_found=$((issues_found + ${ri:-0}))
        done

        : > "$AMIGA_ISSUES_LOG"
        for f in "${compliance_issue_files[@]+"${compliance_issue_files[@]}"}"; do
            [ -s "$f" ] && cat "$f" >> "$AMIGA_ISSUES_LOG"
        done

        rm -rf "$compliance_tmpdir"
    fi

    if [ $files_fixed -gt 0 ]; then
        echo "✓ Fixed $files_fixed file(s) by truncating long filenames to ${MAX_FILENAME_LEN} chars."
    fi

    if [ $issues_found -gt 0 ]; then
        echo "⚠ WARNING: Found $issues_found filename(s) with Amiga compliance issues."
        echo "Full details saved to: $AMIGA_ISSUES_LOG"
        echo
    else
        echo "✓ All $total_scanned filenames are Amiga filesystem compliant ($FS_TYPE)."
    fi

    echo
fi

# ============================================================================
# CLEANUP EMPTY DIRECTORIES
# ============================================================================
echo "Deleting empty directories in $DEST ..."
find "$DEST" -type d -empty -delete 2>/dev/null || true

echo "✓ Sort operation complete. (Check contents of $DEST)"
