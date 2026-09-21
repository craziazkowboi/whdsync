#!/usr/bin/env bash
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

usage() {
    cat << 'USAGE'
Usage: all.sh [options]

Builds or updates every variant listed in VARIANTS (retroplay.conf; default
"aga ecs rtg") - or just the ones you name - extracting archives only once.

Choosing variants (default: VARIANTS from retroplay.conf):
  --aga --ecs --rtg --aga-laced --ecs-laced   Pick variants (repeatable)
  --set NAME            Use the iGame_NAME artwork set as a variant
  --variants "a b c"    Give the whole list at once
  --dest PATH           Custom output folder (only with a single variant)

What to do:
  --rebuild             Rebuild from the archives already downloaded, without
                        checking for updates (same as --clean --skip-update)
  --clean               Check for updates, then rebuild from scratch
  --skip-update         Don't download; process whatever is already queued
  --force               Also run the artwork gap-fill on up-to-date variants
  --dry-run             Show what would happen, change nothing
  --cron                Unattended mode for cron: sets a full PATH, rotates
                        and writes to all_cron.log

Overrides for retroplay.conf settings:
  --art ORDER  --demo-art ORDER  --ffs | --pfs  --no-detox | --detox  --debug

Exit codes: 0 = work done, 2 = nothing to do, 1 = failure.
USAGE
}

VARIANT_ARGS=""; DEST_OVERRIDE=""
CLEAN=0; SKIP_UPDATE=0; FORCE=0; DRY_RUN=0; CRON=0; DEBUG=0
ART_OVERRIDE=""; DEMO_ART_OVERRIDE=""; FS_OVERRIDE=""; DETOX_OVERRIDE=""

while [ $# -gt 0 ]; do
    opt="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$opt" in
        --aga|--ecs|--rtg|--aga-laced|--ecs-laced) VARIANT_ARGS="$VARIANT_ARGS ${opt#--}"; shift ;;
        --set)       [ $# -ge 2 ] || { echo "--set needs a name" >&2; exit 1; }
                     VARIANT_ARGS="$VARIANT_ARGS $2"; shift 2 ;;
        --variants)  [ $# -ge 2 ] || { echo "--variants needs a list" >&2; exit 1; }
                     VARIANT_ARGS="$VARIANT_ARGS $2"; shift 2 ;;
        --variant)   VARIANT_ARGS="$VARIANT_ARGS ${2:-}"; shift 2 ;;
        -d|--dest)   DEST_OVERRIDE="${2:-}"; shift 2 ;;
        --clean)     CLEAN=1; shift ;;
        --rebuild)   CLEAN=1; SKIP_UPDATE=1; shift ;;
        --skip-update) SKIP_UPDATE=1; shift ;;
        --force)     FORCE=1; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --cron)      CRON=1; shift ;;
        --art)       ART_OVERRIDE="${2:-}"; shift 2 ;;
        --demo-art)  DEMO_ART_OVERRIDE="${2:-}"; shift 2 ;;
        --ffs)       FS_OVERRIDE=ffs; shift ;;
        --pfs)       FS_OVERRIDE=pfs; shift ;;
        --no-detox)  DETOX_OVERRIDE=no; shift ;;
        --detox)     DETOX_OVERRIDE=yes; shift ;;
        --debug)     DEBUG=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
done

# ----- Cron mode -----
# (cron's bare PATH is already taken care of by lib.sh, for every script:
# it adds back the PATH remembered from your last interactive run.) cron
# can't rotate its own >> log, so --cron does that and writes the log itself.
if [ "$CRON" -eq 1 ]; then
    CRON_LOG="$SCRIPT_DIR/all_cron.log"
    rp_rotate_log "$CRON_LOG" "$RP_LOG_MAX_MB" "$RP_LOG_KEEP"
    exec >> "$CRON_LOG" 2>&1 < /dev/null
    echo
    echo "==================== all.sh --cron: $(date '+%Y-%m-%d %H:%M:%S') ===================="
fi

rp_print_config_warnings

# Every start.sh step run from here skips its interactive "view error log?"
# prompt and appends to one shared retroerror.log for the whole run.
export RETROPLAY_ALL_SH=1

if [ "$DRY_RUN" -eq 0 ]; then
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

fi

