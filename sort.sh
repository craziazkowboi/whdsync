#!/usr/bin/env bash

# Amiga Retroplay Archive Organizer & Sorter - Ultimate Edition
# Compatible: macOS, Linux, Debian 12/13, Amiga A314
# Version: 3.0.0-ultimate

set -euo pipefail

version="3.0.0-ultimate"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DEST="$SCRIPT_DIR/retro"
dest_path="${DEST:-$SCRIPT_DIR/retro}"
DEST_OVERRIDE=""
DEST="${DEST_OVERRIDE:-$DEFAULT_DEST}"

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
            echo "  --ffs              Sort for Amiga FFS compliance"
            echo "  --pfs              Sort for Amiga PFS3 compliance"
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
FFS_LIMIT=27
PFS_LIMIT=100
MAX_FILENAME_LEN=$PFS_LIMIT
RUN_COMPLIANCE_CHECK=true

# Detect platform for progress bar selection
OS_TYPE="$(uname -s)"

# ============================================================================
# SMOOTH UNICODE PROGRESS BAR (macOS GUI-optimized)
# Uses 8-level Unicode blocks for buttery-smooth animation
# ============================================================================
progress_bar_smooth() {
    local current="$1" total="$2" width="${3:-50}"
    local percent bar_len whole partial partial_block left bar
    local prog_chars=(' ' '▏' '▎' '▍' '▌' '▋' '▊' '▉' '█')
    
    # Calculate percentage
    if [ "$total" -gt 0 ]; then
        percent=$((100 * current / total))
    else
        percent=0
    fi
    
    # Calculate floating-point bar length for smooth rendering
    bar_len=$(awk "BEGIN{printf \"%.2f\", ($width * $current) / $total + 0 }")
    
    # Split into whole and fractional parts
    whole="${bar_len%.*}"
    partial_frac="0.${bar_len#*.}"
    
    # Calculate which partial block character to use (0-8)
    partial_block=$(awk "BEGIN{print int(($partial_frac * 8) + 0.5)}")
    
    # Build the filled portion with full blocks
    bar=""
    i=0
    while [ "$i" -lt "$whole" ]; do
        bar="${bar}█"
        i=$((i + 1))
    done
    
    # Add partial block if we haven't filled the entire width
    if [ "$whole" -lt "$width" ]; then
        bar="${bar}${prog_chars[$partial_block]}"
        left=$((width - whole - 1))
    else
        left=0
    fi
    
    # Fill remaining space with blanks
    while [ "$left" -gt 0 ]; do
        bar="${bar} "
        left=$((left - 1))
    done
    
    printf "\r%3d%% [%-${width}s] %d/%d" "$percent" "$bar" "$current" "$total"
    tput el 2>/dev/null || true
}

# ============================================================================
# ASCII PROGRESS BAR (Debian/Linux/A314 compatible)
# Pure ASCII for maximum compatibility
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
# Automatically selects smooth Unicode on macOS, ASCII elsewhere
# ============================================================================
progress_bar() {
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        progress_bar_smooth "$@"
    else
        progress_bar_ascii "$@"
    fi
}

