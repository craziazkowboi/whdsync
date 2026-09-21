#!/usr/bin/env bash
# Amiga Retroplay - setup check ("doctor")
#
# Checks everything the scripts need and reports what to fix, in plain terms.
# Changes nothing. Also available as: ./start.sh --doctor, or menu option 8.
# Exit status: 0 = no problems found, 1 = at least one problem.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1
if [ ! -f "$SCRIPT_DIR/lib.sh" ]; then
    echo "PROBLEM: lib.sh is missing from $SCRIPT_DIR - download the complete set of scripts."
    exit 1
fi
. "$SCRIPT_DIR/lib.sh"
rp_load_config

OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"
PROBLEMS=0; WARNINGS=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf '  \033[33m!\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
prob() { PROBLEMS=$((PROBLEMS + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
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
else prob "merge.sh needs bash 4 or newer and none was found" "Fix: brew install bash"; fi

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
    locs="$(locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '-')"
    for l in c.utf8 en_us.iso88591; do
        if printf '%s\n' "$locs" | grep -qx "$l"; then good "$l"
        else prob "locale $l is not installed" "Fix: sudo dpkg-reconfigure locales (tick it), or add it to /etc/locale.gen and run sudo locale-gen"; fi
    done
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
for d in "$SCRIPT_DIR"/[iI][gG][aA][mM][eE]_*; do
    [ -d "$d" ] || continue
    n="${d##*/}"; secs=""
    for s in Covers Screens Titles; do [ -d "$d/$s" ] || [ -d "$d/${s%s}" ] && secs="$secs $s"; done
    found_sets="$found_sets ${n#*_}"
    setkey="$(printf '%s' "${n#*_}" | tr '[:lower:]' '[:upper:]')"
    case " $(printf '%s' "$RP_STRUCTURED_ART_SETS" | tr '[:lower:]' '[:upper:]') " in
        *" $setkey "*)
            if [ -n "$secs" ]; then good "$n:$secs"
            else warn "$n has no Covers/Screens/Titles folders - it won't be used" "This pack is only matched by the standard layout (STRUCTURED_ART_SETS)"; fi ;;
        *)
            cnt="$(find "$d" -type f -iname 'igame.iff' 2>/dev/null | grep -c . || true)"
            if [ "$cnt" -gt 0 ]; then good "$n: $cnt artwork folder(s), matched at any depth"
            else warn "$n contains no iGame.iff files - it won't provide any artwork"; fi ;;
    esac
done
[ -z "$found_sets" ] && prob "no iGame_* artwork folders found next to the scripts" "See 'Artwork directory layout' in README.md"
for v in $RP_VARIANTS; do
    want="$(printf '%s' "$v" | tr '[:lower:]-' '[:upper:]_')"
    printf '%s\n' $found_sets | tr '[:lower:]' '[:upper:]' | grep -qx "$want" || \
        warn "no iGame_$want folder for the '$v' variant - it will only get fallback artwork"
done
[ -d "$SCRIPT_DIR/TinyLauncher" ] && good "TinyLauncher (last-resort screenshots)"

head_ "Disk space"
mkdir -p "$RP_OUTPUT_ROOT" 2>/dev/null
if [ -w "$RP_OUTPUT_ROOT" ]; then good "output folder is writable: $RP_OUTPUT_ROOT"
else prob "cannot write to the output folder $RP_OUTPUT_ROOT" "Check OUTPUT_ROOT in retroplay.conf, and that the drive is mounted"; fi
free_kb="$(rp_free_kb "$RP_OUTPUT_ROOT")"; arch_kb="$(rp_du_kb HD_Loaders JST WHDLoad)"
if [ -n "$free_kb" ]; then
    good "$((free_kb / 1024)) MB free; downloaded archives use $((arch_kb / 1024)) MB"
    need=$((arch_kb * RP_SPACE_FACTOR * 2 / 1024))
    if [ "$arch_kb" -gt 0 ] && [ $((free_kb / 1024)) -lt "$need" ]; then
        warn "a full rebuild may need about $need MB free" "Point OUTPUT_ROOT at a bigger drive (a USB SSD is also much faster than an SD card)"
    fi
fi
[ -d old ] && good "quarantined old archives (old/): $(( $(rp_du_kb old) / 1024 )) MB, kept $RP_OLD_ARCHIVE_DAYS days"

head_ "Builds"
for v in $RP_VARIANTS; do
    key="retro_$(rp_variant_suffix "$v")"; dest="$RP_OUTPUT_ROOT/$key"
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
for d in "$RP_OUTPUT_ROOT"/retro_* "$RP_OUTPUT_ROOT"/new_*/*; do
    [ -d "$d" ] || continue
    for e in "$d"/*; do
        [ -e "$e" ] || continue
        case "${e##*/}" in WHDLoad|HD_Loaders|JST) ;; *) bad_layout="$bad_layout
      ${d#"$RP_OUTPUT_ROOT"/}/${e##*/}"; break ;; esac
    done
done
if [ -n "$bad_layout" ]; then
    prob "folders in the wrong place (should only hold WHDLoad, HD_Loaders, JST):$bad_layout" \
         "Fix: ./all.sh --rebuild  (rebuilds retro_* correctly), then delete the new_* batch folders listed"
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
if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "retroplay-all-sh"; then
    line="$(crontab -l 2>/dev/null | grep "retroplay-all-sh" | head -1)"
    good "installed: ${line%%#*}"
    case "$line" in *--cron*) ;; *) warn "the cron entry is from an older version" "Fix: re-run ./install_cron.sh (adds --cron: full PATH and log rotation)";; esac
else
    good "not installed (optional): ./install_cron.sh sets up a 2am nightly run"
fi

head_ "On the Amiga"
echo "  Reminder: PFS partitions must allow long filenames, or long archive names can"
echo "  corrupt the partition. On the Amiga:  setfnsize <drive:> 107"

echo
if [ "$PROBLEMS" -eq 0 ]; then
    printf '\033[32mNo problems found\033[0m%s.\n' "$( [ "$WARNINGS" -gt 0 ] && echo " ($WARNINGS warning(s) above)")"
    exit 0
fi
printf '\033[31m%d problem(s)\033[0m and %d warning(s) found - see the fixes above.\n' "$PROBLEMS" "$WARNINGS"
exit 1
