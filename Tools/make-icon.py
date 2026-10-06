#!/usr/bin/env python3
"""Draws the SolaPraise mark: the app icon and the OAuth consent logo.

A vessel with two lines cut through it, and a small cross above. Three bands
remain — the church's initials read one way, a cup open to receive reads the
other, with the cross as what is held up.

IT IS A SOLID SHAPE ON PURPOSE. Three separate nested strokes is the WiFi
glyph's own construction, and ours was that glyph mirrored: turning it
upward and swapping the dot for a cross helped, but the silhouette still
belonged to the same family. A filled bowl with gaps cut out of it is a
different kind of thing, not a milder version of the same thing — a signal
meter is strokes, a vessel is a shape.

The cross replaced a plain dot. Concentric arcs with a dot on their vertical
axis is the WiFi glyph, and ours was that glyph upside down — an app icon
that reads as a network utility before it reads as anything else. A cross
cannot be mistaken for a signal, and it says plainly what the dot only
implied — which is also why the arcs did not need changing: it is the dot
on the vertical axis that makes the WiFi reading, not the arcs beneath it.

Both sizes come from here so they cannot drift apart: the icon on the home
screen and the logo on the sign-in screen are the same drawing.
"""
from PIL import Image, ImageDraw

S = 1024
NAVY_TOP, NAVY_BOT = (26, 31, 58), (9, 12, 24)
CREAM, CREAM2, GOLD = (245, 234, 206), (226, 214, 186), (231, 178, 76)


def draw() -> Image.Image:
    img = Image.new("RGB", (S, S))
    d = ImageDraw.Draw(img)
    for y in range(S):
        t = y / S
        d.line([(0, y), (S, y)],
               fill=tuple(int(NAVY_TOP[i] + (NAVY_BOT[i] - NAVY_TOP[i]) * t)
                          for i in range(3)))

    # Drawn at 4x and downsampled: PIL's arc has no antialiasing, and at icon
    # size the stair-stepping on a curve this thick is the first thing you see.
    SS = S * 4
    layer = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    cx, cy = SS // 2, int(SS * 0.44)
    # A filled half-disc, then two arcs painted in the background colour to
    # cut it into three bands. Drawn this way rather than as three strokes
    # because the strokes are what read as a signal meter.
    R = int(SS * 0.345)
    ld.pieslice([cx - R, cy - R, cx + R, cy + R], 8, 172,
                fill=CREAM + (255,))
    for r in (0.247, 0.147):
        rr = int(SS * r)
        ld.arc([cx - rr, cy - rr, cx + rr, cy + rr], 0, 180,
               fill=NAVY_BOT + (255,), width=int(SS * 0.030))

    # A small Latin cross, crossbar at the upper third as it is drawn.
    #
    # Square corners, not rounded. Rounding a stroke this short eats most of
    # its length into the curve, and at 120px the arms stopped meeting at a
    # right angle — the one thing that makes a cross a cross. Slightly
    # heavier too, so it holds its own against the three arcs below.
    ccx, ccy = SS // 2, int(SS * 0.205)
    h, w = int(SS * 0.175), int(SS * 0.048)
    bar = int(h * 0.62)
    ld.rectangle([ccx - w // 2, ccy - h // 2, ccx + w // 2, ccy + h // 2],
                 fill=GOLD + (255,))
    by = ccy - h // 2 + int(h * 0.31)
    ld.rectangle([ccx - bar // 2, by - w // 2, ccx + bar // 2, by + w // 2],
                 fill=GOLD + (255,))

    layer = layer.resize((S, S), Image.LANCZOS)
    img.paste(layer, (0, 0), layer)
    return img


if __name__ == "__main__":
    icon = draw()
    icon.save("Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
    # 120×120 is what Google's consent screen asks for.
    icon.resize((120, 120), Image.LANCZOS).save("Resources/Branding/consent-logo-120.png")
    print("wrote app icon and consent logo")
