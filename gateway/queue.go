package main

import (
	"sync"
	"time"
)

// inflight: max concurrent upstream requests plus a small waiting queue.
// A ticket is returned when a slot is acquired; the caller must Release it.
type Ticket struct{ q *inflight }

func (t Ticket) Release() { t.q.free <- struct{}{} }

type inflight struct {
	mu    sync.Mutex
	free  chan struct{}
	wait  int
}

const queueLimit = 16

func NewInflight(max int) *inflight {
	free := make(chan struct{}, max)
	for i := 0; i < max; i++ {
		free <- struct{}{}
	}
	return &inflight{free: free}
}

// Acquire parks the caller for up to d, filling the shared ticket when free.
// ok is false when out of the queue limit; callers respond 429 as inflight_cap.
// A zero d makes callers wait indefinitely for upstream saturation.
func (in *inflight) Acquire(d time.Duration) (Ticket, bool) {
	in.mu.Lock()
	if in.wait >= queueLimit {
		in.mu.Unlock()
		return Ticket{}, false
	}
	in.wait++
	in.mu.Unlock()

	var timer *time.Timer
	if d > 0 {
		timer = time.NewTimer(d)
	} else {
		timer = time.NewTimer(time.Hour * 24 * 365) // never give up: queue does the pacing
	}
	defer timer.Stop()

	select {
	case <-in.free:
		in.mu.Lock()
		in.wait--
		in.mu.Unlock()
		return Ticket{q: in}, true
	case <-timer.C:
		in.mu.Lock()
		in.wait--
		in.mu.Unlock()
		return Ticket{}, false
	}
}

// Depth returns the current number of waiting requests (for the gauge).
func (in *inflight) Depth() float64 {
	in.mu.Lock()
	defer in.mu.Unlock()
	return float64(in.wait)
}
