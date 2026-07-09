package transport

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/cc-collaboration/pkg/handoffschema"
)

// ErrNotImplemented signals the relay returned 404 for an endpoint the client
// expected. Almost always means the relay binary predates the feature; the
// CLI surfaces "your relay is too old, run `make deploy`".
var ErrNotImplemented = errors.New("relay does not implement this endpoint")

// ErrConflict signals the relay returned 409 — typically retracting a
// handoff that's already been picked up. Callers should print the server
// message verbatim; it explains the recovery path.
var ErrConflict = errors.New("conflict")

// ErrAttachmentNotFound signals FetchAttachment hit a 404 — the handoff
// exists but doesn't carry an attachment with that name. Drift detection
// uses this to scan through sent history skipping older handoffs that
// predate the swagger-snapshot attachment.
var ErrAttachmentNotFound = errors.New("attachment not found")

type Client struct {
	BaseURL string
	Token   string
	HTTP    *http.Client
	stream  *http.Client // lazily created for SSE; no request timeout
}

func New(baseURL, token string) *Client {
	return &Client{
		BaseURL: strings.TrimRight(baseURL, "/"),
		Token:   token,
		HTTP:    &http.Client{Timeout: 30 * time.Second},
	}
}

type SubmitResult struct {
	ID        string    `json:"id"`
	CreatedAt time.Time `json:"created_at"`
}

type CurrentUser struct {
	Identity string `json:"identity"`
	IsAdmin  bool   `json:"is_admin"`
}

func (c *Client) Me(ctx context.Context) (*CurrentUser, error) {
	var out CurrentUser
	if err := c.do(ctx, http.MethodGet, "/v1/me", nil, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// Submit posts a Package and uploads any attachments (keyed by name). On
// upload failure the package is already on the relay; the caller can decide
// to retry attachments later. Returned ID always reflects the relay-assigned id.
func (c *Client) Submit(ctx context.Context, p *handoffschema.Package, attachments map[string][]byte) (*SubmitResult, error) {
	body, err := json.Marshal(p)
	if err != nil {
		return nil, err
	}
	var out SubmitResult
	if err := c.do(ctx, http.MethodPost, "/v1/handoffs", bytes.NewReader(body), &out); err != nil {
		return nil, err
	}
	for name, content := range attachments {
		if err := c.UploadAttachment(ctx, out.ID, name, content); err != nil {
			return &out, fmt.Errorf("upload attachment %s: %w", name, err)
		}
	}
	return &out, nil
}

// UploadAttachment posts raw bytes for a previously-submitted handoff. The
// SHA256 is sent in X-Content-Sha256 so the relay can reject corruption.
func (c *Client) UploadAttachment(ctx context.Context, handoffID, name string, content []byte) error {
	endpoint := c.BaseURL + "/v1/handoffs/" + handoffID + "/attachments/" + url.PathEscape(name)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(content))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	req.Header.Set("Content-Type", "application/octet-stream")
	sum := sha256.Sum256(content)
	req.Header.Set("X-Content-Sha256", hex.EncodeToString(sum[:]))
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
		return fmt.Errorf("relay POST attachment %s: %s: %s", name, resp.Status, strings.TrimSpace(string(b)))
	}
	return nil
}

// FetchAttachment returns the raw bytes for a handoff attachment, verifying
// the relay-supplied SHA256 if present.
func (c *Client) FetchAttachment(ctx context.Context, handoffID, name string) ([]byte, error) {
	endpoint := c.BaseURL + "/v1/handoffs/" + handoffID + "/attachments/" + url.PathEscape(name)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, ErrAttachmentNotFound
	}
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
		return nil, fmt.Errorf("relay GET attachment %s: %s: %s", name, resp.Status, strings.TrimSpace(string(b)))
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if want := resp.Header.Get("X-Content-Sha256"); want != "" {
		got := sha256.Sum256(body)
		if hex.EncodeToString(got[:]) != want {
			return nil, fmt.Errorf("attachment %s sha256 mismatch", name)
		}
	}
	return body, nil
}

