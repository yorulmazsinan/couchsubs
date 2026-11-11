# couchsubs-packs

Telefon uygulamasının (couchsubs-android) abonelere oyun paketi verdiği Cloudflare Worker. Paketler R2'de durur;
masaüstü uygulamaları paketleri kendi içinde taşımaya devam eder ve ücretsizdir.

| Yol | Erişim | Ne verir |
|---|---|---|
| `GET /v1/packs` | herkese açık | `{"packs":[{id,title,version,sha256,size,entries}]}` (R2'deki `index.json`) |
| `GET /v1/packs/:id` | Firebase ID token + RevenueCat `packs` hakkı | `packs/<id>.json.gz`, `x-pack-sha256` başlığıyla |

Yanıtlar: `401` token yok/geçersiz, `403 subscription_required`, `503 entitlement_unavailable` (RevenueCat'e
ulaşılamadı; `retry-after: 60`), `404` paket yok.

Doğrulama: Firebase Admin SDK olmadan, WebCrypto ile ([Firebase belgesi](https://firebase.google.com/docs/auth/admin/verify-id-tokens#verify_id_tokens_using_a_third-party_jwt_library)):
RS256 imza Google'ın securetoken anahtarlarıyla (JWK adresi, `Cache-Control` süresince önbellekte), `aud` = proje kimliği,
`iss` = `https://securetoken.google.com/<proje>`, `exp`/`iat`/`auth_time`, `sub`. Abonelik: RevenueCat REST v1
`GET /v1/subscribers/{uid}` (uygulama RevenueCat'i Firebase UID'siyle yapılandırır), `entitlements.packs.expires_date`
boş ya da gelecekte (ödeme sorununda `grace_period_expires_date` de sayılır).

## Kurulum (sahibin hesabıyla; henüz yapılmadı)

```sh
cd server/packs
npm install
npx wrangler r2 bucket create couchsubs-packs
# wrangler.toml: FIREBASE_PROJECT_ID'yi Firebase projesinin kimliğiyle değiştirin
npx wrangler secret put REVENUECAT_SECRET        # RevenueCat gizli anahtarı (sk_…)

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
npm test          # vitest: token doğrulama (sahte RSA anahtarı), RevenueCat eşlemesi, yollar
npm run typecheck
```
