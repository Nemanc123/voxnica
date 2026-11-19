-- 003. Блокировка запоминает, кем люди были до неё.
--
-- Зачем: по решению пользователя 20.11.2026 снятие блокировки возвращает
-- дружбу, если она была. Для этого нужно помнить прежний тип связи: сама
-- строка при блокировке превращается в 'blocked', а обратная удаляется.
--
-- Колонка уже есть в db/001_init.sql для чистых установок. Здесь — для баз,
-- созданных до этого изменения.
--
-- Применить:
--   psql "$DATABASE_URL" -f db/003_block_prev.sql
--
-- Откат (потеряется только память о прежней дружбе, сами связи и сообщения
-- останутся):
--   ALTER TABLE relationships DROP COLUMN blocked_prev;

ALTER TABLE relationships
    ADD COLUMN IF NOT EXISTS blocked_prev text;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'relationships'::regclass
           AND conname = 'relationships_blocked_prev_check'
    ) THEN
        ALTER TABLE relationships
            ADD CONSTRAINT relationships_blocked_prev_check
            CHECK (blocked_prev IS NULL OR blocked_prev IN ('friend','pending_out','pending_in'));
    END IF;
END $$;
