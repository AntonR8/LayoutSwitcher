#!/bin/bash
# Отрисовать меню на всех языках: ./Tests/render_menu.sh [папка] [--no-access] [--a11y]
# Картинки ложатся в папку (по умолчанию build/menu), по одной на язык.
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$DIR/build/menu}"; shift || true
mkdir -p "$OUT" "$DIR/build"
swiftc -swift-version 5 -O -o "$DIR/build/render_menu" \
    "$DIR/Sources/RetroMenu.swift" "$DIR/Sources/Localization.swift" "$DIR/Tests/RenderMenu/main.swift"
for lproj in "$DIR"/Resources/*.lproj; do
    lang=$(basename "$lproj" .lproj)
    "$DIR/build/render_menu" "$DIR/Resources" "$lang" "$OUT/$lang.png" "$@"
done
