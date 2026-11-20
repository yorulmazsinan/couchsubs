# couchsubs-packs

Telefon uygulamasının (couchsubs-android) yeni ve güncellenen oyun paketlerini indirdiği Cloudflare Worker. Paketler
ücretsizdir; hesap, giriş ya da anahtar yoktur. Dosyalar R2'de durur. Uygulama, kendi içinde gelen paketlerin üstüne
buradaki daha yeni sürümleri koyar; masaüstü uygulamaları paketleri kendi içinde taşımaya devam eder.

| Yol | Ne verir | Önbellek |
|---|---|---|
| `GET /v1/packs` | `{"packs":[{id,title,version,sha256,size,entries}]}` (R2'deki `index.json`; havuzdan üretilenlerde ayrıca `auto: true`, `titleId`) | `public, max-age=300` |
| `GET /v1/packs/:id` | `packs/<id>.json.gz`, `x-pack-sha256` ve `etag` başlıklarıyla; `If-None-Match` eşleşirse `304` | `public, no-cache` (ETag ile) |

Kötüye kullanıma karşı IP başına (`CF-Connecting-IP`) saatte 60 paket indirme; aşılırsa `429` ve `retry-after`.
Sınır Worker örneği başına bellektedir (kaba kesme içindir); daha sıkı gerekirse Cloudflare'in Rate Limiting kuralı
eklenir. Uygulama indirdiği dosyayı listedeki SHA-256 ile doğrular; açılışta, günde bir ve PS5'te yeni bir oyun
başlayınca listeye bakar.

## Havuzdan otomatik paketler

`server/pool` Worker'ı her gece (03:07–04:57 UTC, on dakikada bir adım) ortak havuzda en az iki oyuncunun okuduğu
satırlardan oyun başına `pool-<oyun kimliği>` paketini Claude ile (secret yoksa Workers AI) üretip bu kovaya yazar ve `index.json`'u
günceller (bkz. `server/pool/src/autopack.js`). Elle hazırlanmış paketlerin anahtarları `auto/known-keys.bin`'dedir;
yeni elle paket yüklenince `cd server/pool && node scripts/build-known.mjs > known-keys.bin` ile yeniden üretilip
`npx wrangler r2 object put couchsubs-packs/auto/known-keys.bin --file known-keys.bin --remote` ile yüklenir.
Elle paket `index.json`'a eklenirken var olan `pool-*` girdileri korunmalıdır (build-index.mjs yalnız klasördekileri yazar).

## Kurulum (sahibin hesabıyla; 2026-11-15'te yapıldı)

Yayın adresi: `https://couchsubs-packs.enmera.workers.dev` (R2 kovası `couchsubs-packs`, liste sürümü 1).

Yedek adres: `https://couchsubs-packs.enmeraapps.com` (aynı Worker; `wrangler.toml` `routes` içinde Custom Domain, DNS
kaydını ve sertifikayı Cloudflare açar; 2026-11-20). Bazı ağlar (DNS, reklam engelleyici, operatör) `*.workers.dev`'e
ulaşamıyor (#583): uygulamalar önce workers.dev'i dener, ağ hatası, zaman aşımı ya da 5xx olursa yedeğe geçer ve çalışan
adresi uygulama açıkken hatırlar; 4xx (404, 429) gerçek cevaptır, yedek denenmez. `couchsubs.enmeraapps.com` sitesi
Plesk'tedir, bu adresle ilgisi yoktur.

```sh
cd server/packs
npm install
npx wrangler r2 bucket create couchsubs-packs

# Paketleri ve listeyi yükle (sürüm: artan bir sayı; uygulama sürümü değişen paketi yeniden indirir)
node scripts/build-index.mjs ../../core/Sources/CouchSubsCore/Resources/packs 1 > index.json
for f in ../../core/Sources/CouchSubsCore/Resources/packs/*.json.gz; do
  id=$(basename "$f" .json.gz)
  npx wrangler r2 object put "couchsubs-packs/packs/$id.json.gz" --file "$f" --content-type application/gzip --remote
done
npx wrangler r2 object put couchsubs-packs/index.json --file index.json --content-type application/json --remote
npx wrangler deploy
```

wrangler'ın `r2 object put` komutu özel metadata (`sha256`) yazamıyor; bu yüzden `x-pack-sha256` başlığı şimdilik
gelmez. Uygulamalar indirdiği dosyayı listedeki (`index.json`) SHA-256 ile doğrular, başlığa bakmaz.

Uygulamalardaki adres: Android `couchsubs-android/secrets.properties` içindeki `packs.url`; iPhone/iPad
`couchsubs-ios/Config/App.xcconfig` `PACKS_API_BASE_URL`; Mac `mac/project.yml` `PACKS_API_BASE_URL`; Windows yayın
derlemesinde `-p:CouchSubsPacksUrl` (`.github/workflows/windows.yml`). Yedek adres sırasıyla `packs.fallbackUrl`,
`PACKS_API_FALLBACK_URL` (iPhone ve Mac) ve `-p:CouchSubsPacksFallbackUrl`.

## Test

```sh
npm install
npm test          # vitest: liste, indirme, 304, geçersiz kimlik, IP sınırı
npm run typecheck
```
