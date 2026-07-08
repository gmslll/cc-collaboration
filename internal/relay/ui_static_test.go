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
