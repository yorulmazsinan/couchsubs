# CouchSubs tasarım standardı

Mac ve Windows uygulamaları aynı görünür. Bu belge neyin nasıl göründüğünü, `design/tokens.json`
ise sayısal değerleri tanımlar. Değer değişecekse yalnız `tokens.json` düzenlenir; uygulamalar onu
doğrudan okur. Belge ile kod çelişirse `tokens.json` geçerlidir.

## İlke

Düz yüzey: ekran, aynı boşlukla dizilmiş karolardan oluşur; katmanlar parıltıyla değil yüzey basamakları
(zemin → karo → alan) ve ince çizgiyle ayrılır. Tek eylem rengi (altyazı sarısı), oyun paketleri için düz mor
işaret, sakin koyu zemin, büyük ve okunaklı yazı. Uygulama TV karşısında, biraz uzaktan
bakılarak kullanılır; her şey bir bakışta okunmalı. Telefon uygulamalarıyla ortak dil; tasarım tuvali:
https://claude.ai/artifact/UQhATNYKLby6t52HQCvSu9 (masaüstü aynı dili daha geniş ölçülerle kullanır).

1. **Tek ızgara, tek boşluk.** Pencere kenarı her yerde 24, karolar arası 12, karo içi 16 (telefonla aynı ritim;
   telefonda pencere kenarı 20).
2. **Beş yazı boyu** (28/22/17/15/13), kalınlık 400–600. Altyazı içeriği hariç başka boy kullanılmaz.
3. **Bir ekranda tek birincil düğme**, tek vurgu: sarı yalnız birincil düğme, seçili şey ve canlı Türkçe satırda.
4. **Parıltı, degrade, hale, bulanık leke ve renkli gölge yok.** (Yalnız grafiklerin içinde izinli; uygulamada grafik
   yok.) Atan tek şey canlı çeviri noktasıdır; azaltılmış harekette durur.
5. **Tek köşe ölçeği** (16/12/8/6), **cümle düzeni** (yalnız ilk harf büyük; "Check for updates…"), tablo rakamları.
6. **Metin her zaman okunur** (kontrast kuralı aşağıda).

7. **Her şeyin bir durumu var.** Tıklanabilen her şey fareyle üzerine gelince, basılınca ve klavye odağında
   değişir; tıklanamayan bilgi tıklanabilir gibi görünmez.

Masaüstünde ücret, paywall ve Pro yoktur; oyun paketleri ücretsizdir ("Ücretsiz · n oyun" etiketi).

2026-11-17: ölçüler sıkılaştırıldı (denetim yükseklikleri 40/44/52, düğme yazısı 15, boşluk 24/12/16; yazı boyları
aynı). Ana ekranda çeviri motoru ve kısayol durum karosu gibi değil, tek bilgi karosunda satır olarak durur.
Telefonda (iPhone ve Android) denetimler bilerek daha büyüktür: düğme ve satır 52, küçük ve simge düğmesi 44, düğme
yazısı 17; dokunma alanı Android'de en az 48 dp, iOS'ta en az 44 pt kalır.

2026-11-12: onaylı tuvale göre sadeleştirildi (AI Design Check 136 → 0 bulgu). Telefon ayrıntıları ve tuval:
`TASARIM-MOBIL.md` (tasarım tuvali klasörü).

## Logo

- Kaynak: `design/logo.svg` (vektör). Arkalığı ekran gibi duran, üstünde iki sarı altyazı satırı
  olan bir kanepe; koyu grafit zemin.
- Simgeler `swift scripts/make-icons.swift` ile üretilir (macOS simge seti, uygulama içi logo,
  TV uygulaması simgeleri, `design/logo-1024.png`). Windows için `.ico` aynı SVG'den üretilir.
- Logo değiştirilmez, yeniden renklendirilmez, gölge eklenmez. Uygulama içinde en az 32 pt.

## Renk

Her renk açık ve koyu görünüm için ayrı tanımlıdır; uygulama sistemin görünümünü izler.

