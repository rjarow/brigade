// Package orchestrator handles the main Brigade service loop.
package orchestrator

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"brigade/internal/classify"
	"brigade/internal/config"
	"brigade/internal/module"
	"brigade/internal/prd"
	"brigade/internal/state"
	"brigade/internal/supervisor"
	"brigade/internal/verify"
	"brigade/internal/worker"
)

// Orchestrator manages the execution of PRD tasks.
type Orchestrator struct {
	config       *config.Config
	prd          *prd.PRD
	state        *state.State
	store        *state.Store
	serviceLock  *state.ServiceLock
	workers      *worker.Factory
	promptBuilder *worker.PromptBuilder
	verifier     *verify.Runner
	classifier   *classify.Classifier
	modules      *module.Manager
	supervisor   *supervisor.Supervisor
	logger       *slog.Logger

	// Runtime state
	startTime       time.Time
	taskStartTime   time.Time
	cancelled       bool
	runningWorkers  []*workerExecution
}

// Options configures the orchestrator.
type Options struct {
	Config         *config.Config
	PRDPath        string
	Logger         *slog.Logger
	DryRun         bool
	Sequential     bool
	WalkawayMode   bool
	MaxIterations  int

	// Partial execution filters
	OnlyTasks      []string
	SkipTasks      []string
	FromTask       string
	UntilTask      string
}

// workerExecution tracks a running worker.
type workerExecution struct {
	taskID  string
	worker  worker.Worker
	cancel  context.CancelFunc
}

// New creates a new orchestrator.
func New(opts Options) (*Orchestrator, error) {
	logger := opts.Logger
	if logger == nil {
		logger = slog.Default()
	}

	// Load PRD
	p, err := prd.Load(opts.PRDPath)
	if err != nil {
		return nil, fmt.Errorf("loading PRD: %w", err)
	}

	// Initialize state store
	store := state.ForPRD(opts.PRDPath)
	st, _, err := store.LoadOrCreate()
	if err != nil {
		return nil, fmt.Errorf("loading state: %w", err)
	}

	// Apply walkaway mode from PRD or options
	cfg := opts.Config
	if cfg == nil {
		cfg = config.Default()
	}
	if p.Walkaway || opts.WalkawayMode {
		cfg.WalkawayMode = true
	}

	// Create service lock
	serviceLock := state.NewServiceLock(opts.PRDPath)

	// Create workers
	workers := createWorkerFactory(cfg)

	// Create prompt builder
	chefDir := "chef"
	learningsPath := cfg.LearningsFile
	backlogPath := cfg.BacklogFile
	promptBuilder := worker.NewPromptBuilder(chefDir, learningsPath, backlogPath)

	// Create verifier
	verifier := verify.NewRunner(cfg.VerificationTimeout, "")

	// Create classifier
	classifier := classify.NewClassifier()
	if cfg.SmartRetryCustomPatterns != "" {
		classifier.AddPatternsFromString(cfg.SmartRetryCustomPatterns)
	}

	// Create module manager
	modules := module.NewManager("modules", cfg.ModuleConfig, cfg.ModuleTimeout, logger)
	if len(cfg.Modules) > 0 {
		if err := modules.Load(cfg.Modules); err != nil {
			logger.Warn("failed to load modules", "error", err)
		}
	}

	// Create supervisor integration
	sup := supervisor.NewSupervisor(
		cfg.SupervisorStatusFile,
		cfg.SupervisorEventsFile,
		cfg.SupervisorCmdFile,
		p.Prefix(),
		cfg.SupervisorPRDScoped,
		cfg.SupervisorCmdPollInterval,
		cfg.SupervisorCmdTimeout,
	)

	return &Orchestrator{
		config:        cfg,
		prd:           p,
		state:         st,
		store:         store,
		serviceLock:   serviceLock,
		workers:       workers,
		promptBuilder: promptBuilder,
		verifier:      verifier,
		classifier:    classifier,
		modules:       modules,
		supervisor:    sup,
		logger:        logger,
	}, nil
}

