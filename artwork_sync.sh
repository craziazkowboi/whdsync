#!/usr/bin/env bash
# retroplay-suite: 2026.09.22   (every script in the set must carry the same stamp)
#
# Purpose:
#   The one place that downloads, validates and installs iGame_* / TinyLauncher
#   artwork packs. Called directly by people, and by all.sh before a sync.
#
# Inputs:
#   Remote listing at ARTWORK_SOURCE_URL; settings from retroplay.conf.
#
# Outputs / side effects:
#   Archive cache   <script dir>/artwork_archive/<name>.lha
#   Live artwork    <script dir>/iGame_<suffix>/ , <script dir>/TinyLauncher/
#   State           <state>/artwork/{manifests,remote_cache,work,backups}
#
# Safety contract:
#   * Live artwork is replaced only after the archive has been downloaded to a
#     .part file, validated, extracted to staging and checked for layout and
#     unsafe paths.
#   * The previous live folder is backed up first and kept.
#   * A folder you changed yourself, or one this tool never installed, is never
#     overwritten automatically (ARTWORK_LOCAL_CHANGE_POLICY).
#   * A failed download, validation or extraction leaves the cache and the live
#     folder exactly as they were.
#   * plan/status/verify never write anything.
#
# Called by: start.sh --artwork-*, all.sh (library mode), setup.sh
#
# Maintainer notes:
#   Library mode (--called-from-all) must NOT take the global lock: all.sh
#   already holds it. Bash 3.2 compatible: no associative arrays.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1
if [ ! -f "$SCRIPT_DIR/lib.sh" ]; then
    echo "ERROR: lib.sh is missing from $SCRIPT_DIR - it ships with these scripts." >&2
    exit 4
fi
. "$SCRIPT_DIR/lib.sh"
rp_load_config

# =============================================================================
# Configuration and argument parsing
# =============================================================================
usage() {
    cat << USAGE
Keeps the iGame artwork packs up to date, safely.

Usage: artwork_sync.sh <command> [options]
   or: start.sh --artwork-status | --artwork-plan | --artwork-sync | ...

Commands:
  --status              What's installed, what's out of date
  --plan                What a sync would do (downloads nothing, changes nothing)
  --sync                Download, check and install what's needed
  --verify              Check the installed artwork and the archive cache
  --rollback NAME       Put back the previous version of one part

Options:
  --for VARIANT         Only the artwork a variant needs (repeatable):
                        aga, aga-laced, ecs, ecs-laced, rtg
  --all-artwork         Everything the source offers (what all.sh uses)
  --tinylauncher        Include TinyLauncher.lha
  --force               Re-download and re-install even if nothing changed
  --yes                 Don't ask; use the configured policies
  --help                This help

The source publishes one archive per section and flavour. They are installed
into the folders merge.sh reads:

  IGame_Covers_RTG.lha         -> artwork/iGame_RTG/Covers/...
  IGame_Screens_AGA_Laced.lha  -> artwork/iGame_AGA/laced/Screens/...
  IGame_Titles_ECS_LoRes.lha   -> artwork/iGame_ECS/lores/Titles/...
  TinyLauncher.lha             -> artwork/TinyLauncher/...

  --for aga        uses the LoRes archives      --for aga-laced  the Laced ones
  --for ecs        uses the LoRes archives      --for ecs-laced  the Laced ones
  --for rtg        uses the RTG archives

Archives are cached in downloads/artwork_archive/ and only re-downloaded when
the source offers a different version.

Examples:
  ./artwork_sync.sh --plan --for aga        # what the AGA build would fetch
  ./artwork_sync.sh --sync --all-artwork    # everything (as all.sh does)
  ./artwork_sync.sh --rollback iGame_AGA/laced/Covers

Safety: your own changes to an artwork folder are never overwritten
automatically (ARTWORK_LOCAL_CHANGE_POLICY, default "$RP_ARTWORK_LOCAL_CHANGE_POLICY").
A failed download or check leaves the installed artwork exactly as it was.

Exit codes: 0 done, 2 nothing to do, 3 source/network problem,
            4 setup or option problem, 5 validation problem, 130 interrupted.
USAGE
}

