#!/usr/bin/env bash
set -e

# Amiga Retroplay - runs all three artwork variants (AGA, ECS, RTG) in turn.
#
# Since start.sh now builds directly into retro_aga/retro_ecs/retro_rtg
# (derived automatically from which artwork option was chosen), this no
# longer needs to run each variant into a shared "retro" and rename it
# afterward - each variant's own output already lands in its own correctly
# named directory.
#
# Only ONE real update.sh check happens per run, regardless of which path
# below is taken.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || { echo "ERROR: cannot cd to script directory: $SCRIPT_DIR" >&2; exit 1; }

# Tell start.sh (via every invocation below, and any --nothing-new-fallback
# re-exec inside it) that it's running as part of an all.sh pass. start.sh
# uses this to (a) skip its end-of-run "view error log?" prompt even when a
# terminal IS attached, since answering that prompt after variant 1 would
# otherwise stall the whole pipeline waiting on input before variant 2 even
# starts - defeating the point of all.sh being able to run straight through
# unattended (e.g. from cron) - and (b) append each variant's errors to ONE
# shared retroerror.log instead of each variant's start.sh overwriting what
# the previous variant just wrote, so there's a single combined log to check
# after all three variants finish. Reset that log once here, at the start of
# this run, so it doesn't grow across separate all.sh runs (e.g. every past
# week's cron run) - each run starts this file fresh and fills in its own
# section(s) of it as it goes.
rm -f -- "$SCRIPT_DIR/retroerror.log"
export RETROPLAY_ALL_SH=1

# ----- Dependency tracking (for the uninstaller) -----
# Records exactly what THIS suite of scripts installs, so uninstall_deps.sh
# can later remove only those specific things and leave anything that was
# already present on the system - installed by the user, or by something
# else entirely - untouched. Format: one "<method>:<name>" per line, where
# method is apt, brew, or source-build (name is the installed file's full
# path for source-build, since there's no package manager entry to remove).
DEP_TRACK_FILE="$SCRIPT_DIR/.retroplay_installed_deps.log"
record_installed_dep() {
    local dep_line="$1:$2"
    if ! grep -qxF "$dep_line" "$DEP_TRACK_FILE" 2>/dev/null; then
        echo "$dep_line" >> "$DEP_TRACK_FILE"
    fi
}

# True only if the package manager itself already has this package fully
# installed. Checked BEFORE offering an install, so a package that was
# already on the system (e.g. installed but its command isn't on PATH, as
# with Homebrew's keg-only util-linux) is never recorded as installed by
# these scripts - `apt-get install` / `brew install` both succeed as a
# no-op in that case, which would otherwise make the uninstaller remove
# something the user already had. dpkg-query's "install ok installed" is
# used instead of plain `dpkg -s`, which also succeeds for packages that
# were removed but left their config files behind.
pkg_already_installed() {
    case "$1" in
        apt)  dpkg-query -W -f='${Status}' "$2" 2>/dev/null | grep -q "install ok installed" ;;
        brew) command -v brew >/dev/null 2>&1 && brew list --versions "$2" >/dev/null 2>&1 ;;
        *)    return 1 ;;
    esac
}

OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"

# Resolves a usable flock binary, including macOS's keg-only Homebrew
# util-linux install (Homebrew doesn't symlink flock into PATH there,
# since it would shadow other things) - checked before concluding flock
# is genuinely missing and needs installing.
resolve_flock() {
    if command -v flock >/dev/null 2>&1; then
        printf 'flock'
        return 0
    fi
    if [[ "$OS_TYPE" == "darwin" ]] && command -v brew >/dev/null 2>&1; then
        local prefix
        prefix="$(brew --prefix util-linux 2>/dev/null)"
        if [ -n "$prefix" ] && [ -x "$prefix/bin/flock" ]; then
            printf '%s/bin/flock' "$prefix"
            return 0
        fi
    fi
    return 1
}

# ----- Prevent overlapping runs -----
# If a previous cron-triggered run is somehow still going (e.g. an
# unusually slow week, or someone manually starts one while cron's is
# still running) when the next one fires, running two full pipelines
# against the same directories at once is exactly the kind of thing that
# corrupts output and pointlessly doubles resource usage on a small
# device. flock makes a second concurrent instance exit immediately
# instead of piling up.
LOCK_FILE="$SCRIPT_DIR/.all.lock"
FLOCK_BIN="$(resolve_flock || true)"

