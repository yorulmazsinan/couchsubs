# Yeni arayüz: ekranlar, metinler ve davranış

Mac ve Windows yeni arayüzü **birebir aynı metin, düzen ve davranışta** kurar. Tek doğru kaynak onaylı tuvaldir
(`~/Desktop/CouchSubs-tasarim/tuval/`, `canvas.json` sırası); bu belge tuvalden çıkarılmış ortak sözleşmedir.
Tuvalde küçük düzeltme olursa önce tuval dosyası okunur, sonra bu belge güncellenir.

- **Ölçü, renk, yazı ve hareket değerleri:** `design/yeni-arayuz/tasarim.json` (Mac ve Windows doğrudan okur).
- **Metinler:** aşağıdaki tablolar. İlk sütun ortak katalogdaki (`mac/CouchSubs/Resources/Localizable.xcstrings`)
  İngilizce anahtardır, ikinci sütun Türkçesi. Windows aynı katalogu okur (`{t:T '…'}`), yani anahtar iki platformda
  harfi harfine aynıdır. Tablolar `python3 scripts/metinler-katalog.py` ile kataloğa yazılır (eksik anahtar eklenir;
  Türkçesi farklı olan mevcut anahtar raporlanır, üzerine yazılmaz). Yeni metin gerekirse önce buraya eklenir.
- Eski ekranların anahtarları ("Start translating" gibi cümle düzeninde) iPhone ve eski Windows ekranlarında kullanılmaya
  devam eder; yeni arayüz Baş Harfleri Büyük yeni anahtarları kullanır ("Start Translating").

## Genel kurallar

- 8 px ızgara. Kart içi ve kartlar arası 24, öğe arası 16; düğme 48, sekme 40, çip 32, giriş kutusu 48, satır en az 56,
  seçenek kartı en az 64.
- Yazı: gövde 15; başlıklar 18/24/32; mono etiket 12 (büyük harf, +0.08em); gri açıklama/ipucu yazılarında
  −0.5 harf aralığı (gövdede yok). Mono yalnız sayı/teknik bilgi ve bölüm etiketlerinde.
