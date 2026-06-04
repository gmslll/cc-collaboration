package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"

	"golang.org/x/crypto/bcrypt"
)

// HashToken returns the sha256-hex of a raw bearer token — the form stored in
// the token registry, the sessions table, and the machine_tokens table. The
// raw token is never persisted.
func HashToken(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

// NewToken mints a random 256-bit bearer token (hex). Used for both UI login
// sessions and user-minted machine tokens; the caller stores only HashToken(it)
// and shows the raw value once.
func NewToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// GeneratePassword mints a short random password (20 hex chars ≈ 80 bits) for
// admin-provisioned accounts. Shared by the relay's create/reset handlers and
// the `useradd` bootstrap subcommand.
func GeneratePassword() (string, error) {
	t, err := NewToken()
	if err != nil {
		return "", err
	}
	return t[:20], nil
}

// HashPassword returns a bcrypt hash suitable for storage.
func HashPassword(pw string) (string, error) {
	h, err := bcrypt.GenerateFromPassword([]byte(pw), bcrypt.DefaultCost)
	return string(h), err
}

// CheckPassword reports whether pw matches the bcrypt hash.
func CheckPassword(hash, pw string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(pw)) == nil
}
