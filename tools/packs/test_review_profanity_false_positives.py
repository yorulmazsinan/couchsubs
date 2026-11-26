# SPDX-License-Identifier: AGPL-3.0-only
"""Ordinary Turkish words that start like a swear are not profanity; real swears are still caught.

Küfür kuralı: çeviride küfür asla sansürlenmez ve yumuşatılmaz. Bu düzeltmeler yalnız tanımayı düzeltir: "götür",
"alçakgönüllü", "boks", "siklet" küfür sayılmaz; gerçek küfür biçimleri ("götün", "boktan", "sikerim", "alçak") eskisi
gibi tanınır. Yeni sert İngilizce sözcükler (cock, twat, wanker, douche, faggot, retard) yumuşak çeviride işaretlenir.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def run_review(en, old, proposed):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for name in ("review.py", "common.py", "atomic_json.py"):
            shutil.copy2(HERE / name, root / name)
        (root / "translate_rules.py").write_text("GLOSSARY = {'ds': ''}\nRULES = ''\n", encoding="utf-8")
        (root / "llm.py").write_text(
            "def call(*args, **kwargs):\n"
            + "    return {'fixes': [{'id': '0.0', 'tr': " + repr(proposed) + ", 'why': 'meaning'}]}\n"
            + "def spent(): return 0.0\n", encoding="utf-8")
        source = root / "source.json"
        source.write_text(json.dumps([{"speaker": "", "text": en, "sents": [en], "tr": [old]}]), encoding="utf-8")
        output = root / "reviewed.json"
        result = subprocess.run([sys.executable, "-B", str(root / "review.py"), "ds", str(source), str(output)],
                                cwd=root, capture_output=True, text=True, encoding="utf-8", errors="replace")
        if result.returncode != 0:
            raise AssertionError(result.stdout + result.stderr)
        lines = json.loads(output.read_text(encoding="utf-8"))
        log = json.loads((root / "reviewed.json.log.json").read_text(encoding="utf-8"))
        return lines[0]["tr"][0], log, result.stdout


PLAIN_EN = "What a classic trick."
PLAIN_OLD = "Bu eski bir numara."


class ReviewProfanityFalsePositiveTests(unittest.TestCase):
    def test_ordinary_words_are_not_added_profanity(self):
        for fix in ("Bunu eve götür.", "Onu oraya götürmek istiyorum.", "Götürün onu!", "Alçakgönüllü bir adamdı.",
                    "Alçak gönüllü bir adamdı.", "Boks maçı başlıyor.", "Boksör yere düştü.", "Bokstan sıkıldım.", "Boksa başladı.",
                    "Ağır siklet şampiyonu.", "Hafif sikletin en iyisi.", "Sık sık gelir.", "Amin, dedi."):
            with self.subTest(fix=fix):
                translated, log, _ = run_review(PLAIN_EN, PLAIN_OLD, fix)
                self.assertEqual(log["vetoed"], [])
                self.assertEqual(translated, fix)

    def test_real_swears_are_still_caught(self):
        # Detection only got narrower for the ordinary words above; every real form is still profanity.
        for fix in ("Götün kalkmış.", "Göt herif.", "Bok gibi.", "Boktan bir gün.", "Siktir git.", "Sikerim böyle işi.",
                    "Alçak herif!", "Alçaklık bu.", "Seni gidi kıç.", "Amına koyayım.", "SİKTİR GİT."):
            with self.subTest(fix=fix):
                translated, log, _ = run_review(PLAIN_EN, PLAIN_OLD, fix)
                self.assertEqual(translated, PLAIN_OLD)
                self.assertEqual(log["vetoed"][0]["veto"], "added-profanity")

    def test_ordinary_word_does_not_hide_a_softened_swear(self):
        # "götür" used to count as "göt", so a softened "ass" line was not flagged.
        for en, old in (("Move your ass!", "Şunu götür!"), ("Fuck the boxing.", "Boksu boşver."),
                        ("Shit, the heavyweight.", "Eyvah, ağır siklet.")):
            with self.subTest(en=en):
                _, _, stdout = run_review(en, old, old + " ")
                self.assertIn("'softened': 1", stdout)

    # (English, softened old translation, full-strength fix)
    NEW_STRONG = [
        ("You cocksucker!", "Seni alçak!", "Seni yarak yalayıcı!"),
        ("Suck my cock.", "Defol git.", "Sik beni."),
        ("Shut up, you twat.", "Kapa çeneni, salak.", "Kapa çeneni, amcık."),
        ("You wanker.", "Seni ahmak.", "Seni otuzbirci."),
        ("What a douchebag.", "Ne kaba adam.", "Ne yavşak herif."),
        ("Get out, faggot.", "Defol, herif.", "Defol, ibne."),
        ("Don't be a retard.", "Aptallık etme.", "Gerizekalı olma."),
    ]

    def test_new_strong_english_words_flag_soft_translations(self):
        for en, old, _ in self.NEW_STRONG:
            with self.subTest(en=en):
                _, _, stdout = run_review(en, old, old + " ")
                self.assertIn("'softened': 1", stdout)

    def test_full_strength_fix_for_new_strong_words_is_applied(self):
        for en, old, fix in self.NEW_STRONG:
            with self.subTest(en=en):
                translated, log, _ = run_review(en, old, fix)
                self.assertEqual(log["vetoed"], [])
                self.assertEqual(translated, fix)

    def test_lookalike_english_words_are_not_strong(self):
        for en in ("The cockpit is ready.", "Grab a cocktail.", "Fire retardant foam.", "Hancock is here."):
            with self.subTest(en=en):
                translated, log, _ = run_review(en, "Hazır.", "Siktir git, hazır.")
                self.assertEqual(translated, "Hazır.")
                self.assertEqual(log["vetoed"][0]["veto"], "added-profanity")

    def test_strong_insult_words_are_not_made_stricter(self):
        # "gerizekalı" counts as full strength for "retard" but is not a new veto for ordinary insults.
        translated, log, _ = run_review("You idiot.", "Seni aptal.", "Seni gerizekalı.")
        self.assertEqual(log["vetoed"], [])
        self.assertEqual(translated, "Seni gerizekalı.")


if __name__ == "__main__":
    unittest.main()
