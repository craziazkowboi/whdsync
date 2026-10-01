#!/usr/bin/env bash
# retroplay-suite: 2026.10.01.2   (every script in the set must carry the same stamp)
# Remember where the user ran this from, before any cd: retroplay.conf is
# looked for there first (see lib.sh).
RP_INVOKED_FROM="${RP_INVOKED_FROM:-$PWD}"; export RP_INVOKED_FROM
#
# Purpose:
#   Last resort for games that have no artwork in any pack. For each one it
#   asks a command YOU choose (ARTWORK_FETCH_COMMAND) for a picture, converts
#   it to a real Amiga IFF ILBM matching the artwork already in use, and
#   installs it - into your own artwork pack and into the collection.
#
# Why a command of your own:
#   There is no reliable way to search the web from a shell script. You plug
#   in whatever you trust - an AI command line tool, an image search API, or
#   a folder of pictures you collected yourself. Nothing is downloaded unless
#   you set one up, and it is off by default.
#
#   The command is called as:   <your command> "<game name>" "<output file>"
#   It should write ONE image to <output file> (the name ends in .png; any
#   common format is accepted, it is read by content) and exit 0.
#   Exit non-zero if it found nothing; that game is simply reported.
#
# Usage:
#   artwork_fetch.sh --list FILE --variant retro_aga --dest DIR [options]
#     --list FILE      games with no artwork (one path per line, from merge)
#     --variant NAME   which collection these belong to
#     --dest DIR       that collection's folder
#     --limit N        stop after N games this run (default ARTWORK_FETCH_LIMIT)
#     --dry-run        show what would happen, fetch nothing
#     --help
#
# Safety:
#   * Never overwrites artwork that is already there.
#   * A fetched picture is checked to be an image before it is converted, and
#     the IFF is only installed once it has been written in full.
#   * Pictures are saved into your own pack (artwork/iGame_art/<Game>/), which
#     artwork updates never touch - so they are not lost on the next sync.
#
# Called by: all.sh, once the artwork packs have had their turn.

set -u -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1
[ -f "$SCRIPT_DIR/lib.sh" ] || { echo "ERROR: lib.sh is missing from $SCRIPT_DIR" >&2; exit 4; }
. "$SCRIPT_DIR/lib.sh"
rp_load_config
rp_banner "artwork_fetch.sh"

LIST=""; VARIANT=""; DEST=""; LIMIT=""; DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list)    rp_require_option_value "$1" "$#" "${2-}"; LIST="$2"; shift 2 ;;
        --variant) rp_require_option_value "$1" "$#" "${2-}"; VARIANT="$2"; shift 2 ;;
        --dest)    rp_require_option_value "$1" "$#" "${2-}"; DEST="$2"; shift 2 ;;
        --limit)   rp_require_option_value "$1" "$#" "${2-}"; LIMIT="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) rp_print_usage_error artwork_fetch.sh "unknown option: $1"; exit 4 ;;
    esac
done
[ -n "$LIST" ] && [ -n "$DEST" ] || { rp_print_usage_error artwork_fetch.sh "--list and --dest are required"; exit 4; }
LIMIT="${LIMIT:-$RP_ARTWORK_FETCH_LIMIT}"

[ "$RP_ARTWORK_FETCH" = "yes" ] || { rp_debug "artwork fetching is off (ARTWORK_FETCH)"; exit 2; }
[ -s "$LIST" ] || exit 2

if [ -z "$RP_ARTWORK_FETCH_COMMAND" ]; then
    rp_error "artwork search is on (ARTWORK_FETCH=yes) but no ARTWORK_FETCH_COMMAND is set"
    rp_info  "  There is nothing to ask. retroplay.conf.example shows what to put there."
    exit "$RP_EXIT_CONFIG"
fi
# ARTWORK_FETCH_COMMAND may carry arguments of its own, e.g.
#   ARTWORK_FETCH_COMMAND="python3 /home/pi/bin/findart.py --source mobygames"
# It is split on whitespace into an argv array - NOT run through eval and NOT
# through a shell, so nothing in it is expanded, substituted or globbed. Two
# consequences worth knowing, and both are documented in
# retroplay.conf.example: a path containing spaces will not survive the split
# (use a small wrapper script), and shell syntax such as pipes or && has no
# meaning here. Before, the whole string was used as a single executable name,
# so anything with an argument in it could not run at all.
FETCH_CMD=()
set -f                      # no globbing while the string is split
# shellcheck disable=SC2206  # deliberate word splitting; see above
FETCH_CMD=($RP_ARTWORK_FETCH_COMMAND)
set +f
if [ "${#FETCH_CMD[@]}" -eq 0 ]; then
    rp_error "ARTWORK_FETCH_COMMAND is set but empty once whitespace is removed"
    exit "$RP_EXIT_CONFIG"
