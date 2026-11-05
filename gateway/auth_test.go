package main

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeKeys(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "apisecrets")
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadAndCheckAPIKeys(t *testing.T) {
	raw := "demo-key-123"
	raw2 := "second-key-456"
	sum := sha256.Sum256([]byte(raw))
	digest := hex.EncodeToString(sum[:])
	sum2 := sha256.Sum256([]byte(raw2))
	digest2 := hex.EncodeToString(sum2[:])

	path := writeKeys(t, "# secrets\nmain:"+digest+"\n"+digest2+"\n")
	keys, err := LoadAPIKeys(path)
	if err != nil {
		t.Fatal(err)
	}
	if keys.len() != 2 {
		t.Fatalf("expected 2 keys, got %d", keys.len())
	}
	if name, ok := keys.Check(raw); !ok || name != "main" {
		t.Fatalf("valid key should check out as owner main, got %q ok=%v", name, ok)
	}
	if _, ok := keys.Check("nope-key"); ok {
		t.Fatal("invalid key must not authenticate")
	}
	if _, ok := keys.Check(""); ok {
		t.Fatal("empty key must not authenticate")
	}
}

func TestLoadAPIKeysEmptyFile(t *testing.T) {
	if _, err := LoadAPIKeys(writeKeys(t, "\n\n# only comments\n")); err == nil {
		t.Fatal("expected error without at least one key")
	}
}

func TestExtractTokenBearerAndHeader(t *testing.T) {
	r, _ := http.NewRequest("GET", "/", strings.NewReader(""))
	if tok := ExtractToken(r); tok != "" {
		t.Fatal("empty headers mean empty token")
	}
	r2, _ := http.NewRequest("GET", "/", strings.NewReader("a"))
	r2.Header.Set("Authorization", "Bearer abc123")
	if ExtractToken(r2) != "abc123" {
		t.Fatal("bearer token extraction")
	}
	r3, _ := http.NewRequest("GET", "/", strings.NewReader("a"))
	r3.Header.Set("X-API-Key", "xyz")
	if ExtractToken(r3) != "xyz" {
		t.Fatal("api key header extraction")
	}
}
