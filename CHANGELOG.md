# Changelog

## 2026.09.24 (artwork refresh)
### Changed
- Artwork in the collection is now always written from the packs' current version, `iGame.data` included. Checking each file first (timestamps, then sizes) was measured slower than simply writing it - 23s against 11s over 1500 games - so the checks are gone.
- `--refresh-artwork` now means "refresh every game", including ones the nightly gap-fill would skip. It works from `all.sh`, the `aga/ecs/rtg` wrappers, `start.sh --merge` and `merge.sh`.
- Merge reports its mode ("refreshing" or "filling gaps only") and counts the artwork files added and refreshed. `all.sh` says which variant it is refreshing.

## 2026.09.24 (backups, artwork refresh, PFS warning)
### Changed
- The `.retroplay` state folder is no longer backed up. It holds only the queue and build markers, and the next run rebuilds what it needs. Set `STATE_BACKUP="yes"` to keep the rolling copies.

### Added
- Artwork files already in the collection (including `iGame.data`) are refreshed automatically when the pack's copy is newer, or the same age but bigger. The two timestamp tests are shell built-ins, and sizes are only compared when timestamps match, so this costs nothing on the usual "already up to date" run (checking sizes for every file would have taken a 6s merge to 22s over 1500 games).
- `--refresh-artwork` (on `all.sh`, `start.sh --merge` and `merge.sh`): replaces artwork already in the collection, including `iGame.data` and other artwork files. `iGame.iff` was already replaced on every merge.
- Artwork archives already downloaded are not fetched again: the cached file's size is compared with the size the source reports, from its listing or an HTTP header request, before anything is downloaded.
- Every run built for PFS now ends with a prominent reminder to run `setfnsize <drive:> 107` on the Amiga partition first, warning that copying long filenames without it can corrupt the partition.

## 2026.09.24 (state tidy-up)
### Added
- `.retroplay` is tidied at the start of every run. Removed: staging and artwork work folders left by an interrupted run, temporary listing downloads, markers already acted on, empty queue files, and attempt counts for archives that no longer exist. Previous artwork versions are trimmed to `ARTWORK_KEEP_BACKUPS`. Kept: the queue, build markers, what is complete, gap-fill stamps and artwork manifests. It reports how much it freed.

## 2026.09.24 (startup speed)
### Fixed
- Step 1 could sit silent for many minutes on a Pi. The state backup tarred the WHOLE `.retroplay` folder, which now holds previous artwork versions - gigabytes, gzipped on every run, seven copies kept. It now backs up only the small state (queues, build markers, artwork manifests) and skips anything over `STATE_BACKUP_MAX_MB` (50) with a warning. A 16 MB test case went to 8 KB.
- Step 1 now reports each thing it does (checking the drive, tidying folders, clearing logs, backing up), so it is never silent.

## 2026.09.24 (artwork message)
### Fixed
- The "artwork directories are missing" notice was out of date: it listed a fixed set of folder names, looked in the wrong place, and pointed at a forum thread even though the packs are now downloaded and installed automatically. It now names exactly which packs and flavours are missing (e.g. `iGame_AGA/laced`, `TinyLauncher`), says they will be fetched for you - or, with `ARTWORK_SYNC=auto`, that it happens during this run - and stays quiet once the artwork is there. Artwork installed the older flat way counts as present.

## 2026.09.24 (artwork matching)
### Fixed
- Artwork whose folder differs only in capitalisation (`SUPERSKIDMARKS` vs `SuperSkidmarks`) was reported as missing. Matching now falls back to a case-insensitive lookup.
- Artwork installed the older flat way (`iGame_AGA/Covers/...`) was ignored once `lores/` and `laced/` existed. The flat folder is kept as a fallback straight after the flavour folder.

### Added
- `merge.sh --why NAME`: explains where artwork for one game was looked for - every set and section tried, plus anything in the artwork folder with a similar name.

