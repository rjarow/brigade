package main

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"

	"github.com/spf13/cobra"

	"brigade/internal/config"
	"brigade/internal/util"
)

var opencodeModelsCmd = &cobra.Command{
	Use:   "opencode-models",
	Short: "List available OpenCode models",
	RunE: func(cmd *cobra.Command, args []string) error {
		return cmdOpencodeModels()
	},
}

func cmdOpencodeModels() error {
	fmt.Printf("%sAvailable OpenCode Models%s\n", colorBold, colorReset)
	fmt.Printf("%sUse these values for OPENCODE_MODEL in brigade.config%s\n\n", colorDim, colorReset)

	if !util.CommandExists("opencode") {
		fmt.Printf("%sError: opencode CLI not found%s\n\n", colorRed, colorReset)
		fmt.Println("Install OpenCode: https://opencode.ai")
		return fmt.Errorf("opencode CLI not found")
	}

	// Show current config if available
	cfg, _ := config.Load("")
	if cfg != nil && cfg.OpenCodeModel != "" {
		fmt.Printf("%sCurrent config: OPENCODE_MODEL=\"%s\"%s\n\n", colorCyan, cfg.OpenCodeModel, colorReset)
	}

	// Run opencode models command
	cmd := exec.Command("opencode", "models")
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	_ = cmd.Run()

	output := out.String()
	lines := strings.Split(output, "\n")

	// Filter and display GLM models
	fmt.Printf("%sGLM models (cost-effective):%s\n", colorBold, colorReset)
	for _, line := range lines {
		if strings.Contains(line, "zai-coding-plan") || strings.Contains(line, "opencode/glm") {
			fmt.Println(line)
		}
	}
	fmt.Println()

	// Filter and display Claude models (limit to 10)
	fmt.Printf("%sClaude models (via OpenCode):%s\n", colorBold, colorReset)
	count := 0
	for _, line := range lines {
		if strings.Contains(line, "anthropic/claude") && count < 10 {
			fmt.Println(line)
			count++
		}
	}
	fmt.Println()

	fmt.Printf("%sRun 'opencode models' for full list%s\n", colorDim, colorReset)
	return nil
}
