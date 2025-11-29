#!/usr/bin/env bash

# Amiga Retroplay Archive Extractor (OS-adaptive, encoding-robust)
# Version: 1.3.1-os-adaptive

export LANG="${LANG:-en_AU.UTF-8}"
export LC_ALL="${LC_ALL:-en_AU.UTF-8}"

NO_COLOR="${NO_COLOR:-0}"

if [ "$NO_COLOR" = "1" ] || [ ! -t 1 ]; then
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; NC="";
else
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m';
    BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m';
fi

# OS detection
if [ -f /etc/os-release ]; then
    source /etc/os-release
    OS_TYPE="linux"
    OS_NAME="$PRETTY_NAME"
elif command -v uname >/dev/null; then
    OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"
    [ "$OS_TYPE" = "darwin" ] && OS_NAME="macOS"
else
    OS_TYPE="unknown"
    OS_NAME="Unknown"
fi

sanitize_amiga_names_macos() {
    local root="$1"
    [ -d "$root" ] || return 0

    # Allowed: A–Z a–z 0–9 space _ - + ! () [] .
    local pattern='[^A-Za-z0-9 _+\-\!\(\)\[\]\.]'

    # Walk deepest paths first so we rename children before parents
    find "$root" -depth -print0 | while IFS= read -r -d '' path; do
        name="${path##*/}"
        dir="${path%/*}"

        # Skip if already clean ASCII/Amiga‑safe
        if ! printf '%s' "$name" | LC_ALL=C grep -qE "$pattern"; then
            continue
        fi

        # Replace disallowed chars with underscore
        clean="$(printf '%s' "$name" | LC_ALL=C sed -E "s/$pattern/_/g")"

        # Collapse multiple underscores
        clean="$(printf '%s' "$clean" | sed -E 's/_+/_/g')"

        # Avoid empty names
        [ -z "$clean" ] && clean="_"

        # If the target already exists, append a numeric suffix
        target="$dir/$clean"
        if [ -e "$target" ] && [ "$target" != "$path" ]; then
            n=1
            while [ -e "${target}_$n" ]; do
                n=$((n+1))
            done
            target="${target}_$n"
        fi

        mv -n -- "$path" "$target" 2>/dev/null || mv -- "$path" "$target"
    done
}

# Progress bar: block for macOS, text for others
progress_bar() {
    local current="${1:-0}" total="${2:-1}" width="${3:-40}"
    if [[ "$OS_TYPE" == "darwin" ]]; then
        local percent bar_len whole partial partial_block left bar prog_chars
        prog_chars=(' ' '▏' '▎' '▍' '▌' '▋' '▊' '▉' '█')
        (( total > 0 )) && percent=$(( 100 * current / total )) || percent=0
        bar_len=$(awk "BEGIN{printf \"%.2f\", ($width * $current) / $total + 0 }")
        whole=${bar_len%.*}
        partial_frac="0.${bar_len#*.}"
        partial_block=$(awk "BEGIN{print int((${partial_frac}*8)+0.5)}")
        bar=""
        i=0
        while [ $i -lt $whole ]; do bar="${bar}█";  i=$((i + 1)); done
        if [ $whole -lt $width ]; then
            bar="${bar}${prog_chars[$partial_block]}"
            left=$((width - whole - 1))
        else left=0; fi
        while [ $left -gt 0 ]; do bar="${bar} "; left=$((left-1)); done
        printf "\r%3d%% [%-${width}s] %d/%d" "$percent" "$bar" "$current" "$total"
    else
        local percent filled empty done_fill todo_fill
        (( total > 0 )) && percent=$(( 100 * current / total )) || percent=0
        filled=$(( width * current / total )); (( filled < 0 )) && filled=0
        empty=$(( width - filled ))
        done_fill=$(printf "%${filled}s" | tr ' ' '#')
        todo_fill=$(printf "%${empty}s" | tr ' ' '-')
        printf "\rProgress %3d%% [%s%s] %3d%% (%d/%d)" "$percent" "$done_fill" "$todo_fill" "$percent" "$current" "$total"
    fi
    tput el 2>/dev/null || true
}

format_elapsed_time() {
    local t="$1"
    printf '%d:%02d:%02d' $((t/3600)) $(((t%3600)/60)) $((t%60))
}

# Path handling: greadlink for Mac, readlink for Linux
if [[ "$OS_TYPE" == "darwin" ]]; then
    if command -v greadlink >/dev/null 2>&1; then
        _readlinkf() { greadlink -f "$1"; }
    else
        _readlinkf() { perl -MCwd -e 'print Cwd::abs_path(shift)' "$1"; }
    fi