## 2026.09.24 (artwork lookup)
### Fixed
- merge.sh reported hundreds of games as having no artwork when they were not games at all. Two separate scans were still in use: every folder 1-4 levels down, plus every `.info` 5-8 levels down. WHDLoad archives ship icons for drawers *inside* a game (`data`, `Maps`, `Docs`, `MapsFr/CATACOMBES`), so those were each treated as a game and reported.
- One rule now decides: a game is a folder with its matching `.info` icon that is not itself inside another game. Category folders, letter folders and in-game drawers are excluded, and the count reported is the number of games actually processed.
- Archives that wrap the game in a versioned folder (`Might&Magic3_v1.2_2346/Might&Magic3`, `Elvira_v1.4_De_0474/ElviraDe`) resolve to the game inside, so their artwork is found instead of being reported missing. A wrapper is recognised by holding nothing but the game folder, so a real game is never mistaken for one.

## 2026.09.24 (usability)
### Fixed
- `all.sh` appeared to hang for minutes before "Checking for updates": the artwork check fingerprinted every installed pack using one process per file. It now uses a single batched listing - 8s to under 1s for 3,000 files, and far more on a real pack. Every startup step also announces itself with the time.
- `start.sh --help` ran the tool check first (and offered to install things) instead of showing help; `install_cron.sh --help` failed with "crontab not found". Help is now answered before any checks.
- Undocumented options added to `--help` (`quick.sh --skip-update`, `-h/--help` in merge.sh and update.sh).

### Added
- Consistent output styling: numbered steps with timestamps, colour only on a terminal (honours `NO_COLOR`), plain text in logs.
- Script headers list each script's current options and point at `--help`.
- A completely rewritten README for GitHub.

## 2026.09.24
### Fixed
- Artwork: the `_Laced` archives and `TinyLauncher.lha` were never fetched. `--artwork-plan`/`--artwork-sync` with no `--for` now cover every published archive (both flavours plus TinyLauncher).
- merge.sh treated every folder under `WHDLoad` as a game, so category, letter and in-game folders (`data`, `save`) were each reported as having no artwork. A game is now a folder with its matching `.info` icon, and nothing inside a game is examined.
- merge.sh's built-in art order (`Screens,Covers,Titles`) disagreed with the configured `ART_ORDER`; it now follows the config, with `--art` still overriding.
- The artwork checks in `update.sh` and `doctor.sh` looked for the old flat layout and reported artwork as missing. They understand `iGame_AGA/{laced,lores}/<Section>` now, and say how to fetch it (`./start.sh --artwork-sync`) and from where.
- The archive cache folder is now `downloads/artwork_archive` (singular), migrated automatically.

### Added
- At the end of a hands-on run, offers to delete saved backups (state backups and previous artwork versions). Unattended runs never ask, and the question answers "no" by itself after 3 minutes.

## 2026.09.23
### Added
- Tidier folders: `artwork/`, `build/`, `downloads/`, `logs/`, `reports/`. An older flat folder is migrated automatically, once, keeping everything. The scripts also work from a `scripts/` subfolder.
- `LOG_RETENTION_DAYS` (default 1, `0` = keep for ever) prunes old logs each run.
- Artwork now uses the published archive names, installed where merge.sh reads them:
  `IGame_<Section>_AGA_Laced.lha` -> `artwork/iGame_AGA/laced/<Section>/`, `_LoRes` -> `lores/`, `IGame_<Section>_RTG.lha` -> `artwork/iGame_RTG/<Section>/`.
- Artwork archives are cached in `downloads/artwork_archive/`.
- `--for <variant>`: a single-variant build fetches only the artwork it needs; `all.sh` fetches everything.
- Downloads show a progress meter; each install names the archive and its destination.
- `doctor.sh` reports installed artwork, the cache size and the log-retention setting; `setup.sh` offers to fetch the artwork.

- `install_cron.sh` (and `start.sh --schedule`): `--time HH:MM`, `--show`, `--disable`, `--dry-run`, `--yes`. Other people's cron entries are never touched.
- ShellCheck runs in CI (errors fail the build, style warnings are advisory).

