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

# The scripts may sit in the main folder, or tidied away in a "scripts"
# subfolder. Everything else (artwork/, build/, downloads/, logs/, state) is
# kept beside the scripts, or one level up when they are in scripts/.
if [ "${SCRIPT_DIR##*/}" = "scripts" ] && [ -d "${SCRIPT_DIR%/scripts}" ]; then
    RP_BASE_DIR="${SCRIPT_DIR%/scripts}"
else
    RP_BASE_DIR="$SCRIPT_DIR"
fi

RP_STATE_DIR="$RP_BASE_DIR/.retroplay"
RP_CONF_FILE="$RP_BASE_DIR/retroplay.conf"
DEP_TRACK_FILE="$RP_BASE_DIR/.retroplay_installed_deps.log"

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
    RP_STRUCTURED_ART_SETS="AGA ECS RTG"
    RP_MAX_EXTRACT_ATTEMPTS="3"
    RP_DOWNLOAD_RETRIES="3"
    RP_GAPFILL_DAYS="7"
    RP_VERIFY_DOWNLOADS="auto"
    RP_ARTWORK_SYNC="ask"
    RP_ARTWORK_SOURCE_URL="https://ftp2.grandis.nu/turran/FTP/Collection/Various/WHDLoad_Images"
    RP_ARTWORK_ARCHIVE_DIR="artwork_archive"
    RP_ARTWORK_STATE_ROOT=""
    RP_ARTWORK_PACKS="AGA ECS RTG"
    RP_ARTWORK_OPTIONAL_PACKS="AGA_Laced ECS_Laced art TinyLauncher"
    RP_ARTWORK_KEEP_BACKUPS="2"
    RP_ARTWORK_LOCAL_CHANGE_POLICY="ask"
    RP_ARTWORK_VERIFY_DOWNLOADS="yes"
    RP_ARTWORK_FAILURE_POLICY="warn-and-continue"
    RP_ARTWORK_CHECK_INTERVAL_HOURS="24"
    RP_ARTWORK_DIR="artwork"      # holds iGame_*/ TinyLauncher/ archives/
    RP_BUILD_DIR="build"          # holds retro_*/ and new_*/ (under OUTPUT_ROOT)
    RP_DOWNLOAD_DIR="downloads"   # holds WHDLoad/ HD_Loaders/ JST/ old/
    RP_LOG_DIR="logs"
    RP_LOG_RETENTION_DAYS="1"     # delete logs older than this; 0 = keep forever
    RP_STATE_BACKUP="no"          # keep rolling copies of .retroplay? (yes/no)
    RP_STATE_BACKUP_MAX_MB="50"   # if yes: skip when it would exceed this
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
            LOG_KEEP|NTFY_TOPIC|NTFY_SERVER|NOTIFY_EMAIL|NOTIFY_ON_SUCCESS|STRUCTURED_ART_SETS|\
            MAX_EXTRACT_ATTEMPTS|DOWNLOAD_RETRIES|GAPFILL_DAYS|VERIFY_DOWNLOADS|\
            ARTWORK_SYNC|ARTWORK_SOURCE_URL|ARTWORK_ARCHIVE_DIR|ARTWORK_STATE_ROOT|ARTWORK_PACKS|\
            ARTWORK_OPTIONAL_PACKS|ARTWORK_KEEP_BACKUPS|ARTWORK_LOCAL_CHANGE_POLICY|\
            ARTWORK_VERIFY_DOWNLOADS|ARTWORK_FAILURE_POLICY|ARTWORK_CHECK_INTERVAL_HOURS|\
            ARTWORK_DIR|BUILD_DIR|DOWNLOAD_DIR|LOG_DIR|LOG_RETENTION_DAYS|STATE_BACKUP_MAX_MB|STATE_BACKUP)
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
    for n in MIN_FREE_MB SPACE_FACTOR KEEP_NEW_BATCHES OLD_ARCHIVE_DAYS LOG_MAX_MB LOG_KEEP MAX_EXTRACT_ATTEMPTS DOWNLOAD_RETRIES GAPFILL_DAYS LOG_RETENTION_DAYS; do
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
    : "${RP_MAX_EXTRACT_ATTEMPTS:=3}" "${RP_DOWNLOAD_RETRIES:=3}" "${RP_GAPFILL_DAYS:=7}"
    : "${RP_ARTWORK_KEEP_BACKUPS:=2}" "${RP_ARTWORK_CHECK_INTERVAL_HOURS:=24}" "${RP_LOG_RETENTION_DAYS:=1}" "${RP_STATE_BACKUP_MAX_MB:=50}"
    # Artwork settings: check the words, and the pack names for anything unsafe.
    case "$RP_ARTWORK_SYNC" in ask|auto|yes|no) ;; *) RP_CONFIG_WARNINGS="${RP_CONFIG_WARNINGS}ARTWORK_SYNC must be ask, auto, yes or no - using ask
"; RP_ARTWORK_SYNC=ask ;; esac
    case "$RP_ARTWORK_LOCAL_CHANGE_POLICY" in ask|keep-local|backup-and-replace|fail) ;; *) RP_CONFIG_WARNINGS="${RP_CONFIG_WARNINGS}ARTWORK_LOCAL_CHANGE_POLICY must be ask, keep-local, backup-and-replace or fail - using keep-local
"; RP_ARTWORK_LOCAL_CHANGE_POLICY=keep-local ;; esac
    case "$RP_ARTWORK_FAILURE_POLICY" in warn-and-continue|fail) ;; *) RP_CONFIG_WARNINGS="${RP_CONFIG_WARNINGS}ARTWORK_FAILURE_POLICY must be warn-and-continue or fail - using warn-and-continue
"; RP_ARTWORK_FAILURE_POLICY=warn-and-continue ;; esac
    case "$RP_ARTWORK_VERIFY_DOWNLOADS" in yes|no) ;; *) RP_ARTWORK_VERIFY_DOWNLOADS=yes ;; esac
    case "$RP_ARTWORK_SOURCE_URL" in http://*|https://*|ftp://*) ;; *) RP_CONFIG_WARNINGS="${RP_CONFIG_WARNINGS}ARTWORK_SOURCE_URL must start with http://, https:// or ftp://
