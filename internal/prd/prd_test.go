package prd

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoad(t *testing.T) {
	// Create a temp PRD file
	tmpDir := t.TempDir()
	prdPath := filepath.Join(tmpDir, "test-prd.json")

	prdJSON := `{
		"featureName": "Test Feature",
		"branchName": "feature/test",
		"tasks": [
			{
				"id": "US-001",
				"title": "Test Task",
				"acceptanceCriteria": ["Criterion 1"],
				"dependsOn": [],
				"complexity": "junior",
				"passes": false
			}
		]
	}`

	if err := os.WriteFile(prdPath, []byte(prdJSON), 0644); err != nil {
		t.Fatalf("failed to write test PRD: %v", err)
	}

	prd, err := Load(prdPath)
	if err != nil {
		t.Fatalf("Load failed: %v", err)
	}

	if prd.FeatureName != "Test Feature" {
		t.Errorf("expected feature name 'Test Feature', got '%s'", prd.FeatureName)
	}

	if len(prd.Tasks) != 1 {
		t.Errorf("expected 1 task, got %d", len(prd.Tasks))
	}

	if prd.Tasks[0].ID != "US-001" {
		t.Errorf("expected task ID 'US-001', got '%s'", prd.Tasks[0].ID)
	}
}

func TestReadyTasks(t *testing.T) {
	prd := &PRD{
		Tasks: []Task{
			{ID: "US-001", DependsOn: []string{}, Passes: false},
			{ID: "US-002", DependsOn: []string{"US-001"}, Passes: false},
			{ID: "US-003", DependsOn: []string{}, Passes: false},
		},
	}

	// No tasks completed - US-001 and US-003 are ready (no deps)
	ready := prd.ReadyTasks(map[string]bool{})
	if len(ready) != 2 {
		t.Errorf("expected 2 ready tasks, got %d", len(ready))
	}

	// Mark US-001 as passed in the PRD
	prd.Tasks[0].Passes = true

	// US-001 completed - US-002 and US-003 now ready
	ready = prd.ReadyTasks(map[string]bool{"US-001": true})
	if len(ready) != 2 { // US-002 and US-003 now ready
		t.Errorf("expected 2 ready tasks after US-001 complete, got %d", len(ready))
	}
}

func TestTopologicalOrder(t *testing.T) {
	prd := &PRD{
		Tasks: []Task{
			{ID: "US-001", DependsOn: []string{}},
			{ID: "US-002", DependsOn: []string{"US-001"}},
			{ID: "US-003", DependsOn: []string{"US-001", "US-002"}},
		},
	}

	order, err := prd.TopologicalOrder()
	if err != nil {
		t.Fatalf("TopologicalOrder failed: %v", err)
	}

	if len(order) != 3 {
		t.Errorf("expected 3 tasks in order, got %d", len(order))
	}

	// US-001 must come before US-002
	idx001, idx002, idx003 := -1, -1, -1
	for i, id := range order {
		switch id {
		case "US-001":
			idx001 = i
		case "US-002":
			idx002 = i
		case "US-003":
			idx003 = i
		}
	}

	if idx001 > idx002 {
		t.Errorf("US-001 should come before US-002")
	}
	if idx002 > idx003 {
		t.Errorf("US-002 should come before US-003")
	}
}

func TestCircularDependency(t *testing.T) {
	prd := &PRD{
		Tasks: []Task{
			{ID: "US-001", DependsOn: []string{"US-002"}},
			{ID: "US-002", DependsOn: []string{"US-001"}},
		},
	}

	if !prd.HasCircularDependency() {
		t.Error("expected circular dependency to be detected")
	}
}

func TestPrefix(t *testing.T) {
	tests := []struct {
		path     string
		expected string
	}{
		{"brigade/tasks/prd-add-auth.json", "add-auth"},
		{"prd-feature-name.json", "feature-name"},
		{"simple.json", "simple"},
	}

	for _, tt := range tests {
		prd := &PRD{path: tt.path}
		got := prd.Prefix()
		if got != tt.expected {
			t.Errorf("Prefix(%s) = %s, want %s", tt.path, got, tt.expected)
		}
	}
}

func TestValidateQuick(t *testing.T) {
	// Valid PRD
	prd := &PRD{
		FeatureName: "Test",
		BranchName:  "feature/test",
		Tasks: []Task{
			{
				ID:                 "US-001",
				Title:              "Test Task",
				AcceptanceCriteria: []string{"Criterion"},
				Complexity:         ComplexityJunior,
			},
		},
	}

	result := prd.ValidateQuick()
	if !result.IsValid() {
		t.Errorf("expected valid PRD, got errors: %v", result.Errors)
	}

	// Invalid PRD - missing feature name
	prd.FeatureName = ""
	result = prd.ValidateQuick()
	if result.IsValid() {
		t.Error("expected invalid PRD due to missing feature name")
	}
}

func TestVerificationUnmarshal(t *testing.T) {
	// Test string format
	prdJSON := `{
		"featureName": "Test",
		"branchName": "test",
		"tasks": [{
			"id": "US-001",
			"title": "Test",
			"acceptanceCriteria": ["Criterion"],
			"dependsOn": [],
			"complexity": "junior",
			"passes": false,
			"verification": ["grep test file.go"]
		}]
	}`

	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "test.json")
	os.WriteFile(path, []byte(prdJSON), 0644)

	prd, err := Load(path)
	if err != nil {
		t.Fatalf("Load failed: %v", err)
	}

	if len(prd.Tasks[0].Verification) != 1 {
		t.Errorf("expected 1 verification, got %d", len(prd.Tasks[0].Verification))
	}

	if prd.Tasks[0].Verification[0].Cmd != "grep test file.go" {
		t.Errorf("unexpected verification cmd: %s", prd.Tasks[0].Verification[0].Cmd)
	}
}
