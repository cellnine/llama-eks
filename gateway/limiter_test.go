package main

import (
	"sync"
	"testing"
	"time"
)

func TestLimiterPerKeyIsolation(t *testing.T) {
	l := NewLimiter(2, 2) // 2 rps, burst 2
	// exhaustive burst: first 2 immediate, third denied
	if !l.Allow("a") || !l.Allow("a") {
		t.Fatal("expected burst allowance for key a")
	}
	if l.Allow("a") {
		t.Fatal("expected a third immediate request to be over burst for key a")
	}
	if !l.Allow("b") {
		t.Fatal("burst is per key: key b must start its own budget")
	}
}

func TestLimiterTiming(t *testing.T) {
	l := NewLimiter(10, 1) // 1 in burst, 10/s refill
	for i := 0; i < 3; i++ {
		if !l.Allow("k") {
			t.Fatalf("request %d unexpectedly denied", i)
		}
		if i < 2 {
			time.Sleep(120 * time.Millisecond) // ~1 token per 100ms + margin
		}
	}
}

// concurrent Allow should not race or over-admit beyond burst.
func TestLimiterConcurrency(t *testing.T) {
	l := NewLimiter(1000, 5)
	var wg sync.WaitGroup
	var admitted int
	var mu sync.Mutex
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if l.Allow("k") {
				mu.Lock()
				admitted++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if admitted > 5 {
		t.Fatalf("admitted %d beyond burst 5", admitted)
	}
}
