package dm_test

// Интеграционные тесты личных каналов. Требуют живой PostgreSQL:
// без DATABASE_URL пропускаются.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Nemanc123/voxnica/internal/dm"
	"github.com/Nemanc123/voxnica/internal/guild"
	"github.com/Nemanc123/voxnica/internal/store"
)

type env struct {
	service  *dm.Service
	store    *store.Store
	owner    string
	member   string
	stranger string
	guildID  string
	textID   string
}

const testHash = "$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA"

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
	gs := guild.NewService(st)
	service := dm.NewService(st)

	owner := makeUser(t, ctx, st)
	member := makeUser(t, ctx, st)
	stranger := makeUser(t, ctx, st)

	detail, err := gs.CreateGuild(ctx, owner, "Сервер для личных сообщений")
	if err != nil {
		t.Fatalf("сервер: %v", err)
	}
	if err := st.AddMember(ctx, detail.Guild.ID, member); err != nil {
		t.Fatalf("участник: %v", err)
	}

	var textID string
	for _, ch := range detail.Channels {
		if ch.Type == "text" {
			textID = ch.ID
		}
	}
	if textID == "" {
		t.Fatal("текстовый канал не найден")
	}

	return env{
		service:  service,
		store:    st,
		owner:    owner,
		member:   member,
		stranger: stranger,
		guildID:  detail.Guild.ID,
		textID:   textID,
	}
}

func makeUser(t *testing.T, ctx context.Context, st *store.Store) string {
	t.Helper()

	buf := make([]byte, 5)
	if _, err := rand.Read(buf); err != nil {
		t.Fatalf("случайное имя: %v", err)
	}
	u, err := st.CreateUser(ctx, store.CreateUserParams{
		Username:     "d" + hex.EncodeToString(buf),
		PasswordHash: testHash,
	})
	if err != nil {
		t.Fatalf("пользователь: %v", err)
	}
	return u.ID
}

func TestOpenCreatesOneChannelPerPair(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	first, err := e.service.Open(ctx, e.owner, e.member)
	if err != nil {
		t.Fatalf("открытие диалога: %v", err)
	}
	second, err := e.service.Open(ctx, e.member, e.owner)
	if err != nil {
		t.Fatalf("повторное открытие: %v", err)
	}

	if first.ID != second.ID {
		t.Fatalf("диалог задублировался: %s и %s", first.ID, second.ID)
	}
	if len(first.Recipients) != 2 {
		t.Fatalf("получателей %d, ожидали 2", len(first.Recipients))
	}
}

func TestOpenWithStrangerAllowed(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	// Раньше требовался общий сервер. Теперь писать можно любому, как в
	// Discord: единственное ограничение — блокировка.
	ch, err := e.service.Open(ctx, e.owner, e.stranger)
	if err != nil {
		t.Fatalf("диалог с незнакомцем: %v", err)
	}
	if ch.ID == "" {
		t.Fatal("канал не создан")
	}
}

func TestOpenBlockedIsForbidden(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	// Незнакомец блокирует владельца: открыть диалог нельзя.
	if _, err := e.store.BlockUser(ctx, e.stranger, e.owner); err != nil {
		t.Fatalf("блокировка: %v", err)
	}

	_, err := e.service.Open(ctx, e.owner, e.stranger)
	if !errors.Is(err, dm.ErrForbidden) {
		t.Fatalf("ожидали ErrForbidden, получили %v", err)
	}
}

func TestAccessDeniedAfterBlock(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	ch, err := e.service.Open(ctx, e.owner, e.member)
	if err != nil {
		t.Fatalf("диалог: %v", err)
	}

	if _, ok, err := e.service.Access(ctx, e.owner, ch.ID); err != nil || !ok {
		t.Fatalf("до блокировки доступ должен быть: ok=%v err=%v", ok, err)
	}

	// Участник блокирует владельца: старый диалог остаётся в базе, но писать
	// и звонить в него больше нельзя — Access для обоих должен запрещать.
	if _, err := e.store.BlockUser(ctx, e.member, e.owner); err != nil {
		t.Fatalf("блокировка: %v", err)
	}

	if _, ok, err := e.service.Access(ctx, e.owner, ch.ID); err != nil || ok {
		t.Fatalf("после блокировки доступ должен быть закрыт: ok=%v err=%v", ok, err)
	}
	if _, ok, err := e.service.Access(ctx, e.member, ch.ID); err != nil || ok {
		t.Fatalf("заблокировавший тоже не должен писать: ok=%v err=%v", ok, err)
	}
}

func TestOpenRejectsSelf(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	_, err := e.service.Open(ctx, e.owner, e.owner)
	if !errors.Is(err, dm.ErrValidation) {
		t.Fatalf("ожидали ErrValidation, получили %v", err)
	}
}

func TestListReturnsDialogForBothSides(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	created, err := e.service.Open(ctx, e.owner, e.member)
	if err != nil {
		t.Fatalf("открытие диалога: %v", err)
	}

	for _, userID := range []string{e.owner, e.member} {
		list, err := e.service.List(ctx, userID)
		if err != nil {
			t.Fatalf("список: %v", err)
		}
		found := false
		for _, ch := range list {
			if ch.ID == created.ID {
				found = true
			}
		}
		if !found {
			t.Fatalf("диалог %s не виден пользователю %s", created.ID, userID)
		}
	}
}

func TestAccessChecksRecipients(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	created, err := e.service.Open(ctx, e.owner, e.member)
	if err != nil {
		t.Fatalf("открытие диалога: %v", err)
	}

	if _, ok, err := e.service.Access(ctx, e.member, created.ID); err != nil || !ok {
		t.Fatalf("получатель должен иметь доступ: ok=%v err=%v", ok, err)
	}
	if _, ok, err := e.service.Access(ctx, e.stranger, created.ID); err != nil || ok {
		t.Fatalf("посторонний не должен иметь доступ: ok=%v err=%v", ok, err)
	}
	if _, ok, err := e.service.Access(ctx, e.owner, e.textID); err != nil || ok {
		t.Fatalf("обычный канал не должен считаться личным: ok=%v err=%v", ok, err)
	}
}