" ;; esac
    for _p in $RP_ARTWORK_PACKS $RP_ARTWORK_OPTIONAL_PACKS; do
        case "$_p" in
            */*|*..*|.*|*[!A-Za-z0-9_-]*) RP_CONFIG_WARNINGS="${RP_CONFIG_WARNINGS}artwork pack name '$_p' contains characters that aren't allowed - ignoring it
" ;;
        esac
    done
    unset _p
    [ "$RP_GAPFILL_DAYS" -ge 1 ] 2>/dev/null || RP_GAPFILL_DAYS=1
    case "$(printf '%s' "$RP_VERIFY_DOWNLOADS" | tr '[:upper:]' '[:lower:]')" in
        yes|no|auto) RP_VERIFY_DOWNLOADS="$(printf '%s' "$RP_VERIFY_DOWNLOADS" | tr '[:upper:]' '[:lower:]')" ;;
        *) RP_CONFIG_WARNINGS="${RP_CONFIG_WARNINGS}VERIFY_DOWNLOADS must be yes, no or auto - using auto
"; RP_VERIFY_DOWNLOADS=auto ;;
    esac
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
        .|"") RP_OUTPUT_ROOT="$RP_BASE_DIR" ;;
        *) RP_OUTPUT_ROOT="$RP_BASE_DIR/$RP_OUTPUT_ROOT" ;;
    esac
    RP_OUTPUT_ROOT="${RP_OUTPUT_ROOT%/}"
    # Folders the tool works in. Each may be given as an absolute path;
    # otherwise artwork/downloads/logs sit beside the scripts and the builds
    # under OUTPUT_ROOT (so they land on the big drive).
    case "$RP_ARTWORK_DIR"  in /*) RP_ARTWORK_ROOT="$RP_ARTWORK_DIR" ;;  *) RP_ARTWORK_ROOT="$RP_BASE_DIR/${RP_ARTWORK_DIR:-artwork}" ;; esac
    case "$RP_DOWNLOAD_DIR" in /*) RP_DOWNLOAD_ROOT="$RP_DOWNLOAD_DIR" ;; *) RP_DOWNLOAD_ROOT="$RP_BASE_DIR/${RP_DOWNLOAD_DIR:-downloads}" ;; esac
    case "$RP_LOG_DIR"      in /*) RP_LOG_ROOT="$RP_LOG_DIR" ;;          *) RP_LOG_ROOT="$RP_BASE_DIR/${RP_LOG_DIR:-logs}" ;; esac
    case "$RP_BUILD_DIR"    in /*) RP_BUILD_ROOT="$RP_BUILD_DIR" ;;      *) RP_BUILD_ROOT="$RP_OUTPUT_ROOT/${RP_BUILD_DIR:-build}" ;; esac
    RP_ARTWORK_ROOT="${RP_ARTWORK_ROOT%/}"; RP_DOWNLOAD_ROOT="${RP_DOWNLOAD_ROOT%/}"
    RP_LOG_ROOT="${RP_LOG_ROOT%/}"; RP_BUILD_ROOT="${RP_BUILD_ROOT%/}"
    RP_REPORT_ROOT="$RP_BASE_DIR/reports"
    # Downloaded artwork archives live with the other downloads.
    RP_ARTWORK_CACHE="$RP_DOWNLOAD_ROOT/artwork_archive"
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
            { cat "$(rp_queue_file "$key")" 2>/dev/null; printf '%s\n' "$path"; } | rp_atomic_write "$(rp_queue_file "$key")"
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

rp_mark_building() { rp_state_init; printf '%s\n' "$2" | rp_atomic_write "$RP_STATE_DIR/building/$1"; }
rp_mark_complete() {
    rp_state_init
    printf '%s\n' "$2" | rp_atomic_write "$RP_STATE_DIR/complete/$1"
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
    printf '%s\n' "$2" | rp_atomic_write "$RP_STATE_DIR/complete/$1"
}

rp_adopt_configured_variants() {
    local v s
    for v in $RP_VARIANTS; do
        s="$(rp_variant_suffix "$v")"
        rp_adopt_legacy "retro_$s" "$RP_BUILD_ROOT/retro_$s"
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
        k="$(du -skH "$p" 2>/dev/null | awk '{print $1}')"
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
rp_notify() {   # rp_notify <title> <message>; returns 0 if at least one channel got it
    local title="$1" msg="$2" url sent=1
    if [ -n "${RP_NTFY_TOPIC:-}" ]; then
        url="${RP_NTFY_SERVER%/}/$RP_NTFY_TOPIC"
        if command -v curl >/dev/null 2>&1; then
            curl -fsS -m 20 -H "Title: $title" -d "$msg" "$url" >/dev/null 2>&1 && sent=0 || \
                echo "Note: could not send ntfy notification to $url" >&2
        elif command -v wget >/dev/null 2>&1; then
            wget -q -T 20 -O /dev/null --header="Title: $title" --post-data="$msg" "$url" 2>/dev/null && sent=0 || \
                echo "Note: could not send ntfy notification to $url" >&2
        fi
    fi
    if [ -n "${RP_NOTIFY_EMAIL:-}" ]; then
        if command -v mail >/dev/null 2>&1; then
            printf '%s\n' "$msg" | mail -s "$title" "$RP_NOTIFY_EMAIL" 2>/dev/null && sent=0 || \
                echo "Note: could not send email to $RP_NOTIFY_EMAIL" >&2
        else
            echo "Note: NOTIFY_EMAIL is set but no 'mail' command is installed." >&2
        fi
    fi
    return "$sent"
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
    printf '%s\n' "$PATH" | rp_atomic_write "$f" 2>/dev/null || true
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
        pid="$(cat "$d/.owner_pid" 2>/dev/null)" || pid=""   # no owner file = leftover (must not trip set -e)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then continue; fi
        rm -rf -- "$d"
    done
}


# ============================================================================
# 9. Folder layout and script-set consistency
# ============================================================================
# The only folders allowed at the top of retro_*, new_*/<batch> and every
# extracted tree. Prints each unexpected (non-hidden) entry, one per line.
rp_layout_problems() {
    local e
    for e in "$1"/*; do
        [ -e "$e" ] || continue
        case "${e##*/}" in WHDLoad|HD_Loaders|JST) ;; *) printf '%s\n' "${e##*/}" ;; esac
    done
}

