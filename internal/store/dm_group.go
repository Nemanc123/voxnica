package store

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// DMChannelByID возвращает личный канал (dm или group_dm) с участниками.
func (s *Store) DMChannelByID(ctx context.Context, id string) (DMChannel, error) {
	const query = `
		SELECT id::text, type, name, created_at
		  FROM channels
		 WHERE id = $1::uuid AND guild_id IS NULL
		   AND type IN ('dm', 'group_dm') AND deleted_at IS NULL`

	var ch DMChannel
	if err := s.db.QueryRow(ctx, query, id).
		Scan(&ch.ID, &ch.Type, &ch.Name, &ch.CreatedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return DMChannel{}, ErrChannelNotFound
		}
		return DMChannel{}, fmt.Errorf("личный канал: %w", err)
	}

	recipients, err := s.ChannelRecipients(ctx, ch.ID)
	if err != nil {
		return DMChannel{}, err
	}
	ch.Recipients = recipients
	return ch, nil
}

// CreateGroup создаёт групповой личный канал (group_dm) и сразу добавляет
// всех участников.
//
// dm_key остаётся NULL: уникальность нужна только парам 1:1, а групп с
// одинаковым составом может быть сколько угодно.
func (s *Store) CreateGroup(ctx context.Context, name *string, userIDs []string) (DMChannel, error) {
	const query = `
		WITH ch AS (
			INSERT INTO channels (guild_id, type, name)
			VALUES (NULL, 'group_dm', $1)
			RETURNING id, type, name, created_at
		), rec AS (
			INSERT INTO channel_recipients (channel_id, user_id)
			SELECT ch.id, u FROM ch, unnest($2::uuid[]) AS u
			ON CONFLICT DO NOTHING
		)
		SELECT id::text, type, name, created_at FROM ch`

	var ch DMChannel
	if err := s.db.QueryRow(ctx, query, name, userIDs).
		Scan(&ch.ID, &ch.Type, &ch.Name, &ch.CreatedAt); err != nil {
		return DMChannel{}, fmt.Errorf("создание группы: %w", err)
	}

	recipients, err := s.ChannelRecipients(ctx, ch.ID)
	if err != nil {
		return DMChannel{}, err
	}
	ch.Recipients = recipients

	return ch, nil
}

// AddChannelRecipient добавляет участника в группу.
//
// Лимит проверяется под блокировкой строки канала: два одновременных
// добавления не смогут переполнить группу. Возвращает:
//   - added — участник добавлен;
//   - count — сколько участников было до добавления;
//   - found — канал существует, не удалён и является группой.
func (s *Store) AddChannelRecipient(
	ctx context.Context, channelID, userID string, limit int,
) (added bool, count int, found bool, err error) {
	const query = `
		WITH locked AS (
			SELECT id FROM channels
			 WHERE id = $1::uuid AND type = 'group_dm' AND deleted_at IS NULL
			 FOR UPDATE
		), current AS (
			SELECT count(*) AS n
			  FROM channel_recipients
			 WHERE channel_id = $1::uuid
			   AND EXISTS (SELECT 1 FROM locked)
		), ins AS (
			INSERT INTO channel_recipients (channel_id, user_id)
			SELECT $1::uuid, $2::uuid
			 WHERE (SELECT n FROM current) < $3
			ON CONFLICT DO NOTHING
			RETURNING 1
		)
		SELECT EXISTS(SELECT 1 FROM ins),
		       coalesce((SELECT n FROM current), 0),
		       EXISTS(SELECT 1 FROM locked)`

	if err := s.db.QueryRow(ctx, query, channelID, userID, limit).
		Scan(&added, &count, &found); err != nil {
		return false, 0, false, fmt.Errorf("добавление участника группы: %w", err)
	}
	return added, count, found, nil
}

// RemoveChannelRecipient удаляет участника и возвращает, сколько осталось.
func (s *Store) RemoveChannelRecipient(
	ctx context.Context, channelID, userID string,
) (removed bool, remaining int, err error) {
	tag, err := s.db.Exec(ctx, `
		DELETE FROM channel_recipients
		 WHERE channel_id = $1::uuid AND user_id = $2::uuid`,
		channelID, userID)
	if err != nil {
		return false, 0, fmt.Errorf("удаление участника группы: %w", err)
	}

	if err := s.db.QueryRow(ctx,
		`SELECT count(*) FROM channel_recipients WHERE channel_id = $1::uuid`,
		channelID).Scan(&remaining); err != nil {
		return false, 0, fmt.Errorf("подсчёт участников группы: %w", err)
	}

	return tag.RowsAffected() > 0, remaining, nil
}

// RenameGroup переименовывает группу. nil — вернуть имя по умолчанию
// (клиент показывает список участников).
func (s *Store) RenameGroup(
	ctx context.Context, channelID string, name *string,
) (bool, error) {
	tag, err := s.db.Exec(ctx, `
		UPDATE channels
		   SET name = $2, updated_at = now()
		 WHERE id = $1::uuid AND type = 'group_dm' AND deleted_at IS NULL`,
		channelID, name)
	if err != nil {
		return false, fmt.Errorf("переименование группы: %w", err)
	}
	return tag.RowsAffected() > 0, nil
}

// SoftDeleteChannel помечает канал удалённым. Сообщения и участники
// остаются в базе: история не уничтожается.
func (s *Store) SoftDeleteChannel(ctx context.Context, channelID string) error {
	if _, err := s.db.Exec(ctx, `
		UPDATE channels
		   SET deleted_at = now(), updated_at = now()
		 WHERE id = $1::uuid AND deleted_at IS NULL`,
		channelID); err != nil {
		return fmt.Errorf("удаление канала: %w", err)
	}
	return nil
}
