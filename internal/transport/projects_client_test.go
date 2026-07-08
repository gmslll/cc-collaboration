package transport

import (
	"context"
	"net/http"
	"net/http/httptest"
	"slices"
	"testing"
)

func TestResolveTeamRecipientsFiltersReadOnlyRoles(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/projects/p1":
			w.Write([]byte(`{"members":[
				{"identity":"owner@x","role":"owner"},
				{"identity":"dev@x","role":"member"},
				{"identity":"viewer@x","role":"viewer"}
			]}`))
		case "/v1/orgs/o1":
			w.Write([]byte(`{"members":[
				{"identity":"owner@x","role":"owner"},
				{"identity":"admin@x","role":"admin"},
				{"identity":"member@x","role":"member"},
				{"identity":"guest@x","role":"guest"}
			]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	projectRecipients, err := client.ResolveTeamRecipients(context.Background(), "p1", "", "owner@x")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"dev@x"}; !slices.Equal(projectRecipients, want) {
		t.Fatalf("project recipients = %v, want %v", projectRecipients, want)
	}

	orgRecipients, err := client.ResolveTeamRecipients(context.Background(), "", "o1", "owner@x")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"admin@x", "member@x"}; !slices.Equal(orgRecipients, want) {
		t.Fatalf("org recipients = %v, want %v", orgRecipients, want)
	}
}
