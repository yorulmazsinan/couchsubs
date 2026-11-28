"""packclean.py: yalnız bozuk satırları siler, çeviriye dokunmaz, bulanık imzaları korur."""
import base64
import copy
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as c  # noqa: E402
import packclean  # noqa: E402

LABELS = ["Jason: Buradayım.", "Jason: Gidelim.", "Jason: Tamam.", "Jason: Hadi.", "Jason: Dur.",
          "Boobie: Evet.", "Boobie: Hayır.", "Boobie: Belki.", "Boobie: Sonra.", "Boobie: Şimdi."]


def pack(pack_id, entries, segments=None, english=None):
    """Satırlardan biçim 2 paket (anahtarlar İngilizceden); english verilirse bulanık imzalar da yazılır."""
    entries = {c.key(en): tr for en, tr in entries}
    segments = {c.key(en): tr for en, tr in (segments or [])}
    result = {"format": 2, "id": pack_id, "title": "Test", "source": "deneme", "entries": entries, "segments": segments}
    if english:
        order = sorted({int(k, 16) for k in list(entries) + list(segments)})
        result["fuzzy"] = c.fuzzy_index(order, {int(c.key(en), 16): en for en in english})
    return result


def lines(*pairs):
    return [(f"english {i} {tr}", tr) for i, tr in enumerate(pairs)]


class PackCleanTests(unittest.TestCase):
    def clean(self, *packs):
        named = [(p["id"] + ".json.gz", p) for p in packs]
        removed = packclean.clean(named)
        return {item["turkish"]: item["reason"] for item in removed}

    def test_merged_speakers_go_only_when_every_part_exists_on_its_own(self):
        main = pack("gta-6", lines(*LABELS,
                                   "o zamandan beri arkadaşız. Boobie: Ah, ben de onunla futbol sahasında tanıştım.",
                                   "O zamandan beri arkadaşız.",
                                   "Ahh, ben de onunla futbol sahasında tanıştım.",
                                   "Siktir git o zaman! Boobie: Bu da kimdi amına koyayım?",
                                   "Siktir git o zaman!",
                                   "[köpek havlar] Jason: Sustur şu köpeği!",
                                   "Sustur şu köpeği!",
                                   "Ve en kötüsünü görüyorum. Teşhis: hasta bir orospu çocuğu.",
                                   "Ve en kötüsünü görüyorum.",
                                   "hasta bir orospu çocuğu."))
        removed = self.clean(main)
        self.assertEqual(removed, {
            "o zamandan beri arkadaşız. Boobie: Ah, ben de onunla futbol sahasında tanıştım.": "konusmaci-birlesik"})
        # Kalan satırların Türkçesi (küfür dahil) aynen durur.
        self.assertIn("Siktir git o zaman! Boobie: Bu da kimdi amına koyayım?", main["entries"].values())
        self.assertIn("Ve en kötüsünü görüyorum. Teşhis: hasta bir orospu çocuğu.", main["entries"].values())

    def test_merged_rows_are_not_each_others_evidence(self):
        main = pack("gta-6", lines(*LABELS,
                                   "Gel buraya. Jason: Geliyorum, dur!",
                                   "Gel buraya. Jason: Geliyorum, dur!",
                                   "Gel buraya."))
        self.assertEqual(self.clean(main), {})

    def test_doubled_reading_goes_short_repetition_stays(self):
        main = pack("gta-6", lines("Bir şey olduğunu biliyordum, benim kamyonetle gidelim. "
                                   "Bir şey olduğunu biliyordum, benim kamyonetle gidelim.",
                                   "Prezervatif ver! Prezervatif ver!",
                                   "Sakin ol, merak etme. Sakin ol, merak etme."))
        removed = self.clean(main)
        self.assertEqual(list(removed.values()), ["tekrar"])
        self.assertEqual(len(main["entries"]), 2)

    def test_leftover_english_capitals_go_only_next_to_a_known_line(self):
        main = pack("gta-6", lines("LOESERT Şuraya geç, hemen.", "Şuraya geç, hemen.",
                                   "Ateş etmek için RT kullan", "Ateş etmek için",
                                   "UPPER .38 TABANCA", "TABANCA",
                                   "Kötü şans herhalde. CAMPION!", "Kötü şans herhalde."))
        self.assertEqual(self.clean(main), {"LOESERT Şuraya geç, hemen.": "buyuk-harf-copu"})

    def test_pool_line_does_not_override_the_dump(self):
        main = pack("gta-6", [("Get in the car.", "Arabaya bin.")])
        pool = pack("pool-gta-6", [("Get in the car.", "Arabaya gir."), ("Hold on.", "Bekle.")])
        removed = self.clean(main, pool)
        self.assertEqual(removed, {"Arabaya gir.": "havuz-dokumde-var"})
        self.assertEqual(list(main["entries"].values()), ["Arabaya bin."])
        self.assertEqual(list(pool["entries"].values()), ["Bekle."])

    def test_fuzzy_signatures_of_kept_lines_survive(self):
        english = ["Somebody call an ambulance right now!", "Get in the car, we're leaving town.",
                   "Jason said we been friends ever since. Boobie said hi."]
        main = pack("gta-6", [(english[0], "Biri hemen ambulans çağırsın!"),
                              (english[1], "Arabaya bin, şehirden gidiyoruz."),
                              (english[2], "Biri hemen ambulans çağırsın! Boobie: Arabaya bin, şehirden gidiyoruz."),
                              *lines(*LABELS)], english=english)
        before = packclean.fuzzy_records(main)
        removed = self.clean(main)
        self.assertEqual(list(removed.values()), ["konusmaci-birlesik"])
        after = packclean.fuzzy_records(main)
        gone = int(c.key(english[2]), 16)
        self.assertEqual(after, {k: v for k, v in before.items() if k != gone})
        self.assertEqual(main["fuzzy"]["count"], len(main["entries"]) + len(main["segments"]))
        base64.b64decode(main["fuzzy"]["blooms"])


class SharedCasesTests(unittest.TestCase):
    def test_same_rows_as_the_pool_server(self):
        """Ortak deneme dosyası (server/pool/test/packclean.test.js da okur): sunucu aynı satırları siler."""
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "packclean-cases.json")
        with open(path, encoding="utf-8") as f:
            cases = json.load(f)
        packs = copy.deepcopy(cases["packs"])
        removed = packclean.clean([(p["id"], p) for p in packs])
        self.assertEqual([{k: item[k] for k in ("pack", "section", "key", "reason")} for item in removed], cases["removed"])
        self.assertTrue(any(item["pack"] == "pool-gta-6" for item in cases["removed"]))


if __name__ == "__main__":
    unittest.main()
