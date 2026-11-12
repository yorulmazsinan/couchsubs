<p align="center"><img src="design/logo-1024.png" width="120" alt="CouchSubs"></p>

# CouchSubs

**Türkçe dil desteği olmayan PS5 oyunlarını Türkçe altyazıyla oynayın.**

CouchSubs, oyundaki İngilizce altyazıyı anlık okur, Türkçeye çevirir ve TV'de oyun görüntüsünün üstünde
gösterir. Oyunu her zamanki gibi TV'de, kendi kolunuzla oynarsınız. Yazı tanıma ve çeviri bilgisayarınızda
yapılır; altyazılar internete gönderilmez. Ücretsiz ve açık kaynaklıdır.

*English below.*

## Oyunda nasıl görünüyor

Mafia: The Old Country, PS5'te İngilizce oynanıyor; Türkçe altyazı TV'de oyunun üstünde, CouchSubs bilgisayarda çalışıyor.

https://github.com/user-attachments/assets/bb8569d8-115d-49c7-a772-da2d9e171c17

## Ekran görüntüleri

**Mac** (uygulamanın kendisi, örnek verilerle):

| Ana ekran | Kurulum |
|---|---|
| <img src="docs/screenshots/mac/ana.png" width="420" alt="Ana ekran"> | <img src="docs/screenshots/mac/kurulum.png" width="420" alt="Kurulum: PS5'i eşle"> |
| **Ayarlar › Çeviri** | **Ayarlar › Oyun paketleri** |
| <img src="docs/screenshots/mac/ayarlar-ceviri.png" width="420" alt="Ayarlar: çeviri motoru"> | <img src="docs/screenshots/mac/ayarlar-paketler.png" width="420" alt="Ayarlar: oyun paketleri"> |

**Windows** (tasarım; uygulama aynı düzeni kullanır):

| Ana ekran | Kurulum |
|---|---|
| <img src="docs/screenshots/windows/ana.png" width="420" alt="Windows ana ekran tasarımı"> | <img src="docs/screenshots/windows/kurulum.png" width="420" alt="Windows kurulum tasarımı"> |
| **Ayarlar › Çeviri** | **Ayarlar › Oyun paketleri** |
| <img src="docs/screenshots/windows/ceviri.png" width="420" alt="Windows çeviri ayarları tasarımı"> | <img src="docs/screenshots/windows/paketler.png" width="420" alt="Windows oyun paketleri tasarımı"> |
| **Bilgisayar ekranındaki altyazı penceresi** | |
| <img src="docs/screenshots/windows/pencere.png" width="420" alt="Altyazı penceresi tasarımı"> | |

**Telefon uygulaması (yakında)** (tasarım; o da tamamen ücretsiz, hesap gerekmez; yatay altyazı ekranı:
[09-altyazi.png](docs/screenshots/telefon/09-altyazi.png)):

| | | | |
|---|---|---|---|
| <img src="docs/screenshots/telefon/01-karsilama-1.png" width="180" alt="Karşılama"> | <img src="docs/screenshots/telefon/02-karsilama-2.png" width="180" alt="Karşılama"> | <img src="docs/screenshots/telefon/03-psn.png" width="180" alt="PSN girişi"> | <img src="docs/screenshots/telefon/04-ps5.png" width="180" alt="PS5 eşleme"> |
| Karşılama | Karşılama | PSN girişi | PS5 eşleme |
| <img src="docs/screenshots/telefon/05-hedef.png" width="180" alt="Altyazı nerede"> | <img src="docs/screenshots/telefon/06-tur.png" width="180" alt="Kullanım turu"> | <img src="docs/screenshots/telefon/07-ana.png" width="180" alt="Ana ekran"> | <img src="docs/screenshots/telefon/08-calisiyor.png" width="180" alt="Çeviri sürüyor"> |
| Altyazı nerede | Kullanım turu | Ana ekran | Çeviri sürüyor |
| <img src="docs/screenshots/telefon/10-paketler.png" width="180" alt="Oyun paketleri"> | <img src="docs/screenshots/telefon/11-cihazlarim.png" width="180" alt="Cihazlarım"> | <img src="docs/screenshots/telefon/12-ayarlar.png" width="180" alt="Ayarlar"> | |
| Oyun paketleri | Cihazlarım | Ayarlar | |

## İndir

