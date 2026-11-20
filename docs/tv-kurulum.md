# CouchSubs TV uygulamasını kurma

TV uygulamaları henüz mağazalarda yok. TV'nizde geliştirici modunu açmanız yeter: uygulamayı CouchSubs kendisi kurar.
Geliştirici modu ücretsizdir ve TV'ye zarar vermez. Adımları bilgisayar uygulaması da TV adımında gösterir ve TV'yi
kendisi bekler; bu sayfa aynı adımların ayrıntılı hâlidir. Önce TV'nizin hangi gruba girdiğine bakın:

| TV | Durum | Rehber |
|---|---|---|
| **LG** (webOS 4 ve üstü) | Gerçek TV'de denendi. CouchSubs TV uygulamasını kendisi kurar | [LG](#lg-tv) |
| **Samsung** (Tizen, 2019 ve sonrası) | Gerçek TV'de denendi (75" Neo QLED). CouchSubs kendisi kurar, bir kez Samsung girişi ister | [Samsung](#samsung-tv) |
| **Samsung** (Tizen 2.4–4.0, 2016–2018) | Deneysel: kullanıcılar UE43MU7000U'da (2017) ve 40KU7000'de (2016) elle kurup çalıştırdı; CouchSubs'ın kendi kurulumu bu TV'lerde henüz denenmedi | [Samsung](#20162018-samsung-tvler-deneysel) |
| **Android TV / Google TV** (Vestel, Arçelik, Beko, Grundig, Philips ve diğerleri) | Gerçek TV'de denendi. CouchSubs ağ üzerinden kendisi kurar | [Android TV](#android-tv--google-tv) |
| **Vestel, Arçelik, Beko, Grundig'in Linux modelleri, Philips Saphi ve Titan OS** | Desteklenmiyor: bu TV'lere uygulama kurmanın bir yolunu bulamadık | |

**TV'm Android mi?** Ana ekranda Google Play Store ya da Google TV yazıyorsa Android'dir. Üreticinin kendi uygulama
mağazası varsa ve Play Store yoksa büyük olasılıkla değildir.

Bilgisayar ve TV aynı ev ağında olmalıdır.

**Windows güvenlik duvarı:** Ayarlar › Windows Güvenlik Duvarı izni, yalnız CouchSubs uygulaması için
**Özel ağdaki yerel cihazlardan TCP ve UDP bağlantılarını** açar. TV sunucusu 8787 doluysa başka bir port
seçebildiğinden ve PS5 keşfi/yayını değişken portlar kullanabildiğinden izin tek porta bağlanmaz.
Uygulama ağ profilini kendiliğinden değiştirmez; yalnız güvendiğiniz ev ağını Windows Ayarları'nda **Özel** yapın.
Ortak ve Etki alanı profilleri için bu düğme izin açmaz. Ayrı alt ağ/VLAN veya VPN üzerinden bağlantı bu otomatik
kuralın kapsamı dışındadır; gerekirse ağ yöneticisi yalnız ilgili cihazlara özel izin düzenlemelidir.
Önceki CouchSubs sürümünün oluşturduğu geniş kural yeni izinler doğrulandıktan sonra taşınır. Yalnız CouchSubs'ı
hedefleyen engel kuralları (ör. Windows'un ilk açılış sorusu kapatılınca yazdığı kural) kaldırılır; genel, başka
programların ve kurumun engelleme kuralları otomatik silinmez. İzin doğrulanamıyorsa mevcut engelleme kurallarını
Windows Güvenlik Duvarı'nda kontrol edin; güvenlik duvarını bütünüyle kapatmayın.

**Bilgisayarsız: telefondan kurulum ve güncelleme.** Bilgisayarınız yoksa TV uygulamasını CouchSubs telefon
uygulamasından ([Google Play](https://play.google.com/store/apps/details?id=com.couchsubs.mobile) ya da iPhone) da
kurabilirsiniz; Android telefon da iPhone da Samsung, LG ve Android TV'ye kurar:
**Ayarlar › TV uygulaması › TV uygulamasını bu telefondan kur** (aynı giriş ilk kurulumdaki altyazı hedefi adımında da
var). Telefon ağdaki TV'yi bulup markayı kendisi seçer; her markanın adımları aşağıdaki "Telefondan kurulum"
bölümlerindedir. Bilgisayar uygulaması gibi telefon da uygulama açılınca ve TV her bağlandığında TV'deki CouchSubs'ın
sürümüne bakar; telefondaki sürüm daha yeniyse ana ekranda **TV uygulamasını güncelle** çıkar, tek dokunuşla
güncellenir. Telefondaki TV paketleri her telefon sürümünde en yenisidir (Samsung paketi kaynaktan, LG ve Android TV
paketleri son [sürümden](https://github.com/yorulmazsinan/couchsubs/releases) gelir).

## LG TV

### 1. LG geliştirici hesabı açın

1. Bilgisayardan [webostv.developer.lge.com](https://webostv.developer.lge.com) adresine gidin.
2. Sağ üstten **SIGN IN**, ardından **Create Account** seçin ve ücretsiz hesap açın.

### 2. TV'de geliştirici modunu açın

1. TV'nin internete bağlı olduğundan emin olun.
2. TV'de LG Content Store'u açın, **Developer Mode** diye aratıp uygulamayı kurun.
3. Developer Mode uygulamasını açın, hesabınızın e-postası ve şifresiyle giriş yapın.
4. **Dev Mode Status**'u açın. TV yeniden başlar.

### 3. CouchSubs'ın TV uygulamasını kurmasını sağlayın

1. Bilgisayarda CouchSubs'ı açın. Kurulumdaki TV adımında TV'nizi seçip **Bağlan**'a basın, TV'deki izni onaylayın.
2. TV'de Developer Mode uygulamasını yeniden açın ve **Key Server**'ı açın. Uygulamayı ekranda bırakın.
3. TV ekranının sol altında 6 karakterli **Passphrase** görünür. Büyük ve küçük harfe dikkat ederek CouchSubs'a yazın.
4. **TV'ye kur**'a basın.

Parola yalnız bir kez sorulur. Yeni sürümleri CouchSubs, çeviriyi başlattığınızda kendisi kurar.

### Süreyi uzatın

Geliştirici modu en çok 1000 saat açık kalır. **CouchSubs, her kullanışınızda süreyi kendisi baştan başlatır** ve kalan
süreyi TV adımında gösterir. TV'nin kendi ekranındaki **Remain Session** sayacı bunu TV yeniden başlayınca gösterir.

CouchSubs'ı uzun süre kullanmayacaksanız, süre dolmadan TV internete bağlıyken Developer Mode uygulamasındaki
**EXTEND**'e basın. Süre dolarsa geliştirici modu kapanır ve TV uygulaması silinir; süre dolduktan sonra uzatılamaz,
baştan kurmanız gerekir. TV internetsiz 10 kez yeniden başlarsa da aynısı olur.

Modu kapatıp yeniden açarsanız TV yeni anahtar üretir ve parola bir kez daha sorulur.

### Telefondan kurulum

1. Yukarıdaki 1. ve 2. adımlarla geliştirici modunu açın.
2. Telefonda **Ayarlar › TV uygulaması › TV uygulamasını bu telefondan kur**'a basın; LG seçili değilse üstten
   **LG**'yi seçin. Listeden TV'yi seçin (geliştirici modu açıksa "Geliştirici modu açık" yazar) ya da adresini yazın.
3. TV'de Developer Mode uygulamasında **Key Server**'ı açın, ekrandaki 6 karakterli **Passphrase**'i telefona yazıp
   **Kur ve aç**'a basın. Telefon anahtarı alır, uygulamayı kurar ve açar. Parola yalnız ilk kurulumda gerekir.

Telefon, bilgisayar uygulaması gibi geliştirici modunun süresini günde bir kez kendisi uzatır (kurulumda ve TV'deki
sürüme her baktığında). Yeni sürüm çıkınca ana ekrandaki **TV uygulamasını güncelle** ile parola sorulmadan güncellenir
(TV'de geliştirici modu yeniden açıldıysa parola bir kez daha istenir). Paket, [Sürümler](https://github.com/yorulmazsinan/couchsubs/releases) sayfasındaki
`.ipk` ile aynıdır. Kod: `couchsubs-android/.../tv/lg/`; iPhone'da `couchsubs-ios/CouchSubs/TVInstall/LGPhoneInstall.swift`
(SSH bağlantısı uygulamanın kendi küçük SSH istemcisiyle, `SshClient.swift`).

### Elle kurulum

Otomatik kurulum çalışmazsa [Node.js](https://nodejs.org) kurup Terminal'de (Windows'ta PowerShell'de):

```bash
npm install -g @webos-tools/cli
ares-setup-device --add tv --info "{'host':'TV_IP_ADRESI','port':'9922','username':'prisoner'}"
ares-novacom --device tv --getkey
ares-install -d tv com.couchsubs.tv_0.7.0_all.ipk
```

Paketi [Sürümler](https://github.com/yorulmazsinan/couchsubs/releases) sayfasından indirin.

## Samsung TV

Samsung, uygulamanın her TV için ayrı imzalanmasını ister. CouchSubs bunu sizin yerinize yapar: tek gereken, bir kez
ücretsiz bir Samsung hesabıyla giriş yapmanız. Sorun olursa
[Issues](https://github.com/yorulmazsinan/couchsubs/issues) sayfasından TV modelinizle birlikte yazın.

### 1. TV'de geliştirici modunu açın

1. TV'de **Uygulamalar** ekranını açın.
2. Kumandayla `1 2 3 4 5` tuşlarına basın (ya da ekran klavyesiyle `12345` yazın). Geliştirici modu penceresi açılır.
   Bazı yeni modellerde (ör. 2025 QN90F) bu, **Uygulamalar › Uygulama Ayarları** ekranında çalışır.
3. **Developer mode**'u **On** yapın.
4. **Host PC IP** alanına bilgisayarınızın adresini yazıp **OK**'e basın. Adresi CouchSubs TV adımında gösterir.
5. TV'yi yeniden başlatın: kumandanın güç tuşunu TV kapanıp Samsung logosuyla yeniden açılana kadar (yaklaşık 5
   saniye) bırakmadan basılı tutun. TV kapanınca bırakırsanız Samsung TV yalnız bekleme moduna geçer ve geliştirici
   modu ayarı uygulanmaz (TV "geliştirici modu açık" der ama 26101 bağlantıyı reddeder, #524, #484). Logo görünmezse TV'nin
   fişini 30 saniye çekin. Uygulamalar ekranında **Develop Mode** yazısı görünür.

### 2. CouchSubs kursun

1. CouchSubs'ın TV adımında Samsung TV'nizi seçip **Bağlan**'a basın ve TV'deki izni onaylayın.
2. CouchSubs geliştirici modunu görünce tarayıcıda Samsung'un giriş sayfasını açar. Samsung hesabınızla giriş yapın
   (hesabınız yoksa aynı sayfadan ücretsiz açabilirsiniz). Tarayıcı yerel ağa erişim izni sorarsa **İzin ver** deyin.
3. CouchSubs TV'nize özel sertifikayı alır, uygulamayı imzalar, kurar ve açar. Giriş yalnız ilk kurulumda istenir.

**TV bilgisayarı kabul etmedi** uyarısı çıkarsa geliştirici modu penceresindeki **Host PC IP**'nin bilgisayarınızın
şu anki adresi olduğunu kontrol edin ve TV'yi yukarıdaki gibi tam yeniden başlatın. Bilgisayarın adresi değişirse bu
adım yinelenir. Telefondan kurulumda uygulama hatadan sonra TV'ye geliştirici modunu yeniden sorar: ayar doğruysa TV'nin
tam yeniden başlamadığını, Host PC IP başka bir cihazınsa hangi adresin yazılacağını, TV ile telefon farklı ağlardaysa
(ör. 192.168.1.x ve 192.168.0.x: ikinci modem, mesh ya da misafir ağı) ikisini aynı Wi-Fi'ya bağlamayı söyler.

**Sorun çıkarsa** (75" Neo QLED'de denendi):

- **"TV uygulaması kurulamadı" derse:** TV'yi kumandanın güç tuşunu Samsung logosu çıkana kadar basılı tutarak yeniden
  başlatın. Sonra CouchSubs'ta sağ üstteki dişliye (Ayarlar) basın, **CouchSubs TV uygulaması** kutusunda **Yeniden
  dene**'ye basın. Yarım kalan kurulumların çoğu böyle düzeliyor. Yine olmazsa kutuda TV'nin verdiği sebep yazar;
  onu [Issues](https://github.com/yorulmazsinan/couchsubs/issues) sayfasına yazın.
- **TV sürekli HDMI 1'e ya da başka bir kaynağa geçiyorsa** (CouchSubs TV uygulaması açıkken ya da kurulurken):
  **Ayarlar › Tüm Ayarlar › Bağlantı › Harici Cihaz Yöneticisi** altında **Anynet+ (HDMI-CEC)** ve **Otomatik Kaynak
  Değiştirme**'yi kapatın.
- **Kurulum sürerken CouchSubs'ı kapattıysanız:** kurulum bitmiş sayılmaz; CouchSubs yeniden açılınca TV adımından
  devam eder ve TV uygulamasını kurmayı sürdürür.
- **TV'de sürekli "İzin ver" penceresi çıkıyorsa:** kumandayla bir kez **İzin ver**'i seçin. Pencere, TV uygulaması
  henüz kurulmamışken CouchSubs onu açmaya çalıştıkça çıkar; uygulama kurulunca kesilir. Ayarlarda
  **Bağlantı › Harici Cihaz Yöneticisi › Cihaz Bağlantı Yöneticisi** altında bilgisayarı **İzin Ver** yapabilirsiniz
  (menü adı modele göre "Aygıt" ya da "Cihaz" olabilir; ayarlarda **Cihaz** diye arayın).
- **Kurulduğunu nasıl anlarım:** TV'de CouchSubs açıkken **Tamam**'a basınca panelde **HDMI** (PS5'in girişi,
  "oynatılıyor"), **Uygulama** (bilgisayarın adresi) ve **Bağlantı: bağlı** görünür. Paneli kapatmak için yine **Tamam**.

### Telefondan kurulum

Samsung TV ve akıllı monitörler için (Android TV için aşağıdaki Android TV bölümüne bakın):

1. Telefonda **Ayarlar › TV uygulaması › TV uygulamasını bu telefondan kur**'a basın; Samsung seçili değilse üstten
   **Samsung**'u seçin.
2. TV'de geliştirici modunu yukarıdaki gibi açın; **Host PC IP** olarak ekranda yazan **telefonun** adresini girin ve
   TV'yi yeniden başlatın.
3. Listeden TV'yi seçip **Kur ve aç**'a basın. Samsung giriş sayfası uygulamanın içinde açılır (açılmazsa
   **Tarayıcıda aç**); giriş yapınca telefon sertifikayı alır, uygulamayı imzalar, kurar ve açar.

Bilgisayardaki kurulumla aynı adımlardır (`couchsubs-android/.../tv/samsung/`); sertifika telefonda saklanır, sonraki
güncellemelerde giriş istenmez. Güncelleme için TV'nin geliştirici modunda **Host PC IP** telefonun adresi kalmalıdır
(telefonun adresi değişirse bu adım yinelenir). Bir sorun
çıkarsa ekrandaki **Kurulum günlüğünü paylaş** ile günlüğü [Issues](https://github.com/yorulmazsinan/couchsubs/issues)
sayfasına ekleyin.

### 2016–2018 Samsung TV'ler (deneysel)

Tizen 2.4 (2016, ör. KU serisi), Tizen 3.0 (2017, ör. MU serisi) ve Tizen 4.0 (2018, ör. NU serisi) TV'lerde de kurulum aynı adımlarla denenir. Bu
TV'lerde CouchSubs, kurmadan önce TV'ye özel cihaz profilini de gönderir (Tizen Studio'daki "Permit to install
applications" adımı). Bir kullanıcı TV uygulamasını UE43MU7000U'da (Tizen 3.0) Tizen Studio ve Apps2Samsung ile elle
kurdu; bir başka kullanıcı da 2016 model 40KU7000'de (Tizen 2.4) elle kurdu ve sorunsuz çalıştırdı (#71); çeviri ve HDMI görüntüsü GTA V ve Mafia'da çalıştı. CouchSubs'ın otomatik kurulumu bu TV'lerde henüz
denenmedi; sonucu [Issues](https://github.com/yorulmazsinan/couchsubs/issues) sayfasına TV modelinizle yazarsanız
desteği netleştiririz.

- İlk açılışta **bağlantı hatası** görünürse TV'yi güç tuşunu basılı tutarak yeniden başlatın; o kullanıcıda böyle düzeldi.
- 2016 modellerinde (Tizen 2.4) kurulumu şimdilik yalnız telefon uygulamaları (Android telefon ve iPhone) dener; Mac ve
  Windows uygulaması bu TV'lerde "TV çok eski" der (2017 ve sonrası modellere kurar).
- 2015 ve önceki Samsung TV'ler (Tizen 2.3 ve eskisi, Orsay) desteklenmez; CouchSubs bunu kurulumda söyler.

### TV kendiliğinden HDMI'ya geçiyorsa

TV uygulaması açıldıktan hemen sonra (ya da kısa sürede birkaç kez) arka plana düşerse, yeniden göründüğünde ya da bir
sonraki açılışında sağ üstte "TV kendiliğinden HDMI'ya geçti" ipucunu gösterir: **Ayarlar › Tüm Ayarlar › Bağlantı ›
Harici Cihaz Yöneticisi**'nde **Anynet+ (HDMI-CEC)** ve **Otomatik Kaynak Değiştirme**'yi kapatın. İpucu **Tamam** ya
da **Geri** ile kapanır. Ana ekrana açılıştan hemen sonra kendiniz döndüyseniz de bir kez görünebilir; zararsızdır.

### Elle kurulum

Otomatik kurulum çalışmazsa [Tizen Studio](https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk/installing-tv-sdk.html)
ile kurabilirsiniz: Package Manager'dan **Samsung Certificate Extension**'ı kurun, **Device Manager**'dan TV'ye bağlanın,
**Certificate Manager**'da TV'nin DUID'iyle **Samsung** türünde sertifika profili oluşturun. Sonra
[Sürümler](https://github.com/yorulmazsinan/couchsubs/releases) sayfasındaki `CouchSubs-samsung-kaynak.zip`'i bir
klasöre açıp:

```bash
tizen package -t wgt -s SERTIFIKA_PROFILI -- KLASOR
tizen install -n KLASOR/CouchSubs.wgt -t TV_ADI
```

## Android TV / Google TV

Gerçek TV'de denendi. Bazı TV'ler HDMI görüntüsünü başka uygulamaya vermeyebilir; böyle bir durumda altyazılar
görünür ama arkası siyah kalır. Lütfen [Issues](https://github.com/yorulmazsinan/couchsubs/issues) sayfasından
TV modelinizle birlikte yazın.

### 1. TV'de hata ayıklamayı açın

1. **Ayarlar › Cihaz Tercihleri › Hakkında**'ya girin (Google TV'de **Ayarlar › Sistem › Hakkında**).
2. **Yapı numarası**'nın üstünde Tamam tuşuna 7 kez basın. "Geliştiricisiniz" uyarısı çıkar.
3. **Cihaz Tercihleri** (Google TV'de **Sistem**) **› Geliştirici seçenekleri**'nden **USB hata ayıklama**'yı açın.
   **Ağ hata ayıklama** seçeneği varsa onu da açın.

Menü adları markaya göre biraz değişebilir.

### 2. CouchSubs kursun

1. CouchSubs'ın TV adımında **Android TV / Google TV**'yi seçin. CouchSubs TV'yi ağda arar.
2. TV ekranında "USB hata ayıklamaya izin verilsin mi?" sorusu çıkar. **Bu bilgisayardan her zaman izin ver**'i
   işaretleyip **İzin ver**'e basın.
3. CouchSubs uygulamayı kurar ve açar. TV uygulaması bilgisayarı ağda kendisi bulur.
4. Görüntü gelmezse Tamam ile paneli açıp sol ve sağ tuşlarıyla doğru HDMI girişini seçin.

Kurulumdan sonra hata ayıklamayı kapatabilirsiniz; yeni sürümleri kurmak için CouchSubs onu yeniden açmanızı ister.

### Görüntü modu değişiyor, oyun modu ya da HDR kayboluyorsa

TV uygulaması PS5 görüntüsünü kendi içinde gösterir ("Uygulama içinde" modu). Bazı TV'ler (ör. Sony Bravia) bu
görüntüyü HDMI girişi olarak değil uygulama olarak işler: uygulama açıkken görüntü modu değişebilir, oyun modu ya da
HDR kapanabilir. Bu durumda bilgisayarda ya da telefonda Ayarlar'daki **Görüntü modu**'ndan **Katman**'ı seçin:
TV, PS5'i kendi HDMI girişinde (kendi görüntü ayarları, oyun modu ve HDR ile) gösterir, altyazı görüntünün üstünde
çıkar. Katman, bilgisayarın ya da telefonun kurduğu TV uygulamasında vardır; Google Play'den kurulan kopyada yoktur.

LG (webOS) ve Samsung (Tizen) TV uygulamaları HDMI'yi her zaman kendi içinde gösterir, bu TV'lerde Katman modu yoktur;
oyun modu ya da HDR'nin kapanması bu TV'lerin uygulamalara koyduğu bir sınırdır.

### USB bellekle kurulum

CouchSubs TV'yi ağda bulamazsa (bazı TV'ler ağdan hata ayıklamaya izin vermez):

1. **Ayarlar › Uygulamalar › Güvenlik ve kısıtlamalar › Bilinmeyen kaynaklar**'dan dosya yöneticisine izin verin.
2. [Sürümler](https://github.com/yorulmazsinan/couchsubs/releases) sayfasından `CouchSubs-androidtv.apk` dosyasını
   indirip bir USB belleğe kopyalayın ve TV'ye takın.
3. TV'de dosya yöneticisiyle dosyayı açıp kurun. TV'nizde dosya yöneticisi yoksa Play Store'dan ücretsiz birini kurun.
4. CouchSubs'ın TV adımında **Android TV / Google TV**'yi seçin ve TV'de CouchSubs'ı açın.

### Telefondan kurulum

1. Telefonda **Ayarlar › TV uygulaması › TV uygulamasını bu telefondan kur**'a basın; Android TV seçili değilse üstten
   **Android TV**'yi seçin.
2. TV'de hata ayıklamayı yukarıdaki gibi açın ve iki yoldan birini seçin:
   - **USB/ağ hata ayıklama:** Listeden TV'yi seçin (5555 portu açıksa "Ağ hata ayıklaması açık" yazar) ya da adresini
     yazın, **Kur ve aç**'a basın. TV'de "USB hata ayıklamaya izin verilsin mi?" çıkınca **Bu cihazdan her zaman izin
     ver**'i işaretleyip **İzin ver**'e basın.
   - **Kablosuz hata ayıklama** (Android 11 ve sonrası, ör. Google TV): **Geliştirici seçenekleri › Kablosuz hata
     ayıklama**'yı açıp içine girin. Üstteki **IP adresi ve bağlantı noktası**'nı TV'nin adresine yazın. İlk kurulumda
     **Cihazı eşleme kodu ile eşle**'ye basın; açılan penceredeki adresi ve 6 haneli kodu telefona yazıp pencere
     açıkken **Kur ve aç**'a basın. Sonraki kurulumlarda kod gerekmez, yalnız adres ve port (port her açılışta değişir).
3. Telefon uygulamayı kurar, "diğer uygulamaların üzerinde göster" iznini verir ve açar.

Güncellemeler için TV'de hata ayıklamayı açık bırakın: telefon TV'deki sürüme bakar ve yenisi varsa ana ekranda
**TV uygulamasını güncelle** önerir (TV bir daha onay sormaz).

Telefondaki paket, [Sürümler](https://github.com/yorulmazsinan/couchsubs/releases) sayfasındaki `CouchSubs-androidtv.apk`
ile aynıdır (telefon uygulaması derlenirken son sürümden alınır). CouchSubs TV Google Play'deyse ve TV'de Play Store
varsa telefon (ve bilgisayar) APK yüklemez, TV'de CouchSubs'ın Play sayfasını açar: kumandayla **Yükle**'ye basın,
kurulunca uygulama kendiliğinden açılır. Play'den kurulmuş kopyanın güncellemesi de Play'e bırakılır (TV'de Play
sayfası açılır). Birkaç dakika içinde Play'den kurulmazsa doğrudan APK ile kurulur. Bu kurulum TV'deki kopyanın üstüne
yapılamazsa telefon bunu söyler ve yalnız siz **TV'deki kopyayı kaldırıp kur**'a basarsanız eski kopyayı kaldırır. Kod: `couchsubs-android/.../tv/android/`. Sorun çıkarsa **Kurulum günlüğünü paylaş** ile günlüğü
[Issues](https://github.com/yorulmazsinan/couchsubs/issues) sayfasına ekleyin.
