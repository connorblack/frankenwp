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

func TestHeaderContainsAnySubstring(t *testing.T) {
	t.Run("matches a configured cookie fragment", func(t *testing.T) {
		got := headerContainsAnySubstring(
			"wordpress_logged_in_abc=1; foo=bar",
			[]string{"wordpress_logged_in", "wp_woocommerce_session_"},
		)
		if !got {
			t.Fatal("expected logged-in cookie fragment to match")
		}
	})

	t.Run("ignores empty fragments", func(t *testing.T) {
		got := headerContainsAnySubstring(
			"foo=bar",
			[]string{"", "   ", "wp_woocommerce_session_"},
		)
		if got {
			t.Fatal("expected empty fragments to be ignored")
		}
	})

	t.Run("returns false when nothing matches", func(t *testing.T) {
		got := headerContainsAnySubstring(
			"foo=bar; baz=qux",
			[]string{"wordpress_logged_in", "woocommerce_cart_hash"},
		)
		if got {
			t.Fatal("expected no cookie fragment match")
		}
	})
}

func TestServeHTTPBypassesConfiguredCookieFlows(t *testing.T) {
	cache := Cache{
		logger:                 zap.NewNop(),
		PurgePath:              "/__cache/purge",
		BypassCookieSubstrings: []string{"wordpress_logged_in", "woocommerce_cart_hash"},
		CacheResponseCodes:     []string{"2"},
	}

	called := false
	next := testHandler(func(w http.ResponseWriter, r *http.Request) error {
		called = true
		_, err := w.Write([]byte("cookie-bypassed"))
		return err
	})

	req := httptest.NewRequest(http.MethodGet, "http://example.com/", nil)
	req.Header.Set("Cookie", "woocommerce_cart_hash=abc123")
	rec := httptest.NewRecorder()

	if err := cache.ServeHTTP(rec, req, next); err != nil {
		t.Fatalf("ServeHTTP returned error: %v", err)
	}

	if !called {
		t.Fatal("expected cookie-marked request to bypass cache and hit next handler")
	}

	if got := rec.Header().Get("X-WPEverywhere-Cache"); got != "" {
		t.Fatalf("expected bypassed cookie request to avoid cache header, got %q", got)
	}
}

func TestGetPurgeInventoryRequiresNonEmptyKey(t *testing.T) {
	store := NewStore(t.TempDir(), 600, zap.NewNop())
	// Seed the cache so there's something to list.
	if err := store.Set("none::/", 0, []byte("cached-home")); err != nil {
		t.Fatalf("Set returned error: %v", err)
	}

	t.Run("empty PurgeKey blocks inventory listing", func(t *testing.T) {
		cache := Cache{
			logger:             zap.NewNop(),
			Store:              store,
			PurgePath:          "/__cache/purge",
			PurgeKey:           "", // no key configured
			CacheResponseCodes: []string{"2"},
		}

		req := httptest.NewRequest(http.MethodGet, "http://example.com/__cache/purge", nil)
		rec := httptest.NewRecorder()

		// GET with empty key should NOT return the cache listing.
		err := cache.ServeHTTP(rec, req, testHandler(func(w http.ResponseWriter, r *http.Request) error {
			return nil
		}))
		if err != nil {
			t.Fatalf("ServeHTTP returned error: %v", err)
		}

		body := rec.Body.String()
		if body == "[" || len(body) > 2 && body[0] == '[' {
			t.Fatalf("expected empty-key GET to NOT return cache inventory, got %q", body)
		}
	})

	t.Run("correct non-empty PurgeKey returns inventory", func(t *testing.T) {
		cache := Cache{
			logger:             zap.NewNop(),
			Store:              store,
			PurgePath:          "/__cache/purge",
			PurgeKey:           "secret",
			CacheResponseCodes: []string{"2"},
		}

		req := httptest.NewRequest(http.MethodGet, "http://example.com/__cache/purge", nil)
		req.Header.Set("X-WPSidekick-Purge-Key", "secret")
		rec := httptest.NewRecorder()

		err := cache.ServeHTTP(rec, req, testHandler(func(w http.ResponseWriter, r *http.Request) error {
			t.Fatal("authenticated GET inventory should return before next handler")
			return nil
		}))
		if err != nil {
			t.Fatalf("ServeHTTP returned error: %v", err)
		}

		body := rec.Body.String()
		// Inventory is a JSON object with "disk" and "mem" keys.
		if len(body) == 0 || body[0] != '{' {
			t.Fatalf("expected inventory JSON object, got %q", body)
		}
	})

	t.Run("wrong key does not return inventory", func(t *testing.T) {
		cache := Cache{
			logger:             zap.NewNop(),
			Store:              store,
			PurgePath:          "/__cache/purge",
			PurgeKey:           "secret",
			CacheResponseCodes: []string{"2"},
		}

		req := httptest.NewRequest(http.MethodGet, "http://example.com/__cache/purge", nil)
		req.Header.Set("X-WPSidekick-Purge-Key", "wrong-key")
		rec := httptest.NewRecorder()

		err := cache.ServeHTTP(rec, req, testHandler(func(w http.ResponseWriter, r *http.Request) error {
			return nil
		}))
		if err != nil {
			t.Fatalf("ServeHTTP returned error: %v", err)
		}

		body := rec.Body.String()
		if len(body) > 0 && body[0] == '[' {
			t.Fatalf("expected wrong-key GET to NOT return cache inventory, got %q", body)
		}
	})
}

func TestServeHTTPFlushesCacheOnPurgeWhenQueryCachingEnabled(t *testing.T) {
	store := NewStore(t.TempDir(), 600, zap.NewNop())
	if err := store.Set("none::/?page_id=2", 0, []byte("query-cache")); err != nil {
		t.Fatalf("Set(query cache) returned error: %v", err)
	}
	if err := store.Set("none::/sample-page/", 0, []byte("pretty-cache")); err != nil {
		t.Fatalf("Set(pretty cache) returned error: %v", err)
	}

	cache := Cache{
		logger:             zap.NewNop(),
		Store:              store,
		PurgePath:          "/__cache/purge",
		PurgeKey:           "secret",
		BypassQueryStrings: false,
		CacheResponseCodes: []string{"2"},
	}

	req := httptest.NewRequest(
		http.MethodPost,
		"http://example.com/__cache/purge/sample-page/",
		nil,
	)
	req.Header.Set("X-WPSidekick-Purge-Key", "secret")
	rec := httptest.NewRecorder()

	if err := cache.ServeHTTP(rec, req, testHandler(func(w http.ResponseWriter, r *http.Request) error {
		t.Fatal("purge request should not hit next handler")
		return nil
	})); err != nil {
		t.Fatalf("ServeHTTP(purge) returned error: %v", err)
	}

	if got := rec.Body.String(); got != "OK" {
		t.Fatalf("expected purge response body OK, got %q", got)
	}

	if _, err := store.Get("none::/?page_id=2"); err == nil {
		t.Fatal("expected query-string cache entry to be purged by flush")
	}

	if _, err := store.Get("none::/sample-page/"); err == nil {
		t.Fatal("expected pretty permalink cache entry to be purged by flush")
	}
}
