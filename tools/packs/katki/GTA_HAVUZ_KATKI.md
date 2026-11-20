# GTA havuza katkı: 38.187 satır, düzgün çeviri + birkaç düzeltme

Dosya: `gta-tr-havuz-katki.json.gz` · biçim 2 · 38.187 satır + 15.034 cümle parçası + bulanık imza.

Satır sayısı: #505'te gönderilen 24.452 satır → bu PR 38.187 satır (+13.735).

## Benim ayarlarım

Oyunu ve ölçümleri bu ayarlarla yapıyorum; oyunculara da bunları seçmeleri önerilebilir (her birinin etkisi aşağıda):

- **Gelişmiş OCR** açık.
- Oyunda altyazı zemini **Solid**, CouchSubs'ta **"Altyazı zeminini izle"** açık.
- **"Yarım okunan satır için bekleme" 0,3 sn.**

## Nasıl yapıldı

- **Kaynak:** 4 yayıncının %100 gameplay videolarından alınmıştır (YouTube, 1080p). Her video 15 dakikalık
  parçalarla 1. tur OCR ile okundu; 1. turun kaçırdıkları 2. turda (1/8 sn kaydırmalı) tekrar OCR ile çekilip güncellenecektir.
- **Okuma alanı:** ekranın alt ortası (altyazı bandı), çok küçük yazılar elendi.
- **Ayıklama:** tabela, plaka, ekran yazısı (HUD, harita, silah), telefon/sosyal medya, reklam/haber bandı, yayıncı
  filigranı, tuş ipuçları, oyunun menü ve jenerik yazıları çıkarıldı. Konuşmaya yapışan görev yazısı ayrı satıra alındı.
  Okuma hataları elle düzeltildi.
- **"Zaten var mı" kararı:** CouchSubs'ın kendi aramasıyla (`PackLookup.Match`, bulanık imza ve parçalar dahil) verildi;
  CouchSubs'ın bulduğu satır tekrar eklenmedi.
- **Çeviri:** ChatGPT, Codex ve Claude. Küfür sertliği (yumuşatılmış küfür elle sertleştirildi), biçim, boş/İngilizce kalmış
  satır kontrolü yapıldı. Havuzda olmayan satırları oyunda yerel model **Gemma 4 26B** çeviriyor.
- **Oyundan gelen satırlar:** oyunda yerel modele düşen gerçek konuşmalar (Gelişmiş OCR okuması) ayıklanıp havuza eklendi
  (126 satır).

## Havuz hakkında

Sunucudaki GTA paketi (86.973 satır) Workers AI GLM 5.3 Flash ile çevrildiği için bizimkinden kötü çıkıyor:
95 farklı satırda kör karşılaştırma: bizimki daha iyi **59**, sunucu daha iyi **5**, eşit **31**. Ortak 8.025 satırın
1.616'sında sunucu çevirisi bizimkinden farklı. Sunucu paketinde: 444 satırda biçim artığı (`{ } [ ] < > \n`),
24 satır İngilizce kalmış, 17.950 satır 1-3 kelimelik kısa parça.

Bizde sunucu paketi kapalı; yalnız bu havuz + yerel model kullanılıyor. Anahtarlar aynı olduğu için bu satırlarla
sunucudaki havuzu da düzeltebilirsiniz (GLM çevirisi olan satırların yerine bunları koyarak).

## Düzeltmeler ve öneriler: önce → sonra

Ölçü: 4 yayıncının videolarından 156.683 okuma, CouchSubs'ın kendi aramasıyla (simülasyon), havuz 38.187 satır.
Sayı: tamamen yerel modele (Gemma 4 26B) giden okuma. Bu sayıların çoğu ekran yazısı, telefon, reklam ve çöp; hikâye
altyazısı değil (hikâye sayısı en sonda ayrı). Adımlar sırayla eklendi.

