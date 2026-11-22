# couchsubs-packs

Uygulamaların (Windows, Mac, iPhone/iPad, Android) yeni ve güncellenen oyun paketlerini indirdiği Cloudflare Worker.
Paketler ücretsizdir, kullanıcı hesabı ya da giriş yoktur; ama yalnız uygulama içinden alınır: her istek uygulamaya
derlemede gömülen paylaşılan sırla imzalanır (aşağıda "İstek imzası"). Dosyalar R2'de durur. Uygulama, kendi içinde
gelen paketlerin üstüne buradaki daha yeni sürümleri koyar.

| Yol | Ne verir | Önbellek |
|---|---|---|
| `GET /v1/packs` | `{"packs":[{id,title,version,sha256,size,entries}]}` (R2'deki `index.json`; havuzdan üretilenlerde ayrıca `auto: true`, `titleId`) | `public, max-age=300` |
| `GET /v1/packs/:id` | `packs/<id>.json.gz`, `x-pack-sha256` ve `etag` başlıklarıyla; `If-None-Match` eşleşirse `304` | `public, no-cache` (ETag ile) |

Kötüye kullanıma karşı IP başına (`CF-Connecting-IP`) saatte 30 paket indirme; aşılırsa `429` ve `retry-after`.
Yanıtlarda CORS başlığı yoktur: tarayıcıdaki başka bir site paketleri okuyamaz.
Sınır Worker örneği başına bellektedir (kaba kesme içindir); daha sıkı gerekirse Cloudflare'in Rate Limiting kuralı
eklenir. Uygulama indirdiği dosyayı listedeki SHA-256 ile doğrular; açılışta, günde bir ve PS5'te yeni bir oyun
başlayınca listeye bakar.

## İstek imzası

Her istekte iki başlık:

| Başlık | Değer |
|---|---|
| `x-couchsubs-time` | unix zamanı (saniye) |
| `x-couchsubs-signature` | `hex(HMAC-SHA256(APP_SECRET, "GET\n" + yol + "\n" + zaman))`, yol ör. `/v1/packs/gta-6` |

Zaman sunucu saatinden en çok ±5 dakika sapabilir; yanlış, eksik ya da süresi geçmiş imza `403`. Geçiş: imzasız
istekler (eski uygulama sürümleri) **2026-11-29T23:59Z**'ye kadar kabul edilip loglanır (`{"unsigned":"<yol>"}`,
`npx wrangler tail`), sonra `403` (`UNSIGNED_UNTIL`, `src/index.ts`).

İstemciler: Mac ve iPhone/iPad `core/Sources/CouchSubsCore/PackSigning.swift` (Info.plist `CSPacksAppSecret` ←
derleme ayarı `PACKS_APP_SECRET`), Windows `windows/src/CouchSubs.Core/PackSigning.cs` (`-p:CouchSubsPacksSecret`),
Android `couchsubs-android/.../packs/PackSigning.kt` (`BuildConfig.PACKS_APP_SECRET` ← `packs.app.secret` ya da
ortamdaki `PACKS_APP_SECRET`). Dördü aynı test vektörünü sınar. Sır depoda değildir: CI'da GitHub sırrı
`PACKS_APP_SECRET` (release.yml → windows.yml ve package-mac.sh), yerelde `~/.config/couchsubs/packs.env`
(`PACKS_APP_SECRET=…`, chmod 600; package-mac.sh, release-appstore.sh ve Android Gradle okur). Sır yoksa (yerel
geliştirici derlemesi) uygulama paket indirmeyi hiç başlatmaz; uygulamayla gelen paketler çalışır.

Sırrı kurmak (değer ekrana basılmaz; packs.env'de yoksa üretir, Worker'a, GitHub'a ve iCloud yedeğine koyar):

```sh
server/packs/scripts/setup-app-secret.sh
npx wrangler deploy   # server/packs içinde
```

## Uygulamayla gelen paketler ve katkı havuzu (özel)

Paket dosyaları depoda değildir (2026-11-22'den beri; git geçmişinde eski sürümleri durur). Kovadaki önekler:

| Önek | Ne | Kim okur |
|---|---|---|
| `packs/`, `index.json` | Uygulamaların indirdiği paketler ve liste | bu Worker (imzalı istek) |
| `bundled/` | Uygulamayla gelen paketler (`*.json.gz`) | derleme: `scripts/fetch-packs.py` → `core/Sources/CouchSubsCore/Resources/packs/` |
| `contrib/` | GTA topluluk katkı havuzu ve notu | `scripts/fetch-packs.py --contrib` → `tools/packs/katki/` |
| `auto/` | Havuzdan üretim için bilinen anahtarlar | `server/pool` |

`fetch-packs.py` S3 uyumlu API ile okur (yalnız Python standart kitaplığı). Erişim: ortamdaki
`PACKS_R2_ACCESS_KEY_ID`, `PACKS_R2_SECRET_ACCESS_KEY`, `PACKS_R2_ENDPOINT` (`https://<hesap kimliği>.r2.cloudflarestorage.com`)
ya da `~/.config/couchsubs/packs.env` (aynı adlar ve `PACKS_APP_SECRET`; chmod 600, depoya girmez, yedeği iCloud
Drive/CouchSubs-anahtarlar/packs.env). CI'da aynı adlı GitHub sırları: pr-tests.yml (Windows, Swift, Android),
android-app.yml, windows.yml (etikette zorunlu), release.yml (Mac, zorunlu); package-mac.sh ve release-appstore.sh
(`--unsigned` dışında) ve Android `bundleRelease`/`assembleRelease` paket yoksa durur. Erişim yoksa (dış katkıcı PR'ı)
paketler inmez, uygulama paketsiz derlenir ve gerçek paketlere dayanan testler kendini atlar (Swift `XCTSkip`, Windows
`RealPackFact`, Android `couchsubs.packs` özelliği verilmez, Node `skip`).

R2 erişim anahtarı: Cloudflare › R2 › Manage API tokens › Create Account API token, izin "Object Read & Write", yalnız
`couchsubs-packs` kovası. Access Key ID ve Secret Access Key değerleri ekrana yazılmadan `gh secret set` ile
(`PACKS_R2_ACCESS_KEY_ID`, `PACKS_R2_SECRET_ACCESS_KEY`, `PACKS_R2_ENDPOINT`) ve packs.env'e konur.

Yeni ya da güncellenen elle paket: `bundled/<id>.json.gz` ve (uygulamalara da gitsin diye) `packs/<id>.json.gz` olarak
yüklenir, `index.json` güncellenir (var olan `pool-*` girdileri korunur):

```sh
npx wrangler r2 object put couchsubs-packs/bundled/<id>.json.gz --file <id>.json.gz --content-type application/gzip --remote
```

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

# Paketleri ve listeyi yükle (sürüm: artan bir sayı; uygulama sürümü değişen paketi yeniden indirir). Paketler önce
# python3 ../../scripts/fetch-packs.py ile indirilir (depoda değil).
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
npm test          # vitest: liste, indirme, 304, geçersiz kimlik, IP sınırı, imza ve geçiş
npm run typecheck
```