else
    _readlinkf() { readlink -f "$1"; }
fi

SCRIPT_DIR="$(_readlinkf "$(dirname "${BASH_SOURCE[0]}")")"
DEFAULTDEST="$SCRIPT_DIR/retro"
DESTOVERRIDE=""
CUSTOM=0
UNATTENDED=0
DEBUG=0

while [ $# -gt 0 ]; do
    case "$1" in
    -d|--dest) DESTOVERRIDE="$2"; CUSTOM=1; shift 2 ;;
    -u|--unattended) UNATTENDED=1; shift ;;
    --debug) DEBUG=1; shift ;;
    -h|--help)
        echo "Usage: $(basename $0) [options]"
        echo "Options:"
        echo " -d, --dest Set custom destination directory"
        echo " -u, --unattended Run without prompts"
        echo " --debug Enable debug output"
        echo " -h, --help Show this help message"
        echo
        echo "Default destination: $DEFAULTDEST"
        echo "Encoding preference: ASCII first, ISO-8859-1 second, system locale last"
        exit 0
        ;;
    *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

DEST="${DESTOVERRIDE:-$DEFAULTDEST}"

echo -e "${BOLD}========================================================${NC}"
echo -e "${BOLD} Amiga Archive Extractor v1.3.1-os-adaptive ${NC}"
echo -e "${BOLD}========================================================${NC}"
echo -e "Operating System: ${YELLOW}${OS_NAME}${NC}"
echo -e "Destination: ${YELLOW}${DEST}${NC}"
echo -e "Encoding: ${YELLOW}ASCII first, ISO-8859-1 second, system locale last${NC}"
echo -e "${BOLD}========================================================${NC}"

if [ ! -d "$DEST" ]; then
    echo -e "${YELLOW}Creating destination directory: $DEST${NC}"
    mkdir -p "$DEST" || { echo -e "${RED}Failed to create directory: $DEST${NC}"; exit 1; }
fi

chmod -R u+w "$DEST" 2>/dev/null || { echo -e "${RED}Warning: could not set write permissions on $DEST${NC}"; }

missing=()
for tool in lha unlzx 7z unar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing+=("$tool")
    fi
done

if [ ${#missing[@]} -ne 0 ]; then
    echo -e "${RED}Missing tools:${NC} ${missing[*]}"
    if [[ "$OS_TYPE" == "darwin" ]]; then
        echo "Install via Homebrew (macOS): brew install lha unlzx p7zip unar"
        echo "Also: brew install coreutils (for greadlink)"
    else
        echo "Or via apt (Linux): sudo apt install lhasa unlzx p7zip-full unar"
    fi
    exit 1
fi

SRCROOT="$(pwd)"
mapfile -t archives < <(find . -maxdepth 4 -type f \( -iname "*.lha" -o -iname "*.lzx" -o -iname "*.zip" \))

if [ "${#archives[@]}" -eq 0 ]; then
    echo -e "${RED}No archives found!${NC}"
    exit 1
fi

declare -A dir_archives

for archive in "${archives[@]}"; do
    srcdir="$(_readlinkf "$(dirname "$archive")")"
    dir_archives["$srcdir"]+="$archive"$'\n'
done

dirs=("${!dir_archives[@]}")
total_dirs=${#dirs[@]}
echo -e "${NC}Found ${#archives[@]} archives in $total_dirs directories.${NC}"

CORES=""
if command -v getconf >/dev/null 2>&1; then
    CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
fi
if [ -z "$CORES" ] && command -v sysctl >/dev/null 2>&1; then
    CORES=$(sysctl -n hw.ncpu 2>/dev/null)
fi
CORES=${CORES:-3}
[ "$CORES" -gt 8 ] && CORES=8
max_parallel="$CORES"
echo "Detected $CORES CPU core(s) for parallel extraction."

trap 'echo -e "\n${RED}Interrupted. Killing all background jobs and exiting...${NC}"; pkill -P $$; exit 130' INT TERM

extraction_start=$(date +%s)
dir_count=0
errors=0
ERROR_LOG="$SRCROOT/extract_errors.log"
: > "$ERROR_LOG"

extract_archive() {
    local abs_archive="$1"
    local abs_destdir="$2"
    local ext="$3"
    local success=0
    case "${ext,,}" in
    lha)
        (cd "$abs_destdir" && LANG=C LC_ALL=C lha x "$abs_archive") >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -encoding ASCII -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && LANG=C LC_ALL=C 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && (cd "$abs_destdir" && LANG=en_AU.ISO-8859-1 LC_ALL=en_AU.ISO-8859-1 lha x "$abs_archive") >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -encoding ISO-8859-1 -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && LANG=en_AU.ISO-8859-1 LC_ALL=en_AU.ISO-8859-1 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && (cd "$abs_destdir" && lha x "$abs_archive") >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        ;;
    lzx)
        (cd "$abs_destdir" && LANG=C LC_ALL=C unlzx -x "$abs_archive") >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -encoding ASCII -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && LANG=C LC_ALL=C 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && (cd "$abs_destdir" && LANG=en_AU.ISO-8859-1 LC_ALL=en_AU.ISO-8859-1 unlzx -x "$abs_archive") >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -encoding ISO-8859-1 -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && LANG=en_AU.ISO-8859-1 LC_ALL=en_AU.ISO-8859-1 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && (cd "$abs_destdir" && unlzx -x "$abs_archive") >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        ;;
    zip)
        unar -encoding ASCII -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && LANG=C LC_ALL=C 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -encoding ISO-8859-1 -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && LANG=en_AU.ISO-8859-1 LC_ALL=en_AU.ISO-8859-1 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        ;;
    *)
        unar -encoding ASCII -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && LANG=C LC_ALL=C 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -encoding ISO-8859-1 -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && LANG=en_AU.ISO-8859-1 LC_ALL=en_AU.ISO-8859-1 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        ;;
    esac
    return $((1 - success))
}

