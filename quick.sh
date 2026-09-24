#!/usr/bin/env bash
# retroplay-suite: 2026.09.22   (every script in the set must carry the same stamp)
#
# Purpose: Processes only what was downloaded last time into a preview folder.
#   Options: --aga --ecs --rtg --aga-laced --ecs-laced --set NAME -d/--dest DIR
#            --art LIST --demo-art LIST --skip-update --no-detox --help
# Run 'quick.sh --help' for the authoritative, current list.
#
set -o pipefail

# Amiga Retroplay Quick Update & Process Script
# This script downloads new archives, extracts them to a "new" directory,
# merges artwork, and sorts the files - all in one go!
#
# WHY A SEPARATE "new" STAGING DIRECTORY: unlike start.sh --auto (which
# extracts/merges/sorts your WHOLE collection every time), quick.sh only
# processes files that update.sh finds are genuinely new since last run,
# and keeps them isolated under ./new/ rather than mixing them straight
# into your main ./retro/ collection. That way a bad run only affects the
# small "new" batch, and you can review it before folding it into your
# main collection yourself.
#
# THE FIVE STEPS (each calls one of the other scripts, except step 2 which
# is just a directory creation): download -> stage -> extract -> merge
# artwork -> sort. See the "Step N of 5" markers below for each one.


# Color codes
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || { echo "ERROR: cannot cd to script directory: $SCRIPT_DIR" >&2; exit 1; }
[ -f "$SCRIPT_DIR/lib.sh" ] || { echo "ERROR: lib.sh is missing from $SCRIPT_DIR" >&2; exit 1; }
. "$SCRIPT_DIR/lib.sh"
rp_load_config
NEWDIR="$SCRIPT_DIR/new"
UPDATE_LOG="$RP_LOG_ROOT/update.log"
DEST_OPT=""      # holds just the path, if the user gave one
MODE_OPT=""      # holds --ecs / --aga / --rtg, if the user gave one (forwarded to merge.sh)
SET_OPT=""       # holds --set NAME, if the user gave one (forwarded to merge.sh)
ART_ORDER_OPT=""     # holds --art ORDER, if given (forwarded to merge.sh)
DEMO_ART_OPT=""      # holds --demo-art ORDER, if given (forwarded to merge.sh)
SKIP_UPDATE=0        # holds --skip-update - skip step 1 entirely and reuse
                     # the existing update.log (used when a caller like
                     # start.sh has already run update.sh itself this run)
NO_DETOX=0           # holds --no-detox, if given (forwarded to sort.sh)

# List whatever iGame_* artwork sets exist here, for the help text and error messages.
list_igame_sets() {
  local sets=() d base
  shopt -s nullglob
  for d in "$SCRIPT_DIR"/iGame_*/; do
    d="${d%/}"
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    sets+=("${base#iGame_}")
  done
  shopt -u nullglob
  printf '%s\n' "${sets[@]}"
}

print_usage() {
  echo -e "${BOLD}Amiga Retroplay Quick Processor v${RP_SUITE_VERSION}${NC}"
  echo
  echo -e "${BOLD}Usage:${NC} $0 [--ecs|--aga|--rtg|--ecs-laced|--aga-laced|--set NAME] [-d DEST | --dest DEST] [-h|--help]"
  echo
  echo -e "${BOLD}What it does:${NC}"
  echo "  Runs update.sh -> extract.sh -> merge.sh -> sort.sh in sequence,"
  echo "  processing only the files newly downloaded by update.sh into a"
  echo "  local 'new' directory instead of touching your main collection."
  echo
  echo -e "${BOLD}Options:${NC}"
  echo "  --ecs            Shortcut for --set ECS when merging artwork."
  echo "  --aga            Shortcut for --set AGA when merging artwork."
  echo "  --rtg            Shortcut for --set RTG when merging artwork."
  echo "  --ecs-laced      Shortcut for --set ECS_LACED (matches iGame_ECS_Laced)."
  echo "  --aga-laced      Shortcut for --set AGA_LACED (matches iGame_AGA_Laced)."
  echo "  --set NAME       Use the iGame_NAME artwork directory (case-insensitive)."
  echo "                   Any directory named iGame_<NAME> next to these scripts"
  echo "                   works, not just ECS/AGA/RTG."
  echo "                   (--ecs/--aga/--rtg/--set are mutually exclusive; the last one wins.)"
  echo "  --art ORDER      Merge priority order for non-demos, e.g. \"Screens,Covers,Titles\"."
  echo "  --demo-art ORDER Merge priority order for demos, e.g. \"Titles,Screens,Covers\"."
  echo "  --no-detox       Skip the detox pre-clean step in sort.sh, even if detox is installed."
  echo "  -d, --dest DEST  Custom destination directory to pass through to merge.sh"
  echo "                   and sort.sh. If omitted, files stay under:"
  echo "                     $NEWDIR"
  echo "  -h, --help       Show this help message and exit."
  echo
  local found_sets
  found_sets="$(list_igame_sets)"
  if [ -n "$found_sets" ]; then
    echo -e "${BOLD}Artwork sets found here:${NC} $(echo "$found_sets" | tr '\n' ' ')"
  else
    echo -e "${YELLOW}No iGame_* artwork directories found here.${NC}"
  fi
  echo
  echo -e "${BOLD}Examples:${NC}"
  echo "  $0 --aga"
  echo "  $0 --set CD32 -d /media/usbdrive/retro-new"
}

