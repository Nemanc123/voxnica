package social_test

// Интеграционные тесты друзей. Требуют живой PostgreSQL:
// без DATABASE_URL пропускаются.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Nemanc123/voxnica/internal/social"
	"github.com/Nemanc123/voxnica/internal/store"
)

const testHash = "$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA"

type env struct {
	service *social.Service
	store   *store.Store
	alice   string
	bob     string
	carol   string
}

func newEnv(t *testing.T) env {
	t.Helper()

	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL не задан — интеграционные тесты пропущены")
	}

	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatalf("подключение: %v", err)
	}
	t.Cleanup(pool.Close)

	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("транзакция: %v", err)
	}
	t.Cleanup(func() { _ = tx.Rollback(context.Background()) })

	st := store.New(tx)

	return env{
		service: social.NewService(st),
		store:   st,
		alice:   makeUser(t, ctx, st, "a"),
		bob:     makeUser(t, ctx, st, "b"),
		carol:   makeUser(t, ctx, st, "c"),
	}
}

func makeUser(t *testing.T, ctx context.Context, st *store.Store, prefix string) string {
	t.Helper()

	buf := make([]byte, 5)
	if _, err := rand.Read(buf); err != nil {
		t.Fatalf("случайное имя: %v", err)
	}
	u, err := st.CreateUser(ctx, store.CreateUserParams{
		Username:     prefix + hex.EncodeToString(buf),
		PasswordHash: testHash,
	})
	if err != nil {
		t.Fatalf("пользователь: %v", err)
	}
	return u.ID
}

func TestRequestThenAcceptMakesFriends(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	if err := e.service.SendRequest(ctx, e.alice, e.bob); err != nil {
		t.Fatalf("заявка: %v", err)
	}

	aliceView, err := e.service.List(ctx, e.alice)
	if err != nil {
		t.Fatalf("список alice: %v", err)
	}
	if len(aliceView.Outgoing) != 1 || aliceView.Outgoing[0].User.ID != e.bob {
		t.Fatalf("у alice ожидалась одна исходящая заявка, получено %+v", aliceView.Outgoing)
	}

	bobView, err := e.service.List(ctx, e.bob)
	if err != nil {
		t.Fatalf("список bob: %v", err)
	}
	if len(bobView.Incoming) != 1 || bobView.Incoming[0].User.ID != e.alice {
		t.Fatalf("у bob ожидалась одна входящая заявка, получено %+v", bobView.Incoming)
	}

	if err := e.service.Accept(ctx, e.bob, e.alice); err != nil {
		t.Fatalf("принятие: %v", err)
	}

	for _, pair := range [][2]string{{e.alice, e.bob}, {e.bob, e.alice}} {
		ok, err := e.service.CanDM(ctx, pair[0], pair[1])
		if err != nil {
			t.Fatalf("canDM: %v", err)
		}
		if !ok {
			t.Fatalf("после принятия %s должен быть другом %s", pair[0], pair[1])
		}
	}
}

func TestSenderCannotAcceptOwnRequest(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	if err := e.service.SendRequest(ctx, e.alice, e.bob); err != nil {
		t.Fatalf("заявка: %v", err)
	}

	// Отправитель пытается принять свою же заявку — согласия адресата нет.
	err := e.service.Accept(ctx, e.alice, e.bob)
	if !errors.Is(err, social.ErrNotFound) {
		t.Fatalf("отправитель не должен принимать свою заявку, получили %v", err)
	}

	ok, err := e.service.CanDM(ctx, e.alice, e.bob)
	if err != nil {
		t.Fatalf("canDM: %v", err)
	}
	if ok {
		t.Fatal("без согласия адресата дружбы быть не должно")
	}

	// Адресат принимает нормально — и только тогда появляется дружба.
	if err := e.service.Accept(ctx, e.bob, e.alice); err != nil {
		t.Fatalf("принятие адресатом: %v", err)
	}

	ok, err = e.service.CanDM(ctx, e.alice, e.bob)
	if err != nil {
		t.Fatalf("canDM после принятия: %v", err)
	}
	if !ok {
		t.Fatal("после принятия адресатом дружба должна быть")
	}
}

