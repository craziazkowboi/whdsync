#!/usr/bin/env bash
# retroplay-suite: 2026.10.03.1   (every script in the set must carry the same stamp)
# Remember where the user ran this from, before any cd: retroplay.conf is
# looked for there first (see lib.sh).
RP_INVOKED_FROM="${RP_INVOKED_FROM:-$PWD}"; export RP_INVOKED_FROM
# Purpose: build or update the RTG variant (retro_rtg) - a thin wrapper around start.sh.
# Inputs:  any start.sh option, e.g. --rebuild, --clean, --skip-update
# Outputs: whatever start.sh --sync does for this one variant
# Safety:  no logic of its own; all safety rules live in all.sh/start.sh
# Called by: people, and by cron only through all.sh --cron
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --help is about THIS command, so it is answered before --sync --rtg is
# prepended - passing it through produced "start.sh --sync --rtg --help",
# which described a build nobody asked for. (RTG has no laced counterpart:
# the RTG packs are a single set.)
# Anywhere in the arguments, not only first: "./rtg.sh --rebuild --help" used
# to hand --help to start.sh after --sync, which could start a rebuild.
_help=0
for _a in ${1+"$@"}; do case "$_a" in -h|--help) _help=1 ;; esac; done
case "$_help" in
    1)
        echo "Usage: $(basename "$0") [start.sh options]"
        echo
        echo "Builds or updates the RTG collection (build/retro_rtg)."
        echo
        echo "Everything else is passed straight to start.sh, e.g.:"
        echo "  $(basename "$0") --rebuild        Rebuild from the archives already downloaded"
        echo "  $(basename "$0") --skip-update    Process what is queued, don't download"
        echo
        echo "Run './start.sh --help' for the full option list."
        exit 0 ;;
esac

exec "$SCRIPT_DIR/start.sh" --sync --rtg ${1+"$@"}
