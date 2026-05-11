// Package swagger computes a delta between an OpenAPI 3 spec and the
// version cached at ~/.cache/cc-handoff/<repo-hash>/swagger.last.yaml. It
// reports added/changed/removed operations and, for each operation,
// field-level diffs of request body, response bodies (per status code),
// parameters, error-code lists, response headers, and security requirements.
// Top-level servers and security changes also surface on the APIDelta.
package swagger

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/cc-collaboration/pkg/handoffschema"
)

// maxDepth bounds recursion through nested object/array/$ref schemas so a
// self-referencing spec can't blow the stack. Real OpenAPI schemas rarely
// nest beyond ~4 levels; 8 is generous.
const maxDepth = 8

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

// ---- Raw YAML model -------------------------------------------------------

type rawSpec struct {
	Servers    []rawServer            `yaml:"servers"`
	Security   []rawSecReq            `yaml:"security"`
	Paths      map[string]rawPathItem `yaml:"paths"`
	Components rawComponents          `yaml:"components"`
}

type rawServer struct {
	URL string `yaml:"url"`
}

// rawSecReq maps security-scheme name → required scopes.
type rawSecReq map[string][]string

type rawPathItem map[string]rawOperation

type rawOperation struct {
	OperationID string                 `yaml:"operationId"`
	Summary     string                 `yaml:"summary"`
	Parameters  []rawParam             `yaml:"parameters"`
	RequestBody *rawRequestBody        `yaml:"requestBody"`
	Responses   map[string]rawResponse `yaml:"responses"`
	Security    []rawSecReq            `yaml:"security"`
}

type rawParam struct {
	Ref      string     `yaml:"$ref"`
	Name     string     `yaml:"name"`
	In       string     `yaml:"in"`
	Required bool       `yaml:"required"`
	Schema   *rawSchema `yaml:"schema"`
}

type rawRequestBody struct {
	Ref      string                  `yaml:"$ref"`
	Required bool                    `yaml:"required"`
	Content  map[string]rawMediaType `yaml:"content"`
}

type rawResponse struct {
	Ref     string                  `yaml:"$ref"`
	Content map[string]rawMediaType `yaml:"content"`
	Headers map[string]rawHeader    `yaml:"headers"`
}

type rawMediaType struct {
	Schema *rawSchema `yaml:"schema"`
}

type rawHeader struct {
	Ref    string     `yaml:"$ref"`
	Schema *rawSchema `yaml:"schema"`
}

type rawSchema struct {
	Ref        string                `yaml:"$ref"`
	Type       string                `yaml:"type"`
	Format     string                `yaml:"format"`
	Nullable   bool                  `yaml:"nullable"`
	Items      *rawSchema            `yaml:"items"`
	Properties map[string]*rawSchema `yaml:"properties"`
	Required   []string              `yaml:"required"`
	Enum       []any                 `yaml:"enum"`
	OneOf      []*rawSchema          `yaml:"oneOf"`
	AllOf      []*rawSchema          `yaml:"allOf"`
	AnyOf      []*rawSchema          `yaml:"anyOf"`
}

type rawComponents struct {
	Schemas       map[string]*rawSchema     `yaml:"schemas"`
	Parameters    map[string]rawParam       `yaml:"parameters"`
	RequestBodies map[string]rawRequestBody `yaml:"requestBodies"`
	Responses     map[string]rawResponse    `yaml:"responses"`
	Headers       map[string]rawHeader      `yaml:"headers"`
}

func parseSpec(b []byte) (*rawSpec, error) {
	if len(b) == 0 {
		return &rawSpec{}, nil
	}
	var s rawSpec
	if err := yaml.Unmarshal(b, &s); err != nil {
		return nil, err
	}
	return &s, nil
}

// ---- Helpers --------------------------------------------------------------

func isHTTPMethod(m string) bool {
	switch strings.ToLower(m) {
	case "get", "post", "put", "patch", "delete", "head", "options":
		return true
	}
	return false
}

// resolveSchemaRef walks a "#/components/schemas/X" reference once. Returns
// nil if the ref doesn't resolve — caller should treat as "<unresolved>".
func resolveSchemaRef(s *rawSchema, comps rawComponents) *rawSchema {
	if s == nil || s.Ref == "" {
		return s
	}
	name := refName(s.Ref, "schemas")
	if name == "" {
		return nil
	}
	return comps.Schemas[name]
}

