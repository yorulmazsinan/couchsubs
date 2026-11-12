import sys, json, re
sys.path.insert(0, '.')
import common as c
rows=[json.loads(l) for l in open(sys.argv[1])]
pat=sys.argv[3]
units={}
for r in rows:
    units[c.key(r['text'])]=r['text']
    for s in c.sentences(r['text']): units[c.key(s)]=s
grams={k:set(''.join(c.folded(v))[i:i+3] for i in range(len(c.folded(v))-2)) for k,v in units.items()}
pool=json.load(open(sys.argv[2]))['lines']
pool=[l for l in pool if re.search(pat,l['text'],re.I)] if pat!='-' else pool
exact=fz=0; misses=[]
def body(t):
    m=re.match(r'^.{0,32}?[:•]\s*',t)
    return t[m.end():] if m else t
for l in pool:
    b=body(l['text'])
    parts=[b]+c.sentences(b)
    if c.key(b) in units or all(c.key(p) in units for p in c.sentences(b)):
        exact+=1; continue
    fq=''.join(c.folded(b)); g=set(fq[i:i+3] for i in range(len(fq)-2))
    if len(fq)<16 or not g: misses.append(b); continue
    best=0;bt=None
    for k,gg in grams.items():
        if not gg or abs(len(gg)-len(g))>len(g)*0.4: continue
        s=min(len(g&gg)/len(g), len(g&gg)/len(gg))
        if s>best: best,bt=s,units[k]
    if best>=0.6: fz+=1
    else: misses.append(b)
print('pool lines',len(pool),'exact',exact,'fuzzy>=0.6',fz,'miss',len(misses))
for m in misses[:15]: print('  MISS',m[:120])