- Renk anlamları: **amber** (#F5B83D) = ana eylem ve açık anahtar; **yeşil** = tamamlandı/başarı; **kırmızı** (#D9542F) =
  canlı/çalışıyor-durdur ve uyarı. Bir ekranda tek ana (amber) düğme.
- Düğme, sekme, seçenek etiketi, başlık ve kısa durum etiketleri **Her Kelimenin Baş Harfi Büyük** (bağlaçlar küçük:
  "ya da", "ve", "ile"). Tam cümle olan açıklama ve ipuçları **nokta ile biter**.
- Tüm tek seçimli seçiciler üst menü sekme stilinde (`DSTabs`). Anahtar (switch) satırın başında, yazının solunda; açık
  rengi amber. Giriş kutuları tam yuvarlak; kopyala simgesi kutunun içinde.
- Aralıklar: üst menü → ilk içerik 24; etiket → giriş kutusu 12; başlık → açıklama 4; kart içi mono bölüm etiketi ile
  altındaki içerik arası en az 24 (kart boşluğu 16 + 8). Başlık + sağda düğme olan satırlarda alt boşluk satırın
  kendisindedir, ikisi dikeyde ortalıdır.
- Başarı durumu (Eşleşti, Onaylandı, Kaydedildi, Kopyalandı) "btnok": açık yeşil zemin, yeşil yazı, tik, küçük oturma
  animasyonu. İşlem sürerken düğme "…ıyor…" yazar, soluklaşır, tekrar basılamaz (Yeniden Ara → Aranıyor…).
  Düğmelerde alt çizgi yok; alt çizgi yalnız cümle içi bağlantıda.
- Kartlar taşarsa kendi içinde ince çubukla kayar; sayfa kaymaz.
- Pencere: en küçük 1200 × 760 (daha fazla küçülmez). Büyüyünce sütunlar oransal genişler; boşluklar ve yazı boyları
  sabit; oyun görüntüsü hep 16:9; çok geniş ekranda içerik en fazla 1680 genişlikte ortalanır.
- Hareket: kısa 150 ms, orta 250 ms, sayfa 350 ms; giriş eğrisi cubic-bezier(0.05, 0.7, 0.1, 1), çıkış
  (0.3, 0, 0.8, 0.15), çıkış ≈ girişin yarısı. Sistem "hareketi azalt" ya da Ayarlar › Temel › Geçiş Animasyonları
  kapalıyken yalnız 100 ms solma.
- Açılış animasyonu ve sesi **yalnız ilk kurulumun karşılama adımında**; sonraki açılışlar sessiz, uygulama hazır
  olunca kısa solmayla açılır. Ses Ayarlar › Temel › Açılış Sesi'nden kapanır.
- Telif: Hakkında'da "© 2026 Enmera" + Enmera logosu (kişi adı yok).

## Bileşenler (Mac `UI/Yeni/DSComponents.swift`, Windows aynı adlarla)

| Bileşen | Tuval sınıfı | Tarif |
|---|---|---|
| `DSCard` | `.card` | Yüzey #FAF8F4, 24 köşe, 1 pt #E3DDD3 halka, 24 iç boşluk; taşarsa içte kayar. Deneysel kartta solda 4 pt kırmızı şerit. |
| `DSButtonStyle.primary` | `.btnp` | Amber, 48, tam yuvarlak, 15 yarı kalın; üzerine gelince #F8C65A; basılıyken %97. |
| `DSButtonStyle.dark` | `.btnk` | Kömür #2B2D33 zemin, krem yazı. |
| `DSButtonStyle.secondary` | `.btns` | Yüzey zemin, 1 pt halka, 15 orta kalınlık, yanlarda 20. |
| `DSButtonStyle.stop` | `.btnlive` + `.sq` | Kırmızı tonlu zemin, kırmızı yazı, solda 10 pt kare ("Çeviriyi Durdur"). |
| `DSButtonStyle.live` | `.btnlive` + `.ld` | Aynı, solda atan 8 pt nokta. |
| `DSSuccessBadge` | `.btnok` | Başarı: yeşil tonlu zemin, tik, 300 ms oturma. |
| `DSTabs` | `.segwrap` / `.seg` / `.tab` | 4 pt iç boşluklu kapsül (#F1EDE6), seçili sekme yüzey + gölge + halka; 40 yükseklik. Üst menüde sekme en az 112. |
| `DSSwitch`, `DSSwitchRow` | `.sw`, `.row.swl` | 44 × 26, açık amber, kapalı #D6D0C4; satırın başında; satır en az 56, altta ayraç. |
| `DSFieldChrome`, `DSTextFieldStyle`, `DSCopyField` | `.inp`, `.cpy` | 48, tam yuvarlak, #F1EDE6 zemin, odakta amber halka; kopyala simgesi içte sağda (32). |
| `DSMonoLabel`, `DSCardHeader` | `.mono` | 12 mono, büyük harf, #6B665F, +0.08em; altına 8 ek boşluk. |
| `DSBadge` | `.badge .ok/.warn/.unk/.amb` | 24, 12 yarı kalın, tam yuvarlak. |
| `DSStatusPill` | üst çubuk sağı | 40, nokta + 13 pt durum. |
| `DSOptionStyle`, `DSRadio` | `SEL`, `RADIO` | Seçenek kartı en az 64, 16 köşe, seçiliyken 2 pt amber; radyo 20, seçiliyken 6 pt amber halka. |
| `DSAdBand` | `.adband` | 64 yükseklik, 16 köşe, sağ üstte 9 pt mono "REKLAM", 3 reklam 6 sn arayla (8 pt kayarak) döner, sağda 36'lık koyu "İncele". |
| `DSLogoMark`, `DSBrand` | logo SVG | Arka plansız kanepe + iki amber çubuk (çubuklar 1,6 sn'de nefes alır); 36 × 26; yanında 15 pt kalın "CouchSubs". |
| `DSScreenFrame` | oyun önizlemesi | 16 köşe, 6 pt #5A5D66 çerçeve, 16:9. |
| `DSColorDot` | renk yuvarlağı | 32 (karakter satırında 24); seçiliyken 2 pt boşluk + 2 pt amber halka; "Zeminsiz" dama deseni. |

## Reklam kuralları

- **Reklam bandı** (`DSAdBand`): Ana Ekran, Geçmiş, Ayarlar ve diğer uygulama sayfalarının altında sabit (kenarlardan 24,
  alttan 16). Kurulum, açılış, oyun görüntüsü/yayın pencerelerinde **yok**. İçerik şimdilik yerel örnek; uzaktan liste sonra.
- **Açılır reklam**: yalnız görsel (yazı/düğme yok); görselin oranına göre yatay ya da dikey açılır; tıklanınca bağlantı;
  köşede × ve küçük REKLAM etiketi. Günde en fazla 1; yalnız uygulama açılışında ya da çeviri durunca; çeviri sürerken,
  kurulumda ve görüntü penceresinde asla. Üçüncü taraf reklam ağı, izleme yok.

## Pencere kabuğu (üst çubuk)

72 yükseklik, yanlarda 24; üç sütun: solda `DSBrand`, ortada sekmeler, sağda durum hapı. Profil sayfası yok; her şey Ayarlar'da.

| EN | TR |
|---|---|
| Home | Ana Ekran |
| History | Geçmiş |
| Settings | Ayarlar |
| Translation On | Çeviri Açık |
| Ready | Hazır |
| Connecting… | Bağlanıyor… |
| Needs Attention | Sorun Var |
| Setup Incomplete | Kurulum Eksik |
| Demo Mode | Deneme Modu |
| AD | REKLAM |
| Advertisement | Reklam |
| Learn More | İncele |
| App Name | Uygulama Adı |
| Sample ad: a short introduction goes here. | Örnek reklam: kısa tanıtım cümlesi buraya gelir. |
| Second App | İkinci Uygulama |
| Sample ad: ads rotate every 6 seconds. | Örnek reklam: reklamlar sırayla, 6 saniyede bir değişir. |
| Third App | Üçüncü Uygulama |
| Sample ad: the contents will be decided later. | Örnek reklam: içerikler sonra belirlenecek. |

Durum hapı: çeviri sürüyorsa yeşil nokta + "Çeviri Açık"; bağlanırken amber + "Bağlanıyor…"; sorun varsa kırmızı +
"Sorun Var"; kurulum bitmediyse gri + "Kurulum Eksik"; deneme modunda amber + "Deneme Modu"; yoksa gri + "Hazır".

## 00 · Açılış (yalnız ilk kurulum)

Koyu zemin; kanepe parçaları sırayla yükselir (arkalık 80 ms, oturak 300 ms), parıltı 650 ms, çubuklar 780/920 ms'de
soldan açılır, "CouchSubs" 1150 ms, "by Enmera" 1500 ms, düğme 2300 ms. Ses 2–3 sn, atlanabilir.

| EN | TR |
|---|---|
| by | by |
| Let's Get Started | Hadi Başlayalım |
| Setup takes about 3 minutes. | Kurulum yaklaşık 3 dakika sürer. |
| Replay with Sound | Sesli Yeniden Oynat |
| Replay Silently | Sessiz Oynat |
| Skip Intro | Atla |

## Kurulum ortak

Üst çubukta solda `DSBrand`, sağda "Sonra Ayarlarım" (ikincil). İçerik alanı yanlarda 120, üstte 24, altta 40. Altta
solda "Geri" (ikincil), sağda tek ana düğme "Devam"; aralarında küçük gri durum notu. Adım etiketi "ADIM 1 / 4".
Kurulumda reklam yok.

| EN | TR |
|---|---|
| I'll Set Up Later | Sonra Ayarlarım |
| STEP %lld / %lld | ADIM %lld / %lld |
| Back | Geri |
| Continue | Devam |
| Skip for Now | Şimdilik Geç |

## 01 · Kurulum: Konsol

| EN | TR |
|---|---|
| Which console do you play on? | Hangi konsolda oynuyorsunuz? |
| CouchSubs gets the picture from the console over your local network. Nothing is installed on your console. | CouchSubs görüntüyü konsoldan yerel ağ üzerinden alır. Konsolunuza hiçbir şey kurulmaz. |
| PlayStation 5 | PlayStation 5 |
| With Remote Play | Uzaktan Oynatma ile |
| Xbox Series | Xbox Series |
| With Remote Features | Uzak Özellikler ile |
| WINDOW | PENCERE |
| Game Window | Oyun Penceresi |
| Remote Play, OBS, Capture Card | Remote Play, OBS, Capture Kartı |
| You can change the console later in Settings. | Konsolu sonra Ayarlar'dan değiştirebilirsiniz. |

## 02 · Kurulum: PlayStation Hesabı

QR kodu yerel üretilir (Sony'nin resmi hesap açma sayfası). Dört madde tıklanınca yeşil tik alır.

| EN | TR |
|---|---|
| SETUP · ACCOUNT | KURULUM · HESAP |
| Second PlayStation Account | İkinci PlayStation Hesabı |
| CouchSubs connects to the PS5 by itself with a second account. You keep playing with your main account. | CouchSubs PS5'e ikinci hesapla kendisi bağlanır. Siz ana hesabınızla oynamaya devam edersiniz. |
| DONE ONCE | BİR KEZ YAPILIR |
| Create a free account on playstation.com with a different email address. | playstation.com'da farklı bir e-posta adresiyle ücretsiz bir hesap açın. |
| On the PS5, choose Add User and sign in once with the new account. | PS5'te Kullanıcı Ekle'yi seçin ve yeni hesapla bir kez oturum açın. |
| While still on the new user, go to Settings › System › Remote Play and turn on Enable Remote Play. | Hâlâ yeni kullanıcıdayken Ayarlar › Sistem › Uzaktan Oynama'ya gidip Uzaktan Oynama'yı Etkinleştir'i açın. |
| Switch back to your own user. You only do this once. | Kendi kullanıcınıza geri dönün. Bunu yalnızca bir kez yaparsınız. |
| Sony's PS Remote Play app can't be used meanwhile. | Bu sırada Sony'nin PS Remote Play uygulaması kullanılamaz. |
| I Don't Have a Second Account: Read the Remote Play Window | İkinci Hesabım Yok: Remote Play Penceresini Oku |
| Scan with Your Phone | Telefonla Okutun |
| The code opens Sony's free account sign-up page. | Kod, Sony'nin ücretsiz hesap açma sayfasını açar. |
| Open the Page on This Mac | Sayfayı Bu Mac'te Aç |
| Sign In with the Second Account | İkinci Hesapla Giriş Yap |
| Waiting for Sign-In in the Browser… | Tarayıcıda Giriş Bekleniyor… |
| Signed In | Giriş Yapıldı |
| The account is stored on this Mac. You can change it any time in Settings › Console and Source. | Hesap bu Mac'te saklanır. İstediğiniz zaman Ayarlar › Konsol ve Kaynak'tan değiştirebilirsiniz. |
| Sign In Again | Yeniden Giriş Yap |
| If sign-in opens in the browser, finish it there; the app continues by itself. | Giriş tarayıcıda açılırsa orada tamamlayın, uygulama kendiliğinden devam eder. |

## 03 · Kurulum: PS5'e Bağlan

Bulunan cihazlar kart kart belirir; 10 sn'de bulunamazsa ipucu kartı açılır, elle IP baştan görünür.

| EN | TR |
|---|---|
| Let's Connect to the PS5 | PS5'e Bağlanalım |
| You signed in with your free second PlayStation account. Now we're looking for the PS5 on the same network. | Ücretsiz ikinci PlayStation hesabınızla giriş yaptınız. Şimdi aynı ağdaki PS5'i arıyoruz. |
| Searching for the PS5 | PS5 Aranıyor |
| Scanning devices on the same network. | Aynı ağdaki cihazlar taranıyor. |
| PS5 Found | PS5 Bulundu |
| Choose the one you want to connect to. | Bağlanmak istediğinizi seçin. |
| Searching… | Aranıyor… |
| Search Again | Yeniden Ara |
| On | Açık |
| In Rest Mode | Dinlenme Modunda |
| Can't Find the PS5? | PS5 Bulunamadı mı? |
| The PS5 and this Mac must be on the same Wi-Fi network. On the PS5, Stay Connected to the Internet must be on in Settings › System › Power Saving. Turn off any VPN. A 5 GHz network works better. | PS5 ile bu Mac aynı Wi-Fi ağında olmalı. PS5'te Ayarlar › Sistem › Güç Tasarrufu'nda "İnternete Bağlı Kal" açık olmalı. VPN açıksa kapatın. 5 GHz ağ daha iyi çalışır. |
| Check What's Missing | Neyin Eksik Olduğunu Denetle |
| Manual IP Address | Elle IP Adresi |
| CONNECTION | BAĞLANTI |
| PlayStation Account | PlayStation Hesabı |
| Signed in with the second account. | İkinci hesapla giriş yapıldı. |
| %@ selected. | %@ seçildi. |
| Pairing and First Picture | Eşleşme ve İlk Görüntü |
| Setting up an encrypted connection with the PS5. | PS5 ile şifreli bağlantı kuruluyor. |
| Always start the game on the PS5 with your main account. CouchSubs only watches the picture and never touches the game. | Oyunu her zaman PS5'te ana hesabınızla başlatın. CouchSubs yalnız görüntüyü izler, oyuna dokunmaz. |
| If the PS5 isn't found, tips open after 10 seconds. | PS5 bulunamazsa 10 saniye sonra ipuçları açılır. |
| PS5 Login Passcode | PS5 Giriş Şifresi |

## 04 · Kurulum: PS5 Bulunamadı

Denetimler kendiliğinden yapılır; okunamayan madde "Bilinmiyor" (uydurma yok).

| EN | TR |
|---|---|
| COULDN'T CONNECT TO THE PS5 | PS5'E BAĞLANILAMADI |
| Here's What We Checked | Neyin Eksik Olduğuna Baktık |
| Fix the item with a problem and press Try Again. Things we couldn't read are shown as "Unknown". | Sorunlu maddeyi düzeltip Yeniden Dene'ye basın. Okuyamadığımız şeyleri "Bilinmiyor" olarak gösteriyoruz. |
| Same Network | Aynı Ağ |
| This Mac and the PS5 appear to be on the same network. | Bu Mac ve PS5 aynı ağda görünüyor. |
| This Mac isn't connected to a local network. Connect it to the same Wi-Fi as the PS5. | Bu Mac yerel bir ağa bağlı değil. PS5 ile aynı Wi-Fi ağına bağlayın. |
| PS5 Responds | PS5 Yanıt Veriyor |
| The PS5 was found. | PS5 bulundu. |
| The PS5 didn't answer the search. The PS5 must be on or in rest mode. | PS5 aramaya yanıt vermedi. PS5 açık ya da dinlenme modunda olmalı. |
| Remote Play On | Uzaktan Oynama Açık |
| On the second user, Settings › System › Remote Play › Enable Remote Play must be on. | İkinci kullanıcıda Ayarlar › Sistem › Uzaktan Oynama › Uzaktan Oynama'yı Etkinleştir açık olmalı. |
| Internet in Rest Mode | Dinlenme Modunda İnternet |
| Staying connected to the internet in rest mode must be on; otherwise the PS5 can't be woken up. | Dinlenme modunda PS5'in internete bağlı kalması açık olmalı; yoksa uyandırılamaz. |
| Wi-Fi 5 GHz | Wi-Fi 5 GHz |
| You're on a 5 GHz network. | 5 GHz ağdasınız. |
| This Mac is on a 2.4 GHz network. A 5 GHz network works more smoothly and reliably. | Bu Mac 2,4 GHz ağda. 5 GHz ağ daha akıcı ve kararlı çalışır. |
| This Mac is connected by cable or the Wi-Fi band couldn't be read. | Bu Mac kabloyla bağlı ya da Wi-Fi bandı okunamadı. |
| VPN Off | VPN Kapalı |
| No active VPN was found. | Açık VPN bulunmadı. |
| A VPN is on. Turn it off while playing; it can hide the PS5. | Açık bir VPN var. Oynarken kapatın; PS5'i gizleyebilir. |
| Passed | Geçti |
| Problem | Sorunlu |
| Unknown | Bilinmiyor |
| Checking… | Denetleniyor… |
| Try Again | Yeniden Dene |
| Do You Know the PS5's Address? | PS5'in Adresini Biliyor musunuz? |
| On the PS5, the IP address is shown in Settings › Network › Connection Status. | PS5'te Ayarlar › Ağ › Bağlantı Durumu'nda IP adresi yazar. |
| Connect | Bağlan |
| Show Log File | Günlük Dosyasını Göster |
| If the problem continues, attach the log file to an issue on GitHub. | Sorun sürerse günlük dosyasını GitHub'daki sorun bildirimine ekleyin. |

## 05 · Kurulum: TV

Kod iki ekranda: TV'de görünen 4 haneli kod burada da gösterilir; kullanıcı "TV'de Bu Kodu Görüyorum" ile onaylar.

| EN | TR |
|---|---|
| Show Subtitles on the TV | Altyazı TV'de Görünsün |
| We found a TV on the network. Choose it and CouchSubs installs its app on the TV by itself. | Ağda bir TV bulduk. Seçin, CouchSubs uygulamasını TV'ye kendisi kursun. |
| We're looking for TVs on the network. Choose yours and CouchSubs installs its app on the TV by itself. | Ağdaki TV'leri arıyoruz. Seçin, CouchSubs uygulamasını TV'ye kendisi kursun. |
| TVS ON THE NETWORK | AĞDAKİ TV'LER |
| Not in the List? | Listede Yok mu? |
| Choose the Brand and Add It Manually | Markayı Seçip Elle Ekleyin |
| I Don't Have a TV | TV'm Yok |
| Checking Developer Mode | Geliştirici Modu Denetleniyor |
| Installing the App | Uygulama Kuruluyor |
| Installation Complete | Kurulum Tamam |
| Approve the code on the TV, then let's try it. | TV'de kodu onaylayın, sonra deneyelim. |
| CODE SHOWN ON THE TV | TV'DE GÖRÜNEN KOD |
| Do You See This Code on Your TV Too? | Bu Kod TV'nizde de Görünüyor mu? |
| If you see the same code, you're on the right TV. Approving completes the pairing. | Aynı kodu görüyorsanız doğru TV'desiniz. Onaylayınca eşleşme tamamlanır. |
| I See This Code on the TV | TV'de Bu Kodu Görüyorum |
| Paired | Eşleşti |
| If the installation continues in the background, it shows on the home screen when it's done. | Kurulum arka planda sürerse bitince ana ekranda görünür. |
| Approve the code on the TV to continue. If you don't have a TV, skip with "I Don't Have a TV". | Devam etmek için TV'deki kodu onaylayın. TV'niz yoksa "TV'm Yok" seçeneğiyle geçebilirsiniz. |
| Open CouchSubs on the TV. When it shows a code, it appears here too. | TV'de CouchSubs'ı açın. Kod gösterince burada da görünür. |
| Show Subtitles on This Computer | Altyazıyı Bu Bilgisayarda Göster |

## 06 · Kurulum: TV Girişi (HDMI)

Seçim TV uygulamasına gider (`hdmiInput` alanı, aşağıda). "Bilmiyorum, Sırayla Dene" girişleri tek tek açar.

| EN | TR |
|---|---|
| TV INPUT | TV GİRİŞİ |
| Which TV Input Is the PS5 Plugged Into? | PS5 TV'nin Hangi Girişine Takılı? |
| CouchSubs opens this input on the TV to show subtitles over the game. If the wrong input is chosen, the screen stays black. | CouchSubs, altyazıyı oyunun üstünde göstermek için TV'de bu girişi açar. Yanlış giriş seçilirse ekran siyah kalır. |
| I Don't Know, Try Them in Turn | Bilmiyorum, Sırayla Dene |
| We open the inputs one by one; you confirm when you see the picture. | Girişleri tek tek açarız, görüntüyü görünce onaylarsınız. |
| How Do I Tell? | Nereden Anlarım? |
| The number is printed on the back of the TV next to the port the PS5 cable is plugged into. If the PS5 is plugged into a sound system (soundbar, amplifier), choose the input the sound system is connected to. | PS5 kablosunun takılı olduğu yuvanın yanında TV'nin arkasında numarası yazar. PS5 bir ses sistemine (soundbar, amfi) takılıysa ses sisteminin TV'ye bağlı olduğu girişi seçin. |
| HDMI %lld · Trying | HDMI %lld · Deneniyor |
| No picture on this input. | Bu girişte görüntü yok. |
| Do You See the Game Picture on the TV? | TV'de Oyun Görüntüsünü Görüyor musunuz? |
| Yes | Evet |
| Confirmed | Onaylandı |
| No, Next Input | Hayır, Sonraki Giriş |
| The choice is remembered. You can change it later in Settings › Consoles. | Seçim hatırlanır. Sonradan Ayarlar › Konsollar'dan değiştirebilirsiniz. |
| HDMI %lld saved. | HDMI %lld kaydedildi. |
| Confirm the picture to continue. | Devam etmek için görüntüyü onaylayın. |

## 07 · Kurulum: Daha İyi Çeviri (Gemini)

| EN | TR |
|---|---|
| SETUP · TRANSLATION | KURULUM · ÇEVİRİ |
| Better Translation (Free) | Daha İyi Çeviri (Ücretsiz) |
| If you like, add a free Gemini key. Without it the free translation is used; you can also add it later in Settings. | İsterseniz ücretsiz bir Gemini anahtarı ekleyin. Eklemezseniz ücretsiz çeviri kullanılır, sonra Ayarlar'dan da ekleyebilirsiniz. |
| HOW TO GET A KEY | ANAHTAR NASIL ALINIR |
| Press Get a Free Key and sign in with your Google account. | Ücretsiz Anahtar Al'a basın ve Google hesabınızla giriş yapın. |
| Press Create API Key and copy the key. | API Anahtarı Oluştur'a basın ve anahtarı kopyalayın. |
| Paste the key here and press Save and Test. | Anahtarı buraya yapıştırın ve Kaydet ve Dene'ye basın. |
| Get a Free Key | Ücretsiz Anahtar Al |
| The free key has a per-minute limit. When the limit is reached, that line is translated with the free translation. | Ücretsiz anahtarın dakikalık bir sınırı var. Sınıra gelinince o satır ücretsiz çeviriyle çevrilir. |
| API KEY | API ANAHTARI |
| Save and Test | Kaydet ve Dene |
| Testing… | Deneniyor… |
| Working | Çalışıyor |
| Sample translation: "%@" | Örnek çeviri: "%@" |
| Gemini is ready. Subtitles will be translated with Gemini. | Gemini hazır. Altyazılar Gemini ile çevrilecek. |
| The key is stored only in this Mac's keychain. | Anahtar yalnız bu Mac'in anahtar zincirinde saklanır. |

## 08 · Kurulum: Deneyelim

Bağlantı, kare, çeviri ve TV ayrı ayrı yeşil tik alır.

| EN | TR |
|---|---|
| Let's Try It | Deneyelim |
| We test each part one by one. You should see a sample Turkish subtitle on the TV. | Her parçayı tek tek deniyoruz. TV'de örnek bir Türkçe altyazı görmelisiniz. |
| PS5 Connection | PS5 Bağlantısı |
| Picture Arriving | Görüntü Geliyor |
| %lld Frames per Second | Saniyede %lld Kare |
| Translation Working | Çeviri Çalışıyor |
| Sample Sentence Translated | Örnek Cümle Çevrildi |
| TV Shows the Subtitle | TV Altyazıyı Gösteriyor |
| Subtitle on This Screen | Altyazı Bu Ekranda |
| Do you see this subtitle on the TV? | TV'de bu altyazıyı görüyor musunuz? |
| Do you see this subtitle on the screen? | Ekranda bu altyazıyı görüyor musunuz? |
| Yes, I See It | Evet, Görüyorum |
| I Don't See It | Görmüyorum |

## 09–10 · Ana Ekran (çeviri açık / sorun var)

Üstte 4 durum çipi (PS5, TV, Oyun, Çeviri; her biri yeşil tik + değer + mono ek bilgi). Solda (2fr) oyun görüntüsü
(16:9, CANLI hapı, sağ üstte mono "PS5 · 10 Kare/sn", okunan alan amber kesikli çerçeve) ve altında üç düğme (Çeviriyi
Başlat/Durdur, Ekranı Çevir, TV'de Dene). Sağda (1fr) Durum kartı (satır sayısı + kıvılcım çizgi, paketten oranı halka,
ortalama gecikme çubukları) ve Canlı Akış (son satırlar, "Geçmiş →"). Sorun varken Durum kartının yerinde sessizlik nedeni
kartı: "%lld SN SESSİZ", neden başlığı, açıklama, çözüm düğmeleri ve kontrol satırları.

| EN | TR |
|---|---|
| Game | Oyun |
| Translation | Çeviri |
| Pack | Paket |
| Not Set Up | Kurulmadı |
| Not Connected | Bağlı Değil |
| Waiting | Bekleniyor |
| Unknown Game | Bilinmeyen Oyun |
| LIVE | CANLI |
| STOPPED | DURDU |
| %lld Frames/s | %lld Kare/sn |
| Area Read | Okunan Alan |
| Start Translating | Çeviriyi Başlat |
| Stop Translating | Çeviriyi Durdur |
| Starting… | Başlatılıyor… |
| Exit Demo Mode | Deneme Modundan Çık |
| Translate the Screen | Ekranı Çevir |
| Try on TV | TV'de Dene |
| Try on Screen | Ekranda Dene |
| Opening the App on the TV… | TV'de Uygulama Açılıyor… |
| STATUS | DURUM |
| Subtitles Flowing | Altyazı Akıyor |
| Translation Stopped | Çeviri Durdu |
| Waiting for Subtitles | Altyazı Bekleniyor |
| Lines · %lld/min | Satır · %lld/dk |
| From Pack · %lld%% | Paketten · %%%lld |
| Average Delay | Ortalama Gecikme |
| LIVE FEED | CANLI AKIŞ |
| History → | Geçmiş → |
| Subtitles will appear here while you play. | Siz oynarken altyazılar burada görünecek. |
| %lld S SILENT | %lld SN SESSİZ |
| Menu Open | Menü Açık |
| A menu is open in the game; there's no subtitle. | Oyunda menü açık, altyazı yok. |
| We don't translate the text in the pause menu. The subtitles come back by themselves when you return to the game. | Duraklatma menüsündeki yazıları çevirmiyoruz. Oyuna dönünce altyazı kendiliğinden gelir. |
| Translate Menus Too (On-Screen Text) | Menüleri de Çevir (Ekran Yazıları) |
| Area Empty | Alan Boş |
| No text is visible in the area being read. | Okunan alanda yazı görünmüyor. |
| Subtitles may appear somewhere else in this game. Try finding the area automatically or draw it yourself. | Bu oyunda altyazı başka bir yerde çıkıyor olabilir. Alanı otomatik bulmayı deneyin ya da elle çizin. |
| Find the Area Automatically | Alanı Otomatik Bul |
| Draw the Area Manually | Alanı Elle Çiz |
| Picture Stopped | Görüntü Durdu |
| The PS5 picture hasn't arrived for %lld seconds. | PS5 görüntüsü %lld saniyedir gelmiyor. |
| The connection may have weakened. CouchSubs is trying to reconnect; if it doesn't, check that you're on the same Wi-Fi network as the PS5 and using 5 GHz. | Bağlantı zayıflamış olabilir. CouchSubs yeniden bağlanmayı deniyor; olmazsa PS5 ile aynı Wi-Fi ağında olduğunuzu ve 5 GHz kullandığınızı kontrol edin. |
| Reconnect Now | Şimdi Yeniden Bağlan |
| Open the Connection Test | Bağlantı Testini Aç |
| Off | Kapalı |
| Completed | Yapıldı |
| Game Subtitles Off? | Oyunun Altyazısı Kapalı mı? |
| CouchSubs reads the English subtitles on screen, not the audio. Turn on the game's own subtitles. | CouchSubs sesi değil, ekrandaki İngilizce altyazıyı okur. Oyunun kendi altyazısını açın. |
| Open the TV App | TV Uygulamasını Aç |
| Update the TV App | TV Uygulamasını Güncelle |
| Reinstall the TV App | TV Uygulamasını Yeniden Kur |
| Connect TV | TV Bağla |
| Change the TV | TV'yi Değiştir |
| Connect Again | Yeniden Bağlan |
| Restart CouchSubs Now | CouchSubs'ı Yeniden Başlat |
| Open Language and Region | Dil ve Bölge'yi Aç |
| Try Demo Mode | Deneme Modunu Aç |

## 11 · Hangi Oyun?

| EN | TR |
|---|---|
| GAME BEING PLAYED | OYNANAN OYUN |
| Which Game Are You Playing? | Hangi Oyunu Oynuyorsunuz? |
| Search Games | Oyun Ara |
| Pack Available | Paket Var |
| Last Played | Son Oynanan |
| Lines not in a pack go to the shared pool with the game's name, so a ready translation for that game arrives sooner. | Pakette olmayan satırlar oyunun adıyla ortak havuza gider; böylece o oyunun hazır çevirisi daha çabuk gelir. |
| There are saved areas for %@. Use them? | %@ için kayıtlı alanlar var. Kullanılsın mı? |
| Use | Kullan |
| No | Hayır |
| Not in the List | Listede Yok |
| Don't Ask | Sorma |

## 12 · Ekranı Çevir / Serbest Alan

| EN | TR |
|---|---|
| Drag over the text you want to translate. Esc or a right-click closes. | Çevirmek istediğiniz yazının üstünü sürükleyin. Esc ya da sağ tık kapatır. |
| Translating… | Çevriliyor… |
| Press %@ while playing: the picture freezes; drag over any part of it to translate that part once. Translate the Screen (%@) always translates the whole screen. | Oynarken %@ tuşuna basın: görüntü donar, herhangi bir yerini sürükleyip o kısmı bir kez çevirin. Ekranı Çevir (%@) her zaman ekranın tamamını çevirir. |

## 13 · Görüntü Penceresi (yayın)

| EN | TR |
|---|---|
| CouchSubs Stream | CouchSubs Yayın |
| Cover | Örtsün |
| Hide the Bar | Çubuğu Gizle |
| Show the Bar | Çubuğu Göster |

## 14 · Oyun Penceresi Seçimi

| EN | TR |
|---|---|
| OBS PROJECTOR OR GAME WINDOW | OBS PROJEKTÖRÜ VEYA OYUN PENCERESİ |
| Refresh Windows | Pencereleri Yenile |
| If the window isn't listed, open OBS or the game first, then refresh. If screen recording permission is needed, | Pencere görünmüyorsa önce OBS'i ya da oyunu açın, sonra yenileyin. Ekran kaydı izni gerekirse |
| Open macOS Settings | Sistem Ayarlarını Aç |
| SELECTED WINDOW | SEÇİLEN PENCERE |
| Use This Window | Bu Pencereyi Kullan |
| Set the Subtitle Area | Altyazı Alanını Ayarla |
| No window selected. | Pencere seçilmedi. |

## 15 · Xbox

| EN | TR |
|---|---|
| XBOX · MICROSOFT ACCOUNT | XBOX · MICROSOFT HESABI |
| Sign In with Your Microsoft Account | Microsoft Hesabınızla Giriş Yapın |
| Link your Xbox account with a Microsoft device code. The sign-in page opens in your default browser. | Xbox hesabınızı Microsoft cihaz koduyla bağlayın. Giriş sayfası varsayılan tarayıcınızda açılır. |
| Sign In with Microsoft | Microsoft ile Giriş Yap |
| Enter the Code on the Microsoft Page | Kodu Microsoft Sayfasına Girin |
| Copy the code, paste it on the Microsoft page that opens and finish signing in. | Kodu kopyalayın, açılan Microsoft sayfasına yapıştırın ve girişi bitirin. |
| Open the Microsoft Page | Microsoft Sayfasını Aç |
| Copy the Code | Kodu Kopyala |
| Searching for Xbox Consoles… | Xbox Konsolları Aranıyor… |
| Microsoft sign-in is done. Getting the consoles on this account. | Microsoft girişi tamam. Bu hesaptaki konsollar getiriliyor. |
| Find Consoles | Konsolları Bul |
| Choose Your Xbox at Home | Evdeki Xbox'ınızı Seçin |
| Choose the console to use. | Kullanılacak konsolu seçin. |
| Use This Xbox | Bu Xbox'ı Kullan |
| Remote Features Off | Uzak Özellikler Kapalı |
| Start Over | Baştan |
| SOUND | SES |
| Play Xbox Sound on This Computer | Xbox Sesini Bu Bilgisayarda Çal |
| When off, sound comes only from the TV. | Kapalıyken ses yalnız TV'den gelir. |
| Playing with the Xbox App or play.xbox.com on This Computer? | Bu Bilgisayarda Xbox Uygulaması ya da play.xbox.com ile mi Oynuyorsunuz? |
| Then you don't need to sign in with Microsoft; just choose the game window. | O zaman Microsoft girişine gerek yok; oyun penceresini seçmeniz yeter. |
| Choose the Game Window | Oyun Penceresini Seç |
| CouchSubs is not affiliated with Microsoft. Xbox is a trademark of Microsoft Corporation. | CouchSubs, Microsoft ile bağlantılı değildir. Xbox, Microsoft Corporation'ın ticari markasıdır. |

## 16 · Geçmiş

| EN | TR |
|---|---|
| All | Tümü |
| Search Subtitles | Altyazılarda Ara |
| TIME | SAAT |
| TURKISH | TÜRKÇE |
| ENGLISH | İNGİLİZCE |
| SOURCE | KAYNAK |
| No lines match this search. | Bu aramaya uyan satır yok. |
| No subtitles yet. Lines translated while you play appear here. | Henüz altyazı yok. Oynarken çevrilen satırlar burada görünür. |
| %@ · Today · %lld Lines | %@ · Bugün · %lld Satır |
| Today · %lld Lines | Bugün · %lld Satır |
| Export | Dışa Aktar |
| Report a Wrong Translation | Hatalı Çeviriyi Bildir |
| Clear History | Geçmişi Temizle |
| Copy All | Tümünü Kopyala |
| Free | Ücretsiz |
| Apple | Apple |
| AI | Yapay Zekâ |

## 17 · Menü Çubuğu, Hakkında, Sürüm Notları

| EN | TR |
|---|---|
| Clicks Pass to the Window Below | Tıklamalar Alttaki Pencereye Geçsin |
| Subtitles don't block clicks. | Altyazı tıklamaları engellemez. |
| Position the Subtitles | Altyazıları Konumlandır |
| Show CouchSubs | CouchSubs'ı Aç |
| ABOUT | HAKKINDA |
| Free and open source under the GNU AGPL-3.0 license. | GNU AGPL-3.0 lisansıyla ücretsiz ve açık kaynak. |
| Remote Play connection by chiaki-ng (AGPL-3.0). Thanks to its developers. | Uzaktan Oynatma bağlantısı chiaki-ng (AGPL-3.0) ile. Geliştiricilerine teşekkürler. |
| The Xbox home console picture uses the open source approach of Greenlight (MIT). | Xbox ev konsolu görüntüsü Greenlight'ın açık kaynak yaklaşımını kullanır (MIT). |
| CouchSubs is not affiliated with Microsoft. | CouchSubs, Microsoft ile bağlantılı değildir. |
| CouchSubs is not affiliated with Sony Interactive Entertainment. | CouchSubs, Sony Interactive Entertainment ile bağlantılı değildir. |
| Source | Kaynak |
| Check for Updates… | Güncellemeleri Denetle… |
| Copyright © 2026 Enmera | Telif Hakkı © 2026 Enmera |
| RELEASE NOTES | SÜRÜM NOTLARI |
| This Version | Bu Sürüm |
| Previous | Önceki |
| About CouchSubs | CouchSubs Hakkında |
| Release Notes | Sürüm Notları |

## 18 · Açılır Reklam

| EN | TR |
|---|---|
| Close | Kapat |

## 19 · Ayarlar: Temel / Altyazı Görünümü / Gelişmiş

Solda 240 genişlikte gezinme kartı: üstte üç bölüm (64 yükseklik, başlık + gri ipucu), ayraç, altında altı sayfa
(44 yükseklik). En altta gri not "Ayarlar tek yerde. Profil sayfası kaldırıldı." Sağda iki sütun kartlar.

Gelişmiş › Deneysel kartında "GTA 6 Telefonunu Otomatik Çevir" satırının altında **GTA 6 Telefon Mesajları** seçicisi
(`DSTabs`: Yanda Panel / Balonların Üstünde, varsayılan Yanda Panel; ayar Mac `phoneMessagesPanel`, Windows
`PhoneMessagesPanel`) ve altında gri açıklaması. Otomatik telefon okumasına ve "Ekranı Çevir"e birlikte uygulanır.

| EN | TR |
|---|---|
| Basics | Temel |
| Translation, Sound | Çeviri, Ses |
| Subtitle Appearance | Altyazı Görünümü |
| Size, Colors | Boyut, Renkler |
| Advanced | Gelişmiş |
| Engine, Experimental | Motor, Deneysel |
| Subtitle Area | Altyazı Alanı |
| Game Packs | Oyun Paketleri |
| Turkish Dubbing | Türkçe Seslendirme |
| Output Screens | Çıkış Ekranları |
| Keyboard Shortcuts | Klavye Kısayolları |
| Console and Source | Konsol ve Kaynak |
| All settings in one place. The Profile page is gone. | Ayarlar tek yerde. Profil sayfası kaldırıldı. |
| SETTINGS | AYARLAR |
| Basics and Advanced | Temel ve Gelişmiş |
| TRANSLATION | ÇEVİRİ |
| Fast | Hızlı |
| Balanced | Dengeli |
| Accurate | Doğru |
| Subtitles arrive as fast as possible; you may rarely see half a sentence. | Altyazı en hızlı biçimde gelir; nadiren yarım cümle görebilirsiniz. |
| Recommended for most games. Speed and accuracy balanced. | Çoğu oyun için önerilen ayar. Hız ve doğruluk dengeli. |
| Translated once the sentence is complete; arrives about half a second later. | Cümle tamamlanınca çevrilir; yarım saniye kadar geç gelir. |
| Translation Language | Çeviri Dili |
| The game language is detected by itself. | Oyun dili kendiliğinden bulunur. |
| Turkish | Türkçe |
| Startup Sound | Açılış Sesi |
| Plays only on the first launch. | Yalnız ilk açılışta çalar. |
| Transition Animations | Geçiş Animasyonları |
| When off, only a short fade is used. | Kapalıyken yalnız kısa solma kullanılır. |
| SUBTITLE APPEARANCE | ALTYAZI GÖRÜNÜMÜ |
| Text size, background, text and character name colors. The settings apply the same on the TV, phone and computer screen. | Yazı boyutu, zemin, yazı ve karakter adı renkleri. Ayarlar TV, telefon ve bilgisayar ekranında aynı uygulanır. |
| Edit Subtitle Appearance | Altyazı Görünümünü Düzenle |
| SUBTITLES ON THE TV | TV'DEKİ ALTYAZI |
| The text color is too close to the background; it may be hard to read on the TV. | Yazı rengi zemine çok yakın, TV'de okunması zor olabilir. |
| The settings apply the same on the TV, phone and computer screen. | Ayarlar TV, telefon ve bilgisayar ekranında aynı uygulanır. |
| Text Size | Yazı Boyutu |
| %lld px | %lld px |
| Background Color | Zemin Rengi |
| Selected: %@. | Seçili: %@. |
| Darkness | Koyuluk |
| Light | Açık |
| Medium | Orta |
| Dark | Koyu |
| Text Color | Yazı Rengi |
| Character Name | Karakter Adı |
| Same as Text | Yazıyla Aynı |
| Single Color | Tek Renk |
| By Character | Karaktere Göre |
| The character name is shown in the same color as the text. | Karakter adı yazıyla aynı renkte gösterilir. |
| New characters get colors in turn. | Yeni karakterlere sırayla renk verilir. |
| Black | Siyah |
| Navy | Lacivert |
| Dark Gray | Koyu Gri |
| Brown | Kahverengi |
| White | Beyaz |
| Cream | Krem |
| No Background | Zeminsiz |
| Yellow | Sarı |
| Light Blue | Açık Mavi |
| Amber | Amber |
| Turquoise | Turkuaz |
| Pink | Pembe |
| Purple | Mor |
| Green | Yeşil |
| Orange | Turuncu |
| Red | Kırmızı |
| Blue | Mavi |
| TRANSLATION ENGINE | ÇEVİRİ MOTORU |
| Free Translation | Ücretsiz Çeviri |
| No key needed. | Anahtar gerekmez. |
| On This Mac (Apple) | Bu Mac'te (Apple) |
| Apple's translation runs on this Mac; subtitle text never leaves it. | Apple'ın çevirisi bu Mac'te çalışır; altyazı metni dışarı çıkmaz. |
| Better translation with a free Google key. | Ücretsiz Google anahtarıyla daha iyi çeviri. |
| With your own DeepL key. | Kendi DeepL anahtarınızla. |
| Local Model | Yerel Model |
| Ollama or LM Studio; no quota. | Ollama ya da LM Studio; kota yok. |
| Other AI | Diğer Yapay Zekâ |
| OpenAI or Claude with your own key. | Kendi anahtarınızla OpenAI ya da Claude. |
| API Key | API Anahtarı |
| Stored only on this device. | Yalnız bu cihazda saklanır. |
| EXPERIMENTAL | DENEYSEL |
| These settings may slow down or interrupt translation. If there's a problem, go back to the defaults. | Bu ayarlar çeviriyi yavaşlatabilir ya da kesebilir. Sorun olursa varsayılana dönün. |
| Translate On-Screen Text Automatically | Ekran Yazılarını Otomatik Çevir |
| Objectives, menus and other text on the screen. | Görev, menü ve ekrandaki diğer yazılar. |
| Translate the GTA 6 Phone Automatically | GTA 6 Telefonunu Otomatik Çevir |
| Each message is translated over its own bubble. | Her mesaj kendi balonunun üstünde çevrilir. |
| GTA 6 Phone Messages | GTA 6 Telefon Mesajları |
| Side Panel | Yanda Panel |
| On the Bubbles | Balonların Üstünde |
| Side Panel: the chat is shown next to the phone, the other person on the left and you on the right. On the Bubbles: each message is translated on top of its own bubble. | Yanda Panel: sohbet telefonun yanında gösterilir; karşı taraf solda, siz sağdasınız. Balonların Üstünde: her mesaj kendi balonunun üstünde çevrilir. |
| Restore Defaults | Varsayılana Dön |
| Appearance | Görünüm |
| Follow System | Sisteme Uy |
| MORE | DİĞER |

## 20 · Ayarlar: Altyazı Alanı

Ek alan sınırı yok (eskiden 3). İlk 3 ek alanın kısayolu var (Num 1–3 / ⌃⇧1–3); sonrakiler kısayolsuz ("Kısayol Yok").

| EN | TR |
|---|---|
| SUBTITLE AREA | ALTYAZI ALANI |
| Refresh Picture | Görüntüyü Yenile |
| Bottom | Alt |
| Top | Üst |
| Full Screen | Tam Ekran |
| Custom | Özel |
| Drag the frame to move it, or grab an edge or corner to resize it. The subtitle frame should cover where the game shows its subtitles. | Çerçeveyi sürükleyerek taşıyın, kenarından ya da köşesinden tutup boyutlandırın. Altyazı çerçevesi oyunun altyazıyı gösterdiği yeri kapsamalı. |
| While Full Screen is selected the whole screen is read, so extra areas aren't read; choosing another area reads them again. | Tam Ekran seçiliyken ekranın tamamı okunduğu için ek alanlar okunmaz; başka bir alan seçince yeniden okunur. |
| Reset Areas | Alanları Sıfırla |
| EXTRA AREAS | EK ALANLAR |
| Add Extra Area | Ek Alan Ekle |
| Also reads small text next to the subtitle, such as objectives, phone messages or notifications. Each area is read once a second and translated again when the text changes; the translation appears on the TV next to that text. | Altyazının yanında görev, telefon mesajı ya da bildirim gibi küçük yazıları da okur. Her alan saniyede bir okunur, yazı değişince yeniden çevrilir; çeviri TV'de o yazının yanında görünür. |
| No extra areas yet. | Henüz ek alan yok. |
| Area %lld | Alan %lld |
| No Shortcut | Kısayol Yok |
| Objective | Görev |
| Phone | Telefon |
| Notification | Bildirim |
| Subtitle | Altyazı |
| AREAS FOR THIS GAME | BU OYUNUN ALANLARI |
| These areas are saved for %@. | Bu alanlar %@ için kayıtlı. |
| These are your general areas. | Bunlar genel alanlarınız. |
| The areas are saved for this game. | Alanlar bu oyuna kayıtlı. |
| There are unsaved changes. | Kaydedilmemiş değişiklik var. |
| Saved | Kaydedildi |
| Save | Kaydet |
| Saved Games | Kayıtlı Oyunlar |
| When one of these games starts, its areas load by themselves. | Bu oyunlardan biri açılınca alanları kendiliğinden yüklenir. |
| Use Ready Areas for Known Games | Bilinen Oyunlarda Hazır Alanları Kullan |
| Keep Centered | Ortada Tut |

## 21 · Ayarlar: Oyun Paketleri

| EN | TR |
|---|---|
| Use Game Packs | Oyun Paketlerini Kullan |
| Ready Turkish translations for some games. A line found in the pack appears instantly without going to the translation engine. | Bazı oyunlar için hazır Türkçe çeviriler. Pakette bulunan satır çeviri motoruna gitmeden anında görünür. |
| Send the English Subtitles Read to the Shared Pool | Okunan İngilizce Altyazıları Ortak Havuza Gönder |
| Only the game's English text is sent, anonymously. It helps make better Turkish translations for everyone. | Yalnız oyunun İngilizce metni, adsız gönderilir. Herkes için daha iyi Türkçe çeviri yapmaya yarar. |
| INSTALLED PACKS | KURULU PAKETLER |
| INSTALLED PACKS · %lld | KURULU PAKETLER · %lld |
| Update Packs Now | Paketleri Şimdi Güncelle |
| Updating Packs… | Paketler Güncelleniyor… |
| Packs Up to Date | Paketler Güncel |
| Import Pack… | Paket İçe Aktar… |
| Installed · Up to Date | Kurulu · Güncel |
| Update Available | Güncelleme Var |
| Import Game Pack | Oyun Paketi İçe Aktar |
| Usable Lines | Kullanılabilir Satır |
| Duplicate Pairs | Yinelenen Çift |
| Conflicting Lines | Çakışan Satır |
| Invalid Records | Geçersiz Kayıt |
| Install Pack | Paketi Kur |
| Cancel | Vazgeç |
| Usage Data | Kullanım Verisi |
| Ask Which Game I'm Playing | Hangi Oyunu Oynadığımı Sor |
| Show Speaker Name | Konuşanın Adını Göster |

## 22 · Ayarlar: Türkçe Seslendirme

| EN | TR |
|---|---|
| Dub the Translation in Turkish | Çeviriyi Türkçe Seslendir |
| Natural | Doğal |
| This Mac | Bu Mac |
| Natural voices, downloaded once. Each line takes a moment to prepare, so the voice may come a little after the subtitle. | Doğal sesler, bir kez indirilir. Her satır biraz hazırlandığı için ses altyazıdan biraz sonra gelebilir. |
| This Mac's own Turkish voice: speaks right away, no download needed. Sounds more mechanical. | Bu Mac'in kendi Türkçe sesi: hemen konuşur, indirme gerekmez. Daha mekanik duyulur. |
| Downloading Voices… | Sesler İndiriliyor… |
| Voices Downloaded | Sesler İndirildi |
| Download Again | Yeniden İndir |
| Download Voices | Sesleri İndir |
| The voices are downloaded once (%@). | Sesler bir kez indirilir (%@). |
| PLAY THE SOUND ON | SESİ ŞURADA ÇAL |
| CHARACTER VOICES | KARAKTER SESLERİ |
| Narrator and Unnamed Lines | Anlatıcı ve Adsız Satırlar |
| Second Speaker in a Dialogue | Diyalogda İkinci Konuşan |
| Voice %lld | Ses %lld |
| Playing… | Çalıyor… |
| Listen | Dinle |
| Voices: Pocket TTS Turkish (wite-tech, CC BY 4.0), with Kyutai pocket-tts. The voices are synthetic and don't belong to real people. | Sesler: Pocket TTS Turkish (wite-tech, CC BY 4.0), Kyutai pocket-tts ile. Sesler yapaydır, gerçek kişilere ait değildir. |

## 23 · Ayarlar: Çıkış Ekranları

| EN | TR |
|---|---|
| SHOW SUBTITLES ON | ALTYAZIYI GÖSTER |
| Computer Screen | Bilgisayar Ekranı |
| Both | İkisi de |
| OBS Only (Streaming) | Yalnız OBS (Yayın) |
| TV app %@ · Connected. | TV uygulaması %@ · Bağlı. |
| TV app · Waiting for connection. | TV uygulaması · Bağlantı bekleniyor. |
| Linked | Eşli |
| Send Test Subtitle | Deneme Altyazısı Gönder |
| Sent | Gönderildi |
| Pair the TV | TV'yi Eşleştir |
| In fixed position you can also move subtitles with the ▲ and ▼ buttons on the TV remote. | Sabit yerdeyken altyazıyı TV kumandasının ▲ ve ▼ tuşlarıyla da taşıyabilirsiniz. |
| COMPUTER SCREEN | BİLGİSAYAR EKRANI |
| Subtitles appear on this computer in a window over the game or PS Remote Play. | Altyazılar bu bilgisayarda, oyunun ya da PS Remote Play'in üstündeki bir pencerede görünür. |
| Place the Subtitles | Altyazıları Yerleştir |
| Clicks Pass Through | Tıklamalar Geçsin |
| When on, clicks go to the window below. To turn it off press %@. | Açıkken tıklamalar alttaki pencereye gider. Kapatmak için %@. |
| SHOW ON ANOTHER DEVICE | BAŞKA BİR CİHAZDA GÖSTER |
| Open it in a browser on a phone, tablet or second computer on the same Wi-Fi. | Aynı Wi-Fi'deki telefon, tablet ya da ikinci bir bilgisayarda tarayıcıdan açın. |
| OBS OVERLAY | OBS KATMANI |
| Add a Browser Source in OBS and enter this address. If OBS runs on another computer, use the network address. | OBS'te Tarayıcı Kaynağı ekleyip bu adresi girin. OBS başka bir bilgisayarda çalışıyorsa ağ adresini kullanın. |
| Subtitle Placement | Yer |
| Over the English Subtitle | İngilizce Altyazının Üstüne |
| Above | Üstünde |
| Below | Altında |
| Fixed | Sabit |
| Background Area | Zemin Alanı |
| Fit the Text | Yazı Kadar |
| Full-Width Band | Tam Genişlik Bant |
| Bold Text | Kalın Yazı |
| Keep Previous Lines Above | Önceki Satırlar Üstte Kalsın |
| Position on Screen | Ekrandaki Yeri |
| Picture Mode | Görüntü Modu |
| Stream Window | Yayın Penceresi |

## 24 · Ayarlar: Klavye Kısayolları

Her işin iki tuşu: sayı tuş takımı rakamı ve ⌃⇧rakam. Tuşa tıklayınca "Tuşlara Basın…" ile yeni kısayol kaydedilir.

| EN | TR |
|---|---|
| KEYBOARD SHORTCUTS | KLAVYE KISAYOLLARI |
| Free Area | Serbest Alan |
| Translate Area %lld | %lld. Alanı Çevir |
| Pause or Resume Subtitles | Altyazıyı Duraklat ya da Sürdür |
| Turn Clicks Pass Through On or Off | Tıklamalar Geçsin Aç ya da Kapat |
| Refresh the Picture in Settings | Ayarlar'da Görüntüyü Yenile |
| Press Keys… | Tuşlara Basın… |
| Each action has two keys: the number pad digit and ⌃⇧digit. Shortcuts work only while translating, also when CouchSubs is in the background. | Her işin iki tuşu var: sayı tuş takımındaki rakam ve ⌃⇧rakam. Kısayollar yalnız çeviri sürerken çalışır; CouchSubs arka plandayken de. |

## 25 · Ayarlar: Konsol ve Kaynak

| EN | TR |
|---|---|
| CONSOLE | KONSOL |
| Second account: %@ | İkinci hesap: %@ |
| Connected | Bağlı |
| Renew the Access Key | Erişim Anahtarını Yenile |
| Set Up Again… | Yeniden Kur… |
| Link Xbox Account | Xbox Hesabını Bağla |
| PS5 LOGIN PASSCODE | PS5 GİRİŞ ŞİFRESİ |
| If your PS5 has a login passcode, enter the 4-digit passcode. | PS5'inizde giriş şifresi varsa 4 haneli şifreyi girin. |
| Passcode Saved | Şifre Kaydedildi |
| READ THE PICTURE FROM | GÖRÜNTÜYÜ ŞURADAN OKU |
| PS5 (Second Account) | PS5 (İkinci Hesap) |
| Remote Play Window on This Mac | Bu Mac'teki Remote Play Penceresi |
| OBS Projector or Game Window | OBS Projektörü veya Oyun Penceresi |
| LANGUAGE | DİL |
| Game Language | Oyun Dili |
| English | İngilizce |
| App Language | Uygulama Dili |
| Same as System | Sistemle Aynı |
| Online engines only translate English games. Other game languages use the free translation. | Çevrimiçi motorlar yalnız İngilizce oyunları çevirir. Başka oyun dillerinde ücretsiz çeviri kullanılır. |
| TV INPUT (HDMI) | TV GİRİŞİ (HDMI) |
| Demo Mode | Deneme Modu |

## TV kurulumu: başka uygulama (#976)

TV'de CouchSubs'ın kimliğini kullanan başka uygulama bulununca açılır kart (TV adımı ve Çıkış Ekranları › TV kartı):
mono "TV", başlık, açıklama; sağda amber ana eylem "Kaldırıp Kur", ikincil "Vazgeç" (kırmızı tehlikeli eylem değil).
Mevcut anahtarlar: "Another App Is Installed", "Another app on this TV is using the CouchSubs identity. Remove it and
install CouchSubs?", "Remove And Install", "Cancel".

## Ek metinler (kodda geçen)

| EN | TR |
|---|---|
| PROBLEM | SORUN |
| The TV app isn't connected. | TV uygulaması bağlı değil. |
| The language pack isn't downloaded. | Dil paketi indirilmemiş. |
| Translation isn't available on this Mac. | Bu Mac'te çeviri yok. |
| Search History | Geçmişte Ara |
| With your own key. | Kendi anahtarınızla. |
| Characters you meet while playing appear here. | Oynarken karşılaştığınız karakterler burada görünür. |
| Check Unchanged Subtitle Areas More Often | Değişmeyen Altyazı Alanını Daha Sık Oku |
| Set On-Screen Text Apart from Subtitles | Ekran Yazılarını Altyazıdan Ayır |
| Choose Dark under Subtitle Appearance to fully hide the English subtitle in the game. A full-width band also covers the sides. | Oyundaki İngilizce altyazıyı tamamen gizlemek için Altyazı Görünümü'nde Koyu'yu seçin. Tam genişlik bant yanları da örter. |
| Xbox · Beta | Xbox · Beta |
| Beta | Beta |

## Ayar alanları ve TV protokolü (geriye uyumlu)

Yeni ayarlar `UserSettings`'e (core `Pipeline/AppSettings.swift`, Windows `CouchSubs.Shell/Contracts.cs`) **aynı adla**
eklendi; eski kayıtta yoksa varsayılan kullanılır.

| Alan | Tür / varsayılan | Anlamı |
|---|---|---|
| `startupSound` | Bool, `true` | Ayarlar › Temel › Açılış Sesi (yalnız ilk kurulumun açılış adımında çalar). |
| `transitionAnimations` | Bool, `true` | Ayarlar › Temel › Geçiş Animasyonları; kapalıyken yalnız 100 ms solma. |

- **Hızlı / Dengeli / Doğru** yeni alan değildir: mevcut iki beklemenin hazır değerleridir (`misreadWaitMs`/`partialWaitMs`):
  Hızlı 400/0, Dengeli 800/300 (varsayılan), Doğru 1000/800. Değerler başka bir şeyse hiçbir sekme seçili görünmez
  (Gelişmiş'teki kaydırıcılar).
- **Yazı Boyutu 16–50 kaydırıcısı** TV'nin yazı boyuna (`fontSize`, 1920'de 16–90 piksel) doğrusal eşlenir:
  `fontSize = round(16 + (d − 16) · 74 / 34)`, gösterilen `d = round(16 + (fontSize − 16) · 34 / 74)`. Eski büyük boylar kaybolmaz.
- **Koyuluk** Açık/Orta/Koyu = `background` 45/75/100 (Koyu tam örter); "Zeminsiz" = `background` 0.
- **Karakter Adı**: "Yazıyla Aynı" `speakerColors` kapalı; "Tek Renk" ve "Karaktere Göre" açık.
- Ek alan sınırı 3'ten 50'ye çıktı (`ExtraArea.maxCount`); ilk üçünün kısayolu var, sonrakiler "Kısayol Yok".
- Yeni arayüz ilk açılışta bir kez: kayıtlı görünüm Koyu ise Açık yapılır (onaylı tasarım açık), `style.nameOnly` true olur.

TV'ye giden `style` olayına (`SubtitleStyle`) eklenen alanlar; eski TV uygulaması tanımaz, eskisi gibi davranır:

| Alan | Değer | Anlamı |
|---|---|---|
| `backgroundColor` | `"#RRGGBB"`, varsayılan `"#101014"` | Altyazı zemininin rengi; koyuluğu `background` (0–100). |
| `textHex` | `"#RRGGBB"` ya da yok | Yazı rengi; varsa `textColor`'ın yerine geçer (`textColor` eski TV için white/yellow olarak da gönderilir). |
| `nameOnly` | Bool | true: konuşan rengi yalnız adı boyar (yeni arayüz); false/yok: eski davranış (ad ve satır). |
| `hdmiInput` | 1–4 ya da yok | Kurulumun TV Girişi adımında seçilen giriş; TV uygulaması (0.9.77+) değer değişince o girişi açar, aynı değer yeniden gelince TV'de elle seçilen girişi ezmez. |

Kayıtta (`SubtitleStyle`) tutulan, TV'ye ayrıca gitmeyen alanlar: `nameColorMode` (`text`/`single`/`speaker`), `nameHex`
(Tek Renk), `characterColors` (küçük harfli ad → renk). Sunucu bunları `SpeakerColorBook.configure` ile uygular;
renkler satırın mevcut `speakers` alanıyla TV'ye gider.

Eşleşme kodu (TV'de görünen kod) mevcut `SubtitlePairing` biletinde zaten var; yeni arayüz onu iki ekranda gösterir.

## Kurulum sırası ve kaynaklar

- Adım sırası (Mac `AppModel.Step`): Açılış → Konsol (`welcome`) → PlayStation Hesabı (`secondAccount`, `psnLogin`) →
  PS5'e Bağlan (`console`; bulunamazsa denetim ekranı) → TV (`tv`) → TV Girişi (`hdmi`; yalnız TV eşleştiyse ve Android TV
  değilse) → Daha İyi Çeviri (`betterTranslation`) → Deneyelim (`test`) → Ana Ekran. Eskiden deneme çeviriden önceydi.
- Üstte dört ilerleme noktası: 1 Konsol, 2 Hesap + PS5, 3 TV + Giriş, 4 Çeviri + Deneme.
- PlayStation hesabı QR kodu yerelde üretilir; adres Sony'nin resmi hesap açma bağlantısı
  `https://www.playstation.com/acct/create-account` (playstation.com "How to create an account" sayfasındaki bağlantı).
- "Oyun Penceresi" seçilirse görüntü seçilen pencereden okunur ve kurulum biter (pencere Ayarlar › Konsol ve Kaynak'ta).
- Açılış animasyonu yalnız ilk kurulumda (`introPlayed`); ses tuvaldeki Web Audio tarifinin aynısı uygulamada üretilir
  (dosya yok). TV eşleşme kodu sihirbazda kartta gösterilir ("TV'de Bu Kodu Görüyorum"), ana pencerede onay penceresi.
- TV uygulaması 0.9.77 (main'deki 0.9.76 = TV alındısı ve yeniden bağlanma, #1017; yeni-arayuz ikisini birlikte taşır, Windows da bu numarayı kullanır): `backgroundColor`, `textHex`, `nameOnly`, `hdmiInput` alanlarını uygular (OBS katmanı ve ikinci
  ekran sayfası da renkleri).
