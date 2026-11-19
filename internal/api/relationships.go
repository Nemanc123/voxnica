package api

import (
	"errors"
	"log/slog"
	"net/http"
	"regexp"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/Nemanc123/voxnica/internal/social"
	"github.com/Nemanc123/voxnica/internal/store"
)

// uuidPattern проверяет формат идентификатора до похода в базу.
//
// Без этой проверки значение вида `/relationships/abc` доходит до
// `$1::uuid`, Postgres возвращает «invalid input syntax for type uuid»,
// и клиент получает 500 вместо понятной 400.
var uuidPattern = regexp.MustCompile(
	`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`,
)

func validUserID(id string) bool { return uuidPattern.MatchString(id) }

// SocialHandlers — друзья, заявки, блокировки и поиск людей.
type SocialHandlers struct {
	svc *social.Service

	// Лимиты держим в памяти процесса: при нескольких экземплярах сервера
	// они умножаются на их число. Так же устроен лимит входа (auth.go),
	// и по той же причине — переезд в Redis отложен.
	searchLimiter  *rateLimiter
	requestLimiter *rateLimiter
}

func NewSocialHandlers(svc *social.Service) *SocialHandlers {
	return &SocialHandlers{
		svc:            svc,
		searchLimiter:  newRateLimiter(20, time.Minute),
		requestLimiter: newRateLimiter(10, time.Hour),
	}
}

// userCard — безопасное представление пользователя для ответа.
// Пароль и почта наружу не уходят никогда.
type userCard struct {
	ID          string  `json:"id"`
	Username    string  `json:"username"`
	DisplayName *string `json:"display_name,omitempty"`
}

func toCard(u store.User) userCard {
	return userCard{ID: u.ID, Username: u.Username, DisplayName: u.DisplayName}
}

type relationshipItem struct {
	User  userCard `json:"user"`
	Since string   `json:"since"`
}

func toItems(entries []social.Entry) []relationshipItem {
	out := make([]relationshipItem, 0, len(entries))
	for _, e := range entries {
		out = append(out, relationshipItem{
			User:  toCard(e.User),
			Since: e.Since.UTC().Format(time.RFC3339),
		})
	}
	return out
}

// List отдаёт все связи сразу: друзей, входящие, исходящие и блокировки.
//
// Отдельные запросы на каждую корзину означали бы четыре похода в базу
// при открытии экрана «Друзья».
func (h *SocialHandlers) List(w http.ResponseWriter, r *http.Request) {
	userID, _ := UserIDFrom(r.Context())

	view, err := h.svc.List(r.Context(), userID)
	if err != nil {
		mapSocialError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"friends":  toItems(view.Friends),
		"incoming": toItems(view.Incoming),
		"outgoing": toItems(view.Outgoing),
		"blocked":  toItems(view.Blocked),
	})
}

type relationshipActionRequest struct {
	Action string `json:"action"`
}

// Act выполняет действие над связью: отправить заявку или принять её.
//
// Один маршрут на два действия, потому что оба меняют одну и ту же пару
// строк и различаются только переходом состояния.
func (h *SocialHandlers) Act(w http.ResponseWriter, r *http.Request) {
	userID, _ := UserIDFrom(r.Context())
	target := chi.URLParam(r, "userID")

	if !validUserID(target) {
		writeError(w, http.StatusBadRequest, "validation_error", "неверный идентификатор пользователя")
		return
	}

	var req relationshipActionRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", "тело запроса должно быть JSON-объектом")
		return
	}

	var err error
	switch req.Action {
	case "request":
		if !h.requestLimiter.Allow(userID) {
			writeError(w, http.StatusTooManyRequests, "too_many_requests", "слишком много заявок, попробуйте позже")
			return
		}
		err = h.svc.SendRequest(r.Context(), userID, target)
	case "accept":
		err = h.svc.Accept(r.Context(), userID, target)
	default:
		writeError(w, http.StatusBadRequest, "validation_error", "action: ожидается request или accept")
		return
	}

	if err != nil {
		mapSocialError(w, err)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// Remove удаляет связь: дружбу, заявку или отказ.
func (h *SocialHandlers) Remove(w http.ResponseWriter, r *http.Request) {
	userID, _ := UserIDFrom(r.Context())
	target := chi.URLParam(r, "userID")

	if !validUserID(target) {
		writeError(w, http.StatusBadRequest, "validation_error", "неверный идентификатор пользователя")
		return
	}

	if err := h.svc.Remove(r.Context(), userID, target); err != nil {
		mapSocialError(w, err)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

type blockRequest struct {
	Blocked *bool `json:"blocked"`
}

// Block ставит или снимает блокировку.
func (h *SocialHandlers) Block(w http.ResponseWriter, r *http.Request) {
	userID, _ := UserIDFrom(r.Context())
	target := chi.URLParam(r, "userID")

	if !validUserID(target) {
		writeError(w, http.StatusBadRequest, "validation_error", "неверный идентификатор пользователя")
		return
	}

	var req blockRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", "тело запроса должно быть JSON-объектом")
		return
	}
	if req.Blocked == nil {
		writeError(w, http.StatusBadRequest, "validation_error", "blocked: ожидается true или false")
		return
	}

	if err := h.svc.SetBlocked(r.Context(), userID, target, *req.Blocked); err != nil {
		mapSocialError(w, err)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

type searchUserItem struct {
	userCard
	Relation string `json:"relation"`
}

// Search ищет людей по логину или имени.
func (h *SocialHandlers) Search(w http.ResponseWriter, r *http.Request) {
	userID, _ := UserIDFrom(r.Context())

	if !h.searchLimiter.Allow(userID) {
		writeError(w, http.StatusTooManyRequests, "too_many_requests", "слишком много запросов, попробуйте позже")
		return
	}

	results, err := h.svc.Search(r.Context(), userID, r.URL.Query().Get("q"))
	if err != nil {
		mapSocialError(w, err)
		return
	}

	items := make([]searchUserItem, 0, len(results))
	for _, res := range results {
		items = append(items, searchUserItem{
			userCard: toCard(res.User),
			Relation: res.Relation,
		})
	}

	writeJSON(w, http.StatusOK, map[string]any{"users": items})
}

func mapSocialError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, social.ErrValidation):
		writeError(w, http.StatusBadRequest, "validation_error", err.Error())
	case errors.Is(err, social.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "объект не найден")
	case errors.Is(err, social.ErrAlreadyFriends):
		writeError(w, http.StatusConflict, "already_friends", "вы уже друзья")
	case errors.Is(err, social.ErrAlreadyPending):
		writeError(w, http.StatusConflict, "already_pending", "заявка уже есть")
	case errors.Is(err, social.ErrBlocked):
		// Нейтрально: не раскрываем, кто кого заблокировал.
		writeError(w, http.StatusForbidden, "forbidden", "действие недоступно")
	default:
		slog.Error("social: internal error", "err", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "внутренняя ошибка")
	}
}
