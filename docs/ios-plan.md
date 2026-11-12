# iPhone/iPad uygulaması: fizibilite ve plan

Amaç: bilgisayarın yerini telefon alır. Telefon ikinci PSN hesabıyla PS5'e Remote Play istemcisi olarak bağlanır,
görüntüdeki İngilizce altyazıyı okur (Apple Vision), çevirir (oyun paketleri, Apple'ın ücretsiz çevirisi,
DeepL/Gemini/OpenAI/Claude) ve altyazı sunucusundan (SSE, 8787) TV uygulamasına gönderir ya da kendi ekranında
gösterir ("TV'm yok"). Uygulama `couchsubs-ios/` klasöründe (SwiftUI, iOS 16 ve sonrası, `com.couchsubs.ios`).

## Özet

| Parça | iOS'ta | Not |
|---|---|---|
| libchiaki (Remote Play) | Çalışır | `scripts/build-chiaki-ios.sh`, chiaki-ng kaynağına dokunmadan |
| Görüntü çözme | Çalışır | VideoToolbox (FFmpeg gerekmez), Mac'teki `H264FrameDecoder` aynen |
| Yazı tanıma | Çalışır | Vision, Mac'teki `VisionReader` aynen (CouchSubsCore'a taşındı) |
| Ücretsiz çeviri | iOS 26 ve sonrası | Translation çerçevesi; dil paketi uygulama içinden indirilir (`translationTask`). iOS 16–18'de yok: paketler, DeepL, yapay zekâ |
| DeepL / yapay zekâ | Çalışır | Anahtarlar Anahtarlık'ta (`com.couchsubs.ios` hizmeti) |
| Oyun paketleri, ortak havuz | Çalışır | CouchSubsCore'dan aynen |
| Altyazı sunucusu (SSE) | Çalışır, uygulama öndeyken | `NWListener`; iOS arka planda askıya alır |
| LG / Samsung eşleşme ve TV uygulamasını açma | Çalışır | SSAP ve Samsung WebSocket istemcileri saf Swift |
| Android TV | Çalışır | TV uygulaması telefonu ağda kendisi bulur (8787 taraması) |
| PS5 ve TV'yi ağda bulma | Apple yetkisi gerekir | UDP yayını ve SSDP için `com.apple.developer.networking.multicast` |
| TV uygulamasını kurma (LG, Samsung, Android TV) | Yapılamaz | ssh / sdb / adb ve .NET yardımcısı başka program çalıştırır; iOS izin vermez |
| Türkçe dublaj | Şimdilik yok | Ses motoru (pocket-tts) ayrı bir program |

## 1. Remote Play kütüphanesi (libchiaki) iOS için

chiaki-ng iOS'u zaten gözetiyor: `lib/src/takion.c` macOS'a özgü CoreServices'i yalnız `TARGET_OS_OSX` ile kullanıyor,
`lib/CMakeLists.txt` CoreServices'i iOS'ta bağlamıyor. Yani kaynakta değişiklik gerekmiyor; yalnız derleme seçenekleri.

Bağımlılıklar ve Mac'te nereden geldikleri:

