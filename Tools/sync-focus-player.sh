#!/bin/zsh
#
#  sync-focus-player.sh — copies FocusPlayerKit's web files into SolaPraise.
#
#  WHY A COPY: SolaPraise is a public repository and must build from a fresh
#  clone. Pointing project.yml at ../FocusPlayerKit made every clone without
#  that sibling stop at xcodegen ("missing source directory"), and
#  FocusPlayerKit is not published. The family hub copies the same files the
#  same way (its tools/sync-player.sh).
#
#  Run from the SolaPraise root after changing FocusPlayerKit/web:
#      Tools/sync-focus-player.sh
#  Tools/check-player-page.swift fails while the copy and a FocusPlayerKit
#  checked out next to SolaPraise differ.
#
set -euo pipefail
KIT="${1:-../FocusPlayerKit}"
DEST="Vendor/FocusPlayerKit"
[[ -d "$KIT/web" ]] || { echo "no $KIT/web — pass the FocusPlayerKit path"; exit 1; }
rm -rf "$DEST/web"
mkdir -p "$DEST"
cp -R "$KIT/web" "$DEST/web"
VERSION=$(grep -oE "VERSION = '[^']+'" "$KIT/web/focus-player.js" | cut -d"'" -f2)
COMMIT=$(git -C "$KIT" rev-parse --short HEAD 2>/dev/null || echo unknown)
DIRTY=$(git -C "$KIT" status --porcelain web 2>/dev/null | head -1)
printf "FocusPlayerKit %s (%s%s)\n" "$VERSION" "$COMMIT" "${DIRTY:+, with uncommitted changes}" > "$DEST/VERSION"
cat "$DEST/VERSION"
