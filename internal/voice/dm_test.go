package voice_test

import (
	"context"
	"errors"
	"testing"

	"github.com/Nemanc123/voxnica/internal/voice"
)

func TestJoinDMChannelAllowsCall(t *testing.T) {
	e := newVoiceEnv(t)
	ctx := context.Background()

	channel, err := e.dm.Open(ctx, e.owner, e.member)
	if err != nil {
		t.Fatalf("открытие диалога: %v", err)
	}

	result, err := e.service.Join(ctx, e.member, channel.ID)
	if err != nil {
		t.Fatalf("звонок в личный канал: %v", err)
	}
	if !result.CanSpeak || !result.CanVideo || !result.CanScreenShare {
		t.Fatalf("в личном канале должны быть звук и видео: %+v", result)
	}
	if result.Room != channel.ID {
		t.Fatalf("комната %s, ожидали %s", result.Room, channel.ID)
	}
}

func TestJoinDMChannelRejectsStranger(t *testing.T) {
	e := newVoiceEnv(t)
	ctx := context.Background()

	channel, err := e.dm.Open(ctx, e.owner, e.member)
	if err != nil {
		t.Fatalf("открытие диалога: %v", err)
	}

	if _, err := e.service.Join(ctx, e.stranger, channel.ID); !errors.Is(err, voice.ErrForbidden) {
		t.Fatalf("посторонний: ожидали ErrForbidden, получили %v", err)
	}
}

func TestJoinTextChannelStillRejected(t *testing.T) {
	e := newVoiceEnv(t)
	ctx := context.Background()

	if _, err := e.service.Join(ctx, e.owner, e.textID); !errors.Is(err, voice.ErrValidation) {
		t.Fatalf("текстовый канал: ожидали ErrValidation, получили %v", err)
	}
}
