#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/LayoutSwitcher.app"

# Минимальная версия macOS. Должна совпадать с LSMinimumSystemVersion в Info.plist:
# иначе Launch Services пустит приложение на старую систему, а dyld откажется его
# грузить. Без явного -target swiftc берёт версию хоста, и сборка на свежей macOS
# молча получает minos = версии сборочной машины.
DEPLOY="13.0"

SRC=("$DIR/Sources/Mapping.swift" "$DIR/Sources/Extent.swift" \
     "$DIR/Sources/AXText.swift" "$DIR/Sources/main.swift")

rm -rf "$DIR/build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary: swiftc за один вызов делает только одну архитектуру,
# поэтому собираем обе и склеиваем через lipo. Без x86_64 приложение
# не запустится ни на одном Intel-маке.
for ARCH in arm64 x86_64; do
    swiftc -O -swift-version 5 \
        -target "$ARCH-apple-macos$DEPLOY" \
        -o "$DIR/build/LayoutSwitcher-$ARCH" \
        "${SRC[@]}" \
        -framework Cocoa -framework Carbon -framework ServiceManagement
done

lipo -create -output "$APP/Contents/MacOS/LayoutSwitcher" \
    "$DIR/build/LayoutSwitcher-arm64" "$DIR/build/LayoutSwitcher-x86_64"
rm -f "$DIR/build/LayoutSwitcher-arm64" "$DIR/build/LayoutSwitcher-x86_64"

cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

# Подпись стабильным сертификатом: designated requirement перестаёт зависеть от
# хеша бинаря, поэтому выданный доступ к Универсальному доступу переживает пересборку.
# Сменится сертификат — доступ придётся выдать заново, это нормально и ожидаемо.
#
# Конкретный сертификат можно задать снаружи: SIGN_ID=<отпечаток> ./build.sh
# Иначе берём первый неотозванный, предпочитая Developer ID (с ним сборку можно
# нотаризовать и раздавать без плясок с карантином).
pick_identity() {
    local list preferred
    list=$(security find-identity -v -p codesigning 2>/dev/null | grep -v REVOKED || true)
    preferred=$(echo "$list" | grep "Developer ID Application" | grep -oE '[0-9A-F]{40}' | head -1)
    if [ -n "$preferred" ]; then
        echo "$preferred"
    else
        echo "$list" | grep -oE '[0-9A-F]{40}' | head -1
    fi
}

if [ -n "$SIGN_ID" ]; then
    if ! security find-identity -v -p codesigning | grep -v REVOKED | grep -q "$SIGN_ID"; then
        echo "❌ сертификат $SIGN_ID не найден или отозван" >&2
        exit 1
    fi
else
    SIGN_ID="$(pick_identity | head -1)"
fi

if [ -n "$SIGN_ID" ]; then
    codesign --force --options runtime --sign "$SIGN_ID" "$APP"
    echo "подписано: $(security find-identity -v -p codesigning | grep "$SIGN_ID" | sed 's/.*"\(.*\)".*/\1/')"
else
    echo "⚠️  сертификатов для подписи не найдено — подписываю ad-hoc;" >&2
    echo "    доступ к Универсальному доступу придётся выдавать заново после каждой сборки" >&2
    codesign --force --sign - "$APP"
fi

echo "собрано: $APP"
lipo -archs "$APP/Contents/MacOS/LayoutSwitcher" | sed 's/^/архитектуры: /'
