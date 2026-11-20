package dm_test

// Групповые диалоги: создание, участники, лимит, блокировки, события.
// Как и остальные тесты пакета, требуют DATABASE_URL.

import (
	"context"
	"errors"
	"testing"

	"github.com/Nemanc123/voxnica/internal/dm"
)

func namePtr(s string) *string { return &s }

type dmRecorder struct {
	kinds []string
	users [][]string
}

func (r *dmRecorder) PublishToUsers(_ context.Context, userIDs []string, eventType string, _ any) {
	r.kinds = append(r.kinds, eventType)
	r.users = append(r.users, append([]string(nil), userIDs...))
}

func TestCreateGroupWithThreeParticipants(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	extra := makeUser(t, ctx, e.store)

	ch, err := e.service.CreateGroup(ctx, e.owner, []string{e.member, extra}, namePtr("Проект"))
	if err != nil {
		t.Fatalf("создание группы: %v", err)
	}
	if ch.Type != "group_dm" {
		t.Fatalf("тип %q, ожидали group_dm", ch.Type)
	}
	if ch.Name == nil || *ch.Name != "Проект" {
		t.Fatalf("имя %v, ожидали «Проект»", ch.Name)
	}
	if len(ch.Recipients) != 3 {
		t.Fatalf("участников %d, ожидали 3", len(ch.Recipients))
	}

	for _, id := range []string{e.owner, e.member, extra} {
		_, ok, err := e.service.Access(ctx, id, ch.ID)
		if err != nil || !ok {
			t.Fatalf("участник %s должен иметь доступ: ok=%v err=%v", id, ok, err)
		}
	}
	if _, ok, err := e.service.Access(ctx, e.stranger, ch.ID); err != nil || ok {
		t.Fatalf("посторонний не должен иметь доступ: ok=%v err=%v", ok, err)
	}

	list, err := e.service.List(ctx, e.member)
	if err != nil {
		t.Fatalf("список: %v", err)
	}
	found := false
	for _, c := range list {
		if c.ID == ch.ID {
			found = true
		}
	}
	if !found {
		t.Fatal("группа не попала в список участника")
	}
}

func TestCreateGroupSizeLimits(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	if _, err := e.service.CreateGroup(ctx, e.owner, []string{e.member}, nil); !errors.Is(err, dm.ErrValidation) {
		t.Fatalf("группа из двух должна быть ошибкой, получили %v", err)
	}

	ids := make([]string, 0, 10)
	for i := 0; i < 10; i++ {
		ids = append(ids, makeUser(t, ctx, e.store))
	}
	if _, err := e.service.CreateGroup(ctx, e.owner, ids, nil); !errors.Is(err, dm.ErrValidation) {
		t.Fatalf("группа из 11 должна быть ошибкой, получили %v", err)
	}
}

func TestCreateGroupRejectsBlockedPairs(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	extra := makeUser(t, ctx, e.store)

	if _, err := e.store.BlockUser(ctx, e.stranger, e.owner); err != nil {
		t.Fatalf("блокировка: %v", err)
	}
	if _, err := e.service.CreateGroup(ctx, e.owner, []string{e.member, e.stranger}, nil); !errors.Is(err, dm.ErrForbidden) {
		t.Fatalf("создатель и участник в блокировке: ожидали ErrForbidden, получили %v", err)
	}

	if _, err := e.store.BlockUser(ctx, e.member, extra); err != nil {
		t.Fatalf("блокировка между участниками: %v", err)
	}
	if _, err := e.service.CreateGroup(ctx, e.owner, []string{e.member, extra}, nil); !errors.Is(err, dm.ErrForbidden) {
		t.Fatalf("два участника в блокировке: ожидали ErrForbidden, получили %v", err)
	}
}

