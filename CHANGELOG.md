# Changelog

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
