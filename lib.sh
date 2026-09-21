# shellcheck shell=bash
# Amiga Retroplay - shared helper library
#
# Sourced (not executed) by the other scripts, after they have set
# SCRIPT_DIR. Everything here must stay compatible with macOS's stock
# bash 3.2 running under `set -u`: no associative arrays, no ${x,,}, and
# never expand a possibly-empty array without a guard.
#
# Sections:
#   1. Configuration (retroplay.conf)
#   2. Dependency install tracking (for uninstall_deps.sh)
#   3. Pending-batch queues and build markers (resilience)
#   4. Disk space
#   5. Game-folder helpers
#   6. Batch folders, log rotation, notifications

if [ -z "${SCRIPT_DIR:-}" ]; then
    echo "lib.sh: SCRIPT_DIR must be set before sourcing lib.sh" >&2
    return 1 2>/dev/null || exit 1
fi

RP_STATE_DIR="$SCRIPT_DIR/.retroplay"
RP_CONF_FILE="$SCRIPT_DIR/retroplay.conf"
DEP_TRACK_FILE="$SCRIPT_DIR/.retroplay_installed_deps.log"

# ============================================================================
# 1. Configuration
# ============================================================================
# retroplay.conf is plain KEY=VALUE lines. It is PARSED, never sourced, so a
# typo can't run arbitrary commands. Command-line options always override
# whatever the config file says.
rp_load_config() {
    # Built-in defaults (used when there is no config file, or a key is absent)
    RP_VARIANTS="aga ecs rtg"
    RP_OUTPUT_ROOT="."
    RP_ART_ORDER="Covers,Screens,Titles"
    RP_DEMO_ART_ORDER="Titles,Screens,Covers"
    RP_FILESYSTEM="pfs"
    RP_USE_DETOX="no"
    RP_MIN_FREE_MB="1024"
    RP_SPACE_FACTOR="3"
    RP_KEEP_NEW_BATCHES="14"
    RP_OLD_ARCHIVE_DAYS="30"
    RP_LOG_MAX_MB="5"
    RP_LOG_KEEP="4"
    RP_NTFY_TOPIC=""
    RP_NTFY_SERVER="https://ntfy.sh"
    RP_NOTIFY_EMAIL=""
    RP_NOTIFY_ON_SUCCESS="no"
    RP_CONFIG_WARNINGS=""

    [ -f "$RP_CONF_FILE" ] || { rp_finish_config; return 0; }

    local line key val lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line="${line%%#*}"                       # strip comments
        line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        case "$line" in
            *=*) ;;
            *) RP_CONFIG_WARNINGS="${RP_CONFIG_WARNINGS}line $lineno: not KEY=VALUE, ignored
"; continue ;;
        esac
        key="$(printf '%s' "${line%%=*}" | sed 's/[[:space:]]*$//')"
        val="$(printf '%s' "${line#*=}" | sed 's/^[[:space:]]*//')"
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac
        case "$key" in
            VARIANTS|OUTPUT_ROOT|ART_ORDER|DEMO_ART_ORDER|FILESYSTEM|USE_DETOX|\
            MIN_FREE_MB|SPACE_FACTOR|KEEP_NEW_BATCHES|OLD_ARCHIVE_DAYS|LOG_MAX_MB|\
            LOG_KEEP|NTFY_TOPIC|NTFY_SERVER|NOTIFY_EMAIL|NOTIFY_ON_SUCCESS)
                printf -v "RP_$key" '%s' "$val" ;;
            ART_ORDER_[A-Z0-9_]*|EXCLUDE_TAGS_[A-Z0-9_]*)
                printf -v "RP_$key" '%s' "$val" ;;
            *)
                RP_CONFIG_WARNINGS="${RP_CONFIG_WARNINGS}line $lineno: unknown setting '$key', ignored
" ;;
        esac
    done < "$RP_CONF_FILE"
    rp_finish_config
}

rp_finish_config() {
    local n ref
    for n in MIN_FREE_MB SPACE_FACTOR KEEP_NEW_BATCHES OLD_ARCHIVE_DAYS LOG_MAX_MB LOG_KEEP; do
        ref="RP_$n"
        case "${!ref}" in
            ''|*[!0-9]*)
                RP_CONFIG_WARNINGS="${RP_CONFIG_WARNINGS}$n must be a whole number - using default
