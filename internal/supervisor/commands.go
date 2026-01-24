package supervisor

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Action represents a decision action.
type Action string

const (
	ActionRetry Action = "retry"
	ActionSkip  Action = "skip"
	ActionAbort Action = "abort"
	ActionPause Action = "pause"
)

// Command represents a command from a supervisor.
type Command struct {
	Decision string `json:"decision"` // Decision ID this responds to
	Action   Action `json:"action"`   // retry, skip, abort, pause
	Reason   string `json:"reason,omitempty"`
	Guidance string `json:"guidance,omitempty"` // Optional guidance for retry
}

// CommandReader reads commands from a supervisor.
type CommandReader struct {
	path         string
	prdPrefix    string
	scopeByPRD   bool
	pollInterval time.Duration
	timeout      time.Duration
}

// NewCommandReader creates a new command reader.
func NewCommandReader(path string, prdPrefix string, scopeByPRD bool, pollInterval, timeout time.Duration) *CommandReader {
	return &CommandReader{
		path:         path,
		prdPrefix:    prdPrefix,
		scopeByPRD:   scopeByPRD,
		pollInterval: pollInterval,
		timeout:      timeout,
	}
}

// Path returns the actual file path (scoped if enabled).
func (r *CommandReader) Path() string {
	if r.scopeByPRD && r.prdPrefix != "" {
		dir := filepath.Dir(r.path)
		base := filepath.Base(r.path)
		ext := filepath.Ext(base)
		name := base[:len(base)-len(ext)]
		return filepath.Join(dir, fmt.Sprintf("%s-%s%s", r.prdPrefix, name, ext))
	}
	return r.path
}

// Read reads and removes a command from the file.
func (r *CommandReader) Read() (*Command, error) {
	path := r.Path()

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	// Remove the file immediately after reading
	os.Remove(path)

	if len(data) == 0 {
		return nil, nil
	}

	var cmd Command
	if err := json.Unmarshal(data, &cmd); err != nil {
		return nil, fmt.Errorf("parsing command: %w", err)
	}

	return &cmd, nil
}

// WaitForCommand polls for a command with the specified decision ID.
func (r *CommandReader) WaitForCommand(ctx context.Context, decisionID string) (*Command, error) {
	if r.path == "" {
		return nil, fmt.Errorf("no command file configured")
	}

	// Apply timeout
	var cancel context.CancelFunc
	if r.timeout > 0 {
		ctx, cancel = context.WithTimeout(ctx, r.timeout)
		defer cancel()
	}

	ticker := time.NewTicker(r.pollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-ticker.C:
			cmd, err := r.Read()
			if err != nil {
				return nil, err
			}
			if cmd == nil {
				continue
			}

			// Check if this is the command we're waiting for
			if cmd.Decision == decisionID {
				return cmd, nil
			}

			// Wrong decision ID - put it back (this is a race condition but acceptable)
			r.writeCommand(cmd)
		}
	}
}

// writeCommand writes a command back to the file.
func (r *CommandReader) writeCommand(cmd *Command) error {
	path := r.Path()

	// Ensure directory exists
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}

	data, err := json.Marshal(cmd)
	if err != nil {
		return err
	}

	return os.WriteFile(path, data, 0644)
}

// Clear removes any pending command file.
func (r *CommandReader) Clear() error {
	path := r.Path()
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// Enabled returns true if the command reader is enabled.
func (r *CommandReader) Enabled() bool {
	return r.path != ""
}

// HasCommand returns true if a command is waiting.
func (r *CommandReader) HasCommand() bool {
	path := r.Path()
	_, err := os.Stat(path)
	return err == nil
}

// DecisionRequest represents a request for a decision.
type DecisionRequest struct {
	ID       string `json:"id"`
	TaskID   string `json:"taskId"`
	Question string `json:"question"`
	Options  []string `json:"options"`
}

// GenerateDecisionID generates a unique decision ID.
func GenerateDecisionID() string {
	return fmt.Sprintf("d-%d", time.Now().UnixNano())
}

// Supervisor provides a high-level interface for supervisor integration.
type Supervisor struct {
	status   *StatusWriter
	events   *EventWriter
	commands *CommandReader
}

// NewSupervisor creates a new supervisor integration.
func NewSupervisor(statusPath, eventsPath, cmdPath, prdPrefix string, scopeByPRD bool, pollInterval, cmdTimeout time.Duration) *Supervisor {
	return &Supervisor{
		status:   NewStatusWriter(statusPath, prdPrefix, scopeByPRD),
		events:   NewEventWriter(eventsPath, prdPrefix, scopeByPRD),
		commands: NewCommandReader(cmdPath, prdPrefix, scopeByPRD, pollInterval, cmdTimeout),
	}
}

// Status returns the status writer.
func (s *Supervisor) Status() *StatusWriter {
	return s.status
}

// Events returns the event writer.
func (s *Supervisor) Events() *EventWriter {
	return s.events
}

// Commands returns the command reader.
func (s *Supervisor) Commands() *CommandReader {
	return s.commands
}

// UpdateStatus writes a status update.
func (s *Supervisor) UpdateStatus(done, total int, currentTask, worker string, taskStartTime time.Time, attention bool) error {
	return s.status.WriteProgress(done, total, currentTask, worker, taskStartTime, attention)
}

// Cleanup closes files and removes temporary state.
func (s *Supervisor) Cleanup() {
	s.events.Close()
}

// Enabled returns true if any supervisor integration is enabled.
func (s *Supervisor) Enabled() bool {
	return s.status.Enabled() || s.events.Enabled() || s.commands.Enabled()
}

// RequestDecision requests a decision from the supervisor.
func (s *Supervisor) RequestDecision(ctx context.Context, taskID, question string, options []string) (*Command, error) {
	if !s.commands.Enabled() {
		return nil, fmt.Errorf("supervisor commands not configured")
	}

	decisionID := GenerateDecisionID()

	// Write decision_needed event
	if s.events.Enabled() {
		s.events.WriteDecisionNeeded("", taskID, decisionID, question)
	}

	// Wait for response
	cmd, err := s.commands.WaitForCommand(ctx, decisionID)
	if err != nil {
		return nil, err
	}

	// Write decision_received event
	if s.events.Enabled() && cmd != nil {
		s.events.WriteDecisionReceived("", taskID, decisionID, string(cmd.Action), cmd.Reason)
	}

	return cmd, nil
}
