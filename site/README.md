# couchsubs.enmeraapps.com

Tanıtım sayfası (yalnız durağan dosyalar: `public/`). Enmera sunucusunda, Plesk'teki `couchsubs.enmeraapps.com`
aboneliğinde çalışır (2026-11-13'ten beri; önce Cloudflare Workers'taydı). DNS Cloudflare'de, kayıt proxy'li,
SSL Plesk'in Let's Encrypt sertifikası.

Yayına alma: `site/deploy.sh` (rsync, `~/.ssh/enmera_server` anahtarı). Sunucu adresi, SSH portu ve kök klasör depoda
durmaz; betik bunları `~/.config/couchsubs/site.env` dosyasından okur (`SITE_HOST`, `SITE_PORT`, `SITE_ROOT`; chmod 600). `public/.htaccess` uzantısız adresleri
(`/gizlilik`) ve önbellek başlıklarını ayarlar.

Rehber sayfaları (`ps5-turkce-altyazi.html`, `lg-tv-kurulumu.html`, `sss.html`, `sorun-giderme.html`, `surum-notlari.html` …)
ortak `sayfa.css`'i kullanır; `sss.html` ana sayfadaki SSS ile aynı içeriktedir. Yeni sayfa eklenince `sitemap.xml`'e de yazılır.
