# Python port of CouchSubsCore PackKey / PackFuzzy / SubtitleSegmenter (sentence split) for building packs.
import base64, gzip, hashlib, json, re, unicodedata

KEEP = {"Lu", "Ll", "Lt", "Lm", "Lo", "Nd", "Nl", "No"}
MARKS = {"Mn", "Mc", "Me"}
TAG = re.compile(r"<[^<>]{0,40}>")


def canon(text):
    s = TAG.sub(" ", text)
    s = unicodedata.normalize("NFKC", s).lower()
    s = unicodedata.normalize("NFD", s)
    out, gap = [], False
    for ch in s:
        cat = unicodedata.category(ch)
        if cat in MARKS:
            continue
        if cat in KEEP:
            if gap and out:
                out.append(" ")
            gap = False
            out.append(ch)
        else:
            gap = True
    return "".join(out)


def key(text):
    c = canon(text)
    if not c:
        return None
    return hashlib.sha256(c.encode("utf-8")).digest()[:8].hex()


# ---- fuzzy ----
FOLD = {"l": "i", "1": "i", "ı": "i", "j": "i", "0": "o", "5": "s", "æ": "a", "ø": "o", "œ": "o", "ß": "s"}
MIN_LEN, MAX_BITS, BPG = 16, 256, 3


def folded(text):
    return [FOLD.get(c, c) for c in canon(text) if c != " "]


def bits_for(length):
    b = 64
    while b < MAX_BITS and length * BPG > b:
        b *= 2
    return b


def trigram_hashes(sc):
    hs = set()
    for i in range(len(sc) - 2):
        h = 0xCBF29CE484222325
        for ch in sc[i:i + 3]:
            for byte in ch.encode("utf-8"):
                h ^= byte
                h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
        hs.add(h)
    return hs


def bloom(hashes, bits):
    words = [0] * (bits // 64)
    for h in hashes:
        bit = h & (bits - 1)
        words[bit >> 6] |= 1 << (bit & 63)
    return words


def signature(text):
    sc = folded(text)
    if len(sc) < MIN_LEN:
        return None
    length = min(len(sc), 255)
    words = bloom(trigram_hashes(sc), bits_for(length))
    return length, b"".join(w.to_bytes(8, "little") for w in words)


def fuzzy_index(order, english_of):
    """order: sorted list of int keys (entries+segments). english_of: int key -> English text (or None)."""
    mask = bytearray((len(order) + 7) // 8)
    lengths = bytearray()
    blooms = bytearray()
    for i, k in enumerate(order):
        en = english_of.get(k)
        sig = signature(en) if en else None
        if not sig:
            continue
        mask[i >> 3] |= 1 << (i & 7)
        lengths.append(sig[0])
        blooms += sig[1]
    b64 = lambda b: base64.b64encode(bytes(b)).decode()
    return {"version": 1, "count": len(order), "mask": b64(mask), "lengths": b64(lengths), "blooms": b64(blooms)}


# ---- segmenter (sentence split; same rules as SubtitleSegmenter.sentences / speakerLabel) ----
ABBR = {"mr", "mrs", "ms", "dr", "st", "jr", "sr", "prof", "mt", "vs", "etc", "e.g", "i.e", "lt", "sgt", "capt", "gen", "col"}
ENDERS, CLOSERS = set(".!?…"), set("\"'”’)]")


def _ends_abbr(s):
    if not s.endswith("."):
        return False
    parts = s.split(" ")
    word = parts[-1][:-1] if parts else ""
    if len(word) == 1 and word.isupper():
        return True
    return word.lower() in ABBR


def sentences(block):
    ch = list(block)
    res, start, i = [], 0, 0
    while i < len(ch):
        if ch[i] != " ":
            i += 1
            continue
        back = i - 1
        while back >= start and ch[back] in CLOSERS:
            back -= 1
        cand = "".join(ch[start:i])
        nxt = ch[i + 1] if i + 1 < len(ch) else None
        if back >= start and ch[back] in ENDERS and not (nxt is not None and nxt.islower()) and not _ends_abbr(cand):
            res.append(cand)
            start = i + 1
        i += 1
    if start < len(ch):
        res.append("".join(ch[start:]))
    return res


def write_pack(path, pack_id, title, source, entries, segments, english):
    """entries/segments: hex key -> Turkish. english: hex key -> English (only used for fuzzy signatures, not stored)."""
    order = sorted({int(k, 16) for k in list(entries) + list(segments)})
    eng = {int(k, 16): v for k, v in english.items()}
    obj = {"format": 2, "id": pack_id, "title": title, "source": source,
           "entries": dict(sorted(entries.items())), "segments": dict(sorted(segments.items())),
           "fuzzy": fuzzy_index(order, eng)}
    data = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    with gzip.GzipFile(path, "wb", compresslevel=9, mtime=0) as f:
        f.write(data)
