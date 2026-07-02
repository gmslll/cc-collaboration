package linear

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestGetTeamIssues exercises the decode path against a local fake GraphQL
// endpoint (no real network / Linear account needed) — verifies the nested
// state/assignee/labels/dueDate shape unmarshals into Issue correctly,
// including the null-assignee and no-labels edge cases.
func TestGetTeamIssues(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "lin_test_token" {
			t.Errorf("Authorization header = %q, want bare token (no Bearer prefix)", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"data": {
				"issues": {
					"nodes": [
						{
							"identifier": "ENG-456",
							"url": "https://linear.app/x/issue/ENG-456",
							"title": "Fix the thing",
							"description": "It's broken.",
							"state": {"name": "In Progress", "type": "started"},
							"priority": 1,
							"assignee": {"email": "dev@company.com"},
							"labels": {"nodes": [{"name": "bug"}, {"name": "urgent"}]},
							"dueDate": "2026-07-10"
						},
						{
							"identifier": "ENG-457",
							"url": "https://linear.app/x/issue/ENG-457",
							"title": "No assignee, no labels, no due date",
							"description": "",
							"state": {"name": "Backlog", "type": "backlog"},
							"priority": 0,
							"assignee": null,
							"labels": {"nodes": []},
							"dueDate": null
						}
					]
				}
			}
		}`))
	}))
	defer srv.Close()

	c := NewClient("lin_test_token")
	c.Endpoint = srv.URL
	issues, err := GetTeamIssues(t.Context(), c, "ENG")
	if err != nil {
		t.Fatalf("GetTeamIssues: %v", err)
	}
	if len(issues) != 2 {
		t.Fatalf("got %d issues, want 2", len(issues))
	}

	got0 := issues[0]
	if got0.Identifier != "ENG-456" || got0.Title != "Fix the thing" || got0.StateType != "started" ||
		got0.Priority != 1 || got0.AssigneeEmail != "dev@company.com" {
		t.Errorf("issue[0] mismatch: %+v", got0)
	}
	if want := []string{"bug", "urgent"}; !equalStrings(got0.Labels, want) {
		t.Errorf("issue[0].Labels = %v, want %v", got0.Labels, want)
	}
	if got0.DueDate == nil || got0.DueDate.Format("2006-01-02") != "2026-07-10" {
		t.Errorf("issue[0].DueDate = %v, want 2026-07-10", got0.DueDate)
	}

	got1 := issues[1]
	if got1.AssigneeEmail != "" {
		t.Errorf("issue[1].AssigneeEmail = %q, want empty (null assignee)", got1.AssigneeEmail)
	}
	if len(got1.Labels) != 0 {
		t.Errorf("issue[1].Labels = %v, want empty", got1.Labels)
	}
	if got1.DueDate != nil {
		t.Errorf("issue[1].DueDate = %v, want nil", got1.DueDate)
	}
}

func equalStrings(a, b []string) bool {
	data, _ := json.Marshal(a)
	want, _ := json.Marshal(b)
	return string(data) == string(want)
}