"
                printf -v "$ref" '%s' "" ;;
        esac
    done
    : "${RP_MIN_FREE_MB:=1024}" "${RP_SPACE_FACTOR:=3}" "${RP_KEEP_NEW_BATCHES:=14}"
    : "${RP_OLD_ARCHIVE_DAYS:=30}" "${RP_LOG_MAX_MB:=5}" "${RP_LOG_KEEP:=4}"
    RP_FILESYSTEM="$(printf '%s' "$RP_FILESYSTEM" | tr '[:upper:]' '[:lower:]')"
    case "$RP_FILESYSTEM" in
        ffs|pfs) ;;
        *) RP_CONFIG_WARNINGS="${RP_CONFIG_WARNINGS}FILESYSTEM must be pfs or ffs - using pfs
"; RP_FILESYSTEM="pfs" ;;
    esac
    RP_USE_DETOX="$(rp_yesno "$RP_USE_DETOX")"
    RP_NOTIFY_ON_SUCCESS="$(rp_yesno "$RP_NOTIFY_ON_SUCCESS")"
    # OUTPUT_ROOT may be relative (to the scripts' folder) or absolute,
    # e.g. a USB SSD mount point.
    case "$RP_OUTPUT_ROOT" in
        /*) ;;
        .|"") RP_OUTPUT_ROOT="$SCRIPT_DIR" ;;
        *) RP_OUTPUT_ROOT="$SCRIPT_DIR/$RP_OUTPUT_ROOT" ;;
    esac
    RP_OUTPUT_ROOT="${RP_OUTPUT_ROOT%/}"
}

rp_yesno() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        y|yes|1|true|on) echo yes ;;
        *) echo no ;;
    esac
}

rp_print_config_warnings() {
    [ -n "${RP_CONFIG_WARNINGS:-}" ] || return 0
    echo "Warnings from $RP_CONF_FILE:" >&2
    printf '%s' "$RP_CONFIG_WARNINGS" | sed 's/^/  /' >&2
}

# Art order for a variant token: ART_ORDER_<VARIANT> if set, else ART_ORDER.
rp_art_order_for() {
    local up var val
    up="$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"
    var="RP_ART_ORDER_$up"
    val="${!var:-}"
    [ -n "$val" ] && printf '%s' "$val" || printf '%s' "$RP_ART_ORDER"
}

# ============================================================================
# 2. Dependency install tracking
# ============================================================================
record_installed_dep() {
    local dep_line="$1:$2"
    if ! grep -qxF "$dep_line" "$DEP_TRACK_FILE" 2>/dev/null; then
        echo "$dep_line" >> "$DEP_TRACK_FILE"
    fi
}

# True only if the package manager itself already has this package fully
# installed. Checked BEFORE offering an install, so a package that was
# already on the system (e.g. installed but not on PATH, like Homebrew's
# keg-only util-linux) is never recorded as installed by these scripts.
# dpkg-query's "install ok installed" is used rather than `dpkg -s`, which
# also succeeds for packages that were removed but left config files.
pkg_already_installed() {
    case "$1" in
        apt)  dpkg-query -W -f='${Status}' "$2" 2>/dev/null | grep -q "install ok installed" ;;
        brew) command -v brew >/dev/null 2>&1 && brew list --versions "$2" >/dev/null 2>&1 ;;
        *)    return 1 ;;
    esac
}

# ============================================================================
# 3. Variants, pending-batch queues and build markers
# ============================================================================
# A "variant token" is aga, ecs, rtg, aga-laced, ecs-laced, or any other
# artwork set name (for iGame_<NAME>). Its output folder is retro_<suffix>.
rp_variant_suffix() {
    printf '%s' "$1" | tr '[:upper:]-' '[:lower:]_'
}

rp_variant_merge_args() {   # prints one merge option per line
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        aga|ecs|rtg|aga-laced|ecs-laced) printf -- '--%s\n' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" ;;
        default) ;;
        *) printf -- '--set\n%s\n' "$1" ;;
    esac
}

rp_state_init() {
    mkdir -p "$RP_STATE_DIR/queue" "$RP_STATE_DIR/complete" "$RP_STATE_DIR/building" 2>/dev/null
}

# Queues and markers are keyed by the output folder's name (e.g. retro_aga).
rp_queue_file() { printf '%s/queue/%s.list' "$RP_STATE_DIR" "$1"; }

rp_queue_count() {
    local q; q="$(rp_queue_file "$1")"
    if [ -s "$q" ]; then grep -c . "$q" 2>/dev/null; else echo 0; fi
}

# Called by update.sh for every newly downloaded archive: added to the queue
# of every finished output folder that still exists. The entry stays queued
# until that folder has successfully absorbed it - so a run that fails or is
# interrupted part-way leaves it queued and the next run picks it up, rather
# than it being forgotten once it's no longer "new" on the server.
rp_queue_new_archive() {
    local path="$1" m key dest
    rp_state_init
    for m in "$RP_STATE_DIR"/complete/*; do
        [ -f "$m" ] || continue
        key="${m##*/}"
        dest="$(cat "$m" 2>/dev/null)"
        [ -n "$dest" ] && [ -d "$dest" ] || continue
        grep -qxF "$path" "$(rp_queue_file "$key")" 2>/dev/null || \
            printf '%s\n' "$path" >> "$(rp_queue_file "$key")"
    done
}

