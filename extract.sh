#!/usr/bin/env bash
# retroplay-suite: 2026.10.01.2   (every script in the set must carry the same stamp)
# Remember where the user ran this from, before any cd: retroplay.conf is
# looked for there first (see lib.sh).
RP_INVOKED_FROM="${RP_INVOKED_FROM:-$PWD}"; export RP_INVOKED_FROM
RP_ORIG_ARGS="$*"      # remembered for the lock record and the logs
# Unset variables are a bug (this is how the empty "Operating System:"
# line went unnoticed for so long), and a pipeline reports the first
# failure rather than the last. NOT -e: the pipeline deliberately
# tolerates non-zero from some commands and checks exit codes itself,
# and errexit would turn "3 archives could not be extracted" into
# "the whole build stopped".
set -u -o pipefail
#
# Purpose: Extracts archives in parallel.  Options: -d/--dest DIR -u (unattended)
#            --exclude-tags LIST --only-tags LIST --debug --help
# Run 'extract.sh --help' for the authoritative, current list.
#

# Amiga Retroplay Archive Extractor (OS-adaptive, encoding-robust)
# Part of the whdsync suite - the one version is RP_SUITE_VERSION in lib.sh.
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

# Locale is chosen further down, once lib.sh is loaded: it has to be one this
# machine actually has. Forcing en_AU.UTF-8 here made every subprocess on a
# Pi print "setlocale: cannot change locale" straight through the progress bar.

# Colour follows the same rule as lib.sh: any non-empty NO_COLOR turns it
# off (that is the published convention - NO_COLOR=true must work, not just
# NO_COLOR=1), and never on anything that isn't a terminal. Re-applied from
# lib.sh once that is loaded, so --color=always|never wins.
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; NC="";
else
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m';
    BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m';
fi

# OS detection.
# /etc/os-release is read field by field rather than sourced: sourcing it
# would run whatever the file contains. PRETTY_NAME is read the same way -
# it used to be referenced as "$PRETTY_NAME", a leftover from when the file
# WAS sourced, so the banner printed "Operating System:" with nothing after
# it on every Linux machine.
OS_TYPE="unknown"; OS_NAME="Unknown"
if [ -f /etc/os-release ]; then
    _osr() { sed -n "s/^$1=//p" /etc/os-release 2>/dev/null | tr -d "\"'" | head -1; }
    ID="$(_osr ID)"
    ID_LIKE="$(_osr ID_LIKE)"
    OS_TYPE="linux"
    OS_NAME="$(_osr PRETTY_NAME)"
    [ -n "$OS_NAME" ] || OS_NAME="${ID:-Linux}"
    unset -f _osr
elif command -v uname >/dev/null 2>&1; then
    OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"
    [ "$OS_TYPE" = "darwin" ] && OS_NAME="macOS"
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

# Archive filenames come in three flavours: plain ASCII, Latin-1 (most Amiga
# archives), and whatever the system uses. The extraction passes below try
# them in that order, so both a UTF-8 and a Latin-1 locale are wanted - but
# only ones this machine actually has. An existing LANG is honoured first;
# setup.sh generates C.UTF-8 and en_US.ISO-8859-1, which are in the lists.
RP_LC_UTF8="$(rp_pick_locale "${LANG:-}" en_AU.UTF-8 en_GB.UTF-8 en_US.UTF-8 C.UTF-8 C.utf8 2>/dev/null || printf 'C')"
export LANG="$RP_LC_UTF8" LC_ALL="$RP_LC_UTF8"
# May be empty: if no Latin-1 locale is generated, that pass is simply skipped
# rather than run under the wrong locale (which is what used to happen - the
# passes asked for en_AU.ISO-8859-1 while setup.sh generates en_US.ISO-8859-1).
RP_LC_LATIN1="$(rp_pick_locale en_AU.ISO-8859-1 en_GB.ISO-8859-1 en_US.ISO-8859-1 2>/dev/null || true)"
# One colour decision for the whole suite (NO_COLOR, --color, terminal or not).
rp_set_colours
rp_load_config
rp_banner "extract.sh"
DEFAULTDEST="$SCRIPT_DIR/retro"
DESTOVERRIDE=""
CUSTOM=0
UNATTENDED=0
EXCLUDE_TAGS=""   # --exclude-tags AGA,CD32 : skip archives with any of these name fields
ONLY_TAGS=""      # --only-tags AGA,CD32    : extract ONLY archives with one of them
DEBUG=0
# One stage of an all.sh pipeline: no banner or header block of its own.
CALLED_FROM_ALL="${RP_CHILD:-0}"

