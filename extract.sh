#!/usr/bin/env bash
# retroplay-suite: 2026.09.22   (every script in the set must carry the same stamp)

# Amiga Retroplay Archive Extractor (OS-adaptive, encoding-robust)
# Version: 1.4.0-bash32-compatible
#
# WHAT THIS SCRIPT DOES:
#   Finds every .lha/.lzx/.zip archive under the current directory and
#   extracts each one into the same relative path under DEST (default:
#   ./retro), trying several tools and encodings per archive until one
#   works (Amiga-era filenames are often not valid UTF-8). This is the
#   "extract" step of the pipeline, run after update.sh downloads new
#   archives and before merge.sh/sort.sh process the extracted files.
#
# WHY GROUPED BY DIRECTORY, IN PARALLEL: archives are grouped by their
# containing directory and one background job handles each directory's
# whole batch, up to a memory-aware parallelism limit (see the CORES/mem_kb
# section below) - decompression is memory-hungry, and running too many at
# once on a small device (e.g. a Pi Zero 2W's 512MB) risks the OS silently
# killing a job outright. Each archive extraction also runs under a time
# limit, so one hung/corrupt archive can't block its whole directory's job
# (and everything queued behind it) forever. See the "JOB KILLED"/TIMEOUT
# handling further down for how both failure modes are detected and
# reported, since neither shows up in a plain `wait`.

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

        # Skip A314 bridge metadata sidecar files (e.g. iGame.iff:a314) - the
        # colon is intentional there, and renaming would defeat their purpose
        # without actually removing them.
        case "$name" in
            *:a314) continue ;;
        esac

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
progress_bar() {   # progress_bar <current> <total> [width] - shared display (lib.sh)
    rp_progress "$1" "$2" "Extracting"
}

format_elapsed_time() { rp_format_duration "$1"; }   # shared (lib.sh)

# Path handling: resolve to an absolute, symlink-free path. Chosen by what
# actually WORKS here rather than by OS name: Linux's readlink -f, macOS
# 12.3+'s native readlink -f (so this includes Tahoe), Homebrew's greadlink,
# then perl - and finally a pure-bash fallback, so this never depends on
# perl still being bundled with macOS (Apple has been phasing out bundled
# scripting runtimes).
if readlink -f / >/dev/null 2>&1; then
    _readlinkf() { readlink -f "$1"; }
elif command -v greadlink >/dev/null 2>&1; then
    _readlinkf() { greadlink -f "$1"; }
elif command -v perl >/dev/null 2>&1; then
    _readlinkf() { perl -MCwd -e 'print Cwd::abs_path(shift)' "$1"; }
else
    _readlinkf() {
        if [ -d "$1" ]; then
            (cd "$1" 2>/dev/null && pwd -P)
        else
            local _d _b
            _d="$(dirname "$1")"; _b="$(basename "$1")"
            printf '%s/%s\n' "$(cd "$_d" 2>/dev/null && pwd -P)" "$_b"
        fi
    }
fi

SCRIPT_DIR="$(_readlinkf "$(dirname "${BASH_SOURCE[0]}")")"

# Shared helpers (retroplay.conf settings, dependency tracking, pending
# queues, disk-space checks...) live in lib.sh, next to this script.
if [ ! -f "$SCRIPT_DIR/lib.sh" ]; then
    echo "ERROR: lib.sh is missing from $SCRIPT_DIR - it ships with these scripts." >&2
    exit 1
fi
. "$SCRIPT_DIR/lib.sh"
rp_load_config
DEFAULTDEST="$SCRIPT_DIR/retro"
DESTOVERRIDE=""
CUSTOM=0
UNATTENDED=0
EXCLUDE_TAGS=""   # --exclude-tags AGA,CD32 : skip archives with any of these name fields
ONLY_TAGS=""      # --only-tags AGA,CD32    : extract ONLY archives with one of them
DEBUG=0

