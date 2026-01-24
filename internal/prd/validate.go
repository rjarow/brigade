package prd

import (
	"fmt"
	"regexp"
	"strings"
)

// ValidationError represents a PRD validation error.
type ValidationError struct {
	TaskID  string
	Field   string
	Message string
}

func (e ValidationError) Error() string {
	if e.TaskID != "" {
		return fmt.Sprintf("%s.%s: %s", e.TaskID, e.Field, e.Message)
	}
	return fmt.Sprintf("%s: %s", e.Field, e.Message)
}

// ValidationResult holds the results of PRD validation.
type ValidationResult struct {
	Errors   []ValidationError
	Warnings []ValidationError
}

// IsValid returns true if there are no errors.
func (r *ValidationResult) IsValid() bool {
	return len(r.Errors) == 0
}

// HasWarnings returns true if there are warnings.
func (r *ValidationResult) HasWarnings() bool {
	return len(r.Warnings) > 0
}

// AddError adds a validation error.
func (r *ValidationResult) AddError(taskID, field, message string) {
	r.Errors = append(r.Errors, ValidationError{TaskID: taskID, Field: field, Message: message})
}

// AddWarning adds a validation warning.
func (r *ValidationResult) AddWarning(taskID, field, message string) {
	r.Warnings = append(r.Warnings, ValidationError{TaskID: taskID, Field: field, Message: message})
}

// ValidateQuick performs quick validation suitable for pre-service checks.
func (p *PRD) ValidateQuick() *ValidationResult {
	result := &ValidationResult{}

	// Check required top-level fields
	if p.FeatureName == "" {
		result.AddError("", "featureName", "required")
	}
	if p.BranchName == "" {
		result.AddError("", "branchName", "required")
	}
	if len(p.Tasks) == 0 {
		result.AddError("", "tasks", "at least one task required")
	}

	// Build task ID set for dependency validation
	taskIDs := make(map[string]bool)
	for _, task := range p.Tasks {
		taskIDs[task.ID] = true
	}

	// Validate each task
	for _, task := range p.Tasks {
		p.validateTask(&task, taskIDs, result)
	}

	// Check for circular dependencies
	if p.HasCircularDependency() {
		result.AddError("", "tasks", "circular dependency detected")
	}

	return result
}

// validateTask validates a single task.
func (p *PRD) validateTask(task *Task, taskIDs map[string]bool, result *ValidationResult) {
	// Required fields
	if task.ID == "" {
		result.AddError(task.ID, "id", "required")
	}
	if task.Title == "" {
		result.AddError(task.ID, "title", "required")
	}
	if len(task.AcceptanceCriteria) == 0 {
		result.AddError(task.ID, "acceptanceCriteria", "at least one criterion required")
	}

	// Validate complexity
	if task.Complexity != ComplexityJunior && task.Complexity != ComplexitySenior && task.Complexity != ComplexityAuto {
		result.AddError(task.ID, "complexity", fmt.Sprintf("invalid value '%s', must be junior/senior/auto", task.Complexity))
	}

	// Validate dependencies exist
	for _, dep := range task.DependsOn {
		if !taskIDs[dep] {
			result.AddError(task.ID, "dependsOn", fmt.Sprintf("unknown dependency '%s'", dep))
		}
		if dep == task.ID {
			result.AddError(task.ID, "dependsOn", "task cannot depend on itself")
		}
	}

	// Validate verification commands
	for i, v := range task.Verification {
		if v.Cmd == "" {
			result.AddError(task.ID, fmt.Sprintf("verification[%d]", i), "cmd required")
		}
		if v.Type != "" && v.Type != VerificationPattern && v.Type != VerificationUnit &&
			v.Type != VerificationIntegration && v.Type != VerificationSmoke {
			result.AddWarning(task.ID, fmt.Sprintf("verification[%d]", i),
				fmt.Sprintf("unknown type '%s', expected pattern/unit/integration/smoke", v.Type))
		}
	}
}

