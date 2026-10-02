#!/usr/bin/env bash
# retroplay-suite: 2026.10.03.1   (every script in the set must carry the same stamp)
# Remember where the user ran this from, before any cd: retroplay.conf is
# looked for there first (see lib.sh).
RP_INVOKED_FROM="${RP_INVOKED_FROM:-$PWD}"; export RP_INVOKED_FROM
#
# Purpose: Checks the whole setup and explains how to fix anything wrong.
#   Changes nothing.  Options: --help.  Exit: 0 = fine, 1 = problems found.
# Run 'doctor.sh --help' for the authoritative, current list.
#
# Amiga Retroplay - setup check ("doctor")
#
# Checks everything the scripts need and reports what to fix, in plain terms.
# Changes nothing. Also available as: ./start.sh --doctor, or menu option 8.
# Exit status: 0 = no problems found, 1 = at least one problem.

set -u
DOCTOR_ARGS=("$@")
for _a in "$@"; do
    case "$_a" in
        -h|--help)
            echo "Usage: doctor.sh [--color=MODE]"
            echo "Checks the setup and explains how to fix any problems. Changes nothing."
            echo "  --color=MODE   auto (default), always or never. NO_COLOR is honoured."
            echo "Exit status: 0 = no problems, 1 = problems found."
            exit 0 ;;
    esac
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1
if [ ! -f "$SCRIPT_DIR/lib.sh" ]; then
    echo "PROBLEM: lib.sh is missing from $SCRIPT_DIR - download the complete set of scripts."
    exit 1
fi
. "$SCRIPT_DIR/lib.sh"
rp_load_config
for _a in ${DOCTOR_ARGS[@]+"${DOCTOR_ARGS[@]}"}; do
    rp_common_opt "$_a" >/dev/null && continue
    echo "Unknown option: $_a (try --help)" >&2; exit 4
done
unset _a
rp_banner "doctor.sh"

OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"
PROBLEMS=0; WARNINGS=0
# Colours come from lib.sh's single decision, so NO_COLOR, --color and "this
# is being piped into a file" are honoured here too. These were raw escape
# sequences, so a saved doctor report was full of control characters - and
# people save doctor reports precisely to send them to someone else.
good() { printf '  %s✓%s %s\n' "$RP_C_OK" "$RP_C_OFF" "$1"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf '  %s!%s %s\n' "$RP_C_WARN" "$RP_C_OFF" "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
prob() { PROBLEMS=$((PROBLEMS + 1)); printf '  %s✗%s %s\n' "$RP_C_ERR" "$RP_C_OFF" "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
head_() { printf '\n%s%s%s\n' "$RP_C_HEAD" "$1" "$RP_C_OFF"; }
install_hint() {   # <brew pkg> <apt pkg>
    if [ "$OS_TYPE" = "darwin" ]; then echo "Fix: brew install $1"; else echo "Fix: sudo apt install $2"; fi
}

echo "Amiga Retroplay - setup check"
echo "Folder: $SCRIPT_DIR"

head_ "Shell"
good "bash ${BASH_VERSION} running the scripts"
bash4=""
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then bash4="bash"; fi
for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -z "$bash4" ] && [ -x "$b" ] && "$b" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null && bash4="$b"
done
if [ -n "$bash4" ]; then good "bash 4 or newer available for merge.sh ($bash4)"
else prob "merge.sh needs bash 4 or newer and none was found" "$(install_hint bash bash)"; fi

suite_bad="$(rp_suite_mismatches)"
if [ -n "$suite_bad" ]; then
    prob "scripts from different versions (lib.sh is $RP_SUITE_VERSION):
$(printf '%s\n' "$suite_bad" | sed 's/^/      /')" \
         "Fix: copy the COMPLETE current set of scripts - all.sh refuses to run until they match"
else
    good "all scripts are from the same version ($RP_SUITE_VERSION)"
fi

head_ "Required tools"
for t in wget lha 7z unar; do
    if command -v "$t" >/dev/null 2>&1; then good "$t"
    else
        case "$t" in
            lha) prob "lha is missing" "$(install_hint lha lhasa)" ;;
            7z)  prob "7z is missing" "$(install_hint p7zip p7zip-full)" ;;
            *)   prob "$t is missing" "$(install_hint "$t" "$t")" ;;
        esac
    fi
done
if command -v unlzx >/dev/null 2>&1; then good "unlzx"
else prob "unlzx is missing (needed for .lzx archives)" "Build it from source: https://aminet.net/package/util/arc/unlzx"; fi