func TestAddAndRemoveGroupRecipient(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	extra := makeUser(t, ctx, e.store)
	fourth := makeUser(t, ctx, e.store)

	ch, err := e.service.CreateGroup(ctx, e.owner, []string{e.member, extra}, nil)
	if err != nil {
		t.Fatalf("группа: %v", err)
	}

	updated, err := e.service.AddRecipient(ctx, e.member, ch.ID, fourth)
	if err != nil {
		t.Fatalf("добавление: %v", err)
	}
	if len(updated.Recipients) != 4 {
		t.Fatalf("после добавления участников %d, ожидали 4", len(updated.Recipients))
	}

	if err := e.service.RemoveRecipient(ctx, e.member, ch.ID, fourth); err != nil {
		t.Fatalf("удаление: %v", err)
	}
	if _, ok, err := e.service.Access(ctx, fourth, ch.ID); err != nil || ok {
		t.Fatalf("удалённый не должен иметь доступ: ok=%v err=%v", ok, err)
	}

	// Участник может выйти сам.
	if err := e.service.RemoveRecipient(ctx, extra, ch.ID, extra); err != nil {
		t.Fatalf("выход из группы: %v", err)
	}
	if _, ok, err := e.service.Access(ctx, extra, ch.ID); err != nil || ok {
		t.Fatalf("вышедший не должен иметь доступ: ok=%v err=%v", ok, err)
	}

	// Посторонний не может удалять участников.
	if err := e.service.RemoveRecipient(ctx, fourth, ch.ID, e.member); !errors.Is(err, dm.ErrForbidden) {
		t.Fatalf("посторонний удаляет: ожидали ErrForbidden, получили %v", err)
	}

	// Посторонний не может и добавлять.
	if _, err := e.service.AddRecipient(ctx, fourth, ch.ID, e.stranger); !errors.Is(err, dm.ErrForbidden) {
		t.Fatalf("посторонний добавляет: ожидали ErrForbidden, получили %v", err)
	}
}

func TestGroupShrinksToZeroAndIsHidden(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	extra := makeUser(t, ctx, e.store)

	ch, err := e.service.CreateGroup(ctx, e.owner, []string{e.member, extra}, nil)
	if err != nil {
		t.Fatalf("группа: %v", err)
	}

	if err := e.service.RemoveRecipient(ctx, e.owner, ch.ID, e.member); err != nil {
		t.Fatalf("удаление member: %v", err)
	}
	if err := e.service.RemoveRecipient(ctx, e.owner, ch.ID, extra); err != nil {
		t.Fatalf("удаление extra: %v", err)
	}
	if err := e.service.RemoveRecipient(ctx, e.owner, ch.ID, e.owner); err != nil {
		t.Fatalf("выход последнего: %v", err)
	}

	list, err := e.service.List(ctx, e.owner)
	if err != nil {
		t.Fatalf("список: %v", err)
	}
	for _, c := range list {
		if c.ID == ch.ID {
			t.Fatal("удалённая группа не должна быть в списке")
		}
	}
}

func TestAddRecipientRespectsLimit(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	ids := make([]string, 0, 9)
	for i := 0; i < 9; i++ {
		ids = append(ids, makeUser(t, ctx, e.store))
	}
	ch, err := e.service.CreateGroup(ctx, e.owner, ids, nil)
	if err != nil {
		t.Fatalf("группа на 10: %v", err)
	}
	extra := makeUser(t, ctx, e.store)

	if _, err := e.service.AddRecipient(ctx, e.owner, ch.ID, extra); !errors.Is(err, dm.ErrValidation) {
		t.Fatalf("11-й участник: ожидали ErrValidation, получили %v", err)
	}
}

