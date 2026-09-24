# Changelog

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
