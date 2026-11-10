package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// DMChannel — личный канал вместе с получателями.
// Отдельный тип, потому что у DM нет guild_id и прав по ролям.
type DMChannel struct {
	ID         string
	Type       string
	CreatedAt  time.Time
	Recipients []User
}

// CreateDM возвращает существующий личный канал для ключа или создаёт новый.
//
// Ключ детерминированный (отсортированные user_id), поэтому повторный вызов
// для той же пары возвращает тот же канал. Вставка получателей идемпотентна:
// гонка двух создателей не ломает данные.
func (s *Store) CreateDM(ctx context.Context, key string, userIDs []string) (DMChannel, error) {
	const query = `
		WITH inserted AS (
			INSERT INTO channels (guild_id, type, dm_key)
			VALUES (NULL, 'dm', $1)
			ON CONFLICT (dm_key) WHERE dm_key IS NOT NULL DO NOTHING
			RETURNING id, type, created_at
		), chosen AS (
			SELECT id, type, created_at FROM inserted
			UNION ALL
			SELECT id, type, created_at FROM channels
			 WHERE dm_key = $1 AND deleted_at IS NULL
			LIMIT 1
		), rec AS (
			INSERT INTO channel_recipients (channel_id, user_id)
			SELECT chosen.id, u FROM chosen, unnest($2::uuid[]) AS u
			ON CONFLICT DO NOTHING
		)
		SELECT id::text, type, created_at FROM chosen`

	var ch DMChannel
	if err := s.db.QueryRow(ctx, query, key, userIDs).
		Scan(&ch.ID, &ch.Type, &ch.CreatedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return DMChannel{}, ErrChannelNotFound
		}
		return DMChannel{}, fmt.Errorf("создание личного канала: %w", err)
	}

	recipients, err := s.ChannelRecipients(ctx, ch.ID)
	if err != nil {
		return DMChannel{}, err
	}
	ch.Recipients = recipients

	return ch, nil
}

// ChannelRecipients — участники личного канала с именами.
func (s *Store) ChannelRecipients(ctx context.Context, channelID string) ([]User, error) {
	const query = `
		SELECT u.id::text, u.username::text, u.display_name
		  FROM channel_recipients r
		  JOIN users u ON u.id = r.user_id
		 WHERE r.channel_id = $1::uuid AND u.deleted_at IS NULL
		 ORDER BY u.username`

	rows, err := s.db.Query(ctx, query, channelID)
	if err != nil {
		return nil, fmt.Errorf("получатели канала: %w", err)
	}
	defer rows.Close()

	var out []User
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.Username, &u.DisplayName); err != nil {
			return nil, fmt.Errorf("чтение получателя: %w", err)
		}
		out = append(out, u)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("получатели канала: %w", err)
	}
	return out, nil
}

// UserDMChannels — личные каналы пользователя с получателями.
func (s *Store) UserDMChannels(ctx context.Context, userID string) ([]DMChannel, error) {
	const query = `
		SELECT c.id::text, c.type, c.created_at,
		       u.id::text, u.username::text, u.display_name
		  FROM channels c
		  JOIN channel_recipients me ON me.channel_id = c.id AND me.user_id = $1::uuid
		  JOIN channel_recipients r  ON r.channel_id = c.id
		  JOIN users u               ON u.id = r.user_id
		 WHERE c.deleted_at IS NULL AND c.guild_id IS NULL
		   AND c.type IN ('dm', 'group_dm')
		 ORDER BY c.created_at DESC, u.username`

	rows, err := s.db.Query(ctx, query, userID)
	if err != nil {
		return nil, fmt.Errorf("личные каналы: %w", err)
	}
	defer rows.Close()

	byID := make(map[string]*DMChannel)
	var order []string
	for rows.Next() {
		var channelID, channelType string
		var createdAt time.Time
		var u User
		if err := rows.Scan(&channelID, &channelType, &createdAt,
			&u.ID, &u.Username, &u.DisplayName); err != nil {
			return nil, fmt.Errorf("чтение личного канала: %w", err)
		}

		ch, ok := byID[channelID]
		if !ok {
			ch = &DMChannel{
				ID:        channelID,
				Type:      channelType,
				CreatedAt: createdAt,
			}
			byID[channelID] = ch
			order = append(order, channelID)
		}
		ch.Recipients = append(ch.Recipients, u)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("личные каналы: %w", err)
	}

	out := make([]DMChannel, 0, len(order))
	for _, id := range order {
		out = append(out, *byID[id])
	}
	return out, nil
}

// IsChannelRecipient — состоит ли пользователь в личном канале.
func (s *Store) IsChannelRecipient(ctx context.Context, channelID, userID string) (bool, error) {
	const query = `
		SELECT EXISTS (
			SELECT 1 FROM channel_recipients
			 WHERE channel_id = $1::uuid AND user_id = $2::uuid
		)`

	var ok bool
	if err := s.db.QueryRow(ctx, query, channelID, userID).Scan(&ok); err != nil {
		return false, fmt.Errorf("проверка получателя: %w", err)
	}
	return ok, nil
}

// ChannelRecipientIDs — только идентификаторы: нужны для адресной доставки.
func (s *Store) ChannelRecipientIDs(ctx context.Context, channelID string) ([]string, error) {
	const query = `SELECT user_id::text FROM channel_recipients WHERE channel_id = $1::uuid`

	rows, err := s.db.Query(ctx, query, channelID)
	if err != nil {
		return nil, fmt.Errorf("идентификаторы получателей: %w", err)
	}
	defer rows.Close()

	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("чтение получателя: %w", err)
		}
		out = append(out, id)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("идентификаторы получателей: %w", err)
	}
	return out, nil
}

// UsersShareGuild — есть ли у двух пользователей общий сервер.
// Правило: писать в личку можно только тем, с кем уже есть общий сервер.
func (s *Store) UsersShareGuild(ctx context.Context, userA, userB string) (bool, error) {
	const query = `
		SELECT EXISTS (
			SELECT 1
			  FROM guild_members a
			  JOIN guild_members b USING (guild_id)
			 WHERE a.user_id = $1::uuid AND b.user_id = $2::uuid
		)`

	var ok bool
	if err := s.db.QueryRow(ctx, query, userA, userB).Scan(&ok); err != nil {
		return false, fmt.Errorf("общий сервер: %w", err)
	}
	return ok, nil
}
