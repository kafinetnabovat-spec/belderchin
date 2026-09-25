#!/usr/bin/env python3
"""Trace silhouette_source.png into assets/images/logo.svg (single-colour brand mark).

Requires:  pip install potracer numpy pillow
Usage:     python3 tools/branding/trace_logo_svg.py
"""

from __future__ import annotations

import pathlib

import numpy as np
import potrace
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
BRAND_PRIMARY = "#CA4F12"


def main() -> None:
    im = Image.open(HERE / "silhouette_source.png").convert("L").resize((512, 512), Image.LANCZOS)
    # potracer treats False as foreground, so invert: the white bird becomes the traced shape.
    bitmap = potrace.Bitmap(np.array(im) <= 128)
    path = bitmap.trace(turdsize=20, alphamax=1.0, opticurve=True, opttolerance=0.2)
    parts: list[str] = []
    for curve in path:
        sp = curve.start_point
        parts.append(f"M{sp.x:.1f} {sp.y:.1f}")
        for seg in curve:
            if seg.is_corner:
                c, e = seg.c, seg.end_point
                parts.append(f"L{c.x:.1f} {c.y:.1f}L{e.x:.1f} {e.y:.1f}")
            else:
                c1, c2, e = seg.c1, seg.c2, seg.end_point
                parts.append(f"C{c1.x:.1f} {c1.y:.1f} {c2.x:.1f} {c2.y:.1f} {e.x:.1f} {e.y:.1f}")
        parts.append("Z")
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">\n'
        f'  <path fill="{BRAND_PRIMARY}" fill-rule="evenodd" d="{"".join(parts)}"/>\n'
        "</svg>\n"
    )
    out = ROOT / "assets" / "images" / "logo.svg"
    out.write_text(svg)
    print("wrote", out.relative_to(ROOT))


if __name__ == "__main__":
    main()
