-- 004. Бэкфилл отметок прочтения для личных диалогов.
--
-- Зачем: до 1.0.12 счётчики непрочитанных в DM жили только в памяти клиента,
-- и строк в read_states для личных каналов не было. После включения
-- серверного unread запрос считал бы непрочитанной ВСЮ историю диалога.
--
-- Миграция отмечает всё, что уже лежит в базе, прочитанным. Новые сообщения
-- после неё считаются как обычно. Схему не меняет.
--
-- Применить ДО пересборки API 1.0.13:
--   psql "$DATABASE_URL" -f db/004_read_states_backfill.sql
--
-- Повторный запуск безопасен (ON CONFLICT DO NOTHING).
-- Откат не требуется: строки корректны. Если нужно удалить именно
-- добавленные этой миграцией — см. комментарий в конце.

INSERT INTO read_states (user_id, channel_id, last_read_seq)
SELECT cr.user_id,
       cr.channel_id,
       COALESCE(MAX(m.seq), 0)
  FROM channel_recipients cr
  JOIN channels c ON c.id = cr.channel_id
  LEFT JOIN messages m
         ON m.channel_id = cr.channel_id
        AND m.deleted_at IS NULL
 WHERE c.type IN ('dm', 'group_dm')
   AND c.deleted_at IS NULL
 GROUP BY cr.user_id, cr.channel_id
ON CONFLICT (user_id, channel_id) DO NOTHING;

-- Проверка: для всех участников личных каналов должны появиться строки.
--   SELECT count(*) FROM channel_recipients cr
--    JOIN channels c ON c.id = cr.channel_id
--   WHERE c.type IN ('dm','group_dm')
--     AND NOT EXISTS (SELECT 1 FROM read_states rs
--                      WHERE rs.user_id = cr.user_id AND rs.channel_id = cr.channel_id);
--
-- Точечный откат (если действительно нужно «сбросить прочитанное»):
--   DELETE FROM read_states WHERE channel_id IN
--     (SELECT id FROM channels WHERE type IN ('dm','group_dm'));
