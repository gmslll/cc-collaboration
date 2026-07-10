package githubrepo

import (
	"strings"
	"testing"
)

func TestNormalize(t *testing.T) {
	tests := []struct {
		name, input, wantURL, wantRepo string
	}{
		{"https", " https://github.com/acme/widget ", "https://github.com/acme/widget.git", "widget"},
		{"https git", "https://github.com/acme/widget.git", "https://github.com/acme/widget.git", "widget"},
		{"scp", "git@github.com:acme/widget", "git@github.com:acme/widget.git", "widget"},
		{"ssh", "ssh://git@github.com/acme/widget.git", "git@github.com:acme/widget.git", "widget"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Normalize(tt.input)
			if err != nil {
				t.Fatal(err)
			}
			if got.URL != tt.wantURL || got.RepoName != tt.wantRepo || got.Key != "acme/widget" {
				t.Fatalf("Normalize() = %+v", got)
			}
		})
	}
}

func TestNormalizeRejectsUnsafeURLs(t *testing.T) {
	for _, input := range []string{
		"",
		"file:///tmp/repo",
		"/tmp/repo",
		"http://github.com/acme/widget",
		"https://token@github.com/acme/widget.git",
		"https://github.com/acme/widget.git?token=secret",
		"https://github.com/acme/widget.git?",
		"https://github.com/acme/widget.git#",
		"https://github.com:443/acme/widget.git",
		"https://gitlab.com/acme/widget.git",
		"git@github.com:acme/widget.git\n--upload-pack=evil",
		"ssh://root@github.com/acme/widget.git",
		"ssh://git:password@github.com/acme/widget.git",
		"ssh://git@github.com:22/acme/widget.git",
		"git://github.com/acme/widget.git",
		"https://github.com/acme/widget/extra",
		"https://github.com/acme/" + strings.Repeat("a", 2050),
	} {
		t.Run(input, func(t *testing.T) {
			if got, err := Normalize(input); err == nil {
				t.Fatalf("Normalize(%q) unexpectedly succeeded: %+v", input, got)
			}
		})
	}
}

func TestSameRepositoryIgnoresCloneTransport(t *testing.T) {
	if !SameRepository("https://github.com/Acme/Widget.git", "git@github.com:acme/widget.git") {
		t.Fatal("same GitHub repository should match across HTTPS and SSH")
	}
	if SameRepository("https://github.com/acme/one.git", "git@github.com:acme/two.git") {
		t.Fatal("different repositories must not match")
	}
}
