# Sentence-initial "I..." where Turkish needs "İ" (model lowercased/uppercased with ASCII rules).
# Decides per word from word frequencies in the existing Turkish packs. Usage: fixcase.py <packs dir> <file.json>...
import collections, gzip, json, os, re, sys
freq = collections.Counter()
for f in os.listdir(sys.argv[1]):
    d = json.load(gzip.open(os.path.join(sys.argv[1], f)))
    for v in list(d["entries"].values()) + list(d.get("segments", {}).values()):
        for w in re.findall(r"\b[\wçğıöşü]+", v):
            if w[:1].islower():
                freq[w] += 1
TR_LOWER = lambda s: s.replace("I", "ı").replace("İ", "i").lower()
changed = collections.Counter()
def fix(m):
    w = m.group(0)
    rest = TR_LOWER(w[1:])
    dotted, dotless = "i" + rest, "ı" + rest
    if freq[dotted] > freq[dotless]:
        changed[w + "→İ" + w[1:]] += 1
        return "İ" + w[1:]
    return w
for path in sys.argv[2:]:
    L = json.load(open(path, encoding="utf-8"))
    for l in L:
        l["tr"] = [re.sub(r"\bI[a-zçğıöşü]+", fix, t) if t else t for t in l["tr"]]
    json.dump(L, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=0)
print(sum(changed.values()), changed.most_common(40))
