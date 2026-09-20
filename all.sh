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

# ----- Prevent overlapping runs -----
# If a previous cron-triggered run is somehow still going (e.g. an
# unusually slow week, or someone manually starts one while cron's is
# still running) when the next one fires, running two full pipelines
# against the same directories at once is exactly the kind of thing that
# corrupts output and pointlessly doubles resource usage on a small
# device. flock makes a second concurrent instance exit immediately
# instead of piling up.
LOCK_FILE="$SCRIPT_DIR/.all.lock"
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "Another all.sh is already running (lock file: $LOCK_FILE)." >&2
        echo "Exiting rather than run a second instance at the same time." >&2
        exit 1
    fi
else
    echo "Warning: 'flock' not found - cannot guarantee only one instance of" >&2
    echo "all.sh runs at a time. On Debian/Raspberry Pi OS this ships in" >&2
    echo "util-linux and should already be present; check your PATH." >&2
fi

# ----- Decide: single-extract full rebuild, or the original per-variant
# path (needed for incremental updates into existing output) -----
#
# Extracting the same archives three times (once per variant) into
# retro_aga/retro_ecs/retro_rtg is pure waste when all three start from
# nothing: decompression (lha/unlzx/7z) is the most expensive step in the
# whole pipeline, while a plain filesystem copy of already-extracted files
# is comparatively cheap. So when ALL THREE output directories are absent
# (a genuinely fresh build) - or --clean was given, forcing one - this
# extracts ONCE into retro_aga, copies that extracted-but-not-yet-merged
# tree into retro_ecs and retro_rtg, then runs merge+sort separately for
# each variant against its own copy.
#
# The copy happens BEFORE merge, not after: copying the FULLY MERGED aga
# tree and just re-running merge.sh for ecs/rtg would risk stale leftover
# artwork - if AGA found a "Covers" image for some game but ECS only has
# a "Titles" image for that same game, the two variants would name the
# result differently (iGame.iff vs igame1.iff, by art-category priority),
# so re-merging onto an already-merged tree could leave BOTH files sitting
# side by side instead of only the correct one. Copying the clean,
# unmerged extracted tree and letting each variant run its own full merge
# avoids that entirely.
#
# If any of the three already exist, this is an incremental update (or a
# partial prior run) - the original aga.sh/ecs.sh/rtg.sh path already
# handles that correctly (staging just the new files, merging into the
# existing output) and isn't worth the risk of retrofitting here, since an
# incremental run only extracts the small new-files batch anyway - the
# saving this optimization targets barely applies there regardless.
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

if [ "$want_full_rebuild" -ne 1 ]; then
    echo "Existing output found for at least one variant - using the normal"
    echo "per-variant incremental path (aga.sh/ecs.sh/rtg.sh) rather than the"
    echo "single-extract optimization, which only applies to a fresh full build."
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
./start.sh --merge --aga --art Covers,Screens,Titles --no-detox "$@" --dest retro_aga
./start.sh --sort --skipchk --no-detox "$@" --dest retro_aga

echo
echo "===== Variant 2 of 3: ECS artwork + sort ====="
./start.sh --merge --ecs --art Covers,Screens,Titles --no-detox "$@" --dest retro_ecs
./start.sh --sort --skipchk --no-detox "$@" --dest retro_ecs

echo
echo "===== Variant 3 of 3: RTG artwork + sort ====="
./start.sh --merge --rtg --art Covers,Screens,Titles --no-detox "$@" --dest retro_rtg
./start.sh --sort --skipchk --no-detox "$@" --dest retro_rtg

echo
echo "All 3 variants complete: retro_aga, retro_ecs, retro_rtg"