**Patch 1: GTA ekran yazısı çevrilmez** (bu PR'da: `ScreenText`, `SubtitlePipeline.DropsScreenText`; yalnız GTA seçiliyken)
- Önce: silah adı, plaka, tabela, mağaza menüsü gibi küçük harfsiz ve noktalamasız yazılar altyazı sanılıyordu
  (`IsActionLabel` yalnız tek başına okunan, en çok üç sözcüklük etiketi tutuyordu). Yerel modele giden: **16.051**.
- Sonra: **12.405**. 3.202 ekran yazısı hiç çevrilmez; konuşmaya yapışmışsa yalnız o satır atılır, 662 okuma yerel model
  yerine havuzdan gelir; havuzdan gelen 930 yanlış ekran yazısı eşleşmesi ekrana gelmez.

**Patch 2: karakter olmayan kod noktası paket aramasını çökertmez** (bu PR'da: `PackKey.Normalize`)
- Önce: OCR U+FFFE gibi bir karakter okuyunca yedek yol da istisna atıyordu (~2 milyon karakterde bir).
- Sonra: çökme yok, satır normal aranıyor.

**Ayar: Solid zemin + "Altyazı zeminini izle"** (patch değil; CouchSubs'ta zaten var)
- Önce: 12.405.
- Sonra: **3.341**. Zemin dışındaki 8.562 okuma (harita, silah, telefon, yayın yazısı) hiç okunmaz; 502 okuma zemin dışı
  satır atılınca havuzdan gelir.
- Videolarda Solid zemin olmadığı için zemin dışı satırlar kurallarla seçildi. Gerçek oyun görüntüsünde CouchSubs'ın kendi
  zemin kontrolü altyazı satırını tuttu, sahne yazısını attı.

**Öneri 1: kısmi eşleşme (satır satır)** (CouchSubs güncellemesi gerekir; kodda yok)
- Önce: CouchSubs üst üste okunan iki satırı tek tek arıyor ama ikisi de havuzda değilse ikisini birden yerel modele
  yolluyor (`PackLookup`: "parçaların hepsi bulunmalıdır, yoksa satır motorla çevrilir").
- Öneri: havuzda bulunan satır havuzdan, yalnız bulunmayan satır yerel modelden gelsin.
- Değişecek yer: `PackLookup.cs` satır satır aramada bir satır bulunmayınca aramayı bırakıyor (`all = false`), yalnız
  hepsi bulunursa sonuç dönüyor. Bulunan satırların Türkçesi tutulmalı, eksik satırlar da sonuçla dönmeli (`PackMatch`);
  `SubtitlePipeline` yalnız eksik satırları yerel modele gönderip havuzdakilerle birleştirmeli. Mac'te de aynısı.
- Sonra (her satır CouchSubs'ın kendi aramasıyla ayrı arandı): tamamen yerel modele giden **3.341 → 2.662**. 675 okumada
  havuzdaki satır havuzdan gelir, yalnız eksik satır yerel modele gider; 4 okuma tamamen havuzdan gelir.
- CouchSubs'ın "az önce çevrilen satırın parçası" kuralı kalanların 423'ünü zaten atıyor; simülasyona eklenince **2.239**.

**Ayar: "Yarım okunan satır için bekleme" 0,3 sn** (patch değil; CouchSubs'ta var, varsayılanı 0,3)
- Yalnız havuzda olmayan ve yarım görünen satır bekler (küçük harfle başlar ya da noktalamayla bitmez). Havuzdan gelen satır
  ve tam cümle hiç beklemez.
- Önce (0 sn): 2.239. Sonra (0,3 sn): **1.951**. 288 yarım okuma atılır, yerine havuzdaki tam satır gelir.
- Videoda okuma 0,25 sn'de bir olduğu için 0,2 sn ile 0,3 sn aynı sonucu verdi.

**Öneri 2: kısa satırlarda benzerlik eşleştirmesi** (CouchSubs güncellemesi gerekir; kodu yok)
- Önce: benzerlik araması 16 harften kısa satırda hiç yapılmıyor; "I'II take it." gibi okuma hatalı kısa satırlar yerel
  modele gidiyor.
- Nasıl düzelir: benzerlik araması satırı harf üçlülerine bölüp havuzdaki satırla karşılaştırıyor ve OCR'ın karıştırdığı
  harfleri (l, 1, I → i) aynı sayıyor; "I'II take it." ile "I'll take it." aynı çıkıyor. Yalnız 16 harf sınırı inmeli.
- Değişecek yer: `PackFuzzy.MinLength` 16 → 8 (Windows `PackFuzzy.cs`, Mac `PackFuzzy.swift`) ve paket betiğinde
  `common.py` `MIN_LEN` 16 → 8 (havuz kısa satırlara da imza yazsın); ortak deneme verisi `fuzzy-vectors.json` güncellenir,
  havuzlar yeniden üretilir.
- Deneme (kendi betiğimle, CouchSubs'ın eşikleriyle: OCR izli satırda %70, temizde %90, Türkçesi farklı ikinci aday 5 puan
  yakınsa red): **1.951 → 1.898**. 55 satır eşleşti: 44'ü doğru, 1'i yanlış ("Thanks for the" → "Thanks for that."),
  10'u ekran yazısı (Solid'de okunmaz). Kazanç küçük.

**Sonuç: hikâye altyazısında yerel modele düşen çok az.** Her şey açıkken tamamen yerel modele giden 1.898 okumanın
yaklaşık 300'ü hikâye altyazısı (konuşma ya da görev yazısı): 156.683 okumanın %0,2'si, her 1.000 altyazının ~2'si.
Bunlar havuzda var ama videoda bozuk okunmuş (harf hatası, yarım okuma); Solid'in düz zemininde harf hatası daha az olur.
Eşik gevşetilirse yanlış eşleşme getirir. Kalan okumalar hikâye değil: telefon, harita, reklam, oyun ipucu ve çöp.

## Havuzdaki eklemeler: önce → sonra

- **Bulanık imza + cümle parçaları:** PC'de gerçek Gelişmiş OCR okumasında havuzdan bulunan %78,9 → %86,6
  (3.414 okumada 2.694 → 2.957). Mac okumalarının tamamında %81,7 → %86,4 (117.404 okumada 95.919 → 101.437).
- **CouchSubs temizliği sonrası hâller:** `WithoutOcrNoise` 366 satırı değiştiriyordu ("Buy a 6-pack for Cal" →
  "Buy a for Cal"); 131'inin temiz hâli eklendi.
- **Yeni satırlar (part başına, Solid'siz, yerel modele giden):** 3. yayıncı Part 2 1.904 → 465, Part 3 1.839 → 381,
  Part 4 2.846 → 1.920 (çoğu oyun sonu jeneriği; Solid zeminde okunmaz); 4. yayıncı Part 1 1.149 → 356.
- **Oyunda (PC satır kaydı):** eski paketle (24.452 satır) gösterilen 1.837 satırın 622'si yerel modele gitti (%34).
  Yeni paketle hikâye sahnelerinde 80 satırın 4'ü (Solid açılmadan önce); rastgele arka plan sohbetlerinde 95 satırın 29'u
  yerel modele gitti, bu 29 satır da artık havuzda (oyundan eklenen 126 satırın içinde).

## CouchSubs güncellemesinde yapılabilecekler

1. **Ekran yazısı kuralı** (bu PR'da, Patch 1): GTA seçiliyken küçük harfsiz ve noktalamasız satır çevrilmesin.
   Yerel modele giden 16.051 → 12.405.
2. **Karakter olmayan kod noktası** (bu PR'da, Patch 2): OCR'ın okuduğu U+FFFE gibi karakter paket aramasını çökertmesin.
3. **Kısmi eşleşme** (Öneri 1, CouchSubs güncellemesi): üst üste okunan iki satırdan havuzda olan havuzdan, olmayan yerel
   modelden gelsin. Tamamen yerel modele giden 3.341 → 2.662; 675 okumada bir satır havuzdan gelir.
4. **Kısa satırlarda benzerlik** (Öneri 2, CouchSubs güncellemesi): `PackFuzzy.MinLength` ve paket betiğindeki `MIN_LEN`
   16 → 8 olursa 44 doğru satır daha havuzdan gelir, 1 yanlış eşleşme çıktı. Kazanç küçük.
5. **Temizlik sayılı sözcükleri silmesin** (`WithoutOcrNoise`): "6-pack" gibi sözcükler siliniyor, 366 satır bozuluyordu;
   düzelirse havuzdaki takma adlara gerek kalmaz.
6. **GTA seçilince ayar önerisi:** oyuncuya Gelişmiş OCR, Solid zemin ve "Altyazı zeminini izle" önerilsin. Bu ayarla yerel
   modele giden 12.405 → 3.341 (yukarıda).
7. **"Yarım okunan satır için bekleme" varsayılanı 0,3 sn kalsın:** 2.239 → 1.951; yalnız havuzda olmayan yarım satır bekler.
8. **Patch 1 ve 2'nin Mac, iPhone ve Android karşılıkları** (bu PR yalnız Windows).
9. **Bizim kendi eklerimiz** (seçenek olarak faydalı olabilir):
   - Doğru okuma ve saçmayı eleme için:
     - GTA okuma alanı varsayılanı 0,71–1,00 × 0,21–0,79 ve yazı boyutu 33: yalnız altyazı bandı okunur, üstteki ve yandaki
       HUD ve harita okunmaz. Kutu ölçümle seçildi: en yüksek gerçek altyazı satırı %77, en uzun satırlar %22,2–%77,8.
     - "Hızlı altyazı algılama" varsayılanı açık: değişmeyen alan 2 karede bir yeniden okunur, bozuk okumanın düzgünü daha
       çabuk gelir.
     - Sunucu paketini kullanıcı kapatabilir (`atlanan_paketler.txt`): GLM çevirisi gelmez, yalnız bu havuz ve yerel model.
   - Görmek ve ölçmek için: yerel model çevirisinin başına "." işareti (hangi satırın havuzdan gelmediği anlaşılıyor),
     satır başına kaynak ve süre kaydı (`satir_olcum.csv`: havuz mu yerel model mi).
   - Gösterim: tek satır sınırı 42 → 66 karakter. GTA tek satırda 66 karaktere kadar gösteriyor; 42'de oyunun tek satırlık
     altyazılarının %23'ü bizde ikiye bölünüyordu.

Testler: Core 1.125/1.125, Shell 371/371, Translation 215 (14 atlandı). Mac/iPhone/Android karşılıkları bu PR'da yok.

## Devamı

2. tur OCR okumalarından sonra havuzu güncelleyeceğim; yeni %100 gameplay videoları geldikçe de güncelleyeceğim. Bu PR'da
ya da sizin istediğiniz yerde (yeni PR ya da issue). Her güncellemede "önceki X satır → yeni Y satır (+fark)" diye yazacağım.
