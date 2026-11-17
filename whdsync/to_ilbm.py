#!/usr/bin/env python3
"""Convert an ordinary image into an Amiga IFF ILBM file.

PURPOSE
    whdsync's artwork packs do not cover every game. When artwork_fetch.sh
    finds a picture for one that has none, this turns it into the format
    iGame and TinyLauncher actually read on the Amiga: a FORM/ILBM file with
    BMHD, CMAP and a ByteRun1-compressed BODY.

    ImageMagick cannot write ILBM, which is why this exists.

DEPENDENCIES
    python3 and Pillow (Debian/Raspberry Pi OS: python3-pil, macOS:
    pip3 install pillow). Nothing else.

USAGE
    to_ilbm.py IN.png OUT.iff --like artwork/iGame_AGA/lores/.../iGame.iff
    to_ilbm.py IN.jpg OUT.iff --width 320 --height 128 --planes 8

    --like copies the size and colour depth from artwork already installed,
    so what is added looks like the rest of the collection. Failing that,
    the defaults are 320x128 in 8 bitplanes (256 colours), which is what the
    iGame packs use.

EXIT STATUS
    0  the file was written
    1  the picture could not be read, converted or written
    2  the command line was wrong (argparse's own code)
    4  Pillow is not installed
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
from typing import List, Optional, Tuple

try:
    from PIL import Image
except ImportError:                                    # pragma: no cover
    sys.stderr.write(
        "to_ilbm: Pillow is not installed "
        "(Linux: sudo apt install python3-pil, macOS: pip3 install pillow)\n")
    sys.exit(4)


BMHD_PAYLOAD_MIN = 20          # w,h,x,y,planes,mask,compression,pad,transparent...


def read_bmhd(path: str) -> Tuple[int, int, int]:
    """Width, height and bitplane count of an existing IFF ILBM file.

    IFF is a chunked format: "FORM", a 4-byte big-endian length, the form
    type ("ILBM"), then chunks of <4-byte id><4-byte length><payload>, each
    padded to an even length. BMHD is the bitmap header; its bitplane count
    sits at offset 8 within the payload.

    The whole FORM is walked, not just its first 64 bytes. BMHD is
    conventionally the first chunk, but nothing in the specification requires
    it: a file that leads with ANNO, CAMG or a NAME chunk pushes BMHD past the
    first 64 bytes, and reading a fixed 64-byte window reported those perfectly
    valid files as having no BMHD at all.

    The walk is bounded by the FORM's own declared length as well as by the
    file's real size, so a truncated or lying header cannot send it off the end
    or into a loop.
    """
    with open(path, "rb") as fh:
        header = fh.read(12)
        if len(header) < 12:
            raise ValueError("too short to be an IFF file: %s" % path)
        if header[0:4] != b"FORM" or header[8:12] != b"ILBM":
            raise ValueError("not an IFF ILBM file: %s" % path)
        form_size = struct.unpack(">I", header[4:8])[0]
        # The FORM length counts the 4-byte form type plus every chunk after
        # it. Anything claiming more than the file holds is simply capped.
        file_size = os.fstat(fh.fileno()).st_size
        end = min(file_size, 8 + form_size)

        pos = 12
        while pos + 8 <= end:
            fh.seek(pos)
            head = fh.read(8)
            if len(head) < 8:
                break
            cid = head[0:4]
            size = struct.unpack(">I", head[4:8])[0]
            if cid == b"BMHD":
                if size < BMHD_PAYLOAD_MIN:
                    raise ValueError("BMHD chunk is too short in %s" % path)
                payload = fh.read(BMHD_PAYLOAD_MIN)
                if len(payload) < BMHD_PAYLOAD_MIN:
                    raise ValueError("BMHD chunk is cut short in %s" % path)
                w, h = struct.unpack(">HH", payload[0:4])
                planes = payload[8]
                if w <= 0 or h <= 0 or not 1 <= planes <= 8:
                    raise ValueError(
                        "BMHD in %s is not usable (%dx%d, %d planes)"
                        % (path, w, h, planes))
                return w, h, planes
            step = 8 + size + (size & 1)               # chunks are word aligned
            if step <= 8:                              # a zero-length chunk...
                step = 8                               # ...still moves forward
            pos += step
    raise ValueError("no BMHD chunk in %s" % path)


def pack_bitplanes(img: "Image.Image", width: int, height: int,
                   planes: int) -> bytes:
    """Interleaved bitplane rows, as ILBM stores them.

    The Amiga's display hardware reads bitplanes, not chunky pixels: for each
    row, all the bit-0 values come first as a bitstream, then all the bit-1
    values, and so on. Each plane's row is padded to a whole number of
    16-bit words, because that is the unit the blitter works in.
    """
    row_bytes = ((width + 15) // 16) * 2
    pixels = img.load()
    out = bytearray()
    for y in range(height):
        for p in range(planes):
            row = bytearray(row_bytes)
            bit = 1 << p
            for x in range(width):
                if pixels[x, y] & bit:
                    row[x >> 3] |= 0x80 >> (x & 7)
            out += row
    return bytes(out)


def byterun1(data: bytes) -> bytes:
    """ILBM's ByteRun1 (PackBits) compression.

    A control byte n means: 0..127 -> the next n+1 bytes are literal;
    129..255 -> repeat the next byte 257-n times. 128 is unused.
    """
    out = bytearray()
    i, n = 0, len(data)
    while i < n:
        run = 1
        while i + run < n and run < 128 and data[i + run] == data[i]:
            run += 1
        if run > 1:
            out.append(257 - run)
            out.append(data[i])
            i += run
            continue
        start = i
        lit = 1
        while (i + lit < n and lit < 128 and
               not (i + lit + 1 < n and data[i + lit] == data[i + lit + 1])):
            lit += 1
        out.append(lit - 1)
        out += data[start:start + lit]
        i += lit
    return bytes(out)


def chunk(cid: bytes, payload: bytes) -> bytes:
    """One IFF chunk: id, big-endian length, payload, pad to an even length."""
    out = cid + struct.pack(">I", len(payload)) + payload
    if len(payload) & 1:
        out += b"\0"
    return out


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="to_ilbm.py",
        description="Convert an image into an Amiga IFF ILBM file.",
        epilog="Example: to_ilbm.py cover.png iGame.iff --like existing.iff")
    parser.add_argument("source", help="the image to convert (PNG, JPEG, ...)")
    parser.add_argument("dest", help="the .iff file to write")
    parser.add_argument("--like", metavar="IFF",
                        help="copy the size and colour depth from this IFF")
    parser.add_argument("--width", type=int, help="width in pixels (default 320)")
    parser.add_argument("--height", type=int, help="height in pixels (default 128)")
    parser.add_argument("--planes", type=int,
                        help="bitplanes, 1-8; 8 = 256 colours (default 8)")
    return parser.parse_args(argv)


def convert(source: str, dest: str, width: int, height: int, planes: int) -> None:
    """Read `source`, fit it to width x height, and write `dest` as ILBM."""
    colours = 1 << planes
    with Image.open(source) as opened:
        img = opened.convert("RGB")
    # Fit inside the target, keeping the shape, then centre it on black:
    # a stretched cover looks wrong on the Amiga, and the packs' own artwork
    # is letterboxed the same way.
    img.thumbnail((width, height), Image.LANCZOS)
    canvas = Image.new("RGB", (width, height), (0, 0, 0))
    canvas.paste(img, ((width - img.width) // 2, (height - img.height) // 2))
    # The Amiga has a hardware palette, so the picture must be reduced to at
    # most 2^planes colours before it can be stored as bitplanes.
    pal = canvas.quantize(colors=colours, method=Image.MEDIANCUT)

    table = pal.getpalette()[:colours * 3]
    table += [0] * (colours * 3 - len(table))          # CMAP is always full

    body = byterun1(pack_bitplanes(pal, width, height, planes))
    # BMHD: w, h, x, y, planes, mask, compression(1=ByteRun1), pad,
    #       transparent colour, x/y aspect, page width, page height
    bmhd = struct.pack(">HHhhBBBBHBBhh",
                       width, height, 0, 0, planes, 0, 1, 0, 0, 1, 1,
                       width, height)
    form = (b"ILBM" + chunk(b"BMHD", bmhd) + chunk(b"CMAP", bytes(table))
            + chunk(b"BODY", body))
    with open(dest, "wb") as fh:
        fh.write(b"FORM" + struct.pack(">I", len(form)) + form)
    print("%s: %dx%d, %d colours" % (dest, width, height, colours))


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)

    width, height, planes = args.width, args.height, args.planes
    if args.like:
        try:
            like_w, like_h, like_p = read_bmhd(args.like)
        except (OSError, ValueError, struct.error, IndexError) as exc:
            sys.stderr.write("to_ilbm: could not read %s: %s\n" % (args.like, exc))
            return 1
        width = width or like_w
        height = height or like_h
        planes = planes or like_p

    width = width or 320
    height = height or 128
    planes = planes or 8
    if not 1 <= planes <= 8:
        sys.stderr.write("to_ilbm: --planes must be between 1 and 8, not %d\n" % planes)
        return 1
    if width < 1 or height < 1:
        sys.stderr.write("to_ilbm: --width and --height must be positive\n")
        return 1

    # Checked here rather than caught below, so a missing SOURCE cannot be
    # reported with the same message as an unwritable DESTINATION.
    if not os.path.isfile(args.source):
        sys.stderr.write("to_ilbm: no such image: %s\n" % args.source)
        return 1

    try:
        convert(args.source, args.dest, width, height, planes)
    except IsADirectoryError:
        sys.stderr.write("to_ilbm: %s is a folder, not a file\n" % args.dest)
        return 1
    except FileNotFoundError:
        sys.stderr.write("to_ilbm: cannot write %s - the folder does not exist\n"
                         % args.dest)
        return 1
    except PermissionError as exc:
        sys.stderr.write("to_ilbm: %s\n" % exc)
        return 1
    except OSError as exc:
        # Pillow raises OSError for a file it cannot decode, and so does a
        # failed write (a full disk, a read-only drive).
        sys.stderr.write("to_ilbm: could not convert %s: %s\n" % (args.source, exc))
        return 1
    except (ValueError, MemoryError, struct.error) as exc:
        sys.stderr.write("to_ilbm: could not convert %s: %s\n" % (args.source, exc))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