func TestRenameGroup(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	extra := makeUser(t, ctx, e.store)

	ch, err := e.service.CreateGroup(ctx, e.owner, []string{e.member, extra}, nil)
	if err != nil {
		t.Fatalf("группа: %v", err)
	}

	renamed, err := e.service.Rename(ctx, e.member, ch.ID, namePtr("  Новая  "))
	if err != nil {
		t.Fatalf("переименование: %v", err)
	}
	if renamed.Name == nil || *renamed.Name != "Новая" {
		t.Fatalf("имя %v, ожидали «Новая»", renamed.Name)
	}

	cleared, err := e.service.Rename(ctx, e.owner, ch.ID, namePtr("   "))
	if err != nil {
		t.Fatalf("сброс имени: %v", err)
	}
	if cleared.Name != nil {
		t.Fatalf("пустое имя должно стать nil, получили %v", cleared.Name)
	}

	if _, err := e.service.Rename(ctx, e.stranger, ch.ID, namePtr("Чужое")); !errors.Is(err, dm.ErrForbidden) {
		t.Fatalf("посторонний переименовывает: ожидали ErrForbidden, получили %v", err)
	}
}

func TestGroupAccessSurvivesBlockInside(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	extra := makeUser(t, ctx, e.store)

	ch, err := e.service.CreateGroup(ctx, e.owner, []string{e.member, extra}, nil)
	if err != nil {
		t.Fatalf("группа: %v", err)
	}

	if _, err := e.store.BlockUser(ctx, e.member, extra); err != nil {
		t.Fatalf("блокировка внутри группы: %v", err)
	}

	// По решению 20.11.2026 блокировка внутри группы не закрывает канал:
	// иначе один конфликт лишил бы доступа всех.
	for _, id := range []string{e.owner, e.member, extra} {
		if _, ok, err := e.service.Access(ctx, id, ch.ID); err != nil || !ok {
			t.Fatalf("участник %s должен сохранить доступ: ok=%v err=%v", id, ok, err)
		}
	}
}

func TestGroupEvents(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	extra := makeUser(t, ctx, e.store)
	fourth := makeUser(t, ctx, e.store)

	rec := &dmRecorder{}
	e.service.SetPublisher(rec)

	ch, err := e.service.CreateGroup(ctx, e.owner, []string{e.member, extra}, nil)
	if err != nil {
		t.Fatalf("группа: %v", err)
	}
	if len(rec.kinds) != 1 || rec.kinds[0] != "DM_CHANNEL_CREATE" {
		t.Fatalf("ожидали DM_CHANNEL_CREATE, получили %v", rec.kinds)
	}
	if len(rec.users[0]) != 3 {
		t.Fatalf("событие создания ушло %v, ожидали трёх участников", rec.users[0])
	}

	if _, err := e.service.AddRecipient(ctx, e.owner, ch.ID, fourth); err != nil {
		t.Fatalf("добавление: %v", err)
	}
	if len(rec.kinds) != 2 || rec.kinds[1] != "DM_CHANNEL_UPDATE" {
		t.Fatalf("ожидали DM_CHANNEL_UPDATE после добавления, получили %v", rec.kinds)
	}

	if _, err := e.service.Rename(ctx, e.owner, ch.ID, namePtr("Новое")); err != nil {
		t.Fatalf("переименование: %v", err)
	}
	if len(rec.kinds) != 3 || rec.kinds[2] != "DM_CHANNEL_UPDATE" {
		t.Fatalf("ожидали DM_CHANNEL_UPDATE после переименования, получили %v", rec.kinds)
	}

	if err := e.service.RemoveRecipient(ctx, e.owner, ch.ID, fourth); err != nil {
		t.Fatalf("удаление: %v", err)
	}
	if len(rec.kinds) != 5 {
		t.Fatalf("ожидали REMOVE + UPDATE после удаления, получили %v", rec.kinds)
	}
	if rec.kinds[3] != "DM_CHANNEL_REMOVE" || rec.users[3][0] != fourth {
		t.Fatalf("REMOVE должен уйти удалённому: %s %v", rec.kinds[3], rec.users[3])
	}
	if rec.kinds[4] != "DM_CHANNEL_UPDATE" {
		t.Fatalf("оставшимся должен уйти UPDATE, получили %v", rec.kinds)
	}
}
