package relay_test

import (
	"os"
	"strings"
	"testing"
)

func TestProjectManageUIActionsAreRoleGated(t *testing.T) {
	src, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	js := string(src)
	required := []string{
		`const canManage = role === "owner" || state.me?.is_admin;`,
		"${canManage ? `<button type=\"button\" data-unmap=",
		"${canManage ? `<form class=\"inline-form\" data-form=\"repo\">",
		`renderMemberTable(members, { canRemove: canManage, removeAttr: "data-remove-member", label: "项目成员" })`,
		`${canManage ? memberCandidateForm("member", memberCandidates, ["member", "viewer", "owner"]) : ""}`,
	}
	for _, want := range required {
		if !strings.Contains(js, want) {
			t.Fatalf("project management UI is missing role gate fragment %q", want)
		}
	}
	forbidden := []string{
		`renderMemberTable(members, { canRemove: true, removeAttr: "data-remove-member", label: "项目成员" })`,
		`${memberCandidateForm("member", memberCandidates, ["member", "viewer", "owner"])}`,
	}
	for _, bad := range forbidden {
		if strings.Contains(js, bad) {
			t.Fatalf("project management UI still renders ungated fragment %q", bad)
		}
	}
}

func TestProjectRolePrefersFreshProjectListRole(t *testing.T) {
	src, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	js := string(src)
	start := strings.Index(js, "function projectRole(id) {")
	if start < 0 {
		t.Fatal("could not locate projectRole function body")
	}
	end := strings.Index(js[start:], "\nfunction renderProjects()")
	if end < 0 {
		t.Fatal("could not locate projectRole function body")
	}
	body := js[start : start+end]
	required := []string{
		`const project = (state.projects || []).find((pr) => pr.id === id);`,
		`if (project?.role) return project.role;`,
		`const p = (state.me?.projects || []).find((pr) => pr.id === id);`,
		`return state.me?.is_admin ? "admin" : "viewer";`,
	}
	for _, want := range required {
		if !strings.Contains(body, want) {
			t.Fatalf("projectRole is missing freshness/safe-fallback fragment %q", want)
		}
	}
	if strings.Contains(body, `return state.me?.is_admin ? "admin" : "member";`) {
		t.Fatal("projectRole still falls back to editable-looking member role for unknown projects")
	}
}

func TestOrganizationRolePrefersFreshOrganizationListRole(t *testing.T) {
	src, err := os.ReadFile("ui/app.js")
	if err != nil {
		t.Fatal(err)
	}
	js := string(src)
	start := strings.Index(js, "function organizationRole(id) {")
	if start < 0 {
		t.Fatal("could not locate organizationRole function body")
	}
	end := strings.Index(js[start:], "\nfunction organizationName(id)")
	if end < 0 {
		t.Fatal("could not locate organizationRole function body")
	}
	body := js[start : start+end]
	required := []string{
		`const fresh = (state.organizations || []).find((o) => o.id === id);`,
		`if (fresh?.role) return fresh.role;`,
		`const org = (state.me?.organizations || []).find((o) => o.id === id);`,
	}
	for _, want := range required {
		if !strings.Contains(body, want) {
			t.Fatalf("organizationRole is missing freshness fragment %q", want)
		}
	}
	if strings.Index(body, `state.me?.organizations`) < strings.Index(body, `state.organizations`) {
		t.Fatal("organizationRole checks stale me.organizations before fresh state.organizations")
	}
}