if [ -z "$FLOCK_BIN" ] && [ -t 0 ]; then
    echo "'flock' was not found - it's needed to guarantee only one all.sh"
    echo "instance runs at a time (e.g. so cron can't overlap a still-running pass)."
    if [[ "$OS_TYPE" == "darwin" ]]; then
        printf 'Install it now via Homebrew (brew install util-linux)? [y/N] '
    else
        printf 'Install it now via apt (sudo apt install util-linux)? [y/N] '
    fi
    read -r _flock_reply
    case "$_flock_reply" in
        [Yy]*)
            if [[ "$OS_TYPE" == "darwin" ]]; then
                _had=0; pkg_already_installed brew util-linux && _had=1
                if brew install util-linux && [ "$_had" -eq 0 ]; then
                    record_installed_dep "brew" "util-linux"
                fi
            else
                _had=0; pkg_already_installed apt util-linux && _had=1
                if sudo apt-get update && sudo apt-get install -y util-linux && [ "$_had" -eq 0 ]; then
                    record_installed_dep "apt" "util-linux"
                fi
            fi
            FLOCK_BIN="$(resolve_flock || true)"
            ;;
    esac
    unset _flock_reply
fi

if [ -n "$FLOCK_BIN" ]; then
    exec 9>"$LOCK_FILE"
    if ! "$FLOCK_BIN" -n 9; then
        echo "Another all.sh is already running (lock file: $LOCK_FILE)." >&2
        echo "Exiting rather than run a second instance at the same time." >&2
        exit 1
    fi
else
    echo "Warning: 'flock' not found - cannot guarantee only one instance of" >&2
    echo "all.sh runs at a time." >&2
    if [[ "$OS_TYPE" == "darwin" ]]; then
        echo "Install it with: brew install util-linux" >&2
        echo "(Homebrew installs flock keg-only there - this script finds it via" >&2
        echo "'brew --prefix util-linux' automatically once installed, no PATH" >&2
        echo "changes needed.)" >&2
    else
        echo "On Debian/Raspberry Pi OS this ships in util-linux and should" >&2
        echo "already be present: sudo apt install util-linux" >&2
    fi
fi

# ----- Decide which path to take -----
#
# Extracting the same archives three times (once per variant) into
# retro_aga/retro_ecs/retro_rtg is pure waste: decompression (lha/unlzx/
# 7z) is the most expensive step in the whole pipeline, while a plain
# filesystem copy of already-extracted files is comparatively cheap. This
# applies whether it's a fresh build (all archives) or an incremental
# update (just the newly downloaded batch) - so both cases below extract
# once and copy, rather than only the fresh-build case as before.
#
# The copy always happens BEFORE merge, never after: copying an already
# MERGED tree and just re-running merge.sh for ecs/rtg would risk stale
# leftover artwork - if AGA found a "Covers" image for some game but ECS
# only has a "Titles" image for that same game, the two variants would
# name the result differently (iGame.iff vs igame1.iff, by art-category
# priority), so re-merging onto an already-merged tree could leave BOTH
# files sitting side by side instead of only the correct one. Copying the
# clean, unmerged extracted tree and letting each variant run its own
# full merge avoids that entirely.
#
# Three states are distinguished:
#   - none of the three outputs exist yet (or --clean was given): a
#     genuinely fresh build - extract everything once, below.
#   - all three already exist: an incremental update - stage and extract
#     just the newly downloaded batch once, below.
#   - a MIXED state (some exist, some don't, e.g. a partial prior run) -
#     falls back to the original aga.sh/ecs.sh/rtg.sh path, which treats
#     each variant according to its own actual state correctly. This is
#     deliberately not optimized: it's a rare, edge-case state, and
#     handling it wrong (e.g. giving a genuinely-missing variant only the
#     latest incremental batch instead of a full history) would be worse
#     than just accepting three extractions here.
want_full_rebuild=0
if [ ! -d retro_aga ] && [ ! -d retro_ecs ] && [ ! -d retro_rtg ]; then
    want_full_rebuild=1
fi
for arg in "$@"; do
    if [ "$arg" = "--clean" ]; then
        want_full_rebuild=1
        break
    fi
done

all_exist=0
if [ -d retro_aga ] && [ -d retro_ecs ] && [ -d retro_rtg ]; then
    all_exist=1
fi

