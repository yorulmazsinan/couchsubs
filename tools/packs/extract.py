# Extract dialogue lines (speaker, text, scene) from the fan transcripts.
# Usage: python3 -I extract.py ds|sm2 <src dir> <out.jsonl>
import json, re, sys, html

game, src, out = sys.argv[1:4]
rows = []


def clean(t):
    t = re.sub(r"\[[^\]]*\]", " ", t)          # [stage directions]
    t = re.sub(r"\([^)]*\)", " ", t)           # (chuckles), (phone)
    t = t.replace(" ", " ")
    t = re.sub(r"\s+", " ", t).strip()
    t = re.sub(r"^[-–—]\s*", "", t)
    return t


def wiki_inline(t):
    t = re.sub(r"<ref[^>]*>.*?</ref>|<ref[^>]*/>", "", t)
    t = re.sub(r"<br\s*/?>", " ", t)
    t = re.sub(r"<[^>]+>", "", t)
    t = re.sub(r"\{\{[^{}]*\}\}", "", t)
    t = re.sub(r"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]", r"\1", t)
    t = t.replace("'''", "").replace("''", "")
    return html.unescape(t)


if game == "ds":
    scene = ""
    for raw in open(f"{src}/lines.txt", encoding="utf-8"):
        raw = raw.strip()
        if raw.startswith("=="):
            scene = raw.strip("= ")
            continue
        m = re.match(r"^([A-Z][\w’'.\- ]{0,40}?):\s+(.+)$", raw)
        if not m:
            continue
        speaker, text = m.group(1).strip(), clean(m.group(2))
        if len(speaker.split()) > 4 or not re.search(r"[A-Za-z]", text):
            continue
        rows.append({"speaker": speaker, "text": text, "scene": scene})
elif game == "sm2":
    for name in ("script", "menu"):
        w = json.load(open(f"{src}/{name}.json", encoding="utf-8"))["parse"]["wikitext"]["*"]
        scene = ""
        for raw in w.split("\n"):
            raw = raw.strip()
            h = re.match(r"^=+\s*(.*?)\s*=+$", raw)
            if h:
                scene = wiki_inline(h.group(1)).strip()
                continue
            if name == "script":
                m = re.match(r"^'''(.+?)'''\s*(?:\(''[^)]*''\))?\s*:\s*(.+)$", raw)
                if not m:
                    continue
                speaker, text = wiki_inline(m.group(1)).strip(), clean(wiki_inline(m.group(2)))
                # duplicated label typo: "'''Danika Hart''': '''Danika Hart''': ..."
                text = re.sub(r"^" + re.escape(speaker) + r":\s*", "", text)
            else:
                if not raw or raw.startswith(("{", "[[Category", "|", "!")):
                    continue
                speaker, text = "", clean(wiki_inline(raw.lstrip("*:;# ")))
            if not re.search(r"[A-Za-z]", text) or len(text) < 2:
                continue
            rows.append({"speaker": speaker, "text": text, "scene": scene})

with open(out, "w", encoding="utf-8") as f:
    for r in rows:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
print(game, len(rows), "lines,", sum(len(r["text"].split()) for r in rows), "words")
