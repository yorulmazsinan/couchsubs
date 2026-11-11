# CouchSubs Android (telefon ve tablet): fizibilite ve plan

Durum: ilk çalışan sürüm (MVP) `couchsubs-android/` klasöründe, `feat/android-app` dalında. Ekranlar yer tutucudur;
onaylanan tasarım gelince yeniden yapılacak. Motor ve tesisat (Remote Play, yazı tanıma, paketler, çeviri, SSE sunucusu,
ön plan hizmeti) masaüstüyle aynı kurallarla yazıldı.

## Ne yapıyor

```
PS5 ──HDMI──▶ TV (CouchSubs TV uygulaması)          PS5 ── Remote Play (ikinci PSN hesabı) ──▶ Telefon
                ▲                                     telefon: MediaCodec H.264 → ImageReader → ML Kit OCR
                └── SSE :8787 (/events, /hello) ◀──── kararlılık → paket → ML Kit / DeepL / Gemini / OpenAI / Claude
                                                      (ya da altyazı telefonun kendi ekranında, yatay, büyük yazı)
```

Masaüstüyle birebir aynı tutulanlar (Kotlin'e taşındı, testleri de taşındı):

| Parça | Kaynak | Kotlin |
|---|---|---|
| Paket anahtarı (canon + SHA-256) | `GamePacks.cs` / `canon.py` | `core/GamePacks.kt` (`PackKey`), altın vektörler `app/src/test/resources/fixtures` |
| Paket arama (etiket, satır, cümle) | `PackLookup.cs`, `SubtitleSegmenter.cs` | `core/SubtitleSegmenter.kt` |
| Kararlılık, aynı altyazı, OCR çöpü | `SubtitleStabilizer.cs`, `TextMatch.cs`, `OcrNoise.cs`, `Reading.cs` | `core/` aynı adlarla |
| Okuma hattı (tek çeviri + bir sırada) | `SubtitlePipeline.cs` | `core/SubtitlePipeline.kt` |
| SSE sunucusu (subtitle/clear/style/ping, `/hello`) | `SubtitleServer.cs` | `core/SubtitleServer.kt`, JSON çıktısı birebir aynı (sıralı anahtar, 4 basamak) |
| Ortak havuz | `LinePool.cs` | `core/LinePool.kt` (`platform: "android"`) |
| DeepL / Gemini / OpenAI / Claude istekleri | `DeepLTranslator.cs`, `AiTranslator.cs` | `translation/OnlineTranslators.kt`, model listesi ortak `ai-models.json` |
| PSN girişi, kayıt, uyandırma, oturum | `PsnAccount.cs`, `Registration.cs`, `StreamSession.cs`, `couchsubs_native.c` | `remoteplay/`, `app/src/main/cpp/couchsubs-jni.c` |

TV tarafında değişiklik gerekmez: TV uygulaması ağı `:8787/hello` ile tarar ve telefonu bilgisayar gibi bulur
(kayıtlı bilgisayara ulaşamazsa 30 sn içinde yeniden tarar).

## Fizibilite bulguları

### chiaki-ng'nin Android'de derlenmesi

- `third-party/chiaki-ng` değiştirilmeden, `externalNativeBuild` ile kaynaktan derlenir
  (`app/src/main/cpp/CMakeLists.txt`). chiaki-ng'nin kendi `android/` uygulaması eski (AGP 7, oboe, ses, dokunmatik
  kumanda) ve bizim işimize yaramıyor; ondan yalnız MediaCodec çözücü (`video-decoder.c`) ve JNI kalıpları uyarlandı.
- `CHIAKI_ENABLE_ANDROID=ON` libevent bağımlılığını kapatır ama chiaki-ng'nin `android/app` hedefini de ekler; o hedef
  oboe arar. Derlemediğimiz o hedef için boş bir oboe paketi verilir (`cpp/oboe-stub`); Gradle yalnız `couchsubs-jni`
  hedefini derler.
- OpenSSL 1.1.1w, json-c ve miniupnpc chiaki-ng'nin dış proje tarifleriyle derleme sırasında indirilir (ağ gerekir; ilk
  derleme bir mimari için ~10 dk). nanopb kod üreteci protobuf paketli Python ister (`-Pcouchsubs.python=…` ya da
  `COUCHSUBS_PYTHON`).
