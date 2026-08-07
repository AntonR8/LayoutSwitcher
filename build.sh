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
# Конкретный сертификат задаётся снаружи: SIGN_ID=<отпечаток> ./build.sh
#
# ВАЖНО про отозванные сертификаты. Подписать отозванным сертификатом — хуже,
# чем не подписывать вовсе: macOS считает такую сборку вредоносом, показывает
# «Malware Blocked and Moved to Trash» и молча переносит приложение в Корзину.
# Обойти это пользователь не может никак. Ad-hoc в этом смысле безопаснее:
# Gatekeeper всего лишь просит подтвердить запуск.
#
# Верить `security find-identity` тут нельзя: он показывает закешированный
# статус и спокойно отдаёт как «валидный» сертификат, отозванный Apple.
# Единственная надёжная проверка — подписать и спросить Gatekeeper.
sign_is_revoked() {
    spctl -a -t exec "$APP" 2>&1 | grep -q "CSSMERR_TP_CERT_REVOKED"
}

if [ -n "$SIGN_ID" ]; then
    codesign --force --options runtime --sign "$SIGN_ID" "$APP"
    if sign_is_revoked; then
        echo "❌ сертификат $SIGN_ID ОТОЗВАН Apple." >&2
        echo "   Сборка с ним будет опознана как вредонос и удалена в Корзину." >&2
        echo "   Пересобираю с ad-hoc-подписью." >&2
        SIGN_ID=""
    else
        echo "подписано: $(security find-identity -v -p codesigning | grep "$SIGN_ID" | sed 's/.*"\(.*\)".*/\1/')"
    fi
fi

if [ -z "$SIGN_ID" ]; then
    codesign --force --options runtime --sign - "$APP"
    echo "подписано ad-hoc — доступ к Универсальному доступу придётся выдавать заново"
    echo "после каждой пересборки: он привязан к подписи, а у ad-hoc она меняется."
fi

# Последний рубеж: не выпускать сборку, которую система удалит как вредонос.
if sign_is_revoked; then
    echo "❌ подпись всё ещё числится отозванной — сборка непригодна к распространению" >&2
    exit 1
fi

echo "собрано: $APP"
lipo -archs "$APP/Contents/MacOS/LayoutSwitcher" | sed 's/^/архитектуры: /'