// createWorkerFactory creates workers based on configuration.
func createWorkerFactory(cfg *config.Config) *worker.Factory {
	lineConfig := &worker.Config{
		Command: cfg.LineCmd,
		Tier:    state.TierLine,
		Timeout: cfg.TaskTimeoutJunior,
		Quiet:   cfg.QuietWorkers,
		HealthCheckInterval: cfg.WorkerHealthCheckInterval,
	}

	sousConfig := &worker.Config{
		Command: cfg.SousCmd,
		Tier:    state.TierSous,
		Timeout: cfg.TaskTimeoutSenior,
		Quiet:   cfg.QuietWorkers,
		HealthCheckInterval: cfg.WorkerHealthCheckInterval,
	}

	execConfig := &worker.Config{
		Command: cfg.ExecutiveCmd,
		Tier:    state.TierExecutive,
		Timeout: cfg.TaskTimeoutExecutive,
		Quiet:   cfg.QuietWorkers,
		HealthCheckInterval: cfg.WorkerHealthCheckInterval,
	}

	return worker.NewFactory(lineConfig, sousConfig, execConfig)
}

// Run executes the PRD.
func (o *Orchestrator) Run(ctx context.Context) error {
	o.startTime = time.Now()

	// Set up signal handling
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		select {
		case <-sigCh:
			o.logger.Info("received interrupt signal, shutting down gracefully")
			o.cancelled = true
			cancel()
			o.cleanup()
		case <-ctx.Done():
		}
	}()

	// Acquire service lock
	if err := o.serviceLock.AcquireExclusive(); err != nil {
		return err
	}
	defer o.serviceLock.Release()

	// Update state timestamp
	o.state.UpdateLastStartTime()
	if err := o.store.Save(o.state); err != nil {
		return fmt.Errorf("saving state: %w", err)
	}

	// Dispatch service_start event
	o.modules.Dispatch(module.ServiceStartEvent(o.prd.Prefix(), o.prd.TotalTasks()))
	if o.supervisor.Events().Enabled() {
		o.supervisor.Events().WriteServiceStart(o.prd.Prefix(), o.prd.TotalTasks())
	}

	// Main service loop
	err := o.serviceLoop(ctx)

	// Dispatch service_complete event
	completed, total := o.prd.Progress()
	duration := time.Since(o.startTime)
	o.modules.Dispatch(module.ServiceCompleteEvent(o.prd.Prefix(), completed, total, duration))
	if o.supervisor.Events().Enabled() {
		o.supervisor.Events().WriteServiceComplete(o.prd.Prefix(), completed, total, duration)
	}

	return err
}

// serviceLoop is the main execution loop.
func (o *Orchestrator) serviceLoop(ctx context.Context) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		// Get completed tasks
		completed := o.state.CompletedTaskIDs()

		// Update PRD passes from state
		for taskID := range completed {
			o.prd.MarkTaskComplete(taskID)
		}

		// Check if all done
		if o.prd.IsComplete() {
			o.logger.Info("all tasks complete!")
			return nil
		}

		// Get ready tasks
		readyTasks := o.prd.ReadyTasks(completed)
		if len(readyTasks) == 0 {
			// No ready tasks - might be blocked
			pending := o.prd.PendingTasks()
			if len(pending) > 0 {
				o.logger.Warn("no ready tasks but work remains",
					"pending", len(pending))
				return fmt.Errorf("blocked: no tasks ready to execute")
			}
			return nil
		}

		// Execute tasks
		if o.config.MaxParallel > 1 && len(readyTasks) > 1 {
			if err := o.executeParallel(ctx, readyTasks); err != nil {
				return err
			}
		} else {
			// Execute single task
			task := readyTasks[0]
			if err := o.executeTask(ctx, task); err != nil {
				return err
			}
		}

		// Save state after each iteration
		if err := o.store.Save(o.state); err != nil {
			o.logger.Error("failed to save state", "error", err)
		}

		// Update status
		done, total := o.prd.Progress()
		if o.supervisor.Status().Enabled() {
			o.supervisor.UpdateStatus(done, total, "", "", time.Time{}, false)
		}
	}
}