func TestSecondRequestRejected(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	if err := e.service.SendRequest(ctx, e.alice, e.bob); err != nil {
		t.Fatalf("первая заявка: %v", err)
	}

	err := e.service.SendRequest(ctx, e.alice, e.bob)
	if !errors.Is(err, social.ErrAlreadyPending) {
		t.Fatalf("ожидали ErrAlreadyPending, получили %v", err)
	}

	if err := e.service.Accept(ctx, e.bob, e.alice); err != nil {
		t.Fatalf("принятие: %v", err)
	}

	err = e.service.SendRequest(ctx, e.alice, e.bob)
	if !errors.Is(err, social.ErrAlreadyFriends) {
		t.Fatalf("ожидали ErrAlreadyFriends, получили %v", err)
	}
}

func TestAcceptWithoutRequestFails(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	err := e.service.Accept(ctx, e.alice, e.bob)
	if !errors.Is(err, social.ErrNotFound) {
		t.Fatalf("ожидали ErrNotFound, получили %v", err)
	}
}

func TestRemoveDeletesFriendship(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	if err := e.service.SendRequest(ctx, e.alice, e.bob); err != nil {
		t.Fatalf("заявка: %v", err)
	}
	if err := e.service.Accept(ctx, e.bob, e.alice); err != nil {
		t.Fatalf("принятие: %v", err)
	}

	if err := e.service.Remove(ctx, e.alice, e.bob); err != nil {
		t.Fatalf("удаление: %v", err)
	}

	ok, err := e.service.CanDM(ctx, e.alice, e.bob)
	if err != nil {
		t.Fatalf("canDM: %v", err)
	}
	if ok {
		t.Fatal("после удаления писать нельзя")
	}

	// Повторное удаление — не ошибка.
	if err := e.service.Remove(ctx, e.alice, e.bob); err != nil {
		t.Fatalf("повторное удаление: %v", err)
	}
}

func TestBlockPreventsRequestAndDM(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	if err := e.service.SetBlocked(ctx, e.alice, e.bob, true); err != nil {
		t.Fatalf("блокировка: %v", err)
	}

	if err := e.service.SendRequest(ctx, e.bob, e.alice); !errors.Is(err, social.ErrBlocked) {
		t.Fatalf("заблокированный не должен отправлять заявку, получили %v", err)
	}

	ok, err := e.service.CanDM(ctx, e.bob, e.alice)
	if err != nil {
		t.Fatalf("canDM: %v", err)
	}
	if ok {
		t.Fatal("с заблокированным писать нельзя")
	}

	view, err := e.service.List(ctx, e.alice)
	if err != nil {
		t.Fatalf("список alice: %v", err)
	}
	if len(view.Blocked) != 1 || view.Blocked[0].User.ID != e.bob {
		t.Fatalf("ожидался один заблокированный, получено %+v", view.Blocked)
	}
}

// Решение пользователя 20.11.2026: снятие блокировки возвращает дружбу.
func TestUnblockRestoresFriendship(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	if err := e.service.SendRequest(ctx, e.alice, e.bob); err != nil {
		t.Fatalf("заявка: %v", err)
	}
	if err := e.service.Accept(ctx, e.bob, e.alice); err != nil {
		t.Fatalf("принятие: %v", err)
	}

	if err := e.service.SetBlocked(ctx, e.alice, e.bob, true); err != nil {
		t.Fatalf("блокировка: %v", err)
	}
	if err := e.service.SetBlocked(ctx, e.alice, e.bob, false); err != nil {
		t.Fatalf("снятие блокировки: %v", err)
	}

	ok, err := e.service.CanDM(ctx, e.alice, e.bob)
	if err != nil {
		t.Fatalf("canDM: %v", err)
	}
	if !ok {
		t.Fatal("после снятия блокировки дружба должна вернуться")
	}

	view, err := e.service.List(ctx, e.alice)
	if err != nil {
		t.Fatalf("список alice: %v", err)
	}
	if len(view.Friends) != 1 || view.Friends[0].User.ID != e.bob {
		t.Fatalf("ожидался bob в друзьях, получено %+v", view.Friends)
	}
	if len(view.Blocked) != 0 {
		t.Fatalf("заблокированных быть не должно, получено %+v", view.Blocked)
	}
}

