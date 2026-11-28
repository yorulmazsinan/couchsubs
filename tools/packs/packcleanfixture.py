# Paket temizliği ortak deneme dosyası: tools/packs/fixtures/packclean-cases.json. Python (test_packclean.py) ve sunucu
# (server/pool/test/packclean.test.js) aynı paketlerden aynı satırları silmeli. Türkçe satırlar GTA 6 paketinden
# (28 Kas 2026 temizliği); anahtarlar İngilizce yer tutuculardan. Beklenen sonuç packclean.py'nin çıktısıdır; dosya
# yeniden üretildiğinde fark gözle denetlenir.
# Kullanım: python3 tools/packs/packcleanfixture.py
import copy
import json
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as c  # noqa: E402
import packclean  # noqa: E402

LABELS = ["Jason: Buradayım.", "Jason: Gidelim.", "Jason: Tamam.", "Jason: Hadi.", "Jason: Dur.",
          "Boobie: Evet.", "Boobie: Hayır.", "Boobie: Belki.", "Boobie: Sonra.", "Boobie: Şimdi.",
          "Kingfishers: Peki.", "Kingfishers: Hey!", "Kingfishers: Tamam.", "Kingfishers: Of.", "Kingfishers: Gel."]

MAIN = LABELS + [
    "O zamandan beri arkadaşız. Ahh, onunla da bir futbol sahasında tanıştım.",
    "Ahh, ben de onunla futbol sahasında tanıştım.",
    "Paketimi ver yeter. Yoluma giderim.",
    "Paket mi? Sana amına koyduğumun Sahara'sı gibi mi görünüyoruz? Siktir git buradan!",
    "Siktir git o zaman!",
    "Şuraya geç.",
    "Sustur şu lanet köpeği!",
    "Ve en kötüsünü görüyorum.",
    "hasta bir orospu çocuğu.",
    "Bu ülkede annelerin emzirmediğini okudum.",
    "Arabaya bin.",
    # Dökümün kendi birleşik satırı: parçaları dökümde var, döküm temizliğinde gider.
    "Arabaya bin. Jason: Buradayım.",
]
POOL = [
    # parçaları dökümde (cümle cümle ve uzatılmış harfle) var: silinir
    ("entries", "o zamandan beri arkadaşız. Boobie: Ah, ben de onunla futbol sahasında tanıştım."),
    ("entries", "Paketimi ver yeter. Kingfishers: Paket mi? Sana amına koyduğumun Sahara'sı gibi mi görünüyoruz? Siktir git buradan!"),
    # bir parçası hiçbir yerde yok: kalır (küfür olduğu gibi)
    ("entries", "Siktir git o zaman! Boobie: Bu da kimdi amına koyayım?"),
    # ses notu + konuşma: kalır
    ("entries", "[köpek havlar] Jason: Sustur şu lanet köpeği!"),
    # "Teşhis" konuşmacı değil: kalır
    ("entries", "Ve en kötüsünü görüyorum. Teşhis: hasta bir orospu çocuğu."),
    # iki birleşik satır birbirinin tek kanıtı: ikisi de kalır
    ("entries", "Gel buraya. Jason: Geliyorum, dur!"),
    ("segments", "Geliyorum, dur! Kingfishers: Gel buraya."),
    # iki kez okunmuş (en az beş sözcük): silinir; kısa gerçek tekrar kalır
    ("entries", "Bir şey olduğunu biliyordum, benim kamyonetle gidelim. Bir şey olduğunu biliyordum, benim kamyonetle gidelim."),
    ("entries", "Prezervatif ver! Prezervatif ver!"),
    ("entries", "Sakin ol, merak etme. Sakin ol, merak etme."),
    # cümlesi iki kez geçiyor, bütün cümleleri pakette: silinir
    ("entries", "Bu ülkede annelerin emzirmediğini okudum. Arabaya bin. Bu ülkede annelerin emzirmediğini okudum."),
    # büyük harf çöpü: silinir; kısaltma, büyük harfli tabela, noktalamalı bağırış kalır
    ("entries", "LOESERT Şuraya geç."),
    ("entries", "Ateş etmek için RT kullan"),
    ("entries", "UPPER .38 TABANCA"),
    ("entries", "Sustur şu lanet köpeği! CAMPION!"),
]


def main():
    entries = {c.key(f"main {i}"): tr for i, tr in enumerate(MAIN)}
    entries[c.key("shared key")] = "Arabaya bin."
    pool = {"entries": {}, "segments": {}}
    for i, (section, tr) in enumerate(POOL):
        pool[section][c.key(f"pool {i}")] = tr
    # dökümde de olan anahtar: havuzdaki silinir, döküm öncelikli
    pool["entries"][c.key("shared key")] = "Arabaya gir."
    packs = [{"id": "gta-6", "entries": entries, "segments": {}},
             {"id": "pool-gta-6", **pool}]
    removed = packclean.clean([(p["id"], p) for p in copy.deepcopy(packs)])
    out = {"packs": packs,
           "removed": [{k: item[k] for k in ("pack", "section", "key", "reason")} for item in removed]}
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "packclean-cases.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
        f.write("\n")
    for item in removed:
        print(item["pack"], item["reason"], item["turkish"])


if __name__ == "__main__":
    main()
