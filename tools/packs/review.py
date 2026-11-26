# Quality pass: automatic checks + a second Claude review of every sentence; only corrections are applied,
# after filtering. Usage: review.py <game> <tr.json> <out reviewed.json>
import json, re, sys
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import common as c, llm
from atomic_json import dump_atomic
from translate_rules import GLOSSARY, RULES

game, src, out = sys.argv[1:4]
lines = json.load(open(src, encoding="utf-8"))

# Strong English swearing. "ass" is matched as a whole word (with a few compounds) so "assassin", "class" or "pass"
# never count; "nigga" is street address but keeps its weight and is never translated softly.
STRONG_EN = re.compile(r"\b(fuck\w*|shit\w*|bitch\w*|bastard\w*|(?:dumb|jack|smart|fat|kiss|kick)?ass(?:es)?|"
                       r"asshole\w*|motherfuck\w*|dick\w*|cunt\w*|whor(?:e|es|ing)|slut\w*|pricks?|puss(?:y|ies)|"
                       r"nigga\w*|nigger\w*|cock(?:s|sucker\w*|head\w*)?|twats?|wank(?:er|ers|ing)?|"
                       r"douche(?:bag\w*|s)?|fagg?ots?|retard(?:s|ed)?)\b", re.I)
# Turkish swearing that keeps a strong English word at its strength. Mild words (pislik, lanet, kahrolası...) are not
# here: "asshole" -> "pislik" or "pussy" -> "korkak" is softening and must be flagged.
# Ordinary words that start like a swear are left out: "götür/götürmek" (take), "siklet" (boxing weight class), "boks/
# boksa/boksör/boksçu" (boxing). With re.I Python treats dotless "ı" as "i", so "sık/sıkıldım" counted as "sik" and "amin"
# (amen) as "amın"; those letters are matched case-sensitively ("I" stays for all-caps text). These are detection fixes
# only; every real swear form is still matched ("götün", "boktan", "sikerim", "SİKTİR").
HARD_TR = re.compile(r"(?<!\w)(?:s(?-i:[iİI])k(?!let)|amk|am(?-i:[ıI])n|amcık|orospu|piç|"
                     r"bok(?!s(?:\b|a\b|u\b|ör|çu|ta\b|tan\b))|göt(?!ür)|kıç|kahpe|yavşak|puşt|siktir|ibne|şerefsiz|"
                     r"kaltak|sürtük|fahişe|yarak|yarrak|dalyarak|pezevenk|gavat)", re.I)
# Full-strength Turkish for strong English insults that are not swears on their own ("retard" -> "gerizekalı", "wanker" ->
# "otuzbirci"). Only used to see that a strong English line was not softened; never to veto a fix that adds them.
HARD_TR_INSULT = re.compile(r"(?<!\w)(?:gerizekal|geri zekal|özürlü|otuzbirci|hıyar)", re.I)
# Any Turkish insult, mild ones included: a correction must not add one the English does not have.
# "alçakgönüllü" (humble) is not "alçak" (vile).
STRONG_TR = re.compile(HARD_TR.pattern + r"|(?<!\w)(?:pislik|lanet|kahrolası|aşağılık|alçak(?!\s?gönül))", re.I)
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
    if STRONG_EN.search(en) and not HARD_TR.search(tr) and not HARD_TR_INSULT.search(tr):
        p.append("softened")
    return p


SCHEMA = {"type": "object", "properties": {"fixes": {"type": "array", "items": {"type": "object", "properties": {
    "id": {"type": "string"}, "tr": {"type": "string"},
    "why": {"type": "string", "enum": ["meaning", "english_left", "profanity", "grammar", "term", "shifted", "tone"]}},
    "required": ["id", "tr", "why"], "additionalProperties": False}}},
    "required": ["fixes"], "additionalProperties": False}

SYSTEM = f"""You are a senior Turkish subtitle editor checking machine translations of video game subtitles.
{GLOSSARY.get(game, f'Game: {game}.')}
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
    # Like translation, review runs in parallel batches. Ignore model IDs from
    # other batches so a late/hallucinated correction cannot rewrite them.
    allowed = {iid for iid, _, _, _ in chunk}
    proposed = [fix for fix in (res or {}).get("fixes", [])
                if isinstance(fix, dict) and fix.get("id") in allowed]
    counts = {}
    for fix in proposed:
        counts[fix["id"]] = counts.get(fix["id"], 0) + 1
    # A model may offer contradictory fixes for one ID. Reject all ambiguous
    # corrections instead of silently applying whichever came last.
    return [fix for fix in proposed if counts[fix["id"]] == 1]


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
dump_atomic(lines, out, ensure_ascii=False, indent=0)
dump_atomic({"applied": applied, "vetoed": vetoed}, out + ".log.json", ensure_ascii=False, indent=1)