// Дружба возвращается только тем, с кем она была: разблокировка незнакомца
// не должна делать его другом.
func TestUnblockStrangerStaysStranger(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	if err := e.service.SetBlocked(ctx, e.alice, e.carol, true); err != nil {
		t.Fatalf("блокировка: %v", err)
	}
	if err := e.service.SetBlocked(ctx, e.alice, e.carol, false); err != nil {
		t.Fatalf("снятие блокировки: %v", err)
	}

	ok, err := e.service.CanDM(ctx, e.alice, e.carol)
	if err != nil {
		t.Fatalf("canDM: %v", err)
	}
	if ok {
		t.Fatal("разблокировка незнакомца не должна создавать дружбу")
	}

	view, err := e.service.List(ctx, e.alice)
	if err != nil {
		t.Fatalf("список alice: %v", err)
	}
	if len(view.Friends) != 0 || len(view.Blocked) != 0 {
		t.Fatalf("ожидались пустые списки, получено друзья %+v, блокировки %+v",
			view.Friends, view.Blocked)
	}
}

// Повторная блокировка не должна стирать память о дружбе.
//
// Регрессия, которую здесь ловим: в ON CONFLICT колонка бралась из
// предлагаемой строки, и в blocked_prev попадало 'blocked'. С CHECK это
// падало, а без него — тихо теряло дружбу.
func TestRepeatedBlockKeepsFriendshipMemory(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	if err := e.service.SendRequest(ctx, e.alice, e.bob); err != nil {
		t.Fatalf("заявка: %v", err)
	}
	if err := e.service.Accept(ctx, e.bob, e.alice); err != nil {
		t.Fatalf("принятие: %v", err)
	}

	if err := e.service.SetBlocked(ctx, e.alice, e.bob, true); err != nil {
		t.Fatalf("первая блокировка: %v", err)
	}
	if err := e.service.SetBlocked(ctx, e.alice, e.bob, true); err != nil {
		t.Fatalf("повторная блокировка: %v", err)
	}
	if err := e.service.SetBlocked(ctx, e.alice, e.bob, false); err != nil {
		t.Fatalf("снятие блокировки: %v", err)
	}

	ok, err := e.service.CanDM(ctx, e.alice, e.bob)
	if err != nil {
		t.Fatalf("canDM: %v", err)
	}
	if !ok {
		t.Fatal("после двух блокировок дружба должна вернуться")
	}
}

// Вторая сторона должна узнать о восстановлении дружбы событием, иначе
// у неё в списке останется «заблокирован» до перезапуска приложения.
func TestUnblockRestoresFriendshipSendsEvent(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	if err := e.service.SendRequest(ctx, e.alice, e.bob); err != nil {
		t.Fatalf("заявка: %v", err)
	}
	if err := e.service.Accept(ctx, e.bob, e.alice); err != nil {
		t.Fatalf("принятие: %v", err)
	}

	pub := &recordingPublisher{}
	e.service.SetPublisher(pub)

	if err := e.service.SetBlocked(ctx, e.alice, e.bob, true); err != nil {
		t.Fatalf("блокировка: %v", err)
	}
	if err := e.service.SetBlocked(ctx, e.alice, e.bob, false); err != nil {
		t.Fatalf("снятие блокировки: %v", err)
	}

	got := pub.kinds()
	want := []string{"RELATIONSHIP_REMOVE", "FRIEND_ACCEPT"}
	if len(got) != len(want) {
		t.Fatalf("событий %d (%v), ожидали %d (%v)", len(got), got, len(want), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("событие %d: %q, ожидали %q", i, got[i], want[i])
		}
	}
	if pub.events[1].users[0] != e.bob {
		t.Fatalf("FRIEND_ACCEPT ушёл %v, ожидали bob", pub.events[1].users)
	}
}

