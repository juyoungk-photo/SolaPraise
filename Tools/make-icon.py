#!/usr/bin/env python3
"""Draws the SolaPraise mark: the app icon and the OAuth consent logo.

Three C's, nested and turned to face upward — the church's initials read one
way, hands open to receive read the other, with the gold dot above as the
thing being received.

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
    # 15°→165° is the lower arc: a C turned to face the sky.
    for r, col in [(int(SS * 0.355), CREAM),
                   (int(SS * 0.265), CREAM2),
                   (int(SS * 0.175), CREAM)]:
        ld.arc([cx - r, cy - r, cx + r, cy + r], 15, 165,
               fill=col + (255,), width=int(SS * 0.052))
    rr = int(SS * 0.058)
    ld.ellipse([cx - rr, int(SS * 0.235) - rr, cx + rr, int(SS * 0.235) + rr],
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