# Every script in the set carries a "retroplay-suite:" stamp. A mix of old
# and new scripts (easy to end up with when copying files over in stages)
# can do real damage - e.g. an older extract.sh recreating
# Users/<you>/Downloads/Amiga/... inside retro_* - so the set is checked as
# a whole. Prints each script whose stamp doesn't match this lib.sh.
RP_SUITE_VERSION="2026.09.22"
RP_SUITE_FILES="all.sh start.sh extract.sh merge.sh sort.sh update.sh quick.sh aga.sh ecs.sh rtg.sh doctor.sh install_cron.sh uninstall_deps.sh setup.sh"

rp_suite_mismatches() {
    local f v
    for f in $RP_SUITE_FILES; do
        [ -f "$SCRIPT_DIR/$f" ] || { printf '%s (missing)\n' "$f"; continue; }
        v="$(sed -n 's/^# retroplay-suite: *\([^ ]*\).*/\1/p' "$SCRIPT_DIR/$f" | head -1)"
        [ "$v" = "$RP_SUITE_VERSION" ] || printf '%s (%s)\n' "$f" "${v:-older version}"
    done
}

# ============================================================================
# 10. Exit codes, messages, option values, paths, progress
# ============================================================================
# Exit codes used across the suite:
RP_EXIT_OK=0            # completed work
RP_EXIT_NOWORK=2        # nothing to do / no changes
RP_EXIT_REMOTE=3        # transient network / server failure - try again later
RP_EXIT_CONFIG=4        # bad option, configuration or missing prerequisite
RP_EXIT_INTEGRITY=5     # extraction / validation / integrity failure
RP_EXIT_INTERRUPTED=130 # stopped by Ctrl-C or a signal

rp_is_interactive() { [ -t 0 ] && [ -t 1 ]; }

# Consistent output styling. Colour only on a terminal, never in a log.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RP_C_HEAD=$'\033[1m'; RP_C_OK=$'\033[32m'; RP_C_WARN=$'\033[33m'; RP_C_ERR=$'\033[31m'; RP_C_DIM=$'\033[2m'; RP_C_OFF=$'\033[0m'
else
    RP_C_HEAD=""; RP_C_OK=""; RP_C_WARN=""; RP_C_ERR=""; RP_C_DIM=""; RP_C_OFF=""
fi

# rp_heading <text>       - a titled section
# rp_step <n> <of> <text> - "[2/6] Checking for updates" with the time
# rp_done <text>          - a finished step
rp_heading() { printf '\n%s== %s ==%s\n' "$RP_C_HEAD" "$*" "$RP_C_OFF"; }
rp_step() {
    local n="$1" of="$2"; shift 2
    printf '\n%s[%s/%s]%s %s %s(%s)%s\n' "$RP_C_HEAD" "$n" "$of" "$RP_C_OFF" "$*" "$RP_C_DIM" "$(date '+%H:%M:%S')" "$RP_C_OFF"
}
rp_done() { printf '      %s%s%s %s\n' "$RP_C_OK" "done" "$RP_C_OFF" "$*"; }
rp_ts()    { date '+%Y-%m-%d %H:%M:%S'; }
rp_log()   { printf '[%s] %s\n' "$(rp_ts)" "$*"; }
rp_warn()  { printf 'WARNING: %s\n' "$*" >&2; }
rp_debug() { [ "${RP_DEBUG:-0}" = "1" ] && printf '[debug] %s\n' "$*" >&2; return 0; }
rp_die()   {   # rp_die <exit-code> <message...>
    local code="$1"; shift
    printf 'ERROR: %s\n' "$*" >&2
    exit "$code"
}

# Guards an option that takes a value, e.g. inside a parser:
#   --dest) rp_require_option_value "$1" "$#" "${2-}"; DEST="$2"; shift 2 ;;
# A missing value (end of the line) or another option in its place
# (e.g. "--dest --aga") is a clear error instead of a hang or a crash.
rp_require_option_value() {
    if [ "$2" -lt 2 ] || [ -z "$3" ]; then
        rp_die "$RP_EXIT_CONFIG" "$1 needs a value (see --help)"
    fi
    case "$3" in
        -*) rp_die "$RP_EXIT_CONFIG" "$1 needs a value, but was followed by the option '$3' (see --help)" ;;
    esac
}