func TestSearchReportsRelation(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	user, err := e.store.UserByID(ctx, e.bob)
	if err != nil {
		t.Fatalf("пользователь: %v", err)
	}

	results, err := e.service.Search(ctx, e.alice, user.Username)
	if err != nil {
		t.Fatalf("поиск: %v", err)
	}
	if len(results) == 0 {
		t.Fatal("поиск должен найти пользователя по логину")
	}
	if results[0].User.ID != e.bob || results[0].Relation != "none" {
		t.Fatalf("неожиданный результат: %+v", results[0])
	}

	if err := e.service.SendRequest(ctx, e.alice, e.bob); err != nil {
		t.Fatalf("заявка: %v", err)
	}

	results, err = e.service.Search(ctx, e.alice, user.Username)
	if err != nil {
		t.Fatalf("повторный поиск: %v", err)
	}
	if results[0].Relation != "outgoing" {
		t.Fatalf("ожидали outgoing, получили %q", results[0].Relation)
	}
}

func TestSearchHidesUsersWhoBlockedMe(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	// bob блокирует alice: alice не должна видеть bob в поиске.
	if err := e.service.SetBlocked(ctx, e.bob, e.alice, true); err != nil {
		t.Fatalf("блокировка: %v", err)
	}

	bob, err := e.store.UserByID(ctx, e.bob)
	if err != nil {
		t.Fatalf("пользователь: %v", err)
	}

	results, err := e.service.Search(ctx, e.alice, bob.Username)
	if err != nil {
		t.Fatalf("поиск: %v", err)
	}
	for _, r := range results {
		if r.User.ID == e.bob {
			t.Fatal("заблокировавший не должен показываться в поиске")
		}
	}
}

func TestSearchWildcardIsEscaped(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	// "%%" — это шаблон LIKE «любая строка», а не два символа.
	// Если не экранировать, вернутся все пользователи.
	results, err := e.service.Search(ctx, e.alice, "%%")
	if err != nil {
		t.Fatalf("поиск: %v", err)
	}
	if len(results) != 0 {
		t.Fatalf("шаблон LIKE не должен перечислять пользователей, найдено %d", len(results))
	}
}

func TestAcceptAfterBlockGivesForbidden(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	if err := e.service.SendRequest(ctx, e.alice, e.bob); err != nil {
		t.Fatalf("заявка: %v", err)
	}

	// bob блокирует alice, пока заявка висит.
	if err := e.service.SetBlocked(ctx, e.bob, e.alice, true); err != nil {
		t.Fatalf("блокировка: %v", err)
	}

	if err := e.service.Accept(ctx, e.bob, e.alice); !errors.Is(err, social.ErrBlocked) {
		t.Fatalf("ожидали ErrBlocked, получили %v", err)
	}
}

func TestSelfActionsRejected(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	if err := e.service.SendRequest(ctx, e.alice, e.alice); !errors.Is(err, social.ErrValidation) {
		t.Fatalf("заявка себе: ожидали ErrValidation, получили %v", err)
	}
	if err := e.service.SetBlocked(ctx, e.alice, e.alice, true); !errors.Is(err, social.ErrValidation) {
		t.Fatalf("блокировка себя: ожидали ErrValidation, получили %v", err)
	}
}

func TestSearchRequiresTwoCharacters(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	if _, err := e.service.Search(ctx, e.alice, "a"); !errors.Is(err, social.ErrValidation) {
		t.Fatalf("ожидали ErrValidation на один символ, получили %v", err)
	}
}

// recordingPublisher запоминает адресные события — как в тестах voice.
type recordingPublisher struct {
	mu     sync.Mutex
	events []recordedEvent
}

type recordedEvent struct {
	users []string
	kind  string
	data  any
}

func (r *recordingPublisher) PublishToUsers(_ context.Context, userIDs []string, eventType string, data any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, recordedEvent{users: append([]string(nil), userIDs...), kind: eventType, data: data})
}

func (r *recordingPublisher) kinds() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, 0, len(r.events))
	for _, e := range r.events {
		out = append(out, e.kind)
	}
	return out
}