// executeTask executes a single task.
func (o *Orchestrator) executeTask(ctx context.Context, task *prd.Task) error {
	o.taskStartTime = time.Now()
	o.state.SetCurrentTask(task.ID)

	// Determine worker tier
	tier := o.determineWorkerTier(task)

	// Build prompt
	prompt, err := o.buildTaskPrompt(task, tier)
	if err != nil {
		return fmt.Errorf("building prompt: %w", err)
	}

	// Get worker
	w := o.workers.ForTier(tier)

	// Dispatch task_start event
	o.modules.Dispatch(module.TaskStartEvent(o.prd.Prefix(), task.ID, string(tier)))
	if o.supervisor.Events().Enabled() {
		o.supervisor.Events().WriteTaskStart(o.prd.Prefix(), task.ID, string(tier))
	}

	// Update status
	done, total := o.prd.Progress()
	if o.supervisor.Status().Enabled() {
		o.supervisor.UpdateStatus(done, total, task.ID, string(tier), o.taskStartTime, false)
	}

	o.logger.Info("executing task",
		"task", o.prd.FormatTaskID(task.ID),
		"worker", tier)

	// Execute worker
	result, err := w.Execute(ctx, prompt)
	if err != nil {
		return fmt.Errorf("worker execution: %w", err)
	}

	// Process result
	return o.processResult(ctx, task, w, result)
}

// processResult handles the result of a worker execution.
func (o *Orchestrator) processResult(ctx context.Context, task *prd.Task, w worker.Worker, result *worker.Result) error {
	duration := result.Duration

	// Record approach if declared
	if result.Approach != "" {
		entry := state.TaskHistory{
			TaskID:   task.ID,
			Worker:   w.Tier(),
			Status:   state.StatusInProgress,
			Approach: result.Approach,
		}
		o.state.AddTaskHistory(entry)
	}

	// Process learnings
	for _, learning := range result.Learnings {
		o.promptBuilder.AppendLearning(learning)
	}

	// Process backlog items
	for _, item := range result.Backlog {
		o.promptBuilder.AppendBacklog(item)
	}

	// Handle different outcomes
	switch {
	case result.IsComplete():
		return o.handleComplete(ctx, task, w, result, duration)

	case result.IsBlocked():
		return o.handleBlocked(ctx, task, w, result)

	case result.IsAbsorbed():
		return o.handleAbsorbed(task, result.AbsorbedBy)

	case result.Timeout:
		return o.handleTimeout(ctx, task, w)

	case result.Crashed:
		return o.handleCrash(ctx, task, w, result)

	default:
		// Needs iteration
		return o.handleIteration(ctx, task, w, result)
	}
}

// handleComplete handles successful task completion.
func (o *Orchestrator) handleComplete(ctx context.Context, task *prd.Task, w worker.Worker, result *worker.Result, duration time.Duration) error {
	// Run verification if enabled
	if o.config.VerificationEnabled && len(task.Verification) > 0 {
		verifyResult, err := o.verifier.Run(ctx, task)
		if err != nil {
			o.logger.Error("verification error", "error", err)
		} else if !verifyResult.Passed {
			o.logger.Warn("verification failed", "task", task.ID)
			// Treat as needing iteration
			return o.handleIteration(ctx, task, w, result)
		}
	}

	// Run executive review if enabled
	if o.config.ReviewEnabled {
		if !o.config.ReviewJuniorOnly || w.Tier() == state.TierLine {
			passed, reason := o.runReview(ctx, task, result.Output)
			if !passed {
				o.logger.Warn("review failed", "task", task.ID, "reason", reason)
				// Store feedback for next iteration
				o.state.AddReview(task.ID, "fail", reason)
				return o.handleIteration(ctx, task, w, result)
			}
			o.state.AddReview(task.ID, "pass", "")
		}
	}

	// Mark complete
	o.state.AddTaskHistory(state.TaskHistory{
		TaskID:   task.ID,
		Worker:   w.Tier(),
		Status:   state.StatusComplete,
		Duration: int(duration.Seconds()),
	})
	o.prd.MarkTaskComplete(task.ID)

	// Dispatch task_complete event
	o.modules.Dispatch(module.TaskCompleteEvent(o.prd.Prefix(), task.ID, string(w.Tier()), duration))
	if o.supervisor.Events().Enabled() {
		o.supervisor.Events().WriteTaskComplete(o.prd.Prefix(), task.ID, string(w.Tier()), duration)
	}

	o.logger.Info("task complete",
		"task", o.prd.FormatTaskID(task.ID),
		"duration", duration.Round(time.Second))

	o.state.ResetSkips()
	o.state.ClearCurrentTask()
	return nil
}

