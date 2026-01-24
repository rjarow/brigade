package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"brigade/internal/config"
	"brigade/internal/state"
	"brigade/internal/util"
	"brigade/internal/worker"
)

var mapCmd = &cobra.Command{
	Use:   "map [output-file]",
	Short: "Generate codebase analysis markdown",
	Long: `Analyzes the codebase and generates a markdown map.

The map is auto-included in future planning sessions.
Default output: brigade/codebase-map.md`,
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load(cfgFile)
		if err != nil {
			return fmt.Errorf("loading config: %w", err)
		}

		outputPath := "brigade/codebase-map.md"
		if len(args) > 0 {
			outputPath = args[0]
		}

		return cmdMap(outputPath, cfg)
	},
}

func cmdMap(outputPath string, cfg *config.Config) error {
	fmt.Printf("%sGenerating codebase map...%s\n\n", colorBold, colorReset)

	// Ensure output directory exists
	if err := os.MkdirAll(filepath.Dir(outputPath), 0755); err != nil {
		return err
	}

	prompt := `Analyze this codebase and generate a comprehensive codebase map in markdown format.

Include the following sections:

## Tech Stack
- Languages and versions
- Frameworks and libraries
- Build tools

## Architecture
- High-level architecture pattern (MVC, microservices, monolith, etc.)
- Key directories and their purposes
- Entry points

## Conventions
- Naming conventions (files, functions, variables)
- Code organization patterns
- Import/export patterns

## Testing
- Test framework(s) used
- Test file locations and naming
- How to run tests

## Configuration
- Config file locations
- Environment variables used
- Build/deploy configuration

## Technical Debt
- Areas that could use improvement
- Outdated patterns or dependencies
- Missing tests or documentation

Be specific and reference actual files/directories in the codebase.
Output the result as markdown that can be saved to a file.`

	fmt.Printf("%sRunning Executive Chef analysis...%s\n\n", colorDim, colorReset)

	start := time.Now()

	// Create worker for Executive Chef
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
		return fmt.Errorf("executing map: %w", err)
	}

	duration := time.Since(start)

	// Extract markdown content (starts with #)
	var mapContent string
	lines := strings.Split(result.Output, "\n")
	inMarkdown := false
	var mdLines []string

	for _, line := range lines {
		if strings.HasPrefix(line, "#") {
			inMarkdown = true
		}
		if inMarkdown {
			mdLines = append(mdLines, line)
		}
	}

	if len(mdLines) > 0 {
		mapContent = strings.Join(mdLines, "\n")
	} else {
		mapContent = result.Output
	}

	// Embed commit hash for staleness tracking
	commitHash := util.GetHeadCommit()
	mapContent = fmt.Sprintf("%s\n\n<!-- Generated at commit: %s -->\n", strings.TrimSpace(mapContent), commitHash)

	// Write output
	if err := os.WriteFile(outputPath, []byte(mapContent), 0644); err != nil {
		return err
	}

	fmt.Println()
	fmt.Printf("%s╔═══════════════════════════════════════════════════════════╗%s\n", colorGreen, colorReset)
	fmt.Printf("%s║  Codebase map generated: %s%s\n", colorGreen, outputPath, colorReset)
	fmt.Printf("%s╚═══════════════════════════════════════════════════════════╝%s\n\n", colorGreen, colorReset)

	fmt.Printf("%sDuration: %ds%s\n", colorDim, int(duration.Seconds()), colorReset)
	fmt.Printf("%sThis map will be auto-included in future planning sessions.%s\n", colorDim, colorReset)

	return nil
}

// extractMarkdownFromOutput extracts markdown content from worker output.
func extractMarkdownFromOutput(output string) string {
	// Look for content starting with # or ##
	re := regexp.MustCompile(`(?m)^#.*`)
	if loc := re.FindStringIndex(output); loc != nil {
		return output[loc[0]:]
	}
	return output
}
