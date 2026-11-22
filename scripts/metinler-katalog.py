#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Yeni arayüzün metinleri: design/yeni-arayuz/METINLER.md'deki "| EN | TR |" tablolarını ortak kataloğa
# (mac/CouchSubs/Resources/Localizable.xcstrings; Mac, iPhone ve Windows okur) yazar.
#  - Katalogda olmayan anahtar en + tr ile eklenir (dosyanın geri kalanı yeniden biçimlenmez).
#  - Katalogda Türkçesi farklı olan anahtar raporlanır, üzerine yazılmaz (eski ekranlar o metni kullanıyor olabilir).
#  - Aynı İngilizce anahtar belgede iki farklı Türkçeyle geçerse hata.
# Kullanım: python3 scripts/metinler-katalog.py [--check]   (--check: yazmaz, eksik/çelişki varsa çıkış kodu 1)
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOC = ROOT / "design" / "yeni-arayuz" / "METINLER.md"
CATALOG = ROOT / "mac" / "CouchSubs" / "Resources" / "Localizable.xcstrings"


def rows():
    """Belgedeki (en, tr) çiftleri; yalnız başlığı "| EN | TR |" olan tablolar."""
    pairs, in_table = [], False
    for line in DOC.read_text().splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")] if line.startswith("|") else None
        if cells is None:
            in_table = False
            continue
        if cells == ["EN", "TR"]:
            in_table = True
            continue
        if not in_table or set("".join(cells)) <= set("-: "):
            continue
        if len(cells) != 2:
            sys.exit(f"İki sütunlu olmayan satır: {line}")
        pairs.append((cells[0], cells[1]))
    return pairs


def main():
    check = "--check" in sys.argv
    pairs = rows()
    seen, errors = {}, []
    for en, tr in pairs:
        if en in seen and seen[en] != tr:
            errors.append(f"Belgede iki farklı Türkçe: {en!r} → {seen[en]!r} / {tr!r}")
        seen[en] = tr
    if errors:
        print("\n".join(errors))
        sys.exit(1)

    text = CATALOG.read_text()
    strings = json.loads(text)["strings"]
    missing, differs = [], []
    for en, tr in seen.items():
        entry = strings.get(en)
        if entry is None:
            missing.append((en, tr))
            continue
        current = entry.get("localizations", {}).get("tr", {}).get("stringUnit", {}).get("value")
        if current != tr:
            differs.append((en, current, tr))

    for en, current, tr in differs:
        print(f"Katalogda farklı Türkçe (değiştirilmedi): {en!r}: {current!r}, belge: {tr!r}")
    if check:
        for en, _ in missing:
            print(f"Katalogda yok: {en!r}")
        if missing or differs:
            sys.exit(1)
        print(f"Tamam: {len(seen)} metnin hepsi katalogda.")
        return

    if missing:
        def entry(en, tr):
            unit = lambda v: {"stringUnit": {"state": "translated", "value": v}}
            return f"    {json.dumps(en, ensure_ascii=False)}: " + json.dumps({"localizations": {"en": unit(en), "tr": unit(tr)}}, ensure_ascii=False)
        tail = re.search(r"\n  \},\n  \"version\"", text)
        if not tail:
            sys.exit("Katalog sonu bulunamadı.")
        body = text[:tail.start()].rstrip()
        insert = ",\n".join(entry(en, tr) for en, tr in missing)
        text = body + ",\n" + insert + text[tail.start():]
        json.loads(text)  # bozuk JSON yazılmasın
        CATALOG.write_text(text)
    print(f"{len(missing)} metin eklendi, {len(differs)} çelişki raporlandı ({len(seen)} metin).")


main()