### Fixed
- The folder migration ran before the unmounted-drive check, and during `--dry-run`; both now happen in the right order.

## 2026.09.22 (third update - artwork sync)
### Added
- `artwork_sync.sh`: downloads, checks and installs the `iGame_*` / `TinyLauncher` artwork packs, with `--status`, `--plan`, `--sync`, `--verify` and `--rollback`. Reached through `./start.sh --artwork-*`.
- Only `iGame_*.lha` and `TinyLauncher.lha` are used from the source; everything else is ignored.
- Archives are validated before they replace the cache, unpacked to staging, layout-checked, and installed only after the previous folder is backed up.
- Artwork you changed yourself, or that this tool never installed, is never overwritten automatically.
- The nightly run checks artwork first, inside the one existing lock; `ARTWORK_FAILURE_POLICY` decides whether a failure stops the run or lets it continue on the old artwork.
- `start.sh --sync`, `--plan`, `--setup`, `--schedule`.

### Fixed
- `extract.sh` no longer runs `chmod -R u+w` across an existing destination, and reads `/etc/os-release` instead of executing it.
- Downloaded archives named `<name>.lha.part` were not integrity-checked, so a corrupt download could replace a good cached archive.
- `update.sh` now uses `#!/usr/bin/env bash`; per-script version numbers replaced by the single suite version; the `aga/ecs/rtg` wrappers use an absolute path.

## 2026.09.22 (second update)
### Added
- `setup.sh`: one-step, repeatable install - tools, `unlzx` built from Aminet source, Linux locales, `retroplay.conf`, nightly run, final check.
- Status view (`--status`, menu option 9, summary at the top of the menu) and `--test-notify` (menu option 10).
- Plain-English results in summaries, notifications and `start.sh`.
- Unmounted-drive guard: a missing output-drive marker stops the run instead of rebuilding onto the SD card.
- Rolling backups of the state folder, restored automatically if it is lost.
- New downloads are integrity-tested; corrupt ones are fetched again in the same run (`VERIFY_DOWNLOADS`).
- Warning when `wget`'s download log can't be read.
- `doctor.sh` suggests a USB SSD when building on a Pi's SD card, and never creates the output folder.

### Faster
- `sort.sh`: 235 s -> 10 s for 2,000 game folders (no per-folder processes, one tree scan, inline renames). Output verified identical.
- `update.sh` first download: 61 s -> under 1 s for 1,500 archives (one pass per folder). Results verified identical.
- Artwork gap-fill only runs when artwork changed or every `GAPFILL_DAYS` days.

## 2026.09.22
### Fixed
- `all.sh` hung forever when `--dest`, `--variant`, `--art` or `--demo-art` was given without a value.
- `start.sh` crashed ("unbound variable") when `--dest`, `--set`, `--art`, `--demo-art` or `--report-missing` had no value. Every value option in every script now stops with a clear message.
- `update.sh` reported "nothing new" (exit 2) when `wget` was missing.
- `extract.sh` reported success when archives failed, so a failed archive was dropped from the queue and never installed.
- `sort.sh` crashed when an old temp folder without an owner record was left in the temp folder.
- The locale check rejected `C.UTF-8` / `en_US.ISO-8859-1` spellings.
- Counting bugs ("integer expression expected") in `extract.sh` and `quick.sh --skip-update`.
- `doctor.sh --help` ran the full check instead of showing help.
- Files re-published by the server under the same name were downloaded but never processed.

### Added
- Corrupt archives are retried, then moved to `old/corrupt-<date>/` and re-downloaded; the rest of a batch is never blocked.
- Download retries with growing pauses; partial downloads are never processed as complete.
- Consistent exit codes (0, 2, 3, 4, 5, 130).
- Validation of variant names (commas allowed) and art orders.
- Lock records: a refused run shows which run holds the lock; a stale-safe lock when `flock` is unavailable.
- Atomic state-file writes; plain timestamped progress lines in logs and cron output.
- `tests/option_matrix.sh`: every option of every script; the test runner works from `tests/` or the project root.