while [ $# -gt 0 ]; do
    opt_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$opt_lc" in
    -d|--dest) rp_require_option_value "$1" "$#" "${2-}"; DESTOVERRIDE="$2"; CUSTOM=1; shift 2 ;;
    -u|--unattended) UNATTENDED=1; shift ;;
    --exclude-tags) rp_require_option_value "$1" "$#" "${2-}"; EXCLUDE_TAGS="$2"; shift 2 ;;
    --only-tags) rp_require_option_value "$1" "$#" "${2-}"; ONLY_TAGS="$2"; shift 2 ;;
    --debug) DEBUG=1; shift ;;
    --called-from-all) CALLED_FROM_ALL=1; shift ;;
    --jobs) rp_require_option_value "$1" "$#" "${2-}"; RP_JOBS_OVERRIDE="$2"; shift 2 ;;
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
        *)
            # --quiet / --verbose / --color are understood by every script in
            # the suite; lib.sh handles them so they behave the same way here
            # as they do in start.sh.
            rp_common_opt "$1" "${2-}"; _co=$?
            case "$_co" in
                0) shift; continue ;;
                2) shift 2; continue ;;
            esac
            echo -e "${RED}Unknown option: $1${NC}"; exit 4 ;;
    esac
done
unset opt_lc

DEST="${DESTOVERRIDE:-$DEFAULTDEST}"

if [ "$CALLED_FROM_ALL" -eq 0 ]; then
echo -e "${BOLD}========================================================${NC}"
echo -e "${BOLD} Amiga Archive Extractor - whdsync ${RP_RELEASE} ${NC}"
echo -e "${BOLD}========================================================${NC}"
echo -e "Operating System: ${YELLOW}${OS_NAME}${NC}"
echo -e "Destination: ${YELLOW}${DEST}${NC}"
echo -e "Encoding: ${YELLOW}ASCII first, ISO-8859-1 second, system locale last${NC}"
echo -e "${BOLD}========================================================${NC}"
fi

DEST_CREATED_THIS_RUN=0
if [ ! -d "$DEST" ]; then
    echo -e "${YELLOW}Creating destination directory: $DEST${NC}"
    mkdir -p "$DEST" || { echo -e "${RED}Failed to create directory: $DEST${NC}"; exit 4; }
    DEST_CREATED_THIS_RUN=1
fi

# Only make writable what THIS run created: a blanket "chmod -R u+w" would
# rewrite permissions across an existing collection.
if [ "${DEST_CREATED_THIS_RUN:-0}" -eq 1 ]; then
    chmod -R u+w "$DEST" 2>/dev/null || echo -e "${RED}Warning: could not set write permissions on $DEST${NC}"
elif [ ! -w "$DEST" ]; then
    echo -e "${RED}ERROR: $DEST is not writable.${NC}" >&2
    exit 4
fi

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
    # The opt-in guard applies on EVERY platform. It used to sit inside the
    # Darwin branch only, so a Linux build stopped in the middle to ask for a
    # sudo password - exactly the surprise the setup-first dependency policy
    # exists to prevent.
    rp_may_install_tools || { rp_tool_missing_hint "$tool_name"; return 1; }
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
# Not started from a folder holding the archives (e.g. run by hand from the
# main folder)? Then work in the downloads folder instead.
if [ "${#find_roots[@]}" -eq 0 ] && [ -d "${RP_DOWNLOAD_ROOT:-/nonexistent}" ]; then
    for _root in HD_Loaders JST WHDLoad; do
        [ -d "$RP_DOWNLOAD_ROOT/$_root" ] && find_roots+=("$_root")
    done
    if [ "${#find_roots[@]}" -gt 0 ]; then
        cd "$RP_DOWNLOAD_ROOT" || exit 4
        SRCROOT="$(pwd)"
        echo "Reading archives from ${RP_DOWNLOAD_ROOT##*/}/"
    fi