running_jobs=0
tmpdir="$(mktemp -d "${SRCROOT}/extract_tmp.XXXXXX")" || {
    echo -e "${RED}Failed to create temp directory for logs${NC}"
    exit 1
}

dir_index=0

for srcdir in "${dirs[@]}"; do
    reldir="${srcdir#$SRCROOT/}"
    destdir="$DEST/${reldir}"
    mkdir -p "$destdir" || continue

    abs_destdir="$(_readlinkf "$destdir")"
    if [ -z "$abs_destdir" ] || [ ! -d "$abs_destdir" ]; then
        continue
    fi

    dir_index=$((dir_index + 1))
    dir_log="${tmpdir}/dir_${dir_index}.log"

    # One background job per srcdir
    (
        local_errors=0
        # iterate archives for this dir
        while IFS= read -r archive; do
            [ -z "$archive" ] && continue
            abs_archive="$(_readlinkf "$archive")"
            if [ -z "$abs_archive" ] || [ ! -f "$abs_archive" ]; then
                continue
            fi
            base="$(basename "$archive")"
            ext="${base##*.}"

            if ! extract_archive "$abs_archive" "$abs_destdir" "$ext"; then
                printf 'FAILED: %s (format: %s)\n' "$abs_archive" "$ext" >>"$dir_log"
                local_errors=$((local_errors + 1))
            fi
        done < <(printf '%s\n' "${dir_archives["$srcdir"]}")

        # macOS‑only: clean filenames to ASCII/Amiga‑safe set
        if [[ "$OS_TYPE" == "darwin" ]]; then
            sanitize_amiga_names_macos "$abs_destdir"
        fi

        # exit status = number of errors in this dir (capped at 255)
        exit $(( local_errors > 255 ? 255 : local_errors ))
    ) &

    running_jobs=$((running_jobs + 1))
    # throttle parallelism
    if (( running_jobs >= max_parallel )); then
        # wait for one job to finish; we don't care which
        if wait -n; then
            :
        else
            :
        fi
        running_jobs=$((running_jobs - 1))
    fi

    progress_bar "$dir_index" "$total_dirs" 40
done

# wait for remaining jobs
wait
echo

# Aggregate error logs
ERROR_LOG="$SRCROOT/extract_errors.log"
: > "$ERROR_LOG"

if [ -d "$tmpdir" ]; then
    cat "$tmpdir"/dir_*.log 2>/dev/null >>"$ERROR_LOG"
    rm -rf "$tmpdir"
fi

if [ -s "$ERROR_LOG" ]; then
    errors="$(wc -l <"$ERROR_LOG" 2>/dev/null || echo 0)"
else
    errors=0
fi

extraction_end=$(date +%s)
total_time=$((extraction_end - extraction_start))
fmt_time=$(format_elapsed_time "$total_time")

echo -e "\n${BOLD}=================== EXTRACT REPORT ===================${NC}"
echo "Destination: $DEST"
echo "Elapsed Time: $fmt_time"
echo "Extraction Errors: $errors"
if [ $errors -ne 0 ]; then
    echo -e "\n${RED}Failed archives are logged in:${NC} $ERROR_LOG"
fi
echo -e "${BOLD}======================================================${NC}"
