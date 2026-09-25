#!/usr/bin/env python3
"""Generate all Belderchin launcher / notification / splash assets from the two
source images in this directory.

Sources
-------
- icon_source.png        : full-colour quail on a sand background (1024x1024)
- silhouette_source.png  : white quail silhouette on black (1024x1024)

Usage
-----
    python3 tools/branding/generate_android_assets.py

Only Pillow is required.  The script is idempotent and overwrites the generated
files under android/app/src/main/res and assets/images.
"""

from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parents[2]
RES = ROOT / "android" / "app" / "src" / "main" / "res"
ASSETS = ROOT / "assets" / "images"
HERE = pathlib.Path(__file__).resolve().parent

SAND = (242, 221, 189)  # brand background (#F2DDBD)
TERRACOTTA = (202, 79, 18)  # brand primary (#CA4F12)

DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def load_icon() -> Image.Image:
    """Returns the source icon as a full-bleed RGB square (corners filled with sand)."""
    src = Image.open(HERE / "icon_source.png").convert("RGBA")
    canvas = Image.new("RGBA", src.size, SAND + (255,))
    # The generated source has rounded corners with a near-white fill; mask them out.
    mask = Image.new("L", src.size, 0)
    r = int(src.size[0] * 0.13)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, src.size[0] - 1, src.size[1] - 1], radius=r, fill=255)
    canvas.paste(src, (0, 0), mask)
    rgb = canvas.convert("RGB")
    # Any remaining near-white corner pixels become sand as well.
    px = rgb.load()
    w, h = rgb.size
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            if min(r, g, b) >= 250:
                px[x, y] = SAND
    return rgb


def load_silhouette() -> Image.Image:
    """Returns the silhouette as an 'L' alpha mask (white bird == opaque)."""
    src = Image.open(HERE / "silhouette_source.png").convert("L")
    # Threshold to kill compression noise, then soften edges slightly.
    return src.point(lambda v: 255 if v > 128 else 0).filter(ImageFilter.GaussianBlur(0.6))


def scaled_center(img: Image.Image, canvas_px: int, scale: float, bg) -> Image.Image:
    """Scales img to `scale * canvas_px` and centres it on a canvas of colour bg."""
    out = Image.new(img.mode, (canvas_px, canvas_px), bg)
    size = max(1, int(round(canvas_px * scale)))
    resized = img.resize((size, size), Image.LANCZOS)
    off = (canvas_px - size) // 2
    if img.mode == "RGBA":
        out.paste(resized, (off, off), resized)
    else:
        out.paste(resized, (off, off))
    return out


def rounded(img: Image.Image, radius_ratio: float) -> Image.Image:
    mask = Image.new("L", img.size, 0)
    r = int(img.size[0] * radius_ratio)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1], radius=r, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def circular(img: Image.Image) -> Image.Image:
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).ellipse([0, 0, img.size[0] - 1, img.size[1] - 1], fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def write(img: Image.Image, path: pathlib.Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, optimize=True)
    print("wrote", path.relative_to(ROOT))


def main() -> None:
    icon = load_icon()
    sil = load_silhouette()

    # --- Launcher icons -------------------------------------------------------
    for density, factor in DENSITIES.items():
        legacy_px = int(48 * factor)
        # Legacy icons: the bird should look a bit bigger than inside the adaptive mask.
        legacy = scaled_center(icon, legacy_px, 1.0, SAND)
        write(rounded(legacy, 0.18), RES / f"mipmap-{density}" / "ic_launcher.png")
        write(circular(legacy), RES / f"mipmap-{density}" / "ic_launcher_round.png")

        # Adaptive foreground (108dp canvas, visible safe zone = central 66dp).
        fg_px = int(108 * factor)
        fg = scaled_center(icon, fg_px, 0.92, SAND)
        write(fg, RES / f"mipmap-{density}" / "ic_launcher_foreground.png")

        # Monochrome layer for themed icons (Android 13+): alpha-only silhouette.
        mono = Image.new("RGBA", (fg_px, fg_px), (255, 255, 255, 0))
        mono_mask = scaled_center(sil, fg_px, 0.56, 0)
        mono.putalpha(mono_mask)
        write(mono, RES / f"drawable-{density}" / "ic_launcher_monochrome.png")

        # Notification / tile icon (24dp, white on transparent).
        stat_px = int(24 * factor)
        stat = Image.new("RGBA", (stat_px, stat_px), (255, 255, 255, 0))
        stat.putalpha(scaled_center(sil, stat_px, 1.0, 0))
        write(stat, RES / f"drawable-{density}" / "ic_stat_logo.png")

    # --- Splash (legacy launch_background + Android 12 icon) -------------------
    # flutter_native_splash-compatible layout: a 1x1 background bitmap plus a
    # centred splash bitmap per density.
    write(Image.new("RGB", (1, 1), SAND), RES / "drawable" / "background.png")
    write(Image.new("RGB", (1, 1), SAND), RES / "drawable-v21" / "background.png")
    for density, factor in DENSITIES.items():
        splash_px = int(160 * factor)
        splash = scaled_center(icon, splash_px, 1.0, SAND)
        write(rounded(splash, 0.22), RES / f"drawable-{density}" / "splash.png")
        # Android 12+ splash icon: 108dp canvas, icon inside central 2/3 circle.
        s12_px = int(108 * factor)
        s12 = Image.new("RGBA", (s12_px, s12_px), (0, 0, 0, 0))
        inner = circular(scaled_center(icon, int(s12_px * 0.66), 1.0, SAND))
        off = (s12_px - inner.size[0]) // 2
        s12.paste(inner, (off, off), inner)
        write(s12, RES / f"drawable-{density}" / "android12splash.png")

    # --- Flutter in-app assets --------------------------------------------------
    write(rounded(scaled_center(icon, 512, 1.0, SAND), 0.18), ASSETS / "app_icon.png")
    logo_mark = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
    logo_mark.putalpha(scaled_center(sil, 512, 1.0, 0))
    # Colour the silhouette with the brand primary for a monochrome in-app mark.
    coloured = Image.new("RGBA", (512, 512), TERRACOTTA + (255,))
    coloured.putalpha(logo_mark.getchannel("A"))
    write(coloured, ASSETS / "logo_mark.png")

    # Desktop tray icons are not shipped on Android, but the Dart code references
    # them, so regenerate them from the brand mark instead of keeping upstream art.
    def tray(colour, size=64):
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        fill = Image.new("RGBA", (size, size), colour + (255,))
        fill.putalpha(scaled_center(sil, size, 1.0, 0))
        img.paste(fill, (0, 0), fill)
        return img

    variants = {
        "tray_icon": TERRACOTTA,
        "tray_icon_dark": (255, 255, 255),
        "tray_icon_connected": (46, 125, 50),
        "tray_icon_disconnected": (120, 120, 120),
    }
    for name, colour in variants.items():
        img = tray(colour)
        write(img, ASSETS / f"{name}.png")
        img.save(ASSETS / f"{name}.ico", format="ICO", sizes=[(16, 16), (32, 32), (64, 64)])
        print("wrote", (ASSETS / f"{name}.ico").relative_to(ROOT))


if __name__ == "__main__":
    main()
