// Package linear is a minimal GraphQL client for Linear's API. It only knows
// how to authenticate with a personal API key and post a single query, since
// the only feature that calls Linear directly from cc-handoff is the
// notification poller. All other Linear interactions are delegated to
// whichever Linear MCP server the user has configured in Claude Code.
package linear

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

const DefaultEndpoint = "https://api.linear.app/graphql"

type Client struct {
	Token    string
	Endpoint string
	HTTP     *http.Client
}

func NewClient(token string) *Client {
	return &Client{
		Token:    token,
		Endpoint: DefaultEndpoint,
		HTTP:     &http.Client{Timeout: 30 * time.Second},
	}
}

type graphqlRequest struct {
	Query     string         `json:"query"`
	Variables map[string]any `json:"variables,omitempty"`
}

type graphqlError struct {
	Message string `json:"message"`
}

type graphqlResponse struct {
	Data   json.RawMessage `json:"data"`
	Errors []graphqlError  `json:"errors,omitempty"`
}

// Query posts a single GraphQL query and returns the raw `data` payload, or
// an error if the HTTP call failed or the GraphQL response carried any
// `errors` entry. Linear authenticates personal API keys via a bare
// Authorization header (no "Bearer " prefix).
func (c *Client) Query(ctx context.Context, query string, vars map[string]any) (json.RawMessage, error) {
	body, err := json.Marshal(graphqlRequest{Query: query, Variables: vars})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.Endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", c.Token)

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("linear http: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("linear read body: %w", err)
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("linear http %d: %s", resp.StatusCode, truncate(raw, 500))
	}
	var gr graphqlResponse
	if err := json.Unmarshal(raw, &gr); err != nil {
		return nil, fmt.Errorf("linear decode: %w (body=%s)", err, truncate(raw, 200))
	}
	if len(gr.Errors) > 0 {
		return nil, fmt.Errorf("linear graphql: %s", gr.Errors[0].Message)
	}
	return gr.Data, nil
}

func truncate(b []byte, n int) string {
	if len(b) <= n {
		return string(b)
	}
	return string(b[:n]) + "..."
}
