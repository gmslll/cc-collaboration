package transport

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type SSEEvent struct {
	ID    uint64
	Type  string
	Data  []byte
	Retry time.Duration
}

// Subscribe streams events from /v1/events. It auto-reconnects with the last
// observed event id, capped at maxBackoff between retries. The callback is
// invoked synchronously per event; return an error to stop the stream.
//
// The function returns when ctx is cancelled or the callback returns an error.
func (c *Client) Subscribe(ctx context.Context, recipient string, onEvent func(SSEEvent) error) error {
	const (
		minBackoff = 500 * time.Millisecond
		maxBackoff = 30 * time.Second
	)
	stream := c.streamingClient()
	backoff := minBackoff
	var lastID uint64

	for {
		started := time.Now()
		err := c.subscribeOnce(ctx, stream, recipient, &lastID, onEvent)
		if err == nil || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return nil
		}
		var stop stopErr
		if errors.As(err, &stop) {
			return stop.cause
		}
		// If the connection was stable long enough that this isn't a
		// reconnect storm, reset backoff so the next retry is snappy.
		if time.Since(started) > 30*time.Second {
			backoff = minBackoff
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(backoff):
		}
		if backoff < maxBackoff {
			backoff *= 2
			if backoff > maxBackoff {
				backoff = maxBackoff
			}
		}
	}
}

type stopErr struct{ cause error }

func (e stopErr) Error() string { return e.cause.Error() }
func (e stopErr) Unwrap() error { return e.cause }

// streamingClient returns an http.Client suitable for SSE: no request timeout
// (the connection is meant to stay open for hours). Stored on the Client so
// reconnects don't reallocate.
func (c *Client) streamingClient() *http.Client {
	if c.stream != nil {
		return c.stream
	}
	c.stream = &http.Client{Timeout: 0}
	return c.stream
}

func (c *Client) subscribeOnce(ctx context.Context, stream *http.Client, recipient string, lastID *uint64, onEvent func(SSEEvent) error) error {
	url := c.BaseURL + "/v1/events?recipient=" + recipient
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	req.Header.Set("Accept", "text/event-stream")
	if *lastID > 0 {
		req.Header.Set("Last-Event-Id", strconv.FormatUint(*lastID, 10))
	}

	resp, err := stream.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
		return fmt.Errorf("sse status %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64<<10), 4<<20)

	var ev SSEEvent
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			if ev.Type != "" || len(ev.Data) > 0 {
				if ev.ID > 0 {
					*lastID = ev.ID
				}
				if err := onEvent(ev); err != nil {
					return stopErr{cause: err}
				}
			}
			ev = SSEEvent{}
			continue
		}
		if strings.HasPrefix(line, ":") {
			continue
		}
		field, value, found := strings.Cut(line, ":")
		if !found {
			continue
		}
		value = strings.TrimPrefix(value, " ")
		switch field {
		case "id":
			if n, err := strconv.ParseUint(value, 10, 64); err == nil {
				ev.ID = n
			}
		case "event":
			ev.Type = value
		case "data":
			if len(ev.Data) > 0 {
				ev.Data = append(ev.Data, '\n')
			}
			ev.Data = append(ev.Data, value...)
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	return io.EOF
}
