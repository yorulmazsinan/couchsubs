# SPDX-License-Identifier: AGPL-3.0-only
"""Android TV uygulamasını (APK) GitHub sürümünden indirir; Linux imajına gömülür (#617).

APK sürüm anahtarıyla imzalıdır, imaj içinde derlenemez: masaüstü uygulamalarına gömülen ve TV'lerde duran kopyanın
aynısı, SHA256SUMS.txt ile denetlenerek alınır (scripts/ios-tv-packages.sh gibi). Sürümü (versionName) APK'nın ikili
AndroidManifest.xml'inden okunur ve dosya adına yazılır: <çıktı>/couchsubs-androidtv_<sürüm>.apk (sunucu sürümü
dosya adından okur, TvInstall.Versions.OfBundledFile).

Kullanım: fetch-androidtv-apk.py <çıktı klasörü> [sürüm etiketi | latest | none]
"""
import hashlib
import json
import os
import re
import struct
import sys
import urllib.request
import zipfile

REPO = 'yorulmazsinan/couchsubs'


def fetch(url, api=False):
    request = urllib.request.Request(url, headers={'User-Agent': 'couchsubs-linux-build'})
    if api:
        request.add_header('Accept', 'application/vnd.github+json')
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def version_name(apk):
    """İkili AndroidManifest.xml'deki android:versionName."""
    data = zipfile.ZipFile(apk).read('AndroidManifest.xml')

    def u16(o):
        return struct.unpack_from('<H', data, o)[0]

    def u32(o):
        return struct.unpack_from('<I', data, o)[0]

    strings, resources, offset = [], [], 8
    while offset < len(data):
        kind, header, size = u16(offset), u16(offset + 2), u32(offset + 4)
        if kind == 0x0001:
            count, flags, start = u32(offset + 8), u32(offset + 16), u32(offset + 20)
            utf8 = flags & 0x100
            for i in range(count):
                p = offset + start + u32(offset + header + i * 4)
                if utf8:
                    p += 2 if data[p] & 0x80 else 1
                    n = data[p]
                    p += 1
                    if n & 0x80:
                        n = ((n & 0x7f) << 8) | data[p]
                        p += 1
                    strings.append(data[p:p + n].decode('utf-8', 'replace'))
                else:
                    n = u16(p)
                    p += 2
                    if n & 0x8000:
                        n = ((n & 0x7fff) << 16) | u16(p)
                        p += 2
                    strings.append(data[p:p + n * 2].decode('utf-16-le', 'replace'))
        elif kind == 0x0180:
            resources = [u32(offset + 8 + i * 4) for i in range((size - 8) // 4)]
        elif kind == 0x0102:
            start, count = u16(offset + 24), u16(offset + 28)
            for i in range(count):
                a = offset + 16 + start + i * 20
                name, raw = u32(a + 4), u32(a + 8)
                if (name < len(resources) and resources[name] == 0x0101021c) or (name < len(strings) and strings[name] == 'versionName'):
                    if raw != 0xffffffff:
                        return strings[raw]
                    if data[a + 15] == 0x03:
                        return strings[u32(a + 16)]
        if size == 0:
            break
        offset += size
    return None


def main():
    out = sys.argv[1]
    tag = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else 'latest'
    os.makedirs(out, exist_ok=True)
    if tag == 'none':
        print('Android TV APK istenmedi (COUCHSUBS_TV_RELEASE=none)')
        return
    path = 'releases/latest' if tag == 'latest' else 'releases/tags/' + tag
    release = json.loads(fetch(f'https://api.github.com/repos/{REPO}/{path}', api=True))
    assets = {asset['name']: asset['browser_download_url'] for asset in release['assets']}
    if 'SHA256SUMS.txt' not in assets or 'CouchSubs-androidtv.apk' not in assets:
        raise SystemExit(release['tag_name'] + ': CouchSubs-androidtv.apk ya da SHA256SUMS.txt yok')
    sums = [line.strip() for line in fetch(assets['SHA256SUMS.txt']).decode().splitlines()]
    data = fetch(assets['CouchSubs-androidtv.apk'])
    if hashlib.sha256(data).hexdigest() + '  CouchSubs-androidtv.apk' not in sums:
        raise SystemExit('CouchSubs-androidtv.apk: SHA-256 tutmuyor')
    staging = os.path.join(out, '.androidtv.apk')
    with open(staging, 'wb') as f:
        f.write(data)
    version = version_name(staging)
    if not version or not re.fullmatch(r'[0-9]+(\.[0-9]+)*', version):
        os.unlink(staging)
        raise SystemExit('APK sürümü okunamadı')
    target = os.path.join(out, f'couchsubs-androidtv_{version}.apk')
    os.replace(staging, target)
    print(f'Android TV APK: {release["tag_name"]} → {target}')


if __name__ == '__main__':
    main()
