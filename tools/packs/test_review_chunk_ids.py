# SPDX-License-Identifier: AGPL-3.0-only
"""Review batches must never apply a model correction to a different batch."""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


class ReviewChunkTests(unittest.TestCase):
    def test_second_review_chunk_cannot_rewrite_a_previous_subtitle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("review.py", "common.py", "atomic_json.py"):
                shutil.copyfile(HERE / name, root / name)
            (root / "translate_rules.py").write_text(
                "GLOSSARY = {'ds': ''}\nRULES = ''\n", encoding="utf-8")
            (root / "llm.py").write_text(
                "def call(system, user, schema, tag, **kwargs):\n"
                "    if user.startswith('80.0\\t'):\n"
                "        return {'fixes': [{'id': '0.0', 'tr': 'Buradan git.', 'why': 'meaning'}]}\n"
                "    return {'fixes': []}\n"
                "def spent(): return 0.0\n", encoding="utf-8")
            source = root / "review-input.json"
            source.write_text(json.dumps([{
                "speaker": "", "text": "Stop now.", "sents": ["Stop now."], "tr": ["Bekle."],
            } for _ in range(81)]), encoding="utf-8")
            out = root / "reviewed.json"
            result = subprocess.run([sys.executable, "-B", str(root / "review.py"),
                                     "ds", str(source), str(out)],
                                    cwd=root, capture_output=True, text=True,
                                    encoding="utf-8", errors="replace")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            actual = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(actual[0]["tr"], ["Bekle."],
                             "a correction emitted by chunk 80 must not modify chunk 0")
            log = json.loads((root / "reviewed.json.log.json").read_text(encoding="utf-8"))
            self.assertEqual(log["applied"], [],
                             "out-of-chunk correction must not appear in accepted review log")


    def test_duplicate_review_corrections_do_not_choose_last_arbitrarily(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("review.py", "common.py", "atomic_json.py"):
                shutil.copyfile(HERE / name, root / name)
            (root / "translate_rules.py").write_text(
                "GLOSSARY = {'ds': ''}\nRULES = ''\n", encoding="utf-8")
            (root / "llm.py").write_text(
                "def call(*args, **kwargs):\n"
                "    return {'fixes': [\n"
                "      {'id': '0.0', 'tr': 'Buradan git.', 'why': 'meaning'},\n"
                "      {'id': '0.0', 'tr': 'Simdi geri don.', 'why': 'tone'}]}\n"
                "def spent(): return 0.0\n", encoding="utf-8")
            source = root / "source.json"
            source.write_text(json.dumps([{
                "speaker": "", "text": "Stop now.", "sents": ["Stop now."], "tr": ["Bekle."],
            }]), encoding="utf-8")
            dest = root / "reviewed.json"
            result = subprocess.run([sys.executable, "-B", str(root / "review.py"),
                                     "ds", str(source), str(dest)],
                                    cwd=root, capture_output=True, text=True,
                                    encoding="utf-8", errors="replace")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(json.loads(dest.read_text(encoding="utf-8"))[0]["tr"], ["Bekle."],
                             "ambiguous duplicate correction IDs should not change approved subtitles")
            log = json.loads((root / "reviewed.json.log.json").read_text(encoding="utf-8"))
            self.assertEqual(log["applied"], [])


if __name__ == "__main__":
    unittest.main()