// handleBlocked handles a blocked task.
func (o *Orchestrator) handleBlocked(ctx context.Context, task *prd.Task, w worker.Worker, result *worker.Result) error {
	o.logger.Warn("task blocked", "task", task.ID)

	// Dispatch event
	o.modules.Dispatch(module.TaskBlockedEvent(o.prd.Prefix(), task.ID, string(w.Tier()), "worker signaled BLOCKED"))
	if o.supervisor.Events().Enabled() {
		o.supervisor.Events().WriteTaskBlocked(o.prd.Prefix(), task.ID, string(w.Tier()), "worker signaled BLOCKED")
	}

	// Try escalation
	return o.handleEscalation(ctx, task, w, "worker signaled BLOCKED")
}

// handleAbsorbed handles a task absorbed by another.
func (o *Orchestrator) handleAbsorbed(task *prd.Task, absorbedBy string) error {
	o.logger.Info("task absorbed", "task", task.ID, "by", absorbedBy)

	o.state.AddAbsorption(task.ID, absorbedBy)
	o.prd.MarkTaskComplete(task.ID)
	o.state.ClearCurrentTask()
	return nil
}

// handleTimeout handles a worker timeout.
func (o *Orchestrator) handleTimeout(ctx context.Context, task *prd.Task, w worker.Worker) error {
	o.logger.Warn("worker timeout", "task", task.ID)
	return o.handleEscalation(ctx, task, w, "worker timeout")
}

// handleCrash handles a worker crash.
func (o *Orchestrator) handleCrash(ctx context.Context, task *prd.Task, w worker.Worker, result *worker.Result) error {
	o.logger.Error("worker crashed", "task", task.ID)
	return o.handleEscalation(ctx, task, w, "worker crashed")
}

// handleIteration handles a task needing another iteration.
func (o *Orchestrator) handleIteration(ctx context.Context, task *prd.Task, w worker.Worker, result *worker.Result) error {
	attempts := o.state.TotalAttempts(task.ID)

	// Check max iterations
	if attempts >= o.config.MaxIterations {
		o.logger.Error("max iterations reached", "task", task.ID, "attempts", attempts)
		return o.handleDecision(ctx, task, "max iterations reached")
	}

	// Classify error if present
	var category classify.Category
	if result.Error != nil || !result.Success() {
		errorOutput := result.Output
		if result.Error != nil {
			errorOutput = result.Error.Error() + "\n" + result.Output
		}
		category = o.classifier.Classify(errorOutput)

		// Record failure
		errorMsg := classify.ExtractErrorMessage(errorOutput, 100)
		o.state.AddSessionFailure(task.ID, string(category), errorMsg, o.config.SmartRetrySessionFailuresMax)
	}

	// Check escalation
	if o.shouldEscalate(task.ID, w.Tier()) {
		return o.handleEscalation(ctx, task, w, fmt.Sprintf("failed after %d attempts", attempts))
	}

	// Continue with same worker
	o.logger.Info("retrying task",
		"task", task.ID,
		"attempt", attempts+1,
		"category", category)

	return o.executeTask(ctx, task)
}

