package main

import (
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// token-bucket per API key. Keyed by the SHA-256 digest of the raw token;
// digests are deterministic and never collide with raw secrets.
type Limiter struct {
	mu     sync.Mutex
	rps    rate.Limit
	burst  int
	buckets map[string]*rate.Limiter
}

func NewLimiter(rps float64, burst int) *Limiter {
	return &Limiter{
		rps:    rate.Limit(rps),
		burst:  burst,
		buckets: map[string]*rate.Limiter{},
	}
}

func (l *Limiter) Allow(key string) bool {
	l.mu.Lock()
	b, ok := l.buckets[key]
	if !ok {
		b = rate.NewLimiter(l.rps, l.burst)
		l.buckets[key] = b
	}
	l.mu.Unlock()
	return b.Allow()
}

// WaitUntil reports how long the limiter would need to wait (for tests).
func (l *Limiter) reserve(key string) (time.Duration, bool) {
	l.mu.Lock()
	b, ok := l.buckets[key]
	if !ok {
		b = rate.NewLimiter(l.rps, l.burst)
		l.buckets[key] = b
	}
	l.mu.Unlock()
	r := b.Reserve()
	if !r.OK() {
		return 0, false
	}
	return r.Delay(), true
}
