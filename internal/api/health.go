package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func liveness(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func readiness(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()

		if err := pool.Ping(ctx); err != nil {
			slog.Warn("readiness: database unavailable", "err", err)
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "db_unavailable"})
			return
		}

		// Миграции применяются вручную: проверяем, что схема не отстала.
		// Без этого сервер отвечает 200, а блокировка падает на 500 из-за
		// отсутствующей колонки (P-30, P-45).
		const schemaQuery = `
			SELECT to_regclass('public.users') IS NOT NULL
			   AND to_regclass('public.relationships') IS NOT NULL
			   AND to_regclass('public.read_states') IS NOT NULL
			   AND EXISTS (
					SELECT 1 FROM information_schema.columns
					 WHERE table_schema = 'public'
					   AND table_name = 'relationships'
					   AND column_name = 'blocked_prev'
			   )`
		var schemaOK bool
		if err := pool.QueryRow(ctx, schemaQuery).Scan(&schemaOK); err != nil {
			slog.Warn("readiness: schema check failed", "err", err)
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "db_unavailable"})
			return
		}
		if !schemaOK {
			slog.Error("readiness: schema is outdated, migrations are not applied")
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "schema_outdated"})
			return
		}

		writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("write response", "err", err)
	}
}
