#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
# Собираем вне папки проекта: если она лежит в iCloud Drive, тот вешает на
# бандл свои атрибуты (fileprovider, FinderInfo), и codesign отказывается его
# подписывать. Переопределяется: BUILD=<папка> ./build.sh
BUILD="${BUILD:-$HOME/Library/Caches/LayoutSwitcher/build}"
APP="$BUILD/LayoutSwitcher.app"

# Минимальная версия macOS. Должна совпадать с LSMinimumSystemVersion в Info.plist:
# иначе Launch Services пустит приложение на старую систему, а dyld откажется его
# грузить. Без явного -target swiftc берёт версию хоста, и сборка на свежей macOS
# молча получает minos = версии сборочной машины.
DEPLOY="13.0"

SRC=("$DIR/Sources/Mapping.swift" "$DIR/Sources/Extent.swift" "$DIR/Sources/Chain.swift" \
     "$DIR/Sources/ShiftTap.swift" "$DIR/Sources/RetroMenu.swift" "$DIR/Sources/AXText.swift" "$DIR/Sources/main.swift")

rm -rf "$BUILD"
mkdir -p "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary: swiftc за один вызов делает только одну архитектуру,
# поэтому собираем обе и склеиваем через lipo. Без x86_64 приложение
# не запустится ни на одном Intel-маке.
for ARCH in arm64 x86_64; do
    swiftc -O -swift-version 5 \
        -target "$ARCH-apple-macos$DEPLOY" \
        -o "$BUILD/LayoutSwitcher-$ARCH" \
        "${SRC[@]}" \
        -framework Cocoa -framework Carbon -framework ServiceManagement
done

lipo -create -output "$APP/Contents/MacOS/LayoutSwitcher" \
    "$BUILD/LayoutSwitcher-arm64" "$BUILD/LayoutSwitcher-x86_64"
rm -f "$BUILD/LayoutSwitcher-arm64" "$BUILD/LayoutSwitcher-x86_64"

cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

# Значок в строке меню. Исходники — Assets/StatusIcon.svg и StatusIconOn.svg
# (зелёная стрелка: одиночный Shift меняет раскладку). PNG отрисованы из них
# заранее: NSImage на macOS 13 SVG не читает.
cp "$DIR"/Assets/StatusIcon*.png "$APP/Contents/Resources/"

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
        --output-partial-info-plist "$BUILD/icon-partial.plist" \
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

    ICONSET="$BUILD/AppIcon.iconset"
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
    # --timestamp: защищённая метка времени от Apple, без неё нотаризация
    # сборку не примет. Нужна сеть.
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
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

# Нотаризация: NOTARIZE=1 SIGN_ID=<отпечаток Developer ID Application> ./build.sh
#
# Сборку проверяет Apple, результат «пришивается» к приложению (staple), и
# скачанный архив открывается двойным кликом — без «Apple не удалось проверить»
# и без «Всё равно открыть» в настройках. Годится только подпись сертификатом
# Developer ID Application; Apple Development и ad-hoc Apple отклонит.
#
# Ключ App Store Connect API берётся из ~/.appstoreconnect/config.json
# (key_id, issuer_id, key_path) либо из ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH.
# Готовый архив для релиза: dist/LayoutSwitcher.zip.
if [ "$NOTARIZE" = "1" ]; then
    if ! codesign -dvv "$APP" 2>&1 | grep -q "^Authority=Developer ID Application"; then
        echo "❌ для нотаризации нужна подпись Developer ID Application (SIGN_ID)" >&2
        exit 1
    fi

    CONFIG="$HOME/.appstoreconnect/config.json"
    cfg() { python3 -c "import json,os,sys; print(os.path.expanduser(json.load(open(sys.argv[1]))[sys.argv[2]]))" "$CONFIG" "$1" 2>/dev/null; }
    KEY_ID="${ASC_KEY_ID:-$(cfg key_id)}"
    ISSUER="${ASC_ISSUER_ID:-$(cfg issuer_id)}"
    KEY_PATH="${ASC_KEY_PATH:-$(cfg key_path)}"
    [ -n "$KEY_PATH" ] || KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8"
    if [ -z "$KEY_ID" ] || [ -z "$ISSUER" ] || [ ! -f "$KEY_PATH" ]; then
        echo "❌ нет ключа App Store Connect API — см. комментарий у NOTARIZE в build.sh" >&2
        exit 1
    fi

    ZIP="$BUILD/LayoutSwitcher.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "отправляю на нотаризацию (обычно 1–5 минут)…"
    xcrun notarytool submit "$ZIP" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" \
        --wait --output-format json > "$BUILD/notary.json" || true
    STATUS=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status',''))" "$BUILD/notary.json" 2>/dev/null)
    if [ "$STATUS" != "Accepted" ]; then
        echo "❌ нотаризация не прошла: ${STATUS:-нет ответа}" >&2
        cat "$BUILD/notary.json" >&2
        ID=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('id',''))" "$BUILD/notary.json" 2>/dev/null)
        [ -n "$ID" ] && echo "подробности: xcrun notarytool log $ID --key … --key-id $KEY_ID --issuer $ISSUER" >&2
        exit 1
    fi

    xcrun stapler staple "$APP"
    # Архив заново — уже с пришитым билетом, чтобы проверка шла и без сети.
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    mkdir -p "$DIR/dist"
    cp "$ZIP" "$DIR/dist/LayoutSwitcher.zip"
    spctl -a -t exec -vv "$APP" 2>&1 | sed 's/^/gatekeeper: /'
    echo "нотаризовано: $DIR/dist/LayoutSwitcher.zip"
fi
