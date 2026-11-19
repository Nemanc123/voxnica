-- 002. Дефис в логине (19.11.2026).
--
-- Причина: текст ошибки обещал дефис, а CHECK его не разрешал. Решено
-- разрешить — `nemanc-1` теперь допустимый логин.
--
-- Применять на существующей базе один раз:
--   psql -U dc -d voxnica < db/002_username_hyphen.sql
--
-- Для чистой базы правило уже записано в 001_init.sql, этот файл не нужен.

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_username_format;

ALTER TABLE users
    ADD CONSTRAINT users_username_format
    CHECK (username::text ~ '^[a-z0-9_.-]{2,32}$');
