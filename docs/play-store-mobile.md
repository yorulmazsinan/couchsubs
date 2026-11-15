# Android telefon uygulaması: Google Play'de yayın

Yayıncı: **Enmera** (kurumsal Play Console hesabı, geliştirici adı "Enmera"). Uygulama kimliği `com.couchsubs.mobile`.
Kod `feat/android-app` dalında, `couchsubs-android/` altında. Bu belgedeki "koddan doğrulandı" notları o dalın
2026-11-13 tarihli `dcba204` işlemesine göredir (sürüm `0.1.0-beta.34`, versionCode 34). Hedef doğrudan **üretim kanalı**.
Play Console'a henüz hiçbir şey yüklenmedi. Android TV uygulaması için: [play-store-tv.md](play-store-tv.md).

## 0. Yüklemeden önce kapanması gerekenler (engel)

| # | Konu | Durum | Ne yapılmalı |
|---|---|---|---|
| 1 | **Hedef API** | `targetSdk 35` | Play, 31 Ağustos 2026'dan beri yeni telefon uygulamalarında **API 36** istiyor ([play-store-tv.md](play-store-tv.md) §2'deki not). 35 ile yükleme reddedilir. `targetSdk 36` / `compileSdk 36` yapılıp Android 16 davranış değişiklikleri (kenardan kenara ekran, ön plan hizmeti kuralları) denenmeli. Kesin tarih Play Console'da kontrol edilmeli. |
| 2 | **İnceleyici PS5'siz uygulamaya giremiyor** | Kurulum (PSN girişi → PS5 eşleme → altyazı hedefi) atlanamıyor; "Geç" yalnız karşılama sayfalarında var (`MainActivity` `Routes.next()`). | Ana ekrana PS5'siz ulaşan bir **demo modu** ya da "Şimdilik geç" eklenmeli (TV uygulamasındaki demo gibi: örnek altyazı akışı). Eklenmezse §4.3'teki video bağlantısı zorunlu, yine de "işlev erişilemiyor" reddi riski yüksek. |
| 3 | **16 KB sayfa boyutu** | Uygulamada yerel kod var (chiaki-ng, `couchsubs-jni`, NDK 27). | API 35+ hedefleyen uygulamalarda `.so` dosyaları 16 KB hizalı olmalı. AAB derlenince `zipalign -c -P 16 -v 4 app.apk` ya da `llvm-readelf -l lib*.so` (LOAD hizası `0x4000`) ile **kontrol edilmeli**; değilse CMake'e `-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON` (ya da NDK r28+). |
| 4 | **AAB derlemesi** | `build.gradle`'da yalnız APK sürüm imzası var, `bundleRelease` CI'da yok. | `bundleRelease` ile AAB, yükleme anahtarıyla imzalı (§1). |
| 5 | **Firebase ve Meta kimlikleri** | `google-services.json` ve `secrets.properties` depoda yok; yoksa ölçüm hiç açılmaz. | Play derlemesinde bunlar var mı, karar verilmeli: veri güvenliği formu (§4.6) buna göre doldurulur. |
| 6 | **Gizlilik bağlantısı** | Uygulama içi bağlantı `url_privacy` = GitHub'daki `PRIVACY.md`. | Mağazadaki URL ile aynı olsun diye `https://couchsubs.enmeraapps.com/gizlilik` yapılması önerilir (`feat/android-app` dalında, o dalın sahibi değiştirmeli). |
| 7 | **İngilizce arayüz** | Yalnız `values/strings.xml` (Türkçe); `values-en` yok. | İngilizce mağaza kaydı "uygulama Türkçe" der (§2). İngilizce arayüz eklenirse o cümle kalkar. |

## 1. İmza: Play App Signing (Google'ın ürettiği anahtar)

Karar: uygulama imza anahtarını **Google üretir ve saklar**; biz yalnız **yükleme anahtarıyla** imzalarız.

1. Play Console › uygulama › Test ve yayın › Kurulum › **Uygulama imzalama**: varsayılan "Google tarafından oluşturulan
   anahtarı kullan" seçili kalır (ilk sürümü oluştururken de sorulur). Uygulama imza anahtarı sonradan değiştirilemez.
2. Yükleme anahtarı: mevcut telefon sürüm anahtarı (`~/.config/couchsubs/android-signing.properties`, takma ad `couchsubs`)
   ilk AAB'yi imzalar ve Play onu yükleme anahtarı olarak kaydeder. Ayrı bir yükleme anahtarı istenirse:
   ```sh
   keytool -genkeypair -v -keystore upload-mobile.keystore -alias upload -keyalg RSA -keysize 4096 -validity 10000
   ```
   Anahtar ve şifre depoya konmaz; kaybolursa Play Console'dan yükleme anahtarı sıfırlama istenebilir.
3. **Sonuç (bilinçli):** Play'den kurulan kopya ile sitedeki/GitHub'daki doğrudan APK'nın imzası **farklıdır**. Doğrudan
   APK'yı kurmuş kullanıcı Play sürümünü kurmadan önce onu silmeli (ayarlar, PSN ve PS5 eşlemesi yeniden yapılır). Site
   bunu zaten söylüyor ("Play sürümü çıkınca bir kez silip yeniden kurmanız gerekebilir").
