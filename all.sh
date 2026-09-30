#!/usr/bin/env bash
# retroplay-suite: 2026.09.29   (every script in the set must carry the same stamp)
# Remember where the user ran this from, before any cd: retroplay.conf is
# looked for there first (see lib.sh).
RP_INVOKED_FROM="${RP_INVOKED_FROM:-$PWD}"; export RP_INVOKED_FROM
#
# Purpose: The engine: update, extract, artwork, sort, install - for every variant.
#   Options: --aga --ecs --rtg --aga-laced --ecs-laced --set NAME --variants LIST
#            --clean --rebuild --force --skip-update --dry-run/--plan --cron
#            --dest DIR --art LIST --demo-art LIST --ffs/--pfs --detox/--no-detox
#            --status --test-notify --debug --help
# Run 'all.sh --help' for the authoritative, current list.
#
# Amiga Retroplay - pipeline engine
#
# Builds and updates one or more artwork variants (by default AGA, ECS and
# RTG - see VARIANTS in retroplay.conf) end to end. start.sh --auto, and so
# aga.sh / ecs.sh / rtg.sh, also run through here for a single variant, so
# every run gets the same protections:
#
#   * Archives are extracted and sorted ONCE, then copied per variant; only
#     the artwork merge differs between variants.
#   * New downloads are QUEUED per output folder and only removed from the
#     queue once that folder has actually absorbed them - a failed or
#     interrupted run is simply picked up again by the next one.
#   * A full build is marked "building" until it finishes, so an interrupted
#     one is redone instead of being mistaken for a finished collection.
#   * Free disk space is checked before extracting or copying.
#   * An updated game REPLACES its old folder, so files from older versions
#     don't linger; each batch is also kept in a dated new_<variant> folder.
#   * One summary report per run (reports/), optional notifications.
#
# Exit codes: 0 = work done, 2 = nothing to do, 1 = failure.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || { echo "ERROR: cannot cd to script directory: $SCRIPT_DIR" >&2; exit 1; }

# Shared helpers (retroplay.conf settings, dependency tracking, pending
# queues, disk-space checks...) live in lib.sh, next to this script.
if [ ! -f "$SCRIPT_DIR/lib.sh" ]; then
    echo "ERROR: lib.sh is missing from $SCRIPT_DIR - it ships with these scripts." >&2
    exit 1
fi
. "$SCRIPT_DIR/lib.sh"
rp_load_config

# --version answers before anything else is printed (no banner, no checks).
for _a in "$@"; do
    case "$_a" in
        --version|-V) printf 'whdsync %s (suite %s)\n' "$RP_RELEASE" "$RP_SUITE_VERSION"; exit 0 ;;
    esac
done
unset _a
rp_banner "all.sh"

usage() {
    cat << 'USAGE'
Usage: all.sh [options]

Builds or updates every variant listed in VARIANTS (retroplay.conf; default
"aga ecs rtg aga-laced ecs-laced") - or just the ones you name - extracting
archives only once. Each collection needs its own room on the drive; set
VARIANTS in retroplay.conf to build fewer of them.

Choosing variants (default: VARIANTS from retroplay.conf):
  --aga --ecs --rtg --aga-laced --ecs-laced   Pick variants (repeatable)
  --laced               Build the laced form of each AGA/ECS variant picked
  --all                 Every variant: aga, ecs, rtg, aga-laced, ecs-laced
  --set NAME            Use the iGame_NAME artwork set as a variant
  --variants "a b c"    Give the whole list at once
  --dest PATH           Custom output folder (only with a single variant)

What to do:
  --rebuild             Rebuild from the archives already downloaded, without
                        checking for updates (same as --clean --skip-update)
  --clean               Check for updates, then rebuild from scratch
  --skip-update         Don't download; process whatever is already queued
  --refresh-artwork     Refresh artwork for every game, including ones the
                        nightly gap-fill would skip (artwork already in the
                        collection is always rewritten from the packs)
  --force               Also run the artwork gap-fill on up-to-date variants
  --dry-run             Show what would happen, change nothing
  --status              Show the last run, each variant's state, drive, schedule
  --test-notify         Send a test notification and report whether it worked
  --cron                Unattended mode for cron: sets a full PATH, rotates
                        and writes to all_cron.log

Overrides for retroplay.conf settings:
  --art ORDER  --demo-art ORDER  --ffs | --pfs  --no-detox | --detox
  --quiet               Errors and the final result only (good for cron)
  --verbose             More detail about each stage
  --debug               Diagnostic detail (implies --verbose)
  --color auto|always|never   Colour: a terminal by default; NO_COLOR is honoured

Exit codes: 0 = work done, 2 = nothing to do, 1 = failure.
USAGE
}

# What this run was asked to do, for the lock record and the logs. Built from
# "$@" (not "$*") so an argument containing spaces is still readable as one
# argument: --dest "My Drive" stays --dest "My Drive", not two loose words.
# Purpose:       a human-readable record of the command line.
# Inputs:        the script's own arguments.
# Outputs:       ORIG_ARGS, a single display string.
# Side effects:  none. It is never re-executed, only printed.
rp_render_args() {
    local a out=""
    for a in ${1+"$@"}; do
        case "$a" in
            *[!A-Za-z0-9_=/.,:+-]*) out="$out \"$a\"" ;;   # quote anything with a space or shell character
            *)                      out="$out $a" ;;
        esac
    done
    printf '%s' "${out# }"
}
ORIG_ARGS="$(rp_render_args ${1+"$@"})"
VARIANT_ARGS=""; DEST_OVERRIDE=""; WANT_LACED=0
vstart=0            # when the collection being worked on started (see variant_row)
CLEAN=0; SKIP_UPDATE=0; FORCE=0
REFRESH_ART=0        # --refresh-artwork: replace artwork already in the collection
PREVIEW_ONLY=0       # --preview-new: save the dated batch, do not install it
DRY_RUN=0; CRON=0; DEBUG=0
ART_OVERRIDE=""; DEMO_ART_OVERRIDE=""; FS_OVERRIDE=""; DETOX_OVERRIDE=""

while [ $# -gt 0 ]; do
    opt="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$opt" in
        --aga|--ecs|--rtg|--aga-laced|--ecs-laced) VARIANT_ARGS="$VARIANT_ARGS ${opt#--}"; shift ;;
        # --laced is a modifier, not a variant: it turns each plain AGA/ECS
        # choice into its laced counterpart. It is applied after parsing, so
        # it works whether it comes before or after --aga.
        --laced)     WANT_LACED=1; shift ;;
        --all)       VARIANT_ARGS="$VARIANT_ARGS aga ecs rtg aga-laced ecs-laced"; shift ;;
        --set)       rp_require_option_value "$1" "$#" "${2-}"; VARIANT_ARGS="$VARIANT_ARGS $2"; shift 2 ;;
        --variants)  rp_require_option_value "$1" "$#" "${2-}"; VARIANT_ARGS="$VARIANT_ARGS $2"; shift 2 ;;
        --variant)   rp_require_option_value "$1" "$#" "${2-}"; VARIANT_ARGS="$VARIANT_ARGS $2"; shift 2 ;;
        -d|--dest)   rp_require_option_value "$1" "$#" "${2-}"; DEST_OVERRIDE="$2"; shift 2 ;;
        --clean)     CLEAN=1; shift ;;
        --rebuild)   CLEAN=1; SKIP_UPDATE=1; shift ;;
        --skip-update) SKIP_UPDATE=1; shift ;;
        --force)     FORCE=1; shift ;;
        --preview-new)
            # Build the dated batch of new games and stop there: the
            # collection itself is left exactly as it is. Same queue, same
            # lock, same drive check, same report as a normal run.
            PREVIEW_ONLY=1; shift ;;
        --refresh-artwork) REFRESH_ART=1; shift ;;
        --jobs)      rp_require_option_value "$1" "$#" "${2-}"; RP_JOBS_OVERRIDE="$2"; export RP_JOBS_OVERRIDE; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --cron)      CRON=1; shift ;;
        --art)       rp_require_option_value "$1" "$#" "${2-}"; ART_OVERRIDE="$2"; shift 2 ;;
        --demo-art)  rp_require_option_value "$1" "$#" "${2-}"; DEMO_ART_OVERRIDE="$2"; shift 2 ;;
        --ffs)       FS_OVERRIDE=ffs; shift ;;
        --pfs)       FS_OVERRIDE=pfs; shift ;;
        --no-detox)  DETOX_OVERRIDE=no; shift ;;
        --detox)     DETOX_OVERRIDE=yes; shift ;;
        --debug)     DEBUG=1; RP_VERBOSITY=3; RP_DEBUG=1; export RP_VERBOSITY RP_DEBUG; rp_set_colours; shift ;;
        --quiet)     RP_VERBOSITY=0; export RP_VERBOSITY; shift ;;
        --verbose)   [ "$RP_VERBOSITY" -lt 2 ] && RP_VERBOSITY=2; export RP_VERBOSITY; shift ;;
        --color|--colour)
                     rp_require_option_value "$1" "$#" "${2-}"
                     RP_COLOR="$2"; export RP_COLOR; rp_set_colours; shift 2 ;;
        --color=*|--colour=*)
                     RP_COLOR="${1#*=}"; export RP_COLOR; rp_set_colours; shift ;;
                --status)    rp_print_status; exit 0 ;;
        --test-notify) rp_test_notify; exit $? ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)" >&2; exit 4 ;;
    esac