| Bilgisayarınız | Tek tıkla indirin |
|---|---|
| **Mac** (macOS 13+, Apple Silicon ve Intel) | **[CouchSubs-macos.dmg](https://github.com/yorulmazsinan/couchsubs/releases/latest/download/CouchSubs-macos.dmg)** |
| **Windows** 10 / 11 (64 bit) | **[CouchSubs-windows-Setup.exe](https://github.com/yorulmazsinan/couchsubs/releases/latest/download/CouchSubs-windows-Setup.exe)** |

TV uygulamasını ayrıca indirmeniz gerekmez: bilgisayar uygulaması TV'nize kendisi kurar. Uygulama yeni sürümleri
kendisi bulur ve tek tıkla günceller. Kurulum istemeyenler için zip paketleri de duruyor:
[Mac](https://github.com/yorulmazsinan/couchsubs/releases/latest/download/CouchSubs-macos.zip) ·
[Windows](https://github.com/yorulmazsinan/couchsubs/releases/latest/download/CouchSubs-windows-x64.zip).

> **Beta.** Uygulama deneme aşamasındadır ve denemeniz bize çok yardımcı olur. Sorunları ve önerileri
> [Issues](https://github.com/yorulmazsinan/couchsubs/issues) sayfasından bildirebilirsiniz.

## Hangi TV'lerde çalışır

| TV | Durum |
|---|---|
| **LG** (webOS 4 ve üstü) | Gerçek TV'de denendi. Uygulamayı CouchSubs kendisi kurar |
| **Samsung** (Tizen, 2019 ve sonrası) | Gerçek TV'de denendi (75" Neo QLED). Uygulamayı CouchSubs kendisi kurar; bir kez Samsung hesabıyla giriş istenir |
| **Samsung** (Tizen 3.0–4.0, 2017–2018) | Deneysel: bir kullanıcı UE43MU7000U'da (2017) elle kurup çalıştırdı; CouchSubs'ın kendi kurulumu bu TV'lerde henüz denenmedi ([ayrıntı](docs/tv-kurulum.md#20172018-samsung-tvler-deneysel)) |
| **Android TV / Google TV** (Vestel, Arçelik, Beko, Grundig, Philips ve diğerleri) | Gerçek TV'de denendi. Uygulamayı CouchSubs ağ üzerinden kendisi kurar |
| Vestel, Arçelik, Beko, Grundig'in Linux modelleri, Philips Saphi ve Titan OS | Desteklenmiyor: uygulama kurmanın bir yolunu bulamadık |

Bilgisayar tarafında Mac ve Windows gerçek cihazla denendi. Geri bildiriminiz çok değerli.

TV'de yapmanız gereken tek şey geliştirici modunu açmak. Adımları bilgisayar uygulaması ekranda gösterir ve TV'yi
kendisi bekler. Resimli rehber isterseniz: [docs/tv-kurulum.md](docs/tv-kurulum.md)

## Nasıl çalışır

```
PS5 ──HDMI──▶ TV (CouchSubs TV uygulaması: HDMI görüntüsü + altyazı katmanı)
 │                          ▲
 └─ Remote Play ──▶ CouchSubs (Mac / Windows) ── ev ağı
    (ikinci PSN hesabı)    okur → çevirir → TV'ye gönderir
```

Bilgisayar, PS5'e ikinci bir PlayStation Network hesabıyla Remote Play üzerinden bağlanır ve görüntüyü
yalnız altyazıyı okumak için kullanır. Siz oyunu HDMI'dan, gecikmesiz oynamaya devam edersiniz.

## Gerekenler

- **PS5** ve yukarıdaki listeden bir **TV**, bilgisayarla aynı ev ağında
- Ücretsiz **ikinci bir PlayStation Network hesabı** (kendi hesabınızla Remote Play kolunuzu
  kapatırdı; ikinci hesapla oyununuz kesilmez)
- Bilgisayar, şunlardan biri:
  - **Mac:** macOS 13 Ventura veya üstü, Apple Silicon (M1 ve sonrası) ya da Intel. Apple'ın ücretsiz çevirisi
    macOS 26 ister; daha eski macOS'ta oyun paketleri, Gemini (ücretsiz anahtar), DeepL ya da yapay zekâ çevirisi kullanılır
  - **Windows:** Windows 10 (2004) veya 11, 64 bit; ilk açılışta çeviri modeli için yaklaşık 530 MB indirme

## Kurulum

1. Yukarıdan bilgisayarınıza uygun dosyayı indirin.
   - **Mac:** DMG'yi açın, CouchSubs'ı **Uygulamalar** klasörüne sürükleyip açın. Uygulama Apple onaylıdır.
   - **Windows:** `CouchSubs-windows-Setup.exe`'yi açın; yönetici izni istemeden kurulur, Başlat menüsüne ve masaüstüne
     kısayol koyar. "Windows bilgisayarınızı korudu" uyarısı çıkarsa **Ek bilgi › Yine de çalıştır**'a basın. Güvenlik
     duvarı sorarsa **Özel ağlar**'a izin verin.
2. Kurulum sihirbazını izleyin: ikinci PSN hesabıyla giriş, PS5 eşleme, TV seçimi.
3. TV adımında uygulama, TV'nizin markasına göre geliştirici modunu nasıl açacağınızı gösterir. Açtığınızda TV
   uygulamasını kendisi kurar:
   - **LG:** TV ekranındaki 6 karakterli parolayı bir kez yazarsınız.
   - **Samsung:** tarayıcıda bir kez Samsung hesabınızla giriş yaparsınız (Samsung uygulamayı TV'nize özel imzalatır).
   - **Android TV:** TV'de "hata ayıklamaya izin verilsin mi?" sorusuna **İzin ver** dersiniz.

**Bilmeniz gerekenler**

- LG'de geliştirici modu en çok 1000 saat açık kalır. CouchSubs her kullanışınızda süreyi kendisi baştan başlatır;
  uygulamayı uzun süre kullanmazsanız TV'deki Developer Mode uygulamasından **EXTEND** ile uzatın.
- Samsung'da TV, CouchSubs TV uygulaması açıkken sürekli HDMI 1'e ya da başka bir kaynağa geçiyorsa TV'de
  **Ayarlar › Tüm Ayarlar › Bağlantı › Harici Cihaz Yöneticisi** altında **Anynet+ (HDMI-CEC)** ve **Otomatik Kaynak
  Değiştirme**'yi kapatın. Samsung TV'yi yeniden başlatmak için güç tuşunu yaklaşık 2 saniye basılı tutun; kısa basınca
  yalnız bekleme moduna geçer.
- Altyazı, oyunda altyazı açıksa okunabilir. Bölgeyi **Ayarlar › Altyazı alanı**'ndan oyuna göre ayarlayabilirsiniz.
- **Kısayollar** (yalnız çeviri sürerken, CouchSubs arka plandayken de çalışır): Windows'ta **Num 9** ya da
  **Ctrl+Shift+9** ekranı çevirir, **Num 1–3** / **Ctrl+Shift+1–3** ek bölgeleri, **Num 5** / **Ctrl+Shift+5** serbest
  alanı çevirir, **Num 0** / **Ctrl+Shift+0** canlı altyazıyı duraklatır, **Num 7** / **Ctrl+Shift+7** altyazı
  penceresinde tıklamaları geçirir, **Num 8** / **Ctrl+Shift+8** ayarlardaki görüntüyü yeniler. Sayı tuş takımı
  olmayan dizüstünde harflerin üstündeki rakamlar Ctrl+Shift ile kullanılır. Mac'te ekranı çevir **⌥⌘T**,
  tıklamalar **⌥⌘L**.
- Çeviri makine çevirisidir; bazı cümleler kusurlu olabilir.

## Yerel yapay zekâ ile çeviri (Ollama, LM Studio)

Çeviriyi kendi bilgisayarınızda çalışan bir yapay zekâ modeline yaptırabilirsiniz: anahtar, kota ve ücret yoktur,
altyazı metni bilgisayardan çıkmaz. Hız bilgisayarınıza bağlıdır; ekran kartı ya da Apple Silicon olan bir bilgisayarda
7-8 milyar parametreli bir model (ör. Qwen 2.5 7B) bir altyazıyı genellikle bir iki saniyede çevirir. Model yanıt
vermezse o satır her zamanki ücretsiz çeviriyle gelir.

**Ollama ile**

1. [ollama.com/download](https://ollama.com/download)'dan Ollama'yı kurup açın.
2. Terminal'de (Windows'ta PowerShell) modeli indirin: `ollama pull qwen2.5:7b`
3. CouchSubs'ta **Ayarlar › Çeviri › Çeviri motoru › Yerel model**'i seçin. Sunucu adresi
   `http://localhost:11434/v1`, model adı `qwen2.5:7b` olarak gelir; **Bağlantıyı dene**'ye basın.

**LM Studio ile**

1. [lmstudio.ai](https://lmstudio.ai)'dan LM Studio'yu kurun, bir model indirip yükleyin (ör. Qwen 2.5 7B Instruct).
2. **Developer** bölümünden yerel sunucuyu başlatın (varsayılan adres `http://localhost:1234/v1`).
3. CouchSubs'ta **Yerel model**'i seçin, **LM Studio'yu kullan**'a basın, model adını LM Studio'da göründüğü gibi yazın
   ve **Bağlantıyı dene**'ye basın.

Başka bir bilgisayardaki ya da OpenAI uyumlu başka bir sunucuyu da adresini yazarak kullanabilirsiniz; sunucu anahtar
istiyorsa **API anahtarı (isteğe bağlı)** alanına yazın. İlk istek modeli belleğe yüklediği için uzun sürebilir;
Bağlantıyı dene bunu da bekler. Çeviriler sunucu adresi ve model adıyla ayrı saklanır; modeli değiştirince eski
modelin çevirileri karışmaz.

## Gizlilik

CouchSubs hesap şifrenizi görmez (giriş doğrudan Sony'nin sayfasında yapılır), altyazıları ve oyun
görüntüsünü hiçbir sunucuya göndermez. Ayrıntılar: [PRIVACY.md](PRIVACY.md).

## Derleme

**Mac**

```bash
brew install cmake ninja pkg-config protobuf openssl@3 xcodegen   # OpenSSL, json-c, libevent, miniupnpc kaynaktan derlenir
git submodule update --init third-party/chiaki-ng
./scripts/build-chiaki-macos.sh     # libchiaki (arm64 + x86_64, macOS 13+) → third-party/build/CChiaki.xcframework
./scripts/package-mac.sh            # → dist/CouchSubs-<sürüm>-macos.zip
```

Testler: `core/` ve `remoteplay/` içinde `swift test`; `mac/` içinde `xcodegen generate` sonrası
`xcodebuild test -project mac/CouchSubs.xcodeproj -scheme CouchSubs -destination 'platform=macOS'`.

**Windows**

Yerel kütüphane (libchiaki + FFmpeg) MSYS2 ile derlenir; adımlar `.github/workflows/windows.yml` içinde.
.NET 10 ile `dotnet test windows/CouchSubs.Windows.slnx` (uygulamanın kendisi yalnız Windows'ta çalışır).

**TV**

```bash
npm install -g @webos-tools/cli
./scripts/package-tv.sh             # LG → dist/tv-app/com.couchsubs.tv_<sürüm>_all.ipk
./scripts/package-tizen.sh          # Samsung → dist/tv-tizen/app (TIZEN_PROFILE ile imzalı .wgt)
(cd tv-android && gradle assembleRelease)   # Android TV (Gradle 8.11, JDK 17)
```

Mac ve Windows paketleri bu dosyayı içerir, bu yüzden Mac paketinden önce de bu araç kurulu olmalıdır.

Sürümler `v*` etiketiyle `.github/workflows/release.yml` tarafından derlenip yayınlanır.

## Klasörler

- `mac/` – macOS uygulaması (SwiftUI, Vision, Translation)
- `windows/` – Windows uygulaması (WPF, Windows OCR, OPUS-MT çeviri modeli) ve yerel Remote Play kütüphanesi
- `core/` – platformdan bağımsız mantık (altyazı dengeleyici, yerel altyazı sunucusu, LG TV eşleme)
- `remoteplay/` – chiaki-ng'nin `libchiaki`'si üstünde Remote Play bağlantısı
- `tv-webos/` – LG webOS TV uygulaması ve TV arayüzünün ortak kodu
- `tv-tizen/` – Samsung TV uygulaması
- `tv-android/` – Android TV uygulaması
- `design/`, `docs/TASARIM.md` – logo ve ortak tasarım kuralları
- `prototip/` – ilk prototip (başvuru için saklanıyor)

## Lisans

Copyright (C) 2026 Sinan Yorulmaz. [GNU AGPL-3.0](LICENSE) ile lisanslanmıştır; çatallar ve değiştirilmiş
sürümler bu telif satırını korumalı ve [NOTICE](NOTICE) dosyasındaki koşullara uymalıdır. Kullanılan açık kaynak bileşenler ve lisansları:
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Remote Play bağlantısı
[chiaki-ng](https://github.com/chiaki-ng/chiaki-ng) sayesinde mümkün; geliştiricilerine teşekkürler.

Yayıncı: Enmera.

CouchSubs, Sony Interactive Entertainment ile bağlantılı değildir ve onun tarafından onaylanmamıştır.
"PlayStation" ve "PS5", Sony Interactive Entertainment Inc.'in ticari markalarıdır.

---

## English

CouchSubs reads the English subtitles of PS5 games in real time, translates them and shows the translation
on your TV on top of the game picture. You keep playing on the TV with your own controller; text recognition
and translation run on your computer, and subtitles are never sent to the internet.

**You need:** a PS5 and a supported TV on the same network as your computer, a free second
PlayStation Network account, and either a Mac on macOS 13 Ventura or later (Apple Silicon or Intel) or a 64-bit Windows 10 (2004)
or 11 PC. Apple's free on-device translation needs macOS 26; on older macOS the game packs, Gemini (free key), DeepL or
AI translation are used.

**TVs:** LG, Samsung (2019 and later; 2017–2018 models experimental) and Android TV / Google TV such as Vestel,
Arçelik, Beko, Grundig and Philips, all tested on real TVs. CouchSubs installs the TV app on all of them. Mac and
Windows are tested on real hardware.

**Download:** [Mac (DMG)](https://github.com/yorulmazsinan/couchsubs/releases/latest/download/CouchSubs-macos.dmg) · [Windows (installer)](https://github.com/yorulmazsinan/couchsubs/releases/latest/download/CouchSubs-windows-Setup.exe). The app finds new versions and updates itself.

**Screenshots:** the Mac app ([main screen](docs/screenshots/mac/ana.png),
[setup](docs/screenshots/mac/kurulum.png), [translation settings](docs/screenshots/mac/ayarlar-ceviri.png),
[game packs](docs/screenshots/mac/ayarlar-paketler.png)), the Windows design
([main screen](docs/screenshots/windows/ana.png), [setup](docs/screenshots/windows/kurulum.png),
[translation](docs/screenshots/windows/ceviri.png), [game packs](docs/screenshots/windows/paketler.png),
[subtitle window](docs/screenshots/windows/pencere.png)) and the design of the upcoming phone app
([docs/screenshots/telefon](docs/screenshots/telefon)). Everything is free, game packs included; no account is needed.

**Setup:** open the app and follow the setup assistant. On the TV step it shows how to turn on developer mode for your
TV brand and then installs the TV app by itself (LG: type the on-screen passphrase once; Samsung: sign in with a
Samsung account once; Android TV: allow debugging on the TV). Guide: [docs/tv-setup.md](docs/tv-setup.md).
On Windows, if SmartScreen appears, choose **More info › Run anyway**.

**Local AI translation:** in **Settings › Translation** choose **Local model** to translate with a model running on your
own computer through [Ollama](https://ollama.com) (`ollama pull qwen2.5:7b`, address `http://localhost:11434/v1`) or
[LM Studio](https://lmstudio.ai) (local server, `http://localhost:1234/v1`). No key, quota or cost, and subtitle text
stays on your computer; **Test connection** checks the server and the model.

**Shortcuts** (while translating, even with CouchSubs in the background): on Windows **Num 9** or **Ctrl+Shift+9**
translates the screen; Num 1–3, 5, 0, 7 and 8 also work as Ctrl+Shift+1–3, 5, 0, 7 and 8, so laptops without a numeric
keypad can use them. On a Mac: **⌥⌘T** translates the screen, **⌥⌘L** toggles click-through.

Copyright (C) 2026 Sinan Yorulmaz. Licensed under the [GNU AGPL-3.0](LICENSE) (forks must keep this notice, see
[NOTICE](NOTICE)); third-party components are listed in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). CouchSubs is not affiliated with or endorsed by Sony
Interactive Entertainment. "PlayStation" and "PS5" are trademarks of Sony Interactive Entertainment Inc.
