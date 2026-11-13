#!/usr/bin/env bash
# Продление сертификата и перезагрузка nginx.
# Добавьте в crontab на VDS (раз в сутки):
#   15 3 * * * /opt/voxnica/deploy/vds/renew-certs.sh >> /var/log/dc-certs.log 2>&1
set -euo pipefail

cd "$(dirname "$0")"

set -a
# shellcheck disable=SC1091
. ./.env
set +a

docker compose --profile certbot run --rm \
    certbot renew --webroot -w /var/www/certbot --quiet

docker compose exec -T nginx nginx -s reload
echo "сертификаты проверены, nginx перезагружен"