# Removes exactly the lines listed in $2 from key $1's queue (anything
# queued while this run was working stays for next time).
rp_queue_remove_processed() {
    local q tmp; q="$(rp_queue_file "$1")"
    [ -f "$q" ] || return 0
    tmp="$q.tmp.$$"
    grep -vxF -f "$2" "$q" > "$tmp" 2>/dev/null || true
    if [ -s "$tmp" ]; then mv "$tmp" "$q"; else rm -f "$tmp" "$q"; fi
}

rp_queue_clear() { rm -f "$(rp_queue_file "$1")"; }

rp_mark_building() { rp_state_init; printf '%s\n' "$2" > "$RP_STATE_DIR/building/$1"; }
rp_mark_complete() {
    rp_state_init
    printf '%s\n' "$2" > "$RP_STATE_DIR/complete/$1"
    rm -f "$RP_STATE_DIR/building/$1"
}

# Prints: fresh | incomplete | ready
#   fresh       - output folder doesn't exist yet
#   incomplete  - a full build was started but never finished
#   ready       - a finished build (or a legacy one from an older version)
rp_build_state() {
    local key="$1" dest="$2"
    if [ -e "$RP_STATE_DIR/building/$key" ]; then echo incomplete; return; fi
    [ -d "$dest" ] || { echo fresh; return; }
    echo ready
}

# Folders built by older versions of these scripts have no markers. They are
# adopted as finished (rather than forcing a full rebuild of a collection
# that is most likely fine), and from then on get queues like any other.
rp_adopt_legacy() {   # args: key dest
    rp_state_init
    [ -d "$2" ] || return 0
    [ -e "$RP_STATE_DIR/complete/$1" ] && return 0
    [ -e "$RP_STATE_DIR/building/$1" ] && return 0
    printf '%s\n' "$2" > "$RP_STATE_DIR/complete/$1"
}

rp_adopt_configured_variants() {
    local v s
    for v in $RP_VARIANTS; do
        s="$(rp_variant_suffix "$v")"
        rp_adopt_legacy "retro_$s" "$RP_OUTPUT_ROOT/retro_$s"
    done
}

# ============================================================================
# 4. Disk space
# ============================================================================
rp_free_kb() {   # free KB on the filesystem holding $1 (or its nearest existing parent)
    local d="$1"
    while [ ! -e "$d" ] && [ "$d" != "/" ] && [ -n "$d" ]; do d="$(dirname "$d")"; done
    df -Pk "$d" 2>/dev/null | awk 'NR==2 {print $4}'
}

rp_du_kb() {     # total KB used by the given paths (missing ones count as 0)
    local total=0 p k
    for p in "$@"; do
        [ -e "$p" ] || continue
        k="$(du -sk "$p" 2>/dev/null | awk '{print $1}')"
        total=$((total + ${k:-0}))
    done
    echo "$total"
}