func (c *Client) List(ctx context.Context, recipient string) ([]handoffschema.ListItem, error) {
	q := url.Values{}
	if recipient != "" {
		q.Set("recipient", recipient)
	}
	var out struct {
		Items []handoffschema.ListItem `json:"items"`
	}
	path := "/v1/handoffs"
	if encoded := q.Encode(); encoded != "" {
		path += "?" + encoded
	}
	if err := c.do(ctx, http.MethodGet, path, nil, &out); err != nil {
		return nil, err
	}
	return out.Items, nil
}

func (c *Client) Get(ctx context.Context, id string) (*handoffschema.Package, error) {
	var out handoffschema.Package
	if err := c.do(ctx, http.MethodGet, "/v1/handoffs/"+id, nil, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) Ack(ctx context.Context, id string) error {
	return c.do(ctx, http.MethodPost, "/v1/handoffs/"+id+"/ack", nil, nil)
}

func (c *Client) Comment(ctx context.Context, handoffID, body string) (*handoffschema.Comment, error) {
	payload, _ := json.Marshal(map[string]string{"body": body})
	var out handoffschema.Comment
	if err := c.do(ctx, http.MethodPost, "/v1/handoffs/"+handoffID+"/comment", bytes.NewReader(payload), &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// ListInboxComments returns comments addressed to the caller (where they're a
// participant but not the author) with id > since. Limit 0 is interpreted by
// the relay as "max_id only", returning an empty list — used by watch catch-up
// to bootstrap the cursor on first run without replaying historical comments.
func (c *Client) ListInboxComments(ctx context.Context, since int64, limit int) ([]handoffschema.Comment, int64, error) {
	q := "?since=" + strconv.FormatInt(since, 10) + "&limit=" + strconv.Itoa(limit)
	var out struct {
		Comments []handoffschema.Comment `json:"comments"`
		MaxID    int64                   `json:"max_id"`
	}
	if err := c.do(ctx, http.MethodGet, "/v1/comments"+q, nil, &out); err != nil {
		return nil, 0, err
	}
	return out.Comments, out.MaxID, nil
}

// Status returns the status snapshot (state / picked_at / comment summary)
// for a handoff the caller is sender or recipient of. Returns
// ErrNotImplemented when talking to a pre-multi-agent relay binary.
func (c *Client) Status(ctx context.Context, id string) (*handoffschema.Status, error) {
	var out handoffschema.Status
	if err := c.do(ctx, http.MethodGet, "/v1/handoffs/"+id+"/status", nil, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// ListSent returns the caller's most recent sent handoffs (any state),
// newest-first.
func (c *Client) ListSent(ctx context.Context, limit int) ([]handoffschema.ListItem, error) {
	q := "?as=sender"
	if limit > 0 {
		q += "&limit=" + strconv.Itoa(limit)
	}
	var out struct {
		Items []handoffschema.ListItem `json:"items"`
	}
	if err := c.do(ctx, http.MethodGet, "/v1/handoffs"+q, nil, &out); err != nil {
		return nil, err
	}
	return out.Items, nil
}

// ListHistory returns the caller's already-picked receipts, newest-first.
// Mirrors List (pending inbox) but for the history view — shows what the
// caller has already pickup'd, since list_inbox filters those out.
func (c *Client) ListHistory(ctx context.Context, limit int) ([]handoffschema.ListItem, error) {
	q := "?as=history"
	if limit > 0 {
		q += "&limit=" + strconv.Itoa(limit)
	}
	var out struct {
		Items []handoffschema.ListItem `json:"items"`
	}
	if err := c.do(ctx, http.MethodGet, "/v1/handoffs"+q, nil, &out); err != nil {
		return nil, err
	}
	return out.Items, nil
}

// ReassignResult is what the relay returns when /v1/handoffs/{id}/reassign
// succeeds: the id of the newly-created handoff for the new recipient, plus
// the bug_group_id so the caller can mention it in their follow-up comment.
type ReassignResult struct {
	ID             string `json:"id"`
	ReassignedTo   string `json:"reassigned_to"`
	BugGroupID     string `json:"bug_group_id"`
	ReassignedFrom string `json:"reassigned_from"`
}

// Reassign forwards a bug handoff the caller currently owns to a different
// identity. The relay closes the caller's slot on the original handoff and
// creates a fresh bug handoff for `to` sharing the same bug_group_id, so
// comments and reassign chains stay correlated. Returns ErrConflict when the
// target is already an open recipient in the same bug group (loop guard) or
// when the original handoff isn't kind=bug.
func (c *Client) Reassign(ctx context.Context, id, to, reason string) (*ReassignResult, error) {
	payload, _ := json.Marshal(map[string]string{"to": to, "reason": reason})
	var out ReassignResult
	if err := c.do(ctx, http.MethodPost, "/v1/handoffs/"+id+"/reassign", bytes.NewReader(payload), &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// Retract cancels a still-pending handoff the caller sent. reason is
// optional; surfaced in the SSE event the recipient's watch sees. Returns
// ErrConflict if the recipient already picked it up.
func (c *Client) Retract(ctx context.Context, id, reason string) error {
	var body io.Reader
	if reason != "" {
		payload, _ := json.Marshal(map[string]string{"reason": reason})
		body = bytes.NewReader(payload)
	}
	return c.do(ctx, http.MethodPost, "/v1/handoffs/"+id+"/retract", body, nil)
}

// ListOnlineUsers returns the relay's roster of known identities with a
// per-row online flag (true when an SSE subscription is currently live).
// Returns ErrNotImplemented when talking to a relay that predates the
// /v1/users/online endpoint.
func (c *Client) ListOnlineUsers(ctx context.Context) ([]handoffschema.OnlineUser, error) {
	var out struct {
		Users []handoffschema.OnlineUser `json:"users"`
	}
	if err := c.do(ctx, http.MethodGet, "/v1/users/online", nil, &out); err != nil {
		return nil, err
	}
	return out.Users, nil
}

func (c *Client) ListComments(ctx context.Context, handoffID string) ([]handoffschema.Comment, error) {
	var out struct {
		Comments []handoffschema.Comment `json:"comments"`
	}
	if err := c.do(ctx, http.MethodGet, "/v1/handoffs/"+handoffID+"/comments", nil, &out); err != nil {
		return nil, err
	}
	return out.Comments, nil
}

// Alert forwards a log alert to the relay, which fans it out to the target
// recipient's watch as a log.alert event. The relay stamps the sender from the
// bearer token; the caller only sets recipient / project / level / message.
func (c *Client) Alert(ctx context.Context, alert *handoffschema.LogAlert) error {
	body, err := json.Marshal(alert)
	if err != nil {
		return err
	}
	return c.do(ctx, http.MethodPost, "/v1/alerts", bytes.NewReader(body), nil)
}

func (c *Client) do(ctx context.Context, method, path string, body io.Reader, out any) error {
	req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
		msg := strings.TrimSpace(string(b))
		switch resp.StatusCode {
		case http.StatusNotFound:
			// Distinguish "this id doesn't exist" from "this endpoint
			// doesn't exist on this relay" by sniffing the body — the
			// id-not-found path returns the literal "not found" we set
			// in handlers, while unknown-route returns Go's default
			// "404 page not found".
			if strings.Contains(msg, "page not found") {
				return fmt.Errorf("%w: %s %s", ErrNotImplemented, method, path)
			}
		case http.StatusConflict:
			return fmt.Errorf("%w: %s", ErrConflict, msg)
		}
		return fmt.Errorf("relay %s %s: %s: %s", method, path, resp.Status, msg)
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}