fi
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
    rp_lock_release
    trap - EXIT INT TERM
    rp_reap_children            # workers AND the lha/7z they launched
    if [ -d "${tmpdir:-}" ]; then
        [ -n "${ERROR_LOG:-}" ] && cat "$tmpdir"/dir_*.log 2>/dev/null >> "$ERROR_LOG"
        rm -rf -- "$tmpdir"
    fi
    # This run's per-archive unpacking folders (see extract_contained). Only
    # ones carrying this run's pid in their name; another run's are not ours.
    [ -d "${DEST:-}" ] && find "$DEST" -maxdepth 5 -type d -name ".whdsync_x.$$.*" -prune \
        -exec rm -rf {} + 2>/dev/null
    exit "$st"
}
# Unpacking folders left by an extract.sh that was killed outright: removed
# once the pid in their name belongs to no running process.
if [ -d "${DEST:-}" ]; then
    find "$DEST" -maxdepth 5 -type d -name '.whdsync_x.*' -prune 2>/dev/null |
    while IFS= read -r _x; do
        _p="${_x##*/.whdsync_x.}"; _p="${_p%%.*}"
        case "$_p" in ''|*[!0-9]*) continue ;; esac
        kill -0 "$_p" 2>/dev/null || rm -rf -- "$_x"
    done
fi
# Run by hand? Then this is the run, and it takes the same lock all.sh
# uses, so it cannot work on a collection a nightly build is midway through.
rp_lock_for_stage "extract.sh ${RP_ORIG_ARGS:-}"
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

# How many archives at once: CPU cores, capped by memory so a 512 MB Pi Zero
# 2 W is not handed to the out-of-memory killer - which ends a job silently,
# leaving every later archive in its directory unextracted and unlogged. The
# rule lives in lib.sh (rp_auto_jobs) so it is the same everywhere and tested.
CORES="$(rp_auto_jobs extract)"
_raw_cores="$(rp_cpu_cores)"; [ "$_raw_cores" -gt 8 ] && _raw_cores=8
_mem_kb="$(rp_mem_kb)"
if [ "$CORES" -lt "$_raw_cores" ] && [ -n "$_mem_kb" ]; then
    echo "Detected ~$((_mem_kb / 1024))MB RAM - capping parallel extraction to $CORES job(s) to reduce the risk of out-of-memory kills."
fi
unset _raw_cores _mem_kb

max_parallel="$(rp_jobs extract "$CORES")"
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
        rp_short_sleep
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
        [ $success -eq 0 ] && [ -n "$RP_LC_LATIN1" ] && (cd "$abs_destdir" && LANG="$RP_LC_LATIN1" LC_ALL="$RP_LC_LATIN1" lha x "$abs_archive") >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -encoding ISO-8859-1 -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && [ -n "$RP_LC_LATIN1" ] && LANG="$RP_LC_LATIN1" LC_ALL="$RP_LC_LATIN1" 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && (cd "$abs_destdir" && lha x "$abs_archive") >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        ;;
    lzx)
        (cd "$abs_destdir" && LANG=C LC_ALL=C unlzx -x "$abs_archive") >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -encoding ASCII -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && LANG=C LC_ALL=C 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && [ -n "$RP_LC_LATIN1" ] && (cd "$abs_destdir" && LANG="$RP_LC_LATIN1" LC_ALL="$RP_LC_LATIN1" unlzx -x "$abs_archive") >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -encoding ISO-8859-1 -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && [ -n "$RP_LC_LATIN1" ] && LANG="$RP_LC_LATIN1" LC_ALL="$RP_LC_LATIN1" 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && (cd "$abs_destdir" && unlzx -x "$abs_archive") >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        ;;
    zip)
        unar -encoding ASCII -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && LANG=C LC_ALL=C 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -encoding ISO-8859-1 -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && [ -n "$RP_LC_LATIN1" ] && LANG="$RP_LC_LATIN1" LC_ALL="$RP_LC_LATIN1" 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        ;;
    *)
        unar -encoding ASCII -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && LANG=C LC_ALL=C 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -encoding ISO-8859-1 -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && [ -n "$RP_LC_LATIN1" ] && LANG="$RP_LC_LATIN1" LC_ALL="$RP_LC_LATIN1" 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && unar -quiet -f -o "$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        [ $success -eq 0 ] && 7z x -aoa -o"$abs_destdir" "$abs_archive" >/dev/null 2>&1 && success=1
        ;;
    esac
    return $((1 - success))
}
NICE_PREFIX="$(rp_nice_prefix)"