head_ "Optional tools"
flock_bin=""
command -v flock >/dev/null 2>&1 && flock_bin="$(command -v flock)"
if [ -z "$flock_bin" ] && [ "$OS_TYPE" = "darwin" ] && command -v brew >/dev/null 2>&1; then
    p="$(brew --prefix util-linux 2>/dev/null)"; [ -n "$p" ] && [ -x "$p/bin/flock" ] && flock_bin="$p/bin/flock"
fi
if [ -n "$flock_bin" ]; then good "flock (prevents overlapping runs): $flock_bin"
else warn "flock is missing - two runs could overlap" "$(install_hint util-linux util-linux)"; fi
# unzip is only used to test .zip downloads for damage; 7z covers the same
# job, so this is a nicety rather than a requirement.
if command -v unzip >/dev/null 2>&1; then good "unzip (integrity checks on .zip downloads)"
else warn "unzip is missing - .zip downloads are checked with 7z instead" "$(install_hint unzip unzip)"; fi
# python3 + Pillow only matter when the last-resort artwork search is on.
if [ "${RP_ARTWORK_FETCH:-no}" = "yes" ]; then
    if ! command -v python3 >/dev/null 2>&1; then
        prob "ARTWORK_FETCH=yes but python3 is not installed" "$(install_hint python3 python3)"
    elif ! python3 -c 'import PIL' >/dev/null 2>&1; then
        prob "ARTWORK_FETCH=yes but Pillow is not installed for python3" "$(install_hint python3-pil python3-pil)"
    else
        good "python3 with Pillow (makes IFF artwork for games the packs miss)"
    fi
else
    good "python3/Pillow not needed (ARTWORK_FETCH=no)"
fi
if [ "$RP_USE_DETOX" = "yes" ]; then
    if command -v detox >/dev/null 2>&1; then good "detox ($(detox -V 2>&1 | head -1))"
    else prob "USE_DETOX=yes but detox is not installed" "$(install_hint detox 'detox (or build 3.0.1 from source - start.sh offers to)')"; fi
else
    good "detox not needed (USE_DETOX=no)"
fi
if [ -n "$RP_NTFY_TOPIC" ] || [ -n "$RP_NOTIFY_EMAIL" ]; then
    if [ -n "$RP_NTFY_TOPIC" ]; then
        command -v curl >/dev/null 2>&1 && good "curl (for ntfy notifications)" || good "wget will be used for ntfy notifications"
    fi
    if [ -n "$RP_NOTIFY_EMAIL" ]; then
        command -v mail >/dev/null 2>&1 && good "mail (for email notifications)" || prob "NOTIFY_EMAIL is set but there's no 'mail' command" "$(install_hint mailutils mailutils)"
    fi
fi

if [ "$OS_TYPE" != "darwin" ]; then
    head_ "Locales (Linux)"
    # The same candidate lists extract.sh tries, in the same order, through the
    # same helper - so what doctor calls a problem is exactly what would
    # actually fail. It used to demand en_US.ISO-8859-1 by name and call
    # anything else a problem, so a machine with en_GB.ISO-8859-1 (which
    # extract.sh is perfectly happy with) was told to go and install locales.
    if _u="$(rp_pick_locale "${LANG:-}" en_AU.UTF-8 en_GB.UTF-8 en_US.UTF-8 C.UTF-8 C.utf8 2>/dev/null)"; then
        good "UTF-8 locale for extraction: $_u"
    else
        prob "no UTF-8 locale is installed" "Fix: sudo dpkg-reconfigure locales (tick C.UTF-8 or en_US.UTF-8), or add it to /etc/locale.gen and run sudo locale-gen"
    fi
    if _l="$(rp_pick_locale en_AU.ISO-8859-1 en_GB.ISO-8859-1 en_US.ISO-8859-1 2>/dev/null)"; then
        good "Latin-1 locale for old archive filenames: $_l"
    else
        warn "no ISO-8859-1 locale is installed - a few old archives may extract with mangled filenames" \
             "Fix: sudo dpkg-reconfigure locales (tick en_US.ISO-8859-1), or add it to /etc/locale.gen and run sudo locale-gen"
    fi
    unset _u _l
fi

head_ "Settings (retroplay.conf)"
if [ -f "$RP_CONF_FILE" ]; then good "found retroplay.conf"
else good "no retroplay.conf - using built-in defaults (see retroplay.conf.example)"; fi
if [ -n "$RP_CONFIG_WARNINGS" ]; then
    while IFS= read -r w; do [ -n "$w" ] && warn "$w"; done <<< "$RP_CONFIG_WARNINGS"