# ============================================================================
# COMPREHENSIVE FILENAME TRANSLITERATION (100+ character mappings)
# Handles international characters from European Amiga game archives
# ============================================================================
transliterate_filename() {
    local input="$1"
    local output="$input"
    
    # ========== PUNCTUATION & SPECIAL MARKS ==========
    output="${output//—/-}"   # Em dash
    output="${output//–/-}"   # En dash
    output="${output//‐/-}"   # Hyphen
    output="${output//−/-}"   # Minus sign
    output="${output//―/-}"   # Horizontal bar
    output="${output//…/...}" # Ellipsis
    
    # ========== SMART QUOTES ==========
    output="${output//'/\'}"  # Left/right single quote
    output="${output//\"/\"}" # Left/right double quote
    output="${output//„/\"}"  # Double low-9 quotation mark
    output="${output//‚/\'}"  # Single low-9 quotation mark
    output="${output//«/\"}"  # Left-pointing double angle quotation
    output="${output//»/\"}"  # Right-pointing double angle quotation
    output="${output//‹/\'}"  # Left-pointing single angle quotation
    output="${output//›/\'}"  # Right-pointing single angle quotation
    
    # ========== LATIN ACCENTED CHARACTERS - LOWERCASE A ==========
    output="${output//á/a}"; output="${output//à/a}"; output="${output//â/a}"
    output="${output//ä/a}"; output="${output//ã/a}"; output="${output//å/a}"
    output="${output//ā/a}"; output="${output//ą/a}"; output="${output//ă/a}"
    
    # ========== LATIN ACCENTED CHARACTERS - UPPERCASE A ==========
    output="${output//Á/A}"; output="${output//À/A}"; output="${output//Â/A}"
    output="${output//Ä/A}"; output="${output//Ã/A}"; output="${output//Å/A}"
    output="${output//Ā/A}"; output="${output//Ą/A}"; output="${output//Ă/A}"
    
    # ========== LATIN ACCENTED CHARACTERS - LOWERCASE E ==========
    output="${output//é/e}"; output="${output//è/e}"; output="${output//ê/e}"
    output="${output//ë/e}"; output="${output//ē/e}"; output="${output//ė/e}"
    output="${output//ę/e}"; output="${output//ě/e}"
    
    # ========== LATIN ACCENTED CHARACTERS - UPPERCASE E ==========
    output="${output//É/E}"; output="${output//È/E}"; output="${output//Ê/E}"
    output="${output//Ë/E}"; output="${output//Ē/E}"; output="${output//Ė/E}"
    output="${output//Ę/E}"; output="${output//Ě/E}"
    
    # ========== LATIN ACCENTED CHARACTERS - LOWERCASE I ==========
    output="${output//í/i}"; output="${output//ì/i}"; output="${output//î/i}"
    output="${output//ï/i}"; output="${output//ī/i}"; output="${output//į/i}"
    
    # ========== LATIN ACCENTED CHARACTERS - UPPERCASE I ==========
    output="${output//Í/I}"; output="${output//Ì/I}"; output="${output//Î/I}"
    output="${output//Ï/I}"; output="${output//Ī/I}"; output="${output//Į/I}"
    
    # ========== LATIN ACCENTED CHARACTERS - LOWERCASE O ==========
    output="${output//ó/o}"; output="${output//ò/o}"; output="${output//ô/o}"
    output="${output//ö/o}"; output="${output//õ/o}"; output="${output//ō/o}"
    output="${output//ő/o}"; output="${output//ø/o}"
    
    # ========== LATIN ACCENTED CHARACTERS - UPPERCASE O ==========
    output="${output//Ó/O}"; output="${output//Ò/O}"; output="${output//Ô/O}"
    output="${output//Ö/O}"; output="${output//Õ/O}"; output="${output//Ō/O}"
    output="${output//Ő/O}"; output="${output//Ø/O}"
    
    # ========== LATIN ACCENTED CHARACTERS - LOWERCASE U ==========
    output="${output//ú/u}"; output="${output//ù/u}"; output="${output//û/u}"
    output="${output//ü/u}"; output="${output//ū/u}"; output="${output//ų/u}"
    output="${output//ű/u}"; output="${output//ů/u}"
    
    # ========== LATIN ACCENTED CHARACTERS - UPPERCASE U ==========
    output="${output//Ú/U}"; output="${output//Ù/U}"; output="${output//Û/U}"
    output="${output//Ü/U}"; output="${output//Ū/U}"; output="${output//Ų/U}"
    output="${output//Ű/U}"; output="${output//Ů/U}"
    
    # ========== LATIN ACCENTED CHARACTERS - Y ==========
    output="${output//ý/y}"; output="${output//ÿ/y}"; output="${output//ȳ/y}"
    output="${output//Ý/Y}"; output="${output//Ÿ/Y}"; output="${output//Ȳ/Y}"
    
    # ========== LATIN ACCENTED CHARACTERS - N ==========
    output="${output//ñ/n}"; output="${output//ń/n}"; output="${output//ň/n}"
    output="${output//Ñ/N}"; output="${output//Ń/N}"; output="${output//Ň/N}"
    
    # ========== LATIN ACCENTED CHARACTERS - C ==========
    output="${output//ç/c}"; output="${output//ć/c}"; output="${output//č/c}"
    output="${output//Ç/C}"; output="${output//Ć/C}"; output="${output//Č/C}"
    
    # ========== GERMAN SPECIAL CHARACTERS ==========
    output="${output//ß/ss}"  # German sharp s (Eszett)
    
    # ========== LIGATURES ==========
    output="${output//æ/ae}"; output="${output//Æ/AE}"  # Latin ae ligature
    output="${output//œ/oe}"; output="${output//Œ/OE}"  # Latin oe ligature
    
    # ========== POLISH SPECIAL CHARACTERS ==========
    output="${output//ł/l}"; output="${output//Ł/L}"  # Polish L with stroke
    output="${output//ś/s}"; output="${output//Ś/S}"  # Polish S with acute
    output="${output//ź/z}"; output="${output//Ź/Z}"  # Polish Z with acute
    output="${output//ż/z}"; output="${output//Ż/Z}"  # Polish Z with dot above
    
    # ========== CZECH/SLOVAK SPECIAL CHARACTERS ==========
    output="${output//ď/d}"; output="${output//Ď/D}"  # D with caron
    output="${output//ř/r}"; output="${output//Ř/R}"  # R with caron
    output="${output//š/s}"; output="${output//Š/S}"  # S with caron
    output="${output//ť/t}"; output="${output//Ť/T}"  # T with caron
    output="${output//ž/z}"; output="${output//Ž/Z}"  # Z with caron
    
    # ========== SPECIAL SYMBOLS & COPYRIGHT ==========
    output="${output//°/deg}"   # Degree sign
    output="${output//©/(c)}"   # Copyright symbol
    output="${output//®/(R)}"   # Registered trademark
    output="${output//™/(TM)}"  # Trademark symbol
    
    # ========== CURRENCY SYMBOLS ==========
    output="${output//€/EUR}"  # Euro
    output="${output//£/GBP}"  # Pound sterling
    output="${output//¥/YEN}"  # Yen
    output="${output//¢/c}"    # Cent
    
    # ========== MATHEMATICAL SYMBOLS ==========
    output="${output//×/x}"    # Multiplication sign
    output="${output//÷//}"    # Division sign
    output="${output//±/+-}"   # Plus-minus sign
    output="${output//•/*}"    # Bullet
    output="${output//·/.}"    # Middle dot
    
    # ========== AMIGA-FORBIDDEN CHARACTERS ==========
    output="${output//:/-}"    # Colon (forbidden on Amiga)
    
    # Remove trailing spaces (causes issues on Amiga filesystems)
    output="$(printf "%s" "$output" | sed 's/[[:space:]]\+$//')"
    
    echo "$output"
}

