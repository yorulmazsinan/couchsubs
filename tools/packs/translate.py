# Translate transcript rows sentence by sentence with Claude Haiku 5.5.
# Usage: translate.py <game> <rows.jsonl>[,<rows2.jsonl>] <out tr.json>
# Output: {sentence key: {"en": ..., "tr": ...}} plus line structure in <out>.lines.json
import json, re, sys
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import common as c, llm

game, srcs, out = sys.argv[1], sys.argv[2].split(","), sys.argv[3]

GLOSSARY = {
    "ds": """Game: DEATH STRANDING (Director's Cut), Kojima Productions. Keep these Turkish terms (same as our Death Stranding 2 pack):
Timefall = zaman yağmuru; the Beach = Sahil; chiral = kiral; chiralium = kiralyum; Chiral Network = Kiral Ağ;
BT / BTs = BT / BT'ler; BB = BB; Bridges, UCA, DOOMS, Homo Demens, Death Stranding, Odradek, MULE(s), Fragile Express,
Knot City names (Capital Knot City, Port Knot City, Lake Knot City, Edge Knot City), Q-pid stay as is;
cryptobiote = kriptobiyot; porter = taşıyıcı; voidout = boşluk patlaması; repatriate = geri dönen;
Extinction Entity = Yok Oluş Varlığı; Last Stranding = Son Stranding; hologram = hologram; terminal = terminal;
delivery = teslimat; cargo = kargo. Character names stay as is (Sam, Lou, Bridget, Amelie, Die-Hardman, Deadman,
Heartman, Mama, Lockne, Higgs, Cliff/Clifford Unger, Fragile, Igor)."""
    ,
    "sm2": """Game: Marvel's Spider-Man 2 (Insomniac Games). Keep names as is (Peter, Miles, MJ, Harry, Ganke, Hailey,
Rio, Yuri, Kraven, Venom, Scream, Wraith, Spider-Man, Spidey, J. Jonah Jameson, Danika, Martin Li, Dr. Connors).
Terms: symbiote = simbiyot; Hunters = Avcılar; Lizard = Kertenkele; Sandman = Kum Adam; Mister Negative = Bay Negatif;
Black Cat = Kara Kedi; Flame = Alev; the suit = kostüm; web/webs = ağ; web-shooters = ağ atıcılar; Spider-Sense = Örümcek Hissi;
Brooklyn Visions (Academy), Emily-May Foundation (EMF), F.E.A.S.T., Oscorp, Daily Bugle, Harlem, Queens, Manhattan stay as is."""
}

SYSTEM = f"""You translate video game subtitles from English into Turkish for CouchSubs, an app that shows Turkish
subtitles on the TV while people play.
{GLOSSARY[game]}

Rules:
- Natural spoken Turkish, the way a professional Turkish subtitle translator would write it; match the tone and register
  (casual banter stays casual; use "sen" between friends, family and enemies; "siz" only for formal/respectful address).
- Translate every sentence separately: each numbered sentence gets its own Turkish sentence that stands on its own,
  because the game may show it alone on screen. Never move meaning between sentences; never merge or skip one.
- Keep profanity and insults at the same strength (fuck = siktir/amına koyayım etc., shit = siktir/bok, damn = lanet olsun/kahretsin).
  Do not soften and do not intensify.
- Keep punctuation style (…, ?!, quotes, em dashes). Keep numbers. No English words left unless they are names or listed terms.
- Interjections and sounds (Ugh, Huh, Hmm, Ah) get a Turkish equivalent or stay as a sound (Ah, Hı, Hmm).
- Output only the requested JSON."""

SCHEMA = {"type": "object", "properties": {"items": {"type": "array", "items": {"type": "object", "properties": {
    "id": {"type": "string"}, "tr": {"type": "string"}}, "required": ["id", "tr"], "additionalProperties": False}}},
    "required": ["items"], "additionalProperties": False}

rows = []
for s in srcs:
    rows += [json.loads(l) for l in open(s, encoding="utf-8")]

# Unique lines by key, in order; each line split into sentences.
lines, seen = [], set()
for r in rows:
    k = c.key(r["text"])
    if not k or k in seen:
        continue
    seen.add(k)
    sents = [x for x in c.sentences(r["text"]) if x.strip()]
    lines.append({"key": k, "speaker": r["speaker"], "scene": r["scene"], "text": r["text"], "sents": sents,
                  "raw": r.get("raw")})
print(game, "lines", len(lines), "sentences", sum(len(l["sents"]) for l in lines))

CH = 40


def run(start):
    ctx = lines[max(0, start - 4):start]
    chunk = lines[start:start + CH]
    parts = []
    if ctx:
        parts.append("Previous lines for context (do not translate):")
        parts += [f"  {l['speaker'] or '-'}: {l['text']}" for l in ctx]
    parts.append(f"Scene: {chunk[0]['scene'] or '-'}\nTranslate each numbered sentence (id = line.sentence):")
    for i, l in enumerate(chunk):
        parts.append(f"[{l['speaker'] or 'text'}]")
        for j, s in enumerate(l["sents"]):
            parts.append(f"  {start + i}.{j}\t{s}")
    res = llm.call(SYSTEM, "\n".join(parts), SCHEMA, f"{game}-translate", max_tokens=32000)
    return start, {it["id"]: it["tr"].strip() for it in (res or {}).get("items", [])}


got = {}
for attempt in range(3):
    todo = [s for s in range(0, len(lines), CH)
            if any(f"{s + i}.{j}" not in got for i, l in enumerate(lines[s:s + CH]) for j in range(len(l["sents"])))]
    if not todo:
        break
    with ThreadPoolExecutor(4) as ex:
        for start, items in ex.map(run, todo):
            got.update(items)
    print("attempt", attempt, "chunks", len(todo), "spent $%.4f" % llm.spent())

for i, l in enumerate(lines):
    l["tr"] = [got.get(f"{i}.{j}") for j in range(len(l["sents"]))]
missing = sum(1 for l in lines for t in l["tr"] if not t)
print("missing sentences", missing)
json.dump(lines, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=0)