done

# ----- Cron mode -----
# (cron's bare PATH is already taken care of by lib.sh, for every script:
# it adds back the PATH remembered from your last interactive run.) cron
# can't rotate its own >> log, so --cron does that and writes the log itself.
if [ "$CRON" -eq 1 ]; then
    mkdir -p "$RP_LOG_ROOT" 2>/dev/null; CRON_LOG="$RP_LOG_ROOT/all_cron.log"
    rp_rotate_log "$CRON_LOG" "$RP_LOG_MAX_MB" "$RP_LOG_KEEP"
    exec >> "$CRON_LOG" 2>&1 < /dev/null
    echo
    echo "==================== all.sh --cron: $(date '+%Y-%m-%d %H:%M:%S') ===================="
fi

rp_print_config_warnings

# Refuse to run with a mix of old and new scripts - an out-of-date one can do
# real damage (an older extract.sh recreated Users/<you>/Downloads/Amiga/...
# inside retro_*).
suite_bad="$(rp_suite_mismatches)"
if [ -n "$suite_bad" ]; then
    echo "ERROR: these scripts are not from the same version as lib.sh ($RP_SUITE_VERSION):" >&2
    printf '%s\n' "$suite_bad" | sed 's/^/  /' >&2
    echo "Copy the COMPLETE, current set of scripts into $SCRIPT_DIR, then run again." >&2
    rp_notify "Amiga Retroplay: run refused" "Scripts from different versions found: $(printf '%s ' $suite_bad)- copy the complete current set."
    exit "$RP_EXIT_CONFIG"
fi

# Every start.sh step run from here skips its interactive "view error log?"
# prompt and appends to one shared retroerror.log for the whole run.
export RETROPLAY_ALL_SH=1

if [ "$DRY_RUN" -eq 0 ]; then
OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"

# ----- Prevent overlapping runs -----
# Two full pipelines against the same folders at once is exactly what
# corrupts output and doubles the load on a small device, so a second
# instance exits immediately instead of piling up. The lock itself lives in
# lib.sh, so the stage scripts run by hand honour the same one.
RUN_ID="$(date '+%Y%m%d-%H%M%S')-$$"
RP_RUN_ID="$RUN_ID"

# Installing packages mid-run would stop a build (or a cron job) at a sudo
# prompt, so it only happens when explicitly asked for.
if ! rp_flock_bin >/dev/null 2>&1 && [ -t 0 ] && rp_may_install_tools; then
    echo "'flock' was not found - it's needed to guarantee only one run"
    echo "happens at a time (e.g. so cron can't overlap a still-running pass)."
    if [ "$OS_TYPE" = "darwin" ]; then
        printf 'Install it now via Homebrew (brew install util-linux)? [y/N] '
    else
        printf 'Install it now via apt (sudo apt install util-linux)? [y/N] '
    fi
    read -r _flock_reply
    case "$_flock_reply" in
        [Yy]*)
            if [ "$OS_TYPE" = "darwin" ]; then
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
            ;;
    esac
    unset _flock_reply
fi

rp_lock_take "all.sh $ORIG_ARGS" || rp_lock_refuse "all.sh"
if [ "$RP_LOCK_HELD" = "2" ]; then
    rp_warn "'flock' not found - using a simpler lock folder instead"
    if [ "$OS_TYPE" = "darwin" ]; then
        rp_info "  For the most reliable locking: brew install util-linux"
    else
        rp_info "  For the most reliable locking: sudo apt install util-linux"
    fi
fi

fi

# ============================================================================
# Settings for this run
# ============================================================================
FS_FLAG="--${FS_OVERRIDE:-$RP_FILESYSTEM}"
# Art orders must only name the three artwork sections.
for _o in "${ART_OVERRIDE:-}" "${DEMO_ART_OVERRIDE:-}" "$RP_ART_ORDER" "$RP_DEMO_ART_ORDER"; do
    [ -n "$_o" ] || continue
    for _s in $(printf '%s' "$_o" | tr ',' ' '); do
        case "$(printf '%s' "$_s" | tr '[:upper:]' '[:lower:]')" in
            covers|screens|titles) ;;
            *) rp_die "$RP_EXIT_CONFIG" "art order '$_o' contains '$_s' - use only Covers, Screens and Titles, e.g. Covers,Screens,Titles" ;;
        esac
    done
done
USE_DETOX="${DETOX_OVERRIDE:-$RP_USE_DETOX}"
DETOX_FLAG=""; [ "$USE_DETOX" = "yes" ] || DETOX_FLAG="--no-detox"
DEBUG_FLAG=""; [ "$DEBUG" -eq 1 ] && DEBUG_FLAG="--debug"
DEMO_ART="${DEMO_ART_OVERRIDE:-$RP_DEMO_ART_ORDER}"
RUN_TS="$(rp_timestamp)"
WORK_ROOT="$RP_OUTPUT_ROOT/.retroplay_work"     # same drive as the output, so moves are instant
STAGE_ROOT="$RP_STATE_DIR/stage"                # same drive as the archives, so staging can hardlink
REPORT_DIR="$RP_REPORT_ROOT"
REPORT_TMP="$(mktemp "${TMPDIR:-/tmp}/retroplay_report.XXXXXX")"
# finish() (installed further down) is what normally clears these, but it is
# not in place yet: until it is, anything that exits early - a bad option, a
# drive that is not mounted - would leave the file in /tmp. This stop-gap trap
# is replaced by `trap finish EXIT` once the real one is ready.
trap 'rm -f "$REPORT_TMP" "$REPORT_TMP".* 2>/dev/null' EXIT INT TERM
FAIL_REASON=""

report() { printf '%s\n' "$*" >> "$REPORT_TMP"; }
# Per-variant results for the table at the end.
VARIANT_ROWS=""
# Per-stage seconds, so a slow run can be explained rather than guessed at.
# (Per-variant time is already in the summary table; this is the breakdown.)
STAGE_TIMES=""
_stage_t0=0
stage_start() { _stage_t0="$SECONDS"; }
stage_end()   { STAGE_TIMES="$STAGE_TIMES$1=$(( SECONDS - _stage_t0 ))
"; }
variant_row() {   # variant_row <key> <started at $SECONDS> [note]
    local key="$1" t0="$2" note="${3:-}" dest="" art="" games kb i kind i_last=0
    for i in "${!V_KEY[@]}"; do
        [ "${V_KEY[$i]}" = "$key" ] && { dest="${V_DEST[$i]}"; art="${V_ART[$i]%%,*}"; i_last="$i"; }
    done
    [ -n "$dest" ] && [ -d "$dest" ] || return 0
    games="$(rp_count_games "$dest")"; kb="$(rp_du_kb "$dest")"
    VARIANT_ROWS="$VARIANT_ROWS$key|${games:-0}|$(( ${kb:-0} / 1024 ))|$(rp_format_duration $(( SECONDS - t0 )))|${art:-none}|$note
"
    # Record what this collection now is, while the numbers are in hand.
    case "$note" in
        built)   kind=full ;;
        updated) kind=update ;;
        *)       kind="${note:-update}" ;;
    esac
    rp_write_manifest "$key" "$dest" "$kind" "${games:-0}" "${kb:-0}" \
        "${V_ART[$i_last]:-}" "${V_MFLAGS[$i_last]:-}"
    return 0
}

mark_success() { mkdir -p "$RP_STATE_DIR/last_success" 2>/dev/null; rp_ts | rp_atomic_write "$RP_STATE_DIR/last_success/$1"; }
# fail_with <exit code> <message>; fail <message> = unexpected error (1).
FAIL_CODE=1
fail_with() { FAIL_CODE="$1"; shift; FAIL_REASON="$*"; echo; echo "ERROR: $*" >&2; exit "$FAIL_CODE"; }
fail()      { fail_with 1 "$@"; }

# ----- Resolve the variants -----
V_TOK=(); V_DEST=(); V_KEY=(); V_EXCL=(); V_ART=(); V_NEW=(); V_MFLAGS=(); V_ACT=(); V_WHY=()
# --laced rewrites the plain AGA/ECS choices into their laced counterparts
# before anything else looks at the list. RTG has no laced pack, so it is
# left as it is rather than silently dropped.
if [ "$WANT_LACED" -eq 1 ]; then
    _laced_in="${VARIANT_ARGS:-$RP_VARIANTS}"; _laced_out=""
    for _lt in $(printf '%s' "$_laced_in" | tr ',' ' '); do
        case "$(printf '%s' "$_lt" | tr '[:upper:]' '[:lower:]')" in
            aga) _lt="aga-laced" ;;
            ecs) _lt="ecs-laced" ;;
        esac
        _laced_out="$_laced_out $_lt"
    done
    VARIANT_ARGS="$_laced_out"
    unset _laced_in _laced_out _lt