if [ "$want_full_rebuild" -ne 1 ] && [ "$all_exist" -ne 1 ]; then
    echo "Mixed state (some but not all variant outputs exist) - using the"
    echo "normal per-variant path (aga.sh/ecs.sh/rtg.sh) so each variant is"
    echo "correctly treated as fresh or incremental on its own terms."
    echo

    echo "===== Variant 1 of 3: aga.sh ====="
    if ./aga.sh "$@"; then
        aga_status=0
    else
        aga_status=$?
    fi

    if [ "$aga_status" -ne 0 ]; then
        echo
        echo "aga.sh found nothing new or hit an error (exit $aga_status) - stopping" >&2
        echo "here. ecs.sh and rtg.sh were NOT run this time." >&2
        exit "$aga_status"
    fi

    echo
    echo "===== Variant 2 of 3: ecs.sh (reusing aga.sh's update check) ====="
    ./ecs.sh --skip-update "$@"

    echo
    echo "===== Variant 3 of 3: rtg.sh (reusing aga.sh's update check) ====="
    ./rtg.sh --skip-update "$@"

    echo
    echo "All 3 variants complete: retro_aga, retro_ecs, retro_rtg"
    exit 0
fi

if [ "$want_full_rebuild" -eq 1 ]; then

echo "Fresh build for all three variants - extracting once and reusing the"
echo "result for all three instead of extracting the same archives three times."
echo

# --clean (or the fresh-build state itself) means starting completely
# clean - remove any partial/stale output for all three variants before
# extracting, matching what --auto's own --clean handling would do for a
# single variant.
for d in retro_aga retro_ecs retro_rtg; do
    [ -e "$d" ] && rm -rf -- "$d"
done

echo "===== Update check ====="
if ./start.sh --update "$@"; then
    update_status=0
else
    update_status=$?
fi

if [ "$update_status" -eq 3 ]; then
    echo
    echo "Stopping: update.sh reported a wget error (see above)." >&2
    exit 1
elif [ "$update_status" -eq 2 ]; then
    echo
    echo "Nothing new to download - nothing to build. Stopping."
    exit 2
elif [ "$update_status" -ne 0 ]; then
    echo
    echo "Stopping: update.sh failed unexpectedly (exit $update_status)." >&2
    exit "$update_status"
fi

# --dest is placed AFTER "$@" in every call below (rather than before, as
# aga.sh/ecs.sh/rtg.sh place their own hardcoded flags) so that whichever
# directory this optimization depends on can never be silently overridden
# by something in "$@" - correctness here specifically depends on each
# step landing in the right one of retro_aga/retro_ecs/retro_rtg.
echo
echo "===== Extracting once into retro_aga ====="
./start.sh --extract "$@" --dest retro_aga

# Amiga filesystem compliance checking (illegal characters, FFS/PFS length
# limits) only cares about each file/path component's own name - it's
# unaffected by which variant's artwork ends up sitting next to it later,
# or by the CD32/AGA/NTSC/MT32/CDTV/language reorganization sort.sh does
# afterward (that only adds new parent directories with short, fixed
# names - it doesn't lengthen or rename any existing component). So it's
# safe to run this ONCE here, on the shared extracted tree, and skip it in
# each variant's own sort.sh pass below (--skipchk) - matching what the
# extract-once optimization above already does for extraction itself.
#
# The CD32/AGA/NTSC/MT32/CDTV/language reorganization itself is NOT
# shared this same way: it moves each game's whole directory under a new
# parent (e.g. WHDLoad/Languages/German/Games/S/SomeGame), and merge.sh's
# own game-directory search only looks a few levels deep - doing that
# reorganization before merge would risk merge.sh silently failing to
# find (and so failing to add artwork to) any game already moved into one
# of those subfolders. So --skip-variant-sort is used ONLY for this
# shared pass, and each variant still does its own reorganization after
# its own merge step, same as before.
echo
echo "===== Compliance check (once, shared across all variants) ====="
./start.sh --sort --skip-variant-sort --no-detox "$@" --dest retro_aga

echo
echo "Copying extracted+checked files into retro_ecs and retro_rtg (no re-extraction or re-checking needed)..."
rm -rf -- retro_ecs retro_rtg
cp -a retro_aga retro_ecs
cp -a retro_aga retro_rtg

echo
echo "===== Variant 1 of 3: AGA artwork + sort ====="
./start.sh --merge --art Covers,Screens,Titles --no-detox "$@" --aga --dest retro_aga
./start.sh --sort --skipchk --no-detox "$@" --dest retro_aga

