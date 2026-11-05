package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// in-memory fake llama-server: streams an SSE body slowly to test passthrough + TTFT.
func fakeUpstream(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fl := w.(http.Flusher)
		w.Header().Set("Content-Type", "text/event-stream")
		for i := 0; i < 3; i++ {
			fmt.Fprintf(w, "data: chunk-%d\n\n", i)
			fl.Flush()
		}
		fmt.Fprint(w, "data: [DONE]\n\n")
		fl.Flush()
	}))
}

func testGateway(t *testing.T, upstream string, rate float64, burst, maxInflight int, rawKey string) *Gateway {
	t.Helper()
	// upstream httptest uses http; hold a direct proxy
	proxy, err := NewUpstreamProxy(upstream)
	if err != nil {
		t.Fatal(err)
	}
	// rather than reading a file, use an on-disk key
	digest := sha256.Sum256([]byte(rawKey))
	dir := t.TempDir()
	p := filepath.Join(dir, "keys")
	_ = os.WriteFile(p, []byte("tester:"+hex.EncodeToString(digest[:])+"\n"), 0o600)
	keys, err := LoadAPIKeys(p)
	if err != nil {
		t.Fatal(err)
	}
	return &Gateway{
		cfg: Config{
			Upstream:    upstream,
			RateRPS:     rate,
			RateBurst:   burst,
			InflightMax: maxInflight,
			QueueWait:   10 * time.Millisecond,
		},
		keys:     keys,
		limiter:  NewLimiter(rate, burst),
		inflight: NewInflight(maxInflight),
		metrics:  NewMetrics(),
		proxy:    proxy,
	}
}

func TestGatewayStreamingPassthrough(t *testing.T) {
	up := fakeUpstream(t)
	defer up.Close()
	g := testGateway(t, up.URL, 1000, 1000, 4, "demo-key-123")

	rec := httptest.NewRecorder()
	recv := &recorder{ResponseWriter: rec}
	_ = recv
	r := httptest.NewRequest("POST", "/v1/chat/completions", strings.NewReader(`{"model":"q"}`))
	r.Header.Set("Authorization", "Bearer demo-key-123")
	r.Header.Set("X-API-Key", "") // ignored; Authorization wins
	defer func() { _ = r.Body.Close() }()
	g.handleLLM(rec, r)

	if rec.Code != 200 {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	body := rec.Body.String()
	for _, s := range []string{"chunk-0", "chunk-1", "chunk-2", "[DONE]"} {
		if !strings.Contains(body, s) {
			t.Fatalf("streamed body missing %q:\n%s", s, body)
		}
	}
}

func TestGatewayAuthRejectsMissingKey(t *testing.T) {
	up := fakeUpstream(t)
	defer up.Close()
	g := testGateway(t, up.URL, 1, 1, 4, "demo-key-123")

	rec := httptest.NewRecorder()
	g.handleLLM(rec, httptest.NewRequest("POST", "/v1/chat/completions", nil))
	if rec.Code != 401 {
		t.Fatalf("expected 401 missing key, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `"type":"auth"`) {
		t.Fatalf("reason type must distinguish from rate limiting: %s", rec.Body.String())
	}
}

func TestGatewayAuthRejectsBadKey(t *testing.T) {
	up := fakeUpstream(t)
	defer up.Close()
	g := testGateway(t, up.URL, 1, 1, 4, "demo-key-123")
	rec := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/v1/chat/completions", nil)
	r.Header.Set("X-API-Key", "wrong-key")
	g.handleLLM(rec, r)
	if rec.Code != 401 {
		t.Fatalf("expected 401 bad key, got %d", rec.Code)
	}
}

func TestGatewayRateLimit(t *testing.T) {
	up := fakeUpstream(t)
	defer up.Close()
	g := testGateway(t, up.URL, 1, 1, 4, "demo-key-123")

	// first allowed, second (over burst=1) rate-limited
	for i := 0; i < 2; i++ {
		rec := httptest.NewRecorder()
		r := httptest.NewRequest("POST", "/v1/chat/completions", strings.NewReader(`{}`))
		r.Header.Set("Authorization", "Bearer demo-key-123")
		g.handleLLM(rec, r)
		if i == 0 && rec.Code != 200 {
			t.Fatalf("first request within burst should be allowed, got %d", rec.Code)
		}
		if i == 1 {
			if rec.Code != 429 {
				t.Fatalf("expected 429 over burst, got %d", rec.Code)
			}
			if !strings.Contains(rec.Body.String(), `"type":"rate_limit"`) {
				t.Fatalf("rate_limit reason not set: %s", rec.Body.String())
			}
			if rec.Header().Get("Retry-After") != "" {
				t.Fatalf("only the inflight cap should carry Retry-After")
			}
		}
	}
}

func TestGatewayInflightCap(t *testing.T) {
	// slow upstream: each request parks ~80ms
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(80 * time.Millisecond)
		w.WriteHeader(200)
	}))
	defer up.Close()
	g := testGateway(t, up.URL, 1000, 1000, 1, "demo-key-123")

	const n = 4
	results := make(chan int, n)
	for i := 0; i < n; i++ {
		go func() {
			rec := httptest.NewRecorder()
			r := httptest.NewRequest("POST", "/v1/chat/completions", nil)
			r.Header.Set("Authorization", "Bearer demo-key-123")
			g.handleLLM(rec, r)
			results <- rec.Code
		}()
	}

	var four29s, ok200s int
	for i := 0; i < n; i++ {
		c := <-results
		switch c {
		case 200:
			ok200s++
		case 429:
			four29s++
		default:
			t.Fatalf("unexpected status %d", c)
		}
	}
	// inFlightMax=1 and a tiny queue; the burst must spill into 429s
	if four29s == 0 {
		t.Fatal("expected at least one 429 from the in-flight cap")
	}
	if ok200s == 0 {
		t.Fatal("expected the leading request to have been served")
	}
}
