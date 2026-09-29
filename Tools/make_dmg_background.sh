#!/bin/bash
# Перерисовать фон окна DMG: Assets/dmg/background.tiff (1x + 2x в одном файле).
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$DIR/Assets/dmg" "$DIR/build"
swiftc -swift-version 5 -O -o "$DIR/build/dmg_background" "$DIR/Tools/DMGBackground/main.swift"
"$DIR/build/dmg_background" "$DIR/Assets/dmg/background.tiff"
