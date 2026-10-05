#!/usr/bin/env python3
"""Draws the SolaPraise mark: the app icon and the OAuth consent logo.

Three C's, nested and turned to face upward — the church's initials read one
way, hands open to receive read the other, with a small cross above as what
is held up.

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
    cx, cy = SS // 2, int(SS * 0.46)
    # The lower arc of each circle: a C turned to face the sky. Equal spans,
    # which keeps the three C's reading as one family rather than as a fan.
    for r, col in [(int(SS * 0.355), CREAM),
                   (int(SS * 0.265), CREAM2),
                   (int(SS * 0.175), CREAM)]:
        ld.arc([cx - r, cy - r, cx + r, cy + r], 15, 165,
               fill=col + (255,), width=int(SS * 0.052))

    # A small Latin cross, crossbar at the upper third as it is drawn.
    ccx, ccy = SS // 2, int(SS * 0.215)
    h, w = int(SS * 0.165), int(SS * 0.042)
    bar = int(h * 0.58)
    ld.rounded_rectangle([ccx - w // 2, ccy - h // 2, ccx + w // 2, ccy + h // 2],
                         radius=w // 2, fill=GOLD + (255,))
    by = ccy - h // 2 + int(h * 0.30)
    ld.rounded_rectangle([ccx - bar // 2, by - w // 2, ccx + bar // 2, by + w // 2],
                         radius=w // 2, fill=GOLD + (255,))

    layer = layer.resize((S, S), Image.LANCZOS)
    img.paste(layer, (0, 0), layer)
    return img


if __name__ == "__main__":
    icon = draw()
    icon.save("Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
    # 120×120 is what Google's consent screen asks for.
    icon.resize((120, 120), Image.LANCZOS).save("Resources/Branding/consent-logo-120.png")
    print("wrote app icon and consent logo")
