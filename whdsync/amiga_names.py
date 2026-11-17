#!/usr/bin/env python3
import argparse
import os
import unicodedata
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("directory", type=Path)
parser.add_argument("--apply", action="store_true",
                    help="Rename files; otherwise only preview")
args = parser.parse_args()

root = args.directory
if not root.is_dir():
    parser.error(f"Not a directory: {root}")

special = str.maketrans({
    "\u00e4": "ae", "\u00f6": "oe", "\u00fc": "ue",
    "\u00c4": "Ae", "\u00d6": "Oe", "\u00dc": "Ue",
    "\u00df": "ss", "\u1e9e": "SS",
    "\u0153": "oe", "\u0152": "OE",
    "\u00e6": "ae", "\u00c6": "AE",
    "\u00f8": "o",  "\u00d8": "O",
    "\u0142": "l",  "\u0141": "L",
})
# Only what AmigaDOS itself trips over: # and ? are its pattern-matching
# wildcards, and \ is not a name character there. - and + are ordinary, legal
# characters on the Amiga and are left exactly as they are: WHDLoad slaves
# open their data files by name, so renaming "disk-1" would break the game.
punctuation = str.maketrans({c: "_" for c in "#?\\"})

def convert(name):
    name = unicodedata.normalize("NFC", name)
    name = name.translate(special)
    name = unicodedata.normalize("NFD", name)
    name = "".join(
        c for c in name
        if unicodedata.category(c) != "Mn"
    )
    name = unicodedata.normalize("NFC", name)
    return name.translate(punctuation)

for directory, dirs, files in os.walk(root, topdown=False):
    for name in files + dirs:
        new_name = convert(name)
        if new_name == name:
            continue

        source = Path(directory) / name
        target = source.with_name(new_name)

        if os.path.lexists(target):
            print(f"SKIP (destination exists): {str(source)!r} -> {new_name!r}")
            continue

        if args.apply:
            try:
                source.rename(target)
            except OSError as exc:
                print(f"ERROR: {str(source)!r}: {exc}")
                continue

        label = "RENAMED" if args.apply else "PREVIEW"
        print(f"{label}: {str(source)!r} -> {new_name!r}")
