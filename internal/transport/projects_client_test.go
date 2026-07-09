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
	projectRecipients, err := client.ResolveTeamRecipients(context.Background(), "p1", "", "owner@x", "")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"dev@x"}; !slices.Equal(projectRecipients, want) {
		t.Fatalf("project recipients = %v, want %v", projectRecipients, want)
	}

	orgRecipients, err := client.ResolveTeamRecipients(context.Background(), "", "o1", "owner@x", "")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"admin@x", "member@x"}; !slices.Equal(orgRecipients, want) {
		t.Fatalf("org recipients = %v, want %v", orgRecipients, want)
	}
}

func TestResolveTeamRecipientsIncludesProjectTeamManagers(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/projects/p1":
			w.Write([]byte(`{
				"project":{"id":"p1","org_id":"o1"},
				"members":[
					{"identity":"owner@x","role":"owner"},
					{"identity":"dev@x","role":"member"},
					{"identity":"viewer@x","role":"viewer"}
				]}`))
		case "/v1/orgs/o1":
			w.Write([]byte(`{"members":[
				{"identity":"owner@x","role":"owner"},
				{"identity":"org-admin@x","role":"admin"},
				{"identity":"org-member@x","role":"member"},
				{"identity":"guest@x","role":"guest"}
			]}`))
		case "/v1/users/online":
			w.Write([]byte(`{"users":[
				{"identity":"owner@x","online":false},
				{"identity":"dev@x","online":false},
				{"identity":"viewer@x","online":false},
				{"identity":"org-admin@x","online":false},
				{"identity":"org-member@x","online":false},
				{"identity":"guest@x","online":false}
			]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	recipients, err := client.ResolveTeamRecipients(context.Background(), "p1", "", "owner@x", "")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"dev@x", "org-admin@x"}; !slices.Equal(recipients, want) {
		t.Fatalf("project recipients = %v, want %v", recipients, want)
	}

	recipients, err = client.ResolveTeamRecipients(context.Background(), "p1", "", "owner@x", "org-admin@x")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"org-admin@x"}; !slices.Equal(recipients, want) {
		t.Fatalf("project manager recipient = %v, want %v", recipients, want)
	}

	recipients, err = client.ResolveTeamRecipients(context.Background(), "p1", "", "org-admin@x", "")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"owner@x", "dev@x"}; !slices.Equal(recipients, want) {
		t.Fatalf("project recipients from team manager = %v, want %v", recipients, want)
	}

	if _, err := client.ResolveTeamRecipients(context.Background(), "p1", "", "owner@x", "org-member@x"); err == nil {
		t.Fatal("plain organization member should not receive project-targeted handoffs without project membership")
	}
}

func TestResolveTeamRecipientsAllowsGlobalAdminSender(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/projects/p1":
			w.Write([]byte(`{
				"project":{"id":"p1","org_id":"o1"},
				"members":[
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
		case "/v1/me":
			w.Write([]byte(`{"identity":"sysadmin@x","is_admin":true}`))
		case "/v1/users/online":
			w.Write([]byte(`{"users":[
				{"identity":"owner@x","online":false},
				{"identity":"admin@x","online":false},
				{"identity":"member@x","online":false},
				{"identity":"dev@x","online":false},
				{"identity":"viewer@x","online":false},
				{"identity":"guest@x","online":false}
			]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	projectRecipients, err := client.ResolveTeamRecipients(context.Background(), "p1", "", "sysadmin@x", "")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"dev@x", "owner@x", "admin@x"}; !slices.Equal(projectRecipients, want) {
		t.Fatalf("admin project recipients = %v, want %v", projectRecipients, want)
	}

	projectMember, err := client.ResolveTeamRecipients(context.Background(), "p1", "", "sysadmin@x", "admin@x")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"admin@x"}; !slices.Equal(projectMember, want) {
		t.Fatalf("admin project member recipient = %v, want %v", projectMember, want)
	}

	orgRecipients, err := client.ResolveTeamRecipients(context.Background(), "", "o1", "sysadmin@x", "")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"owner@x", "admin@x", "member@x"}; !slices.Equal(orgRecipients, want) {
		t.Fatalf("admin org recipients = %v, want %v", orgRecipients, want)
	}
}

func TestResolveTeamRecipientsRejectsReadOnlySender(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/projects/p1":
			w.Write([]byte(`{
				"project":{"id":"p1","org_id":"o1"},
				"members":[
					{"identity":"viewer@x","role":"viewer"},
					{"identity":"dev@x","role":"member"}
				]}`))
		case "/v1/orgs/o1":
			w.Write([]byte(`{"members":[
				{"identity":"guest@x","role":"guest"},
				{"identity":"org-member@x","role":"member"}
			]}`))
		case "/v1/users/online":
			w.Write([]byte(`{"users":[
				{"identity":"viewer@x","online":false},
				{"identity":"dev@x","online":false},
				{"identity":"guest@x","online":false},
				{"identity":"org-member@x","online":false}
			]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	if _, err := client.ResolveTeamRecipients(context.Background(), "p1", "", "viewer@x", ""); err == nil {
		t.Fatal("project viewer should not be allowed to team-share")
	}
	if _, err := client.ResolveTeamRecipients(context.Background(), "p1", "", "org-member@x", ""); err == nil {
		t.Fatal("plain organization member should not project-share without project membership")
	}
	if _, err := client.ResolveTeamRecipients(context.Background(), "p1", "", "stranger@x", ""); err == nil {
		t.Fatal("non-member should not project-share")
	}
	if _, err := client.ResolveTeamRecipients(context.Background(), "", "o1", "guest@x", ""); err == nil {
		t.Fatal("organization guest should not be allowed to team-share")
	}
	if _, err := client.ResolveTeamRecipients(context.Background(), "", "o1", "stranger@x", ""); err == nil {
		t.Fatal("non-member should not organization-share")
	}
}

func TestResolveTeamRecipientsCanTargetOneMember(t *testing.T) {
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
				{"identity":"guest@x","role":"guest"}
			]}`))
		case "/v1/users/online":
			w.Write([]byte(`{"users":[
				{"identity":"owner@x","online":false},
				{"identity":"dev@x","online":false},
				{"identity":"viewer@x","online":false},
				{"identity":"admin@x","online":false},
				{"identity":"guest@x","online":false}
			]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	projectRecipients, err := client.ResolveTeamRecipients(context.Background(), "p1", "", "owner@x", "dev@x")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"dev@x"}; !slices.Equal(projectRecipients, want) {
		t.Fatalf("project member recipients = %v, want %v", projectRecipients, want)
	}

	orgRecipients, err := client.ResolveTeamRecipients(context.Background(), "", "o1", "owner@x", "admin@x")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"admin@x"}; !slices.Equal(orgRecipients, want) {
		t.Fatalf("org member recipients = %v, want %v", orgRecipients, want)
	}

	if _, err := client.ResolveTeamRecipients(context.Background(), "p1", "", "owner@x", "viewer@x"); err == nil {
		t.Fatal("project viewer should not receive actionable team handoffs")
	}
	if _, err := client.ResolveTeamRecipients(context.Background(), "", "o1", "owner@x", "guest@x"); err == nil {
		t.Fatal("organization guest should not receive actionable team handoffs")
	}
	if _, err := client.ResolveTeamRecipients(context.Background(), "p1", "", "owner@x", "missing@x"); err == nil {
		t.Fatal("non-member should not receive actionable team handoffs")
	}
}

func TestResolveTeamRecipientsNormalizesTeamIdentityAndRoleFields(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/projects/p1":
			w.Write([]byte(`{
				"project":{"id":"p1","org_id":"o1"},
				"members":[
					{"identity":" owner@x ","role":" OWNER "},
					{"identity":" dev@x ","role":" MEMBER "},
					{"identity":" viewer@x ","role":" VIEWER "}
				]}`))
		case "/v1/orgs/o1":
			w.Write([]byte(`{"members":[
				{"identity":" org-admin@x ","role":" ADMIN "},
				{"identity":" org-member@x ","role":" MEMBER "}
			]}`))
		case "/v1/users/online":
			w.Write([]byte(`{"users":[
				{"identity":" owner@x ","online":false},
				{"identity":" dev@x ","online":false},
				{"identity":" viewer@x ","online":false},
				{"identity":" org-admin@x ","online":false},
				{"identity":" org-member@x ","online":false}
			]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	recipients, err := client.ResolveTeamRecipients(context.Background(), "p1", "", " owner@x ", "")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"dev@x", "org-admin@x"}; !slices.Equal(recipients, want) {
		t.Fatalf("normalized project recipients = %v, want %v", recipients, want)
	}

	recipients, err = client.ResolveTeamRecipients(context.Background(), "p1", "", "owner@x", " dev@x ")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"dev@x"}; !slices.Equal(recipients, want) {
		t.Fatalf("normalized targeted recipient = %v, want %v", recipients, want)
	}

	if _, err := client.ResolveTeamRecipients(context.Background(), "p1", "", "owner@x", " viewer@x "); err == nil {
		t.Fatal("normalized project viewer should still be rejected")
	}
}

func TestListProjectAssigneeIdentitiesIncludesTeamManagers(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/projects/p1":
			w.Write([]byte(`{
				"project":{"id":"p1","org_id":"o1"},
				"members":[
					{"identity":"owner@x","role":"owner"},
					{"identity":"dev@x","role":"member"},
					{"identity":"viewer@x","role":"viewer"},
					{"identity":"org-admin@x","role":"member"}
				]}`))
		case "/v1/orgs/o1":
			w.Write([]byte(`{"members":[
				{"identity":"org-owner@x","role":"owner"},
				{"identity":"org-admin@x","role":"admin"},
				{"identity":"org-member@x","role":"member"},
				{"identity":"guest@x","role":"guest"}
			]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	ids, err := client.ListProjectAssigneeIdentities(context.Background(), "p1")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"owner@x", "dev@x", "viewer@x", "org-admin@x", "org-owner@x"}; !slices.Equal(ids, want) {
		t.Fatalf("project assignee identities = %v, want %v", ids, want)
	}
}

func TestListTeamIdentitiesCanFilterOneMember(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/projects/p1":
			w.Write([]byte(`{
				"project":{"id":"p1","org_id":"o1"},
				"members":[
					{"identity":"owner@x","role":"owner"},
					{"identity":"viewer@x","role":"viewer"}
				]}`))
		case "/v1/orgs/o1":
			w.Write([]byte(`{"members":[
				{"identity":"admin@x","role":"admin"},
				{"identity":"manager@x","role":"owner"},
				{"identity":"member@x","role":"member"},
				{"identity":"guest@x","role":"guest"}
			]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)

	client := New(srv.URL, "tok")
	projectIDs, err := client.ListTeamIdentities(context.Background(), "p1", "", "viewer@x")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"viewer@x"}; !slices.Equal(projectIDs, want) {
		t.Fatalf("project ids = %v, want %v", projectIDs, want)
	}
	projectIDs, err = client.ListTeamIdentities(context.Background(), "p1", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"owner@x", "viewer@x", "admin@x", "manager@x"}; !slices.Equal(projectIDs, want) {
		t.Fatalf("project ids with team managers = %v, want %v", projectIDs, want)
	}
	projectIDs, err = client.ListTeamIdentities(context.Background(), "p1", "", "manager@x")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"manager@x"}; !slices.Equal(projectIDs, want) {
		t.Fatalf("project manager ids = %v, want %v", projectIDs, want)
	}

	orgIDs, err := client.ListTeamIdentities(context.Background(), "", "o1", "")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"admin@x", "manager@x", "member@x", "guest@x"}; !slices.Equal(orgIDs, want) {
		t.Fatalf("org ids = %v, want %v", orgIDs, want)
	}

	if _, err := client.ListTeamIdentities(context.Background(), "p1", "", "missing@x"); err == nil {
		t.Fatal("non-member should not pass team identity filtering")
	}
}
