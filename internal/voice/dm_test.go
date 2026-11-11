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

func TestInviteDMNotifiesRecipientOnly(t *testing.T) {
	e := newVoiceEnv(t)
	ctx := context.Background()

	channel, err := e.dm.Open(ctx, e.owner, e.member)
	if err != nil {
		t.Fatalf("открытие диалога: %v", err)
	}

	if err := e.service.Invite(ctx, e.owner, channel.ID); err != nil {
		t.Fatalf("вызов: %v", err)
	}

	event := e.pub.lastUserEvent()
	if event.kind != "CALL_INVITE" {
		t.Fatalf("событие %q, ожидали CALL_INVITE", event.kind)
	}
	if len(event.users) != 1 || event.users[0] != e.member {
		t.Fatalf("вызов ушёл %v, ожидали только получателя %s", event.users, e.member)
	}
	data, ok := event.data.(map[string]any)
	if !ok || data["channel_id"] != channel.ID || data["from_user_id"] != e.owner {
		t.Fatalf("данные вызова: %+v", event.data)
	}
}

func TestInviteRejectsStranger(t *testing.T) {
	e := newVoiceEnv(t)
	ctx := context.Background()

	channel, err := e.dm.Open(ctx, e.owner, e.member)
	if err != nil {
		t.Fatalf("открытие диалога: %v", err)
	}

	if err := e.service.Invite(ctx, e.stranger, channel.ID); !errors.Is(err, voice.ErrForbidden) {
		t.Fatalf("посторонний: ожидали ErrForbidden, получили %v", err)
	}
}

func TestInviteRejectsGuildChannel(t *testing.T) {
	e := newVoiceEnv(t)
	ctx := context.Background()

	if err := e.service.Invite(ctx, e.owner, e.voiceID); !errors.Is(err, voice.ErrValidation) {
		t.Fatalf("канал сервера: ожидали ErrValidation, получили %v", err)
	}
}

func TestDeclineDMNotifiesCaller(t *testing.T) {
	e := newVoiceEnv(t)
	ctx := context.Background()

	channel, err := e.dm.Open(ctx, e.owner, e.member)
	if err != nil {
		t.Fatalf("открытие диалога: %v", err)
	}

	if err := e.service.Decline(ctx, e.member, channel.ID); err != nil {
		t.Fatalf("отклонение: %v", err)
	}

	event := e.pub.lastUserEvent()
	if event.kind != "CALL_DECLINE" {
		t.Fatalf("событие %q, ожидали CALL_DECLINE", event.kind)
	}
	if len(event.users) != 1 || event.users[0] != e.owner {
		t.Fatalf("отклонение ушло %v, ожидали звонящего %s", event.users, e.owner)
	}
}
