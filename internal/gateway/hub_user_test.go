package gateway

import (
	"context"
	"testing"
)

func TestPublishToUsersDeliversOnlyRecipients(t *testing.T) {
	hub := NewHub()
	sessions := NewSessionStore()

	alice := sessions.Create("user-alice", nil)
	bob := sessions.Create("user-bob", nil)
	hub.Attach(alice, nil)
	hub.Attach(bob, nil)

	hub.PublishToUsers(context.Background(), []string{"user-alice"}, "MESSAGE_CREATE", map[string]string{
		"id":         "m1",
		"channel_id": "dm-1",
	})

	if payloads, ok := alice.eventsAfter(0); !ok || len(payloads) != 1 {
		t.Fatalf("получатель должен получить 1 событие: ok=%v len=%d", ok, len(payloads))
	}
	if payloads, ok := bob.eventsAfter(0); !ok || len(payloads) != 0 {
		t.Fatalf("посторонний не должен получать событие: ok=%v len=%d", ok, len(payloads))
	}
}

func TestPublishToUsersStopsAfterDrop(t *testing.T) {
	hub := NewHub()
	sessions := NewSessionStore()

	alice := sessions.Create("user-alice", nil)
	hub.Attach(alice, nil)

	hub.PublishToUsers(context.Background(), []string{"user-alice"}, "MESSAGE_CREATE", map[string]string{"id": "m1"})
	hub.Drop(alice)

	hub.PublishToUsers(context.Background(), []string{"user-alice"}, "MESSAGE_CREATE", map[string]string{"id": "m2"})

	payloads, ok := alice.eventsAfter(1)
	if !ok || len(payloads) != 0 {
		t.Fatalf("после Drop событий быть не должно: ok=%v len=%d", ok, len(payloads))
	}
}
