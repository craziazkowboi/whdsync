#!/usr/bin/env python3
"""to_ilbm.py - convert an ordinary image into an Amiga IFF ILBM file.

Used by artwork_fetch.sh when a game has no artwork in any pack. The output
matches the artwork already in use: same width, height and colour depth as an
existing iGame.iff, so iGame shows it exactly like the rest.

  to_ilbm.py <input image> <output .iff> --like <existing .iff>
  to_ilbm.py <input image> <output .iff> --width 320 --height 128 --planes 8

Writes a standard FORM/ILBM file: BMHD, CMAP and a ByteRun1-compressed BODY,
which is what iGame and TinyLauncher expect. Needs Pillow (python3-pil).
"""

import sys
import struct

try:
    from PIL import Image
except ImportError:                                    # pragma: no cover
    sys.stderr.write("to_ilbm: Pillow is not installed (sudo apt install python3-pil)\n")
    sys.exit(4)


def read_bmhd(path):
    """Width, height and bitplane count of an existing IFF ILBM file."""
    with open(path, "rb") as fh:
        data = fh.read(64)
    if data[0:4] != b"FORM" or data[8:12] != b"ILBM":
        raise ValueError("not an IFF ILBM file: %s" % path)
    pos = 12
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        size = struct.unpack(">I", data[pos + 4:pos + 8])[0]
        if cid == b"BMHD":
            w, h = struct.unpack(">HH", data[pos + 8:pos + 12])
            planes = data[pos + 16]
            return w, h, planes
        pos += 8 + size + (size & 1)
    raise ValueError("no BMHD chunk in %s" % path)


def pack_bitplanes(img, width, height, planes):
    """Interleaved bitplane rows, as ILBM stores them."""
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


def byterun1(data):
    """ILBM's run-length compression."""
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


def chunk(cid, payload):
    out = cid + struct.pack(">I", len(payload)) + payload
    if len(payload) & 1:
        out += b"\0"                                   # chunks are word aligned
    return out


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        sys.stderr.write(__doc__)
        return 4
    src, dst = args[0], args[1]
    width = height = planes = None
    i = 2
    while i < len(args):
        if args[i] == "--like":
            width, height, planes = read_bmhd(args[i + 1]); i += 2
        elif args[i] == "--width":
            width = int(args[i + 1]); i += 2
        elif args[i] == "--height":
            height = int(args[i + 1]); i += 2
        elif args[i] == "--planes":
            planes = int(args[i + 1]); i += 2
        else:
            sys.stderr.write("to_ilbm: unknown option %s\n" % args[i])
            return 4
    width = width or 320
    height = height or 128
    planes = planes or 8
    colours = 1 << planes

    img = Image.open(src)
    img = img.convert("RGB")
    # Fit inside the target, keeping the shape, then centre it on black -
    # a stretched cover looks wrong on the Amiga.
    img.thumbnail((width, height), Image.LANCZOS)
    canvas = Image.new("RGB", (width, height), (0, 0, 0))
    canvas.paste(img, ((width - img.width) // 2, (height - img.height) // 2))
    pal = canvas.quantize(colors=colours, method=Image.MEDIANCUT)

    table = pal.getpalette()[:colours * 3]
    table += [0] * (colours * 3 - len(table))

    body = byterun1(pack_bitplanes(pal, width, height, planes))
    bmhd = struct.pack(">HHhhBBBBHBBhh",
                       width, height, 0, 0, planes, 0, 1, 0, 0, 1, 1, width, height)
    form = b"ILBM" + chunk(b"BMHD", bmhd) + chunk(b"CMAP", bytes(table)) + chunk(b"BODY", body)
    with open(dst, "wb") as fh:
        fh.write(b"FORM" + struct.pack(">I", len(form)) + form)
    print("%s: %dx%d, %d colours" % (dst, width, height, colours))
    return 0


if __name__ == "__main__":
    sys.exit(main())