# rp_require_space <dir> <needed_kb> <what> - returns 1 (with a clear
# message) if there isn't room for needed_kb plus the MIN_FREE_MB margin.
rp_require_space() {
    local dir="$1" need_kb="$2" what="$3" free_kb margin_kb
    free_kb="$(rp_free_kb "$dir")"
    [ -n "$free_kb" ] || return 0     # can't tell - don't block the run
    margin_kb=$((RP_MIN_FREE_MB * 1024))
    if [ $((need_kb + margin_kb)) -gt "$free_kb" ]; then
        echo "ERROR: not enough free disk space for $what." >&2
        echo "  Needed:    about $((need_kb / 1024)) MB (+ $RP_MIN_FREE_MB MB safety margin)" >&2
        echo "  Available: $((free_kb / 1024)) MB on the drive holding $dir" >&2
        echo "  Free up space, or point OUTPUT_ROOT in retroplay.conf at a bigger drive." >&2
        return 1
    fi
    return 0
}

# ============================================================================
# 5. Game-folder helpers
# ============================================================================
# A WHDLoad game/demo/magazine folder "X" always ships with an "X.info"
# drawer icon beside it. rp_game_roots prints (relative to $1) every such
# folder that isn't inside another one - i.e. one line per game.
rp_game_roots() {
    local root="$1"
    [ -d "$root" ] || return 0
    {
        (cd "$root" && find . -type d -print) | awk '{ sub(/^\.\//, ""); print "D\t" $0 }'
        (cd "$root" && find . -type f -iname '*.info' -print) | awk '{ sub(/^\.\//, ""); print "I\t" $0 }'
    } | awk -F'\t' '
        $1=="D" { dirs[$2]=1; next }
        $1=="I" { s=$2; sub(/\.[^.\/]*$/, "", s); if (s in dirs) cand[s]=1 }
        END {
            for (c in cand) {
                n=split(c, parts, "/"); p=""; nested=0
                for (i=1; i<n; i++) { p=(p=="" ? parts[i] : p "/" parts[i]); if (p in cand) { nested=1; break } }
                if (!nested) print c
            }
        }' | sort
}

rp_count_games() { rp_game_roots "$1" | grep -c . || true; }

# Copies a processed batch into the collection. Each game in the batch
# first REPLACES its existing folder (removing it), so files that only
# existed in an older version of that game don't linger alongside the new
# version. Everything else is merged in normally.
rp_replace_and_copy() {
    local src="$1" dest="$2" rel
    mkdir -p "$dest" || return 1
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        [ -d "$dest/$rel" ] && rm -rf -- "${dest:?}/$rel"
    done < <(rp_game_roots "$src")
    cp -a "$src/." "$dest/"
}

# ============================================================================
# 6. Batch folders, log rotation, notifications
# ============================================================================
rp_timestamp() { date '+%Y-%m-%d_%H%M%S'; }

# Keeps only the newest $2 dated batch folders inside $1.
rp_prune_batches() {
    local dir="$1" keep="$2" count old
    [ -d "$dir" ] || return 0
    count="$(find "$dir" -mindepth 1 -maxdepth 1 -type d | grep -c . || true)"
    [ "$count" -gt "$keep" ] || return 0
    find "$dir" -mindepth 1 -maxdepth 1 -type d | sort | head -n $((count - keep)) | \
        while IFS= read -r old; do rm -rf -- "$old"; done
}

# new_<variant> used to be one flat folder, overwritten every run. It now
# holds dated batch folders; an old-style one is kept as "previous_format".
rp_migrate_new_dir() {
    local d="$1" tmp
    [ -d "$d" ] || return 0
    if [ -e "$d/WHDLoad" ] || [ -e "$d/HD_Loaders" ] || [ -e "$d/JST" ]; then
        tmp="$d.migrating.$$"
        mv "$d" "$tmp" && mkdir -p "$d" && mv "$tmp" "$d/previous_format"
    fi
}

