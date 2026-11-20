package api_test

// Сквозной тест HTTP-слоя: реальные обработчики, реальная база.
// Запускается там, где доступен PostgreSQL (локально в WSL или в CI).

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Nemanc123/voxnica/internal/api"
	"github.com/Nemanc123/voxnica/internal/auth"
	"github.com/Nemanc123/voxnica/internal/chat"
	"github.com/Nemanc123/voxnica/internal/dm"
	"github.com/Nemanc123/voxnica/internal/gateway"
	"github.com/Nemanc123/voxnica/internal/guild"
	"github.com/Nemanc123/voxnica/internal/social"
	"github.com/Nemanc123/voxnica/internal/storage"
	"github.com/Nemanc123/voxnica/internal/store"
	"github.com/Nemanc123/voxnica/internal/voice"
)

const (
	e2eLiveKitKey    = "e2e-key"
	e2eLiveKitSecret = "e2e-livekit-secret"
)

type client struct {
	t     *testing.T
	base  string
	token string
}

func (c *client) do(method, path string, body any) (int, map[string]any) {
	c.t.Helper()

	var reader *bytes.Reader
	if body != nil {
		payload, err := json.Marshal(body)
		if err != nil {
			c.t.Fatalf("кодирование тела: %v", err)
		}
		reader = bytes.NewReader(payload)
	} else {
		reader = bytes.NewReader(nil)
	}

	req, err := http.NewRequest(method, c.base+path, reader)
	if err != nil {
		c.t.Fatalf("запрос: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatalf("%s %s: %v", method, path, err)
	}
	defer func() { _ = resp.Body.Close() }()

	var decoded map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&decoded)
	return resp.StatusCode, decoded
}

func (c *client) mustDo(method, path string, body any, want int) map[string]any {
	c.t.Helper()
	code, decoded := c.do(method, path, body)
	if code != want {
		c.t.Fatalf("%s %s: код %d, ожидали %d (ответ: %v)", method, path, code, want, decoded)
	}
	return decoded
}

// newTestServer собирает полный HTTP-слой на реальной базе во временной
// транзакции. Если хранилище передано — вложения включены.
func newTestServer(t *testing.T, files *storage.Storage) (*httptest.Server, *chat.Service) {
	t.Helper()

	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL не задан")
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
	authSvc := auth.NewService(st, "e2e-secret", 15*time.Minute, time.Hour)
	gs := guild.NewService(st)
	hub := gateway.NewHub()
	hub.SetFilter(gateway.NewCachedFilter(gs, 10*time.Second))

	chatSvc := chat.NewService(st, gs, hub)
	dmSvc := dm.NewService(st)
	chatSvc = chatSvc.WithDM(dmSvc)
	if files != nil {
		chatSvc = chatSvc.WithStorage(files)
	}

	voiceSvc := voice.NewService(st, gs, voice.TokenIssuer{
		APIKey:    e2eLiveKitKey,
		APISecret: e2eLiveKitSecret,
		TTL:       5 * time.Minute,
	}, "ws://localhost:7880", nil)

	router := api.NewRouter(api.Deps{
		Pool:     pool,
		Auth:     api.NewAuthHandlers(authSvc),
		Guild:    api.NewGuildHandlers(gs),
		Messages: api.NewMessageHandlers(chatSvc),
		Presence: api.NewPresenceHandlers(hub, gs),
		Voice:    api.NewVoiceHandlers(voiceSvc),
		Social:   api.NewSocialHandlers(social.NewService(st), hub),
		DM:       api.NewDMHandlers(dmSvc),
	})

	srv := httptest.NewServer(router)
	t.Cleanup(srv.Close)

	return srv, chatSvc
}

