package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"brigade/internal/util"
)

var initCmd = &cobra.Command{
	Use:   "init",
	Short: "Interactive setup wizard",
	Long:  `Prepares a project for Brigade by creating configuration and directories.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		return cmdInit()
	},
}

func cmdInit() error {
	fmt.Println()
	fmt.Printf("%sWelcome to Brigade Kitchen Setup!%s\n\n", colorBold, colorReset)
	fmt.Println("Let's get your kitchen ready for cooking.")
	fmt.Println()

	// Step 1: Check for AI tools
	fmt.Printf("%sStep 1: Checking for AI tools...%s\n", colorBold, colorReset)
	claudeFound := util.CommandExists("claude")
	opencodeFound := util.CommandExists("opencode")

	if claudeFound {
		fmt.Printf("  %s✓%s Claude CLI found\n", colorGreen, colorReset)
	} else {
		fmt.Printf("  %s○%s Claude CLI not found\n", colorYellow, colorReset)
	}

	if opencodeFound {
		fmt.Printf("  %s✓%s OpenCode CLI found\n", colorGreen, colorReset)
	} else {
		fmt.Printf("  %s○%s OpenCode CLI not found (optional - for cost savings)\n", colorDim, colorReset)
	}

	fmt.Println()

	if !claudeFound && !opencodeFound {
		fmt.Printf("%sNo AI tools found!%s\n\n", colorRed, colorReset)
		fmt.Println("Brigade needs at least one AI CLI tool to work.")
		fmt.Println()
		fmt.Println("Install Claude CLI:")
		fmt.Printf("  %snpm install -g @anthropic-ai/claude-code%s\n\n", colorCyan, colorReset)
		fmt.Println("Or OpenCode:")
		fmt.Printf("  %sgo install github.com/sst/opencode@latest%s\n", colorCyan, colorReset)
		fmt.Println()
		return fmt.Errorf("no AI tools found")
	}

	// Step 2: Create config file
	fmt.Printf("%sStep 2: Creating configuration...%s\n", colorBold, colorReset)

	configPath := "brigade/brigade.config"
	// If we can find where brigade.sh is, use that directory
	if scriptDir := findBrigadeScriptDir(); scriptDir != "" {
		configPath = filepath.Join(scriptDir, "brigade.config")
	}

	if _, err := os.Stat(configPath); err == nil {
		fmt.Printf("  %s!%s brigade.config already exists\n", colorYellow, colorReset)
		if !confirmPrompt("  Overwrite? (y/N) ", false) {
			fmt.Printf("  %sKeeping existing config.%s\n", colorDim, colorReset)
		} else {
			if err := createDefaultConfig(configPath); err != nil {
				return err
			}
		}
	} else {
		if err := createDefaultConfig(configPath); err != nil {
			return err
		}
	}

	// Step 3: Create directories
	fmt.Println()
	fmt.Printf("%sStep 3: Setting up directories...%s\n", colorBold, colorReset)

	dirs := []string{"brigade/tasks", "brigade/notes", "brigade/logs"}
	for _, dir := range dirs {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return fmt.Errorf("creating %s: %w", dir, err)
		}
		fmt.Printf("  %s✓%s Created %s/\n", colorGreen, colorReset, dir)
	}

	// Step 4: Check/update .gitignore
	fmt.Println()
	fmt.Printf("%sStep 4: Checking .gitignore...%s\n", colorBold, colorReset)

	if err := updateGitignore(); err != nil {
		return err
	}

	// Final message
	fmt.Println()
	fmt.Printf("%s╔═══════════════════════════════════════════════════════════╗%s\n", colorGreen, colorReset)
	fmt.Printf("%s║              Kitchen is ready to cook!                    ║%s\n", colorGreen, colorReset)
	fmt.Printf("%s╚═══════════════════════════════════════════════════════════╝%s\n", colorGreen, colorReset)
	fmt.Println()
	fmt.Println("Next steps:")
	fmt.Println()
	fmt.Printf("  Try a demo:     %s./brigade.sh demo%s\n", colorCyan, colorReset)
	fmt.Printf("  Plan a feature: %s./brigade.sh plan \"Add user login\"%s\n", colorCyan, colorReset)
	fmt.Println()

	return nil
}

func findBrigadeScriptDir() string {
	// Try to find brigade.sh in common locations
	locations := []string{
		"brigade/brigade.sh",
		"brigade.sh",
	}
	for _, loc := range locations {
		if _, err := os.Stat(loc); err == nil {
			return filepath.Dir(loc)
		}
	}
	return ""
}

func createDefaultConfig(path string) error {
	// Ensure directory exists
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}

	content := `# Brigade Kitchen Configuration
# See brigade.config.example for all options

# Quiet mode: suppress worker conversation output
QUIET_WORKERS=false

# Executive review: have Opus review completed work
REVIEW_ENABLED=true

# Escalation: promote tasks to higher tiers on failure
ESCALATION_ENABLED=true
ESCALATION_AFTER=3
`
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		return err
	}
	fmt.Printf("  %s✓%s Created brigade.config\n", colorGreen, colorReset)
	return nil
}

func updateGitignore() error {
	gitignorePath := ".gitignore"

	// Check if .gitignore exists
	content, err := os.ReadFile(gitignorePath)
	if err != nil {
		if os.IsNotExist(err) {
			// No .gitignore exists
			fmt.Printf("  %s!%s No .gitignore found\n", colorYellow, colorReset)
			fmt.Println()
			if confirmPrompt("  Create .gitignore with brigade/? (Y/n) ", true) {
				newContent := "# Brigade working directory\nbrigade/\n"
				if err := os.WriteFile(gitignorePath, []byte(newContent), 0644); err != nil {
					return err
				}
				fmt.Printf("  %s✓%s Created .gitignore with brigade/\n", colorGreen, colorReset)
			} else {
				fmt.Printf("  %s!%s Skipped. Remember to add manually:\n", colorYellow, colorReset)
				fmt.Printf("      %secho 'brigade/' >> .gitignore%s\n", colorCyan, colorReset)
			}
			return nil
		}
		return err
	}

	// Check if brigade/ is already in .gitignore
	lines := strings.Split(string(content), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "brigade/" || line == "brigade" {
			fmt.Printf("  %s✓%s brigade/ already in .gitignore\n", colorGreen, colorReset)
			return nil
		}
	}

	// brigade/ not in .gitignore
	fmt.Printf("  %s!%s brigade/ not in .gitignore\n", colorYellow, colorReset)
	fmt.Println()
	fmt.Println("  The brigade/ directory contains working files (PRDs, state, logs)")
	fmt.Println("  that shouldn't be committed to your repo.")
	fmt.Println()

	if confirmPrompt("  Add 'brigade/' to .gitignore? (Y/n) ", true) {
		f, err := os.OpenFile(gitignorePath, os.O_APPEND|os.O_WRONLY, 0644)
		if err != nil {
			return err
		}
		defer f.Close()

		_, err = f.WriteString("\n# Brigade working directory\nbrigade/\n")
		if err != nil {
			return err
		}
		fmt.Printf("  %s✓%s Added brigade/ to .gitignore\n", colorGreen, colorReset)
	} else {
		fmt.Printf("  %s!%s Skipped. Remember to add manually:\n", colorYellow, colorReset)
		fmt.Printf("      %secho 'brigade/' >> .gitignore%s\n", colorCyan, colorReset)
	}

	return nil
}

func confirmPrompt(prompt string, defaultYes bool) bool {
	reader := bufio.NewReader(os.Stdin)
	fmt.Print(prompt)
	response, _ := reader.ReadString('\n')
	response = strings.TrimSpace(strings.ToLower(response))

	if response == "" {
		return defaultYes
	}
	return response == "y" || response == "yes"
}
