# GTA 6 havuz eklenmesi, düzeltilmesi ve kod düzeltmeleri (43.130 satır)

Dosya: `gta-tr-havuz-katki.json.gz` · biçim 2 · 43.130 satır + 17.286 cümle parçası + bulanık imza (kısa satırlar dahil).

Satır sayısı: #505'te gönderilen 24.452 satır → bu PR 39.186 satır (+14.734).

## Benim ayarlarım

Oyunu ve ölçümleri bu ayarlarla yapıyorum; oyunculara da bunları seçmeleri önerilebilir (her birinin etkisi aşağıda):

- **Gelişmiş OCR** açık.
- Oyunda altyazı zemini **Solid**, CouchSubs'ta **"Altyazı zeminini izle"** açık.
- **"Yarım okunan satır için bekleme" 0,3 sn.**
- Kendi sürümümde otomatik güncelleme ve sunucu paketi kapalı: yalnız kendi havuzum ve kendi yerel modelim
  (Gemma 4 26B) kullanılsın diye.

## Nasıl yapıldı

- **Kaynak:** oyunu %100 bitiren 4 yayıncının gameplay videolarından alınmıştır (YouTube, 1080p). Her video 15 dakikalık
  parçalarla OCR ile okundu.
- **Okuma alanı:** ekranın alt ortası (altyazı bandı), çok küçük yazılar elendi.
- **Ayıklama:** tabela, plaka, ekran yazısı (HUD, harita, silah), telefon/sosyal medya, reklam/haber bandı, yayıncı
  filigranı, tuş ipuçları, oyunun menü ve jenerik yazıları çıkarıldı. Konuşmaya yapışan görev yazısı ayrı satıra alındı.
  Okuma hataları elle düzeltildi.
- **"Zaten var mı" kararı:** CouchSubs'ın kendi aramasıyla (`PackLookup.Match`, bulanık imza ve parçalar dahil) verildi;
  CouchSubs'ın bulduğu satır tekrar eklenmedi.
- **Çeviri:** Codex, ChatGPT ve Claude ile çevrilmiş ve kontrol edilmiştir (küfür sertliği, biçim, boş ya da İngilizce
  kalmış satır). Havuzda olmayan satırları oyunda yerel model **Gemma 4 26B** çeviriyor.
- **Oyundan gelen satırlar:** oyunda yerel modele düşen gerçek konuşmalar (Gelişmiş OCR okuması) ayıklanıp havuza eklendi
  (126 satır).

## Havuz hakkında

Sunucudaki GTA paketi (86.973 satır) Workers AI GLM 5.3 Flash ile çevrildiği için bizimkinden kötü çıkıyor:
95 farklı satırda kör karşılaştırma: bizimki daha iyi **59**, sunucu daha iyi **5**, eşit **31**. Ortak 8.025 satırın
1.616'sında sunucu çevirisi bizimkinden farklı. Sunucu paketinde: 444 satırda biçim artığı (`{ } [ ] < > \n`),
24 satır İngilizce kalmış, 17.950 satır 1-3 kelimelik kısa parça.

Bizde sunucu paketi kapalı; yalnız bu havuz + yerel model kullanılıyor. Anahtarlar aynı olduğu için bu satırlarla
sunucudaki havuzu da düzeltebilirsiniz (GLM çevirisi olan satırların yerine bunları koyarak).

**İmza:** bu havuzda bulanık imza ve cümle parçaları var; GTA'da 8-15 harfli kısa satırlar da imzalı (Patch 4). Sunucudaki
GTA havuzunu da bu PR'daki betikle (`common.py`, `fuzzy_min_len`) kısa satırlar dahil imzalayabilirsiniz.

## Kod düzeltmeleri: önce → sonra

Ölçü: 4 yayıncının videolarından 156.683 okuma, CouchSubs'ın kendi aramasıyla (simülasyon), havuz 38.187 satır.
Sayı: yerel modele giden **hikâye altyazısı** (konuşma ve görev yazısı). Adımlar sırayla eklendi.

Patch 1, 3 ve 4 öteki oyunlarda da işe yarar; ben yalnız GTA'da denedim ve test ettim, bu yüzden kodda yalnız GTA
seçiliyken açık.

**Patch 1: GTA ekran yazısı çevrilmez** (`ScreenText`, `SubtitlePipeline.DropsScreenText`)
- Önce: silah adı, plaka, tabela, mağaza menüsü gibi küçük harfsiz ve noktalamasız yazılar altyazı sanılıyordu
  (`IsActionLabel` yalnız tek başına okunan, en çok üç sözcüklük etiketi tutuyordu); konuşmaya yapışınca konuşma da
  havuzdan bulunamıyordu.
- Sonra: yerel modele giden hikâye altyazısı **2.221 → 1.799**. Ekran yazısı hiç çevrilmez; konuşmaya yapışmışsa yalnız
  o satır atılır.

**Patch 2: karakter olmayan kod noktası paket aramasını çökertmez** (`PackKey.Normalize`)
- Önce: OCR U+FFFE gibi bir karakter okuyunca yedek yol da istisna atıyordu.
- Sonra: çökme yok, satır normal aranıyor.

