package main

import (
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const (
	reasonAuth      = "auth"
	reasonRateLimit = "rate_limit"
	reasonInflight  = "inflight_cap"
)

type Metrics struct {
	reg     *prometheus.Registry
	Count   *prometheus.CounterVec
	Inflight  prometheus.Gauge
	QueueDepth prometheus.Gauge
	QueueWait  prometheus.Histogram
	TTFT       prometheus.Histogram
	Latency    prometheus.Histogram
}

func NewMetrics() *Metrics {
	reg := prometheus.NewRegistry()
	f := promauto.With(reg)
	return &Metrics{
		reg: reg,
		Count: f.NewCounterVec(
			prometheus.CounterOpts{
				Name: "gateway_requests_total",
				Help: "Requests by outer status and rejection reason (empty reason = proxied).",
			},
			[]string{"status", "reason"},
		),
		Inflight: f.NewGauge(prometheus.GaugeOpts{
			Name: "gateway_inflight",
			Help: "Current number of in-flight upstream requests.",
		}),
		QueueDepth: f.NewGauge(prometheus.GaugeOpts{
			Name: "gateway_queue_depth",
			Help: "Current number of requests waiting in the inflight queue.",
		}),
		QueueWait: f.NewHistogram(prometheus.HistogramOpts{
			Name:   "gateway_queue_wait_seconds",
			Help:   "Time a request waited in the inflight queue.",
			Buckets: prometheus.ExponentialBuckets(0.005, 4, 8),
		}),
		TTFT: f.NewHistogram(prometheus.HistogramOpts{
			Name:   "gateway_time_to_first_token_seconds",
			Help:   "Time from request accepted to first byte streamed back.",
			Buckets: prometheus.ExponentialBuckets(0.02, 4, 10),
		}),
		Latency: f.NewHistogram(prometheus.HistogramOpts{
			Name:   "gateway_request_duration_seconds",
			Help:   "Total request latency.",
			Buckets: prometheus.ExponentialBuckets(0.05, 2, 14),
		}),
	}
}

// recorder: status, first-byte time and total time. Streaming-aware via Flush.
type recorder struct {
	http.ResponseWriter
	status   int
	first    time.Time
	recorded bool
}

func (r *recorder) WriteHeader(code int) {
	if !r.recorded {
		r.status, r.recorded = code, true
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *recorder) Write(p []byte) (int, error) {
	if !r.recorded {
		r.status, r.recorded = 200, true
	}
	if r.first.IsZero() {
		r.first = time.Now()
	}
	return r.ResponseWriter.Write(p)
}

func (r *recorder) Flush() {
	if f, ok := r.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (r *recorder) recordEnd(m *Metrics, reason string) {
	if !r.recorded {
		r.status, r.recorded = 200, true
	}
	m.Count.WithLabelValues(strconv.Itoa(r.status), reason).Inc()
}

func (m *Metrics) Handler() http.Handler {
	return promhttp.HandlerFor(m.reg, promhttp.HandlerOpts{})
}
