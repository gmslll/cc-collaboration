package transport

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/cc-collaboration/pkg/handoffschema"
)

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
	url := c.BaseURL + "/v1/handoffs/" + handoffID + "/attachments/" + name
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(content))
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
	url := c.BaseURL + "/v1/handoffs/" + handoffID + "/attachments/" + name
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
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
	q := ""
	if recipient != "" {
		q = "?recipient=" + recipient
	}
	var out struct {
		Items []handoffschema.ListItem `json:"items"`
	}
	if err := c.do(ctx, http.MethodGet, "/v1/handoffs"+q, nil, &out); err != nil {
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

func (c *Client) ListComments(ctx context.Context, handoffID string) ([]handoffschema.Comment, error) {
	var out struct {
		Comments []handoffschema.Comment `json:"comments"`
	}
	if err := c.do(ctx, http.MethodGet, "/v1/handoffs/"+handoffID+"/comments", nil, &out); err != nil {
		return nil, err
	}
	return out.Comments, nil
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
		return fmt.Errorf("relay %s %s: %s: %s", method, path, resp.Status, strings.TrimSpace(string(b)))
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}
