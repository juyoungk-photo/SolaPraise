# Branding assets

## consent-logo-120.png

The logo for Google's OAuth consent screen, cut from the app icon so the
screen a teammate sees when signing in carries the same mark as the app
they are signing in to.

Google's requirements: square, 120×120, JPG/PNG/BMP. This is a straight
resize of `Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` — regenerate
it with:

    sips -s format png -z 120 120 \
      Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png \
      --out Resources/Branding/consent-logo-120.png

### Before uploading it

Uploading a logo to an External app that is published triggers **brand
verification** — a Google review, which also wants a homepage and a privacy
policy on a domain we control. Publishing the consent screen WITHOUT a logo
needs none of that, and publishing is the part that matters: it ends the
7-day refresh token expiry that makes everyone sign in again weekly.

So the order is: publish first, add the logo later if the review is worth it.
