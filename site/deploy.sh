#!/usr/bin/env bash
# couchsubs.enmeraapps.com'u Enmera sunucusuna (Plesk, couchsubs.enmeraapps.com aboneliği) yükler.
# Kullanım: site/deploy.sh   (SSH anahtarı: ~/.ssh/enmera_server)
set -euo pipefail
cd "$(dirname "$0")"
HOST=root@171.22.185.218
PORT=23422
ROOT=/var/www/vhosts/couchsubs.enmeraapps.com/httpdocs
rsync -rlptz --no-o --no-g --omit-dir-times --delete --exclude _headers --exclude .DS_Store \
  -e "ssh -i $HOME/.ssh/enmera_server -p $PORT" public/ "$HOST:$ROOT/"
ssh -i "$HOME/.ssh/enmera_server" -p "$PORT" "$HOST" \
  "U=\$(stat -c %U $ROOT/..) && chown \$U:psaserv $ROOT && chmod 750 $ROOT && find $ROOT -mindepth 1 -exec chown \$U:psacln {} + && find $ROOT -mindepth 1 -type d -exec chmod 755 {} + && find $ROOT -type f -exec chmod 644 {} +"
echo "Yüklendi: https://couchsubs.enmeraapps.com"
