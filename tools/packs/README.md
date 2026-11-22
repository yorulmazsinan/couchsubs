# Oyun paketi yapım araçları

Marvel's Spider-Man 2 paketi bu betiklerle yapıldı (2026-11-12).
Akış: `extract.py` (herkese açık kaynaktan İngilizce satırlar) → `poolfix.py` (ortak havuzdaki OCR satırlarını
düzeltme) → `translate.py` (Claude ile cümle cümle çeviri) → `review.py` ve `fixcase.py` (denetim) → `build.py`
(biçim 2 paket: SHA-256 anahtarlar, parçalar, bulanık imzalar) → `coverage.py` (havuz satırlarıyla kapsam ölçümü).

Anthropic anahtarı `~/.config/couchsubs/anthropic-key` dosyasından okunur; depoya konmaz. Harcama `ledger.jsonl`'a
yazılır. Kaynaklar ve lisansları THIRD-PARTY-NOTICES.md'de.

`sentences.py`: çok cümleli satırların cümlelerini, Türkçesi aynı sayıda cümleye bölünüyorsa API'siz parça olarak ekler
(GTA V'te ~51 bin, RDR2'de ~47 bin yeni parça; paketler ~3 MB büyür). Henüz gömülü paketlere uygulanmadı.

## Havuzdan otomatik paket (sunucuda, her gece)

`server/pool` Worker'ı (`src/autopack.js`) bu dosyadaki temizlik kurallarıyla her gece 03:02–05:57 UTC arasında (beş dakikada bir) kendisi
paket üretir: en az 2 kurulumun okuduğu satırlar, oyun başına en az 300 temiz satır olunca `pool-<oyun kimliği>` paketi
(Worker'da `ANTHROPIC_API_KEY` secret'ı varsa Claude `claude-opus-5-5` Message Batches ile, yoksa Workers AI `@cf/zai-org/glm-5.3-flash`),
R2'ye ve `index.json`'a. Elle paket (aşağıdaki akış) her zaman öncelikli:
elle paket yüklenince `server/pool/scripts/build-known.mjs` ile `auto/known-keys.bin` yenilenir, otomatik paket o satırları
bırakır. Elle akış daha iyi çeviri (Claude + sözlük + denetim) gerektiğinde kullanılır.

Dev oyunlar (yüz binlerce satır) anahtar imleciyle (installs azalan, key artan) sayfa sayfa gezilir. Claude ile bir
tetiklemede 1000 satır tek Message Batch olarak gider (%50 indirim), sonuç sonraki tetiklemelerde toplanır; bir oyun gecede
en çok 4000, tüm oyunlar 5500 satır (`CLAUDE_LIMITS`, ~2,6 $), toplanan yanıtların usage'ına göre gecede en çok 3 $
(`NIGHT_BUDGET_USD`; gecenin harcaması R2 `auto/state.json` içinde `usd`). Model yazı tanıma çöpü satırı boş döndürürse
satır kalıcı atlanır. Workers AI ile 200 / 2000 / 5000 (`NIGHTLY_LIMIT`, nöron payı). Hesaplar `autopack.js`'te. Çevrilen oyunun paketi gecenin sonunda
(ya da payı dolunca) kurulur ve sürümü artar: `pool-<oyun>` her gece büyür.

## Havuzdan hızlı paket (`poolpack.py`)

