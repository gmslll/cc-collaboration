package apns

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"strings"
	"testing"
	"time"
)

type rtFunc func(*http.Request) (*http.Response, error)

func (f rtFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func testKeyPEM(t *testing.T) ([]byte, *ecdsa.PublicKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), &key.PublicKey
}

func TestNewRejectsBadP8(t *testing.T) {
	if _, err := New(Config{KeyID: "K", TeamID: "T", Topic: "x", P8PEM: []byte("nope")}); err == nil {
		t.Fatal("expected error for bad p8")
	}
}

func TestNewRequiresFields(t *testing.T) {
	pemB, _ := testKeyPEM(t)
	if _, err := New(Config{Topic: "x", P8PEM: pemB}); err == nil {
		t.Fatal("expected error for missing KeyID/TeamID")
	}
}

func TestPushBuildsCorrectRequest(t *testing.T) {
	pemB, pub := testKeyPEM(t)
	c, err := New(Config{
		KeyID: "ABC1234567", TeamID: "TEAM123456",
		Topic: "dev.cchandoff.app", P8PEM: pemB,
	})
	if err != nil {
		t.Fatal(err)
	}
	c.Now = func() time.Time { return time.Unix(1700000000, 0) }

	var got *http.Request
	var gotBody []byte
	c.HTTPClient = &http.Client{Transport: rtFunc(func(r *http.Request) (*http.Response, error) {
		got = r
		gotBody, _ = io.ReadAll(r.Body)
		h := http.Header{}
		h.Set("apns-id", "ABC-123")
		return &http.Response{StatusCode: 200, Header: h, Body: io.NopCloser(strings.NewReader(""))}, nil
	})}

	res, err := c.Push(context.Background(), Notification{
		DeviceToken:  "deadbeef",
		Event:        "update",
		ContentState: map[string]any{"working": true, "latestText": "hi", "updatedAt": 1.0},
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.APNsID != "ABC-123" {
		t.Errorf("apns-id = %q", res.APNsID)
	}
	if !strings.HasSuffix(got.URL.Path, "/3/device/deadbeef") {
		t.Errorf("path = %s", got.URL.Path)
	}
	if got.URL.Host != "api.sandbox.push.apple.com" {
		t.Errorf("host = %s (want sandbox by default)", got.URL.Host)
	}
	if v := got.Header.Get("apns-push-type"); v != "liveactivity" {
		t.Errorf("apns-push-type = %q", v)
	}
	if v := got.Header.Get("apns-topic"); v != "dev.cchandoff.app.push-type.liveactivity" {
		t.Errorf("apns-topic = %q", v)
	}
	if v := got.Header.Get("apns-priority"); v != "10" {
		t.Errorf("apns-priority = %q", v)
	}
	auth := got.Header.Get("authorization")
	if !strings.HasPrefix(auth, "bearer ") {
		t.Fatalf("authorization = %q", auth)
	}
	verifyJWT(t, strings.TrimPrefix(auth, "bearer "), pub, "ABC1234567", "TEAM123456")

	var payload struct {
		APS struct {
			Event string         `json:"event"`
			CS    map[string]any `json:"content-state"`
		} `json:"aps"`
	}
	if err := json.Unmarshal(gotBody, &payload); err != nil {
		t.Fatal(err)
	}
	if payload.APS.Event != "update" {
		t.Errorf("event = %q", payload.APS.Event)
	}
	if payload.APS.CS["latestText"] != "hi" {
		t.Errorf("content-state = %v", payload.APS.CS)
	}
}

func verifyJWT(t *testing.T, tok string, pub *ecdsa.PublicKey, kid, iss string) {
	t.Helper()
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		t.Fatalf("jwt has %d parts", len(parts))
	}
	hdrB, _ := base64.RawURLEncoding.DecodeString(parts[0])
	var hdr map[string]string
	if err := json.Unmarshal(hdrB, &hdr); err != nil {
		t.Fatal(err)
	}
	if hdr["alg"] != "ES256" || hdr["kid"] != kid {
		t.Errorf("jwt header = %v", hdr)
	}
	clB, _ := base64.RawURLEncoding.DecodeString(parts[1])
	var claims map[string]any
	if err := json.Unmarshal(clB, &claims); err != nil {
		t.Fatal(err)
	}
	if claims["iss"] != iss {
		t.Errorf("jwt iss = %v", claims["iss"])
	}
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	if len(sig) != 64 {
		t.Fatalf("jwt sig len = %d (want 64 raw r||s)", len(sig))
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r := new(big.Int).SetBytes(sig[:32])
	s := new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(pub, digest[:], r, s) {
		t.Error("jwt signature does not verify against the public key")
	}
}

func TestPushReturnsErrorOnNon200(t *testing.T) {
	pemB, _ := testKeyPEM(t)
	c, _ := New(Config{KeyID: "K123456789", TeamID: "T123456789", Topic: "x", P8PEM: pemB})
	c.HTTPClient = &http.Client{Transport: rtFunc(func(r *http.Request) (*http.Response, error) {
		h := http.Header{}
		h.Set("apns-id", "E1")
		return &http.Response{
			StatusCode: 400, Header: h,
			Body: io.NopCloser(strings.NewReader(`{"reason":"BadDeviceToken"}`)),
		}, nil
	})}
	_, err := c.Push(context.Background(), Notification{DeviceToken: "t", ContentState: map[string]any{}})
	if err == nil || !strings.Contains(err.Error(), "BadDeviceToken") {
		t.Fatalf("err = %v (want it to carry the APNs reason)", err)
	}
}

func TestProductionHost(t *testing.T) {
	pemB, _ := testKeyPEM(t)
	c, _ := New(Config{KeyID: "K123456789", TeamID: "T123456789", Topic: "x", P8PEM: pemB, Production: true})
	if !strings.Contains(c.BaseURL, "api.push.apple.com") {
		t.Errorf("BaseURL = %s (want production host)", c.BaseURL)
	}
}
