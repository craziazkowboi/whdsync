# whdsync
A collection of Bash scripts to automate updating, extracting, merging artwork, sorting, and quick-processing of Retroplay WHDLoad archives for Amiga setups. 

## Notes

- All scripts are written to be non-destructive where possible but do perform moves and renames; keeping backups of your WHDLoad tree is recommended before first use. 
- This README intentionally avoids including any copyrighted third-party content and only describes the behaviour of the provided scripts.

To merge artwork, you will need to create the following direcgtory structure in the same direcotry that the script is run from, and add your .iff files.  Create the same structure for iGame_ECS, iGame_RTG, and iGame_AGA:

iGame_AGA/
├── Covers/
│   ├── Demos/
│   ├── Games/
│   └── Magazines/
├── Screens/
│   ├── Demos/
│   ├── Games/
│   └── Magazines/
└── Titles/
    ├── Demos/
    ├── Games/
    └── Magazines/

Under each of this directories, I have 0, A, B, C... etc and under those are the WHDLoad games/demos/magazines directories with the .iff files.  Yeah, I know a bit of a pain to setup, but worth the effort I think.

## Overview

- `**start.sh**` – Top-level dispatcher that runs update, extract, merge, sort, or quick modes with a single command, including locale checks and cross-platform handling (macOS / Linux). 
- `**update.sh**` – Mirrors Retroplay FTP packs using `wget`, logging new files and elapsed time for WHDLoad subtrees. [attached_file:9]
- `**extract.sh**` – Parallel archive extractor for `.lha`, `.lzx`, and `.zip` using `lha`, `unlzx`, `7z`, and `unar`, with robust fallback across ASCII, ISO-8859-1, and system locales.
- `**merge.sh**` – Artwork merger for iGame/TinyLauncher, walking WHDLoad game directories and copying Screens/Titles/Covers (and TinyLauncher SCR) into game folders in parallel. 
- `**sort.sh**` – Ultimate language and filesystem sorter, enforcing FFS/PFS-safe filenames, transliterating Unicode, and restructuring WHDLoad sets into language and filesystem-compliant layouts. 
- `**quick.sh**` – Fast-path helper to process only newly added files without re-running the entire pipeline. [attached_file:6]

## Prerequisites

- Bash 3.2+ (tested on macOS 10.15.7 and Debian-like Linux).
- Tools:
  - `wget` (for `update.sh`).
  - `lha`, `unlzx`, `7z`, `unar` (for `extract.sh`).
- For best locale behaviour on Linux, ensure at least:
  - `C.UTF-8`
  - `en_US.ISO-8859-1`  
  are generated and available.

## Directory Layout

Typical structure under the root destination (default `.retro` relative to the script directory):

- `./WHDLoad` – Main WHDLoad archive tree.
- `./iGame_ECS`, `./iGame_AGA`, `./iGame_RTG` – Artwork sources for different chipsets.
- `./TinyLauncher` – Optional TinyLauncher artwork.

You can override the destination root with `--dest` options as described below.  The Default destiantion will be ./retro

## Script Details

### start.sh (dispatcher)

`start.sh` is the main entry point that wires all other scripts together. It sets safe shell options, raises file descriptor limits, checks required locales (on non-macOS), and then calls the relevant helper scripts.

Supported options:

- `--auto` – Run full pipeline: `update`, `extract`, `merge`, `sort` (in that order).
- `--update` – Only run `update.sh`.
- `--extract` – Only run `extract.sh`.
- `--merge` – Only run `merge.sh`.
- `--sort` – Only run `sort.sh`.
- `--quick` – Only run `quick.sh` (process new files only).
- `--ecs` / `--aga` / `--rtg` – Pass chipset selection to `merge.sh`.
- `--ffs` / `--pfs` – Pass filesystem mode to `sort.sh`.
- `--dest <path>` – Override default `.retro` destination root for downstream scripts.
- `--exit` – Exit immediately.
- `-h`, `--help` – Show help.  

## What does each Script do?


### update.sh (Retroplay FTP mirroring)

