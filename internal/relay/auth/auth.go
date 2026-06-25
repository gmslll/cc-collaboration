package auth

import (
	"context"
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

// Resolver maps a raw bearer credential to an authenticated identity. The relay
// composes one over login sessions + DB machine tokens + the file registry.
type Resolver interface {
	Resolve(ctx context.Context, raw string) (identity string, ok bool)
}

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
		next[HashToken(e.Token)] = e.Identity
	}
	t.mu.Lock()
	t.m = next
	t.mu.Unlock()
	return nil
}

func (t *Tokens) lookup(raw string) (string, bool) {
	t.mu.RLock()
	id, ok := t.m[HashToken(raw)]
	t.mu.RUnlock()
	return id, ok
}

// Resolve implements Resolver against the in-memory file registry.
func (t *Tokens) Resolve(_ context.Context, raw string) (string, bool) {
	return t.lookup(raw)
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

// tokenFromRequest pulls the bearer credential from the Authorization header.
// When allowQuery is set it also accepts a ?access_token= query param — needed
// only for the browser WebSocket handshake, which can't carry a custom header.
// REST routes leave it off so tokens aren't invited into URLs (and access logs).
func tokenFromRequest(req *http.Request, allowQuery bool) string {
	const prefix = "Bearer "
	if hdr := req.Header.Get("Authorization"); strings.HasPrefix(hdr, prefix) {
		return strings.TrimPrefix(hdr, prefix)
	}
	if allowQuery {
		return req.URL.Query().Get("access_token")
	}
	return ""
}

// Middleware requires Authorization: Bearer <token> (the path for all REST
// routes), resolves it to an identity via r, and attaches the identity to the
// request context (and to any installed WithIdentityHolder).
func Middleware(r Resolver) func(http.Handler) http.Handler {
	return middleware(r, false)
}

// MiddlewareAllowingQueryToken is Middleware that additionally accepts the token
// as ?access_token=. Use it only for the WebSocket route (browsers can't set the
// handshake header) so REST routes stay header-only.
func MiddlewareAllowingQueryToken(r Resolver) func(http.Handler) http.Handler {
	return middleware(r, true)
}

func middleware(r Resolver, allowQuery bool) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			raw := tokenFromRequest(req, allowQuery)
			if raw == "" {
				http.Error(w, "missing bearer token", http.StatusUnauthorized)
				return
			}
			id, ok := r.Resolve(req.Context(), raw)
			if !ok {
				http.Error(w, "invalid token", http.StatusUnauthorized)
				return
			}
			ctx := req.Context()
			if holder, ok := ctx.Value(identityHolderKey{}).(*string); ok {
				*holder = id
			}
			ctx = context.WithValue(ctx, identityKey{}, id)
			next.ServeHTTP(w, req.WithContext(ctx))
		})
	}
}

// Middleware (method) keeps the original *Tokens call site working: it resolves
// against the file registry only. The relay composes a richer Resolver and uses
// the package-level Middleware directly.
func (t *Tokens) Middleware(next http.Handler) http.Handler {
	return Middleware(t)(next)
}
