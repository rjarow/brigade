package util

import (
	"os/exec"
	"strings"
)

// GetHeadCommit returns the current git HEAD commit hash.
// Returns "unknown" if git is not available or not in a repo.
func GetHeadCommit() string {
	cmd := exec.Command("git", "rev-parse", "HEAD")
	output, err := cmd.Output()
	if err != nil {
		return "unknown"
	}
	return strings.TrimSpace(string(output))
}
