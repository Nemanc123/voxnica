package store

import (
	"context"
	"fmt"
	"time"
)

// Member — участник сервера с данными пользователя.
type Member struct {
	UserID      string
	Username    string
	DisplayName *string
	Nickname    *string
	JoinedAt    time.Time
}

// MembersForGuild отдаёт участников в порядке вступления.
func (s *Store) MembersForGuild(ctx context.Context, guildID string) ([]Member, error) {
	const query = `
		SELECT gm.user_id::text, u.username, u.display_name, gm.nickname, gm.joined_at
		  FROM guild_members gm
		  JOIN users u ON u.id = gm.user_id
		 WHERE gm.guild_id = $1::uuid
		 ORDER BY gm.joined_at`

	rows, err := s.db.Query(ctx, query, guildID)
	if err != nil {
		return nil, fmt.Errorf("участники сервера: %w", err)
	}
	defer rows.Close()

	out := make([]Member, 0, 8)
	for rows.Next() {
		var m Member
		if err := rows.Scan(
			&m.UserID, &m.Username, &m.DisplayName, &m.Nickname, &m.JoinedAt,
		); err != nil {
			return nil, fmt.Errorf("чтение участника: %w", err)
		}
		out = append(out, m)
	}

	return out, rows.Err()
}
