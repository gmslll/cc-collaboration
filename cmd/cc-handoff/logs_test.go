package main

import (
	"regexp"
	"testing"

	"github.com/cc-collaboration/internal/config"
)

func TestExtractLatestError(t *testing.T) {
	re := regexp.MustCompile(config.DefaultLogErrorPattern)

	tests := []struct {
		name    string
		raw     string
		context int
		tail    int
		want    string
	}{
		{
			name:    "last match wins with context",
			raw:     "line1\nline2\nERROR first\nline4\nline5\nline6\nline7\nERROR second\nline9\nline10",
			context: 1,
			tail:    5,
			want:    "line7\nERROR second\nline9",
		},
		{
			name:    "no match falls back to tail",
			raw:     "a\nb\nc\nd",
			context: 3,
			tail:    2,
			want:    "c\nd",
		},
		{
			name:    "context clamps at end",
			raw:     "x1\nx2\nboom ERROR",
			context: 2,
			tail:    5,
			want:    "x1\nx2\nboom ERROR",
		},
		{
			name:    "single matching line",
			raw:     "just an Error here\n",
			context: 5,
			tail:    5,
			want:    "just an Error here",
		},
		{
			name:    "empty input",
			raw:     "",
			context: 3,
			tail:    3,
			want:    "",
		},
		{
			name:    "no match, fewer lines than tail keeps all",
			raw:     "only\ntwo",
			context: 1,
			tail:    10,
			want:    "only\ntwo",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := extractLatestError(tt.raw, re, tt.context, tt.tail)
			if got != tt.want {
				t.Errorf("extractLatestError() =\n%q\nwant\n%q", got, tt.want)
			}
		})
	}
}
