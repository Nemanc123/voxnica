// Package social — друзья, заявки и блокировки.
//
// Правила живут здесь, а не в HTTP-слое: API только разбирает запрос и
// переводит ошибки в коды. Так правила можно проверить тестами без сервера.
package social

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/Nemanc123/voxnica/internal/store"
)

var (
	ErrValidation     = errors.New("неверные данные")
	ErrNotFound       = errors.New("не найдено")
	ErrAlreadyFriends = errors.New("уже друзья")
	ErrAlreadyPending = errors.New("заявка уже отправлена")
	ErrBlocked        = errors.New("действие недоступно")
)

const (
	// maxSearchResults ограничивает выдачу поиска: это не каталог людей.
	maxSearchResults = 10
	minSearchRunes   = 2
	maxSearchRunes   = 32
)

type Service struct {
	store *store.Store

	// pub задаётся после старта: hub и fan-out создаются позже сервиса.
	// До установки события просто не отправляются — это не ошибка,
	// а режим тестов и одиночного процесса без Redis.
	pub UserPublisher
}

// UserPublisher — адресная доставка событий конкретным пользователям.
// Реализуют gateway.Hub и fanout.Publisher.
type UserPublisher interface {
	PublishToUsers(ctx context.Context, userIDs []string, eventType string, data any)
}

func NewService(st *store.Store) *Service {
	return &Service{store: st}
}

// SetPublisher включает живые события дружбы и присутствия.
func (s *Service) SetPublisher(pub UserPublisher) {
	s.pub = pub
}

// FriendIDs отдаёт идентификаторы друзей — нужно хабу для рассылки
// присутствия (интерфейс gateway.FriendIDsProvider).
func (s *Service) FriendIDs(ctx context.Context, userID string) ([]string, error) {
	rels, err := s.store.Relationships(ctx, userID)
	if err != nil {
		return nil, err
	}

	out := make([]string, 0, len(rels))
	for _, rel := range rels {
		if rel.Type == store.RelationFriend {
			out = append(out, rel.User.ID)
		}
	}
	return out, nil
}

// notify отправляет событие, если издатель подключён.
func (s *Service) notify(ctx context.Context, userIDs []string, eventType string, data any) {
	if s.pub == nil || len(userIDs) == 0 {
		return
	}
	s.pub.PublishToUsers(ctx, userIDs, eventType, data)
}

// userPayload — то, что нужно клиенту для отрисовки карточки.
func userPayload(u store.User) map[string]any {
	out := map[string]any{"id": u.ID, "username": u.Username}
	if u.DisplayName != nil && strings.TrimSpace(*u.DisplayName) != "" {
		out["display_name"] = *u.DisplayName
	}
	return out
}

// Entry — человек в списке связей и дата, когда связь появилась.
type Entry struct {
	User  store.User
	Since time.Time
}

// View — всё, что нужно экрану «Друзья» одним ответом.
type View struct {
	Friends  []Entry
	Incoming []Entry
	Outgoing []Entry
	Blocked  []Entry
}

// SearchResult — найденный пользователь и его отношение к ищущему.
type SearchResult struct {
	User     store.User
	Relation string // none | friend | incoming | outgoing | blocked
}

// List собирает связи пользователя по четырём корзинам.
func (s *Service) List(ctx context.Context, actor string) (View, error) {
	rels, err := s.store.Relationships(ctx, actor)
	if err != nil {
		return View{}, err
	}

	view := View{
		Friends:  make([]Entry, 0, len(rels)),
		Incoming: make([]Entry, 0, 4),
		Outgoing: make([]Entry, 0, 4),
		Blocked:  make([]Entry, 0, 2),
	}

	for _, rel := range rels {
		entry := Entry{User: rel.User, Since: rel.CreatedAt}
		switch rel.Type {
		case store.RelationFriend:
			view.Friends = append(view.Friends, entry)
		case store.RelationPendingIn:
			view.Incoming = append(view.Incoming, entry)
		case store.RelationPendingOut:
			view.Outgoing = append(view.Outgoing, entry)
		case store.RelationBlocked:
			view.Blocked = append(view.Blocked, entry)
		}
	}

	return view, nil
}