4. Firebase/Google girişleri için SHA-1 gerekirse Play Console › Uygulama imzalama sayfasındaki **uygulama imza
   anahtarı** sertifikasının parmak izi kullanılır (yükleme anahtarınınki değil). Bugün kodda Google girişi yok.

## 2. Mağaza kaydı

Varsayılan dil **Türkçe (tr-TR)**, ikinci dil **İngilizce (en-US)**. Uygulama ücretsiz.

### Marka kuralları (Sony)

- Ad, simge, öne çıkan görsel ve ekran görüntülerinde **PlayStation/PS5 logosu, PlayStation düğme simgeleri (üçgen,
  daire, çarpı, kare) ya da Sony'nin yazı biçimi yok**.
- "PS5" yalnız tanımlayıcı olarak geçer ("PS5 oyunlarına", "PS5 ile çalışır"); ad yalnız "CouchSubs" + betimleme.
- Açıklamanın sonunda bağlantısızlık ve marka notu var. Oyun adları yalnız hangi yamaların hazır olduğunu söylemek için
  düz metin olarak geçer, oyun görselleri ya da logoları kullanılmaz.
- Risk (bkz. §6): PSN girişi Sony'nin Remote Play istemci kimliğiyle yapılıyor. Sony'den marka/telif şikâyeti gelirse
  uygulama kaldırılabilir; bu metinler o riski azaltır, ortadan kaldırmaz.

### Ad, kısa açıklama

| Alan | tr-TR | en-US |
|---|---|---|
| Ad (≤ 30) | `CouchSubs: Türkçe Yama` (22) | `CouchSubs: Turkish Subtitles` (28) |
| Kısa açıklama (≤ 80) | `PS5 oyunlarına Türkçe yama: telefon İngilizce altyazıyı okur, Türkçeye çevirir.` (79) | `Turkish subtitles for PS5 games, read and translated by your phone. Free.` (73) |

Not: TV uygulamasının adı "CouchSubs: Türkçe Altyazı". Telefon için "Türkçe Yama" sitedeki deyişle aynı; ikisi aynı
geliştirici sayfasında yan yana durur. "Yama" sözcüğü oyun dosyasını değiştiriyor gibi anlaşılırsa (inceleyici
sorarsa) ad "CouchSubs: Türkçe Altyazı" yapılabilir.

### Tam açıklama: tr-TR (2451 karakter, sınır 4000)

```
CouchSubs, Türkçe dil desteği olmayan PS5 oyunlarına Türkçe yama getirir. Telefonun oyundaki İngilizce altyazıyı okur, Türkçeye çevirir ve TV'de ya da kendi ekranında gösterir. Sen kumandayı bırakmadan, her zamanki gibi oynarsın.

NASIL ÇALIŞIR
• Telefon, PS5'in kendi Uzaktan Oynatma (Remote Play) özelliğiyle ev ağından konsola bağlanır. Bilgisayar gerekmez.
• Görüntüdeki İngilizce altyazı telefonun içinde, cihaz üstünde okunur. Görüntü kaydedilmez, hiçbir yere gönderilmez.
• Türkçe çeviri telefonda büyük yazıyla ya da TV'de oyunun üstünde görünür.

HAZIR TÜRKÇE YAMALAR
Bu oyunların bütün metni önceden çevrildi. Oyunu açınca yama kendiliğinden seçilir; altyazı beklemeden ve internetsiz gelir:
• Grand Theft Auto V
• Red Dead Redemption 2
• Elden Ring
• Mafia: The Old Country
• Assassin's Creed Shadows
• Death Stranding 2
• Death Stranding Director's Cut
• Marvel's Spider-Man 2
• Call of Duty: Modern Warfare (2019)
Yeni yamalar ve düzeltmeler kendiliğinden iner. Listede olmayan oyunlar da çalışır: yamada olmayan satırı seçtiğin çeviri motoru çevirir.

ÇEVİRİ MOTORU
• Ücretsiz: Google ML Kit ile telefonun içinde çeviri. Dil modeli ilk kullanımda bir kez iner, sonra internet gerekmez.
• İstersen kendi anahtarınla DeepL, Gemini, OpenAI ya da Claude.

NE GEREKİR
• PS5 ve aynı Wi-Fi ağında bir Android telefon (Android 8 ve üstü, 64 bit).
• Ücretsiz ikinci bir PSN hesabı. Uzaktan Oynatma aynı hesapla bağlanınca oynadığın oturumu devralır; ikinci hesap yalnız görüntüyü alır, sen kendi hesabınla ve kendi kumandanla oynamaya devam edersin. PS Plus gerekmez.
• Altyazıyı TV'de görmek istersen TV'de CouchSubs TV uygulaması (Android TV, Google TV, LG, Samsung). Altyazıyı telefonda göstermek için başka bir şey gerekmez.

ÜCRETSİZ, HESAPSIZ
Abonelik, satın alma, reklam ve hesap yok. Ayarların yalnız telefonunda durur. Kaynak kodu açık (AGPL-3.0).

GİZLİLİK
PSN girişi Sony'nin kendi sayfasında yapılır; şifren uygulamaya geçmez. Anonim kullanım istatistikleri ve hiçbir yamada olmayan İngilizce satırların ortak havuza gönderilmesi ayarlardan kapatılabilir.

Kurulum rehberi ve SSS: https://couchsubs.enmeraapps.com

CouchSubs bağımsız bir uygulamadır; Sony Interactive Entertainment ile bağlantılı değildir, onun tarafından onaylanmamış ya da desteklenmemiştir. PlayStation, PS5 ve Remote Play, Sony Interactive Entertainment Inc.'in markalarıdır ve burada yalnız uyumluluğu anlatmak için anılır. Oyun adları sahiplerinin markalarıdır.
```

