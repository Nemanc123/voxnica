package api

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"

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

type createGroupRequest struct {
	RecipientIDs []string `json:"recipient_ids"`
	Name         *string  `json:"name"`
}

type addRecipientRequest struct {
	UserID string `json:"user_id"`
}

type renameGroupRequest struct {
	// RawMessage, а не *string: нужно отличать «поле не передали» от
	// «передали null». Иначе PATCH {} молча сбрасывает имя группы.
	Name json.RawMessage `json:"name"`
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

// CreateGroup создаёт групповой диалог.
func (h *DMHandlers) CreateGroup(w http.ResponseWriter, r *http.Request) {
	userID, _ := UserIDFrom(r.Context())

	var req createGroupRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", "тело запроса должно быть JSON-объектом")
		return
	}

	channel, err := h.svc.CreateGroup(r.Context(), userID, req.RecipientIDs, req.Name)
	if err != nil {
		mapDMError(w, err)
		return
	}

	writeJSON(w, http.StatusCreated, channel)
}

// AddRecipient добавляет участника в группу.
func (h *DMHandlers) AddRecipient(w http.ResponseWriter, r *http.Request) {
	userID, _ := UserIDFrom(r.Context())
	channelID := chi.URLParam(r, "channelID")
	if !validUserID(channelID) {
		writeError(w, http.StatusBadRequest, "validation_error", "неверный идентификатор канала")
		return
	}

	var req addRecipientRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", "тело запроса должно быть JSON-объектом")
		return
	}
	if !validUserID(req.UserID) {
		writeError(w, http.StatusBadRequest, "validation_error", "неверный идентификатор пользователя")
		return
	}

	channel, err := h.svc.AddRecipient(r.Context(), userID, channelID, req.UserID)
	if err != nil {
		mapDMError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, channel)
}

// RemoveRecipient убирает участника; себя — «выйти», другого — «исключить».
func (h *DMHandlers) RemoveRecipient(w http.ResponseWriter, r *http.Request) {
	userID, _ := UserIDFrom(r.Context())
	channelID := chi.URLParam(r, "channelID")
	targetID := chi.URLParam(r, "userID")
	if !validUserID(channelID) || !validUserID(targetID) {
		writeError(w, http.StatusBadRequest, "validation_error", "неверный идентификатор")
		return
	}

	if err := h.svc.RemoveRecipient(r.Context(), userID, channelID, targetID); err != nil {
		mapDMError(w, err)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// Rename задаёт имя группы; пустое имя — вернуть показ по участникам.
func (h *DMHandlers) Rename(w http.ResponseWriter, r *http.Request) {
	userID, _ := UserIDFrom(r.Context())
	channelID := chi.URLParam(r, "channelID")
	if !validUserID(channelID) {
		writeError(w, http.StatusBadRequest, "validation_error", "неверный идентификатор канала")
		return
	}

	var req renameGroupRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", "тело запроса должно быть JSON-объектом")
		return
	}
	if len(req.Name) == 0 {
		writeError(w, http.StatusBadRequest, "validation_error", "нужно поле name")
		return
	}

	var name *string
	if string(req.Name) != "null" {
		var value string
		if err := json.Unmarshal(req.Name, &value); err != nil {
			writeError(w, http.StatusBadRequest, "validation_error", "name должен быть строкой или null")
			return
		}
		name = &value
	}

	channel, err := h.svc.Rename(r.Context(), userID, channelID, name)
	if err != nil {
		mapDMError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, channel)
}

func mapDMError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, dm.ErrValidation):
		writeError(w, http.StatusBadRequest, "validation_error", err.Error())
	case errors.Is(err, dm.ErrForbidden):
		writeError(w, http.StatusForbidden, "forbidden", err.Error())
	case errors.Is(err, dm.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", err.Error())
	default:
		slog.Error("dm internal error", "err", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "внутренняя ошибка")
	}
}