# Absolute form of a path; relative paths are taken relative to the scripts'
# folder (the scripts always run from there). The path need not exist.
rp_resolve_path() {
    case "$1" in
        /*) printf '%s\n' "${1%/}" ;;
        *)  local p="${1#./}"; printf '%s\n' "${SCRIPT_DIR%/}/${p%/}" ;;
    esac
}

rp_format_duration() {   # seconds -> H:MM:SS
    printf '%d:%02d:%02d' $(($1 / 3600)) $((($1 % 3600) / 60)) $(($1 % 60))
}

# One progress display for every script. On a terminal: a bar redrawn in
# place. Anywhere else (cron, logs, pipes): a plain timestamped line at 0,
# 25, 50, 75 and 100% - no carriage returns or escape codes in log files.
RP_PROGRESS_LAST=""
rp_progress() {   # rp_progress <current> <total> [label]
    local cur="$1" tot="$2" label="${3:-Progress}" pct width=40 fill bar
    [ "$tot" -gt 0 ] 2>/dev/null || return 0
    [ "$cur" -gt "$tot" ] && cur="$tot"
    pct=$((cur * 100 / tot))
    if [ -t 1 ]; then
        fill=$((pct * width / 100))
        bar="$(printf '%*s' "$fill" '' | tr ' ' '#')"
        printf '\r%s %3d%% [%-*s] %d/%d' "$label" "$pct" "$width" "$bar" "$cur" "$tot"
        [ "$cur" -ge "$tot" ] && printf '\n'
    else
        local bucket=$((pct / 25))
        if [ "$cur" -le 1 ] || [ "$bucket" != "$RP_PROGRESS_LAST" ]; then
            [ "$bucket" = "$RP_PROGRESS_LAST" ] && [ "$cur" -gt 1 ] || \
                printf '[%s] %s: %d%% (%d/%d)\n' "$(rp_ts)" "$label" "$pct" "$cur" "$tot"
            RP_PROGRESS_LAST="$bucket"
        fi
    fi
    return 0
}

# Writes stdin to a file atomically: a reader never sees a half-written file,
# and a crash mid-write leaves the previous version intact.
rp_atomic_write() {   # rp_atomic_write <file>   (content on stdin)
    local f="$1" tmp
    tmp="$(dirname "$f")/.$(basename "$f").tmp.$$"
    cat > "$tmp" && mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# ============================================================================
# 13. Status view and test notification
# ============================================================================
rp_test_notify() {
    if [ -z "${RP_NTFY_TOPIC:-}" ] && [ -z "${RP_NOTIFY_EMAIL:-}" ]; then
        echo "Notifications aren't set up. Set NTFY_TOPIC (and/or NOTIFY_EMAIL) in retroplay.conf."
        return 4
    fi
    if rp_notify "Amiga Retroplay: test notification" "If you can read this, notifications work. Sent $(rp_ts) from $(hostname 2>/dev/null || uname -n)."; then
        echo "Test notification sent${RP_NTFY_TOPIC:+ to ntfy topic '$RP_NTFY_TOPIC'}${RP_NOTIFY_EMAIL:+ to $RP_NOTIFY_EMAIL}. Check it arrived."
        return 0
    fi
    echo "Couldn't send the test notification - see the note above."
    return 3
}

# rp_print_status [short]: what the collection looks like right now.
rp_print_status() {
    local short="${1:-}" v key dest q st last code when result ls free drive
    echo "Amiga Retroplay status"
    if [ -f "$RP_STATE_DIR/last_run" ]; then
        code="$(sed -n 's/^code=//p' "$RP_STATE_DIR/last_run")"
        when="$(sed -n 's/^time=//p' "$RP_STATE_DIR/last_run")"
        echo "  Last run:      $when - $(rp_exit_meaning "$code")"
    else
        echo "  Last run:      none recorded yet"
    fi
    for v in $(printf '%s' "$RP_VARIANTS" | tr ',' ' '); do
        key="retro_$(rp_variant_suffix "$v")"; dest="$RP_BUILD_ROOT/$key"
        q="$(rp_queue_count "$key")"
        case "$(rp_build_state "$key" "$dest")" in
            fresh)      st="not built yet" ;;
            incomplete) st="a full build was interrupted - the next run redoes it" ;;
            *)          st="built"
                        [ -f "$RP_STATE_DIR/last_success/$key" ] && st="built, last updated $(cat "$RP_STATE_DIR/last_success/$key")"
                        [ "$q" -gt 0 ] && st="$st - $q new archive(s) waiting" ;;
        esac
        printf '  %-14s %s
' "$key:" "$st"
    done
    if drive="$(rp_check_output_root dry 2>&1)"; then
        free="$(rp_free_kb "$RP_OUTPUT_ROOT")"
        echo "  Output folder: $RP_OUTPUT_ROOT${free:+ ($((free / 1024)) MB free)}"
    else
        echo "  Output folder: NOT AVAILABLE - $drive"
    fi
    [ -n "$short" ] && return 0
    if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "retroplay-all-sh"; then
        echo "  Nightly run:   installed (every night at 2am)"
    else
        echo "  Nightly run:   not installed (./install_cron.sh)"
    fi
    if [ -n "${RP_NTFY_TOPIC:-}${RP_NOTIFY_EMAIL:-}" ]; then
        echo "  Notifications: ${RP_NTFY_TOPIC:+ntfy topic '$RP_NTFY_TOPIC' }${RP_NOTIFY_EMAIL:+email $RP_NOTIFY_EMAIL}"
    else
        echo "  Notifications: off (set NTFY_TOPIC or NOTIFY_EMAIL in retroplay.conf)"
    fi
    last="$(ls -1 "$RP_REPORT_ROOT"/*.txt 2>/dev/null | grep -v '_no_artwork' | sort | tail -1)"
    [ -n "$last" ] && echo "  Last report:   reports/${last##*/}"
    return 0
}

# ============================================================================
# Run at load time (kept at the very end so every helper above exists):
# before any script checks for its tools, so even a cron job that calls
# start.sh or aga.sh directly finds them.
# ============================================================================
rp_remember_path
rp_extend_path

