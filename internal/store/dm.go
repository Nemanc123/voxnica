package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// DMChannel — личный канал вместе с получателями.
// Отдельный тип, потому что у DM нет guild_id и прав по ролям.
// LastMessage — последнее сообщение канала для списка диалогов.
type LastMessage struct {
	ID             string
	AuthorID       *string
	Content        string
	CreatedAt      time.Time
	HasAttachments bool
}

type DMChannel struct {
	ID          string
	Type        string
	Name        *string
	CreatedAt   time.Time
	Recipients  []User
	LastMessage *LastMessage
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
		SELECT c.id::text, c.type, c.name, c.created_at,
		       u.id::text, u.username::text, u.display_name,
		       lm.id::text, lm.author_id::text, lm.content, lm.created_at,
		       coalesce(lm.has_attachments, false)
		  FROM channels c
		  JOIN channel_recipients me ON me.channel_id = c.id AND me.user_id = $1::uuid
		  JOIN channel_recipients r  ON r.channel_id = c.id
		  JOIN users u               ON u.id = r.user_id
		  LEFT JOIN LATERAL (
		       SELECT m.id, m.author_id, m.content, m.created_at,
		              EXISTS (
		                  SELECT 1 FROM attachments a WHERE a.message_id = m.id
		              ) AS has_attachments
		         FROM messages m
		        WHERE m.channel_id = c.id AND m.deleted_at IS NULL
		        ORDER BY m.seq DESC
		        LIMIT 1
		  ) lm ON true
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
		var channelName *string
		var createdAt time.Time
		var u User
		var lmID, lmAuthor, lmContent pgtype.Text
		var lmCreated pgtype.Timestamptz
		var lmHas bool
		if err := rows.Scan(&channelID, &channelType, &channelName, &createdAt,
			&u.ID, &u.Username, &u.DisplayName,
			&lmID, &lmAuthor, &lmContent, &lmCreated, &lmHas); err != nil {
			return nil, fmt.Errorf("чтение личного канала: %w", err)
		}

		ch, ok := byID[channelID]
		if !ok {
			ch = &DMChannel{
				ID:        channelID,
				Type:      channelType,
				Name:      channelName,
				CreatedAt: createdAt,
			}
			if lmID.Valid {
				lm := &LastMessage{
					ID:             lmID.String,
					Content:        lmContent.String,
					CreatedAt:      lmCreated.Time,
					HasAttachments: lmHas,
				}
				if lmAuthor.Valid {
					author := lmAuthor.String
					lm.AuthorID = &author
				}
				ch.LastMessage = lm
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

// UsersShareGuild удалена 19.11.2026: правило «писать только с общим
// сервером» отменено, личка доступна любому (кроме заблокировавших).
