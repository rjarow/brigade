package worker

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"brigade/internal/prd"
	"brigade/internal/state"
)

// PromptBuilder constructs prompts for workers.
type PromptBuilder struct {
	chefDir      string
	learningsPath string
	backlogPath  string
}

// NewPromptBuilder creates a new prompt builder.
func NewPromptBuilder(chefDir, learningsPath, backlogPath string) *PromptBuilder {
	return &PromptBuilder{
		chefDir:      chefDir,
		learningsPath: learningsPath,
		backlogPath:  backlogPath,
	}
}

// BuildTaskPrompt builds a prompt for task execution.
func (b *PromptBuilder) BuildTaskPrompt(opts TaskPromptOptions) (string, error) {
	var parts []string

	// Load base prompt for worker tier
	basePrompt, err := b.loadChefPrompt(opts.Tier)
	if err != nil {
		return "", fmt.Errorf("loading chef prompt: %w", err)
	}
	parts = append(parts, basePrompt)

	// Add task details
	taskSection := b.buildTaskSection(opts.Task, opts.PRD)
	parts = append(parts, taskSection)

	// Add learnings if available
	if b.learningsPath != "" {
		learnings, err := b.loadLearnings()
		if err == nil && learnings != "" {
			parts = append(parts, "\n=== TEAM LEARNINGS ===\n"+learnings+"\n=== END LEARNINGS ===")
		}
	}

	// Add review feedback if present
	if opts.ReviewFeedback != "" {
		parts = append(parts, fmt.Sprintf("\n⚠️ PREVIOUS ATTEMPT FAILED EXECUTIVE REVIEW: %s\n", opts.ReviewFeedback))
	}

	// Add previous approaches for smart retry
	if len(opts.PreviousApproaches) > 0 {
		parts = append(parts, b.buildApproachHistory(opts.PreviousApproaches))
	}

	// Add session failures for cross-task learning
	if len(opts.SessionFailures) > 0 {
		parts = append(parts, b.buildSessionFailures(opts.SessionFailures))
	}

	// Add escalation context if escalated
	if opts.EscalationContext != nil {
		parts = append(parts, b.buildEscalationContext(opts.EscalationContext))
	}

	// Add codebase map if available
	if opts.CodebaseMap != "" {
		parts = append(parts, "\n=== CODEBASE MAP ===\n"+opts.CodebaseMap+"\n=== END MAP ===")
	}

	return strings.Join(parts, "\n"), nil
}

// TaskPromptOptions holds options for building a task prompt.
type TaskPromptOptions struct {
	Task               *prd.Task
	PRD                *prd.PRD
	Tier               state.WorkerTier
	ReviewFeedback     string
	PreviousApproaches []state.ApproachEntry
	SessionFailures    []state.SessionFailure
	EscalationContext  *EscalationContext
	CodebaseMap        string
}

// EscalationContext holds context about an escalation.
type EscalationContext struct {
	FromTier          state.WorkerTier
	Attempts          []state.ApproachEntry
	FailureCategories []string
}

// buildTaskSection builds the task details section.
func (b *PromptBuilder) buildTaskSection(task *prd.Task, p *prd.PRD) string {
	var sb strings.Builder

	sb.WriteString("\n=== TASK ===\n")
	sb.WriteString(fmt.Sprintf("ID: %s\n", task.ID))
	sb.WriteString(fmt.Sprintf("Title: %s\n", task.Title))
	if task.Description != "" {
		sb.WriteString(fmt.Sprintf("Description: %s\n", task.Description))
	}

	sb.WriteString("\nAcceptance Criteria:\n")
	for i, criterion := range task.AcceptanceCriteria {
		sb.WriteString(fmt.Sprintf("  %d. %s\n", i+1, criterion))
	}

	if len(task.Verification) > 0 {
		sb.WriteString("\nVerification Commands (will be run after completion):\n")
		for _, v := range task.Verification {
			if v.Type != "" {
				sb.WriteString(fmt.Sprintf("  [%s] %s\n", v.Type, v.Cmd))
			} else {
				sb.WriteString(fmt.Sprintf("  %s\n", v.Cmd))
			}
		}
	}

	if len(task.DependsOn) > 0 {
		sb.WriteString(fmt.Sprintf("\nDepends on: %s (already completed)\n", strings.Join(task.DependsOn, ", ")))
	}

	sb.WriteString("\n=== END TASK ===")

	return sb.String()
}

