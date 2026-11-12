# Pick Spider-Man pool lines (OCR readings users actually saw) that the transcript does not cover and let Claude
# restore the English. Usage: poolfix.py <pool export.json> <sm2 rows.jsonl> <out.jsonl>
import json, re, sys
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import common as c, llm

pool = json.load(open(sys.argv[1]))["lines"]
rows = [json.loads(l) for l in open(sys.argv[2])]
known = set()
for r in rows:
    known.add(c.key(r["text"]))
    known.update(c.key(s) for s in c.sentences(r["text"]))

LABELS = r"(SPIDER[- ]?M?A?N?\b.*|SPIDER|KRAVEN|HUNTERS?|SCREAM|GANKE|MJ|MILES|RIO|HARRY|PETER|MARTIN LI|DANIKA|DR\. ?CONNORS|CONNORS|SYMBIOTE|VENOM|BLACK CAT|YURI|HAILEY|HOWARD|J\. ?JONAH JAMESON|JAMESON|NORMAN( OSBORN)?|TINKERER|AARON DAVIS|JEFFERSON DAVIS|WRAITH|LIZARD|SANDMAN|FLAME|MYSTERIO|ROBBIE|EMILY-MAY|MEPHISTO|TOMBSTONE|PROWLER)"
KEYWORDS = r"\b(spider-?man|kraven|venom|symbiote|ganke|hailey|lizard|connors|wraith|yuri|mister negative|martin li|sandman|oscorp|emf|brooklyn visions|harlem|peter parker|miles morales)\b"

picked = []
for l in pool:
    t = l["text"]
    m = re.match(r"^[-•\s]*([A-Za-z][A-Za-z .'’-]{1,28}?)\s*[•:]", t)
    label = m.group(1).strip().upper() if m else ""
    if not (re.fullmatch(LABELS, label) or re.search(KEYWORDS, t, re.I)):
        continue
    body = t[m.end():].strip(" •:") if m else t
    if c.key(body) in known or (c.sentences(body) and all(c.key(s) in known for s in c.sentences(body))):
        continue
    picked.append({"raw": t, "body": body, "label": label, "installs": l["installs"]})
print("picked", len(picked))

SYSTEM = """You restore English video game subtitle lines that were read from a TV screen with OCR.
The lines come from players of Insomniac's Marvel's Spider-Man games (mostly Marvel's Spider-Man 2).
For each line return the most likely original English subtitle text (without the speaker label), fixing only OCR damage
(wrong letters, merged/split words, stray symbols, missing apostrophes). Do not paraphrase or complete cut-off text.
Set keep=false when the line is not a Spider-Man game subtitle (UI/menu fragment, another game, Turkish text,
PlayStation notification) or when it is too damaged or too cut off (a fragment that is not a full subtitle) to restore with confidence.
speaker: the restored speaker name if a label is visible (e.g. "Spider-Man", "Kraven"), else ""."""
SCHEMA = {"type": "object", "properties": {"items": {"type": "array", "items": {"type": "object", "properties": {
    "id": {"type": "integer"}, "keep": {"type": "boolean"}, "english": {"type": "string"}, "speaker": {"type": "string"}},
    "required": ["id", "keep", "english", "speaker"], "additionalProperties": False}}},
    "required": ["items"], "additionalProperties": False}


def run(start):
    chunk = picked[start:start + 60]
    user = "Lines:\n" + "\n".join(f"{start + i}\t{p['raw']}" for i, p in enumerate(chunk))
    return llm.call(SYSTEM, user, SCHEMA, "sm2-poolfix", max_tokens=16000)


out = []
with ThreadPoolExecutor(4) as ex:
    for res in ex.map(run, range(0, len(picked), 60)):
        for it in (res or {}).get("items", []):
            i = it["id"]
            if 0 <= i < len(picked) and it["keep"] and re.search(r"[A-Za-z]", it["english"]):
                out.append({"speaker": it["speaker"], "text": it["english"].strip(), "scene": "pool",
                            "raw": picked[i]["body"]})
with open(sys.argv[3], "w") as f:
    for r in out:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
print("kept", len(out), "spent so far $%.4f" % llm.spent())
