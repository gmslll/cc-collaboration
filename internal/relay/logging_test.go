package relay

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHandoffIDForLogUsesServeMuxPathValue(t *testing.T) {
	var got string
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/handoffs/{id}/ack", func(w http.ResponseWriter, r *http.Request) {
		got = handoffIDForLog(r)
		w.WriteHeader(http.StatusNoContent)
	})

	req := httptest.NewRequest(http.MethodPost, "/v1/handoffs/h%2Fteam%231/ack", nil)
	mux.ServeHTTP(httptest.NewRecorder(), req)

	if got != "h/team#1" {
		t.Fatalf("handoffIDForLog = %q, want full decoded handoff id", got)
	}
}

func TestHandoffIDForLogIgnoresOtherIDRoutes(t *testing.T) {
	var got string
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/projects/{id}", func(w http.ResponseWriter, r *http.Request) {
		got = handoffIDForLog(r)
		w.WriteHeader(http.StatusNoContent)
	})

	req := httptest.NewRequest(http.MethodGet, "/v1/projects/p%2Fteam%231", nil)
	mux.ServeHTTP(httptest.NewRecorder(), req)

	if got != "" {
		t.Fatalf("handoffIDForLog on project route = %q, want empty", got)
	}
}