- Yalnız `arm64-v8a` derlenir (`couchsubs.abis`); öykünücü için `x86_64` eklenebilir.
- `third-party/patches` yamaları CI'da masaüstündeki gibi uygulanır (`-Pcouchsubs.patchChiaki=true`).

### Görüntü → yazı tanıma

- PS5 akışı masaüstüyle aynı: 1080p30 H.264, ses kapalı, kol girdisi yok. Çözme donanımda (AMediaCodec), çıkış bir
  `ImageReader` (YUV_420_888) yüzeyine gider; yalnız altyazı bölgesinin parlaklık düzlemi kopyalanır (renk gerekmez).
- Risk: bazı cihazlarda MediaCodec'in ImageReader'a YUV verememesi (yalnız PRIVATE biçim). B planı: SurfaceTexture +
  OpenGL ile bölgeyi okumak. Gerçek cihazda denenmeli.
- Yazı tanıma: Google ML Kit Text Recognition v2, Latin modeli uygulamaya gömülü (APK'ya ~4 MB), cihaz üstü, internetsiz.
  Saniyede en çok 5 okuma; bölge değişmediyse yeniden okunmaz (son okuma hattı besler).

### Çeviri

- Sıra: oyun paketi (anında, ücretsiz) → seçilen çevrimiçi motor (kullanıcının anahtarıyla) → hata olursa ücretsiz motor.
- Ücretsiz motor: ML Kit Translation EN→TR. Model ~30 MB, ilk kullanımda bir kez iner, sonra internetsiz çalışır.
  Kalite masaüstündeki yerel modelden (Windows'ta Marian/ONNX, Mac'te Apple Translation) belirgin şekilde düşük;
  paketsiz oyunlarda çevrimiçi motor önerilmeli. Masaüstündeki terim koruma, sözlük ve Türkçe son düzeltme
  (`Glossary`, `TermProtection`, `TurkishPostEdit`) henüz taşınmadı.
- Paket belleği: uygulamayla gelen altı pakette ~520 bin satır var. Satırlar sıralı anahtar dizisi + tek UTF-8 blokta
  (~30 MB) tutulur, dosya akış hâlinde okunur; `HashMap<Long, String>` ile ~110 MB tutardı.

### Ön plan hizmeti ve güç

- `TranslationService`, `foregroundServiceType="connectedDevice"` (Android 14+ için ön koşulu
  `CHANGE_WIFI_MULTICAST_STATE`). Ağdaki iki cihazla (PS5, TV) sürekli konuşan uygulama için doğru tür; `dataSync`
  Android 15'te 6 saatle sınırlı, `mediaPlayback` yanlış olurdu.
- Okuma sürerken kısmi wake lock ve düşük gecikmeli Wi-Fi kilidi alınır; "Ekranı açık tut" seçeneği var.
- 1080p çözme + saniyede 5 OCR telefonu ısıtır ve pili yer; masaüstündeki `ReadScheduler` (gereksiz okumayı atlama)
  taşınmalı, 720p seçeneği denenmeli.

### Yerel ağ izinleri

- Bugün (targetSdk 35) yalnız `INTERNET` yeter: TCP sunucusu, PS5'e UDP arama, SSDP çoklu yayını için
  `CHANGE_WIFI_MULTICAST_STATE`. Konum ya da `NEARBY_WIFI_DEVICES` istenmez.
- Google, Android 16'da yerel ağ erişimini isteğe bağlı bir korumayla kısıtlamaya başladı ve sonraki sürümlerde hedef
  SDK'ya bağlı zorunlu izin (yakındaki cihazlar grubu) planlıyor. targetSdk yükseltilirken bu izin istenmeli ve PS5/TV
  adımında gerekçesi gösterilmeli. (Ayrıntı sürüm notlarından yeniden doğrulanmalı.)
- `usesCleartextTraffic=true`: TV'nin cihaz tanımı (`http://tv:1990/`) ve yerel sunucu düz HTTP'dir.

### Play Store riskleri

1. **Sony'nin Remote Play istemci kimliği**: PSN girişi chiaki-ng'nin kullandığı Sony istemci kimliği ve gizli anahtarıyla
   yapılıyor (masaüstüyle aynı). Resmî olmayan bir Remote Play istemcisi Play'de Sony'nin şikâyetiyle (marka/telif)
   kaldırılabilir; mağaza adında ve görsellerinde "PlayStation", "PS5" logoları ve Sony markası kullanılmamalı
   ("PS5 ile çalışır" gibi tanımlayıcı kullanım). En güvenli yol: önce GitHub sürümünde APK, sonra Play'de kapalı test.
2. **Ön plan hizmeti beyanı**: `connectedDevice` türü Play Console'da gerekçe ve kısa video ister.
3. **Veri güvenliği formu**: ortak havuz (pakette olmayan İngilizce satırlar + kuruluma özgü rastgele kimlik), kullanıcının
   seçtiği çevrimiçi motorlara giden altyazı metni, PSN girişi (yalnız Sony'ye). Gizlilik metni `PRIVACY.md`'ye
   telefon bölümü eklenmeli.
4. **WebView ile Sony girişi**: Google hesabı değil, sorun yok; Custom Tab kullanılamaz çünkü Sony yönlendirmesi
   `https://remoteplay.dl.playstation.net/...` adresine gider, uygulama yakalayamaz.
5. **AGPL**: kaynak zaten açık; uygulama içinde kaynak bağlantısı ve üçüncü taraf lisansları (chiaki-ng, OpenSSL, curl,
   ML Kit koşulları) gösterilmeli.

## Aşama 2: hesap, abonelik, ölçüm (telefon uygulaması)

İş modeli: uygulama ücretsiz (ücretsiz motor, DeepL ve kendi API anahtarıyla çeviri). Hazır çeviri paketleri Pro
abonelikle: aylık 399 TL, yıllık 3.588 TL (aylık 299 TL). Masaüstü tamamen ücretsiz kalır. Play Console hesabı Enmera
adına **kuruluş** hesabıdır: 12 test kullanıcısı / 14 günlük kapalı test şartı yoktur; geliştirici adı "Enmera".

| Parça | Nerede | Not |
|---|---|---|
| Firebase Analytics, Auth (Google, e-posta/şifre, şifre sıfırlama, Apple), Crashlytics, Remote Config | `account/Backend.kt` | `app/google-services.json` yoksa Firebase hiç açılmaz; derleme ve uygulama çalışır |
| RevenueCat (Play Billing) | `account/Subscriptions.kt` | appUserID = Firebase UID; hak `packs`; teklif `default` (`$rc_monthly` → `couchsubs_packs_monthly`, `$rc_annual` → `couchsubs_packs_annual`); satın alma ekranı bizim (`PaywallScreen`) |
| Meta App Events | `account/Ads.kt` | yalnız "Reklam ölçümü" izniyle; otomatik başlatma manifestte kapalı |
| AdMob + UMP | `account/Ads.kt` | Remote Config `ads_enabled` (varsayılan false) açılmadan başlatılmaz, reklam gösterilmez |
| İzin (KVKK/GDPR) | `ConsentScreen`, `account/Policies.kt` | ölçüm ve reklam ölçümü ayrı; karar verilene kadar hiçbir şey toplanmaz (Consent Mode v2) |
| Paket kapısı | `PackGate`, `Services.packsAllowed()` | abonelik + ayar; hata ayıklamada "abonelik olmadan dene" |
| Paket indirme | `packs/PackStore.kt`, `server/packs` | aboneye sunucudan, SHA-256 doğrulamalı, haftada bir; abonelik bitince silinir |

Mağaza APK'sında paket yoktur; hata ayıklama APK'sında `core/.../packs` gömülüdür (sunucusuz deneme).

Olaylar: `sign_up`, `login`, `paywall_view`, `purchase`, `pack_hit` (oturumda paket başına bir kez),
`tv_connected`, ekran görüntülemeleri. Firebase `session_start` adını ayırdığı için okuma oturumu
`subtitle_session_start` / `subtitle_session_stop` adını taşır.

### Sahibin vermesi gerekenler

1. **Firebase**: proje oluştur, Android uygulaması ekle (paket `com.couchsubs.mobile`, hata ayıklama ve sürüm SHA-1/
   SHA-256), `google-services.json`'u `couchsubs-android/app/` altına koy (depoya girmez). Authentication'da
   E-posta/Şifre, Google ve (isteğe bağlı) Apple sağlayıcılarını aç; Apple için Apple Developer'da Services ID ve
   anahtar. Remote Config'de `ads_enabled` (boolean, false). Crashlytics'i aç.
2. **RevenueCat**: proje + Google Play uygulaması, Play servis hesabı bağlantısı; hak `packs`, teklif `default`,
   paketler `$rc_monthly`/`$rc_annual`. Public SDK anahtarı (`goog_…`) → `couchsubs-android/secrets.properties`
   `revenuecat.apiKey`. Gizli anahtar (`sk_…`) → Worker sırrı `REVENUECAT_SECRET`.
3. **Play Console**: abonelik ürünleri `couchsubs_packs_monthly` (399 TL/ay) ve `couchsubs_packs_annual` (3.588 TL/yıl);
   uygulama imza anahtarı; veri güvenliği formu; ön plan hizmeti (connectedDevice) beyanı.
4. **Cloudflare**: R2 kovası `couchsubs-packs`, `server/packs/wrangler.toml` içinde `FIREBASE_PROJECT_ID`,
   `wrangler deploy`; adres → `secrets.properties` `packs.url` (bkz. `server/packs/README.md`).
5. **Meta**: uygulama kimliği ve istemci tokeni → `facebook.appId`, `facebook.clientToken`.
6. **AdMob** (reklam açılacaksa): uygulama kimliği ve banner birimi → `admob.appId`, `admob.bannerId`; AEA/İngiltere için
   AdMob'da GDPR mesajı (UMP).
7. **Metinler**: Kullanım koşulları sayfası (şimdilik `TERMS.md` bağlantısı, dosya yok) ve gizlilik metnine telefon
   bölümü (Firebase, RevenueCat, Meta, AdMob, ortak havuz).

## Bilinen eksikler

- TV uygulamasını telefondan kurma yok: "TV uygulamasını ilk kez kurmak için bir kez bilgisayardaki CouchSubs'ı
  kullanın". Android TV için ADB-over-Wi-Fi kurulumu (`CouchSubs.TvInstall/Android/AdbConnection.cs` taşınarak) sonraki
  adım; LG (geliştirici modu, SSH) mümkün, Samsung (Samsung hesabıyla imza) zor.
- Bölge seçimi (RegionPicker), "ekranı çevir", dublaj, sözlük/terim koruma, ReadScheduler taşınmadı.
- Gerçek PS5 ve gerçek telefonla uçtan uca deneme yapılmadı (bu ortamda cihaz yok).

## Derleme

```
cd couchsubs-android
# JVM testleri (yerel kütüphane gerekmez)
gradle testDebugUnitTest -Pcouchsubs.skipNative=true --no-daemon --max-workers=4
# Hata ayıklama APK'sı (NDK 27.0.12077973, CMake 3.22.1, protobuf'lu Python)
gradle assembleDebug -Pcouchsubs.python=/yol/venv/bin/python3 --no-daemon --max-workers=4
```

İlk sonuç (Mac, Kasım 2026): 59 JVM testi geçti; `assembleDebug` yerel kütüphaneyle birlikte ~7,5 dk'da derlendi.
Hata ayıklama APK'sı 64 MB: `libcouchsubs-jni.so` 4,8 MB, ML Kit çeviri 16 MB ve yazı tanıma 11 MB yerel kütüphanesi,
oyun paketleri (AGP `.gz` uzantısını atıp APK içinde zip sıkıştırmasıyla saklar; kod `.json`'u da okur). Sürümde
yalnız arm64 ve küçültme (R8) ile küçülür; paketler ileride ilk açılışta indirilebilir.

CI önerisi: `.github/workflows/android-app.yml` (yalnız `couchsubs-android/**` değişince ve elle; sürüm iş akışına bağlı değil).

## Play Store / APK sürümüne giden adımlar

1. Gerçek cihazda uçtan uca deneme: ImageReader biçimi, ML Kit okuma kalitesi, ısınma, Wi-Fi uykusu.
2. Tasarımın uygulanması ve İngilizce metinler (`values-en`).
3. İmza: TV uygulamasıyla aynı anahtar (depo sırları); `release.yml`'e `CouchSubs-android.apk` olarak eklenmesi.
4. Uygulama içi güncelleme denetimi (masaüstündeki gibi GitHub sürümleri) — Play dışı dağıtım için.
5. Play (kuruluş hesabı, kapalı test şartı yok): iç test kanalı, veri güvenliği formu, FGS beyanı, abonelik ürünleri,
   marka kullanımının gözden geçirilmesi.
