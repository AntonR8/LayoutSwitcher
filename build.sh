#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/LayoutSwitcher.app"

rm -rf "$DIR/build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
    -o "$APP/Contents/MacOS/LayoutSwitcher" \
    "$DIR/Sources/Extent.swift" "$DIR/Sources/main.swift" \
    -framework Cocoa -framework Carbon -framework ServiceManagement

cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

# Подпись стабильным сертификатом: designated requirement перестаёт зависеть от
# хеша бинаря, поэтому выданный доступ к Универсальному доступу переживает пересборку.
# Указан отпечаток, а не имя: в связке два сертификата с одинаковым CN, один отозван.
SIGN_ID="${SIGN_ID:-D57E1097E785188DCFE74612491335DD2C48ACC4}"

if security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    codesign --force --options runtime --sign "$SIGN_ID" "$APP"
else
    echo "⚠️  сертификат $SIGN_ID не найден — подписываю ad-hoc;" >&2
    echo "    доступ придётся выдавать заново после каждой сборки" >&2
    codesign --force --sign - "$APP"
fi

echo "собрано: $APP"
