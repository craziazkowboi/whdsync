# whdsync

> ⚠️ **Before copying anything onto a PFS Amiga partition:** set its filename size to 107, or PFS's default limit can corrupt the partition when it meets the long filenames some Retroplay archives extract to.
>
> ```
> setfnsize <drive:> 107
> ```
>
> `setfnsize` ships in the PFS package on [Aminet](https://aminet.net/). Run it once per partition, on the Amiga, before your first sync.

Bash scripts that download the Retroplay WHDLoad packs, extract them, add iGame/TinyLauncher artwork, sort them into variant and language folders, and keep everything up to date — unattended, nightly, on something as small as a Raspberry Pi Zero 2W, as well as on macOS and Linux.

## Quick start

```bash
chmod +x *.sh
./setup.sh               # installs everything, asks 3 questions, offers the nightly run
./all.sh                 # first run: downloads and builds retro_aga, retro_ecs, retro_rtg
./start.sh --status      # any time: last run, what's queued, drive, schedule
```

`setup.sh` installs the tools (via apt or Homebrew), downloads and compiles `unlzx` from Aminet, enables the locales Linux needs, creates `retroplay.conf`, offers the nightly run and finishes with `doctor.sh`. It's safe to run again at any time — each step only does what's missing. `--yes` answers every question with its default; `--dry-run` shows what it would do.

## Notes

- Scripts move and rename files as part of normal operation. Keep a backup of your WHDLoad tree before first use.
- **Always update the scripts as a complete set.** Each one carries a `retroplay-suite:` version stamp, and `all.sh` refuses to run on a mix of versions (naming the out-of-date files), because an old script mixed with new ones can damage a collection. `./doctor.sh` checks this too.
- Every script can be run from any directory — each one switches to its own folder first. The archive folders (`WHDLoad`, `HD_Loaders`, `JST`) may be symlinks to another drive.
- Temporary folders (`extract_tmp.*` and friends) are removed whenever a script finishes, fails or is stopped. Leftovers from a crash or power cut are swept up at the start of the next run (a folder whose run is still going is never touched).
- Bash 3.2+ everywhere, except `merge.sh`, which needs Bash 4+. On macOS it relaunches itself under Homebrew's bash automatically (`brew install bash`).
- This README only describes the scripts; it contains no third-party content.

## Prerequisites

- **wget** (downloads), **lha**, **unlzx**, **7z**, **unar** (extraction).
- **flock** (recommended) — stops two runs overlapping. Part of `util-linux`; on macOS Homebrew installs it keg-only and the scripts find it automatically.
- **detox** (optional) — only if you set `USE_DETOX=yes`.
- **curl** or **wget**, and/or **mail** — only for notifications.
- Linux locales `C.UTF-8` and `en_US.ISO-8859-1`.

Run `./doctor.sh` to check all of this at once. Scripts offer to install missing tools via `apt`/`brew` when run interactively. `unlzx` has no package and must be built from [source on Aminet](https://aminet.net/package/util/arc/unlzx).

Everything the scripts install is recorded, and only recorded if the package manager confirms it **wasn't** already installed — so `uninstall_deps.sh` can later remove exactly that and nothing you already had.

## Settings: `retroplay.conf`

Copy `retroplay.conf.example` to `retroplay.conf` and edit it. Every setting is optional; command-line options override it. The file is read as plain `KEY=VALUE` lines (never executed), and `doctor.sh` warns about typos.

| Setting | Default | What it does |
|---|---|---|
| `VARIANTS` | `aga ecs rtg` | Which variants `all.sh` builds (`aga-laced`, `ecs-laced`, or any `iGame_NAME` set also work). |
| `OUTPUT_ROOT` | `.` | Where `retro_*`, `new_*` and working files go — e.g. a USB SSD, which is far faster than an SD card. |
| `ART_ORDER`, `ART_ORDER_<VARIANT>` | `Covers,Screens,Titles` | Artwork priority (per variant if needed). |
| `DEMO_ART_ORDER` | `Titles,Screens,Covers` | Artwork priority for demos. |
| `MAX_EXTRACT_ATTEMPTS` | `3` | Failed extractions of one archive before it is moved to `old/corrupt-<date>/` and re-downloaded. |
| `DOWNLOAD_RETRIES` | `3` | Attempts at each download pass before giving up (exit 3). |
| `GAPFILL_DAYS` | `7` | The artwork gap-fill runs when an artwork pack changes, or after this many days. |
| `VERIFY_DOWNLOADS` | `auto` | Test new downloads straight away (`yes`/`no`/`auto` = batches of up to 100 files). |
| `STRUCTURED_ART_SETS` | `AGA ECS RTG` | Artwork packs matched only by the standard layout; all others are also searched at any depth. |
| `EXCLUDE_TAGS_<VARIANT>` | ECS variants: `AGA,CD32` | Releases a variant leaves out (see below). |
| `FILESYSTEM` | `pfs` | Filename limits: `pfs` (107 characters) or `ffs` (30). |
| `USE_DETOX` | `no` | Clean filenames with detox before sorting. |
| `MIN_FREE_MB`, `SPACE_FACTOR` | `1024`, `3` | Free space to always keep, and how much bigger extracted files are than the archives. |
| `KEEP_NEW_BATCHES` | `14` | Dated `new_*` batch folders to keep per variant. |
| `OLD_ARCHIVE_DAYS` | `30` | Days to keep superseded archives in `old/`. |
| `LOG_MAX_MB`, `LOG_KEEP` | `5`, `4` | Rotation of the nightly `all_cron.log`. |
| `NTFY_TOPIC`, `NTFY_SERVER`, `NOTIFY_EMAIL`, `NOTIFY_ON_SUCCESS` | off | Notifications when a run fails (or succeeds). |

## Artwork directory layout

Create this next to the scripts for each artwork set (at least `iGame_AGA`, `iGame_ECS`, `iGame_RTG`):

```
iGame_AGA/
├── Covers/
│   ├── Games/<A-Z, 0-9>/<GameName>/iGame.iff (+ matching .data file)
│   ├── Demos/<A-Z, 0-9>/<GameName>/iGame.iff
│   └── Magazines/<A-Z, 0-9>/<GameName>/iGame.iff
├── Screens/   (same layout)
└── Titles/    (same layout)
```

`<GameName>` must match the extracted game folder's name. Singular folder names (`Game`, `Cover`) also work. Any `iGame_<NAME>` folder is picked up automatically and usable as `--set NAME`. A generic `iGame_art` is a catch-all fallback, and `TinyLauncher/<Game|Demo|Magazine|Beta>/<GameName>_SCR<n>.iff` a last resort.

**`iGame_AGA`, `iGame_ECS` and `iGame_RTG` must use the layout above. Every other pack — `iGame_art`, the `_Laced` packs, your own — can be organised however you like:** a folder named after the game, holding an `iGame.iff`, is found at any depth. The layout above is still checked first, so a pack that follows it works exactly as before. A match somewhere under a `Covers`, `Screens` or `Titles` folder keeps that section's priority; one with no section in its path is tried after that pack's sections. Which packs are standard-layout-only is set by `STRUCTURED_ART_SETS` in `retroplay.conf`.

## What gets built

| Folder | Contents |
|---|---|
| `retro_aga`, `retro_ecs`, `retro_rtg` (and `retro_aga_laced`, `retro_ecs_laced`, `retro_<name>`) | The full collection for each variant. |
| `new_<variant>/<date_time>/` | Just the games added or updated in each run — handy for copying only what changed to the Amiga. The newest `KEEP_NEW_BATCHES` are kept. |
| `old/<date>/` | Superseded archives, kept `OLD_ARCHIVE_DAYS` days in case one was wrongly retired. |
| `reports/` | A summary of every run, plus lists of games that got no artwork. |

**ECS leaves out AGA and CD32 releases.** An ECS machine can't run them, so archives whose name has an `AGA` or `CD32` field (e.g. `Game_v1.1_AGA_HD.lha`, but not a game merely called *Agamemnon*) are never extracted into `retro_ecs` or `retro_ecs_laced`. `retro_aga` and `retro_rtg` get everything. Change this with `EXCLUDE_TAGS_ECS` in `retroplay.conf`.

## How a run works (and why it's safe to interrupt)

`all.sh` is the engine; `start.sh --auto` and `aga.sh`/`ecs.sh`/`rtg.sh` run through it for a single variant.

1. **Update.** `update.sh` mirrors the Retroplay FTP packs and **queues** every new archive for each finished variant. An archive stays queued until that variant has actually absorbed it, so a run that fails or is interrupted part-way is simply picked up by the next one.
2. **Plan.** Each variant is either *not built yet*, *interrupted* (a full build that never finished — it's redone, never mistaken for a finished one), *has queued archives*, or *up to date*.
3. **Full builds** extract and sort every archive **once**, then copy the result per variant; only the artwork differs.
4. **Updates** stage just the queued archives, extract and sort them once, add each variant's artwork, then install them. A game in the batch **replaces** its old folder, so files from older versions don't linger. A dated copy goes into `new_<variant>/`, and a quick artwork gap-fill runs over the whole collection.
5. **Report** in `reports/`, and a notification if something failed.

**Corrupt or failed archives never block the rest.** Everything that extracts is installed; an archive that fails stays queued and is retried next run. After `MAX_EXTRACT_ATTEMPTS` failures (default 3) it is moved to `old/corrupt-<date>/`, so the next update downloads a fresh copy. The run exits 5 and the report names it.

**A USB drive that isn't mounted is never mistaken for an empty one.** The output folder gets a marker file on first use; if it's missing later (drive not mounted, so the mount point is just an empty folder on the SD card), the run stops with exit 4 and changes nothing, instead of rebuilding everything onto the SD card.

**The state folder is backed up** (`.retroplay_backups/`, newest 7) at the start of every run. If `.retroplay` is ever lost, it's restored automatically, so queued downloads aren't lost. To deliberately start from scratch, delete both folders.

**New downloads are tested straight away** (`lha t`, `unzip -t`, `lsar -t` for .lzx when available). A corrupt download is deleted and fetched again in the same run.

**Artwork gap-fill runs only when it can help:** when an artwork pack has changed (so new artwork reaches an up-to-date collection by itself), after `GAPFILL_DAYS` days, or with `--force`.

**Downloads are retried** (`DOWNLOAD_RETRIES`, default 3, with growing pauses). A file the server re-publishes under the same name is picked up and processed, and a file left half-downloaded by an interrupted transfer is never processed as if complete: it is re-downloaded in full on the next run.

Free disk space is checked before extracting and before each copy, and an existing collection is only removed once its replacement is ready to install. Every extraction is also checked to contain only `WHDLoad`, `HD_Loaders` and `JST` at the top; anything else stops the run before it reaches a collection. If a `retro_*` folder ever holds anything else at the top (such as a `Users/…` tree left by an older version), the next run rebuilds that variant from your archives, and `new_*` batches with the wrong layout are removed.

## Script reference

| Script | Purpose |
|---|---|
| `all.sh` | The pipeline engine — builds/updates every variant in `VARIANTS`. |
| `start.sh` | Menu and individual steps (update, extract, merge, sort, quick). |
| `aga.sh` / `ecs.sh` / `rtg.sh` | One variant, via `start.sh --auto`. |
| `update.sh` | Downloads, queues, and retires superseded archives. |
| `extract.sh` | Parallel, memory-aware archive extractor. |
| `merge.sh` | Adds artwork to game folders. |
| `sort.sh` | Variant/language sorting and Amiga filename checks. |
| `quick.sh` | Preview new downloads in `new/` without touching the collection. |
| `setup.sh` | One-step install and setup (safe to repeat). |
| `doctor.sh` | Checks the whole setup and explains fixes. |
| `install_cron.sh` | Nightly 2am run. |
| `uninstall_deps.sh` | Removes only the tools these scripts installed. |
| `lib.sh` | Shared helpers (not run directly). |

### all.sh

```
./all.sh [--aga] [--ecs] [--rtg] [--aga-laced] [--ecs-laced] [--set NAME] [--variants "a b"]
         [--rebuild | --clean] [--skip-update] [--force] [--dry-run] [--cron] [--dest PATH]
         [--art ORDER] [--demo-art ORDER] [--ffs | --pfs] [--no-detox | --detox] [--debug]
```

- No variant options: builds `VARIANTS` from `retroplay.conf`. Lists may use spaces or commas (`--variants aga,ecs`); an unknown variant name is rejected rather than building a folder with the wrong artwork.
- `--rebuild` — rebuild from the archives already downloaded, **without checking for updates**.
- `--clean` — check for updates, then rebuild from scratch.
- `--skip-update` — don't download; process whatever is queued.
- `--force` — also run the artwork gap-fill on variants that are up to date.
- `--dry-run` — show the plan, what's queued, the space needed, and an estimate from the server of what would be downloaded. Changes nothing.
- `--status` — last run, each variant's state, queued downloads, output drive, schedule. Also `./start.sh --status`, and a summary heads the menu.
- `--test-notify` — send a test ntfy/email notification and say whether it worked.
- `--cron` — for cron: full `PATH` (cron's default misses `/usr/local/bin` and Homebrew), log rotation, output to `all_cron.log`.
- `--dest PATH` — custom output folder (single variant only).
- Exit codes: `0` work done, `2` nothing to do, `3` network/server problem (try again later), `4` setup or option problem (e.g. a missing tool, another run in progress, not enough disk space), `5` some archives couldn't be extracted (everything else was installed), `130` interrupted, `1` any other failure.

### start.sh

With no options it shows a menu:

```
  1) Auto (update, extract, merge, sort, clean)
  2) Update only
  3) Extract only
  4) Merge artwork
  5) Sort languages
  6) Quick (process new files)
  7) Rebuild from downloaded archives (no update check)
  8) Check setup (doctor)
  9) Show full status
 10) Send a test notification
  0) Exit
```

Options: `--auto`, `--rebuild`, `--update`, `--extract`, `--merge`, `--sort`, `--quick`, `--doctor`, `--ecs`/`--aga`/`--rtg`/`--ecs-laced`/`--aga-laced`, `--set NAME`, `--ffs`/`--pfs`, `--dest PATH`, `--art ORDER`, `--demo-art ORDER`, `--no-detox`/`--detox`, `--clean`, `--skip-update`, `--force`, `--skipchk`, `--skip-variant-sort`, `--only-missing`, `--report-missing FILE`, `--debug`, `--exit`, `-h`. All are case-insensitive.

### aga.sh / ecs.sh / rtg.sh

```bash
./ecs.sh              # update, then build or update retro_ecs
./ecs.sh --rebuild    # rebuild retro_ecs from the downloaded archives, no update check
./ecs.sh --clean      # update, then rebuild retro_ecs from scratch
```

Any `start.sh` option can be added.

### update.sh

Mirrors `HD_Loaders/Games`, `JST/Games`, `WHDLoad/Magazines`, `WHDLoad/Demos` and `WHDLoad/Games`, logs new files to `update.log`, and queues them.

**Retiring old versions.** An existing archive is only treated as an older version of a new one when the two names are **identical apart from the `_vX.Y` field**, and its version is **strictly lower**. Versions compare number by number, so `1.10` > `1.9` > `1.1`. So `_AGA`, `_CD32`, `_HD` and `_68040` releases of the same game are separate files and never touch each other. Retired archives go to `old/<date>/`, not the bin. If the server keeps offering one that was retired, it's exempted from then on rather than downloaded and retired every night.

- `--dry-run` — ask the server what would be downloaded (a name-based estimate), without downloading.
- Exit codes: `0` new files, `2` nothing new, `3` network/server error.

### extract.sh

Extracts `.lha`/`.lzx`/`.zip` from `HD_Loaders/`, `JST/` and `WHDLoad/` in parallel. It caps parallelism by available memory (a single job on a 512MB Pi Zero 2W) and falls back through ASCII, ISO-8859-1 and system locales for awkward filenames.

Options: `-d, --dest PATH`, `-u, --unattended`, `--exclude-tags LIST`, `--only-tags LIST` (filter by name fields, e.g. `AGA,CD32`), `--debug`, `-h`.

### merge.sh

For each game folder under `DEST/WHDLoad`, copies the best artwork found along a fallback chain:

| Selection | Fallback chain |
|---|---|
| `--rtg` | RTG → AGA_Laced → AGA → iGame_art → ECS_Laced → ECS → TinyLauncher → *(any other set)* |
| `--aga` | AGA → iGame_art → ECS → TinyLauncher → *(other)* |
| `--aga-laced` | AGA_Laced → AGA → iGame_art → ECS → TinyLauncher → *(other)* |
| `--ecs` | ECS → iGame_art → TinyLauncher → *(other)* |
| `--ecs-laced` | ECS_Laced → ECS → iGame_art → TinyLauncher → *(other)* |
| `--set NAME` | the chosen set → iGame_art → TinyLauncher → *(other)* |

Games already sorted into variant/language folders are found at any depth.

Options: `--custom`, `--ecs`/`--aga`/`--rtg`/`--ecs-laced`/`--aga-laced`, `--set NAME`, `-d, --dest PATH`, `--art ORDER`, `--demo-art ORDER`, `--a314`, `--only-missing`, `--report-missing FILE`, `--debug`, `-h`.

### sort.sh

Moves games tagged CD32/AGA/NTSC/MT32/CDTV into `WHDLoad/<Variant>/` and language releases into `WHDLoad/Languages/<Language>/`. It also checks every filename against Amiga limits (forbidden characters, FFS/PFS length), fixing what it safely can and logging the rest to `amiga_filename_issues.log`.

Options: `-d, --dest PATH`, `--ffs`, `--pfs`, `--skipchk`, `--no-detox`, `--skip-variant-sort`, `-h`.

### quick.sh

Previews only the newest downloads (from `update.log`) in a separate `new/` folder, without touching your collection. ECS previews leave out AGA/CD32 releases too.

Options: `--ecs`/`--aga`/`--rtg`/`--ecs-laced`/`--aga-laced`/`--set NAME`, `--art`, `--demo-art`, `--no-detox`, `-d`/`--dest`, `--skip-update`, `-h`.

### install_cron.sh

Installs `0 2 * * * cd "<script dir>" && ./all.sh --cron` — every night at 2am. Re-running it replaces the old entry, including ones from older versions.

**Run it from the terminal where your tools work.** cron starts jobs with a minimal `PATH` (usually just `/usr/bin:/bin`), which is why a tool such as `unlzx` can work everywhere in your terminal yet be "not found" in the nightly run. `install_cron.sh` remembers your terminal's `PATH`, and every script adds it back when running unattended; any interactive run of a script refreshes it too. `./doctor.sh` checks that the nightly run will find everything.

### uninstall_deps.sh

Removes only what these scripts installed (tracked in `.retroplay_installed_deps.log`), with per-item confirmation. `--yes` skips the prompts, `--dry-run` only lists.

### doctor.sh

Checks bash, tools, locales, `retroplay.conf`, artwork folders, disk space, build and queue state, and the nightly job, with a fix for each problem. Also `./start.sh --doctor` or menu option 8.

## Tests

```bash
tests/run_tests.sh        # end-to-end scenarios; add -v to see each script's output
tests/option_matrix.sh    # every option of every script, and combinations (slower)
MATRIX_SECTIONS="1 2" tests/option_matrix.sh   # just some sections (1-6)
```

The runner also works if copied to the project root. The option matrix fails on any unexpected exit code, hang, or shell error (unbound variable, bad substitution, etc.) in any output.

End-to-end tests against a mock Retroplay server with mock tools — no network needed. They cover full builds, updates, version retirement, ECS exclusion, failure recovery, interrupted builds, `--rebuild`, `--dry-run`, disk-space refusal, running from another folder, overlapping runs, cron's minimal `PATH`, and temp-folder cleanup (including when a run is stopped part-way). GitHub Actions runs them on Ubuntu and on macOS with the stock bash 3.2 (`.github/workflows/tests.yml`).

## Typical usage

```bash
./all.sh                  # the nightly job, by hand
./all.sh --dry-run        # what would happen?
./all.sh --rebuild        # rebuild everything from the downloaded archives
./ecs.sh --rebuild        # ...or just one variant
./install_cron.sh         # nightly at 2am
./uninstall_deps.sh --dry-run
```
