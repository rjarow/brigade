// Package verify handles task verification commands.
package verify

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"brigade/internal/prd"
)

// Result holds the result of a verification run.
type Result struct {
	// Passed is true if all verification commands passed
	Passed bool

	// Results contains individual command results
	Results []CommandResult

	// Duration is the total verification time
	Duration time.Duration
}

// CommandResult holds the result of a single verification command.
type CommandResult struct {
	// Command is the verification command that was run
	Command string

	// Type is the verification type (pattern, unit, integration, smoke)
	Type prd.VerificationType

	// Passed is true if the command succeeded
	Passed bool

	// Output is the command output
	Output string

	// Error message if the command failed
	Error string

	// Duration of this command
	Duration time.Duration

	// ExitCode of the command
	ExitCode int
}

// Runner runs verification commands.
type Runner struct {
	// Timeout for each verification command
	Timeout time.Duration

	// WorkingDir is the working directory for commands
	WorkingDir string

	// Quiet suppresses output
	Quiet bool
}

// NewRunner creates a new verification runner.
func NewRunner(timeout time.Duration, workingDir string) *Runner {
	return &Runner{
		Timeout:    timeout,
		WorkingDir: workingDir,
	}
}

// Run executes all verification commands for a task.
func (r *Runner) Run(ctx context.Context, task *prd.Task) (*Result, error) {
	if len(task.Verification) == 0 {
		return &Result{Passed: true}, nil
	}

	start := time.Now()
	result := &Result{
		Passed:  true,
		Results: make([]CommandResult, 0, len(task.Verification)),
	}

	for _, v := range task.Verification {
		cmdResult := r.runCommand(ctx, v.Cmd, v.Type)
		result.Results = append(result.Results, cmdResult)

		if !cmdResult.Passed {
			result.Passed = false
		}
	}

	result.Duration = time.Since(start)
	return result, nil
}

// runCommand executes a single verification command.
func (r *Runner) runCommand(ctx context.Context, command string, vType prd.VerificationType) CommandResult {
	start := time.Now()

	result := CommandResult{
		Command: command,
		Type:    vType,
	}

	// Create timeout context
	timeoutCtx, cancel := context.WithTimeout(ctx, r.Timeout)
	defer cancel()

	// Execute command via shell
	cmd := exec.CommandContext(timeoutCtx, "sh", "-c", command)
	if r.WorkingDir != "" {
		cmd.Dir = r.WorkingDir
	}

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	result.Duration = time.Since(start)
	result.Output = stdout.String() + stderr.String()

	if err != nil {
		if timeoutCtx.Err() == context.DeadlineExceeded {
			result.Error = fmt.Sprintf("command timed out after %v", r.Timeout)
			result.Passed = false
			return result
		}

		if exitErr, ok := err.(*exec.ExitError); ok {
			result.ExitCode = exitErr.ExitCode()
			result.Error = fmt.Sprintf("exited with code %d", result.ExitCode)
		} else {
			result.Error = err.Error()
		}
		result.Passed = false
		return result
	}

	result.Passed = true
	result.ExitCode = 0
	return result
}

// RunTestCmd runs a general test command (not task-specific).
func (r *Runner) RunTestCmd(ctx context.Context, testCmd string) (*CommandResult, error) {
	if testCmd == "" {
		return nil, nil
	}

	result := r.runCommand(ctx, testCmd, "")
	return &result, nil
}

// Summary returns a human-readable summary of verification results.
func (r *Result) Summary() string {
	if r.Passed {
		return fmt.Sprintf("All %d verification commands passed (%v)", len(r.Results), r.Duration.Round(time.Millisecond))
	}

	var failed []string
	for _, cr := range r.Results {
		if !cr.Passed {
			failed = append(failed, cr.Command)
		}
	}

	return fmt.Sprintf("%d/%d verification commands failed: %s", len(failed), len(r.Results), strings.Join(failed, ", "))
}

// FailedCommands returns the commands that failed.
func (r *Result) FailedCommands() []CommandResult {
	var failed []CommandResult
	for _, cr := range r.Results {
		if !cr.Passed {
			failed = append(failed, cr)
		}
	}
	return failed
}

// HasGrepOnly returns true if the task only has grep-based verification.
func HasGrepOnly(task *prd.Task) bool {
	if len(task.Verification) == 0 {
		return false
	}

	for _, v := range task.Verification {
		if !isGrepCommand(v.Cmd) {
			return false
		}
	}
	return true
}

// isGrepCommand checks if a command is grep-based (pattern check without execution).
func isGrepCommand(cmd string) bool {
	cmdLower := strings.ToLower(cmd)
	grepPatterns := []string{"grep ", "grep\t", "test -f", "test -d", "test -e", "[ -f", "[ -d", "[ -e"}
	for _, pattern := range grepPatterns {
		if strings.Contains(cmdLower, pattern) {
			return true
		}
	}
	return false
}

// HasExecutionTests returns true if the task has execution-based tests.
func HasExecutionTests(task *prd.Task) bool {
	for _, v := range task.Verification {
		if v.Type == prd.VerificationUnit || v.Type == prd.VerificationIntegration || v.Type == prd.VerificationSmoke {
			return true
		}
		// Also check for common test commands
		cmdLower := strings.ToLower(v.Cmd)
		if strings.Contains(cmdLower, "test") || strings.Contains(cmdLower, "spec") || strings.Contains(cmdLower, "pytest") {
			return true
		}
	}
	return false
}