func resolveParamRef(p rawParam, comps rawComponents) rawParam {
	if p.Ref == "" {
		return p
	}
	name := refName(p.Ref, "parameters")
	if name == "" {
		return p
	}
	if resolved, ok := comps.Parameters[name]; ok {
		return resolved
	}
	return p
}

func resolveResponseRef(r rawResponse, comps rawComponents) rawResponse {
	if r.Ref == "" {
		return r
	}
	name := refName(r.Ref, "responses")
	if name == "" {
		return r
	}
	if resolved, ok := comps.Responses[name]; ok {
		return resolved
	}
	return r
}

func resolveHeaderRef(h rawHeader, comps rawComponents) rawHeader {
	if h.Ref == "" {
		return h
	}
	name := refName(h.Ref, "headers")
	if name == "" {
		return h
	}
	if resolved, ok := comps.Headers[name]; ok {
		return resolved
	}
	return h
}

func refName(ref, kind string) string {
	prefix := "#/components/" + kind + "/"
	if !strings.HasPrefix(ref, prefix) {
		return ""
	}
	return strings.TrimPrefix(ref, prefix)
}

func enumStrings(e []any) []string {
	if len(e) == 0 {
		return nil
	}
	out := make([]string, 0, len(e))
	for _, v := range e {
		out = append(out, fmt.Sprintf("%v", v))
	}
	return out
}

// schemaSummary produces a FieldRef for a non-recursive snapshot of s (the
// type/format/etc on this node, ignoring nested properties). Used as Before
// or After on a FieldChange.
func schemaSummary(path string, s *rawSchema, required bool, comps rawComponents) FieldRef {
	if s == nil {
		return FieldRef{Path: path}
	}
	resolved := resolveSchemaRef(s, comps)
	if resolved == nil {
		// $ref didn't resolve — degrade gracefully.
		return FieldRef{Path: path, Type: "<unresolved>"}
	}
	if isPolymorphic(resolved) {
		return FieldRef{Path: path, Type: "<polymorphic>"}
	}
	return FieldRef{
		Path:     path,
		Type:     resolved.Type,
		Format:   resolved.Format,
		Nullable: resolved.Nullable,
		Required: required,
		Enum:     enumStrings(resolved.Enum),
	}
}

// FieldRef alias purely to keep the helper signatures terse.
type FieldRef = handoffschema.FieldRef

func isPolymorphic(s *rawSchema) bool {
	return s != nil && (len(s.OneOf) > 0 || len(s.AllOf) > 0 || len(s.AnyOf) > 0)
}

func joinPath(parent, child string) string {
	if parent == "" {
		return child
	}
	return parent + "." + child
}

// ---- Schema walk (one-sided, used for added/removed subtrees) -------------

