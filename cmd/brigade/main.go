// Package main provides the Brigade CLI entry point.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"brigade/internal/config"
	"brigade/internal/orchestrator"
	"brigade/internal/prd"
	"brigade/internal/state"
)

var (
	// Version is set at build time
	Version = "dev"

	// Global flags
	cfgFile      string
	dryRun       bool
	sequential   bool
	walkawayMode bool
	autoContinue bool

	// Partial execution flags
	onlyTasks  []string
	skipTasks  []string
	fromTask   string
	untilTask  string
)

func main() {
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

var rootCmd = &cobra.Command{
	Use:   "brigade",
	Short: "Multi-model AI orchestration framework",
	Long: `Brigade routes coding tasks to the right AI based on complexity.

It uses a kitchen metaphor:
  - Executive Chef (Opus): Plans PRDs, reviews work, handles escalations
  - Sous Chef (Sonnet): Complex tasks, architecture, security
  - Line Cooks (GLM): Routine tasks, tests, boilerplate

For more information: https://github.com/anthropics/brigade`,
	Version: Version,
}

func init() {
	// Global flags
	rootCmd.PersistentFlags().StringVar(&cfgFile, "config", "", "config file path")
	rootCmd.PersistentFlags().BoolVar(&dryRun, "dry-run", false, "preview execution without running")
	rootCmd.PersistentFlags().BoolVar(&sequential, "sequential", false, "force sequential execution")
	rootCmd.PersistentFlags().BoolVar(&walkawayMode, "walkaway", false, "autonomous execution mode")
	rootCmd.PersistentFlags().BoolVar(&autoContinue, "auto-continue", false, "chain multiple PRDs")

	// Partial execution flags
	rootCmd.PersistentFlags().StringSliceVar(&onlyTasks, "only", nil, "run specific tasks only")
	rootCmd.PersistentFlags().StringSliceVar(&skipTasks, "skip", nil, "skip specific tasks")
	rootCmd.PersistentFlags().StringVar(&fromTask, "from", "", "start from task (inclusive)")
	rootCmd.PersistentFlags().StringVar(&untilTask, "until", "", "run until task (inclusive)")

	// Add commands
	rootCmd.AddCommand(serviceCmd)
	rootCmd.AddCommand(validateCmd)
	rootCmd.AddCommand(statusCmd)
	rootCmd.AddCommand(summaryCmd)
	rootCmd.AddCommand(resumeCmd)
	rootCmd.AddCommand(ticketCmd)
	rootCmd.AddCommand(costCmd)
	rootCmd.AddCommand(riskCmd)
}

// serviceCmd runs the Brigade service.
var serviceCmd = &cobra.Command{
	Use:   "service <prd.json>",
	Short: "Execute all tasks in a PRD",
	Args:  cobra.MinimumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load(cfgFile)
		if err != nil {
			return fmt.Errorf("loading config: %w", err)
		}

		// Apply flag overrides
		if sequential {
			cfg.MaxParallel = 0
		}
		if walkawayMode {
			cfg.WalkawayMode = true
		}

		// Set up logger
		logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
			Level: slog.LevelInfo,
		}))

		for _, prdPath := range args {
			fmt.Printf("Processing %s...\n", prdPath)

			if dryRun {
				return previewExecution(prdPath, cfg)
			}

			orch, err := orchestrator.New(orchestrator.Options{
				Config:        cfg,
				PRDPath:       prdPath,
				Logger:        logger,
				DryRun:        dryRun,
				Sequential:    sequential,
				WalkawayMode:  walkawayMode,
				OnlyTasks:     onlyTasks,
				SkipTasks:     skipTasks,
				FromTask:      fromTask,
				UntilTask:     untilTask,
			})
			if err != nil {
				return err
			}

			if err := orch.Run(context.Background()); err != nil {
				return err
			}

			if !autoContinue {
				break
			}
		}

		return nil
	},
}