// handleEscalation handles escalating to a higher tier.
func (o *Orchestrator) handleEscalation(ctx context.Context, task *prd.Task, w worker.Worker, reason string) error {
	if !o.config.EscalationEnabled {
		return o.handleDecision(ctx, task, reason)
	}

	currentTier := w.Tier()
	var nextTier state.WorkerTier

	switch currentTier {
	case state.TierLine:
		nextTier = state.TierSous
	case state.TierSous:
		if o.config.EscalationToExec {
			nextTier = state.TierExecutive
		} else {
			return o.handleDecision(ctx, task, reason)
		}
	case state.TierExecutive:
		return o.handleDecision(ctx, task, reason)
	}

	// Record escalation
	o.state.AddEscalation(task.ID, currentTier, nextTier, reason)

	// Dispatch event
	o.modules.Dispatch(module.EscalationEvent(o.prd.Prefix(), task.ID, string(currentTier), string(nextTier), reason))
	if o.supervisor.Events().Enabled() {
		o.supervisor.Events().WriteEscalation(o.prd.Prefix(), task.ID, string(currentTier), string(nextTier), reason)
	}

	o.logger.Info("escalating task",
		"task", task.ID,
		"from", currentTier,
		"to", nextTier,
		"reason", reason)

	// Execute with higher tier
	return o.executeTask(ctx, task)
}

// handleDecision handles a decision point (walkaway or interactive).
func (o *Orchestrator) handleDecision(ctx context.Context, task *prd.Task, reason string) error {
	if o.config.WalkawayMode {
		return o.handleWalkawayDecision(ctx, task, reason)
	}

	// In interactive mode, we'd prompt the user
	// For now, just fail
	return fmt.Errorf("task %s failed: %s", task.ID, reason)
}

// handleWalkawayDecision handles autonomous decision making.
func (o *Orchestrator) handleWalkawayDecision(ctx context.Context, task *prd.Task, reason string) error {
	attempts := o.state.TotalAttempts(task.ID)

	// Build decision prompt
	prompt, err := o.promptBuilder.BuildWalkawayDecisionPrompt(task, reason, attempts)
	if err != nil {
		o.logger.Error("failed to build decision prompt", "error", err)
		return fmt.Errorf("building decision prompt: %w", err)
	}

	// Get executive to decide
	exec := o.workers.Executive()
	result, err := exec.Execute(ctx, prompt)
	if err != nil {
		o.logger.Error("decision failed", "error", err)
		// Default to skip
		return o.skipTask(task, "decision execution failed")
	}

	// Parse decision from output
	decision := parseDecision(result.Output)
	guidance := parseGuidance(result.Output)

	switch decision {
	case "RETRY":
		o.logger.Info("walkaway: retrying task", "task", task.ID, "guidance", guidance)
		return o.executeTask(ctx, task)
	case "SKIP":
		return o.skipTask(task, reason)
	case "ABORT":
		return fmt.Errorf("walkaway aborted: %s", reason)
	default:
		// Default to skip
		return o.skipTask(task, "unknown decision")
	}
}

// skipTask skips a task and handles consecutive skip tracking.
func (o *Orchestrator) skipTask(task *prd.Task, reason string) error {
	skips := o.state.IncrementSkips()

	o.logger.Warn("skipping task",
		"task", task.ID,
		"reason", reason,
		"consecutiveSkips", skips)

	o.state.AddTaskHistory(state.TaskHistory{
		TaskID: task.ID,
		Worker: state.TierLine, // Record at lowest tier
		Status: state.StatusSkipped,
		Error:  reason,
	})

	// Check safety rail
	if skips >= o.config.WalkawayMaxSkips {
		return fmt.Errorf("too many consecutive skips (%d), pausing", skips)
	}

	o.prd.MarkTaskComplete(task.ID) // Mark as "done" so we don't retry
	o.state.ClearCurrentTask()
	return nil
}

