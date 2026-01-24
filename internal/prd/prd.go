// Package prd handles PRD (Product Requirements Document) loading and manipulation.
package prd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Complexity represents task complexity level.
type Complexity string

const (
	ComplexityJunior Complexity = "junior"
	ComplexitySenior Complexity = "senior"
	ComplexityAuto   Complexity = "auto"
)

// VerificationType represents the type of verification command.
type VerificationType string

const (
	VerificationPattern     VerificationType = "pattern"
	VerificationUnit        VerificationType = "unit"
	VerificationIntegration VerificationType = "integration"
	VerificationSmoke       VerificationType = "smoke"
)

// Verification represents a verification command for a task.
type Verification struct {
	Type VerificationType `json:"type,omitempty"`
	Cmd  string           `json:"cmd"`
}

// UnmarshalJSON handles both string and object formats for backward compatibility.
func (v *Verification) UnmarshalJSON(data []byte) error {
	// Try string format first (backward compatible)
	var s string
	if err := json.Unmarshal(data, &s); err == nil {
		v.Cmd = s
		v.Type = "" // Type will be inferred
		return nil
	}

	// Try object format
	type verificationAlias Verification
	var va verificationAlias
	if err := json.Unmarshal(data, &va); err != nil {
		return err
	}
	*v = Verification(va)
	return nil
}

// Task represents a single task in a PRD.
type Task struct {
	ID                 string         `json:"id"`
	Title              string         `json:"title"`
	Description        string         `json:"description,omitempty"`
	AcceptanceCriteria []string       `json:"acceptanceCriteria"`
	DependsOn          []string       `json:"dependsOn"`
	Complexity         Complexity     `json:"complexity"`
	Passes             bool           `json:"passes"`
	Verification       []Verification `json:"verification,omitempty"`
	ManualVerification bool           `json:"manualVerification,omitempty"`
}

// IsSenior returns true if the task should be handled by a senior worker.
func (t *Task) IsSenior() bool {
	return t.Complexity == ComplexitySenior
}

// IsJunior returns true if the task should be handled by a junior worker.
func (t *Task) IsJunior() bool {
	return t.Complexity == ComplexityJunior
}

// PRD represents a Product Requirements Document.
type PRD struct {
	FeatureName string `json:"featureName"`
	BranchName  string `json:"branchName"`
	CreatedAt   string `json:"createdAt,omitempty"`
	Description string `json:"description,omitempty"`
	Walkaway    bool   `json:"walkaway,omitempty"`
	Tasks       []Task `json:"tasks"`

	// Internal tracking
	path string
}

// Load loads a PRD from the given file path.
func Load(path string) (*PRD, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading PRD file: %w", err)
	}

	var prd PRD
	if err := json.Unmarshal(data, &prd); err != nil {
		return nil, fmt.Errorf("parsing PRD JSON: %w", err)
	}

	prd.path = path
	return &prd, nil
}

// Save writes the PRD to the given file path.
func (p *PRD) Save(path string) error {
	if path == "" {
		path = p.path
	}
	if path == "" {
		return fmt.Errorf("no path specified for PRD save")
	}

	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling PRD: %w", err)
	}

	// Atomic write: write to temp file then rename
	dir := filepath.Dir(path)
	tmpFile, err := os.CreateTemp(dir, ".prd-*.json")
	if err != nil {
		return fmt.Errorf("creating temp file: %w", err)
	}
	tmpPath := tmpFile.Name()

	if _, err := tmpFile.Write(data); err != nil {
		tmpFile.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("writing temp file: %w", err)
	}
	if err := tmpFile.Close(); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("closing temp file: %w", err)
	}

	if err := os.Rename(tmpPath, path); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("renaming temp file: %w", err)
	}

	p.path = path
	return nil
}

// Path returns the file path the PRD was loaded from.
func (p *PRD) Path() string {
	return p.path
}

// TaskByID returns the task with the given ID, or nil if not found.
func (p *PRD) TaskByID(id string) *Task {
	for i := range p.Tasks {
		if p.Tasks[i].ID == id {
			return &p.Tasks[i]
		}
	}
	return nil
}

// TaskIndex returns the index of the task with the given ID, or -1 if not found.
func (p *PRD) TaskIndex(id string) int {
	for i := range p.Tasks {
		if p.Tasks[i].ID == id {
			return i
		}
	}
	return -1
}

