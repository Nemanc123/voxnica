#!/usr/bin/env bash
# Подставляет секреты из .env в конфиги LiveKit, nginx и SeaweedFS.
# Запускать из deploy/vds перед docker compose up и после смены .env.
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
    echo "нет файла .env — скопируйте .env.example и заполните" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

mkdir -p runtime

envsubst '${LIVEKIT_API_KEY} ${LIVEKIT_API_SECRET} ${RTC_DOMAIN}' \
    < livekit.yaml.template > runtime/livekit.yaml

envsubst '${DOMAIN} ${RTC_DOMAIN} ${CERT_NAME}' \
    < nginx.conf.template > runtime/nginx.conf

envsubst '${STORAGE_ACCESS_KEY} ${STORAGE_SECRET_KEY}' \
    < seaweedfs-s3.json.template > runtime/seaweedfs-s3.json

chmod 600 runtime/*.json runtime/*.yaml runtime/*.conf

echo "конфиги отрендерены в deploy/vds/runtime/"
