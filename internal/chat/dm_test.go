package chat_test

import (
	"context"
	"errors"
	"testing"

	"github.com/Nemanc123/voxnica/internal/chat"
)

func TestDMRecipientsCanPostAndRead(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	channel, err := e.dm.Open(ctx, e.owner, e.member)
	if err != nil {
		t.Fatalf("открытие диалога: %v", err)
	}

	if _, err := e.service.Post(ctx, e.owner, channel.ID, "привет", nil); err != nil {
		t.Fatalf("отправка в личный канал: %v", err)
	}

	history, err := e.service.History(ctx, e.member, channel.ID, 0, 50)
	if err != nil {
		t.Fatalf("чтение личного канала: %v", err)
	}
	if len(history) != 1 || history[0].Content != "привет" {
		t.Fatalf("история не совпала: %+v", history)
	}
}

func TestDMStrangerIsForbidden(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()

	channel, err := e.dm.Open(ctx, e.owner, e.member)
	if err != nil {
		t.Fatalf("открытие диалога: %v", err)
	}

	if _, err := e.service.Post(ctx, e.stranger, channel.ID, "чужой", nil); !errors.Is(err, chat.ErrForbidden) {
		t.Fatalf("отправка посторонним: ожидали ErrForbidden, получили %v", err)
	}
	if _, err := e.service.History(ctx, e.stranger, channel.ID, 0, 50); !errors.Is(err, chat.ErrForbidden) {
		t.Fatalf("чтение посторонним: ожидали ErrForbidden, получили %v", err)
	}
}