fi
if ! command -v "${FETCH_CMD[0]}" >/dev/null 2>&1; then
    rp_error "ARTWORK_FETCH_COMMAND starts with '${FETCH_CMD[0]}', which is not an executable on PATH"
    rp_info  "  Full setting: $RP_ARTWORK_FETCH_COMMAND"
    rp_action "check ARTWORK_FETCH_COMMAND in retroplay.conf, or set ARTWORK_FETCH=no"
    exit "$RP_EXIT_CONFIG"
fi
# python3 + Pillow are what turn a downloaded picture into an Amiga IFF.
# Both checks keep their output to themselves: a missing module otherwise
# prints an ImportError traceback in front of the explanation.
if ! command -v python3 >/dev/null 2>&1; then
    rp_error "artwork search needs python3, which is not installed"
    rp_info  "  Linux:  sudo apt install python3 python3-pil"
    rp_info  "  macOS:  brew install python3 && pip3 install pillow"
    exit "$RP_EXIT_CONFIG"
fi
if ! python3 -c 'import PIL' >/dev/null 2>&1; then
    rp_error "artwork search needs the Pillow library for python3, which is not installed"
    rp_info  "  Linux:  sudo apt install python3-pil"
    rp_info  "  macOS:  pip3 install pillow"
    exit "$RP_EXIT_CONFIG"
fi

# A picture to copy the size and colour depth from: any artwork already
# installed for this variant, so what we add looks like the rest.
reference_iff() {
    local d
    for d in "$RP_ARTWORK_ROOT"/iGame_*/lores "$RP_ARTWORK_ROOT"/iGame_* ; do
        [ -d "$d" ] || continue
        find "$d" -name 'iGame.iff' -print 2>/dev/null | head -1 | grep . && return 0
    done
    return 1
}
REF="$(reference_iff || true)"
GEOM=(--width 320 --height 128 --planes 8)
[ -n "$REF" ] && GEOM=(--like "$REF")

rp_heading "Looking for artwork the packs don't have"
rp_info "  Games without artwork: $(grep -c . "$LIST")   (will try up to $LIMIT this run)"
[ -n "$REF" ] && rp_info "  Matching the size and colours of: ${REF#$RP_ARTWORK_ROOT/}"
rp_info "  Asking: $RP_ARTWORK_FETCH_COMMAND"
[ "$DRY" -eq 1 ] && rp_info "  (dry run - nothing will be fetched or written)"

FOUND=0; FAILED=0; TRIED=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/artfetch.XXXXXX")" || exit 1
# Purpose:       leave nothing of this run behind, however it ended.
# Assumptions:   TMP is this run's own scratch folder, made by mktemp -d.
# Side effects:  removes TMP. Artwork already installed is left in place: each
#                file is only copied once it has been converted whole.
cleanup_fetch() {
    local st=$?
    trap - EXIT INT TERM
    rp_reap_children            # the fetch command and whatever it launched
    rm -rf -- "$TMP"
    exit "$st"
}
trap cleanup_fetch EXIT
trap 'printf "\n"; rp_warn "interrupted - nothing further was changed"; exit 130' INT TERM

total="$(grep -c . "$LIST")"
[ "$total" -gt "$LIMIT" ] && total="$LIMIT"

