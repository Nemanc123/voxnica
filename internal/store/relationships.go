package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// Типы связей в таблице relationships.
//
// Хранится по строке на направление: пара строк описывает одно отношение.
// Так «мои друзья» — это WHERE user_id = $1 AND type = 'friend', без OR
// и без сортировок; цена — две строки вместо одной.
const (
	RelationFriend     = "friend"
	RelationPendingOut = "pending_out"
	RelationPendingIn  = "pending_in"
	RelationBlocked    = "blocked"
)

// Relationship — связь пользователя с другим пользователем.
type Relationship struct {
	User      User
	Type      string
	CreatedAt time.Time
}

// Relationships возвращает все связи пользователя с именами собеседников.
func (s *Store) Relationships(ctx context.Context, userID string) ([]Relationship, error) {
	const query = `
		SELECT u.id::text, u.username::text, u.display_name, u.email::text,
		       u.password_hash, u.status, u.created_at,
		       r.type, r.created_at
		  FROM relationships r
		  JOIN users u ON u.id = r.target_id
		 WHERE r.user_id = $1::uuid AND u.deleted_at IS NULL
		 ORDER BY u.username`

	rows, err := s.db.Query(ctx, query, userID)
	if err != nil {
		return nil, fmt.Errorf("связи пользователя: %w", err)
	}
	defer rows.Close()

	out := make([]Relationship, 0, 8)
	for rows.Next() {
		var rel Relationship
		if err := rows.Scan(
			&rel.User.ID, &rel.User.Username, &rel.User.DisplayName, &rel.User.Email,
			&rel.User.PasswordHash, &rel.User.Status, &rel.User.CreatedAt,
			&rel.Type, &rel.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("чтение связи: %w", err)
		}
		out = append(out, rel)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("связи пользователя: %w", err)
	}

	return out, nil
}

// RelationType возвращает тип связи a → b или пустую строку, если связи нет.
func (s *Store) RelationType(ctx context.Context, a, b string) (string, error) {
	const query = `
		SELECT type FROM relationships
		 WHERE user_id = $1::uuid AND target_id = $2::uuid`

	var t string
	err := s.db.QueryRow(ctx, query, a, b).Scan(&t)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("тип связи: %w", err)
	}
	return t, nil
}

// RelationTypes возвращает типы связей actor → каждый из targets.
// Нужно для поиска: одним запросом вместо N.
func (s *Store) RelationTypes(ctx context.Context, actor string, targets []string) (map[string]string, error) {
	if len(targets) == 0 {
		return map[string]string{}, nil
	}

	const query = `
		SELECT target_id::text, type FROM relationships
		 WHERE user_id = $1::uuid AND target_id = ANY($2::uuid[])`

	rows, err := s.db.Query(ctx, query, actor, targets)
	if err != nil {
		return nil, fmt.Errorf("типы связей: %w", err)
	}
	defer rows.Close()

	out := make(map[string]string, len(targets))
	for rows.Next() {
		var id, t string
		if err := rows.Scan(&id, &t); err != nil {
			return nil, fmt.Errorf("чтение типа связи: %w", err)
		}
		out[id] = t
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("типы связей: %w", err)
	}

	return out, nil
}

// RequestFriend создаёт заявку в обе стороны.
//
// Оба INSERT идут одним запросом: либо появятся обе строки, либо ни одной.
// ON CONFLICT DO NOTHING — повторная заявка не ломает существующие связи;
// что именно уже есть, проверяет сервис до вызова.
func (s *Store) RequestFriend(ctx context.Context, from, to string) error {
	const query = `
		INSERT INTO relationships (user_id, target_id, type)
		VALUES ($1::uuid, $2::uuid, 'pending_out'),
		       ($2::uuid, $1::uuid, 'pending_in')
		ON CONFLICT (user_id, target_id) DO NOTHING`

	if _, err := s.db.Exec(ctx, query, from, to); err != nil {
		return fmt.Errorf("заявка в друзья: %w", err)
	}
	return nil
}

