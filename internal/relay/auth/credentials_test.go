package auth

import "testing"

func TestPasswordRoundTrip(t *testing.T) {
	h, err := HashPassword("hunter2horse")
	if err != nil {
		t.Fatal(err)
	}
	if h == "hunter2horse" {
		t.Error("password stored in plaintext")
	}
	if !CheckPassword(h, "hunter2horse") {
		t.Error("correct password rejected")
	}
	if CheckPassword(h, "wrong") {
		t.Error("wrong password accepted")
	}
}

func TestNewTokenUniqueAndHashed(t *testing.T) {
	a, err := NewToken()
	if err != nil {
		t.Fatal(err)
	}
	b, _ := NewToken()
	if a == b {
		t.Error("tokens not unique")
	}
	if len(a) != 64 {
		t.Errorf("token len = %d, want 64 hex chars", len(a))
	}
	if HashToken(a) == a {
		t.Error("hash equals raw token")
	}
	if HashToken(a) != HashToken(a) {
		t.Error("hash is not deterministic")
	}
}