`**update.sh**` walks a set of WHDLoad directories (Games, Demos, Magazines, etc.), mirrors corresponding Retroplay FTP pack directories with `wget`, and logs only newly downloaded files. It also prints padded “Checking for updates…” messages and a final elapsed time.

Key characteristics:

- Uses `wget --mirror -np -nH --cut-dirs=2` against the Retroplay FTP tree.
- Maintains `before.txt` / `after.txt` lists per directory to compute new files.
- Logs new files with timestamps in `update.log`.
- Prints total runtime as `hh:mm:ss`.


### extract.sh (multi-encoding archive extractor)

`**extract.sh**` scans for archives up to depth 4 under the current directory and extracts them in parallel into a destination tree (default `.retro`). It uses smart encoding fallbacks so that “difficult” filenames are still handled correctly.

Features:

- Detects OS (Linux/macOS) and uses `greadlink` when needed on macOS.
- Supports `.lha`, `.lzx`, `.zip` (and generic archives handled by `unar`/`7z`).
- For each archive type, tries multiple extraction passes:
  - ASCII, ISO-8859-1, then system locale.
- Parallel extraction based on CPU core count, with a progress bar.
- Writes failed archives to `extracterrors.log`.

Options:

- `-d, --dest <path>` – Destination root (default `.retro`).
- `-u, --unattended` – Non-interactive mode.
- `--debug` – Verbose debug output.
- `-h, --help` – Usage information.


### merge.sh (iGame / TinyLauncher artwork merger)

`**merge.sh**` merges artwork from iGame ECS/AGA/RTG folders and optional TinyLauncher sources into per-game WHDLoad directories under the chosen destination. It runs in parallel and logs what was copied.

Core behaviour:

- Discovers WHDLoad subdirectories (up to depth 4).
- For each game directory:
  - Searches `Screens`, `Titles`, and `Covers` hierarchies by:
    - Section: `Screens`, `Titles`, `Covers`
    - Category: `Games`, `Magazines`, `Demos`
    - Prefix: `A..Z`, `0..9`
  - Copies:
    - Screen files into the game directory.
    - Cover artwork to `igame1.iff`.
    - Title artwork to `igame2.iff`.
  - Optionally merges TinyLauncher screenshots (`SCR*.iff`) if present.
- Logs:
  - iGame matches, TinyLauncher matches, missed titles, and copy errors.
- Parallelized based on CPU core count with a text/Unicode progress bar.

Options:

- `--custom` – Show interactive artwork set menu (ECS / AGA / RTG).
- `--ecs` / `--aga` / `--rtg` – Select artwork source non-interactively.
- `-d, --destination <path>` – Destination root (default `.retro`).
- `--debug` – Enable debug logging to stdout.
- `-h, --help` – Usage information.


### sort.sh (language and filesystem sorter)

`**sort.sh**` is the final pass that ensures Amiga filesystem compatibility and language separation. It can enforce FFS-style or PFS3-style limits and transliterate a wide range of Unicode characters into safe ASCII.

Key capabilities:

- Destination root default `.retro`, override via `--dest`.
- Filesystem modes:
  - `--ffs` – Conservative limits suitable for classic FFS (shorter names).
  - `--pfs` – More permissive limits for PFS3.
- Compliance checker:
  - Optionally scans all files under destination and:
    - Flags forbidden characters (e.g., colon, slash, etc.).
    - Transliterates accented Latin characters, ligatures, smart quotes, and various symbols.
    - Attempts auto-renames where safe.
- Language sorter:
  - Detects language codes in directory names and moves them under language roots (e.g., `Languages/DE`, `Languages/FR`), preserving `.info` icons.  
- Parallel processing with progress bar and per-language summaries.

Options:

- `-d, --dest <path>` – Destination root.
- `--ffs` / `--pfs` – Select filesystem profile.
- `--skipchk` – Skip compliance check (faster, less safe).
- `--custom` – Reserved for dispatcher integration; currently a no-op.
- `-h, --help` – Usage.


### quick.sh (incremental processing)

`**quick.sh**` is invoked by `start.sh --quick` and is designed to handle only newly added content, avoiding a full re-run of heavy stages. It shares destination and environment conventions with the other scripts so it can slot into the same workflow. 