fi
good "variants: $RP_VARIANTS   filesystem: $RP_FILESYSTEM   output folder: $RP_OUTPUT_ROOT"

head_ "Artwork"
found_sets=""
for d in "$RP_ARTWORK_ROOT"/[iI][gG][aA][mM][eE]_*; do
    [ -d "$d" ] || continue
    n="${d##*/}"; secs=""
    # Sections may be directly inside (iGame_RTG/Covers) or under a flavour
    # folder (iGame_AGA/lores/Covers, iGame_AGA/laced/Covers).
    for s in Covers Screens Titles; do
        for base in "$d" "$d/lores" "$d/laced"; do
            if [ -d "$base/$s" ] || [ -d "$base/${s%s}" ]; then
                case " $secs " in *" $s "*) ;; *) secs="$secs $s" ;; esac
            fi
        done
    done
    for fl in lores laced; do [ -d "$d/$fl" ] && secs="$secs ($fl)"; done
    found_sets="$found_sets ${n#*_}"
    setkey="$(printf '%s' "${n#*_}" | tr '[:lower:]' '[:upper:]')"
    case " $(printf '%s' "$RP_STRUCTURED_ART_SETS" | tr '[:lower:]' '[:upper:]') " in
        *" $setkey "*)
            if [ -n "$secs" ]; then good "$n:$secs"
            else warn "$n has no Covers/Screens/Titles folders - it won't be used" "Get the artwork with: ./start.sh --artwork-sync"; fi ;;
        *)
            cnt="$(find "$d" -type f -iname 'igame.iff' 2>/dev/null | grep -c . || true)"
            if [ "$cnt" -gt 0 ]; then good "$n: $cnt artwork folder(s), matched at any depth"
            else warn "$n contains no iGame.iff files - it won't provide any artwork"; fi ;;
    esac
done
[ -z "$found_sets" ] && prob "no iGame_* artwork folders in $RP_ARTWORK_ROOT" "Get them with: ./start.sh --artwork-sync   (see 'Artwork directory layout' in README.md)"
# Which variants have no artwork, asked of lib.sh rather than guessed from the
# variant's name. The laced flavours live INSIDE their pack (iGame_AGA/laced),
# so building the folder name out of the variant name looked for an
# iGame_AGA_LACED that has never existed, and warned about artwork that was
# sitting right there.
for v in $RP_VARIANTS; do
    if _adir="$(rp_artwork_dir_for "$v" 2>/dev/null)"; then
        if rp_artwork_installed "$v"; then
            good "$v: artwork installed ($_adir)"
        else
            warn "no artwork in $_adir for the '$v' variant - it will only get fallback artwork" \
                 "Fix: ./start.sh --artwork-sync --for $v"
        fi
    else
        # A custom --set style variant: its folder is iGame_<NAME>.
        want="$(printf '%s' "$v" | tr '[:lower:]-' '[:upper:]_')"
        printf '%s\n' $found_sets | tr '[:lower:]' '[:upper:]' | grep -qx "$want" || \
            warn "no iGame_$want folder for the '$v' variant - it will only get fallback artwork"
    fi
done
unset _adir
# In artwork/, where artwork_sync.sh installs it. Looking beside the scripts
# was the pre-migration location, so an installed TinyLauncher was never
# reported. The old spot still counts for anyone who has not migrated.
if [ -d "$RP_ARTWORK_ROOT/TinyLauncher" ]; then good "TinyLauncher (last-resort screenshots)"
elif [ -d "$SCRIPT_DIR/TinyLauncher" ]; then warn "TinyLauncher is still beside the scripts" "It will be moved into $RP_ARTWORK_ROOT/ on the next run"
fi

head_ "Artwork packs (downloaded)"
if [ -x "$SCRIPT_DIR/artwork_sync.sh" ]; then
    # rp_artwork_installed is the one rule for "is this pack here", shared with
    # update.sh and all.sh. The copy that used to live here mapped AGA_Laced to
    # iGame_AGA_Laced - a folder that does not exist - and so reported the
    # laced packs as missing however many times they had been downloaded.
    _n_inst=0; _n_missing=""
    for _v in $RP_ARTWORK_PACKS; do
        if rp_artwork_installed "$_v"; then _n_inst=$((_n_inst + 1)); else _n_missing="$_n_missing $_v"; fi
    done
    [ "$_n_inst" -gt 0 ] && good "$_n_inst of the configured packs are installed ($RP_ARTWORK_PACKS)"
    [ -n "$_n_missing" ] && warn "no artwork yet for:$_n_missing" "Fix: ./start.sh --artwork-sync   (or ./start.sh --artwork-plan to see what it would fetch)"
    [ -d "$RP_ARTWORK_CACHE" ] && good "archive cache: ${RP_ARTWORK_CACHE#"$RP_BASE_DIR"/} ($(( $(rp_du_kb "$RP_ARTWORK_CACHE") / 1024 )) MB)"
    good "source: $RP_ARTWORK_SOURCE_URL (checked at most every ${RP_ARTWORK_CHECK_INTERVAL_HOURS}h when ARTWORK_SYNC=auto; currently $RP_ARTWORK_SYNC)"