CMD=""; SEL_VARIANTS=""; ALL_ARTWORK=0; WANT_TINY=0; FORCE=0; ASSUME_YES=0
CALLED_FROM_ALL=0; UNATTENDED=0; ROLLBACK_NAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --status|--plan|--sync|--verify) CMD="${1#--}"; shift ;;
        --rollback)   rp_require_option_value "$1" "$#" "${2-}"; CMD=rollback; ROLLBACK_NAME="$2"; shift 2 ;;
        --for|--set)  rp_require_option_value "$1" "$#" "${2-}"; SEL_VARIANTS="$SEL_VARIANTS $2"; shift 2 ;;
        --tinylauncher|--tinylaucher) WANT_TINY=1; shift ;;   # second spelling kept as an alias
        --all-artwork) ALL_ARTWORK=1; shift ;;
        --force)      FORCE=1; shift ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        --unattended) UNATTENDED=1; ASSUME_YES=1; shift ;;
        --called-from-all) CALLED_FROM_ALL=1; UNATTENDED=1; ASSUME_YES=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) rp_print_usage_error artwork_sync.sh "unknown option: $1"; exit 4 ;;
    esac
done
[ -n "$CMD" ] || { usage; exit 0; }

ART_STATE="${RP_ARTWORK_STATE_ROOT:-$RP_STATE_DIR/artwork}"
case "$RP_ARTWORK_ARCHIVE_DIR" in
    /*) CACHE_DIR="$RP_ARTWORK_ARCHIVE_DIR" ;;
    *)  CACHE_DIR="$RP_ARTWORK_CACHE" ;;          # downloads/artwork_archive
esac
MANIFEST_DIR="$ART_STATE/manifests"; WORK_DIR="$ART_STATE/work"
BACKUP_DIR="$ART_STATE/backups"; REMOTE_CACHE="$ART_STATE/remote_cache"
SOURCE_URL="${RP_ARTWORK_SOURCE_URL%/}"
CHANGED_LIST="$RP_STATE_DIR/artwork_changed"
WARNINGS=0; INSTALLED=0; SKIPPED=0; FAILED=0

cleanup() { [ -n "${MY_WORK:-}" ] && rm -rf "$MY_WORK"; }
trap cleanup EXIT
trap 'echo; echo "Interrupted - the current artwork is unchanged."; exit 130' INT TERM

# =============================================================================
# Remote listing: only iGame_*.lha and TinyLauncher.lha are ever considered
# =============================================================================
# The source publishes one archive per section and flavour:
#   IGame_<Covers|Screens|Titles>_<AGA|ECS>_<Laced|LoRes>.lha
#   IGame_<Covers|Screens|Titles>_RTG.lha
#   TinyLauncher.lha
# Anything else there (readmes, other archives, zips) is ignored.
approved() {
    case "$1" in
        [Ii][Gg]ame_[CST]*_*.lha|[Ii][Gg]ame_[CST]*_*.LHA) : ;;
        [Tt]iny[Ll]auncher.lha|[Tt]iny[Ll]auncher.LHA) return 0 ;;
        *) return 1 ;;
    esac
    # section and variant must both be ones we know
    case "$(printf '%s' "$1" | cut -d_ -f2)" in Covers|Screens|Titles) ;; *) return 1 ;; esac
    case "$(printf '%s' "${1%.[Ll][Hh][Aa]}" | cut -d_ -f3-)" in
        AGA_Laced|AGA_LoRes|ECS_Laced|ECS_LoRes|RTG) return 0 ;;
        *) return 1 ;;
    esac
}

# Where an archive's contents belong, relative to the artwork folder.
#   IGame_Screens_AGA_Laced.lha -> iGame_AGA/laced/Screens
#   IGame_Covers_RTG.lha        -> iGame_RTG/Covers
#   TinyLauncher.lha            -> TinyLauncher
target_for() {
    local stem section rest
    case "$1" in [Tt]iny*) printf 'TinyLauncher'; return 0 ;; esac
    stem="${1%.[Ll][Hh][Aa]}"
    section="$(printf '%s' "$stem" | cut -d_ -f2)"
    rest="$(printf '%s' "$stem" | cut -d_ -f3-)"
    case "$rest" in
        RTG)        printf 'iGame_RTG/%s' "$section" ;;
        AGA_Laced)  printf 'iGame_AGA/laced/%s' "$section" ;;
        AGA_LoRes)  printf 'iGame_AGA/lores/%s' "$section" ;;
        ECS_Laced)  printf 'iGame_ECS/laced/%s' "$section" ;;
        ECS_LoRes)  printf 'iGame_ECS/lores/%s' "$section" ;;
    esac
}
# Manifests and backups are keyed by a flat, safe version of that path.
target_key() { printf '%s' "$1" | tr '/' '_'; }

# The archives one variant needs (three sections).
archives_for_variant() {
    local v flav
    v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$v" in
        aga)        flav="AGA_LoRes" ;;
        aga-laced)  flav="AGA_Laced" ;;
        ecs)        flav="ECS_LoRes" ;;
        ecs-laced)  flav="ECS_Laced" ;;
        rtg)        flav="RTG" ;;
        tiny*)      printf 'TinyLauncher.lha\n'; return 0 ;;
        *) rp_warn "no artwork is published for '$1' - skipping it"; return 0 ;;
    esac
    printf 'IGame_Covers_%s.lha\nIGame_Screens_%s.lha\nIGame_Titles_%s.lha\n' "$flav" "$flav" "$flav"
}

# Fetches the listing (cached for ARTWORK_CHECK_INTERVAL_HOURS unless forced)
# and writes: name <TAB> size <TAB> date   for approved files only.
LISTING="$REMOTE_CACHE/listing.tsv"
fetch_listing() {
    # Always read the source when a check happens. WHEN to check is decided
    # by the caller (all.sh honours ARTWORK_CHECK_INTERVAL_HOURS; an explicit
    # artwork command always checks). The stored copy is only a fallback for
    # reporting when the source can't be reached.
    local raw
    mkdir -p "$REMOTE_CACHE" 2>/dev/null
    raw="$REMOTE_CACHE/.listing.raw.$$"
    if ! rp_fetch_listing "$SOURCE_URL/" > "$raw" 2>/dev/null || [ ! -s "$raw" ]; then
        rm -f "$raw"
        return 1
    fi
    # Accepts an HTML index or a plain FTP-style listing. The name comes from
    # href="..." or the last field; size/date are taken when the line offers
    # them, and simply left empty when it doesn't.
    awk '
        { line = $0
          name = ""
          if (match(line, /href="[^"]*\.[Ll][Hh][Aa]"/)) {
              name = substr(line, RSTART + 6, RLENGTH - 7)
          } else if (match(line, /[^ \t"><]+\.[Ll][Hh][Aa]/)) {
              name = substr(line, RSTART, RLENGTH)
          }
          if (name == "") next
          sub(/.*\//, "", name)
          size = ""; date = ""
          if (match(line, /[0-9]{4}-[0-9]{2}-[0-9]{2}[ 	]+[0-9]{2}:[0-9]{2}/)) date = substr(line, RSTART, RLENGTH)
          if (match(line, /[0-9]+(\.[0-9]+)?[KMG]?[ \t]*$/)) { size = substr(line, RSTART, RLENGTH); gsub(/[ \t]/, "", size) }
          if (!(name in seen)) { seen[name] = 1; printf "%s\t%s\t%s\n", name, size, date }
        }' "$raw" > "$raw.tsv"
    rm -f "$raw"
    : > "$LISTING.tmp"
    while IFS="$(printf '\t')" read -r n sz dt; do
        approved "$n" && printf '%s\t%s\t%s\n' "$n" "$sz" "$dt" >> "$LISTING.tmp"
    done < "$raw.tsv"
    rm -f "$raw.tsv"
    mv -f "$LISTING.tmp" "$LISTING"
    return 0
}

# Which archives this run is about, one per line (in listing order, so the
# progress display counts sensibly).
selected_archives() {
    local v
    {
        if [ "$ALL_ARTWORK" -eq 1 ]; then
            cut -f1 "$LISTING" 2>/dev/null
        elif [ -n "$SEL_VARIANTS" ]; then
            for v in $SEL_VARIANTS; do archives_for_variant "$v"; done
            [ "$WANT_TINY" -eq 1 ] && printf 'TinyLauncher.lha\n'
        else
            # No variant given: everything the source offers, which includes
            # both flavours (Laced and LoRes) and TinyLauncher.
            cut -f1 "$LISTING" 2>/dev/null
        fi
    } | awk 'NF && !seen[$0]++'
}

remote_field() { awk -F'\t' -v n="$1" -v f="$2" '$1 == n { print $f; exit }' "$LISTING" 2>/dev/null; }
# Manifests are flat files: the target path's slashes become underscores.
manifest_file() { printf '%s/%s.meta' "$MANIFEST_DIR" "$(target_key "$1")"; }
manifest_get()  { sed -n "s/^$2=//p" "$(manifest_file "$1")" 2>/dev/null | head -1; }

# managed | modified | unmanaged | absent
target_state() {
    local target="$1" live="$RP_ARTWORK_ROOT/$1" fp
    [ -d "$live" ] || { echo absent; return; }
    [ -f "$(manifest_file "$target")" ] || { echo unmanaged; return; }
    fp="$(rp_dir_fingerprint "$live")"
    if [ "$fp" = "$(manifest_get "$target" fingerprint)" ]; then echo managed; else echo modified; fi
}

# install | update | current | unavailable
planned_action() {
    local archive="$1" target="$2" rsize rdate
    grep -q "^$archive	" "$LISTING" 2>/dev/null || { echo unavailable; return; }
    [ "$FORCE" -eq 1 ] && { echo update; return; }
    [ -d "$RP_ARTWORK_ROOT/$target" ] || { echo install; return; }
    rsize="$(remote_field "$archive" 2)"; rdate="$(remote_field "$archive" 3)"
    if [ -f "$(manifest_file "$target")" ] && [ -f "$CACHE_DIR/$archive" ] \
       && [ "$(manifest_get "$target" remote_size)" = "$rsize" ] \
       && [ "$(manifest_get "$target" remote_date)" = "$rdate" ]; then
        echo current
    else
        echo update
    fi
}

# =============================================================================
# Download, validate, extract, install
# =============================================================================
download_archive() {   # <archive>; leaves a validated file in the cache
    local archive="$1" url part have want
    url="$SOURCE_URL/$archive"; part="$CACHE_DIR/$archive.part"
    mkdir -p "$CACHE_DIR" || return 1
    rm -f "$part"

    # Already downloaded? Compare what we have with the size the source
    # reports - from the listing if it gave one, otherwise by asking the
    # server for the headers only. Nothing is downloaded to make this check,
    # so an archive that hasn't changed is never fetched twice.
    have="$(rp_file_size "$CACHE_DIR/$archive")"
    if [ -n "$have" ]; then
        want="$(remote_field "$archive" 2)"
        case "$want" in *[!0-9]*) want="" ;; esac       # listing sizes like "185M" are no use
        [ -n "$want" ] || want="$(rp_remote_size "$url")"
        if [ -n "$want" ] && [ "$have" = "$want" ]; then
            rp_info "  $archive is already downloaded and unchanged ($(( have / 1048576 )) MB) - not fetching it again"
            return 0
        fi
    fi

    rp_info "  downloading $archive"
    rp_fetch "$url" "$part" || { rm -f "$part"; rp_warn "could not download $archive - the current artwork is unchanged"; return 3; }
    if [ "$RP_ARTWORK_VERIFY_DOWNLOADS" = "yes" ] && ! rp_test_archive "$part" "$archive"; then
        rm -f "$part"
        rp_warn "$archive failed its integrity check - the cached archive and the live folder were left unchanged"
        return 5
    fi
    mv -f "$part" "$CACHE_DIR/$archive" || return 1    # replaces the cache only now
    return 0
}

# Rejects anything that could escape staging, plus unexpected layouts.
# Rejects anything that could escape staging, and anything that isn't the
# expected shape. Each archive holds ONE section's category folders
# (Games/Demos/Magazines/Beta), either at the top level or inside one
# wrapping folder (sometimes with the section folder in between).
validate_staging() {   # <staging folder> <target path>
    local stage="$1" target="$2" bad tops n inner t
    bad="$(cd "$stage" && find . -name '*..*' -o -type l 2>/dev/null | head -5)"
    if [ -n "$bad" ]; then
        rp_warn "$target: the archive contains links or '..' paths - refusing it"; return 5
    fi
    tops="$(cd "$stage" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||')"
    [ -n "$tops" ] || { rp_warn "$target: the archive is empty"; return 5; }

    if _is_category_set "$stage"; then printf '%s\n' "$stage"; return 0; fi
    n="$(printf '%s\n' "$tops" | grep -c .)"
    if [ "$n" = "1" ] && [ -d "$stage/$tops" ]; then
        inner="$stage/$tops"
        if _is_category_set "$inner"; then printf '%s\n' "$inner"; return 0; fi
        for t in "$inner"/*; do          # e.g. <archive name>/Covers/Games/...
            [ -d "$t" ] || continue
            if _is_category_set "$t"; then printf '%s\n' "$t"; return 0; fi
        done
    fi
    rp_warn "$target: unexpected layout inside the archive (top level: $(printf '%s ' $tops))- refusing it rather than guessing"
    return 5
}

# True when a folder holds WHDLoad category folders (or the letter folders
# some packs use directly).
_is_category_set() {
    local d="$1" e
    for e in "$d"/*; do
        [ -d "$e" ] || continue
        case "${e##*/}" in
            Games|Demos|Magazines|Beta|Game|Demo|Magazine|[0-9A-Za-z]) return 0 ;;
        esac
    done
    return 1
}

