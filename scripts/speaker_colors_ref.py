# SPDX-License-Identifier: AGPL-3.0-only
# Konuşana göre renk (v2) başvuru uygulaması ve ortak test vektörü. Windows, Mac/iPhone ve Android'deki
# SpeakerColorBook aynı sırayla verilen adlara AYNI rengi vermek zorunda; testleri docs/speaker-colors-vectors.json'u okur.
# Kurallar: ad anahtarı = kırpılmış, sondaki noktalaması atılmış, küçük harf. OCR yakın okuması aynı kişi: karışan harfler
# (l/1/| → i, 0 → o, rn → m) eşitlenince aynıysa ya da ikisi de >= 5 harfken Levenshtein <= 1 ise. Yeni kişi tabanı
# (FNV-1a % 10) alır; taban ya da ailesi kullanılıyorsa palet sırasıyla ilk kullanılmayan ve ailesi kullanılmayan renk,
# o da yoksa ilk kullanılmayan, o da yoksa taban. Vektörü yeniden üretmek: python3 scripts/speaker_colors_ref.py > docs/speaker-colors-vectors.json
import json, sys
P=['#FFD54F','#4FC3F7','#81C784','#FF8A65','#CE93D8','#F06292','#4DD0E1','#AED581','#FFB74D','#90CAF9']
FAM={'#FFD54F':'A','#FFB74D':'A','#FF8A65':'A','#4FC3F7':'B','#4DD0E1':'B','#90CAF9':'B','#81C784':'C','#AED581':'C','#CE93D8':'D','#F06292':'D'}
def key(name):
    s=name.strip()
    while s and s[-1] in '.,!?;:…': s=s[:-1]
    return s.strip().lower()
def fnv(s):
    h=2166136261
    b=s.encode('utf-16-le')
    for i in range(0,len(b),2):
        h^=b[i]|(b[i+1]<<8); h=(h*16777619)&0xffffffff
    return h
def confuse(s):
    s=s.replace('rn','m')
    return ''.join({'l':'i','1':'i','|':'i','0':'o'}.get(c,c) for c in s)
def lev(a,b):
    d=list(range(len(b)+1))
    for i,ca in enumerate(a,1):
        p=d[:]; d[0]=i
        for j,cb in enumerate(b,1):
            d[j]=min(p[j]+1,d[j-1]+1,p[j-1]+(ca!=cb))
    return d[-1]
class Book:
    def __init__(s): s.people=[]
    def color(s,name):
        k=key(name)
        if not k: return None
        for pk,c in s.people:
            if pk==k or confuse(pk)==confuse(k) or (min(len(pk),len(k))>=5 and lev(pk,k)<=1): return c
        base=fnv(k)%10
        used={c for _,c in s.people}; fams={FAM[c] for c in used}
        pick=None
        for i in range(10):
            c=P[(base+i)%10]
            if c not in used and FAM[c] not in fams: pick=c;break
        if pick is None:
            for i in range(10):
                c=P[(base+i)%10]
                if c not in used: pick=c;break
        if pick is None: pick=P[base]
        s.people.append((k,pick)); return pick
seq=["Mattia","Lucia","Mattla","Mattia.","MATTIA","Boobie","Jason","Cal","Raul","Brian","Mattia","Lucia:","Jasen","Dre'Quan","Bae-Luxe","Lori","Cal"]
b=Book(); out=[]
for n in seq: out.append({"name":n,"color":b.color(n)})
json.dump({"palette":P,"families":FAM,"sequence":out},sys.stdout,ensure_ascii=False,indent=1)