while [ $# -gt 0 ]; do
    opt_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$opt_lc" in
    -d|--dest) rp_require_option_value "$1" "$#" "${2-}"; DESTOVERRIDE="$2"; CUSTOM=1; shift 2 ;;
    -u|--unattended) UNATTENDED=1; shift ;;
    --exclude-tags) rp_require_option_value "$1" "$#" "${2-}"; EXCLUDE_TAGS="$2"; shift 2 ;;
    --only-tags) rp_require_option_value "$1" "$#" "${2-}"; ONLY_TAGS="$2"; shift 2 ;;
    --debug) DEBUG=1; shift ;;
    -h|--help)
        echo "Usage: $(basename $0) [options]"
        echo "Options (case-insensitive):"
        echo " -d, --dest Set custom destination directory"
        echo " -u, --unattended Run without prompts"
        echo " --exclude-tags LIST  Skip archives whose name has any of these fields (e.g. AGA,CD32)"
        echo " --only-tags LIST     Extract only archives with one of these fields"
        echo " --debug Enable debug output"
        echo " -h, --help Show this help message"
        echo
        echo "Default destination: $DEFAULTDEST"
        echo "Encoding preference: ASCII first, ISO-8859-1 second, system locale last"
        exit 0
        ;;
    *) echo -e "${RED}Unknown option: $1${NC}"; exit 4 ;;
    esac
done
unset opt_lc

DEST="${DESTOVERRIDE:-$DEFAULTDEST}"

echo -e "${BOLD}========================================================${NC}"
echo -e "${BOLD} Amiga Archive Extractor v1.4.0-bash32-compatible ${NC}"
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

# Prompts to auto-install a missing tool via the platform's package manager.
# Returns 0 if the tool is available afterwards (already present, or the
# install succeeded), 1 otherwise. Declines automatically (no prompt hang)
# if stdin isn't a terminal.
offer_install_pkg() {
    local tool_name="$1" apt_pkg="$2" brew_pkg="$3" reply
    if [ ! -t 0 ]; then
        echo "  (no terminal attached to answer a prompt - skipping auto-install of $tool_name)"
        return 1
    fi
    if [[ "$OS_TYPE" == "darwin" ]]; then
        printf '%s is missing. Install it now via Homebrew (brew install %s)? [y/N] ' "$tool_name" "$brew_pkg"
    else
        printf '%s is missing. Install it now via apt (sudo apt install %s)? [y/N] ' "$tool_name" "$apt_pkg"
    fi
    read -r reply
    case "$reply" in
        [Yy]*)
            if [[ "$OS_TYPE" == "darwin" ]]; then
                local _had=0; pkg_already_installed brew "$brew_pkg" && _had=1
                brew install "$brew_pkg" && [ "$_had" -eq 0 ] && record_installed_dep "brew" "$brew_pkg"
            else
                local _had=0; pkg_already_installed apt "$apt_pkg" && _had=1
                sudo apt-get update && sudo apt-get install -y "$apt_pkg" && [ "$_had" -eq 0 ] && record_installed_dep "apt" "$apt_pkg"
            fi
            ;;
        *)
            return 1
            ;;
    esac
    command -v "$tool_name" >/dev/null 2>&1
}

missing=()
for tool in lha unlzx 7z unar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing+=("$tool")
    fi
done