// AcceptFriend переводит обе строки пары в friend.
//
// Принимает только адресат заявки: у него строка pending_in, у отправителя —
// pending_out. Без этого условия отправитель мог бы «принять» собственную
// заявку и стать другом без согласия второй стороны (найдено ревью 19.11.2026).
//
// Возвращает false, если входящей заявки нет: обновлять нечего.
func (s *Store) AcceptFriend(ctx context.Context, actor, from string) (bool, error) {
	const query = `
		WITH updated AS (
			UPDATE relationships
			   SET type = 'friend'
			 WHERE (user_id = $1::uuid AND target_id = $2::uuid AND type = 'pending_in')
			    OR (user_id = $2::uuid AND target_id = $1::uuid AND type = 'pending_out')
			RETURNING 1
		)
		SELECT count(*) FROM updated`

	var n int
	if err := s.db.QueryRow(ctx, query, actor, from).Scan(&n); err != nil {
		return false, fmt.Errorf("принятие заявки: %w", err)
	}
	return n == 2, nil
}

// DeleteRelationshipPair удаляет обе строки пары: дружбу, заявку или отказ.
func (s *Store) DeleteRelationshipPair(ctx context.Context, a, b string) error {
	const query = `
		DELETE FROM relationships
		 WHERE user_id IN ($1::uuid, $2::uuid)
		   AND target_id IN ($1::uuid, $2::uuid)`

	if _, err := s.db.Exec(ctx, query, a, b); err != nil {
		return fmt.Errorf("удаление связи: %w", err)
	}
	return nil
}

// BlockUser ставит блокировку from → to и убирает обратную строку.
//
// Одним запросом: иначе между DELETE и INSERT остаётся окно, в котором
// заблокированный успевает отправить заявку.
func (s *Store) BlockUser(ctx context.Context, from, to string) error {
	const query = `
		WITH removed AS (
			DELETE FROM relationships
			 WHERE user_id = $2::uuid AND target_id = $1::uuid
		), blocked AS (
			INSERT INTO relationships (user_id, target_id, type)
			VALUES ($1::uuid, $2::uuid, 'blocked')
			ON CONFLICT (user_id, target_id)
			DO UPDATE SET type = 'blocked', created_at = now()
		)
		SELECT 1`

	if _, err := s.db.Exec(ctx, query, from, to); err != nil {
		return fmt.Errorf("блокировка: %w", err)
	}
	return nil
}

// UnblockUser снимает блокировку from → to. Дружба не восстанавливается.
func (s *Store) UnblockUser(ctx context.Context, from, to string) error {
	const query = `
		DELETE FROM relationships
		 WHERE user_id = $1::uuid AND target_id = $2::uuid AND type = 'blocked'`

	if _, err := s.db.Exec(ctx, query, from, to); err != nil {
		return fmt.Errorf("снятие блокировки: %w", err)
	}
	return nil
}

// BlockedEither сообщает, есть ли блокировка в любую сторону пары.
func (s *Store) BlockedEither(ctx context.Context, a, b string) (bool, error) {
	const query = `
		SELECT EXISTS (
			SELECT 1 FROM relationships
			 WHERE type = 'blocked'
			   AND ((user_id = $1::uuid AND target_id = $2::uuid)
			     OR (user_id = $2::uuid AND target_id = $1::uuid))
		)`

	var blocked bool
	if err := s.db.QueryRow(ctx, query, a, b).Scan(&blocked); err != nil {
		return false, fmt.Errorf("проверка блокировки: %w", err)
	}
	return blocked, nil
}

// SearchUsers ищет пользователей по логину или отображаемому имени.
//
// Не показывает: себя, удалённых и тех, кто заблокировал ищущего.
func (s *Store) SearchUsers(ctx context.Context, actor, query string, limit int) ([]User, error) {
	const sql = `
		SELECT u.id::text, u.username::text, u.display_name, u.email::text,
		       u.password_hash, u.status, u.created_at
		  FROM users u
		 WHERE u.deleted_at IS NULL
		   AND u.id <> $1::uuid
		   AND (u.username ILIKE '%' || $2 || '%'
		     OR coalesce(u.display_name, '') ILIKE '%' || $2 || '%')
		   AND NOT EXISTS (
				SELECT 1 FROM relationships r
				 WHERE r.user_id = u.id AND r.target_id = $1::uuid
				   AND r.type = 'blocked'
		   )
		 ORDER BY u.username
		 LIMIT $3`

	rows, err := s.db.Query(ctx, sql, actor, query, limit)
	if err != nil {
		return nil, fmt.Errorf("поиск пользователей: %w", err)
	}
	defer rows.Close()

	out := make([]User, 0, limit)
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.Username, &u.DisplayName, &u.Email,
			&u.PasswordHash, &u.Status, &u.CreatedAt); err != nil {
			return nil, fmt.Errorf("чтение пользователя: %w", err)
		}
		out = append(out, u)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("поиск пользователей: %w", err)
	}

	return out, nil
}
