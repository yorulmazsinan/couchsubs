# couchsubs-packs

Telefon uygulamasının (couchsubs-android) yeni ve güncellenen oyun paketlerini indirdiği Cloudflare Worker. Paketler
ücretsizdir; hesap, giriş ya da anahtar yoktur. Dosyalar R2'de durur. Uygulama, kendi içinde gelen paketlerin üstüne
buradaki daha yeni sürümleri koyar; masaüstü uygulamaları paketleri kendi içinde taşımaya devam eder.

| Yol | Ne verir | Önbellek |
|---|---|---|
| `GET /v1/packs` | `{"packs":[{id,title,version,sha256,size,entries}]}` (R2'deki `index.json`) | `public, max-age=3600` |
| `GET /v1/packs/:id` | `packs/<id>.json.gz`, `x-pack-sha256` ve `etag` başlıklarıyla; `If-None-Match` eşleşirse `304` | `public, max-age=86400` |

Kötüye kullanıma karşı IP başına (`CF-Connecting-IP`) saatte 60 paket indirme; aşılırsa `429` ve `retry-after`.
Sınır Worker örneği başına bellektedir (kaba kesme içindir); daha sıkı gerekirse Cloudflare'in Rate Limiting kuralı
eklenir. Uygulama indirdiği dosyayı listedeki SHA-256 ile doğrular, haftada bir yeniler.

## Kurulum (sahibin hesabıyla; henüz yapılmadı)

```sh
cd server/packs
npm install
npx wrangler r2 bucket create couchsubs-packs

# Paketleri ve listeyi yükle (sürüm: artan bir sayı; uygulama sürümü değişen paketi yeniden indirir)
node scripts/build-index.mjs ../../core/Sources/CouchSubsCore/Resources/packs 1 > index.json
for f in ../../core/Sources/CouchSubsCore/Resources/packs/*.json.gz; do
  id=$(basename "$f" .json.gz)
  sha=$(shasum -a 256 "$f" | cut -d' ' -f1)
  npx wrangler r2 object put "couchsubs-packs/packs/$id.json.gz" --file "$f" --content-type application/gzip \
    --custom-metadata "sha256=$sha" --remote
done
npx wrangler r2 object put couchsubs-packs/index.json --file index.json --content-type application/json --remote
npx wrangler deploy
```

Uygulamadaki adres `couchsubs-android/secrets.properties` içindeki `packs.url` ile verilir.

## Test

```sh
npm install
npm test          # vitest: liste, indirme, 304, geçersiz kimlik, IP sınırı
npm run typecheck
```
