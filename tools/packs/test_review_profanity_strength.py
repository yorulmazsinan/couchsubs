# SPDX-License-Identifier: AGPL-3.0-only
"""Mild English exclamations must not allow an unrelated severe Turkish insult."""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


class ReviewProfanityStrengthTests(unittest.TestCase):
    def review(self, english, old, proposed):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ("review.py", "common.py", "atomic_json.py"):
                shutil.copy2(HERE / name, root / name)
            (root / "translate_rules.py").write_text(
                "GLOSSARY = {'ds': ''}\nRULES = ''\n", encoding="utf-8")
            (root / "llm.py").write_text(
                "def call(*args, **kwargs):\n"
                + "    return {'fixes': [{'id': '0.0', 'tr': " + repr(proposed)
                + ", 'why': 'tone'}]}\n"
                + "def spent(): return 0.0\n", encoding="utf-8")
            source = root / "source.json"
            source.write_text(json.dumps([{
                "speaker": "", "text": english, "sents": [english], "tr": [old],
            }], ensure_ascii=False), encoding="utf-8")
            output = root / "reviewed.json"
            proc = subprocess.run(
                [sys.executable, "-B", str(root / "review.py"), "ds", str(source), str(output)],
                cwd=root, capture_output=True, text=True, encoding="utf-8", errors="replace")
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            lines = json.loads(output.read_text(encoding="utf-8"))
            log = json.loads((root / "reviewed.json.log.json").read_text(encoding="utf-8"))
            return lines[0]["tr"][0], log

    def test_mild_english_hell_does_not_justify_severe_turkish_expletive(self):
        updated, log = self.review("What the hell?", "Ne oluyor?", "Siktir, ne oluyor?")
        self.assertEqual(updated, "Ne oluyor?")
        self.assertEqual(log["applied"], [])
        self.assertEqual(log["vetoed"][0]["veto"], "added-profanity")

    def test_mild_turkish_equivalent_remains_accepted(self):
        updated, log = self.review("What the hell?", "Ne oluyor?", "Lanet olsun, ne oluyor?")
        self.assertEqual(updated, "Lanet olsun, ne oluyor?")
        self.assertEqual(len(log["applied"]), 1)

    def test_strong_english_profanity_still_allows_matching_turkish(self):
        updated, log = self.review("Fuck this.", "Bunu istemiyorum.", "Siktir et.")
        self.assertEqual(updated, "Siktir et.")
        self.assertEqual(len(log["applied"]), 1)


if __name__ == "__main__":
    unittest.main()