if [ ${#missing[@]} -ne 0 ]; then
    echo -e "${RED}Missing tools:${NC} ${missing[*]}"
    still_missing=()
    for tool in "${missing[@]}"; do
        case "$tool" in
            lha)
                if offer_install_pkg "lha" "lhasa" "lha"; then
                    echo "  lha is now available."
                else
                    still_missing+=("lha")
                fi
                ;;
            7z)
                if offer_install_pkg "7z" "p7zip-full" "p7zip"; then
                    echo "  7z is now available."
                else
                    still_missing+=("7z")
                fi
                ;;
            unar)
                if offer_install_pkg "unar" "unar" "unar"; then
                    echo "  unar is now available."
                else
                    still_missing+=("unar")
                fi
                ;;
            unlzx)
                # No standard apt/brew package exists for unlzx - it has to be
                # built from source, so it isn't offered through the same
                # apt/brew flow as the others.
                still_missing+=("unlzx")
                ;;
        esac
    done

    if [ ${#still_missing[@]} -ne 0 ]; then
        echo
        echo -e "${RED}Still missing:${NC} ${still_missing[*]}"
    if [ ! -t 0 ]; then
        echo "Note: this is an unattended run (e.g. cron), which starts with a minimal PATH."
        echo "If the tool works in your terminal, run ./install_cron.sh again from that"
        echo "terminal (or any script once, interactively) so its folder is remembered."
    fi

        pkg_missing=()
        for t in "${still_missing[@]}"; do
            [ "$t" != "unlzx" ] && pkg_missing+=("$t")
        done
        if [ ${#pkg_missing[@]} -ne 0 ]; then
            if [[ "$OS_TYPE" == "darwin" ]]; then
                echo "Install via Homebrew (macOS): brew install ${pkg_missing[*]}"
                echo "Also: brew install coreutils (for greadlink)"
            else
                apt_names=()
                for t in "${pkg_missing[@]}"; do
                    case "$t" in
                        lha) apt_names+=("lhasa") ;;
                        7z)  apt_names+=("p7zip-full") ;;
                        *)   apt_names+=("$t") ;;
                    esac
                done
                echo "Or via apt (Linux): sudo apt install ${apt_names[*]}"
            fi
        fi
        if printf '%s\n' "${still_missing[@]}" | grep -qx unlzx; then
            echo
            echo "unlzx has no standard package and must be built from source. See:"
            echo "  https://aminet.net/package/util/arc/unlzx"
            echo "Build hints (gcc), from the extracted unlzx source directory:"
            echo "  gcc -O2 -std=c99 -Wall -Wextra -o unlzx unlzx.c && strip unlzx"
            echo "  sudo mv unlzx /usr/local/bin/"
        fi
        exit 1
    fi
fi

SRCROOT="$(pwd)"

# Scope the search to only the real download roots (HD_Loaders/JST/WHDLoad
# - matching update.sh's own directory list). Without this, a blanket scan
# of "." also picks up whatever sits alongside them in the same script
# directory - notably the iGame_* artwork directories, some of which are
# themselves distributed as compressed .lha/.zip archives. Scanning those
# too meant artwork-pack archives could get mistaken for WHDLoad games and
# extracted straight into the output (e.g. an "Archive_image_packs" or
# "IGame_Covers_ECS_LoRes" folder showing up in retro_*, which they have no
# business being in). If none of the known roots exist (e.g. a caller uses
# a different top-level layout), fall back to scanning "." as before.
find_roots=()
for _root in HD_Loaders JST WHDLoad; do
    [ -d "$_root" ] && find_roots+=("$_root")
done
[ "${#find_roots[@]}" -eq 0 ] && find_roots=(".")

# Bash-3.2-safe replacement for `mapfile`
archives=()
while IFS= read -r _line; do
    [ -n "$_line" ] && archives+=("$_line")
done < <(find -H "${find_roots[@]}" -maxdepth 4 -type f \( -iname "*.lha" -o -iname "*.lzx" -o -iname "*.zip" \))
unset _line _root

# Optional filtering by archive-name fields (e.g. leaving AGA and CD32
# releases out of an ECS build). Matches whole "_"-separated fields,
# case-insensitively, so "Name_v1.0_AGA_HD.lha" has the AGA tag but a game
# merely called "Agamemnon" does not. See rp_archive_has_tag in lib.sh.
if [ -n "$EXCLUDE_TAGS" ] || [ -n "$ONLY_TAGS" ]; then
    _kept=()
    _skipped=0
    for _a in "${archives[@]+"${archives[@]}"}"; do
        if [ -n "$ONLY_TAGS" ] && ! rp_archive_has_tag "$_a" "$ONLY_TAGS"; then
            _skipped=$((_skipped + 1)); continue
        fi
        if [ -n "$EXCLUDE_TAGS" ] && rp_archive_has_tag "$_a" "$EXCLUDE_TAGS"; then
            _skipped=$((_skipped + 1)); continue
        fi
        _kept+=("$_a")
    done
    archives=("${_kept[@]+"${_kept[@]}"}")
    echo "Archive filter:${ONLY_TAGS:+ only [$ONLY_TAGS]}${EXCLUDE_TAGS:+ excluding [$EXCLUDE_TAGS]} - $_skipped archive(s) left out."
    if [ "${#archives[@]}" -eq 0 ]; then
        echo "Nothing left to extract after filtering - that's fine."
        exit 0
    fi
    unset _kept _a _skipped
fi

if [ "${#archives[@]}" -eq 0 ]; then
    echo -e "${RED}No archives found!${NC}"
    exit 1
fi

# Bash-3.2-safe replacement for the associative-array grouping: build a
# tab-separated "dir<TAB>archive" map keyed by RESOLVED directory, then
# derive the unique directory list from that. Per-directory archive lookups
# later use awk against this same file instead of an associative array.
#
# Performance note: dirname+readlink used to run once PER ARCHIVE. With
# thousands of archives sharing a much smaller number of directories (e.g.
# 5521 archives in 114 directories on a real run), that's thousands of
# redundant subprocess forks for a value that's identical across every
# archive in the same folder. Instead: extract the raw directory cheaply via
# bash parameter expansion (no subprocess) for every archive, then resolve
# each UNIQUE raw directory with _readlinkf exactly once, then join the two
# back together - cutting readlink calls from "one per archive" to "one per
# directory".
# Remove extract_tmp.* folders left behind by earlier runs that were
# killed or lost power (a folder whose owning run is still going is left
# alone), both here and in the scripts' own folder.
rp_sweep_stale_temp "${SRCROOT}"/extract_tmp.* "${SCRIPT_DIR}"/extract_tmp.*

tmpdir="$(mktemp -d "${SRCROOT}/extract_tmp.XXXXXX")" || {
    echo -e "${RED}Failed to create temp directory for logs${NC}"
    exit 1
}
rp_mark_temp_owner "$tmpdir"

# Always remove the temp folder when this script ends - normally, on an
# error, or when interrupted/terminated - after stopping any extraction
# jobs still running and saving their error logs.
cleanup_extract() {
    local st=$?
    trap - EXIT INT TERM
    pkill -P $$ 2>/dev/null     # no-op on a normal finish: no jobs left
    wait 2>/dev/null
    if [ -d "${tmpdir:-}" ]; then
        [ -n "${ERROR_LOG:-}" ] && cat "$tmpdir"/dir_*.log 2>/dev/null >> "$ERROR_LOG"
        rm -rf -- "$tmpdir"
    fi
    exit "$st"
}
trap cleanup_extract EXIT
trap 'echo -e "\n${RED}Interrupted - stopping extraction jobs and cleaning up...${NC}"; exit 130' INT TERM

RAW_MAP="$tmpdir/raw_dir_archive_map.tsv"
: > "$RAW_MAP"
for archive in "${archives[@]}"; do
    rawdir="${archive%/*}"
    [ "$rawdir" = "$archive" ] && rawdir="."
    printf '%s\t%s\n' "$rawdir" "$archive" >> "$RAW_MAP"
done
sort -t "$(printf '\t')" -k1,1 "$RAW_MAP" -o "$RAW_MAP"

uniq_raw_dirs=()
_last_raw=""
while IFS=$'\t' read -r _rd _rest; do
    if [ "$_rd" != "$_last_raw" ]; then
        uniq_raw_dirs+=("$_rd")
        _last_raw="$_rd"
    fi
done < "$RAW_MAP"
unset _rd _rest _last_raw

RESOLVE_MAP="$tmpdir/resolve_map.tsv"
: > "$RESOLVE_MAP"
for rd in "${uniq_raw_dirs[@]}"; do
    printf '%s\t%s\n' "$rd" "$(_readlinkf "$rd")" >> "$RESOLVE_MAP"
done

DIR_MAP="$tmpdir/dir_archive_map.tsv"
join -t "$(printf '\t')" -1 1 -2 1 -o 2.2,1.2 "$RAW_MAP" "$RESOLVE_MAP" > "$DIR_MAP"

dirs=()
while IFS= read -r d; do
    [ -n "$d" ] && dirs+=("$d")
done < <(cut -f2 "$RESOLVE_MAP" | sort -u)

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

# Cap parallelism based on available memory, not just CPU core count.
# Running several simultaneous decompression processes on a memory-limited
# device (e.g. a Raspberry Pi Zero 2W's 512MB) risks the kernel's OOM killer
# silently terminating a background job outright. A plain `wait` at the end
# of the run can't tell that apart from a clean finish - the job just
# vanishes mid-batch, and every archive after that point in its directory
# is left unextracted with no entry anywhere in the error log.
mem_kb=""
if [ -r /proc/meminfo ]; then
    mem_kb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
elif command -v sysctl >/dev/null 2>&1; then
    mem_bytes=$(sysctl -n hw.memsize 2>/dev/null)
    if [ -n "$mem_bytes" ]; then
        mem_kb=$((mem_bytes / 1024))
    fi
fi

if [ -n "$mem_kb" ] && [ "$mem_kb" -gt 0 ]; then
    if [ "$mem_kb" -lt 786432 ]; then
        mem_cap=1     # under ~768MB (e.g. Pi Zero 2W's 512MB): serialize extraction
    elif [ "$mem_kb" -lt 1572864 ]; then
        mem_cap=2     # under ~1.5GB
    else
        mem_cap=8
    fi
    if [ "$CORES" -gt "$mem_cap" ]; then
        echo "Detected ~$((mem_kb / 1024))MB RAM - capping parallel extraction to $mem_cap job(s) to reduce the risk of out-of-memory kills."
        CORES="$mem_cap"
    fi
fi

max_parallel="$CORES"
echo "Detected $CORES CPU core(s); using $max_parallel parallel extraction job(s)."

# Per-archive timeout, so one hung/corrupt archive can't stall its whole
# directory's job forever (and, since a stalled job never frees its
# wait_for_job_slot slot, can't stall every directory queued behind it).
TIMEOUT_SECS=120
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout ${TIMEOUT_SECS}s"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout ${TIMEOUT_SECS}s"
else
    echo "Note: no 'timeout' command found - extraction attempts have no time limit."
    echo "On macOS: brew install coreutils (provides gtimeout)."
fi


extraction_start=$(date +%s)
dir_count=0
errors=0
ERROR_LOG="$SRCROOT/extract_errors.log"
: > "$ERROR_LOG"

# Bash-3.2-safe job throttling (no `wait -n`, which needs bash 4.3+)
wait_for_job_slot() {
    local max_jobs="$1" job_count
    while true; do
        job_count=$(jobs -r | wc -l | tr -d ' ')
        [ "$job_count" -lt "$max_jobs" ] && break
        sleep 0.1
    done
}

extract_archive() {
    local abs_archive="$1"
    local abs_destdir="$2"
    local ext="$3"
    local success=0
    local ext_lc
    ext_lc="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
    case "$ext_lc" in
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
export -f extract_archive

dir_index=0
declare -a JOB_PIDS=()
declare -a JOB_DIRS=()
declare -a JOB_LOGS=()

for srcdir in "${dirs[@]}"; do
    # Where this folder's archives go inside DEST comes from the RELATIVE
    # path find reported (e.g. WHDLoad/Games/S) - never from the resolved
    # absolute path. Stripping the working directory off a resolved path
    # silently fails whenever the two are spelled differently - macOS's
    # case-insensitive disks (~/downloads vs ~/Downloads), symlinks such as
    # /tmp -> /private/tmp, or WHDLoad symlinked to another drive - and the
    # whole absolute path (Users/you/Downloads/Amiga/...) then got recreated
    # inside retro_*/new_*.
    reldir="$(awk -F'\t' -v r="$srcdir" '$2 == r { print $1; exit }' "$RESOLVE_MAP")"
    reldir="${reldir#./}"
    [ -n "$reldir" ] || reldir="."
    case "$reldir" in
        /*|..|../*|*/../*|*/..)
            echo -e "${RED}Skipping $srcdir: can't place it inside $DEST safely.${NC}" >&2
            continue ;;
    esac
    destdir="$DEST/${reldir}"
    mkdir -p "$destdir" || continue

    abs_destdir="$(_readlinkf "$destdir")"
    if [ -z "$abs_destdir" ] || [ ! -d "$abs_destdir" ]; then
        continue
    fi

    dir_index=$((dir_index + 1))
    dir_log="${tmpdir}/dir_${dir_index}.log"

    wait_for_job_slot "$max_parallel"

    # One background job per srcdir
    (
        local_errors=0
        # iterate archives for this dir (looked up from the sorted dir/archive map)
        while IFS=$'\t' read -r _mapdir archive; do
            [ -z "$archive" ] && continue
            abs_archive="$(_readlinkf "$archive")"
            if [ -z "$abs_archive" ] || [ ! -f "$abs_archive" ]; then
                continue
            fi
            base="$(basename "$archive")"
            ext="${base##*.}"

            if [ -n "$TIMEOUT_CMD" ]; then
                $TIMEOUT_CMD bash -c 'extract_archive "$1" "$2" "$3"' _ "$abs_archive" "$abs_destdir" "$ext"
                extract_rc=$?
            else
                extract_archive "$abs_archive" "$abs_destdir" "$ext"
                extract_rc=$?
            fi

            if [ "$extract_rc" -ne 0 ]; then
                if [ "$extract_rc" -eq 124 ]; then
                    printf 'FAILED: %s (format: %s) - TIMED OUT after %ss\n' "$abs_archive" "$ext" "$TIMEOUT_SECS" >>"$dir_log"
                else
                    printf 'FAILED: %s (format: %s)\n' "$abs_archive" "$ext" >>"$dir_log"
                fi
                local_errors=$((local_errors + 1))
            fi
        done < <(awk -F'\t' -v d="$srcdir" '$1==d' "$DIR_MAP")

        # macOS‑only: clean filenames to ASCII/Amiga‑safe set
        if [[ "$OS_TYPE" == "darwin" ]]; then
            sanitize_amiga_names_macos "$abs_destdir"
        fi

        # exit status = number of errors in this dir (capped at 255)
        exit $(( local_errors > 255 ? 255 : local_errors ))
    ) &
    JOB_PIDS+=("$!")
    JOB_DIRS+=("$srcdir")
    JOB_LOGS+=("$dir_log")

    progress_bar "$dir_index" "$total_dirs" 40
done

# Wait for each job individually (rather than a bare `wait`) so we can tell
# a clean finish apart from a job that was killed outright - e.g. by the
# OOM killer on a memory-constrained device. A signal kill shows up as an
# exit status of 128+signal; a plain `wait` would just silently return once
# the job was gone either way, with no record of which directory it was or
# that anything went wrong.
killed_dirs=()
for _ji in "${!JOB_PIDS[@]}"; do
    # On macOS in particular, bash can lose track of a background job's
    # PID by the time we get here - typically because wait_for_job_slot's
    # `jobs -r` polling above already noticed it finished and reaped it
    # internally, so this explicit `wait` can no longer retrieve its exit
    # status at all. That shows up as "wait: pid N is not a child of this
    # shell" (exit status 127) - not a real problem, just bash's job table
    # having already let go of a job that (almost always) finished
    # normally, so it's treated as such rather than surfaced as an error.
    wait "${JOB_PIDS[$_ji]}" 2>/dev/null
    job_status=$?
    if [ "$job_status" -eq 127 ]; then
        continue
    fi
    if [ "$job_status" -ge 128 ]; then
        sig=$((job_status - 128))
        printf 'JOB KILLED: directory %s (signal %d - likely killed by the OS, e.g. out-of-memory). Archives not yet reached in this directory were NOT extracted and have no FAILED entry above.\n' \
            "${JOB_DIRS[$_ji]}" "$sig" >> "${JOB_LOGS[$_ji]}"
        killed_dirs+=("${JOB_DIRS[$_ji]}")
    fi
done
unset _ji
echo

# Aggregate per-directory error logs into one file. Each background job
# wrote its own "FAILED: ..." lines (one per archive it couldn't extract)
# and, if it was itself killed mid-run, a "JOB KILLED: ..." line was added
# by the wait-loop above. These two kinds of line mean different things
# (one bad archive vs. an entire batch cut short), so they're counted
# separately below rather than lumped into a single "errors" number.
ERROR_LOG="$SRCROOT/extract_errors.log"
: > "$ERROR_LOG"

if [ -d "$tmpdir" ]; then
    # THIS run's failures only (the error log can also hold older runs').
    cat "$tmpdir"/dir_*.log 2>/dev/null | sed -n 's/^FAILED: \(.*\) (format: .*$/\1/p' > "$tmpdir/.run_failed"
    errors="$(grep -c . "$tmpdir/.run_failed" 2>/dev/null)"; errors="${errors:-0}"
    # Machine-readable list for all.sh: one failed archive per line, plus
    # "DIR:<folder>" for folders whose job was killed (none of their
    # archives can be trusted to have been extracted).
    if [ -n "${RP_EXTRACT_FAILED_LIST:-}" ]; then
        {
            cat "$tmpdir/.run_failed"
            for _kd in "${killed_dirs[@]+"${killed_dirs[@]}"}"; do printf 'DIR:%s\n' "$_kd"; done
        } > "$RP_EXTRACT_FAILED_LIST"
    fi
    cat "$tmpdir"/dir_*.log 2>/dev/null >>"$ERROR_LOG"
    rm -rf "$tmpdir"
fi
: "${errors:=0}"

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
if [ "${#killed_dirs[@]}" -gt 0 ]; then
    echo
    echo -e "${RED}WARNING: ${#killed_dirs[@]} extraction job(s) were killed mid-run:${NC}"
    printf '  %s\n' "${killed_dirs[@]}"
    echo "This usually means the device ran out of memory running $max_parallel job(s) in parallel."
    echo "Some archives in these directories may not have been extracted at all - re-run"
    echo "extract.sh to pick up anything missed (already-extracted files are left alone)."
    echo "(These killed jobs are NOT included in the 'Extraction Errors' count above,"
    echo "since a killed job can leave an unknown number of archives unattempted -"
    echo "not a fixed count of individual failures.)"
fi
echo -e "${BOLD}======================================================${NC}"

# 5 = some archives could not be extracted (see the log). Everything else
# that could be extracted has been.
if [ "$errors" -gt 0 ] || [ "${#killed_dirs[@]}" -gt 0 ]; then
    exit 5
fi
exit 0
