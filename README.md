# whdsync

> ⚠️ **Before copying anything onto a PFS Amiga partition:** set its filename size to 107, or PFS's default limit can corrupt the partition when it encounters the longer filenames some Retroplay archives extract to.
>
> ```
> setfnsize <drive:> 107
> ```
>
> `setfnsize` ships in the PFS package on [Aminet](https://aminet.net/). Run this once per partition before your first sync — it is **not** something these scripts can do for you from the Pi/macOS/Linux side, since it has to be set on the Amiga itself.

A collection of Bash scripts to automate downloading, extracting, merging artwork into, sorting, and deploying Retroplay WHDLoad archives for Amiga setups. Designed to run unattended (e.g. via cron) on modest hardware such as a Raspberry Pi Zero 2W, as well as on macOS and Linux desktops.

## Notes

- After downloading the scripts into a directory, run `chmod +x *.sh` to make them executable.
- All scripts move and rename files as part of normal operation. Keep backups of your WHDLoad tree before first use.
- This README intentionally avoids including any copyrighted third-party content and only describes the behaviour of the provided scripts.
- Bash 3.2+ is supported everywhere **except** `merge.sh`, which needs Bash 4+ (associative arrays). On macOS, `merge.sh` automatically re-launches itself under a Homebrew Bash if one is available; if not, it exits with an install hint (`brew install bash`).

## Prerequisites

- **wget** – for `update.sh`.
- **lha**, **unlzx**, **7z** (p7zip-full), **unar** – for `extract.sh`.
- **detox** (optional) – for filename pre-cleaning in `sort.sh`; skip with `--no-detox` if not installed or not wanted.
- **flock** (optional but recommended) – lets `all.sh` refuse to run a second overlapping instance (e.g. if cron fires while a previous run is still going).
- On Linux, make sure at least these locales are generated for extract.sh's encoding fallback chain:
  - `C.UTF-8`
  - `en_US.ISO-8859-1`

Each script offers to auto-install missing tools via `apt` (Linux) or `brew` (macOS) when run interactively; under cron or any other non-interactive context, it prints what's missing and continues without prompting.

## Artwork directory layout

To merge artwork, create the following structure next to the scripts, once per artwork set you want to use (at minimum `iGame_AGA`, `iGame_ECS`, `iGame_RTG`):

```
iGame_AGA/
├── Covers/
│   ├── Games/<A-Z, 0-9>/<GameName>/iGame.iff (+ matching .data file)
│   ├── Demos/<A-Z, 0-9>/<GameName>/iGame.iff
│   └── Magazines/<A-Z, 0-9>/<GameName>/iGame.iff
├── Screens/
│   └── ...same Games/Demos/Magazines/<letter>/<GameName> layout
└── Titles/
    └── ...same Games/Demos/Magazines/<letter>/<GameName> layout
```

`<GameName>` must match the name of the extracted game/demo/magazine directory under `WHDLoad/`. `Games`/`Demos`/`Magazines` and `Covers`/`Screens`/`Titles` may also be singular (`Game`, `Cover`, etc.) — both are recognised.

Any directory named `iGame_<NAME>` next to the scripts is automatically picked up as a usable artwork set — not just AGA/ECS/RTG. Drop in `iGame_CD32`, `iGame_MyPack`, etc. and it becomes selectable via `--set <NAME>` with no script changes needed. A generic `iGame_art` (or anything starting `iGame_Art`) acts as a catch-all fallback pool tried before giving up on a game entirely. `TinyLauncher/<Game|Demo|Magazine|Beta>/<GameName>_SCR<0|1|2>.iff` is used as a last-resort screenshot source if no iGame artwork is found anywhere.

## Directory layout produced

Each artwork variant builds into its own destination, named automatically from which artwork option was chosen (no manual renaming needed):

- `retro_aga`, `retro_ecs`, `retro_rtg` — the three main variants
- `retro_aga_laced`, `retro_ecs_laced` — the "Laced" artwork tiers, if selected directly
- `retro_<name>` — for a custom `--set NAME` selection
- `retro` — if no artwork variant was specified at all

Override with `--dest <path>` on any script/action.

## Overview

| Script | Purpose |
|---|---|
| `start.sh` | Top-level dispatcher: runs update/extract/merge/sort/quick, or an interactive menu. |
| `update.sh` | Mirrors Retroplay FTP packs, logging genuinely new files. |
| `extract.sh` | Parallel archive extractor for `.lha`/`.lzx`/`.zip`, memory-aware on low-RAM devices. |
| `merge.sh` | Copies the best available iGame/TinyLauncher artwork into each game's directory. |
| `sort.sh` | Moves games into variant (CD32/AGA/NTSC/MT32/CDTV) and language subfolders, then checks/fixes Amiga filesystem compliance. |
| `quick.sh` | Processes only newly downloaded files into a separate `new` directory, without touching the main collection. |
| `all.sh` | Runs all three artwork variants (AGA, ECS, RTG) in one pass, extracting archives only once. |
| `aga.sh` / `ecs.sh` / `rtg.sh` | One-liner wrappers around `start.sh --auto` for a single variant. |
| `install_cron.sh` | Installs a daily (2am) cron job that runs `all.sh`. |

## start.sh (dispatcher)

The main entry point. With no action flag given, it shows an interactive menu instead.

```
Select an action:
  1) Auto (update, extract, merge, sort, clean)
  2) Update only
  3) Extract only
  4) Merge artwork
  5) Sort languages
  6) Quick (process new files)
  7) Full rebuild, skip update (update already ran, or use option 1 instead)
  0) Exit
```

Options:

- `--auto` — Full pipeline: update, extract, merge, sort. If the destination directory already exists, this runs **incrementally** (stages and processes only newly downloaded files, then merges the result in, plus a light artwork gap-fill pass) instead of rebuilding everything.
- `--clean` — Forces a full rebuild even if the destination already exists (removes it first).
- `--skip-update` — Skip calling `update.sh`; reuse the existing `update.log` from this run to decide whether there's anything to process. Used internally by `all.sh`'s per-variant chaining.
- `--update` — Only run `update.sh` (exit code passed straight through: 0 = new files, 2 = nothing new, 3 = wget error).
- `--extract` — Only run `extract.sh`.
- `--merge` — Only run `merge.sh`.
- `--sort` — Only run `sort.sh`.
- `--quick` — Only run `quick.sh`.
- `--ecs` / `--aga` / `--rtg` — Select an artwork variant (also determines the destination directory name).
- `--ecs-laced` / `--aga-laced` — Select the "Laced" tier of ECS/AGA artwork directly (matches `iGame_ECS_Laced`/`iGame_AGA_Laced`).
- `--set [name]` — Select any other discovered `iGame_<name>` artwork directory.
- `--ffs` / `--pfs` — Filesystem filename-length limits for `sort.sh` (PFS is the default).
- `--dest [path]` — Override the destination directory.
- `--art [order]` / `--demo-art [order]` — Artwork-section priority order for non-demos/demos, e.g. `Screens,Covers,Titles`.
- `--no-detox` — Skip the detox pre-clean step (and its startup dependency check) entirely.
- `--skipchk` — Skip the Amiga filesystem compliance check in `sort.sh`.
- `--skip-variant-sort` — Skip the CD32/AGA/NTSC/MT32/CDTV and language-folder reorganization in `sort.sh` (used by `all.sh` for a shared compliance-only pass — see below).
- `--debug` — Verbose debug output, forwarded to `extract.sh`/`merge.sh`.
- `--exit` — Exit immediately.
- `-h`, `--help` — Show help.

At the end of a run, if anything was logged to `extract_errors.log`, `merge_errors.log`, `sort.log`, or `amiga_filename_issues.log`, these are consolidated into a single `retroerror.log` and you're prompted to view, delete, or leave it (skipped automatically when there's no terminal attached, e.g. under cron, or when running as part of `all.sh` — see below).

