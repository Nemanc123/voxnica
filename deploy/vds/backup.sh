#!/usr/bin/env bash
# Бэкап БД и файлов. Хранит последние 7 дней локально.
#
# ВАЖНО: локальный бэкап не спасает при потере VDS. Копируйте backups/
# на другой хост или в объектное хранилище (rclone/restic).
set -euo pipefail

cd "$(dirname "$0")"

set -a
# shellcheck disable=SC1091
. ./.env
set +a

stamp="$(date +%Y%m%d-%H%M%S)"
mkdir -p backups

docker compose exec -T postgres \
    pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip \
    > "backups/db-$stamp.sql.gz"

docker run --rm \
    -v voxnica_vds_seaweeddata:/data:ro \
    -v "$PWD/backups":/backup \
    alpine:3.22 \
    tar czf "/backup/storage-$stamp.tar.gz" -C /data .

find backups -type f -mtime +7 -delete

echo "готово: backups/db-$stamp.sql.gz и storage-$stamp.tar.gz"
