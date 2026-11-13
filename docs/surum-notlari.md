CouchSubs'ın yeni deneme sürümü. Türkçe dil desteği olmayan PS5 oyunlarının İngilizce altyazısını okur, Türkçesini TV'de oyunun üstünde gösterir ve isterseniz Türkçe seslendirir.

**Site, kurulum rehberi ve SSS:** [couchsubs.enmeraapps.com](https://couchsubs.enmeraapps.com)

**İndir:** [Mac (DMG)](https://github.com/yorulmazsinan/couchsubs/releases/latest/download/CouchSubs-macos.dmg) · [Windows (kurulum)](https://github.com/yorulmazsinan/couchsubs/releases/latest/download/CouchSubs-windows-Setup.exe)

**Bu sürümde yeni**

- **Açık renkli sahnelerde çeviri kaybolmuyor:** İngilizce altyazı beyaz ya da parlak bir zeminin önündeyken yazı tanıma kısa süre kaçırınca Türkçe çeviri siliniyordu. Artık altyazının yeri değişmediyse çeviri ekranda kalıyor; altyazı gerçekten gidince eskisi gibi hemen kalkıyor.
- **DeepL'de adlar korunuyor:** Sözlükteki adlar (ör. Phantom Blade Zero'daki "Soul") DeepL'de de çevrilmiyor; adın arkasındaki sözcük de bozulmuyor ("began" → "Pegan" gibi).
- **Takılan okuma çeviriyi durdurmuyor (Windows ve iPhone):** Mac'te beta.35'te düzeltilen sorun diğer platformlarda da giderildi.
- **Ayarlar'da altyazının yeri:** "Yerleşim" ve "Ekrandaki konum" yalnız TV'ye gönderilirken görünüyor; bilgisayar ekranındaki altyazı için yerinde "Altyazı penceresini ayarla" düğmesi var.

**beta.35'te gelenler:** Samsung kurulumunda doğru "Host PC IP" (VPN ve sanal bağdaştırıcılar seçilmiyor), Samsung girişi açılmazsa açılır pencere ipucu ve bağlantıyı kopyala düğmesi, Mac'te alan değişince çevirinin durmasının giderilmesi, "Üstünü örtsün"de tek kutu (TV uygulaması 0.9.17), ücretsiz çeviride "Soul" gibi adların korunması.

**beta.34'te gelenler:** Marvel's Spider-Man 2 ve Death Stranding (Director's Cut) yamaları, Mac'te sol sütun taşmasının giderilmesi, Windows'ta uzun yazıların kesilmeden alt satıra inmesi.

**beta.33'te gelenler:** canlı ölçümler (okuma, çeviri, gecikme), altyazı alanı için hazır seçimler ve canlı önizleme, "TV'de test et", Geçmiş, Windows'ta bozuk ve yarım okunan altyazıların çok azalması (katkı: [ronaldinho62](https://github.com/ronaldinho62), #28), TV uygulaması 0.9.16.

**beta.32'de gelenler:** koyu görünümün varsayılan olması ve Ayarlar'da Görünüm seçimi, yerel yapay zekâ ile çeviri (Ollama, LM Studio), sadeleştirilmiş görünüm, Linux sunucusu (Docker; katkı: Ceyhun Yılmaz), 2017–2018 Samsung TV'ler (deneysel), TV uygulaması 0.9.15 (HDMI'ya kendiliğinden geçen TV için ipucu), Mac'te macOS 13 ve Intel desteği, PS5 eşleşmesinin açıkça gösterilmesi, altyazı günlüğü (`altyazi.log`) ve ortak havuza yalnız İngilizce oyun satırlarının gitmesi.

**beta.31'de gelenler:** Mac'te Samsung TV kurulumundaki "EphemeralKeySet" hatasının düzeltilmesi (Kadir Eker), Mac'te "Çeviriyi durdur"da çökmenin giderilmesi, TV uygulaması 0.9.14 (seslendirme açıkken oyun ekranı kararmıyor; Kadir Eker), aynı cümlenin TV'de üst üste yığılmaması ve hızlı konuşmada satırların kaybolmaması.

**beta.30'da gelenler:** Elden Ring + Shadow of the Erdtree paketi, Windows'ta sayı tuş takımı olmayan klavyeler için Ctrl+Shift+rakam kısayolları, Samsung TV ipuçları (Anynet+ ve güç tuşu), TV uygulaması 0.9.13 (dublaj kapatılınca oyunun sesi geri geliyor), yarım kalan TV kurulumunun bitmiş sayılmaması.

**beta.29'da gelenler:** yeni görünüm (Mac ve Windows'ta iki sütunlu ana ekran, tek pencerede bölümlü Ayarlar), Windows'ta bazı bilgisayarlarda hiç çalışmayan ücretsiz çevirinin düzeltilmesi, GTA V ve RDR2 paketlerinin baştan sona gözden geçirilmesi (yaklaşık 26 bin satır düzeltildi), TV uygulaması 0.9.12.

