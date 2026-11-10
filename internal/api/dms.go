package api

import (
	"errors"
	"log/slog"
	"net/http"

	"github.com/Nemanc123/voxnica/internal/dm"
)

type DMHandlers struct {
	svc *dm.Service
}

func NewDMHandlers(svc *dm.Service) *DMHandlers {
	return &DMHandlers{svc: svc}
}

type openDMRequest struct {
	UserID string `json:"user_id"`
}

// Open создаёт личный канал с пользователем или возвращает существующий.
func (h *DMHandlers) Open(w http.ResponseWriter, r *http.Request) {
	userID, _ := UserIDFrom(r.Context())

	var req openDMRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", "тело запроса должно быть JSON-объектом")
		return
	}

	channel, err := h.svc.Open(r.Context(), userID, req.UserID)
	if err != nil {
		mapDMError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, channel)
}

// List — все личные каналы текущего пользователя.
func (h *DMHandlers) List(w http.ResponseWriter, r *http.Request) {
	userID, _ := UserIDFrom(r.Context())

	channels, err := h.svc.List(r.Context(), userID)
	if err != nil {
		mapDMError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"channels": channels})
}

func mapDMError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, dm.ErrValidation):
		writeError(w, http.StatusBadRequest, "validation_error", err.Error())
	case errors.Is(err, dm.ErrForbidden):
		writeError(w, http.StatusForbidden, "forbidden", err.Error())
	default:
		slog.Error("внутренняя ошибка личных каналов", "err", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "внутренняя ошибка")
	}
}
