#!/bin/bash
# Отрисовать окно настройки на всех языках во всех состояниях: ./Tests/render_setup.sh [папка] [язык…]
# Картинки ложатся в папку (по умолчанию build/setup): <язык>-<состояние>.png.
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$DIR/build/setup}"; shift || true
mkdir -p "$OUT" "$DIR/build"
swiftc -swift-version 5 -O -o "$DIR/build/render_setup" \
    "$DIR/Sources/RetroMenu.swift" "$DIR/Sources/Localization.swift" "$DIR/Sources/SetupView.swift" \
    "$DIR/Tests/RenderSetup/main.swift"
LANGS=("$@")
[ ${#LANGS[@]} -gt 0 ] || LANGS=($(cd "$DIR/Resources" && ls -d *.lproj | sed 's/\.lproj//'))
for lang in "${LANGS[@]}"; do
    for state in moved access try done; do
        "$DIR/build/render_setup" "$DIR/Resources" "$lang" "$OUT/$lang-$state.png" "$state"
    done
done