# ============================================================================
# 11. Fast superseded-archive detection (one awk pass instead of a process
#     per archive pair). Same rules as rp_archive_version_key/rp_version_cmp.
# ============================================================================
# rp_find_superseded <exempt-list> <new-archives> <all-archives>
# Each list: one path per line. Prints, tab-separated, for every archive to
# retire:  <old path>  <old version>  <new version>  <new path>
# An archive is retired only when a NEW archive in the SAME folder has the
# identical name apart from the version field, and a strictly higher version.
rp_find_superseded() {
    awk -F'\t' '
    function keyver(path,   n, i, stem, f, tok, key, ver, rest) {
        n = split(path, f, "/"); stem = f[n]; dir = substr(path, 1, length(path) - length(stem))
        sub(/\.[^.]*$/, "", stem)
        n = split(stem, f, "_")
        if (n > 1 && f[n] == "") n--          # like bash read: no trailing empty field
        key = ""; ver = ""
        for (i = 1; i <= n; i++) {
            tok = f[i]
            if (ver == "" && i > 1 && tok ~ /^[Vv][0-9]/) {
                rest = substr(tok, 2)
                if (rest !~ /[^0-9A-Za-z.]/) { ver = rest; tok = "#VERSION#" }
            }
            key = key (i > 1 ? "_" : "") tok
        }
        KEY = dir key; VER = ver
        return ver != ""
    }
    function vcmp(a, b,   pa, pb, ia, ib, na, nb, sa, sb) {
        while (a != "" || b != "") {
            ia = index(a, "."); if (ia) { pa = substr(a, 1, ia - 1); a = substr(a, ia + 1) } else { pa = a; a = "" }
            ib = index(b, "."); if (ib) { pb = substr(b, 1, ib - 1); b = substr(b, ib + 1) } else { pb = b; b = "" }
            match(pa, /^[0-9]*/); na = substr(pa, 1, RLENGTH); sa = substr(pa, RLENGTH + 1)
            match(pb, /^[0-9]*/); nb = substr(pb, 1, RLENGTH); sb = substr(pb, RLENGTH + 1)
            na += 0; nb += 0
            if (na < nb) return -1
            if (na > nb) return 1
            if (sa < sb) return -1
            if (sa > sb) return 1
        }
        return 0
    }
    FILENAME == ARGV[1] { exempt[$0] = 1; next }
    FILENAME == ARGV[2] {
        if (keyver($0)) {
            if (!(KEY in best) || vcmp(VER, bestver[KEY]) > 0) { best[KEY] = $0; bestver[KEY] = VER }
            isnew[$0] = 1
        }
        next
    }
    {
        if ($0 in exempt) next
        if (!keyver($0) || !(KEY in best)) next
        if ($0 == best[KEY]) next
        if (vcmp(VER, bestver[KEY]) < 0) print $0 "\t" VER "\t" bestver[KEY] "\t" best[KEY]
    }' "$1" "$2" "$3"
}

# rp_queue_new_archives <file of paths>: rp_queue_new_archive for a whole
# batch - one read and one atomic write per queue instead of per archive.
rp_queue_new_archives() {
    local list="$1" m key dest q
    [ -s "$list" ] || return 0
    rp_state_init
    for m in "$RP_STATE_DIR"/complete/*; do
        [ -f "$m" ] || continue
        key="${m##*/}"
        dest="$(cat "$m" 2>/dev/null)" || dest=""
        [ -n "$dest" ] && [ -d "$dest" ] || continue
        q="$(rp_queue_file "$key")"
        { cat "$q" 2>/dev/null; cat "$list"; } | awk 'NF && !seen[$0]++' | rp_atomic_write "$q"
    done
}

# ============================================================================
# 12. Output-drive guard, state backups, gap-fill scheduling, exit meanings
# ============================================================================
RP_OUTPUT_MARKER=".retroplay_output"

# If OUTPUT_ROOT is on a USB drive that isn't mounted, its folder is either
# missing or an empty mount point on the SD card - and a run would quietly
# rebuild everything there, filling the card. So the output folder gets a
# marker file with an ID the first time it's used, recorded in the state
# folder (which lives with the scripts, not on that drive). Later runs
# refuse unless the same marker is there.
# rp_check_output_root [dry]  - "dry": check only, never create the marker.
rp_check_output_root() {
    local root="$RP_OUTPUT_ROOT" idf="$RP_STATE_DIR/output_root_id" want id
    if [ ! -d "$root" ]; then
        echo "The output folder $root doesn't exist. If it's on a USB drive, check the drive is connected and mounted." >&2
        return 1
    fi
    want="$(cat "$idf" 2>/dev/null)" || want=""
    if [ -n "$want" ] && [ "${want%%|*}" = "$root" ]; then
        id="$(cat "$root/$RP_OUTPUT_MARKER" 2>/dev/null)" || id=""
        [ "$id" = "${want#*|}" ] && return 0
        echo "The output folder $root is missing its marker file ($RP_OUTPUT_MARKER), so it isn't the drive this collection was built on." >&2
        echo "If it's a USB drive, it's probably not mounted - nothing was changed. (To really start over on a new drive, delete $idf.)" >&2
        return 1
    fi
    [ "${1:-}" = "dry" ] && return 0
    id="$(date '+%s')-$$-${RANDOM:-0}"
    printf '%s\n' "$id" | rp_atomic_write "$root/$RP_OUTPUT_MARKER" 2>/dev/null || {
        echo "Can't write to the output folder $root." >&2; return 1; }
    rp_state_init
    printf '%s|%s\n' "$root" "$id" | rp_atomic_write "$idf"
}

# Rolling backups of the small state folder (queues, build markers, ...),
# so losing it doesn't mean losing what's queued. The newest 7 are kept.
RP_BACKUP_DIR="$RP_BASE_DIR/.retroplay_backups"
rp_backup_state() {
    local skip
    # Off by default: .retroplay holds only the queue and build markers, and
    # if it is ever lost the next run simply rebuilds what it needs. Set
    # STATE_BACKUP="yes" to keep the rolling copies.
    [ "${RP_STATE_BACKUP:-no}" = "yes" ] || return 0
    [ -d "$RP_STATE_DIR" ] || return 0
    mkdir -p "$RP_BACKUP_DIR" 2>/dev/null || return 0
    # Only the small state: queues, build markers, artwork manifests. The
    # bulky things that also live under .retroplay - previous artwork
    # versions, staging and work folders - are NOT backed up: they can be
    # gigabytes, and tarring them every run took many minutes on a Pi.
    local kb
    kb="$(rp_du_kb "$RP_STATE_DIR")"
    for skip in "$RP_STATE_DIR/artwork/backups" "$RP_STATE_DIR/artwork/work" "$RP_STATE_DIR/stage"; do
        [ -d "$skip" ] && kb=$(( kb - $(rp_du_kb "$skip") ))
    done
    if [ "${kb:-0}" -gt $(( ${RP_STATE_BACKUP_MAX_MB:-50} * 1024 )) ]; then
        rp_warn "skipping the state backup: it would be $(( kb / 1024 )) MB (limit ${RP_STATE_BACKUP_MAX_MB:-50} MB)"
        return 0
    fi
    tar -czf "$RP_BACKUP_DIR/.state-new.tgz" \
        --exclude='.retroplay/stage' \
        --exclude='.retroplay/artwork/backups' \
        --exclude='.retroplay/artwork/work' \
        --exclude='.retroplay/artwork/remote_cache' \
        -C "$RP_BASE_DIR" .retroplay 2>/dev/null \
        && mv -f "$RP_BACKUP_DIR/.state-new.tgz" "$RP_BACKUP_DIR/state-$(date '+%Y%m%d-%H%M%S').tgz"
    rm -f "$RP_BACKUP_DIR/.state-new.tgz"
    ls -1 "$RP_BACKUP_DIR"/state-*.tgz 2>/dev/null | sort -r | awk 'NR > 7' | while IFS= read -r old; do rm -f "$old"; done
    return 0
}