// determineWorkerTier determines which tier should handle a task.
func (o *Orchestrator) determineWorkerTier(task *prd.Task) state.WorkerTier {
	// Check for escalation
	if o.state.WasEscalatedTo(task.ID, state.TierExecutive) {
		return state.TierExecutive
	}
	if o.state.WasEscalatedTo(task.ID, state.TierSous) {
		return state.TierSous
	}

	// Use task complexity
	switch task.Complexity {
	case prd.ComplexitySenior:
		return state.TierSous
	case prd.ComplexityJunior:
		return state.TierLine
	default:
		// Auto: use heuristics (for now, default to line)
		return state.TierLine
	}
}

// shouldEscalate checks if a task should be escalated.
func (o *Orchestrator) shouldEscalate(taskID string, tier state.WorkerTier) bool {
	attempts := o.state.AttemptsAtTier(taskID, tier)

	switch tier {
	case state.TierLine:
		return attempts >= o.config.EscalationAfter
	case state.TierSous:
		return o.config.EscalationToExec && attempts >= o.config.EscalationToExecAfter
	default:
		return false
	}
}

// buildTaskPrompt builds the prompt for a task.
func (o *Orchestrator) buildTaskPrompt(task *prd.Task, tier state.WorkerTier) (string, error) {
	opts := worker.TaskPromptOptions{
		Task: task,
		PRD:  o.prd,
		Tier: tier,
	}

	// Add review feedback if present
	opts.ReviewFeedback = o.state.GetLastReviewFeedback(task.ID)

	// Add previous approaches for smart retry
	if o.config.SmartRetryEnabled {
		opts.PreviousApproaches = o.state.GetApproachHistory(task.ID, o.config.SmartRetryApproachHistoryMax)
		opts.SessionFailures = o.state.SessionFailures
	}

	// Add escalation context
	if o.state.WasEscalated(task.ID) {
		approaches := o.state.GetApproachHistory(task.ID, 10)
		opts.EscalationContext = &worker.EscalationContext{
			FromTier: o.state.CurrentTier(task.ID, state.TierLine),
			Attempts: approaches,
		}
	}

	return o.promptBuilder.BuildTaskPrompt(opts)
}

// runReview runs an executive review on completed work.
func (o *Orchestrator) runReview(ctx context.Context, task *prd.Task, workerOutput string) (bool, string) {
	prompt, err := o.promptBuilder.BuildReviewPrompt(task, workerOutput)
	if err != nil {
		o.logger.Error("failed to build review prompt", "error", err)
		return true, "" // Pass by default if we can't build prompt
	}

	exec := o.workers.Executive()
	result, err := exec.Execute(ctx, prompt)
	if err != nil {
		o.logger.Error("review execution failed", "error", err)
		return true, "" // Pass by default on error
	}

	return parseReview(result.Output)
}

// cleanup cleans up resources.
func (o *Orchestrator) cleanup() {
	// Kill running workers
	for _, we := range o.runningWorkers {
		if we.cancel != nil {
			we.cancel()
		}
	}

	// Cleanup modules
	o.modules.Cleanup()

	// Cleanup supervisor
	o.supervisor.Cleanup()

	// Save state
	if err := o.store.Save(o.state); err != nil {
		o.logger.Error("failed to save state on cleanup", "error", err)
	}
}

// Helper functions for parsing output

func parseDecision(output string) string {
	// Look for <decision>ACTION</decision>
	// This is a simplified parser
	if contains(output, "<decision>RETRY</decision>") {
		return "RETRY"
	}
	if contains(output, "<decision>SKIP</decision>") {
		return "SKIP"
	}
	if contains(output, "<decision>ABORT</decision>") {
		return "ABORT"
	}
	return ""
}

func parseGuidance(output string) string {
	// Look for <guidance>...</guidance>
	// Simplified extraction
	return ""
}

func parseReview(output string) (bool, string) {
	// Look for <review>PASS</review> or <review>FAIL: reason</review>
	if contains(output, "<review>PASS</review>") {
		return true, ""
	}
	// Extract failure reason (simplified)
	return false, "review failed"
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsImpl(s, substr))
}

func containsImpl(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
