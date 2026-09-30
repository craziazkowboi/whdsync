#!/usr/bin/env bash
# retroplay-suite: 2026.09.29   (every script in the set must carry the same stamp)
# Remember where the user ran this from, before any cd: retroplay.conf is
# looked for there first (see lib.sh).
RP_INVOKED_FROM="${RP_INVOKED_FROM:-$PWD}"; export RP_INVOKED_FROM
# Purpose: build or update the ECS variant (retro_ecs) - a thin wrapper around start.sh.
# Inputs:  --laced to build the laced collection (retro_ecs_laced) instead,
#          plus any start.sh option, e.g. --rebuild, --clean, --skip-update
# Outputs: whatever start.sh --sync does for this one variant
# Safety:  no logic of its own; all safety rules live in all.sh/start.sh
# Called by: people, and by cron only through all.sh --cron
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --help and --version are about THIS command, so they are answered before
# --sync --ecs is prepended. Passing them through produced the nonsense
# "start.sh --sync --ecs --help", which described a build nobody asked for.
case "${1:-}" in
    -h|--help)
        echo "Usage: $(basename "$0") [--laced] [start.sh options]"
        echo
        echo "Builds or updates the ECS collection (build/retro_ecs)."
        echo "  --laced      Build the laced ECS collection instead (build/retro_ecs_laced)"
        echo
        echo "Everything else is passed straight to start.sh, e.g.:"
        echo "  $(basename "$0") --rebuild        Rebuild from the archives already downloaded"
        echo "  $(basename "$0") --skip-update    Process what is queued, don't download"
        echo "  $(basename "$0") --laced --plan   Show what a laced build would do"
        echo
        echo "Run './start.sh --help' for the full option list."
        exit 0 ;;
esac

# --laced may appear anywhere in the arguments, not only first.
VARIANT="--ecs"
ARGS=()
for arg in ${1+"$@"}; do
    case "$arg" in
        --laced) VARIANT="--ecs-laced" ;;
        *)       ARGS+=("$arg") ;;
    esac
done

exec "$SCRIPT_DIR/start.sh" --sync "$VARIANT" ${ARGS[@]+"${ARGS[@]}"}