# If the state folder has gone missing (deleted by mistake, disk problem)
# but backups exist, restore the newest one rather than silently starting
# over - which would lose every queued download.
rp_restore_state_if_lost() {
    local latest
    [ -d "$RP_STATE_DIR/complete" ] && return 0
    latest="$(ls -1 "$RP_BACKUP_DIR"/state-*.tgz 2>/dev/null | sort | tail -1)"
    [ -n "$latest" ] || return 0
    if tar -xzf "$latest" -C "$RP_BASE_DIR" 2>/dev/null; then
        echo "The state folder (.retroplay) was missing - restored it from ${latest##*/}."
        echo "(To deliberately start from scratch, delete both .retroplay and .retroplay_backups.)"
    fi
    return 0
}

# Is the artwork gap-fill worth running for this output folder? Only if an
# artwork pack changed since the last one, or it's been GAPFILL_DAYS days.
rp_gapfill_due() {   # <key>
    local stamp="$RP_STATE_DIR/gapfill/$1" d
    [ -f "$stamp" ] || return 0
    [ -n "$(find "$stamp" -mtime +"$(( RP_GAPFILL_DAYS - 1 ))" 2>/dev/null)" ] && return 0
    for d in "$RP_ARTWORK_ROOT"/[iI][gG][aA][mM][eE]_* "$RP_ARTWORK_ROOT/TinyLauncher"; do
        [ -d "$d" ] || continue
        [ -n "$(find "$d" -newer "$stamp" 2>/dev/null | head -1)" ] && return 0
    done
    return 1
}
rp_gapfill_done() { mkdir -p "$RP_STATE_DIR/gapfill" 2>/dev/null; touch "$RP_STATE_DIR/gapfill/$1"; }

# Plain-English meaning of an exit code, for summaries and notifications.
rp_exit_meaning() {
    case "$1" in
        0)   echo "finished successfully" ;;
        2)   echo "nothing to do - everything is up to date" ;;
        3)   echo "network or server problem - it will try again next run" ;;
        4)   echo "setup problem (missing tool, drive not mounted, another run in progress, or not enough space) - see the message above" ;;
        5)   echo "some archives couldn't be extracted - everything else was installed, and they'll be retried" ;;
        130) echo "stopped before finishing (interrupted)" ;;
        *)   echo "unexpected error (code $1) - see the log" ;;
    esac
}

# rp_test_archive <file>: integrity test with the format's own tool. A tool
# that isn't installed means "can't test" - treated as OK, never as corrupt.
# rp_test_archive <file> [name to judge the format by]
# The second argument matters for a download still named "<name>.lha.part":
# without it the format would be unknown and the file would go untested.
rp_test_archive() {
    case "${2:-$1}" in
        *.lha|*.LHA|*.lzh|*.LZH)
            command -v lha >/dev/null 2>&1 || return 0
            lha t "$1" >/dev/null 2>&1 ;;
        *.zip|*.ZIP)
            if command -v unzip >/dev/null 2>&1; then unzip -tqq "$1" >/dev/null 2>&1
            elif command -v 7z >/dev/null 2>&1; then 7z t "$1" >/dev/null 2>&1
            else return 0; fi ;;
        *.lzx|*.LZX)
            command -v lsar >/dev/null 2>&1 || return 0
            lsar -t "$1" >/dev/null 2>&1 ;;
        *) return 0 ;;
    esac
}

# =============================================================================
# 14. Downloads, checksums, fingerprints (used by the artwork engine)
# =============================================================================
rp_info() { printf '%s\n' "$*"; }
rp_print_usage_error() {   # <script> <message>
    printf 'ERROR: %s\n' "$2" >&2
    printf "Try '%s --help'.\n" "$1" >&2
    return "$RP_EXIT_CONFIG"
}

# rp_sha256 <file>: prints the checksum, or nothing if no tool is available
# (callers must treat "no checksum" as reduced verification, not failure).
rp_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    fi
}
rp_have_sha256() { command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; }

# rp_fetch <url> <output file>: download to the given path (curl or wget).
rp_fetch() {
    # On a terminal, show the transfer meter; in a log, stay quiet (the
    # caller prints one line per file instead).
    if command -v curl >/dev/null 2>&1; then
        if [ -t 1 ]; then curl -fL --progress-bar -m 1800 -o "$2" "$1"
        else curl -fsSL -m 1800 -o "$2" "$1"; fi
    elif command -v wget >/dev/null 2>&1; then
        if [ -t 1 ]; then wget -T 1800 --progress=bar:force -O "$2" "$1"
        else wget -q -T 1800 -O "$2" "$1"; fi
    else return 1; fi
}

# rp_fetch_listing <url>: print a directory listing page (HTML or FTP style).
rp_fetch_listing() {
    if command -v curl >/dev/null 2>&1; then curl -fsSL -m 120 "$1"
    elif command -v wget >/dev/null 2>&1; then wget -q -T 120 -O - "$1"
    else return 1; fi
}

