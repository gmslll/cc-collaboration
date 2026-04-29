// Package mcp implements a minimal Model Context Protocol server that speaks
// newline-delimited JSON-RPC 2.0 over stdio. It supports the subset of methods
// Claude Code needs to register a tools-only server: initialize, tools/list,
// tools/call, ping, and the initialized notification.
package mcp

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
)

const (
	ProtocolVersion = "2025-11-25"
	JSONRPCVersion  = "2.0"

	MethodInitialize = "initialize"
	MethodPing       = "ping"
	MethodToolsList  = "tools/list"
	MethodToolsCall  = "tools/call"

	NotificationInitialized = "notifications/initialized"
	NotificationCancelled   = "notifications/cancelled"

	ContentTypeText = "text"

	codeParseError     = -32700
	codeMethodNotFound = -32601
	codeInvalidParams  = -32602
)

type Request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"` // absent for notifications
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type Response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
}

type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

// Tool is a minimal tools/list entry. The handler is called with the raw
// `arguments` JSON object from a tools/call request and returns one or more
// content items.
type Tool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"inputSchema"`

	Handler func(ctx context.Context, args json.RawMessage) (ToolResult, error) `json:"-"`
}

type ToolResult struct {
	Content []ContentBlock `json:"content"`
	IsError bool           `json:"isError,omitempty"`
}

type ContentBlock struct {
	Type string `json:"type"`           // "text" only for now
	Text string `json:"text,omitempty"`
}

type ServerInfo struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

type Server struct {
	Info  ServerInfo
	Tools []Tool
}

// Run reads JSON-RPC messages from r and writes responses to w. Requests are
// dispatched sequentially: stdio MCP clients send one request at a time and
// wait for the response, and serial dispatch avoids racing in-flight handlers
// against stdin EOF and a closed output pipe.
func (s *Server) Run(ctx context.Context, r io.Reader, w io.Writer) error {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64<<10), 4<<20)

	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)

	send := func(resp Response) {
		if err := enc.Encode(resp); err != nil {
			log.Printf("mcp: write response: %v", err)
		}
	}

	for scanner.Scan() {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			send(Response{
				JSONRPC: JSONRPCVersion,
				Error:   &RPCError{Code: codeParseError, Message: "parse error: " + err.Error()},
			})
			continue
		}
		if len(req.ID) == 0 {
			s.handleNotification(req)
			continue
		}
		send(s.dispatch(ctx, req))
	}
	if err := scanner.Err(); err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	return nil
}

func (s *Server) handleNotification(req Request) {
	switch req.Method {
	case NotificationInitialized, NotificationCancelled:
	default:
		log.Printf("mcp: ignoring unknown notification %q", req.Method)
	}
}

func (s *Server) dispatch(ctx context.Context, req Request) Response {
	resp := Response{JSONRPC: JSONRPCVersion, ID: req.ID}
	switch req.Method {
	case MethodInitialize:
		resp.Result = s.handleInitialize()
	case MethodPing:
		resp.Result = struct{}{}
	case MethodToolsList:
		resp.Result = s.handleToolsList()
	case MethodToolsCall:
		result, rpcErr := s.handleToolsCall(ctx, req.Params)
		if rpcErr != nil {
			resp.Error = rpcErr
		} else {
			resp.Result = result
		}
	default:
		resp.Error = &RPCError{Code: codeMethodNotFound, Message: "method not found: " + req.Method}
	}
	return resp
}

func (s *Server) handleInitialize() any {
	return map[string]any{
		"protocolVersion": ProtocolVersion,
		"capabilities":    map[string]any{"tools": map[string]any{}},
		"serverInfo":      s.Info,
	}
}

func (s *Server) handleToolsList() any {
	return map[string]any{"tools": s.Tools}
}

type toolsCallParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

func (s *Server) handleToolsCall(ctx context.Context, raw json.RawMessage) (ToolResult, *RPCError) {
	var p toolsCallParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return ToolResult{}, &RPCError{Code: codeInvalidParams, Message: "invalid params: " + err.Error()}
	}
	for _, t := range s.Tools {
		if t.Name != p.Name {
			continue
		}
		args := p.Arguments
		if len(args) == 0 {
			args = json.RawMessage(`{}`)
		}
		out, err := t.Handler(ctx, args)
		if err != nil {
			// Tool errors are surfaced as content with isError=true so Claude
			// can read and react, rather than as JSON-RPC errors.
			return ToolResult{
				Content: []ContentBlock{{Type: "text", Text: err.Error()}},
				IsError: true,
			}, nil
		}
		return out, nil
	}
	return ToolResult{}, &RPCError{Code: codeMethodNotFound, Message: fmt.Sprintf("tool not found: %s", p.Name)}
}