// ValidateFull performs full validation including quality checks.
func (p *PRD) ValidateFull(opts ValidationOptions) *ValidationResult {
	result := p.ValidateQuick()

	if opts.LintCriteria {
		p.lintAcceptanceCriteria(result)
	}

	if opts.CheckVerificationTypes {
		p.checkVerificationTypes(result)
	}

	if opts.WarnGrepOnly {
		p.warnGrepOnlyVerification(result)
	}

	return result
}

// ValidationOptions controls which validation checks to perform.
type ValidationOptions struct {
	LintCriteria           bool
	CheckVerificationTypes bool
	WarnGrepOnly           bool
	WalkawayMode           bool
}

// Ambiguous language patterns to detect in acceptance criteria.
var ambiguousPatterns = []struct {
	pattern *regexp.Regexp
	message string
}{
	{regexp.MustCompile(`(?i)\b(shown|displayed)\b`), "use specific element names instead of 'shown/displayed'"},
	{regexp.MustCompile(`(?i)\bsupports\s+\w+\b`), "specify default behavior for 'supports X'"},
	{regexp.MustCompile(`(?i)\bhandles?\s+errors?\b`), "specify error handling behavior"},
	{regexp.MustCompile(`(?i)\buser\s+can\b`), "specify interaction method for 'user can'"},
	{regexp.MustCompile(`(?i)\b(appropriate|suitable|reasonable|proper)\b`), "avoid subjective terms"},
	{regexp.MustCompile(`(?i)\betc\.?\b`), "be specific instead of using 'etc.'"},
	{regexp.MustCompile(`(?i)\b(should|might|could)\b`), "use definitive language (must, will) instead of tentative"},
}

// lintAcceptanceCriteria checks for ambiguous language.
func (p *PRD) lintAcceptanceCriteria(result *ValidationResult) {
	for _, task := range p.Tasks {
		for i, criterion := range task.AcceptanceCriteria {
			for _, check := range ambiguousPatterns {
				if check.pattern.MatchString(criterion) {
					result.AddWarning(task.ID, fmt.Sprintf("acceptanceCriteria[%d]", i), check.message)
				}
			}
		}
	}
}

// checkVerificationTypes validates that verification types match task types.
func (p *PRD) checkVerificationTypes(result *ValidationResult) {
	for _, task := range p.Tasks {
		titleLower := strings.ToLower(task.Title)

		// Collect verification types
		hasUnit := false
		hasIntegration := false
		hasSmoke := false
		for _, v := range task.Verification {
			switch v.Type {
			case VerificationUnit:
				hasUnit = true
			case VerificationIntegration:
				hasIntegration = true
			case VerificationSmoke:
				hasSmoke = true
			}
		}

		// Check task type expectations
		isAddCreate := strings.Contains(titleLower, "add") || strings.Contains(titleLower, "create") || strings.Contains(titleLower, "implement")
		isConnect := strings.Contains(titleLower, "connect") || strings.Contains(titleLower, "integrate") || strings.Contains(titleLower, "wire")
		isFlow := strings.Contains(titleLower, "flow") || strings.Contains(titleLower, "workflow") || strings.Contains(titleLower, "user can")

		if isAddCreate && len(task.Verification) > 0 && !hasUnit && !hasIntegration {
			result.AddWarning(task.ID, "verification", "add/create tasks should have unit or integration tests")
		}
		if isConnect && len(task.Verification) > 0 && !hasIntegration {
			result.AddWarning(task.ID, "verification", "integration tasks should have integration tests")
		}
		if isFlow && len(task.Verification) > 0 && !hasSmoke && !hasIntegration {
			result.AddWarning(task.ID, "verification", "flow tasks should have smoke or integration tests")
		}
	}
}

