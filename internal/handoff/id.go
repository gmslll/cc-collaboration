package handoff

import (
	"crypto/rand"
	"encoding/base32"
	"strings"
	"time"
)

// NewID returns a sortable, human-friendly handoff id like "h_20260428_K8H3J7Q2".
func NewID(now time.Time) string {
	var b [5]byte
	_, _ = rand.Read(b[:])
	tail := strings.TrimRight(base32.StdEncoding.EncodeToString(b[:]), "=")
	return "h_" + now.UTC().Format("20060102") + "_" + tail
}

// ShortSHA returns the first 8 characters of a git SHA, or the full string if shorter.
func ShortSHA(sha string) string {
	if len(sha) <= 8 {
		return sha
	}
	return sha[:8]
}