fi
for tok in $(printf '%s' "${VARIANT_ARGS:-$RP_VARIANTS}" | tr ',' ' '); do
    tok="$(printf '%s' "$tok" | tr '[:upper:]' '[:lower:]')"
    # A typo such as "agaa" would otherwise quietly build retro_agaa with
    # fallback artwork only - reject anything that isn't a known variant or
    # an existing iGame_<NAME> artwork folder.
    case "$tok" in
        aga|ecs|rtg|aga-laced|ecs-laced|default) ;;
        *)
            _found=""
            for _d in "$RP_ARTWORK_ROOT"/[iI][gG][aA][mM][eE]_*; do
                [ -d "$_d" ] || continue
                [ "$(printf '%s' "${_d##*/}" | cut -d_ -f2- | tr '[:upper:]' '[:lower:]')" = "$tok" ] && _found=1
            done
            [ -n "$_found" ] || rp_die "$RP_EXIT_CONFIG" "unknown variant '$tok' - use aga, ecs, rtg, aga-laced, ecs-laced, or the name of an iGame_<NAME> artwork folder"
            ;;
    esac
    dup=0
    for t in "${V_TOK[@]+"${V_TOK[@]}"}"; do [ "$t" = "$tok" ] && dup=1; done
    [ "$dup" -eq 1 ] && continue
    V_TOK+=("$tok")
done
[ "${#V_TOK[@]}" -gt 0 ] || rp_die "$RP_EXIT_CONFIG" "no variants to build (check VARIANTS in retroplay.conf)."
# Say out loud how many collections this run will produce. Each one is a full
# copy on the drive, so "why is this taking all night" and "why is the disk
# full" both start here.
rp_info "Collections this run: ${V_TOK[*]}   (set VARIANTS in retroplay.conf to change)"
if [ -n "$DEST_OVERRIDE" ] && [ "${#V_TOK[@]}" -gt 1 ]; then
    rp_die "$RP_EXIT_CONFIG" "--dest can only be used when building a single variant."
fi

for i in "${!V_TOK[@]}"; do
    tok="${V_TOK[$i]}"
    if [ -n "$DEST_OVERRIDE" ]; then
        case "$DEST_OVERRIDE" in /*) d="$DEST_OVERRIDE" ;; *) d="$SCRIPT_DIR/$DEST_OVERRIDE" ;; esac
    elif [ "$tok" = "default" ]; then
        d="$RP_BUILD_ROOT/retro"
    else
        d="$RP_BUILD_ROOT/retro_$(rp_variant_suffix "$tok")"
    fi
    d="${d%/}"
    V_DEST[$i]="$d"
    V_KEY[$i]="${d##*/}"
    V_EXCL[$i]="$(rp_exclude_tags_for "$tok")"
    V_ART[$i]="${ART_OVERRIDE:-$(rp_art_order_for "$tok")}"
    V_NEW[$i]="$RP_BUILD_ROOT/new_${V_KEY[$i]#retro_}"
    V_MFLAGS[$i]="$(rp_variant_merge_args "$tok" | tr '\n' ' ')"
done

# Leftovers from an interrupted run are only temporary copies. The staging
# folder lives under .retroplay and is cleared by rp_tidy_state in step 1,
# which also reports how much it freed.
if [ "$DRY_RUN" -eq 0 ]; then
    rm -rf -- "$WORK_ROOT"
    rm -f "$RP_LOG_ROOT/retroerror.log"
fi

finish() {
    local st=$? errs=0 result body sname ssecs free_left
    stage_end build_seconds
    if [ "$DRY_RUN" -eq 0 ]; then rp_lock_release; fi
    rm -f "$REPORT_TMP".* 2>/dev/null        # .missing, .fetch and anything else
    if [ "$DRY_RUN" -eq 1 ]; then rm -f "$REPORT_TMP"; return; fi
    rm -rf -- "$WORK_ROOT" "$STAGE_ROOT"
    [ -s "$RP_LOG_ROOT/retroerror.log" ] && errs="$(grep -c . "$RP_LOG_ROOT/retroerror.log")"
    case "$st" in
        0) result="Finished successfully" ;;
        2) result="Nothing to do - everything is up to date" ;;
        5) result="Finished, but some archives couldn't be extracted (exit 5: they'll be retried)" ;;
        *) result="FAILED (exit $st: $(rp_exit_meaning "$st"))${FAIL_REASON:+ - $FAIL_REASON}" ;;
    esac
    # For the status view: the last run's result.
    rp_state_init
    printf 'code=%s\ntime=%s\nresult=%s\nreport=reports/%s.txt\n' "$st" "$(rp_ts)" "$result" "$RUN_TS" \
        | rp_atomic_write "$RP_STATE_DIR/last_run"
    if [ "$st" -ne 2 ] || [ -s "$REPORT_TMP" ]; then
        mkdir -p "$REPORT_DIR"
        {
            echo "Amiga Retroplay run report - $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Result:   $result"
            if [ -n "$VARIANT_ROWS" ]; then
                echo
                printf '  %-14s %6s %9s %9s  %-8s %s\n' "Collection" "Games" "Size(MB)" "Time" "Artwork" "Result"
                printf '  %-14s %6s %9s %9s  %-8s %s\n' "--------------" "------" "--------" "--------" "--------" "-------"
                printf '%s' "$VARIANT_ROWS" | while IFS='|' read -r k g m t a n; do
                    [ -n "$k" ] || continue
                    printf '  %-14s %6s %9s %9s  %-8s %s\n' "$k" "$g" "$m" "$t" "$a" "$n"
                done
                echo
            fi
            printf 'Total time: %d:%02d:%02d\n' $((SECONDS / 3600)) $(((SECONDS % 3600) / 60)) $((SECONDS % 60))
            # Where the time actually went. Useful on a Pi, and the thing to
            # look at before changing any JOBS setting.
            if [ -n "$STAGE_TIMES" ]; then
                echo "Time per stage (seconds):"
                printf '%s' "$STAGE_TIMES" | while IFS='=' read -r sname ssecs; do
                    [ -n "$sname" ] || continue
                    printf '  %-22s %s\n' "${sname%_seconds}" "$ssecs"
                done
            fi
            echo
            [ -s "$REPORT_TMP" ] && cat "$REPORT_TMP" && echo
            if [ "$errs" -gt 0 ]; then
                echo "Errors/warnings logged: $errs line(s) - see retroerror.log"
            else
                echo "No errors logged."
            fi
            free_left="$(rp_free_kb "$RP_OUTPUT_ROOT")"      # asked once, not twice
            [ -n "$free_left" ] && echo "Free space left: $(( free_left / 1024 )) MB"
        } > "$REPORT_DIR/$RUN_TS.txt"
        echo
        echo "======================== Summary ========================"
        cat "$REPORT_DIR/$RUN_TS.txt"
        echo "(saved as reports/$RUN_TS.txt)"
        # Keep the newest 60 reports. Report names are timestamps, so the
        # shell's own glob order is the chronological one.
        _rep_total="$(rp_count_matching "$REPORT_DIR/*.txt")"
        if [ "$_rep_total" -gt 60 ]; then
            _rep_n=0
            for _rep in "$REPORT_DIR"/*.txt; do
                [ -e "$_rep" ] || continue
                _rep_n=$((_rep_n + 1))
                [ "$_rep_n" -le $((_rep_total - 60)) ] || break
                rm -f -- "$_rep" "${_rep%.txt}"_*
            done
        fi
        unset _rep _rep_n _rep_total
    fi
    [ -n "${ARTWORK_NOTE:-}" ] && result="$result ($ARTWORK_NOTE)"
    body="$(cat "$REPORT_DIR/$RUN_TS.txt" 2>/dev/null)"
    if [ "$st" -ne 0 ] && [ "$st" -ne 2 ]; then
        rp_notify "Amiga Retroplay: $(rp_exit_meaning "$st")" "${body:-$result}"
    elif [ "$st" -eq 0 ] && [ "$RP_NOTIFY_ON_SUCCESS" = "yes" ]; then
        rp_notify "Amiga Retroplay: run finished" "$body"
    fi
    rm -f "$REPORT_TMP"

    # Last thing on the screen, after the summary, however the run ended:
    # the PFS filename warning (only when building for PFS).
    [ "$DRY_RUN" -eq 0 ] && rp_pfs_reminder
}
trap finish EXIT
trap 'fail_with "$RP_EXIT_INTERRUPTED" "interrupted"' INT TERM

# ----- Safety checks before touching anything -----
# Everything from here on says what it is doing before it does it: the first
# steps can take a while on a Pi (tidying folders, checking artwork), and
# silence looks like a hung script.
TOTAL_STEPS=5
if ! rp_quiet; then
echo
echo "${RP_C_HEAD}Amiga Retroplay${RP_C_OFF} - $([ "$DRY_RUN" -eq 1 ] && echo "plan only, nothing will be changed" || echo "building: $(printf '%s ' "${V_KEY[@]}")")"
echo "${RP_C_DIM}Collection: $RP_BUILD_ROOT   Archives: $RP_DOWNLOAD_ROOT   Artwork: $RP_ARTWORK_ROOT${RP_C_OFF}"
fi
if [ "$DRY_RUN" -eq 0 ]; then
    stage_start
    rp_step 1 "$TOTAL_STEPS" "Checking the setup and the output drive"
    rp_restore_state_if_lost
    # After the restore: this writes a timestamp into the state folder, and
    # doing it earlier made a lost state folder look present.
    rp_check_for_update
    rp_info '      checking the tools this run needs...'
    rp_require_tools lha 7z unar || fail "some tools this run needs are not on PATH - nothing was downloaded or changed"
    command -v unlzx >/dev/null 2>&1 || rp_warn "unlzx is not installed - .lzx archives will be skipped (./setup.sh installs it)"
    rp_require_bash4 || fail_with "$RP_EXIT_CONFIG" "cannot add artwork without bash 4 - nothing was downloaded or changed"
    rp_info '      checking the output folder is there...'
    rp_check_output_root || fail_with "$RP_EXIT_CONFIG" "the output folder isn't available (drive not mounted?) - nothing was changed"
    rp_info '      tidying the folder layout if needed...'
    rp_migrate_layout      # only once the output drive is known to be there
    rp_info '      tidying leftovers in .retroplay...'
    rp_tidy_state
    rp_info '      clearing old logs...'
    rp_prune_logs
    rp_info '      backing up the queue and build markers...'
    rp_backup_state
    rp_done "ready"
else
    rp_step 1 "$TOTAL_STEPS" "Checking the setup (plan only)"
    rp_check_output_root dry || rp_die "$RP_EXIT_CONFIG" "the output folder isn't available (drive not mounted?)"
fi

# ============================================================================
# 0. Artwork check (before the game pipeline, inside this run's single lock)
# ============================================================================
# ARTWORK_SYNC: no = never here; ask = only when run by hand and artwork is
# missing; auto/yes = check at most once every ARTWORK_CHECK_INTERVAL_HOURS.
# artwork_sync.sh runs in library mode so it does NOT take a second lock.
ARTWORK_NOTE=""
stage_end preflight_seconds
artwork_preflight() {
    local due_stamp="$RP_STATE_DIR/artwork_last_check" rc=0 mode="$RP_ARTWORK_SYNC"
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ -f "$SCRIPT_DIR/artwork_sync.sh" ] || return 0
    case "$mode" in
        no) return 0 ;;
        ask)
            # Missing artwork is fetched without asking - a build without it
            # produces a collection with no pictures, which is never wanted.
            # (The question only remains for the interval check below.)
            : ;;
        auto|yes)
            if [ -f "$due_stamp" ] && [ -z "$(find "$due_stamp" -mmin "+$(( RP_ARTWORK_CHECK_INTERVAL_HOURS * 60 ))" 2>/dev/null)" ]; then
                rp_debug "artwork checked recently - skipping"
                return 0
            fi ;;
    esac
    # Only the artwork the variants in THIS run need; a full run (every
    # variant in VARIANTS) fetches everything the source offers.
    local art_args="" i_ nvar=0
    for i_ in "${!V_TOK[@]}"; do art_args="$art_args --for ${V_TOK[$i_]}"; nvar=$((nvar + 1)); done
    if [ "$nvar" -ge "$(printf '%s' "$RP_VARIANTS" | tr ',' ' ' | wc -w)" ]; then
        art_args="--all-artwork"
    fi
    # Anything missing? Then fetch it now, before the collection is built.
    local missing
    missing="$(rp_artwork_missing "$(printf '%s ' "${V_TOK[@]}")" | tr '\n' ' ')"
    if [ -n "$missing" ]; then
        rp_step 2 "$TOTAL_STEPS" "[Artwork] missing: $missing- downloading it now"
    else
        # Nothing missing: only check again when the interval says so.
        if [ "$mode" != "auto" ] && [ "$mode" != "yes" ]; then
            rp_debug "artwork present and ARTWORK_SYNC=$mode - not checking for updates"
            return 0
        fi
        rp_step 2 "$TOTAL_STEPS" "[Artwork] checking for updates ($art_args)"
    fi
    # shellcheck disable=SC2086
    ./artwork_sync.sh --sync $art_args --called-from-all; rc=$?
    rp_state_init
    # The "checked recently" stamp is only written when the check actually
    # finished. A pack that failed to download (a 503 from the source, a
    # dropped connection) is NOT recorded as current: its manifest in
    # .retroplay is left exactly as it was, and removing the stamp means the
    # very next run tries again instead of waiting out the 24 hour interval.
    case "$rc" in
        0|2) : > "$due_stamp" ;;
        *)   rm -f "$due_stamp" ;;
    esac
    case "$rc" in
        0) ARTWORK_NOTE="artwork updated"; report "[Artwork] packs updated (see the messages above)" ;;
        2) report "[Artwork] no changes" ;;
        *)
            ARTWORK_NOTE="artwork update had problems; the previous artwork was kept"
            report "[Artwork] WARNING: update did not complete - your previous artwork was kept"
            rp_warn "the pack(s) that failed were not recorded as up to date - the next run will try them again"
            if [ "$RP_ARTWORK_FAILURE_POLICY" = "fail" ]; then
                fail_with "$RP_EXIT_INTEGRITY" "artwork update failed and ARTWORK_FAILURE_POLICY=fail - stopping before any collection changes (queues are untouched)"
            fi
            WARN_ONLY=1 ;;
    esac
    return 0
}
stage_start
artwork_preflight
stage_end artwork_seconds

# ============================================================================
# 1. Check for updates
# ============================================================================
# Folders from older versions of these scripts get markers first, so that
# anything downloaded now is queued for them.
if [ "$DRY_RUN" -eq 0 ]; then
    for i in "${!V_TOK[@]}"; do
        # A build cut short while swapping the new collection in leaves the
        # previous one under a .previous_ name: put it back before anything
        # else looks at the folder.
        rp_recover_swap "${V_DEST[$i]}"
        rp_adopt_legacy "${V_KEY[$i]}" "${V_DEST[$i]}"
    done
fi

stage_start
if [ "$SKIP_UPDATE" -eq 0 ]; then
    rp_step 3 "$TOTAL_STEPS" "Checking the Retroplay server for new archives"
    if [ "$DRY_RUN" -eq 1 ]; then
        RP_CHILD=1 ./update.sh --dry-run
    else
        RP_CHILD=1 ./update.sh; ust=$?
        case "$ust" in
            0|2) ;;
            3) fail_with "$RP_EXIT_REMOTE" "could not update from the Retroplay server (network or server problem) - will retry next run" ;;
            4) fail_with "$RP_EXIT_CONFIG" "update.sh could not run (missing tool or bad setup - see above)" ;;
            *) fail "update.sh failed (exit $ust)" ;;
        esac
    fi
    echo
fi

# ============================================================================
# 2. Decide what each variant needs
# ============================================================================
for i in "${!V_TOK[@]}"; do
    state="$(rp_build_state "${V_KEY[$i]}" "${V_DEST[$i]}")"
    q="$(rp_queue_count "${V_KEY[$i]}")"
    if [ "$CLEAN" -eq 1 ]; then
        V_ACT[$i]=full; V_WHY[$i]="rebuild requested"
    elif [ "$state" = fresh ]; then
        V_ACT[$i]=full; V_WHY[$i]="not built yet"
    elif [ "$state" = incomplete ]; then
        V_ACT[$i]=full; V_WHY[$i]="the last full build was interrupted - redoing it"
    elif [ -n "$(rp_layout_problems "${V_DEST[$i]}")" ]; then
        # e.g. a Users/<you>/Downloads/Amiga/... tree from the old path bug.
        # Games in there never got artwork or sorting, so rebuild cleanly.
        V_ACT[$i]=full
        V_WHY[$i]="folders in the wrong place ($(rp_layout_problems "${V_DEST[$i]}" | tr '\n' ' ' | sed 's/ $//')) - rebuilding it correctly"
    elif [ "$q" -gt 0 ]; then
        V_ACT[$i]=update; V_WHY[$i]="$q new archive(s) queued"
    elif [ "$REFRESH_ART" -eq 1 ]; then
        V_ACT[$i]=gapfill; V_WHY[$i]="up to date - refreshing the artwork for every game"
    elif [ "$FORCE" -eq 1 ]; then
        V_ACT[$i]=gapfill; V_WHY[$i]="up to date - artwork gap-fill only"
    elif rp_gapfill_due "${V_KEY[$i]}"; then
        V_ACT[$i]=gapfill; V_WHY[$i]="up to date - artwork packs changed (or ${RP_GAPFILL_DAYS}-day check): filling in missing artwork"
    else
        V_ACT[$i]=none; V_WHY[$i]="up to date"
    fi
done

stage_end update_seconds
stage_start
rp_step 4 "$TOTAL_STEPS" "Plan - working out what needs doing"
echo
for i in "${!V_TOK[@]}"; do
    printf '  %-16s %-8s %s%s\n' "${V_KEY[$i]}" "${V_ACT[$i]}" "${V_WHY[$i]}" \
        "${V_EXCL[$i]:+  (leaving out: ${V_EXCL[$i]})}"
done
echo

# Saved batches with the wrong layout are only broken copies (the games are
# in the archives and get rebuilt) - remove them so they can't be copied on.
for i in "${!V_TOK[@]}"; do
    for b in "${V_NEW[$i]}"/*; do
        [ -d "$b" ] && [ -n "$(rp_layout_problems "$b")" ] || continue
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "Would remove ${b#"$RP_OUTPUT_ROOT"/} (wrong folder layout)"
        else
            rm -rf -- "$b"
            echo "Removed ${b#"$RP_OUTPUT_ROOT"/} - it had the wrong folder layout"
            report "Removed ${b#"$RP_OUTPUT_ROOT"/} (wrong folder layout from the old path bug)"
        fi
    done
done

any_work=0
for i in "${!V_TOK[@]}"; do [ "${V_ACT[$i]}" != none ] && any_work=1; done

if [ "$DRY_RUN" -eq 1 ]; then
    for i in "${!V_TOK[@]}"; do
        [ "${V_ACT[$i]}" = update ] || continue
        echo "Queued for ${V_KEY[$i]}:"
        n=0
        while IFS= read -r p; do
            n=$((n + 1)); [ "$n" -le 10 ] || continue
            note=""
            [ -f "$RP_DOWNLOAD_ROOT/$p" ] || note="  (superseded - will be skipped)"
            [ -n "${V_EXCL[$i]}" ] && rp_archive_has_tag "$p" "${V_EXCL[$i]}" && note="  (left out: ${V_EXCL[$i]})"
            echo "    $p$note"
        done < "$(rp_queue_file "${V_KEY[$i]}")"
        [ "$n" -gt 10 ] && echo "    ...and $((n - 10)) more"
    done
    for i in "${!V_TOK[@]}"; do
        if [ "${V_ACT[$i]}" = full ]; then
            akb="$(rp_du_kb "$RP_DOWNLOAD_ROOT")"
            free_kb_now="$(rp_free_kb "$RP_OUTPUT_ROOT")"
            echo "A full build needs roughly $(( akb * RP_SPACE_FACTOR * 2 / 1024 )) MB free; $(( ${free_kb_now:-0} / 1024 )) MB available."
            break
        fi
    done
    echo
    echo "Dry run only - nothing was changed."
    exit 0
fi

if [ "$any_work" -eq 0 ]; then
    echo "Nothing new to process - every variant is up to date."
    exit 2
fi
stage_end plan_seconds
stage_start
mkdir -p "$WORK_ROOT" "$STAGE_ROOT"

# extract.sh writes extract_errors.log into the folder it runs from; when
# that's a temporary staging folder, move the log out before it's deleted.
rescue_extract_log() {
    if [ -s "$1/extract_errors.log" ]; then
        cat "$1/extract_errors.log" >> "$RP_LOG_ROOT/extract_errors.log"
    fi
}

# stage_failed <exit status> <what failed> <log heading>
# Every stage failure says the same four things: which stage, the exit status
# and what it means, that the previous collection is untouched, and where the
# details are. "ERROR: sorting failed" said none of them, and nothing reached
# the logs either.
stage_failed() {
    local rc="$1" what="$2" heading="$3"
    collect_stage_logs "$heading" || true
    mkdir -p "$RP_LOG_ROOT" 2>/dev/null
    {
        printf '===== %s failed =====\n' "$what"
        printf '%s  exit status %s (%s)\n' "$(rp_ts)" "$rc" "$(rp_exit_meaning "$rc")"
        printf 'The collection in %s was not changed; the archives stay queued.\n\n' "$RP_BUILD_ROOT"
    } >> "$RP_LOG_ROOT/retroerror.log"
    {
        echo
        echo "$what failed with exit status $rc ($(rp_exit_meaning "$rc"))."
        echo "  Nothing in $RP_BUILD_ROOT was changed, and the archives stay queued for the next run."
        echo "  Details: $RP_LOG_ROOT/retroerror.log"
        echo "  The stage's own last message, just above this, usually names the cause."
    } >&2
    fail "$what failed (exit $rc) - see logs/retroerror.log"
}

# all.sh calls the stage scripts directly rather than through start.sh, so the
# log gathering start.sh does at the end of a manual run never happens here.
# Without this, retroerror.log stayed empty for a pipeline run and the summary
# cheerfully reported "No errors logged" after a stage had written a full page
# of them. Each stage log is appended under its own heading and then removed,
# so the next stage's errors cannot be mistaken for this one's.
collect_stage_logs() {   # collect_stage_logs <heading>
    local f name found=0
    for f in "$RP_LOG_ROOT"/extract_errors.log "$RP_LOG_ROOT"/merge_errors.log \
             "$RP_LOG_ROOT"/sort.log "$RP_LOG_ROOT"/amiga_filename_issues.log; do
        [ -s "$f" ] || { rm -f -- "$f"; continue; }
        name="${f##*/}"
        {
            printf '===== %s%s =====\n' "$name" "${1:+  ($1)}"
            cat "$f"
            printf '\n'
        } >> "$RP_LOG_ROOT/retroerror.log"
        rm -f -- "$f"
        found=1
    done
    return "$((1 - found))"
}

