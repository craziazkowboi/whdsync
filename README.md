# whdsync — an Amiga WHDLoad collection that keeps itself up to date

Downloads the Retroplay WHDLoad archives, extracts them, adds iGame artwork, sorts everything the way an Amiga expects, and builds a ready-to-copy collection for each machine you own — AGA, ECS and RTG.

Then it does the same again every night, by itself, and tells you only when something needs you.

```
downloads/            →  extract  →  artwork  →  sort  →  build/retro_aga/
(Retroplay archives)                                      build/retro_ecs/
                                                          build/retro_rtg/
```

- **Runs on** a Raspberry Pi (including a Pi Zero 2 W) or a Mac. Linux and macOS, nothing else needed.
- **Safe by design.** It never deletes a collection until its replacement is ready, never overwrites artwork you changed yourself, and stops rather than guessing.
- **Tested.** 157 automated tests plus 201 option checks, run on Linux and macOS.

---

## Contents

- [What you need](#what-you-need)
- [Install it](#install-it)
- [Your first run](#your-first-run)
- [Everyday use](#everyday-use)
- [Where everything lives](#where-everything-lives)
- [Artwork](#artwork)
- [The nightly run](#the-nightly-run)
- [Settings](#settings)
- [When something goes wrong](#when-something-goes-wrong)
- [Uninstalling](#uninstalling)
- [How it keeps your collection safe](#how-it-keeps-your-collection-safe)
- [Command reference](#command-reference)
- [For developers](#for-developers)

---

## What you need

| | |
|---|---|
| **A computer** | Raspberry Pi OS / Debian / Ubuntu, or macOS |
| **Disk space** | Roughly 3× the size of the collection you want. A full set of three variants needs a few hundred GB — start with one variant if you're unsure |
| **Time** | The first run downloads a lot. Leave it overnight |
| **Tools** | `wget`, `lha`, `7z`, `unar`, `unlzx` — **the setup script installs all of these for you** |

On a Raspberry Pi, putting the collection on a **USB SSD** rather than the SD card makes an enormous difference to speed, and saves the card a lot of wear. Setup asks where you want it.

---

## Install it

### 1. Get the files

```bash
git clone https://github.com/<your-account>/whdsync.git
cd whdsync
chmod +x *.sh
```

No git? Download the ZIP from the GitHub page, unzip it, and `cd` into the folder.

### 2. Choose where it lives

Put the folder anywhere you have space — for example `/home/pi/whdsync` or `~/Amiga/whdsync`. Everything the tool creates (downloads, artwork, finished collections, logs) goes **inside that folder**, unless you point the collection at another drive during setup.

macOS note: avoid iCloud-synced folders such as Desktop and Documents. Something like `~/Amiga/whdsync` is ideal.

### 3. Run the setup

```bash
./setup.sh
```

It will:

1. install the tools it needs (`apt` on Linux, Homebrew on macOS);
2. download and compile `unlzx`, which has no package anywhere;
3. add the two text encodings Linux needs for Amiga filenames;
4. ask three questions — which machines you build for, where the collection should go, and whether you want failure notifications;
5. offer to set up the nightly update;
6. finish by checking everything.

It's safe to run again at any time: every step checks first and only does what's missing. `./setup.sh --yes` takes every default without asking; `./setup.sh --dry-run` shows what it would do and changes nothing.

---

## Your first run

```bash
./start.sh --plan      # optional: shows what WOULD happen, changes nothing
./all.sh               # the real thing
```

What to expect, in order:

| Step | What happens | How long |
|---|---|---|
| 1 | Checks your setup and that the drive is there | seconds |
| 2 | Downloads the artwork packs | minutes |
| 3 | Mirrors the Retroplay archives | **hours** on a first run |
| 4 | Works out what needs building | seconds |
| 5 | Extracts, adds artwork, sorts and installs each variant | **hours** on a Pi |

Each step announces itself with the time, and long jobs show a progress bar, so you can always tell it's working. A readable report is written to `reports/`, and a summary appears at the end.

**You can stop it at any time with Ctrl-C.** Nothing is left half-installed: an interrupted build is redone next time, and everything already downloaded is kept.

When it finishes, your collections are in `build/retro_aga/`, `build/retro_ecs/` and `build/retro_rtg/`. Copy the one you want to your Amiga's drive, or point your A314 or network share at it.

---

## Everyday use

```bash
./start.sh                 # menu, if you'd rather not remember options
./start.sh --status        # what happened last night, what's waiting
./all.sh                   # update and rebuild everything
./aga.sh                   # just the AGA collection (also ecs.sh, rtg.sh)
./start.sh --plan          # what a run would do; changes nothing
./doctor.sh                # check the setup, and be told how to fix anything wrong
```

After the first run, a nightly update usually takes a few minutes: only newly published games are downloaded and added.

**New games appear in two places:** merged into your collection, and copied on their own into `build/new_aga/<date>/`, so you can send just the new ones to your Amiga instead of recopying everything.

---

## Where everything lives

```
whdsync/
├── artwork/          the iGame artwork packs
│   ├── iGame_AGA/{laced,lores}/{Covers,Screens,Titles}/...
│   ├── iGame_ECS/{laced,lores}/...
│   ├── iGame_RTG/{Covers,Screens,Titles}/...
│   └── TinyLauncher/
├── build/            your finished collections — this is what you copy to the Amiga
│   ├── retro_aga/  retro_ecs/  retro_rtg/
│   └── new_aga/<date>/          only the games added that night
├── downloads/        the Retroplay mirror — the raw archives
│   ├── WHDLoad/  HD_Loaders/  JST/
│   ├── artwork_archive/         downloaded artwork archives
│   └── old/                     superseded archives, kept for a while
├── logs/             deleted automatically after LOG_RETENTION_DAYS
├── .retroplay/       state: the queue, what's built, artwork manifests
│                     (tidied at the start of every run - only essentials stay)
├── reports/          one readable summary per run
├── retroplay.conf    your settings
└── the scripts
```

`build/` can live on another drive — set `OUTPUT_ROOT` during setup or in `retroplay.conf`. The scripts can also be tidied into a `scripts/` subfolder if you prefer; everything else then sits alongside it.

---

## Artwork

Artwork comes from the Turran FTP mirror and is installed where the merge step expects it.

```bash
./start.sh --artwork-status     # what's installed, and whether it's current
./start.sh --artwork-plan       # what an update would do — changes nothing
./start.sh --artwork-sync       # fetch and install everything
./start.sh --artwork-sync --for aga     # only what an AGA build needs
./start.sh --artwork-verify     # check what's installed
./start.sh --artwork-rollback iGame_AGA/lores/Covers    # undo one update
```

| Published archive | Installed as |
|---|---|
| `IGame_Covers_RTG.lha` | `artwork/iGame_RTG/Covers/…` |
| `IGame_Screens_AGA_Laced.lha` | `artwork/iGame_AGA/laced/Screens/…` |
| `IGame_Titles_ECS_LoRes.lha` | `artwork/iGame_ECS/lores/Titles/…` |
| `TinyLauncher.lha` | `artwork/TinyLauncher/…` |

A plain `--aga` or `--ecs` build uses the **LoRes** artwork; `--aga-laced` and `--ecs-laced` use the **Laced** artwork; `--rtg` uses the RTG packs.

**Refreshing artwork.** Every merge writes artwork from the packs' current version — `iGame.iff`, `iGame.data` and the rest — so updating a pack refreshes your collection. (Checking each file first was measured *slower* than simply writing it: 23 s against 11 s over 1500 games.)

The nightly gap-fill only visits games that have no artwork yet. To refresh **every** game, including those:

```bash
./all.sh --refresh-artwork                    # every variant, every game
./aga.sh --refresh-artwork                    # one variant
./start.sh --merge --aga --refresh-artwork --dest build/retro_aga
```

Each merge reports what it did: which mode it is in, and how many artwork files were added and refreshed. To leave existing artwork alone, use `--only-missing`.

**Artwork you already have is not downloaded twice.** Before fetching anything, the size of your cached archive is compared with the size the source reports (from its listing, or an HTTP header request — no download either way). Unchanged archives are reused.

**Your own artwork is safe.** If you change a folder, or drop in a pack this tool didn't install, it is never overwritten automatically — see `ARTWORK_LOCAL_CHANGE_POLICY`. Put your own images in `artwork/iGame_art/` in whatever structure you like; they're used whenever a game has no artwork in the main packs.

### When no pack has the artwork

After every pack has been tried, the games still without artwork can be looked up elsewhere. This is **off by default**, and you decide what does the looking:

```
ARTWORK_FETCH="yes"
ARTWORK_FETCH_COMMAND="/home/pi/bin/find-cover"     # your command
ARTWORK_FETCH_LIMIT=25                              # per run
```

Your command is called as `<command> "<game name>" "<output .png>"`; it writes one picture and exits 0, or exits non-zero if it found nothing. People plug in an AI command line tool, an image-search API wrapper, or a script that picks from their own folder of pictures. Nothing is fetched unless you set this up.

What the suite does with the result: checks it really is an image, converts it to a proper Amiga IFF ILBM with the **same size and colour depth as your existing artwork**, then installs it into `artwork/iGame_art/<Game>/` (your own pack, which artwork updates never overwrite) and into the collection. It says what it is doing for each game and counts the results:

```
  [3/18] Blastaway: searching... found - converted and installed (320x128, 256 colours)
  [4/18] Zoetrope: searching... nothing found

  Artwork found and installed: 11
  Still without artwork:       7
```

Needs `python3` with Pillow (`sudo apt install python3-pil`). `./doctor.sh` checks it for you.

### Which artwork a build uses, and what it falls back to

Each build tries its own artwork first, then works down the list until it finds a picture. "Your own art" is `artwork/iGame_art/`.

| Build | Order it tries |
|---|---|
| `--aga` | AGA (lores) → your own art → ECS → TinyLauncher |
| `--aga-laced` | AGA Laced → AGA (lores) → your own art → ECS → TinyLauncher |
| `--ecs` | ECS (lores) → your own art → TinyLauncher |
| `--ecs-laced` | ECS Laced → ECS (lores) → your own art → TinyLauncher |
| `--rtg` | RTG → AGA Laced → AGA (lores) → your own art → ECS Laced → ECS → TinyLauncher |
| `--set NAME` | that pack → your own art → TinyLauncher |
| no variant given | your own art → TinyLauncher |

Two things are added to these automatically:

- **Artwork you installed the older flat way** (`iGame_AGA/Covers/…` rather than `iGame_AGA/lores/…`) is tried immediately after the pack it belongs to, so nothing is lost.
- **Any other `iGame_*` pack you have** is tried last, after TinyLauncher — so a pack the list doesn't mention still gets used rather than ignored.

Within each pack, sections are tried in `ART_ORDER` (`Covers,Screens,Titles` by default), and demos use `DEMO_ART_ORDER`.

---

## The nightly run

```bash
./start.sh --schedule                 # every night at 02:00
./start.sh --schedule --time 04:30    # at a time that suits you
./start.sh --schedule --show          # what's scheduled now
./start.sh --schedule --disable       # stop it
```

The nightly run is silent unless something needs you. To hear about failures, set `NTFY_TOPIC` (a free [ntfy.sh](https://ntfy.sh) topic) or `NOTIFY_EMAIL` in `retroplay.conf`, then check it works:

```bash
./start.sh --test-notify
```

Output from each night goes to `logs/all_cron.log`, and a summary to `reports/`. To include artwork updates in the nightly run, set `ARTWORK_SYNC="auto"`.

---

## Settings

Settings live in `retroplay.conf` beside the scripts. Copy `retroplay.conf.example` if you don't have one; every setting is commented there. The ones people change most:

| Setting | Default | What it does |
|---|---|---|
| `VARIANTS` | `aga ecs rtg` | Which collections to build |
| `OUTPUT_ROOT` | `.` | Where `build/` goes — point this at a USB SSD |
| `ART_ORDER` | `Screens,Covers,Titles` | Which artwork iGame shows first |
| `FILESYSTEM` | `pfs` | Use `ffs` for the 30-character filename limit. With `pfs`, every run ends with a reminder to run `setfnsize <drive:> 107` on the Amiga first |
| `ARTWORK_SYNC` | `ask` | `auto` also updates artwork in the nightly run |
| `LOG_RETENTION_DAYS` | `1` | Delete logs after this many days; `0` keeps them for ever |
| `ARTWORK_KEEP_BACKUPS` | `2` | Previous artwork versions kept for rollback |
| `STATE_BACKUP` | `no` | Keep rolling copies of the state folder (queue and markers only) |
| `NTFY_TOPIC` | *(empty)* | Get told when a run fails |

See what's in force with `./start.sh --status`, and the full list in `retroplay.conf.example`.

---

## When something goes wrong

**Start here:**

```bash
./doctor.sh
```

It checks the whole setup and, for anything wrong, tells you the command that fixes it.

| Message | What it means |
|---|---|
| "the output folder isn't available (drive not mounted?)" | Your USB drive isn't mounted. Nothing was changed — plug it in and run again |
| "some archives couldn't be extracted" (exit 5) | A damaged download. Everything else was installed; it retries by itself, and after three attempts fetches a fresh copy |
| "network or server problem" (exit 3) | The server was unreachable. It tries again next run |
| "scripts are not from the same version" | Some files weren't updated. Copy the whole set across |
| A game has no artwork | Ask why: `./merge.sh --why SuperSkidmarks -d build/retro_aga`. It lists every set and section it looked in, and anything in `artwork/` with a similar name |

**Exit codes**, if you script around it: `0` done, `2` nothing to do, `3` network, `4` setup problem, `5` some archives failed, `130` interrupted.

Logs are in `logs/`, the last run's summary in `reports/`.

---

## Uninstalling

**Stop the nightly run, keep everything else:**

```bash
./start.sh --schedule --disable
```

**Remove the tools it installed for you** — and only those; anything you already had is left alone:

```bash
./uninstall_deps.sh --dry-run    # see what would go
./uninstall_deps.sh              # do it
```

**Remove everything:** disable the schedule, run `./uninstall_deps.sh`, then delete the folder. Your collections are just files in `build/` — copy them somewhere first if you want to keep them.

---

## How it keeps your collection safe

Every one of these has an automated test that fails if the protection is removed:

- **Your collection is never removed before its replacement is ready**, and free space is checked before each stage.
- **An unmounted drive is refused**, rather than quietly rebuilding hundreds of GB onto your SD card.
- **A damaged archive never blocks the rest.** It's retried, then re-downloaded, and always reported by name.
- **Interrupted downloads are never treated as complete**, and an interrupted build is redone rather than left half-installed.
- **Artwork you changed is never overwritten**, and the previous version is kept so an update can be rolled back.
- **Two runs can't overlap**, and a refused run says which one holds the lock.
- **Your queue of pending downloads is backed up** every run, and restored if it's ever lost.
- **Filenames are made Amiga-safe** (PFS or FFS limits) before anything reaches your Amiga.

---

## Command reference

| Command | What it does |
|---|---|
| `./setup.sh` | Install and set up everything (safe to repeat) |
| `./all.sh` | Update and build every configured variant |
| `./aga.sh` `./ecs.sh` `./rtg.sh` | Build one variant |
| `./start.sh` | Menu |
| `./start.sh --status` | Last run, what's queued, drive, schedule |
| `./start.sh --plan` | What a run would do; changes nothing |
| `./start.sh --artwork-*` | `status`, `plan`, `sync`, `verify`, `rollback` |
| `./start.sh --schedule` | Set up, show or disable the nightly run |
| `./start.sh --test-notify` | Check notifications work |
| `./doctor.sh` | Check the setup and explain any fixes |
| `./uninstall_deps.sh` | Remove tools this tool installed |

Run the leaf scripts on their own and they work out which collection you mean — the one matching the variant you name (`./merge.sh --aga`), or the only one you have. With several and no hint, they list them rather than guess.

Every script supports `--help`. Useful extras: `--rebuild` (rebuild from archives already downloaded, no server check), `--skip-update`, `--force` (also fill in missing artwork), `--dry-run`.

---

## For developers

```bash
tests/run_tests.sh                    # 213 end-to-end tests, no network needed
tests/option_matrix.sh                # every option of every script
MATRIX_SECTIONS="1 2" tests/option_matrix.sh    # just some sections
```

Both run offline against mock tools and a mock server, so a full run takes minutes and touches nothing outside its temporary folder. GitHub Actions runs them on Ubuntu and macOS (bash 3.2), plus ShellCheck.

The layout: `all.sh` is the engine; `start.sh` is the front end; `update.sh`, `extract.sh`, `merge.sh`, `sort.sh` and `artwork_sync.sh` each do one job; `lib.sh` holds everything shared. All scripts carry a version stamp and refuse to run as a mixed set.

Contributions welcome — please keep the tests passing, add one for whatever you change, and stick to bash 3.2 (macOS ships it) outside `merge.sh`.

---

## Thanks

To Retroplay for the WHDLoad archives, to the iGame artwork packs and their maintainers, and to the EAB community.

This tool downloads publicly published archives. Make sure you're entitled to the games you use.
