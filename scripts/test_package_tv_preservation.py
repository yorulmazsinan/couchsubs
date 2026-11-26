# SPDX-License-Identifier: AGPL-3.0-only
"""An LG TV rebuild must not erase installers for other TV platforms."""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("package-tv.sh")
NORMALIZER = Path(__file__).with_name("normalize-ipk.py")
sys.path.insert(0, str(Path(__file__).parent))
from test_normalize_ipk import build_ipk, load_normalizer  # noqa: E402

NEW_IPK = build_ipk("0.9.75", mtime=4102444800)


def bash_executable():
    if os.name == "nt":
        p = Path(r"C:\Program Files\Git\bin\bash.exe")
        if p.is_file():
            return str(p)
    return shutil.which("bash") or "/bin/sh"


def posix(path):
    value = str(path.resolve()).replace("\\", "/")
    return "/" + value[0].lower() + value[2:] if len(value) > 1 and value[1] == ":" else value


class PackageTvTests(unittest.TestCase):
    def package(self, fail=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "repo"
            (root / "scripts").mkdir(parents=True)
            (root / "tv-webos").mkdir()
            shutil.copy2(SCRIPT, root / "scripts/package-tv.sh")
            shutil.copy2(NORMALIZER, root / "scripts/normalize-ipk.py")
            out = root / "dist/tv-app"
            out.mkdir(parents=True)
            (out / "couchsubs-samsung_0.9.75.wgt").write_bytes(b"samsung WGT")
            (out / "couchsubs-androidtv_0.9.75.apk").write_bytes(b"android APK")
            old = out / "com.couchsubs.tv_0.9.75_all.ipk"
            old.write_bytes(b"last working LG installer")
            fake = Path(tmp) / "bin"
            fake.mkdir()
            (fake / "new.ipk").write_bytes(NEW_IPK)
            cmd = fake / "ares-package"
            cmd.write_text('#!/bin/sh\n' + (
                'exit 33\n' if fail else
                'mkdir -p "$3"\ncp "$(dirname "$0")/new.ipk" "$3/com.couchsubs.tv_0.9.75_all.ipk"\n'
            ), encoding="utf-8")
            cmd.chmod(0o755)
            env = {**os.environ, "PATH": posix(fake) + ":/usr/bin:/bin"}
            result = subprocess.run([bash_executable(), posix(root / "scripts/package-tv.sh")],
                                    cwd=root, env=env, capture_output=True, text=True, errors="replace")
            return result, {p.name: p.read_bytes() for p in out.iterdir() if p.is_file()}

    def test_success_preserves_samsung_and_android_installers(self):
        proc, files = self.package()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(files["couchsubs-samsung_0.9.75.wgt"], b"samsung WGT")
        self.assertEqual(files["couchsubs-androidtv_0.9.75.apk"], b"android APK")
        # Yeni paket zaman damgaları geçmişe çekilmiş olarak gelir (normalize-ipk.py).
        self.assertEqual(files["com.couchsubs.tv_0.9.75_all.ipk"], load_normalizer().normalize(NEW_IPK))

    def test_failed_lg_packager_preserves_previous_installers(self):
        proc, files = self.package(fail=True)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(files["com.couchsubs.tv_0.9.75_all.ipk"], b"last working LG installer")
        self.assertEqual(files["couchsubs-samsung_0.9.75.wgt"], b"samsung WGT")
        self.assertEqual(files["couchsubs-androidtv_0.9.75.apk"], b"android APK")


if __name__ == "__main__":
    unittest.main()
