// Package state manages Brigade execution state persistence.
package state

import (
	"fmt"
	"os"
	"time"
)

// TaskStatus represents the status of a task attempt.
type TaskStatus string

const (
	StatusPending    TaskStatus = "pending"
	StatusInProgress TaskStatus = "in_progress"
	StatusComplete   TaskStatus = "complete"
	StatusBlocked    TaskStatus = "blocked"
	StatusFailed     TaskStatus = "failed"
	StatusSkipped    TaskStatus = "skipped"
	StatusAbsorbed   TaskStatus = "absorbed"
)

// WorkerTier represents which worker tier handled a task.
type WorkerTier string

const (
	TierLine      WorkerTier = "line"
	TierSous      WorkerTier = "sous"
	TierExecutive WorkerTier = "executive"
)

// TaskHistory records an attempt to complete a task.
type TaskHistory struct {
	TaskID    string     `json:"taskId"`
	Worker    WorkerTier `json:"worker"`
	Status    TaskStatus `json:"status"`
	Timestamp string     `json:"timestamp"`
	Duration  int        `json:"duration,omitempty"` // Duration in seconds
	Approach  string     `json:"approach,omitempty"`
	Error     string     `json:"error,omitempty"`
	Category  string     `json:"category,omitempty"` // Error category (syntax/logic/integration/env)
}

// Escalation records when a task was escalated to a higher tier.
type Escalation struct {
	TaskID    string     `json:"taskId"`
	From      WorkerTier `json:"from"`
	To        WorkerTier `json:"to"`
	Reason    string     `json:"reason"`
	Timestamp string     `json:"timestamp"`
}

// Review records an executive review result.
type Review struct {
	TaskID    string `json:"taskId"`
	Result    string `json:"result"` // "pass" or "fail"
	Reason    string `json:"reason,omitempty"`
	Timestamp string `json:"timestamp"`
}

// Absorption records when a task was absorbed by another task.
type Absorption struct {
	TaskID     string `json:"taskId"`
	AbsorbedBy string `json:"absorbedBy"`
	Timestamp  string `json:"timestamp"`
}

// PhaseReview records a periodic phase review result.
type PhaseReview struct {
	CompletedTasks int    `json:"completedTasks"`
	TotalTasks     int    `json:"totalTasks"`
	Status         string `json:"status"` // "pass", "concerns", "fail"
	Content        string `json:"content,omitempty"`
	Timestamp      string `json:"timestamp"`
}

// SessionFailure tracks failures across tasks in a session for cross-task learning.
type SessionFailure struct {
	TaskID    string `json:"taskId"`
	Category  string `json:"category"`
	Error     string `json:"error"`
	Timestamp string `json:"timestamp"`
}

// State represents the execution state for a PRD.
type State struct {
	SessionID     string        `json:"sessionId"`
	StartedAt     string        `json:"startedAt"`
	LastStartTime string        `json:"lastStartTime"`
	CurrentTask   string        `json:"currentTask,omitempty"`
	TaskHistory   []TaskHistory `json:"taskHistory"`
	Escalations   []Escalation  `json:"escalations"`
	Reviews       []Review      `json:"reviews"`
	Absorptions   []Absorption  `json:"absorptions"`
	PhaseReviews  []PhaseReview `json:"phaseReviews,omitempty"`

	// Smart retry tracking
	SessionFailures []SessionFailure `json:"sessionFailures,omitempty"`

	// Walkaway mode tracking
	ConsecutiveSkips int `json:"consecutiveSkips,omitempty"`

	// Internal tracking
	path string
}

// New creates a new State with initialized fields.
func New() *State {
	now := time.Now()
	return &State{
		SessionID:       fmt.Sprintf("%d-%d", now.Unix(), os.Getpid()),
		StartedAt:       now.Format(time.RFC3339),
		LastStartTime:   now.Format(time.RFC3339),
		TaskHistory:     []TaskHistory{},
		Escalations:     []Escalation{},
		Reviews:         []Review{},
		Absorptions:     []Absorption{},
		PhaseReviews:    []PhaseReview{},
		SessionFailures: []SessionFailure{},
	}
}

// UpdateLastStartTime updates the last start timestamp.
func (s *State) UpdateLastStartTime() {
	s.LastStartTime = time.Now().Format(time.RFC3339)
}

// SetCurrentTask sets the current task being worked on.
func (s *State) SetCurrentTask(taskID string) {
	s.CurrentTask = taskID
}

// ClearCurrentTask clears the current task.
func (s *State) ClearCurrentTask() {
	s.CurrentTask = ""
}

// AddTaskHistory adds a task history entry.
func (s *State) AddTaskHistory(entry TaskHistory) {
	if entry.Timestamp == "" {
		entry.Timestamp = time.Now().Format(time.RFC3339)
	}
	s.TaskHistory = append(s.TaskHistory, entry)
}

// AddEscalation records an escalation.
func (s *State) AddEscalation(taskID string, from, to WorkerTier, reason string) {
	s.Escalations = append(s.Escalations, Escalation{
		TaskID:    taskID,
		From:      from,
		To:        to,
		Reason:    reason,
		Timestamp: time.Now().Format(time.RFC3339),
	})
}

// AddReview records a review result.
func (s *State) AddReview(taskID, result, reason string) {
	s.Reviews = append(s.Reviews, Review{
		TaskID:    taskID,
		Result:    result,
		Reason:    reason,
		Timestamp: time.Now().Format(time.RFC3339),
	})
}

