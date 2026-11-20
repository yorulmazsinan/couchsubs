# Ortak bulanık eşleme deneme paketi ve vakaları: core/Tests/CouchSubsCoreTests/Fixtures/pack-fuzzy.json.gz ve
# pack-fuzzy-cases.json (Mac, Android ve Windows aynı sonucu vermeli). Satırlar bu betik için yazıldı.
# Kullanım: python3 tools/packs/fuzzyfixture.py; sonra iki dosyayı couchsubs-android/app/src/test/resources/fixtures/'a kopyala.
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
repo = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
import common as c

LINES = [
    ("Get in the car, we're leaving.", "Arabaya bin, gidiyoruz."),
    ("I told you not to come here.", "Buraya gelme demiştim."),
    ("Where did you put the money?", "Parayı nereye koydun?"),
    ("Keep your head down and follow me.", "Başını eğ ve beni takip et."),
    ("We need to talk about your brother.", "Kardeşin hakkında konuşmamız lazım."),
    ("That's not what I meant.", "Demek istediğim bu değildi."),
    ("Somebody call an ambulance!", "Biri ambulans çağırsın!"),
    ("The boat leaves at midnight.", "Tekne gece yarısı kalkıyor."),
    ("Don't make me ask you twice.", "Bana iki kez sordurtma."),
    ("I'll meet you at the diner.", "Lokantada buluşuruz."),
    ("You have no idea what you're doing.", "Ne yaptığın hakkında hiçbir fikrin yok."),
    ("Stay close and keep quiet.", "Yakında dur ve sessiz ol."),
    ("How long have you been working here?", "Ne zamandır burada çalışıyorsun?"),
    ("Let's get out of here before the cops show up.", "Polisler gelmeden buradan gidelim."),
    ("I never liked that guy anyway.", "O adamı zaten hiç sevmedim."),
    ("Give me the keys.", "Anahtarları ver."),
    ("Are you out of your mind?", "Aklını mı kaçırdın?"),
    ("This place gives me the creeps.", "Burası tüylerimi diken diken ediyor."),
    ("We're running out of time.", "Zamanımız tükeniyor."),
    ("Tell your father I said hello.", "Babana selamımı söyle."),
    ("I can't believe you did that.", "Bunu yaptığına inanamıyorum."),
    ("Watch out for the guards.", "Muhafızlara dikkat et."),
    ("The deal is off.", "Anlaşma iptal."),
    ("Nobody move or the girl gets hurt!", "Kimse kıpırdamasın yoksa kız zarar görür!"),
    ("You owe me a favor.", "Bana bir iyilik borçlusun."),
    ("Pull over right here.", "Tam burada kenara çek."),
    ("I just want to go home.", "Sadece eve gitmek istiyorum."),
    ("Who sent you?", "Seni kim gönderdi?"),
    ("Drop the gun, now!", "Silahı bırak, hemen!"),
    ("She doesn't trust anyone.", "Kimseye güvenmiyor."),
]

entries = {c.key(en): tr for en, tr in LINES}
english = {c.key(en): en for en, tr in LINES}
out = os.path.join(repo, "core/Tests/CouchSubsCoreTests/Fixtures/pack-fuzzy.json.gz")
c.write_pack(out, "fuzzy-test", "Fuzzy Test", "CouchSubs denemesi", entries, {}, english)
T = dict(LINES)
cases = [
    # tam
    ("Give me the keys.", T["Give me the keys."]),
    # birinci tur (variants): karışan harf, yutulan boşluk/kesme
    ("Somebody caII an ambulance!", T["Somebody call an ambulance!"]),
    ("I cant believe you did that.", T["I can't believe you did that."]),
    # ikinci tur: yutulmuş harf
    ("Wach out for the guards.", T["Watch out for the guards."]),
    ("The dal is off.", T["The deal is off."]),
    ("Pull ovr right here.", T["Pull over right here."]),
    # ikinci tur: benzeyen harf (b → h, n → m)
    ("Who sent yov?", T["Who sent you?"]),
    ("You owe me a favar.", T["You owe me a favor."]),
    # ikinci tur: iki karışıklık birden
    ("Stay cIose and keep qviet.", T["Stay close and keep quiet."]),
    # konuşmacı adıyla
    ("LUCIA: Drop the gun, now!", "LUCIA: " + T["Drop the gun, now!"]),
    ("JASON: Wach out for the guards.", "JASON: " + T["Watch out for the guards."]),
    # bulanık imza (uzun, OCR izli)
    ("Let's get 0ut of here bef0re the c0ps show up.", T["Let's get out of here before the cops show up."]),
    ("We need to ta1k about y0ur br0ther.", T["We need to talk about your brother."]),
    # pakette olmayan, benzer satırlar: eşleşmemeli
    ("Give me the money.", None),
    ("Who sent him?", None),
    ("I just want to go to bed.", None),
    ("The boat leaves at noon tomorrow.", None),
    ("Nobody trusts anyone here.", None),
    ("We need to talk about your sister.", None),
]
json.dump({"warmUp": "Give me the keys.", "cases": [{"screen": s, "turkish": t} for s, t in cases]},
          open(os.path.join(repo, "core/Tests/CouchSubsCoreTests/Fixtures/pack-fuzzy-cases.json"), "w"),
          ensure_ascii=False, indent=1)
print("satır", len(entries), "vaka", len(cases))