| Bağımlılık | Mac (`build-chiaki-macos.sh`) | iOS (`build-chiaki-ios.sh`) |
|---|---|---|
| OpenSSL 3 (libcrypto, libssl) | Kaynaktan, `darwin64-arm64-cc` / `darwin64-x86_64-cc` | Kaynaktan, `ios64-xcrun` / `iossimulator-arm64-xcrun` |
| json-c | Kaynaktan (CMake) | Kaynaktan (CMake) |
| libevent, miniupnpc | Kaynaktan (CMake) | Kaynaktan (CMake), aynı sürümler |
| curl (WebSocket'li) | chiaki-ng alt modülü | Aynı, OpenSSL ile |
| nanopb, jerasure, gf-complete | chiaki-ng alt modülleri | Aynı |
| protobuf | Kod üreteci için (protoc + Python `protobuf`) | Aynı (yalnız derleyen makinede) |
| Opus, Speex, FFmpeg | Kapalı | Kapalı (ses yok, görüntü VideoToolbox) |

Betik ne yapar:

1. chiaki-ng ağacını `third-party/build/ios-work/chiaki` klasörüne kopyalar, `third-party/patches` yamalarını orada
   uygular (asıl alt modül değişmez). Başka bir çalışma kopyasındaki kaynakla derlemek için `CHIAKI_SRC=...`.
2. Her dilim için (cihaz `iphoneos` arm64, simülatör `iphonesimulator` arm64) OpenSSL, json-c, libevent ve miniupnpc'yi
   `CMAKE_SYSTEM_NAME=iOS` ile derler; Homebrew'un macOS kütüphaneleri `CMAKE_IGNORE_PREFIX_PATH` ve ayrı
   `PKG_CONFIG_LIBDIR` ile dışarıda kalır.
3. libchiaki'yi Mac'teki seçeneklerle derler (arayüz, komut satırı, ses ve FFmpeg kapalı), çıkan her `.a`'nın doğru
   platform için olduğunu (`otool -l`, platform 2 / 7) denetler.
4. `scripts/make-cchiaki-xcframework.sh` ile `CChiaki.xcframework`'ü macOS + iOS + simülatör dilimleriyle kurar.
   Mac betiği de artık bunu çağırır; biri ötekinin dilimini silmez.

chiaki-ng Apple'da dağıtım hedefini CMakeLists'te 13.0'a sabitliyor (`CACHE FORCE`); iOS kütüphaneleri bu yüzden
iOS 13'ü hedefler, iOS 16 uygulamasına sorunsuz bağlanır. Derleme süresi (4 iş, düşük öncelik): ilk sefer OpenSSL ile
birlikte dilim başına birkaç dakika; OpenSSL sonraki derlemelerde yeniden kullanılır.

`remoteplay/Package.swift` `.iOS(.v16)` bildiriyor; CoreServices yalnız macOS'ta bağlanıyor. Swift kodunda
(`StreamSession`, `Registration`, `Console`, `PSNAccount`, `H264FrameDecoder`) değişiklik gerekmedi.

## 2. CouchSubsCore iOS'ta

Paket `.iOS(.v26)` bildiriyordu ama iki yer derlenmiyordu: `ProcessRunner` (LG kurulumunda ssh) ve
`PocketTTSServer` (dublaj motoru) `Process` kullanıyor. İkisi `#if os(macOS)` içine alındı. Geri kalan her şey
(sunucu, SSAP, Samsung, TV bulma, paketler, havuz, çeviri metin hattı) iOS'ta olduğu gibi derleniyor.

Mac uygulamasından CouchSubsCore'a taşınanlar (Mac uygulaması da bunları kullanıyor):

- `Pipeline/SubtitlePipeline.swift`, `VisionReader.swift`, `RegionCropper.swift` (okuma hattı)
- `Pipeline/Translator.swift`, `DeepLTranslator.swift`, `AITranslator.swift` (çevirmenler)
- `Pipeline/AppSettings.swift`: `UserSettings`, `TranslationEngine`, `SubtitleOutput`, `StoreKey`, `AppStore`,
  `KeychainStore`, `DubbingSettings`
- `Pipeline/SecureStore.swift` (Anahtarlık; Mac `com.couchsubs.mac`, iOS `com.couchsubs.ios`), `AppIdentity.swift`
- `NetworkAddress.near` (TV'ye bildirilen yerel adres)

Arayüzde ortak olanlar dosya olarak paylaşılır (`couchsubs-ios/project.yml` içinde `../mac/...` yolları):
`Theme.swift` (tokens.json; NSColor/UIColor), `Components.swift`, `LoginWebView.swift` (Sony giriş sayfası,
NSViewRepresentable/UIViewRepresentable). Ekran metinleri Mac'teki `Localizable.xcstrings`'te; iOS'a özgü yeni metinler
sona eklendi, `scripts/check-strings.py` iki uygulamayı birlikte denetler.

## 3. Yerel ağ ve Apple yetkileri

- `NSLocalNetworkUsageDescription` Info.plist'te. İlk PS5/TV bağlantısında iOS izin sorar; reddedilirse eşleştirme
  `localNetworkBlocked` ile anlatılır (Ayarlar › Gizlilik ve Güvenlik › Yerel Ağ).
- **Multicast yetkisi (`com.apple.developer.networking.multicast`)**: PS5 araması (UDP yayını, 9302) ve LG/Samsung
  araması (SSDP, 239.255.255.250) için gerekli. Bu yetki Apple'dan ayrıca istenir
  (developer.apple.com/contact/request/networking-multicast) ve onay gelmeden bu yetkiyle imzalanan uygulama cihaza
  kurulamaz. Proje dosyası yetkiyi içeriyor; onaya kadar cihaz derlemesinde `CouchSubs.entitlements`'tan çıkarılmalı.
  Yetkisiz de çalışır: PS5'in ve TV'nin IP adresi elle yazılır (kurulum ekranlarında alan var). PS5'e bağlanmak,
  uyandırmak ve kayıt tek adrese (unicast) gittiği için yetki istemez; PS5'in adresi değişince ağda yeniden bulma
  (`relocate`) yetkisiz çalışmaz.
- Bonjour kullanılmıyor (`NSBonjourServices` gerekmez): TV uygulamaları sunucuyu adresle (LG, Samsung) ya da alt ağı
  tarayarak (Android TV) buluyor.

## 4. Arka plan sınırları

iOS, arka plana geçen ya da ekranı kilitlenen uygulamayı birkaç saniye içinde askıya alır: Remote Play oturumu,
yazı tanıma ve altyazı sunucusu durur. Remote Play bir arka plan kipine (ses, konum, VoIP) uymadığı için bunu meşru
şekilde aşmanın yolu yok; sessiz ses çalarak açık tutmak App Store incelemesinde reddedilir. Bu yüzden:

- Çeviri sürerken `UIApplication.isIdleTimerDisabled` açık (ekran kararmaz), ana ekranda "CouchSubs açık kalsın" notu var.
- Uygulama öne dönünce (`scenePhase == .active`) PS5 ve TV bağlantıları hemen yenilenir (`reconnectNow`).
- Arka plana geçerken ortak havuz kuyruğu gönderilir.
- Telefon şarja takılı ve ekranı açık kalacak; pil ve ısınma gerçek cihazda ölçülmeli (H.264 çözme donanımda, Vision
  saniyede birkaç kez; Mac'teki gibi `ReadScheduler` değişmeyen kareleri okumaz).

## 5. App Store riskleri

- **Multicast yetkisi** onaylanmazsa keşif yok, adres elle.
- **PSN girişi ve Remote Play protokolü**: Sony'nin resmî olmayan istemci kimliğiyle giriş (chiaki-ng'nin kullandığı).
  İnceleme "üçüncü taraf hizmetine yetkisiz erişim" (5.2.2) diyebilir. chiaki-ng ve benzer istemciler App Store'da
  zaman zaman yer aldı ama risk gerçek. TestFlight dış test incelemesi de aynı kuralları uygular.
- **AGPL-3.0**: App Store dağıtımı AGPL ile çelişebilir (ek kısıtlamalar). Kaynak açık ve tek telif sahibi CouchSubs
  ise sorun değil; chiaki-ng de AGPL, katkıcılarının izni yok. Hukuki karar gerekiyor; TestFlight için de geçerli.
- **Şifreleme beyanı**: Remote Play OpenSSL ile şifreli; yükleme sırasında ihracat uyumu sorusu yanıtlanmalı
  (`ITSAppUsesNonExemptEncryption` bilinçli olarak yazılmadı).
- **Simge**: `design/logo-1024.png` saydam kenarlı (macOS ızgarası). iOS simgesi saydamlık içeremez; tam dolu 1024'lük
  simge `scripts/make-icons.swift` ile üretilmeli.

## 6. TV uygulamasını kurma

Telefon TV uygulamasını kuramaz: LG kurulumu ssh/ssh-keygen (`DevModeInstaller` + `ProcessRunner`), Samsung sdb ve
imzalama, Android TV adb ister; hepsi başka program çalıştırmak ya da .NET yardımcısıdır. Uygulama TV'de açılmazsa
telefon "TV uygulamasını ilk kez kurmak için bir kez bilgisayardaki CouchSubs'ı kullanın" der. Kurulumdan sonra
telefon tek başına yeter (eşleşme ve TV uygulamasını açma SSAP / Samsung WebSocket ile, saf Swift).

İleride: LG için saf Swift SSH (ör. swift-nio-ssh; LG'nin parolalı RSA anahtarı ve `ssh-rsa` desteği gerekiyor),
Android TV için Swift ADB (Windows'taki C# `AdbConnection`/`AdbTls`/`Spake2` çalışmasının karşılığı). Samsung imzalama
Samsung'un sertifika hizmetine bağlı, en zoru.

## 7. Derleme

```sh
scripts/build-chiaki-macos.sh      # macOS dilimi (Mac uygulaması için)
scripts/build-chiaki-ios.sh        # iPhone/iPad dilimleri; xcframework ikisini birleştirir
cd couchsubs-ios && xcodegen
xcodebuild -project CouchSubs.xcodeproj -scheme CouchSubs -destination 'generic/platform=iOS Simulator' build
xcodebuild -project CouchSubs.xcodeproj -scheme CouchSubs -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## 8. Ücretsiz uygulama, ölçüm, reklam altyapısı ve paket indirme

İş modeli: CouchSubs **tamamen ücretsiz** ve **hesap istemez**; masaüstü gibi telefon da ücretsiz çeviri, DeepL, kendi
yapay zekâ anahtarı ve oyun paketlerini herkese verir. Abonelik, ödeme ekranı, giriş/kayıt yoktur. Satıcı: Enmera
(kuruluş hesabı, takım `79N3CT6T46`, Mac uygulamasını imzalayan takım).

| Parça | Nerede | Anahtar yokken |
|---|---|---|
| Firebase Analytics, Crashlytics, Remote Config | `Account/Measurement.swift` | `GoogleService-Info.plist` yoksa Firebase hiç kurulmaz |
| Meta App Events | `Measurement.swift` | `FACEBOOK_APP_ID` boşsa Meta SDK kurulmaz; reklam kimliği ve otomatik olaylar izin gelene kadar kapalı |
| İzin akışı: Google UMP formu, sonra Apple ATT | `Integrations.requestConsent` (karşılamadan sonra) | — |
| AdMob | `Measurement.swift` | Reklam yok: Remote Config `ads_enabled` (varsayılan false) true olmadan SDK başlatılmaz; reklam birimi de yok |
| Paket güncelleme | `Packs/PackStore.swift`, `Account/AppModel.swift` | `PACKS_API_BASE_URL` boşsa yalnız uygulamayla gelen paketler |

Ölçülen olaylar: `session_start`, `session_stop`, `pack_hit`, `tv_connected`, `packs_updated` ve ekran görüntülemeleri.
Profil › Kullanım verisi kapatılınca Analytics ve Crashlytics toplaması durur.

Paketler: uygulamayla gelenler (CouchSubsCore kaynakları) her zaman okunur; sunucudan indirilen güncel sürüm aynı
kimlikli paketin yerine geçer. Sunucuya ulaşılamazsa telefondaki paketlerle devam edilir.

### Paket sunucusu sözleşmesi (istemci tarafı)

Sunucu `server/packs` (Cloudflare Worker, `feat/android-app` dalında; Android tarafı onu da kimliksiz hale getiriyor).
İkisi de herkese açık, kimlik ve abonelik istemez:

- `GET /v1/packs` → `{"packs":[{"id","title","version","sha256","size","entries"}]}` (`version` artan bir sayı).
- `GET /v1/packs/:id` → `packs/<id>.json.gz`; gövdenin SHA-256'sı listedekiyle aynı olmalı, değilse dosya yazılmaz.
- 404 paket yok; diğer hatalar bildirilir, telefondaki paketler kullanılmaya devam eder.

İstemci: liste değişmemiş paketi yeniden indirmez, listeden kalkanı siler, haftada bir yeniler (Paketler ekranındaki
"Paketleri şimdi güncelle" ile hemen). Önbellek: `Application Support/CouchSubs/Packs/{manifest.json,files/}`.

### Profil

Hesap olmadığı için Profil bir cihaz ve tercih sayfasıdır: PS5 ve bağlantı, altyazı hedefi (TV'ler), ikinci PSN hesabı,
bildirim tercihi, ortak havuza katkı, kullanım verisi, gizlilik, yardım ve Hakkında.

### Sahibinin vermesi gerekenler

1. **Firebase**: iOS uygulaması (`com.couchsubs.ios`) ekleyip `GoogleService-Info.plist`'i
   `couchsubs-ios/Config/GoogleService-Info.plist` olarak koymak (gitignore'da; derleme adımı varsa kopyalar).
   Remote Config'te `ads_enabled = false`. Crashlytics için ek bir şey gerekmez (Release derlemesi sembolleri yükler).
2. **Meta**: uygulama kimliği ve istemci jetonu → `Config/Secrets.xcconfig` içinde `FACEBOOK_APP_ID`,
   `FACEBOOK_CLIENT_TOKEN`; Meta'da iOS platformu ve paket kimliği.
3. **AdMob**: uygulama kimliği → `GAD_APPLICATION_ID` (şimdilik Google'ın deneme kimliği); UMP izin mesajı (AB/İngiltere)
   AdMob panelinden; yayın öncesi SKAdNetwork listesi Google'ın ve Meta'nın güncel listesiyle karşılaştırılmalı.
4. **Paket sunucusu adresi** → `PACKS_API_BASE_URL` (Cloudflare Worker yayına alınınca).
5. **App Store Connect**: uygulama kaydı (satıcı Enmera, ücretsiz), gizlilik politikası adresi (`PRIVACY.md`), gizlilik
   etiketi (Firebase Analytics/Crashlytics, Meta: kullanım ve tanılama verisi, reklam kimliği yalnız izinle), ATT metni
   Info.plist'te.
6. **Apple Developer** (`com.couchsubs.ios`, takım `79N3CT6T46`): multicast başvurusu (bkz. §3); (isteğe bağlı) Push.
   Sign in with Apple ve uygulama içi satın alma gerekmez.

Değerler `couchsubs-ios/Config/Secrets.xcconfig`'e yazılır (örnek: `Secrets.xcconfig.example`), ardından `xcodegen`.

## 9. TestFlight'a kalan işler

1. Apple Developer hesabında `com.couchsubs.ios` kimliği, multicast yetkisi başvurusu (onaya kadar yetkisiz imza).
2. Otomatik imza (takım `79N3CT6T46` projede); tam dolu iOS simgesi; §8'deki anahtarlar.
3. Gerçek iPhone'da PS5 eşleştirme, akış ve okuma; pil/ısı ölçümü; Vision'ın telefondaki hızı.
4. Ekranlar onaylı mobil tasarıma (TASARIM-MOBIL.md, bento) göre kuruldu; gerçek cihazda gözden geçirilmeli. Ana ekrandaki "GTA V paketi" gibi paket adı henüz yok (CouchSubsCore eşleşmenin hangi paketten geldiğini vermiyor), yerine "Hazır çeviri" yazıyor.
5. Hukuki: AGPL ve App Store, PSN girişi; ihracat uyumu.
6. App Store Connect kaydı (ücretsiz uygulama), gizlilik etiketi (havuz anonim satır gönderir; çeviri anahtarları cihazda kalır).
