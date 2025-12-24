#!/usr/bin/env bash

# Amiga Retroplay Archive Organizer & Sorter - Ultimate Edition
# Compatible: macOS, Linux, Debian 12/13, Amiga A314
# Version: 3.0.0-ultimate

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

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dest)
            DEST_OVERRIDE="$2"
            shift 2
            ;;
        --custom)
            # Accept --custom from start.sh but no special behaviour needed here
            shift
            ;;
        -h|--help)
            echo "Usage: $(basename "$0") [options]"
            echo "Options:"
            echo "  -d, --dest [path]  Set custom destination directory (default: ./retro)"
            echo "  -h, --help         Show this help"
            echo "  --ffs              Sort for Amiga FFS compliance (PFS is the default)"
            echo "  --skipchk          Skip compliance check"
            echo "  --custom           Reserved for dispatcher integration (no-op here)"
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# Use either CLI override, or default
DEST="${DEST_OVERRIDE:-$DEFAULT_DEST}"

declare -a sort_summary=()
trap 'exit 130' INT TERM

BAR_WIDTH=50
processed=0
total_count=0
FS_TYPE="PFS"
FFS_LIMIT=25
PFS_LIMIT=100
MAX_FILENAME_LEN=$PFS_LIMIT
RUN_COMPLIANCE_CHECK=true

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

        if [ "$newfilename" != "$filename" ] && [ ! -e "$dirpath/$newfilename" ]; then
            mv "$filepath" "$dirpath/$newfilename" 2>/dev/null
            printf 'FIXED: %s -> %s\n' "$filename" "$newfilename"
            return 0
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
if command -v detox >/dev/null 2>&1; then
    # Only pre-clean a custom destination if explicitly passed via -d/--dest.
    if [ -n "$DEST_OVERRIDE" ]; then
        echo "Pre-cleaning filenames with detox in: $DEST_OVERRIDE"
        detox -r -s utf_8 "$DEST_OVERRIDE" >/dev/null 2>&1
        echo "detox pre-clean complete."
    else
        echo "detox not run (no -d/--dest override specified)."
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

# ============================================================================
# PARALLEL JOB MANAGEMENT
# ============================================================================
declare -a running_pids=()

_start_job() {
    "$@" &
    local pid=$!
    running_pids+=("$pid")

    # Wait if job limit reached
    while [ "${#running_pids[@]}" -ge "$NUM_JOBS" ]; do
        for i in "${!running_pids[@]}"; do
            if ! kill -0 "${running_pids[$i]}" 2>/dev/null; then
                wait "${running_pids[$i]}" 2>/dev/null || true
                unset 'running_pids[$i]'
                running_pids=( "${running_pids[@]}" )
                break
            fi
        done
        sleep 0.1
    done
}

wait_all_jobs() {
    for pid in "${running_pids[@]:-}"; do
        wait "$pid" 2>/dev/null || true
    done
    running_pids=()
}

# ============================================================================
# COMMAND LINE ARGUMENT PROCESSING
# ============================================================================
for arg in "$@"; do
    case "$arg" in
        --ffs)
            FS_TYPE="FFS"
            MAX_FILENAME_LEN=$FFS_LIMIT
            ;;
        --pfs)
            FS_TYPE="PFS"
            MAX_FILENAME_LEN=$PFS_LIMIT
            ;;
        --skipchk)
            RUN_COMPLIANCE_CHECK=false
            ;;
        --help)
            echo "Amiga Retroplay Archive Organizer & Sorter - Ultimate Edition"
            echo "Version: $version"
            echo ""
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --ffs       Use FFS filesystem limits (30 character filenames)"
            echo "  --pfs       Use PFS filesystem limits (107 character filenames) [default]"
            echo "  --skipchk   Skip the Amiga filesystem compliance check entirely"
            echo "  --help      Show this help message"
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
            exit 0
            ;;
    esac
done

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
        for search_dir in "${variant_dirs[@]}"; do
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
        for search_dir in "${variant_dirs[@]}"; do
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
variant_sort_strict "CD32"
variant_sort_strict "AGA"
variant_sort_strict "NTSC"
variant_sort_strict "MT32"
variant_sort_strict "CDTV"
lang_sort

echo
echo "======== SORTING SUMMARY ========"
for summary_line in "${sort_summary[@]}"; do
    echo "$summary_line"
done
echo "================================="
echo

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

    issues_found=0
    total_scanned=0
    files_fixed=0
    total_files=$(find "$CHECK_ROOT" -type f 2>/dev/null | wc -l)

    while IFS= read -r -d '' file; do
        total_scanned=$((total_scanned + 1))

        # Progress update every 1000 files
        if (( total_scanned % 1000 == 0 )); then
            printf "\rScanned: %d/%d files" "$total_scanned" "$total_files"
        fi

        if ! issues=$(check_path_compliance "$file" 2>&1); then
            if echo "$issues" | grep -q "^FIXED:"; then
                files_fixed=$((files_fixed + 1))
                echo ""
                echo "$issues"
            else
                issues_found=$((issues_found + 1))
                echo ""
                echo "$file"
                while IFS= read -r issue; do
                    echo " → $issue"
                done <<< "$issues"

                # Log to file
                echo "$file" >> "$AMIGA_ISSUES_LOG"
                while IFS= read -r issue; do
                    echo " → $issue" >> "$AMIGA_ISSUES_LOG"
                done <<< "$issues"
            fi
        fi
    done < <(find "$CHECK_ROOT" -type f -print0 2>/dev/null)

    printf "\r%-60s\n" " "

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