**beta.28'de gelenler:** oyun paketlerinin ekrandan bozuk okunan ve parça parça gösterilen satırları da yakalaması (Mafia'da kaçan satırların yarısından fazlası artık paketten), altı paketin kalite denetimi (yaklaşık 2.600 satır düzeltildi).

**beta.27'de gelenler:** GTA V, Red Dead Redemption 2, Assassin's Creed Shadows, Death Stranding 2 ve Call of Duty: Modern Warfare (2019) paketleri; Android TV'de siyah ekran için katman modu (TV uygulaması 0.9.11); Windows'ta "Çeviriyi başlat"ta kapanma düzeltmesi; daha açık PS5 durumu; Samsung TV kurulumu düzeltmeleri (sebepli hata mesajları, eski TV uygulamasının kendiliğinden güncellenmesi).

**beta.25 ve beta.26'da gelenler**

- **Oyun çeviri paketleri:** Desteklenen oyunlarda altyazı, önceden hazırlanmış Türkçe çeviriyle anında ve internet gerekmeden gösterilir. İlk paket **Mafia: The Old Country** (18 bin satır, oyunun bütün metni Claude ile çevrildi). Pakette olmayan satırlar her zamanki çeviri motoruyla çevrilir. Ayarlar › Çeviri › Oyun paketleri.
- **Ortak altyazı havuzu:** Paketlerde bulunmayan İngilizce altyazı satırları anonim olarak ortak havuza gönderilir; biriken satırlar çevrilip yeni paketlerle herkese gelir. Yalnız oyunun İngilizce metni gider, başka hiçbir bilgi gitmez. Ayarlar › Çeviri'den kapatılabilir.
- **Altyazı bilgisayar ekranında (TV'siz kullanım):** Kurulumda "TV'm yok, bilgisayar ekranında göster" seçilebiliyor. Altyazı her zaman üstte duran saydam bir pencerede, TV'deki görünümle gösterilir; sürüklenip genişletilebilir, "Tıklamalar geçsin" ile fareyi engellemez (geri almak için Mac'te ⌥⌘L, Windows'ta Num 7). Ana ekranda ve ayarlarda "Altyazıyı göster: TV / Bilgisayar ekranı / İkisi de".
- **PS5 eşleme ve PSN girişi düzeltildi:** Eşleme kodu yazılıp Enter'a basılınca artık bağlanıyor (önceden hiçbir şey olmuyor, kodun süresi doluyordu); kod boşluklu ya da tireli yazılabiliyor. Eşleme ve giriş hataları artık sebebiyle gösteriliyor ("Kod yanlış ya da süresi dolmuş", "PS5 yanıt vermedi", "Sony çok fazla giriş denemesi aldı" gibi). Sorun sürerse ekranda gösterilen günlük dosyasını gönderebilirsiniz (Mac'te `~/Library/Logs/CouchSubs/remoteplay.log`).
- **Ücretsiz Gemini ile daha iyi çeviri:** Kurulumun sonunda isteğe bağlı "Daha iyi çeviri (ücretsiz)" adımı: bir dakikada ücretsiz Google Gemini anahtarı alıp yapıştırınca çeviri çok daha iyi olur. Ücretsiz kotanın dakikalık sınırı aşılmaz; aşılacaksa o satır ücretsiz yerel çeviriyle gösterilir.

