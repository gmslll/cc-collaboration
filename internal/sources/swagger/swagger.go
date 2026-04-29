// Package swagger computes a coarse OpenAPI delta between the current spec
// file and the version cached at ~/.cache/cc-handoff/<repo-hash>/swagger.last.yaml.
// It does not validate the spec — it just walks the `paths.<route>.<method>`
// tree and reports added/changed/removed operations.
package swagger

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/cc-collaboration/pkg/handoffschema"
)

// Collect compares the spec at specPath against the cached previous version
// and returns an APIDelta. If specPath does not exist, returns (nil, nil) so
// callers can treat "no swagger file" as a non-fatal absence.
//
// repoRoot is used as the cache key (its absolute path is hashed) so that two
// distinct repos on the same machine don't share a cache.
func Collect(repoRoot, specPath string) (*handoffschema.APIDelta, error) {
	abs, err := filepath.Abs(specPath)
	if err != nil {
		return nil, err
	}
	current, err := os.ReadFile(abs)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("read swagger %s: %w", abs, err)
	}

	cacheDir, err := cachePath(repoRoot)
	if err != nil {
		return nil, err
	}
	cacheFile := filepath.Join(cacheDir, "swagger.last.yaml")
	previous, _ := os.ReadFile(cacheFile) // first run: empty previous

	delta, err := diff(previous, current)
	if err != nil {
		return nil, err
	}

	// Skip the cache write when nothing changed: the bytes on disk already
	// equal `current` (modulo whitespace tolerated by the YAML parser).
	if delta != nil {
		if err := os.MkdirAll(cacheDir, 0o755); err != nil {
			return nil, err
		}
		if err := os.WriteFile(cacheFile, current, 0o644); err != nil {
			return nil, err
		}
	}
	return delta, nil
}

func cachePath(repoRoot string) (string, error) {
	abs, err := filepath.Abs(repoRoot)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256([]byte(abs))
	hash := hex.EncodeToString(sum[:])[:16]

	base, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "cc-handoff", hash), nil
}

type spec struct {
	Paths map[string]map[string]operation `yaml:"paths"`
}

type operation struct {
	OperationID string `yaml:"operationId"`
	Summary     string `yaml:"summary"`
}

func diff(previous, current []byte) (*handoffschema.APIDelta, error) {
	prev, err := parse(previous)
	if err != nil {
		return nil, fmt.Errorf("parse previous swagger: %w", err)
	}
	curr, err := parse(current)
	if err != nil {
		return nil, fmt.Errorf("parse current swagger: %w", err)
	}

	out := &handoffschema.APIDelta{Format: "openapi-3"}

	for path, methods := range curr {
		for method, op := range methods {
			prevOp, existed := lookup(prev, path, method)
			if !existed {
				out.Added = append(out.Added, op)
				continue
			}
			if prevOp.OperationID != op.OperationID || prevOp.Summary != op.Summary {
				out.Changed = append(out.Changed, op)
			}
		}
	}
	for path, methods := range prev {
		for method, op := range methods {
			if _, ok := lookup(curr, path, method); !ok {
				out.Removed = append(out.Removed, op)
			}
		}
	}

	sortOps := func(ops []handoffschema.Operation) {
		sort.Slice(ops, func(i, j int) bool {
			if ops[i].Path != ops[j].Path {
				return ops[i].Path < ops[j].Path
			}
			return ops[i].Method < ops[j].Method
		})
	}
	sortOps(out.Added)
	sortOps(out.Changed)
	sortOps(out.Removed)

	if len(out.Added)+len(out.Changed)+len(out.Removed) == 0 {
		return nil, nil
	}
	return out, nil
}

// parse returns map[path]map[uppercase-method]Operation. Empty input yields nil.
func parse(b []byte) (map[string]map[string]handoffschema.Operation, error) {
	if len(b) == 0 {
		return nil, nil
	}
	var s spec
	if err := yaml.Unmarshal(b, &s); err != nil {
		return nil, err
	}
	out := make(map[string]map[string]handoffschema.Operation, len(s.Paths))
	for path, methods := range s.Paths {
		bucket := make(map[string]handoffschema.Operation, len(methods))
		for method, raw := range methods {
			m := strings.ToUpper(method)
			if !isHTTPMethod(m) {
				continue
			}
			bucket[m] = handoffschema.Operation{
				Method:      m,
				Path:        path,
				OperationID: raw.OperationID,
				Summary:     raw.Summary,
			}
		}
		out[path] = bucket
	}
	return out, nil
}

func lookup(m map[string]map[string]handoffschema.Operation, path, method string) (handoffschema.Operation, bool) {
	if methods, ok := m[path]; ok {
		if op, ok := methods[method]; ok {
			return op, true
		}
	}
	return handoffschema.Operation{}, false
}

func isHTTPMethod(m string) bool {
	switch m {
	case "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS":
		return true
	}
	return false
}
