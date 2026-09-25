# Putting whdsync on GitHub

`whdsync.bundle` is the whole repository in one file: the files, the commit
and the history. You clone from it exactly as you would from a server.

## 1. Get a working copy

```bash
git clone whdsync.bundle whdsync
cd whdsync
```

That gives you a normal Git repository on the `main` branch.

## 2. Create the repository on GitHub

On github.com: **New repository** → name it `whdsync` → **don't** tick
"Add a README", "Add .gitignore" or "Choose a licence" (the bundle has all
three, and an empty commit on their side would only need merging).

## 3. Push

```bash
git remote remove origin                 # the bundle is the current 'origin'
git remote add origin https://github.com/<your-account>/whdsync.git
git push -u origin main
```

With SSH instead: `git@github.com:<your-account>/whdsync.git`.

## 4. Check the workflow ran

Open the **Actions** tab. `.github/workflows/tests.yml` runs on every push:
the 213 tests and the option matrix on Ubuntu and on macOS (which still ships
bash 3.2 - the reason the scripts are written for it), plus ShellCheck.

This is the first time those run anywhere but Linux, so expect the macOS run
to be the interesting one. ShellCheck failures for real errors will fail the
build; style warnings are reported but don't.

## What's in the repository

```
whdsync/
├── *.sh                     the scripts
├── to_ilbm.py               PNG/JPEG -> Amiga IFF ILBM (artwork search)
├── retroplay.conf.example    settings template (your own conf is git-ignored)
├── tests/                   run_tests.sh, option_matrix.sh - both run offline
├── .github/workflows/       CI
├── .gitignore               keeps downloads, artwork, builds and logs out
├── LICENSE                  MIT - change it if you'd rather something else
├── README.md
└── CHANGELOG.md
```

`.gitignore` deliberately excludes `artwork/`, `build/`, `downloads/`,
`logs/`, `reports/`, `retroplay.conf` and `.retroplay/`: your collection is
hundreds of gigabytes and must never be committed.

## Working on it afterwards

```bash
tests/run_tests.sh        # before every commit
tests/option_matrix.sh    # every option of every script
```

Both run offline against mock tools and a mock server, and touch nothing
outside their temporary folder.

## A note on the licence

I put MIT in `LICENSE` because it suits a tool like this, but it's your
project - replace it if you'd prefer something else. It covers these scripts
only, not the WHDLoad archives, the artwork packs or the games.