// AddAbsorption records a task absorption.
func (s *State) AddAbsorption(taskID, absorbedBy string) {
	s.Absorptions = append(s.Absorptions, Absorption{
		TaskID:     taskID,
		AbsorbedBy: absorbedBy,
		Timestamp:  time.Now().Format(time.RFC3339),
	})
}

// AddPhaseReview records a phase review.
func (s *State) AddPhaseReview(completed, total int, status, content string) {
	s.PhaseReviews = append(s.PhaseReviews, PhaseReview{
		CompletedTasks: completed,
		TotalTasks:     total,
		Status:         status,
		Content:        content,
		Timestamp:      time.Now().Format(time.RFC3339),
	})
}

// AddSessionFailure records a failure for cross-task learning.
func (s *State) AddSessionFailure(taskID, category, errorMsg string, maxFailures int) {
	s.SessionFailures = append(s.SessionFailures, SessionFailure{
		TaskID:    taskID,
		Category:  category,
		Error:     errorMsg,
		Timestamp: time.Now().Format(time.RFC3339),
	})

	// Trim to max size
	if maxFailures > 0 && len(s.SessionFailures) > maxFailures {
		s.SessionFailures = s.SessionFailures[len(s.SessionFailures)-maxFailures:]
	}
}

// CompletedTaskIDs returns a set of completed task IDs.
func (s *State) CompletedTaskIDs() map[string]bool {
	completed := make(map[string]bool)
	for _, h := range s.TaskHistory {
		if h.Status == StatusComplete || h.Status == StatusAbsorbed {
			completed[h.TaskID] = true
		}
	}
	// Also check absorptions
	for _, a := range s.Absorptions {
		completed[a.TaskID] = true
	}
	return completed
}

// AttemptsAtTier returns the number of attempts for a task at a specific tier.
func (s *State) AttemptsAtTier(taskID string, tier WorkerTier) int {
	count := 0
	for _, h := range s.TaskHistory {
		if h.TaskID == taskID && h.Worker == tier {
			count++
		}
	}
	return count
}

// TotalAttempts returns the total number of attempts for a task.
func (s *State) TotalAttempts(taskID string) int {
	count := 0
	for _, h := range s.TaskHistory {
		if h.TaskID == taskID {
			count++
		}
	}
	return count
}

// LastAttempt returns the most recent attempt for a task, or nil if none.
func (s *State) LastAttempt(taskID string) *TaskHistory {
	for i := len(s.TaskHistory) - 1; i >= 0; i-- {
		if s.TaskHistory[i].TaskID == taskID {
			return &s.TaskHistory[i]
		}
	}
	return nil
}

// GetApproachHistory returns previous approaches tried for a task.
func (s *State) GetApproachHistory(taskID string, maxApproaches int) []ApproachEntry {
	var approaches []ApproachEntry
	for _, h := range s.TaskHistory {
		if h.TaskID == taskID && h.Approach != "" {
			approaches = append(approaches, ApproachEntry{
				Worker:   h.Worker,
				Approach: h.Approach,
				Category: h.Category,
			})
		}
	}

	// Return most recent approaches up to max
	if maxApproaches > 0 && len(approaches) > maxApproaches {
		approaches = approaches[len(approaches)-maxApproaches:]
	}

	return approaches
}

// ApproachEntry represents a previous approach attempt.
type ApproachEntry struct {
	Worker   WorkerTier
	Approach string
	Category string // Error category from the attempt
}

// WasEscalated returns true if a task was escalated.
func (s *State) WasEscalated(taskID string) bool {
	for _, e := range s.Escalations {
		if e.TaskID == taskID {
			return true
		}
	}
	return false
}

// WasEscalatedTo returns true if a task was escalated to a specific tier.
func (s *State) WasEscalatedTo(taskID string, tier WorkerTier) bool {
	for _, e := range s.Escalations {
		if e.TaskID == taskID && e.To == tier {
			return true
		}
	}
	return false
}

// CurrentTier returns the current tier for a task based on escalation history.
func (s *State) CurrentTier(taskID string, defaultTier WorkerTier) WorkerTier {
	currentTier := defaultTier
	for _, e := range s.Escalations {
		if e.TaskID == taskID {
			currentTier = e.To
		}
	}
	return currentTier
}

// GetLastReviewFeedback returns the last failed review reason for a task.
func (s *State) GetLastReviewFeedback(taskID string) string {
	for i := len(s.Reviews) - 1; i >= 0; i-- {
		r := s.Reviews[i]
		if r.TaskID == taskID && r.Result == "fail" {
			return r.Reason
		}
	}
	return ""
}

// IncrementSkips increments the consecutive skip counter.
func (s *State) IncrementSkips() int {
	s.ConsecutiveSkips++
	return s.ConsecutiveSkips
}

// ResetSkips resets the consecutive skip counter.
func (s *State) ResetSkips() {
	s.ConsecutiveSkips = 0
}

// TaskCompletedCount returns the number of completed tasks.
func (s *State) TaskCompletedCount() int {
	return len(s.CompletedTaskIDs())
}

// Path returns the file path the state was loaded from.
func (s *State) Path() string {
	return s.path
}

// SetPath sets the file path for the state.
func (s *State) SetPath(path string) {
	s.path = path
}