# Safety net: an extracted tree must only contain the archive folders at
# its top level. Anything else (e.g. a whole absolute path such as
# Users/<you>/Downloads/Amiga recreated inside it) means the extraction went
# wrong - stop before it reaches a collection; the batch stays queued.
check_layout() {
    local bad
    bad="$(rp_layout_problems "$1" | tr '\n' ' ')"
    [ -z "$bad" ] || fail_with "$RP_EXIT_INTEGRITY" "unexpected folder(s) in the extracted files:$bad (expected only WHDLoad, HD_Loaders, JST) - nothing was installed"
}

# ----- Archives that fail to extract -----
# Everything that DID extract is installed; failed archives stay queued and
# are retried next run. After MAX_EXTRACT_ATTEMPTS failures an archive is
# moved to old/corrupt-<date>/, so the next update downloads a fresh copy
# (a corrupt download is the usual cause). The run exits 5 so you hear of it.
INTEGRITY_ISSUES=0
ATTEMPTS_FILE="$RP_STATE_DIR/extract_attempts.list"      # "<count><TAB><archive>"

# run_extract <failure-accumulator> <extract.sh args...>  (from the current folder)
run_extract() {
    local acc="$1" tmp st; shift
    tmp="$WORK_ROOT/.failed.$$.${RANDOM:-0}"
    # Run from the downloads folder so the paths inside the collection stay
    # WHDLoad/... rather than downloads/WHDLoad/...
    ( cd "$RP_DOWNLOAD_ROOT" && RP_EXTRACT_FAILED_LIST="$tmp" RP_CHILD=1 \
        bash "$SCRIPT_DIR/extract.sh" --called-from-all "$@" ); st=$?
    [ -s "$tmp" ] && cat "$tmp" >> "$acc"
    rm -f "$tmp"
    case "$st" in
        0|5) return 0 ;;
        130) fail_with "$RP_EXIT_INTERRUPTED" "interrupted" ;;
        *)   fail "the extractor stopped unexpectedly (exit $st)" ;;
    esac
}