// validateCmd validates a PRD file.
var validateCmd = &cobra.Command{
	Use:   "validate <prd.json>",
	Short: "Validate PRD structure",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		p, err := prd.Load(args[0])
		if err != nil {
			return err
		}

		cfg, _ := config.Load(cfgFile)
		opts := prd.ValidationOptions{
			LintCriteria:           cfg.CriteriaLintEnabled,
			CheckVerificationTypes: true,
			WarnGrepOnly:           cfg.VerificationWarnGrepOnly,
			WalkawayMode:           cfg.WalkawayMode,
		}

		result := p.ValidateFull(opts)

		// Print errors
		if len(result.Errors) > 0 {
			fmt.Println("Errors:")
			for _, e := range result.Errors {
				fmt.Printf("  ✗ %s\n", e)
			}
		}

		// Print warnings
		if len(result.Warnings) > 0 {
			fmt.Println("Warnings:")
			for _, w := range result.Warnings {
				fmt.Printf("  ⚠ %s\n", w)
			}
		}

		if result.IsValid() {
			fmt.Printf("✓ PRD is valid: %d tasks\n", len(p.Tasks))
			return nil
		}

		return fmt.Errorf("validation failed with %d errors", len(result.Errors))
	},
}

// statusCmd shows execution status.
var statusCmd = &cobra.Command{
	Use:   "status [prd.json]",
	Short: "Show execution status",
	RunE: func(cmd *cobra.Command, args []string) error {
		jsonOutput, _ := cmd.Flags().GetBool("json")
		briefOutput, _ := cmd.Flags().GetBool("brief")
		watchMode, _ := cmd.Flags().GetBool("watch")

		// Find PRD if not specified
		var prdPath string
		if len(args) > 0 {
			prdPath = args[0]
		} else {
			// Auto-detect from current directory
			prdPath = findActivePRD()
			if prdPath == "" {
				return fmt.Errorf("no PRD specified and none found in brigade/tasks/")
			}
		}

		for {
			status, err := getStatus(prdPath)
			if err != nil {
				return err
			}

			if jsonOutput || briefOutput {
				if briefOutput {
					fmt.Println(status.Brief())
				} else {
					fmt.Println(status.JSON())
				}
			} else {
				fmt.Print(status.Format())
			}

			if !watchMode {
				break
			}

			cfg, _ := config.Load(cfgFile)
			time.Sleep(cfg.StatusWatchInterval)
			fmt.Print("\033[H\033[2J") // Clear screen
		}

		return nil
	},
}

func init() {
	statusCmd.Flags().Bool("json", false, "output as JSON")
	statusCmd.Flags().Bool("brief", false, "ultra-compact JSON")
	statusCmd.Flags().BoolP("watch", "w", false, "auto-refresh")
	statusCmd.Flags().Bool("all", false, "show all escalations")
}

// summaryCmd generates a summary report.
var summaryCmd = &cobra.Command{
	Use:   "summary <prd.json>",
	Short: "Generate summary report from state",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		p, err := prd.Load(args[0])
		if err != nil {
			return err
		}

		store := state.ForPRD(args[0])
		st, err := store.Load()
		if err != nil {
			return err
		}

		fmt.Println(generateSummary(p, st))
		return nil
	},
}

// resumeCmd resumes interrupted execution.
var resumeCmd = &cobra.Command{
	Use:   "resume [prd.json] [retry|skip]",
	Short: "Resume after interruption",
	RunE: func(cmd *cobra.Command, args []string) error {
		var prdPath string
		var action string

		if len(args) > 0 {
			prdPath = args[0]
		} else {
			prdPath = findActivePRD()
		}

		if prdPath == "" {
			return fmt.Errorf("no PRD specified and none found")
		}

		if len(args) > 1 {
			action = args[1]
		}

		cfg, err := config.Load(cfgFile)
		if err != nil {
			return err
		}

		logger := slog.New(slog.NewTextHandler(os.Stderr, nil))

		// Check for stuck task
		store := state.ForPRD(prdPath)
		st, err := store.Load()
		if err != nil {
			return err
		}

		if st.CurrentTask != "" && action == "" {
			fmt.Printf("Task %s was in progress. Use 'retry' or 'skip' to continue.\n", st.CurrentTask)
			return nil
		}

		if action == "skip" && st.CurrentTask != "" {
			// Mark current task as skipped
			st.AddTaskHistory(state.TaskHistory{
				TaskID: st.CurrentTask,
				Worker: state.TierLine,
				Status: state.StatusSkipped,
			})
			st.ClearCurrentTask()
			if err := store.Save(st); err != nil {
				return err
			}
		}

		orch, err := orchestrator.New(orchestrator.Options{
			Config:  cfg,
			PRDPath: prdPath,
			Logger:  logger,
		})
		if err != nil {
			return err
		}

		return orch.Run(context.Background())
	},
}

