# SPDX-License-Identifier: AGPL-3.0-only
"""Yayınlanmış biçim 2 paketlerden yazı tanıma kaynaklı bozuk satırları siler (API yok, tekrar çalıştırılabilir).

Havuzdan gelen satırlar oyuncuların ekranda okuduğu hâliyle çevrilir; iki konuşmacının alt alta okunduğu ya da aynı
altyazının iki kez okunduğu satırlar pakete tek satır olarak girer. Bu satırların asıl parçaları pakette zaten ayrı ayrı
vardır; birleşik satır ise yarım okumaya uzun, yanlış bir Türkçe getirir ("Jason: been friends ever since." →
"…Boobie: Ah, ben de onunla futbol sahasında tanıştım."). Betik yalnız şu satırları siler, hiçbir çeviriyi değiştirmez
(küfür, ton, yazım olduğu gibi kalır):

  konusmaci-birlesik   Türkçesinin ortasında başka bir konuşmacı etiketi var ("… Boobie: …") ve her parça pakette ayrı
                       bir satırın Türkçesi olarak (ya da cümle cümle) zaten var.
  tekrar               Türkçesi aynı birimin (en az beş sözcük) art arda tekrarı ("A. B. A. B.") ya da en az beş
                       sözcüklü bir cümlesi iki kez geçiyor ve bütün cümleleri pakette ayrı satır olarak var.
  buyuk-harf-copu      Türkçede çevrilmemiş büyük harfli İngilizce çöp kalmış ("Auto GREAT.") ve çöp atılınca kalan
                       Türkçe pakette ayrı bir satır olarak zaten var.
  havuz-dokumde-var    Havuz paketindeki (pool-*) anahtar ana pakette de var: oyun metni dökümünden gelen satır
                       öncelikli (uygulamalar sonra okunan paketi kazandırır; havuz paketi alfabede sonra gelir).

Konuşmacı etiketi sayılan adlar paketin kendisinden çıkarılır: en az LABEL_MIN satırın başında "Ad:" olarak geçen adlar
("Jason", "Yabancı", "Polis"); "Teşhis: hasta…" gibi sıradan iki nokta etiket sayılmaz.

Kullanım:
  python3 tools/packs/packclean.py <çıkış klasörü> <paket.json.gz>... [--report silinenler.jsonl] [--dry-run]
Paketler birlikte verilir (ör. gta-6 ve pool-gta-6): "pakette zaten var" denetimi hepsinin satırlarına bakar.
Çıktı aynı dosya adlarıyla çıkış klasörüne yazılır; bulanık imzalar silinen anahtarlar çıkarılarak korunur.
"""

import argparse
import base64
import collections
import gzip
import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as c  # noqa: E402

LABEL_MIN = 5
REPEAT_WORDS = 5
UPPER = "A-ZÇĞİÖŞÜ"
WORD = rf"[{UPPER}][\wÇĞİÖŞÜçğıöşü'’.&\-]*"
# Satır başında ya da cümle sonundan sonra en çok üç sözcüklü "Ad:" etiketi.
LABEL = re.compile(rf"(?:^|(?<=[.!?…\"'”)\]]))\s*({WORD}(?:\s{WORD}){{0,2}}):\s")
# Satırın başında ya da sonunda kalan, noktalamasız, en az dört harfli, yalnız büyük İngilizce harfli sözcük ("LOESERT",
# "TERLA"). Uzatılmış bağırış ("KOOOOY", "TAAVAAAANG") ve noktalamalı sözcük ("CAMPION!", "VANTUZ?") çöp sayılmaz.
CAPS_TOKEN = re.compile(r"^(?!.*(.)\1\1)([A-Z]{4,})$")
CAPS_RARE = 2
TURKISH_FOLD = str.maketrans("ıİşŞğĞüÜöÖçÇ", "iisSgGuUoOcC")


def norm(text):
    """Karşılaştırma biçimi: küçük harf, harf ve rakam dışı her şey atılır, uzatılan harf teke iner ("Ahh" = "Ah")."""
    return re.sub(r"(.)\1+", r"\1", re.sub(r"[\W_]+", "", text.lower()))


def words(text):
    return [w for w in text.split() if re.search(r"\w", w)]