# ============================================================================
# Settings for this run
# ============================================================================
FS_FLAG="--${FS_OVERRIDE:-$RP_FILESYSTEM}"
USE_DETOX="${DETOX_OVERRIDE:-$RP_USE_DETOX}"
DETOX_FLAG=""; [ "$USE_DETOX" = "yes" ] || DETOX_FLAG="--no-detox"
DEBUG_FLAG=""; [ "$DEBUG" -eq 1 ] && DEBUG_FLAG="--debug"
DEMO_ART="${DEMO_ART_OVERRIDE:-$RP_DEMO_ART_ORDER}"
RUN_TS="$(rp_timestamp)"
WORK_ROOT="$RP_OUTPUT_ROOT/.retroplay_work"     # same drive as the output, so moves are instant
STAGE_ROOT="$RP_STATE_DIR/stage"                # same drive as the archives, so staging can hardlink
REPORT_DIR="$SCRIPT_DIR/reports"
REPORT_TMP="$(mktemp "${TMPDIR:-/tmp}/retroplay_report.XXXXXX")"
FAIL_REASON=""

report() { printf '%s\n' "$*" >> "$REPORT_TMP"; }
fail()   { FAIL_REASON="$*"; echo; echo "ERROR: $*" >&2; exit 1; }

# ----- Resolve the variants -----
V_TOK=(); V_DEST=(); V_KEY=(); V_EXCL=(); V_ART=(); V_NEW=(); V_MFLAGS=(); V_ACT=(); V_WHY=()
for tok in ${VARIANT_ARGS:-$RP_VARIANTS}; do
    tok="$(printf '%s' "$tok" | tr '[:upper:]' '[:lower:]')"
    dup=0
    for t in "${V_TOK[@]+"${V_TOK[@]}"}"; do [ "$t" = "$tok" ] && dup=1; done
    [ "$dup" -eq 1 ] && continue
    V_TOK+=("$tok")
done
[ "${#V_TOK[@]}" -gt 0 ] || { echo "ERROR: no variants to build (check VARIANTS in retroplay.conf)." >&2; exit 1; }
if [ -n "$DEST_OVERRIDE" ] && [ "${#V_TOK[@]}" -gt 1 ]; then
    echo "ERROR: --dest can only be used when building a single variant." >&2; exit 1
fi

for i in "${!V_TOK[@]}"; do
    tok="${V_TOK[$i]}"
    if [ -n "$DEST_OVERRIDE" ]; then
        case "$DEST_OVERRIDE" in /*) d="$DEST_OVERRIDE" ;; *) d="$SCRIPT_DIR/$DEST_OVERRIDE" ;; esac
    elif [ "$tok" = "default" ]; then
        d="$RP_OUTPUT_ROOT/retro"
    else
        d="$RP_OUTPUT_ROOT/retro_$(rp_variant_suffix "$tok")"
    fi
    d="${d%/}"
    V_DEST[$i]="$d"
    V_KEY[$i]="${d##*/}"
    V_EXCL[$i]="$(rp_exclude_tags_for "$tok")"
    V_ART[$i]="${ART_OVERRIDE:-$(rp_art_order_for "$tok")}"
    V_NEW[$i]="$RP_OUTPUT_ROOT/new_${V_KEY[$i]#retro_}"
    V_MFLAGS[$i]="$(rp_variant_merge_args "$tok" | tr '\n' ' ')"
done

# Leftovers from an interrupted run are only temporary copies - clear them.
if [ "$DRY_RUN" -eq 0 ]; then
    rm -rf -- "$WORK_ROOT" "$STAGE_ROOT"
    rm -f "$SCRIPT_DIR/retroerror.log"
fi

