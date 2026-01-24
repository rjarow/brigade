package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"brigade/internal/config"
	"brigade/internal/orchestrator"
	"brigade/internal/prd"
)

var iterateCmd = &cobra.Command{
	Use:   "iterate <description>",
	Short: "Quick tweaks on a completed PRD",
	Long: `Makes quick tweaks on a completed PRD.

For substantial changes, use 'plan' instead.

Example:
  ./brigade-go iterate "make the button blue instead of green"`,
	Args: cobra.MinimumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load(cfgFile)
		if err != nil {
			return fmt.Errorf("loading config: %w", err)
		}
		description := strings.Join(args, " ")
		return cmdIterate(description, cfg)
	},
}

func cmdIterate(description string, cfg *config.Config) error {
	// Find most recently completed PRD
	parentPRD := findCompletedPRD()
	if parentPRD == "" {
		fmt.Printf("%sError: No completed PRD found%s\n\n", colorRed, colorReset)
		fmt.Printf("%sIteration mode requires a completed PRD to iterate on.%s\n", colorDim, colorReset)
		fmt.Printf("%sRun './brigade.sh service prd.json' first to complete a PRD.%s\n", colorDim, colorReset)
		return fmt.Errorf("no completed PRD found")
	}

	// Load parent PRD for context
	parentP, err := prd.Load(parentPRD)
	if err != nil {
		return err
	}

	fmt.Println()
	fmt.Printf("%s╔═══════════════════════════════════════════════════════════╗%s\n", colorCyan, colorReset)
	fmt.Printf("%s║  ITERATION MODE                                           ║%s\n", colorCyan, colorReset)
	fmt.Printf("%s╚═══════════════════════════════════════════════════════════╝%s\n\n", colorCyan, colorReset)

	fmt.Printf("%sParent PRD:%s %s\n", colorBold, colorReset, parentP.FeatureName)
	fmt.Printf("%s%s%s\n\n", colorDim, parentPRD, colorReset)
	fmt.Printf("%sTweak:%s %s\n\n", colorBold, colorReset, description)

	// Warn if this looks substantial
	if isSubstantialChange(description) {
		fmt.Printf("%s⚠ This description sounds substantial.%s\n", colorYellow, colorReset)
		fmt.Printf("%sIteration mode is for quick tweaks. For larger changes, consider:%s\n", colorDim, colorReset)
		fmt.Printf("%s  ./brigade.sh plan \"%s\"%s\n\n", colorDim, description, colorReset)

		if !confirmPrompt("Continue anyway? (y/N) ", false) {
			fmt.Printf("%sAborted.%s\n", colorDim, colorReset)
			return nil
		}
		fmt.Println()
	}

	// Generate iteration PRD
	timestamp := time.Now().Unix()
	parentPrefix := parentP.Prefix()
	iterPRDPath := fmt.Sprintf("brigade/tasks/prd-%s-iter-%d.json", parentPrefix, timestamp)

	// Create minimal iteration PRD
	iterPRD := prd.PRD{
		FeatureName: fmt.Sprintf("Iteration: %s", description),
		BranchName:  parentP.BranchName,
		Tasks: []prd.Task{
			{
				ID:                 "ITER-001",
				Title:              description,
				AcceptanceCriteria: []string{"Change implemented as described"},
				DependsOn:          []string{},
				Complexity:         prd.ComplexityJunior,
				Passes:             false,
			},
		},
	}

	data, err := json.MarshalIndent(iterPRD, "", "  ")
	if err != nil {
		return err
	}

	if err := os.WriteFile(iterPRDPath, data, 0644); err != nil {
		return err
	}

	fmt.Printf("%s✓%s Created iteration PRD: %s\n\n", colorGreen, colorReset, iterPRDPath)

	// Set parent context environment variable
	os.Setenv("ITERATION_PARENT_PRD", parentPRD)

	// Execute the iteration task using orchestrator
	orch, err := orchestrator.New(orchestrator.Options{
		Config:    cfg,
		PRDPath:   iterPRDPath,
		OnlyTasks: []string{"ITER-001"},
	})
	if err != nil {
		return err
	}

	if err := orch.Run(nil); err != nil {
		fmt.Println()
		fmt.Printf("%sIteration task did not complete successfully.%s\n", colorYellow, colorReset)
		fmt.Printf("%sPRD preserved: %s%s\n", colorDim, iterPRDPath, colorReset)
		fmt.Printf("%sResume with: ./brigade.sh resume %s%s\n", colorDim, iterPRDPath, colorReset)
		return err
	}

	fmt.Println()
	fmt.Printf("%s╔═══════════════════════════════════════════════════════════╗%s\n", colorGreen, colorReset)
	fmt.Printf("%s║  Iteration complete!                                      ║%s\n", colorGreen, colorReset)
	fmt.Printf("%s╚═══════════════════════════════════════════════════════════╝%s\n\n", colorGreen, colorReset)

	// Offer to clean up
	if confirmPrompt("Remove iteration PRD? (Y/n) ", true) {
		os.Remove(iterPRDPath)
		stateFile := strings.TrimSuffix(iterPRDPath, ".json") + ".state.json"
		os.Remove(stateFile)
		fmt.Printf("%s✓%s Cleaned up iteration files\n", colorGreen, colorReset)
	} else {
		fmt.Printf("%sKept: %s%s\n", colorDim, iterPRDPath, colorReset)
	}

	return nil
}

// findCompletedPRD finds the most recently completed PRD (all tasks pass, has state file).
func findCompletedPRD() string {
	pattern := "brigade/tasks/prd-*.state.json"
	stateFiles, err := filepath.Glob(pattern)
	if err != nil || len(stateFiles) == 0 {
		return ""
	}

	var latestPRD string
	var latestTime time.Time

	for _, stateFile := range stateFiles {
		// Get corresponding PRD file
		prdFile := strings.TrimSuffix(stateFile, ".state.json") + ".json"
		if _, err := os.Stat(prdFile); err != nil {
			continue
		}

		// Load PRD and check if all tasks are complete
		p, err := prd.Load(prdFile)
		if err != nil {
			continue
		}

		allComplete := true
		for _, task := range p.Tasks {
			if !task.Passes {
				allComplete = false
				break
			}
		}
		if !allComplete {
			continue
		}

		// Get modification time
		info, err := os.Stat(stateFile)
		if err != nil {
			continue
		}

		if info.ModTime().After(latestTime) {
			latestTime = info.ModTime()
			latestPRD = prdFile
		}
	}

	return latestPRD
}

// isSubstantialChange checks if the description sounds like a substantial change.
func isSubstantialChange(description string) bool {
	descLower := strings.ToLower(description)

	// Keywords that suggest substantial work
	substantialPatterns := []*regexp.Regexp{
		regexp.MustCompile(`add new`),
		regexp.MustCompile(`implement`),
		regexp.MustCompile(`create`),
		regexp.MustCompile(`refactor`),
		regexp.MustCompile(`rewrite`),
		regexp.MustCompile(`redesign`),
		regexp.MustCompile(`overhaul`),
		regexp.MustCompile(`migrate`),
		regexp.MustCompile(`integrate`),
	}

	for _, pattern := range substantialPatterns {
		if pattern.MatchString(descLower) {
			return true
		}
	}

	// Word count heuristic
	words := strings.Fields(description)
	if len(words) > 15 {
		return true
	}

	return false
}
