# TV uygulaması: ince kabuk

TV uygulaması (LG webOS, Samsung Tizen, Android TV) 0.9.72'den beri iki parçadır:

- **Kabuk** — TV'de kurulu kalan, nadiren değişen kısım: `platform.js` (HDMI/AVPlay/TVWindow, webOS luna çağrıları,
  Android TV köprüsü ve katman servisi), `config.js`, `tv-webos/shell.js` ve paketle gelen **yedek sayfa**.
- **Sayfa** — `index.html`'in gövdesi, `style.css`, `i18n.js`, `app.js`: altyazı, telefon balonları, stilli bloklar,
  bilgi paneli, eşleştirme ve bağlantı. Eşleşmiş bilgisayar ya da telefon daha yenisini sunuyorsa TV onu kullanır.

Amaç: masaüstü ya da telefon uygulaması güncellenince TV'deki sayfa da güncel olsun; TV'ye yeniden kurulum ve LG'de
geliştirici modu gerekmesin. (LG'de geliştirici modunun süresi dolunca TV uygulaması eski kalıyor, yeni olayları
tanımadığı için altyazı göstermiyordu.)

## Sunucu: `/tv/app`

Mac/iPhone (`core/.../TVAppBundle.swift`), Windows (`TvAppBundle.cs`) ve Android telefon (`TvAppBundle.kt`) aynı
dosyaları aynı biçimde sunar. Dosyalar uygulamanın içindeki `tv-webos` kopyasıdır (Mac/iPhone: uygulama paketinde
`tv-webos` klasörü, `mac/project.yml`, `couchsubs-ios/project.yml`; Windows: CouchSubs.Core'a gömülü; Android:
`assets/tv-webos`).

| İstek | Yanıt |
| --- | --- |
| `GET /tv/app/manifest?k=<anahtar>` | İmzalı liste (JSON), `Cache-Control: no-store` |
| `GET /tv/app/<sürüm>/<dosya>?k=<anahtar>` | Dosya, `Content-Length`, `Cache-Control: private, max-age=31536000, immutable` |

- Anahtar (`k`) eşleşme anahtarıdır; eski TV'lere tanınan anahtarsız geçiş `/tv/app`'e uygulanmaz (401). Sunucu
  zaten yalnız yerel ağdan bağlantı kabul eder.
- Sürüm ve kabuk arayüzü `app.js`'ten okunur: `var APP_VERSION = '…';` ve `var SHELL_API = <n>;`. İkisinden biri
  yoksa (kabuktan önceki sayfa) sunucu `/tv/app` için 404 döner.
- Yalnız listedeki dört dosya ve yalnız kendi sürümü verilir; başka yol 404.

Liste:

```json
{"files":[{"path":"index.html","sha256":"…","size":5123}, … ],"format":1,"hmac":"…","shellApi":1,"version":"0.9.72"}
```

İmzalanan metin (UTF-8), her satır `\n` ile biter:

```
couchsubs-tv-app/1
<sürüm>
<shellApi>
index.html <bayt> <sha256>
style.css <bayt> <sha256>
i18n.js <bayt> <sha256>
app.js <bayt> <sha256>
```

`hmac = HMAC-SHA256(anahtar, metin)` (küçük harf onaltılık). Ortak deneme dosyası:
`core/Tests/CouchSubsCoreTests/Fixtures/tv-app-bundle.json` (Android kopyası `fixtures/`; parity-check aynı olmasını
denetler).

## Kabuk: `shell.js`

Açılışta (ağı beklemeden):

1. `localStorage['couchsubs.shell.page']`'de saklanmış, doğrulanmış bir sayfa var ve paketteki yedekten yeniyse,
   arayüzü bu kabukta varsa (`shellApi <= SHELL_API`) ve daha önce bozuk sayılmadıysa onu başlatır: `style.css`
   bağlantısı yerine `<style>`, gövde uzak `index.html`'in gövdesiyle değiştirilir (`#video-host` kabuğunki kalır,
   Samsung'un `panel-icon.png` adı korunur), `i18n.js` ve `app.js` satır içi `<script>` olarak eklenir.
   `script src` ya da `iframe` ile sunucudan doğrudan yüklenmez: kod doğrulanmadan çalışmaz.
2. Yoksa paketteki `i18n.js` ve `app.js`'i ayrıştırma sırasında yazar (eski davranışın aynısı).

Sayfa açılışını bitirince `COUCHSUBS_SHELL.started()` çağırır. Uzak sayfa çağırmazsa (sözdizimi hatası, eski
tarayıcıda olmayan bir çağrı, açılışta hata) sürümü `couchsubs.shell.bad`'e yazılır, saklanan sayfa silinir ve sayfa
yeniden yüklenip yedekle açılır; o sürüm bir daha indirilmez.

Güncelleme: sayfa bilgisayara/telefona bağlanınca (`EventSource` açıldı) `COUCHSUBS_SHELL.connected(adres, anahtar)`
çağırır. Kabuk:

- anahtarsız ya da yerel ağ IP'si olmayan adresi sormaz (özel IPv4, 169.254, 100.64/10, 127; fc00::/7, fe80::/10;
  ad kabul edilmez),
- listeyi indirir, biçimini ve HMAC'ini anahtarla doğrular (sabit süreli karşılaştırma),
- sürüm çalışandan yeni değilse, `shellApi` bu kabuktan yeniyse ya da sürüm bozuk sayıldıysa durur,
- dört dosyayı sürümlü adresten indirir, her birinin bayt boyunu ve SHA-256'sını listeyle karşılaştırır,
- hepsi tutarsa tek kayıt olarak saklar ve sayfayı yeniden yükler (bir güncellemede bir kez; aynı sürüm için yeniden
  yükleme döngüsü olmaz).

Aynı sunucu 10 dakikada bir kereden sık sorulmaz. SHA-256/HMAC saf ES5 ile yazılmıştır (eski webOS/Tizen'de
`crypto.subtle` güvenli olmayan bağlamda yoktur).

## ShellAPI v1

Sayfanın platforma eriştiği yollar yalnız bunlardır:

- `COUCHSUBS_SHELL`: `api` (1), `version` (kabuk sürümü), `platform`, `config`, `page()` (`{version, source}`),
  `started()`, `connected(adres, anahtar)`, `status()` (bilgi panelinin tanı satırı).
- `COUCHSUBS_SHELL.platform` = platform.js'in `COUCHSUBS_PLATFORM` nesnesi: `backKey`, `init`, `launchParams`,
  `onRelaunch`, `showHdmi`, `findConsolePort`, `localAddress`, `exit`; platforma göre isteğe bağlı olanlar (sayfa
  varlığını denetler): `noPictureHelp`, `hasPicture`, `diagnostics`, `inputLabel`, `pickPort`, `chooseInput`,
  `closeWhenHidden`, `speechElement`, `subtitleBand`, `sourceSwitchTip`, `pictureDiagnostics`, `pictureModes`,
  `pictureModeList`, `togglePicture`, `videoResolution`.
- `window.COUCHSUBS_CONFIG`, `window.COUCHSUBS_ZOOM`; localStorage'daki `couchsubs.*` kayıtları (sunucu, anahtarlar).

Kural: sayfa yeni bir platform çağrısını **isteğe bağlı** kullanabilir (yoksa eski davranış). Sayfanın şart koştuğu
bir çağrı ya da kabukta değişiklik gerekiyorsa `shell.js`'teki `SHELL_API` ve `app.js`'teki `SHELL_API` birlikte
artırılır; eski kabuklu TV'ler o sayfayı yüklemez, yedeklerinde kalır ve bilgisayar/telefon "TV uygulamasını güncelle"
der (akıştaki `v` yedeğin sürümüdür).

Gövde işaretlemesi uzak sayfadan gelir; `<head>` (görünüm, `platform.js`, Samsung'un `webapis.js`'i) kabuğundur.

## Sürüm

- Kabuğun sürümü (`shell.js` `SHELL_VERSION`) TV paketinin sürümüdür: `appinfo.json`, `tv-tizen/config.xml`,
  `tv-android/app/build.gradle` ve paketteki `app.js` `APP_VERSION` ile aynıdır (`scripts/tv-shell.test.js`).
- Sayfa sonraki sürümlerde kabuktan bağımsız artabilir: yalnız sayfa değişen bir sürümde TV yeniden kurulmaz.

## Kalan sınırlar

- Anahtar yerel ağda düz HTTP ile gider (bugünkü `/events?k=` gibi). Aynı ağı dinleyebilen biri anahtarı görüp imzalı
  sayfa üretebilir; imza, anahtarı bilmeyen bir cihazın (ör. DHCP ile aynı adresi alan başka cihaz) kod vermesini önler.
- Uzak sayfa açılışı bitirdikten sonra çalışırken bozulursa kabuk bunu anlamaz; düzeltme yeni sürümle gelir.
- Kabuktan önceki TV uygulamaları (0.9.71 ve öncesi) kendini güncellemez: bir kez daha kurulmaları gerekir.
- Güncelleme bağlantı kurulduktan sonra iner ve sayfayı bir kez yeniden açar (görüntü bir an kesilir).

## Testler

- `node --test scripts/tv-shell.test.js` — akış, red nedenleri (HMAC, SHA-256, arayüz, yerel olmayan adres), bozuk
  sayfada yedeğe düşme, sürüm tutarlılığı; gerçek Chromium'da gerçek sayfanın güncellenmesi ve yedeğe düşmesi.
- `scripts/tv-es5.test.js` — `shell.js` ES5 ile ayrışıyor, eski tarayıcıda olmayan API kullanmıyor.
- Sunucu: `TVAppBundleTests` (Mac/iPhone), `TvAppBundleTests` (Windows), `TvAppBundleTest` (Android).