| Ad | Kullanım |
|---|---|
| `background` | Pencere zemini (düz renk) |
| `surface` | Karolar |
| `surface2` | Alan, ikincil düğme, kenar çubuğunda seçili satır |
| `tileBorder` | Karo çerçevesi (koyuda %7 beyazın düz karşılığı) |
| `border` | Alan çerçevesi, ayraçlar, ilerleme çubuğu zemini |
| `textPrimary` | Ana metin |
| `textSecondary` | Açıklamalar, ikincil bilgiler |
| `accent` | Birincil düğme, ilerleme, seçili bölge (yalnız dolgu olarak; metin rengi değildir) |
| `onAccent` | Sarı düğme üstündeki yazı |
| `accentText` | Sarı tonda metin ve simgeler (açık görünümde koyulaştırılmış) |
| `accentHi` | Basılı birincil düğme |
| `accentSoft` | (Kullanılmıyor; eski simge rozeti zemini, kontrast testi için duruyor) |
| `pro` / `proSoft` | Yalnız oyun paketleri: düz mor simge ve yazı / paket etiketinin zemini. Sarı eylem demek, mor paket demek |
| `success` / `successSoft` | Bağlı, canlı (nokta + kelime); `successSoft` kullanılmıyor |
| `warning` | Dikkat |
| `danger` / `dangerSoft` / `dangerBorder` | "Çeviriyi durdur", "Yeniden kur": kırmızı yazı, kırmızı tonlu zemin, çerçevesiz |
| `onDanger` | Dolu kırmızı zemin üstündeki yazı |

### Parıltı yok

