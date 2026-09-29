#!/bin/bash
# Выпуск версии одной командой:
#
#   ./release.sh 1.16 notes.md
#
# notes.md — описание релиза (Markdown). SHA-256 файлов допишется само.
#
# Что делает, по порядку, и останавливается на первой ошибке:
#   1. проверяет, что ветка main, дерево чистое и нет отставания от GitHub;
#   2. поднимает версию в Info.plist (CFBundleShortVersionString и CFBundleVersion);
#   3. прогоняет тесты;
#   4. собирает, подписывает Developer ID и нотаризует (DMG + zip);
#   5. коммитит «Версия X», пушит, создаёт релиз vX с DMG и zip;
#   6. скачивает файлы по ссылкам «latest» и сверяет с собранными.
#
# Сертификат: SIGN_ID=<отпечаток> или первый найденный «Developer ID Application».
# COMMIT_TRAILER — строки, которые допишутся в конец сообщения коммита.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
REPO="AntonR8/LayoutSwitcher"

VERSION="${1:-}"
NOTES="${2:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || [ ! -f "$NOTES" ]; then
    echo "использование: ./release.sh <версия, например 1.16> <файл с описанием релиза>" >&2
    exit 2
fi

fail() { echo "❌ $*" >&2; exit 1; }

# 1. Состояние репозитория
[ "$(git branch --show-current)" = "main" ] || fail "нужна ветка main"
[ -z "$(git status --porcelain)" ] || fail "есть незакоммиченные изменения — сначала закоммить их"
git fetch -q origin
[ "$(git rev-list --count HEAD..origin/main)" = "0" ] || fail "на GitHub есть коммиты, которых тут нет — сначала git pull"
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && fail "тег v$VERSION уже есть"
gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1 && fail "релиз v$VERSION уже есть на GitHub"

if [ -z "${SIGN_ID:-}" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $0; exit}' | awk '{print $2}')
    [ -n "$SIGN_ID" ] || fail "не найден сертификат Developer ID Application (или задай SIGN_ID)"
fi
export SIGN_ID

# 2. Версия
PLIST="$DIR/Info.plist"
OLD=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")
BUILD_NO=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST")
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $((BUILD_NO + 1))" "$PLIST"
echo "версия: $OLD → $VERSION (сборка $((BUILD_NO + 1)))"
# Если дальше что-то упадёт — вернуть Info.plist, чтобы не оставлять полуготовый выпуск.
RESTORE_PLIST=1
trap '[ "$RESTORE_PLIST" = 1 ] && git checkout -q -- "$PLIST" 2>/dev/null; true' EXIT

# 3. Тесты
./test.sh > /dev/null || fail "тесты не прошли — ./test.sh"
echo "тесты: прошли"

# 4. Сборка и нотаризация
LOG="$HOME/Library/Caches/LayoutSwitcher/release-build.log"
mkdir -p "$(dirname "$LOG")"
NOTARIZE=1 ./build.sh > "$LOG" 2>&1 || { tail -20 "$LOG" >&2; fail "сборка или нотаризация не прошли — полный лог: $LOG"; }
grep -E "подписано|нотаризовано|gatekeeper" "$LOG" || true
DMG="$DIR/dist/LayoutSwitcher.dmg"
ZIP="$DIR/dist/LayoutSwitcher.zip"
[ -f "$DMG" ] && [ -f "$ZIP" ] || fail "нет dist/LayoutSwitcher.dmg или .zip"
BUILT=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    "$HOME/Library/Caches/LayoutSwitcher/build/LayoutSwitcher.app/Contents/Info.plist")
[ "$BUILT" = "$VERSION" ] || fail "собралась версия $BUILT, а не $VERSION"

# 5. Коммит, релиз
RESTORE_PLIST=0
git add "$PLIST"
git commit -q -m "Версия $VERSION${COMMIT_TRAILER:+

$COMMIT_TRAILER}"
git push -q origin main

BODY="$(mktemp)"
{
    cat "$NOTES"
    echo
    echo "---"
    echo
    echo "**SHA-256**"
    echo '```'
    (cd "$DIR/dist" && shasum -a 256 LayoutSwitcher.dmg LayoutSwitcher.zip)
    echo '```'
} > "$BODY"
gh release create "v$VERSION" "$DMG" "$ZIP" -R "$REPO" --title "v$VERSION" --notes-file "$BODY" --target main
rm -f "$BODY"

# 6. Проверка: по ссылкам «latest» отдаются ровно эти файлы
CHECK="$(mktemp -d)"
for f in LayoutSwitcher.dmg LayoutSwitcher.zip; do
    curl -sfL -o "$CHECK/$f" "https://github.com/$REPO/releases/latest/download/$f" || fail "не скачивается $f"
    cmp -s "$CHECK/$f" "$DIR/dist/$f" || fail "по ссылке latest отдаётся не тот $f"
done
rm -rf "$CHECK"
echo "✅ v$VERSION выпущена: https://github.com/$REPO/releases/tag/v$VERSION"