// warnGrepOnlyVerification checks for PRDs that only use grep-based verification.
func (p *PRD) warnGrepOnlyVerification(result *ValidationResult) {
	hasExecution := false
	hasGrepOnly := false

	for _, task := range p.Tasks {
		for _, v := range task.Verification {
			if isGrepCommand(v.Cmd) {
				hasGrepOnly = true
			} else {
				hasExecution = true
			}
		}
	}

	if hasGrepOnly && !hasExecution {
		result.AddWarning("", "verification", "PRD only has grep-based verification; consider adding execution tests")
	}
}

// isGrepCommand checks if a command is grep-based (pattern check without execution).
func isGrepCommand(cmd string) bool {
	cmdLower := strings.ToLower(cmd)
	grepPatterns := []string{"grep ", "grep\t", "test -f", "test -d", "test -e", "[ -f", "[ -d", "[ -e"}
	for _, pattern := range grepPatterns {
		if strings.Contains(cmdLower, pattern) {
			return true
		}
	}
	return false
}

// ValidateDependencies checks that a filtered set of tasks has valid dependencies.
// Returns an error if any included task depends on an excluded task.
func (p *PRD) ValidateDependencies(included map[string]bool) error {
	for _, task := range p.Tasks {
		if !included[task.ID] {
			continue
		}
		for _, dep := range task.DependsOn {
			// Dependency must be either included OR already completed
			if !included[dep] {
				depTask := p.TaskByID(dep)
				if depTask == nil || !depTask.Passes {
					return fmt.Errorf("task %s depends on %s which is not in the execution set", task.ID, dep)
				}
			}
		}
	}
	return nil
}

// SuggestVerification suggests verification commands based on task title and project stack.
func SuggestVerification(task *Task, projectStack string) []Verification {
	var suggestions []Verification
	titleLower := strings.ToLower(task.Title)

	// Detect test-related tasks
	if strings.Contains(titleLower, "test") {
		return nil // Test tasks don't need verification suggestions
	}

	// Suggest based on project stack
	switch projectStack {
	case "go":
		suggestions = append(suggestions, Verification{
			Type: VerificationUnit,
			Cmd:  "go test ./...",
		})
	case "node", "javascript", "typescript":
		suggestions = append(suggestions, Verification{
			Type: VerificationUnit,
			Cmd:  "npm test",
		})
	case "python":
		suggestions = append(suggestions, Verification{
			Type: VerificationUnit,
			Cmd:  "pytest",
		})
	case "rust":
		suggestions = append(suggestions, Verification{
			Type: VerificationUnit,
			Cmd:  "cargo test",
		})
	}

	// Add pattern check for add/create tasks
	if strings.Contains(titleLower, "add") || strings.Contains(titleLower, "create") {
		suggestions = append(suggestions, Verification{
			Type: VerificationPattern,
			Cmd:  "# TODO: Add pattern check for created files/code",
		})
	}

	return suggestions
}

// DetectProjectStack attempts to detect the project's technology stack.
func DetectProjectStack(projectPath string) string {
	// Check for common project files
	files := map[string]string{
		"go.mod":       "go",
		"Cargo.toml":   "rust",
		"package.json": "node",
		"pyproject.toml": "python",
		"requirements.txt": "python",
		"setup.py":     "python",
		"Gemfile":      "ruby",
		"pom.xml":      "java",
		"build.gradle": "java",
	}

	for file, stack := range files {
		if _, err := FileExists(projectPath, file); err == nil {
			return stack
		}
	}

	return "unknown"
}

// FileExists is a helper to check if a file exists.
func FileExists(dir, name string) (bool, error) {
	path := dir + "/" + name
	if dir == "" {
		path = name
	}
	_, err := ReadFileInfo(path)
	if err != nil {
		return false, err
	}
	return true, nil
}

// ReadFileInfo is a helper that can be mocked in tests.
var ReadFileInfo = func(path string) (interface{}, error) {
	return nil, fmt.Errorf("not implemented in this context")
}