finish() {
    local st=$? errs=0 result body
    rm -f "$REPORT_TMP.missing" 2>/dev/null
    if [ "$DRY_RUN" -eq 1 ]; then rm -f "$REPORT_TMP"; return; fi
    rm -rf -- "$WORK_ROOT" "$STAGE_ROOT"
    [ -s "$SCRIPT_DIR/retroerror.log" ] && errs="$(grep -c . "$SCRIPT_DIR/retroerror.log")"
    case "$st" in
        0) result="Finished successfully" ;;
        2) result="Nothing to do - everything is up to date" ;;
        *) result="FAILED${FAIL_REASON:+ - $FAIL_REASON}" ;;
    esac
    if [ "$st" -ne 2 ] || [ -s "$REPORT_TMP" ]; then
        mkdir -p "$REPORT_DIR"
        {
            echo "Amiga Retroplay run report - $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Result:   $result"
            printf 'Duration: %d:%02d:%02d\n' $((SECONDS / 3600)) $(((SECONDS % 3600) / 60)) $((SECONDS % 60))
            echo
            [ -s "$REPORT_TMP" ] && cat "$REPORT_TMP" && echo
            if [ "$errs" -gt 0 ]; then
                echo "Errors/warnings logged: $errs line(s) - see retroerror.log"
            else
                echo "No errors logged."
            fi
            [ -n "$(rp_free_kb "$RP_OUTPUT_ROOT")" ] && \
                echo "Free space left: $(( $(rp_free_kb "$RP_OUTPUT_ROOT") / 1024 )) MB"
        } > "$REPORT_DIR/$RUN_TS.txt"
        echo
        echo "======================== Summary ========================"
        cat "$REPORT_DIR/$RUN_TS.txt"
        echo "(saved as reports/$RUN_TS.txt)"
        # keep the newest 60 reports
        ls -1 "$REPORT_DIR"/*.txt 2>/dev/null | sort | awk -v n="$(ls -1 "$REPORT_DIR"/*.txt 2>/dev/null | grep -c .)" 'NR <= n - 60' | \
            while IFS= read -r old; do rm -f "$old" "${old%.txt}"_*; done
    fi
    body="$(cat "$REPORT_DIR/$RUN_TS.txt" 2>/dev/null)"
    if [ "$st" -ne 0 ] && [ "$st" -ne 2 ]; then
        rp_notify "Amiga Retroplay: run FAILED" "${body:-$result}"
    elif [ "$st" -eq 0 ] && [ "$RP_NOTIFY_ON_SUCCESS" = "yes" ]; then
        rp_notify "Amiga Retroplay: run finished" "$body"
    fi
    rm -f "$REPORT_TMP"
}
trap finish EXIT
trap 'fail "interrupted"' INT TERM

# ============================================================================
# 1. Check for updates
# ============================================================================
# Folders from older versions of these scripts get markers first, so that
# anything downloaded now is queued for them.
if [ "$DRY_RUN" -eq 0 ]; then
    for i in "${!V_TOK[@]}"; do rp_adopt_legacy "${V_KEY[$i]}" "${V_DEST[$i]}"; done
fi

if [ "$SKIP_UPDATE" -eq 0 ]; then
    echo "===== Checking for updates ====="
    if [ "$DRY_RUN" -eq 1 ]; then
        ./update.sh --dry-run
    else
        ./update.sh; ust=$?
        case "$ust" in
            0|2) ;;
            3) fail "could not update from the Retroplay server (network or server problem)" ;;
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
    elif [ "$q" -gt 0 ]; then
        V_ACT[$i]=update; V_WHY[$i]="$q new archive(s) queued"
    elif [ "$FORCE" -eq 1 ]; then
        V_ACT[$i]=gapfill; V_WHY[$i]="up to date - artwork gap-fill only"
    else
        V_ACT[$i]=none; V_WHY[$i]="up to date"
    fi
done

echo "===== Plan ====="
for i in "${!V_TOK[@]}"; do
    printf '  %-16s %-8s %s%s\n' "${V_KEY[$i]}" "${V_ACT[$i]}" "${V_WHY[$i]}" \
        "${V_EXCL[$i]:+  (leaving out: ${V_EXCL[$i]})}"
done
echo

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
            [ -f "$SCRIPT_DIR/$p" ] || note="  (superseded - will be skipped)"
            [ -n "${V_EXCL[$i]}" ] && rp_archive_has_tag "$p" "${V_EXCL[$i]}" && note="  (left out: ${V_EXCL[$i]})"
            echo "    $p$note"
        done < "$(rp_queue_file "${V_KEY[$i]}")"
        [ "$n" -gt 10 ] && echo "    ...and $((n - 10)) more"
    done
    for i in "${!V_TOK[@]}"; do
        if [ "${V_ACT[$i]}" = full ]; then
            akb="$(rp_du_kb HD_Loaders JST WHDLoad)"
            echo "A full build needs roughly $(( akb * RP_SPACE_FACTOR * 2 / 1024 )) MB free; $(( $(rp_free_kb "$RP_OUTPUT_ROOT") / 1024 )) MB available."
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
mkdir -p "$WORK_ROOT" "$STAGE_ROOT"

# extract.sh writes extract_errors.log into the folder it runs from; when
# that's a temporary staging folder, move the log out before it's deleted.
rescue_extract_log() {
    if [ -s "$1/extract_errors.log" ]; then
        cat "$1/extract_errors.log" >> "$SCRIPT_DIR/extract_errors.log"
    fi
}

# merge_variant <index> <folder> [extra merge.sh options...]
merge_variant() {
    local i="$1" dir="$2"; shift 2
    # shellcheck disable=SC2086
    ./start.sh --merge ${V_MFLAGS[$i]} --art "${V_ART[$i]}" --demo-art "$DEMO_ART" \
        --dest "$dir" $DETOX_FLAG $DEBUG_FLAG "$@"
}

sort_folder() { ./start.sh --sort $FS_FLAG $DETOX_FLAG --dest "$1"; }

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
FULL=()
for i in "${!V_TOK[@]}"; do [ "${V_ACT[$i]}" = full ] && FULL+=("$i"); done

if [ "${#FULL[@]}" -gt 0 ]; then
    names=""; for i in "${FULL[@]}"; do names="$names ${V_KEY[$i]}"; done
    echo "===== Full build:$names ====="
    arch_kb="$(rp_du_kb HD_Loaders JST WHDLoad)"
    [ "$arch_kb" -gt 0 ] || fail "no downloaded archives found yet (HD_Loaders/, JST/, WHDLoad/) - run once without --rebuild/--skip-update first"
    est_kb=$((arch_kb * RP_SPACE_FACTOR))
    rp_require_space "$RP_OUTPUT_ROOT" "$est_kb" "extracting the archives" || fail "not enough disk space to extract the archives"
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
        bash ./extract.sh -u -d "$COMMON" --exclude-tags "$ALL_EXCL" $DEBUG_FLAG || fail "extraction failed"
    else
        echo "--- Extracting all archives ---"
        bash ./extract.sh -u -d "$COMMON" $DEBUG_FLAG || fail "extraction failed"
    fi
    mkdir -p "$COMMON"
    echo "--- Sorting and checking filenames ---"
    sort_folder "$COMMON" || fail "sorting failed"

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
            bash ./extract.sh -u -d "$WORK_ROOT/extra_$n" --only-tags "$ALL_EXCL" --exclude-tags "$ex" $DEBUG_FLAG || fail "extraction failed"
        else
            bash ./extract.sh -u -d "$WORK_ROOT/extra_$n" --only-tags "$ALL_EXCL" $DEBUG_FLAG || fail "extraction failed"
        fi
        mkdir -p "$WORK_ROOT/extra_$n"
        sort_folder "$WORK_ROOT/extra_$n" || fail "sorting failed"
    done

    remaining="${#FULL[@]}"
    for i in "${FULL[@]}"; do
        remaining=$((remaining - 1))
        dest="${V_DEST[$i]}"; key="${V_KEY[$i]}"
        extra=""
        for n in ${EXTRA_SET[@]+"${!EXTRA_SET[@]}"}; do [ "${EXTRA_SET[$n]}" = "${V_EXCL[$i]}" ] && extra="${EXTRA_DIR[$n]}"; done
        echo
        echo "===== $key: installing and adding artwork ====="
        need_kb="$(rp_du_kb "$COMMON" ${extra:+"$extra"})"
        [ "$remaining" -eq 0 ] && need_kb="$(rp_du_kb ${extra:+"$extra"})"   # last one moves instead of copying
        free_kb="$(rp_free_kb "$RP_OUTPUT_ROOT")"; old_kb="$(rp_du_kb "$dest")"
        if [ -n "$free_kb" ] && [ $((need_kb + RP_MIN_FREE_MB * 1024)) -gt $((free_kb + old_kb)) ]; then
            fail "not enough disk space to install $key (needs about $((need_kb / 1024)) MB)"
        fi
        rm -rf -- "$dest"
        mkdir -p "$(dirname "$dest")"
        if [ "$remaining" -eq 0 ]; then
            mv "$COMMON" "$dest" || fail "could not move the build into $dest"
        else
            cp -a "$COMMON" "$dest" || fail "could not copy the build into $dest"
        fi
        [ -n "$extra" ] && { cp -a "$extra/." "$dest/" || fail "could not copy the $ALL_EXCL releases into $dest"; }
        miss="$REPORT_TMP.missing"; : > "$miss"
        merge_variant "$i" "$dest" --report-missing "$miss" || fail "adding artwork to $key failed"
        rp_mark_complete "$key" "$dest"
        rp_queue_clear "$key"
        games="$(rp_count_games "$dest")"; nomiss="$(save_missing_list "$i" "$miss")"
        line="$key: full build - $games games${V_EXCL[$i]:+ (without ${V_EXCL[$i]} releases)}, $nomiss without artwork"
        [ "$nomiss" -gt 0 ] && line="$line (list: reports/${RUN_TS}_${key}_no_artwork.txt)"
        report "$line"
    done
    rm -rf -- "$WORK_ROOT/common" "$WORK_ROOT"/extra_*
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
        [ -n "$p" ] && [ -f "$SCRIPT_DIR/$p" ] || continue             # superseded meanwhile
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
        ln "$SCRIPT_DIR/$p" "$src/$p" 2>/dev/null || cp -p "$SCRIPT_DIR/$p" "$src/$p" || fail "could not stage $p"
        narch=$((narch + 1))
    done < "$list"

    est_kb=$(( $(rp_du_kb "$src") * RP_SPACE_FACTOR ))
    rp_require_space "$RP_OUTPUT_ROOT" $((est_kb * (1 + 2 * nmembers))) "processing $narch new archive(s)" \
        || fail "not enough disk space to process the new downloads"

    echo "--- Extracting $narch new archive(s) ---"
    (cd "$src" && bash "$SCRIPT_DIR/extract.sh" -u -d "$batch" $DEBUG_FLAG)
    xst=$?
    rescue_extract_log "$src"
    [ "$xst" -eq 0 ] || fail "extracting the new archives failed"
    mkdir -p "$batch"
    echo "--- Sorting and checking filenames ---"
    sort_folder "$batch" || fail "sorting the new archives failed"
    bgames="$(rp_count_games "$batch")"

    remaining="$nmembers"
    for i in $members; do
        remaining=$((remaining - 1))
        key="${V_KEY[$i]}"; dest="${V_DEST[$i]}"; vcopy="$WORK_ROOT/v_$key"
        echo
        echo "===== $key: adding artwork and installing the new batch ====="
        if [ "$remaining" -eq 0 ]; then
            mv "$batch" "$vcopy" || fail "could not prepare the batch for $key"
        else
            cp -a "$batch" "$vcopy" || fail "could not prepare the batch for $key"
        fi
        miss="$REPORT_TMP.missing"; : > "$miss"
        merge_variant "$i" "$vcopy" --report-missing "$miss" || fail "adding artwork to the new batch for $key failed"
        rp_replace_and_copy "$vcopy" "$dest" || fail "copying the new batch into $dest failed"

        # Keep a dated copy of just this batch (e.g. for copying to the Amiga).
        rp_migrate_new_dir "${V_NEW[$i]}"
        mkdir -p "${V_NEW[$i]}"
        mv "$vcopy" "${V_NEW[$i]}/$RUN_TS" || fail "could not save the batch to ${V_NEW[$i]}"
        rp_prune_batches "${V_NEW[$i]}" "$RP_KEEP_NEW_BATCHES"

        # Fill in artwork for anything in the collection still missing it.
        gapnote=""
        merge_variant "$i" "$dest" --only-missing || gapnote=" (artwork gap-fill reported errors - see retroerror.log)"

        rp_queue_remove_processed "$key" "$STAGE_ROOT/processed_$key.list"
        nomiss="$(save_missing_list "$i" "$miss")"
        line="$key: $bgames game(s) added/updated from $narch archive(s) - batch saved in ${V_NEW[$i]##*/}/$RUN_TS, $nomiss without artwork"
        [ "$nomiss" -gt 0 ] && line="$line (list: reports/${RUN_TS}_${key}_no_artwork.txt)"
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
    echo "===== ${V_KEY[$i]}: artwork gap-fill ====="
    merge_variant "$i" "${V_DEST[$i]}" --only-missing || fail "artwork gap-fill for ${V_KEY[$i]} failed"
    report "${V_KEY[$i]}: up to date - artwork gap-fill done"
done

exit 0
