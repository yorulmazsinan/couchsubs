# SPDX-License-Identifier: AGPL-3.0-only
"""Profanity guard must not misread ordinary Turkish words as insults."""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


class ReviewProfanityBoundariesTests(unittest.TestCase):
    def review(self, proposed):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("review.py", "common.py", "atomic_json.py"):
                shutil.copy2(HERE / name, root / name)
            (root / "translate_rules.py").write_text(
                "GLOSSARY = {'ds': ''}\nRULES = ''\n", encoding="utf-8")
            (root / "llm.py").write_text(
                "def call(*args, **kwargs):\n"
                + "    return {'fixes': [{'id': '0.0', 'tr': " + repr(proposed) + ", 'why': 'term'}]}\n"
                + "def spent(): return 0.0\n", encoding="utf-8")
            source = root / "source.json"
            source.write_text(json.dumps([{
                "speaker": "", "text": "What a classic trick.",
                "sents": ["What a classic trick."], "tr": ["Bu eski bir numara."],
            }]), encoding="utf-8")
            output = root / "reviewed.json"
            result = subprocess.run([sys.executable, "-B", str(root / "review.py"),
                                     "ds", str(source), str(output)], cwd=root,
                                    capture_output=True, text=True,
                                    encoding="utf-8", errors="replace")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            lines = json.loads(output.read_text(encoding="utf-8"))
            details = json.loads((root / "reviewed.json.log.json").read_text(encoding="utf-8"))
            return lines[0]["tr"][0], details

    def test_klasik_does_not_count_as_turkish_profanity(self):
        translated, log = self.review("Bu klasik bir numara.")
        self.assertEqual(translated, "Bu klasik bir numara.")
        self.assertEqual(len(log["applied"]), 1)
        self.assertEqual(log["vetoed"], [])

    def test_actual_word_initial_profanity_is_still_rejected(self):
        translated, log = self.review("Siktir git.")
        self.assertEqual(translated, "Bu eski bir numara.")
        self.assertEqual(len(log["applied"]), 0)
        self.assertEqual(log["vetoed"][0]["veto"], "added-profanity")


if __name__ == "__main__":
    unittest.main()
