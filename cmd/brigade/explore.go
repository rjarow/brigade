package main

import (
	"context"
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"brigade/internal/config"
	"brigade/internal/state"
	"brigade/internal/util"
	"brigade/internal/worker"
)

var exploreCmd = &cobra.Command{
	Use:   "explore <question>",
	Short: "Research questions about the codebase",
	Long: `Invokes the researcher to explore a question about the codebase.

Example:
  ./brigade-go explore "could we add real-time sync with websockets?"`,
	Args: cobra.MinimumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load(cfgFile)
		if err != nil {
			return fmt.Errorf("loading config: %w", err)
		}
		question := strings.Join(args, " ")
		return cmdExplore(question, cfg)
	},
}

func cmdExplore(question string, cfg *config.Config) error {
	// Ensure explorations directory exists
	if err := os.MkdirAll("brigade/explorations", 0755); err != nil {
		return err
	}

	// Generate filename from question
	datePrefix := time.Now().Format("2006-01-02")
	slug := util.Slugify(question, 40)
	outputPath := fmt.Sprintf("brigade/explorations/%s-%s.md", datePrefix, slug)

	fmt.Println()
	fmt.Printf("%s═══════════════════════════════════════════════════════════%s\n", colorCyan, colorReset)
	fmt.Printf("EXPLORATION: %s\n", question)
	fmt.Printf("%s═══════════════════════════════════════════════════════════%s\n\n", colorCyan, colorReset)

	// Build exploration prompt
	var promptBuilder strings.Builder

	// Load researcher prompt if available
	researcherPrompts := []string{
		"brigade/chef/researcher.md",
		"chef/researcher.md",
	}
	for _, rp := range researcherPrompts {
		if content, err := os.ReadFile(rp); err == nil {
			promptBuilder.Write(content)
			promptBuilder.WriteString("\n\n---\n")
			break
		}
	}

	// Include codebase map if available
	if content, err := os.ReadFile("brigade/codebase-map.md"); err == nil {
		promptBuilder.WriteString("CODEBASE CONTEXT\n\n")
		promptBuilder.Write(content)
		promptBuilder.WriteString("\n\n---\n")
	} else {
		fmt.Printf("%sTip: Run './brigade.sh map' first to include codebase context in exploration.%s\n\n", colorDim, colorReset)
	}

	// Add exploration request
	promptBuilder.WriteString(fmt.Sprintf(`EXPLORATION REQUEST

Question: %s
Output File: %s
Date: %s

Research this question and save your findings to the output file.
When complete, output: <exploration_complete>%s</exploration_complete>

BEGIN RESEARCH:`, question, outputPath, time.Now().Format("2006-01-02"), outputPath))

	prompt := promptBuilder.String()

	fmt.Printf("%sInvoking Researcher (Executive model)...%s\n\n", colorDim, colorReset)

	start := time.Now()

	// Create worker for Executive Chef (researcher uses same model)
	workerCfg := &worker.Config{
		Command:    cfg.ExecutiveCmd,
		Tier:       state.TierExecutive,
		Timeout:    cfg.TaskTimeoutExecutive,
		WorkingDir: "",
		Quiet:      false,
	}
	exec := worker.NewCLIWorker(workerCfg)

	// Execute
	result, err := exec.Execute(context.Background(), prompt)
	if err != nil {
		return fmt.Errorf("executing explore: %w", err)
	}

	duration := time.Since(start)
	fmt.Printf("\n%sDuration: %ds%s\n", colorDim, int(duration.Seconds()), colorReset)

	// Check for completion signal
	resultFile := ""
	if result.Output != "" {
		re := regexp.MustCompile(`<exploration_complete>([^<]+)</exploration_complete>`)
		if matches := re.FindStringSubmatch(result.Output); len(matches) > 1 {
			resultFile = strings.TrimSpace(matches[1])
		}
	}

	if resultFile != "" && fileExists(resultFile) {
		fmt.Println()
		fmt.Printf("%s╔═══════════════════════════════════════════════════════════╗%s\n", colorGreen, colorReset)
		fmt.Printf("%s║  EXPLORATION COMPLETE: %s%s\n", colorGreen, resultFile, colorReset)
		fmt.Printf("%s╚═══════════════════════════════════════════════════════════╝%s\n\n", colorGreen, colorReset)

		fmt.Printf("%sNext steps:%s\n", colorBold, colorReset)
		fmt.Printf("  View report:    %scat %s%s\n", colorCyan, resultFile, colorReset)
		fmt.Printf("  Plan feature:   %s./brigade.sh plan \"[feature description]\"%s\n", colorCyan, colorReset)
	} else if fileExists(outputPath) {
		// File exists but no signal
		fmt.Println()
		fmt.Printf("%s╔═══════════════════════════════════════════════════════════╗%s\n", colorGreen, colorReset)
		fmt.Printf("%s║  EXPLORATION COMPLETE: %s%s\n", colorGreen, outputPath, colorReset)
		fmt.Printf("%s╚═══════════════════════════════════════════════════════════╝%s\n\n", colorGreen, colorReset)

		fmt.Printf("%sNext steps:%s\n", colorBold, colorReset)
		fmt.Printf("  View report:    %scat %s%s\n", colorCyan, outputPath, colorReset)
		fmt.Printf("  Plan feature:   %s./brigade.sh plan \"[feature description]\"%s\n", colorCyan, colorReset)
	} else {
		fmt.Println()
		fmt.Printf("%sExploration output:%s\n", colorYellow, colorReset)
		fmt.Printf("%s(No output file generated - see above for results)%s\n", colorDim, colorReset)
	}

	return nil
}
