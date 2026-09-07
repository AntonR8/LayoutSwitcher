#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/LayoutSwitcher.app"

# Минимальная версия macOS. Должна совпадать с LSMinimumSystemVersion в Info.plist:
# иначе Launch Services пустит приложение на старую систему, а dyld откажется его
# грузить. Без явного -target swiftc берёт версию хоста, и сборка на свежей macOS
# молча получает minos = версии сборочной машины.
DEPLOY="13.0"

SRC=("$DIR/Sources/Mapping.swift" "$DIR/Sources/Extent.swift" "$DIR/Sources/Chain.swift" \
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

# Значок приложения собирается в двух видах, потому что одного не хватает.
#
# Assets/AppIcon.icon — документ Icon Composer. actool превращает его в
# Assets.car, откуда macOS 26 берёт «живой» значок со всеми эффектами.
# Побочно actool кладёт и AppIcon.icns, но он обрезан по 256×256 — это
# запасной вариант Apple, и в Finder на крупных размерах он мылит.
#
# Assets/icon.png — плоская отрисовка того же значка в 1024×1024, из неё
# ниже собирается полноразмерный .icns для macOS 13…15, где .icon не
# поддерживается. Файл перекрывает обрезанный .icns от actool.
ICON_DOC="$DIR/Assets/AppIcon.icon"
if [ -d "$ICON_DOC" ] && xcrun --find actool >/dev/null 2>&1; then
    actool "$ICON_DOC" --compile "$APP/Contents/Resources" --app-icon AppIcon \
        --output-partial-info-plist "$DIR/build/icon-partial.plist" \
        --platform macosx --minimum-deployment-target "$DEPLOY" >/dev/null 2>&1
    if [ -f "$APP/Contents/Resources/Assets.car" ]; then
        echo "значок: Assets.car (macOS 26)"
    else
        echo "⚠️  actool не собрал Assets.car — на macOS 26 значок будет обычным" >&2
    fi
elif [ -d "$ICON_DOC" ]; then
    echo "⚠️  нет actool (нужен Xcode) — Assets.car не собран" >&2
fi

ICON_SRC="$DIR/Assets/icon.png"
if [ -f "$ICON_SRC" ]; then
    SIZE=$(sips -g pixelWidth "$ICON_SRC" | awk '/pixelWidth/{print $2}')
    [ "$SIZE" -ge 1024 ] || echo "⚠️  Assets/icon.png шириной ${SIZE}px, нужно 1024 — значок будет мылить" >&2

    ICONSET="$DIR/build/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for PAIR in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" \
                "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
        set -- $PAIR
        sips -z "$1" "$1" "$ICON_SRC" --out "$ICONSET/icon_$2.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
    echo "значок: AppIcon.icns (полноразмерный, для macOS 13…15)"
else
    echo "⚠️  Assets/icon.png не найден — приложение соберётся без значка" >&2
fi

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