rp_rotate_log() {   # args: file max_mb keep
    local f="$1" max_kb=$(( $2 * 1024 )) keep="$3" size i
    [ -f "$f" ] || return 0
    size="$(du -k "$f" 2>/dev/null | awk '{print $1}')"
    [ "${size:-0}" -ge "$max_kb" ] || return 0
    rm -f "$f.$keep"
    i="$keep"
    while [ "$i" -gt 1 ]; do
        [ -f "$f.$((i - 1))" ] && mv "$f.$((i - 1))" "$f.$i"
        i=$((i - 1))
    done
    mv "$f" "$f.1"
}

# rp_notify <title> <message> - never fails the caller.
rp_notify() {
    local title="$1" msg="$2" url
    if [ -n "${RP_NTFY_TOPIC:-}" ]; then
        url="${RP_NTFY_SERVER%/}/$RP_NTFY_TOPIC"
        if command -v curl >/dev/null 2>&1; then
            curl -fsS -m 20 -H "Title: $title" -d "$msg" "$url" >/dev/null 2>&1 || \
                echo "Note: could not send ntfy notification to $url" >&2
        elif command -v wget >/dev/null 2>&1; then
            wget -q -T 20 -O /dev/null --header="Title: $title" --post-data="$msg" "$url" 2>/dev/null || \
                echo "Note: could not send ntfy notification to $url" >&2
        fi
    fi
    if [ -n "${RP_NOTIFY_EMAIL:-}" ]; then
        if command -v mail >/dev/null 2>&1; then
            printf '%s\n' "$msg" | mail -s "$title" "$RP_NOTIFY_EMAIL" 2>/dev/null || \
                echo "Note: could not send email to $RP_NOTIFY_EMAIL" >&2
        else
            echo "Note: NOTIFY_EMAIL is set but no 'mail' command is installed." >&2
        fi
    fi
    return 0
}

# ============================================================================
# 7. Archive names: version-aware matching and variant tags
# ============================================================================
# Retroplay archive names look like  Name_v1.2_AGA_HD_JOTD_1763.lha  - fields
# separated by "_", one of them a version ("v" + digits/dots/letters).

# Prints "<key>|<version>" for an archive, where <key> is the whole name with
# ONLY the version field blanked out. Two archives are the same release in
# different versions exactly when their keys match - so _AGA, _CD32, _HD,
# _68040 etc. all keep archives apart. Prints nothing if there's no version.
rp_archive_version_key() {
    local stem="${1##*/}" out="" ver="" tok i
    stem="${stem%.*}"
    local -a toks
    IFS=_ read -r -a toks <<< "$stem"
    for ((i = 0; i < ${#toks[@]}; i++)); do
        tok="${toks[$i]}"
        if [ -z "$ver" ] && [ "$i" -gt 0 ]; then
            case "$tok" in
                [Vv][0-9]*)
                    case "${tok#?}" in *[!0-9A-Za-z.]*) ;; *) ver="${tok#?}"; tok="#VERSION#" ;; esac ;;
            esac
        fi
        out="${out}${out:+_}${tok}"
    done
    [ -n "$ver" ] && printf '%s|%s\n' "$out" "$ver"
}