func TestHTTPFlow(t *testing.T) {
	srv, _ := newTestServer(t, nil)

	suffix := time.Now().UnixNano()
	alice := &client{t: t, base: srv.URL}
	bob := &client{t: t, base: srv.URL}

	// 1. Регистрация двух пользователей.
	alice.mustDo("POST", "/api/v1/auth/register", map[string]any{
		"username": randomName(suffix, "a"),
		"password": "very-long-password",
	}, http.StatusCreated)
	bob.mustDo("POST", "/api/v1/auth/register", map[string]any{
		"username": randomName(suffix, "b"),
		"password": "very-long-password",
	}, http.StatusCreated)

	// Токены получаем входом: так проверяется и /login.
	aliceLogin := alice.mustDo("POST", "/api/v1/auth/login", map[string]any{
		"login":    randomName(suffix, "a"),
		"password": "very-long-password",
	}, http.StatusOK)
	alice.token = aliceLogin["access_token"].(string)

	bobLogin := bob.mustDo("POST", "/api/v1/auth/login", map[string]any{
		"login":    randomName(suffix, "b"),
		"password": "very-long-password",
	}, http.StatusOK)
	bob.token = bobLogin["access_token"].(string)

	// 2. Сервер и канал.
	created := alice.mustDo("POST", "/api/v1/guilds", map[string]any{
		"name": "E2E сервер",
	}, http.StatusCreated)

	guildObj := created["guild"].(map[string]any)
	guildID := guildObj["id"].(string)

	var channelID string
	for _, raw := range created["channels"].([]any) {
		ch := raw.(map[string]any)
		if ch["type"] == "text" {
			channelID = ch["id"].(string)
			break
		}
	}
	if channelID == "" {
		t.Fatal("текстовый канал не найден")
	}

	// 3. Два сообщения.
	first := alice.mustDo("POST", "/api/v1/channels/"+channelID+"/messages",
		map[string]any{"content": "первое"}, http.StatusCreated)
	second := alice.mustDo("POST", "/api/v1/channels/"+channelID+"/messages",
		map[string]any{"content": "второе"}, http.StatusCreated)

	if first["seq"].(float64) >= second["seq"].(float64) {
		t.Fatal("seq должен возрастать")
	}

	// 4. Лента.
	history := alice.mustDo("GET", "/api/v1/channels/"+channelID+"/messages", nil, http.StatusOK)
	if got := len(history["messages"].([]any)); got != 2 {
		t.Fatalf("в ленте %d сообщений, ожидали 2", got)
	}

	// 5. Приглашение и вступление.
	invite := alice.mustDo("POST", "/api/v1/guilds/"+guildID+"/invites",
		map[string]any{"channel_id": channelID}, http.StatusCreated)
	bob.mustDo("POST", "/api/v1/invites/"+invite["code"].(string), map[string]any{}, http.StatusOK)

	// 5.0. Негативные сценарии приглашений.
	// Без channel_id — понятная 400, а не 500 из приведения к uuid.
	alice.mustDo("POST", "/api/v1/guilds/"+guildID+"/invites",
		map[string]any{}, http.StatusBadRequest)

	// Канал из другого сервера не должен подходить (иначе приглашение
	// ссылается на чужой канал).
	other := alice.mustDo("POST", "/api/v1/guilds", map[string]any{
		"name": "Другой сервер",
	}, http.StatusCreated)
	var otherChannelID string
	for _, raw := range other["channels"].([]any) {
		ch := raw.(map[string]any)
		if ch["type"] == "text" {
			otherChannelID = ch["id"].(string)
			break
		}
	}
	if otherChannelID == "" {
		t.Fatal("во втором сервере нет текстового канала")
	}
	alice.mustDo("POST", "/api/v1/guilds/"+guildID+"/invites",
		map[string]any{"channel_id": otherChannelID}, http.StatusBadRequest)

	// Неизвестный код — 404, а не 500.
	bob.mustDo("POST", "/api/v1/invites/zzzzzz", map[string]any{}, http.StatusNotFound)

	// 5.1. Список участников: владелец и вступивший.
	members := bob.mustDo("GET", "/api/v1/guilds/"+guildID+"/members", nil, http.StatusOK)
	if got := len(members["members"].([]any)); got != 2 {
		t.Fatalf("участников %d, ожидали 2", got)
	}

	// 6. Непрочитанные у bob.
	unread := bob.mustDo("GET", "/api/v1/guilds/"+guildID+"/unread", nil, http.StatusOK)
	if got := unreadForChannel(t, unread, channelID); got != 2 {
		t.Fatalf("непрочитано %d, ожидали 2", got)
	}

	// 7. Отметка о прочтении.
	bob.mustDo("POST", "/api/v1/channels/"+channelID+"/read",
		map[string]any{"seq": second["seq"]}, http.StatusNoContent)

	unread = bob.mustDo("GET", "/api/v1/guilds/"+guildID+"/unread", nil, http.StatusOK)
	if got := unreadForChannel(t, unread, channelID); got != 0 {
		t.Fatalf("после прочтения непрочитано %d", got)
	}

	// 8. Правка и удаление.
	edited := alice.mustDo("PATCH", "/api/v1/messages/"+first["id"].(string),
		map[string]any{"content": "первое (исправлено)"}, http.StatusOK)
	if edited["edited_at"] == nil {
		t.Fatal("edited_at не заполнен")
	}

	alice.mustDo("DELETE", "/api/v1/messages/"+second["id"].(string), nil, http.StatusNoContent)

	history = alice.mustDo("GET", "/api/v1/channels/"+channelID+"/messages", nil, http.StatusOK)
	if got := len(history["messages"].([]any)); got != 1 {
		t.Fatalf("после удаления в ленте %d сообщений, ожидали 1", got)
	}

	// 9. Presence без подключённых сокетов.
	presence := alice.mustDo("GET", "/api/v1/guilds/"+guildID+"/presence", nil, http.StatusOK)
	if got := len(presence["online"].([]any)); got != 0 {
		t.Fatalf("онлайн = %d, ожидали 0", got)
	}

	// 10. Посторонний не видит непрочитанные чужого сервера.
	stranger := &client{t: t, base: srv.URL}
	reg := stranger.mustDo("POST", "/api/v1/auth/register", map[string]any{
		"username": randomName(suffix, "c"),
		"password": "very-long-password",
	}, http.StatusCreated)
	stranger.token = reg["access_token"].(string)

	stranger.mustDo("GET", "/api/v1/guilds/"+guildID+"/unread", nil, http.StatusForbidden)
	stranger.mustDo("GET", "/api/v1/guilds/"+guildID+"/members", nil, http.StatusForbidden)
}

