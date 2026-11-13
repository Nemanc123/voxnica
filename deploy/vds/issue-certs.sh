#!/usr/bin/env bash
# Первый выпуск сертификата. nginx должен быть остановлен: certbot
# занимает порт 80 для standalone-проверки.
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
    echo "нет файла .env" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

docker compose --profile certbot run --rm \
    -p 80:80 \
    certbot certonly --standalone \
    --cert-name "$CERT_NAME" \
    -d "$DOMAIN" -d "$RTC_DOMAIN" -d "s3.$DOMAIN" \
    --agree-tos -m "$LETSENCRYPT_EMAIL" --non-interactive

echo "сертификат $CERT_NAME выпущен"
