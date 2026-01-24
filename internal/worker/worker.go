// Package worker handles execution of tasks by AI workers.
package worker

import (
	"context"
	"time"

	"brigade/internal/state"
)

// Promise represents the result signal from a worker.
type Promise string

const (
	PromiseComplete    Promise = "COMPLETE"
	PromiseBlocked     Promise = "BLOCKED"
	PromiseAlreadyDone Promise = "ALREADY_DONE"
	PromiseAbsorbedBy  Promise = "ABSORBED_BY"
	PromiseNeedsIteration Promise = ""  // No explicit promise, needs another iteration
)

// Result holds the output from a worker execution.
type Result struct {
	// Output is the full output from the worker
	Output string

	// Promise is the signal extracted from output
	Promise Promise

	// AbsorbedBy is set when Promise is PromiseAbsorbedBy
	AbsorbedBy string

	// Learnings extracted from <learning> tags
	Learnings []string

	// Backlog items extracted from <backlog> tags
	Backlog []string

	// Approach extracted from <approach> tag
	Approach string

	// ScopeQuestion extracted from <scope-question> tag
	ScopeQuestion string

	// ExitCode from the process
	ExitCode int

	// Duration of execution
	Duration time.Duration

	// Error if execution failed
	Error error

	// Timeout indicates the worker was killed due to timeout
	Timeout bool

	// Crashed indicates unexpected process termination
	Crashed bool
}

// IsComplete returns true if the worker signaled completion.
func (r *Result) IsComplete() bool {
	return r.Promise == PromiseComplete
}

// IsBlocked returns true if the worker signaled it's blocked.
func (r *Result) IsBlocked() bool {
	return r.Promise == PromiseBlocked
}

// IsAbsorbed returns true if the work was absorbed by another task.
func (r *Result) IsAbsorbed() bool {
	return r.Promise == PromiseAbsorbedBy || r.Promise == PromiseAlreadyDone
}

// NeedsIteration returns true if another iteration is needed.
func (r *Result) NeedsIteration() bool {
	return r.Promise == PromiseNeedsIteration && r.Error == nil && !r.Timeout && !r.Crashed
}

// Success returns true if the result represents successful completion.
func (r *Result) Success() bool {
	return r.Error == nil && !r.Timeout && !r.Crashed
}

// Worker is the interface for AI workers.
type Worker interface {
	// Execute runs the worker with the given prompt
	Execute(ctx context.Context, prompt string) (*Result, error)

	// Name returns the worker name for logging
	Name() string

	// Tier returns the worker's tier
	Tier() state.WorkerTier
}

// Config holds worker configuration.
type Config struct {
	// Command is the base command to run (e.g., "claude", "opencode run")
	Command string

	// Args are additional arguments
	Args []string

	// Tier is the worker's tier level
	Tier state.WorkerTier

	// Timeout is the maximum execution time
	Timeout time.Duration

	// WorkingDir is the working directory for execution
	WorkingDir string

	// Env are additional environment variables
	Env []string

	// LogPath is the path to write output logs (optional)
	LogPath string

	// Quiet suppresses output to stdout
	Quiet bool

	// HealthCheckInterval is how often to check if the process is alive
	HealthCheckInterval time.Duration
}

// DefaultConfig returns a default worker configuration.
func DefaultConfig(tier state.WorkerTier) *Config {
	timeout := 15 * time.Minute
	switch tier {
	case state.TierSous:
		timeout = 30 * time.Minute
	case state.TierExecutive:
		timeout = 60 * time.Minute
	}

	return &Config{
		Tier:                tier,
		Timeout:             timeout,
		HealthCheckInterval: 5 * time.Second,
	}
}

// Factory creates workers based on configuration.
type Factory struct {
	lineConfig      *Config
	sousConfig      *Config
	executiveConfig *Config
}

// NewFactory creates a worker factory.
func NewFactory(line, sous, exec *Config) *Factory {
	return &Factory{
		lineConfig:      line,
		sousConfig:      sous,
		executiveConfig: exec,
	}
}

// Line creates a line cook worker.
func (f *Factory) Line() Worker {
	return NewCLIWorker(f.lineConfig)
}

// Sous creates a sous chef worker.
func (f *Factory) Sous() Worker {
	return NewCLIWorker(f.sousConfig)
}

// Executive creates an executive chef worker.
func (f *Factory) Executive() Worker {
	return NewCLIWorker(f.executiveConfig)
}

// ForTier returns a worker for the given tier.
func (f *Factory) ForTier(tier state.WorkerTier) Worker {
	switch tier {
	case state.TierLine:
		return f.Line()
	case state.TierSous:
		return f.Sous()
	case state.TierExecutive:
		return f.Executive()
	default:
		return f.Line()
	}
}
