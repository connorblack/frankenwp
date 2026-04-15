package cache

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"go.uber.org/zap"
)

type testHandler func(http.ResponseWriter, *http.Request) error

func (h testHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) error {
	return h(w, r)
}

func TestCachePathForRequest(t *testing.T) {
	t.Run("keeps path-only requests unchanged", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "http://example.com/", nil)
		if got := cachePathForRequest(req); got != "/" {
			t.Fatalf("expected path-only cache key to stay '/', got %q", got)
		}
	})

	t.Run("includes raw query for routed WordPress requests", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "http://example.com/?page_id=2", nil)
		if got := cachePathForRequest(req); got != "/?page_id=2" {
			t.Fatalf("expected query-aware cache path '/?page_id=2', got %q", got)
		}
	})
}

func TestServeHTTPBypassesQueryStringsWhenEnabled(t *testing.T) {
	cache := Cache{
		logger:             zap.NewNop(),
		BypassQueryStrings: true,
		PurgePath:          "/__cache/purge",
		CacheResponseCodes: []string{"2"},
	}

	called := false
	next := testHandler(func(w http.ResponseWriter, r *http.Request) error {
		called = true
		_, err := w.Write([]byte("query-bypassed"))
		return err
	})

	req := httptest.NewRequest(http.MethodGet, "http://example.com/?page_id=2", nil)
	rec := httptest.NewRecorder()

	if err := cache.ServeHTTP(rec, req, next); err != nil {
		t.Fatalf("ServeHTTP returned error: %v", err)
	}

	if !called {
		t.Fatal("expected query-string request to bypass cache and hit next handler")
	}

	if got := rec.Header().Get("X-WPEverywhere-Cache"); got != "" {
		t.Fatalf("expected bypassed request to avoid cache header, got %q", got)
	}

	if body := rec.Body.String(); body != "query-bypassed" {
		t.Fatalf("expected next-handler body, got %q", body)
	}
}

func TestServeHTTPUsesDistinctKeysWhenCachingQueryStrings(t *testing.T) {
	store := NewStore(t.TempDir(), 600, zap.NewNop())
	cache := Cache{
		logger:             zap.NewNop(),
		Store:              store,
		PurgePath:          "/__cache/purge",
		CacheResponseCodes: []string{"2"},
	}

	hits := 0
	next := testHandler(func(w http.ResponseWriter, r *http.Request) error {
		hits++
		_, err := w.Write([]byte(r.URL.RawQuery))
		return err
	})

	reqPage2 := httptest.NewRequest(http.MethodGet, "http://example.com/?page_id=2", nil)
	recPage2 := httptest.NewRecorder()
	if err := cache.ServeHTTP(recPage2, reqPage2, next); err != nil {
		t.Fatalf("ServeHTTP(page_id=2) returned error: %v", err)
	}

	reqPage3 := httptest.NewRequest(http.MethodGet, "http://example.com/?page_id=3", nil)
	recPage3 := httptest.NewRecorder()
	if err := cache.ServeHTTP(recPage3, reqPage3, next); err != nil {
		t.Fatalf("ServeHTTP(page_id=3) returned error: %v", err)
	}

	reqPage3Again := httptest.NewRequest(http.MethodGet, "http://example.com/?page_id=3", nil)
	recPage3Again := httptest.NewRecorder()
	if err := cache.ServeHTTP(recPage3Again, reqPage3Again, next); err != nil {
		t.Fatalf("ServeHTTP(page_id=3 again) returned error: %v", err)
	}

	if body := recPage2.Body.String(); body != "page_id=2" {
		t.Fatalf("expected first query-string response to keep its own payload, got %q", body)
	}

	if body := recPage3.Body.String(); body != "page_id=3" {
		t.Fatalf("expected uncached second request to preserve its own query payload, got %q", body)
	}

	if body := recPage3Again.Body.String(); body != "page_id=3" {
		t.Fatalf("expected repeated query-string request to read back its cached payload, got %q", body)
	}

	if hits != 2 {
		t.Fatalf("expected next handler to run twice (two unique query strings), got %d", hits)
	}
}
