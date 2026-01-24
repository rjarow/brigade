package main

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/spf13/cobra"

	"brigade/internal/prd"
)

var analyzeCmd = &cobra.Command{
	Use:   "analyze <prd.json>",
	Short: "Show task analysis with complexity suggestions",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return cmdAnalyze(args[0])
	},
}

func cmdAnalyze(prdPath string) error {
	p, err := prd.Load(prdPath)
	if err != nil {
		return err
	}

	fmt.Printf("%sTask Analysis:%s\n\n", colorBold, colorReset)

	for i := range p.Tasks {
		task := &p.Tasks[i]
		suggested := suggestComplexity(task)
		complexity := string(task.Complexity)
		if complexity == "" {
			complexity = "auto"
		}

		fmt.Printf("  %s: %s\n", task.ID, task.Title)
		if complexity == "auto" {
			fmt.Printf("    %sCriteria: %d | Suggested: %s%s%s\n",
				colorDim, len(task.AcceptanceCriteria), colorCyan, suggested, colorReset)
		} else {
			fmt.Printf("    %sCriteria: %d | Assigned: %s%s%s\n",
				colorDim, len(task.AcceptanceCriteria), colorCyan, complexity, colorReset)
		}
	}

	fmt.Println()
	return nil
}

// suggestComplexity suggests a complexity level based on task title heuristics.
func suggestComplexity(task *prd.Task) string {
	title := strings.ToLower(task.Title)

	// Junior indicators
	juniorPatterns := []*regexp.Regexp{
		regexp.MustCompile(`test`),
		regexp.MustCompile(`boilerplate`),
		regexp.MustCompile(`add.*flag`),
		regexp.MustCompile(`simple`),
	}

	for _, pattern := range juniorPatterns {
		if pattern.MatchString(title) {
			return "line"
		}
	}

	// Few acceptance criteria suggests simpler task
	if len(task.AcceptanceCriteria) <= 3 {
		return "line"
	}

	// Default to senior (Sous Chef)
	return "sous"
}
