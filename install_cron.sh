#!/usr/bin/env bash
set -e

# Installs (or updates) a cron job that runs all.sh every morning at 2am.
# Safe to run more than once - it removes any entry it previously added
# (identified by the marker comment below) before adding the current one,
# so re-running this never creates duplicate cron lines.
#
# WHY THE "cd" IS NEEDED: cron jobs run with an unrelated working
# directory, but all.sh/aga.sh/ecs.sh/rtg.sh/start.sh all call each other
# with relative paths like "./start.sh" - without first cd-ing into this
# script's own directory, those relative calls would fail to find anything.

if ! command -v crontab >/dev/null 2>&1; then
    echo "ERROR: 'crontab' command not found. On Raspberry Pi OS/Debian, install it with:" >&2
    echo "  sudo apt install cron" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER="# retroplay-all-sh-cron"
CRON_LINE="0 2 * * * cd \"$SCRIPT_DIR\" && ./all.sh >> \"$SCRIPT_DIR/all_cron.log\" 2>&1 $MARKER"

# Remove any previous entry this script added, then add the current one.
# Matched on the broader "retroplay-all-sh" prefix rather than the exact
# marker above, so upgrading from an older version of this script (which
# used a schedule-specific marker, e.g. "-weekly") still correctly
# replaces that old entry instead of leaving both installed side by side.
#
# The "|| true" after grep matters: if the retroplay entry is the ONLY
# line in the crontab, grep -v filters it out entirely and returns exit
# status 1 (no lines matched) - under this script's `set -e`, that
# non-zero status would otherwise abort the whole subshell right there,
# before the new CRON_LINE ever gets echoed, silently piping an EMPTY
# crontab into `crontab -` and wiping out the entire crontab rather than
# updating it.
{ crontab -l 2>/dev/null | grep -v -F "retroplay-all-sh" || true; echo "$CRON_LINE"; } | crontab -

echo "Installed: all.sh will run every day at 2:00am."
echo "  $CRON_LINE"
echo
echo "Output from each run is appended to: $SCRIPT_DIR/all_cron.log"
echo
echo "Current crontab:"
crontab -l
