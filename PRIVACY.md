# Gizlilik / Privacy

*Son güncelleme / Last updated: 2026-11-21*

## Türkçe

CouchSubs, Enmera tarafından yayınlanan açık kaynaklı bir uygulamadır. Hesap istemez, sizi izlemez. CouchSubs üçüncü taraf reklam ağı ya da reklam SDK'sı kullanmaz, reklam kimliğini (IDFA/AAID) toplamaz ve sizi uygulamalar arasında izlemez. Uygulamada ve sitede yalnızca geliştiricinin (Enmera) kendi ürünlerinin tanıtımı ve sponsor bağlantıları gösterilebilir; bu görseller sunucumuzdan (couchsubs.enmeraapps.com/promo.json) yüklenir, gösterim sıklığı yalnızca cihazda tutulur, tıklama bağlantıyı tarayıcıda açar.
Kendi sunucumuza giden tek şey, kapatabileceğiniz ortak havuzdaki İngilizce oyun metnidir (aşağıya bakın).
TV uygulamaları hiçbir kişisel veri toplamaz; reklam, analiz ya da izleme kodu içermez. Bilgisayar (Windows, Mac) ve
telefon (iPhone, Android) uygulamalarının kimliğe bağlanmayan, kapatılabilen kullanım istatistikleri için aşağıdaki
"Kullanım istatistikleri", "iPhone uygulaması" ve "Android telefon uygulaması" bölümlerine bakın.

**Bilgisayarda kalanlar**

- PS5'ten gelen oyun görüntüsü yalnız altyazıyı okumak için bellekte işlenir; kaydedilmez, hiçbir yere
  gönderilmez.
- Okunan altyazılar ve çevirileri bilgisayarda üretilir ve yalnız ev ağınızdaki TV'ye gönderilir (çevrimiçi çeviriyi
  açarsanız İngilizce metin DeepL'e de gider; aşağıya bakın).
- PlayStation Network hesap kimliği (sayısal), PS5 eşleme anahtarı ve TV eşleme anahtarı bilgisayarda
  saklanır: Mac'te Anahtar Zinciri'nde, Windows'ta yalnız sizin kullanıcı hesabınızın açabileceği
  şifreli bir dosyada (DPAPI).

**Dışarıyla kurulan bağlantılar**

- **Sony:** PlayStation Network girişi doğrudan Sony'nin sayfasında yapılır; şifrenizi CouchSubs görmez.
  Girişten sonra Sony'den yalnız hesap kimliği alınır, oturum anahtarı saklanmaz.
- **Hugging Face (yalnız Windows):** ilk açılışta çeviri modeli `huggingface.co` adresinden bir kez indirilir.
- **Apple (yalnız Mac):** çeviri dilleri macOS tarafından indirilir ve yönetilir.
- **DeepL (yalnız siz açarsanız):** ayarlarda kendi DeepL anahtarınızı girip çevrimiçi çeviriyi açarsanız okunan
  İngilizce altyazı metni çeviri için DeepL'e (`api.deepl.com` ya da `api-free.deepl.com`) gönderilir. Görüntü,
  ses ve hesap bilgisi gönderilmez. DeepL'in kendi gizlilik koşulları geçerlidir. Anahtar Mac'te Anahtar
  Zinciri'nde, Windows'ta DPAPI ile şifreli dosyada saklanır. Açmazsanız DeepL'e hiçbir şey gönderilmez.
