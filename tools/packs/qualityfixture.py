# Paket eşleşme kalitesi deneme paketi ve vakaları: core/Tests/CouchSubsCoreTests/Fixtures/pack-quality.json.gz ve
# pack-quality-cases.json (Mac, iPhone, Android ve Windows aynı sonucu vermeli). Ekran satırları GTA 6 oyuncularının
# gerçek okumalarından (28 Kas 2026 ölçümü); paket satırları onların paketteki uzun karşılıklarına benzetilerek yazıldı.
# Kullanım: python3 tools/packs/qualityfixture.py; sonra iki dosyayı couchsubs-android/app/src/test/resources/fixtures/'a kopyala.
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
repo = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
import common as c

LINES = [
    ("Give me the keys.", "Anahtarları ver."),
    ("Get in the car, we're leaving.", "Arabaya bin, gidiyoruz."),
    # İki konuşmacının birleştiği uzun satır: yarım okuması bunun tamamını getirmemeli.
    ("Jason: Yeah, we been friends ever since. Boobie: Ah, I met him on the football field too.",
     "Jason: Evet, o zamandan beri arkadaşız. Boobie: Ah, ben de onunla futbol sahasında tanıştım."),
    ("It ain't rocket science. Yellow containers, SCOOP branding, pelican on the side. Can't miss 'em.",
     "Roket bilimi değil. Sarı konteynerler, SCOOP logosu, yanında pelikan. Gözden kaçmaz."),
    # Sonu kesik okunan satır: neredeyse tamamı okunduysa paketten gelir.
    ("Who cares if you were? I actually liked the guy.", "Haklıysan ne olmuş? Ben o adamı severdim."),
    # Tabela: satırları ayrı ayrı pakette.
    ("WARNING", "Uyarı"),
    ("THIS AREA.", "BU BÖLGE!"),
]

entries = {c.key(en): tr for en, tr in LINES}
english = {c.key(en): en for en, tr in LINES}
out = os.path.join(repo, "core/Tests/CouchSubsCoreTests/Fixtures/pack-quality.json.gz")
c.write_pack(out, "quality-test", "Quality Test", "CouchSubs denemesi", entries, {}, english)
T = dict(LINES)
cases = [
    ("Give me the keys.", T["Give me the keys."]),
    # Yarım okuma (uzun satırın üçte ikisinden az): paketin tam çevirisi değil, motor.
    ("Jason: been friends ever since.", None),
    ("SCOOP branding, pelican on the side. Can't miss'em.", None),
    # Neredeyse tam okuma: paketten.
    ("Who cares if you were? I actuâlly liked th", T["Who cares if you were? I actually liked the guy."]),
    # Büyük harfli tabela: bulunmayan satırlar köşe yazısı sayılıp atlanmaz, tabela motora gider.
    ("WARNING\nWE OPERATE\nCAMERAS IN\nTHIS AREA.", None),
    ("WE OPERATE\nCAMERAS IN F\nTHIS AREA.", None),
    # Tabelanın bütün satırları paketteyse paketten.
    ("WARNING\nTHIS AREA.", T["WARNING"] + "\n" + T["THIS AREA."]),
    # Altyazının yanındaki köşe yazısı yine atlanır.
    ("Get in the car, we're leaving.\nMirror Park", T["Get in the car, we're leaving."]),
]
json.dump({"warmUp": "Give me the keys.", "cases": [{"screen": s, "turkish": t} for s, t in cases]},
          open(os.path.join(repo, "core/Tests/CouchSubsCoreTests/Fixtures/pack-quality-cases.json"), "w"),
          ensure_ascii=False, indent=1)
print("satır", len(entries), "vaka", len(cases))
