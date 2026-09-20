#!/usr/bin/env bash
set -e

# Installs (or updates) a cron job that runs all.sh every Wednesday at
# midnight. Safe to run more than once - it removes any entry it
# previously added (identified by the marker comment below) before adding
# the current one, so re-running this never creates duplicate cron lines.
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
MARKER="# retroplay-all-sh-weekly"
CRON_LINE="0 0 * * 3 cd \"$SCRIPT_DIR\" && ./all.sh >> \"$SCRIPT_DIR/all_cron.log\" 2>&1 $MARKER"

# Remove any previous entry we added, then add the current one.
(crontab -l 2>/dev/null | grep -v -F "$MARKER"; echo "$CRON_LINE") | crontab -

echo "Installed: all.sh will run every Wednesday at midnight."
echo "  $CRON_LINE"
echo
echo "Output from each run is appended to: $SCRIPT_DIR/all_cron.log"
echo
echo "Current crontab:"
crontab -l
