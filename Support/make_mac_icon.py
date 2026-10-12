"""Mac icon sizes from the iOS icon: macOS draws no mask, so the art sits on a rounded square with margin."""
import sys
from PIL import Image, ImageDraw, ImageFilter

src_path, out_dir = sys.argv[1], sys.argv[2]
SIZE, ART, RADIUS = 1024, 824, 185  # Apple's macOS icon grid
inset = (SIZE - ART) // 2

art = Image.open(src_path).convert("RGBA").resize((ART, ART), Image.LANCZOS)
mask = Image.new("L", (ART, ART), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, ART - 1, ART - 1), RADIUS, fill=255)

shadow = Image.new("L", (SIZE, SIZE), 0)
shadow.paste(mask, (inset, inset + 10))
shadow = shadow.filter(ImageFilter.GaussianBlur(14)).point(lambda a: int(a * 0.35))
icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
icon.putalpha(shadow)
icon.paste(art, (inset, inset), mask)

for px in (16, 32, 64, 128, 256, 512, 1024):
    icon.resize((px, px), Image.LANCZOS).save(f"{out_dir}/mac-{px}.png")
