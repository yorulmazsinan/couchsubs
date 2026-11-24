"""Regression checks for reviewed sentence alignment when building packs."""
import gzip
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("build.py")

class BuildPackTests(unittest.TestCase):
    def run_build(self, translations, rows=None, strict=False):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            source = base / "reviewed.json"
            output = base / "built.json.gz"
            source.write_text(json.dumps(rows if rows is not None else [{
                "text": "We should leave now. Stay behind.",
                "sents": ["We should leave now.", "Stay behind."],
                "tr": translations,
            }], ensure_ascii=False), encoding="utf-8")
            cmd = [sys.executable, str(SCRIPT), str(source), str(output),
                   "test-pack", "Regression test", "Source"]
            if strict:
                cmd.append("--strict")
            proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                                  env={**os.environ, "PYTHONIOENCODING": "utf-8"})
            return proc, (json.loads(gzip.decompress(output.read_bytes())) if output.exists() else None)

    def test_incomplete_or_extra_sentence_translation_is_rejected(self):
        for translations in ([], ["Now we leave."],
                             ["Now we leave.", "Wait here.", "Another line."]):
            with self.subTest(translations=translations):
                proc, pack = self.run_build(translations)
                self.assertNotEqual(proc.returncode, 0, "misaligned translations must stop package generation")
                self.assertIsNone(pack, "do not write a pack with wrong sentence alignment")

    def test_no_valid_translations_cannot_publish_an_unusable_pack(self):
        for translations in (["", ""], ["We should leave now.", "Stay behind."]):
            with self.subTest(translations=translations):
                proc, pack = self.run_build(translations)
                self.assertNotEqual(proc.returncode, 0, "a pack without full translations is rejected by clients")
                self.assertIsNone(pack, "do not emit a zero-entry package")

    def conflicting_reviewed_rows(self):
        # Two reviewed subtitles canonicalize to the same key but disagree on
        # Turkish translation: a silent last-row-wins overwrite is unsafe.
        rows = [{
            "text": "We should leave now.",
            "sents": ["We should leave now."],
            "tr": ["Şimdi gitmeliyiz."],
        }, {
            "text": "We should leave now!",
            "sents": ["We should leave now!"],
            "tr": ["Şimdi kalmalıyız."],
        }]
        return rows

    def test_conflicting_reviewed_translations_warn_and_keep_first_by_default(self):
        proc, pack = self.run_build([], rows=self.conflicting_reviewed_rows())
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(list(pack["entries"].values()), ["Şimdi gitmeliyiz."])
        self.assertIn(next(iter(pack["entries"])), proc.stderr)
        reversed_proc, reversed_pack = self.run_build(
            [], rows=list(reversed(self.conflicting_reviewed_rows())))
        self.assertEqual(reversed_proc.returncode, 0, reversed_proc.stderr)
        self.assertEqual(list(reversed_pack["entries"].values()), ["Şimdi kalmalıyız."])
        self.assertIn("conflicting reviewed translations", proc.stderr)
        self.assertIn("We should leave now.", proc.stderr)
        self.assertIn("We should leave now!", proc.stderr)
        self.assertIn("Şimdi gitmeliyiz.", proc.stderr)
        self.assertIn("Şimdi kalmalıyız.", proc.stderr)

    def test_strict_conflicting_reviewed_translations_refuse_the_pack(self):
        proc, pack = self.run_build([], rows=self.conflicting_reviewed_rows(), strict=True)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("conflicting reviewed translations", proc.stderr)
        self.assertIsNone(pack)

    def test_duplicate_reviewed_rows_with_identical_translations_are_safe(self):
        row = {"text": "We should leave now.", "sents": ["We should leave now."],
               "tr": ["Şimdi gitmeliyiz."]}
        proc, pack = self.run_build([], rows=[row, row])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(pack["entries"]), 1)
        self.assertNotIn("conflicting reviewed translations", proc.stderr)

    def test_valid_aligned_subtitles_still_build(self):
        proc, pack = self.run_build(["Now we leave.", "Wait here."])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(pack["id"], "test-pack")
        self.assertEqual(len(pack["entries"]), 1)
        self.assertEqual(len(pack["segments"]), 2)

if __name__ == "__main__":
    unittest.main()