# match_failures <failure-list> <archive-list>: prints the archives (from the
# second list, relative paths) that failed. Matched by path SUFFIX, so the
# way a folder's path happens to be spelled can never cause a mismatch.
match_failures() {
    local p line d
    [ -s "$1" ] || return 0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        while IFS= read -r line; do
            case "$line" in
                DIR:*) d="${line#DIR:}"; case "$d/" in *"/${p%/*}/") printf '%s\n' "$p"; break ;; esac ;;
                *"/$p") printf '%s\n' "$p"; break ;;
            esac
        done < "$1"
    done < "$2"
}

clear_extract_failures() {   # <file of archives that extracted fine>
    [ -s "$ATTEMPTS_FILE" ] && [ -s "$1" ] || return 0
    awk -F'\t' 'NR == FNR { ok[$0] = 1; next } !($2 in ok)' "$1" "$ATTEMPTS_FILE" | rp_atomic_write "$ATTEMPTS_FILE"
}

# handle_failed <archive>: counts the attempt; gives up after the limit.
handle_failed() {
    local rel="$1" n q dest
    rp_state_init
    n="$(awk -F'\t' -v r="$rel" '$2 == r { print $1 }' "$ATTEMPTS_FILE" 2>/dev/null)"
    n=$(( ${n:-0} + 1 ))
    { awk -F'\t' -v r="$rel" '$2 != r' "$ATTEMPTS_FILE" 2>/dev/null; printf '%s\t%s\n' "$n" "$rel"; } | rp_atomic_write "$ATTEMPTS_FILE"
    INTEGRITY_ISSUES=1
    if [ "$n" -ge "$RP_MAX_EXTRACT_ATTEMPTS" ]; then
        dest="$RP_DOWNLOAD_ROOT/old/corrupt-$(date '+%Y-%m-%d')/$rel"
        mkdir -p "$(dirname "$dest")"
        [ -f "$RP_DOWNLOAD_ROOT/$rel" ] && mv "$RP_DOWNLOAD_ROOT/$rel" "$dest"
        for q in "$RP_STATE_DIR"/queue/*.list; do
            [ -f "$q" ] || continue
            grep -vxF "$rel" "$q" 2>/dev/null | rp_atomic_write "$q"
            [ -s "$q" ] || rm -f "$q"
        done
        awk -F'\t' -v r="$rel" '$2 != r' "$ATTEMPTS_FILE" | rp_atomic_write "$ATTEMPTS_FILE"
        report "GAVE UP on $rel after $n failed extraction attempts - moved to old/corrupt-$(date '+%Y-%m-%d')/ so the next update downloads a fresh copy"
    else
        report "FAILED to extract $rel (attempt $n of $RP_MAX_EXTRACT_ATTEMPTS) - still queued, will retry next run"
    fi
}

# merge_variant <index> <folder> [extra merge.sh options...]
# The stage scripts are run directly. They used to be reached through
# "./start.sh --merge" and "./start.sh --sort", which meant the pipeline
# engine called the interactive dispatcher, and every variant re-printed its
# banner and re-ran the startup checks - one build looked like several
# unrelated tools starting up in turn. RP_CHILD tells them they are one stage
# of this run: no banner, no header block, and their counts come back in
# RP_RESULT_FILE as key=value rather than being read off the screen.
STAGE_RESULT="$WORK_ROOT/.stage_result.$$"
merge_variant() {   # (adds --refresh-artwork when asked for)
    local i="$1" dir="$2"; shift 2
    local refresh=""
    [ "$REFRESH_ART" -eq 1 ] && refresh="--refresh-artwork"
    mkdir -p "$WORK_ROOT" 2>/dev/null
    # shellcheck disable=SC2086
    RP_CHILD=1 RP_RESULT_FILE="$STAGE_RESULT" bash "$SCRIPT_DIR/merge.sh" \
        ${V_MFLAGS[$i]} --art "${V_ART[$i]}" --demo-art "$DEMO_ART" \
        -d "$dir" $DEBUG_FLAG $refresh --called-from-all "$@"
}

sort_folder() {
    mkdir -p "$WORK_ROOT" 2>/dev/null
    # shellcheck disable=SC2086
    RP_CHILD=1 RP_RESULT_FILE="$STAGE_RESULT" bash "$SCRIPT_DIR/sort.sh" \
        "$FS_FLAG" $DETOX_FLAG --dest "$1" --called-from-all
}

# stage_result <key> : the last stage's figure, or empty. Never parses text.
stage_result() { sed -n "s/^$1=//p" "$STAGE_RESULT" 2>/dev/null | tail -1; }

# After the packs have had their turn: ask the command you configured for
# anything still missing (off unless ARTWORK_FETCH=yes). Counts go into the
# run report; a failure here never affects the collection.
FETCH_FOUND=0
fetch_missing_artwork() {   # <index> <missing-list-file>
    local out found
    [ "$RP_ARTWORK_FETCH" = "yes" ] || return 0
    [ -s "$2" ] || return 0
    [ -f "$SCRIPT_DIR/artwork_fetch.sh" ] || return 0
    out="$REPORT_TMP.fetch"
    RP_RESULT_FILE="$out" ./artwork_fetch.sh --list "$2" --variant "${V_KEY[$1]}" --dest "${V_DEST[$1]}"
    found="$(sed -n 's/^found=//p' "$out" 2>/dev/null | tail -1)"
    case "$found" in ''|*[!0-9]*) found=0 ;; esac
    if [ "$found" -gt 0 ]; then
        FETCH_FOUND=$(( FETCH_FOUND + found ))
        report "${V_KEY[$1]}: found artwork elsewhere for $found game(s) and converted it to IFF"
    fi
    rm -f "$out"
    return 0
}

save_missing_list() {   # <index> <missing-list-file> ; prints the count
    local n=0
    if [ -s "$2" ]; then
        n="$(grep -c . "$2")"
        mkdir -p "$REPORT_DIR"
        sort -u "$2" > "$REPORT_DIR/${RUN_TS}_${V_KEY[$1]}_no_artwork.txt"
    fi
    echo "$n"
}

# ============================================================================
# 3. Full builds - every archive extracted and sorted ONCE for all of them
# ============================================================================
# The run announces five steps; this is the fifth, and it never said so. On a
# long build that left the display stuck on "[4/5] Plan" for the entire job.
rp_step 5 "$TOTAL_STEPS" "Building the collections"
FULL=()
for i in "${!V_TOK[@]}"; do [ "${V_ACT[$i]}" = full ] && FULL+=("$i"); done
# A preview shows what the NEW archives would add. A collection that does not
# exist yet has nothing to add to, so those variants are left for an ordinary
# run rather than silently building the whole thing under a preview name.
if [ "$PREVIEW_ONLY" -eq 1 ] && [ "${#FULL[@]}" -gt 0 ]; then
    for i in "${FULL[@]}"; do
        rp_warn "${V_KEY[$i]} has not been built yet - there is nothing to preview against"
        report "${V_KEY[$i]}: skipped - a preview needs an existing collection (run ./start.sh --sync first)"
    done
    FULL=()
fi

if [ "${#FULL[@]}" -gt 0 ]; then
    names=""; for i in "${FULL[@]}"; do names="$names ${V_KEY[$i]}"; done
    echo "===== Full build:$names ====="
    arch_kb="$(rp_du_kb "$RP_DOWNLOAD_ROOT")"
    [ "$arch_kb" -gt 0 ] || fail_with "$RP_EXIT_CONFIG" "no downloaded archives found yet (HD_Loaders/, JST/, WHDLoad/) - run once without --rebuild/--skip-update first"
    est_kb=$((arch_kb * RP_SPACE_FACTOR))
    rp_require_space "$RP_OUTPUT_ROOT" "$est_kb" "extracting the archives" || fail_with "$RP_EXIT_CONFIG" "not enough disk space to extract the archives"
    for i in "${FULL[@]}"; do rp_mark_building "${V_KEY[$i]}" "${V_DEST[$i]}"; done

    # Tags some of these variants must leave out (e.g. AGA,CD32 for ECS).
    # Archives WITHOUT any of them go into "common" (used by every variant);
    # archives WITH them are extracted separately, so a variant that must
    # leave them out simply doesn't receive that part. Still one extraction
    # per archive in the usual setup.
    ALL_EXCL=""
    for i in "${FULL[@]}"; do
        IFS=, read -r -a _tags <<< "${V_EXCL[$i]}"
        for t in "${_tags[@]+"${_tags[@]}"}"; do
            [ -n "$t" ] || continue
            case ",$ALL_EXCL," in *",$t,"*) ;; *) ALL_EXCL="${ALL_EXCL:+$ALL_EXCL,}$t" ;; esac
        done
    done

    COMMON="$WORK_ROOT/common"
    if [ -n "$ALL_EXCL" ]; then
        echo "--- Extracting archives without $ALL_EXCL (shared by all variants) ---"
        run_extract "$WORK_ROOT/failed_fresh.list" -u -d "$COMMON" --exclude-tags "$ALL_EXCL" $DEBUG_FLAG
    else
        echo "--- Extracting all archives ---"
        run_extract "$WORK_ROOT/failed_fresh.list" -u -d "$COMMON" $DEBUG_FLAG
    fi
    mkdir -p "$COMMON"
    echo "--- Sorting and checking filenames ---"
    sort_folder "$COMMON" || stage_failed "$?" "sorting the extracted games" "sort"
    collect_stage_logs "sort" || true
    check_layout "$COMMON"

    # One "extra" part per distinct set of left-out tags that isn't "all of
    # them" (normally just one: the AGA/CD32 releases for AGA and RTG).
    EXTRA_SET=(); EXTRA_DIR=()
    for i in "${FULL[@]}"; do
        ex="${V_EXCL[$i]}"
        [ -n "$ALL_EXCL" ] || continue
        [ "$ex" = "$ALL_EXCL" ] && continue
        seen=0; for s in "${EXTRA_SET[@]+"${EXTRA_SET[@]}"}"; do [ "$s" = "$ex" ] && seen=1; done
        [ "$seen" -eq 1 ] && continue
        n="${#EXTRA_SET[@]}"
        EXTRA_SET+=("$ex"); EXTRA_DIR+=("$WORK_ROOT/extra_$n")
        echo "--- Extracting the $ALL_EXCL archives${ex:+ (without $ex)} ---"
        if [ -n "$ex" ]; then
            run_extract "$WORK_ROOT/failed_fresh.list" -u -d "$WORK_ROOT/extra_$n" --only-tags "$ALL_EXCL" --exclude-tags "$ex" $DEBUG_FLAG
        else
            run_extract "$WORK_ROOT/failed_fresh.list" -u -d "$WORK_ROOT/extra_$n" --only-tags "$ALL_EXCL" $DEBUG_FLAG
        fi
        mkdir -p "$WORK_ROOT/extra_$n"
        sort_folder "$WORK_ROOT/extra_$n" || stage_failed "$?" "sorting the releases only some variants get (extra_$n)" "sort"
        collect_stage_logs "sort" || true
        check_layout "$WORK_ROOT/extra_$n"
    done

    remaining="${#FULL[@]}"
    for i in "${FULL[@]}"; do
        remaining=$((remaining - 1))
        dest="${V_DEST[$i]}"; key="${V_KEY[$i]}"
        extra=""
        for n in ${EXTRA_SET[@]+"${!EXTRA_SET[@]}"}; do [ "${EXTRA_SET[$n]}" = "${V_EXCL[$i]}" ] && extra="${EXTRA_DIR[$n]}"; done
        echo
        # When this collection's own work starts. ${vstart:-$SECONDS} was the
        # fallback for a variable nothing ever set, so every "Time" in the
        # summary came out as zero.
        vstart=$SECONDS
        echo "===== $key: installing and adding artwork ====="
        # The last variant MOVES the shared tree rather than copying it, so only
        # the extras need room. Work out which measurement is wanted first and
        # take it once: this is a full walk of the staged collection.
        if [ "$remaining" -eq 0 ]; then
            need_kb="$(rp_du_kb ${extra:+"$extra"})"
        else
            need_kb="$(rp_du_kb "$COMMON" ${extra:+"$extra"})"
        fi
        free_kb="$(rp_free_kb "$RP_OUTPUT_ROOT")"
        # The new collection is now built BESIDE the finished one and only
        # swapped in when it is complete, so the space for both is needed at
        # once. That is the price of never leaving the drive without a usable
        # collection if the power goes out mid-build.
        if [ -n "$free_kb" ] && [ $((need_kb + RP_MIN_FREE_MB * 1024)) -gt "$free_kb" ]; then
            fail_with "$RP_EXIT_CONFIG" "not enough disk space to build $key beside the collection you already have (needs about $((need_kb / 1024)) MB free; the previous collection is kept until the new one is finished)"
        fi
        staged="$(rp_staged_path "$dest")"
        rm -rf -- "$staged"
        mkdir -p "$(dirname "$dest")"
        if [ "$remaining" -eq 0 ]; then
            mv "$COMMON" "$staged" || fail "could not move the build into $staged"
        else
            cp -a "$COMMON" "$staged" || fail "could not copy the build into $staged"
        fi
        [ -n "$extra" ] && { cp -a "$extra/." "$staged/" || fail "could not copy the $ALL_EXCL releases into $staged"; }
        miss="$REPORT_TMP.missing"; : > "$miss"
        merge_variant "$i" "$staged" --report-missing "$miss" || stage_failed "$?" "adding artwork to $key" "$key"
        collect_stage_logs "$key" || true
        # Everything is in place and merged: now, and only now, the previous
        # collection is replaced - two renames in one folder, so the moment
        # where neither is complete is as short as the filesystem can make it.
        rp_swap_collection "$dest" || fail "could not put the new $key in place - your previous collection was kept"
        variant_row "$key" "${vstart:-$SECONDS}" "built"
        rp_mark_complete "$key" "$dest"
        rp_queue_clear "$key"
        rp_gapfill_done "$key"          # a full build merged everything
        mark_success "$key"
        fetch_missing_artwork "$i" "$miss"
        games="$(rp_count_games "$dest")"; nomiss="$(save_missing_list "$i" "$miss")"
        line="$key: full build - $games games${V_EXCL[$i]:+ (without ${V_EXCL[$i]} releases)}, $nomiss without artwork"
        [ "$nomiss" -gt 0 ] && line="$line (list: reports/${RUN_TS}_${key}_no_artwork.txt)"
        report "$line"
    done
    rm -rf -- "$WORK_ROOT/common" "$WORK_ROOT"/extra_*

    if [ -s "$WORK_ROOT/failed_fresh.list" ]; then
        ( cd "$RP_DOWNLOAD_ROOT" && find -H HD_Loaders JST WHDLoad -type f \( -iname '*.lha' -o -iname '*.lzx' -o -iname '*.zip' \) 2>/dev/null \
            | sed 's|^\./||' ) > "$WORK_ROOT/all_archives.list"
        match_failures "$WORK_ROOT/failed_fresh.list" "$WORK_ROOT/all_archives.list" | sort -u > "$WORK_ROOT/fresh_failed.list"
        while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            for i in "${FULL[@]}"; do
                q="$(rp_queue_file "${V_KEY[$i]}")"
                grep -qxF "$rel" "$q" 2>/dev/null || { cat "$q" 2>/dev/null; printf '%s\n' "$rel"; } | rp_atomic_write "$q"
            done
            handle_failed "$rel"
        done < "$WORK_ROOT/fresh_failed.list"
    fi
fi

# ============================================================================
# 4. Updates - queued archives staged, extracted and sorted once per group
# ============================================================================
INC=()
for i in "${!V_TOK[@]}"; do [ "${V_ACT[$i]}" = update ] && INC+=("$i"); done

G_SIG=(); G_MEMBERS=()
for i in "${INC[@]+"${INC[@]}"}"; do
    key="${V_KEY[$i]}"
    cp "$(rp_queue_file "$key")" "$STAGE_ROOT/processed_$key.list"
    : > "$STAGE_ROOT/applicable_$key.list"
    while IFS= read -r p; do
        [ -n "$p" ] && [ -f "$RP_DOWNLOAD_ROOT/$p" ] || continue        # superseded meanwhile
        [ -n "${V_EXCL[$i]}" ] && rp_archive_has_tag "$p" "${V_EXCL[$i]}" && continue
        printf '%s\n' "$p" >> "$STAGE_ROOT/applicable_$key.list"
    done < "$STAGE_ROOT/processed_$key.list"
    sig="$(sort "$STAGE_ROOT/applicable_$key.list" | cksum | tr ' ' _)"
    found=""
    for g in ${G_SIG[@]+"${!G_SIG[@]}"}; do [ "${G_SIG[$g]}" = "$sig" ] && found="$g"; done
    if [ -n "$found" ]; then
        G_MEMBERS[$found]="${G_MEMBERS[$found]} $i"
    else
        G_SIG+=("$sig"); G_MEMBERS+=("$i")
    fi
done

for g in ${G_SIG[@]+"${!G_SIG[@]}"}; do
    set -- ${G_MEMBERS[$g]}
    lead="$1"; members="$*"; nmembers=$#
    list="$STAGE_ROOT/applicable_${V_KEY[$lead]}.list"
    names=""; for i in $members; do names="$names ${V_KEY[$i]}"; done
    echo
    echo "===== Update:$names ====="

    if [ ! -s "$list" ]; then
        for i in $members; do
            rp_queue_remove_processed "${V_KEY[$i]}" "$STAGE_ROOT/processed_${V_KEY[$i]}.list"
            report "${V_KEY[$i]}: nothing to add (queued archives were superseded${V_EXCL[$i]:+ or ${V_EXCL[$i]} releases})"
        done
        continue
    fi

    src="$STAGE_ROOT/src_$g"; batch="$WORK_ROOT/batch_$g"
    narch=0
    while IFS= read -r p; do
        mkdir -p "$src/$(dirname "$p")"
        ln "$RP_DOWNLOAD_ROOT/$p" "$src/$p" 2>/dev/null || cp -p "$RP_DOWNLOAD_ROOT/$p" "$src/$p" || fail "could not stage $p"
        narch=$((narch + 1))
    done < "$list"

    est_kb=$(( $(rp_du_kb "$src") * RP_SPACE_FACTOR ))
    rp_require_space "$RP_OUTPUT_ROOT" $((est_kb * (1 + 2 * nmembers))) "processing $narch new archive(s)" \
        || fail_with "$RP_EXIT_CONFIG" "not enough disk space to process the new downloads"

    echo "--- Extracting $narch new archive(s) ---"
    : > "$STAGE_ROOT/failed_$g.list"
    (cd "$src" && RP_EXTRACT_FAILED_LIST="$STAGE_ROOT/failed_$g.list" RP_CHILD=1 \
        bash "$SCRIPT_DIR/extract.sh" --called-from-all -u -d "$batch" $DEBUG_FLAG)
    xst=$?
    rescue_extract_log "$src"
    case "$xst" in
        0|5) ;;
        130) fail_with "$RP_EXIT_INTERRUPTED" "interrupted" ;;
        *)   fail "the extractor stopped unexpectedly (exit $xst)" ;;
    esac
    failed_rels="$STAGE_ROOT/failed_rels_$g.list"
    match_failures "$STAGE_ROOT/failed_$g.list" "$list" | sort -u > "$failed_rels"
    if [ -s "$failed_rels" ]; then
        grep -vxF -f "$failed_rels" "$list" > "$STAGE_ROOT/ok_$g.list" || true
        for i in $members; do       # failed archives stay queued for next time
            grep -vxF -f "$failed_rels" "$STAGE_ROOT/processed_${V_KEY[$i]}.list" > "$STAGE_ROOT/processed_${V_KEY[$i]}.tmp" || true
            mv "$STAGE_ROOT/processed_${V_KEY[$i]}.tmp" "$STAGE_ROOT/processed_${V_KEY[$i]}.list"
        done
        while IFS= read -r rel; do handle_failed "$rel"; done < "$failed_rels"
    else
        cp "$list" "$STAGE_ROOT/ok_$g.list"
    fi
    clear_extract_failures "$STAGE_ROOT/ok_$g.list"
    nfailed="$(grep -c . "$failed_rels" 2>/dev/null)"; nfailed="${nfailed:-0}"
    mkdir -p "$batch"
    echo "--- Sorting and checking filenames ---"
    sort_folder "$batch" || stage_failed "$?" "sorting the new archives" "sort (new batch)"
    collect_stage_logs "sort (new batch)" || true
    mkdir -p "$batch"          # sort.sh removes empty folders
    check_layout "$batch"
    bgames="$(rp_count_games "$batch")"
    if [ ! -s "$STAGE_ROOT/ok_$g.list" ]; then
        for i in $members; do
            rp_queue_remove_processed "${V_KEY[$i]}" "$STAGE_ROOT/processed_${V_KEY[$i]}.list"
            report "${V_KEY[$i]}: nothing installed - all $narch new archive(s) failed to extract (they will be retried)"
        done
        rm -rf -- "$src" "$batch"
        continue
    fi

    remaining="$nmembers"
    for i in $members; do
        remaining=$((remaining - 1))
        key="${V_KEY[$i]}"; dest="${V_DEST[$i]}"; vcopy="$WORK_ROOT/v_$key"
        echo
        vstart=$SECONDS
        echo "===== $key: adding artwork and installing the new batch ====="
        if [ "$remaining" -eq 0 ]; then
            mv "$batch" "$vcopy" || fail "could not prepare the batch for $key"
        else
            cp -a "$batch" "$vcopy" || fail "could not prepare the batch for $key"
        fi
        miss="$REPORT_TMP.missing"; : > "$miss"
        merge_variant "$i" "$vcopy" --report-missing "$miss" || stage_failed "$?" "adding artwork to the new batch for $key" "$key (new batch)"
        collect_stage_logs "$key (new batch)" || true
        if [ "$PREVIEW_ONLY" -eq 1 ]; then
            rp_info "  preview only - $key itself was not changed"
        else
            rp_replace_and_copy "$vcopy" "$dest" || fail "copying the new batch into $dest failed"
        fi

        # Keep a dated copy of just this batch (e.g. for copying to the Amiga).
        rp_migrate_new_dir "${V_NEW[$i]}"
        mkdir -p "${V_NEW[$i]}"
        mv "$vcopy" "${V_NEW[$i]}/$RUN_TS" || fail "could not save the batch to ${V_NEW[$i]}"
        if [ "$PREVIEW_ONLY" -eq 1 ]; then
            printf '%s\n' \
                "PREVIEW ONLY - this is NOT a collection." \
                "" \
                "These are the games from the archives downloaded on $RUN_TS," \
                "with artwork added, so you can look at them before they go in." \
                "$key itself was not changed, and these archives are still" \
                "queued: the next ordinary run installs them properly." \
                > "${V_NEW[$i]}/$RUN_TS/PREVIEW_ONLY.txt"
        fi
        rp_prune_batches "${V_NEW[$i]}" "$RP_KEEP_NEW_BATCHES"

        # Fill in artwork for anything in the collection still missing it.
        # (only when an artwork pack changed, or every GAPFILL_DAYS days)
        gapnote=""
        if [ "$PREVIEW_ONLY" -eq 0 ] && { [ "$REFRESH_ART" -eq 1 ] || rp_gapfill_due "$key"; }; then
            gapmode="--only-missing"
            [ "$REFRESH_ART" -eq 1 ] && gapmode=""      # every game, not just the gaps
            echo "  refreshing artwork for $key..."
            # shellcheck disable=SC2086
            if merge_variant "$i" "$dest" $gapmode; then collect_stage_logs "$key (gap-fill)" || true; rp_gapfill_done "$key"
            else gapnote=" (artwork gap-fill reported errors - see retroerror.log)"; fi
        fi
        if [ "$PREVIEW_ONLY" -eq 0 ]; then
            mark_success "$key"
            rp_queue_remove_processed "$key" "$STAGE_ROOT/processed_$key.list"
        fi
        fetch_missing_artwork "$i" "$miss"
        nomiss="$(save_missing_list "$i" "$miss")"
        if [ "$PREVIEW_ONLY" -eq 1 ]; then
            line="$key: PREVIEW - $bgames game(s) from $narch archive(s) put in ${V_NEW[$i]##*/}/$RUN_TS; $key itself was not changed and the archives stay queued"
        else
        line="$key: $bgames game(s) added/updated from $narch archive(s) - batch saved in ${V_NEW[$i]##*/}/$RUN_TS, $nomiss without artwork"
        [ "$nomiss" -gt 0 ] && line="$line (list: reports/${RUN_TS}_${key}_no_artwork.txt)"
        [ "$nfailed" -gt 0 ] && line="$line; $nfailed archive(s) failed and stay queued"
        fi
        if [ "$PREVIEW_ONLY" -eq 1 ]; then
            variant_row "${V_KEY[$i]}" "${vstart:-$SECONDS}" "preview"
        else
            variant_row "${V_KEY[$i]}" "${vstart:-$SECONDS}" "updated"
        fi
        report "$line$gapnote"
    done
    rm -rf -- "$src"