install_pack() {   # <archive> <target path, may contain />
    local archive="$1" target="$2" live="$RP_ARTWORK_ROOT/$2" key state cand backup ts
    key="$(target_key "$target")"
    state="$(target_state "$target")"
    case "$state" in
        modified|unmanaged)
            case "$RP_ARTWORK_LOCAL_CHANGE_POLICY" in
                keep-local)
                    rp_info "  $target: your own changes are there - left alone (ARTWORK_LOCAL_CHANGE_POLICY=keep-local)"
                    SKIPPED=$((SKIPPED + 1)); return 0 ;;
                fail)
                    rp_warn "$target: your own changes are there and the policy is 'fail' - stopping"
                    FAILED=$((FAILED + 1)); return 5 ;;
                ask)
                    if [ "$ASSUME_YES" -eq 1 ] || ! rp_is_interactive; then
                        rp_info "  $target: your own changes are there - left alone (unattended default)"
                        SKIPPED=$((SKIPPED + 1)); return 0
                    fi
                    printf '  %s has changes of your own (or was not installed by this tool). Replace it, keeping a backup? [y/N] ' "$target"
                    read -r reply
                    case "$reply" in [Yy]*) ;; *) SKIPPED=$((SKIPPED + 1)); return 0 ;; esac ;;
            esac ;;
    esac

    MY_WORK="$WORK_DIR/$key.$$"
    rm -rf "$MY_WORK"; mkdir -p "$MY_WORK/x" || return 1
    rp_info "  unpacking $archive -> ${RP_ARTWORK_ROOT##*/}/$target"
    ( cd "$MY_WORK/x" && lha x "$CACHE_DIR/$archive" ) > /dev/null 2>&1 || {
        rp_warn "$target: could not unpack $archive - the live folder is unchanged"; FAILED=$((FAILED + 1)); return 5; }
    cand="$(validate_staging "$MY_WORK/x" "$target")" || { FAILED=$((FAILED + 1)); return 5; }

    ts="$(date '+%Y%m%d-%H%M%S')"; backup="$BACKUP_DIR/$key/$ts"
    if ! rp_replace_tree "$cand" "$live" "$backup"; then
        rp_warn "$target: installing failed; restoring the previous folder"
        [ -d "$backup" ] && [ ! -d "$live" ] && mv "$backup" "$live"
        FAILED=$((FAILED + 1)); return 5
    fi
    # keep only the newest few backups
    ls -1d "$BACKUP_DIR/$key"/*/ 2>/dev/null | sort -r | awk -v k="$RP_ARTWORK_KEEP_BACKUPS" 'NR > k' \
        | while IFS= read -r old; do rm -rf "$old"; done

    mkdir -p "$MANIFEST_DIR" "$CHANGED_LIST" 2>/dev/null
    printf 'archive=%s\nfingerprint=%s\nsha256=%s\nremote_size=%s\nremote_date=%s\ninstalled_at=%s\nbackup=%s\n' \
        "$archive" "$(rp_dir_fingerprint "$live")" "$(rp_sha256 "$CACHE_DIR/$archive")" \
        "$(remote_field "$archive" 2)" "$(remote_field "$archive" 3)" "$(rp_ts)" "$backup" \
        | rp_atomic_write "$(manifest_file "$target")"
    : > "$CHANGED_LIST/$key"
    rm -rf "$MY_WORK"; MY_WORK=""
    INSTALLED=$((INSTALLED + 1))
    rp_info "  $target: installed (previous version kept in ${backup#$SCRIPT_DIR/})"
    return 0
}

# =============================================================================
# Commands
# =============================================================================
cmd_status() {
    echo "Artwork status"
    echo "  Source:        $SOURCE_URL"
    echo "  Archive cache: ${CACHE_DIR#$SCRIPT_DIR/}"
    if [ -s "$LISTING" ]; then
        echo "  Remote list:   $(grep -c . "$LISTING") approved archive(s), checked $(rp_file_age "$LISTING")"
    else
        echo "  Remote list:   not checked yet (run ./start.sh --artwork-plan)"
    fi
    local a t st
    for a in $(selected_archives); do
        t="$(target_for "$a")"; st="$(target_state "$t")"
        case "$st" in
            absent)    st="not installed" ;;
            managed)   st="installed $(manifest_get "$t" installed_at), unchanged" ;;
            modified)  st="installed, but you have changed it - it won't be overwritten" ;;
            unmanaged) st="your own folder (not installed by this tool) - it won't be overwritten" ;;
        esac
        printf '  %-18s %s\n' "$t:" "$st"
    done
    echo "  Policy:        ARTWORK_SYNC=$RP_ARTWORK_SYNC, local changes: $RP_ARTWORK_LOCAL_CHANGE_POLICY, on failure: $RP_ARTWORK_FAILURE_POLICY"
    echo "  Next:          ./start.sh --artwork-plan   (see what would change)"
    return 0
}

cmd_plan() {
    fetch_listing || { rp_warn "could not read the artwork source listing ($SOURCE_URL) - nothing was changed"; return 3; }
    echo "Artwork update plan"
    echo "  Source: $SOURCE_URL"
    local a t act rdate rsize n=0
    for a in $(selected_archives); do
        t="$(target_for "$a")"; act="$(planned_action "$a" "$t")"
        echo
        echo "  Remote archive:     $a"
        echo "  Local archive cache: ${CACHE_DIR#$SCRIPT_DIR/}/$a"
        echo "  Live target:        ${SCRIPT_DIR}/$t"
        rdate="$(remote_field "$a" 3)"; rsize="$(remote_field "$a" 2)"
        echo "  Remote metadata:    ${rdate:-date not given by the source}, ${rsize:-size not given by the source}"
        echo "  Local target state: $(target_state "$t")"
        case "$act" in
            install)     echo "  Planned action:     download, validate, install (new pack)"; n=$((n + 1)) ;;
            update)      echo "  Planned action:     download, validate, back up the current folder, install"; n=$((n + 1)) ;;
            current)     echo "  Planned action:     nothing - already up to date" ;;
            unavailable) echo "  Planned action:     nothing - not offered at the source right now (your copy is kept)" ;;
        esac
    done
    echo
    echo "Nothing was changed. To apply: ./start.sh --artwork-sync"
    [ "$n" -gt 0 ] || return 2
    return 0
}

cmd_sync() {
    fetch_listing || { rp_warn "could not read the artwork source listing ($SOURCE_URL) - the current artwork is unchanged"; return 3; }
    local a t act rc=0 worked=0 total done_n=0
    total="$(selected_archives | grep -c .)"
    for a in $(selected_archives); do
        done_n=$((done_n + 1))
        rp_progress "$done_n" "$total" "Artwork"
        t="$(target_for "$a")"; act="$(planned_action "$a" "$t")"
        case "$act" in
            current)     rp_debug "$t up to date"; continue ;;
            unavailable) rp_warn "$a is not offered at the source right now - keeping your current $t"; WARNINGS=$((WARNINGS + 1)); continue ;;
        esac
        if [ "$FORCE" -eq 1 ] && [ -d "$RP_ARTWORK_ROOT/$t" ] && ! [ "$ASSUME_YES" -eq 1 ] && rp_is_interactive; then
            printf '  Re-install %s from %s? [y/N] ' "$t" "$a"; read -r reply
            case "$reply" in [Yy]*) ;; *) continue ;; esac
        fi
        rp_info "$t:"
        if ! download_archive "$a"; then WARNINGS=$((WARNINGS + 1)); rc=3; continue; fi
        install_pack "$a" "$t" || rc=5
        worked=1
    done
    if [ "$INSTALLED" -gt 0 ]; then
        if [ "$SKIPPED" -gt 0 ]; then rp_info "Artwork: $INSTALLED pack(s) updated, $SKIPPED left alone"
        else rp_info "Artwork: $INSTALLED pack(s) updated"; fi
    fi
    [ "$worked" -eq 0 ] && [ "$rc" -eq 0 ] && return 2
    return "$rc"
}

cmd_verify() {
    local a t live rc=0
    echo "Artwork check (nothing is changed)"
    for a in $(selected_archives); do
        t="$(target_for "$a")"; live="$RP_ARTWORK_ROOT/$t"
        if [ ! -d "$live" ]; then printf '  %-18s not installed\n' "$t:"; continue; fi
        if [ -n "$(find "$live" -type l 2>/dev/null | head -1)" ]; then
            printf '  %-18s PROBLEM: contains links\n' "$t:"; rc=5; continue
        fi
        if [ -z "$(find "$live" -type d -name 'Covers' -o -type d -name 'Screens' -o -type d -name 'Titles' -o -type d -name 'Game' 2>/dev/null | head -1)" ]; then
            printf '  %-18s WARNING: no Covers/Screens/Titles folders\n' "$t:"; WARNINGS=$((WARNINGS + 1)); continue
        fi
        printf '  %-18s OK (%s)\n' "$t:" "$(target_state "$t")"
    done
    for a in $(selected_archives); do
        [ -f "$CACHE_DIR/$a" ] || continue
        rp_test_archive "$CACHE_DIR/$a" || { printf '  cache %-12s PROBLEM: the cached archive is damaged (it will be downloaded again)\n' "$a"; rc=5; }
    done
    return "$rc"
}

cmd_rollback() {
    local t="$1" live backups newest ts
    case "$t" in [Tt]iny*) t=TinyLauncher ;; iGame_*) ;; *) t="iGame_$t" ;; esac
    live="$RP_ARTWORK_ROOT/$t"
    newest="$(ls -1d "$BACKUP_DIR/$(target_key "$t")"/*/ 2>/dev/null | sort | tail -1)"
    [ -n "$newest" ] || { rp_warn "no saved previous version of $t to go back to"; return 2; }
    echo "Roll back $t"
    echo "  Restore:  ${newest%/}"
    echo "  Replacing: $live (kept as a new backup first)"
    if [ "$ASSUME_YES" -ne 1 ] && rp_is_interactive; then
        printf '  Go ahead? [y/N] '; read -r reply
        case "$reply" in [Yy]*) ;; *) echo "  Cancelled - nothing changed."; return 2 ;; esac
    fi
    ts="$(date '+%Y%m%d-%H%M%S')"
    rp_replace_tree "${newest%/}" "$live" "$BACKUP_DIR/$t/$ts" || { rp_warn "rollback failed - $t is unchanged"; return 5; }
    mkdir -p "$MANIFEST_DIR" "$CHANGED_LIST" 2>/dev/null
    printf 'archive=%s\nfingerprint=%s\ninstalled_at=%s\nnote=rolled back\n' \
        "$(manifest_get "$t" archive)" "$(rp_dir_fingerprint "$live")" "$(rp_ts)" | rp_atomic_write "$(manifest_file "$t")"
    : > "$CHANGED_LIST/$(target_key "$t")"
    echo "  Done. Artwork gap-fill will run on the next sync."
    return 0
}

