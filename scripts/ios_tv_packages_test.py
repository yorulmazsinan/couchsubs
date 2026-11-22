#!/usr/bin/env python3
"""Integration tests for the iOS build's bundled TV release cache."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ios-tv-packages.sh"
SOURCE_WEBOS = json.loads((ROOT / "tv-webos" / "appinfo.json").read_text(encoding="utf-8"))["version"]


def posix_path(path: Path) -> str:
    value = str(path.resolve()).replace("\\", "/")
    if len(value) >= 2 and value[1] == ":":
        return "/" + value[0].lower() + value[2:]
    return value


def bash_executable() -> str:
    if os.name == "nt":
        candidates = [
            Path(r"C:\Program Files\Git\bin\bash.exe"),
            Path(shutil.which("bash") or ""),
        ]
        for candidate in candidates:
            if candidate.is_file() and "\\System32\\" not in str(candidate):
                return str(candidate)
        raise RuntimeError("Git Bash is required to run this integration test on Windows")
    return shutil.which("bash") or "/bin/sh"


class IosTvPackageCacheTests(unittest.TestCase):
    def run_build(self, failure: str | None = None,
                  extra: dict | None = None) -> tuple[Path, Path, subprocess.CompletedProcess[str]]:
        temp_dir = tempfile.TemporaryDirectory(prefix="couchsubs-ios-tv-cache-")
        self.addCleanup(temp_dir.cleanup)
        temp = Path(temp_dir.name)
        home = temp / "home"
        cache = home / "Library" / "Caches" / "CouchSubs" / "ios-tv-release"
        output = temp / "output"
        mock = temp / "python-mock"
        cache.mkdir(parents=True)
        mock.mkdir()
        output.mkdir()

        (cache / "couchsubs-androidtv.apk").write_bytes(b"previous-apk")
        (cache / "couchsubs-lg.ipk").write_bytes(b"previous-ipk")
        (cache / "release.properties").write_text(
            "release=v1.0.0\n"
            "couchsubs-androidtv.apk=CouchSubs-androidtv-v1.apk\n"
            "couchsubs-lg.ipk=com.couchsubs.tv_1.0.0_all.ipk\n",
            encoding="utf-8",
        )

        (mock / "sitecustomize.py").write_text(
            '''import hashlib, io, json, os, urllib.error, urllib.request, zipfile
apk_file = io.BytesIO()
with zipfile.ZipFile(apk_file, "w") as archive:
    archive.writestr("AndroidManifest.xml", b"")
apk = apk_file.getvalue()
ipk = b"new-ipk-v2"
ipk_name = os.environ.get("IOS_TV_IPK", "com.couchsubs.tv_2.0.0_all.ipk")
release = {"tag_name": "v2.0.0", "assets": [
    {"name": "SHA256SUMS.txt", "browser_download_url": "https://fixture/sums"},
    {"name": "CouchSubs-androidtv.apk", "browser_download_url": "https://fixture/android.apk"},
    {"name": ipk_name, "browser_download_url": "https://fixture/lg.ipk"},
]}
# Daha yeni ama TV'si kaynaktan eski bir sürüm listenin başında (TV sürümü yükseltilmeden çıkan beta).
older_tv = {"tag_name": "v2.1.0", "assets": [
    {"name": "SHA256SUMS.txt", "browser_download_url": "https://fixture/sums"},
    {"name": "CouchSubs-androidtv.apk", "browser_download_url": "https://fixture/android.apk"},
    {"name": "com.couchsubs.tv_0.0.1_all.ipk", "browser_download_url": "https://fixture/lg.ipk"},
]}
releases = [older_tv, release] if os.environ.get("IOS_TV_NEWER_OLD_TV") else [release]
sums = (hashlib.sha256(apk).hexdigest() + "  CouchSubs-androidtv.apk\\n" +
        hashlib.sha256(ipk).hexdigest() + "  " + ipk_name + "\\n" +
        hashlib.sha256(ipk).hexdigest() + "  com.couchsubs.tv_0.0.1_all.ipk\\n").encode()
class Response:
    def __init__(self, data): self.data = data
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def read(self): return self.data
def fixture(request, timeout=60):
    url = request.full_url
    if url.endswith("/releases?per_page=30"): return Response(json.dumps(releases).encode())
    if url.endswith("/sums"): return Response(sums)
    if url.endswith("/android.apk"): return Response(apk)
    if url.endswith("/lg.ipk"):
        if os.environ.get("IOS_TV_FAILURE") == "download":
            raise urllib.error.URLError("simulated IPK download failure")
        if os.environ.get("IOS_TV_FAILURE") == "checksum":
            return Response(b"corrupt-ipk")
        return Response(ipk)
    raise AssertionError(url)
urllib.request.urlopen = fixture
''',
            encoding="utf-8",
        )

        env = os.environ.copy()
        env["HOME"] = posix_path(home)
        env["PYTHONPATH"] = posix_path(mock)
        env.pop("COUCHSUBS_REQUIRE_TV_PACKAGES", None)
        for key in ("IOS_TV_IPK", "IOS_TV_NEWER_OLD_TV"):
            env.pop(key, None)
        env.update(extra or {})
        if failure:
            env["IOS_TV_FAILURE"] = failure
        else:
            env.pop("IOS_TV_FAILURE", None)
        result = subprocess.run(
            [bash_executable(), posix_path(SCRIPT), posix_path(output)],
            cwd=str(ROOT),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        return cache, output / "tv", result

    def assert_previous_release(self, cache: Path, output: Path) -> None:
        expected_properties = (
            "release=v1.0.0\n"
            "couchsubs-androidtv.apk=CouchSubs-androidtv-v1.apk\n"
            "couchsubs-lg.ipk=com.couchsubs.tv_1.0.0_all.ipk\n"
        )
        self.assertEqual((cache / "couchsubs-androidtv.apk").read_bytes(), b"previous-apk")
        self.assertEqual((cache / "couchsubs-lg.ipk").read_bytes(), b"previous-ipk")
        self.assertEqual((cache / "release.properties").read_text(encoding="utf-8"), expected_properties)
        self.assertEqual((output / "couchsubs-androidtv.apk").read_bytes(), b"previous-apk")
        self.assertEqual((output / "couchsubs-lg.ipk").read_bytes(), b"previous-ipk")
        output_properties = (output / "tv-packages.properties").read_text(encoding="utf-8")
        self.assertIn(expected_properties, output_properties)

    def test_ipk_download_failure_keeps_previous_release_pair(self) -> None:
        cache, output, result = self.run_build("download")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_previous_release(cache, output)

    def test_ipk_checksum_failure_keeps_previous_release_pair(self) -> None:
        cache, output, result = self.run_build("checksum")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_previous_release(cache, output)

    def test_successful_download_replaces_the_release_pair(self) -> None:
        cache, output, result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual((cache / "couchsubs-androidtv.apk").read_bytes(), b"previous-apk")
        self.assertEqual((cache / "couchsubs-lg.ipk").read_bytes(), b"new-ipk-v2")
        cache_properties = (cache / "release.properties").read_text(encoding="utf-8")
        self.assertIn("release=v2.0.0\n", cache_properties)
        self.assertIn("com.couchsubs.tv_2.0.0_all.ipk", cache_properties)
        self.assertEqual((output / "couchsubs-lg.ipk").read_bytes(), b"new-ipk-v2")

    def test_release_carrying_the_source_tv_version_is_preferred(self) -> None:
        ipk = "com.couchsubs.tv_" + SOURCE_WEBOS + "_all.ipk"
        cache, output, result = self.run_build(extra={"IOS_TV_IPK": ipk, "IOS_TV_NEWER_OLD_TV": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        properties = (output / "tv-packages.properties").read_text(encoding="utf-8")
        self.assertIn("release=v2.0.0\n", properties)
        self.assertIn("couchsubs-lg.ipk=" + ipk, properties)
        self.assertNotIn("LG (.ipk) paketi", result.stdout)

    def test_old_tv_package_stops_a_store_build(self) -> None:
        # Kaynaktaki TV'den eski LG paketi (iPhone 1.0.6 build 39: 0.9.63, main 0.9.71) mağaza derlemesini durdurur.
        cache, output, result = self.run_build(extra={"COUCHSUBS_REQUIRE_TV_PACKAGES": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LG (.ipk) paketi 2.0.0, kaynaktaki TV uygulaması " + SOURCE_WEBOS, result.stdout)

    def test_old_tv_package_only_warns_in_a_development_build(self) -> None:
        cache, output, result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("warning: TV paketleri kaynaktaki TV uygulamasıyla aynı değil", result.stdout)


class CheckTvPackagesTests(unittest.TestCase):
    def setUp(self) -> None:
        import importlib.util
        spec = importlib.util.spec_from_file_location("check_tv_packages", ROOT / "scripts" / "check-tv-packages.py")
        self.check = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.check)
        self.source = self.check.source_versions()
        temp = tempfile.TemporaryDirectory(prefix="couchsubs-tv-check-")
        self.addCleanup(temp.cleanup)
        self.dir = Path(temp.name)

    def test_desktop_folder_with_current_packages_passes(self) -> None:
        (self.dir / ("com.couchsubs.tv_" + self.source["ipk"] + "_all.ipk")).write_bytes(b"x")
        (self.dir / ("couchsubs-samsung_" + self.source["wgt"] + ".wgt")).write_bytes(b"x")
        (self.dir / ("couchsubs-androidtv_" + self.source["apk"] + ".apk")).write_bytes(b"x")
        self.assertEqual(self.check.problems(self.dir), [])

    def test_desktop_folder_with_an_old_ipk_fails(self) -> None:
        (self.dir / "com.couchsubs.tv_0.9.63_all.ipk").write_bytes(b"x")
        (self.dir / ("couchsubs-samsung_" + self.source["wgt"] + ".wgt")).write_bytes(b"x")
        self.assertEqual(self.check.problems(self.dir, allow_missing=("apk",)),
                         ["LG (.ipk) paketi 0.9.63, kaynaktaki TV uygulaması " + self.source["ipk"]])

    def test_missing_package_fails_unless_allowed(self) -> None:
        (self.dir / ("com.couchsubs.tv_" + self.source["ipk"] + "_all.ipk")).write_bytes(b"x")
        (self.dir / ("couchsubs-samsung_" + self.source["wgt"] + ".wgt")).write_bytes(b"x")
        self.assertEqual(len(self.check.problems(self.dir)), 1)
        self.assertEqual(self.check.problems(self.dir, allow_missing=("apk",)), [])

    def test_iphone_bundle_properties_are_read(self) -> None:
        for name in ("couchsubs-lg.ipk", "couchsubs-samsung.wgt", "couchsubs-androidtv.apk"):
            (self.dir / name).write_bytes(b"x")
        (self.dir / "tv-packages.properties").write_text(
            "couchsubs-samsung.wgt.version=" + self.source["wgt"] + "\n"
            "release=v0.1.0-beta.79\n"
            "couchsubs-lg.ipk=com.couchsubs.tv_0.9.63_all.ipk\n"
            "couchsubs-androidtv.apk.version=0.9.63\n", encoding="utf-8")
        self.assertEqual(self.check.problems(self.dir), [
            "LG (.ipk) paketi 0.9.63, kaynaktaki TV uygulaması " + self.source["ipk"],
            "Android TV (.apk) paketi 0.9.63, kaynaktaki TV uygulaması " + self.source["apk"],
        ])


if __name__ == "__main__":
    unittest.main()
