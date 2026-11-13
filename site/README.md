# couchsubs.enmeraapps.com

Tanıtım sayfası (yalnız durağan dosyalar: `public/`). Enmera sunucusunda, Plesk'teki `couchsubs.enmeraapps.com`
aboneliğinde çalışır (2026-11-13'ten beri; önce Cloudflare Workers'taydı). DNS Cloudflare'de, kayıt proxy'li,
SSL Plesk'in Let's Encrypt sertifikası.

Yayına alma: `site/deploy.sh` (rsync, `~/.ssh/enmera_server` anahtarı). `public/.htaccess` uzantısız adresleri
(`/gizlilik`) ve önbellek başlıklarını ayarlar.