// loadChefPrompt loads the base prompt for a worker tier.
func (b *PromptBuilder) loadChefPrompt(tier state.WorkerTier) (string, error) {
	var filename string
	switch tier {
	case state.TierLine:
		filename = "line.md"
	case state.TierSous:
		filename = "sous.md"
	case state.TierExecutive:
		filename = "executive.md"
	default:
		filename = "line.md"
	}

	path := filepath.Join(b.chefDir, filename)
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("reading %s: %w", path, err)
	}

	return string(data), nil
}

// loadLearnings loads the learnings file.
func (b *PromptBuilder) loadLearnings() (string, error) {
	if b.learningsPath == "" {
		return "", nil
	}

	data, err := os.ReadFile(b.learningsPath)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}

	return string(data), nil
}

// buildApproachHistory builds the previous approaches section.
func (b *PromptBuilder) buildApproachHistory(approaches []state.ApproachEntry) string {
	var sb strings.Builder

	sb.WriteString("\n=== PREVIOUS APPROACHES (avoid repeating these) ===\n")
	for _, a := range approaches {
		if a.Category != "" {
			sb.WriteString(fmt.Sprintf("- %s: %s → %s\n", a.Worker, a.Approach, a.Category))
		} else {
			sb.WriteString(fmt.Sprintf("- %s: %s\n", a.Worker, a.Approach))
		}
	}
	sb.WriteString("\nTry a DIFFERENT approach.\n=== END PREVIOUS APPROACHES ===")

	return sb.String()
}

// buildSessionFailures builds the session failures section.
func (b *PromptBuilder) buildSessionFailures(failures []state.SessionFailure) string {
	var sb strings.Builder

	sb.WriteString("\n=== SESSION FAILURES (issues encountered in other tasks this session) ===\n")
	for _, f := range failures {
		sb.WriteString(fmt.Sprintf("- %s: %s\n", f.Category, f.Error))
	}
	sb.WriteString("\nBe aware of these patterns that have caused problems.\n=== END SESSION FAILURES ===")

	return sb.String()
}

// buildEscalationContext builds the escalation context section.
func (b *PromptBuilder) buildEscalationContext(ctx *EscalationContext) string {
	var sb strings.Builder

	sb.WriteString("\n=== ESCALATION CONTEXT ===\n")
	sb.WriteString(fmt.Sprintf("Escalated from %s after multiple failures.\n", ctx.FromTier))

	if len(ctx.Attempts) > 0 {
		sb.WriteString("\nAttempted approaches:\n")
		for _, a := range ctx.Attempts {
			if a.Category != "" {
				sb.WriteString(fmt.Sprintf("- %s: %s → %s\n", a.Worker, a.Approach, a.Category))
			} else {
				sb.WriteString(fmt.Sprintf("- %s: %s\n", a.Worker, a.Approach))
			}
		}
	}

	sb.WriteString("\nDo NOT repeat these approaches.\n=== END ESCALATION CONTEXT ===")

	return sb.String()
}

// BuildReviewPrompt builds a prompt for executive review.
func (b *PromptBuilder) BuildReviewPrompt(task *prd.Task, workerOutput string) (string, error) {
	basePrompt, err := b.loadChefPrompt(state.TierExecutive)
	if err != nil {
		return "", err
	}

	var sb strings.Builder
	sb.WriteString(basePrompt)
	sb.WriteString("\n\n=== REVIEW REQUEST ===\n")
	sb.WriteString("Please review the following task completion.\n\n")

	sb.WriteString("Task:\n")
	sb.WriteString(fmt.Sprintf("  ID: %s\n", task.ID))
	sb.WriteString(fmt.Sprintf("  Title: %s\n", task.Title))
	sb.WriteString("  Acceptance Criteria:\n")
	for i, criterion := range task.AcceptanceCriteria {
		sb.WriteString(fmt.Sprintf("    %d. %s\n", i+1, criterion))
	}

	sb.WriteString("\nWorker Output:\n")
	sb.WriteString(workerOutput)

	sb.WriteString("\n\nRespond with:\n")
	sb.WriteString("- <review>PASS</review> if all acceptance criteria are met\n")
	sb.WriteString("- <review>FAIL: [reason]</review> if criteria are not met\n")
	sb.WriteString("=== END REVIEW REQUEST ===")

	return sb.String(), nil
}