echo
echo "===== Variant 2 of 3: ECS artwork + sort ====="
./start.sh --merge --art Covers,Screens,Titles --no-detox "$@" --ecs --dest retro_ecs
./start.sh --sort --skipchk --no-detox "$@" --dest retro_ecs

echo
echo "===== Variant 3 of 3: RTG artwork + sort ====="
./start.sh --merge --art Covers,Screens,Titles --no-detox "$@" --rtg --dest retro_rtg
./start.sh --sort --skipchk --no-detox "$@" --dest retro_rtg

echo
echo "All 3 variants complete: retro_aga, retro_ecs, retro_rtg"

else

echo "Existing output found for all three variants - staging and extracting"
echo "just the newly downloaded batch once, instead of once per variant."
echo

echo "===== Update check ====="
if ./start.sh --update "$@"; then
    update_status=0
else
    update_status=$?
fi

if [ "$update_status" -eq 3 ]; then
    echo
    echo "Stopping: update.sh reported a wget error (see above)." >&2
    exit 1
elif [ "$update_status" -eq 2 ]; then
    echo
    echo "Nothing new to download - nothing to build. Stopping."
    exit 2
elif [ "$update_status" -ne 0 ]; then
    echo
    echo "Stopping: update.sh failed unexpectedly (exit $update_status)." >&2
    exit "$update_status"
fi

# Stage exactly the files update.log named this run, preserving their
# relative layout (the same technique start.sh's own incremental --auto
# path and quick.sh use), then extract that small batch ONCE - this is
# the same waste as the fresh-build case, just on a smaller scale: a
# handful of new archives extracted three times instead of once.
TEMP_SRC_DIR="$SCRIPT_DIR/.staging_src_all_$$"
STAGING_BASE="$SCRIPT_DIR/.staging_out_all_$$"
rm -rf -- "$TEMP_SRC_DIR" "$STAGING_BASE"
mkdir -p "$TEMP_SRC_DIR" "$STAGING_BASE"

staged_any=0
if [ -f update.log ]; then
    while IFS= read -r logline; do
        filepath=$(printf '%s\n' "$logline" | sed 's/^[0-9-]* [0-9:]* //')
        [ -f "$filepath" ] || continue
        relpath="${filepath#./}"
        destpath="$TEMP_SRC_DIR/$relpath"
        mkdir -p "$(dirname "$destpath")"
        cp -f "$filepath" "$destpath" 2>/dev/null && staged_any=1
    done < update.log
fi

if [ "$staged_any" -eq 0 ]; then
    echo "Nothing to stage - update.log had no readable entries. Stopping."
    rm -rf -- "$TEMP_SRC_DIR" "$STAGING_BASE"
    exit 2
fi

echo
echo "===== Extracting the new batch once (shared across all variants) ====="
(cd "$TEMP_SRC_DIR" && bash "$SCRIPT_DIR/extract.sh" -d "$STAGING_BASE")
rm -rf -- "$TEMP_SRC_DIR"

echo
echo "===== Compliance check (once, shared across all variants) ====="
./start.sh --sort --skip-variant-sort --no-detox "$@" --dest "$STAGING_BASE"

for variant in aga ecs rtg; do
    dest="retro_$variant"
    staging_copy="$SCRIPT_DIR/.staging_${variant}_batch_$$"
    rm -rf -- "$staging_copy"
    cp -a "$STAGING_BASE" "$staging_copy"

    echo
    echo "===== Variant: $variant (incremental) ====="
    ./start.sh --merge --art Covers,Screens,Titles --no-detox "$@" --"$variant" --dest "$staging_copy"
    ./start.sh --sort --skipchk --no-detox "$@" --dest "$staging_copy"

    echo "Merging new batch into $dest..."
    mkdir -p "$dest"
    cp -a "$staging_copy/." "$dest/"

    new_dir_name="new_${variant}"
    rm -rf -- "$new_dir_name"
    mv "$staging_copy" "$new_dir_name"
    echo "New-files duplicate: $new_dir_name"

    echo "Gap-fill artwork pass on $dest..."
    ./start.sh --merge --art Covers,Screens,Titles --no-detox "$@" --"$variant" --dest "$dest" --only-missing
done

rm -rf -- "$STAGING_BASE"

echo
echo "All 3 variants updated: retro_aga, retro_ecs, retro_rtg"

fi