else
    warn "artwork_sync.sh is missing - artwork can't be downloaded automatically"
fi

if [ "$RP_ARTWORK_FETCH" = "yes" ]; then
    if [ -z "$RP_ARTWORK_FETCH_COMMAND" ]; then
        prob "ARTWORK_FETCH=yes but no ARTWORK_FETCH_COMMAND is set" "Set the command that finds a picture, or turn ARTWORK_FETCH off"
    elif ! command -v "${RP_ARTWORK_FETCH_COMMAND%% *}" >/dev/null 2>&1 && [ ! -x "${RP_ARTWORK_FETCH_COMMAND%% *}" ]; then
        prob "ARTWORK_FETCH_COMMAND is not runnable: $RP_ARTWORK_FETCH_COMMAND" "Check the path, and that it is executable"
    elif ! python3 -c 'import PIL' 2>/dev/null; then
        prob "artwork search needs python3 with Pillow to write IFF files" "Fix: sudo apt install python3-pil   (macOS: pip3 install pillow)"
    else
        good "artwork search is on, using ${RP_ARTWORK_FETCH_COMMAND%% *} (up to $RP_ARTWORK_FETCH_LIMIT per run)"
    fi
else
    good "artwork search for games the packs miss: off (ARTWORK_FETCH)"
fi

head_ "Disk space"
# (Never create the output folder here: if it's on a USB drive that isn't
# mounted, that would create it on the SD card instead.)
if ! guard_msg="$(rp_check_output_root dry 2>&1)"; then
    prob "output folder not available: $guard_msg" "Connect/mount the drive, or check OUTPUT_ROOT in retroplay.conf"
elif [ -w "$RP_OUTPUT_ROOT" ]; then good "output folder is available and writable: $RP_OUTPUT_ROOT"
else prob "cannot write to the output folder $RP_OUTPUT_ROOT" "Check its permissions"; fi
# Speed hint: on a Raspberry Pi, an SD card is by far the slowest place to build.
case "$(df -P "$RP_OUTPUT_ROOT" 2>/dev/null | awk 'NR==2 {print $1}')" in
    */mmcblk*) good "tip: builds run far faster on a USB SSD - set OUTPUT_ROOT in retroplay.conf to its mount point" ;;
esac
# Against the downloads folder. These were bare relative names, measured from
# the scripts' own directory, so the answer was always "downloads use 0 MB"
# and the rebuild-space estimate below was always zero.
free_kb="$(rp_free_kb "$RP_OUTPUT_ROOT")"
arch_kb="$(rp_du_kb "$RP_DOWNLOAD_ROOT/HD_Loaders" "$RP_DOWNLOAD_ROOT/JST" "$RP_DOWNLOAD_ROOT/WHDLoad")"
if [ -n "$free_kb" ]; then
    good "$((free_kb / 1024)) MB free; downloads use $((arch_kb / 1024)) MB"
    if [ "${RP_LOG_RETENTION_DAYS:-1}" -gt 0 ]; then good "logs are deleted after $RP_LOG_RETENTION_DAYS day(s) (LOG_RETENTION_DAYS)"
    else good "logs are kept for ever (LOG_RETENTION_DAYS=0)"; fi
    need=$((arch_kb * RP_SPACE_FACTOR * 2 / 1024))
    if [ "$arch_kb" -gt 0 ] && [ $((free_kb / 1024)) -lt "$need" ]; then
        warn "a full rebuild may need about $need MB free" "Point OUTPUT_ROOT at a bigger drive (a USB SSD is also much faster than an SD card)"
    fi
fi
[ -d "$RP_DOWNLOAD_ROOT/old" ] && good "quarantined old archives (downloads/old/): $(( $(rp_du_kb "$RP_DOWNLOAD_ROOT/old") / 1024 )) MB, kept $RP_OLD_ARCHIVE_DAYS days"

