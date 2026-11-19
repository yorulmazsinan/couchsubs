# Android TV uygulaması: Google Play'de yayın

Yayıncı: **Enmera** (kurumsal Play Console hesabı). Uygulama kimliği `com.couchsubs.tv`, sürüm **0.9.12 (versionCode 15)**.
Bu belge yüklemeden önce gerekenleri toplar: derleme, imza, mağaza metinleri ve görselleri, Play Console formlarının
cevapları, politika riskleri. Play Console'a henüz hiçbir şey yüklenmedi.

## 1. İki dağıtım: `sideload` ve `play`

`tv-android/app/build.gradle` iki ürün çeşidi (flavor) tanımlar:

| | `sideload` | `play` |
|---|---|---|
| Kim kurar | Mac/Windows CouchSubs, ADB ile | Google Play |
| Çıktı | `CouchSubs-androidtv.apk` (masaüstü uygulamalarına gömülür) | `CouchSubs-androidtv-play.aab` |
| Katman modu (siyah ekran çözümü) | var | **yok** |
| İzinler | INTERNET, SYSTEM_ALERT_WINDOW, FOREGROUND_SERVICE, FOREGROUND_SERVICE_SPECIAL_USE | yalnız INTERNET |
| `OverlayService` | var (`src/sideload/AndroidManifest.xml`) | yok |
| `BuildConfig.OVERLAY_MODE` | `true` | `false` |

**Neden katman modu Play'de yok:**

- Android TV kalite kuralı **TV-TR**: "Uygulama başka uygulamaların bir kısmını örtmez; tüm ekranı kaplar ve arka planı
  saydam değildir." Katman modu tam olarak bunu yapar (TV'nin kendi HDMI ekranının üstünde saydam pencere). TV incelemesi
  bu yüzden reddeder.
- Katman, `specialUse` tipinde ön plan servisi ister. Play bunun için Console'da ayrı beyan ve kullanımı gösteren video
  istiyor; inceleme elle yapılıyor ve `specialUse` sık reddediliyor.
- `SYSTEM_ALERT_WINDOW` Play'in kısıtlı izin listesinde değil, ama çoğu Android TV / Google TV'de "Diğer uygulamaların
  üzerinde göster" ayarı menüde yok; izin zaten yalnız ADB ile verilebiliyor (masaüstü uygulaması bunu yapıyor). Play'den
  kuran kullanıcı izni çoğu TV'de kendisi veremezdi.

