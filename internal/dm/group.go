package dm

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"

	"github.com/Nemanc123/voxnica/internal/store"
)

const (
	// MinGroupParticipants — группа начинается с трёх человек: двое — это
	// обычный диалог 1:1.
	MinGroupParticipants = 3
	// MaxGroupParticipants — как в Discord.
	MaxGroupParticipants = 10
	// MaxGroupNameRunes — ограничение схемы (char_length(name) <= 100).
	MaxGroupNameRunes = 100
)

// CreateGroup создаёт групповой диалог.
//
// Дефолты (решение 20.11.2026): до 10 участников, имя можно менять,
// любой участник может добавлять и удалять, блокировка внутри группы
// не влияет на доступ, но заблокированного нельзя добавить.
func (s *Service) CreateGroup(
	ctx context.Context, actorID string, recipientIDs []string, name *string,
) (Channel, error) {
	if _, err := uuid.Parse(actorID); err != nil {
		return Channel{}, fmt.Errorf("%w: неверный идентификатор пользователя", ErrValidation)
	}

	others, err := normalizeRecipients(actorID, recipientIDs)
	if err != nil {
		return Channel{}, err
	}
	total := len(others) + 1
	if total < MinGroupParticipants || total > MaxGroupParticipants {
		return Channel{}, fmt.Errorf(
			"%w: в группе должно быть от %d до %d участников",
			ErrValidation, MinGroupParticipants, MaxGroupParticipants)
	}

	for _, id := range others {
		if err := s.checkCanAdd(ctx, actorID, id); err != nil {
			return Channel{}, err
		}
	}
	// Участники не должны быть в блокировке друг с другом: иначе группа
	// соберётся, но кто-то из неё сразу не сможет писать.
	for i := 0; i < len(others); i++ {
		for j := i + 1; j < len(others); j++ {
			blocked, err := s.store.BlockedEither(ctx, others[i], others[j])
			if err != nil {
				return Channel{}, err
			}
			if blocked {
				return Channel{}, fmt.Errorf("%w: действие недоступно", ErrForbidden)
			}
		}
	}

	cleanName, err := normalizeGroupName(name)
	if err != nil {
		return Channel{}, err
	}

	all := make([]string, 0, total)
	all = append(all, actorID)
	all = append(all, others...)

	ch, err := s.store.CreateGroup(ctx, cleanName, all)
	if err != nil {
		return Channel{}, err
	}

	view := toView(ch)
	s.notify(ctx, all, "DM_CHANNEL_CREATE", map[string]any{"channel": view})
	return view, nil
}

// AddRecipient добавляет человека в группу. Любой участник может это делать,
// пока не достигнут лимит.
func (s *Service) AddRecipient(
	ctx context.Context, actorID, channelID, userID string,
) (Channel, error) {
	ch, err := s.groupFor(ctx, actorID, channelID)
	if err != nil {
		return Channel{}, err
	}

	if _, err := uuid.Parse(userID); err != nil {
		return Channel{}, fmt.Errorf("%w: неверный идентификатор пользователя", ErrValidation)
	}
	if userID == actorID {
		return Channel{}, fmt.Errorf("%w: вы уже в группе", ErrValidation)
	}

	already := false
	for _, r := range ch.Recipients {
		if r.ID == userID {
			already = true
			break
		}
	}
	if already {
		return toView(ch), nil
	}

	// Блокировка: нельзя добавить того, кто в конфликте с кем-то из группы.
	for _, r := range ch.Recipients {
		blocked, err := s.store.BlockedEither(ctx, userID, r.ID)
		if err != nil {
			return Channel{}, err
		}
		if blocked {
			return Channel{}, fmt.Errorf("%w: действие недоступно", ErrForbidden)
		}
	}
	if err := s.checkCanAdd(ctx, actorID, userID); err != nil {
		return Channel{}, err
	}

	added, count, found, err := s.store.AddChannelRecipient(
		ctx, channelID, userID, MaxGroupParticipants)
	if err != nil {
		return Channel{}, err
	}
	if !found {
		return Channel{}, fmt.Errorf("%w: группа не найдена", ErrNotFound)
	}
	if !added && count >= MaxGroupParticipants {
		return Channel{}, fmt.Errorf(
			"%w: в группе уже %d участников", ErrValidation, MaxGroupParticipants)
	}

	updated, err := s.store.DMChannelByID(ctx, channelID)
	if err != nil {
		return Channel{}, err
	}
	view := toView(updated)
	ids := participantIDs(updated)
	s.notify(ctx, ids, "DM_CHANNEL_UPDATE", map[string]any{"channel": view})
	return view, nil
}