### Tam açıklama: en-US (2529 karakter)

```
CouchSubs brings Turkish subtitles to PS5 games that have no Turkish language option. Your phone reads the English subtitles in the game, translates them into Turkish and shows them on your TV or on the phone itself. You keep playing as usual, controller in hand.

The app is in Turkish.

HOW IT WORKS
• The phone connects to your PS5 over your home network with the console's own Remote Play feature. No computer needed.
• The English subtitles in the picture are read on the phone itself. The picture is never stored or uploaded.
• The Turkish translation appears in large text on the phone, or on the TV over the game.

READY-MADE TURKISH PACKS
The full text of these games is already translated. The pack is picked automatically when you start the game, so subtitles appear instantly, even offline:
• Grand Theft Auto V
• Red Dead Redemption 2
• Elden Ring
• Mafia: The Old Country
• Assassin's Creed Shadows
• Death Stranding 2
• Death Stranding Director's Cut
• Marvel's Spider-Man 2
• Call of Duty: Modern Warfare (2019)
New packs and fixes download automatically. Other games work too: lines that are not in a pack are translated by the engine you choose.

TRANSLATION ENGINE
• Free: on-device translation with Google ML Kit. The language model downloads once on first use, then no internet is needed.
• Or use your own DeepL, Gemini, OpenAI or Claude key.

WHAT YOU NEED
• A PS5 and an Android phone on the same Wi-Fi (Android 8 or later, 64-bit).
• A free second PSN account. Remote Play with the same account takes over the session you are playing; the second account only receives the picture, so you keep playing with your own account and controller. No PS Plus needed.
• To see subtitles on the TV, the CouchSubs TV app (Android TV, Google TV, LG, Samsung). Nothing else is needed to show them on the phone.

FREE, NO ACCOUNT
No subscription, no purchases, no ads, no account. Your settings stay on your phone. Open source (AGPL-3.0).

PRIVACY
PSN sign-in happens on Sony's own page; your password never passes through the app. Anonymous usage statistics and sending English lines that are in no pack to the shared pool can be turned off in settings.

Setup guide and FAQ: https://couchsubs.enmeraapps.com

CouchSubs is an independent app. It is not affiliated with, endorsed or sponsored by Sony Interactive Entertainment. PlayStation, PS5 and Remote Play are trademarks of Sony Interactive Entertainment Inc. and are mentioned only to describe compatibility. Game titles are trademarks of their respective owners.
```

**Metinlerin dayanağı (doğrulandı):**

- Oyun listesi: `core/Sources/CouchSubsCore/Resources/packs/` (main ve `feat/android-app` aynı, dokuz paket) ve sitedeki
  "Bu oyunların Türkçe yaması hazır" listesi. Paketler her derlemede uygulamayla gelir (`copyCouchSubsPacks`), yenileri
  `server/packs`'ten iner. Yeni paket eklenince iki açıklama da güncellenmeli.
- Remote Play yalnız ev ağında: `couchsubs-jni.c`'de `holepunch_info = NULL` (internet üzerinden bağlantı yok).
- Android 8+, 64 bit: `minSdk 26`, `abiFilters arm64-v8a`.
- Çeviri motorları: `EngineChoice { FREE, DEEPL, GEMINI, OPENAI, CLAUDE }`; ücretsiz motor `MlKitTranslator` (model
  ~30 MB, ilk kullanımda iner).
- TV'de gösterme: telefon ev ağında 8787 portunda altyazı sunucusu açar, TV uygulaması telefonu bulur. LG/Samsung TV
  uygulamasını ilk kez kurmak için bir kez bilgisayardaki CouchSubs gerekiyor (`target_tv_body` metni); açıklama bunu
  ayrıntılandırmıyor, sitedeki rehbere bırakıyor.

**Sitedeki görseller eski:** `telefon-paketler.webp` ve ana ekran görüntüsü "7 oyun" / "4 oyun daha" diyor, kod ise dokuz
paket taşıyor ve "3 oyun daha" diyor (`main_packs_games`). Gerçek ekran görüntüsü alındığında (§3) düzelir.

### Diğer kayıt alanları

