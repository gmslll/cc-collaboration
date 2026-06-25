// Package apns is a minimal APNs HTTP/2 client for updating iOS Live Activities
// (Dynamic Island / Lock Screen) while the phone app is suspended — the only
// Apple-sanctioned way to keep the island fresh once the user leaves the app.
//
// STATUS: Tier 2 scaffold. This client is unit-tested (JWT signing, headers,
// payload, error handling), but end-to-end delivery is NOT verifiable without a
// paid Apple Developer account, an APNs auth key (.p8 + Key ID + Team ID), the
// Push capability signed into the app, and a physical device (the Simulator does
// not issue usable Live Activity push tokens). See docs/live-activity-push-setup.md
// for how to supply credentials and wire the remaining client→relay token plumbing.
package apns

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"
)

// Config carries the APNs auth-key credentials from the Apple Developer portal.
type Config struct {
	KeyID      string // 10-char Key ID of the .p8 auth key
	TeamID     string // 10-char Apple Developer Team ID
	Topic      string // app bundle id, e.g. dev.cchandoff.app (client appends the suffix)
	P8PEM      []byte // contents of AuthKey_XXXXXXXXXX.p8 (PKCS#8 PEM)
	Production bool   // true → api.push.apple.com, false → sandbox
}

// Client sends Live Activity pushes. Safe for concurrent use.
type Client struct {
	cfg Config
	key *ecdsa.PrivateKey

	// BaseURL and HTTPClient are exposed so tests can intercept requests; in
	// production leave them at their New() defaults (real APNs over HTTP/2).
	BaseURL    string
	HTTPClient *http.Client
	// Now is the clock, overridable in tests for deterministic JWT iat.
	Now func() time.Time

	mu        sync.Mutex
	jwt       string
	jwtIssued time.Time
}

// New parses the .p8 key and returns a ready client. Apple defaults to HTTP/2
// over TLS, which Go's net/http negotiates automatically.
func New(cfg Config) (*Client, error) {
	if cfg.KeyID == "" || cfg.TeamID == "" || cfg.Topic == "" {
		return nil, errors.New("apns: KeyID, TeamID and Topic are required")
	}
	key, err := parseP8(cfg.P8PEM)
	if err != nil {
		return nil, err
	}
	base := "https://api.sandbox.push.apple.com"
	if cfg.Production {
		base = "https://api.push.apple.com"
	}
	return &Client{
		cfg:        cfg,
		key:        key,
		BaseURL:    base,
		HTTPClient: &http.Client{Timeout: 15 * time.Second},
		Now:        time.Now,
	}, nil
}

func parseP8(pemBytes []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("apns: invalid .p8 PEM")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("apns: parse p8: %w", err)
	}
	ec, ok := k.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("apns: .p8 is not an ECDSA P-256 key")
	}
	return ec, nil
}

func (c *Client) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

// bearer returns a provider JWT (ES256), cached and refreshed under Apple's
// 1-hour limit (Apple rejects tokens regenerated too often and tokens > 1h old).
func (c *Client) bearer() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.jwt != "" && c.now().Sub(c.jwtIssued) < 50*time.Minute {
		return c.jwt, nil
	}
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": c.cfg.KeyID})
	claims, _ := json.Marshal(map[string]any{"iss": c.cfg.TeamID, "iat": c.now().Unix()})
	signing := b64(header) + "." + b64(claims)
	digest := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, c.key, digest[:])
	if err != nil {
		return "", err
	}
	// JWS ES256 wants the raw 64-byte r||s, each left-padded to 32 bytes — NOT
	// the ASN.1 DER that ecdsa.SignASN1 produces.
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	c.jwt = signing + "." + base64.RawURLEncoding.EncodeToString(sig)
	c.jwtIssued = c.now()
	return c.jwt, nil
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// Notification is one Live Activity push.
type Notification struct {
	DeviceToken   string         // the activity's pushToken (hex), from pushTokenUpdates
	Event         string         // "update" or "end"
	ContentState  map[string]any // must match the Swift ContentState Codable keys
	Timestamp     int64          // unix seconds; 0 → now
	StaleDate     int64          // unix seconds; 0 → omit
	DismissalDate int64          // unix seconds (for "end"); 0 → omit
	Priority      int            // 10 (immediate) or 5 (conserve power); 0 → 10
}

// Result reports APNs' response.
type Result struct {
	APNsID string
	Status int
}

// Push delivers one Live Activity update/end. Returns a non-nil error (with the
// APNs reason body) on any non-200 status.
func (c *Client) Push(ctx context.Context, n Notification) (*Result, error) {
	if n.DeviceToken == "" {
		return nil, errors.New("apns: empty device token")
	}
	if n.Event == "" {
		n.Event = "update"
	}
	ts := n.Timestamp
	if ts == 0 {
		ts = c.now().Unix()
	}
	aps := map[string]any{
		"timestamp":     ts,
		"event":         n.Event,
		"content-state": n.ContentState,
	}
	if n.StaleDate > 0 {
		aps["stale-date"] = n.StaleDate
	}
	if n.DismissalDate > 0 {
		aps["dismissal-date"] = n.DismissalDate
	}
	body, err := json.Marshal(map[string]any{"aps": aps})
	if err != nil {
		return nil, err
	}
	bearer, err := c.bearer()
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(
		ctx, http.MethodPost, c.BaseURL+"/3/device/"+n.DeviceToken, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	prio := n.Priority
	if prio == 0 {
		prio = 10
	}
	req.Header.Set("authorization", "bearer "+bearer)
	req.Header.Set("apns-topic", c.cfg.Topic+".push-type.liveactivity")
	req.Header.Set("apns-push-type", "liveactivity")
	req.Header.Set("apns-priority", strconv.Itoa(prio))
	req.Header.Set("content-type", "application/json")

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	rb, _ := io.ReadAll(resp.Body)
	res := &Result{APNsID: resp.Header.Get("apns-id"), Status: resp.StatusCode}
	if resp.StatusCode != http.StatusOK {
		return res, fmt.Errorf("apns: push rejected (%d): %s", resp.StatusCode, bytes.TrimSpace(rb))
	}
	return res, nil
}