head_ "Builds"
for v in $RP_VARIANTS; do
    # build/retro_aga, not <output root>/retro_aga: this asked about a path
    # that has not existed since the folder layout changed, so every finished
    # collection was reported as "not built yet".
    key="retro_$(rp_variant_suffix "$v")"; dest="$RP_BUILD_ROOT/$key"
    q="$(rp_queue_count "$key")"
    case "$(rp_build_state "$key" "$dest")" in
        incomplete) warn "$key: a full build was interrupted - the next run will redo it" ;;
        fresh)      good "$key: not built yet (the next run will build it)" ;;
        ready)      if [ "$q" -gt 0 ]; then warn "$key: $q downloaded archive(s) waiting to be processed" "They'll be processed on the next run (or now: ./all.sh --skip-update)"
                    else good "$key: built and up to date"; fi ;;
    esac
done

# Collections or batches with anything but WHDLoad/HD_Loaders/JST at the top
# (e.g. a Users/... folder from the path bug fixed in this version).
bad_layout=""
for d in "$RP_BUILD_ROOT"/retro_* "$RP_BUILD_ROOT"/new_*/*; do
    [ -d "$d" ] || continue
    e="$(rp_layout_problems "$d" | head -1)"
    [ -n "$e" ] && bad_layout="$bad_layout
      ${d#"$RP_BUILD_ROOT"/}/$e"
done
if [ -n "$bad_layout" ]; then
    prob "folders in the wrong place (should only hold WHDLoad, HD_Loaders, JST):$bad_layout" \
         "Fix: just run ./all.sh - it rebuilds those retro_* folders from your archives and removes the broken new_* batches"
else
    good "all retro_* and new_* folders have the correct layout"
fi

head_ "Nightly run"
# Would the nightly run find the tools? cron starts with a bare PATH; lib.sh
# adds back the PATH remembered from interactive runs. Simulated here with
# stdin from /dev/null, so the check itself can't overwrite that memory.
cron_missing=""
for t in wget lha unlzx 7z unar; do
    command -v "$t" >/dev/null 2>&1 || continue          # already reported above
    if ! env -i HOME="${HOME:-/}" PATH="/usr/bin:/bin" "$BASH" -c \
         'SCRIPT_DIR="$1"; . "$1/lib.sh" >/dev/null 2>&1; command -v "$2" >/dev/null' \
         _ "$SCRIPT_DIR" "$t" < /dev/null; then
        cron_missing="$cron_missing $t"
    fi
done
if [ -n "$cron_missing" ]; then
    prob "cron would NOT find:$cron_missing (they work here, but cron starts with a minimal PATH)" \
         "Fix: run ./install_cron.sh from this terminal - it remembers this PATH for the nightly run"
else
    good "the nightly run will find all the tools, despite cron's minimal PATH"
fi
# Both marker names, matched as plain text (grep -F), exactly as
# install_cron.sh writes and removes them. Matching only the older marker
# meant a schedule installed by a current version read as "not installed".
line=""
if command -v crontab >/dev/null 2>&1; then
    for _m in retroplay-all-sh whdsync-all-sh; do
        [ -n "$line" ] && break
        line="$(crontab -l 2>/dev/null | grep -F "$_m" | head -1)"
    done
    unset _m
fi
if [ -n "$line" ]; then
    good "installed: ${line%%#*}"
    # The time comes out of the crontab. install_cron.sh --time can set any
    # hour, so "2am" was simply wrong for anyone who had changed it.
    _min="$(printf '%s' "$line" | awk '{print $1}')"
    _hr="$(printf '%s' "$line" | awk '{print $2}')"
    case "$_min$_hr" in
        ''|*[!0-9]*) ;;
        *) good "$(printf 'runs every night at %02d:%02d' "$((10#$_hr))" "$((10#$_min))")" ;;
    esac
    unset _min _hr
    case "$line" in *--cron*) ;; *) warn "the cron entry is from an older version" "Fix: re-run ./install_cron.sh (adds --cron: full PATH and log rotation)";; esac
else
    good "not installed (optional): ./install_cron.sh sets up a nightly run (2am unless you pass --time)"
fi

head_ "On the Amiga"
echo "  Reminder: PFS partitions must allow long filenames, or long archive names can"
echo "  corrupt the partition. On the Amiga:  setfnsize <drive:> 107"

echo
if [ "$PROBLEMS" -eq 0 ]; then
    printf '%sNo problems found%s%s.\n' "$RP_C_OK" "$RP_C_OFF" "$( [ "$WARNINGS" -gt 0 ] && echo " ($WARNINGS warning(s) above)")"
    exit 0
fi
printf '%s%d problem(s)%s and %d warning(s) found - see the fixes above.\n' "$RP_C_ERR" "$PROBLEMS" "$RP_C_OFF" "$WARNINGS"
exit 1