class Index:
    """Paketlerdeki bütün Türkçe satırlar: bir parçanın pakette ayrı satır (ya da başka bir satırın cümlesi) olarak var
    olup olmadığını söyler. Aynı Türkçe birkaç anahtarda olabilir (birleşik satırın kopyası): sayımlar farklı Türkçe
    metinler üzerindendir, yoksa birleşik satırın kopyası kendi parçalarına kanıt olurdu."""

    def __init__(self, packs):
        self.values = collections.Counter()
        self.sentences = collections.Counter()
        starts = collections.Counter()
        vocabulary = collections.Counter()
        caps = collections.Counter()
        distinct = {value for pack in packs for value in rows(pack)}
        for value in distinct:
            self.values[norm(value)] += 1
            for sentence in set(sentence_keys(value)):
                self.sentences[sentence] += 1
        for pack in packs:
            for value in rows(pack):
                for token in value.split():
                    if CAPS_TOKEN.match(token):
                        caps[token] += 1
                m = LABEL.match(value)
                if m:
                    starts[m.group(1)] += 1
                for word in value.split():
                    if any(ch.islower() for ch in word):
                        vocabulary[norm(word).translate(TURKISH_FOLD).lower()] += 1
        self.labels = {name for name, count in starts.items() if count >= LABEL_MIN}
        self.vocabulary = vocabulary
        self.caps = caps

    def known(self, text, own):
        """Metin (ya da etiketsiz gövdesi) pakette ayrı bir satırın Türkçesi mi; değilse bütün cümleleri başka
        satırlarda (tek başına ya da başka bir satırın cümlesi olarak) var mı. `own`: incelenen satırın Türkçesi."""
        own_key = norm(own)
        for candidate in (text, strip_label(text)):
            n = norm(candidate)
            if n and self.values[n] - (1 if n == own_key else 0) > 0:
                return True
        own_sentences = set(sentence_keys(own))
        keys = sentence_keys(strip_label(text))
        return bool(keys) and all(self.values[k] - (1 if k == own_key else 0) > 0
                                  or self.sentences[k] - (1 if k in own_sentences else 0) > 0 for k in keys)


def sentence_keys(text):
    return [norm(s) for s in c.sentences(text.strip()) if len(norm(s)) >= 3]


def strip_label(text):
    m = LABEL.match(text)
    return text[m.end():].strip() if m else text.strip()


def rows(pack):
    yield from pack.get("entries", {}).values()
    yield from pack.get("segments", {}).values()


def speaker_pieces(value, labels):
    """Ortasında bilinen konuşmacı etiketi olan satırın parçaları; yoksa None."""
    cuts = [m.start() for m in LABEL.finditer(value) if m.start() > 0 and m.group(1) in labels]
    if not cuts:
        return None
    pieces, start = [], 0
    for cut in cuts + [len(value)]:
        piece = value[start:cut].strip()
        if piece:
            pieces.append(piece)
        start = cut
    # Yalnız ses notu olan parça ("[köpek havlar] Dr. Bill: …") ayrı konuşma değil, altyazının kendi parçası olabilir.
    if any(re.fullmatch(r"[\[(][^\])]*[\])]", piece) for piece in pieces):
        return None
    return pieces if len(pieces) > 1 else None