# ============================================================================
# AMIGA FILESYSTEM COMPLIANCE CHECK
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
    
    # Check for non-ASCII characters
    if [[ "$filename" =~ [^[:ascii:]] ]]; then 
        issues+=("contains non-ASCII characters - can be transliterated")
        needs_fix=true
    fi
    
    # Check filename length
    if [ ${#filename} -gt "$MAX_FILENAME_LEN" ]; then 
        issues+=("filename exceeds $MAX_FILENAME_LEN chars (${FS_TYPE} limit): ${#filename} chars")
    fi
    
    # Check path component lengths
    local IFS='/'
    for component in $filepath; do
        if [ -n "$component" ] && [ ${#component} -gt "$MAX_FILENAME_LEN" ]; then
            issues+=("path component exceeds $MAX_FILENAME_LEN chars (${FS_TYPE} limit): '$component' (${#component} chars)")
            break
        fi
    done
    
    # Attempt auto-fix if needed
    if [ ${#issues[@]} -gt 0 ] && [ "$needs_fix" = true ]; then
        local dir_path="$(dirname "$filepath")"
        local new_filename="$(transliterate_filename "$filename")"
        
        if [ "$new_filename" != "$filename" ] && [ ! -e "$dir_path/$new_filename" ]; then
            mv "$filepath" "$dir_path/$new_filename" 2>/dev/null && {
                printf "FIXED: %s → %s\n" "$filename" "$new_filename"
                return 0
            }
        fi
    fi
    
    # Report issues if any remain
    if [ ${#issues[@]} -gt 0 ]; then
        printf '%s\n' "${issues[@]}"
        local suggested="$(transliterate_filename "$filename")"
        if [ "$suggested" != "$filename" ]; then
            printf 'Suggested: %s\n' "$suggested"
        fi
        return 1
    fi
    
    return 0
}

# ============================================================================
# CPU CORE DETECTION (macOS/Linux/Debian compatible)
# ============================================================================
get_cpu_cores() {
    # Try Linux nproc first (Debian/Ubuntu/etc)
    if command -v nproc >/dev/null 2>&1; then
        local c=$(nproc 2>/dev/null || echo "")
        if [ -n "$c" ] && [ "$c" -gt 0 ]; then
            echo "$c"
            return 0
        fi
    fi
    
    # Try macOS sysctl
    if command -v sysctl >/dev/null 2>&1; then
        local c=$(sysctl -n hw.ncpu 2>/dev/null || echo "")
        if [ -n "$c" ] && [ "$c" -gt 0 ]; then
            echo "$c"
            return 0
        fi
    fi
    
    # Try Linux getconf fallback
    if command -v getconf >/dev/null 2>&1; then
        local c=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo "")
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
            echo "  • Comprehensive transliteration (100+ international character mappings)"
            echo "  • Parallel processing (auto-detects CPU cores)"
            echo "  • Adaptive progress bar (smooth Unicode on macOS, ASCII elsewhere)"
            echo "  • Amiga filesystem compliance checking with auto-fix"
            echo "  • Handles European accented characters (Polish, Czech, German, French, etc.)"
            echo "  • Converts special symbols (©, ®, ™, €, £, ×, ÷, etc.)"
            echo "  • Smart quote normalization"
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
    "Dutch:Nl" "Danish:Dk" "Finnish:Fi" "Swedish:Sv" "Sweden:Se" "Norwegian:No" "Portuguese:Pt" "Hungarian:Hu" "Russian:Ru" "Greek:Gr" "Turkish:Tr" "Slovak:Sk" "Croatian:Hr" "Serbian:Sr" "Bulgarian:Bg" "Romanian:Ro" "Slovenian:Si" "Estonian:Et" "Latvian:Lv" "Lithuanian:Lt" 
)

LOGFILE="$(pwd)/sort.log"
AMIGA_ISSUES_LOG="$(pwd)/amiga_filename_issues.log"
: > "$AMIGA_ISSUES_LOG"

# ============================================================================
# MOVE AND TAG FUNCTION (with language detection)
# ============================================================================
move_and_tag() {
    local variant="$1"
    local src_dir="$2"
    local rel_path="${src_dir#$SRC/}"
    local language_found=""
    
    # Check for language suffix
    local name="$(basename "$src_dir")"
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
    local info_file="$(dirname "$src_dir")/$(basename "$src_dir").info"
    local new_info_file="$(dirname "$dest_path")/$(basename "$dest_path").info"
    
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
    local info_file="$(dirname "$dir")/$(basename "$dir").info"
    local new_info_path="$(dirname "$newpath")/$(basename "$dir").info"
    
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
                local name="$(basename "$dir")"
                
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
                        elif echo "$name" | grep -Eq 'AGA([0-9][0-9]?MB)?$|AGA$|AGA_.*$' && ! echo "$name" | grep -Eq 'CD32AGA$'; then
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

# ============================================================================ 
# LANGUAGE SORTING - with parallel processing
# ============================================================================

lang_sort() {
    echo "Sorting Languages"

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

    local lang_total=0

    for entry in "${langs[@]}"; do
        local lang="${entry%%:*}"
        local code="${entry##*:}"
        local dir_matches=()

        for search_dir in "${variant_dirs[@]}"; do
            if [ -d "$search_dir" ]; then
                while IFS= read -r -d '' dir; do
                    local name="$(basename "$dir")"
                    # Case-sensitive, exact language code at end of basename
                   if [[ "$name" =~ ${code}$ ]]; then
                        dir_matches+=("$dir")
                    fi
                done < <(find "$search_dir" -mindepth 1 -maxdepth 2 -type d -print0 2>/dev/null || true)
            fi
        done

        lang_total=$((lang_total + ${#dir_matches[@]}))
    done

    local lang_processed=0

    for entry in "${langs[@]}"; do
        local lang="${entry%%:*}"
        local code="${entry##*:}"
        local lang_dir="$SRC/Languages/$lang"
        local dir_matches=()

        for search_dir in "${variant_dirs[@]}"; do
            if [ -d "$search_dir" ]; then
                while IFS= read -r -d '' dir; do
                    local name="$(basename "$dir")"
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
    DEST="${DEST_OVERRIDE:-$DEFAULT_DEST}"

    echo "Performing Amiga filesystem compliance check ($FS_TYPE: max $MAX_FILENAME_LEN chars) in: $DEST"
    echo

    issues_found=0
    total_scanned=0
    files_fixed=0
    total_files=$(find "$DEST" -type f 2>/dev/null | wc -l)

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
    done < <(find "$DEST" -type f -print0 2>/dev/null)

    printf "\r%-60s\n" " "
    if [ $files_fixed -gt 0 ]; then
        echo "✓ Fixed $files_fixed file(s) by transliterating special characters."
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
find "$(dirname "$dest_path")" -type d -empty -delete 2>/dev/null || true

echo "✓ Sort operation complete. (Check contents of $DEST)"
