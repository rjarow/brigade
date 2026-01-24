package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"brigade/internal/config"
	"brigade/internal/prd"
)

var demoCmd = &cobra.Command{
	Use:   "demo",
	Short: "Shows what Brigade does without executing",
	Long:  `Demonstrates Brigade's capabilities using a demo PRD in dry-run mode.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load(cfgFile)
		if err != nil {
			// Config is optional for demo
			cfg = config.Default()
		}
		return cmdDemo(cfg)
	},
}

func cmdDemo(cfg *config.Config) error {
	fmt.Println()
	fmt.Printf("%sBrigade Kitchen Demo%s\n\n", colorBold, colorReset)
	fmt.Println("Let's see how Brigade would cook up a feature!")
	fmt.Println()

	// Find or create demo PRD
	examplePRD := findExamplePRD()
	if examplePRD == "" {
		fmt.Printf("%sDemo PRD not found.%s\n\n", colorYellow, colorReset)
		fmt.Println("Let's create a simple one for the demo...")
		fmt.Println()

		var err error
		examplePRD, err = createDemoPRD()
		if err != nil {
			return err
		}
		fmt.Printf("%s✓%s Created demo PRD: %s\n\n", colorGreen, colorReset, examplePRD)
	}

	// Load PRD
	p, err := prd.Load(examplePRD)
	if err != nil {
		return err
	}

	// Display menu
	fmt.Printf("%s╔═══════════════════════════════════════════════════════════╗%s\n", colorCyan, colorReset)
	fmt.Printf("%s║  Demo: %s%s\n", colorCyan, p.FeatureName, colorReset)
	fmt.Printf("%s╚═══════════════════════════════════════════════════════════╝%s\n\n", colorCyan, colorReset)

	fmt.Printf("%sTonight's menu:%s %d dishes\n\n", colorBold, colorReset, len(p.Tasks))

	// Show tasks with chef assignments
	for _, task := range p.Tasks {
		chefEmoji := "🔪"
		chefName := "Line Cook"
		if task.Complexity == prd.ComplexitySenior {
			chefEmoji = "👨‍🍳"
			chefName = "Sous Chef"
		}
		fmt.Printf("  %s %s: %s %s(%s)%s\n", chefEmoji, task.ID, task.Title, colorDim, chefName, colorReset)
	}

	fmt.Println()
	fmt.Printf("%sHow it works:%s\n\n", colorBold, colorReset)
	fmt.Println("  1. 🔪 Line Cook handles simple tasks (tests, CRUD, boilerplate)")
	fmt.Println("  2. 👨‍🍳 Sous Chef handles complex tasks (architecture, security)")
	fmt.Println("  3. 👔 Executive Chef reviews work and handles escalations")
	fmt.Println()
	fmt.Println("  If a chef struggles, the task escalates to a more senior chef.")
	fmt.Println()

	fmt.Printf("%sRunning in dry-run mode...%s\n\n", colorBold, colorReset)

	// Run dry-run
	if err := previewExecution(examplePRD, cfg); err != nil {
		return err
	}

	fmt.Println()
	fmt.Printf("%s╔═══════════════════════════════════════════════════════════╗%s\n", colorGreen, colorReset)
	fmt.Printf("%s║                   Demo Complete!                          ║%s\n", colorGreen, colorReset)
	fmt.Printf("%s╚═══════════════════════════════════════════════════════════╝%s\n\n", colorGreen, colorReset)

	fmt.Println("Ready to cook for real? Try:")
	fmt.Println()
	fmt.Printf("  Plan a feature:  %s./brigade.sh plan \"your feature idea\"%s\n", colorCyan, colorReset)
	fmt.Printf("  Run the example: %s./brigade.sh service %s%s\n", colorCyan, examplePRD, colorReset)
	fmt.Println()

	return nil
}

func findExamplePRD() string {
	locations := []string{
		"examples/prd-example.json",
		"brigade/examples/prd-example.json",
	}
	for _, loc := range locations {
		if _, err := os.Stat(loc); err == nil {
			return loc
		}
	}
	return ""
}

func createDemoPRD() (string, error) {
	prdPath := "brigade/tasks/prd-demo.json"

	// Ensure directory exists
	if err := os.MkdirAll(filepath.Dir(prdPath), 0755); err != nil {
		return "", err
	}

	demoPRD := prd.PRD{
		FeatureName: "Hello World Demo",
		BranchName:  "demo/hello-world",
		Tasks: []prd.Task{
			{
				ID:                 "US-001",
				Title:              "Create greeting function",
				AcceptanceCriteria: []string{"Function returns 'Hello, World!'"},
				DependsOn:          []string{},
				Complexity:         prd.ComplexityJunior,
				Passes:             false,
			},
			{
				ID:                 "US-002",
				Title:              "Add tests for greeting",
				AcceptanceCriteria: []string{"Test verifies greeting output"},
				DependsOn:          []string{"US-001"},
				Complexity:         prd.ComplexityJunior,
				Passes:             false,
			},
		},
	}

	data, err := json.MarshalIndent(demoPRD, "", "  ")
	if err != nil {
		return "", err
	}

	if err := os.WriteFile(prdPath, data, 0644); err != nil {
		return "", err
	}

	return prdPath, nil
}
