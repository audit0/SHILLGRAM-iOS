"""Render a square iOS app icon (1024 px, no alpha) from the round SHILLGRAM desktop icon.

Background: vertical-ish gradient #081813 -> #030505. The S and mint dot are cut out of the
round source by masking pixels that differ from its dark disc, then centred and scaled.
"""
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

src_path, out_path = sys.argv[1], sys.argv[2]
SIZE = 1024
src = Image.open(src_path).convert("RGBA")
w, h = src.size

# gradient background (top-left #081813 -> bottom-right #030505)
bg = Image.new("RGB", (SIZE, SIZE))
top = (0x08, 0x18, 0x13)
bot = (0x03, 0x05, 0x05)
px = bg.load()
for y in range(SIZE):
    for x in range(SIZE):
        t = (x + y) / (2 * (SIZE - 1))
        px[x, y] = tuple(int(round(a + (b - a) * t)) for a, b in zip(top, bot))

# foreground mask: bright pixels (white S) and green pixels (dot + glow ring)
rgb = src.convert("RGB")
r, g, b = rgb.split()
lum = rgb.convert("L")
# brightness above the disc background (~<40) -> foreground
fg_mask = lum.point(lambda v: 0 if v < 45 else min(255, int((v - 45) * 255 / 60)))
# keep only inside the disc (drop the thin light rim)
disc = Image.new("L", (w, h), 0)
inset = int(w * 0.04)
ImageDraw.Draw(disc).ellipse((inset, inset, w - inset, h - inset), fill=255)
fg_mask = ImageChops.multiply(fg_mask, disc)

bbox = fg_mask.getbbox()
fg = src.crop(bbox)
mask = fg_mask.crop(bbox)
fw, fh = fg.size
# scale so the glyph group spans ~56% of the icon
scale = (SIZE * 0.56) / max(fw, fh)
nw, nh = int(fw * scale), int(fh * scale)
fg = fg.resize((nw, nh), Image.LANCZOS)
mask = mask.resize((nw, nh), Image.LANCZOS)

# soft mint glow behind the dot area comes from the source colours themselves
ox, oy = (SIZE - nw) // 2, (SIZE - nh) // 2
canvas = bg.copy()
canvas.paste(fg.convert("RGB"), (ox, oy), mask)
canvas.save(out_path, "PNG")
print("ok", bbox, (nw, nh))

# transparent glyph layer for the Icon Composer (.icon) bundle
if len(sys.argv) > 3:
    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    fg_rgba = fg.copy()
    fg_rgba.putalpha(mask)
    layer.paste(fg_rgba, (ox, oy), fg_rgba)
    layer.save(sys.argv[3], "PNG")
    print("layer ok")
