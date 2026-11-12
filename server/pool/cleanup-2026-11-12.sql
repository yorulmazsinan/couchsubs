-- Tek seferlik temizlik (2026-11-12): havuza eski sürümlerin süzmeden gönderdiği Türkçe arayüz yazıları, PS5 sistem
-- bildirimleri, yarım okumalar ve noktalamasız kısa parçalar silinir (src/filter.js'in SQL'e yaklaşık karşılığı).
-- ÇALIŞTIRILMADI. Her silinen satır D1'de yazma sayılır; günlük yazma sınırı sıfırlandıktan sonra çalıştırın.
--
-- Önce kaç satırın gideceğine bakın (yalnız okur):
--   cd server/pool && npx wrangler d1 execute couchsubs-pool --remote --command \
--     "SELECT COUNT(*) FROM lines WHERE exported=0 AND <aşağıdaki koşul>"
-- Silmek için:
--   cd server/pool && npx wrangler d1 execute couchsubs-pool --remote --file=cleanup-2026-11-12.sql

DELETE FROM lines WHERE exported = 0 AND (
  -- Türkçeye özgü harf ya da iki ve daha çok ü/ö/ç.
  text GLOB '*[ğĞşŞıİ]*'
  OR length(text) - length(replace(replace(replace(replace(replace(replace(text, 'ü', ''), 'Ü', ''), 'ö', ''), 'Ö', ''), 'ç', ''), 'Ç', '')) >= 2
  -- Yazı tanımada harfleri bozulmuş Türkçe PS5 arayüzü ("Oturum Aqtl", "Sifirlama Seqenekleri").
  OR text LIKE '%oturum%' OR text LIKE '%sifirlama%' OR text LIKE '%seqenek%' OR text LIKE '%secenek%'
  OR text LIKE '%sistemini%' OR text LIKE '%yeniden bas%' OR text LIKE '%oyunu kapat%' OR text LIKE '%ana ekranda%'
  OR text LIKE '%ekran ve video%' OR text LIKE '%tfen bekle%' OR text LIKE '%kupalar%' OR text LIKE '%takip edin%'
  OR text LIKE '%kaydedildi%'
  -- PS5 ve oyun sistem yazıları.
  OR ' ' || text LIKE '% signed in%' OR ' ' || text LIKE '% signed out%' OR text LIKE '%earned a trophy%'
  OR text LIKE '%trophy earned%' OR text LIKE '%trophy unlocked%' OR text LIKE '%screenshot saved%'
  OR text LIKE '%video clip saved%' OR text LIKE '%media gallery%' OR text LIKE '%is now online%'
  OR text LIKE '%joined the party%' OR text LIKE '%left the party%' OR text LIKE '%remote play%'
  OR text LIKE '%controller battery%' OR text LIKE '%controller%disconnected%' OR text LIKE '%press the ps button%'
  OR text LIKE '%playstation network%' OR text LIKE '%turn off your console%' OR text LIKE '%cloud save%'
  OR text LIKE '%do not quit%' OR text LIKE '%photo mode%' OR text LIKE '%story mode%' OR text LIKE '%press any button%'
  -- Küçük harfle başlayan yarım okuma ("it Auto V's Story Mode.").
  OR text GLOB '[a-z]*'
  -- Noktalamasız ve tanımlık/bağlaçla biten ("GO to the", "Take out the").
  OR lower(text) LIKE '% the' OR lower(text) LIKE '% to' OR lower(text) LIKE '% a' OR lower(text) LIKE '% an'
  OR lower(text) LIKE '% of' OR lower(text) LIKE '% and' OR lower(text) LIKE '% or' OR lower(text) LIKE '% with'
  OR lower(text) LIKE '% for' OR lower(text) LIKE '% my' OR lower(text) LIKE '% your'
  -- Tümü büyük harfli, noktalamasız, en çok altı sözcüklü arayüz yazısı ("FREE MONTH OF GTA+", "PHOTO MODE SELECT").
  OR (text = upper(text) AND text GLOB '*[A-Z]*' AND substr(text, -1) NOT IN ('.', '!', '?', '…', '"', '”', '’', ')')
      AND length(text) - length(replace(text, ' ', '')) < 6)
  -- 15 karakterden kısa ve cümle noktalamasıyla bitmeyen parça.
  OR (length(text) < 15 AND substr(text, -1) NOT IN ('.', '!', '?', '…', '"', '”', '’', ')'))
);

-- Silinen satırların görülme kayıtları.
DELETE FROM sightings WHERE key NOT IN (SELECT key FROM lines);
