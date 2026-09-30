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
     "$DIR/Sources/ShiftTap.swift" "$DIR/Sources/RetroMenu.swift" "$DIR/Sources/Localization.swift" "$DIR/Sources/AXText.swift" "$DIR/Sources/Installer.swift" "$DIR/Sources/SetupView.swift" "$DIR/Sources/SetupWindow.swift" "$DIR/Sources/main.swift")

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

# Переводы интерфейса: Resources/<язык>.lproj/Localizable.strings.
# Список языков — CFBundleLocalizations в Info.plist, должен совпадать с папками.
cp -R "$DIR"/Resources/*.lproj "$APP/Contents/Resources/"

# Логотип автора для визитки в меню.
cp "$DIR/Resources/Developer.png" "$APP/Contents/Resources/"

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
# Готовое для релиза: dist/LayoutSwitcher.dmg (основное) и dist/LayoutSwitcher.zip.
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

    # Отправить файл Apple и дождаться ответа. Падает, если не приняли.
    notarize() {
        local file="$1" log="$BUILD/notary-$(basename "$1").json"
        echo "отправляю на нотаризацию $(basename "$file") (обычно 1–5 минут)…"
        xcrun notarytool submit "$file" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" \
            --wait --output-format json > "$log" || true
        local status id
        status=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status',''))" "$log" 2>/dev/null)
        if [ "$status" != "Accepted" ]; then
            echo "❌ нотаризация $(basename "$file") не прошла: ${status:-нет ответа}" >&2
            cat "$log" >&2
            id=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('id',''))" "$log" 2>/dev/null)
            [ -n "$id" ] && echo "подробности: xcrun notarytool log $id --key … --key-id $KEY_ID --issuer $ISSUER" >&2
            exit 1
        fi
    }

    # 1. Само приложение: отправляем в zip, билет пришиваем к .app.
    ZIP="$BUILD/LayoutSwitcher.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP"
    xcrun stapler staple "$APP"

    # 2. Zip для релиза — заново, уже с пришитым билетом, чтобы проверка шла и без сети.
    #    Остаётся ради старой ссылки releases/latest/download/LayoutSwitcher.zip.
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"

    # 3. DMG — основной способ установки: в окне приложение и ярлык «Программы»,
    #    перетащил — готово. Из zip приложение часто запускают прямо из «Загрузок»,
    #    а там macOS запускает временную копию (App Translocation), и доступ к
    #    клавиатуре слетает. Образ тоже подписываем, нотаризуем и пришиваем билет.
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
    DMG="$BUILD/LayoutSwitcher.dmg"
    STAGE="$BUILD/dmg"
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/LayoutSwitcher.app"
    ln -s /Applications "$STAGE/Applications"
    mkdir -p "$STAGE/.background"
    cp "$DIR/Assets/dmg/background.tiff" "$STAGE/.background/background.tiff"

    # Оформление окна: фон и места значков. Хранится в .DS_Store тома, а
    # записать его умеет только Finder — поэтому образ сначала создаётся
    # записываемым, Finder расставляет всё через AppleScript, и лишь потом
    # образ сжимается. Координаты — центры значков, должны совпадать
    # с гнёздами на фоне (Tools/DMGBackground/main.swift).
    VOLNAME="LayoutSwitcher $VERSION"
    RW="$BUILD/LayoutSwitcher-rw.dmg"
    rm -f "$RW"
    hdiutil detach -quiet "/Volumes/$VOLNAME" 2>/dev/null || true
    hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
    rm -rf "$STAGE"
    MNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')
    [ -d "$MNT" ] || { echo "❌ не смонтировался $RW" >&2; exit 1; }
    DMG_W=640; DMG_H=400; ICON_Y=215
    if ! osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 200 + $DMG_W, 120 + $DMG_H + 28}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "LayoutSwitcher.app" of container window to {160, $ICON_Y}
        set position of item "Applications" of container window to {480, $ICON_Y}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
    then
        echo "⚠️  Finder не оформил окно DMG (нет разрешения на управление Finder?) — образ будет без фона" >&2
    fi
    # Finder пишет .DS_Store не сразу — ждём, пока появится.
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$MNT/.DS_Store" ] && break; sleep 1; done
    chmod -Rf go-w "$MNT" 2>/dev/null || true
    rm -rf "$MNT/.fseventsd"
    sync
    hdiutil detach -quiet "$MNT" || { sleep 2; hdiutil detach -force -quiet "$MNT"; }
    hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
    rm -f "$RW"
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"

    mkdir -p "$DIR/dist"
    cp "$ZIP" "$DIR/dist/LayoutSwitcher.zip"
    cp "$DMG" "$DIR/dist/LayoutSwitcher.dmg"
    spctl -a -t exec -vv "$APP" 2>&1 | sed 's/^/gatekeeper app: /'
    spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/gatekeeper dmg: /'
    echo "нотаризовано: $DIR/dist/LayoutSwitcher.dmg и LayoutSwitcher.zip"
fi