# =============================================================================
# Run
# =============================================================================
mkdir -p "$ART_STATE" "$MANIFEST_DIR" "$WORK_DIR" "$BACKUP_DIR" "$REMOTE_CACHE" 2>/dev/null

# Standalone runs take their own lock; in library mode all.sh already holds
# the one global lock, so taking another here would deadlock.
if [ "$CALLED_FROM_ALL" -eq 0 ] && [ "$CMD" != "status" ] && [ "$CMD" != "plan" ] && [ "$CMD" != "verify" ]; then
    ART_LOCK="$ART_STATE/.artwork.lock"
    FLOCK_BIN="$(command -v flock 2>/dev/null)"
    if [ -z "$FLOCK_BIN" ] && command -v brew >/dev/null 2>&1; then
        p="$(brew --prefix util-linux 2>/dev/null)"; [ -x "$p/bin/flock" ] && FLOCK_BIN="$p/bin/flock"
    fi
    if [ -n "$FLOCK_BIN" ]; then
        exec 8>"$ART_LOCK"
        "$FLOCK_BIN" -n 8 || rp_die "$RP_EXIT_CONFIG" "another artwork sync is already running"
    fi
fi

case "$CMD" in
    status)   cmd_status ;;
    plan)     cmd_plan ;;
    sync)     cmd_sync ;;
    verify)   cmd_verify ;;
    rollback) cmd_rollback "$ROLLBACK_NAME" ;;
esac
rc=$?
[ "$FAILED" -gt 0 ] && [ "$rc" -eq 0 ] && rc=5
exit "$rc"
