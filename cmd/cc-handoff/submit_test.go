package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/cc-collaboration/internal/config"
	"github.com/cc-collaboration/internal/transport"
)

func TestResolveSubmitRecipientsNormalizesDirectTarget(t *testing.T) {
	recipients, err := resolveSubmitRecipients(
		context.Background(),
		nil,
		" sender@x ",
		" receiver@x ",
		"   ",
		"",
		"   ",
	)
	if err != nil {
		t.Fatalf("resolveSubmitRecipients returned error: %v", err)
	}
	if len(recipients) != 1 || recipients[0] != "receiver@x" {
		t.Fatalf("recipients = %#v, want receiver@x", recipients)
	}
}

func TestResolveSubmitRecipientsMemberStillRequiresTeamTarget(t *testing.T) {
	_, err := resolveSubmitRecipients(
		context.Background(),
		nil,
		"sender@x",
		"receiver@x",
		"",
		"",
		" member@x ",
	)
	if err == nil || !strings.Contains(err.Error(), "--member requires") {
		t.Fatalf("error = %v, want --member requires", err)
	}
}

func TestResolveSubmitRecipientsRejectsSelfAfterTrimming(t *testing.T) {
	_, err := resolveSubmitRecipients(
		context.Background(),
		nil,
		" sender@x ",
		"sender@x",
		"",
		"",
		"",
	)
	if err == nil || !strings.Contains(err.Error(), "cannot send a handoff to yourself") {
		t.Fatalf("error = %v, want self-send rejection", err)
	}
}

func TestInferDefaultProjectIDPrefersWorkspaceBinding(t *testing.T) {
	got, ok, err := inferDefaultProjectID(
		context.Background(),
		nil,
		&config.Resolved{WorkspaceProjectID: " relay-project ", RepoName: "repo"},
	)
	if err != nil {
		t.Fatal(err)
	}
	if !ok || got != "relay-project" {
		t.Fatalf("project id = %q ok=%v, want relay-project true", got, ok)
	}
}

func TestInferDefaultProjectIDFallsBackToRepoMapping(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/projects":
			w.Write([]byte(`{"projects":[{"id":"p1"}]}`))
		case "/v1/projects/p1":
			w.Write([]byte(`{"project":{"id":"p1"},"repos":["repo"]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)

	got, ok, err := inferDefaultProjectID(
		context.Background(),
		transport.New(srv.URL, "tok"),
		&config.Resolved{RepoName: "repo"},
	)
	if err != nil {
		t.Fatal(err)
	}
	if !ok || got != "p1" {
		t.Fatalf("project id = %q ok=%v, want p1 true", got, ok)
	}
}