# rp_dir_fingerprint <folder>: a stable fingerprint of a folder's contents
# (relative paths and sizes). Used to notice user changes to artwork.
rp_dir_fingerprint() {
    [ -d "$1" ] || return 1
    # One batched listing rather than a process per file: an artwork pack can
    # hold tens of thousands of files, and the per-file version took minutes
    # (far worse on a Pi). "ls -ldn" gives size and name for every entry.
    ( cd "$1" && find . \( -type f -o -type l \) -exec ls -ldn {} + 2>/dev/null \
        | awk '{ size = $5; name = $9; for (i = 10; i <= NF; i++) name = name " " $i; print size "\t" name }' \
        | LC_ALL=C sort ) \
        | { if rp_have_sha256; then rp_sha256 /dev/stdin; else cksum | awk '{print $1"-"$2}'; fi; }
}

# rp_same_filesystem <path a> <path b>: 0 if both are on one filesystem, so a
# rename is atomic. Missing paths are checked via their nearest parent.
rp_same_filesystem() {
    local a="$1" b="$2"
    while [ ! -e "$a" ] && [ "$a" != "/" ]; do a="$(dirname "$a")"; done
    while [ ! -e "$b" ] && [ "$b" != "/" ]; do b="$(dirname "$b")"; done
    [ "$(df -P "$a" 2>/dev/null | awk 'NR==2 {print $1}')" = "$(df -P "$b" 2>/dev/null | awk 'NR==2 {print $1}')" ]
}

# rp_replace_tree <candidate> <live> <backup folder>
# Puts <candidate> in place of <live>, keeping the old one as a backup first.
# Same filesystem: renames (atomic). Different filesystem: copies the
# candidate in first, and only then swaps - the live folder is never removed
# before its replacement is complete.
rp_replace_tree() {
    local cand="$1" live="$2" backup="$3" tmp
    mkdir -p "$(dirname "$live")" || return 1
    if [ -e "$live" ]; then
        mkdir -p "$(dirname "$backup")" || return 1
        if rp_same_filesystem "$live" "$backup"; then mv "$live" "$backup" || return 1
        else cp -a "$live" "$backup" || return 1; rm -rf "$live" || return 1; fi
    fi
    if rp_same_filesystem "$cand" "$live"; then
        mv "$cand" "$live" || return 1
    else
        tmp="$live.incoming.$$"
        rm -rf "$tmp"
        cp -a "$cand" "$tmp" || { rm -rf "$tmp"; return 1; }
        mv "$tmp" "$live" || { rm -rf "$tmp"; return 1; }
    fi
    return 0
}

# rp_file_age <file>: "3 hours ago" style age, for status displays.
rp_file_age() {
    [ -f "$1" ] || { echo "never"; return; }
    if [ -n "$(find "$1" -mmin +1440 2>/dev/null)" ]; then echo "more than a day ago"
    elif [ -n "$(find "$1" -mmin +60 2>/dev/null)" ]; then echo "within the last day"
    else echo "within the last hour"; fi
}

# =============================================================================
# 15. One-time move to the tidier folder layout
# =============================================================================
# Older versions kept everything beside the scripts: iGame_*/ , retro_*/ ,
# WHDLoad/ , *.log. This moves each of those into artwork/ , build/ ,
# downloads/ and logs/ exactly once. Anything already in place is left alone,
# and nothing is ever overwritten - a move only happens when the new location
# is free, so an interrupted migration simply continues next time.
rp_migrate_layout() {
    local moved=0 d name
    mkdir -p "$RP_ARTWORK_ROOT" "$RP_LOG_ROOT" "$RP_DOWNLOAD_ROOT" 2>/dev/null
    for d in "$RP_BASE_DIR"/[iI][gG][aA][mM][eE]_* "$RP_BASE_DIR/TinyLauncher"; do
        [ -d "$d" ] || continue
        name="${d##*/}"
        [ -e "$RP_ARTWORK_ROOT/$name" ] || { mv "$d" "$RP_ARTWORK_ROOT/$name" && moved=1; }
    done
    mkdir -p "$RP_DOWNLOAD_ROOT" 2>/dev/null
    for d in "$RP_BASE_DIR/artwork_archives" "$RP_BASE_DIR/artwork_archive" \
             "$RP_ARTWORK_ROOT/archives" "$RP_DOWNLOAD_ROOT/artwork_archives"; do
        [ -d "$d" ] || continue
        [ -e "$RP_ARTWORK_CACHE" ] || { mv "$d" "$RP_ARTWORK_CACHE" && moved=1; }
    done
    for name in WHDLoad HD_Loaders JST old; do
        [ -d "$RP_BASE_DIR/$name" ] || continue
        [ -e "$RP_DOWNLOAD_ROOT/$name" ] || { mv "$RP_BASE_DIR/$name" "$RP_DOWNLOAD_ROOT/$name" && moved=1; }
    done
    for d in "$RP_BASE_DIR"/*.log; do
        [ -f "$d" ] || continue
        name="${d##*/}"
        [ -e "$RP_LOG_ROOT/$name" ] || { mv "$d" "$RP_LOG_ROOT/$name" && moved=1; }
    done
    mkdir -p "$RP_BUILD_ROOT" 2>/dev/null
    for d in "$RP_OUTPUT_ROOT"/retro_* "$RP_OUTPUT_ROOT"/new_*; do
        [ -d "$d" ] || continue
        name="${d##*/}"
        case "$name" in retro_\*|new_\*) continue ;; esac
        [ -e "$RP_BUILD_ROOT/$name" ] || { mv "$d" "$RP_BUILD_ROOT/$name" && moved=1; }
    done
    # Build markers record where each collection lives - point them at build/.
    if [ "$moved" -eq 1 ] && [ -d "$RP_STATE_DIR/complete" ]; then
        for d in "$RP_STATE_DIR"/complete/*; do
            [ -f "$d" ] || continue
            name="$(cat "$d" 2>/dev/null)"
            case "$name" in
                "$RP_BUILD_ROOT"/*) ;;
                */retro_*) printf '%s\n' "$RP_BUILD_ROOT/${name##*/}" | rp_atomic_write "$d" ;;
            esac
        done
    fi
    [ "$moved" -eq 1 ] && rp_info "Tidied the folder layout: artwork/, build/, downloads/ and logs/."
    return 0
}

