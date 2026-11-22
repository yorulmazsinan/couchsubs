#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# iPhone uygulamasının telefondan TV kurulumu için TV paketlerini uygulama paketine (<çıktı>/tv) koyar; Android'deki
# build.gradle samsungTvPackage + tvReleasePackages'ın aynısı:
#  - Samsung (.wgt): kaynaktan (tv-webos + tv-tizen, package-tizen.sh gibi), sıkıştırmasız zip; kurulurken telefonda
#    TV'ye özel sertifikayla imzalanır.
#  - Android TV (.apk) ve LG (.ipk): kaynaktaki TV uygulamasının sürümünü (tv-webos/appinfo.json) taşıyan en yeni GitHub
#    sürümünden, SHA256SUMS.txt ile denetlenerek (masaüstünün kurduğu ve TV'lerde duran kopyayla aynı imza). Öyle bir
#    sürüm yoksa en yenisi alınır. İndirilemezse önceki indirilen (önbellek) kullanılır.
#  - tv-packages.properties: hangi sürümden geldikleri ve sürümleri.
#  - Son olarak paketlerin sürümü kaynakla karşılaştırılır (scripts/check-tv-packages.py). iPhone 1.0.6 (39) LG paketini
#    son sürümden (beta.79, TV 0.9.63) almıştı, main'deki TV 0.9.71'di; telefon TV'yi güncelleyemedi.
# Kullanım: scripts/ios-tv-packages.sh <çıktı klasörü>   (Xcode derleme adımı; COUCHSUBS_REQUIRE_TV_PACKAGES=1 indirmeyi
# ve sürümlerin kaynakla aynı olmasını şart koşar: release-appstore.sh ios bunu verir)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1/tv"
CACHE="${HOME}/Library/Caches/CouchSubs/ios-tv-release"
PY=$(command -v python3 || command -v python)
mkdir -p "$OUT/samsung-ca" "$CACHE"

# Samsung: sıkıştırmasız (telefondaki imzalayıcı yalnız "stored" kayıtları okur).
"$PY" - "$ROOT" "$OUT/couchsubs-samsung.wgt" <<'PYEOF'
import sys, zipfile
root, dst = sys.argv[1], sys.argv[2]
web, tizen = root + '/tv-webos/', root + '/tv-tizen/'
files = [(web + n, n) for n in ['app.js', 'i18n.js', 'config.js', 'style.css', 'largeIcon.png']]
files.append((web + 'icon.png', 'panel-icon.png'))
files += [(tizen + n, n) for n in ['platform.js', 'config.xml', 'icon.png']]
with open(web + 'index.html', encoding='utf-8') as f:
    lines = []
    for line in f.read().split('\n'):
        if line == '  <script src="platform.js"></script>':
            lines.append('  <script src="$WEBAPIS/webapis/webapis.js"></script>')
            lines.append(line)
        else:
            # Görünüm sabit width=1920 kalır (package-tizen.sh, 0.9.55).
            lines.append(line.replace('src="icon.png"', 'src="panel-icon.png"'))
with zipfile.ZipFile(dst, 'w', zipfile.ZIP_STORED) as z:
    for path, name in sorted(files, key=lambda item: item[1]):
        info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
        with open(path, 'rb') as f:
            z.writestr(info, f.read())
    z.writestr(zipfile.ZipInfo('index.html', (1980, 1, 1, 0, 0, 0)), '\n'.join(lines).encode('utf-8'))
PYEOF
cp "$ROOT"/couchsubs-android/app/src/main/resources/samsung-ca/*.pem "$OUT/samsung-ca/"
SAMSUNG_VERSION=$(sed -n 's/.* version="\([0-9.]*\)" viewmodes.*/\1/p' "$ROOT/tv-tizen/config.xml" | head -1)

# Android TV ve LG: kaynaktaki TV sürümünü taşıyan en yeni GitHub sürümü.
WEBOS_VERSION=$(sed -n 's/.*"version": *"\([0-9.]*\)".*/\1/p' "$ROOT/tv-webos/appinfo.json" | head -1)
if "$PY" - "$CACHE" "$WEBOS_VERSION" <<'PYEOF'
import hashlib, json, os, re, sys, tempfile, urllib.request
cache, wanted = sys.argv[1], sys.argv[2]
token = os.environ.get('GITHUB_TOKEN')
def fetch(url, api):
    request = urllib.request.Request(url, headers={'User-Agent': 'couchsubs-ios-build'})
    if api:
        request.add_header('Accept', 'application/vnd.github+json')
        if token: request.add_header('Authorization', 'Bearer ' + token)
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()
releases = [r for r in json.loads(fetch('https://api.github.com/repos/yorulmazsinan/couchsubs/releases?per_page=30', True))
            if not r.get('draft')]
