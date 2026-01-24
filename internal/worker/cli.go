package worker

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"brigade/internal/state"
)

// CLIWorker executes tasks via a CLI tool (Claude, OpenCode, etc.).
type CLIWorker struct {
	config *Config
	name   string
}

// NewCLIWorker creates a new CLI-based worker.
func NewCLIWorker(config *Config) *CLIWorker {
	// Extract name from command
	name := config.Command
	if parts := strings.Fields(config.Command); len(parts) > 0 {
		name = parts[0]
	}

	return &CLIWorker{
		config: config,
		name:   name,
	}
}

// Name returns the worker name.
func (w *CLIWorker) Name() string {
	return w.name
}

// Tier returns the worker's tier.
func (w *CLIWorker) Tier() state.WorkerTier {
	return w.config.Tier
}

// Execute runs the worker with the given prompt.
func (w *CLIWorker) Execute(ctx context.Context, prompt string) (*Result, error) {
	start := time.Now()

	// Build command
	cmdParts := strings.Fields(w.config.Command)
	if len(cmdParts) == 0 {
		return nil, fmt.Errorf("empty command")
	}

	// Add default args based on tool type
	args := append([]string{}, cmdParts[1:]...)
	args = append(args, w.config.Args...)

	// Detect tool type and add appropriate flags
	toolName := cmdParts[0]
	switch {
	case strings.Contains(toolName, "claude"):
		// Claude CLI: use --dangerously-skip-permissions and -p for prompt
		args = append(args, "--dangerously-skip-permissions", "-p", prompt)
	case strings.Contains(toolName, "opencode"):
		// OpenCode: prompt is the last argument after "run"
		// Ensure we have "run" in args
		hasRun := false
		for _, arg := range args {
			if arg == "run" {
				hasRun = true
				break
			}
		}
		if !hasRun {
			args = append([]string{"run"}, args...)
		}
		args = append(args, prompt)
	default:
		// Generic: assume prompt is last argument
		args = append(args, prompt)
	}

	// Create command with context for timeout
	timeoutCtx, cancel := context.WithTimeout(ctx, w.config.Timeout)
	defer cancel()

	cmd := exec.CommandContext(timeoutCtx, cmdParts[0], args...)

	// Set working directory
	if w.config.WorkingDir != "" {
		cmd.Dir = w.config.WorkingDir
	}

	// Set environment
	cmd.Env = os.Environ()
	cmd.Env = append(cmd.Env, w.config.Env...)

	// Capture output
	var stdout, stderr bytes.Buffer
	var logFile *os.File

	if w.config.LogPath != "" {
		var err error
		logFile, err = os.Create(w.config.LogPath)
		if err != nil {
			return nil, fmt.Errorf("creating log file: %w", err)
		}
		defer logFile.Close()
	}

	// Set up output handling
	if w.config.Quiet {
		if logFile != nil {
			cmd.Stdout = io.MultiWriter(&stdout, logFile)
			cmd.Stderr = io.MultiWriter(&stderr, logFile)
		} else {
			cmd.Stdout = &stdout
			cmd.Stderr = &stderr
		}
	} else {
		if logFile != nil {
			cmd.Stdout = io.MultiWriter(os.Stdout, &stdout, logFile)
			cmd.Stderr = io.MultiWriter(os.Stderr, &stderr, logFile)
		} else {
			cmd.Stdout = io.MultiWriter(os.Stdout, &stdout)
			cmd.Stderr = io.MultiWriter(os.Stderr, &stderr)
		}
	}

	// Start the process
	if err := cmd.Start(); err != nil {
		return &Result{
			Error:    fmt.Errorf("starting process: %w", err),
			Duration: time.Since(start),
		}, nil
	}

	// Set up health check monitoring
	var crashed bool
	var healthWg sync.WaitGroup
	healthDone := make(chan struct{})

	if w.config.HealthCheckInterval > 0 {
		healthWg.Add(1)
		go func() {
			defer healthWg.Done()
			w.monitorHealth(cmd.Process, healthDone, &crashed)
		}()
	}

	// Wait for completion
	err := cmd.Wait()
	close(healthDone)
	healthWg.Wait()

	duration := time.Since(start)
	output := stdout.String() + stderr.String()

	// Parse output
	result := ParseOutput(output)
	result.Duration = duration

	// Check for timeout
	if timeoutCtx.Err() == context.DeadlineExceeded {
		result.Timeout = true
		result.Error = fmt.Errorf("worker timed out after %v", w.config.Timeout)
		return result, nil
	}

	// Check for crash
	if crashed {
		result.Crashed = true
		result.Error = fmt.Errorf("worker process crashed unexpectedly")
		return result, nil
	}

	// Check exit code
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			result.ExitCode = exitErr.ExitCode()

			// Map exit codes to promises
			switch result.ExitCode {
			case 0:
				// Success
			case 32:
				result.Promise = PromiseBlocked
			case 33:
				result.Promise = PromiseAlreadyDone
			case 34:
				result.Promise = PromiseAbsorbedBy
			default:
				result.Error = fmt.Errorf("process exited with code %d", result.ExitCode)
			}
		} else {
			result.Error = err
		}
	}

	return result, nil
}

// monitorHealth periodically checks if the process is still running.
func (w *CLIWorker) monitorHealth(process *os.Process, done chan struct{}, crashed *bool) {
	ticker := time.NewTicker(w.config.HealthCheckInterval)
	defer ticker.Stop()

	for {
		select {
		case <-done:
			return
		case <-ticker.C:
			// Check if process is still running
			err := process.Signal(syscall.Signal(0))
			if err != nil {
				// Process is gone - could be normal exit or crash
				// The Wait() call will determine which
				return
			}
		}
	}
}

// ClaudeWorker is a specialized worker for Claude CLI.
type ClaudeWorker struct {
	*CLIWorker
	model                        string
	dangerouslySkipPermissions   bool
}

// NewClaudeWorker creates a Claude-specific worker.
func NewClaudeWorker(config *Config, model string, skipPermissions bool) *ClaudeWorker {
	// Build command
	cmd := "claude"
	if model != "" {
		cmd = fmt.Sprintf("claude --model %s", model)
	}
	config.Command = cmd

	return &ClaudeWorker{
		CLIWorker:                  NewCLIWorker(config),
		model:                      model,
		dangerouslySkipPermissions: skipPermissions,
	}
}

// OpenCodeWorker is a specialized worker for OpenCode CLI.
type OpenCodeWorker struct {
	*CLIWorker
	model  string
	server string
}

// NewOpenCodeWorker creates an OpenCode-specific worker.
func NewOpenCodeWorker(config *Config, model string, server string) *OpenCodeWorker {
	// Build command
	cmd := "opencode run"
	if model != "" {
		cmd = fmt.Sprintf("opencode run --model %s", model)
	}
	config.Command = cmd

	// Add server env if specified
	if server != "" {
		config.Env = append(config.Env, fmt.Sprintf("OPENCODE_SERVER=%s", server))
	}

	return &OpenCodeWorker{
		CLIWorker: NewCLIWorker(config),
		model:     model,
		server:    server,
	}
}

// WorkerFromConfig creates a worker from configuration strings.
func WorkerFromConfig(cmd string, tier state.WorkerTier, timeout time.Duration, workDir string) Worker {
	config := &Config{
		Command:             cmd,
		Tier:                tier,
		Timeout:             timeout,
		WorkingDir:          workDir,
		HealthCheckInterval: 5 * time.Second,
	}
	return NewCLIWorker(config)
}
