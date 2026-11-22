#!/usr/bin/env bash
# couchsubs.enmeraapps.com'u Enmera sunucusuna (Plesk, couchsubs.enmeraapps.com aboneliği) yükler.
# Kullanım: site/deploy.sh   (SSH anahtarı: ~/.ssh/enmera_server)
# Sunucu bilgileri depoda tutulmaz; ~/.config/couchsubs/site.env dosyasından okunur:
#   SITE_HOST=kullanici@sunucu   SITE_PORT=ssh-portu   SITE_ROOT=/var/www/vhosts/…/httpdocs
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="${COUCHSUBS_SITE_ENV:-$HOME/.config/couchsubs/site.env}"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Hata: sunucu ayar dosyası bulunamadı: $ENV_FILE" >&2
  echo "Bu dosyayı oluşturup SITE_HOST, SITE_PORT ve SITE_ROOT değerlerini yazın (chmod 600; depoya eklemeyin)." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"
for v in SITE_HOST SITE_PORT SITE_ROOT; do
  if [[ -z "${!v:-}" ]]; then
    echo "Hata: $ENV_FILE içinde $v boş ya da yok." >&2
    exit 1
  fi
done
KEY="$HOME/.ssh/enmera_server"
if [[ ! -f "$KEY" ]]; then
  echo "Hata: SSH anahtarı bulunamadı: $KEY" >&2
  exit 1
fi
HOST=$SITE_HOST PORT=$SITE_PORT ROOT=$SITE_ROOT
rsync -rlptz --no-o --no-g --omit-dir-times --delete --exclude _headers --exclude .DS_Store \
  -e "ssh -i $KEY -p $PORT" public/ "$HOST:$ROOT/"
ssh -i "$KEY" -p "$PORT" "$HOST" \
  "U=\$(stat -c %U $ROOT/..) && chown \$U:psaserv $ROOT && chmod 750 $ROOT && find $ROOT -mindepth 1 -exec chown \$U:psacln {} + && find $ROOT -mindepth 1 -type d -exec chmod 755 {} + && find $ROOT -type f -exec chmod 644 {} +"
echo "Yüklendi: https://couchsubs.enmeraapps.com"
