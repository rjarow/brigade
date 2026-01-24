// Package module handles the Brigade module system for event notifications.
package module

import (
	"encoding/json"
	"time"
)

// EventType represents the type of event.
type EventType string

const (
	EventServiceStart    EventType = "service_start"
	EventTaskStart       EventType = "task_start"
	EventTaskComplete    EventType = "task_complete"
	EventTaskBlocked     EventType = "task_blocked"
	EventEscalation      EventType = "escalation"
	EventReview          EventType = "review"
	EventVerification    EventType = "verification"
	EventAttention       EventType = "attention"
	EventDecisionNeeded  EventType = "decision_needed"
	EventDecisionReceived EventType = "decision_received"
	EventScopeDecision   EventType = "scope_decision"
	EventServiceComplete EventType = "service_complete"
)

// AllEventTypes returns all available event types.
func AllEventTypes() []EventType {
	return []EventType{
		EventServiceStart,
		EventTaskStart,
		EventTaskComplete,
		EventTaskBlocked,
		EventEscalation,
		EventReview,
		EventVerification,
		EventAttention,
		EventDecisionNeeded,
		EventDecisionReceived,
		EventScopeDecision,
		EventServiceComplete,
	}
}

// Event represents an event sent to modules.
type Event struct {
	Type      EventType              `json:"type"`
	Timestamp string                 `json:"timestamp"`
	PRD       string                 `json:"prd,omitempty"`
	TaskID    string                 `json:"taskId,omitempty"`
	Worker    string                 `json:"worker,omitempty"`
	Data      map[string]interface{} `json:"data,omitempty"`
}

// NewEvent creates a new event with the current timestamp.
func NewEvent(eventType EventType) *Event {
	return &Event{
		Type:      eventType,
		Timestamp: time.Now().Format(time.RFC3339),
		Data:      make(map[string]interface{}),
	}
}

// WithPRD sets the PRD name.
func (e *Event) WithPRD(prd string) *Event {
	e.PRD = prd
	return e
}

// WithTask sets the task ID.
func (e *Event) WithTask(taskID string) *Event {
	e.TaskID = taskID
	return e
}

// WithWorker sets the worker tier.
func (e *Event) WithWorker(worker string) *Event {
	e.Worker = worker
	return e
}

// WithData adds data to the event.
func (e *Event) WithData(key string, value interface{}) *Event {
	e.Data[key] = value
	return e
}

// JSON returns the event as JSON bytes.
func (e *Event) JSON() ([]byte, error) {
	return json.Marshal(e)
}

// JSONString returns the event as a JSON string.
func (e *Event) JSONString() string {
	data, err := e.JSON()
	if err != nil {
		return "{}"
	}
	return string(data)
}

// Module represents a loaded module.
type Module struct {
	// Name is the module name (e.g., "telegram", "cost_tracking")
	Name string

	// Path is the path to the module executable
	Path string

	// Events is the list of events this module handles
	Events []EventType

	// Config holds module-specific configuration
	Config map[string]string

	// Enabled indicates if the module is enabled
	Enabled bool
}

// HandlesEvent returns true if the module handles the given event type.
func (m *Module) HandlesEvent(eventType EventType) bool {
	for _, e := range m.Events {
		if e == eventType {
			return true
		}
	}
	return false
}

// GetConfig returns a configuration value for the module.
func (m *Module) GetConfig(key string) string {
	return m.Config[key]
}

// ServiceStartEvent creates a service_start event.
func ServiceStartEvent(prd string, totalTasks int) *Event {
	return NewEvent(EventServiceStart).
		WithPRD(prd).
		WithData("totalTasks", totalTasks)
}

// TaskStartEvent creates a task_start event.
func TaskStartEvent(prd, taskID, worker string) *Event {
	return NewEvent(EventTaskStart).
		WithPRD(prd).
		WithTask(taskID).
		WithWorker(worker)
}

// TaskCompleteEvent creates a task_complete event.
func TaskCompleteEvent(prd, taskID, worker string, duration time.Duration) *Event {
	return NewEvent(EventTaskComplete).
		WithPRD(prd).
		WithTask(taskID).
		WithWorker(worker).
		WithData("duration", int(duration.Seconds()))
}

// TaskBlockedEvent creates a task_blocked event.
func TaskBlockedEvent(prd, taskID, worker, reason string) *Event {
	return NewEvent(EventTaskBlocked).
		WithPRD(prd).
		WithTask(taskID).
		WithWorker(worker).
		WithData("reason", reason)
}

// EscalationEvent creates an escalation event.
func EscalationEvent(prd, taskID, from, to, reason string) *Event {
	return NewEvent(EventEscalation).
		WithPRD(prd).
		WithTask(taskID).
		WithData("from", from).
		WithData("to", to).
		WithData("reason", reason)
}

// ReviewEvent creates a review event.
func ReviewEvent(prd, taskID, result, reason string) *Event {
	return NewEvent(EventReview).
		WithPRD(prd).
		WithTask(taskID).
		WithData("result", result).
		WithData("reason", reason)
}

// VerificationEvent creates a verification event.
func VerificationEvent(prd, taskID string, passed bool, details string) *Event {
	return NewEvent(EventVerification).
		WithPRD(prd).
		WithTask(taskID).
		WithData("passed", passed).
		WithData("details", details)
}

// AttentionEvent creates an attention event.
func AttentionEvent(prd, taskID, reason string) *Event {
	return NewEvent(EventAttention).
		WithPRD(prd).
		WithTask(taskID).
		WithData("reason", reason)
}

// DecisionNeededEvent creates a decision_needed event.
func DecisionNeededEvent(prd, taskID, decisionID, question string) *Event {
	return NewEvent(EventDecisionNeeded).
		WithPRD(prd).
		WithTask(taskID).
		WithData("decisionId", decisionID).
		WithData("question", question)
}

// DecisionReceivedEvent creates a decision_received event.
func DecisionReceivedEvent(prd, taskID, decisionID, action, reason string) *Event {
	return NewEvent(EventDecisionReceived).
		WithPRD(prd).
		WithTask(taskID).
		WithData("decisionId", decisionID).
		WithData("action", action).
		WithData("reason", reason)
}

// ScopeDecisionEvent creates a scope_decision event.
func ScopeDecisionEvent(prd, taskID, question, decision string) *Event {
	return NewEvent(EventScopeDecision).
		WithPRD(prd).
		WithTask(taskID).
		WithData("question", question).
		WithData("decision", decision)
}

// ServiceCompleteEvent creates a service_complete event.
func ServiceCompleteEvent(prd string, completed, total int, duration time.Duration) *Event {
	return NewEvent(EventServiceComplete).
		WithPRD(prd).
		WithData("completedTasks", completed).
		WithData("totalTasks", total).
		WithData("duration", int(duration.Seconds()))
}