func TestEventsGoToRightPeople(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	pub := &recordingPublisher{}
	e.service.SetPublisher(pub)

	if err := e.service.SendRequest(ctx, e.alice, e.bob); err != nil {
		t.Fatalf("заявка: %v", err)
	}
	if err := e.service.Accept(ctx, e.bob, e.alice); err != nil {
		t.Fatalf("принятие: %v", err)
	}
	if err := e.service.SetBlocked(ctx, e.alice, e.bob, true); err != nil {
		t.Fatalf("блокировка: %v", err)
	}

	got := pub.kinds()
	want := []string{"FRIEND_REQUEST", "FRIEND_ACCEPT", "RELATIONSHIP_REMOVE"}
	if len(got) != len(want) {
		t.Fatalf("событий %d (%v), ожидали %d (%v)", len(got), got, len(want), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("событие %d: %q, ожидали %q", i, got[i], want[i])
		}
	}

	// Заявка уходит адресату, принятие — отправителю, удаление — второму.
	if pub.events[0].users[0] != e.bob {
		t.Fatalf("FRIEND_REQUEST ушёл %v, ожидали bob", pub.events[0].users)
	}
	if pub.events[1].users[0] != e.alice {
		t.Fatalf("FRIEND_ACCEPT ушёл %v, ожидали alice", pub.events[1].users)
	}
	if pub.events[2].users[0] != e.bob {
		t.Fatalf("RELATIONSHIP_REMOVE ушёл %v, ожидали bob", pub.events[2].users)
	}
}

func TestBlockStrangerSendsNoEvent(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	pub := &recordingPublisher{}
	e.service.SetPublisher(pub)

	// С carol отношений не было: событие об удалении отправлять некому и незачем.
	if err := e.service.SetBlocked(ctx, e.alice, e.carol, true); err != nil {
		t.Fatalf("блокировка: %v", err)
	}
	if got := pub.kinds(); len(got) != 0 {
		t.Fatalf("блокировка незнакомца не должна слать события, получено %v", got)
	}
}

func TestBlockFriendSendsOneRemovalEvent(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	if err := e.service.SendRequest(ctx, e.alice, e.bob); err != nil {
		t.Fatalf("заявка: %v", err)
	}
	if err := e.service.Accept(ctx, e.bob, e.alice); err != nil {
		t.Fatalf("принятие: %v", err)
	}

	pub := &recordingPublisher{}
	e.service.SetPublisher(pub)

	if err := e.service.SetBlocked(ctx, e.alice, e.bob, true); err != nil {
		t.Fatalf("блокировка: %v", err)
	}

	got := pub.kinds()
	if len(got) != 1 || got[0] != "RELATIONSHIP_REMOVE" {
		t.Fatalf("ожидали одно RELATIONSHIP_REMOVE, получено %v", got)
	}
	if pub.events[0].users[0] != e.bob {
		t.Fatalf("событие ушло %v, ожидали bob", pub.events[0].users)
	}
}

func TestRepeatedBlockSendsOneEvent(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	if err := e.service.SendRequest(ctx, e.alice, e.bob); err != nil {
		t.Fatalf("заявка: %v", err)
	}
	if err := e.service.Accept(ctx, e.bob, e.alice); err != nil {
		t.Fatalf("принятие: %v", err)
	}

	pub := &recordingPublisher{}
	e.service.SetPublisher(pub)

	// Дважды блокируем одного и того же: второе нажатие не должно слать
	// второе событие — блокировка уже стоит.
	if err := e.service.SetBlocked(ctx, e.alice, e.bob, true); err != nil {
		t.Fatalf("первая блокировка: %v", err)
	}
	if err := e.service.SetBlocked(ctx, e.alice, e.bob, true); err != nil {
		t.Fatalf("повторная блокировка: %v", err)
	}

	if got := pub.kinds(); len(got) != 1 {
		t.Fatalf("ожидали одно событие, получено %v", got)
	}
}

func TestUnknownUserGivesNotFound(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	missing := "00000000-0000-0000-0000-000000000000"
	if err := e.service.SendRequest(ctx, e.alice, missing); !errors.Is(err, social.ErrNotFound) {
		t.Fatalf("заявка несуществующему: ожидали ErrNotFound, получили %v", err)
	}

	ok, err := e.service.CanDM(ctx, e.alice, e.carol)
	if err != nil {
		t.Fatalf("canDM: %v", err)
	}
	if ok {
		t.Fatal("незнакомым писать нельзя")
	}
}
