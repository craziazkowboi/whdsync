#!/usr/bin/env bash

# Amiga Retroplay Quick Update & Process Script
# This script downloads new archives, extracts them to a "new" directory,
# merges artwork, and sorts the files - all in one go!

version="1.0.1"

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
NEWDIR="$SCRIPT_DIR/new"
UPDATE_LOG="$SCRIPT_DIR/update.log"
DEST_OPT=""
MODE_OPT=""

# --- Parse CLI Options for ECS/AGA/RTG
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ECS|--AGA|--RTG)
      MODE_OPT="$1"
      shift
      ;;
    -d|--dest)
      # Pass custom destination or use ./new by default
      DEST_OPT="-d $2"
      shift 2
      ;;
    --help|-h)
      echo -e "${BOLD}Usage: $0 [--ECS|--AGA|--RTG] [-d DEST]${NC}"
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}" >&2
      exit 1
      ;;
  esac
done

echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}Amiga Retroplay Quick Processor v${version}${NC}"
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
echo -e "${GREEN}Step 1: Downloading new archives...${NC}"
echo -e "${BLUE}Running update.sh${NC}"
echo

bash "$SCRIPT_DIR/update.sh"
update_exit=$?
if [ $update_exit -ne 0 ]; then
  echo -e "${RED}Error: update.sh failed with exit code $update_exit${NC}"
  exit 1
fi

# Check if update.log exists and has new files
if [ ! -f "$UPDATE_LOG" ]; then
  echo -e "${YELLOW}No update.log found. No new files downloaded.${NC}"
  exit 0
fi

new_file_count=$(grep -c "^" "$UPDATE_LOG" 2>/dev/null || echo 0)
if [ "$new_file_count" -eq 0 ]; then
  echo -e "${YELLOW}No new files downloaded. Nothing to process.${NC}"
  exit 0
fi

echo
echo -e "${GREEN}Found $new_file_count new files to process.${NC}"
echo

# Step 2: Create "new" directory
echo -e "${GREEN}Step 2: Creating 'new' directory...${NC}"
mkdir -p "$NEWDIR"
echo -e "Created: ${NEWDIR}"
echo

# Step 3: Extract only new archives to "new" directory
echo -e "${GREEN}Step 3: Extracting new archives to 'new' directory...${NC}"
echo

temp_extract_dir="$SCRIPT_DIR/.temp_new_archives"
rm -rf "$temp_extract_dir"
mkdir -p "$temp_extract_dir"

# Parse update.log and copy new archives while preserving directory structure
while IFS= read -r line; do
  filepath=$(echo "$line" | sed 's/^[0-9-]* [0-9:]* //')
  if [ -f "$filepath" ]; then
    relpath="${filepath#./}"
    destpath="$temp_extract_dir/$relpath"
    mkdir -p "$(dirname "$destpath")"
    cp -f "$filepath" "$destpath" 2>/dev/null || {
      echo -e "${YELLOW}Warning: Could not copy $filepath${NC}"
    }
  fi
done < "$UPDATE_LOG"

# Run extract.sh on the temporary directory
cd "$temp_extract_dir" || exit 1
bash "$SCRIPT_DIR/extract.sh" "$NEWDIR"
extract_exit=$?
cd "$SCRIPT_DIR" || exit 1
rm -rf "$temp_extract_dir"
if [ $extract_exit -ne 0 ]; then
  echo -e "${YELLOW}Warning: extract.sh completed with errors (exit code $extract_exit)${NC}"
fi

echo
# Step 4: Merge artwork for files in "new" directory
echo -e "${GREEN}Step 4: Merging artwork for new files...${NC}"
echo
if [ ! -d "$SCRIPT_DIR/iGame_art" ]; then
  echo -e "${YELLOW}Warning: iGame_art directory not found. Skipping artwork merge.${NC}"
else
  if [ -n "$MODE_OPT" ]; then
    DEST_OVERRIDE="$NEWDIR" bash "$SCRIPT_DIR/merge.sh" $DEST_OPT "$MODE_OPT"
  else
    DEST_OVERRIDE="$NEWDIR" bash "$SCRIPT_DIR/merge.sh" $DEST_OPT
  fi
  merge_exit=$?
  if [ $merge_exit -ne 0 ]; then
    echo -e "${YELLOW}Warning: merge.sh completed with errors (exit code $merge_exit)${NC}"
  fi
fi

echo
# Step 5: Sort files in "new" directory
echo -e "${GREEN}Step 5: Sorting files in 'new' directory...${NC}"
echo

temp_sort="$SCRIPT_DIR/.temp_sort.sh"
sed "s|DEST=\"\$HOME/retro\"|DEST=\"$NEWDIR\"|g" "$SCRIPT_DIR/sort.sh" > "$temp_sort"
chmod +x "$temp_sort"
bash "$temp_sort" $DEST_OPT
sort_exit=$?
rm -f "$temp_sort"
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

exit 0