`tokens.json`'da parıltı bloğu yoktur. Karolar, düğmeler, anahtarlar ve pencere zemini düz renktir; seçili karo
1 pt `accent` çerçeveyle, seçili segment ve menü öğesi `surface2`/yükseltilmiş zeminle ve yarı kalın yazıyla belli
olur. Canlı nokta (8 pt yeşil, 2 sn'de bir genişleyip sönen halka) yalnız çeviri canlıyken ("Çevriliyor") atar;
"Bağlı" ve "Hazır" noktaları atmaz. Azaltılmış hareket açıkken halka durur. Tarama ışığı kaldırıldı.

Okunaklılık kuralı (Mac'te `ThemeTests` ile denetlenir; Windows'ta da aynı test yazılır):
ana metin zeminlere karşı en az 7:1, diğer tüm metinler en az 4,5:1 kontrastta olur.

## Yazı

Sistem yazı tipi: Mac'te SF Pro, Windows'ta Segoe UI Variable. Boyutlar nokta (pt) cinsinden;
Windows'ta aynı sayılar efektif piksel (epx) olarak kullanılır.

| Ad | Boyut | Kalınlık | Kullanım |
|---|---|---|---|
| `display` | 28 | yarı kalın, harf aralığı 0 | Ekran başlığı (sihirbaz adımı, ayarlar bölümü); ekran başına bir |
| `title` | 22 | yarı kalın | Uygulama adı, kenar çubuğu başlığı |
| `headline` | 17 | yarı kalın | Karo başlığı, karodaki değer |
| `body` | 15 | normal | Tüm metinler (varsayılan) |
| `callout` / `caption` | 13 | orta | Karo etiketi, açıklama ve ipuçları, rozet, yasal not; ikincil renkte |
| `button` | 15 | yarı kalın | Düğme yazısı (`body` ile aynı boy; ana ekrandaki büyük eylem `headline`) |
| `code` | 22 | yarı kalın, eş genişlikli rakam | PS5 eşleme kodu |

Altyazı içeriği arayüz değil içeriktir: canlı altyazı karosunda son satır 28 pt yarı kalın ve altyazı sarısında
(`accentText`), öncekiler 17 pt normal ve `textSecondary` renginde, altlarındaki özgün metin `caption` (opaklıkla
soldurulmaz; çeviri ile özgün metin boyla ayrılır). Paragraflarda satır arası yazı boyutunun yaklaşık 1,3 katıdır. 13 pt'nin altı
kullanılmaz.

## Boşluk ve biçim

- Boşluk: `screen` 24 (pencere kenarı), `gap` 12 (karolar ve bölümler arası), `tile` 16 (karo içi), `inline` 8
  (simge ile yazı), `hair` 4 (başlık ile altındaki satır). Eski ölçek (`xs` 4 … `xxl` 32) karo içindeki küçük
  aralıklar için durur.
- Köşe (tek ölçek): karolar `card` 16, denetimler (düğme, alan, bölmeli seçim rayı, kenar çubuğu ve adım satırı)
  `control` 12, karo içindeki küçük kutular (seçili segment, oyun monogramı, oyun görüntüsü) `inner` 8, etiket `tag` 6;
  tam yuvarlak (`pill`) yalnız anahtar, nokta, kaydırıcı, ilerleme çubuğu ve numara dairesinde.
- Pencere 1040 × 720 (iki sütun: sol `mainColumn` 380, sağ esnek); kenar çubuğu `sidebarWidth` 240.
  Mac'te Ayarlar pencerenin üstünde sayfa (sheet) olarak 976 × 656; Windows'ta ayrı pencere.

## Bileşenler

Her iki platformda aynı adla bulunur.

- **LogoView** – logo, kenar boşluğu kırpılmış hâliyle; koyu temada kenarı seçilsin diye 1 pt `border` çerçeve.
- **Düğme** – yükseklik 40 (`buttonHeight`), sihirbazın Geri / Devam ve Ayarların Bitti düğmesi 44 (`buttonLarge`),
  ana ekrandaki "Çeviriyi başlat/durdur" 52 (`primaryActionHeight`, yazısı `headline`), yatay iç boşluk `tile`.
  - *Birincil*: düz `accent` dolgu, `onAccent` yazı, gölge yok; basılıyken `accentHi`. Ekranda en fazla bir tane.
  - *İkincil*: `surface2` dolgu, `border` çerçeve, `textPrimary` yazı.
  - *Tehlikeli*: `dangerSoft` dolgu, `danger` yazı, çerçevesiz ("Çeviriyi durdur", "Yeniden kur").
  - *Hayalet*: dolgusuz, `accentText` yazı, yatay iç boşluk 12.
  - Üzerine gelince: birincil `accentHi`, ikincil `border` dolgu, tehlikeli `dangerBorder` çerçeve, hayalet `surface2`
    dolgu. Basılıyken %97 ölçek. Klavye odağında 2 pt `accentText` çerçeve.
  - Devre dışı: birincil `surface2` dolgu ve `textSecondary` yazı (soldurulmuş sarı kullanılmaz); diğerleri %40
    saydamlık.
- **Card (karo)** – düz `surface` zemin, 1 pt `tileBorder` çerçeve, `card` köşe, `tile` iç boşluk, isteğe bağlı
  `headline` başlık. Türleri: *düz* ve *etkin* (seçili seçenek: 1 pt `accent` çerçeve; parıltı yok). Paket karosu
  düz karodur; yalnız paket simgesi mor.
- **StatusTile** – durum karosu: üstte etiket satırı (18 pt kutusuz simge `textSecondary`, `caption` ad, sağda durum
  noktası), altında `headline` değer. Değer kısa bir durumdur ("Bağlı", "Kurulmadı"); bağlı değilken gelen açıklama
  cümlesi ("PS5-123 ile eşleşti. Çeviriyi başlatınca bağlanır.") `body`/`textSecondary` yazılır.
- **InfoCard (bilgi karosu)** – durum değil, ayar bilgisi gösteren düz karo: satırlar arasında 1 pt `border` ayraç,
  satır en az `rowHeight` 40; solda `body`/`textSecondary` ad, sağda değer (`body` yarı kalın, `textPrimary`). Bir
  ayara götüren satırın sonunda `›` (`textSecondary`) durur ve satır tıklanır (üzerine gelince `surface2` zemin,
  `inner` köşe). Simge yoktur.
- **Keycap (tuş)** – kısayol tuşu: `keycap` 24 yükseklik, `tag` köşe, `surface2` zemin, 1 pt `border` çerçeve, yatay
  iç boşluk 8, `caption` yazı `textPrimary`. Birden çok kısayol arasında `caption`/`textSecondary` "ya da".
- **TileIcon** – kutusuz simge, `textSecondary` (paket simgesi `pro`). Renkli kare içine simge konmaz.
- **Pill (etiket)** – 24 yükseklik, `tag` köşe, `caption` (orta kalınlık), `surface2` zemin + `textSecondary` yazı;
  paket için `proSoft` + `pro`. Canlı durum etiket değildir: atan nokta + kelime, zeminsiz.
- **Kenar çubuğu** – `sidebarWidth` genişliğinde karo; üstte `title` başlık, altında satırlar (simge + `body`);
  seçili satır `surface2` zemin ve yarı kalın yazı (sarı değil).
- **StepLayout** – sihirbaz adımı: `display` başlık, `body`/`textSecondary` açıklama, içerik (simge rozeti yok).
- **NumberedRow** – 28 pt `surface2` dairede numara (`textPrimary`), yanında `body` metin.
- **StatusRow** – 10 pt durum noktası, kalın ad, sağda değer. Nokta: bağlı `success`, çeviri sürerken
  bağlantı yok `warning`, çeviri başlamamışken `textSecondary` (boşta olmak uyarı değildir).
- **Metin alanı** – `surface2` zemin, 1 pt `border` çerçeve (odaktayken `accent`), `control` köşe, en az 40 yükseklik;
  PS5 kodu alanı 52 yükseklik ve `code` yazı. Etiketi alanın üstünde `callout`/`textSecondary`.
- **Bölmeli seçim** – 2–4 seçenek: `surface2` ray (`control` köşe, 4 iç boşluk), seçili parça yükseltilmiş zemin
  (`inner` köşe) ve yarı kalın yazı; halka ve parıltı yok (Mac'te sistemin büyük boy segmented denetimi).
  Telefonda seçili parça ayrıca 1 pt `accent` çerçeve alır: küçük ekranda yükseltilmiş zemin ile ray arasındaki fark
  (yaklaşık 1,2:1) tek başına seçimi belli etmiyor.
- **Seçenek karoları** – her seçeneğin kısa notu olan seçim (çeviri motoru): yan yana küçük karolar (ad
  `headline`, not `caption`), seçili olan *etkin* karo.
- **Anahtar** – açık/kapalı ayarlar (oyun paketleri, ortak havuz): başlık (`body`) solda, anahtar sağda. Açık/kapalı
  ayarların hepsi anahtardır; onay kutusu kullanılmaz.
- **Seçenek düğmesi** – listeden tek seçim (PS5 listesi): 20 pt daire, 1,5 pt `border` çerçeve; seçiliyken `accent`
  çerçeve ve içinde 10 pt `accent` nokta. Yazı `body`.
- **Kaydırma** – tekerlek ve dokunmatik yüzey adımla orantılı kaydırır (120 birim = 48 pt) ve 120 ms yumuşatılır;
  azaltılmış harekette yumuşatma yoktur. Dokunmatik yüzeyin küçük adımları tam satır sayılmaz.
- **Kaydırıcı** – 8 pt ray (`border`), dolu kısım `accent`, düz 24 pt tutamaç.
- **Bağlantı** – `accentText` renginde.
- **DoneLabel** – `success` renkli onay simgesi ve metin.
- **HintText** – `callout`, `textSecondary`.
- **ErrorText** – `callout`, `warning`, uyarı simgesi.
- **ProgressBar** – 6 pt yüksek, yuvarlak uçlu; zemin `border`, dolu kısım `accent`.

## Ekranlar

**Kurulum sihirbazı**: solda kenar çubuğu (logo + "Kurulum"; adımlar: biten adım yeşil dairede onay, sıradaki adım sarı
dairede numara ve `surface2` zeminli satır, gelecek adım gri numaralı; altta "Adım n / toplam" ve ilerleme çubuğu); sağda adım
(kaydırılabilir StepLayout; Ayarlar sayfası gibi başlık zeminde, bloklar kendi karolarında, dış karo yok), altında solda "Geri" (ikincil), sağda "Devam" (birincil). Son adım isteğe bağlı "Daha iyi çeviri (ücretsiz)": tek cümle
açıklama, numaralı üç satır ve "Ücretsiz anahtar al" (birincil, Google AI Studio'nun anahtar sayfası),
gizli anahtar alanı ve "Kaydet ve dene" (ikincil), altta veri kullanımı ve dakikalık sınır HintText'i.
Anahtar yokken alttaki düğme "Şimdilik geç" (ikincil) olur; kaydedilince "Gemini hazır" (DoneLabel) ve "Devam".

**Ana ekran** (bento, iki sütun): üstte logo + "CouchSubs" + sağda "Ayarlar" (ikincil, dişli simgeli).
Sol sütun: "Çeviriyi başlat" (birincil) ya da "Çeviriyi durdur" (tehlikeli), 52 yükseklik; altında iki sütunlu
karolar: PS5 ve TV durum karoları (altyazı yalnız bilgisayar ekranındaysa TV karosu yoktur; TV seçili ama bağlı
değilse "Kurulmadı" ve "TV bağla"), iki sütun genişliğinde "Altyazıyı göster: TV / Bilgisayar ekranı / İkisi de"
karosu (bilgisayar ekranı seçiliyse "Tıklamalar geçsin" ve "Altyazı penceresini ayarla"), iki satırlı bilgi karosu:
"Çeviri" (seçili motor ve `›`; Ayarlar › Çeviri'yi açar) ve "Ekranı çevir" (seçili kısayollar, her biri bir tuş:
Windows'ta varsayılan `Num 9` ya da `Ctrl+Shift+9`, Ayarlar › Kısayollar'dan değişir, hiç yoksa "kısayol yok"; Mac'te
`⌥⌘T`); gerekiyorsa uyarı karoları (dil paketi, çevrimiçi motor, yazı tanıma).
Sağ sütun: oyun paketleri açıksa (İngilizce→Türkçe, paket kurulu) paket karosu (mor paket simgesi) "Oyun paketleri
açık · n oyunun çevirisi hazır"; altında kalan yüksekliği dolduran "Canlı altyazı" karosu: son çeviri 28 pt altyazı
sarısında, altında özgün metin `caption`; önceki satırlar ayraçlarla, 17 pt ve kaydırılabilir. Yeni satır 0,18 sn
solarak gelir (azaltılmış harekette geçiş yok). Çeviri sürerken sağ üstte "Çevriliyor" (atan nokta + kelime). Karo parlamaz.

**Telefon ana ekranı** (iPhone ve Android aynı): PS5 ve Altyazı durum karoları (dokununca ilgili ayar açılır,
sağ üstte `›`), paket karosu (başlık ve not tek satır, sağda yalnız `›`; paketler kapalıysa nötr "Kapalı" etiketi),
altında iki satırlı bilgi karosu: "Çeviri" (motor, `›`, çeviri ayarlarını açar) ve "Son oturum" (süre, `›`, geçmişi
açar). Süreler ve sayaçlar tablo rakamlıdır; bir saati geçen süre "1 sa 12 dk" ya da "1:12:10" yazılır.

**Ayarlar**: solda kenar çubuğu ("Ayarlar" ve bölümler: Altyazı görünümü, Türkçe dublaj, Çeviri, Oyun paketleri,
Dil, Altyazı bölgesi, OBS katmanı, Hakkında; Windows'ta TV uygulaması da), sağda seçili bölümün `display` başlığı
ve karoları; altta sağda "Bitti" (birincil). "Altyazı görünümü" bölümünde "Altyazıyı göster" karosu, "TV'de" karosu
(yazı boyutu, ekrandaki konum, test altyazısı) ve gerekiyorsa TV uygulaması karosu.
"Oyun paketleri" bölümünde başlığın yanında nötr "Ücretsiz · n oyun" etiketi, açıklama, iki sütunlu paket karoları
(nötr kısaltma monogramı, ad, "n satır") ve altta anahtarlı satırlar: "Oyun paketlerini kullan", "Okunan İngilizce
altyazıları ortak havuza gönder" (varsayılan açık) ve tek satırlık HintText.
"Çeviri" bölümündeki "Çeviri motoru" karosunda motor seçimi seçenek karolarıyla (Ücretsiz, DeepL, Gemini, OpenAI,
Claude; her birinin altında kısa not); ücretli motorda kısa açıklama, model
seçimi, gizli anahtar alanı ve "Kaydet ve dene" (ikincil), anahtar sayfası bağlantısı, kayıtlıysa "Anahtar kayıtlı" (DoneLabel) ile
"Dene" ve "Anahtarı sil" (ikincil). Model yazılamaz; "Model" seçiminde yalnız ortak listedeki modeller
(`core/Sources/CouchSubsCore/Resources/ai-models.json`) sade adlarıyla görünür. Sonuç HintText, hata ErrorText olur.
Ücretsiz motor seçiliyken altında "Daha iyi çeviri için ücretsiz Gemini anahtarı alın." ve "Ücretsiz anahtar al"
(ikincil; Gemini'yi seçer ve anahtar sayfasını açar) durur; Gemini seçiliyken veri kullanımı ve dakikalık sınır HintText'i görünür.
Çevrimiçi motor çeviri sırasında hata verirse ana ekranda uyarı karosu çıkar. Kurulumun son adımında ortak havuz
bir HintText ile söylenir. Altyazı bilgisayar ekranında da gösteriliyorsa "TV'de" karosunun adı "Altyazı görünümü"
olur (aynı ayarlar pencereye de uygulanır).

**Kurulum, TV adımı**: TV aramasının altında "TV'm yok, bilgisayar ekranında göster" kartı (ikincil "Seç"). Seçilince
TV kurulumu atlanır, deneme adımı örnek altyazıyı bilgisayar ekranında gösterir.

**Bilgisayar ekranındaki altyazı penceresi**: kenarsız, saydam zeminli, her pencerenin (tam ekran oyun ve PS Remote
Play dahil) üstünde; odağı almaz, görev çubuğunda / Dock'ta görünmez. Altyazı kutusu TV'dekinin aynısıdır (yazı boyu
1080 satırlık ekrana göre ölçeklenir, beyaz ya da sarı yazı, siyah yarı saydam zemin, üstteki satırlar küçük ve soluk,
en çok üç satır). Altyazı yokken pencere gizlenir. "Tıklamalar geçsin" kapalıyken yazıdan tutup sürüklenir; açıkken
fare alttaki pencereye gider, geri almak için Mac'te ⌥⌘L ya da menü çubuğundaki CouchSubs simgesi, Windows'ta Num 7
(ya da sayı tuş takımı olmayan klavyede Ctrl+Shift+7) ya da ana ekran. "Altyazı penceresini ayarla": `accent` kesik çizgili çerçeve (parıltısız), üstte açıklama ve "Bitti" (birincil),
iki yanda genişletme tutamakları; yer, genişlik ve ekran hatırlanır.

**Hakkında**: 88 pt logo, ad, sürüm, lisans, teşekkür, bağlantılar, Sony ile ilişkisizlik notu.

## TV uygulaması

TV'de her zaman koyu temanın renkleri kullanılır (oyunun üstünde durur). Bilgi paneli ve "uygulamayı açın"
ekranı `background` %92–94 saydam zemin, 2 px `border` çerçeve, 24–32 px köşe; başlıkta logo. Kumanda
tuşları satır satır, tuş adı `accent` renginde. Altyazı kutusu mavimsi siyah (`#0c0e12`) %90 zemin üstünde beyaz,
normal kalınlıkta yazı (okunaklılık için tema rengi değil); iç boşluk ve köşe yazı boyuna göre (em). Bekleme ekranı açıkken panel kendiliğinden açılmaz.
Bekleme ekranında tek düğme "Demoyu izle"dir; seçili düğme `accent` dolgu ve beyaz çerçeveyle belli olur.
Demo sırasında sağ üstte panel biçiminde "DEMO" notu durur. Geri tuşu önce demoyu ya da paneli kapatır,
giriş ekranında TV'nin ana ekranına döner (mağaza kuralı).

## Windows'a aktarım

- `tokens.json` uygulamayla birlikte paketlenir ve açılışta okunur (Mac ile aynı yöntem);
  renkler açık/koyu tema kaynaklarına, boyutlar yazı ve boşluk kaynaklarına dönüştürülür.
- Yazı tipi Segoe UI Variable; sayılar yukarıdaki tablodakiyle aynı.
- Pencere zemini düz `background` rengidir (Mica/Acrylic, radyal ışık ve `DropShadowEffect` parıltısı kullanılmaz).
- Bileşenler yukarıdaki adlarla kurulur; ekran düzenleri birebir aynıdır.
- Kontrast testi Windows test projesine de eklenir.
