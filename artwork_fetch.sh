#!/usr/bin/env bash
# retroplay-suite: 2026.09.22   (every script in the set must carry the same stamp)
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
    echo "Artwork search is on (ARTWORK_FETCH=yes) but no ARTWORK_FETCH_COMMAND is set,"
    echo "so there is nothing to ask. See retroplay.conf.example for what to put there."
    exit 4
fi
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import PIL' 2>/dev/null; then
    echo "Artwork search needs python3 with Pillow to make the IFF files."
    echo "  Linux:  sudo apt install python3-pil"
    echo "  macOS:  pip3 install pillow"
    exit 4
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

echo
echo "===== Looking for artwork the packs don't have ====="
echo "  Games without artwork: $(grep -c . "$LIST")   (will try up to $LIMIT this run)"
[ -n "$REF" ] && echo "  Matching the size and colours of: ${REF#$RP_ARTWORK_ROOT/}"
echo "  Asking: $RP_ARTWORK_FETCH_COMMAND"
[ "$DRY" -eq 1 ] && echo "  (dry run - nothing will be fetched or written)"

FOUND=0; FAILED=0; TRIED=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/artfetch.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
trap 'echo; echo "Interrupted - nothing further was changed."; exit 130' INT TERM

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
    if ! "$RP_ARTWORK_FETCH_COMMAND" "$game" "$img" > "$TMP/cmd.log" 2>&1 || [ ! -s "$img" ]; then
        printf ' nothing found\n'
        FAILED=$((FAILED + 1)); continue
    fi
    # Make sure it really is a picture before doing anything with it.
    if ! python3 -c 'import sys;from PIL import Image;Image.open(sys.argv[1]).verify()' "$img" 2>/dev/null; then
        printf ' what came back was not an image - ignored\n'
        FAILED=$((FAILED + 1)); continue
    fi

    iff="$TMP/$TRIED.iff"
    if ! python3 "$SCRIPT_DIR/to_ilbm.py" "$img" "$iff" "${GEOM[@]}" > "$TMP/conv.log" 2>&1; then
        printf ' found a picture, but converting it to IFF failed (see %s)\n' "${TMP##*/}/conv.log"
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
    printf ' found - converted and installed (%s)\n' "$(python3 - "$iff" << 'PY'
import sys, struct
d = open(sys.argv[1], 'rb').read(32)
w, h = struct.unpack('>HH', d[20:24]); print("%dx%d, %d colours" % (w, h, 1 << d[28]))
PY
)"
    FOUND=$((FOUND + 1))
done < "$LIST"

echo
echo "  Artwork found and installed: $FOUND"
echo "  Still without artwork:       $FAILED"
[ "$FOUND" -gt 0 ] && echo "  Saved in artwork/iGame_art/ so later artwork updates keep them."
printf 'ARTWORK_FETCH_RESULT found=%d failed=%d tried=%d\n' "$FOUND" "$FAILED" "$TRIED" > "$RP_STATE_DIR/artwork_fetch_last" 2>/dev/null
[ "$FOUND" -gt 0 ] && exit 0
exit 2
