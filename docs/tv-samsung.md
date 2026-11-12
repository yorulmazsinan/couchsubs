# Samsung TV (Tizen) uygulaması

Durum: gerçek Samsung TV'de (75" Neo QLED) kuruldu ve çalıştı. Kurulum
adımları: [tv-kurulum.md](tv-kurulum.md#samsung-tv).

## Desteklenen sürümler

| Tizen | Yıl | Durum |
|---|---|---|
| 5.0 ve üstü | 2019+ | Desteklenir, gerçek TV'de denendi |
| 3.0–4.0 | 2017–2018 | Deneysel (bkz. aşağı) |
| 2.x ve Orsay | 2016 ve öncesi | Desteklenmez: kurulum `TooOld` ile durur |

Tizen 3.0 için yapılanlar ve neyin doğrulandığı:

- `config.xml`'de `required_version="3.0"` (önceden 5.0'dı; TV, paketin istediğinden eski sürümde kurulumu reddeder).
  Yeni TV'ler daha düşük isteyen paketi de kurar (Jellyfin'in Tizen paketi de düşük sürüm ister). İzinlerin hepsi
  `public` düzeyinde: `tv.window`, `tv.inputdevice`, `application.launch`, `internet`, `network.get`;
  `<access origin="*">` ve `tizen:allow-navigation` zaten vardı.
- Sayfa ES5 ile yazılıdır (Tizen 3.0'ın tarayıcısı Chromium 47'dir; Tizen 4.0: 56). `acorn` ile `ecmaVersion: 5`
  ayrıştırmasından geçer; CSS'te değişken, grid, `gap`, `inset` yoktur. M47'de olmayan söz döndüren `play()` ve
  `decodeAudioData` için geri çağrılı yol zaten vardır.
- `tizen.*` ve `webapis.*` çağrılarının hepsi `try/catch` içindedir; API yoksa sessizce geçilir (`tizen` nesnesi
  olmadan sayfa hatasız açılıyor, başsız Chrome'da denendi). `webapis.js` yüklenemezse yalnız ekran koruyucuyu
  kapatma çalışmaz.
- Kurulum: `SamsungTvInstaller` Tizen 3.0'dan eskisini reddeder. Tizen 3.0–4.0'da, Apps2Samsung'un
  `TizenPermitInstall`'ı gibi, sertifika alınırken saklanan `device-profile.xml`'i kurulumdan önce TV'nin
  `sdk_toolpath` klasörüne gönderir. Sertifika aynı uç noktalardan, aynı `public` düzeyle alınır.
- **Gerçek TV'de doğrulanan:** bir kullanıcı (UE43MU7000U, Tizen 3.0) paketi Tizen Studio sertifikası ve Apps2Samsung
  ile elle kurdu; çeviri ve HDMI görüntüsü (`tvwindow` `BEHIND`) çalıştı. İlk açılıştaki "bağlantı hatası" TV yeniden
  başlatılınca geçti.
- **Doğrulanmayan:** CouchSubs'ın kendi kurulumunun (Samsung sertifikası + cihaz profili + `vd_appinstall`) Tizen
  3.0–4.0'da çalışması, `0 vd_applist` çıktısının bu TV'lerde aynı biçimde gelmesi, `webapis.appcommon` ekran koruyucu
  ayarı ve Web Audio dublajı.

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
4. Tizen 3.0–4.0'da cihaz profilini (`device-profile.xml`) `sdk_toolpath`'e gönderir.
5. Uygulamayla gelen imzasız `couchsubs-samsung_<sürüm>.wgt`'yi imzalar, `vd_appinstall` ile kurar ve `was_execute` ile açar.
   TV başka sertifikalı eski kopya ya da paket kimliği yüzünden reddederse (`[118, -12]`, `[118, -11]`, `[118, -22]`)
   eski kopyayı kaldırıp bir kez daha dener; TV sertifikayı reddederse kayıtlı sertifika bırakılır, bir sonraki
   denemede yenisi alınır. Hata kodlarının anlamı `SamsungInstallDiagnostics.cs`'te.

Her adım ve TV'nin, Samsung'un bütün yanıtları `tvinstall.log`'a yazılır (Mac: `~/Library/Logs/CouchSubs/`,
Windows: `%LOCALAPPDATA%\CouchSubs\`); hata iletisi bu dosyayı da söyler.

Uç noktalar belgesizdir ve Apps2Samsung'dan alınmıştır; Samsung değiştirirse burası güncellenir. Herkes için kalıcı
yol yine mağaza yayınıdır (`docs/magaza.md`).
