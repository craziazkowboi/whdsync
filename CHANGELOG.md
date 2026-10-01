# Changelog

## 0.5 - 2026-10-01 (laced variants, the Pi "hang", the macOS sort failure, and the paths that pointed at the old layout)

### Last checks before release
- **Licence: MIT, stated once and consistently.** `LICENSE` said MIT while
  `start.sh`'s header said Creative Commons BY-NC 4.0 (and a different
  year). Both now say MIT, copyright 2025-2026 Craziazkowboi and whdsync
  contributors, and the README and `GITHUB_SETUP.md` agree.
- **Installing an update could leave a game half-copied in the live
  collection.** Each changed game's folder was deleted and the new one copied
  in its place. Now each game is copied in beside the old one and swapped in
  by renaming, loose files (the `.info` icons) by copy-then-rename, and a
  marker records that an install is under way; a run stopped part-way is
  finished or undone, game by game, before the next run touches that
  collection. Files only the old version had still disappear with it.
- **Archives are unpacked one at a time in a sealed folder.** The extraction
  tree sits in the output folder next to the finished collections, and an
  archive member named `../../..` could have written beside them. Each archive
  now unpacks several empty levels down inside its own folder; anything that
  climbs out is caught there, the archive is refused ("REFUSED: it has
  entries that climb out of their folder") and goes through the normal
  retry-then-set-aside path. Links pointing out of an archive are removed.
  Roughly one extra rename and two tiny scans per archive.
- **Artwork packs: the `..` check was both too strict and useless.** It
  refused a whole pack if any folder had two dots in its name ("Dr..Doom"),
  and could not catch a real `../` escape, which has already happened by the
  time the tree is looked at. Packs now unpack in the same sealed way; links
  and hard links are still refused.
- **Lock record removed after the lock was released.** A new run could take
  the lock and write its record in between, and the old run then deleted the
  new run's record. The record is now removed first.
- **Two runs breaking the same stale lock (no `flock`) could both go ahead.**
  It was broken with "rm, then mkdir". Now an atomic rename decides which run
  breaks it, and a run that finds the record changed underneath it backs off.
  Tested with eight runs racing for it: exactly one holds it.
- **A recycled PID kept a dead run's lock alive.** After a reboot the PID in a
  stale lock can belong to an unrelated process; `kill -0` alone then called
  the lock live, for ever. The live process must now also be running the
  script that took the lock. Anything uncertain still counts as alive.
- **Replacing an artwork pack removed the old backup before the new one
  existed**, so a failed move left no rollback copy at all.
- **Reports gave "build" a time for builds that never started** - a
  nothing-to-do run, or one stopped in Preflight, reported its plan or
  preflight time under "build".
- The support bundle shows a setting's value only if it is one of the suite's
  own settings known to say nothing private; anything else, including a
  setting it does not recognise, is `<hidden>`. E-mail addresses and
  `token=`/`key=`/`password=` values are hidden wherever they appear.
- Manifests record `archive_fingerprint` (the downloaded archive names) and
  `artwork_fingerprint` (the packs used, as artwork_sync recorded them, plus
  the art order). Both are cheap listings, defined in `lib.sh`.
- "Automatic" job counts live in one tested function (`rp_auto_jobs`) instead
  of two copies; the numbers are exactly the ones used before (checked across
  48 machine sizes), and `--verbose` says what was chosen and why.
- A run building four or more collections says what that multiplies.
- The suite stamp is `2026.10.01.2`, so these files cannot be mixed with the
  earlier 0.5 download without the run refusing.

### A314 GUI, last checks
- New: **Status** and **Check set-up** (read-only, so they never trigger the
  copy to the Amiga), **Rebuild**, **Skip update**, **Refresh artwork** and
  **Verbose output** - all options `start.sh` has. A test now checks every
  option the GUI can send against `start.sh`'s own parser.
- The output list was created by passing tags inline to `CreateGadgetA()`,
  which takes a pointer to a tag array; fixed like the `SystemTagList` call.
- On a screen smaller than the window (a 640x256 PAL Workbench) Intuition now
  fits the window to it instead of refusing to open it.
- The two settings to edit are in a box at the top of the file.

### Release housekeeping
- **The scripts said "release 0.4"** on every banner, `--version` and in the
  release check, although this changelog was already describing 0.5.
  `RP_RELEASE` is 0.5 and every script carries the 2026.10.01 stamp. The test
  that checked the banner had the old number written into it; it now reads
  the release from `lib.sh` and checks it against the top of this file.
- `gitignore.txt` is now `.gitignore`, which is what `GITHUB_SETUP.md` has
  always said it was.

### Fixed in the final pass
- **`./start.sh --doctor` refused to run when the archive tools were
  missing** - the one command whose job is to explain how to install them.
  `--status`, `--plan`, every `--why-*`, `--show-failed` and `--unlock-stale`
  were blocked the same way. Commands that extract nothing now skip the tool,
  unlzx, detox and locale checks; a real build still stops for them.
- **The next ordinary run deleted a `--preview-new` batch** as "wrong folder
  layout from the old path bug": the layout rule took the preview's own
  `PREVIEW_ONLY.txt` for debris. Preview batches now carry a machine-readable
  `.preview_marker`, and only a folder with that marker may hold the readme.
- **A preview stamped the live collection's manifest `kind=preview`** with
  that day's date, although a preview leaves the collection untouched.
- **A hand-run `--artwork-sync` could change packs underneath a nightly
  build.** It took a private `.artwork.lock` that nothing else held (and no
  lock at all without `flock`). It now takes the same run lock as every
  other stage.
- **An interrupted artwork swap was never put right.** 0.5's safer
  replacement stages under `<name>.incoming.<pid>` and retires under
  `<name>.previous.<pid>`; a power cut between its two renames left the pack
  missing until a successful re-download. The next artwork run now puts the
  previous version back, removes the half-staged one, and leaves alone
  anything belonging to a run that is still going.
- `./aga.sh --rebuild --help` (help anywhere but first) passed `--help` on to
  a sync; `start.sh` only recognised `--help` in first place before its tool
  check. Help is recognised anywhere now, and never runs anything.
- `setup.sh` offered three variants by default while everything else built
  five, and wrote every artwork pack into the config whatever was chosen. It
  now defaults to the five, says what five cost before asking, and fetches
  only the packs the chosen variants use.

### A314 GUI (`a314_retroplay_gui.c`)
- **The ECS-Lo and AGA-Lo boxes sent `--ecs-lo` / `--aga-lo`, which
  `start.sh` has never accepted** - every run with one ticked stopped with
  "Unknown option". They are now **ECS laced** and **AGA laced**
  (`--ecs-laced` / `--aga-laced`); plain ECS and AGA already are LoRes.
- **"Merge with Amiga" copied from `PI0:retro`**, a folder the scripts stopped
  producing when collections became one per variant. `PI_RETRO_SOURCE` is now
  `PI_BUILD_SOURCE` (the Pi's `build/` folder) and the collection copied is
  the one for the variant ticked. The window logs both settings when it
  opens.
- **The output list was created with `CreateGadgetA()` and inline tags**, the
  calling convention of the varargs `CreateGadget()`; the first tag value was
  read as the tag-list address.
- The command line was built with `strcpy`/`strcat` into a 512-byte buffer
  that the four text fields together could overrun. Everything now goes
  through bounded `CopyStr`/`AppendStr`; a command or path that does not fit
  is refused and logged, never run or copied cut short.
- Text fields containing a quote, `*` (the AmigaDOS escape character) or a
  shell metacharacter are refused: they would change the command run on the
  Pi. Filenames with `"` or `*` are skipped with a note rather than passed to
  `Copy`.
- A C99 compound literal is gone, so the SAS/C build line in the header works.
- Checked with a C99 syntax pass (`-Wall -Wextra`, stub Amiga headers) and the
  string helpers run under AddressSanitizer. It has still not been compiled or
  run on a real Amiga.

### Added in the final pass
- `./start.sh --why-queued NAME`: read-only. Which collections have an archive
  waiting and why, when it was downloaded, how often it has failed, whether it
  was set aside as corrupt or replaced by a newer version, and which
  collections leave it out on purpose (e.g. AGA releases in ECS).
- `./start.sh --support-bundle`: `logs/whdsync-support-<date>.tar.gz` with
  versions, tools, settings, status, the doctor report, queue and manifest
  summaries and recent logs. Private values are replaced with `<hidden>` in
  every file, logs included; no game, archive or artwork file goes in.
- `./start.sh --clean-backups [--yes]`. A build no longer ends by asking
  whether to delete backups - that question came before the summary, so a
  finished run sat looking unfinished for up to three minutes. The report
  mentions them once they pass 200 MB.
- **Five phases**: `[1/5] Preflight`, `[2/5] Updates` (artwork and archives),
  `[3/5] Plan`, `[4/5] Build`, `[5/5] Finalise`. Artwork used to be a
  numbered step of its own and nothing marked the end. The `=====` / `---`
  banners inside the build go through the shared presentation API
  (`rp_task`, `rp_subtask`; `rp_phase`, `rp_detail`, `rp_summary_row` added
  alongside), so they follow `--quiet` and the colour setting.
- The report now shows how long extracting, sorting, the artwork merge and
  installing took, summed over all collections - taken from `$SECONDS` around
  work that happens anyway, not from extra scans.
- `NOCOLOR` is honoured like `NO_COLOR`. An explicit `--color=always` still
  wins over both, as the no-color.org convention asks.
- The lock record includes the script version, and `--unlock-stale` shows
  PID, machine, start time, command and version one per line.
- Manifests carry `manifest_version=1`, and each collection gets its own copy
  as `.whdsync_manifest.conf` (a dotfile, so the layout rule is unaffected),
  so a collection copied elsewhere still says what it is.

### Considered and not done
- **`NO_COLOR` overriding `--color=always`** (one review): no-color.org says
  a per-run command-line option should override the variable, which is what
  the suite already did.
- **Automatic `JOBS` from storage type**: each stage already scales from CPU
  count and caps by memory (now in one tested function). Telling a USB SSD
  from an SD card through a USB bridge is unreliable, and guessing wrong
  makes a Pi slower, not faster. The per-stage timings are the evidence to
  tune from.
- **Rewriting all output into a new format**: the phases and banners were
  brought into the shared API; the per-game progress inside each stage was
  left as it is.
- **Replacing `rp_swap_collection` with `rp_replace_tree`** (one review
  called it critical): the swap is two renames in one folder with a recovery
  step that runs before anything else, and it is now tested at every point
  it could be cut. It is separate on purpose - a collection keeps no backup
  copy (a second 9 GB tree per variant), an artwork pack does.
- **Listing every archive before unpacking it**: parsing four tools' listing
  formats on two systems could not be tested here, and a check that works on
  one system only is worse than none. Unpacking in a sealed folder catches
  the same thing on every system.
- **A full ownership record for every temporary object**: the in-flight names
  carry the PID of the run that made them, recovery acts only when that run
  is gone, and the collection-level ones are only ever touched under the run
  lock. A record file per object would add a write to every game installed.


### Added
- **`all.sh` builds the laced variants.** The shipped default is now
  `VARIANTS="aga ecs rtg aga-laced ecs-laced"`, and `ARTWORK_PACKS` fetches
  `AGA_Laced` and `ECS_Laced` to match - a laced variant whose pack is not
  fetched is built from the fallback chain and comes out identical to the
  plain one, which is worse than not building it.
  **This is five complete collections on the drive where there were three.**
  Trim `VARIANTS` in `retroplay.conf` on a small card; the run now prints the
  list it is about to build, and the existing space check still stops before
  anything is overwritten.
- `all.sh --laced` builds the laced form of each AGA/ECS variant selected, and
  `all.sh --all` builds every variant.
- `./aga.sh --laced` and `./ecs.sh --laced`.
- `--quiet`, `--verbose`, `--color=MODE` and `--no-color` now work on
  `update.sh`, `extract.sh`, `merge.sh` and `sort.sh` when they are run
  directly, through one `rp_common_opt` in `lib.sh`. Previously only
  `start.sh` and `all.sh` honoured them.
- `NICE=auto|no` in `retroplay.conf`. Off a terminal - cron, a redirected log
  - extraction workers run under `nice` (and `ionice` on Linux), so a nightly
  build leaves a Pi usable. An interactive run is never slowed down.

### Fixed
- **`merge.sh --aga-laced` reported "destination folder not found:
  build/retro" on a machine with three working collections.**
  `rp_default_collection` was handed the command-line spelling
  (`aga-laced`) and looked for `build/retro_aga-laced`; collections are named
  with the folder spelling (`retro_aga_laced`). It now normalises, and when a
  variant genuinely has no collection yet it says so instead of silently
  falling back to `build/retro`.
- **`retro_rtg` looked like it had hung after "installing and adding
  artwork".** It had not - `merge.sh` was reading the artwork packs, and said
  nothing at all while it did. Three things changed:
  - it now names each source as it indexes it, with a count and a total;
  - the index does one `find` per section and category instead of one per
    letter of the alphabet - 9 calls per source where there were 324, and an
    RTG build reads seven sources;
  - the lower-case index key is a parameter expansion instead of
    `printf | tr`, removing two forked processes per artwork folder.
  The destination check and the settings banner also moved *before* the scan,
  so a wrong `--dest` is reported in a second rather than after it.
- `./start.sh --aga-laced --refresh-artwork` dropped into the menu.
  `--refresh-artwork`, `--only-missing` and `--report-missing` only mean
  anything to the artwork merge, so they now select that stage. A bare variant
  flag still opens the menu - that is what it has always meant - but the menu
  now says which collection it is about to work on, and the help no longer
  claims `--aga` "runs merge.sh".
- `./aga.sh --help` ran `start.sh --sync --aga --help` and described a build
  nobody had asked for. Same for `ecs.sh` and `rtg.sh`.
- `merge.sh` looked for TinyLauncher beside the scripts - the pre-migration
  location - so the TinyLauncher fallback never fired on a current install.
- `update.sh --dry-run` compared remote names against the *script* folder
  rather than `downloads/`, reporting every file on the server as new.
- `sort.sh`'s compliance check reset the destination to `build/retro` after
  the run had already resolved it, so a standalone run reported on a folder
  that was not there while the collection it had just sorted went unchecked.
- `merge.sh` wrote `merge_errors.log` beside the scripts and `sort.sh` wrote
  its logs into whatever folder you started from. Both go to `logs/` now, and
  `all.sh` gathers each stage's log into `retroerror.log` - it calls the stage
  scripts directly, so the gathering `start.sh` does at the end of a manual
  run never happened for a pipeline run, and the summary reported "No errors
  logged" after a stage had written a page of them.
- `ARTWORK_FETCH_COMMAND` could not carry arguments: the whole string was used
  as one executable name, so `python3 /path/script.py` could not run at all.
  It is split into an argument list and run directly - no shell, no `eval` -
  and an executable that is not on `PATH` is reported before anything starts.
- A `#` in a setting truncated it: `NTFY_TOPIC="retro#build"` became `retro`.
  A `#` inside quotes is now an ordinary character, and only a `#` following
  whitespace starts a comment.
- `UPDATE_CHECK_INTERVAL_HOURS` was never checked for being a number, so
  `soon` or `-5` produced malformed arithmetic and a remote check every run.
- **`rp_replace_tree` could leave the drive with no collection at all.** It
  backed the live tree up first - across filesystems that means copy, then
  delete - and only then started copying the replacement in. The window with
  nothing in place was as long as a full copy of a 9 GB tree. The candidate is
  now staged beside the live folder first, then two renames in one directory
  swap them, and the previous collection is retired last. A backup location
  that cannot be written no longer fails the replacement, and never causes the
  previous collection to be deleted to hide it.
- `to_ilbm.py` searched only the first 64 bytes for the BMHD chunk, so a
  perfectly valid IFF that leads with `ANNO` or `CAMG` was reported as having
  none. The whole FORM is walked now, bounded by both its declared length and
  the real file size.
- `extract.sh` applied the "don't install packages mid-run" opt-in on macOS
  only, so a Linux build could stop at a `sudo` prompt.
- `--status` said the nightly run was "every night at 2am" whatever time was
  actually installed. It reads the time back out of the crontab now.
- `all.sh` announced five steps and only ever printed four, so a long build
  sat on "[4/5] Plan" for the whole job.
- `setup.sh` had two steps numbered 6 and no 7.
- `start.sh` blanked `RED` and `NC` immediately after `lib.sh` had chosen the
  colours, so its own messages came out plain even with colour on.
- `setup.sh` printed raw ANSI escapes and ignored `NO_COLOR`, so a piped setup
  log was full of control characters.
- `merge.sh --help` listed `--only-missing` twice, attached its explanation to
  the wrong option, and gave the wrong default destination.

### Changed
- `ls -1 ... | sort | awk` and `ls | grep -c .` are gone from the report and
  backup housekeeping, replaced by `rp_count_matching`, `rp_newest_matching`
  and `rp_prune_oldest` in `lib.sh` (ShellCheck SC2012; a newline in a name
  split one entry into two).
- `sleep 0.1` in the "wait for a free job slot" loops is now `rp_short_sleep`,
  which probes once and falls back to `sleep 1`. A `sleep` that rejects
  fractions turned that loop into a busy loop burning a core.
- `sort.sh`'s worker no longer calls a string `issues` while
  `check_path_compliance` has a local array of the same name (SC2178/SC2128).
- `rp_atomic_write` and a few other `A && B || C` chains are spelled out as
  `if`/`else`. `rp_atomic_write` decides whether a queue survives a crash and
  should be readable at a glance.
- Removed dead code: `build_quick_args` and the `quick` action in `start.sh`
  (unreachable since `quick.sh` became a shim), and `required_art_dirs` in
  `update.sh` (never read, and out of date with the config).

- `all.sh` reported every collection's build time as zero: `vstart` was read
  as `${vstart:-$SECONDS}` and never assigned anywhere, so the Time column in
  the summary was always `SECONDS - SECONDS`. It is set at the start of each
  collection's own work now.

### "ERROR: sorting failed" on macOS
- **Every build on a Mac failed at the sort, after the sort had finished.**
  `sort.sh` runs under `set -e`, and its cleanup trap asks `pgrep -P` for any
  child processes left to stop. With none left, `pgrep` exits 1. On Linux
  that never happened, because procps `pgrep` counts the `$(...)` subshell it
  runs in as a child. macOS's BSD `pgrep` leaves out its own ancestors, so it
  found nothing, exited 1, and errexit ended the cleanup right there, taking
  the whole sort down with status 1 after it printed "Sort operation
  complete". That is why it worked on the Pi and failed on the Mac, and why
  there was nothing in the logs: nothing had actually gone wrong with the
  sort. Introduced in 0.4 with the whole-tree child cleanup.
  Fixed three ways: `rp_child_pids` always returns 0 ("no children" is an
  answer, not an error); `rp_reap_children` guards its one fallible line;
  and `sort.sh`'s cleanup turns errexit off before it starts, so no tidy-up
  step can ever again cut a finished run short.
- **A failed stage now says what happened.** "ERROR: sorting failed" said
  neither which stage, nor how, nor where to look. Every stage failure now
  gives the exit status and its meaning, confirms the collection was not
  changed and the archives stay queued, and points at `logs/retroerror.log`,
  which gets the same record.
- **`sort.sh` names the command that stopped it.** It runs under `set -e`,
  which stops at the first failing command without a word. It now prints the
  command, its exit status and the line, and writes the same into
  `logs/sort.log`, which the pipeline copies into `retroerror.log`.

### doctor.sh
Brought into scope on request. Every fix below was reproduced on a real
folder tree first.
- **Every finished collection was reported as "not built yet".** It looked
  for `<output>/retro_aga`; collections have lived in `build/retro_aga` since
  the layout change.
- **"downloads use 0 MB", always.** The archives were measured with bare
  relative names from the scripts' folder instead of `downloads/`, so the
  rebuild-space warning computed from that figure could never fire either.
  The quarantine folder (`downloads/old`) had the same problem.
- **The laced artwork was reported missing however often it was
  downloaded.** doctor built the folder name from the variant name and looked
  for `iGame_AGA_LACED` / `iGame_AGA_Laced`, which have never existed - the
  laced flavour lives inside its pack, at `iGame_AGA/laced`. With laced now in
  the default variants, this would have warned on every machine. doctor now
  asks `lib.sh` (`rp_artwork_dir_for`, `rp_artwork_installed`), the same rule
  `update.sh` and `all.sh` use, instead of keeping two private copies of it.
- TinyLauncher in `artwork/` was never reported (it looked beside the
  scripts), and the "no artwork" message said "next to the scripts".
- A schedule installed with the current `whdsync-all-sh` marker read as "not
  installed". Both markers are matched now, as plain text (`grep -F`), the
  way `install_cron.sh` writes them - and the time shown is read out of the
  crontab rather than assumed to be 2am.
- The locale check demanded `en_US.ISO-8859-1` by name and called anything
  else a problem, though `extract.sh` is equally happy with the en_AU and
  en_GB ones. It now checks the same candidate lists through the same helper
  `extract.sh` uses; a missing Latin-1 locale is a warning, since it only
  affects a few old archive names.
- Raw ANSI escapes throughout, so `NO_COLOR` was ignored and a saved report -
  the thing people send to someone else - was full of control characters.
  It uses the shared colour decision now and accepts `--color=MODE`.
- The "no bash 4" fix always said `brew install bash`, on Linux too.

### Notes on what was NOT changed
- No blanket `set -e`. Adding errexit everywhere fails 121 of the tests: the
  pipeline deliberately tolerates non-zero and turns "3 archives failed" into
  a completed build with a warning.
- The `${ARRAY[@]+"${ARRAY[@]}"}` guards stay: bash < 4.4 errors on
  `"${arr[@]}"` for an empty array under `set -u`, and every guarded array has
  an empty case in ordinary use.
- No `kill 0`.
- The proposed rewrite of `all.sh` into a fixed five-phase display was not
  done. The reported problem is the opposite - not enough output during the
  long silent stretches - and the concrete symptom (step 5 never printed) is
  fixed above.
- `--support-bundle`, `--why-queued` and `--status --json` remain deferred.
- ShellCheck could not be run in the environment these changes were made in
  (no package for it there). The ShellCheck-class findings above were fixed
  and verified by hand and by test; CI is still the authority on the rest.

### Tests
651 automated tests (was 386) and 231 option checks (was 205). Every fix above
has a test that fails without it.

## 0.4 - 2026-09-29 (hardening pass: strict mode, temp files, child processes)
### Fixed
- **The Latin-1 extraction passes still never ran on Linux.** Yesterday's
  locale fix chose the right locale but did not export it, and
  `extract_archive` runs inside `timeout bash -c ...` - a fresh shell that
  sees exported variables only. `RP_LC_LATIN1`/`RP_LC_UTF8` are exported now.
  This was a regression introduced by that fix; it only ever affected machines
  with `timeout`, which is to say every Linux one.
- The Linux banner printed `Operating System:` and nothing else:
  `OS_NAME="$PRETTY_NAME"` was a leftover from when `/etc/os-release` was
  sourced. It is read field by field like the others now.
- `merge.sh` kept its logs at `/tmp/artwork_merger_*.$$` - a guessable name in
  a world-writable folder, and one that ignored `TMPDIR`. One `mktemp -d`
  folder per run instead, swept up like every other temp folder.
- `.lzx` archives were only integrity-checked when `lsar` happened to be
  installed, so on a normal setup (which installs `unlzx`) they never were.
- A zero-length file is now rejected as an archive outright, whatever its name.

### Changed
- `set -u -o pipefail` on `extract.sh`, `merge.sh` and `update.sh`, which is
  how the `PRETTY_NAME` bug would have been caught. **Not** `set -e`: adding
  errexit everywhere fails 121 of the 386 tests, because the pipeline
  deliberately tolerates non-zero from some commands and turns "3 archives
  could not be extracted" into a completed build with a warning.
- Interrupting a run now stops the whole child tree. `pkill -P $$` reached
  direct children only, so the `lha`/`wget` a worker had launched carried on
  writing after Ctrl-C. Not `kill 0`, which signals the process group: a
  finishing `extract.sh` would take `all.sh` down with it.
- Downloads give up on a host that will not answer after 15 seconds, while
  still allowing 30 minutes for a pack that is genuinely large.
- A symlink under `downloads/` that points outside it is removed after every
  mirror pass, and `wget --retr-symlinks` is used where the build has it, so
  extraction cannot follow a link out of the collection.
- `install_cron.sh` edits the crontab with `grep -F` throughout and matches
  both `retroplay-all-sh` and `whdsync-all-sh`, never the bare word.
- Log output carries a timestamp; terminal output does not.
- `to_ilbm.py` uses argparse, type hints and structured exception handling:
  a missing picture, a file that is not one, a bad `--like`, an unwritable
  destination and an impossible bitplane count each exit 1 with one sentence
  instead of a traceback.
- Artwork that converts to an empty or truncated IFF, or that came back too
  small to be a picture, is rejected rather than installed. The reason a
  conversion failed is copied into `logs/artwork_fetch.log`, which outlives
  the temp folder it used to point at.

### Tests
- 386 automated tests (was 344) and 205 option checks.

## 0.4 - 2026-09-29 (reported from the Mac and the Pi)
### Fixed
- **`--aga-laced` and `--ecs-laced` were never using the laced artwork.** The
  flavour folders (`iGame_AGA/laced`, `iGame_AGA/lores`) were mapped onto the
  set names about 300 lines AFTER the command line had been resolved, so
  `merge.sh --aga-laced` asked for a name that did not exist yet: it reported
  "no iGame_AGA_LACED directory found", then quietly built from the fallback
  chain - the lores artwork - instead. Running a laced build through `all.sh`
  was unaffected; running `merge.sh` directly was not.
- That message also named the folder the scripts are in rather than the
  artwork folder, which is what made the fault visible. It now names
  `artwork/` and says which `--artwork-sync --for` would fetch the set.
- **No more `setlocale: cannot change locale (en_AU.UTF-8)` on a Pi.**
  `extract.sh` exported `LANG`/`LC_ALL=en_AU.UTF-8` outright, but `setup.sh`
  generates `C.UTF-8` and `en_US.ISO-8859-1`. On a machine set up exactly as
  documented, every subprocess printed the warning - two lines per archive,
  straight through the progress bar. The locale is now chosen from what
  `locale -a` actually lists, honouring an existing `LANG` first.
- The same mismatch meant the **Latin-1 extraction passes never ran in
  Latin-1**: they asked for `en_AU.ISO-8859-1` while setup generates
  `en_US.ISO-8859-1`. They now use whichever Latin-1 locale exists, and are
  skipped rather than run under the wrong one when there is none.

## 0.4 - 2026-09-29 (shell review: safety, noise, per-item subprocesses)
### Fixed
- `artwork_fetch.sh` read the finished IFF's header with no stderr redirect and
  no status check, so a short or malformed file printed a Python traceback into
  the middle of the "found - converted and installed (...)" line. It now reports
  "size unknown" instead. The Pillow and image checks say which piece is
  missing rather than letting an ImportError speak for them.
- `all.sh` created its report scratch file about 170 lines before `trap finish
  EXIT` was installed. Anything that exited in that window - a bad option, a
  drive that was not mounted - left the file in `/tmp`. A stop-gap trap now
  covers it, and `finish` clears the side files by pattern.
- The lock record flattened its command line through `"$*"`, so
  `--dest "My Drive"` was written as two loose words. It is rendered from `"$@"`
  with the quoting intact.
- `artwork_fetch.sh` and `artwork_sync.sh` now clean up the way the other stage
  scripts do: capture the exit status, stop and reap any children, remove only
  this run's scratch folder, then exit with the status that was saved.

### Changed
- `approved()`, `target_for()` and `target_key()` in `artwork_sync.sh` used
  `cut` and `tr` - two or three processes per archive, on every name in the
  remote listing. They use parameter expansion now; classification was compared
  against the old code over 654 archive names with no differences.
- Two `df` calls in consecutive lines, and a `du` of the whole staged collection
  taken twice for the last variant, are now taken once.
- `artwork_fetch.sh` uses the shared `rp_heading`/`rp_info`/`rp_warn`/`rp_error`
  helpers, so its headings, indentation and stderr behaviour match every other
  script.
- Comments on the non-obvious functions now state purpose, assumptions, inputs,
  outputs and side effects.

**Not changed, deliberately:** the `${ARRAY[@]+"${ARRAY[@]}"}` guards stay. On
macOS's stock bash 3.2 - which this suite supports and CI tests - expanding an
empty array as `"${ARRAY[@]}"` under `set -u` is an "unbound variable" error;
bash only stopped doing that in 4.4. Every guarded array in `all.sh`
(`V_TOK`, `EXTRA_SET`, `INC`, `G_SIG`) is empty in the ordinary case, so
removing the guards would break the common path on a Mac.

## 0.4 - 2026-09-29 (engineering review: output, locking, state)
### Changed
- **`all.sh` no longer runs merge and sort through `start.sh`.** The engine
  called the interactive dispatcher, which re-printed its banner and re-ran its
  tool and locale checks for every variant - the reason one build looked like
  several unrelated tools starting in turn. The stages are now called directly
  and take `--called-from-all`, so `all.sh` owns the display and the children
  hand back a `key=value` result file instead of printing a summary each.
- Output levels: `--quiet` (errors, warnings and the result only), `--verbose`,
  `--debug`, and `--color=auto|always|never`. Warnings and errors go to stderr.
  `NO_COLOR` now follows the published convention everywhere - any non-empty
  value turns colour off, not only `NO_COLOR=1`.
- `./start.sh --help` leads with the seven everyday commands and groups the
  rest; `--help advanced` explains each advanced option in full. Every option
  that worked before still works.
- `quick.sh` is deprecated. It now runs `./start.sh --preview-new`, which does
  the same job through the engine and so gets the lock, the output-drive check,
  the shared queue, the report and the summary table. The old name keeps
  working for one release.

### Fixed
- **A finished collection is no longer deleted before its replacement exists.**
  The new one is built beside it and swapped in with two renames, so a power cut
  mid-build leaves the previous collection usable. A build now needs room for
  one collection twice over while it runs, and says so if there isn't.
- **One run at a time, properly.** `merge.sh`, `sort.sh`, `extract.sh`,
  `update.sh` and `quick.sh` take the same lock `all.sh` does when you run them
  by hand, so an interactive merge cannot work on a collection a nightly build
  is halfway through. Background workers no longer inherit the lock, which
  previously let a killed run hold it for ever.
- `ARTWORK_CHECK_INTERVAL_HOURS`, `ARTWORK_KEEP_BACKUPS`, `ARTWORK_FETCH_LIMIT`
  and `STATE_BACKUP_MAX_MB` were not checked for being numbers. A typo silently
  evaluated to 0 - which turned the daily artwork check into an every-run check,
  and could have emptied the artwork backup keep-count.
- Artwork progress no longer writes progress bars into a cron log: it now
  degrades to timestamped milestones like every other stage.
- The Retroplay listing is given 60 seconds with a 15-second connect timeout
  instead of 120 seconds across five directories, so `--dry-run` against an
  unreachable server reports in seconds instead of looking like a hang.
- The artwork-fetch count is read from a result file rather than scraped out of
  the child's console text, so rewording a message cannot change a report figure.
- `merge.sh` now reaps its workers and preserves the exit status on any exit,
  not only on Ctrl-C.

### Added
- Every finished collection records what it is in `.retroplay/manifest/` -
  counts, size, artwork order, filesystem and a fingerprint of the settings that
  affect output. `--status` reads it instead of walking the tree. A collection
  built by an older release simply has no manifest, which means "details
  unknown", never "needs rebuilding".
- Commands that explain themselves from what the run recorded:
  `--why-build VARIANT`, `--why-artwork NAME`, `--why-space`, `--show-failed`,
  `--retry-failed`.
- `--unlock-stale`: shows the lock's owner, host, age, command and path, and
  removes it only when that run is provably gone from this machine. It never
  removes a live lock or one taken on another machine.
- `--preview-new`: builds the dated folder of just the new games and leaves the
  collection alone. The batch carries a `PREVIEW_ONLY.txt` note and the archives
  stay queued, so an ordinary run still installs them properly.
- `JOBS`, `EXTRACT_JOBS`, `MERGE_JOBS` and `SORT_JOBS` in `retroplay.conf`, plus
  `--jobs N`. `auto` keeps exactly what each stage worked out before, so nothing
  changes unless you set one.
- The run report now shows the time each stage took, which is the thing to look
  at before changing any job count.

### Tests
- 344 automated tests (was 265) and 205 option checks. The option matrix's
  per-case limit is now 180 seconds (`MATRIX_TIMEOUT` to change it): at 25 it was
  measuring machine speed rather than catching hangs.

## 0.4 - 2026-09-28 (fixes from the Pi 400 install)
### Fixed
- **unlzx would not compile on a current Raspberry Pi OS or Xcode.** The Aminet
  source calls `mkdir()` and `getopt()` without including the headers that
  declare them; GCC 14 and clang 16 turn that into an error, so `setup.sh`
  stopped with `implicit declaration of function 'mkdir'`. setup.sh now adds
  the missing headers before compiling, with permissive compiler flags and the
  unpatched source as fallbacks, and prints the compiler's own message if the
  build still fails.
- **A failed artwork download was recorded as if the check had succeeded.**
  When the artwork host answered 503, the pack was correctly left alone, but
  the "checked recently" stamp in `.retroplay` was written anyway, so the next
  24 hours of runs skipped the artwork check and never retried. The stamp is
  now written only when the check actually finished; after a failure it is
  removed, so the very next run tries again. The pack's own record in
  `.retroplay` is untouched, so nothing that failed is left looking current.
- Artwork failures are now recorded in `.retroplay/artwork/last_failure` and
  shown by `./start.sh --artwork-status`, naming the archives still to do.

### Changed
- 265 automated tests (was 250), including the two faults above with mutation
  checks proving the new tests catch them.

## 0.4 - 2026-09-26 (engineering review)
### Changed (engineering review)
- One canonical version: the old per-script labels (merge 1.8.0, sort 3.0.0, extract 1.4.0) are gone; `--version` on all.sh and start.sh reports the suite release.
- bash 4 (needed by merge.sh) is checked at the start of a run, so a macOS system without it fails immediately instead of after a long download.
- Installing packages is setup.sh's job. all.sh, update.sh and extract.sh no longer offer to run brew/apt mid-run - a build or cron job can't stop at a sudo prompt. `./start.sh --install-missing-tools` opts in.

### Added
- A release check that only ever reads a version number over HTTPS: it prints the address and the commands and never downloads or runs anything. A tag that isn't digits and dots is ignored, and a non-HTTPS address is refused. `./start.sh --check-update`, `UPDATE_CHECK` to disable.
- Per-variant artwork order now applies however merge is run: `merge.sh --rtg` on its own used the default order instead of `ART_ORDER_RTG`; only all.sh was applying it.
- Progress bar style is per platform again (blocks on macOS, ASCII on Linux/A314, `PROGRESS_STYLE` to override). It had fallen back to `#` everywhere because the style was chosen before the config was read, and `tr` cannot map to a multi-byte character.
- Summary table at the end: per collection - games, size, time, the primary artwork applied, and the result - plus the total time.
- `setup.sh`: waits for the dpkg lock (a fresh Pi holds it for minutes) instead of failing; unlzx is fetched as C source from Aminet or GitHub (no lha needed); an interrupted setup is cleared before starting again; offers to tidy the scripts into `scripts/`.

### Fixed
- `retroplay.conf` was only looked for in one place, so a conf beside the scripts was ignored and the built-in defaults were used silently. It is now looked for where you ran the script, then beside the scripts, then the folder above - and if none is found, every run says so.
- Artwork order defaults corrected: `Screens,Covers,Titles` for every variant, `Covers,Screens,Titles` for RTG (`ART_ORDER_RTG`).
- `--artwork-sync` reported "installed, but you have changed it" for packs the tool installed itself. iGame_AGA, iGame_ECS, iGame_RTG (with their laced/lores subfolders) and TinyLauncher are now always replaced with the current version, with no backup kept. Only packs you added yourself (iGame_art and the like) are protected.
- Missing artwork was detected by checking for a pack FOLDER, so an empty `iGame_AGA/` counted as installed and only `iGame_RTG` was reported. One shared check now looks for actual section folders, reports every missing pack and flavour, and `all.sh` downloads them before building rather than leaving the collection without pictures.
- Artwork console output no longer interleaves the transfer meter with the overall progress bar; the overall bar prints once per file, each file gets its own lines, and the noisy "previous version kept in ..." path is gone.
- `--refresh-artwork` now clears the whole `iGame.iff` family first, so changing `ART_ORDER` can't leave an old primary file being shown.

### Added
- Every script prints its version and release when it starts, so mixed-up copies are obvious.
- `--status` shows which `retroplay.conf` is in use, or "not in use (built-in defaults)".

## 2026.09.25 (packaging and docs)
### Added
- `whdsync.zip`: every script, the tests and the docs in one archive. Save it where you want the tool to live, unpack, run `./setup.sh`.
- The README command reference now covers every option of every script - checked mechanically against the scripts' own option parsers, so it cannot drift.

## 2026.09.25 (final message, README)
### Changed
- The PFS `setfnsize` warning is now printed after the run summary, so it is the last thing on the screen.
- The README lists the artwork fallback order for every build (AGA, AGA Laced, ECS, ECS Laced, RTG, `--set NAME`, and none), not just RTG - including the two chains that are added automatically (older flat artwork, and any other `iGame_*` pack you have).

## 2026.09.25 (running the leaf scripts by hand)
### Fixed
- `./merge.sh` on its own failed with "destination folder not found: build/retro" - a folder that never exists. The leaf scripts now work out which collection you mean: the one matching the variant you named (`--aga` -> `build/retro_aga`), or the only collection there is. With several and no hint they list them and ask, instead of silently using a path that isn't there.
- Same fault in `sort.sh`, and two places in it that still pointed at a `retro` folder beside the scripts rather than under `build/`.
- `extract.sh` and `quick.sh` defaulted to `retro` and `new` beside the scripts; both now sit under `build/`.

## 2026.09.25 (artwork of last resort)
### Added
- `artwork_fetch.sh`: for games no artwork pack covers, a command of your choosing is asked for a picture, which is converted to a real Amiga IFF ILBM matching your existing artwork's size and colour depth, then installed into `artwork/iGame_art/` and the collection. Off by default (`ARTWORK_FETCH`), with per-game messages and totals in the run report.
- `to_ilbm.py`: the IFF ILBM writer (BMHD/CMAP/ByteRun1 BODY), sized from an existing `iGame.iff` so added artwork matches the rest. ImageMagick cannot write ILBM, hence writing it directly.
- `doctor.sh` checks the fetch command and that Pillow is installed.

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

## 2026.09.29 (third update - artwork sync)
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

## 2026.09.29 (second update)
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

## 2026.09.29
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
