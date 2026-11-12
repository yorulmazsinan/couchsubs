# CouchSubs Linux sunucusu

CouchSubs'ın ekransız (headless) Linux sürümü: evdeki bir Ubuntu sunucusunda Docker ile çalışır, kurulum ve denetim
aynı ağdaki bir tarayıcıdan (telefon ya da bilgisayar) açılan panelle yapılır. Windows uygulamasının arayüz dışındaki
bütün katmanlarını (`windows/src` altındaki Core, RemotePlay, Translation, Shell, TvInstall) olduğu gibi kullanır;
Linux'a özgü olan yalnız şunlardır:

| Parça | Windows | Linux |
|---|---|---|
| Arayüz | WPF | Tarayıcı paneli (`Panel/index.html`, port 8788) |
| Yazı tanıma | Windows.Media.Ocr | Tesseract (`TesseractReader.cs`) |
| Anahtar saklama | DPAPI | Yalnız sahibinin okuyabildiği dosya (`Stores.cs`) |
| PSN girişi | WebView2 penceresi | Sony sayfası tarayıcıda açılır, dönen adres panele yapıştırılır |
| Yerel kütüphane | `couchsubs_native.dll` (MSYS2) | `couchsubs_native.so` (aynı kaynak, dağıtımın FFmpeg'iyle) |

Dublaj, uygulama güncellemesi, klavye kısayolları ve Windows Güvenlik Duvarı kartı bu sürümde yoktur.

## Kurulum

Docker kurulu bir Ubuntu makinede, depo kökünde:

```bash
./linux/build.sh
docker compose -f linux/compose.yml up -d
```

Sonra aynı ağdaki bir cihazdan `http://<sunucu adresi>:8788` adresini açıp sihirbazı izleyin. Sunucu ev ağına
doğrudan bağlı çalışır (`network_mode: host`): PS5 araması UDP yayınıyla, TV araması SSDP ile yapılır.

- 8788: panel. Parola yoktur; yalnız ev ağınızda açık tutun.
- 8787: TV uygulamasının bağlandığı altyazı sunucusu.
- Veriler (hesap kimliği, PS5 ve TV anahtarları, ~530 MB çeviri modeli, `remoteplay.log`) `couchsubs-data` biriminde durur.

Ortam değişkenleri: `COUCHSUBS_LANG` (`tr`/`en`, sunucunun hata iletileri), `COUCHSUBS_PANEL_PORT`,
`COUCHSUBS_AUTOSTART=1` (sunucu yeniden başlayınca çeviri kendiliğinden sürer; dinlenme modundaki PS5'i de
uyandırdığı için varsayılan kapalıdır).

## Tanı

- Panelde **Günlük**: PS5 bağlantısının uyarı ve hataları; ayrıntılısı veri klasöründeki `remoteplay.log`.
- Panelde **Bu bölgeyi şimdi oku**: PS5'ten gelen son karede altyazı bölgesinde ne okunduğunu ve kaç ms sürdüğünü gösterir.
- PS5 olmadan okuma ve çeviri denemesi (ham BGRA kare; `ffmpeg -i kare.png -pix_fmt bgra -f rawvideo kare.bgra`):

```bash
docker run --rm -v "$PWD:/in" couchsubs-linux --read-raw /in/kare.bgra 1920 1080 --translate
```

## Docker'sız derleme

Ubuntu 24.04 için gereken paketler `Dockerfile` içindedir. Kısaca: `cmake -S windows/native -B build/native -G Ninja`
ile `couchsubs_native.so` derlenip `windows/native/bin/` altına konur, ardından
`dotnet publish linux/CouchSubs.Linux -c Release`.

---

**English.** Headless Linux build of CouchSubs. It reuses every non-UI layer of the Windows app and adds a browser
panel (port 8788), Tesseract text recognition and a file-based key store. Build with `./linux/build.sh`, run with
`docker compose -f linux/compose.yml up -d`, then open `http://<server>:8788` from a device on the same network.
The container must use host networking so it can find the PS5 and the TV.
