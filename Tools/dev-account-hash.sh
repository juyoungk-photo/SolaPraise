#!/bin/sh
# The value to put in Secrets.xcconfig's DEV_ACCOUNTS for an address, so
# the address itself never goes into the app (see Sources/Chords/DevGate.swift).
#
#   Tools/dev-account-hash.sh someone@example.org
#   DEV_ACCOUNTS = <hash>, <hash>
#
# Lowercased first, as the app compares.
[ -n "$1" ] || { echo "usage: $0 ADDRESS" >&2; exit 1; }
printf %s "$1" | tr '[:upper:]' '[:lower:]' | shasum -a 256 | cut -d' ' -f1