// SendRequest отправляет заявку в друзья.
//
// Входящая заявка от того же человека не ошибка «уже отправлено»: клиент
// по этому признаку предлагает её принять. Но и второй заявки не создаём.
func (s *Service) SendRequest(ctx context.Context, actor, target string) error {
	if target == "" {
		return fmt.Errorf("%w: нужен пользователь", ErrValidation)
	}
	if actor == target {
		return fmt.Errorf("%w: нельзя добавить себя", ErrValidation)
	}

	if _, err := s.store.UserByID(ctx, target); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return ErrNotFound
		}
		return err
	}

	blocked, err := s.store.BlockedEither(ctx, actor, target)
	if err != nil {
		return err
	}
	if blocked {
		// Ответ нейтральный: не раскрываем, кто кого заблокировал.
		return ErrBlocked
	}

	rel, err := s.store.RelationType(ctx, actor, target)
	if err != nil {
		return err
	}
	switch rel {
	case store.RelationFriend:
		return ErrAlreadyFriends
	case store.RelationPendingOut, store.RelationPendingIn:
		return ErrAlreadyPending
	}

	created, err := s.store.RequestFriend(ctx, actor, target)
	if err != nil {
		return err
	}
	if !created {
		// Между проверкой и вставка связь успела появиться (гонка).
		return ErrAlreadyPending
	}

	if actorUser, err := s.store.UserByID(ctx, actor); err == nil {
		s.notify(ctx, []string{target}, "FRIEND_REQUEST", map[string]any{
			"user": userPayload(actorUser),
		})
	}
	return nil
}

// Accept принимает входящую заявку.
func (s *Service) Accept(ctx context.Context, actor, from string) error {
	if from == "" || actor == from {
		return fmt.Errorf("%w: неверная пара пользователей", ErrValidation)
	}

	ok, err := s.store.AcceptFriend(ctx, actor, from)
	if err != nil {
		return err
	}
	if !ok {
		// Заявки нет. Если второй успел заблокировать — отвечаем 403,
		// а не 404: иначе клиент будет искать «пропавшую» заявку.
		blocked, berr := s.store.BlockedEither(ctx, actor, from)
		if berr != nil {
			return berr
		}
		if blocked {
			return ErrBlocked
		}
		return fmt.Errorf("%w: входящей заявки нет", ErrNotFound)
	}

	if actorUser, err := s.store.UserByID(ctx, actor); err == nil {
		// И второе устройство того, кто принял: список друзей должно
		// обновить и оно, а не только отправитель заявки.
		s.notify(ctx, []string{from, actor}, "FRIEND_ACCEPT", map[string]any{
			"user": userPayload(actorUser),
		})
	} else {
		slog.Warn("friend accept: load user", "err", err, "user_id", actor)
	}
	return nil
}

// Remove удаляет любую связь пары: дружбу, заявку или отказ.
//
// Повторный вызов не ошибка — удалять уже нечего.
func (s *Service) Remove(ctx context.Context, actor, other string) error {
	if other == "" || actor == other {
		return fmt.Errorf("%w: неверная пара пользователей", ErrValidation)
	}

	rel, err := s.store.RelationType(ctx, actor, other)
	if err != nil {
		return err
	}

	if err := s.store.DeleteRelationshipPair(ctx, actor, other); err != nil {
		return err
	}

	// Событие отправляем, только если связь была: иначе повторное удаление
	// каждый раз дергало бы вторую сторону.
	if rel != "" {
		s.notify(ctx, []string{other}, "RELATIONSHIP_REMOVE", map[string]any{
			"user_id": actor,
		})
	}
	return nil
}