**beta.24'te gelenler:** altyazı yazı rengi (beyaz/sarı, TV uygulaması 0.9.10, katkı: [Kadir Eker](https://github.com/kadireker)), Mac'te her açılışta güncelleme kontrolü.

**beta.23'te gelenler:** daha kararlı altyazı (tekrar eden ve kaybolan satırlar giderildi), hızlı konuşmada önceki satırların TV'de üstte kalması (TV uygulaması 0.9.9), isteğe bağlı yapay zekâ çevirisi (Gemini, OpenAI, Claude), oyun sözlüğüyle daha iyi ücretsiz çeviri, kalıcı çeviri önbelleği, TV'nin kopan bağlantıyı kendisi toparlaması, Android TV'de doğru HDMI girişi, Windows'ta LG parolası ve WebView2 düzeltmeleri.

**beta.22'de gelenler:** LG TV'de sihirli kumandanın işaretçisiyle Tamam tuşu (TV uygulaması 0.9.8).

**beta.21'de gelenler:** TV'de altyazının bir an görünüp kaybolması için düzeltme ve panelde Tanı satırı (TV uygulaması 0.9.7), Windows'ta PS5'in IP adresi değişince yeniden bulunması, PS5 eşleştirme hatalarında gerçek sebebin görünmesi, Windows dublajında Türkçe ses motoru hatasının gösterilmesi.