- **Ortak havuz (Ayarlar › Çeviri'den kapatılabilir):** hiçbir oyun paketinde bulunmayan, okunan İngilizce altyazı
  satırları herkes için daha iyi Türkçe çeviriler hazırlamak üzere `couchsubs-pool.enmera.workers.dev` adresine
  gönderilir. Giden yalnız satırın metni, ondan üretilen anahtar, ilk görüldüğü an, uygulama sürümü, işletim sistemi
  (mac/windows/ios/android) ve kuruluma özgü rastgele bir kimliktir. Biliniyorsa satırla birlikte oynanan oyunun
  kimliği ve adı (ör. PPSA01234, "Grand Theft Auto VI") da gönderilir: oyunu PS5 bildirir, uygulama okunan satırları
  hazır paketlerle eşleştirerek kendisi tanır ya da siz "Hangi oyunu oynuyorsunuz?" sorusunda seçersiniz (soru
  Ayarlar'dan kapatılabilir); bu, satırların hangi oyuna ait olduğunu
  bilmek içindir ve sizinle ilgili bir bilgi taşımaz. Görüntü, ses, kullanıcı adı, PSN ya da hesap bilgisi gönderilmez.
  En az iki farklı kurulumda okunan satırlar her gece kendiliğinden makine çevirisiyle (kendi Cloudflare
  hesabımızdaki Workers AI) o oyunun Türkçe yamasına dönüştürülür ve herkese dağıtılır; yamada satırı kimin
  gönderdiğine dair bir bilgi bulunmaz. Kapatınca gönderim hemen durur ve bekleyen satırlar silinir.
- **Kullanım istatistikleri (Ayarlar › Oyun paketleri › Kullanım verisi'nden kapatılabilir, varsayılan açık):** Windows
  uygulaması ve GitHub'dan indirilen Mac uygulaması, telefonlardaki ölçümün aynısını kimliğinize bağlamadan Google
  Analytics'e (Measurement Protocol, `www.google-analytics.com`) gönderir. Giden: açılan ekranlar, kurulumun bitmesi ve
  seçilen altyazı hedefi (TV, bilgisayar ya da ikisi), çevirinin başlaması (hedef, çeviri motoru, paketlerin açık olup
  olmadığı, konsol türü: PS5 ya da Xbox) ve bitmesi (süre, satır sayısı, hazır paketten gelen satır sayısı), bağlanan TV
  sayısı ve markası, kullanılan oyun paketinin adı; ayrıca uygulama sürümü, işletim sistemi sürümü ve bu kuruluma özgü
  rastgele bir kimlik (bilgisayarda saklanan UUID). Google, isteğin IP adresinden yaklaşık konumu (ülke) çıkarabilir.
  Altyazı metni, görüntü, PSN ya da Microsoft hesabı ve anahtarlar gönderilmez; reklam kişiselleştirmesi her zaman
  kapalıdır, çökme raporu gönderilmez. Kapatınca hiçbir şey gönderilmez ve bekleyen olaylar silinir. İlk açılışta bu
  ölçüm kısa bir notla söylenir. Mac App Store sürümünde bu ölçüm yoktur. Google'ın kendi gizlilik koşulları geçerlidir.
- **Ev ağı:** PS5 ve LG TV'yi bulmak ve onlarla eşleşmek için yalnız yerel ağ kullanılır.

TV uygulaması altyazıları yalnız ev ağındaki CouchSubs bilgisayarından alır ve internete bağlanmaz.

**iPhone uygulaması**

- **Üçüncü taraf reklamı yok, izleme yok, hesap yok.** Reklam ağı ya da reklam SDK'sı yoktur. Apple'ın izleme izni
  (App Tracking Transparency) istenmez ve reklam kimliği (IDFA) toplanmaz; veriler başka şirketlerin verileriyle
  birleştirilmez.
- **Kendi ürünlerimizin tanıtımı:** uygulama ana ekranda, boştayken, en çok günde bir kez Enmera'nın kendi ürünlerini
  tanıtan bir görsel gösterebilir. Görsel ve ayarı couchsubs.enmeraapps.com'dan hesap ya da kimlik bilgisi
  gönderilmeden indirilir; ne zaman gösterildiği yalnız telefonda tutulur, tıklama ya da gösterim hiçbir yere bildirilmez.
- **Kullanım istatistikleri (Profil › Kullanım verisi'nden kapatılabilir):** uygulamanın nasıl kullanıldığı Google
  Firebase Analytics ve Meta App Events ile, kimliğinize bağlanmadan ölçülür; çökmeler Firebase Crashlytics ile
  bildirilir. Giden: çevirinin başlaması ve süresi, altyazının nerede gösterildiği (TV ya da telefon), bağlanan TV'nin
  markası, hazır paketten gelen satır sayısı, güncellenen paket sayısı, açılan ekranlar; ayrıca bu hizmetlerin
  uygulamaya özgü rastgele kimliği, cihaz modeli, iOS sürümü ve IP'den çıkan ülke. Meta'ya olayların yalnız adı
  (ayrıntısız) ve uygulamanın açılışı gider.
  Altyazı metni, görüntü, PSN hesabı ya da anahtarlar gönderilmez. Google'ın ve Meta'nın kendi gizlilik koşulları
  geçerlidir.
- **PSN girişi** Sony'nin kendi sayfasında yapılır; şifreniz uygulamada tutulmaz, görülmez. Yalnız sayısal hesap
  kimliği ile PS5 ve TV eşleme anahtarları telefonun Anahtar Zinciri'nde saklanır.
- **Çeviri anahtarları** (Gemini, DeepL ve benzeri) yalnız telefonda, Anahtar Zinciri'nde kalır. Okunan İngilizce
  metin yalnız siz bu hizmetlerden birini açarsanız ona gönderilir.
- **Ortak havuza** yalnız hiçbir oyun paketinde bulunmayan, okunan İngilizce oyun satırları gider (yukarıda anlatıldığı
  gibi). Profil'deki "Ortak havuza katkı" ile kapatılır.
- Oyun paketleri paket sunucusundan hesap ya da kimlik bilgisi gönderilmeden indirilir.

**Android telefon uygulaması**

- **Üçüncü taraf reklamı yok, hesap yok.** Reklam ağı ya da reklam SDK'sı yoktur; reklam kimliği (Android Advertising
  ID) toplanmaz, ilgili izinler uygulamada yoktur.
- **Kendi ürünlerimizin tanıtımı:** iPhone uygulamasındaki gibi; ana ekranda, boştayken, en çok günde bir kez Enmera'nın
  kendi ürünlerini tanıtan bir görsel görünebilir. Hesap ya da kimlik bilgisi gönderilmez; gösterim ve tıklama
  bildirilmez.
- **PS5 bağlantısı yalnız ev ağında:** telefon PS5'e Uzaktan Oynatma (Remote Play) ile aynı Wi-Fi üzerinden bağlanır.
  Gelen oyun görüntüsü yalnız altyazıyı okumak için telefonun belleğinde, cihaz üstünde (Google ML Kit yazı tanıma)
  işlenir; kaydedilmez, hiçbir yere gönderilmez. Çeviri işi sürerken kalıcı bir bildirim görünür.
- **PSN girişi** uygulama içinde açılan Sony'nin kendi sayfasında yapılır; şifreniz yalnız Sony'ye gider. Sony'den yalnız
  sayısal hesap kimliği alınır, oturum anahtarı saklanmaz. Hesap kimliği, PS5 eşleme anahtarları ve girdiğiniz çeviri
  anahtarları yalnız telefonda, Android Keystore anahtarıyla şifrelenmiş olarak saklanır; uygulama silinince gider ve
  yedeğe alınmaz.
- **Ücretsiz çeviri** telefonun içinde Google ML Kit ile yapılır; Türkçe dil modeli ilk kullanımda Google'dan bir kez
  indirilir. Google ML Kit, kendi çalışmasıyla ilgili performans ve kullanım ölçümlerini Google'a gönderebilir; altyazı
  metni ya da görüntü bunlara dahil değildir.
- **Çevrimiçi çeviri (yalnız siz seçerseniz):** kendi anahtarınızla DeepL, Gemini (Google), OpenAI, Claude
  (Anthropic) ya da DeepSeek seçerseniz okunan İngilizce satır ve bağlam için son birkaç satır doğrudan o servise gönderilir. Görüntü,
  ses ve hesap bilgisi gönderilmez; o servisin kendi gizlilik koşulları geçerlidir.
- **Kullanım istatistikleri (Profil › Kullanım verisi'nden kapatılabilir, varsayılan açık):** Google Firebase Analytics
  ve Meta App Events uygulamanın nasıl kullanıldığını, kimliğinize bağlanmadan ölçer; çökmeler Firebase Crashlytics ile
  bildirilir. Giden: açılan ekranlar, kurulumun bitmesi ve seçilen altyazı hedefi (TV ya da telefon), çevirinin
  başlaması (hedef, çeviri motoru, paketlerin açık olup olmadığı) ve bitmesi (süre, satır sayısı, hazır paketten gelen
  satır sayısı), bağlanan TV sayısı, kullanılan oyun paketinin adı; ayrıca bu hizmetlerin uygulamaya özgü rastgele
  kimliği, cihaz modeli, Android sürümü ve IP'den çıkan ülke. Meta'ya olayların yalnız adı (ayrıntısız) ve uygulamanın
  açılışı gider, karşılama ekranı geçildikten sonra. Altyazı metni, görüntü, PSN hesabı ya da anahtarlar gönderilmez.
  Kapatınca Firebase ve Meta'ya hiçbir şey gitmez. Google'ın ve Meta'nın kendi gizlilik koşulları geçerlidir.
- **Ortak havuz (Ayarlar › Ortak havuza katkı'dan kapatılabilir, varsayılan açık):** yukarıda anlatıldığı gibi; işletim
  sistemi "android" olarak gider.
- **TV'de gösterme:** telefon ev ağında küçük bir altyazı sunucusu açar (port 8787) ve TV'yi yerel ağda arar; altyazılar
  yalnız aynı ağdaki CouchSubs TV uygulamasına gider.
- Oyun paketleri uygulama açılınca, günde bir ve PS5'te yeni bir oyun başlayınca, hesap ya da kimlik bilgisi
  gönderilmeden indirilir.

Sorularınız ve silme talepleriniz için: info@enmera.com.tr ya da https://github.com/yorulmazsinan/couchsubs/issues

## English

CouchSubs is open-source software published by Enmera. It needs no account and does not track you. CouchSubs uses no third-party ad network or ad SDK, does not collect the advertising identifier (IDFA/AAID) and does not track you across apps. The app and the website may show only promotions of the developer's (Enmera's) own products and sponsor links; these images are loaded from our server (couchsubs.enmeraapps.com/promo.json), how often they are shown is kept on the device only, and a tap opens the link in your browser.
The only thing sent to a server of ours is English game text for the shared pool, which you can turn off (see
below). The TV apps collect no personal data and contain no advertising, analytics or tracking code. For the unlinked
usage statistics of the computer (Windows, Mac) and phone (iPhone, Android) apps, which you can turn off, see "Usage
statistics", "iPhone app" and "Android phone app" below.

**Stays on your computer:** the game picture received from the PS5 is processed in memory only to read
subtitles and is never stored or uploaded. Subtitles and translations are produced on your computer and
sent only to the TV on your home network. Your numeric PlayStation Network account ID and the PS5 and TV
pairing keys are stored locally (Keychain on Mac; a file encrypted for your Windows user account with
DPAPI on Windows).

**External connections:** PlayStation Network sign-in happens on Sony's own page, and CouchSubs never sees
your password; afterwards only the account ID is requested from Sony, and no session token is kept. On
Windows, the translation model is downloaded once from `huggingface.co`. On Mac, translation languages are
downloaded and managed by macOS. If you enter your own DeepL key in settings and turn on online
translation, the English subtitle text that was read is sent to DeepL (`api.deepl.com` or
`api-free.deepl.com`) to be translated; no picture, audio or account data is sent, and DeepL's own privacy
terms apply. The key is stored in the Keychain on Mac and in the DPAPI-encrypted file on Windows. Nothing is
sent to DeepL unless you turn this on. PS5 and TV discovery and pairing use your local network only.

**Usage statistics (on by default, turn off in Settings › Game packs › Usage data):** the Windows app and the Mac app
downloaded from GitHub send the same measurement as the phone apps to Google Analytics (Measurement Protocol,
`www.google-analytics.com`) without linking it to you. What is sent: opened screens, finishing setup and the chosen
subtitle target (TV, computer or both), translation start (target, engine, whether packs are on, console type: PS5 or
Xbox) and stop (duration, number of lines, lines from a ready-made pack), the number and brand of connected TVs, the name
of the game pack used, plus the app version, the operating system version and a random ID made for this installation (a
UUID stored on the computer). Google may derive the approximate location (country) from the request's IP address. No
subtitle text, picture, PSN or Microsoft account or keys are sent; ad personalisation is always off and no crash reports
are sent. When turned off nothing is sent and waiting events are deleted. A short note tells you about this on first
launch. The Mac App Store version does not include this measurement. Google's own privacy terms apply.

**Shared pool (can be turned off in Settings › Translation):** English subtitle lines that were read and are not
in any game pack are sent to `couchsubs-pool.enmera.workers.dev` to make better Turkish translations for
everyone. Only the line's text, a key derived from it, when it was first seen, the app version, the operating
system (mac/windows/ios/android) and a random ID made for this installation are sent. When known, the ID and name of
the game being played (e.g. PPSA01234, "Grand Theft Auto VI") are sent with the line: the PS5 reports it, the app
recognises it by matching the lines it reads with the ready packs, or you pick it when asked "Which game are you
playing?" (the question can be turned off in Settings); this is only
to know which game the lines belong to and carries no information about you. Lines read by at least two different installations are
automatically machine-translated every night (Workers AI on our own Cloudflare account) into that game's Turkish pack,
which is given to everyone; the pack holds nothing about who sent a line. No picture, audio, user name, PSN or
account data is sent. Turning it off stops sending at once and deletes lines waiting to be sent.

The TV app receives subtitles only from the CouchSubs computer on your home network and does not connect
to the internet.

**iPhone app:** no third-party ads, no tracking, no account. There is no ad network or ad SDK. On the home screen, while
idle and at most once a day, the app may show an image promoting Enmera's own products; the image and its settings are
downloaded from couchsubs.enmeraapps.com without any account or identifying data, when it was shown is kept only on the
phone, and views or taps are not reported anywhere. The app never asks for tracking permission (App
Tracking Transparency) and does not collect the advertising identifier (IDFA); data is not combined with other
companies' data. Usage statistics (can be turned off in Profile › Usage data) are measured with Google Firebase Analytics
and Meta App Events without being linked to you, and crashes are reported with Firebase Crashlytics. What is sent: when
translation starts and how long it ran, where subtitles are shown (TV or phone), the brand of the connected TV, how many
lines came from a ready-made pack, how many packs were updated, which screens were opened, plus these services' random
app-specific ID, device model, iOS version and the country derived from the IP address. Meta receives only the event
names (without details) and app launches. No subtitle text, picture, PSN account or keys are sent. Google's and Meta's own privacy terms apply. PlayStation
Network sign-in happens on Sony's own page; your password is never seen or kept by the app. Only the numeric account ID
and the PS5 and TV pairing keys are stored, in the phone's Keychain. Translation keys (Gemini, DeepL and similar) stay on
the phone, in the Keychain; English text is sent to such a service only if you turn it on. Only English game lines that
are not in any game pack go to the shared pool (as described above); turn it off with "Contribute to the shared pool"
in Profile. Game packs are downloaded from the pack server without sending any account or identifying data.

**Android phone app:** no third-party ads, no account. There is no ad network or ad SDK and the Android advertising ID
is not collected; the app does not hold the related permissions. Like the iPhone app, it may show an image promoting
Enmera's own products on the idle home screen at most once a day, without sending identifying data or reporting views
or taps. The phone connects to your PS5 with Remote Play over your home Wi-Fi only. The
game picture is processed in the phone's memory, on the device (Google ML Kit text recognition), only to read
subtitles; it is never stored or uploaded. A persistent notification is shown while translation runs. PlayStation
Network sign-in happens on Sony's own page opened inside the app; your password goes only to Sony. Only the numeric
account ID is requested from Sony and no session token is kept. The account ID, the PS5 pairing keys and any
translation keys you enter are stored only on the phone, encrypted with an Android Keystore key; they are removed with
the app and are not backed up. Free translation runs on the phone with Google ML Kit; the Turkish language model is
downloaded once from Google on first use, and ML Kit may send Google performance and usage metrics about its own
operation, which do not include subtitle text or pictures. If you choose DeepL, Gemini (Google), OpenAI, Claude
(Anthropic) or DeepSeek with your own key, the English line that was read and the last few lines for context are sent directly to
that service; no picture, audio or account data, and that service's own privacy terms apply. Usage statistics (on by
default, turn off in Profile › Usage data) are measured with Google Firebase Analytics and Meta App Events without being
linked to you, and crashes are reported with Firebase Crashlytics. What is sent: opened screens, finishing setup and the
chosen subtitle target (TV or phone), translation start (target, engine, whether packs are on) and stop (duration,
number of lines, lines from a ready-made pack), number of connected TVs, the name of the game pack used, plus these
services' random app-specific ID, device model, Android version and the country derived from the IP address. Meta
receives only event names (without details) and app launches, after the welcome screen. No subtitle text, picture, PSN
account or keys are sent; when turned off nothing goes to Firebase or Meta. Google's and Meta's own privacy terms apply.
The shared pool works as described above (can be turned off in Settings › Contribute to the shared pool, on by default;
the operating system is sent as "android"). To show subtitles on a TV, the phone runs a small subtitle server on your
home network (port 8787) and looks for TVs on the local network; subtitles go only to the CouchSubs TV app on the same
network. Game packs are downloaded when the app opens, once a day and when a new game starts on the PS5,
without sending any account or identifying data.

Contact and deletion requests: info@enmera.com.tr or https://github.com/yorulmazsinan/couchsubs/issues
