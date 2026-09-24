#!/usr/bin/env bash
# retroplay-suite: 2026.09.22   (every script in the set must carry the same stamp)
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


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/lib.sh" ] || { echo "ERROR: lib.sh is missing from $SCRIPT_DIR" >&2; exit 1; }
. "$SCRIPT_DIR/lib.sh"
# cron runs jobs with a bare PATH, so remember the PATH of THIS shell - the
# one where your tools (unlzx etc.) work - for the nightly run to use.
rp_remember_path force

RUN_TIME="02:00"; ACTION=install; DRY=0; ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --time)    rp_require_option_value "$1" "$#" "${2-}"; RUN_TIME="$2"; shift 2 ;;
        --daily)   shift ;;                        # the only schedule for now
        --show)    ACTION=show; shift ;;
        --disable) ACTION=disable; shift ;;
        --dry-run) DRY=1; shift ;;
        --yes|-y)  ASSUME_YES=1; shift ;;
        -h|--help)
            cat << USAGE
Sets up (or removes) the nightly run.

Usage: install_cron.sh [--time HH:MM] [--daily] [--dry-run] [--yes]
       install_cron.sh --show | --disable
   or: start.sh --schedule [same options]

  --time HH:MM   When to run each night (default 02:00)
  --show         Show the entry that is installed now
  --disable      Remove it again
  --dry-run      Print what would change, change nothing
  --yes          Don't ask for confirmation

Your current PATH is remembered, so the nightly run finds tools such as
unlzx even though cron itself starts with a minimal PATH. Cron entries that
aren't this one are never touched.
USAGE
            exit 0 ;;
        *) rp_print_usage_error install_cron.sh "unknown option: $1"; exit 4 ;;
    esac
done

case "$RUN_TIME" in
    [0-9][0-9]:[0-9][0-9]) ;;
    [0-9]:[0-9][0-9])      RUN_TIME="0$RUN_TIME" ;;
    *) rp_die "$RP_EXIT_CONFIG" "--time needs a 24-hour time like 02:00 (got '$RUN_TIME')" ;;
esac
CRON_HOUR="${RUN_TIME%%:*}"; CRON_MIN="${RUN_TIME##*:}"
{ [ "$((10#$CRON_HOUR))" -le 23 ] && [ "$((10#$CRON_MIN))" -le 59 ]; } \
    || rp_die "$RP_EXIT_CONFIG" "--time must be between 00:00 and 23:59 (got '$RUN_TIME')"

# (checked after the options, so --help always works)
if ! command -v crontab >/dev/null 2>&1; then
    echo "ERROR: 'crontab' command not found. On Raspberry Pi OS/Debian, install it with:" >&2
    echo "  sudo apt install cron" >&2
    exit 4
fi

current_entry() { crontab -l 2>/dev/null | grep "retroplay-all-sh" || true; }

MARKER="# retroplay-all-sh-cron"

if [ "$ACTION" = "show" ]; then
    if [ -n "$(current_entry)" ]; then
        echo "The nightly run is installed:"; current_entry | sed 's/^/  /'
        echo "Log: $RP_LOG_ROOT/all_cron.log"
    else
        echo "No nightly run is installed. Add one with: ./start.sh --schedule"
    fi
    exit 0
fi

if [ "$ACTION" = "disable" ]; then
    if [ -z "$(current_entry)" ]; then echo "Nothing to remove - no nightly run is installed."; exit 2; fi
    if [ "$DRY" -eq 1 ]; then echo "Would remove:"; current_entry | sed 's/^/  /'; exit 0; fi
    if [ "$ASSUME_YES" -ne 1 ] && rp_is_interactive; then
        printf 'Remove the nightly run? [y/N] '; read -r reply
        case "$reply" in [Yy]*) ;; *) echo "Left as it is."; exit 2 ;; esac
    fi
    { crontab -l 2>/dev/null | grep -v "retroplay-all-sh" || true; } | crontab -
    echo "Removed. Your other cron entries were left alone."
    exit 0
fi
# --cron makes all.sh set a full PATH (cron's default PATH misses
# /usr/local/bin and Homebrew), rotate all_cron.log and write to it itself.
CRON_LINE="$((10#$CRON_MIN)) $((10#$CRON_HOUR)) * * * cd \"$SCRIPT_DIR\" && ./all.sh --cron $MARKER"

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
if [ "$DRY" -eq 1 ]; then
    echo "Would install:"; echo "  $CRON_LINE"
    [ -n "$(current_entry)" ] && { echo "replacing:"; current_entry | sed 's/^/  /'; }
    exit 0
fi
{ crontab -l 2>/dev/null | grep -v -F "retroplay-all-sh" || true; echo "$CRON_LINE"; } | crontab -

echo "Installed: all.sh will run every day at $RUN_TIME."
echo "  $CRON_LINE"
echo
echo "Output from each run is appended to: $RP_LOG_ROOT/all_cron.log"
echo "Your current PATH was saved for the nightly run, so tools like unlzx are"
echo "found even though cron itself starts with a minimal PATH."
echo
echo "Current crontab:"
crontab -l
