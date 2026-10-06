"""Draws the white shapes and icons the Wax GUI tints at draw time (wax/runtime/assets/*.png).

Run from the workspace root:  python scripts/make_wax_assets.py
Shapes are 64x64 nine-slice images (corner radius in the name). Icons come from Lucide (import_lucide.py). Needs Pillow.
"""
from pathlib import Path
from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "wax" / "runtime" / "assets"
SCALE = 8  # supersampling factor
WHITE = (255, 255, 255, 255)


def canvas(size):
    image = Image.new("RGBA", (size * SCALE, size * SCALE), (255, 255, 255, 0))
    return image, ImageDraw.Draw(image)


def save(image, name, size):
    # Downsample the alpha only, and keep every pixel white, so tinted edges never pick up a dark fringe.
    alpha = image.getchannel("A").resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), WHITE)
    out.putalpha(alpha)
    out.save(OUT / f"{name}.png")


def rounded(name, radius, size=64):
    image, draw = canvas(size)
    draw.rounded_rectangle([0, 0, size * SCALE - 1, size * SCALE - 1], radius * SCALE, fill=WHITE)
    save(image, name, size)


def rounded_top(name, radius, size=64):
    image, draw = canvas(size)
    edge = size * SCALE - 1
    draw.rounded_rectangle([0, 0, edge, edge], radius * SCALE, fill=WHITE)
    draw.rectangle([0, edge // 2, edge, edge], fill=WHITE)
    save(image, name, size)


def rounded_bottom(name, radius, size=64):
    image, draw = canvas(size)
    edge = size * SCALE - 1
    draw.rounded_rectangle([0, 0, edge, edge], radius * SCALE, fill=WHITE)
    draw.rectangle([0, 0, edge, edge // 2], fill=WHITE)
    save(image, name, size)


def glow(name, radius, stroke, blur, size=64, margin=20):
    """The bottom and right edges of a window outline, fading in over the last third towards the corner (9-slice)."""
    from PIL import ImageFilter
    big = size * SCALE
    ring = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(ring)
    draw.rounded_rectangle([0, 0, big - 1, big - 1], radius * SCALE, fill=255)
    draw.rounded_rectangle([stroke * SCALE, stroke * SCALE, big - 1 - stroke * SCALE, big - 1 - stroke * SCALE],
                           max(0, radius - stroke) * SCALE, fill=0)
    if blur:
        soft = ring.filter(ImageFilter.GaussianBlur(blur * SCALE))
        ring = Image.eval(soft, lambda v: min(255, int(v * 1.3)))
    alpha = ring.resize((size, size), Image.LANCZOS)
    start = margin + 0.72 * (size - 2 * margin)

    def weight(at):
        t = max(0.0, min(1.0, (at - start) / (size - margin - start)))
        return t * t * (3 - 2 * t)

    pixels = alpha.load()
    for y in range(size):
        for x in range(size):
            pixels[x, y] = int(pixels[x, y] * weight(x) * weight(y))
    out = Image.new("RGBA", (size, size), WHITE)
    out.putalpha(alpha)
    out.save(OUT / f"{name}.png")


def frame(name, radius, stroke, size=64):
    image, draw = canvas(size)
    s = SCALE
    draw.rounded_rectangle([0, 0, size * s - 1, size * s - 1], radius * s, fill=WHITE)
    inner = Image.new("L", image.size, 0)
    ImageDraw.Draw(inner).rounded_rectangle(
        [stroke * s, stroke * s, size * s - 1 - stroke * s, size * s - 1 - stroke * s], max(0, radius - stroke) * s, fill=255)
    alpha = image.getchannel("A")
    alpha.paste(0, mask=inner)
    image.putalpha(alpha)
    save(image, name, size)


def icon(name, painter, size=32):
    image, draw = canvas(size)
    painter(draw, size * SCALE)
    save(image, name, size)


def line(draw, points, width):
    draw.line(points, fill=WHITE, width=width, joint="curve")
    r = width / 2
    for x, y in (points[0], points[-1]):
        draw.ellipse([x - r, y - r, x + r, y + r], fill=WHITE)


def grip(draw, n):
    w = int(n * 0.085)
    for offset in (0.28, 0.54, 0.80):
        line(draw, [(n * 0.92, n * offset), (n * offset, n * 0.92)], w)


def fade(name, across):
    """White that fades out to the right, or black that fades in downward. Laid over a colour they give every shade of it."""
    size = 256
    image = Image.new("RGBA", (size, 4) if across else (4, size))
    pixels = image.load()
    for step in range(size):
        value = round(255 * step / (size - 1))
        for other in range(4):
            if across:
                pixels[step, other] = (255, 255, 255, 255 - value)
            else:
                pixels[other, step] = (0, 0, 0, value)
    (OUT / name).parent.mkdir(parents=True, exist_ok=True)
    image.save(OUT / f"{name}.png")


def hues(name, width=360, height=4):
    """Every hue from left to right, for the hue bar."""
    import colorsys
    image = Image.new("RGBA", (width, height))
    pixels = image.load()
    for x in range(width):
        r, g, b = colorsys.hsv_to_rgb(x / (width - 1), 1, 1)
        for y in range(height):
            pixels[x, y] = (round(r * 255), round(g * 255), round(b * 255), 255)
    image.save(OUT / f"{name}.png")


def corners(name, radius, size=64):
    """The opposite of a rounded rectangle: only what lies outside its corners. Drawn over a square image it rounds it."""
    scale = 4
    n = size * scale
    inside = Image.new("L", (n, n), 0)
    ImageDraw.Draw(inside).rounded_rectangle([0, 0, n - 1, n - 1], radius=radius * scale, fill=255)
    alpha = inside.point(lambda value: 255 - value).resize((size, size), Image.LANCZOS)
    image = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    image.putalpha(alpha)
    image.save(OUT / f"{name}.png")


def ring(name, size=32):
    """A white ring with a dark edge, for the marker on the colour wheel."""
    scale = 4
    n = size * scale
    image = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.ellipse([0, 0, n - 1, n - 1], fill=(0, 0, 0, 150))
    draw.ellipse([n * 0.09, n * 0.09, n * 0.91 - 1, n * 0.91 - 1], fill=(255, 255, 255, 255))
    draw.ellipse([n * 0.27, n * 0.27, n * 0.73 - 1, n * 0.73 - 1], fill=(0, 0, 0, 0))
    image.resize((size, size), Image.LANCZOS).save(OUT / f"{name}.png")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    fade("picker/fade_white", True)
    fade("picker/fade_black", False)
    hues("picker/hues")
    corners("picker/corners5", 5)
    corners("picker/corners6", 6)
    ring("picker/ring")
    # A rounded end is only a true half circle when the radius is half the height, so there is one per small size.
    for radius in (2, 3, 4, 5, 6, 7, 8, 9, 10, 12):
        rounded(f"round{radius}", radius)
    rounded_top("top8", 8)
    rounded_top("top6", 6)
    rounded_bottom("bottom6", 6)
    glow("glow12", 12, 1.5, 0)
    glow("glow12_soft", 12, 2, 2)
    frame("frame6", 6, 1)
    frame("frame8", 8, 1)
    frame("frame12", 12, 1.5)
    icon("icon_grip", grip)
    print(f"wrote {len(list(OUT.glob('*.png')))} images to {OUT}")


if __name__ == "__main__":
    main()