if not releases: raise SystemExit('GitHub sürümü yok')
def carries(r): return any(a['name'] == 'com.couchsubs.tv_' + wanted + '_all.ipk' for a in r['assets'])
release = next((r for r in releases if carries(r)), releases[0])
if not carries(release): print('warning: TV ' + wanted + ' hiçbir GitHub sürümünde yok; ' + release['tag_name'] + ' alınıyor')
sums = next((a for a in release['assets'] if a['name'] == 'SHA256SUMS.txt'), None)
if not sums: raise SystemExit(release['tag_name'] + ': SHA256SUMS.txt yok')
lines = [l.strip() for l in fetch(sums['browser_download_url'], False).decode().splitlines()]
props = ['release=' + release['tag_name']]
names = ['couchsubs-androidtv.apk', 'couchsubs-lg.ipk', 'release.properties']
with tempfile.TemporaryDirectory(prefix='.tv-release-', dir=cache) as staging:
    for pattern, name in [(r'CouchSubs-androidtv\.apk', names[0]), (r'com\.couchsubs\.tv_[0-9.]+_all\.ipk', names[1])]:
        asset = next((a for a in release['assets'] if re.fullmatch(pattern, a['name'])), None)
        if not asset: raise SystemExit(release['tag_name'] + ': ' + pattern + ' yok')
        data = fetch(asset['browser_download_url'], False)
        if hashlib.sha256(data).hexdigest() + '  ' + asset['name'] not in lines: raise SystemExit(asset['name'] + ': SHA-256 tutmuyor')
        with open(os.path.join(staging, name), 'wb') as f: f.write(data)
        props.append(name + '=' + asset['name'])
    with open(os.path.join(staging, names[2]), 'w') as f: f.write('\n'.join(props) + '\n')

    # Do not change the fallback cache until both assets and their metadata have been verified. If a local replace fails,
    # restore the previous complete release before propagating the error to the shell fallback.
    backups, installed = {}, []
    try:
        for name in names:
            target = os.path.join(cache, name)
            if os.path.exists(target):
                backup = os.path.join(staging, '.previous-' + name)
                os.replace(target, backup)
                backups[name] = backup
            os.replace(os.path.join(staging, name), target)
            installed.append(name)
    except Exception:
        for name in reversed(names):
            target = os.path.join(cache, name)
            if name in installed:
                os.unlink(target)
            if name in backups:
                os.replace(backups[name], target)
        raise
print('TV paketleri: ' + release['tag_name'])
PYEOF
then :
else
  if [ -n "$COUCHSUBS_REQUIRE_TV_PACKAGES" ]; then echo "error: TV paketleri indirilemedi"; exit 1; fi
  if [ -f "$CACHE/release.properties" ]; then echo "warning: TV paketleri yenilenemedi, önceki indirilen kullanılıyor"
  else echo "warning: TV paketleri indirilemedi, telefondan Android TV ve LG kurulumu bu derlemede çalışmaz"; fi
fi

{
  echo "couchsubs-samsung.wgt.version=$SAMSUNG_VERSION"
  [ -f "$CACHE/release.properties" ] && cat "$CACHE/release.properties"
  # APK'nın sürümü (versionName) ikili AndroidManifest.xml'den okunur.
  if [ -f "$CACHE/couchsubs-androidtv.apk" ]; then
    APK_VERSION=$("$PY" - "$CACHE/couchsubs-androidtv.apk" <<'PYEOF'
import struct, sys, zipfile
data = zipfile.ZipFile(sys.argv[1]).read('AndroidManifest.xml')
def u16(o): return struct.unpack_from('<H', data, o)[0]
def u32(o): return struct.unpack_from('<I', data, o)[0]
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
                n = data[p]; p += 1
                if n & 0x80: n = ((n & 0x7f) << 8) | data[p]; p += 1
                strings.append(data[p:p + n].decode('utf-8', 'replace'))
            else:
                n = u16(p); p += 2
                if n & 0x8000: n = ((n & 0x7fff) << 16) | u16(p); p += 2
                strings.append(data[p:p + n * 2].decode('utf-16-le', 'replace'))
    elif kind == 0x0180:
        resources = [u32(offset + 8 + i * 4) for i in range((size - 8) // 4)]
    elif kind == 0x0102:
        start, count = u16(offset + 24), u16(offset + 28)
        for i in range(count):
            a = offset + 16 + start + i * 20
            name, raw = u32(a + 4), u32(a + 8)
            if (name < len(resources) and resources[name] == 0x0101021c) or (name < len(strings) and strings[name] == 'versionName'):
                if raw != 0xffffffff: print(strings[raw]); raise SystemExit(0)
                if data[a + 15] == 0x03: print(strings[u32(a + 16)]); raise SystemExit(0)
    offset += size
PYEOF
) || APK_VERSION=""
    [ -n "$APK_VERSION" ] && echo "couchsubs-androidtv.apk.version=$APK_VERSION"
  fi
} > "$OUT/tv-packages.properties"
for name in couchsubs-androidtv.apk couchsubs-lg.ipk; do
  [ -f "$CACHE/$name" ] && cp "$CACHE/$name" "$OUT/$name"
done
echo "TV paketleri uygulamada: $OUT"
cat "$OUT/tv-packages.properties"

# Paketlerin sürümü kaynaktaki TV uygulamasıyla aynı olmalı: eski paket telefondan TV'yi güncelleyemez.
if ! "$PY" "$ROOT/scripts/check-tv-packages.py" "$OUT"; then
  if [ -n "$COUCHSUBS_REQUIRE_TV_PACKAGES" ]; then
    echo "error: TV paketleri kaynaktaki TV uygulamasıyla aynı değil; önce bu TV sürümüyle GitHub sürümünü yayınlayın"
    exit 1
  fi
  echo "warning: TV paketleri kaynaktaki TV uygulamasıyla aynı değil (mağaza derlemesinde derleme durur)"
fi