// ReadyTasks returns tasks that are ready to be executed (dependencies met, not passed).
func (p *PRD) ReadyTasks(completed map[string]bool) []*Task {
	var ready []*Task
	for i := range p.Tasks {
		task := &p.Tasks[i]
		if task.Passes {
			continue
		}

		// Check all dependencies are completed
		allDepsMet := true
		for _, dep := range task.DependsOn {
			if !completed[dep] {
				allDepsMet = false
				break
			}
		}

		if allDepsMet {
			ready = append(ready, task)
		}
	}
	return ready
}

// PendingTasks returns all tasks that haven't passed yet.
func (p *PRD) PendingTasks() []*Task {
	var pending []*Task
	for i := range p.Tasks {
		if !p.Tasks[i].Passes {
			pending = append(pending, &p.Tasks[i])
		}
	}
	return pending
}

// CompletedTasks returns all tasks that have passed.
func (p *PRD) CompletedTasks() []*Task {
	var completed []*Task
	for i := range p.Tasks {
		if p.Tasks[i].Passes {
			completed = append(completed, &p.Tasks[i])
		}
	}
	return completed
}

// AllTaskIDs returns all task IDs in the PRD.
func (p *PRD) AllTaskIDs() []string {
	ids := make([]string, len(p.Tasks))
	for i, task := range p.Tasks {
		ids[i] = task.ID
	}
	return ids
}

// Prefix extracts a short prefix from the PRD filename for display.
// e.g., "prd-add-auth.json" -> "add-auth"
func (p *PRD) Prefix() string {
	if p.path == "" {
		return ""
	}
	base := filepath.Base(p.path)
	base = strings.TrimSuffix(base, ".json")
	base = strings.TrimPrefix(base, "prd-")
	return base
}

// FormatTaskID formats a task ID with the PRD prefix.
// e.g., "US-001" -> "add-auth/US-001"
func (p *PRD) FormatTaskID(taskID string) string {
	prefix := p.Prefix()
	if prefix == "" {
		return taskID
	}
	return prefix + "/" + taskID
}

// StatePath returns the path to the state file for this PRD.
func (p *PRD) StatePath() string {
	if p.path == "" {
		return ""
	}
	return strings.TrimSuffix(p.path, ".json") + ".state.json"
}

// DependencyGraph returns a map of task ID -> tasks that depend on it.
func (p *PRD) DependencyGraph() map[string][]string {
	graph := make(map[string][]string)
	for _, task := range p.Tasks {
		for _, dep := range task.DependsOn {
			graph[dep] = append(graph[dep], task.ID)
		}
	}
	return graph
}

// TopologicalOrder returns task IDs in dependency order (tasks appear after their dependencies).
func (p *PRD) TopologicalOrder() ([]string, error) {
	// Build adjacency list and in-degree count
	inDegree := make(map[string]int)
	graph := make(map[string][]string)

	for _, task := range p.Tasks {
		inDegree[task.ID] = len(task.DependsOn)
		for _, dep := range task.DependsOn {
			graph[dep] = append(graph[dep], task.ID)
		}
	}

	// Start with tasks that have no dependencies
	var queue []string
	for _, task := range p.Tasks {
		if inDegree[task.ID] == 0 {
			queue = append(queue, task.ID)
		}
	}

	var order []string
	for len(queue) > 0 {
		// Pop from queue
		id := queue[0]
		queue = queue[1:]
		order = append(order, id)

		// Reduce in-degree of dependents
		for _, dependent := range graph[id] {
			inDegree[dependent]--
			if inDegree[dependent] == 0 {
				queue = append(queue, dependent)
			}
		}
	}

	if len(order) != len(p.Tasks) {
		return nil, fmt.Errorf("circular dependency detected in PRD")
	}

	return order, nil
}

// HasCircularDependency checks if the PRD has circular dependencies.
func (p *PRD) HasCircularDependency() bool {
	_, err := p.TopologicalOrder()
	return err != nil
}

// TotalTasks returns the total number of tasks.
func (p *PRD) TotalTasks() int {
	return len(p.Tasks)
}

// Progress returns (completed, total) task counts.
func (p *PRD) Progress() (int, int) {
	completed := 0
	for _, task := range p.Tasks {
		if task.Passes {
			completed++
		}
	}
	return completed, len(p.Tasks)
}

// IsComplete returns true if all tasks have passed.
func (p *PRD) IsComplete() bool {
	for _, task := range p.Tasks {
		if !task.Passes {
			return false
		}
	}
	return true
}

// MarkTaskComplete marks a task as passed.
func (p *PRD) MarkTaskComplete(taskID string) bool {
	task := p.TaskByID(taskID)
	if task == nil {
		return false
	}
	task.Passes = true
	return true
}