// ticketCmd runs a single task.
var ticketCmd = &cobra.Command{
	Use:   "ticket <prd.json> <task-id>",
	Short: "Run a single task",
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load(cfgFile)
		if err != nil {
			return err
		}

		logger := slog.New(slog.NewTextHandler(os.Stderr, nil))

		orch, err := orchestrator.New(orchestrator.Options{
			Config:    cfg,
			PRDPath:   args[0],
			Logger:    logger,
			OnlyTasks: []string{args[1]},
		})
		if err != nil {
			return err
		}

		return orch.Run(context.Background())
	},
}

// costCmd shows cost estimation.
var costCmd = &cobra.Command{
	Use:   "cost <prd.json>",
	Short: "Show estimated cost breakdown",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		p, err := prd.Load(args[0])
		if err != nil {
			return err
		}

		cfg, _ := config.Load(cfgFile)
		fmt.Println(estimateCost(p, cfg))
		return nil
	},
}

// riskCmd performs risk assessment.
var riskCmd = &cobra.Command{
	Use:   "risk <prd.json>",
	Short: "Risk assessment",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		p, err := prd.Load(args[0])
		if err != nil {
			return err
		}

		cfg, _ := config.Load(cfgFile)
		history, _ := cmd.Flags().GetBool("history")
		fmt.Println(assessRisk(p, cfg, history))
		return nil
	},
}

func init() {
	riskCmd.Flags().Bool("history", false, "include historical patterns")
}

// Helper functions

func previewExecution(prdPath string, cfg *config.Config) error {
	p, err := prd.Load(prdPath)
	if err != nil {
		return err
	}

	fmt.Printf("=== DRY RUN: %s ===\n\n", p.FeatureName)
	fmt.Printf("Branch: %s\n", p.BranchName)
	fmt.Printf("Tasks: %d\n\n", len(p.Tasks))

	order, err := p.TopologicalOrder()
	if err != nil {
		return fmt.Errorf("dependency error: %w", err)
	}

	for i, taskID := range order {
		task := p.TaskByID(taskID)
		tier := "line"
		if task.Complexity == prd.ComplexitySenior {
			tier = "sous"
		}
		fmt.Printf("%d. [%s] %s: %s\n", i+1, tier, task.ID, task.Title)
	}

	return nil
}

func findActivePRD() string {
	// Look for PRDs in brigade/tasks/
	// Find one with active state
	// For now, just return empty
	return ""
}

type statusInfo struct {
	PRD       string
	Done      int
	Total     int
	Current   string
	Worker    string
	Elapsed   time.Duration
	Tasks     []taskStatus
}

type taskStatus struct {
	ID      string
	Title   string
	Status  string
	Marker  string
}

func getStatus(prdPath string) (*statusInfo, error) {
	p, err := prd.Load(prdPath)
	if err != nil {
		return nil, err
	}

	store := state.ForPRD(prdPath)
	st, err := store.Load()
	if err != nil {
		return nil, err
	}

	completed := st.CompletedTaskIDs()
	done := len(completed)

	info := &statusInfo{
		PRD:     p.Prefix(),
		Done:    done,
		Total:   len(p.Tasks),
		Current: st.CurrentTask,
	}

	for _, task := range p.Tasks {
		ts := taskStatus{
			ID:    task.ID,
			Title: task.Title,
		}

		if completed[task.ID] {
			ts.Status = "complete"
			ts.Marker = "✓"
		} else if task.ID == st.CurrentTask {
			ts.Status = "in_progress"
			ts.Marker = "→"
		} else if st.WasEscalated(task.ID) {
			ts.Status = "escalated"
			ts.Marker = "⬆"
		} else {
			ts.Status = "pending"
			ts.Marker = "○"
		}

		info.Tasks = append(info.Tasks, ts)
	}

	return info, nil
}

func (s *statusInfo) Format() string {
	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("=== %s: %d/%d tasks ===\n\n", s.PRD, s.Done, s.Total))

	for _, t := range s.Tasks {
		sb.WriteString(fmt.Sprintf("%s %s: %s\n", t.Marker, t.ID, t.Title))
	}

	return sb.String()
}

func (s *statusInfo) JSON() string {
	data, _ := json.MarshalIndent(s, "", "  ")
	return string(data)
}

func (s *statusInfo) Brief() string {
	data, _ := json.Marshal(map[string]interface{}{
		"done":    s.Done,
		"total":   s.Total,
		"current": s.Current,
		"worker":  s.Worker,
	})
	return string(data)
}

