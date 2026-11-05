// Command gateway: auth + rate limit + in-flight cap + streaming passthrough
// in front of the llama.cpp server. The only public component.
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

// Config from environment (all set by the Helm chart).
type Config struct {
	Port        string // PORT, default 8080
	Upstream    string // LLAMA_UPSTREAM, default http://llama-server:80
	MetricsPort string // METRICS_PORT, default 9090
	KeysPath    string // API_KEYS_PATH, default /etc/gateway/apikeys
	RateRPS     float64
	RateBurst   int
	InflightMax int
	QueueWait   time.Duration
}

type Gateway struct {
	cfg      Config
	keys     *APIKeys
	limiter  *Limiter
	inflight *inflight
	metrics  *Metrics
	proxy    http.Handler
	ready    func() bool
}

func (g *Gateway) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", g.handleHealth)
	mux.HandleFunc("/readyz", g.handleReady)
	mux.HandleFunc("/v1/chat/completions", g.handleLLM)
	mux.HandleFunc("/v1/completions", g.handleLLM)
	mux.HandleFunc("/", g.handleLLM)
	return mux
}

// handleLLM is the complete chain: auth → rate limit → in-flight admission → proxy.
func (g *Gateway) handleLLM(w http.ResponseWriter, r *http.Request) {
	rec := &recorder{ResponseWriter: w}
	start := time.Now()
	defer func() {
		g.metrics.Latency.Observe(time.Since(start).Seconds())
	}()

	// 1) auth
	token := ExtractToken(r)
	if _, ok := g.keys.Check(token); !ok {
		g.reject(rec, 401, reasonAuth, "invalid or missing api key")
		return
	}

	// 2) per-key rate limit, keyed by the token digest (raw keys never stay in RAM)
	if !g.limiter.Allow(Digest(token)) {
		g.reject(rec, 429, reasonRateLimit, "rate limit exceeded")
		return
	}

	// 3) in-flight limiter with bounded short queue, then 429
	queueStart := time.Now()
	t, ok := g.inflight.Acquire(g.cfg.QueueWait)
	g.metrics.QueueWait.Observe(time.Since(queueStart).Seconds())
	if !ok {
		g.reject(rec, 429, reasonInflight, "in-flight limit reached")
		return
	}
	defer t.Release()
	g.metrics.Inflight.Inc()
	g.metrics.QueueDepth.Set(g.inflight.Depth())

	// 4) proxy; first byte from upstream timestamps the stream
	g.proxy.ServeHTTP(rec, r)
	g.metrics.Inflight.Dec()
	g.metrics.QueueDepth.Set(g.inflight.Depth())
	if !rec.first.IsZero() {
		g.metrics.TTFT.Observe(time.Since(rec.first).Seconds())
	}
}

func (g *Gateway) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
}

func (g *Gateway) handleReady(w http.ResponseWriter, r *http.Request) {
	if g.ready == nil || g.ready() {
		w.WriteHeader(http.StatusOK)
		return
	}
	http.Error(w, `{"status":"upstream not ready"}`, http.StatusServiceUnavailable)
}

// reject distinguishes the two 429 reasons in the body so load-test numbers
// do not conflate rate limiting with the in-flight cap.
func (g *Gateway) reject(rec *recorder, code int, reason, msg string) {
	w := rec.ResponseWriter
	w.Header().Set("Content-Type", "application/json")
	if code == http.StatusTooManyRequests && reason == reasonInflight {
		w.Header().Set("Retry-After", "2")
	}
	rec.WriteHeader(code)
	_, _ = w.Write([]byte(`{"error":{"code":` + strconv.Itoa(code) + `,"type":"` + reason + `","message":"` + msg + `"}}`))
}

// OkReady probes the upstream /health with a short timeout.
func OkReady(client *http.Client, upstream string) func() bool {
	return func() bool {
		r, err := client.Get(upstream + "/health")
		if err != nil {
			return false
		}
		defer r.Body.Close()
		return r.StatusCode == http.StatusOK
	}
}

func main() {
	cfg := Config{
		Port:        envOr("PORT", "8080"),
		Upstream:    envOr("LLAMA_UPSTREAM", "http://llama-server.llama.svc.cluster.local:80"),
		MetricsPort: envOr("METRICS_PORT", "9090"),
		KeysPath:    envOr("API_KEYS_PATH", "/etc/gateway/apikeys"),
		RateRPS:     envF("RATE_RPS", 1),
		RateBurst:   envI("RATE_BURST", 2),
		InflightMax: envI("INFLIGHT_MAX", 4),
		QueueWait:   time.Duration(envI("QUEUE_WAIT_MS", 2000)) * time.Millisecond,
	}

	keys, err := LoadAPIKeys(cfg.KeysPath)
	if err != nil {
		log.Fatalf("gateway: %v", err)
	}
	log.Printf("gateway: %d api keys loaded from %s", keys.len(), cfg.KeysPath)

	proxy, err := NewUpstreamProxy(cfg.Upstream)
	if err != nil {
		log.Fatalf("gateway: bad upstream %q: %v", cfg.Upstream, err)
	}

	client := &http.Client{Timeout: 3 * time.Second}
	g := &Gateway{
		cfg:      cfg,
		keys:     keys,
		limiter:  NewLimiter(cfg.RateRPS, cfg.RateBurst),
		inflight: NewInflight(cfg.InflightMax),
		metrics:  NewMetrics(),
		proxy:    proxy,
		ready:    OkReady(client, cfg.Upstream),
	}

	metricsSrv := &http.Server{Addr: "0.0.0.0:" + cfg.MetricsPort, Handler: g.metrics.Handler()}
	apiSrv := &http.Server{
		Addr:              "0.0.0.0:" + cfg.Port,
		Handler:           g.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		if err := metricsSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("gateway: metrics: %v", err)
		}
	}()
	log.Printf("gateway: listening on :%s (metrics :%s, upstream %s)", cfg.Port, cfg.MetricsPort, cfg.Upstream)

	go func() {
		if err := apiSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("gateway: api: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop
	log.Println("gateway: shutting down")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	_ = apiSrv.Shutdown(ctx)
	_ = metricsSrv.Shutdown(ctx)
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func envI(k string, d int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return d
}

func envF(k string, d float64) float64 {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.ParseFloat(v, 64); err == nil {
			return n
		}
	}
	return d
}