// SetBlocked ставит или снимает блокировку actor → target.
//
// Снятие блокировки возвращает дружбу, если она была до блокировки
// (решение пользователя 20.11.2026). Заявки не восстанавливаются.
// Незнакомец после разблокировки остаётся незнакомцем: мгновенная дружба
// со спамером — не то, чего ждут от кнопки.
func (s *Service) SetBlocked(ctx context.Context, actor, target string, blocked bool) error {
	if target == "" {
		return fmt.Errorf("%w: нужен пользователь", ErrValidation)
	}
	if actor == target {
		return fmt.Errorf("%w: нельзя заблокировать себя", ErrValidation)
	}

	if _, err := s.store.UserByID(ctx, target); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return ErrNotFound
		}
		return err
	}

	if blocked {
		// blockUser возвращает, какая связь была до блокировки: событие
		// об удалении нужно только тем, у кого в списке что-то было.
		// Проверка и запись — один запрос, окна для гонки нет.
		prev, err := s.store.BlockUser(ctx, actor, target)
		if err != nil {
			return err
		}

		switch prev {
		case store.RelationFriend, store.RelationPendingIn, store.RelationPendingOut:
			s.notify(ctx, []string{target}, "RELATIONSHIP_REMOVE", map[string]any{
				"user_id": actor,
			})
		}
		return nil
	}
	restored, err := s.store.UnblockUser(ctx, actor, target)
	if err != nil {
		return err
	}
	if restored {
		// Дружба вернулась автоматически (решение 20.11.2026) — вторая
		// сторона должна увидеть это без перезапуска приложения. Своё второе
		// устройство тоже: оно не знает, что блокировку сняли.
		if actorUser, uerr := s.store.UserByID(ctx, actor); uerr == nil {
			s.notify(ctx, []string{target, actor}, "FRIEND_ACCEPT", map[string]any{
				"user": userPayload(actorUser),
			})
		} else {
			slog.Warn("friend unblock: load user", "err", uerr, "user_id", actor)
		}
	}
	return nil
}

// likeEscaper обезвреживает служебные символы LIKE.
//
// Без этого запрос `q=%%` проходит проверку длины и перечисляет
// пользователей: `%` — шаблон «любая строка», а не символ.
var likeEscaper = strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)

// Search ищет людей по логину или имени и подсказывает, какая связь уже есть.
func (s *Service) Search(ctx context.Context, actor, query string) ([]SearchResult, error) {
	q := strings.TrimSpace(query)
	runes := []rune(q)
	if len(runes) < minSearchRunes {
		return nil, fmt.Errorf("%w: минимум %d символа", ErrValidation, minSearchRunes)
	}
	if len(runes) > maxSearchRunes {
		q = string(runes[:maxSearchRunes])
	}

	users, err := s.store.SearchUsers(ctx, actor, likeEscaper.Replace(q), maxSearchResults)
	if err != nil {
		return nil, err
	}

	ids := make([]string, 0, len(users))
	for _, u := range users {
		ids = append(ids, u.ID)
	}

	types, err := s.store.RelationTypes(ctx, actor, ids)
	if err != nil {
		return nil, err
	}

	out := make([]SearchResult, 0, len(users))
	for _, u := range users {
		out = append(out, SearchResult{User: u, Relation: relationName(types[u.ID])})
	}

	return out, nil
}

// CanDM отвечает, можно ли открыть личный диалог и звонить.
//
// Разрешено только друзьям: иначе любой, кто знает логин, может писать
// и звонить. Заблокированные и незнакомые — нельзя.
func (s *Service) CanDM(ctx context.Context, actor, target string) (bool, error) {
	if actor == "" || target == "" || actor == target {
		return false, nil
	}

	rel, err := s.store.RelationType(ctx, actor, target)
	if err != nil {
		return false, err
	}
	return rel == store.RelationFriend, nil
}

// relationName переводит тип строки в термин для клиента.
func relationName(stored string) string {
	switch stored {
	case store.RelationFriend:
		return "friend"
	case store.RelationPendingIn:
		return "incoming"
	case store.RelationPendingOut:
		return "outgoing"
	case store.RelationBlocked:
		return "blocked"
	default:
		return "none"
	}
}