// BuildWalkawayDecisionPrompt builds a prompt for autonomous failure decisions.
func (b *PromptBuilder) BuildWalkawayDecisionPrompt(task *prd.Task, failureReason string, attempts int) (string, error) {
	basePrompt, err := b.loadChefPrompt(state.TierExecutive)
	if err != nil {
		return "", err
	}

	var sb strings.Builder
	sb.WriteString(basePrompt)
	sb.WriteString("\n\n=== DECISION REQUIRED ===\n")
	sb.WriteString(fmt.Sprintf("Task %s failed after %d attempts.\n\n", task.ID, attempts))
	sb.WriteString(fmt.Sprintf("Task: %s\n", task.Title))
	sb.WriteString(fmt.Sprintf("Failure: %s\n\n", failureReason))

	sb.WriteString("Options:\n")
	sb.WriteString("1. RETRY - Try the task again with a different approach\n")
	sb.WriteString("2. SKIP - Skip this task and continue with others\n")
	sb.WriteString("3. ABORT - Stop execution entirely\n\n")

	sb.WriteString("Respond with:\n")
	sb.WriteString("<decision>RETRY</decision> or <decision>SKIP</decision> or <decision>ABORT</decision>\n")
	sb.WriteString("Optionally add <guidance>advice for next attempt</guidance>\n")
	sb.WriteString("=== END DECISION REQUEST ===")

	return sb.String(), nil
}

// BuildScopeDecisionPrompt builds a prompt for scope question decisions.
func (b *PromptBuilder) BuildScopeDecisionPrompt(task *prd.Task, question string) (string, error) {
	basePrompt, err := b.loadChefPrompt(state.TierExecutive)
	if err != nil {
		return "", err
	}

	var sb strings.Builder
	sb.WriteString(basePrompt)
	sb.WriteString("\n\n=== SCOPE DECISION REQUIRED ===\n")
	sb.WriteString(fmt.Sprintf("Task %s has a scope question:\n\n", task.ID))
	sb.WriteString(fmt.Sprintf("Task: %s\n", task.Title))
	sb.WriteString(fmt.Sprintf("Question: %s\n\n", question))

	sb.WriteString("Please decide on the approach. Consider:\n")
	sb.WriteString("- What makes sense for this codebase?\n")
	sb.WriteString("- What's the simplest reasonable approach?\n")
	sb.WriteString("- What aligns with existing patterns?\n\n")

	sb.WriteString("Respond with:\n")
	sb.WriteString("<scope-decision>Your decision and reasoning</scope-decision>\n")
	sb.WriteString("=== END SCOPE DECISION REQUEST ===")

	return sb.String(), nil
}

// StrategySuggestions returns suggestions based on error category.
func StrategySuggestions(category string) string {
	switch category {
	case "integration":
		return "Try: Mock the service, use test doubles, verify service is running"
	case "environment":
		return "Try: Check file paths, verify permissions, ensure dependencies installed"
	case "syntax":
		return "Try: Check language version, verify imports, review compiler output"
	case "logic":
		return "Try: Re-read acceptance criteria, check edge cases, verify test setup"
	default:
		return ""
	}
}

// AppendLearning appends a learning to the learnings file.
func (b *PromptBuilder) AppendLearning(learning string) error {
	if b.learningsPath == "" {
		return nil
	}

	f, err := os.OpenFile(b.learningsPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	defer f.Close()

	_, err = f.WriteString(learning + "\n\n")
	return err
}

// AppendBacklog appends an item to the backlog file.
func (b *PromptBuilder) AppendBacklog(item string) error {
	if b.backlogPath == "" {
		return nil
	}

	f, err := os.OpenFile(b.backlogPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	defer f.Close()

	_, err = f.WriteString("- " + item + "\n")
	return err
}
