package githubrepo

import (
	"errors"
	"net/url"
	"regexp"
	"strings"
	"unicode"
)

var componentPattern = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)

// CloneURL is a validated GitHub repository remote. URL is normalized for
// storage while Key identifies the repository independently of HTTPS vs SSH.
type CloneURL struct {
	URL      string
	RepoName string
	Key      string
}

// Normalize validates a GitHub HTTPS or SSH clone URL. It deliberately rejects
// credentials, query strings, fragments, local/file URLs and non-GitHub hosts:
// repository bindings are shared team metadata, never a place to persist a
// personal token or password.
func Normalize(raw string) (CloneURL, error) {
	if hasControl(raw) {
		return CloneURL{}, errors.New("control characters are not allowed")
	}
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return CloneURL{}, errors.New("URL is required")
	}
	if len(raw) > 2048 {
		return CloneURL{}, errors.New("URL is too long")
	}
	// Reject even empty query/fragment delimiters. url.URL represents a
	// trailing '#' as an empty Fragment, which would otherwise make it
	// indistinguishable from a URL with no fragment at all.
	if strings.ContainsAny(raw, "?#") {
		return CloneURL{}, errors.New("query strings and fragments are not allowed")
	}
	if strings.HasPrefix(strings.ToLower(raw), "git@github.com:") {
		return normalizeSCP(raw)
	}
	u, err := url.Parse(raw)
	if err != nil || u == nil {
		return CloneURL{}, errors.New("malformed URL")
	}
	switch strings.ToLower(u.Scheme) {
	case "https":
		return normalizeHTTPS(u)
	case "ssh":
		return normalizeSSH(u)
	default:
		return CloneURL{}, errors.New("use a GitHub HTTPS or SSH URL")
	}
}

// SameRepository reports whether both remotes identify the same GitHub owner
// and repository. This lets an HTTPS-bound project safely import an existing
// SSH checkout (and vice versa) without treating credential transport as part
// of repository identity.
func SameRepository(left, right string) bool {
	a, err := Normalize(left)
	if err != nil {
		return false
	}
	b, err := Normalize(right)
	return err == nil && a.Key == b.Key
}

func normalizeHTTPS(u *url.URL) (CloneURL, error) {
	if !strings.EqualFold(u.Hostname(), "github.com") || u.Port() != "" {
		return CloneURL{}, errors.New("host must be github.com")
	}
	if u.User != nil {
		return CloneURL{}, errors.New("credentials must not be embedded in the URL")
	}
	if u.RawQuery != "" || u.Fragment != "" || u.RawPath != "" {
		return CloneURL{}, errors.New("query strings, fragments and escaped paths are not allowed")
	}
	owner, repo, err := pathParts(u.Path)
	if err != nil {
		return CloneURL{}, err
	}
	return cloneURL("https://github.com/"+owner+"/"+repo+".git", owner, repo), nil
}

func normalizeSSH(u *url.URL) (CloneURL, error) {
	if !strings.EqualFold(u.Hostname(), "github.com") || u.Port() != "" {
		return CloneURL{}, errors.New("host must be github.com")
	}
	if u.User == nil || u.User.Username() != "git" {
		return CloneURL{}, errors.New("GitHub SSH URLs must use the git user")
	}
	if _, ok := u.User.Password(); ok {
		return CloneURL{}, errors.New("credentials must not be embedded in the URL")
	}
	if u.RawQuery != "" || u.Fragment != "" || u.RawPath != "" {
		return CloneURL{}, errors.New("query strings, fragments and escaped paths are not allowed")
	}
	owner, repo, err := pathParts(u.Path)
	if err != nil {
		return CloneURL{}, err
	}
	return cloneURL("git@github.com:"+owner+"/"+repo+".git", owner, repo), nil
}

func normalizeSCP(raw string) (CloneURL, error) {
	const prefix = "git@github.com:"
	if len(raw) < len(prefix) || !strings.EqualFold(raw[:len(prefix)], prefix) {
		return CloneURL{}, errors.New("host must be github.com")
	}
	owner, repo, err := pathParts(strings.TrimPrefix(raw[len(prefix):], "/"))
	if err != nil {
		return CloneURL{}, err
	}
	return cloneURL("git@github.com:"+owner+"/"+repo+".git", owner, repo), nil
}

func pathParts(path string) (string, string, error) {
	path = strings.Trim(path, "/")
	parts := strings.Split(path, "/")
	if len(parts) != 2 {
		return "", "", errors.New("URL must name one GitHub owner and repository")
	}
	owner := parts[0]
	repo := strings.TrimSuffix(parts[1], ".git")
	if owner == "" || repo == "" || owner == "." || owner == ".." || repo == "." || repo == ".." {
		return "", "", errors.New("owner and repository are required")
	}
	if !componentPattern.MatchString(owner) || !componentPattern.MatchString(repo) {
		return "", "", errors.New("owner or repository contains unsupported characters")
	}
	return owner, repo, nil
}

func cloneURL(normalized, owner, repo string) CloneURL {
	return CloneURL{
		URL:      normalized,
		RepoName: repo,
		Key:      strings.ToLower(owner + "/" + repo),
	}
}

func hasControl(value string) bool {
	for _, r := range value {
		if unicode.IsControl(r) {
			return true
		}
	}
	return false
}