**beta.20'de gelenler:** LG TV'de "TV uygulaması kurulamadı" hatasının düzeltilmesi (bildiren: [yag_ats](https://x.com/yag_ats)).

**beta.19'da gelenler:** Samsung ve Android TV'de görünmeyen altyazının düzeltilmesi (TV uygulaması 0.9.6), Windows Güvenlik Duvarı izni, GTA V ve renkli zeminlerde daha düzgün çeviri (Windows), ortalı altyazının kutusunun ortada durması (Mac ve Windows).

**beta.18'de gelenler:** OBS katmanı (Mac ve Windows), altyazı geçmişi (Mac, katkı: [rumpony](https://github.com/rumpony)).

**beta.17'de gelenler:** Mac uygulamasının macOS 26'da yeniden açılması, kapanıştaki Remote Play çökmesinin giderilmesi (Mac ve Windows), Mac'te disk dolu uyarısı.

**beta.16'da gelenler:** Ekranı çevir (Windows'ta Num 9, Mac'te ⌥⌘T: menüler, görev paneli ve bilgi kutuları TV'de kendi yerinde Türkçe), TV uygulaması 0.9.5, Windows'ta aynı hizadaki uzak yazıların ayrılması.

**beta.15'te gelenler:** birkaç çeviriyi deneyip en iyisini seçen Windows çevirisi, oyun ifadelerinin ("friendlies", "got your six") anlamıyla çevrilmesi, isteğe bağlı DeepL çevirisi (Mac ve Windows), Windows'ta indirmesiz hızlı Türkçe ses.

**beta.14'te gelenler:** Windows'ta İngilizce yazı tanıma paketi uyarısı ve tek düğmeyle kurulumu, menü/gösterge/kumanda ipuçlarının altyazıya karışmaması, yeni altyazı gelince eski dublaj cümlesinin kesilmesi, fareyle çizilen alan ve Num 1/2/3 ek bölgeler (katkı: [sadumqn](https://github.com/sadumqn)), Samsung'da eski kurulumun yeni sürümü engellememesi.

**İndirme**

| Dosya | Ne için |
|---|---|
| `CouchSubs-macos.dmg` | Mac kurulumu (macOS 13+, Apple Silicon ve Intel) |
| `CouchSubs-windows-Setup.exe` | Windows 10 (2004) / 11 kurulumu, 64 bit |
| `CouchSubs-macos.zip`, `CouchSubs-windows-x64.zip` | Kurulumsuz kullanmak isteyenler için |
| `com.couchsubs.tv_…_all.ipk` | LG TV uygulaması, elle kurmak isteyenler için |
| `CouchSubs-samsung-kaynak.zip` | Samsung TV uygulaması, Tizen Studio ile elle kurmak isteyenler için |
| `CouchSubs-androidtv.apk` | Android TV / Google TV uygulaması, USB bellekle kurmak isteyenler için |
| `appcast.xml`, `releases.win.json`, `*.nupkg` | Uygulama içi güncelleme dosyaları (elle indirmeyin) |
| `SHA256SUMS.txt` | Dosyaların doğrulama özetleri |

**Bilinen durumlar**

- Windows kurulum dosyası imzasız: "Windows bilgisayarınızı korudu" uyarısında **Ek bilgi › Yine de çalıştır**. Uyarı yalnız ilk kurulumda çıkar; güncellemelerde çıkmaz.
- Dublaj yeni: sesin TV'den oyunun sesiyle birlikte çalması her TV'de henüz denenmedi. TV'den ses gelmezse ayarlardan sesi bilgisayara alın ve modelinizi yazın. Oyunun ses ayarlarından konuşma (diyalog) sesini kısın.
- Sesler yapaydır, gerçek kişilere ait değildir: Pocket TTS Turkish (wite-tech, CC BY 4.0), Kyutai'nin pocket-tts programıyla.
- Samsung ve Android TV kurulumu gerçek TV'de henüz az denendi. Sorun olursa TV modelinizle birlikte [Issues](https://github.com/yorulmazsinan/couchsubs/issues) sayfasından yazın; Windows'ta günlükler `%LOCALAPPDATA%\CouchSubs` klasöründe (`hata.log`, `remoteplay.log`).
- PS5 aynı anda tek Remote Play bağlantısına izin verdiği için oyun PS Remote Play uygulamasıyla oynanırken CouchSubs kullanılamaz; PS5'in TV'ye HDMI ile bağlı olması gerekir.
- Mağaza sürümleri henüz yok. Vestel, Arçelik, Beko ve Grundig'in Linux modelleri ile Philips Saphi ve Titan OS desteklenmiyor.

---

New beta. Two new game translation packs: Grand Theft Auto V (story text from the GTA TR / TechnoGame Turkish translation, the rest including GTA Online translated with Claude) and Red Dead Redemption 2 (all subtitles and UI text translated with Claude), shown instantly and offline. Also includes beta.25 and beta.26: game translation packs: supported games show a ready-made Turkish translation instantly and offline; the first pack is Mafia: The Old Country (the whole game text translated with Claude). Shared subtitle pool: English lines missing from the packs are sent anonymously so they can be translated for everyone (can be turned off in Settings). Subtitles on the computer screen: a no-TV setup option and an always-on-top, click-through subtitle window. Free Gemini key step for much better free translation. PS5 pairing and PSN sign-in fixed: Enter now connects and every failure shows its reason. Also includes beta.24: subtitle text colour (TV app 0.9.10, contributed by Kadir Eker) and update checks on every Mac launch. Download: [Mac (DMG)](https://github.com/yorulmazsinan/couchsubs/releases/latest/download/CouchSubs-macos.dmg) · [Windows (installer)](https://github.com/yorulmazsinan/couchsubs/releases/latest/download/CouchSubs-windows-Setup.exe). Also: Three new game translation packs, translated with Claude and shown instantly and offline: Assassin's Creed Shadows (40k lines), Death Stranding 2: On the Beach (23k lines) and Call of Duty: Modern Warfare (2019) (51k lines: multiplayer and Warzone radio chatter, cinematics, menus). Also includes beta.26: game translation packs (first pack Mafia: The Old Country), the anonymous shared subtitle pool (can be turned off in Settings), subtitles on the computer screen (no-TV setup, click-through window), the PS5 pairing and PSN sign-in fix and the free Gemini key step. Download: [Mac (DMG)](https://github.com/yorulmazsinan/couchsubs/releases/latest/download/CouchSubs-macos.dmg) · [Windows (installer)](https://github.com/yorulmazsinan/couchsubs/releases/latest/download/CouchSubs-windows-Setup.exe). Overlay mode for Android TVs where the PS5 picture stays black inside CouchSubs (TCL and others, TV app 0.9. Windows no longer closes when starting translation (errors are shown and logged), and a paired PS5 now reads "paired, connects when translation starts" instead of "not connected". Samsung TV install fixed on Mac (failed after the first install), every install error now shows its reason, and the Samsung TV app is updated automatically.