# --- Parse CLI Options for artwork set / destination ---
while [[ $# -gt 0 ]]; do
  opt_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$opt_lc" in
    --ecs|--aga|--rtg|--ecs-laced|--aga-laced)
      MODE_OPT="$opt_lc"
      shift
      ;;
    --skip-update)
      SKIP_UPDATE=1
      shift
      ;;
    --set)
      rp_require_option_value "$1" "$#" "${2-}"
      if [ -z "${2:-}" ]; then
        echo -e "${RED}Error: --set requires a NAME argument (matching an iGame_NAME directory)${NC}" >&2
        exit 1
      fi
      SET_OPT="$2"
      shift 2
      ;;
    --art)
      rp_require_option_value "$1" "$#" "${2-}"
      if [ -z "${2:-}" ]; then
        echo -e "${RED}Error: --art requires an ORDER argument, e.g. \"Screens,Covers,Titles\"${NC}" >&2
        exit 1
      fi
      ART_ORDER_OPT="$2"
      shift 2
      ;;
    --demo-art)
      rp_require_option_value "$1" "$#" "${2-}"
      if [ -z "${2:-}" ]; then
        echo -e "${RED}Error: --demo-art requires an ORDER argument, e.g. \"Titles,Screens,Covers\"${NC}" >&2
        exit 1
      fi
      DEMO_ART_OPT="$2"
      shift 2
      ;;
    --no-detox)
      NO_DETOX=1
      shift
      ;;
    -d|--dest)
      rp_require_option_value "$1" "$#" "${2-}"
      if [ -z "${2:-}" ]; then
        echo -e "${RED}Error: $1 requires a directory argument${NC}" >&2
        exit 1
      fi
      DEST_OPT="$2"
      shift 2
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}" >&2
      echo "Run '$0 --help' for usage." >&2
      exit 4
      ;;
  esac
done
unset opt_lc

