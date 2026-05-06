package auth

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"maps"
	"net/http"
	"os"
	"slices"
	"strings"
	"sync"
)

type identityKey struct{}
type identityHolderKey struct{}

// Identity returns the authenticated identity from the request context.
func Identity(ctx context.Context) string {
	v, _ := ctx.Value(identityKey{}).(string)
	return v
}

// WithIdentityHolder lets an outer middleware (logging) install a *string
// that the auth middleware will fill in once the bearer token is resolved.
// Needed because mutating r.Context() inside an inner middleware doesn't
// propagate back to outer middleware reading the original *Request.
func WithIdentityHolder(ctx context.Context, holder *string) context.Context {
	return context.WithValue(ctx, identityHolderKey{}, holder)
}

// Tokens is an in-memory mapping from sha256(token) -> identity.
type Tokens struct {
	mu sync.RWMutex
	m  map[string]string
}

func NewTokens() *Tokens {
	return &Tokens{m: map[string]string{}}
}

// LoadFile reads a JSON file of the shape:
//
//	[{"token":"raw-secret","identity":"user@backend"}, ...]
//
// It can be reloaded at runtime to add/revoke tokens.
func (t *Tokens) LoadFile(path string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read tokens file: %w", err)
	}
	var entries []struct {
		Token    string `json:"token"`
		Identity string `json:"identity"`
	}
	if err := json.Unmarshal(b, &entries); err != nil {
		return fmt.Errorf("parse tokens file: %w", err)
	}
	next := make(map[string]string, len(entries))
	for i, e := range entries {
		if e.Token == "" || e.Identity == "" {
			log.Printf("tokens[%d]: skipping entry with empty token or identity", i)
			continue
		}
		next[hash(e.Token)] = e.Identity
	}
	t.mu.Lock()
	t.m = next
	t.mu.Unlock()
	return nil
}

func (t *Tokens) lookup(raw string) (string, bool) {
	t.mu.RLock()
	id, ok := t.m[hash(raw)]
	t.mu.RUnlock()
	return id, ok
}

func (t *Tokens) Count() int {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return len(t.m)
}

// Identities returns the registered identities, collapsing any one-per-machine
// tokens that map to the same person into a single entry.
func (t *Tokens) Identities() []string {
	t.mu.RLock()
	defer t.mu.RUnlock()
	seen := make(map[string]struct{}, len(t.m))
	for _, id := range t.m {
		seen[id] = struct{}{}
	}
	return slices.Sorted(maps.Keys(seen))
}

// Middleware returns an http middleware that requires Authorization: Bearer <token>
// and attaches the resolved identity to the request context.
func (t *Tokens) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hdr := r.Header.Get("Authorization")
		const prefix = "Bearer "
		if !strings.HasPrefix(hdr, prefix) {
			http.Error(w, "missing bearer token", http.StatusUnauthorized)
			return
		}
		raw := strings.TrimPrefix(hdr, prefix)
		id, ok := t.lookup(raw)
		if !ok {
			http.Error(w, "invalid token", http.StatusUnauthorized)
			return
		}
		ctx := r.Context()
		if holder, ok := ctx.Value(identityHolderKey{}).(*string); ok {
			*holder = id
		}
		ctx = context.WithValue(ctx, identityKey{}, id)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func hash(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}
