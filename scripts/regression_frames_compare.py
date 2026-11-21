#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Gerçek kare gerileme setinin iki koşusunu (önceki etiket, bu çekirdek) karşılaştırır (scripts/regression-frames.sh).

Kırmızı (çıkış 1): altyazı yakalama oranı düştü, yanlış kabul arttı ya da telefon/harita sınıflaması, kutu örtme, telefon
çevirisi senaryosu, konuşan adı sonradan okunan satır (tek satır) ya da ekran yazısı (menü sekmeleri, görev listesi, özel ad, fotoğraf/tuş simgesi örtme) geriledi. Ayrıca karede kare: önceki etikette geçip bu çekirdekte kalan her kare listelenir.
GITHUB_STEP_SUMMARY tanımlıysa tablo oraya da yazılır.
"""

import json
import os
import sys

# (anahtar, ad, düşük mü iyi)
METRICS = [
    ("capture", "Altyazı satırı yakalama", False),
    ("falseAccept", "Yanlış kabul (tabela/altyazısız)", True),
    ("phone", "Telefon sınıflama", False),
    ("map", "Harita kartı sınıflama", False),
    ("cover", "Çizim kutusu örtme (piksel ≥%95)", False),
    ("phoneTranslation", "Telefon çevirisi gösteriliyor", False),
    ("speaker", "Konuşan adı sonradan (tek satır)", False),
    ("screen", "Ekran yazısı (menü, görev listesi)", False),
]


def rate(metric):
    return 1.0 if metric["total"] == 0 else metric["passed"] / metric["total"]


def shown(metric, lower):
    count = metric["total"] - metric["passed"] if lower else metric["passed"]
    value = (1 - rate(metric)) if lower else rate(metric)
    return f"{count}/{metric['total']} (%{value * 100:.1f})"


def frame_failures(summary):
    failed = {}
    for frame in summary["frames"]:
        notes = []
        if frame.get("captured") is False:
            notes.append("altyazı yakalanmadı")
        if frame.get("falseAccept") is False:
            notes.append("yanlış kabul")
        if frame["phoneExpected"] != frame["phoneDetected"]:
            notes.append(f"telefon {frame['phoneExpected']}≠{frame['phoneDetected']}")
        if frame["mapExpected"] != frame["mapDetected"]:
            notes.append("harita kartı")
        if frame.get("coverage") is not None and frame["coverage"] < 0.95:
            notes.append("kutu örtmüyor")
        if frame.get("screen") is False:
            notes.append("ekran yazısı: " + "; ".join(frame.get("screenNotes") or []))
        if notes:
            failed[frame["id"]] = notes
    for scenario in summary["scenarios"]:
        if not scenario["passed"]:
            failed["telefon senaryosu " + scenario["name"]] = [scenario["detail"]]
    for scenario in summary.get("speakerScenarios", []):
        if not scenario["passed"]:
            failed["konuşan adı senaryosu " + scenario["name"]] = [scenario["detail"]]
    return failed


def main():
    base = json.load(open(sys.argv[1], encoding="utf-8"))
    head = json.load(open(sys.argv[2], encoding="utf-8"))
    lines = [f"### Gerçek kare gerileme seti: {head['core']} ↔ {base['core']} ({len(head['frames'])} kare)", "",
             f"| Ölçüt | {base['core']} | {head['core']} | Durum |", "|---|---|---|---|"]
    red = False
    for key, name, lower in METRICS:
        # Ölçütü bilmeyen eski koşucunun özeti: boş sayılır.
        b, h = base.get(key, {"passed": 0, "total": 0}), head.get(key, {"passed": 0, "total": 0})
        if key == "cover":
            # Kutu yalnız yakalanan satırlarda ölçülür; paydalar farklı olabilir. Önceki etikette örten, bu çekirdekte
            # örtmeyen kare varsa gerilemedir.
            def covered(summary):
                return {f["id"]: f["coverage"] >= 0.95 for f in summary["frames"] if f.get("coverage") is not None}
            cb, ch = covered(base), covered(head)
            worse = any(ok and ch.get(i) is False for i, ok in cb.items())
            better = any(not ok and ch.get(i) is True for i, ok in cb.items())
        else:
            worse = rate(h) < rate(b) - 1e-9
            better = rate(h) > rate(b) + 1e-9
        red |= worse
        state = "🔴 geriledi" if worse else ("🟢 iyileşti" if better else "🟢 aynı")
        lines.append(f"| {name} | {shown(b, lower)} | {shown(h, lower)} | {state} |")
    before, after = frame_failures(base), frame_failures(head)
    regressed = {k: v for k, v in after.items() if k not in before}
    fixed = [k for k in before if k not in after]
    if regressed:
        lines += ["", f"**{base['core']} sürümünde geçip {head['core']} sürümünde kalan kareler:**"]
        lines += [f"- {k}: {', '.join(v)}" for k, v in sorted(regressed.items())]
    if fixed:
        lines += ["", f"{head['core']} sürümünde düzelen: " + ", ".join(sorted(fixed))]
    lines += ["", ("**KIRMIZI:** " + head["core"] + " önceki etiketin (" + base["core"] + ") altında; sürüm çıkmamalı.")
              if red else f"YEŞİL: {head['core']} önceki etiketten ({base['core']}) geride değil."]
    text = "\n".join(lines)
    print(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as out:
            out.write(text + "\n")
    sys.exit(1 if red else 0)


if __name__ == "__main__":
    main()
