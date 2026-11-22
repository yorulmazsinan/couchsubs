#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Uygulamayla gelen oyun paketlerini özel R2 kovasından (couchsubs-packs, S3 uyumlu) derleme klasörüne indirir.

Paket dosyaları depoda değildir (yalnız uygulama içinden dağıtılır). Derleme hattı ve yerel yayın derlemesi bunu çağırır:

  python3 scripts/fetch-packs.py              # bundled/*.json.gz → core/Sources/CouchSubsCore/Resources/packs/
  python3 scripts/fetch-packs.py --contrib    # ayrıca contrib/* → tools/packs/katki/ (topluluk katkı havuzu)
  python3 scripts/fetch-packs.py --require    # erişim yoksa ya da hiç paket inmezse çıkış 1 (yayın derlemesi)

Erişim: ortamdaki PACKS_R2_ACCESS_KEY_ID, PACKS_R2_SECRET_ACCESS_KEY, PACKS_R2_ENDPOINT (CI: GitHub sırları), yoksa
~/.config/couchsubs/packs.env (aynı adlar, KEY=değer; chmod 600, depoya girmez). Kova adı PACKS_R2_BUCKET (varsayılan
couchsubs-packs). Erişim yoksa (dış katkıcı, yerel geliştirici) uyarı verip çıkış 0: uygulama paketsiz derlenir, gerçek
paketlere dayanan testler kendini atlar. Yalnız standart kitaplık (SigV4 imzası elle); değerler hiçbir yere yazılmaz.
"""

import datetime
import hashlib
import hmac
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGETS = {
    "bundled/": ROOT / "core/Sources/CouchSubsCore/Resources/packs",
    "contrib/": ROOT / "tools/packs/katki",
}
KEYS = ("PACKS_R2_ACCESS_KEY_ID", "PACKS_R2_SECRET_ACCESS_KEY", "PACKS_R2_ENDPOINT")


def config():
    values = {key: os.environ.get(key, "").strip() for key in KEYS + ("PACKS_R2_BUCKET",)}
    env_file = Path(os.environ.get("PACKS_ENV", Path.home() / ".config/couchsubs/packs.env"))
    if not all(values[key] for key in KEYS) and env_file.is_file():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.removeprefix("export ").strip()
            if key in values and not values[key]:
                values[key] = value.strip().strip("'\"")
    values["PACKS_R2_BUCKET"] = values["PACKS_R2_BUCKET"] or "couchsubs-packs"
    return values


def _hmac(key, text):
    return hmac.new(key, text.encode(), hashlib.sha256).digest()


def request(cfg, key="", query=None):
    """İmzalı (AWS SigV4, bölge auto) GET; gövdeyi döner."""
    endpoint = urllib.parse.urlparse(cfg["PACKS_R2_ENDPOINT"].rstrip("/"))
    host = endpoint.netloc
    path = ("/" + cfg["PACKS_R2_BUCKET"] if cfg["PACKS_R2_BUCKET"] else "") + ("/" + urllib.parse.quote(key, safe="/-_.~") if key else "")
    path = path or "/"
    query = query or {}
    canonical_query = "&".join(f"{urllib.parse.quote(k, safe='-_.~')}={urllib.parse.quote(v, safe='-_.~')}"
                               for k, v in sorted(query.items()))
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    payload = hashlib.sha256(b"").hexdigest()
    headers = {"host": host, "x-amz-content-sha256": payload, "x-amz-date": amz_date}
    signed = ";".join(sorted(headers))
    canonical = "\n".join(["GET", path, canonical_query, "".join(f"{k}:{headers[k]}\n" for k in sorted(headers)), signed, payload])
    region = cfg.get("PACKS_R2_REGION") or "auto"
    scope = f"{day}/{region}/s3/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    signing = _hmac(_hmac(_hmac(_hmac(("AWS4" + cfg["PACKS_R2_SECRET_ACCESS_KEY"]).encode(), day), region), "s3"), "aws4_request")
    signature = hmac.new(signing, to_sign.encode(), hashlib.sha256).hexdigest()
    auth = f"AWS4-HMAC-SHA256 Credential={cfg['PACKS_R2_ACCESS_KEY_ID']}/{scope}, SignedHeaders={signed}, Signature={signature}"
    url = f"{endpoint.scheme}://{host}{path}" + (f"?{canonical_query}" if canonical_query else "")
    req = urllib.request.Request(url, headers={**{k: v for k, v in headers.items() if k != "host"}, "Authorization": auth})
    with urllib.request.urlopen(req, timeout=120) as response:
        return response.read()


def list_keys(cfg, prefix):
    ns = "{http://s3.amazonaws.com/doc/2006-03-01/}"
    keys, token = [], None
    while True:
        query = {"list-type": "2", "prefix": prefix}
        if token:
            query["continuation-token"] = token
        tree = ET.fromstring(request(cfg, query=query))
        keys += [(item.findtext(f"{ns}Key"), int(item.findtext(f"{ns}Size") or 0)) for item in tree.iter(f"{ns}Contents")]
        if tree.findtext(f"{ns}IsTruncated") != "true":
            return keys
        token = tree.findtext(f"{ns}NextContinuationToken")


def main(argv):
    require = "--require" in argv
    prefixes = ["bundled/"] + (["contrib/"] if "--contrib" in argv else [])
    cfg = config()
    if not all(cfg[key] for key in KEYS):
        message = "paket kovasına erişim yok (PACKS_R2_* ya da ~/.config/couchsubs/packs.env); paketler indirilmedi"
        print(("✗ " if require else "! ") + message, file=sys.stderr)
        return 1 if require else 0
    total = 0
    for prefix in prefixes:
        target = TARGETS[prefix]
        target.mkdir(parents=True, exist_ok=True)
        try:
            keys = list_keys(cfg, prefix)
        except (urllib.error.URLError, ET.ParseError) as error:
            print(f"✗ {prefix} listelenemedi: {getattr(error, 'code', '') or error.__class__.__name__}", file=sys.stderr)
            return 1
        for key, _size in keys:
            name = key[len(prefix):]
            if not name or "/" in name or name.startswith("."):
                continue
            dest = target / name
            try:
                data = request(cfg, key)
            except urllib.error.URLError as error:
                print(f"✗ {key} indirilemedi: {getattr(error, 'code', '') or error.__class__.__name__}", file=sys.stderr)
                return 1
            temporary = dest.with_name("." + name + ".download")
            temporary.write_bytes(data)
            temporary.replace(dest)
            total += 1
        print(f"✓ {prefix} → {target.relative_to(ROOT)} ({len(keys)} dosya)")
    if require and total == 0:
        print("✗ hiç paket inmedi", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