done

# ============================================================================
# 5. Up-to-date variants with --force: artwork gap-fill only
# ============================================================================
for i in "${!V_TOK[@]}"; do
    [ "${V_ACT[$i]}" = gapfill ] || continue
    echo
    vstart=$SECONDS
    echo "===== ${V_KEY[$i]}: artwork gap-fill ====="
    if [ "$REFRESH_ART" -eq 1 ]; then
        echo "  refreshing artwork for ${V_KEY[$i]} (every game)..."
        gapmode=""
    else
        echo "  filling in missing artwork for ${V_KEY[$i]}..."
        gapmode="--only-missing"
    fi
    miss="$REPORT_TMP.missing"; : > "$miss"
    # shellcheck disable=SC2086
    merge_variant "$i" "${V_DEST[$i]}" $gapmode --report-missing "$miss" || stage_failed "$?" "the artwork gap-fill for ${V_KEY[$i]}" "${V_KEY[$i]} (gap-fill)"
    collect_stage_logs "${V_KEY[$i]} (gap-fill)" || true
    rp_gapfill_done "${V_KEY[$i]}"
    mark_success "${V_KEY[$i]}"
    fetch_missing_artwork "$i" "$miss"
    variant_row "${V_KEY[$i]}" "${vstart:-$SECONDS}" "artwork refreshed"
    report "${V_KEY[$i]}: up to date - artwork gap-fill done; $(save_missing_list "$i" "$miss") game(s) still without artwork"
