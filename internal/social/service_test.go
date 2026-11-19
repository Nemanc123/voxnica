package social_test

// Интеграционные тесты друзей. Требуют живой PostgreSQL:
// без DATABASE_URL пропускаются.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
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

func TestUnblockDoesNotRestoreFriendship(t *testing.T) {
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
	if ok {
		t.Fatal("снятие блокировки не должно восстанавливать дружбу")
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
