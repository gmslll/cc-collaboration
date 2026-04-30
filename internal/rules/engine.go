package rules

import (
	"fmt"
	"regexp"
	"strings"
	"sync"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/pkg/handoffschema"
)

// Engine compiles a set of partner_mapping rules once and applies them to
// changed paths. Compilation is cached so repeated submits stay cheap.
type Engine struct {
	rules []compiledRule
}

type compiledRule struct {
	src config.Rule
	re  *regexp.Regexp
}

// Compile validates and compiles a ruleset. Returns an error listing all
// invalid regexes — callers should surface this so users can fix their config.
func Compile(rules []config.Rule) (*Engine, error) {
	out := make([]compiledRule, 0, len(rules))
	var errs []string
	for i, r := range rules {
		if r.WhenPathMatches == "" {
			errs = append(errs, fmt.Sprintf("rule[%d]: when_path_matches is required", i))
			continue
		}
		re, err := regexp.Compile(r.WhenPathMatches)
		if err != nil {
			errs = append(errs, fmt.Sprintf("rule[%d]: %v", i, err))
			continue
		}
		out = append(out, compiledRule{src: r, re: re})
	}
	if len(errs) > 0 {
		return nil, fmt.Errorf("invalid rules:\n  %s", strings.Join(errs, "\n  "))
	}
	return &Engine{rules: out}, nil
}

// Apply walks each changed path, runs every rule against it, and returns a
// deduplicated slice of TargetingHints. Each hint records which path matched
// and which capture groups were used for template expansion, so the receiving
// side can show *why* a target was suggested.
//
// Two-stage dedup: first by (path, edits, creates) so a single path doesn't
// appear twice; then by (edits, creates) alone so a module mode that walks
// many files all routing to the same client target collapses to one
// representative hint with a "(and N other paths in module)" suffix.
func (e *Engine) Apply(changedPaths []string) []handoffschema.TargetingHint {
	if e == nil || len(e.rules) == 0 || len(changedPaths) == 0 {
		return nil
	}
	seen := make(map[string]struct{})
	var hints []handoffschema.TargetingHint

	for _, path := range changedPaths {
		for _, cr := range e.rules {
			match := cr.re.FindStringSubmatch(path)
			if match == nil {
				continue
			}
			captures := captureMap(cr.re, match)
			edits := renderAll(cr.src.SuggestEdit, captures)
			var creates []string
			if cr.src.SuggestCreateIfMissing {
				creates = edits
			}
			key := dedupeKey(path, edits, creates)
			if _, dup := seen[key]; dup {
				continue
			}
			seen[key] = struct{}{}
			hints = append(hints, handoffschema.TargetingHint{
				Reason:        "matched rule " + cr.src.WhenPathMatches,
				MatchedPath:   path,
				Captures:      captures,
				SuggestEdit:   edits,
				SuggestCreate: creates,
			})
		}
	}

	return collapseByTarget(hints)
}

// collapseByTarget folds hints that share the same (SuggestEdit, SuggestCreate)
// down to a single representative hint, recording how many other paths fed
// into it on the Reason line. Useful in module mode where every handler/dto
// file in the same module routes to the same client target.
func collapseByTarget(hints []handoffschema.TargetingHint) []handoffschema.TargetingHint {
	if len(hints) <= 1 {
		return hints
	}
	idxByKey := make(map[string]int, len(hints))
	extras := make(map[string]int, len(hints))
	out := make([]handoffschema.TargetingHint, 0, len(hints))
	for _, h := range hints {
		key := strings.Join(h.SuggestEdit, ",") + "|" + strings.Join(h.SuggestCreate, ",")
		if _, ok := idxByKey[key]; ok {
			extras[key]++
			continue
		}
		idxByKey[key] = len(out)
		out = append(out, h)
	}
	for key, n := range extras {
		if n == 0 {
			continue
		}
		i := idxByKey[key]
		out[i].Reason = fmt.Sprintf("%s (and %d other paths in module)", out[i].Reason, n)
	}
	return out
}

func captureMap(re *regexp.Regexp, match []string) map[string]string {
	names := re.SubexpNames()
	out := make(map[string]string, len(names))
	for i, name := range names {
		if name == "" || i >= len(match) {
			continue
		}
		out[name] = match[i]
	}
	return out
}

// renderAll expands {name} placeholders using captures. Unknown names are left
// as-is so users notice typos in their rules instead of getting silent empties.
var placeholderRE = sync.OnceValue(func() *regexp.Regexp {
	return regexp.MustCompile(`\{([a-zA-Z_][a-zA-Z0-9_]*)\}`)
})

func renderAll(templates []string, captures map[string]string) []string {
	if len(templates) == 0 {
		return nil
	}
	out := make([]string, len(templates))
	re := placeholderRE()
	for i, tmpl := range templates {
		out[i] = re.ReplaceAllStringFunc(tmpl, func(token string) string {
			name := token[1 : len(token)-1]
			if v, ok := captures[name]; ok {
				return v
			}
			return token
		})
	}
	return out
}

func dedupeKey(path string, edits, creates []string) string {
	var sb strings.Builder
	sb.WriteString(path)
	sb.WriteByte('|')
	sb.WriteString(strings.Join(edits, ","))
	sb.WriteByte('|')
	sb.WriteString(strings.Join(creates, ","))
	return sb.String()
}