## update.sh (Retroplay FTP mirroring)

Mirrors five WHDLoad pack directories from the Retroplay FTP server (`HD_Loaders/Games`, `JST/Games`, `WHDLoad/Magazines`, `WHDLoad/Demos`, `WHDLoad/Games`), and works out what's genuinely new by diffing the local file list before and after each mirror pass (`wget`'s own mirror mode doesn't report this directly).

- Logs newly downloaded files with timestamps to `update.log`.
- Exit codes: `0` = new files found, `2` = nothing new anywhere, `3` = a `wget` error occurred (don't trust "0 new" in that case).

## extract.sh (archive extractor)

Scans **only** `HD_Loaders/`, `JST/`, and `WHDLoad/` (up to 4 levels deep) for `.lha`/`.lzx`/`.zip` archives and extracts them in parallel, trying ASCII, then ISO-8859-1, then the system locale for filenames that don't decode cleanly. The search is deliberately scoped to those three directories rather than the whole script directory, so artwork-pack folders sitting alongside them (some of which are themselves distributed as compressed archives) never get mistaken for WHDLoad games.

- Parallelism is capped based on available memory (as low as 1 job on devices with under ~768MB RAM) as well as CPU core count, with a per-archive timeout and detection of jobs killed by the OS (e.g. an out-of-memory kill).
- Failed extractions are logged to `extract_errors.log`; killed jobs are reported separately from ordinary failures.

Options:

- `-d, --dest <path>` — Destination root (default `./retro`).
- `-u, --unattended` — Run without prompts.
- `--debug` — Verbose debug output.
- `-h, --help` — Show help.

## merge.sh (iGame / TinyLauncher artwork merger)

For every game/demo/magazine directory under `DEST/WHDLoad`, finds the best available iGame-style artwork and copies it in — the primary `iGame.iff` (renamed to `igame1.iff`/`igame2.iff` for lower-priority art sections found for the same game), its paired `.data` file, and any other files sitting alongside them in that artwork source directory. Falls back to TinyLauncher screenshots if no iGame artwork exists at all for that game.

"Best available" is an ordered **fallback chain** of artwork sets, not just the one you asked for — so a game missing artwork in your chosen set can still pick it up from a lower-priority one rather than being left with nothing:

| Selection | Fallback chain |
|---|---|
| `--rtg` | RTG → AGA_Laced → AGA → iGame_art → ECS_Laced → ECS → TinyLauncher → *(any other discovered set)* |
| `--aga` | AGA → iGame_art → ECS → TinyLauncher → *(other)* |
| `--aga-laced` | AGA_Laced → AGA → iGame_art → ECS → TinyLauncher → *(other)* |
| `--ecs` | ECS → iGame_art → TinyLauncher → *(other)* |
| `--ecs-laced` | ECS_Laced → ECS → iGame_art → TinyLauncher → *(other)* |
| `--set NAME` / `--custom` | the chosen set → iGame_art → TinyLauncher → *(other)* |

Options:

- `--custom` — Interactive menu listing every discovered artwork set.
- `--ecs` / `--aga` / `--rtg` — Shortcuts for `--set ECS` / `AGA` / `RTG`.
- `--ecs-laced` / `--aga-laced` — Shortcuts for `--set ECS_LACED` / `AGA_LACED`.
- `--set NAME` — Use the `iGame_NAME` directory as the artwork source (case-insensitive).
- `-d, --dest <path>` — Destination root (default `./retro`).
- `--art <order>` — Artwork-section priority for non-demos (default `Screens,Covers,Titles`).
- `--demo-art <order>` — Artwork-section priority for demos (default `Titles,Screens,Covers`).
- `--a314` — Hint that this is running on an A314 bridge (lower parallelism, fewer progress updates).
- `--only-missing` — Skip any target that already has both an iGame.iff-family file and a `.data` file — a cheap way to fill gaps in an existing collection instead of re-checking everything.
- `--debug` — Trace artwork matching decisions.
- `-h, --help` — Show help, including the fallback chain reference above.

## sort.sh (variant/language sorter and compliance checker)

The final pipeline step. Runs three largely independent passes:

1. **Detox pre-clean** (optional, external tool) — cleans up problematic characters in filenames. Skip with `--no-detox`.
2. **Variant and language sorting** — moves games with a recognised suffix (e.g. `SomeGame_AGA`, `SomeGame_De`) into `WHDLoad/<Variant>/...` or `WHDLoad/Languages/<Language>/...`, preserving `.info` icons alongside. Runs in parallel across several directories at once. Skip with `--skip-variant-sort`.
3. **Amiga filesystem compliance check** — scans every file for forbidden characters (colon, slash, control characters, trailing spaces) and filename-length limits (FFS or PFS), auto-fixing what it safely can (truncation only — no transliteration) and logging what it can't to `amiga_filename_issues.log`. This check is parallelized across multiple worker processes for speed on large collections. Skip with `--skipchk`.

Options:

- `-d, --dest <path>` — Destination root (default `./retro`).
- `--ffs` — FFS filename limits (30 characters — shorter).
- `--pfs` — PFS filename limits (107 characters — default, more permissive).
- `--skipchk` — Skip the compliance check entirely.
- `--no-detox` — Skip detox, even if installed.
- `--skip-variant-sort` — Skip the variant/language reorganization (used by `all.sh` — see below).
- `--custom` — Reserved for dispatcher integration (no-op here).
- `-h, --help` — Show help.

## quick.sh (incremental processing)

Runs `extract.sh → merge.sh → sort.sh` on only the files named in the most recent `update.log`, into a separate `new` directory (override with `-d`/`--dest`) rather than touching your main collection — useful for previewing what a batch of new downloads looks like before folding it into the real archive.

Options: `--ecs` / `--aga` / `--rtg` / `--ecs-laced` / `--aga-laced` / `--set NAME` (mutually exclusive, last one wins), `--art`, `--demo-art`, `--no-detox`, `-d`/`--dest`, `--skip-update`, `-h`/`--help`.

## all.sh (all three variants in one pass)

Runs AGA, ECS, and RTG end to end, always extracting archives once and reusing the result for all three variants rather than extracting the same archives three times — whether this is a fresh build or a routine incremental update, since that's the far more common case in practice (e.g. weekly cron runs).

**Fresh build** (none of `retro_aga`/`retro_ecs`/`retro_rtg` exist yet, or `--clean` is given):

1. Runs `update.sh` once.
2. **Extracts archives once**, into `retro_aga` — not once per variant. Decompression is by far the most expensive step, so this alone roughly triples build speed for a fresh archive.
3. Runs the **compliance check once** on that extracted tree (filename length/character fixes don't depend on which variant's artwork ends up sitting next to them, or on the later variant/language reorganization, so there's no need to repeat it three times).
4. Copies that extracted-and-checked tree into `retro_ecs` and `retro_rtg` (a plain filesystem copy, much cheaper than re-extracting).
5. Runs artwork merge + variant/language sorting **separately for each variant** against its own copy — this part genuinely differs per variant (different artwork, and each variant needs its own reorganization pass since the newly-merged artwork moves along with its game folder).

**Incremental update** (all three destinations already exist): the same idea, applied to just the newly downloaded batch instead of the whole archive collection — stages and extracts only the files named in this run's `update.log` once, runs the compliance check on that small batch once, copies it into a per-variant working copy, merges and sorts each copy separately, then folds each into its real destination (plus a `--only-missing` gap-fill pass, same as the original per-variant path did).

**Mixed state** (some but not all of the three destinations exist — a rare edge case, typically from an interrupted prior run): falls back to the original per-variant path (`aga.sh` → `ecs.sh --skip-update` → `rtg.sh --skip-update`), so each variant is correctly treated as fresh or incremental on its own terms rather than risking a genuinely-missing variant getting only the latest batch instead of its full history.

Other behaviour:

- Uses `flock` to refuse a second overlapping run (e.g. if cron fires while a previous run is still going).
- Errors from all three variants (or all pipeline steps, in the optimized paths) are accumulated into one `retroerror.log` for the whole run, and the end-of-run "view error log?" prompt is skipped even if a terminal is attached — answering it after variant one would otherwise stall the whole unattended pipeline waiting on input.

## aga.sh / ecs.sh / rtg.sh

One-liner wrappers for a single variant, forwarding any extra arguments through:

```bash
./aga.sh   # ./start.sh --auto --aga --no-detox "$@"
./ecs.sh   # ./start.sh --auto --ecs --no-detox "$@"
./rtg.sh   # ./start.sh --auto --rtg --art Covers,Screens,Titles --no-detox "$@"
```

## install_cron.sh

Installs a cron entry that runs `all.sh` every day at 2am, with output appended to `all_cron.log`:

```
0 2 * * * cd "<script dir>" && ./all.sh >> "<script dir>/all_cron.log" 2>&1
```

Idempotent — re-running it replaces the previous entry rather than adding a duplicate.

## Typical usage

```bash
# One-off: build a single variant
./start.sh --auto --aga

# Everything, extracting archives only once (recommended for a fresh setup)
./all.sh

# Preview what a batch of new downloads contains before committing to it
./quick.sh --aga

# Set up unattended weekly updates
./install_cron.sh
```