func randomName(seed int64, prefix string) string {
	// Допустимые символы: a-z, 0-9, _.
	return "e2e" + prefix + time.Unix(0, seed).Format("150405") + "x"
}

func unreadForChannel(t *testing.T, payload map[string]any, channelID string) int64 {
	t.Helper()

	items, ok := payload["channels"].([]any)
	if !ok {
		t.Fatalf("нет поля channels: %v", payload)
	}
	for _, raw := range items {
		item := raw.(map[string]any)
		if item["channel_id"] == channelID {
			return int64(item["unread"].(float64))
		}
	}
	t.Fatalf("канал %s не найден в ответе", channelID)
	return 0
}

// TestHTTPAttachments — полный путь файла: ссылка на загрузку → PUT в
// хранилище → сообщение со вложением → вложение в ленте.
func TestHTTPAttachments(t *testing.T) {
	endpoint := os.Getenv("STORAGE_ENDPOINT")
	if endpoint == "" {
		t.Skip("STORAGE_ENDPOINT не задан")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	files, err := storage.New(ctx, storage.Config{
		Endpoint:  endpoint,
		AccessKey: envOr("STORAGE_ACCESS_KEY", "dcstorage"),
		SecretKey: envOr("STORAGE_SECRET_KEY", "devstorage123"),
		Bucket:    envOr("STORAGE_BUCKET", "voxnica-e2e"),
	})
	if err != nil {
		t.Skipf("хранилище недоступно: %v", err)
	}

	srv, _ := newTestServer(t, files)

	suffix := time.Now().UnixNano()
	alice := &client{t: t, base: srv.URL}

	reg := alice.mustDo("POST", "/api/v1/auth/register", map[string]any{
		"username": randomName(suffix, "f"),
		"password": "very-long-password",
	}, http.StatusCreated)
	alice.token = reg["access_token"].(string)

	created := alice.mustDo("POST", "/api/v1/guilds", map[string]any{
		"name": "E2E вложения",
	}, http.StatusCreated)

	var channelID string
	for _, raw := range created["channels"].([]any) {
		ch := raw.(map[string]any)
		if ch["type"] == "text" {
			channelID = ch["id"].(string)
			break
		}
	}
	if channelID == "" {
		t.Fatal("текстовый канал не найден")
	}

	// 1. Ссылка на загрузку.
	presign := alice.mustDo("POST", "/api/v1/channels/"+channelID+"/attachments/presign", map[string]any{
		"filename":     "заметка.txt",
		"content_type": "text/plain",
		"size_bytes":   len("содержимое файла"),
	}, http.StatusCreated)

	storageKey := presign["storage_key"].(string)
	uploadURL := presign["upload_url"].(string)
	if storageKey == "" || uploadURL == "" {
		t.Fatalf("пустой ответ presign: %v", presign)
	}

	// 2. Загрузка напрямую в хранилище, мимо сервера.
	body := []byte("содержимое файла")
	req, err := http.NewRequest(http.MethodPut, uploadURL, bytes.NewReader(body))
	if err != nil {
		t.Fatalf("запрос загрузки: %v", err)
	}
	req.Header.Set("Content-Type", "text/plain")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("загрузка: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		t.Fatalf("загрузка вернула %d", resp.StatusCode)
	}

	// 3. Сообщение с вложением: в ответе вложение должно быть сразу.
	posted := alice.mustDo("POST", "/api/v1/channels/"+channelID+"/messages", map[string]any{
		"content": "файл во вложении",
		"attachments": []map[string]any{{
			"storage_key":  storageKey,
			"filename":     "заметка.txt",
			"content_type": "text/plain",
			"size_bytes":   len(body),
		}},
	}, http.StatusCreated)

	attachments, ok := posted["attachments"].([]any)
	if !ok || len(attachments) != 1 {
		t.Fatalf("в ответе нет вложения: %v", posted)
	}
	if attachments[0].(map[string]any)["storage_key"] != storageKey {
		t.Fatalf("ключ вложения не совпал: %v", attachments[0])
	}

	// 4. Лента тоже отдаёт вложение.
	history := alice.mustDo("GET", "/api/v1/channels/"+channelID+"/messages", nil, http.StatusOK)
	messages := history["messages"].([]any)
	if len(messages) != 1 {
		t.Fatalf("в ленте %d сообщений, ожидали 1", len(messages))
	}
	fromHistory, ok := messages[0].(map[string]any)["attachments"].([]any)
	if !ok || len(fromHistory) != 1 {
		t.Fatalf("в ленте нет вложения: %v", messages[0])
	}

	attachmentID := attachments[0].(map[string]any)["id"].(string)

	// 5. Скачивание: 302 на подписанную ссылку, файл отдаёт само хранилище.
	noRedirect := &http.Client{
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	dlReq, err := http.NewRequest(http.MethodGet, srv.URL+"/api/v1/attachments/"+attachmentID+"/download", nil)
	if err != nil {
		t.Fatalf("запрос скачивания: %v", err)
	}
	dlReq.Header.Set("Authorization", "Bearer "+alice.token)

	dlResp, err := noRedirect.Do(dlReq)
	if err != nil {
		t.Fatalf("скачивание: %v", err)
	}
	_ = dlResp.Body.Close()
	if dlResp.StatusCode != http.StatusFound {
		t.Fatalf("скачивание вернуло %d, ожидали 302", dlResp.StatusCode)
	}

	location := dlResp.Header.Get("Location")
	if location == "" {
		t.Fatal("нет Location в ответе скачивания")
	}

	fileResp, err := http.Get(location)
	if err != nil {
		t.Fatalf("получение файла по ссылке: %v", err)
	}
	defer func() { _ = fileResp.Body.Close() }()

	downloaded, err := io.ReadAll(fileResp.Body)
	if err != nil {
		t.Fatalf("чтение файла: %v", err)
	}
	if !bytes.Equal(downloaded, body) {
		t.Fatalf("содержимое не совпало: %q", downloaded)
	}

	// 6. Посторонний не получает ссылку.
	stranger := &client{t: t, base: srv.URL}
	regStranger := stranger.mustDo("POST", "/api/v1/auth/register", map[string]any{
		"username": randomName(suffix, "g"),
		"password": "very-long-password",
	}, http.StatusCreated)
	stranger.token = regStranger["access_token"].(string)
	stranger.mustDo("GET", "/api/v1/attachments/"+attachmentID+"/download", nil, http.StatusForbidden)

	// 7. Несуществующее вложение — 404.
	alice.mustDo("GET", "/api/v1/attachments/00000000-0000-0000-0000-000000000000/download", nil, http.StatusNotFound)

	// 8. Несуществующий ключ прикрепить нельзя.
	alice.mustDo("POST", "/api/v1/channels/"+channelID+"/messages", map[string]any{
		"content": "битая ссылка",
		"attachments": []map[string]any{{
			"storage_key":  "attachments/нет-такого/файл.txt",
			"filename":     "файл.txt",
			"content_type": "text/plain",
			"size_bytes":   10,
		}},
	}, http.StatusBadRequest)
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// TestHTTPVoice — голос через HTTP: токен, список участников, вебхуки.
func TestHTTPVoice(t *testing.T) {
	srv, _ := newTestServer(t, nil)

	alice := &client{t: t, base: srv.URL}
	reg := alice.mustDo("POST", "/api/v1/auth/register", map[string]any{
		"username": randomName(time.Now().UnixNano(), "v"),
		"password": "very-long-password",
	}, http.StatusCreated)
	alice.token = reg["access_token"].(string)
	aliceID := reg["user"].(map[string]any)["id"].(string)

	created := alice.mustDo("POST", "/api/v1/guilds", map[string]any{
		"name": "E2E голос",
	}, http.StatusCreated)

	var voiceID string
	for _, raw := range created["channels"].([]any) {
		ch := raw.(map[string]any)
		if ch["type"] == "voice" {
			voiceID = ch["id"].(string)
			break
		}
	}
	if voiceID == "" {
		t.Fatal("голосовой канал не найден")
	}

	// 1. Токен на вход.
	joined := alice.mustDo("POST", "/api/v1/channels/"+voiceID+"/voice/join", map[string]any{}, http.StatusOK)
	if joined["room"] != voiceID {
		t.Fatalf("room = %v, ожидали %s", joined["room"], voiceID)
	}
	if joined["url"] != "ws://localhost:7880" {
		t.Fatalf("url = %v", joined["url"])
	}
	if joined["can_publish"] != true {
		t.Fatalf("can_publish = %v", joined["can_publish"])
	}

	token, _ := joined["token"].(string)
	if token == "" {
		t.Fatal("пустой токен")
	}
	parsed, err := jwt.Parse(token, func(*jwt.Token) (any, error) {
		return []byte(e2eLiveKitSecret), nil
	}, jwt.WithValidMethods([]string{"HS256"}))
	if err != nil || !parsed.Valid {
		t.Fatalf("токен не разобрался: %v", err)
	}

	// 2. Пока никто не зашёл — список пуст.
	list := alice.mustDo("GET", "/api/v1/channels/"+voiceID+"/voice", nil, http.StatusOK)
	if got := len(list["participants"].([]any)); got != 0 {
		t.Fatalf("участников %d, ожидали 0", got)
	}

	// 3. Вебхук с плохой подписью отклоняется.
	joinBody := e2eWebhookBody(t, "participant_joined", voiceID, aliceID)
	if code := e2eWebhook(t, srv.URL, "bad-token", joinBody); code != http.StatusUnauthorized {
		t.Fatalf("плохая подпись: код %d, ожидали 401", code)
	}

	// 4. Настоящий вебхук входа создаёт сессию.
	if code := e2eWebhook(t, srv.URL, e2eSignWebhook(t, joinBody), joinBody); code != http.StatusOK {
		t.Fatalf("вход: код %d, ожидали 200", code)
	}

	list = alice.mustDo("GET", "/api/v1/channels/"+voiceID+"/voice", nil, http.StatusOK)
	participants := list["participants"].([]any)
	if len(participants) != 1 {
		t.Fatalf("участников %d, ожидали 1", len(participants))
	}
	if participants[0].(map[string]any)["user_id"] != aliceID {
		t.Fatalf("не тот участник: %v", participants[0])
	}

	// 4.1. Mute и deaf сохраняются в voice_sessions.
	alice.mustDo(
		"PATCH",
		"/api/v1/channels/"+voiceID+"/voice/state",
		map[string]any{"self_mute": true, "self_deaf": true},
		http.StatusNoContent,
	)

	list = alice.mustDo("GET", "/api/v1/channels/"+voiceID+"/voice", nil, http.StatusOK)
	state := list["participants"].([]any)[0].(map[string]any)
	if state["self_mute"] != true || state["self_deaf"] != true {
		t.Fatalf("состояние не сохранилось: %v", state)
	}

	// 5. Посторонний не видит участников.
	stranger := &client{t: t, base: srv.URL}
	regStranger := stranger.mustDo("POST", "/api/v1/auth/register", map[string]any{
		"username": randomName(time.Now().UnixNano(), "w"),
		"password": "very-long-password",
	}, http.StatusCreated)
	stranger.token = regStranger["access_token"].(string)
	stranger.mustDo("GET", "/api/v1/channels/"+voiceID+"/voice", nil, http.StatusForbidden)

	// 6. Выход закрывает сессию.
	leaveBody := e2eWebhookBody(t, "participant_left", voiceID, aliceID)
	if code := e2eWebhook(t, srv.URL, e2eSignWebhook(t, leaveBody), leaveBody); code != http.StatusOK {
		t.Fatalf("выход: код %d, ожидали 200", code)
	}

	list = alice.mustDo("GET", "/api/v1/channels/"+voiceID+"/voice", nil, http.StatusOK)
	if got := len(list["participants"].([]any)); got != 0 {
		t.Fatalf("после выхода участников %d", got)
	}
}

func e2eSignWebhook(t *testing.T, body []byte) string {
	t.Helper()

	sum := sha256.Sum256(body)
	claims := jwt.MapClaims{
		"iss":    e2eLiveKitKey,
		"sha256": base64.StdEncoding.EncodeToString(sum[:]),
		"exp":    time.Now().Add(time.Minute).Unix(),
	}
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(e2eLiveKitSecret))
	if err != nil {
		t.Fatalf("подпись вебхука: %v", err)
	}
	return token
}

func e2eWebhookBody(t *testing.T, event, channelID, userID string) []byte {
	t.Helper()

	payload := map[string]any{
		"event": event,
		"room":  map[string]any{"name": channelID, "sid": "RM_e2e"},
	}
	if userID != "" {
		payload["participant"] = map[string]any{"identity": userID, "name": "e2e"}
	}

	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("тело вебхука: %v", err)
	}
	return body
}

func e2eWebhook(t *testing.T, base, token string, body []byte) int {
	t.Helper()

	req, err := http.NewRequest(http.MethodPost, base+"/webhooks/livekit", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("запрос вебхука: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", token)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("вебхук: %v", err)
	}
	_ = resp.Body.Close()
	return resp.StatusCode
}

// TestRelationshipsFlow проверяет друзей через HTTP: заявка, принятие,
// поиск, блокировка и запрет на действия с самим собой.
func TestRelationshipsFlow(t *testing.T) {
	srv, _ := newTestServer(t, nil)
	suffix := time.Now().UnixNano()

	alice := &client{t: t, base: srv.URL}
	bob := &client{t: t, base: srv.URL}

	aliceName := randomName(suffix, "a")
	bobName := randomName(suffix, "b")

	alice.mustDo("POST", "/api/v1/auth/register", map[string]any{
		"username": aliceName,
		"password": "very-long-password",
	}, http.StatusCreated)
	bob.mustDo("POST", "/api/v1/auth/register", map[string]any{
		"username": bobName,
		"password": "very-long-password",
	}, http.StatusCreated)

	aliceLogin := alice.mustDo("POST", "/api/v1/auth/login", map[string]any{
		"login":    aliceName,
		"password": "very-long-password",
	}, http.StatusOK)
	alice.token = aliceLogin["access_token"].(string)
	aliceID := aliceLogin["user"].(map[string]any)["id"].(string)

	bobLogin := bob.mustDo("POST", "/api/v1/auth/login", map[string]any{
		"login":    bobName,
		"password": "very-long-password",
	}, http.StatusOK)
	bob.token = bobLogin["access_token"].(string)
	bobID := bobLogin["user"].(map[string]any)["id"].(string)

	// 1. Списки пустые.
	list := alice.mustDo("GET", "/api/v1/relationships", nil, http.StatusOK)
	if got := len(list["friends"].([]any)); got != 0 {
		t.Fatalf("друзей %d, ожидали 0", got)
	}

	// 2. Заявка от alice к bob.
	alice.mustDo("POST", "/api/v1/relationships/"+bobID,
		map[string]any{"action": "request"}, http.StatusNoContent)

	list = bob.mustDo("GET", "/api/v1/relationships", nil, http.StatusOK)
	if got := len(list["incoming"].([]any)); got != 1 {
		t.Fatalf("входящих %d, ожидали 1", got)
	}

	// 3. Повторная заявка — конфликт.
	alice.mustDo("POST", "/api/v1/relationships/"+bobID,
		map[string]any{"action": "request"}, http.StatusConflict)

	// 3.1. Отправитель не может принять свою заявку: согласия адресата нет.
	alice.mustDo("POST", "/api/v1/relationships/"+bobID,
		map[string]any{"action": "accept"}, http.StatusNotFound)

	// 4. Принятие.
	bob.mustDo("POST", "/api/v1/relationships/"+aliceID,
		map[string]any{"action": "accept"}, http.StatusNoContent)

	list = alice.mustDo("GET", "/api/v1/relationships", nil, http.StatusOK)
	friends := list["friends"].([]any)
	if len(friends) != 1 {
		t.Fatalf("друзей %d, ожидали 1", len(friends))
	}
	friend := friends[0].(map[string]any)["user"].(map[string]any)
	if friend["id"] != bobID {
		t.Fatalf("друг %v, ожидали %s", friend["id"], bobID)
	}
	if _, leaked := friend["email"]; leaked {
		t.Fatal("в ответе не должно быть почты")
	}

	// 5. Поиск показывает отношение.
	found := bob.mustDo("GET", "/api/v1/users/search?q="+aliceName, nil, http.StatusOK)
	users := found["users"].([]any)
	if len(users) == 0 {
		t.Fatal("поиск по логину ничего не нашёл")
	}
	if got := users[0].(map[string]any)["relation"]; got != "friend" {
		t.Fatalf("отношение %v, ожидали friend", got)
	}

	// 5.1. Присутствие: друзья в ответе, оба сейчас не в сети
	// (WebSocket в этом тесте не открывается).
	presence := alice.mustDo("GET", "/api/v1/relationships/presence", nil, http.StatusOK)
	statuses := presence["presence"].(map[string]any)
	if statuses[bobID] != "offline" {
		t.Fatalf("статус друга %v, ожидали offline", statuses[bobID])
	}

	// 6. Кривой ввод.
	alice.mustDo("POST", "/api/v1/relationships/"+bobID,
		map[string]any{"action": "teleport"}, http.StatusBadRequest)
	alice.mustDo("GET", "/api/v1/users/search?q=a", nil, http.StatusBadRequest)
	alice.mustDo("POST", "/api/v1/relationships/00000000-0000-0000-0000-000000000000",
		map[string]any{"action": "request"}, http.StatusNotFound)
	alice.mustDo("POST", "/api/v1/relationships/"+aliceID,
		map[string]any{"action": "request"}, http.StatusBadRequest)

	// 6.1. Невалидный идентификатор — понятная 400, а не 500 из ::uuid.
	alice.mustDo("POST", "/api/v1/relationships/abc",
		map[string]any{"action": "request"}, http.StatusBadRequest)
	alice.mustDo("DELETE", "/api/v1/relationships/abc", nil, http.StatusBadRequest)
	alice.mustDo("PUT", "/api/v1/relationships/abc/block",
		map[string]any{"blocked": true}, http.StatusBadRequest)

	// 7. Блокировка: заявка от заблокированного не проходит,
	// и он больше не видит alice в поиске.
	alice.mustDo("PUT", "/api/v1/relationships/"+bobID+"/block",
		map[string]any{"blocked": true}, http.StatusNoContent)

	bob.mustDo("POST", "/api/v1/relationships/"+aliceID,
		map[string]any{"action": "request"}, http.StatusForbidden)

	found = bob.mustDo("GET", "/api/v1/users/search?q="+aliceName, nil, http.StatusOK)
	if got := len(found["users"].([]any)); got != 0 {
		t.Fatalf("заблокировавший не должен находиться в поиске, найдено %d", got)
	}

	// 8. Снятие блокировки возвращает дружбу (решение 20.11.2026):
	// блокировали друга — значит, друг вернулся.
	alice.mustDo("PUT", "/api/v1/relationships/"+bobID+"/block",
		map[string]any{"blocked": false}, http.StatusNoContent)

	list = alice.mustDo("GET", "/api/v1/relationships", nil, http.StatusOK)
	if got := len(list["friends"].([]any)); got != 1 {
		t.Fatalf("после разблокировки друзей %d, ожидали 1", got)
	}
	if got := len(list["blocked"].([]any)); got != 0 {
		t.Fatalf("после разблокировки заблокированных %d, ожидали 0", got)
	}

	// 8.1. Поиск у обеих сторон снова показывает дружбу.
	found = bob.mustDo("GET", "/api/v1/users/search?q="+aliceName, nil, http.StatusOK)
	users = found["users"].([]any)
	if len(users) != 1 || users[0].(map[string]any)["relation"] != "friend" {
		t.Fatalf("bob должен видеть alice другом, получено %v", users)
	}
}

// TestSocialRateLimits проверяет, что поиск и заявки ограничены по частоте.
//
// Лимиты живут в памяти обработчика, поэтому здесь отдельный сервер:
// в TestRelationshipsFlow счётчики уже израсходованы.
func TestSocialRateLimits(t *testing.T) {
	srv, _ := newTestServer(t, nil)
	suffix := time.Now().UnixNano()

	c := &client{t: t, base: srv.URL}
	name := randomName(suffix, "rl")
	c.mustDo("POST", "/api/v1/auth/register", map[string]any{
		"username": name,
		"password": "very-long-password",
	}, http.StatusCreated)
	login := c.mustDo("POST", "/api/v1/auth/login", map[string]any{
		"login":    name,
		"password": "very-long-password",
	}, http.StatusOK)
	c.token = login["access_token"].(string)

	// Поиск: 20 в минуту.
	for i := 0; i < 20; i++ {
		c.mustDo("GET", "/api/v1/users/search?q=ab", nil, http.StatusOK)
	}
	c.mustDo("GET", "/api/v1/users/search?q=ab", nil, http.StatusTooManyRequests)

	// Заявки: 10 в час. Каждый запрос уходит на несуществующего
	// пользователя и получает 404, но лимит расходуется до похода в базу.
	for i := 0; i < 10; i++ {
		target := fmt.Sprintf("00000000-0000-0000-0000-%012d", i+1)
		c.mustDo("POST", "/api/v1/relationships/"+target,
			map[string]any{"action": "request"}, http.StatusNotFound)
	}
	c.mustDo("POST", "/api/v1/relationships/00000000-0000-0000-0000-000000000099",
		map[string]any{"action": "request"}, http.StatusTooManyRequests)
}

// TestDMBlockedAfterOpen проверяет обещание интерфейса: после блокировки
// в уже открытом диалоге нельзя ни писать, ни получать доступ.
func TestDMBlockedAfterOpen(t *testing.T) {
	srv, _ := newTestServer(t, nil)
	suffix := time.Now().UnixNano()

	alice := &client{t: t, base: srv.URL}
	bob := &client{t: t, base: srv.URL}

	aliceName := randomName(suffix, "da")
	bobName := randomName(suffix, "db")

	alice.mustDo("POST", "/api/v1/auth/register", map[string]any{
		"username": aliceName,
		"password": "very-long-password",
	}, http.StatusCreated)
	bob.mustDo("POST", "/api/v1/auth/register", map[string]any{
		"username": bobName,
		"password": "very-long-password",
	}, http.StatusCreated)

	aliceLogin := alice.mustDo("POST", "/api/v1/auth/login", map[string]any{
		"login":    aliceName,
		"password": "very-long-password",
	}, http.StatusOK)
	alice.token = aliceLogin["access_token"].(string)
	aliceID := aliceLogin["user"].(map[string]any)["id"].(string)

	bobLogin := bob.mustDo("POST", "/api/v1/auth/login", map[string]any{
		"login":    bobName,
		"password": "very-long-password",
	}, http.StatusOK)
	bob.token = bobLogin["access_token"].(string)
	bobID := bobLogin["user"].(map[string]any)["id"].(string)

	// Диалог с незнакомцем: дружба и общий сервер не нужны.
	dm := alice.mustDo("POST", "/api/v1/dms", map[string]any{
		"user_id": bobID,
	}, http.StatusOK)
	channelID := dm["id"].(string)

	alice.mustDo("POST", "/api/v1/channels/"+channelID+"/messages",
		map[string]any{"content": "до блокировки"}, http.StatusCreated)

	// bob блокирует alice.
	bob.mustDo("PUT", "/api/v1/relationships/"+aliceID+"/block",
		map[string]any{"blocked": true}, http.StatusNoContent)

	// Ни заблокированный, ни блокирующий писать не могут.
	alice.mustDo("POST", "/api/v1/channels/"+channelID+"/messages",
		map[string]any{"content": "после блокировки"}, http.StatusForbidden)
	bob.mustDo("POST", "/api/v1/channels/"+channelID+"/messages",
		map[string]any{"content": "после блокировки"}, http.StatusForbidden)

	// И новый диалог открыть тоже нельзя.
	alice.mustDo("POST", "/api/v1/dms", map[string]any{
		"user_id": bobID,
	}, http.StatusForbidden)
}

// TestGroupDMFlow проверяет групповые диалоги через HTTP: создание, список,
// добавление и удаление участников, переименование, права и сообщения.
func TestGroupDMFlow(t *testing.T) {
	srv, _ := newTestServer(t, nil)
	suffix := time.Now().UnixNano()

	type account struct {
		c    *client
		id   string
		name string
	}

	makeAccount := func(prefix string) account {
		name := randomName(suffix, prefix)
		c := &client{t: t, base: srv.URL}
		c.mustDo("POST", "/api/v1/auth/register", map[string]any{
			"username": name,
			"password": "very-long-password",
		}, http.StatusCreated)
		login := c.mustDo("POST", "/api/v1/auth/login", map[string]any{
			"login":    name,
			"password": "very-long-password",
		}, http.StatusOK)
		c.token = login["access_token"].(string)
		return account{
			c:    c,
			id:   login["user"].(map[string]any)["id"].(string),
			name: name,
		}
	}

	alice := makeAccount("ga")
	bob := makeAccount("gb")
	carol := makeAccount("gc")
	dave := makeAccount("gd")

	// 1. Группа из трёх человек.
	created := alice.c.mustDo("POST", "/api/v1/dms/group", map[string]any{
		"recipient_ids": []string{bob.id, carol.id},
		"name":          "Проект",
	}, http.StatusCreated)
	groupID := created["id"].(string)
	if created["type"] != "group_dm" {
		t.Fatalf("тип %v, ожидали group_dm", created["type"])
	}
	if got := len(created["recipients"].([]any)); got != 3 {
		t.Fatalf("участников %d, ожидали 3", got)
	}
	if created["name"] != "Проект" {
		t.Fatalf("имя %v, ожидали «Проект»", created["name"])
	}

	// 2. Группа видна всем участникам и не видна постороннему.
	for _, acc := range []account{alice, bob, carol} {
		list := acc.c.mustDo("GET", "/api/v1/dms", nil, http.StatusOK)
		found := false
		for _, raw := range list["channels"].([]any) {
			if raw.(map[string]any)["id"] == groupID {
				found = true
			}
		}
		if !found {
			t.Fatalf("%s не видит группу в списке", acc.name)
		}
	}
	daveList := dave.c.mustDo("GET", "/api/v1/dms", nil, http.StatusOK)
	for _, raw := range daveList["channels"].([]any) {
		if raw.(map[string]any)["id"] == groupID {
			t.Fatal("посторонний не должен видеть группу")
		}
	}

	// 3. Посторонний не может ни добавлять, ни переименовывать.
	dave.c.mustDo("POST", "/api/v1/dms/"+groupID+"/recipients",
		map[string]any{"user_id": dave.id}, http.StatusForbidden)
	dave.c.mustDo("PATCH", "/api/v1/dms/"+groupID,
		map[string]any{"name": "Чужое"}, http.StatusForbidden)

	// 4. Участник добавляет четвёртого.
	added := bob.c.mustDo("POST", "/api/v1/dms/"+groupID+"/recipients",
		map[string]any{"user_id": dave.id}, http.StatusOK)
	if got := len(added["recipients"].([]any)); got != 4 {
		t.Fatalf("после добавления участников %d, ожидали 4", got)
	}

	// 5. Переименование.
	renamed := carol.c.mustDo("PATCH", "/api/v1/dms/"+groupID,
		map[string]any{"name": "  Новое  "}, http.StatusOK)
	if renamed["name"] != "Новое" {
		t.Fatalf("имя %v, ожидали «Новое»", renamed["name"])
	}

	// 6. Сообщение в группе доступно участнику.
	msg := bob.c.mustDo("POST", "/api/v1/channels/"+groupID+"/messages",
		map[string]any{"content": "привет группе"}, http.StatusCreated)
	if msg["content"] != "привет группе" {
		t.Fatalf("сообщение %v", msg["content"])
	}
	dave.c.mustDo("GET", "/api/v1/channels/"+groupID+"/messages",
		nil, http.StatusOK)

	// 7. Удаление участника: он теряет доступ и больше не видит группу.
	bob.c.mustDo("DELETE", "/api/v1/dms/"+groupID+"/recipients/"+dave.id,
		nil, http.StatusNoContent)
	dave.c.mustDo("GET", "/api/v1/channels/"+groupID+"/messages",
		nil, http.StatusForbidden)
	daveList = dave.c.mustDo("GET", "/api/v1/dms", nil, http.StatusOK)
	for _, raw := range daveList["channels"].([]any) {
		if raw.(map[string]any)["id"] == groupID {
			t.Fatal("удалённый не должен видеть группу")
		}
	}

	// 8. Ошибки: группа из двух, неверный UUID, несуществующая группа.
	alice.c.mustDo("POST", "/api/v1/dms/group", map[string]any{
		"recipient_ids": []string{bob.id},
	}, http.StatusBadRequest)
	alice.c.mustDo("POST", "/api/v1/dms/group", map[string]any{
		"recipient_ids": []string{bob.id, "abc"},
	}, http.StatusBadRequest)
	alice.c.mustDo("PATCH", "/api/v1/dms/abc",
		map[string]any{"name": "x"}, http.StatusBadRequest)
	alice.c.mustDo("POST", "/api/v1/dms/00000000-0000-0000-0000-000000000000/recipients",
		map[string]any{"user_id": bob.id}, http.StatusNotFound)
}