| Alan | Değer |
|---|---|
| Uygulama ya da oyun | Uygulama |
| Ücretli / ücretsiz | Ücretsiz (sonradan ücretliye çevrilemez) |
| **Kategori** | **Araçlar (Tools)** — öneri. Uygulama oyun değil, oyunun yanında çalışan bir yardımcı; TV uygulamasıyla aynı kategori. Alternatif "Eğlence"; "Oyunlar" kategorisi seçilmez (oyun değil, içerik derecelendirmesi de değişir). |
| Etiketler | altyazı, çeviri, erişilebilirlik (Console'un sunduğu listeden en yakınları) |
| E-posta | `info@enmera.com.tr` |
| Web sitesi | https://couchsubs.enmeraapps.com |
| Telefon | boş bırakılabilir |
| **Gizlilik politikası URL'si** | **https://couchsubs.enmeraapps.com/gizlilik** (Android bölümü eklendi; bkz. §5). İngilizce metin gerekirse: https://github.com/yorulmazsinan/couchsubs/blob/main/PRIVACY.md |
| Uygulama içi ürün / abonelik | Yok |
| Reklam | Yok |

## 3. Görseller

Hepsi `swift scripts/make-play-mobile-assets.swift` (depo kökünden) ile üretilir ve `store/play-mobile/` altındadır:

| Dosya | Boyut | Kaynak |
|---|---|---|
| `icon.png` | 512×512, 32 bit | `design/logo.svg` (TV'nin Play simgesiyle aynı çizim) |
| `tr-TR/featureGraphic.png` | 1024×500, 24 bit | logo + "Oyun altyazıları Türkçe, telefonda ve TV'de" |
| `en-US/featureGraphic.png` | 1024×500, 24 bit | logo + "Game subtitles in Turkish, on phone and TV" |
| `phoneScreenshots/1-karsilama.png` … `6-hedef.png` | 1080×1920 (9:16), 24 bit | `docs/screenshots/telefon/` |

**Ekran görüntüleri nasıl üretildi:** Sitedeki `site/public/img/telefon-*.webp` dosyaları `docs/screenshots/telefon/*.png`'nin
WebP kopyasıdır (ikisi de 780×1688). Bu oran (≈ 9:19,5) Play'in "uzun kenar kısa kenarın en çok iki katı" kuralını aşar
(1688/780 = 2,16), bu yüzden doğrudan yüklenemez. Betik PNG kaynağı 1920 yüksekliğe büyütür ve uygulamanın zemin
rengiyle (`#141518`) 1080 genişliğe ortalar; kırpma yok. 1080×1920 ve 9:16 olduğu için Play'in öneri/öne çıkarma
şartlarını da karşılar. Sıra: karşılama, ana ekran, çeviri sürüyor, oyun paketleri, ikinci PSN hesabı, altyazı hedefi.
`09-altyazi.png` alınmadı: telefondaki altyazı ekranı yatay, kaynak dikey tuvalde kesik çizilmiş.

**Önemli:** `docs/screenshots/telefon/` görüntüleri **tasarım panolarından** üretildi (commit `0529e67`), uygulamanın
kendisinden alınmadı. Play, görüntülerin uygulamayı doğru göstermesini ister. Yüklemeden önce en az iki tanesinin
gerçek cihazdan alınması önerilir:

```sh
adb exec-out screencap -p > ana.png          # telefon bağlıyken, ilgili ekran açıkken
```

Gerçek görüntüler aynı adlarla `docs/screenshots/telefon/` altına konup betik yeniden çalıştırılırsa aynı biçimde
çerçevelenir. Ayrıca yatay **telefondaki altyazı** ekranının (`PhoneSubtitleActivity`) gerçek bir görüntüsü (16:9,
ör. 1920×1080) eklenmesi iyi olur: uygulamanın asıl işini o gösteriyor. Görüntülerde PS5 sistem menüsü, PlayStation
logoları ya da oyun görüntüsü olmamalı (oyun görüntüsü telif riski taşır; altyazı ekranı düz koyu zemin kullanıyor).

## 4. Uygulama içeriği formları (Play Console sırasıyla)

Play Console › uygulama › **Politika ve programlar › Uygulama içeriği**.

### 4.1 Gizlilik politikası

URL: `https://couchsubs.enmeraapps.com/gizlilik` (canlı, HTTP 200). Sayfada Android telefon bölümü var (§5).

### 4.2 Reklamlar

"Uygulamanızda reklam var mı?" → **Hayır.** (Doğrulandı: AdMob/UMP bağımlılığı yok; `AD_ID`,
`ACCESS_ADSERVICES_AD_ID` ve `ACCESS_ADSERVICES_ATTRIBUTION` izinleri manifestte `tools:node="remove"` ile çıkarılıyor.
Meta App Events reklam göstermez; bkz. §4.6.)

### 4.3 Uygulama erişimi

Seçim: **"Tüm işlevler veya bazı işlevler kısıtlanmış"**. Giriş bilgisi verilemez (giriş, inceleyicinin kendi Sony PSN
hesabıyla yapılır ve PS5 gerekir). Talimat adı: "PS5 and PSN account required". Talimat (EN, Console'a yapıştırılır):

> CouchSubs has no account of its own. It reads English subtitles from a game running on the user's own PlayStation 5
> console via the console's Remote Play feature on the same Wi-Fi network, translates them into Turkish on the device,
> and shows them on the phone or on a TV on the same network.
>
> Full use therefore needs: (1) a PS5 on the same Wi-Fi as the phone, (2) a free PlayStation Network account. Sign-in
> happens on Sony's own page inside the app ("Sony ile giriş yap"); we never receive the password. We cannot share a
> PSN account because the console must be paired with it. Steps: open the app › swipe the three welcome pages ›
> "Sony ile giriş yap" and sign in with a PSN account › on the PS5, signed in with that account, open Settings ›
> System › Remote Play › Pair Device and type the 8-digit code into the app › choose "Bu telefonda" (this phone) ›
> start a game on the PS5 › tap "Çeviriyi başlat" (Start translation). A foreground notification appears while the
> phone receives the Remote Play stream; "Çeviriyi durdur" stops it.
>
> A video showing the full flow on a real PS5: <VİDEO BAĞLANTISI>
>
> The app UI is in Turkish. Contact: info@enmera.com.tr

**Açık konu (§0 madde 2):** Uygulamaya PS5'siz girilebilen bir demo/geç yolu eklenirse talimat şöyle kısalır:
"Without a PS5, tap 'Şimdilik geç' on the sign-in screen to reach the main screen and the demo." Bu yol yoksa inceleme
büyük olasılıkla video üzerinden yapılır; videoyu §4.7'deki çekimle birlikte hazırlayın (YouTube "liste dışı").

### 4.4 İçerik derecelendirmesi (IARC anketi)

- E-posta: `info@enmera.com.tr`. Kategori: **"Diğer tüm uygulama türleri"** (Yardımcı program, verimlilik, iletişim
  ya da diğer). "Oyun" seçilmez.
- Şiddet, korku, cinsellik/çıplaklık, küfür/kaba dil, uyuşturucu/alkol/tütün, ayrımcılık, kumar: **Hayır**.
  Gerekçe: uygulamanın kendi içeriği yalnız arayüz metinleri. Ekranda görünen altyazı, kullanıcının kendi PS5'inde
  oynadığı ve kendi derecelendirmesi olan oyunun metnidir; uygulama bunu üretmez, yalnız çevirir.
- Kullanıcılar arası etkileşim / içerik paylaşımı (sohbet, kullanıcı içeriği yayınlama): **Hayır**. (Ortak havuza giden
  satırlar başka kullanıcılara gösterilmez; yalnız Enmera'nın yeni paketler hazırlamasına girdi olur.)
- Kullanıcının konumunu başka kullanıcılarla paylaşma: **Hayır**.
- Dijital ürün satın alma: **Hayır**.
- Sınırsız internet erişimi / web tarayıcı: **Hayır** (WebView yalnız Sony giriş sayfasını açar, yönlendirme yakalanır;
  serbest gezinme yok — `OnboardingScreens.kt`).
- Uygulama bir oyun mu / oyun içeriği yayınlıyor mu: **Hayır**.
- Beklenen sonuç: PEGI 3, ESRB Everyone, USK 0, IARC 3+. (Sonuç bundan yüksek çıkarsa sorun değil, yayın engellenmez.)

### 4.5 Hedef kitle ve içerik

- **Hedef yaş grupları: yalnız "18 ve üstü"** (öneri). Gerekçe:
  1. Uygulama varsayılan olarak açık **Firebase Analytics, Crashlytics ve Meta App Events** taşıyor. 13 yaş altını
     seçmek Aileler politikasını, Meta SDK'sının yasaklanmasını ve ayrı izin akışını getirir; 13–17'yi seçmek de
     Avrupa'da (GDPR md. 8, 16 yaş) ve Play'in genç kullanıcı kurallarında ek yük getirir.
  2. Kullanım bir ikinci **PSN hesabı** açmayı ve konsolu eşlemeyi gerektirir; Sony'de 18 yaş altı hesaplar aile
     yöneticisinin denetimindeki çocuk hesaplarıdır.
  3. Hazır yamaların çoğu (GTA V, RDR2, Elden Ring, Mafia, CoD MW, AC Shadows) PEGI 16/18 oyunlar.
  4. Seçim kimseyi engellemez, yalnız beyandır; uygulamanın kendi içeriği yine PEGI 3 çıkar.
  Alternatif: TV uygulamasında olduğu gibi "16–17 ve 18 ve üstü". O durumda varsayılan açık ölçüm için 16–17 yaşta
  sorun çıkabileceği "kontrol edilmeli".
- "Uygulamanız çocuklara hitap edebilir mi?" → **Hayır** (ikon, renkler, dil çocuklara yönelik değil).
- Aileler politikası uygulanmaz.

### 4.6 Veri güvenliği (Data safety)

Aşağıdaki cevaplar **Firebase ve Meta kimlikleri Play derlemesine konursa** geçerlidir (§0 madde 5). Konmazlarsa
"Uygulama etkinliği" ve "Uygulama bilgileri ve performansı" satırlarındaki Firebase/Meta payı düşer, ortak havuz ve
ML Kit kalır.

**Genel sorular**

| Soru | Cevap |
|---|---|
| Uygulama gerekli veri türlerinden birini topluyor ya da paylaşıyor mu? | **Evet** |
| Toplanan bütün veriler aktarımda şifreleniyor mu? | **Evet** — internete giden her şey HTTPS (Firebase, Meta, ortak havuz `https://couchsubs-pool.enmera.workers.dev`, paket sunucusu, Sony, DeepL/Gemini/OpenAI/Anthropic). Ev ağındaki PS5 bağlantısı Remote Play'in kendi şifrelemesini kullanır; TV'ye giden altyazı ev ağında düz HTTP'dir ama bu "toplama" değildir (cihazdan geliştiriciye ya da üçüncü tarafa gitmez). |
| Hesap oluşturma | **Uygulamada hesap yok** (PSN girişi Sony'nin hesabıdır, uygulama hesap açmaz). Bu yüzden hesap silme URL'si gerekmez. |
| Kullanıcılar verilerinin silinmesini isteyebilir mi? | **Evet**: `info@enmera.com.tr` (gizlilik sayfasında yazıyor). Ortak havuz satırları kuruluma özgü rastgele kimlikle tutulur; kullanıcı Profil'den kimliği göremediği için silme ancak kimlik verilirse yapılabilir — kontrol edilmeli (Profil'de kurulum kimliğini gösteren bir satır eklenebilir). |
| Bağımsız güvenlik incelemesi (MASA) | Hayır |

**Toplanan veri türleri**

| Veri türü (Play adı) | Ne | Toplanır | Paylaşılır | İsteğe bağlı mı | Amaç |
|---|---|---|---|---|---|
| Uygulama etkinliği › **Uygulama etkileşimleri** | Ekran görüntülemeleri (`screen_view`), olaylar: `onboarding_done` (hedef), `subtitle_session_start` (hedef, motor, paket açık mı), `subtitle_session_stop` (süre, paketten gelen satır sayısı, satır sayısı), `tv_connected` (TV sayısı), `pack_hit` (paket kimliği). Firebase Analytics; Meta'ya yalnız olay adı + uygulamanın açılışı/kurulumu | Evet | **Evet (Meta)** — muhafazakâr cevap, aşağıdaki nota bakın | Evet (Profil › Kullanım verisi; varsayılan açık) | Analiz |
| Uygulama etkinliği › **Kullanıcının oluşturduğu diğer içerik** | Okunan, hiçbir pakette olmayan İngilizce oyun satırının metni, ondan üretilen anahtar, ilk görüldüğü an (ortak havuz) | Evet | Hayır | Evet (Ayarlar › Ortak havuza katkı; varsayılan açık; kapatınca bekleyenler silinir) | Uygulama işlevi (yeni çeviri paketleri) |
| Uygulama bilgileri ve performansı › **Kilitlenme günlükleri** | Firebase Crashlytics çökme raporu | Evet | Hayır | Evet (Kullanım verisi) | Analiz |
| Uygulama bilgileri ve performansı › **Teşhis** | Crashlytics cihaz durumu; Google ML Kit'in API performans/kullanım ölçümleri | Evet | Hayır | ML Kit için hayır, Crashlytics için evet | Analiz, uygulama işlevi |
| Cihaz veya diğer kimlikler | Firebase uygulama örneği kimliği, Crashlytics kurulum kimliği, Meta'nın anonim kimliği, ortak havuzun kuruluma özgü rastgele UUID'si | Evet | Evet (Meta'nın anonim kimliği; muhafazakâr) | Ortak havuz ve Kullanım verisi kapatılınca gitmez | Analiz, uygulama işlevi |

Toplanmayanlar (doğrulandı): konum (IP'den ülke çıkarımı Firebase'in kendi işidir; uygulama konum izni istemez), ad,
e-posta, telefon, kişiler, mesajlar, fotoğraf/video, ses, dosyalar, takvim, sağlık, finans, web geçmişi, reklam kimliği.
**Oyun görüntüsü** yalnız bellekte yazı tanıma için işlenir, kaydedilmez, gönderilmez (`TranslationService` →
`SubtitleReader`, ML Kit Latin modeli uygulamayla gelir).

**Toplanmış sayılmayanlar ve gerekçesi (kontrol edilmeli):**

- **PSN girişi:** Sony'nin sayfası uygulama içi WebView'da açılır; şifre yalnız Sony'ye gider. Uygulama dönen tek
  kullanımlık kodu Sony'ye verip sayısal hesap kimliğini alır; erişim tokeni saklanmaz (`PsnAccount.kt`). Hesap
  kimliği ve PS5 eşleme anahtarları yalnız telefonda, Android Keystore anahtarıyla AES-GCM şifreli saklanır
  (`SecretStore`), yalnız ev ağındaki PS5'e gider. Geliştiriciye ya da başka üçüncü tarafa gitmediği için
  **toplanmış sayılmaz**. İnceleyici farklı düşünürse "Kişisel bilgiler › Kullanıcı kimlikleri: toplanır, paylaşılmaz,
  zorunlu, uygulama işlevi" eklenir.
- **Çevrimiçi çeviri motorları:** Kullanıcı kendi DeepL/Gemini/OpenAI/Claude anahtarını girip motoru kendisi seçerse
  okunan İngilizce satır (ve bağlam olarak son üç satır, AI motorlarında çevirileriyle) doğrudan o servise gider
  (`OnlineTranslators.kt`). Kullanıcının başlattığı, beklediği bir aktarım olduğu için Play'in tanımında **paylaşım
  değildir**; veri Enmera'ya gelmez. Muhafazakâr seçenek: "Kullanıcının oluşturduğu diğer içerik" satırında
  "Paylaşılır: Evet" işaretlemek. Öneri: işaretlemeyin, gizlilik politikasında açıkça yazıyor.
- **Paket indirme** (`HttpPackServer`): düz `GET`, kimlik ya da gövde göndermez.
- **ML Kit çeviri modeli:** ilk kullanımda Google'dan iner (indirme, veri toplama değil).

**Meta neden "paylaşılır":** Meta App Events, Meta'nın kendi koşullarıyla işlenir (salt hizmet sağlayıcı sayılması
tartışmalı). Uygulama reklam kimliğini toplamıyor, otomatik başlatma ve reklam kimliği manifestte kapalı, olay
parametresi gitmiyor (`Meta.mirror` yalnız ad). Yine de "paylaşılır" demek reddi önler; "paylaşılmaz" demek ileride
politika ihlali sayılabilir. Meta kaldırılırsa bu satırlar "Hayır" olur.

**Ölçüm varsayılan olarak açık** (`AppSettings` ve `MeasurementPolicy`: Kullanım verisi varsayılan açık; Meta karşılama
ekranından sonra başlar). Play formu bunu "isteğe bağlı" saymaya yeter (kullanıcı kapatabiliyor). Ama AB'deki
kullanıcılar için izin almadan analitik başlatmak GDPR açısından tartışmalıdır — **kontrol edilmeli** (gerekirse AB'de
varsayılanı kapalı yapmak ya da karşılamada tek satırlık bildirim eklemek).

### 4.7 Ön plan hizmeti beyanı (FOREGROUND_SERVICE_CONNECTED_DEVICE)

Play Console › Uygulama içeriği › **Ön plan hizmeti izinleri**.

- Hizmet: `service.TranslationService`, `android:foregroundServiceType="connectedDevice"`, Android 14+'da
  `startForeground(…, FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)`. Önkoşul izni `CHANGE_WIFI_MULTICAST_STATE` manifestte.
- Seçilecek görev türü: **"Bağlı cihaz" (Connected device)** › "Ağ bağlantısı gerektiren harici cihazlarla etkileşim".
- **Açıklama (EN, Console'a):**

> CouchSubs connects to the user's PlayStation 5 console on the same Wi-Fi network using Remote Play and continuously
> receives its video stream, reads the English subtitles on the device and serves the Turkish translation to a TV app
> on the same network (and to the phone screen). The user starts this explicitly with "Çeviriyi başlat" (Start
> translation) while playing on the console; the phone is usually put aside or its screen turns off during play, so
> the stream and the subtitle server must keep running while the app is in the background. A persistent notification
> with a "Çeviriyi durdur" (Stop translation) action is shown the whole time. The service stops when the user stops it,
> when the console session ends or cannot be reached. Deferring or interrupting the work would make subtitles stop
> appearing on the TV mid-game, so WorkManager or other APIs are not suitable.

- Kullanıcı etkisi: "Görev ertelenirse ya da kesilirse kullanıcı oyunun ortasında altyazıyı kaybeder."
- **Video (30–60 sn, YouTube "liste dışı", gerçek telefon + gerçek PS5)** — çekim senaryosu:
  1. **0–5 sn:** Telefonda CouchSubs ana ekranı ("Hazır", PS5 eşli). Arkada TV'de PS5'te oyun açık (oyun görüntüsü kısa
     ve bulanık/uzaktan; logo yakın çekimi yok).
  2. **5–12 sn:** "Çeviriyi başlat"a dokunulur. "PS5'e bağlanılıyor…", sonra "Altyazılar okunuyor".
  3. **12–20 sn:** Bildirim çekmecesi aşağı çekilir: kalıcı "Çeviri sürüyor — PS5 altyazıları okunup Türkçeye
     çevriliyor" bildirimi ve "Çeviriyi durdur" düğmesi görünür.
  4. **20–35 sn:** Ana ekran tuşuyla uygulamadan çıkılır, sonra telefonun ekranı kilitlenir. TV'de oyunda konuşma
     sürer, Türkçe altyazı TV'de görünmeye devam eder (hizmetin arka planda çalıştığını gösteren asıl sahne).
  5. **35–45 sn:** Telefon açılır, bildirimdeki "Çeviriyi durdur"a dokunulur; bildirim kaybolur, TV'deki altyazı durur.
  6. (İsteğe bağlı, 45–55 sn) Aynı akış "Bu telefonda" hedefiyle: yatay altyazı ekranı.
  Videonun açıklamasına bir satır: "CouchSubs foreground service (connectedDevice) demo: PS5 Remote Play stream +
  subtitle server for a TV on the local network."
- Diğer ön plan hizmeti türleri: yok (`specialUse`, `mediaProjection`, `dataSync` kullanılmıyor).

### 4.8 Diğer beyanlar

| Form | Cevap |
|---|---|
| Finansal özellikler | Hiçbiri |
| Sağlık (Health apps) | Sağlık özelliği yok |
| Haber uygulaması | Hayır |
| Devlet uygulaması | Hayır |
| COVID-19 temaslı izleme | Hayır |
| Reklam kimliği (Advertising ID) | **Hayır, kullanılmıyor** (izinler manifestten çıkarılıyor; Firebase `google_analytics_adid_collection_enabled=false`, Meta `AdvertiserIDCollectionEnabled=false`) |
| Tam ekran amaçlı bildirim, tam alarm, erişilebilirlik hizmeti, VPN, tüm dosyalara erişim, paket görünürlüğü (QUERY_ALL_PACKAGES) | Kullanılmıyor |
| Bildirim izni | `POST_NOTIFICATIONS` (Android 13+, ilk açılışta istenir); beyan formu yok |

## 5. Gizlilik politikası

- Site: `site/public/gizlilik.html` → https://couchsubs.enmeraapps.com/gizlilik. "Android telefon uygulaması" bölümü
  bu dalda eklendi ve yayınlandı.
- Depo: `PRIVACY.md` (Türkçe + İngilizce), aynı bilgiyle "Android telefon uygulaması / Android phone app" bölümü eklendi.
- İletişim ve silme talepleri: `info@enmera.com.tr`.

## 6. Politika riskleri

1. **Sony istemci kimliği ve marka (en büyük risk):** PSN girişi chiaki-ng'nin kullandığı Sony Remote Play istemci
   kimliği ve gizli anahtarıyla yapılıyor (`PsnAccount.kt`, masaüstüyle aynı). Sony şikâyet ederse Play uygulamayı
   kaldırabilir ve bu, geliştirici hesabına uyarı olarak yazılır (kurumsal hesabın diğer uygulamalarını da etkileyebilir).
   Azaltma: §2'deki marka kuralları; siteden doğrudan APK dağıtımının sürmesi.
2. **Uygulama erişimi / asgari işlev:** §0 madde 2. Demo yolu yoksa inceleme reddi olası.
3. **Ön plan hizmeti beyanı:** `connectedDevice` gerekçesi güçlü (gerçek harici cihaz, ağ bağlantısı), ama video
   eksikse ya da hizmetin arka planda neden sürdüğünü göstermiyorsa reddedilir. §4.7'deki 4. sahne şart.
4. **Veri güvenliği tutarlılığı:** Google, derlemedeki SDK'ları (Firebase, Meta, ML Kit) formla karşılaştırır.
   Form §4.6'daki gibi doldurulmazsa "veri güvenliği bölümü yanlış" uyarısı gelir.
5. **Hedef API ve 16 KB:** §0 madde 1 ve 3.
6. **Açık metin HTTP (`usesCleartextTraffic=true`):** ev ağında TV bulma (SSDP `LOCATION` adresi) ve TV'ye altyazı
   sunucusu için. Play uyarı verebilir, engellemez. İleride `network_security_config` ile yalnız özel ağ adreslerine
   izin verilebilir.
7. **AGPL ve üçüncü taraf lisansları:** uygulamada kaynak bağlantısı var (Ayarlar › Hakkında). chiaki-ng, OpenSSL,
   ML Kit lisans metinlerinin gösterildiği bir ekran yok — kontrol edilmeli.
8. **Kapalı test şartı yok:** Enmera kurumsal hesap; 12 kullanıcı / 14 gün kapalı test gerekmez, doğrudan üretime
   gönderilebilir. Yine de önce **dahili test** kanalında kendi telefonunuzda Play kopyasını denemeniz önerilir (imza
   ve Play'in eklediği APK bölme işlemi yerel kütüphaneyi bozmasın diye).

## 7. Play Console'da adım adım (Sinan Bey)

1. **Uygulama oluştur:** ad "CouchSubs: Türkçe Yama", varsayılan dil Türkçe (tr-TR), Uygulama, Ücretsiz; beyanları onaylayın.
2. **Uygulama içeriği** (§4): gizlilik URL'si, reklam yok, uygulama erişimi (video bağlantısıyla), içerik
   derecelendirmesi, hedef kitle 18+, veri güvenliği, ön plan hizmeti (video), diğer beyanlar.
3. **Ana mağaza kaydı** (§2): metinler, simge, öne çıkan görsel, telefon ekran görüntüleri (`store/play-mobile/`);
   en-US çevirisini ekleyin. Kategori Araçlar, e-posta, web sitesi.
4. **Ülkeler:** Türkiye başta; Türkçe konuşulan diğer ülkeler (KKTC Play'de ayrı ülke değil) ve yurt dışındaki Türk
   kullanıcılar için Almanya, Hollanda, Avusturya, Belçika, Fransa, İngiltere vb. ya da tüm ülkeler.
5. **AAB** (§0 engelleri kapandıktan sonra): Test ve yayın › Üretim › Yeni sürüm › Google tarafından oluşturulan imza
   anahtarını kabul edin › AAB'yi yükleyin › sürüm notu (tr-TR, en-US).
6. **İncelemeye gönder.** Ön plan hizmeti beyanı ve uygulama erişimi elle incelenir; birkaç gün sürebilir, istekler
   hesabın e-postasına gelir.
7. Yayından sonra siteye Play bağlantısını ekleyin; doğrudan APK "deneme" olarak kalabilir. **Yapıldı:** uygulama
   Play'de herkese açık (https://play.google.com/store/apps/details?id=com.couchsubs.mobile); site, README ve sürüm notları Play'e yönlendiriyor, APK
   "Play Store'u olmayan cihazlar için" ikincil bağlantı.
