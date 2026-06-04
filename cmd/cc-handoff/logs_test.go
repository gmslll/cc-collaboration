package main

import (
	"regexp"
	"testing"

	"github.com/cc-collaboration/internal/config"
)

func TestExtractLatestError(t *testing.T) {
	re := regexp.MustCompile(config.DefaultLogErrorPattern)

	tests := []struct {
		name      string
		raw       string
		context   int
		tail      int
		want      string
		wantMatch string
	}{
		{
			name:      "last match wins with context",
			raw:       "line1\nline2\nERROR first\nline4\nline5\nline6\nline7\nERROR second\nline9\nline10",
			context:   1,
			tail:      5,
			want:      "line7\nERROR second\nline9",
			wantMatch: "ERROR second",
		},
		{
			name:      "no match falls back to tail",
			raw:       "a\nb\nc\nd",
			context:   3,
			tail:      2,
			want:      "c\nd",
			wantMatch: "",
		},
		{
			name:      "context clamps at end",
			raw:       "x1\nx2\nboom ERROR",
			context:   2,
			tail:      5,
			want:      "x1\nx2\nboom ERROR",
			wantMatch: "boom ERROR",
		},
		{
			name:      "single matching line",
			raw:       "just an Error here\n",
			context:   5,
			tail:      5,
			want:      "just an Error here",
			wantMatch: "just an Error here",
		},
		{
			name:      "empty input",
			raw:       "",
			context:   3,
			tail:      3,
			want:      "",
			wantMatch: "",
		},
		{
			name:      "no match, fewer lines than tail keeps all",
			raw:       "only\ntwo",
			context:   1,
			tail:      10,
			want:      "only\ntwo",
			wantMatch: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, gotMatch := extractLatestError(tt.raw, re, tt.context, tt.tail)
			if got != tt.want {
				t.Errorf("extractLatestError() excerpt =\n%q\nwant\n%q", got, tt.want)
			}
			if gotMatch != tt.wantMatch {
				t.Errorf("extractLatestError() matchLine = %q, want %q", gotMatch, tt.wantMatch)
			}
		})
	}
}

func TestErrorFingerprint(t *testing.T) {
	// Same failure, different timestamp / id / hex address / line number → same
	// fingerprint (so it dedups to one backup).
	a := errorFingerprint("2026-06-04T10:00:00 ERROR conn 0xab12 id=42 failed at line 318")
	b := errorFingerprint("2026-06-04T11:30:09 ERROR conn 0xcd99 id=77 failed at line 902")
	if a != b {
		t.Errorf("same error with volatile parts should share a fingerprint: %s != %s", a, b)
	}

	// A genuinely different error must not collide.
	c := errorFingerprint("2026-06-04T10:00:00 ERROR disk full on /var")
	if a == c {
		t.Errorf("different errors should not share a fingerprint: %s == %s", a, c)
	}

	// UUIDs are normalized too.
	u1 := errorFingerprint("request 550e8400-e29b-41d4-a716-446655440000 timed out")
	u2 := errorFingerprint("request 7c9e6679-7425-40de-944b-e07fc1f90ae7 timed out")
	if u1 != u2 {
		t.Errorf("UUID-only difference should share a fingerprint: %s != %s", u1, u2)
	}
}

func TestParseSeverity(t *testing.T) {
	tests := []struct {
		in   string
		want string
	}{
		{"high", "high"},
		{"High", "high"},
		{"  CRITICAL\n", "critical"},
		{"The severity is medium because the service degraded.", "medium"},
		{"I cannot determine the level.", ""},
		{"", ""},
	}
	for _, tt := range tests {
		if got := parseSeverity(tt.in); got != tt.want {
			t.Errorf("parseSeverity(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}
