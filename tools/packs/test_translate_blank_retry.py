# SPDX-License-Identifier: AGPL-3.0-only
"""Empty model translations are still missing: retry rather than treating them as done."""
import json
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import poolpack


class RetryBlankAiTests(unittest.TestCase):
    def test_manual_translator_retries_a_blank_first_response(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("translate.py", "common.py", "atomic_json.py"):
                shutil.copy2(HERE / name, root / name)
            (root / "llm.py").write_text(
                "calls = 0\n"
                "def call(*args, **kwargs):\n"
                "    global calls\n"
                "    calls += 1\n"
                "    return {'items': [{'id': '0.0', 'tr': '   ' if calls == 1 else 'Devam et.'}]}\n"
                "def spent(): return 0.0\n", encoding="utf-8")
            source = root / "source.jsonl"
            source.write_text(json.dumps({
                "speaker": "", "scene": "", "text": "Keep moving now.",
            }) + "\n", encoding="utf-8")
            dest = root / "translated.json"
            result = subprocess.run([sys.executable, "-B", str(root / "translate.py"),
                                     "ds", str(source), str(dest)],
                                    cwd=root, capture_output=True, text=True,
                                    encoding="utf-8", errors="replace")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("attempt 1 chunks 1", result.stdout, "a missing sentence must be retried")
            self.assertEqual(json.loads(dest.read_text(encoding="utf-8"))[0]["tr"], ["Devam et."])

    def test_pool_translator_retries_a_blank_first_response(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "pool.json"
            counter = {"calls": 0}
            def fake_call(*args, **kwargs):
                counter["calls"] += 1
                value = "  " if counter["calls"] == 1 else "Devam et."
                return {"items": [{"id": "0.0", "tr": value}]}
            fake = types.SimpleNamespace(call=fake_call, spent=lambda: 0.0)
            with patch.dict(sys.modules, {"llm": fake}):
                poolpack.translate([{"speaker": "", "text": "Keep moving now."}],
                                   "Offline system", "test", output)
            self.assertEqual(counter["calls"], 2)
            self.assertEqual(json.loads(output.read_text(encoding="utf-8"))[0]["tr"], ["Devam et."])


if __name__ == "__main__":
    unittest.main()
