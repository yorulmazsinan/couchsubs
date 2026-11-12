# App Store sürümleri: iPhone/iPad ve Mac App Store

İki mağaza sürümü de App Store Connect'teki **tek kayıttadır**: "CouchSubs", Apple ID 6833558947, paket kimliği
`com.couchsubs.ios`, takım `79N3CT6T46` (Enmera). Kayda macOS platformu eklendi; Mac App Store sürümü de aynı kimliği
kullanır (ortak satın alma, "universal purchase"). Uygulama ücretsizdir.

GitHub'dan dağıtılan Mac uygulaması (DMG, `com.couchsubs.mac`, Sparkle güncellemesi, sandbox yok) **olduğu gibi kalır**:
`mac/project.yml`'deki `CouchSubs` hedefi, `scripts/package-mac.sh` ve `scripts/release-mac.sh` değişmedi.

| | iPhone/iPad | Mac App Store | Mac (GitHub, DMG) |
|---|---|---|---|
| Proje | `couchsubs-ios/` | `mac/` › `CouchSubsAppStore` hedefi | `mac/` › `CouchSubs` hedefi |
| Kimlik | `com.couchsubs.ios` | `com.couchsubs.ios` | `com.couchsubs.mac` |
| Sandbox | iOS | App Sandbox açık | yok |
| Güncelleme | App Store | App Store | Sparkle (GitHub) |
| Derleme bayrağı | — | `APP_STORE` | — |
| En eski sistem | iOS 16 | macOS 13 (Apple Silicon ve Intel) | macOS 13 |

## Arşivleme ve yükleme

```sh
scripts/release-appstore.sh ios <yapı>      # iPhone/iPad
scripts/release-appstore.sh mac <yapı>      # Mac App Store
scripts/release-appstore.sh mac <yapı> --no-upload   # yüklemeden dist/appstore/export-mac'e
```

Ağır iş olduğu için `~/Projeler/Web/enmera/ekip/heavy-job.sh` ile çalıştırılır. Betik arşivi
`dist/appstore/CouchSubs-<platform>-<sürüm>-<yapı>.xcarchive` olarak yazar, sonra `scripts/appstore/ExportOptions.plist`
ile (`app-store-connect`, `destination: upload`, `testFlightInternalTestingOnly`) App Store Connect'e yükler. Yükleme
yalnız **iç TestFlight** içindir; dış test, inceleme ve yayın App Store Connect'te elle açılır.

- **Yapı numarası** (`CFBundleVersion`) her platformda bir öncekinden büyük olmalı; iPhone ve Mac numaraları ayrı
  sayılır. İlk yüklemeler 1'dir. Sürüm (`CFBundleShortVersionString`) son `v*` etiketinin sayı kısmıdır
  (`v0.1.0-beta.31` → `0.1.0`; App Store harf kabul etmez), `APP_VERSION` ile değişir.
- **İmza** otomatiktir (`-allowProvisioningUpdates`). xcodebuild Apple hesabına Xcode › Settings › Accounts'taki
  Enmera hesabıyla erişir; hesap yoksa arşiv, dışa aktarma ve yükleme "No Accounts" / "No signing certificate" hatasıyla
  durur. Mac App Store paketi için "Mac Installer Distribution" (3rd Party Mac Developer Installer) sertifikası da
  gerekir (anahtarlıkta yok); hesap açıkken `-allowProvisioningUpdates` ile Xcode'un oluşturması beklenir, oluşturamazsa
  developer.apple.com › Certificates'tan elle alınır. Bu henüz denenemedi.
- **İhracat uyumu**: `ITSAppUsesNonExemptEncryption` bilerek yazılmadı. Her yapı yüklendikten sonra App Store
  Connect › TestFlight'ta şifreleme sorusu yanıtlanır (Remote Play OpenSSL ile şifreli; bkz. Riskler).

