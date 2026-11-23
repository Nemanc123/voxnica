package api

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TestReadinessSchemaCheck проверяет обе ветки проверки схемы:
// без blocked_prev — 503 schema_outdated, с колонкой — 200.
//
// Временная схема не трогает public, поэтому тест можно запускать
// параллельно с остальными e2e-тестами.
func TestReadinessSchemaCheck(t *testing.T) {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL не задан")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatalf("подключение: %v", err)
	}
	t.Cleanup(pool.Close)

	schema := fmt.Sprintf("readiness_test_%d", time.Now().UnixNano())
	schemaIdent := pgx.Identifier{schema}.Sanitize()
	if _, err := pool.Exec(ctx, "CREATE SCHEMA "+schemaIdent); err != nil {
		// На роли без права CREATE на базу тест не должен быть красным:
		// проверка схемы к правам отношения не имеет.
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "42501" {
			t.Skip("нет права CREATE на базу — проверка схемы пропущена")
		}
		t.Fatalf("создание схемы: %v", err)
	}
	t.Cleanup(func() {
		dropCtx, dropCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer dropCancel()
		if _, err := pool.Exec(dropCtx, "DROP SCHEMA "+schemaIdent+" CASCADE"); err != nil {
			t.Logf("удаление временной схемы %s: %v", schema, err)
		}
	})

	for _, table := range []string{"users", "relationships", "read_states"} {
		query := "CREATE TABLE " + pgx.Identifier{schema, table}.Sanitize() + " (id uuid PRIMARY KEY)"
		if _, err := pool.Exec(ctx, query); err != nil {
			t.Fatalf("создание %s: %v", table, err)
		}
	}

	handler := readinessForSchema(pool, schema)

	// Схема есть, но колонки blocked_prev нет — как после забытой 003.
	rec := httptest.NewRecorder()
	handler(rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("без blocked_prev: код %d, ожидали 503", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `"schema_outdated"`) {
		t.Fatalf("без blocked_prev: тело %s, ожидали schema_outdated", rec.Body.String())
	}

	if _, err := pool.Exec(ctx,
		"ALTER TABLE "+pgx.Identifier{schema, "relationships"}.Sanitize()+" ADD COLUMN blocked_prev text"); err != nil {
		t.Fatalf("добавление blocked_prev: %v", err)
	}

	rec = httptest.NewRecorder()
	handler(rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("с blocked_prev: код %d, ожидали 200 (%s)", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"status":"ready"`) {
		t.Fatalf("с blocked_prev: тело %s, ожидали ready", rec.Body.String())
	}
}
