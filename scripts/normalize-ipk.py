#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""LG paketinin (.ipk) tüm zaman damgalarını geçmişte sabit bir ana çeker.

webOS'un kurulum servisi (com.webos.appInstallService) paketi doğrularken control.tar.gz ve data.tar.gz'yi GNU tar
1.17 ile açar ve tar'ın her uyarısını hata sayar: "ipk verified failed" (errorCode -5). ares-package dosyaların
derlendiği anı yazar; saati geride kalmış bir TV'de (LG OLED CX/webOS 5'te ağ saati alınamayınca saat 2020-01-01'e
döner) tar "time stamp ... in the future" der ve kurulum -5 ile reddedilir. 1970 damgası da reddedilir ("implausibly
old time stamp"). Bu yüzden her damga 2010'a çekilir; sürüm başına birkaç gün kayar ki sürümler ayrı damga taşısın.

Paket bayt düzeyinde düzeltilir (ar başlıkları, ustar başlıkları ve sağlamaları, gzip başlığı); başka hiçbir alan
değişmez. Kullanım: scripts/normalize-ipk.py <paket.ipk>
"""
import gzip
import re
import sys

BASE = 1262304000  # 2010-01-01T00:00:00Z
AR_MAGIC = b"!<arch>\n"


def stamp(version):
    """0.9.113 → 2010-01-01 + 9113 dakika. Sayı okunamazsa taban."""
    parts = [int(p) for p in re.findall(r"\d+", version or "")[:3]]
    parts += [0] * (3 - len(parts))
    return BASE + (parts[0] * 100_000 + parts[1] * 1_000 + parts[2]) * 60


def read_ar(data):
    if not data.startswith(AR_MAGIC):
        raise ValueError("ar arşivi değil")
    members, offset = [], len(AR_MAGIC)
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) < 60 or header[58:60] != b"`\n":
            raise ValueError("bozuk ar başlığı")
        size = int(header[48:58].strip())
        body = data[offset + 60:offset + 60 + size]
        if len(body) != size:
            raise ValueError("ar üyesi eksik")
        members.append((header, body))
        offset += 60 + size + (size & 1)
    return members


def write_ar(members, mtime):
    out = bytearray(AR_MAGIC)
    for header, body in members:
        header = bytearray(header)
        header[16:28] = str(mtime).encode().ljust(12)
        header[48:58] = str(len(body)).encode().ljust(10)
        out += header + body
        if len(body) & 1:
            out += b"\n"
    return bytes(out)


def fix_tar(raw, mtime):
    """Her ustar başlığının mtime alanını yazar ve sağlamasını yeniler."""
    raw = bytearray(raw)
    offset = 0
    while offset + 512 <= len(raw):
        header = raw[offset:offset + 512]
        if header == bytes(512):
            break
        if header[257:262] != b"ustar":
            raise ValueError("ustar başlığı değil")
        size_field = bytes(header[124:136]).strip(b"\0 ")
        size = int(size_field or b"0", 8)
        header[136:148] = b"%011o\0" % mtime
        header[148:156] = b" " * 8
        header[148:156] = b"%06o\0 " % sum(header)
        raw[offset:offset + 512] = header
        offset += 512 + (size + 511) // 512 * 512
    return bytes(raw)


def control_version(control_gz):
    raw = gzip.decompress(control_gz)
    found = re.search(rb"^Version:\s*(\S+)", raw, re.M)
    return found.group(1).decode() if found else None


def normalize(data):
    members = read_ar(data)
    control = next((body for header, body in members if header[:16].strip().rstrip(b"/") == b"control.tar.gz"), None)
    if control is None:
        raise ValueError("control.tar.gz yok")
    mtime = stamp(control_version(control))
    fixed = []
    for header, body in members:
        name = header[:16].strip().rstrip(b"/")
        if name.endswith(b".tar.gz"):
            body = gzip.compress(fix_tar(gzip.decompress(body), mtime), compresslevel=9, mtime=mtime)
        fixed.append((header, body))
    return write_ar(fixed, mtime)


def main(argv):
    if len(argv) != 2:
        print("Kullanım: normalize-ipk.py <paket.ipk>", file=sys.stderr)
        return 2
    with open(argv[1], "rb") as f:
        data = f.read()
    result = normalize(data)
    with open(argv[1], "wb") as f:
        f.write(result)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
