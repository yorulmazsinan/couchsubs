# CouchSubs — Vestel Linux TV istemcisi (deneysel)

Vestel'in kendi Linux'unu çalıştıran (Android TV olmayan) TV'ler için yerel altyazı istemcisi. TV'de çalışır,
CouchSubs bilgisayarına kendisi bağlanır, diğer TV uygulamaları gibi eşleşir ve altyazıyı HDMI görüntüsünün üstüne
DirectFB ile çizer. Geliştirildiği cihaz: Vestel 55UD8400 (MB130, Linux 3.10.40, glibc 2.18, DirectFB 1.4.2, MStar G2).

> **Durum: deneysel ama doğrulandı (Vestel 55UD8400, MB130, 21.11.2026).** Tek tuşla kurulum, eşleşme, canlı altyazı ve
> ek alanlar (çoklu pencere) gerçek TV'de uçtan uca çalıştı; Aurora bozulmadı. Yalnız bu model/anakart denendi; başka
> Vestel modelleri (özellikle FHD, farklı koordinat alanı) ayrıca doğrulanmalı.

## Protokol (değiştirilmedi)

`GET /hello` (`auth:1`) → kayıtlı anahtar varsa `GET /pair?validate=1&k=` → yoksa `POST /pair`, 6 haneli kod TV'de
gösterilir, kullanıcı CouchSubs'ta onaylar, `GET /pair?id=` ile anahtar alınır → `GET /events?k=` SSE akışı.
`subtitle`, `clear`, `style`, `region`, `region-clear`, `screen`, `screen-clear`, `exit`, `ping` işlenir; `speech` yok sayılır. `401` →
yeniden eşleşir, `403` → bekler, `409` → 5 sn sonra tekrar dener. Origin başlığı gönderilmez. Anahtar yalnız bellekte
tutulur, günlüğe yazılmaz; istemci her başladığında yeniden eşleşir.

### Ek alan blokları (`region` → `blocks`)

Bir ek alanda ayrı duran birden çok çeviri varsa (telefon sohbeti, çoklu etiket), `region` olayı `blocks:[{box, text,
surface?, style?}]` taşır. Her blok kendi İngilizce yazısının yerinde ayrı pencerede, varsa özgün renk/bold ile gösterilir
(birleşik pencere o alan için gizlenir). Ayrı havuz `"<id>#<n>"` anahtarlı; o alan güncellenince/kalkınca yalnız o alanın
blokları temizlenir. Blok yoksa birleşik `text` tek kutuda (eski davranış). En çok `SCREEN_ITEMS_MAX` (8) blok.

### Ek alanlar (`region`)

