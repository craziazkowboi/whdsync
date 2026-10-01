#!/usr/bin/env bash
# retroplay-suite: 2026.10.01.2   (every script in the set must carry the same stamp)
# Remember where the user ran this from, before any cd: retroplay.conf is
# looked for there first (see lib.sh).
RP_INVOKED_FROM="${RP_INVOKED_FROM:-$PWD}"; export RP_INVOKED_FROM
RP_ORIG_ARGS="$*"      # remembered for the lock record and the logs
#
# Purpose: DEPRECATED. quick.sh has become "./start.sh --preview-new", which
#   does the same job through the pipeline engine and so gets the things
#   quick.sh never had: the overlapping-run lock, the output-drive check, the
#   shared queue, the run report and the summary table.
#
#   This file stays for one release so existing notes, scripts and cron lines
#   keep working. It prints one line saying what to use instead, then runs it.
#
# Called by: people (and start.sh --quick, which is the same alias)
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/lib.sh" ] || { echo "ERROR: lib.sh is missing from $SCRIPT_DIR" >&2; exit 4; }
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
rp_load_config

case " $* " in
    *" --help "*|*" -h "*)
        rp_banner "quick.sh"
        echo
        echo "quick.sh has been replaced by:  ./start.sh --preview-new"
        echo
        echo "It builds the same dated folder of just the new games, with artwork,"
        echo "and leaves your collection untouched - but it now runs through the"
        echo "pipeline engine, so it also gets:"
        echo "  - the lock that stops it clashing with a nightly build"
        echo "  - the output-drive check"
        echo "  - the shared queue (nothing is processed twice, or lost)"
        echo "  - the run report and the summary table"
        echo
        echo "Usage: ./start.sh --preview-new [--aga|--ecs|--rtg|--aga-laced|--ecs-laced]"
        echo
        echo "This file still works and passes your options straight through."
        echo "It will be removed in a later release."
        exit 0
        ;;
esac

rp_warn "quick.sh is deprecated - use:  ./start.sh --preview-new"
rp_info "  Running that for you now; quick.sh goes away in a later release."
exec "$SCRIPT_DIR/start.sh" --preview-new "$@"
