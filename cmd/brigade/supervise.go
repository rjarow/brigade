package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var superviseCmd = &cobra.Command{
	Use:   "supervise",
	Short: "Print quick reference for supervisor mode",
	Long:  `Shows how to monitor and intervene in Brigade's autonomous execution.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		return cmdSupervise()
	},
}

func cmdSupervise() error {
	fmt.Printf("%s Supervisor Mode%s\n\n", colorBold, colorReset)

	// Check for supervisor docs
	supervisorMd := "brigade/chef/supervisor.md"
	if _, err := os.Stat(supervisorMd); err == nil {
		fmt.Printf("Full supervisor instructions: %s\n\n", supervisorMd)
	}

	fmt.Printf("%sQuick Reference:%s\n\n", colorBold, colorReset)
	fmt.Println("  Status check:     ./brigade.sh status --brief")
	fmt.Println("  Detailed status:  ./brigade.sh status --json")
	fmt.Println("  Watch events:     tail -f brigade/tasks/events.jsonl")
	fmt.Println()

	fmt.Printf("%sIntervene via cmd.json:%s\n\n", colorBold, colorReset)
	fmt.Println("  Write to: brigade/tasks/cmd.json")
	fmt.Println()
	fmt.Println("  Actions:")
	fmt.Println("    retry  - Try again (add 'guidance' field to help worker)")
	fmt.Println("    skip   - Move on to next task")
	fmt.Println("    abort  - Stop everything")
	fmt.Println("    pause  - Stop and wait for investigation")
	fmt.Println()
	fmt.Println("  Example:")
	fmt.Println(`    {"decision":"d-123","action":"retry","guidance":"Check the OpenAPI spec"}`)
	fmt.Println()

	fmt.Printf("%sWhen to intervene:%s\n\n", colorBold, colorReset)
	fmt.Println("  ✓ 'attention' events - Brigade needs you")
	fmt.Println("  ✓ 'decision_needed' - Waiting for your input")
	fmt.Println("  ✓ Multiple failures on same task")
	fmt.Println("  ✗ Normal task_start/task_complete - let it run")
	fmt.Println("  ✗ Single escalation - that's normal")
	fmt.Println()

	if _, err := os.Stat(supervisorMd); err == nil {
		fmt.Printf("For complete documentation: %scat %s%s\n", colorCyan, supervisorMd, colorReset)
	}

	return nil
}