# If the caller gave --dest/-d, that's where extract/merge/sort should all
# actually work - NEWDIR previously stayed hardcoded to "$SCRIPT_DIR/new"
# regardless of --dest, so extract.sh and merge.sh silently ignored a
# custom destination entirely (only the final sort step tried to honor
# it, by which point extract/merge had already put everything in the
# default "new" directory instead, leaving sort with nothing to do there).
#
# A relative --dest is resolved against SCRIPT_DIR, not just used as-is:
# this script later does `cd "$temp_extract_dir"` before calling
# extract.sh, so a bare relative path passed through unchanged would
# resolve against THAT temporary directory instead of where the user
# meant it, and everything extracted would vanish when the temp
# directory is cleaned up afterward - a real data-loss trap, not just a
# cosmetic path issue.
if [ -n "$DEST_OPT" ]; then
    case "$DEST_OPT" in
        /*) NEWDIR="$DEST_OPT" ;;
        *)  NEWDIR="$SCRIPT_DIR/$DEST_OPT" ;;
    esac
fi

echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}Amiga Retroplay Quick Processor v${RP_SUITE_VERSION}${NC}"
echo -e "${BOLD}========================================${NC}"
echo

# Check required scripts exist
for script in update.sh extract.sh merge.sh sort.sh; do
  if [ ! -f "$SCRIPT_DIR/$script" ]; then
    echo -e "${RED}Error: Required script not found: $script${NC}"
    echo "Please ensure all scripts are in the same directory."
    exit 1
  fi
done

# Step 1: Run update.sh
echo -e "${GREEN}Step 1 of 5: Downloading new archives...${NC}"

if [ "$SKIP_UPDATE" -eq 1 ]; then
  echo -e "${BLUE}Skipping update.sh - already checked by the caller this run.${NC}"
else
  echo -e "${BLUE}Running update.sh${NC}"
  echo

  bash "$SCRIPT_DIR/update.sh"
  update_exit=$?
  # update.sh signals its outcome via exit code: 3 = a wget error occurred
  # (stop, don't trust anything below), 2 = nothing new (nothing to do,
  # not an error), 0 = ran fine. Anything else is a genuine unexpected
  # failure.
  if [ "$update_exit" -eq 3 ]; then
    echo -e "${RED}Error: update.sh reported a wget error - stopping.${NC}"
    exit 1
  elif [ "$update_exit" -eq 2 ]; then
    echo -e "${YELLOW}No new archives available. Nothing to process.${NC}"
    exit 0
  elif [ "$update_exit" -ne 0 ]; then
    echo -e "${RED}Error: update.sh failed with exit code $update_exit${NC}"
    exit 1
  fi
fi

# Check if update.log exists and has new files
if [ ! -f "$UPDATE_LOG" ]; then
  echo -e "${YELLOW}No update.log found. No new files downloaded.${NC}"
  exit 0
fi

new_file_count=$(grep -c "^" "$UPDATE_LOG" 2>/dev/null); new_file_count="${new_file_count:-0}"   # (grep -c prints 0 itself on no match)
if [ "$new_file_count" -eq 0 ]; then
  echo -e "${YELLOW}No new files downloaded. Nothing to process.${NC}"
  exit 0
fi

echo
echo -e "${GREEN}Found $new_file_count new files to process.${NC}"
echo

# Step 2: Create "new" directory
echo -e "${GREEN}Step 2 of 5: Creating 'new' directory...${NC}"
mkdir -p "$NEWDIR"
echo -e "Created: ${NEWDIR}"
echo

# Step 3: Extract only new archives to "new" directory
echo -e "${GREEN}Step 3 of 5: Extracting new archives to 'new' directory...${NC}"
echo

temp_extract_dir="$SCRIPT_DIR/.temp_new_archives"
rm -rf "$temp_extract_dir"
mkdir -p "$temp_extract_dir"
# Removed however the script ends - normally, on an error, or interrupted.
trap 'rm -rf "$temp_extract_dir"' EXIT
trap 'exit 130' INT TERM

# Parse update.log and copy new archives while preserving directory structure
while IFS= read -r line; do
  filepath=$(echo "$line" | sed 's/^[0-9-]* [0-9:]* //')
  relpath="${filepath#./}"
  if [ -f "$RP_DOWNLOAD_ROOT/$relpath" ]; then
    destpath="$temp_extract_dir/$relpath"
    mkdir -p "$(dirname "$destpath")"
    cp -f "$RP_DOWNLOAD_ROOT/$relpath" "$destpath" 2>/dev/null || {
      echo -e "${YELLOW}Warning: Could not copy $filepath${NC}"
    }
  fi
done < "$UPDATE_LOG"

# Run extract.sh on the temporary directory
cd "$temp_extract_dir" || exit 1
# ECS builds leave out AGA/CD32 releases (EXCLUDE_TAGS_ECS in retroplay.conf).
quick_excl="$(rp_exclude_tags_for "${MODE_OPT#--}")"
bash "$SCRIPT_DIR/extract.sh" -d "$NEWDIR" ${quick_excl:+--exclude-tags "$quick_excl"}
extract_exit=$?
cd "$SCRIPT_DIR" || exit 1
rm -rf "$temp_extract_dir"
if [ $extract_exit -ne 0 ]; then
  echo -e "${YELLOW}Warning: extract.sh completed with errors (exit code $extract_exit)${NC}"
fi

echo
# Step 4: Merge artwork for files in "new" directory
echo -e "${GREEN}Step 4 of 5: Merging artwork for new files...${NC}"
echo

have_igame_dir=0
shopt -s nullglob
for _igdir in "$SCRIPT_DIR"/iGame_*/; do
  [ -d "$_igdir" ] && have_igame_dir=1 && break
