// Package fanout — доставка событий между экземплярами сервера.
//
// Один сервер обслуживает соединения своим хабом. Когда серверов несколько,
// событие, созданное на узле A, должно дойти до клиентов узла B. Для этого
// публикуем в Redis, а каждый узел подписан на каналы гильдий и раздаёт
// полученное своим соединениям.
//
// Узел-отправитель не дублирует доставку: в сообщении есть node_id, и
// подписчик игнорирует сообщения от самого себя (свои клиенты уже получили
// событие напрямую через хаб).
package fanout

import (
	"context"
	"encoding/json"
	"log/slog"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/Nemanc123/voxnica/internal/chat"
)

const (
	ChannelPrefix = "voxnica:guild:"
	UserPrefix    = "voxnica:user:"
)

const publishTimeout = 2 * time.Second

// Local — то, что умеет доставлять события локальным соединениям. Это хаб.
type Local interface {
	Publish(ctx context.Context, guildID string, event chat.Event)
}

// UserLocal — адресная доставка личных событий.
type UserLocal interface {
	PublishToUsers(ctx context.Context, userIDs []string, eventType string, data any)
}

type wireEvent struct {
	NodeID string     `json:"node_id"`
	Event  chat.Event `json:"event"`
}

type wireUserEvent struct {
	NodeID string          `json:"node_id"`
	Type   string          `json:"type"`
	Data   json.RawMessage `json:"data"`
}

type Publisher struct {
	local  Local
	rdb    *redis.Client
	nodeID string
}

func NewPublisher(local Local, rdb *redis.Client, nodeID string) *Publisher {
	return &Publisher{local: local, rdb: rdb, nodeID: nodeID}
}

// Publish сначала отдаёт событие своим клиентам, потом публикует в Redis.
// Порядок важен: локальная доставка не должна зависеть от доступности Redis.
func (p *Publisher) Publish(ctx context.Context, guildID string, event chat.Event) {
	p.local.Publish(ctx, guildID, event)

	payload, err := json.Marshal(wireEvent{NodeID: p.nodeID, Event: event})
	if err != nil {
		slog.Error("fanout: encode event", "err", err, "type", event.Type)
		return
	}

	pubCtx, cancel := context.WithTimeout(ctx, publishTimeout)
	defer cancel()

	if err := p.rdb.Publish(pubCtx, ChannelPrefix+guildID, payload).Err(); err != nil {
		// Redis упал — локальные клиенты событие уже получили.
		// Теряем только другие узлы; сервер продолжает работать.
		slog.Warn("fanout: redis publish failed", "err", err, "guild_id", guildID)
	}
}

// PublishToUsers — адресная доставка личных событий. В отличие от гильдии,
// публикуем в канал каждого получателя: узел-подписчик знает user_id и
// отдаёт событие только его сессиям.
func (p *Publisher) PublishToUsers(ctx context.Context, userIDs []string, eventType string, data any) {
	if local, ok := p.local.(UserLocal); ok {
		local.PublishToUsers(ctx, userIDs, eventType, data)
	}

	raw, err := json.Marshal(data)
	if err != nil {
		slog.Error("fanout: encode user event", "err", err, "type", eventType)
		return
	}

	payload, err := json.Marshal(wireUserEvent{NodeID: p.nodeID, Type: eventType, Data: raw})
	if err != nil {
		slog.Error("fanout: encode user event", "err", err, "type", eventType)
		return
	}

	pubCtx, cancel := context.WithTimeout(ctx, publishTimeout)
	defer cancel()

	for _, userID := range userIDs {
		if err := p.rdb.Publish(pubCtx, UserPrefix+userID, payload).Err(); err != nil {
			slog.Warn("fanout: user event publish failed",
				"err", err, "user_id", userID)
		}
	}
}

type Subscriber struct {
	local  Local
	rdb    *redis.Client
	nodeID string
}

func NewSubscriber(local Local, rdb *redis.Client, nodeID string) *Subscriber {
	return &Subscriber{local: local, rdb: rdb, nodeID: nodeID}
}

// Run блокируется до отмены контекста.
func (s *Subscriber) Run(ctx context.Context) {
	sub := s.rdb.PSubscribe(ctx, ChannelPrefix+"*", UserPrefix+"*")
	defer func() { _ = sub.Close() }()

	slog.Info("fanout: subscribed to guild and user events", "node_id", s.nodeID)

	for {
		select {
		case <-ctx.Done():
			return
		case msg, ok := <-sub.Channel():
			if !ok {
				return
			}

			if strings.HasPrefix(msg.Channel, UserPrefix) {
				var w wireUserEvent
				if err := json.Unmarshal([]byte(msg.Payload), &w); err != nil {
					slog.Warn("fanout: malformed user message", "err", err)
					continue
				}
				if w.NodeID == s.nodeID {
					continue
				}

				userID := strings.TrimPrefix(msg.Channel, UserPrefix)
				if local, ok := s.local.(UserLocal); ok {
					local.PublishToUsers(ctx, []string{userID}, w.Type, w.Data)
				}
				continue
			}

			var w wireEvent
			if err := json.Unmarshal([]byte(msg.Payload), &w); err != nil {
				slog.Warn("fanout: malformed message", "err", err)
				continue
			}
			if w.NodeID == s.nodeID {
				continue // свои события уже доставлены
			}

			guildID := strings.TrimPrefix(msg.Channel, ChannelPrefix)
			s.local.Publish(ctx, guildID, w.Event)
		}
	}
}
