# SPDX-License-Identifier: AGPL-3.0-only
"""A model response for one translation chunk must not rewrite earlier chunks."""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).with_name("translate.py")
COMMON = SOURCE.with_name("common.py")


class TranslationChunkTests(unittest.TestCase):
    def test_out_of_chunk_llm_id_cannot_overwrite_previous_subtitle(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shutil.copy2(SOURCE, root / "translate.py")
            shutil.copy2(COMMON, root / "common.py")
            shutil.copy2(SOURCE.with_name("atomic_json.py"), root / "atomic_json.py")
            (root / "llm.py").write_text(
                'import re\n'
                'def call(system, prompt, schema, tag, max_tokens):\n'
                '    ids = re.findall(r"(?m)^  (\\d+\\.\\d+)\\t", prompt)\n'
                '    items = [{"id": i, "tr": "Correct " + i} for i in ids]\n'
                '    if "40.0" in ids:\n'
                '        items.append({"id": "0.0", "tr": "WRONG SECOND CHUNK"})\n'
                '    return {"items": items}\n'
                'def spent(): return 0.0\n',
                encoding="utf-8")
            rows = root / "source.jsonl"
            rows.write_text("".join(json.dumps({"speaker": "", "scene": "test",
                "text": f"Different character number {i} is speaking now."}) + "\n"
                for i in range(41)), encoding="utf-8")
            output = root / "translations.json"
            proc = subprocess.run([sys.executable, "-B", str(root / "translate.py"),
                                   "ds", str(rows), str(output)], cwd=root,
                                  capture_output=True, text=True, encoding="utf-8")
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            result = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(len(result), 41)
            self.assertEqual(result[0]["tr"], ["Correct 0.0"],
                             "a cross-chunk hallucinated ID must not replace another subtitle")
            self.assertEqual(result[40]["tr"], ["Correct 40.0"])


if __name__ == "__main__":
    unittest.main()
