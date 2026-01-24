package supervisor

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"brigade/internal/module"
)

// EventWriter writes events to a JSONL file.
type EventWriter struct {
	path       string
	prdPrefix  string
	scopeByPRD bool
	mu         sync.Mutex
	file       *os.File
}

// NewEventWriter creates a new event writer.
func NewEventWriter(path string, prdPrefix string, scopeByPRD bool) *EventWriter {
	return &EventWriter{
		path:       path,
		prdPrefix:  prdPrefix,
		scopeByPRD: scopeByPRD,
	}
}

// Path returns the actual file path (scoped if enabled).
func (w *EventWriter) Path() string {
	if w.scopeByPRD && w.prdPrefix != "" {
		dir := filepath.Dir(w.path)
		base := filepath.Base(w.path)
		ext := filepath.Ext(base)
		name := base[:len(base)-len(ext)]
		return filepath.Join(dir, fmt.Sprintf("%s-%s%s", w.prdPrefix, name, ext))
	}
	return w.path
}

// Open opens the event file for writing.
func (w *EventWriter) Open() error {
	if w.path == "" {
		return nil
	}

	w.mu.Lock()
	defer w.mu.Unlock()

	if w.file != nil {
		return nil // Already open
	}

	path := w.Path()

	// Ensure directory exists
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("creating directory: %w", err)
	}

	// Open file for append
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("opening event file: %w", err)
	}

	w.file = f
	return nil
}

// Close closes the event file.
func (w *EventWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()

	if w.file == nil {
		return nil
	}

	err := w.file.Close()
	w.file = nil
	return err
}

// Write writes an event to the file.
func (w *EventWriter) Write(event *module.Event) error {
	if w.path == "" {
		return nil
	}

	w.mu.Lock()
	defer w.mu.Unlock()

	// Auto-open if needed
	if w.file == nil {
		if err := w.openLocked(); err != nil {
			return err
		}
	}

	// Marshal event
	data, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("marshaling event: %w", err)
	}

	// Write with newline
	if _, err := w.file.Write(append(data, '\n')); err != nil {
		return fmt.Errorf("writing event: %w", err)
	}

	// Sync to disk
	return w.file.Sync()
}

// openLocked opens the file (assumes mutex is held).
func (w *EventWriter) openLocked() error {
	path := w.Path()

	// Ensure directory exists
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("creating directory: %w", err)
	}

	// Open file for append
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("opening event file: %w", err)
	}

	w.file = f
	return nil
}

// WriteServiceStart writes a service_start event.
func (w *EventWriter) WriteServiceStart(prd string, totalTasks int) error {
	return w.Write(module.ServiceStartEvent(prd, totalTasks))
}

// WriteTaskStart writes a task_start event.
func (w *EventWriter) WriteTaskStart(prd, taskID, worker string) error {
	return w.Write(module.TaskStartEvent(prd, taskID, worker))
}

// WriteTaskComplete writes a task_complete event.
func (w *EventWriter) WriteTaskComplete(prd, taskID, worker string, duration time.Duration) error {
	return w.Write(module.TaskCompleteEvent(prd, taskID, worker, duration))
}

// WriteTaskBlocked writes a task_blocked event.
func (w *EventWriter) WriteTaskBlocked(prd, taskID, worker, reason string) error {
	return w.Write(module.TaskBlockedEvent(prd, taskID, worker, reason))
}

// WriteEscalation writes an escalation event.
func (w *EventWriter) WriteEscalation(prd, taskID, from, to, reason string) error {
	return w.Write(module.EscalationEvent(prd, taskID, from, to, reason))
}

// WriteReview writes a review event.
func (w *EventWriter) WriteReview(prd, taskID, result, reason string) error {
	return w.Write(module.ReviewEvent(prd, taskID, result, reason))
}

// WriteVerification writes a verification event.
func (w *EventWriter) WriteVerification(prd, taskID string, passed bool, details string) error {
	return w.Write(module.VerificationEvent(prd, taskID, passed, details))
}

// WriteAttention writes an attention event.
func (w *EventWriter) WriteAttention(prd, taskID, reason string) error {
	return w.Write(module.AttentionEvent(prd, taskID, reason))
}

// WriteDecisionNeeded writes a decision_needed event.
func (w *EventWriter) WriteDecisionNeeded(prd, taskID, decisionID, question string) error {
	return w.Write(module.DecisionNeededEvent(prd, taskID, decisionID, question))
}

// WriteDecisionReceived writes a decision_received event.
func (w *EventWriter) WriteDecisionReceived(prd, taskID, decisionID, action, reason string) error {
	return w.Write(module.DecisionReceivedEvent(prd, taskID, decisionID, action, reason))
}

// WriteScopeDecision writes a scope_decision event.
func (w *EventWriter) WriteScopeDecision(prd, taskID, question, decision string) error {
	return w.Write(module.ScopeDecisionEvent(prd, taskID, question, decision))
}

// WriteServiceComplete writes a service_complete event.
func (w *EventWriter) WriteServiceComplete(prd string, completed, total int, duration time.Duration) error {
	return w.Write(module.ServiceCompleteEvent(prd, completed, total, duration))
}

// Clear removes the event file.
func (w *EventWriter) Clear() error {
	w.Close()
	path := w.Path()
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// Enabled returns true if the event writer is enabled.
func (w *EventWriter) Enabled() bool {
	return w.path != ""
}
