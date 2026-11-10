// Package voice — голосовые каналы: выдача токенов LiveKit и учёт сессий.
//
// Токен — обычный JWT, подписанный API-секретом LiveKit. В нём лежит
// grant (поле video), который разрешает вход в конкретную комнату и
// публикацию звука. Сервер LiveKit проверяет подпись сам, наш API в
// момент разговора не участвует.
package voice

import (
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// TokenIssuer выдаёт токены для входа в комнату LiveKit.
type TokenIssuer struct {
	APIKey    string
	APISecret string
	TTL       time.Duration
}

// Issue возвращает токен для комнаты room.
//
// canPublish отвечает за микрофон: без права Speak клиент сможет только
// слушать. Видео выдаётся отдельно через IssueWithSources.
func (i TokenIssuer) Issue(userID, name, room string, canPublish bool) (string, error) {
	var sources []string
	if canPublish {
		sources = []string{"microphone"}
	}
	return i.IssueWithSources(userID, name, room, sources)
}

// IssueWithSources выдаёт токен с конкретными источниками публикации:
// microphone, camera, screen_share, screen_share_audio.
func (i TokenIssuer) IssueWithSources(userID, name, room string, sources []string) (string, error) {
	if i.APIKey == "" || i.APISecret == "" {
		return "", fmt.Errorf("не настроены ключи LiveKit")
	}

	ttl := i.TTL
	if ttl <= 0 {
		ttl = 10 * time.Minute
	}

	now := time.Now()
	claims := jwt.MapClaims{
		"iss":  i.APIKey,
		"sub":  userID,
		"name": name,
		"nbf":  now.Unix(),
		"exp":  now.Add(ttl).Unix(),
		"video": map[string]any{
			"room":              room,
			"roomJoin":          true,
			"canPublish":        len(sources) > 0,
			"canPublishSources": sources,
			"canSubscribe":      true,
			"canPublishData":    true,
		},
	}

	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(i.APISecret))
	if err != nil {
		return "", fmt.Errorf("подпись токена LiveKit: %w", err)
	}
	return token, nil
}