Play sürümünde HDMI görüntüsü 10 sn gelmezse (ya da bilgisayarda Ayarlar › TV'de › Görüntü modu › Katman seçiliyse)
uygulama izin yerine şunu anlatır: "Katman modu yalnız bilgisayardaki CouchSubs'ın kurduğu TV uygulamasında var: bu
kopyayı kaldırın, USB hata ayıklamayı açın, çeviriyi bilgisayarda başlatın" (`overlay_unavailable` metni).

**Bilinen sınır (masaüstü kurulumu):** Masaüstü kurucusu (`windows/src/CouchSubs.TvInstall/Android/AndroidTvInstaller.cs`)
yalnız `versionName`'e bakar. TV'de Play'den kurulmuş aynı sürüm (0.9.12) varsa yeniden kurmaz, katman modu da gelmez.
Play kopyası kaldırılınca masaüstü kendi APK'sını kurar. İleride kurucu, `dumpsys package` çıktısında `installerPackageName=
com.android.vending` ya da `SYSTEM_ALERT_WINDOW` iznin yokluğuna bakarak siyah ekranlı TV'lerde sideload sürümünü kurabilir
(bu dosyalar başka bir çalışmada açık olduğundan bu dalda değiştirilmedi).

**Masaüstünün beklediği TV sürümü:** Mac ve Windows sabit bir sürüm tutmaz. `scripts/bundle-android-apk.sh` sürümü
`build.gradle`'daki `versionName`'den alır, APK'yı `couchsubs-androidtv_0.9.12.apk` adıyla gömer; uygulamalar sürümü bu
addan okur (`BundledTVApp.version(ofFile:)`, `Versions.OfBundledFile`). Sürümü yükseltmek için yalnız `build.gradle`
değişir. Not: Play'e her yükleme daha büyük `versionCode` ister; iki çeşit aynı sayıyı kullanır.

## 2. Play'e hazırlık durumu

| Konu | Durum |
|---|---|
| Hedef API | `targetSdk 35`, `compileSdk 35`. Play şartı (31 Ağustos 2026'dan beri): telefon 36, **Android TV 34+**. Sonraki yıl TV için 35'in isteneceği beklenir; 35 hazır. |
| Paket biçimi | AAB zorunlu (TV-G1): `gradle bundlePlayRelease` → `app/build/outputs/bundle/playRelease/app-play-release.aab` |
| 64 bit, 16 KB sayfa (TV-G6) | Yerel (native) kod yok; ikisi de kendiliğinden sağlanır |
| `minSdk` (TV-PS) | 24 (≤ 31 şartı sağlanır) |
| Leanback | `android.software.leanback` required=true (yalnız TV'de listelenir), `LEANBACK_LAUNCHER`, `android:banner` |
| Dokunmatik | `touchscreen` ve `faketouch` required=false; `live_tv` required=false |
| Afiş | 320×180, uygulama adını içerir (TV-BN; eskisinde ad yoktu, yenilendi) |
| Ön plan servisi | Play paketinde yok |
| Reklam kimliği | Kullanılmıyor, `AD_ID` izni yok |
| Açık metin trafiği | `usesCleartextTraffic=true`: ev ağındaki bilgisayar HTTP (8787) konuşuyor; dışarıya bağlantı yok |

## 3. Android TV kalite incelemesi (Tier 3 – TV Ready)

| Kural | Durum |
|---|---|
| TV-LM, TV-ML | `LEANBACK_LAUNCHER` etkinliği var |
| TV-LB, TV-BN | 320×180 afiş (adla) ve 512×512 simge |
| TV-LS | Kurulum ve açılış hatasız; HDMI'sız cihazda "kaynak desteklenmiyor" durumu gösterilir, çökme yok |
| TV-LO | Yalnız yatay, tam ekran |
| TV-OV | Panel ve demo notu Android TV güvenli alanında (yanlarda 96, üstte 54 piksel; `tv-android/platform.js`) |
| TV-TR | Play paketinde katman yok; uygulama tüm ekranı kaplar (HDMI görüntüsü uygulamanın kendi `TvView`'inde) |
| TV-DP, TV-DM | Her şey yön tuşları, Tamam ve Geri ile: Tamam bekleme ekranında demoyu, sonra durum panelini açar; panelde ◀▶ HDMI girişi; ▲▼ altyazı yeri. Renk ve sayı tuşları yalnız kısayol. Menü tuşu gerekmez |
| TV-DB | Geri önce demoyu ya da paneli kapatır, giriş ekranında TV'nin ana ekranına döner |
| TV-WB | Yalnız `WebView`; tarayıcı açılmaz |
| TV-NP | Uygulamadan çıkınca dublaj sesi kısılır (`onStop` → `__onBackground`), arka planda ses çalmaz |
| TV-BU, TV-BY | Ekran yalnız HDMI görüntüsü oynarken açık tutulur; bekleme ekranı ve demoda ekran koruyucusu engellenmez |
| TV-G1, TV-G6 | AAB; native kod yok |
| TV-G3 | Mağaza metni, bilgisayar uygulaması gerektiğini ve yayın çubuklarında çalışmadığını açıkça yazar |
| TV-G4 | En az bir gerçek ekran görüntüsü; bkz. §6 |
| TV-G5 | Giriş yok; inceleme notu demo modunu anlatır (§7) |
| TV-ME | Tek WebView, düşük bellek; düşük RAM'li cihazda denenmedi |

Medya oynatma kuralları (TV-PC, TV-PP, TV-PA), reklam, oyun kumandası ve PiP kuralları uygulanmaz.

## 4. İmza: Play App Signing ve yükleme anahtarı

TV'nin kendi sürüm anahtarı vardır (takma ad `couchsubs-tv`, CN=CouchSubs TV); telefon uygulamasının anahtarından
ayrıdır. Asıl dosya ve parolası Sinan Bey'in bilgisayarında durur, depoda yoktur. CI şu depo sırlarıyla imzalar:
`TV_KEYSTORE_BASE64`, `TV_KEYSTORE_PASSWORD`, `TV_KEY_ALIAS`. Sürüm derlemesinde (release.yml) bu sırlar yoksa iş hata
verir; APK geliştirme anahtarına düşmez (her derlemede imzası değişen APK, TV'de güncelleme olarak kurulamaz).

**Yol (A): TV sürüm anahtarı = Play'in uygulama imza anahtarı.** Play'den ve masaüstünden kurulan kopyalar aynı imzayı
taşır: masaüstü, Play kopyasının üstüne kaldırmadan kurabilir (TV'deki ayarlar kaybolmaz) ve tersi.

1. Play Console › uygulama › Test ve yayın › Kurulum › **Uygulama imzalama**: "Farklı bir anahtar kullan" ›
   **"Java anahtar deposundan dışa aktar ve yükle"**. Console'un verdiği `pepk.jar` ve şifreleme anahtarıyla Console'un
   gösterdiği komutu çalıştırın; örnek:
   ```sh
   java -jar pepk.jar --keystore=android-tv-release.jks --alias=couchsubs-tv --output=couchsubs-tv-signing.zip \
     --include-cert --rsa-aes-encryption --encryption-key-path=encryption_public_key.pem
   ```
   Çıkan zip'i yükleyin; zip'i depoya koymayın.
2. Ayrı yükleme anahtarı isteğe bağlıdır (`TV_UPLOAD_KEYSTORE_BASE64`, `TV_UPLOAD_KEYSTORE_PASSWORD`,
   `TV_UPLOAD_KEY_ALIAS`). Yoksa AAB de sürüm anahtarıyla imzalanır.

**Yerel derleme (imzalı AAB):**
```sh
cd tv-android
TV_KEYSTORE_FILE=/yol/android-tv-release.jks TV_KEYSTORE_PASSWORD=… TV_KEY_ALIAS=couchsubs-tv \
  ~/Projeler/Web/enmera/ekip/heavy-job.sh gradle --no-daemon --max-workers=4 bundlePlayRelease
```
CI'da `tv-android` iş akışı AAB'yi `couchsubs-android-play` yapıtı olarak verir (GitHub sürümüne konmaz).

## 5. Mağaza kaydı

Metinler fastlane düzeninde: `tv-android/fastlane/metadata/android/{tr-TR,en-US}/`. Varsayılan dil **tr-TR**.

| Alan | tr-TR | en-US |
|---|---|---|
| Ad (≤ 30) | CouchSubs: Türkçe Altyazı (25) | CouchSubs: Turkish Subtitles (28) |
| Kısa açıklama (≤ 80) | `short_description.txt` (76) | `short_description.txt` (75) |
| Tam açıklama (≤ 4000) | `full_description.txt` (~2300) | `full_description.txt` (~2250) |
| Sürüm notu | `changelogs/15.txt` | `changelogs/15.txt` |

- Ad, simge ve görsellerde konsol markası ya da logosu yok; açıklamanın sonunda bağlantısızlık ve marka notu var.
  Ad yalnız "CouchSubs" da olabilir (diğer mağazalardaki gibi).
- **Kategori:** Uygulama › Araçlar (Tools). Etiketler: altyazı, erişilebilirlik.
- **Geliştirici adı:** Enmera. **E-posta:** `<destek e-postası>` (kişisel adres kullanmayın). **Web sitesi:**
  https://github.com/yorulmazsinan/couchsubs
- **Gizlilik politikası URL'si:** https://github.com/yorulmazsinan/couchsubs/blob/main/docs/privacy-tv.md (dal `main`'e
  birleşince açılır; istenirse enmera sitesinde de yayınlanabilir).
- **Fiyat:** Ücretsiz. **Uygulama içi satın alma:** yok. **Reklam:** yok.

## 6. Görseller

Hepsi betikle üretilir ve fastlane klasörlerindedir (`images/`):

| Dosya | Boyut | Kaynak |
|---|---|---|
| `icon.png` | 512×512 | `swift scripts/make-play-assets.swift` (design/logo.svg) |
| `featureGraphic.png` | 1024×500 | aynı betik; dile göre alt yazı |
| `tvBanner.png` | 1280×720 | aynı betik (Play'in istediği Android TV afişi) |
| `tvScreenshots/1-demo … 4-panel.png` | 1920×1080 | `scripts/play-screenshots.sh` |
| `res/drawable-nodpi/banner.png` | 320×180 | aynı Swift betiği (TV ana ekranı afişi) |

**Ekran görüntüleri hakkında:** Emülatörde Android TV sistem görüntüsü yok; görüntüler TV uygulamasının **gerçek
sayfasının** (tv-webos + `tv-android/platform.js`, aynı CSS ve metinler) Chrome'da 1920×1080 çizilmesiyle üretildi.
Android köprüsü ve bilgisayar bağlantısı taklit edildi (`scripts/play-screenshot-harness.js`); altyazı metinleri demo
türünden kurgu cümlelerdir. Arka plan düz koyu: TV'de HDMI görüntüsü sayfanın altındaki ayrı katmandadır ve TV'nin ekran
görüntüsünde de (adb `screencap`) siyah çıkar. Yani bunlar **taklit ortamda çizilmiş görüntülerdir**, TV'den alınmadı.
TV-G4 ("değiştirilmemiş, güncel sürümü doğru gösteren en az bir görüntü") için yüklemeden önce bir tanesini gerçek TV'den
almanız önerilir: `adb exec-out screencap -p > demo.png` (demo açıkken).

1. `1-demo` – demo: örnek altyazı ve DEMO notu
2. `2-stacked` – hızlı konuşma: önceki satır üstte soluk
3. `3-waiting` – ilk ekran: "Bilgisayarınızda CouchSubs uygulamasını açın" ve "Demoyu izle"
4. `4-panel` – durum paneli: HDMI, bağlantı, son altyazı, kumanda tuşları

## 7. Play Console formlarının cevapları

**Uygulama erişimi:** "Bazı işlevler kısıtlı" seçilir, giriş bilgisi yoktur. Talimat (EN):

> No account or login. The app shows subtitles sent by the free CouchSubs computer app (Mac/Windows) on the same network,
> so a console and computer are needed for the full experience. For review, on the first screen press OK on "Watch the
> demo" (or the Blue key) to play sample subtitles over the picture; Back leaves the demo, Back on the first screen
> returns to the home screen. OK (or Green) opens the status panel; Left/Right there switch HDMI input, Up/Down move the
> subtitles. On devices without an HDMI input the picture behind the subtitles stays black.

**Reklam:** Hayır, reklam içermez.

> **Not (19 Kas 2026):** TV uygulamasında tanıtım penceresi yok; mobil tanıtım penceresi yayına girince Play "Reklam içerir" beyanı (mobil uygulama için) yeniden değerlendirilecek.

**İçerik derecelendirmesi (IARC):** Kategori "Yardımcı program, verimlilik, iletişim veya diğer". Şiddet, cinsellik,
küfür, uyuşturucu, kumar: hayır. Kullanıcılar arası etkileşim ya da içerik paylaşımı: hayır. Konum paylaşımı: hayır.
Dijital satın alma: hayır. Sınırsız internet/tarayıcı: hayır. (Ekrandaki altyazı, kullanıcının kendi oyununun metnidir;
uygulamanın sunduğu içerik değildir. Demo satırları "Silahını indir!" gibi şiddet içermeyen kurgu diyaloglardır.)
Beklenen sonuç: PEGI 3 / ESRB Everyone / USK 0.

**Hedef kitle:** 16–17 ve 18 yaş üstü (13 yaş altı seçilmez; Aileler politikası uygulanmaz). "Çocuklara hitap ediyor
mu?": Hayır. İsterseniz 13–15 de eklenebilir.

**Veri güvenliği (Data safety):**

| Soru | Cevap |
|---|---|
| Uygulama gerekli kullanıcı verisi türlerinden birini topluyor ya da paylaşıyor mu? | **Hayır** |
| (Bunun üzerine diğer bölümler sorulmaz) | – |
| Konum, kişisel bilgi, finans, sağlık, mesaj, fotoğraf/video, ses, dosya, takvim, kişiler, uygulama etkinliği, web geçmişi, uygulama bilgisi ve performansı, cihaz kimlikleri | Toplanmaz, paylaşılmaz |
| Hesap oluşturma / silme | Hesap yok |
| Dayanak (kodda doğrulandı) | Tek izin INTERNET; analiz, reklam, çökme raporu SDK'sı yok (bağımlılık yalnız JUnit, test için); ağ trafiği yalnız ev ağındaki bilgisayara: `/hello` taraması ve `/events` SSE, dublaj sesleri; cihazda yalnız ayarlar (`localStorage`, `SharedPreferences`), `allowBackup=false` |

**Diğer beyanlar:** Devlet uygulaması: hayır. Finans özellikleri: hayır. Sağlık: hayır. Haber: hayır. Reklam kimliği:
kullanılmıyor. Ön plan servisi izinleri: Play paketinde yok, beyan gerekmez.

## 8. Play Console'da adım adım (Sinan Bey)

1. **Uygulama oluştur:** ad "CouchSubs", varsayılan dil Türkçe (tr-TR), Uygulama, Ücretsiz. Beyanları onaylayın.
2. **İmza seçimi** (§4): yol A ya da B. İlk sürümü yüklemeden önce karar verin.
3. **Form faktörü:** Test ve yayın › Kurulum › Gelişmiş ayarlar › Form faktörleri › Android TV'yi ekleyin, TV kurallarını
   kabul edin. Ayrı "Yalnız Android TV" kanalı sorulursa onu kullanabilirsiniz (uygulama yalnız TV'de çalışır).
4. **Uygulama içeriği:** gizlilik politikası URL'si, reklam (yok), uygulama erişimi, içerik derecelendirmesi, hedef kitle,
   veri güvenliği, diğer beyanlar: cevaplar §7'de.
5. **Ana mağaza kaydı:** fastlane klasöründeki metinleri (tr-TR, sonra en-US çevirisi olarak) yapıştırın; simge, öne
   çıkan görsel, **TV afişi** ve **TV ekran görüntüleri** (Android TV bölümü) yükleyin. Kategori Araçlar, iletişim
   bilgileri.
6. **AAB:** CI'da `tv-android` iş akışını (ya da sürüm iş akışını) çalıştırın, `couchsubs-android-play` yapıtındaki
   `CouchSubs-androidtv-play.aab`'yi indirin. Yükleme anahtarı sırları tanımlı olmalı (§4).
7. **Dahili test:** Test › Dahili test › yeni sürüm › AAB'yi yükleyin, sürüm notunu yapıştırın, test kullanıcısı olarak
   kendi Google hesabınızı ekleyin. Katılım bağlantısıyla TV'nizde Play'den kurup deneyin (demo, bilgisayarla bağlantı,
   Geri ile çıkış).
8. **Üretim:** Kurumsal hesap olduğu için 12 test kullanıcısı / 14 gün kapalı test şartı yoktur. Dahili testteki sürümü
   Üretim'e taşıyın, ülkeleri seçin (Türkiye ve diğerleri), incelemeye gönderin. TV incelemesi normal incelemeden ayrıca
   yapılır; ret ya da istekler hesabın e-postasına gelir.
9. **Cihaz kataloğu (isteğe bağlı):** HDMI girişi olmayan yayın cihazlarını (Chromecast with Google TV, Google TV Streamer,
   Mi Box, Shield gibi) hariç tutabilirsiniz; tutmazsanız açıklama bu cihazlarda çalışmadığını zaten söyler.

## 9. Politika riskleri

- **Kapalı test şartı:** 2023 sonrası açılan *kişisel* hesaplar üretimden önce 12+ kullanıcıyla 14 gün kapalı test
  yapmak zorunda. Enmera **kurumsal** hesap (doğrulandı): şart yok.
- **TV incelemesi:** §3'teki kurallar. En olası itirazlar: TV-G4 (görüntüler taklit ortamda çizildi; bir gerçek görüntü
  ekleyin) ve "asgari işlev" (uygulama bilgisayar olmadan yalnız demo gösterir; açıklama ve inceleme notu bunu açıkça
  söylüyor).
- **Fikri mülkiyet:** Konsol markası ad, simge ve görsellerde yok; açıklamada yalnız bağlantısızlık notu var. Uygulama içi
  birkaç yardım metni "PS5" der (betimleyici kullanım).
- **Hedef API:** TV için şu an 34+, uygulama 35. Her yıl Ağustos sonunda yükselir; takip edin.
- **Katman modu:** Play'e ileride eklenmek istenirse TV-TR ile çelişir; ayrıca `specialUse` ön plan servisi beyanı ve video
  gerekir. Önerilmez.
- **Açık metin HTTP:** yalnız ev ağı; Play'in güvenlik taraması uyarı verebilir ama engellemez.