// RemoveRecipient убирает участника. Себя — «выйти», другого — «исключить»;
// по дефолту это может любой участник.
//
// Когда уходит последний, канал помечается удалённым (история остаётся в БД).
func (s *Service) RemoveRecipient(
	ctx context.Context, actorID, channelID, userID string,
) error {
	ch, err := s.groupFor(ctx, actorID, channelID)
	if err != nil {
		return err
	}

	if _, err := uuid.Parse(userID); err != nil {
		return fmt.Errorf("%w: неверный идентификатор пользователя", ErrValidation)
	}

	member := false
	for _, r := range ch.Recipients {
		if r.ID == userID {
			member = true
			break
		}
	}
	if !member {
		return fmt.Errorf("%w: участник не найден", ErrNotFound)
	}

	removed, remaining, err := s.store.RemoveChannelRecipient(ctx, channelID, userID)
	if err != nil {
		return err
	}
	if !removed {
		return fmt.Errorf("%w: участник не найден", ErrNotFound)
	}

	s.notify(ctx, []string{userID}, "DM_CHANNEL_REMOVE",
		map[string]any{"channel_id": channelID})

	if remaining == 0 {
		if err := s.store.SoftDeleteChannel(ctx, channelID); err != nil {
			return err
		}
		return nil
	}

	updated, err := s.store.DMChannelByID(ctx, channelID)
	if err != nil {
		return err
	}
	view := toView(updated)
	s.notify(ctx, participantIDs(updated), "DM_CHANNEL_UPDATE",
		map[string]any{"channel": view})
	return nil
}

// Rename задаёт имя группы. nil или пустая строка — вернуть имя по умолчанию
// (клиент показывает список участников).
func (s *Service) Rename(
	ctx context.Context, actorID, channelID string, name *string,
) (Channel, error) {
	if _, err := s.groupFor(ctx, actorID, channelID); err != nil {
		return Channel{}, err
	}

	cleanName, err := normalizeGroupName(name)
	if err != nil {
		return Channel{}, err
	}

	ok, err := s.store.RenameGroup(ctx, channelID, cleanName)
	if err != nil {
		return Channel{}, err
	}
	if !ok {
		return Channel{}, fmt.Errorf("%w: группа не найдена", ErrNotFound)
	}

	updated, err := s.store.DMChannelByID(ctx, channelID)
	if err != nil {
		return Channel{}, err
	}
	view := toView(updated)
	s.notify(ctx, participantIDs(updated), "DM_CHANNEL_UPDATE",
		map[string]any{"channel": view})
	return view, nil
}

// groupFor проверяет, что канал — существующая группа, а пользователь в ней.
func (s *Service) groupFor(
	ctx context.Context, userID, channelID string,
) (store.DMChannel, error) {
	if _, err := uuid.Parse(channelID); err != nil {
		return store.DMChannel{}, fmt.Errorf(
			"%w: неверный идентификатор канала", ErrValidation)
	}

	ch, err := s.store.DMChannelByID(ctx, channelID)
	if err != nil {
		if errors.Is(err, store.ErrChannelNotFound) {
			return store.DMChannel{}, fmt.Errorf("%w: канал не найден", ErrNotFound)
		}
		return store.DMChannel{}, err
	}
	if ch.Type != "group_dm" {
		return store.DMChannel{}, fmt.Errorf("%w: это не группа", ErrValidation)
	}

	for _, r := range ch.Recipients {
		if r.ID == userID {
			return ch, nil
		}
	}
	return store.DMChannel{}, fmt.Errorf("%w: вы не участник группы", ErrForbidden)
}

// checkCanAdd: пользователь существует и не заблокирован с actor.
func (s *Service) checkCanAdd(ctx context.Context, actorID, userID string) error {
	if _, err := s.store.UserByID(ctx, userID); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return fmt.Errorf("%w: пользователь не найден", ErrValidation)
		}
		return err
	}
	blocked, err := s.store.BlockedEither(ctx, actorID, userID)
	if err != nil {
		return err
	}
	if blocked {
		return fmt.Errorf("%w: действие недоступно", ErrForbidden)
	}
	return nil
}

// normalizeRecipients очищает список: убирает пустые, повторы и самого
// создателя. Порядок сохраняется.
func normalizeRecipients(actorID string, ids []string) ([]string, error) {
	seen := make(map[string]struct{}, len(ids))
	out := make([]string, 0, len(ids))
	for _, raw := range ids {
		id := strings.TrimSpace(raw)
		if id == "" || id == actorID {
			continue
		}
		if _, err := uuid.Parse(id); err != nil {
			return nil, fmt.Errorf("%w: неверный идентификатор участника", ErrValidation)
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		out = append(out, id)
	}
	return out, nil
}

func normalizeGroupName(name *string) (*string, error) {
	if name == nil {
		return nil, nil
	}
	clean := strings.TrimSpace(*name)
	if clean == "" {
		return nil, nil
	}
	if utf8.RuneCountInString(clean) > MaxGroupNameRunes {
		return nil, fmt.Errorf(
			"%w: имя группы длиннее %d символов", ErrValidation, MaxGroupNameRunes)
	}
	return &clean, nil
}

func participantIDs(ch store.DMChannel) []string {
	out := make([]string, 0, len(ch.Recipients))
	for _, r := range ch.Recipients {
		out = append(out, r.ID)
	}
	return out
}