# --------------------------------------------------- contained extraction ---
# The archives come from a remote server (over plain FTP), so an archive that
# names a member ../../x, or a link pointing out of the folder, must not be
# able to write anywhere but where it is meant to. The extraction tree lives
# inside the output folder, next to the finished collections, so "a few
# levels up" is exactly where the damage would be.
#
# Each archive is therefore unpacked on its own, into
#     <letter folder>/.whdsync_x.<run pid>.XXXXXX/j/j/j/x
# and only then moved into the letter folder:
#   * anything that appears in the .whdsync_x folder OUTSIDE x climbed out
#     with ../ - the archive is refused and counted as failed (it is retried
#     and, after the usual attempts, set aside);
#   * a symlink inside x that points outside x is removed - extraction tools
#     on a Unix system have no business creating one from an Amiga archive;
#   * the content is then moved into place - a rename, as it is the same
#     folder - or merged into an existing folder exactly as the tools would.
# Absolute member paths are not tested for here: lha (lhasa), unar and 7z all
# turn /x into x when extracting, and the tree is checked as a whole
# afterwards (rp_layout_problems in all.sh).
extract_contained() {   # <archive> <dest letter folder> <ext>  -> 0 ok, 1 failed, 3 refused
    local arc="$1" dest="$2" ext="$3" xdir stage rc esc e name
    xdir="$(mktemp -d "$dest/.whdsync_x.$EXTRACT_RUN_PID.XXXXXX")" || return 1
    stage="$xdir/j/j/j/x"
    mkdir -p "$stage" || { rm -rf -- "$xdir"; return 1; }
    if [ -n "$TIMEOUT_CMD" ]; then
        # shellcheck disable=SC2086
        $NICE_PREFIX $TIMEOUT_CMD bash -c 'extract_archive "$1" "$2" "$3"' _ "$arc" "$stage" "$ext"
        rc=$?
    else
        extract_archive "$arc" "$stage" "$ext"
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then rm -rf -- "$xdir"; return "$rc"; fi
    esc="$(find "$xdir" -mindepth 1 ! -path "$xdir/j" ! -path "$xdir/j/j" ! -path "$xdir/j/j/j" \
             ! -path "$stage" ! -path "$stage/*" -print 2>/dev/null | head -1)"
    if [ -n "$esc" ]; then rm -rf -- "$xdir"; return 3; fi
    rp_prune_escaping_symlinks "$stage" >/dev/null 2>&1
    for e in "$stage"/* "$stage"/.[!.]*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        name="${e##*/}"
        if [ -d "$e" ] && [ -d "$dest/$name" ]; then
            cp -a "$e/." "$dest/$name/" || { rm -rf -- "$xdir"; return 1; }
        else
            mv -f -- "$e" "$dest/$name" 2>/dev/null || { rm -rf -- "$dest/$name"; mv -f -- "$e" "$dest/$name"; } \
                || { rm -rf -- "$xdir"; return 1; }
        fi
    done
    rm -rf -- "$xdir"
    return 0
}
EXTRACT_RUN_PID=$$
export -f extract_archive
# extract_archive runs inside `timeout bash -c ...` when timeout exists - a
# FRESH bash, which inherits exported variables only. Without these the
# Latin-1 passes silently saw an empty locale and never ran, on exactly the
# Linux machines where `timeout` is always present.
export RP_LC_LATIN1 RP_LC_UTF8

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

            # NICE_PREFIX is empty on an interactive run and "nice -n 10 "
            # (plus ionice on Linux) under cron, so a nightly extraction on a
            # Pi leaves the machine usable. Deliberately unquoted: it is a
            # command prefix, not a filename.
            extract_contained "$abs_archive" "$abs_destdir" "$ext"
            extract_rc=$?

            if [ "$extract_rc" -ne 0 ]; then
                if [ "$extract_rc" -eq 3 ]; then
                    printf 'FAILED: %s (format: %s) - REFUSED: it has entries that climb out of their folder (../)\n' "$abs_archive" "$ext" >>"$dir_log"
                elif [ "$extract_rc" -eq 124 ]; then
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
    ) 9>&- &                  # 9>&-: a worker must not hold the run lock
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

rp_child_result "stage=extract" "status=$([ "$errors" -eq 0 ] && echo ok || echo errors)" \
    "seconds=$SECONDS" "errors=$errors" "killed=${#killed_dirs[@]}" "dest=$DEST"
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