def repeated(value, index):
    sentences = [s for s in c.sentences(value.strip()) if norm(s)]
    keys = [norm(s) for s in sentences]
    n = len(keys)
    for size in range(1, n // 2 + 1):
        if n % size == 0 and keys == keys[:size] * (n // size):
            return len(words(" ".join(sentences[:size]))) >= REPEAT_WORDS
    long_twice = any(keys[i] in keys[:i] and len(words(sentences[i])) >= REPEAT_WORDS for i in range(n))
    if not long_twice:
        return False
    return all(index.known(sentence, value) for sentence in dict.fromkeys(sentences))


def caps_junk(value, index):
    """Baştaki ya da sondaki büyük harf çöpü: pakette seyrek (en çok CAPS_RARE kez), Türkçe yazıda küçük harfle hiç
    geçmeyen sözcük ("NOOSE", "LUCIA" gibi sık adlar ve "RT", "GPS" gibi kısaltmalar çöp sayılmaz); etiket değil."""
    tokens = value.split()
    if len(tokens) < 3:
        return False

    def junk(token):
        return bool(CAPS_TOKEN.match(token)) and index.caps[token] <= CAPS_RARE and index.vocabulary[token.lower()] < 2

    start, end = 0, len(tokens)
    while start < end and junk(tokens[start]):
        start += 1
    while end > start and junk(tokens[end - 1]):
        end -= 1
    if start == 0 and end == len(tokens):
        return False
    rest = " ".join(tokens[start:end])
    # Kalan kısım küçük harfli Türkçe cümle olmalı: büyük harfli tabela, radyo ve menü satırlarında büyük harfli sözcük
    # satırın kendisidir.
    if len(words(rest)) < 2 or not any(ch.islower() for ch in rest):
        return False
    return index.known(rest, value)


def classify(value, index):
    pieces = speaker_pieces(value, index.labels)
    if pieces and all(index.known(piece, value) for piece in pieces):
        return "konusmaci-birlesik"
    if repeated(value, index):
        return "tekrar"
    if caps_junk(value, index):
        return "buyuk-harf-copu"
    return None


def fuzzy_records(pack):
    """Bulanık imzalar: sıralı anahtar sayısı -> (uzunluk, Bloom baytları)."""
    fuzzy = pack.get("fuzzy")
    if not fuzzy:
        return None
    order = sorted({int(k, 16) for k in list(pack.get("entries", {})) + list(pack.get("segments", {}))})
    if fuzzy.get("count") != len(order):
        raise SystemExit(f"{pack.get('id')}: bulanık imza sayısı anahtarlarla uyuşmuyor")
    mask = base64.b64decode(fuzzy["mask"])
    lengths = base64.b64decode(fuzzy["lengths"])
    blooms = base64.b64decode(fuzzy["blooms"])
    records, li, bi = {}, 0, 0
    for i, key in enumerate(order):
        if mask[i >> 3] & (1 << (i & 7)):
            length = lengths[li]
            size = c.bits_for(length) // 8
            records[key] = (length, blooms[bi:bi + size])
            li += 1
            bi += size
    if li != len(lengths) or bi != len(blooms):
        raise SystemExit(f"{pack.get('id')}: bulanık imzalar okunamadı")
    return records


def rebuild_fuzzy(pack, records):
    order = sorted({int(k, 16) for k in list(pack["entries"]) + list(pack["segments"])})
    mask = bytearray((len(order) + 7) // 8)
    lengths, blooms = bytearray(), bytearray()
    for i, key in enumerate(order):
        record = records.get(key)
        if not record:
            continue
        mask[i >> 3] |= 1 << (i & 7)
        lengths.append(record[0])
        blooms += record[1]
    b64 = lambda data: base64.b64encode(bytes(data)).decode()
    return {"version": 1, "count": len(order), "mask": b64(mask), "lengths": b64(lengths), "blooms": b64(blooms)}


def clean(packs):
    """packs: (ad, paket) listesi. Silinenleri döner ve paketleri yerinde temizler.

    İki tur: önce adaylar bulunur, sonra adaylar bir kez daha, bu kez adayların kendisi kanıt sayılmadan denetlenir.
    Bir parçanın tek kanıtı başka bir birleşik satırsa (o da silinecek) satır kalır: hiçbir parça paketten tümden düşmez.
    """
    tables = [(name, pack, section, pack.get(section, {})) for name, pack in packs for section in ("entries", "segments")]
    index = Index([pack for _, pack in packs])
    main_keys = set()
    for name, pack in packs:
        if not pack.get("id", "").startswith("pool-"):
            main_keys.update(pack.get("entries", {}))
            main_keys.update(pack.get("segments", {}))
    candidates = {}
    for name, pack, section, table in tables:
        pool = pack.get("id", "").startswith("pool-")
        for key, value in table.items():
            reason = "havuz-dokumde-var" if pool and key in main_keys else classify(value, index)
            if reason:
                candidates[(name, section, key)] = reason
    survivors = [{section: {k: v for k, v in pack.get(section, {}).items() if (name, section, k) not in candidates}
                  for section in ("entries", "segments")} for name, pack in packs]
    reduced = Index(survivors)
    reduced.labels = index.labels
    removed = []
    for name, pack in packs:
        records = fuzzy_records(pack)
        for section in ("entries", "segments"):
            table = pack.get(section, {})
            for key in list(table):
                reason = candidates.get((name, section, key))
                if reason and reason != "havuz-dokumde-var" and classify(table[key], reduced) != reason:
                    reason = None
                if reason:
                    removed.append({"pack": name, "section": section, "key": key, "reason": reason, "turkish": table[key]})
                    del table[key]
        if not pack["entries"]:
            raise SystemExit(f"{name}: temizlikten sonra tam satır kalmadı")
        if records is not None:
            pack["fuzzy"] = rebuild_fuzzy(pack, records)
    return removed


def write(path, pack):
    data = json.dumps(pack, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    directory = os.path.dirname(os.path.abspath(path))
    fd, staged = tempfile.mkstemp(prefix="." + os.path.basename(path) + ".", suffix=".tmp", dir=directory)
    try:
        os.chmod(staged, 0o644)
        with os.fdopen(fd, "wb") as stream:
            with gzip.GzipFile(filename=path, mode="wb", fileobj=stream, compresslevel=9, mtime=0) as f:
                f.write(data)
        os.replace(staged, path)
    finally:
        if os.path.exists(staged):
            os.unlink(staged)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("out_dir")
    parser.add_argument("packs", nargs="+")
    parser.add_argument("--report")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    packs = []
    for path in args.packs:
        with gzip.open(path) as stream:
            packs.append((os.path.basename(path), json.load(stream)))
    before = {name: len(pack.get("entries", {})) + len(pack.get("segments", {})) for name, pack in packs}
    removed = clean(packs)
    summary = collections.Counter((item["pack"], item["reason"]) for item in removed)
    for name, pack in packs:
        after = len(pack["entries"]) + len(pack["segments"])
        reasons = ", ".join(f"{reason} {count}" for (pack_name, reason), count in sorted(summary.items()) if pack_name == name)
        print(f"{name}: {before[name]} → {after} satır (silinen {before[name] - after}: {reasons or '-'})")
    if args.report:
        with open(args.report, "w", encoding="utf-8") as report:
            for item in removed:
                report.write(json.dumps(item, ensure_ascii=False) + "\n")
    if not args.dry_run:
        os.makedirs(args.out_dir, exist_ok=True)
        for name, pack in packs:
            write(os.path.join(args.out_dir, name), pack)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