done
shopt -u nullglob
unset _igdir

if [ "$have_igame_dir" -eq 0 ]; then
  echo -e "${YELLOW}Warning: no iGame_* artwork directories found next to these scripts. Skipping artwork merge.${NC}"
else
  # Build the extra-args array cleanly so an empty DEST_OPT never turns into
  # a stray/duplicated -d flag, and paths with spaces survive intact.
  merge_args=(-d "$NEWDIR")
  if [ -n "$DEST_OPT" ]; then
    merge_args=(-d "$DEST_OPT")
  fi
  if [ -n "$MODE_OPT" ]; then
    merge_args+=("$MODE_OPT")
  fi
  if [ -n "$SET_OPT" ]; then
    merge_args+=(--set "$SET_OPT")
  fi
  if [ -n "$ART_ORDER_OPT" ]; then
    merge_args+=(--art "$ART_ORDER_OPT")
  fi
  if [ -n "$DEMO_ART_OPT" ]; then
    merge_args+=(--demo-art "$DEMO_ART_OPT")
  fi
  bash "$SCRIPT_DIR/merge.sh" "${merge_args[@]}"
  merge_exit=$?
  if [ $merge_exit -ne 0 ]; then
    echo -e "${YELLOW}Warning: merge.sh completed with errors (exit code $merge_exit)${NC}"
  fi
fi

echo
# Step 5: Sort files in "new" directory
echo -e "${GREEN}Step 5 of 5: Sorting files in 'new' directory...${NC}"
echo

# Default to the staging "new" directory unless the user gave a custom -d.
# (Previously this used a sed hack to patch sort.sh's default before running
# it, but the text it searched for didn't match sort.sh's actual source, so
# the patch silently never applied and this step operated on the *main*
# collection instead of the staging directory. Passing -d directly is both
# correct and simpler.)
sort_target="$NEWDIR"
sort_args=(-d "$sort_target")
if [ "$NO_DETOX" -eq 1 ]; then
  sort_args+=(--no-detox)
fi
bash "$SCRIPT_DIR/sort.sh" "${sort_args[@]}"
sort_exit=$?
if [ $sort_exit -ne 0 ]; then
  echo -e "${YELLOW}Warning: sort.sh completed with errors (exit code $sort_exit)${NC}"
fi

echo
# Final summary
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}QUICK PROCESS COMPLETE${NC}"
echo -e "${BOLD}========================================${NC}"
echo
echo -e "${GREEN}Summary:${NC}"
echo -e " New files downloaded: ${new_file_count}"
echo -e " Extraction directory: ${NEWDIR}"
echo -e " All steps completed successfully!"
echo
echo -e "${BLUE}The 'new' directory contains:${NC}"
echo -e " ✓ Extracted archives"
echo -e " ✓ Merged artwork"
echo -e " ✓ Sorted by variant/language"
echo -e " ✓ Amiga-compatible filenames"
echo
echo -e "${YELLOW}Next steps:${NC}"
echo -e " Review the files in: ${NEWDIR}"
echo -e " When ready, move them to your main collection"
echo

# Clean up any 0-byte logs from this run. update.log is handled separately
# since it's a useful standalone record (what was downloaded), not an
# error log - only deleted if genuinely empty, never touched otherwise.
[ -e "$UPDATE_LOG" ] && [ ! -s "$UPDATE_LOG" ] && rm -f -- "$UPDATE_LOG"
for _logf in extract_errors.log merge_errors.log sort.log amiga_filename_issues.log; do
    [ -e "$SCRIPT_DIR/$_logf" ] && [ ! -s "$SCRIPT_DIR/$_logf" ] && rm -f -- "$SCRIPT_DIR/$_logf"
done
unset _logf

exit 0
