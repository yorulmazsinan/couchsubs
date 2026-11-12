# Quality pass: automatic checks + a second Claude review of every sentence; only corrections are applied,
# after filtering. Usage: review.py <game> <tr.json> <out reviewed.json>
import json, re, sys
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import common as c, llm
from translate_rules import GLOSSARY, RULES

game, src, out = sys.argv[1:4]
lines = json.load(open(src, encoding="utf-8"))

STRONG_EN = re.compile(r"\b(fuck\w*|shit\w*|bitch\w*|bastard\w*|asshole\w*|motherfuck\w*|dick\w*|cunt\w*)\b", re.I)
STRONG_TR = re.compile(r"(sik|amk|amın|amına|orospu|piç|bok|göt|kahpe|yavşak|puşt|siktir|ibne|şerefsiz|pislik|kaltak|lanet|kahrolası|aşağılık|alçak)", re.I)
TR_CHARS = re.compile(r"[çğıöşüÇĞİÖŞÜ]")
EN_WORDS = re.compile(r"\b(the|and|you|what|this|that|with|have|are|is|not|for|your|we|they)\b", re.I)
BAD_SCRIPT = re.compile(r"[Ѐ-ӿ぀-ヿ一-鿿가-힯]")


def problems(en, tr):
    p = []
    if not tr:
        return ["missing"]
    if BAD_SCRIPT.search(tr):
        p.append("script")
    words = re.findall(r"[A-Za-z']+", en)
    if len(words) >= 3 and (c.canon(tr) == c.canon(en) or (not TR_CHARS.search(tr) and len(EN_WORDS.findall(tr)) >= 2)):
        p.append("english")
    if len(en) >= 25 and not (0.45 <= len(tr) / len(en) <= 2.3):
        p.append("length")
    if STRONG_EN.search(en) and not STRONG_TR.search(tr):
        p.append("softened")
    return p


SCHEMA = {"type": "object", "properties": {"fixes": {"type": "array", "items": {"type": "object", "properties": {
    "id": {"type": "string"}, "tr": {"type": "string"},
    "why": {"type": "string", "enum": ["meaning", "english_left", "profanity", "grammar", "term", "shifted", "tone"]}},
    "required": ["id", "tr", "why"], "additionalProperties": False}}},
    "required": ["fixes"], "additionalProperties": False}

SYSTEM = f"""You are a senior Turkish subtitle editor checking machine translations of video game subtitles.
{GLOSSARY[game]}
{RULES}
You get numbered English sentences with their Turkish translation (sometimes marked with automatic warnings).
Return a fix ONLY for translations that are actually wrong: wrong meaning, a sentence translated as a neighbouring
sentence (shifted), English left untranslated, softened or intensified profanity, broken Turkish grammar or spelling,
a glossary term not followed, or clearly wrong register. Do not rewrite acceptable translations for style.
Each fix must be the full corrected Turkish for that one sentence only."""

items = []
for i, l in enumerate(lines):
    for j, en in enumerate(l["sents"]):
        items.append((f"{i}.{j}", l["speaker"], en, l["tr"][j] or ""))
flag = {iid: problems(en, tr) for iid, _, en, tr in items}
print("auto flags", sum(1 for v in flag.values() if v),
      {k: sum(1 for v in flag.values() if k in v) for k in ["missing", "script", "english", "length", "softened"]})

CH = 80


def run(start):
    chunk = items[start:start + CH]
    body = []
    for iid, sp, en, tr in chunk:
        warn = f"  [warning: {', '.join(flag[iid])}]" if flag[iid] else ""
        body.append(f"{iid}\t[{sp or '-'}] EN: {en}\n\tTR: {tr}{warn}")
    res = llm.call(SYSTEM, "\n".join(body), SCHEMA, f"{game}-review", max_tokens=32000, effort=__import__("os").environ.get("EFFORT", "medium"))
    return (res or {}).get("fixes", [])


fixes = []
with ThreadPoolExecutor(4) as ex:
    for f in ex.map(run, range(0, len(items), CH)):
        fixes += f
print("proposed fixes", len(fixes), "spent $%.4f" % llm.spent())

by_id = {iid: (en, tr) for iid, _, en, tr in items}
applied, vetoed = [], []
for f in fixes:
    if f["id"] not in by_id:
        continue
    en, old = by_id[f["id"]]
    new = f["tr"].strip()
    reason = None
    if not new or new == old:
        reason = "same"
    elif problems(en, new) and not (problems(en, old) and len(problems(en, new)) < len(problems(en, old))):
        reason = "new-problem:" + ",".join(problems(en, new))
    elif STRONG_TR.search(new) and not STRONG_TR.search(old) and not STRONG_EN.search(en) \
            and not re.search(r"\b(damn|hell|crap|goddamn)\b", en, re.I):
        reason = "added-profanity"
    if reason:
        vetoed.append({**f, "en": en, "old": old, "veto": reason})
        continue
    i, j = map(int, f["id"].split("."))
    lines[i]["tr"][j] = new
    applied.append({**f, "en": en, "old": old})

print("applied", len(applied), "vetoed", len(vetoed),
      {k: sum(1 for a in applied if a["why"] == k) for k in SCHEMA["properties"]["fixes"]["items"]["properties"]["why"]["enum"]})
left = sum(1 for l in lines for j, en in enumerate(l["sents"]) if problems(en, l["tr"][j] or ""))
print("auto flags left", left)
json.dump(lines, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=0)
json.dump({"applied": applied, "vetoed": vetoed}, open(out + ".log.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