while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ "$TRIED" -ge "$LIMIT" ] && break
    TRIED=$((TRIED + 1))
    game="${rel##*/}"
    game_dir="$DEST/$rel"
    [ -d "$game_dir" ] || game_dir="$DEST/${rel#*/}"
    rp_progress "$TRIED" "$total" "Artwork search"
    printf '\n  [%d/%d] %s: searching...' "$TRIED" "$total" "$game"

    if [ "$DRY" -eq 1 ]; then printf ' (dry run)\n'; continue; fi

    # .png, because most tools choose the format from the extension. Whatever
    # arrives is read by content, so a JPEG saved under this name is fine too.
    img="$TMP/$TRIED.png"
    if ! "${FETCH_CMD[@]}" "$game" "$img" > "$TMP/cmd.log" 2>&1 || [ ! -s "$img" ]; then
        printf ' nothing found\n'
        FAILED=$((FAILED + 1)); continue
    fi
    # Smaller than any real image header: a stub, a "not found" page saved as
    # a file, or a transfer that stopped early. Checked before Pillow, which
    # does not reliably reject every such file.
    if [ "$(rp_file_size "$img")" -lt 128 ] 2>/dev/null; then
        printf ' what came back was not an image (too small to be one) - ignored\n'
        FAILED=$((FAILED + 1)); continue
    fi
    # Make sure it really is a picture before doing anything with it.
    # Pillow's verify() raises for anything that is not a readable image; the
    # traceback is of no use to the person watching, so only the verdict is kept.
    if ! python3 -c 'import sys;from PIL import Image;Image.open(sys.argv[1]).verify()' "$img" >/dev/null 2>&1; then
        printf ' what came back was not an image - ignored\n'
        FAILED=$((FAILED + 1)); continue
    fi

    iff="$TMP/$TRIED.iff"
    if ! python3 "$SCRIPT_DIR/to_ilbm.py" "$img" "$iff" "${GEOM[@]}" > "$TMP/conv.log" 2>&1; then
        printf ' found a picture, but converting it to IFF failed\n'
        # The temp folder goes when this script ends, so the reason is copied
        # into the log that survives rather than pointed at where it was.
        sed 's/^/      /' "$TMP/conv.log" >> "$RP_LOG_ROOT/artwork_fetch.log" 2>/dev/null || true
        rp_verbose "      $(tail -1 "$TMP/conv.log" 2>/dev/null)"
        FAILED=$((FAILED + 1)); continue
    fi
    # 32 bytes is FORM + length + ILBM + the start of BMHD. Anything shorter
    # is not a file iGame can show, however the converter exited.
    if [ ! -s "$iff" ] || [ "$(rp_file_size "$iff")" -lt 32 ] 2>/dev/null; then
        printf ' converted, but the IFF came out empty - ignored\n'
        FAILED=$((FAILED + 1)); continue
    fi

    # 1) into your own artwork pack, which artwork updates never overwrite
    own="$RP_ARTWORK_ROOT/iGame_art/$game"
    mkdir -p "$own" 2>/dev/null
    cp -f "$iff" "$own/iGame.iff" 2>/dev/null
    # 2) into the collection, unless it somehow has artwork by now
    if [ -d "$game_dir" ] && [ ! -e "$game_dir/iGame.iff" ]; then
        cp -f "$iff" "$game_dir/iGame.iff" 2>/dev/null
    fi
    # Describe what was written, from the IFF's own BMHD header. This is
    # cosmetic: if the header cannot be read, say so rather than letting a
    # Python traceback land in the middle of the line.
    # Inputs:  $iff, a file to_ilbm.py has just written.
    # Outputs: "320x128, 256 colours", or "size unknown".
    # Side effects: none.
    geom="$(python3 - "$iff" 2>/dev/null << 'PY'
import sys, struct
with open(sys.argv[1], 'rb') as fh:
    d = fh.read(32)
if len(d) < 32:
    raise SystemExit(1)
w, h = struct.unpack('>HH', d[20:24])
print("%dx%d, %d colours" % (w, h, 1 << d[28]))
PY
)" || geom=""
    printf ' found - converted and installed (%s)\n' "${geom:-size unknown}"
    FOUND=$((FOUND + 1))
done < "$LIST"

echo
rp_info "  Artwork found and installed: $FOUND"
rp_info "  Still without artwork:       $FAILED"
[ "$FOUND" -gt 0 ] && rp_info "  Saved in artwork/iGame_art/ so later artwork updates keep them."
# Results go in a key=value file, never scraped back out of the text above:
# rewording a console message must not be able to change a reported figure.
# RP_RESULT_FILE is set by the caller (all.sh); the copy in the state folder
# is kept so --status and doctor.sh can see the last run.
_rp_write_result() {
    printf 'stage=artwork_fetch\nstatus=%s\nfound=%d\nfailed=%d\ntried=%d\n' \
        "$([ "$FOUND" -gt 0 ] && echo ok || echo none)" "$FOUND" "$FAILED" "$TRIED"
}
_rp_write_result > "$RP_STATE_DIR/artwork_fetch_last" 2>/dev/null
[ -n "${RP_RESULT_FILE:-}" ] && _rp_write_result > "$RP_RESULT_FILE" 2>/dev/null
[ "$FOUND" -gt 0 ] && exit 0
exit 2
