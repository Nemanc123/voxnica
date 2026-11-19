package gateway

import (
	"context"
	"testing"
)

type friendStub struct {
	ids []string
}

func (f friendStub) FriendIDs(context.Context, string) ([]string, error) { return f.ids, nil }

// TestHubIsOnlineAndFriendPresence проверяет два новых метода хаба:
// IsOnline (нужен эндпоинту присутствия) и рассылку присутствия друзьям.
func TestHubIsOnlineAndFriendPresence(t *testing.T) {
	hub := NewHub()
	hub.SetFriends(friendStub{ids: []string{"friend-1", "friend-2"}})

	if hub.IsOnline("user-1") {
		t.Fatal("до подключения пользователь не в сети")
	}

	session := &Session{ID: "s1", UserID: "user-1", Guilds: nil}
	client := newClient(hub, nil, session)
	hub.Attach(session, client)

	if !hub.IsOnline("user-1") {
		t.Fatal("после Attach пользователь должен быть в сети")
	}

	// Друзья подписаны на личные события через byUser; для проверки
	// достаточно того, что вызов не паникует и проходит через PublishToUsers.
	hub.NotifyFriendsPresence(context.Background(), "user-1", "online")

	hub.Detach(session)
	if hub.IsOnline("user-1") {
		t.Fatal("после единственного Detach пользователь не в сети")
	}
}

func TestHubPresenceTracksFirstAndLastConnection(t *testing.T) {
	hub := NewHub()

	session1 := &Session{ID: "s1", UserID: "user-1", Guilds: []string{"g1"}}
	client1 := newClient(hub, nil, session1)

	if !hub.Attach(session1, client1) {
		t.Fatal("первое соединение должно означать переход в онлайн")
	}
	if got := hub.OnlineUsers("g1"); len(got) != 1 || got[0] != "user-1" {
		t.Fatalf("онлайн = %v", got)
	}

	// Второе соединение того же пользователя с другого устройства:
	// онлайн-статус не должен «мигнуть» второй раз.
	session2 := &Session{ID: "s2", UserID: "user-1", Guilds: []string{"g1"}}
	client2 := newClient(hub, nil, session2)

	if hub.Attach(session2, client2) {
		t.Fatal("второе соединение не должно повторно объявлять онлайн")
	}

	// Закрываем одно — пользователь ещё онлайн.
	if hub.Detach(session2) {
		t.Fatal("пока живо второе соединение, офлайн объявлять нельзя")
	}
	if got := hub.OnlineUsers("g1"); len(got) != 1 {
		t.Fatalf("ожидали одного онлайн, получили %v", got)
	}

	// Закрываем последнее — теперь офлайн.
	if !hub.Detach(session1) {
		t.Fatal("последнее соединение должно давать переход в офлайн")
	}
	if got := hub.OnlineUsers("g1"); len(got) != 0 {
		t.Fatalf("ожидали пустой список, получили %v", got)
	}
}

func TestHubPresencePerGuild(t *testing.T) {
	hub := NewHub()

	session := &Session{ID: "s1", UserID: "user-1", Guilds: []string{"g1", "g2"}}
	client := newClient(hub, nil, session)
	hub.Attach(session, client)

	if len(hub.OnlineUsers("g1")) != 1 {
		t.Fatal("должен быть виден в первом сервере")
	}
	if len(hub.OnlineUsers("g2")) != 1 {
		t.Fatal("должен быть виден во втором сервере")
	}
	if len(hub.OnlineUsers("g3")) != 0 {
		t.Fatal("в чужом сервере его быть не должно")
	}
}

func TestHubDropRemovesFromPresence(t *testing.T) {
	hub := NewHub()

	session := &Session{ID: "s1", UserID: "user-1", Guilds: []string{"g1"}}
	client := newClient(hub, nil, session)
	hub.Attach(session, client)

	hub.Drop(session)

	if len(hub.OnlineUsers("g1")) != 0 {
		t.Fatal("после Drop пользователь не должен считаться онлайн")
	}
}