**Ayar: Solid zemin + "Altyazı zeminini izle"** (patch değil; CouchSubs'ta zaten var)
- **1.799 → 1.317.** Zemin dışındaki satırlar (harita, silah, telefon) hiç okunmaz; yanındaki konuşma havuzdan gelir.

**Patch 3: kısmi eşleşme** (`PackLookup.MatchPartial`, `SubtitlePipeline.PartialPackLookup`)
- Önce: iki konuşma alt alta okununca ikisi de havuzda değilse ikisi birden yerel modele gidiyordu (`PackLookup`:
  "parçaların hepsi bulunmalıdır").
- Sonra: yalnız bir satır havuzda yoksa havuzdaki satır havuzdan, yalnız eksik satır yerel modelden gelir; TV'de ikisi
  birlikte gösterilir. **1.317 → 990.**
- CouchSubs'ın "az önce çevrilen satırın parçası" kuralı bunların bir kısmını zaten atıyor: **990 → 861.**

**Ayar: "Yarım okunan satır için bekleme" 0,3 sn** (patch değil; CouchSubs'ta var, varsayılanı 0,3)
- Yalnız havuzda olmayan ve yarım görünen satır bekler (küçük harfle başlar ya da noktalamayla bitmez). Havuzdan gelen
  satır ve tam cümle hiç beklemez. **861 → 715.**

**Patch 4: kısa satırlarda benzerlik** (`PackFuzzy.ShortMinLength = 8`; paket betiği `common.py` `SHORT_MIN_LEN`)
- Önce: benzerlik araması 16 harften kısa satırda hiç yapılmıyordu; "I'II take it." gibi kısa satırlar yerel modele
  gidiyordu.
- Sonra: GTA havuzunda 8-15 harfli satırlar da imzalı ve aranıyor; benzerlik araması OCR'ın karıştırdığı harfleri
  (l, 1, I → i) aynı sayıyor, "I'II take it." ile "I'll take it." aynı çıkıyor. **715 → 681.** Öteki oyunlar 16 harf
  sınırında kalır.

**Sonuç:** her şey açıkken yerel modele giden hikâye altyazısı **681** okuma: her 1.000 altyazının ~4'ü. Kalanı havuzdan.

## Havuzdaki eklemeler: önce → sonra

- **Bulanık imza + cümle parçaları:** PC'de gerçek Gelişmiş OCR okumasında havuzdan bulunan %78,9 → %86,6
  (3.414 okumada 2.694 → 2.957).
- **CouchSubs temizliği sonrası hâller:** `WithoutOcrNoise` 366 satırı değiştiriyordu ("Buy a 6-pack for Cal" →
  "Buy a for Cal"); 131'inin temiz hâli eklendi.
- **Oyunda (PC satır kaydı):** eski paketle (24.452 satır) gösterilen 1.837 satırın 622'si yerel modele gitti (%34).
  Yeni paketle hikâye sahnelerinde 80 satırın 4'ü (Solid açılmadan önce); rastgele arka plan sohbetlerinde 95 satırın 29'u
  yerel modele gitti, bu 29 satır da artık havuzda (oyundan eklenen 126 satırın içinde).

## CouchSubs güncellemesinde yapılabilecekler

1. **Patch 1-4'ün Mac, iPhone ve Android karşılıkları** (bu PR yalnız Windows; Mac ve Android'de bulanık arama sınırı
   16 harfte kaldı).
2. **Sunucudaki GTA havuzunu yeniden imzalamak:** kısa satırlar dahil (`fuzzy_min_len`).
3. **GTA seçilince ayarlar:** Gelişmiş OCR ve "Altyazı zeminini izle" kendiliğinden açılsın, Solid zemin oyuncuya önerilsin
   (Solid oyunun kendi ayarı).
4. **"Yarım okunan satır için bekleme" varsayılanı 0,3 sn kalsın.**
5. **Temizlik sayılı sözcükleri silmesin** (`WithoutOcrNoise`): "6-pack" gibi sözcükler siliniyor; düzelirse havuzdaki
   takma adlara gerek kalmaz.
6. **Bizim kendi eklerimiz** (seçenek olarak faydalı olabilir):
   - GTA 6'ya özel ayarlanmış okuma alanı (0,71–1,00 × 0,21–0,79) ve yazı boyutu 33: yalnız altyazı bandı okunur.
   - "Hızlı altyazı algılama" varsayılanı açık: değişmeyen alan 2 karede bir yeniden okunur, bozuk okumanın düzgünü daha
     çabuk gelir.
   - Sunucu paketini kullanıcı kapatabilir (`atlanan_paketler.txt`): yalnız bu havuz ve yerel model.
   - Yerel model çevirisinin başına "." işareti (hangi satırın havuzdan gelmediği anlaşılıyor) ve satır başına kaynak ve
     süre kaydı (`satir_olcum.csv`).
   - Tek satır sınırı 42 → 66 karakter: GTA tek satırda 66 karaktere kadar gösteriyor; 42'de oyunun tek satırlık
     altyazılarının %23'ü bizde ikiye bölünüyordu.

Testler (en son main üstünde): Core 1.143/1.143, Shell 396/396, Translation 217 (14 atlandı), paket betiği 9/9.

## Güncellemeler

- **20 Kas:** 38.821 satır → 39.186 satır (+365): oyunu %100 bitiren 4. yayıncının Part 3'ü eklendi; PR en son main'in
  (beta.60 sonrası) üstüne taşındı.
- **21 Kas:** önceki 39.186 satır → yeni 43.130 satır.

## Devamı

2. tur OCR okuması yapılacak; OCR'ın kaçırdığı satırlar ve yeni %100 gameplay videolarındaki satırlar da eklenecek. Bu
PR'da ya da sizin istediğiniz yerde güncelleyeceğim; her güncellemede "önceki X satır → yeni Y satır (+fark)" diye
yazacağım.
