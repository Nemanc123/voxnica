package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func liveness(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// schemaQuery проверяет, что ключевые объекты схемы на месте.
//
// Список поддерживается вручную: новая миграция, которая добавляет
// обязательную таблицу или колонку, должна быть дополнена здесь.
// Data-миграции (например, бэкфилл read_states) эта проверка не видит.
const schemaQuery = `
	SELECT to_regclass($1 || '.users') IS NOT NULL
	   AND to_regclass($1 || '.relationships') IS NOT NULL
	   AND to_regclass($1 || '.read_states') IS NOT NULL
	   AND EXISTS (
			SELECT 1 FROM information_schema.columns
			 WHERE table_schema = $1
			   AND table_name = 'relationships'
			   AND column_name = 'blocked_prev'
	   )`

func schemaReady(ctx context.Context, pool *pgxpool.Pool, schema string) (bool, error) {
	var ok bool
	err := pool.QueryRow(ctx, schemaQuery, schema).Scan(&ok)
	return ok, err
}

func readiness(pool *pgxpool.Pool) http.HandlerFunc {
	return readinessForSchema(pool, "public")
}

// readinessForSchema вынесен отдельно, чтобы тест мог проверить ветку
// schema_outdated на временной схеме, не ломая public.
func readinessForSchema(pool *pgxpool.Pool, schema string) http.HandlerFunc {
	// Мониторинг ходит часто: пишем ошибку один раз на состояние,
	// иначе лог заполняется одинаковыми строками.
	var outdated atomic.Bool

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
		schemaOK, err := schemaReady(ctx, pool, schema)
		if err != nil {
			slog.Warn("readiness: schema check failed", "err", err)
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "db_unavailable"})
			return
		}
		if !schemaOK {
			if outdated.CompareAndSwap(false, true) {
				slog.Error("readiness: schema is outdated, migrations are not applied")
			}
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "schema_outdated"})
			return
		}

		outdated.Store(false)
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