func generateSummary(p *prd.PRD, st *state.State) string {
	var sb strings.Builder

	sb.WriteString(fmt.Sprintf("# Summary: %s\n\n", p.FeatureName))

	completed := st.CompletedTaskIDs()
	sb.WriteString(fmt.Sprintf("**Progress:** %d/%d tasks complete\n\n", len(completed), len(p.Tasks)))

	// Escalations
	if len(st.Escalations) > 0 {
		sb.WriteString("## Escalations\n\n")
		for _, e := range st.Escalations {
			sb.WriteString(fmt.Sprintf("- %s: %s → %s (%s)\n", e.TaskID, e.From, e.To, e.Reason))
		}
		sb.WriteString("\n")
	}

	// Task history
	sb.WriteString("## Task History\n\n")
	for _, task := range p.Tasks {
		status := "○"
		if completed[task.ID] {
			status = "✓"
		}
		sb.WriteString(fmt.Sprintf("%s %s: %s\n", status, task.ID, task.Title))
	}

	return sb.String()
}

func estimateCost(p *prd.PRD, cfg *config.Config) string {
	var sb strings.Builder
	var totalCost float64

	sb.WriteString(fmt.Sprintf("=== Cost Estimate: %s ===\n\n", p.FeatureName))

	juniorCount := 0
	seniorCount := 0

	for _, task := range p.Tasks {
		switch task.Complexity {
		case prd.ComplexityJunior:
			juniorCount++
		case prd.ComplexitySenior:
			seniorCount++
		default:
			juniorCount++ // Default to junior
		}
	}

	// Estimate 5 min per junior, 15 min per senior
	juniorMinutes := juniorCount * 5
	seniorMinutes := seniorCount * 15

	juniorCost := float64(juniorMinutes) * cfg.CostRateLine
	seniorCost := float64(seniorMinutes) * cfg.CostRateSous
	totalCost = juniorCost + seniorCost

	sb.WriteString(fmt.Sprintf("Junior tasks: %d × ~5min @ $%.2f/min = $%.2f\n", juniorCount, cfg.CostRateLine, juniorCost))
	sb.WriteString(fmt.Sprintf("Senior tasks: %d × ~15min @ $%.2f/min = $%.2f\n", seniorCount, cfg.CostRateSous, seniorCost))
	sb.WriteString(fmt.Sprintf("\nEstimated total: $%.2f\n", totalCost))

	if cfg.CostWarnThreshold > 0 && totalCost > cfg.CostWarnThreshold {
		sb.WriteString(fmt.Sprintf("\n⚠️ Warning: Exceeds threshold of $%.2f\n", cfg.CostWarnThreshold))
	}

	return sb.String()
}

func assessRisk(p *prd.PRD, cfg *config.Config, includeHistory bool) string {
	var sb strings.Builder
	var riskScore int

	sb.WriteString(fmt.Sprintf("=== Risk Assessment: %s ===\n\n", p.FeatureName))

	// Check for issues
	issues := []string{}

	// Many tasks
	if len(p.Tasks) > 15 {
		issues = append(issues, fmt.Sprintf("Large PRD (%d tasks)", len(p.Tasks)))
		riskScore += 3
	}

	// Check for complex dependency chains
	if p.HasCircularDependency() {
		issues = append(issues, "Circular dependencies detected")
		riskScore += 10
	}

	// Check verification coverage
	tasksMissingVerification := 0
	for _, task := range p.Tasks {
		if len(task.Verification) == 0 {
			tasksMissingVerification++
		}
	}
	if tasksMissingVerification > 0 {
		issues = append(issues, fmt.Sprintf("%d tasks missing verification", tasksMissingVerification))
		riskScore += tasksMissingVerification
	}

	// Risk level
	var level string
	switch {
	case riskScore >= 21:
		level = "CRITICAL"
	case riskScore >= 13:
		level = "HIGH"
	case riskScore >= 6:
		level = "MEDIUM"
	default:
		level = "LOW"
	}

	sb.WriteString(fmt.Sprintf("Risk Level: %s (score: %d)\n\n", level, riskScore))

	if len(issues) > 0 {
		sb.WriteString("Issues:\n")
		for _, issue := range issues {
			sb.WriteString(fmt.Sprintf("  - %s\n", issue))
		}
	} else {
		sb.WriteString("No significant risks identified.\n")
	}

	return sb.String()
}
