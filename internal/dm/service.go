// Package dm — личные каналы: создать, показать, проверить доступ.
//
// Правила простые: канал один на пару пользователей, ключ детерминированный,
// войти может только получатель. Роли и переопределения каналов здесь не
// работают — в личном канале их просто нет.
package dm

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/Nemanc123/voxnica/internal/perms"
	"github.com/Nemanc123/voxnica/internal/store"
)

var (
	ErrValidation = errors.New("неверные данные")
	ErrForbidden  = errors.New("нет доступа")
)

type Service struct {
	store *store.Store
}

func NewService(st *store.Store) *Service {
	return &Service{store: st}
}

// Participant — собеседник в личном канале.
type Participant struct {
	UserID      string  `json:"user_id"`
	Username    string  `json:"username"`
	DisplayName *string `json:"display_name,omitempty"`
}

// Channel — личный канал в том виде, в каком его видит клиент.
type Channel struct {
	ID         string        `json:"id"`
	Type       string        `json:"type"`
	CreatedAt  time.Time     `json:"created_at"`
	Recipients []Participant `json:"recipients"`
}

// Open возвращает личный канал с пользователем recipientID, создавая его
// при необходимости.
//
// Ограничение: личный канал доступен только тем, у кого есть общий сервер.
// Иначе любой мог бы писать незнакомым людям по username.
func (s *Service) Open(ctx context.Context, actorID, recipientID string) (Channel, error) {
	if recipientID == "" {
		return Channel{}, fmt.Errorf("%w: нужен user_id получателя", ErrValidation)
	}
	if actorID == recipientID {
		return Channel{}, fmt.Errorf("%w: нельзя открыть личный канал с собой", ErrValidation)
	}

	recipient, err := s.store.UserByID(ctx, recipientID)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return Channel{}, fmt.Errorf("%w: пользователь не найден", ErrValidation)
		}
		return Channel{}, err
	}

	shared, err := s.store.UsersShareGuild(ctx, actorID, recipient.ID)
	if err != nil {
		return Channel{}, err
	}
	if !shared {
		return Channel{}, fmt.Errorf("%w: нужен общий сервер", ErrForbidden)
	}

	key := pairKey(actorID, recipient.ID)
	ch, err := s.store.CreateDM(ctx, key, []string{actorID, recipient.ID})
	if err != nil {
		return Channel{}, err
	}

	return toView(ch), nil
}

// List — личные каналы пользователя, новые сверху.
func (s *Service) List(ctx context.Context, userID string) ([]Channel, error) {
	channels, err := s.store.UserDMChannels(ctx, userID)
	if err != nil {
		return nil, err
	}

	out := make([]Channel, 0, len(channels))
	for _, ch := range channels {
		out = append(out, toView(ch))
	}
	return out, nil
}

// Access сообщает, может ли пользователь работать с личным каналом,
// и какие права ему там доступны. ok=false — пользователь не получатель
// или канал не личный.
func (s *Service) Access(ctx context.Context, userID, channelID string) (perms.Permission, bool, error) {
	channel, err := s.store.ChannelByID(ctx, channelID)
	if err != nil {
		return 0, false, err
	}
	if channel.GuildID != nil || (channel.Type != "dm" && channel.Type != "group_dm") {
		return 0, false, nil
	}

	member, err := s.store.IsChannelRecipient(ctx, channelID, userID)
	if err != nil {
		return 0, false, err
	}
	if !member {
		return 0, false, nil
	}

	return perms.DMDefault, true, nil
}

// RecipientIDs — кому доставлять события личного канала.
func (s *Service) RecipientIDs(ctx context.Context, channelID string) ([]string, error) {
	return s.store.ChannelRecipientIDs(ctx, channelID)
}

// pairKey — детерминированный ключ пары: порядок аргументов не важен,
// поэтому один и тот же диалог не дублируется.
func pairKey(a, b string) string {
	ids := []string{a, b}
	sort.Strings(ids)
	return strings.Join(ids, ":")
}

func toView(ch store.DMChannel) Channel {
	recipients := make([]Participant, 0, len(ch.Recipients))
	for _, u := range ch.Recipients {
		recipients = append(recipients, Participant{
			UserID:      u.ID,
			Username:    u.Username,
			DisplayName: u.DisplayName,
		})
	}

	return Channel{
		ID:         ch.ID,
		Type:       ch.Type,
		CreatedAt:  ch.CreatedAt,
		Recipients: recipients,
	}
}
