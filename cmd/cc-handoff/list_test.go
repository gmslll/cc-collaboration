package main

import (
	"strings"
	"testing"
)

func TestListProjectTargetNormalizesProjectFlag(t *testing.T) {
	project, projectMode, err := listProjectTarget("  project-1  ", false)
	if err != nil {
		t.Fatalf("listProjectTarget returned error: %v", err)
	}
	if project != "project-1" || !projectMode {
		t.Fatalf("target = (%q, %v), want project-1 project mode", project, projectMode)
	}
}

func TestListProjectTargetBlankProjectUsesPersonalInbox(t *testing.T) {
	project, projectMode, err := listProjectTarget("   ", false)
	if err != nil {
		t.Fatalf("listProjectTarget returned error: %v", err)
	}
	if project != "" || projectMode {
		t.Fatalf("target = (%q, %v), want personal inbox", project, projectMode)
	}
}

func TestListProjectTargetAllProjectsUsesProjectUnion(t *testing.T) {
	project, projectMode, err := listProjectTarget("", true)
	if err != nil {
		t.Fatalf("listProjectTarget returned error: %v", err)
	}
	if project != "" || !projectMode {
		t.Fatalf("target = (%q, %v), want project union", project, projectMode)
	}
}

func TestListProjectTargetRejectsProjectAndAllProjects(t *testing.T) {
	_, _, err := listProjectTarget(" project-1 ", true)
	if err == nil || !strings.Contains(err.Error(), "mutually exclusive") {
		t.Fatalf("error = %v, want mutually exclusive", err)
	}
}
