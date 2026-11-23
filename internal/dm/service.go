// Package dm — личные каналы: диалоги 1:1 и группы (group_dm).
//
// Правила 1:1: канал один на пару, ключ детерминированный, войти может
// только получатель. Группы создаются явно, до 10 участников; любой
// участник может добавлять, удалять и переименовывать. Роли и
// переопределения каналов здесь не работают — в личном канале их нет.
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
	ErrNotFound   = errors.New("не найдено")
)

// Publisher — адресная доставка событий личных каналов. Реализуют хаб и
// fan-out; интерфейс отдельный, чтобы тесты могли его не иметь.
type Publisher interface {
	PublishToUsers(ctx context.Context, userIDs []string, eventType string, data any)
}

type Service struct {
	store *store.Store
	pub   Publisher
}

func NewService(st *store.Store) *Service {
	return &Service{store: st}
}

// SetPublisher включает события личных каналов (создание группы, участники,
// переименование). Без него сервис работает молча.
func (s *Service) SetPublisher(p Publisher) { s.pub = p }

func (s *Service) notify(ctx context.Context, userIDs []string, eventType string, data any) {
	if s.pub == nil || len(userIDs) == 0 {
		return
	}
	s.pub.PublishToUsers(ctx, userIDs, eventType, data)
}

// Participant — собеседник в личном канале.
type Participant struct {
	UserID      string  `json:"user_id"`
	Username    string  `json:"username"`
	DisplayName *string `json:"display_name,omitempty"`
}

// LastMessage — превью последнего сообщения для списка диалогов.
type LastMessage struct {
	ID             string    `json:"id"`
	AuthorID       *string   `json:"author_id,omitempty"`
	Content        string    `json:"content"`
	CreatedAt      time.Time `json:"created_at"`
	HasAttachments bool      `json:"has_attachments"`
}

// Channel — личный канал в том виде, в каком его видит клиент.
type Channel struct {
	ID          string        `json:"id"`
	Type        string        `json:"type"`
	Name        *string       `json:"name,omitempty"`
	CreatedAt   time.Time     `json:"created_at"`
	Recipients  []Participant `json:"recipients"`
	LastMessage *LastMessage  `json:"last_message,omitempty"`
}

// Open возвращает личный канал с пользователем recipientID, создавая его
// при необходимости.
//
// Писать можно любому зарегистрированному пользователю — без дружбы и без
// общего сервера, как в Discord: человек находится поиском и сразу получает
// диалог. Единственное ограничение — блокировка: если кто-то из двоих
// заблокировал другого, диалог не открывается, и причина не раскрывается.
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

	blocked, err := s.store.BlockedEither(ctx, actorID, recipient.ID)
	if err != nil {
		return Channel{}, err
	}
	if blocked {
		// Тот же нейтральный ответ, что и при заявке в друзья.
		return Channel{}, fmt.Errorf("%w: действие недоступно", ErrForbidden)
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
// и какие права ему там доступны. ok=false — пользователь не получатель,
// канал не личный или кто-то из участников заблокировал другого.
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

	// Блокировка закрывает уже существующий диалог 1:1: без этой проверки
	// заблокированный продолжал бы писать и звонить в старую переписку
	// (нашло ревью 19.11.2026). На группы блокировка не распространяется:
	// иначе один конфликт двух участников закрыл бы канал всем.
	if channel.Type == "dm" {
		recipients, err := s.store.ChannelRecipientIDs(ctx, channelID)
		if err != nil {
			return 0, false, err
		}
		for _, other := range recipients {
			if other == userID {
				continue
			}
			blocked, err := s.store.BlockedEither(ctx, userID, other)
			if err != nil {
				return 0, false, err
			}
			if blocked {
				return 0, false, nil
			}
		}
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
		ID:          ch.ID,
		Type:        ch.Type,
		Name:        ch.Name,
		CreatedAt:   ch.CreatedAt,
		Recipients:  recipients,
		LastMessage: toLastMessage(ch.LastMessage),
	}
}

func toLastMessage(lm *store.LastMessage) *LastMessage {
	if lm == nil {
		return nil
	}
	return &LastMessage{
		ID:             lm.ID,
		AuthorID:       lm.AuthorID,
		Content:        lm.Content,
		CreatedAt:      lm.CreatedAt,
		HasAttachments: lm.HasAttachments,
	}
}
