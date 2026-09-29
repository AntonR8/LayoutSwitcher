#!/usr/bin/env python3
"""Проверка переводов: все языки полные, ключи из кода существуют,
список в Info.plist совпадает с папками Resources/*.lproj."""
import glob, os, plistlib, re, subprocess, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
errors = []

def load(path):
    # plutil понимает формат .strings и отдаёт его как словарь.
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", path],
                         capture_output=True, text=True)
    if out.returncode:
        errors.append(f"{path}: не читается — {out.stderr.strip()}")
        return {}
    import json
    return json.loads(out.stdout)

tables = {os.path.basename(os.path.dirname(p)).removesuffix(".lproj"): load(p)
          for p in sorted(glob.glob(os.path.join(root, "Resources", "*.lproj", "Localizable.strings")))}
base = tables.get("en", {})
if not base:
    errors.append("нет базового en.lproj")

for lang, table in tables.items():
    missing = sorted(set(base) - set(table))
    extra = sorted(set(table) - set(base))
    empty = sorted(k for k, v in table.items() if not v.strip())
    if missing: errors.append(f"{lang}: нет ключей {missing}")
    if extra:   errors.append(f"{lang}: лишние ключи {extra}")
    if empty:   errors.append(f"{lang}: пустые строки {empty}")

used = set()
for src in glob.glob(os.path.join(root, "Sources", "*.swift")):
    used |= set(re.findall(r'\bL\("([^"]+)"\)', open(src, encoding="utf-8").read()))
for key in sorted(used - set(base)):
    errors.append(f"ключ из кода отсутствует в переводах: {key}")
for key in sorted(set(base) - used):
    errors.append(f"ключ в переводах нигде не используется: {key}")

declared = plistlib.load(open(os.path.join(root, "Info.plist"), "rb")).get("CFBundleLocalizations", [])
if sorted(declared) != sorted(tables):
    errors.append(f"CFBundleLocalizations {sorted(declared)} ≠ папки {sorted(tables)}")

for e in errors:
    print("✗", e)
print(f"переводы: {len(tables)} языков, {len(base)} ключей, в коде {len(used)} —",
      "всё сходится" if not errors else f"ошибок {len(errors)}")
sys.exit(1 if errors else 0)
