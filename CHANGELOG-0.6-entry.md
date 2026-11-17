## 0.6 - 2026-11-15

### Added
- **Amiga-safe names.** The last job of every run that changed something runs
  `amiga_names.py` over each collection and each dated batch: accented letters
  lose their accents and `#`, `?` and `\` become `_`. `-` and `+` are legal on
  the Amiga and are left alone. `AMIGA_NAMES="no"` or `--no-amiga-names` turns
  it off; `--plan` shows what it would change; every rename is listed in
  `logs/amiga_names.log` and counted in the run report.
- **`logs/last_run.log`** - a plain-text copy of a run started by hand at a
  terminal (`RUN_LOG="no"` turns it off).
- **`MIRROR_DIRS`** in `retroplay.conf`: the server folders `update.sh`
  mirrors, which used to be a list written into the script.
- **`DOWNLOAD_TIMEOUT`** (60 s stalled) and **`ARTWORK_TIMEOUT`** (one hour
  per pack, doubled from 30 minutes; 0 = no limit) in `retroplay.conf`. Both
  used to be fixed values in the scripts.
- `setup.sh` measures the drive you choose and suggests how many collections
  fit; it also installs `python3` and checks `amiga_names.py` is there.
- `doctor.sh` checks the names step, shows the mirror list and the run log.
- `all.sh --plan` (the name `start.sh` and the README already used).

### Changed
- **Logs and reports share `logs/`, and only the latest of each is kept.**
  `logs/` is cleared at the start of every run, `all_cron.log` holds the last
  nightly run only, and a new report replaces the previous one. An existing
  `reports/` folder is folded in on the next run. `LOG_RETENTION_DAYS`,
  `LOG_MAX_MB` and `LOG_KEEP` are still accepted but no longer used.
- `ARTWORK_SYNC` now defaults to `auto`; `retroplay.conf.example` and the
  built-in defaults are the same file's worth of settings.
- `start.sh` no longer stops for a missing locale: it accepts whatever
  `extract.sh` accepts (`en_GB`, `en_AU`, `en_US`, `C`) and otherwise warns.
- Help: `start.sh` has one help text (the second, older copy is gone);
  `all.sh --help` lists every exit code and the options it never mentioned
  (`--preview-new`, `--jobs`, `--variant`, `--version`).

### Fixed
- `uninstall_deps.sh` looked for its list of installed tools beside the
  scripts, while `lib.sh` writes it in the main folder. After `setup.sh` had
  tidied the scripts into `scripts/` it reported "nothing to uninstall". It
  now uses the same folder rule as `lib.sh`, and folds in a list left beside
  the scripts.
- `rp_pick_locale` took an unset `LANG` for a match, so a machine with no
  UTF-8 locale was told it had one.
- Without `curl`, an artwork download waited 30 minutes for a host that did
  not answer: `wget -T` overrode the 15-second connect timeout given just
  before it. Each `wget` timeout is now set by name, the overall limit comes
  from `timeout`/`gtimeout`, and with `curl` a stalled transfer is dropped
  after `DOWNLOAD_TIMEOUT` instead of waiting out the whole limit.

