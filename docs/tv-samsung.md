# Samsung TV (Tizen) uygulaması

Durum: gerçek Samsung TV'de (75" Neo QLED) kuruldu ve çalıştı. Kurulum
adımları: [tv-kurulum.md](tv-kurulum.md#samsung-tv).

## Desteklenen sürümler

| Tizen | Yıl | Durum |
|---|---|---|
| 5.0 ve üstü | 2019+ | Desteklenir, gerçek TV'de denendi |
| 3.0–4.0 | 2017–2018 | Deneysel (bkz. aşağı) |
| 2.4 | 2016 | Deneysel: dört uygulama da (Mac, Windows, Android telefon, iPhone) kurulumu dener (en eski sürüm 2.4); paket imzalanmadan önce sadeleştirilir (`LegacyTizenPackage`) |
| 2.3 | 2015 | Deneysel, yalnız elle kurulum: CouchSubs'ın kendi kurulumu `TooOld` ile durur; Tizen Studio ile kurulan paket TV uygulaması 0.9.57'den beri çalışmalı ([aşağıda](#2015-modeller-tizen-23)) |
| Orsay | 2014 ve öncesi | Desteklenmez |

Tizen 3.0 için yapılanlar ve neyin doğrulandığı:

- `config.xml`'de `required_version="2.4"` (önce 5.0, sonra 3.0 idi; #71; TV, paketin istediğinden eski sürümde kurulumu reddeder).
  Yeni TV'ler daha düşük isteyen paketi de kurar (Jellyfin'in Tizen paketi de düşük sürüm ister). İzinlerin hepsi
  `public` düzeyinde: `tv.window`, `tv.inputdevice`, `application.launch`, `internet`, `network.get`,
  `network.public` (Samsung, `webapis.network.getIp`). Samsung TV'nin izin listesinde olmayan izin eklenmez: Tizen 2.4
  böyle paketi sebep yazmadan `install failed[118]` ile reddeder (#497'de `power`; Power API TV'de yok).
  `scripts/tv-tizen.test.js` izinleri bu listeye göre denetler;
  `<access origin="*">` ve `tizen:allow-navigation` zaten vardı.
- Sayfa ES5 ile yazılıdır (Tizen 3.0'ın tarayıcısı Chromium 47'dir; Tizen 4.0: 56). `acorn` ile `ecmaVersion: 5`
  ayrıştırmasından geçer; CSS'te değişken, grid, `gap`, `inset` yoktur. M47'de olmayan söz döndüren `play()` ve
  `decodeAudioData` için geri çağrılı yol zaten vardır.
- `tizen.*` ve `webapis.*` çağrılarının hepsi `try/catch` içindedir; API yoksa sessizce geçilir (`tizen` nesnesi
  olmadan sayfa hatasız açılıyor, başsız Chrome'da denendi). `webapis.js` yüklenemezse yalnız ekran koruyucuyu
  kapatma çalışmaz.
- Kurulum: dört uygulamada da alt sınır Tizen 2.4'tür (Mac ve Windows `SamsungTvInstaller.MinimumTizen`, Android
  `SamsungInstaller.MINIMUM_TIZEN`, iPhone `SamsungInstaller.minimumTizen`); 2.3 ve eskisi `TooOld` ile durur (#638'de
  masaüstü 2016 TV'yi reddediyordu). Tizen 2.x'te dördü de imzalamadan önce paketin `config.xml`'ini #71'de çalışan hâle
  döndürür: `network.public` izni ve `base_screen_resolution` ayarı çıkarılır (`LegacyTizenPackage`, #621; Android
  `.kt`, iPhone `.swift`, Mac ve Windows `.cs`). TV'nin 8001 yanıtı 21:9 / 32:9 Samsung monitör diyorsa (model
  `LS34`/`LS49`/`LS57…` ya da çözünürlük oranı en az 1,9) dördü de paketi geniş uygulama yüzeyiyle kurar:
  `config.xml`'e `base_screen_resolution=fullscreen`, `index.html`'e `width=device-width` görünümü eklenir
  (`WideScreenPackage`, #886; Odyssey G9'da 0.9.55'ten beri uygulama 16:9 kutuda kalıyordu). TV'lerde paket değişmez:
  aynı ayar 4K/8K TV'de görüntüyü sol üst köşede bırakıyordu (#799). Tizen 2.4–4.0'da, Apps2Samsung'un
  `TizenPermitInstall`'ı gibi, sertifika alınırken saklanan `device-profile.xml`'i kurulumdan önce TV'ye gönderir:
  Tizen 3.0–4.0'da `sdk_toolpath` klasörüne, Tizen 2.x'te `/home/developer`'a (#890). Sertifika aynı uç noktalardan, aynı `public` düzeyle alınır.
- **Gerçek TV'de doğrulanan:** bir kullanıcı (UE43MU7000U, Tizen 3.0) paketi Tizen Studio sertifikası ve Apps2Samsung
  ile elle kurdu; çeviri ve HDMI görüntüsü (`tvwindow` `BEHIND`) çalıştı. İlk açılıştaki "bağlantı hatası" TV yeniden
  başlatılınca geçti.
- **Doğrulanmayan:** CouchSubs'ın kendi kurulumunun (Samsung sertifikası + cihaz profili + `vd_appinstall`) Tizen
  2.4–4.0'da çalışması, `0 vd_applist` çıktısının bu TV'lerde aynı biçimde gelmesi, `webapis.appcommon` ekran koruyucu
  ayarı ve Web Audio dublajı.

### Tizen 2.4'te `install failed[118]` (#497, #621, #638, #890)

Tizen 2.4 kurulumu reddederken sebep yazmaz. `118` Samsung'un kurulum aracının genel "kurulum başarısız" kodudur;
Tizen 3.0 ve üstü yanına asıl sebebi yazar (`[118, -12]` sertifika, `[118, -19]` ayrıştırma, `[118, -20]` izin,
`[118, -22]` güvenlik, `[118, -4]` sürüm), 2.4 yazmaz. `power` izni (#497), `network.public` + `base_screen_resolution`
(#621), SHA-256 imza ve yalın paket (#638) denendi; gerçek KU7000'ler yine `[118]` verdi (#638, #890).

- **Bulunan fark (#890):** #71'de 40KU7000'de çalışan paket Apps2Samsung ile kuruldu. Apps2Samsung (Kasım 2026 öncesi
  sürümlerde de) paketi TV'nin Samsung sertifikasıyla TizenSdb'de SHA-512 imzalar ve Tizen 3.0'dan eski TV'de
  `device-profile.xml`'i `/home/developer`'a gönderir (`TizenPermitInstall.TargetPath`; Samsung'un "Permitting Device
  to Install Apps" belgesi de profilin oraya gittiğini yazar). CouchSubs'ın dört uygulaması profili her TV'de
  `sdk_toolpath`'e (2.4'te `/opt/usr/apps/tmp`) gönderiyordu; 2.4 profili orada aramaz, DUID'li Samsung dağıtıcı
  sertifikasını bu yüzden tanımaz. #497, #621, #638 ve #890'daki bütün günlüklerde bu ortaktı, imza biçimi (SHA-512 ya
  da SHA-256) ve config değişse de sonuç değişmedi. Artık Tizen 2.x'te profil `/home/developer`'a gider (olmazsa
  `sdk_toolpath` denenir). Tizen Studio'nun "Tizen" sertifikası cihaz profili istemediği için o yolda kurulum
  çalışıyordu (aşağıdaki free-my-tv raporları da bununla uyumlu). Henüz gerçek 2.4 TV'de doğrulanmadı.
- **İmza biçimi:** Tizen 2.x'te ilk deneme yine #71'deki gibi `rsa-sha512` + `sha512` (Mac ve Windows'ta TizenSdb,
  telefonlarda `WgtSigner`'ın SHA-512'si; ikisi aynı kanonik imzayı üretir). Yalın paket `rsa-sha256` + `sha256`
  (W3C Widget Signature'ın zorunlu tuttuğu, Tizen 2.x SDK'sının ürettiği biçim) ile imzalanır. Kanonikleştirme
  (exclusive C14N; `#prop` için C14N 1.1), referans sırası, `#prop` nesnesi ve zincir (yaprak + ara sertifika, kök yok)
  aynıdır. Tizen 2.x'e giden config.xml'in #71 paketininkiyle öğe öğe aynı olduğu birim testinde denetlenir
  (`testdata/tizen/config-71.xml`).
- **Deneme zinciri (yalnız Tizen 2.x):** 1) tam paket, SHA-512; 2) yalın `[118]` gelirse eski kopya kaldırılıp aynı
  paket; 3) yine yalın `[118]` ise "yalın paket" (`tizen:profile` satırı ile `application.launch` ve `network.get`
  izinleri de çıkar), SHA-256. Her adım ve hangisinin tuttuğu günlüğe yazılır ("tam paket SHA-512 imzayla kuruldu" /
  "yalın paket SHA-256 …").
- **Bilinen ama yapılmayan:** başka projelerdeki gerçek TV raporlarına göre (free-my-tv #349: KU6300, KU6640, KU6400;
  hepsi Tizen 2.4) bu TV'lerde Samsung'un DUID'li dağıtıcı sertifikasıyla imzalı paket tek sayfalık deneme
  uygulamasında bile `[118]` alıyor; Tizen Studio'nun kendi "Tizen" sertifikasıyla (yazar: Tizen Developers CA,
  dağıtıcı: SDK'daki eski `tizen-distributor-signer.p12`) imzalı paket kuruluyor, KU6300'de SHA-512 imzayla bile.
  Aynı kaynaklarda bir Full HD modelde (UA40K5300) ayrıca SHA-256 gerektiği yazıyor. CouchSubs bu sertifikayı
  kullanmıyor: SDK'nın CA anahtarını ve imzalayıcı dosyasını uygulamaya gömmek ayrı bir karar. Cihaz profili düzeltmesi
  (#890) de yetmezse sıradaki aday budur; o zamana kadar elle kurulumda Tizen Studio'da **Tizen** türünde sertifika profili denenebilir
  (aşağıda). #638'de beta.68 (SHA-256 + yalın paket) de UE60KU7000'de `[118]` aldı.
- **Elle kurulmuş kopya korunur:** Tizen 2.x'te TV'de CouchSubs görünüyorsa ya da `vd_applist` okunamıyorsa (2.4'te sık)
  kurtarma adımı TV'deki kopyayı kaldırmaz (`keepExisting`); yalnız tam paket ve sebepsiz `[118]`'de yalın paket denenir.
  TV'de bir sürüm görünüyor ve yeni paket kurulamıyorsa hata yerine o sürüm açılır. Böylece Tizen Studio ile elle
  kurulmuş, çalışan uygulamayı bilgisayardaki ya da telefondaki CouchSubs güncellerken silmez.

## 2016 modellerde elle kurulum (Tizen Studio)

CouchSubs'ın kendi kurulumu 2016 TV'de `install failed[118]` ile bitiyorsa (#497, #621, #638) paketi kendi
bilgisayarınızda Tizen Studio'nun **Tizen** sertifikasıyla imzalayıp kurabilirsiniz. CouchSubs bu sertifikayı (Tizen
SDK'nın anahtarları) içermez; imzayı sizin bilgisayarınızdaki Tizen Studio atar. Başka projelerden gelen raporlara göre
aynı Tizen 2.4 serisinde (KU6300, KU6400, KU6640) Samsung sertifikası `[118]` alırken Tizen sertifikasıyla imzalı paket
kuruluyor; KU6640 ve KU6400'de ancak TV'de kalmış eski kopya kaldırıldıktan sonra
([free-my-tv #349](https://github.com/simbasjungles/free-my-tv/issues/349)). UE60KU7000'de henüz denenmedi. Bazı 2016
Full HD modeller (ör. K5670) geliştirici kurulumunu hiç kabul etmiyor.

Menü adları Tizen Studio sürümüne göre biraz farklı olabilir.

### 1. Tizen Studio

1. [Samsung'un TV SDK sayfasındaki](https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk/installing-tv-sdk.html)
   adımlarla Tizen Studio'yu kurun (bugünkü kurulum dosyaları:
   [download.tizen.org/sdk/Installer/tizen-studio_6.1](https://download.tizen.org/sdk/Installer/tizen-studio_6.1/)).
2. Package Manager'ın **Extension SDK** sekmesinden **TV Extensions** ve **Samsung Certificate Extension**'ı kurun
   (aynı sayfada yazdığı gibi). Tizen sertifikası için Samsung Certificate Extension şart değildir, ama kuruluysa
   sertifika sihirbazı önce tür sorar. Tizen 2.4'e özel bir TV profili gerekmez: paket hazır klasörden imzalanır, proje
   açılmaz.
3. Komut satırı araçları varsayılan kurulumda `tizen-studio/tools/ide/bin/tizen` (Windows'ta `tizen.bat`) ve
   `tizen-studio/tools/sdb` klasöründedir; aşağıdaki komutları bu klasörlerden ya da PATH'e ekleyerek çalıştırın.

### 2. TV'de geliştirici modu

CouchSubs kurulumundaki gibi: **Apps** paneli › **12345** › **Developer mode** açık › **Host PC IP**'ye bu bilgisayarın
yerel IP adresi › TV'yi yeniden başlatın (fişten çekip 30 sn beklemek en garantisi). Host PC IP başka bir bilgisayarı
gösterirse TV sdb bağlantısını keser.

### 3. Paket

1. [Sürümler](https://github.com/yorulmazsinan/couchsubs/releases) sayfasından `CouchSubs-samsung-kaynak.zip`'i indirip
   boş bir klasöre açın (imzasız uygulama klasörü; `config.xml` doğrudan bu klasörde olmalı). İmzalı `.wgt`
   yayınlanmaz: Samsung paketi TV'ye göre imzalanır.
2. `config.xml`'den Tizen 2.4'ün tanımadığı satırı silin (CouchSubs'ın 2016 TV'ler için yaptığıyla aynı,
   `LegacyTizenPackage`; 0.9.54 ve eskisinin paketinde `base_screen_resolution` satırı da vardı, o da silinir):
   ```xml
   <tizen:privilege name="http://developer.samsung.com/privilege/network.public"/>
   ```
   `network.public` Samsung'a özgü bir izindir; Tizen sertifikasıyla imzalanan pakette olmaması daha güvenli. #71'de
   40KU7000'de elle kurulup çalışan paket bu satırı içermiyordu.

### 4. Tizen sertifika profili

Tizen Studio'da **Tools › Certificate Manager** › **+**:

1. Tür sorulursa **Tizen**'i seçin (Samsung'u değil), profile bir ad verin (ör. `CouchSubsTizen`).
2. **Create a new author certificate**: dosya adı, yazar adı ve parola girin.
3. Dağıtıcı adımında varsayılan **Tizen distributor certificate**'ı bırakın, yetki düzeyi **Public**. Sürüm seçeneği
   varsa **old**'u seçin: Tizen belgelerine göre Tizen 7.0 ve eskisi için "old", 8.0 ve sonrası için "new".
4. **Finish**. Profilde DUID istenmez; TV'nin DUID'ini kimseye göndermeniz gerekmez.

Komut satırında da olur (dağıtıcı verilmezse SDK'daki varsayılan Tizen dağıtıcısı kullanılır; "old/new" seçimi
için Certificate Manager daha kolay):

```bash
tizen certificate -a couchsubs -p PAROLA -n "Adınız" -f couchsubs
tizen security-profiles add -n CouchSubsTizen -a <tizen-studio-data>/keystore/author/couchsubs.p12 -p PAROLA
```

`-a`'ya tam yol verin; göreli yolda "Not found" hatası verdiği bildiriliyor.

### 5. İmzala, eski kopyayı kaldır, kur

```bash
tizen security-profiles list                      # profil listede olmalı
tizen package -t wgt -s CouchSubsTizen -- KLASOR  # KLASOR/CouchSubs.wgt üretilir
sdb connect TV_IP
sdb devices                                       # TV_IP:26101 "device" görünmeli
tizen uninstall -p CouchSubsT -s TV_IP:26101      # TV'de kalmış kopyayı kaldırır
tizen install -n CouchSubs.wgt -s TV_IP:26101 -- KLASOR
```

- `security-profiles list` profili göstermezse Certificate Manager'ın yazdığı `profiles.xml`'i
  `tizen cli-config "default.profiles.path=<profiles.xml yolu>"` ile gösterin.
- Paketi yeniden üretirken klasördeki eski `CouchSubs.wgt`'yi silin.
- Kaldırma TV'de bir şey görünmese de önemlidir: CouchSubs'ın denediği Samsung imzalı kurulumlar yarım kopya bırakmış
  olabilir ve TV başka sertifikalı paketi `[118]` ile reddeder. `tizen uninstall` çalışmazsa aynısı
  `sdb -s TV_IP:26101 shell 0 vd_appuninstall CouchSubsT` ile yapılır; "uninstall completed" ya da (kopya yoksa)
  `uninstall failed[132]` döner. İkisi de sorun değil.
- Kurulum yine yalın `install failed[118]` derse yalın paketi deneyin: `config.xml`'den
  `<tizen:profile name="tv-samsung"/>` satırını ve `application.launch`, `network.get` izinlerini de silip 5. adımı
  tekrarlayın.

### 6. Kurduktan sonra

- Uygulama TV'nin uygulama listesinde görünür; açınca bilgisayardaki CouchSubs'ı ağda bulur.
- Bilgisayardaki ya da telefondaki CouchSubs, TV'deki uygulamayı güncellemeye kalkarsa (geliştirici modu açıkken)
  Samsung sertifikasıyla yine `[118]` alabilir ve kart "kurulamadı" diyebilir; ama Tizen 2.x'te TV'deki kopyayı
  silmez (yukarıda "Elle kurulmuş kopya korunur"). TV uygulamasının yeni sürümü gerektiğinde bu adımları yeni
  `CouchSubs-samsung-kaynak.zip` ile tekrarlayın.
- Sonucu (kuruldu mu, hangi adımda ne dedi) #638'e yazarsanız 2016 modeller için yolu netleştiririz. `tizen install`
  çıktısı yeterli; DUID ve IP satırlarını silebilirsiniz.

## 2015 modeller (Tizen 2.3)

CouchSubs'ın kendi kurulumu Tizen 2.3'ü `TooOld` ile reddeder; paket yukarıdaki 2016 adımlarıyla elle kurulabilir
(#761'de Tizen Studio ve Apps2Samsung ile kuruldu). 3. adımda `config.xml`'deki
`required_version="2.4"` değerini `2.3` yapın; yoksa TV paketi reddeder.

**0.9.56 ve eskisinde uygulama 2-3 saniye görünüp kayboluyordu (#761).** Neden: TVWindow `show()`'un `zPosition`
değişkeni (`BEHIND`, HDMI görüntüsü sayfanın arkasında) Tizen 2.4'te geldi. Samsung'un TVWindow belgesi: değer
verilmezse ya da `FRONT` ise "Tizen 2.4'ten önceki gibi" davranır, pencere sayfanın **önünde** çizilir. Tizen 2.3'te
`'100%'` pencere HDMI girişi açılır açılmaz (2-3 sn) sayfanın tamamını örtüyordu: bekleme ekranı, panel ve çeviri
görünmüyor, çeviri yalnız telefonda/bilgisayarda kalıyordu. Sayfanın betikleri zaten ES5'tir
(`scripts/tv-es5.test.js`); `tizen.*`/`webapis.*` çağrıları `try/catch` içindedir, sorun sözdizimi değildi.

0.9.57'den beri `tv-tizen/platform.js` Tizen sürümünü (`platform.version`) okur; 2.4'ten eskiyse:

- HDMI penceresi `zPosition` verilmeden ekranın üst %75'inde, ortada 16:9 açılır (`12.5%, 0%, 75%, 75%`).
- Çeviri alttaki %25'lik şeritte gösterilir (`platform.subtitleBand`); oyundaki altyazının yerine göre yerleşim ve
  ekran çevirisi kutuları pencerenin altında kalacağı için kullanılmaz. Kumandanın yukarı/aşağı okları altyazıyı
  yalnız şerit içinde taşır.
- Bekleme ekranı, panel, eşleştirme kodu, ipuçları ya da demo görünürken pencere gizlenir (`tvwindow.hide`), kapanınca
  yeniden açılır. Bağlanınca panel 8 sn açık kaldığı için görüntü o kadar gecikir.
- Sarı tuşun görüntü yöntemleri yoktur. Bilgi panelindeki "Pencere" satırı `tizen 2.3 front ... ok` yazar.

Gerçek bir 2015 TV'de doğrulanmadı (yalnız Node'da sahte TVWindow ile, `scripts/tv-tizen.test.js`).

## Yapı

Arayüz kodu LG ile ortaktır (`tv-webos/`). Samsung'a özgü olanlar `tv-tizen/` içindedir:

- `platform.js`: HDMI görüntüsü (`tizen.tvwindow`, `BEHIND`), kumanda tuşları, başlatma parametreleri
- `config.xml`: uygulama kimliği ve izinler

`./scripts/package-tizen.sh` bunları `dist/tv-tizen/app` altında toplar.

## Denenecekler

- HDMI görüntüsü altyazının arkasında görünüyor mu, ses geliyor mu?
- Tek bağlı HDMI otomatik seçiliyor mu?
- Sayı ve renk tuşu olmayan kumandada Tamam paneli açıyor, sol ve sağ HDMI girişini değiştiriyor mu?
- Bilgisayardan `ed.apps.launch` ile uygulama açılabiliyor mu? Yeni modellerde çalışmadığını bildirenler var.
- Anynet+ açıkken TV kendiliğinden HDMI'ya geçince uygulama `visibilitychange` (gizlendi) alıyor mu? İpucu buna dayanır
  (`app.js`, "TV kendiliğinden HDMI'ya geçiyor"): açılıştan ya da öne gelişten sonraki 10 sn içinde, ya da 5 dk içinde
  üçüncü kez arka plana düşen uygulama `localStorage`'a not düşer; yeniden görünürken ya da bir sonraki açılışta ipucu
  gösterilir. Yalnız Samsung'da (`platform.sourceSwitchTip`). TV'den bilgisayara giden bir kanal olmadığı için
  bilgisayara bildirilmez; bilgisayar uygulaması aynı ipucunu Samsung TV kutusunda zaten gösterir.

## LG'den farkı

Samsung'da paket, TV'nin DUID'ini içeren distributor sertifikasıyla imzalanır. Bu yüzden tek bir paketi herkesin
TV'sine kurmak mümkün değildir. Mac ve Windows uygulamaları bunu kullanıcının yerine yapar
(`windows/src/CouchSubs.TvInstall/Samsung/`; Mac'te aynı kod gömülü `couchsubs-tv-helper` ile çalışır):

1. sdb (26101) ile TV'ye bağlanır, `0 vd_applist` ile TV'deki CouchSubs sürümüne bakar (güncelse burada durur),
   `0 getduid` ile DUID'i okur.
2. Bu TV için geçerli sertifika yoksa Samsung'un SignInGate sayfasını tarayıcıda açar; jeton `localhost:4794`'e POST
   edilir.
3. Yazar ve dağıtıcı CSR'lerini `svdca.samsungqbe.com`'a gönderir (dağıtıcı CSR'sinde `URN:tizen:deviceid=<DUID>`),
   gelen sertifikaları Samsung ara sertifikasıyla PKCS#12'ye yazar (Mac: `~/Library/Application Support/CouchSubs/samsung`,
   Windows: `%LOCALAPPDATA%\CouchSubs\samsung`).
4. Tizen 2.4–4.0'da cihaz profilini (`device-profile.xml`) `sdk_toolpath`'e gönderir.
5. Uygulamayla gelen imzasız `couchsubs-samsung_<sürüm>.wgt`'yi (Tizen 2.x'te sadeleştirilmiş kopyasını) imzalar, `vd_appinstall` ile kurar ve `was_execute` ile açar.
   TV başka sertifikalı eski kopya ya da paket kimliği yüzünden reddederse (`[118, -12]`, `[118, -11]`, `[118, -22]`)
   eski kopyayı kaldırıp bir kez daha dener; TV sertifikayı reddederse kayıtlı sertifika bırakılır, bir sonraki
   denemede yenisi alınır. Hata kodlarının anlamı `SamsungInstallDiagnostics.cs`'te.

Her adım ve TV'nin, Samsung'un bütün yanıtları `tvinstall.log`'a yazılır (Mac: `~/Library/Logs/CouchSubs/`,
Windows: `%LOCALAPPDATA%\CouchSubs\`); hata iletisi bu dosyayı da söyler. LG ve Android TV kurulumu da aynı dosyaya
yazar. Kurulum hatasında kart, üç markada da **Kurulum günlüğünü göster** (Finder / Explorer) ve **Günlüğü kopyala**
düğmelerini gösterir (telefonlardaki **Kurulum günlüğünü paylaş**ın karşılığı).

Uç noktalar belgesizdir ve Apps2Samsung'dan alınmıştır; Samsung değiştirirse burası güncellenir. Herkes için kalıcı
yol yine mağaza yayınıdır (`docs/magaza.md`).