Mac App Store arşivinden önce gerekenler (dist/ gitignore'dadır):

| Dosya | Nasıl |
|---|---|
| `third-party/build/CChiaki.xcframework` macOS dilimi, arm64 + x86_64 | `scripts/build-chiaki-macos.sh` |
| `third-party/build/CChiaki.xcframework` iOS dilimleri | `scripts/build-chiaki-ios.sh` |
| `dist/tv-helper/couchsubs-tv-helper`, evrensel | `scripts/build-tv-helper.sh`, **Microsoft'un .NET 10 SDK'sıyla** (Homebrew'un .NET'i Homebrew kitaplıklarına bağlı dosya üretir; betik reddeder) |
| `dist/tts/pocket-tts`, evrensel | `scripts/fetch-pocket-tts.sh mac` |
| `dist/tv-app/` (ipk, wgt, apk) | `scripts/package-tv.sh`, `scripts/package-tizen.sh`, `scripts/bundle-android-apk.sh <apk>` |

Betik arşivden sonra denetler: uygulama sandbox'lı mı, gömülü programlar yalnız `app-sandbox` + `inherit` ile mi
imzalı, Sparkle pakete girmiş mi.

## Mac App Store sürümü: sandbox farkları

`CouchSubsAppStore` hedefi DMG sürümüyle aynı kaynakları derler. Farklar:

- **Sparkle yok.** Paket hedefe bağlanmaz; `CouchSubsApp.swift`'te güncelleyici ve "Check for updates…" menüsü
  `#if !APP_STORE` içinde. Info.plist'te `SU*` anahtarları yok (`mac/AppStore/Info.plist`).
- **Yetkiler** (`mac/AppStore/CouchSubs.entitlements`): `app-sandbox`, `network.client` (PS5, PSN girişi, TV, çeviri
  hizmetleri, paketler, dublaj modeli indirme), `network.server` (8787'deki altyazı sunucusu: TV uygulaması ve OBS;
  Remote Play'in UDP portları; Samsung girişinin `localhost` dönüşü). Dosya seçme ya da başka yetki gerekmedi.
- **Gömülü programlar** (`couchsubs-tv-helper`, `pocket-tts`) derlemede `mac/AppStore/Helper.entitlements`
  (`app-sandbox` + `inherit`) ile yeniden imzalanır; uygulamanın sandbox'ını ve yetkilerini miras alırlar.
- **Veriler kapsayıcıda**: ayarlar, dublaj modeli, TV kurulum yardımcısının anahtarları ve günlükler
  `~/Library/Containers/com.couchsubs.ios/Data/...` altındadır. Hata iletilerindeki günlük yolu bunu gösterir
  (`RemotePlayLog.userPath`). DMG sürümünün ayarları ve PS5 kaydı taşınmaz; App Store sürümünde kurulum baştan yapılır.
- **Anahtarlık** aynı hizmet adını (`com.couchsubs.mac`) kullanır; kayıtlar uygulamaya özel erişim listesiyle tutulur.
- 8787 doluysa (iki sürüm aynı anda açıksa) sunucu boş bir porta geçer; bu zaten DMG sürümündeki davranış.

### Özellikler sandbox'ta

`mac/CouchSubsAppStoreTests/SandboxTests.swift` uygulamanın içinde, sandbox'lı çalışır (`xcodebuild -scheme
CouchSubsAppStore test`; yerelde ad-hoc imzayla: `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=`).

| Özellik | Sandbox'ta | Nasıl doğrulandı |
|---|---|---|
| PS5 Remote Play, PSN giriş sayfası (WKWebView) | Çalışır (ağ yetkileri) | Derleme; gerçek PS5 ile denenmedi |
| Yazı tanıma (Vision), Apple çevirisi, DeepL/yapay zekâ | Çalışır, yetki istemez | Derleme |
| TV bulma (SSDP), eşleşme (SSAP, Samsung WebSocket) | Çalışır (`network.client/server`) | Derleme; gerçek TV ile denenmedi |
| Altyazı sunucusu, OBS katmanı | Çalışır | Test: sunucu sandbox'ta dinliyor ve yanıt veriyor |
| Türkçe dublaj (pocket-tts) | Çalışır | Test: program sandbox'ı miras alarak açılıyor |
| TV uygulamasını kurma: Samsung, Android TV (.NET yardımcısı) | Çalışır | Test: yardımcı sandbox'ta açılıyor, `self-test` geçiyor |
| TV uygulamasını kurma: LG (`/usr/bin/ssh`, `ssh-keygen`) | Çalışır | Test: ssh açılıp bağlanmayı deniyor (engellenmiyor), ssh-keygen kapsayıcıdaki anahtar dosyasını yazıyor |

Sandbox hiçbir özelliği engellemedi. Yine de gerçek TV ile kurulum denenmedi ve App Review'ın sistem programı
(`/usr/bin/ssh`) çalıştırmaya bakışı belirsiz. Bu yüzden App Store sürümünde TV kurulumu "kurulamadı" hatasıyla biterse
ileti şunu da söyler: "Mac App Store sürümü TV uygulamasını kuramıyorsa, TV uygulamasını bir kez CouchSubs'ın GitHub
(DMG) sürümüyle kurun. Sonrasında bu sürüm yeter." (iPhone uygulamasındaki yaklaşım, bkz. `docs/ios-plan.md` §6).
İnceleme sistem programı çalıştırmayı reddederse LG kurulumu App Store sürümünde kapatılır ve bu ileti doğrudan
gösterilir.

## iPhone/iPad sürümü

Ayrıntılar `docs/ios-plan.md`'de. App Store için yapılanlar:

- Simge saydamlıksız, tam dolu 1024'lük kare (`scripts/make-icons.swift` üretir); App Store alfa kanallı simgeyi
  reddeder.
- `com.apple.developer.networking.multicast` yetkisi projede. Apple onaylamadıysa otomatik imza bu yetkiyle profil
  üretemez ("Entitlement com.apple.developer.networking.multicast requires approval from Apple"); o zaman yetki onaya
  kadar `couchsubs-ios/project.yml`'den çıkarılır (PS5/TV adresi elle yazılır).
- `Config/Secrets.xcconfig` ve `GoogleService-Info.plist` yoksa Firebase, Meta ve paket sunucusu kapalı derlenir;
  AdMob Google'ın deneme kimliğiyle gelir, reklam Remote Config ile zaten kapalı.

## Durum (2026-11-12)

Hiçbir yapı yüklenmedi; ikisinde de engel Apple hesabı:

- **iOS**: arşiv imza adımında durdu: "No Accounts: Add a new account in Accounts settings." ve multicast yetkisi
  onaysız ("Entitlement com.apple.developer.networking.multicast requires approval from Apple"). İmzasız Release arşivi
  derleniyor (`release-appstore.sh ios 1 --unsigned`).
- **Mac App Store**: arşiv Apple Development kimliğiyle imzalandı ve sandbox denetimlerinden geçti
  (`dist/appstore/CouchSubs-mac-0.1.0-1.xcarchive`, evrensel, Sparkle yok). Yükleme durdu: "exportArchive Failed to
  Use Accounts. App Store Connect access for “79N3CT6T46” is required."

Yapılacak: Xcode › Settings › Accounts'a Enmera takımına (App Manager ya da Admin) erişimi olan Apple hesabıyla girmek;
iOS için multicast onayını beklemek ya da yetkiyi şimdilik çıkarmak. Sonra:

```sh
~/Projeler/Web/enmera/ekip/heavy-job.sh scripts/release-appstore.sh mac 1
~/Projeler/Web/enmera/ekip/heavy-job.sh scripts/release-appstore.sh ios 1
```

Not: Xcode 27'nin `lipo`'su `-verify_arch`'ta tek mimari kabul ediyor; `package-mac.sh` ve bu betik mimarileri ayrı
ayrı denetler (eskiden `package-mac.sh` evrensel kütüphaneyi her seferinde "evrensel değil" sayıp yeniden derliyordu).

## Açık riskler

Ayrıntılar `docs/ios-plan.md` §5'te; iki sürüm için de geçerli:

- **Sony / 5.2.2**: PSN'e chiaki-ng'nin kullandığı resmî olmayan istemci kimliğiyle giriş ve Remote Play protokolü.
  İnceleme "üçüncü taraf hizmetine yetkisiz erişim" diyebilir. İç TestFlight incelemesizdir; dış TestFlight ve yayın
  incelemeden geçer.
- **AGPL-3.0 ve chiaki-ng**: App Store dağıtım koşulları AGPL'nin "ek kısıtlama yok" şartıyla çelişebilir. CouchSubs'ın
  kendi kodu tek sahipliyse sorun değil; chiaki-ng de AGPL ve katkıcılarının izni yok. Yayından önce hukuki karar
  gerekiyor (iç TestFlight için de).
- **Şifreleme beyanı**: Remote Play OpenSSL (TLS, AES) kullanıyor. `ITSAppUsesNonExemptEncryption` yazılmadı; her
  yüklemede App Store Connect soruyu sorar, sahibi yanıtlar (gerekirse Fransa için ayrı belge).
- **Mac App Store'a özgü**: uygulama gömülü programlar (.NET yardımcısı, pocket-tts) çalıştırıyor ve LG kurulumu için
  `/usr/bin/ssh` açıyor; TV'lere uygulama kuruyor. Hepsi sandbox içinde ve uygulamanın paketinden geliyor, ama
  inceleme 2.4.5 / 2.5.2 kapsamında soru sorabilir. İnceleme notunda TV uygulamasının (aynı açık kaynak proje) TV'ye
  kurulduğu, Mac'e kod indirilmediği yazılmalı.
- **GitHub sürümüne yönlendirme**: TV kurulumu hata iletisi GitHub (DMG) sürümünü anıyor. İnceleme başka dağıtım
  kanalına yönlendirme sayarsa ileti "bilgisayardaki diğer CouchSubs" diye genelleştirilir.
