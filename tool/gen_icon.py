"""
One-off generator for the DupeSweep app icon: a smartphone showing a
stack of duplicate photos, with AI sparkle diamonds accenting the
cleanup, on a deep jewel-tone background. Renders at high resolution
then downsamples for anti-aliasing, and writes both the Android legacy
mipmap PNGs and reference master assets.

Not part of the app build -- run manually with `python tool/gen_icon.py`
whenever the icon design changes.
"""
from PIL import Image, ImageDraw, ImageFilter

CANVAS = 2048  # supersample size; downsampled per target with LANCZOS

# -- palette -------------------------------------------------------------
BG_TOP = (35, 10, 66)       # vivid aubergine
BG_BOTTOM = (4, 4, 12)      # near-black indigo
GLOW = (79, 209, 255)       # cyan glow behind the phone

PHONE_BODY = (18, 16, 34)
PHONE_EDGE = (233, 250, 255)     # near-white outline
SCREEN_TOP = (56, 209, 255)
SCREEN_BOTTOM = (20, 30, 60)

PHOTO_BACK_STOPS = [(110, 70, 255), (56, 12, 120)]     # violet card (behind)
PHOTO_FRONT_STOPS = [(210, 255, 253), (56, 209, 255)]  # cyan card (front)
PHOTO_EDGE = (233, 250, 255)
MOUNTAIN_COLOR = (255, 255, 255)
SUN_COLOR = (255, 214, 120)

SPARK = (255, 255, 255)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def vgradient(size_w, size_h, top, bottom):
    img = Image.new("RGB", (size_w, size_h))
    px = img.load()
    for y in range(size_h):
        c = lerp(top, bottom, y / max(1, size_h - 1))
        for x in range(size_w):
            px[x, y] = c
    return img


def rounded_rect_mask(size_w, size_h, radius):
    mask = Image.new("L", (size_w, size_h), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size_w - 1, size_h - 1], radius=radius, fill=255)
    return mask


def draw_sparkle(draw, cx, cy, size, color, alpha=255):
    """Wide 4-point diamond sparkle, drawn as a single polygon."""
    long_ = size
    short = size * 0.62
    pts = [(cx, cy - long_), (cx + short, cy), (cx, cy + long_), (cx - short, cy)]
    draw.polygon(pts, fill=color + (alpha,))


def photo_card(w, h, stops, outline, size):
    """A rounded-rect photo tile with a simple mountain+sun glyph."""
    card = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    grad = vgradient(w, h, stops[0], stops[1]).convert("RGBA")
    mask = rounded_rect_mask(w, h, int(h * 0.16))
    card.paste(grad, (0, 0), mask)
    d = ImageDraw.Draw(card, "RGBA")
    d.rounded_rectangle(
        [1, 1, w - 2, h - 2], radius=int(h * 0.16),
        outline=outline + (220,), width=max(2, int(size * 0.006)),
    )

    sun_r = h * 0.11
    sun_cx, sun_cy = w * 0.28, h * 0.32
    d.ellipse([sun_cx - sun_r, sun_cy - sun_r, sun_cx + sun_r, sun_cy + sun_r], fill=SUN_COLOR + (255,))

    base_y = h * 0.78
    d.polygon(
        [(w * 0.06, base_y), (w * 0.40, h * 0.40), (w * 0.62, h * 0.60), (w * 0.94, base_y)],
        fill=MOUNTAIN_COLOR + (235,),
    )
    d.polygon(
        [(w * 0.42, base_y), (w * 0.68, h * 0.48), (w * 0.94, base_y)],
        fill=MOUNTAIN_COLOR + (170,),
    )
    return card


