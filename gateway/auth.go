package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync"
)

// API keys are stored hashed. The mounted file lists one key per line:
//
//   <name>:<hex sha256 of the raw token>
//
// The gateway hashes presented tokens and compares digests, so raw keys never
// live in memory beyond request scope.
type APIKeys struct {
	mu    sync.RWMutex
	names map[string]string // hex digest -> name
}

func LoadAPIKeys(path string) (*APIKeys, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open api keys: %w", err)
	}
	defer f.Close()

	k := &APIKeys{names: map[string]string{}}
	sc := bufio.NewScanner(f)
	line := 0
	for sc.Scan() {
		line++
		s := strings.TrimSpace(sc.Text())
		if s == "" || strings.HasPrefix(s, "#") {
			continue
		}
		// accept "name:hex" or bare "hex" with the digest itself as the name
		parts := strings.SplitN(s, ":", 2)
		var digest, name string
		if len(parts) == 2 {
			name, digest = parts[0], parts[1]
		} else {
			digest, name = s, s
		}
		k.names[strings.ToLower(digest)] = name
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if len(k.names) == 0 {
		return nil, fmt.Errorf("no api keys loaded from %s", path)
	}
	return k, nil
}

func (k *APIKeys) len() int {
	k.mu.RLock()
	defer k.mu.RUnlock()
	return len(k.names)
}

// Check hashes the presented token and returns the key owner name if valid.
func (k *APIKeys) Check(token string) (string, bool) {
	if token == "" {
		return "", false
	}
	sum := sha256.Sum256([]byte(token))
	digest := hex.EncodeToString(sum[:])
	k.mu.RLock()
	defer k.mu.RUnlock()
	name, ok := k.names[digest]
	return name, ok
}

// Digest is a stable per-key limiter identifier that never leaks the raw token.
func Digest(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// ExtractToken takes the bearer token from Authorization or X-API-Key.
func ExtractToken(r *http.Request) string {
	if h := r.Header.Get("Authorization"); h != "" {
		if len(h) > 7 && (h[:7] == "Bearer " || h[:7] == "bearer ") {
			return strings.TrimSpace(h[7:])
		}
	}
	return r.Header.Get("X-API-Key")
}
