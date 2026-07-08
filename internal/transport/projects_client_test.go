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
				{"identity":"viewer@x","role":"viewer"},
				{"identity":"disabled@x","role":"member"}
			]}`))
		case "/v1/orgs/o1":
			w.Write([]byte(`{"members":[
				{"identity":"owner@x","role":"owner"},
				{"identity":"admin@x","role":"admin"},
				{"identity":"member@x","role":"member"},
				{"identity":"guest@x","role":"guest"}
			]}`))
		case "/v1/users/online":
			w.Write([]byte(`{"users":[
				{"identity":"owner@x","online":false},
				{"identity":"dev@x","online":false},
				{"identity":"viewer@x","online":false},
				{"identity":"admin@x","online":false},
				{"identity":"member@x","online":false},
				{"identity":"guest@x","online":false}
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

func TestResolveTeamRecipientsRejectsReadOnlySender(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/projects/p1":
			w.Write([]byte(`{"members":[
				{"identity":"viewer@x","role":"viewer"},
				{"identity":"dev@x","role":"member"}
			]}`))
		case "/v1/orgs/o1":
			w.Write([]byte(`{"members":[
				{"identity":"guest@x","role":"guest"},
				{"identity":"member@x","role":"member"}
			]}`))
		case "/v1/users/online":
			w.Write([]byte(`{"users":[
				{"identity":"viewer@x","online":false},
				{"identity":"dev@x","online":false},
				{"identity":"guest@x","online":false},
				{"identity":"member@x","online":false}
			]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	if _, err := client.ResolveTeamRecipients(context.Background(), "p1", "", "viewer@x"); err == nil {
		t.Fatal("project viewer should not be allowed to team-share")
	}
	if _, err := client.ResolveTeamRecipients(context.Background(), "", "o1", "guest@x"); err == nil {
		t.Fatal("organization guest should not be allowed to team-share")
	}
}
