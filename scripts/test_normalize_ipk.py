# SPDX-License-Identifier: AGPL-3.0-only
"""normalize-ipk.py: LG paketinin zaman damgaları geçmişte, içerik birebir aynı (saati geride TV'de -5 olmasın)."""
import gzip
import importlib.util
import io
import tarfile
import unittest
from pathlib import Path

NORMALIZER = Path(__file__).with_name("normalize-ipk.py")
TV_CLOCK_RESET = 1577836800  # 2020-01-01: ağ saati alınamayan LG CX'in döndüğü tarih


def load_normalizer():
    spec = importlib.util.spec_from_file_location("normalize_ipk", NORMALIZER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def targz(files, mtime):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for name, data in files:
            info = tarfile.TarInfo(name)
            info.mtime = mtime
            if data is None:
                info.type = tarfile.DIRTYPE
                info.mode = 0o777
                tar.addfile(info)
            else:
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
    return gzip.compress(buffer.getvalue(), mtime=0)


def ar(members, mtime):
    out = bytearray(b"!<arch>\n")
    for name, body in members:
        out += (name.ljust(16) + str(mtime).ljust(12) + "0".ljust(6) + "0".ljust(6) + "100644".ljust(8)
                + str(len(body)).ljust(10) + "`\n").encode()
        out += body + (b"\n" if len(body) & 1 else b"")
    return bytes(out)


def build_ipk(version, mtime):
    """ares-package'in çıktısı gibi: debian-binary, control.tar.gz, data.tar.gz (ustar), derlendiği anın damgası."""
    control = targz([("control", f"Package: com.couchsubs.tv\nVersion: {version}\nArchitecture: all\n".encode())], mtime)
    data = targz([("usr/", None), ("usr/palm/applications/com.couchsubs.tv/", None),
                  ("usr/palm/applications/com.couchsubs.tv/app.js", b"console.log(1)\n" * 50),
                  ("usr/palm/applications/com.couchsubs.tv/fonts/OFL.txt", b"x")], mtime)
    return ar([("debian-binary", b"2.0\n"), ("control.tar.gz", control), ("data.tar.gz", data)], mtime)


def members(ipk):
    normalizer = load_normalizer()
    return {header[:16].strip().decode(): (int(header[16:28]), body) for header, body in normalizer.read_ar(ipk)}


class NormalizeIpkTests(unittest.TestCase):
    def setUp(self):
        self.normalizer = load_normalizer()
        # Paket TV'nin saatinden "ileride" derlenmiş (gerçek derleme anı, saati geride TV).
        self.original = build_ipk("0.9.110", mtime=1795660080)

    def test_all_timestamps_move_before_the_reset_tv_clock(self):
        fixed = self.normalizer.normalize(self.original)
        expected = self.normalizer.stamp("0.9.110")
        self.assertLess(expected, TV_CLOCK_RESET)
        self.assertGreater(expected, 0)  # 1970 damgası da tar'da "implausibly old" uyarısıdır
        for name, (mtime, body) in members(fixed).items():
            self.assertEqual(mtime, expected, name)
            if name.endswith(".tar.gz"):
                self.assertEqual(int.from_bytes(body[4:8], "little"), expected)
                # tarfile sağlamayı denetler; bozuk sağlama burada hata verir.
                with tarfile.open(fileobj=io.BytesIO(gzip.decompress(body))) as tar:
                    for info in tar.getmembers():
                        self.assertEqual(info.mtime, expected, info.name)

    def test_contents_and_order_are_unchanged(self):
        fixed = self.normalizer.normalize(self.original)
        before, after = members(self.original), members(fixed)
        self.assertEqual(list(before), list(after))
        self.assertEqual(before["debian-binary"][1], after["debian-binary"][1])
        for name in ("control.tar.gz", "data.tar.gz"):
            with tarfile.open(fileobj=io.BytesIO(gzip.decompress(before[name][1]))) as a, \
                 tarfile.open(fileobj=io.BytesIO(gzip.decompress(after[name][1]))) as b:
                self.assertEqual([(i.name, i.type, i.mode, i.size) for i in a], [(i.name, i.type, i.mode, i.size) for i in b])
                for info in a:
                    if info.isfile():
                        self.assertEqual(a.extractfile(info).read(), b.extractfile(info.name).read())

    def test_is_idempotent_and_deterministic(self):
        once = self.normalizer.normalize(self.original)
        self.assertEqual(once, self.normalizer.normalize(once))
        self.assertEqual(once, self.normalizer.normalize(build_ipk("0.9.110", mtime=1795669999)))

    def test_newer_versions_get_later_stamps(self):
        stamp = self.normalizer.stamp
        self.assertLess(stamp("0.9.99"), stamp("0.9.110"))
        self.assertLess(stamp("0.9.999"), stamp("1.0.0"))
        self.assertLess(stamp("9.9.999"), TV_CLOCK_RESET)

    def test_rejects_non_ipk(self):
        with self.assertRaises(ValueError):
            self.normalizer.normalize(b"new LG installer")


if __name__ == "__main__":
    unittest.main()