Herkese açık bir İngilizce döküm yokken (yeni çıkan oyun) paket, oyuncuların ekranda okuyup ortak havuza gönderdiği
satırlardan yapılır. Uygulamalar her satırla PS5'te o an çalışan oyunun kimliğini (`titleId`, ör. `PPSA01234`) ve adını
gönderir (server/pool, `migrate-2026-11-14-game.sql`'den sonra tutulur), böylece bir oyunun satırları ayrı alınır.

- `poolpack.py titles` · havuzda görülen oyun kimliklerini listeleyecek **okuma** komutunu yazar.
- `poolpack.py query --title … [--game …]` · o oyunun satırlarını alacak **okuma** komutunu yazar; çalıştırmaz.
- `poolpack.py plan <dışa aktarım.json> --id <paket>` · temizler (Türkçe, OCR çöpü, kısa parça, zaten pakette olan),
  aynı anahtardakileri birleştirir, sıklığa göre sıralar, `<paket>.rows.jsonl` yazar ve çeviri maliyetini tahmin eder.
  **Kuru çalıştırmadır**: ağ ve API yok.
- Çeviri yalnız `--translate --limit N` ile yapılır (en sık N satır; `llm.py`'deki model, harcama `ledger.jsonl`'a).
  Çıktı `<paket>.tr.json`, `translate.py` çıktısıyla aynı biçimde; `build.py` doğrudan okur.
- `glossary/gta6.json` · GTA V paketinden API'siz çıkarılmış başlangıç terim ve hitap sözlüğü (`gta6glossary.py` yeniden
  üretir); `plan --translate` bunu modele verir. Denemeler: `python3 -m unittest tools/packs/test_poolpack.py`.

### GTA 6 günü (19 Kasım 2026)

Önceden, Sinan Bey'in onayıyla bir kez: havuz geçişi (`server/pool/migrate-2026-11-14-game.sql`, sonra Worker
yayını) ve oyun bilgisini gönderen uygulama sürümü. Paket sunucusu (server/packs) kurulmadıysa yeni paket yalnız uygulama
güncellemesiyle gider; kuruluysa paket R2'ye yüklenince Mac, Windows, iPhone ve Android bir hafta içinde kendisi indirir.

1. Oyun çıkıp birkaç saat oynanınca kimliği bul:
   `python3 tools/packs/poolpack.py titles` → yazdığı komutu çalıştır (yalnız okur). GTA 6 satırının `title_id`'si alınır.
2. Satırları al: `python3 tools/packs/poolpack.py query --title PPSAxxxxx --min 2 --out /tmp/gta6-pool.json`
   → yazdığı komutu çalıştır. İlk gün az kurulum varsa `--min 1`.
3. Kuru plan: `python3 tools/packs/poolpack.py plan /tmp/gta6-pool.json --id gta-6 --out-dir /tmp/gta6`
   → temiz satır sayısı, en sık satırlar ve tahmini maliyet yazılır. Sözlüğü (`glossary/gta6.json`) gözden geçir.
4. Onaydan sonra çeviri: `… plan /tmp/gta6-pool.json --id gta-6 --out-dir /tmp/gta6 --translate --limit 1000`.
5. Denetim: `python3 tools/packs/fixcase.py core/Sources/CouchSubsCore/Resources/packs /tmp/gta6/gta-6.tr.json` ve en
   sık 100 satıra göz at (`review.py` şu an eksik `translate_rules` modülünü istiyor; o dosya eklenene dek kullanılamaz).
6. Paket: `python3 tools/packs/build.py /tmp/gta6/gta-6.tr.json core/Sources/CouchSubsCore/Resources/packs/gta-6.json.gz
   gta-6 "Grand Theft Auto VI" "CouchSubs havuzu + Claude" core/Sources/CouchSubsCore/Resources/packs`
7. Dağıtım: uygulama sürümüne koy; paket sunucusu varsa `server/packs/README.md`'deki gibi R2'ye yükle ve index.json'u
   yenile (sürüm numarasını artır).
8. Çevrilen satırları havuzda işaretle ki sonraki turda yeniden çevrilmesin (yönetici anahtarıyla, yazma yapar):
   `curl -X POST -H "authorization: Bearer $ADMIN_TOKEN" --data @/tmp/gta6/gta-6.pool-keys.json
   https://couchsubs-pool.enmera.workers.dev/v1/exported`
   Gün içinde yeni satırlar biriktikçe 2-8 tekrarlanır; `--limit` her turda küçük tutulur.
