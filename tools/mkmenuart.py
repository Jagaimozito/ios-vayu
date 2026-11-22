#!/usr/bin/env python3
"""mkmenuart.py - turn the boot menu's OS pictures into raw pixels the shim draws (shim/art.S):

  python3 tools/mkmenuart.py            (reads shim/art/src/{ios27,macos27,android}.png)

Each picture is cropped to its opaque square, given a clean rounded-square edge (the PNGs carry
coloured specks in their transparent margin), scaled to ICON x ICON with Lanczos, and blended onto
the menu background (shim/menu.c BG), so the shim only copies pixels: 3 bytes R, G, B each, row
by row (3 x 1.08 MB in the shim Image). Needs Pillow; the .bin files are committed so a
shim build does not.
"""
import os, sys
from PIL import Image, ImageChops, ImageDraw

ICON = 600
BG = (0, 0, 0)
NAMES = ("ios27", "macos27", "android")
SS = 4  # supersampling for the edge mask


def convert(src, dst):
    im = Image.open(src).convert("RGBA")
    a = im.getchannel("A").point(lambda v: 255 if v > 200 else 0)
    im = im.crop(a.getbbox())
    w, h = im.size
    side = max(w, h)
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.paste(im, ((side - w) // 2, (side - h) // 2))
    m = Image.new("L", (side * SS // 4 * 4, side * SS // 4 * 4), 0)
    inset = int(side * 0.006) * SS
    ImageDraw.Draw(m).rounded_rectangle((inset, inset, m.size[0] - 1 - inset, m.size[1] - 1 - inset),
                                        radius=int(side * 0.22) * SS, fill=255)
    m = m.resize((side, side), Image.LANCZOS)
    sq.putalpha(ImageChops.multiply(sq.getchannel("A"), m))
    sq = sq.resize((ICON, ICON), Image.LANCZOS)
    bg = Image.new("RGBA", (ICON, ICON), BG + (255,))
    out = Image.alpha_composite(bg, sq).convert("RGB")
    open(dst, "wb").write(out.tobytes())
    out.save(dst[:-4] + "-preview.png")


def main():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "shim", "art")
    if len(sys.argv) > 1:
        root = sys.argv[1]
    for n in NAMES:
        convert(os.path.join(root, "src", n + ".png"), os.path.join(root, n + ".bin"))
        print(n, ICON, "x", ICON)


if __name__ == "__main__":
    main()