# Deletes logs older than LOG_RETENTION_DAYS (0 = keep them for ever).
# Only the logs folder is touched; reports and state are left alone.
rp_prune_logs() {
    [ "${RP_LOG_RETENTION_DAYS:-1}" -gt 0 ] 2>/dev/null || return 0
    [ -d "$RP_LOG_ROOT" ] || return 0
    find "$RP_LOG_ROOT" -type f \( -name '*.log' -o -name '*.log.[0-9]' \) \
        -mtime +"$(( RP_LOG_RETENTION_DAYS - 1 ))" -exec rm -f {} + 2>/dev/null
    return 0
}


# =============================================================================
# 16. Keeping .retroplay small
# =============================================================================
# Run at the start of each run. Everything removed here is either left over
# from an interrupted run or can be rebuilt; nothing that the next run needs
# is touched.
#
#   KEPT (essential):  queue/          what is waiting to be installed
#                      complete/       which collections are built, and where
#                      building/       an interrupted build, so it gets redone
#                      gapfill/        when artwork was last filled in
#                      last_success/, last_run, output_root_id
#                      extract_attempts.list, prune_exempt.list, user_path
#                      artwork/manifests/   what artwork is installed
#   KEPT, but capped:  artwork/backups/     previous artwork (ARTWORK_KEEP_BACKUPS)
#   REMOVED:           stage/, artwork/work/    staging from an earlier run
#                      artwork/remote_cache/ temporary listing downloads
#                      artwork_changed/ markers already acted on
#                      empty queue files, attempts for archives that are gone
rp_tidy_state() {
    local before after freed d n target keep
    [ -d "$RP_STATE_DIR" ] || return 0
    before="$(rp_du_kb "$RP_STATE_DIR")"

    rm -rf "$RP_STATE_DIR/stage" "$RP_STATE_DIR/artwork/work" 2>/dev/null
    rm -f "$RP_STATE_DIR/artwork/remote_cache"/.listing.raw.* 2>/dev/null
    rm -rf "$RP_STATE_DIR/artwork_changed" 2>/dev/null

    for d in "$RP_STATE_DIR"/queue/*.list; do            # empty queues
        [ -f "$d" ] && [ ! -s "$d" ] && rm -f "$d"
    done

    # Attempt counts for archives that no longer exist (downloaded again, or
    # retired) would otherwise linger for ever.
    if [ -s "$RP_STATE_DIR/extract_attempts.list" ]; then
        while IFS="$(printf '\t')" read -r n target; do
            [ -n "$target" ] && [ -f "$RP_DOWNLOAD_ROOT/$target" ] && printf '%s\t%s\n' "$n" "$target"
        done < "$RP_STATE_DIR/extract_attempts.list" | rp_atomic_write "$RP_STATE_DIR/extract_attempts.list"
    fi

    # Previous artwork versions: keep the configured number per pack.
    keep="${RP_ARTWORK_KEEP_BACKUPS:-2}"
    for d in "$RP_STATE_DIR"/artwork/backups/*; do
        [ -d "$d" ] || continue
        ls -1d "$d"/*/ 2>/dev/null | sort -r | awk -v k="$keep" 'NR > k' | while IFS= read -r old; do rm -rf "$old"; done
        rmdir "$d" 2>/dev/null                            # nothing left to keep
    done

    after="$(rp_du_kb "$RP_STATE_DIR")"
    freed=$(( ${before:-0} - ${after:-0} ))
    if [ "$freed" -gt 1024 ]; then
        rp_info "      tidied .retroplay: freed $(( freed / 1024 )) MB (kept the queue, build markers and artwork manifests)"
    fi
    return 0
}

# rp_remote_size <url>: the size the server reports, without downloading the
# file (an HTTP HEAD). Prints nothing if the server doesn't say.
rp_remote_size() {
    local hdr
    if command -v curl >/dev/null 2>&1; then hdr="$(curl -fsSLI -m 30 "$1" 2>/dev/null)"
    elif command -v wget >/dev/null 2>&1; then hdr="$(wget -q -T 30 --spider --server-response "$1" 2>&1)"
    else return 1; fi
    printf '%s\n' "$hdr" | awk 'BEGIN{IGNORECASE=1} /^ *content-length:/ { gsub(/\r/,""); n=$2 } END { if (n) print n }'
}

# rp_file_size <file>
rp_file_size() { [ -f "$1" ] && wc -c < "$1" 2>/dev/null | tr -d ' '; }

# Printed at the end of a run when the collection is built for PFS. Amiga
# PFS partitions default to 31-character filenames; WHDLoad names are longer,
# and copying them onto a partition that hasn't been told to allow 107
# characters can CORRUPT it.
rp_pfs_reminder() {
    [ "$(printf '%s' "${RP_FILESYSTEM:-pfs}" | tr '[:upper:]' '[:lower:]')" = "pfs" ] || return 0
    printf '\n%s' "$RP_C_WARN"
    echo "============================================================"
    echo " IMPORTANT - before copying this collection to your Amiga"
    echo "============================================================"
    echo " These files are named for PFS, which allows long filenames."
    echo " Your Amiga PFS partition must be told to allow them first:"
    echo
    echo "     setfnsize <drive:> 107"
    echo
    echo " for example:  setfnsize DH1: 107"
    echo
    echo " Copying long filenames onto a PFS partition that still has the"
    echo " 31-character default CAN CORRUPT THAT PARTITION."
    echo " (Set FILESYSTEM=\"ffs\" in retroplay.conf if you use FFS instead.)"
    echo "============================================================"
    printf '%s\n' "$RP_C_OFF"
    return 0
}