# Compares two version strings field by field, numerically: prints -1, 0 or 1.
#   1.10 > 1.9 > 1.1     1.1.1 > 1.1     1.01a > 1.01     1.01 = 1.1
rp_version_cmp() {
    local a="$1" b="$2" pa pb na nb sa sb
    while [ -n "$a" ] || [ -n "$b" ]; do
        pa="${a%%.*}"; pb="${b%%.*}"
        case "$a" in *.*) a="${a#*.}" ;; *) a="" ;; esac
        case "$b" in *.*) b="${b#*.}" ;; *) b="" ;; esac
        na="${pa%%[!0-9]*}"; sa="${pa#"$na"}"; na="${na:-0}"
        nb="${pb%%[!0-9]*}"; sb="${pb#"$nb"}"; nb="${nb:-0}"
        na=$((10#$na)); nb=$((10#$nb))
        if [ "$na" -lt "$nb" ]; then echo -1; return; fi
        if [ "$na" -gt "$nb" ]; then echo 1; return; fi
        if [[ "$sa" < "$sb" ]]; then echo -1; return; fi
        if [[ "$sa" > "$sb" ]]; then echo 1; return; fi
    done
    echo 0
}

# True if the archive name has any of the comma-separated tags as one of
# its "_" fields (case-insensitive), e.g. rp_archive_has_tag X_v1_AGA.lha AGA,CD32
rp_archive_has_tag() {
    local stem="${1##*/}" tag tok list
    stem="$(printf '%s' "${stem%.*}" | tr '[:lower:]' '[:upper:]')"
    list="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
    local -a toks tags
    IFS=_ read -r -a toks <<< "$stem"
    IFS=, read -r -a tags <<< "$list"
    [ ${#toks[@]} -gt 0 ] && [ ${#tags[@]} -gt 0 ] || return 1
    for tag in "${tags[@]}"; do
        tag="${tag// /}"
        [ -n "$tag" ] || continue
        for tok in "${toks[@]}"; do
            [ "$tok" = "$tag" ] && return 0
        done
    done
    return 1
}

# Tags a variant must NOT contain (EXCLUDE_TAGS_<VARIANT> in retroplay.conf).
# ECS machines can't run AGA or CD32 releases, so those are left out of the
# ECS variants by default.
rp_exclude_tags_for() {
    local up var
    up="$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"
    var="RP_EXCLUDE_TAGS_$up"
    if [ -n "${!var+x}" ]; then printf '%s' "${!var}"; return; fi
    case "$up" in
        ECS|ECS_LACED) printf 'AGA,CD32' ;;
    esac
}

# Archives that were quarantined as superseded but then came back from the
# server are clearly still current there - they are exempted from pruning
# for good, so they aren't downloaded and removed again on every run.
rp_prune_exempt_file() { printf '%s/prune_exempt.list' "$RP_STATE_DIR"; }

# ============================================================================
# 8. PATH under cron, and temporary-folder cleanup
# ============================================================================
# cron runs jobs with a bare PATH (usually just /usr/bin:/bin), so a tool that
# works everywhere in your terminal - unlzx in ~/bin, /usr/local/bin or
# Homebrew, say - can be "not found" in the nightly run. So: every
# interactive run remembers your real PATH, and every run (cron or not)
# APPENDS the remembered folders plus the usual install locations to PATH.
# Appending never overrides your own ordering; it only fills gaps.
rp_path_file() { printf '%s/user_path' "$RP_STATE_DIR"; }

rp_remember_path() {   # rp_remember_path [force]
    [ "${1:-}" = "force" ] || [ -t 0 ] || return 0
    local f; f="$(rp_path_file)"
    [ -f "$f" ] && [ "$(cat "$f" 2>/dev/null)" = "$PATH" ] && return 0
    rp_state_init
    printf '%s\n' "$PATH" > "$f" 2>/dev/null || true
}

rp_extend_path() {
    local saved="" d IFS=:
    [ -f "$(rp_path_file)" ] && saved="$(cat "$(rp_path_file)" 2>/dev/null)"
    for d in $saved "${HOME:-/nonexistent}/bin" "${HOME:-/nonexistent}/.local/bin" \
             /usr/local/bin /usr/local/sbin /opt/homebrew/bin /opt/homebrew/sbin \
             /opt/local/bin /usr/sbin /sbin; do
        case "$d" in /*) ;; *) continue ;; esac      # absolute folders only
        [ -d "$d" ] || continue
        case ":$PATH:" in *":$d:"*) ;; *) PATH="$PATH:$d" ;; esac
    done
    export PATH
}

# Temporary folders record their owner's process ID in ".owner_pid". Any
# matching folder whose owner is no longer running (killed, crashed, power
# cut) is a leftover and is removed; one whose owner is still running is
# never touched. Folders from before this existed have no .owner_pid and are
# treated as leftovers.
rp_mark_temp_owner() { printf '%s\n' "$$" > "$1/.owner_pid" 2>/dev/null || true; }

rp_sweep_stale_temp() {   # rp_sweep_stale_temp <folder-glob>...
    local d pid
    for d in "$@"; do
        [ -d "$d" ] || continue
        pid="$(cat "$d/.owner_pid" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then continue; fi
        rm -rf -- "$d"
    done
}

# Runs as soon as lib.sh is sourced - i.e. before any script checks for its
# tools - so even a cron job that calls start.sh or aga.sh directly finds them.
rp_remember_path
rp_extend_path
