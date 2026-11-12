# Build a format-2 pack from reviewed lines. Usage: build.py <reviewed.json> <out.json.gz> <id> <title> <source>
import json, re, sys
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import common as c

src, out, pack_id, title, source = sys.argv[1:6]
# Var olan paketlerin anahtarları (canon noktalamayı attığı için "Dead?" ile "Dead." aynı anahtar): yeni paket bunları
# tam satır olarak değil parça olarak taşır, böylece birleşik sözlükte eski paketlerin tam satırı yerinde kalır.
import gzip, os
taken = set()
for d in sys.argv[6:]:
    for f in os.listdir(d):
        if f.endswith(".json.gz") and not f.startswith(pack_id + "."):
            p = json.load(gzip.open(os.path.join(d, f)))
            taken.update(k.lower() for k in p.get("entries", {}))
lines = json.load(open(src, encoding="utf-8"))
entries, segments, english = {}, {}, {}


def put(table, en, tr):
    k = c.key(en)
    if not k or not tr:
        return
    table[k] = tr
    english.setdefault(k, en)


for l in lines:
    if not all(l["tr"]) or not l["sents"]:
        continue
    whole = " ".join(t.strip() for t in l["tr"])
    # Türkçesi İngilizcesiyle aynı satırlar (adlar, ünlemler) parça olarak girer, tam satır olarak değil.
    if c.canon(whole) == c.canon(l["text"]):
        put(segments, l["text"], whole)
    else:
        put(entries, l["text"], whole)
    if len(l["sents"]) > 1:
        for en, tr in zip(l["sents"], l["tr"]):
            put(segments, en, tr.strip())
    # Havuzdan gelen satır: oyuncunun ekranda okuduğu bozuk hâl de aynı Türkçeye çıkar (imzası yok).
    if l.get("raw"):
        rk = c.key(l["raw"])
        if rk and rk not in entries:
            segments.setdefault(rk, whole)

for k in list(entries):
    if k in taken:
        segments[k] = entries.pop(k)
for k in list(segments):
    if k in entries:
        del segments[k]
print("demoted (taken by older packs)", sum(1 for k in segments if k in taken))
c.write_pack(out, pack_id, title, source, entries, segments, english)
print(pack_id, "entries", len(entries), "segments", len(segments), "signed", sum(1 for k in english if c.signature(english[k])))
