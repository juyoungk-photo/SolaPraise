#!/bin/bash
# Compiles the detection DSP plus the harness into one binary and runs it.
# Nothing here touches the app target or the simulator.
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
xcrun swiftc -O \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  Sources/Chords/ChordModels.swift \
  Sources/Chords/NNLSChromaExtractor.swift \
  Sources/Chords/ChordDetector.swift \
  Sources/Chords/ChordHMM.swift \
  Sources/Chords/BassDetector.swift \
  Tools/main.swift \
  -o "$OUT/chord-harness"
"$OUT/chord-harness"
