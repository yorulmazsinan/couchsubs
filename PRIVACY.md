# Gizlilik / Privacy

*Son güncelleme / Last updated: 2026-11-12*

## Türkçe

CouchSubs, Enmera tarafından yayınlanan açık kaynaklı bir uygulamadır. Hesap istemez, reklam göstermez, sizi izlemez.
Kendi sunucumuza giden tek şey, kapatabileceğiniz ortak havuzdaki İngilizce oyun metnidir (aşağıya bakın).
Bilgisayar ve TV uygulamaları hiçbir kişisel veri toplamaz; reklam, analiz ya da izleme kodu içermez. iPhone
uygulamasının kimliğe bağlanmayan kullanım istatistikleri için aşağıdaki "iPhone uygulaması" bölümüne bakın.

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
  (mac/windows/ios) ve kuruluma özgü rastgele bir kimliktir. Görüntü, ses, kullanıcı adı, PSN ya da hesap bilgisi gönderilmez.
  Kapatınca gönderim hemen durur ve bekleyen satırlar silinir.
- **Ev ağı:** PS5 ve LG TV'yi bulmak ve onlarla eşleşmek için yalnız yerel ağ kullanılır.

TV uygulaması altyazıları yalnız ev ağındaki CouchSubs bilgisayarından alır ve internete bağlanmaz.

**iPhone uygulaması**

- **Reklam yok, izleme yok, hesap yok.** Uygulamada reklam gösterilmez. Apple'ın izleme izni (App Tracking
  Transparency) istenmez ve reklam kimliği (IDFA) toplanmaz; veriler başka şirketlerin verileriyle birleştirilmez.
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

Sorularınız için: https://github.com/yorulmazsinan/couchsubs/issues

## English

CouchSubs is open-source software published by Enmera. It needs no account, shows no ads and does not track you.
The only thing sent to a server of ours is English game text for the shared pool, which you can turn off (see
below). The computer and TV apps collect no personal data and contain no advertising, analytics or tracking code. For
the iPhone app's unlinked usage statistics, see "iPhone app" below.

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

**Shared pool (can be turned off in Settings › Translation):** English subtitle lines that were read and are not
in any game pack are sent to `couchsubs-pool.enmera.workers.dev` to make better Turkish translations for
everyone. Only the line's text, a key derived from it, when it was first seen, the app version, the operating
system (mac/windows/ios) and a random ID made for this installation are sent; no picture, audio, user name, PSN or
account data. Turning it off stops sending at once and deletes lines waiting to be sent.

The TV app receives subtitles only from the CouchSubs computer on your home network and does not connect
to the internet.

**iPhone app:** no ads, no tracking, no account. No ads are shown. The app never asks for tracking permission (App
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

Contact: https://github.com/yorulmazsinan/couchsubs/issues