done

# ----- Saved backups -----
# State backups and previous artwork versions build up over time. Offer to
# clear them at the end of a hands-on run. Unattended runs never ask, and
# the question times out after 3 minutes answering "no", so a run started by
# hand and left alone can't hang.
offer_backup_cleanup() {
    local kb mb reply
    [ "$DRY_RUN" -eq 0 ] && [ "$CRON" -eq 0 ] || return 0
    rp_is_interactive || return 0
    kb="$(rp_du_kb "$RP_BACKUP_DIR" "$RP_STATE_DIR/artwork/backups")"
    [ "${kb:-0}" -gt 0 ] || return 0
    mb=$(( kb / 1024 ))
    echo
    echo "Saved backups are using ${mb} MB:"
    [ -d "$RP_BACKUP_DIR" ] && echo "  $(rp_count_matching "$RP_BACKUP_DIR/state-*.tgz") state backup(s)   ${RP_BACKUP_DIR##*/}/"
    [ -d "$RP_STATE_DIR/artwork/backups" ] && echo "  previous artwork versions   .retroplay/artwork/backups/"
    printf 'Delete them? (rollback of artwork won'"'"'t be possible afterwards) [y/N] '
    reply=""
    read -r -t 180 reply || { echo; echo "No answer in 3 minutes - keeping them."; return 0; }
    case "$reply" in
        [Yy]*)
            rm -rf "$RP_BACKUP_DIR" "$RP_STATE_DIR/artwork/backups"
            echo "Deleted. (New backups are made on the next run.)" ;;
        *) echo "Kept." ;;
    esac
    return 0
}
offer_backup_cleanup

# All possible work is done; report extraction failures with exit 5.
[ "$INTEGRITY_ISSUES" -eq 1 ] && exit "$RP_EXIT_INTEGRITY"
exit 0
