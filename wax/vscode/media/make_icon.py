"""Draws the extension's icon: python wax/vscode/media/make_icon.py (needs Pillow). Writes ../icon.png, 128x128."""
import math
from pathlib import Path

from PIL import Image, ImageDraw

SIZE, SCALE = 128, 4
BACK, AMBER, LIGHT = (20, 23, 31, 255), (242, 163, 27, 255), (255, 205, 96, 255)


def hexagon(cx, cy, radius):
    return [(cx + radius * math.sin(math.radians(60 * i)), cy - radius * math.cos(math.radians(60 * i))) for i in range(6)]


def thick_line(draw, points, width, color):
    draw.line(points, fill=color, width=width, joint="curve")
    for x, y in points:
        draw.ellipse((x - width / 2, y - width / 2, x + width / 2, y + width / 2), fill=color)


def main():
    n = SIZE * SCALE
    image = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((0, 0, n - 1, n - 1), radius=26 * SCALE, fill=BACK)
    center = n / 2
    draw.polygon(hexagon(center, center, 50 * SCALE), fill=AMBER)
    draw.polygon(hexagon(center, center, 50 * SCALE)[5:] + hexagon(center, center, 50 * SCALE)[:2] + [(center, center)], fill=LIGHT)
    draw.polygon(hexagon(center, center, 41 * SCALE), fill=AMBER)
    letter = [(38, 50), (49, 82), (64, 56), (79, 82), (90, 50)]
    thick_line(draw, [(x * SCALE, y * SCALE) for x, y in letter], 9 * SCALE, BACK)
    out = Path(__file__).resolve().parent.parent / "icon.png"
    image.resize((SIZE, SIZE), Image.LANCZOS).save(out)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