Görev yazısı, telefon mesajı, bildirim gibi ekran köşelerindeki çeviriler `region` olayıyla gelir
(`{id, text, box, line}`). Her alan, İngilizce yazının **kendi yerinde**, **box genişliğinde** bir DirectFB penceresinde
(yarı saydam kutu + Türkçe metin) gösterilir; font `line` (satır yüksekliği) ile özgün boyuta göre ayarlanır. Pencere box'ın
sol-üstüne, box genişliğinde kurulup ekran kenarına sığdırılır — böylece **sol-alt / sağ-üst / sağ-alt** gibi her köşedeki
alan kaymadan kendi yerinde kalır (sabit genişlik yok; boyut değişince pencere güvenle yeniden kurulur, webOS `placeItems`
ile aynı). Boş `text` o alanı, `region-clear` hepsini kaldırır. En çok 3 alan (CouchSubs `ExtraArea.maxCount`). `icons` yok
sayılır (sunucu birleşik `text`'i de gönderir); `blocks` kendi bölümünde.

### Ekranı çevir (`screen`)

Kullanıcı "Ekranı çevir"e basınca sunucu `screen` olayını `{duration, items:[{box, line, text, surface?}]}` ile yollar;
her öğe İngilizce yazının yerinde, varsa `surface` özgün renkleriyle (arka/ön plan) gösterilir, `duration` sonra ya da
`screen-clear` ile kalkar. **Ayrı pencere havuzu** (canlı ek alanlara dokunmaz), en çok `SCREEN_ITEMS_MAX` (8) öğe.
`surface` yoksa varsayılan yarı saydam siyah kutu + beyaz yazı. Her öğe box'ın yerinde/genişliğinde, `line` fontuyla çizilir
(ek alanlarla aynı). Per-öğe `bold`/`condensed` uygulanır; yok sayılan: `icons`, per-öğe `align`.

### Stil (`style`), bold ve konuşan adı rengi

`fontSize`, `bottomPercent`, `background` (0-100 kutu koyuluğu), `textColor` (white/yellow) uygulanır. **`bold`:** TV'de
`/vendor/fonts/OpenSans-Bold.ttf` (aynı aile) varsa gerçek bold font yüklenir; yoksa çift çizimle faux-bold'a düşer.
**Konuşan adını renklendir** (`speakerNames`): subtitle `[{name,color}]` taşır; satır başındaki `Ad:` (ya da tam-genişlik
`：`) o konuşanın renginde, cümlenin kalanı varsayılan renkte çizilir (webOS `speakerSegments` ile aynı; en uzun ad kazanır).
**`placement`** (cover/above/below/fixed, varsayılan cover): subtitle İngilizce altyazının yerini (`box`) taşır; band
`cover`'da onun üstüne, `above`/`below`'da hemen üstüne/altına konur, `fixed`'de (ya da kutu yoksa) `bottomPercent`'e düşer.
Yatayda band hep ortalı (altyazılar ortalı gelir; yatay kaydırma sonraki tur). **`stackPrevious`** (varsayılan açık): yeni
altyazı öncekini 1.5 sn içinde takip ediyorsa (replace değil, aynı değil) önceki satır üstte kalır — **yalnız tek önceki satır**
(ekranı kaplamaz), çok satırlı paneller (`paragraphs`) yığılmaz. **`backgroundShape`**: `fit` (kutu yazı kadar) / `band` (tam
genişlik bant, yazı ortalı). **Per-öğe `condensed`** (screen/blocks): metin DirectFB `SetMatrix` ile genişliği `CONDENSE_SCALE`
(%85) oranına iner — harfler oranlı küçülür, iç içe geçmez; sürücü desteklemezse normal genişlikte çizilir (ayrı condensed font
gerekmez). Yok sayılan: `displayMode` (katman/uygulama-içi seçimi — bu istemci zaten hep HDMI katmanına çizer, karşılığı yok),
per-öğe `align` (kutular metne göre boyutlandığından görünmez), `icons`. `upper` sunucuda Türkçe büyük harfe çevrilir.

## Güvenlik

TV'de port açmaz (yalnız bilgisayara bağlanır). DirectFB'de `session=0` + `force-slave` ile mevcut grafik oturumuna
katılır, `DLSCL_SHARED` ve kendi küçük penceresini kullanır; EXCLUSIVE, ekran modu, katman ayarı ve doğrudan GOP yazımı
yok. TV'ye kalıcı hiçbir şey yazmaz.

## Derleme

```sh
docker build -t couchsubs-vestel-xc tv-vestel
docker run --rm -v "$PWD/tv-vestel":/src couchsubs-vestel-xc /src/build.sh   # -> tv-vestel/out/couchsubs-vestel-tv
./scripts/package-vestel.sh                                                  # Mac paketine (dist/tv-app) koyar
```

Çıktı ARM EABI5 soft-float, yükleyici `/lib/ld-linux.so.3`, glibc ≤ 2.18 (betik denetler).

## Testler (Mac'te, DirectFB'siz)

```sh
./tv-vestel/test/run_tests.sh
```

SSE/JSON/satır bölme birim testleri, ek alan (`region`) ayrıştırma/gösterme/temizleme, sahte sunucuya (auth=1, anahtarsız
erişim kapalı) karşı eşleştirme, `401`, anahtar yenileme, kopma ve `exit` senaryoları.

## Kurulum

**Ön koşul (tek seferlik): test aracı soketini (TCP 1986) aç.** Firmware'de kapalıdır. ProfileComposer ile `TesttoolSocket=True`
devprofile (`mb130_devprofile.bin`) USB'ye konur → TV menüsünde **4725** → **USB Diagnostic** → TV kapatılıp ~1 dk sonra
açılır → 1986 açılır. Geri almak için `TesttoolSocket=False` profille aynı adımlar. (Vestel 55UD8400 MB130'da doğrulandı.)

**Tek tuş (uygulamadan):** CouchSubs Mac uygulamasında TV IP'si girilip "TV'ye kur ve başlat"a basılır. Uygulama TV'nin
test aracı soketinden (TCP 1986) bir kabuk açar, istemciyi `http://<mac>:8787/vestel-tv-client` adresinden indirtir,
çalıştırır ve kabuğu kapatır. Ayrıntı: `core/Sources/CouchSubsCore/Vestel/VestelInstall.swift`. **Bu TV'nin açık root
soketini kullanır; kullanıcının açık onayıyla eklendi.** TV'ye kalıcı hiçbir şey yazılmaz.

**Elle (yedek):** TV'de istemciyi `/tmp`'ye kopyala, `chmod +x`, sonra `./couchsubs-vestel-tv <BİLGİSAYAR_IP> 8787`. TV'de
çıkan kodu CouchSubs'ta onayla. Durdurmak için süreci `kill` ile sonlandır (altyazıyı kaldırıp çıkar).