// walkSchema emits one FieldRef per "leaf" plus container nodes that have
// children — i.e. it produces a flattened tree. Cycle-safe via depth cap.
// requiredOnParent indicates whether the slot at `path` is required.
func walkSchema(path string, s *rawSchema, requiredOnParent bool, comps rawComponents, depth int, out *[]FieldRef) {
	if depth > maxDepth {
		*out = append(*out, FieldRef{Path: path, Type: "<truncated>"})
		return
	}
	resolved := resolveSchemaRef(s, comps)
	if resolved == nil {
		*out = append(*out, FieldRef{Path: path, Type: "<unresolved>", Required: requiredOnParent})
		return
	}
	if isPolymorphic(resolved) {
		*out = append(*out, FieldRef{Path: path, Type: "<polymorphic>", Required: requiredOnParent})
		return
	}
	switch resolved.Type {
	case "object":
		if path != "" {
			*out = append(*out, FieldRef{
				Path:     path,
				Type:     "object",
				Nullable: resolved.Nullable,
				Required: requiredOnParent,
			})
		}
		names := make([]string, 0, len(resolved.Properties))
		for n := range resolved.Properties {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, name := range names {
			childRequired := slices.Contains(resolved.Required, name)
			walkSchema(joinPath(path, name), resolved.Properties[name], childRequired, comps, depth+1, out)
		}
	case "array":
		if path != "" {
			*out = append(*out, FieldRef{
				Path:     path,
				Type:     "array",
				Nullable: resolved.Nullable,
				Required: requiredOnParent,
			})
		}
		walkSchema(path+"[]", resolved.Items, false, comps, depth+1, out)
	default:
		if path == "" {
			return
		}
		*out = append(*out, FieldRef{
			Path:     path,
			Type:     resolved.Type,
			Format:   resolved.Format,
			Nullable: resolved.Nullable,
			Required: requiredOnParent,
			Enum:     enumStrings(resolved.Enum),
		})
	}
}

// ---- Schema diff (two-sided, recursive) -----------------------------------

func diffSchema(path string, prev, curr *rawSchema, requiredPrev, requiredCurr bool, prevComps, currComps rawComponents, depth int, out *handoffschema.SchemaDiff) {
	if depth > maxDepth {
		return
	}
	prevR := resolveSchemaRef(prev, prevComps)
	currR := resolveSchemaRef(curr, currComps)

	if prevR == nil && currR == nil {
		return
	}
	if prevR == nil {
		var added []FieldRef
		walkSchema(path, curr, requiredCurr, currComps, depth, &added)
		out.Added = append(out.Added, added...)
		return
	}
	if currR == nil {
		var removed []FieldRef
		walkSchema(path, prev, requiredPrev, prevComps, depth, &removed)
		out.Removed = append(out.Removed, removed...)
		return
	}

	// Both resolved — polymorphic schemas don't recurse.
	if isPolymorphic(prevR) || isPolymorphic(currR) {
		if !samePolymorphic(prevR, currR) {
			out.Changed = append(out.Changed, handoffschema.FieldChange{
				Path:   path,
				Before: schemaSummary(path, prev, requiredPrev, prevComps),
				After:  schemaSummary(path, curr, requiredCurr, currComps),
				Reason: "polymorphic",
			})
		}
		return
	}

	// Type / format / nullable differ → record change, stop recursing.
	if prevR.Type != currR.Type {
		out.Changed = append(out.Changed, handoffschema.FieldChange{
			Path:   path,
			Before: schemaSummary(path, prev, requiredPrev, prevComps),
			After:  schemaSummary(path, curr, requiredCurr, currComps),
			Reason: "type",
		})
		return
	}

	switch currR.Type {
	case "object":
		props := map[string]struct{}{}
		for n := range prevR.Properties {
			props[n] = struct{}{}
		}
		for n := range currR.Properties {
			props[n] = struct{}{}
		}
		names := make([]string, 0, len(props))
		for n := range props {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, name := range names {
			childPath := joinPath(path, name)
			prevChild := prevR.Properties[name]
			currChild := currR.Properties[name]
			prevReq := slices.Contains(prevR.Required, name)
			currReq := slices.Contains(currR.Required, name)
			diffSchema(childPath, prevChild, currChild, prevReq, currReq, prevComps, currComps, depth+1, out)
			// Required-flag flip is only a change when the field exists in BOTH
			// sides (otherwise added/removed already captures it).
			if prevChild != nil && currChild != nil && prevReq != currReq {
				before := schemaSummary(childPath, prevChild, prevReq, prevComps)
				after := schemaSummary(childPath, currChild, currReq, currComps)
				out.Changed = append(out.Changed, handoffschema.FieldChange{
					Path: childPath, Before: before, After: after, Reason: "required",
				})
			}
		}
	case "array":
		diffSchema(path+"[]", prevR.Items, currR.Items, false, false, prevComps, currComps, depth+1, out)
	default:
		// Leaf — compare format / nullable / enum.
		if prevR.Format != currR.Format {
			out.Changed = append(out.Changed, handoffschema.FieldChange{
				Path: path, Before: schemaSummary(path, prev, requiredPrev, prevComps), After: schemaSummary(path, curr, requiredCurr, currComps), Reason: "format",
			})
		}
		if prevR.Nullable != currR.Nullable {
			out.Changed = append(out.Changed, handoffschema.FieldChange{
				Path: path, Before: schemaSummary(path, prev, requiredPrev, prevComps), After: schemaSummary(path, curr, requiredCurr, currComps), Reason: "nullable",
			})
		}
		if !slices.Equal(enumStrings(prevR.Enum), enumStrings(currR.Enum)) {
			out.Changed = append(out.Changed, handoffschema.FieldChange{
				Path: path, Before: schemaSummary(path, prev, requiredPrev, prevComps), After: schemaSummary(path, curr, requiredCurr, currComps), Reason: "enum",
			})
		}
	}
}

func samePolymorphic(a, b *rawSchema) bool {
	if a == nil || b == nil {
		return a == b
	}
	return len(a.OneOf) == len(b.OneOf) &&
		len(a.AllOf) == len(b.AllOf) &&
		len(a.AnyOf) == len(b.AnyOf)
}

// ---- Parameters diff ------------------------------------------------------

// diffParameters returns a SchemaDiff treating each (in, name) param as a
// single leaf field with path "<in>.<name>".
func diffParameters(prev, curr []rawParam, prevComps, currComps rawComponents) *handoffschema.SchemaDiff {
	prevByKey := paramMap(prev, prevComps)
	currByKey := paramMap(curr, currComps)

	var d handoffschema.SchemaDiff
	keys := map[string]struct{}{}
	for k := range prevByKey {
		keys[k] = struct{}{}
	}
	for k := range currByKey {
		keys[k] = struct{}{}
	}
	sorted := make([]string, 0, len(keys))
	for k := range keys {
		sorted = append(sorted, k)
	}
	sort.Strings(sorted)
	for _, k := range sorted {
		p, prevHas := prevByKey[k]
		c, currHas := currByKey[k]
		switch {
		case !prevHas:
			d.Added = append(d.Added, paramFieldRef(k, c, currComps))
		case !currHas:
			d.Removed = append(d.Removed, paramFieldRef(k, p, prevComps))
		default:
			if p.Required != c.Required {
				d.Changed = append(d.Changed, handoffschema.FieldChange{
					Path: k, Before: paramFieldRef(k, p, prevComps), After: paramFieldRef(k, c, currComps), Reason: "required",
				})
			}
			// Compare param's inner schema as a sub-diff rooted at k. Most
			// param schemas are scalar so this stays cheap.
			diffSchema(k, p.Schema, c.Schema, p.Required, c.Required, prevComps, currComps, 0, &d)
		}
	}
	if len(d.Added)+len(d.Removed)+len(d.Changed) == 0 {
		return nil
	}
	return &d
}

func paramMap(ps []rawParam, comps rawComponents) map[string]rawParam {
	out := map[string]rawParam{}
	for _, p := range ps {
		p = resolveParamRef(p, comps)
		if p.Name == "" || p.In == "" {
			continue
		}
		out[p.In+"."+p.Name] = p
	}
	return out
}

func paramFieldRef(path string, p rawParam, comps rawComponents) FieldRef {
	return schemaSummary(path, p.Schema, p.Required, comps)
}

// ---- Headers diff ---------------------------------------------------------

func diffHeaders(prev, curr map[string]rawHeader, prevComps, currComps rawComponents) *handoffschema.SchemaDiff {
	keys := map[string]struct{}{}
	for k := range prev {
		keys[k] = struct{}{}
	}
	for k := range curr {
		keys[k] = struct{}{}
	}
	var d handoffschema.SchemaDiff
	sorted := make([]string, 0, len(keys))
	for k := range keys {
		sorted = append(sorted, k)
	}
	sort.Strings(sorted)
	for _, k := range sorted {
		p, prevHas := prev[k]
		c, currHas := curr[k]
		path := k
		switch {
		case !prevHas:
			c = resolveHeaderRef(c, currComps)
			d.Added = append(d.Added, schemaSummary(path, c.Schema, false, currComps))
		case !currHas:
			p = resolveHeaderRef(p, prevComps)
			d.Removed = append(d.Removed, schemaSummary(path, p.Schema, false, prevComps))
		default:
			p = resolveHeaderRef(p, prevComps)
			c = resolveHeaderRef(c, currComps)
			diffSchema(path, p.Schema, c.Schema, false, false, prevComps, currComps, 0, &d)
		}
	}
	if len(d.Added)+len(d.Removed)+len(d.Changed) == 0 {
		return nil
	}
	return &d
}

// ---- Responses / status codes --------------------------------------------

func splitResponseCodes(resps map[string]rawResponse) (success, errors []string) {
	for code := range resps {
		c, err := strconv.Atoi(code)
		if err != nil {
			continue
		}
		switch {
		case c >= 200 && c < 300:
			success = append(success, code)
		case c >= 400:
			errors = append(errors, code)
		}
	}
	sort.Strings(success)
	sort.Strings(errors)
	return
}

func diffStatusCodes(prev, curr []string) *handoffschema.StatusCodeListDiff {
	a, r := stringSetDiff(prev, curr)
	if len(a) == 0 && len(r) == 0 {
		return nil
	}
	return &handoffschema.StatusCodeListDiff{Added: a, Removed: r}
}

func stringSetDiff(prev, curr []string) (added, removed []string) {
	prevSet := map[string]struct{}{}
	for _, s := range prev {
		prevSet[s] = struct{}{}
	}
	currSet := map[string]struct{}{}
	for _, s := range curr {
		currSet[s] = struct{}{}
	}
	for s := range currSet {
		if _, ok := prevSet[s]; !ok {
			added = append(added, s)
		}
	}
	for s := range prevSet {
		if _, ok := currSet[s]; !ok {
			removed = append(removed, s)
		}
	}
	sort.Strings(added)
	sort.Strings(removed)
	return
}

func diffStringList(prev, curr []string) *handoffschema.StringListDiff {
	a, r := stringSetDiff(prev, curr)
	if len(a) == 0 && len(r) == 0 {
		return nil
	}
	return &handoffschema.StringListDiff{Added: a, Removed: r}
}

// ---- Security helpers -----------------------------------------------------

// flattenSecurity turns the OpenAPI `security` array into a sorted list of
// "scheme:scope1,scope2,..." strings so we can diff with stringSetDiff.
func flattenSecurity(reqs []rawSecReq) []string {
	out := make([]string, 0, len(reqs))
	for _, req := range reqs {
		for scheme, scopes := range req {
			sort.Strings(scopes)
			if len(scopes) == 0 {
				out = append(out, scheme)
			} else {
				out = append(out, scheme+":"+strings.Join(scopes, ","))
			}
		}
	}
	sort.Strings(out)
	return out
}

func flattenServers(servers []rawServer) []string {
	out := make([]string, 0, len(servers))
	for _, s := range servers {
		if s.URL != "" {
			out = append(out, s.URL)
		}
	}
	sort.Strings(out)
	return out
}

// ---- Operation detail builder --------------------------------------------

func buildDetail(prevOp, currOp rawOperation, prevComps, currComps rawComponents) *handoffschema.OperationDetail {
	d := &handoffschema.OperationDetail{}

	d.Parameters = diffParameters(prevOp.Parameters, currOp.Parameters, prevComps, currComps)
	d.RequestBody = diffRequestBody(prevOp.RequestBody, currOp.RequestBody, prevComps, currComps)
	d.Responses = diffSuccessResponses(prevOp.Responses, currOp.Responses, prevComps, currComps)
	_, prevErr := splitResponseCodes(prevOp.Responses)
	_, currErr := splitResponseCodes(currOp.Responses)
	d.ErrorCodes = diffStatusCodes(prevErr, currErr)
	d.Security = diffStringList(flattenSecurity(prevOp.Security), flattenSecurity(currOp.Security))

	if d.Parameters == nil && d.RequestBody == nil && len(d.Responses) == 0 && d.ErrorCodes == nil && d.Security == nil {
		return nil
	}
	return d
}

func diffRequestBody(prev, curr *rawRequestBody, prevComps, currComps rawComponents) *handoffschema.SchemaDiff {
	prevS := bodySchema(prev)
	currS := bodySchema(curr)
	if prevS == nil && currS == nil {
		return nil
	}
	var d handoffschema.SchemaDiff
	diffSchema("", prevS, currS, false, false, prevComps, currComps, 0, &d)
	if len(d.Added)+len(d.Removed)+len(d.Changed) == 0 {
		return nil
	}
	return &d
}

func bodySchema(rb *rawRequestBody) *rawSchema {
	if rb == nil {
		return nil
	}
	return jsonSchemaFromContent(rb.Content)
}

// jsonSchemaFromContent picks one schema out of an OpenAPI `content` map.
// Prefers application/json; falls back to the first content entry by sorted
// key so the choice is deterministic across runs.
func jsonSchemaFromContent(content map[string]rawMediaType) *rawSchema {
	if mt, ok := content["application/json"]; ok {
		return mt.Schema
	}
	keys := make([]string, 0, len(content))
	for k := range content {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if len(keys) > 0 {
		return content[keys[0]].Schema
	}
	return nil
}

func diffSuccessResponses(prev, curr map[string]rawResponse, prevComps, currComps rawComponents) map[string]*handoffschema.ResponseDetail {
	prevCodes, _ := splitResponseCodes(prev)
	currCodes, _ := splitResponseCodes(curr)
	codes := map[string]struct{}{}
	for _, c := range prevCodes {
		codes[c] = struct{}{}
	}
	for _, c := range currCodes {
		codes[c] = struct{}{}
	}
	if len(codes) == 0 {
		return nil
	}
	out := map[string]*handoffschema.ResponseDetail{}
	for code := range codes {
		prevResp := resolveResponseRef(prev[code], prevComps)
		currResp := resolveResponseRef(curr[code], currComps)
		body := diffResponseBody(prevResp, currResp, prevComps, currComps)
		headers := diffHeaders(prevResp.Headers, currResp.Headers, prevComps, currComps)
		if body == nil && headers == nil {
			continue
		}
		out[code] = &handoffschema.ResponseDetail{Body: body, Headers: headers}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func diffResponseBody(prev, curr rawResponse, prevComps, currComps rawComponents) *handoffschema.SchemaDiff {
	prevS := jsonSchemaFromContent(prev.Content)
	currS := jsonSchemaFromContent(curr.Content)
	if prevS == nil && currS == nil {
		return nil
	}
	var d handoffschema.SchemaDiff
	diffSchema("", prevS, currS, false, false, prevComps, currComps, 0, &d)
	if len(d.Added)+len(d.Removed)+len(d.Changed) == 0 {
		return nil
	}
	return &d
}

// ---- Top-level diff -------------------------------------------------------

func diff(previous, current []byte) (*handoffschema.APIDelta, error) {
	prev, err := parseSpec(previous)
	if err != nil {
		return nil, fmt.Errorf("parse previous swagger: %w", err)
	}
	curr, err := parseSpec(current)
	if err != nil {
		return nil, fmt.Errorf("parse current swagger: %w", err)
	}

	out := &handoffschema.APIDelta{Format: "openapi-3"}

	for path, methods := range curr.Paths {
		for method, op := range methods {
			if !isHTTPMethod(method) {
				continue
			}
			m := strings.ToUpper(method)
			opSummary := handoffschema.Operation{
				Method:      m,
				Path:        path,
				OperationID: op.OperationID,
				Summary:     op.Summary,
			}
			prevOp, existed := lookupOp(prev, path, m)
			if !existed {
				opSummary.Detail = buildDetail(rawOperation{}, op, prev.Components, curr.Components)
				out.Added = append(out.Added, opSummary)
				continue
			}
			detail := buildDetail(prevOp, op, prev.Components, curr.Components)
			if prevOp.OperationID != op.OperationID || prevOp.Summary != op.Summary || detail != nil {
				opSummary.Detail = detail
				out.Changed = append(out.Changed, opSummary)
			}
		}
	}
	for path, methods := range prev.Paths {
		for method, op := range methods {
			if !isHTTPMethod(method) {
				continue
			}
			m := strings.ToUpper(method)
			if _, ok := lookupOp(curr, path, m); ok {
				continue
			}
			out.Removed = append(out.Removed, handoffschema.Operation{
				Method:      m,
				Path:        path,
				OperationID: op.OperationID,
				Summary:     op.Summary,
				Detail:      buildDetail(op, rawOperation{}, prev.Components, curr.Components),
			})
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

	out.Servers = diffStringList(flattenServers(prev.Servers), flattenServers(curr.Servers))
	out.Security = diffStringList(flattenSecurity(prev.Security), flattenSecurity(curr.Security))

	if len(out.Added)+len(out.Changed)+len(out.Removed) == 0 && out.Servers == nil && out.Security == nil {
		return nil, nil
	}
	return out, nil
}

func lookupOp(s *rawSpec, path, method string) (rawOperation, bool) {
	if methods, ok := s.Paths[path]; ok {
		for k, v := range methods {
			if strings.ToUpper(k) == method {
				return v, true
			}
		}
	}
	return rawOperation{}, false
}