def render(size):
    bg = vgradient(size, size, BG_TOP, BG_BOTTOM).convert("RGBA")

    # ambient glow
    glow_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow_layer)
    gd.ellipse([size * 0.10, size * 0.14, size * 0.90, size * 0.94], fill=GLOW + (100,))
    glow_layer = glow_layer.filter(ImageFilter.GaussianBlur(size * 0.07))
    bg = Image.alpha_composite(bg, glow_layer)

    # -- phone body ---------------------------------------------------
    phone_w, phone_h = size * 0.46, size * 0.72
    phone_x0 = size * 0.50 - phone_w * 0.62
    phone_y0 = size * 0.52 - phone_h * 0.50
    phone_x1 = phone_x0 + phone_w
    phone_y1 = phone_y0 + phone_h
    radius = phone_w * 0.16

    phone_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pd = ImageDraw.Draw(phone_layer)
    pd.rounded_rectangle(
        [phone_x0, phone_y0, phone_x1, phone_y1], radius=radius,
        fill=PHONE_BODY + (255,), outline=PHONE_EDGE + (255,), width=max(3, int(size * 0.009)),
    )
    bg = Image.alpha_composite(bg, phone_layer)

    # screen inset
    bez = phone_w * 0.07
    scr_x0, scr_y0 = phone_x0 + bez, phone_y0 + bez * 1.3
    scr_x1, scr_y1 = phone_x1 - bez, phone_y1 - bez * 1.3
    scr_w, scr_h = scr_x1 - scr_x0, scr_y1 - scr_y0
    screen = vgradient(int(scr_w), int(scr_h), SCREEN_TOP, SCREEN_BOTTOM).convert("RGBA")
    scr_mask = rounded_rect_mask(int(scr_w), int(scr_h), int(scr_w * 0.14))
    bg.paste(screen, (int(scr_x0), int(scr_y0)), scr_mask)

    # -- duplicate photo stack, centered inside the screen -------------
    card_w, card_h = scr_w * 0.56, scr_w * 0.56
    cx, cy = (scr_x0 + scr_x1) / 2, (scr_y0 + scr_y1) / 2

    back = photo_card(int(card_w), int(card_h), PHOTO_BACK_STOPS, PHOTO_EDGE, size)
    front = photo_card(int(card_w), int(card_h), PHOTO_FRONT_STOPS, PHOTO_EDGE, size)

    offset = card_w * 0.16
    back_x, back_y = cx - card_w * 0.5 - offset * 0.5, cy - card_h * 0.5 - offset * 0.5
    front_x, front_y = cx - card_w * 0.5 + offset * 0.5, cy - card_h * 0.5 + offset * 0.5

    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(
        [front_x + 4, front_y + 6, front_x + card_w + 4, front_y + card_h + 6],
        radius=card_h * 0.16, fill=(0, 0, 0, 90),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(size * 0.012))
    bg = Image.alpha_composite(bg, shadow)

    bg.alpha_composite(back, (int(back_x), int(back_y)))
    bg.alpha_composite(front, (int(front_x), int(front_y)))

    # -- AI sparkle accents --------------------------------------------
    spark_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd2 = ImageDraw.Draw(spark_layer)
    draw_sparkle(sd2, phone_x1 + size * 0.055, phone_y0 + size * 0.02, size * 0.085, SPARK, alpha=245)
    draw_sparkle(sd2, phone_x1 - size * 0.01, phone_y0 - size * 0.05, size * 0.040, SPARK, alpha=190)
    draw_sparkle(sd2, phone_x0 - size * 0.04, phone_y1 - size * 0.10, size * 0.036, SPARK, alpha=150)
    bg = Image.alpha_composite(bg, spark_layer)

    return bg.convert("RGB")


def main():
    master = render(CANVAS)

    targets = {
        "android/app/src/main/res/mipmap-mdpi/ic_launcher.png": 48,
        "android/app/src/main/res/mipmap-hdpi/ic_launcher.png": 72,
        "android/app/src/main/res/mipmap-xhdpi/ic_launcher.png": 96,
        "android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png": 144,
        "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png": 192,
        "assets/icon/app_icon.png": 1024,
    }

    for path, size in targets.items():
        resized = master.resize((size, size), Image.LANCZOS)
        resized.save(path)
        print(f"wrote {path} ({size}x{size})")


if __name__ == "__main__":
    main()
