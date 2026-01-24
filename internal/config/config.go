// Package config handles Brigade configuration loading and validation.
package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Config holds all Brigade configuration options.
type Config struct {
	// Quick Start - Cost Optimization
	UseOpenCode   bool   `mapstructure:"USE_OPENCODE"`
	OpenCodeModel string `mapstructure:"OPENCODE_MODEL"`

	// Workers
	ExecutiveCmd   string `mapstructure:"EXECUTIVE_CMD"`
	ExecutiveAgent string `mapstructure:"EXECUTIVE_AGENT"`
	SousCmd        string `mapstructure:"SOUS_CMD"`
	SousAgent      string `mapstructure:"SOUS_AGENT"`
	LineCmd        string `mapstructure:"LINE_CMD"`
	LineAgent      string `mapstructure:"LINE_AGENT"`

	// OpenCode Settings
	OpenCodeServer                   string `mapstructure:"OPENCODE_SERVER"`
	ClaudeDangerouslySkipPermissions bool   `mapstructure:"CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS"`

	// Output
	QuietWorkers bool `mapstructure:"QUIET_WORKERS"`

	// Visibility & Monitoring
	ActivityLog                string        `mapstructure:"ACTIVITY_LOG"`
	ActivityLogInterval        time.Duration `mapstructure:"ACTIVITY_LOG_INTERVAL"`
	TaskTimeoutWarningJunior   time.Duration `mapstructure:"TASK_TIMEOUT_WARNING_JUNIOR"`
	TaskTimeoutWarningSenior   time.Duration `mapstructure:"TASK_TIMEOUT_WARNING_SENIOR"`
	WorkerLogDir               string        `mapstructure:"WORKER_LOG_DIR"`
	StatusWatchInterval        time.Duration `mapstructure:"STATUS_WATCH_INTERVAL"`

	// Supervisor Integration
	SupervisorStatusFile     string        `mapstructure:"SUPERVISOR_STATUS_FILE"`
	SupervisorEventsFile     string        `mapstructure:"SUPERVISOR_EVENTS_FILE"`
	SupervisorCmdFile        string        `mapstructure:"SUPERVISOR_CMD_FILE"`
	SupervisorCmdPollInterval time.Duration `mapstructure:"SUPERVISOR_CMD_POLL_INTERVAL"`
	SupervisorCmdTimeout     time.Duration `mapstructure:"SUPERVISOR_CMD_TIMEOUT"`
	SupervisorPRDScoped      bool          `mapstructure:"SUPERVISOR_PRD_SCOPED"`

	// Modules
	Modules       []string      `mapstructure:"MODULES"`
	ModuleTimeout time.Duration `mapstructure:"MODULE_TIMEOUT"`
	ModuleConfig  map[string]string // MODULE_* env vars

	// Terminal Module
	ModuleTerminalBell bool `mapstructure:"MODULE_TERMINAL_BELL"`

	// Cost Estimation
	CostRateLine      float64 `mapstructure:"COST_RATE_LINE"`
	CostRateSous      float64 `mapstructure:"COST_RATE_SOUS"`
	CostRateExecutive float64 `mapstructure:"COST_RATE_EXECUTIVE"`
	CostWarnThreshold float64 `mapstructure:"COST_WARN_THRESHOLD"`

	// Risk Assessment
	RiskReportEnabled bool   `mapstructure:"RISK_REPORT_ENABLED"`
	RiskHistoryScan   bool   `mapstructure:"RISK_HISTORY_SCAN"`
	RiskWarnThreshold string `mapstructure:"RISK_WARN_THRESHOLD"`

	// Codebase Map
	MapStaleCommits int `mapstructure:"MAP_STALE_COMMITS"`

	// Git
	DefaultBranch string `mapstructure:"DEFAULT_BRANCH"`

	// Testing
	TestCmd     string        `mapstructure:"TEST_CMD"`
	TestTimeout time.Duration `mapstructure:"TEST_TIMEOUT"`

	// Verification
	VerificationEnabled         bool          `mapstructure:"VERIFICATION_ENABLED"`
	VerificationTimeout         time.Duration `mapstructure:"VERIFICATION_TIMEOUT"`
	TodoScanEnabled             bool          `mapstructure:"TODO_SCAN_ENABLED"`
	VerificationWarnGrepOnly    bool          `mapstructure:"VERIFICATION_WARN_GREP_ONLY"`
	ManualVerificationEnabled   bool          `mapstructure:"MANUAL_VERIFICATION_ENABLED"`

	// PRD Quality & Verification Depth
	CriteriaLintEnabled        bool `mapstructure:"CRITERIA_LINT_ENABLED"`
	VerificationScaffoldEnabled bool `mapstructure:"VERIFICATION_SCAFFOLD_ENABLED"`
	E2EDetectionEnabled        bool `mapstructure:"E2E_DETECTION_ENABLED"`
	CrossPRDContextEnabled     bool `mapstructure:"CROSS_PRD_CONTEXT_ENABLED"`
	CrossPRDMaxRelated         int  `mapstructure:"CROSS_PRD_MAX_RELATED"`

	// Smart Retry
	SmartRetryEnabled            bool   `mapstructure:"SMART_RETRY_ENABLED"`
	SmartRetryCustomPatterns     string `mapstructure:"SMART_RETRY_CUSTOM_PATTERNS"`
	SmartRetryStrategiesFile     string `mapstructure:"SMART_RETRY_STRATEGIES_FILE"`
	SmartRetryApproachHistoryMax int    `mapstructure:"SMART_RETRY_APPROACH_HISTORY_MAX"`
	SmartRetrySessionFailuresMax int    `mapstructure:"SMART_RETRY_SESSION_FAILURES_MAX"`
	SmartRetryAutoLearningThreshold int `mapstructure:"SMART_RETRY_AUTO_LEARNING_THRESHOLD"`

	// Escalation
	EscalationEnabled     bool `mapstructure:"ESCALATION_ENABLED"`
	EscalationAfter       int  `mapstructure:"ESCALATION_AFTER"`
	EscalationToExec      bool `mapstructure:"ESCALATION_TO_EXEC"`
	EscalationToExecAfter int  `mapstructure:"ESCALATION_TO_EXEC_AFTER"`

	// Task Timeouts (Per-Complexity)
	TaskTimeoutJunior    time.Duration `mapstructure:"TASK_TIMEOUT_JUNIOR"`
	TaskTimeoutSenior    time.Duration `mapstructure:"TASK_TIMEOUT_SENIOR"`
	TaskTimeoutExecutive time.Duration `mapstructure:"TASK_TIMEOUT_EXECUTIVE"`

	// Worker Health Checks
	WorkerHealthCheckInterval time.Duration `mapstructure:"WORKER_HEALTH_CHECK_INTERVAL"`
	WorkerCrashExitCode       int           `mapstructure:"WORKER_CRASH_EXIT_CODE"`

	// Executive Review
	ReviewEnabled    bool `mapstructure:"REVIEW_ENABLED"`
	ReviewJuniorOnly bool `mapstructure:"REVIEW_JUNIOR_ONLY"`

	// Phase Review
	PhaseReviewEnabled bool   `mapstructure:"PHASE_REVIEW_ENABLED"`
	PhaseReviewAfter   int    `mapstructure:"PHASE_REVIEW_AFTER"`
	PhaseReviewAction  string `mapstructure:"PHASE_REVIEW_ACTION"`

	// Context Isolation
	ContextIsolation bool   `mapstructure:"CONTEXT_ISOLATION"`
	StateFile        string `mapstructure:"STATE_FILE"`

	// Knowledge Sharing
	KnowledgeSharing bool   `mapstructure:"KNOWLEDGE_SHARING"`
	LearningsFile    string `mapstructure:"LEARNINGS_FILE"`
	BacklogFile      string `mapstructure:"BACKLOG_FILE"`
	LearningsMax     int    `mapstructure:"LEARNINGS_MAX"`
	LearningsArchive bool   `mapstructure:"LEARNINGS_ARCHIVE"`

	// Parallel Execution
	MaxParallel int `mapstructure:"MAX_PARALLEL"`

	// Auto-Continue (Multi-PRD Chaining)
	AutoContinue bool   `mapstructure:"AUTO_CONTINUE"`
	PhaseGate    string `mapstructure:"PHASE_GATE"`

	// Walkaway Mode (Autonomous Execution)
	WalkawayMode           bool          `mapstructure:"WALKAWAY_MODE"`
	WalkawayMaxSkips       int           `mapstructure:"WALKAWAY_MAX_SKIPS"`
	WalkawayDecisionTimeout time.Duration `mapstructure:"WALKAWAY_DECISION_TIMEOUT"`
	WalkawayScopeDecisions bool          `mapstructure:"WALKAWAY_SCOPE_DECISIONS"`

	// Lock Heartbeat
	LockHeartbeatInterval time.Duration `mapstructure:"LOCK_HEARTBEAT_INTERVAL"`

	// Service Idle Detection
	ServiceIdleThreshold time.Duration `mapstructure:"SERVICE_IDLE_THRESHOLD"`
	ServiceIdleAction    string        `mapstructure:"SERVICE_IDLE_ACTION"`

	// Limits
	MaxIterations int `mapstructure:"MAX_ITERATIONS"`

	// Runtime flags (set via CLI, not config file)
	ForceOverrideLock bool

	// Internal tracking
	configPath string
}

// Default returns a Config with default values.
func Default() *Config {
	return &Config{
		// Quick Start
		UseOpenCode:   false,
		OpenCodeModel: "zai-coding-plan/glm-4.7",

		// Workers
		ExecutiveCmd:   "claude --model opus",
		ExecutiveAgent: "claude",
		SousCmd:        "claude --model sonnet",
		SousAgent:      "claude",
		LineCmd:        "claude --model sonnet",
		LineAgent:      "claude",

		// OpenCode Settings
		ClaudeDangerouslySkipPermissions: true,

		// Output
		QuietWorkers: false,

		// Visibility & Monitoring
		ActivityLogInterval:      30 * time.Second,
		TaskTimeoutWarningJunior: 10 * time.Minute,
		TaskTimeoutWarningSenior: 20 * time.Minute,
		StatusWatchInterval:      30 * time.Second,

		// Supervisor Integration
		SupervisorCmdPollInterval: 2 * time.Second,
		SupervisorCmdTimeout:      5 * time.Minute,
		SupervisorPRDScoped:       true,

		// Modules
		Modules:       []string{},
		ModuleTimeout: 5 * time.Second,
		ModuleConfig:  make(map[string]string),

		// Terminal Module
		ModuleTerminalBell: true,

		// Cost Estimation
		CostRateLine:      0.05,
		CostRateSous:      0.15,
		CostRateExecutive: 0.30,

		// Risk Assessment
		RiskReportEnabled: true,
		RiskHistoryScan:   false,

		// Codebase Map
		MapStaleCommits: 20,

		// Testing
		TestTimeout: 2 * time.Minute,

		// Verification
		VerificationEnabled:      true,
		VerificationTimeout:      60 * time.Second,
		TodoScanEnabled:          true,
		VerificationWarnGrepOnly: true,

		// PRD Quality
		CriteriaLintEnabled:         true,
		VerificationScaffoldEnabled: true,
		E2EDetectionEnabled:         true,
		CrossPRDContextEnabled:      true,
		CrossPRDMaxRelated:          3,

		// Smart Retry
		SmartRetryEnabled:               true,
		SmartRetryApproachHistoryMax:    3,
		SmartRetrySessionFailuresMax:    5,
		SmartRetryAutoLearningThreshold: 3,

		// Escalation
		EscalationEnabled:     true,
		EscalationAfter:       3,
		EscalationToExec:      true,
		EscalationToExecAfter: 5,

		// Task Timeouts
		TaskTimeoutJunior:    15 * time.Minute,
		TaskTimeoutSenior:    30 * time.Minute,
		TaskTimeoutExecutive: 60 * time.Minute,

		// Worker Health Checks
		WorkerHealthCheckInterval: 5 * time.Second,
		WorkerCrashExitCode:       125,

		// Executive Review
		ReviewEnabled:    true,
		ReviewJuniorOnly: true,

		// Phase Review
		PhaseReviewAfter:  5,
		PhaseReviewAction: "continue",

		// Context Isolation
		ContextIsolation: true,
		StateFile:        "brigade-state.json",

		// Knowledge Sharing
		KnowledgeSharing: true,
		LearningsFile:    "brigade-learnings.md",
		BacklogFile:      "brigade-backlog.md",
		LearningsMax:     50,
		LearningsArchive: true,

		// Parallel Execution
		MaxParallel: 3,

		// Auto-Continue
		PhaseGate: "continue",

		// Walkaway Mode
		WalkawayMaxSkips:        3,
		WalkawayDecisionTimeout: 2 * time.Minute,
		WalkawayScopeDecisions:  true,

		// Lock Heartbeat
		LockHeartbeatInterval: 30 * time.Second,

		// Service Idle Detection
		ServiceIdleThreshold: 180 * time.Second, // 3 min
		ServiceIdleAction:    "warn",

		// Limits
		MaxIterations: 50,
	}
}

// Load loads configuration from the given path, falling back to defaults.
// If path is empty, it searches for brigade.config in common locations.
func Load(path string) (*Config, error) {
	cfg := Default()

	if path == "" {
		// Search for config in common locations
		// Config lives in Brigade subdir, not project root
		searchPaths := []string{
			"brigade/brigade.config",
			"brigade.config", // fallback if running from Brigade dir
			filepath.Join(os.Getenv("HOME"), ".config/brigade/brigade.config"),
		}
		for _, p := range searchPaths {
			if _, err := os.Stat(p); err == nil {
				path = p
				break
			}
		}
	}

	if path != "" {
		if err := cfg.loadFromFile(path); err != nil {
			return nil, fmt.Errorf("loading config from %s: %w", path, err)
		}
		cfg.configPath = path
	}

	// Override with environment variables
	cfg.loadFromEnv()

	// Apply USE_OPENCODE shortcut
	if cfg.UseOpenCode {
		cfg.LineCmd = fmt.Sprintf("opencode run --model %s", cfg.OpenCodeModel)
		cfg.LineAgent = "opencode"
	}

	return cfg, nil
}

// loadFromFile loads configuration from a bash-style config file.
func (c *Config) loadFromFile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}

	lines := strings.Split(string(data), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Parse KEY=VALUE, handling quotes
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])

		// Remove surrounding quotes
		if (strings.HasPrefix(value, "\"") && strings.HasSuffix(value, "\"")) ||
			(strings.HasPrefix(value, "'") && strings.HasSuffix(value, "'")) {
			value = value[1 : len(value)-1]
		}

		c.setValue(key, value)
	}

	return nil
}

// loadFromEnv loads configuration from environment variables.
func (c *Config) loadFromEnv() {
	envVars := []string{
		"USE_OPENCODE", "OPENCODE_MODEL",
		"EXECUTIVE_CMD", "EXECUTIVE_AGENT", "SOUS_CMD", "SOUS_AGENT", "LINE_CMD", "LINE_AGENT",
		"OPENCODE_SERVER", "CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS",
		"QUIET_WORKERS",
		"ACTIVITY_LOG", "ACTIVITY_LOG_INTERVAL",
		"TASK_TIMEOUT_WARNING_JUNIOR", "TASK_TIMEOUT_WARNING_SENIOR",
		"WORKER_LOG_DIR", "STATUS_WATCH_INTERVAL",
		"SUPERVISOR_STATUS_FILE", "SUPERVISOR_EVENTS_FILE", "SUPERVISOR_CMD_FILE",
		"SUPERVISOR_CMD_POLL_INTERVAL", "SUPERVISOR_CMD_TIMEOUT", "SUPERVISOR_PRD_SCOPED",
		"MODULES", "MODULE_TIMEOUT", "MODULE_TERMINAL_BELL",
		"COST_RATE_LINE", "COST_RATE_SOUS", "COST_RATE_EXECUTIVE", "COST_WARN_THRESHOLD",
		"RISK_REPORT_ENABLED", "RISK_HISTORY_SCAN", "RISK_WARN_THRESHOLD",
		"MAP_STALE_COMMITS", "DEFAULT_BRANCH",
		"TEST_CMD", "TEST_TIMEOUT",
		"VERIFICATION_ENABLED", "VERIFICATION_TIMEOUT", "TODO_SCAN_ENABLED",
		"VERIFICATION_WARN_GREP_ONLY", "MANUAL_VERIFICATION_ENABLED",
		"CRITERIA_LINT_ENABLED", "VERIFICATION_SCAFFOLD_ENABLED", "E2E_DETECTION_ENABLED",
		"CROSS_PRD_CONTEXT_ENABLED", "CROSS_PRD_MAX_RELATED",
		"SMART_RETRY_ENABLED", "SMART_RETRY_CUSTOM_PATTERNS", "SMART_RETRY_STRATEGIES_FILE",
		"SMART_RETRY_APPROACH_HISTORY_MAX", "SMART_RETRY_SESSION_FAILURES_MAX",
		"SMART_RETRY_AUTO_LEARNING_THRESHOLD",
		"ESCALATION_ENABLED", "ESCALATION_AFTER", "ESCALATION_TO_EXEC", "ESCALATION_TO_EXEC_AFTER",
		"TASK_TIMEOUT_JUNIOR", "TASK_TIMEOUT_SENIOR", "TASK_TIMEOUT_EXECUTIVE",
		"WORKER_HEALTH_CHECK_INTERVAL", "WORKER_CRASH_EXIT_CODE",
		"REVIEW_ENABLED", "REVIEW_JUNIOR_ONLY",
		"PHASE_REVIEW_ENABLED", "PHASE_REVIEW_AFTER", "PHASE_REVIEW_ACTION",
		"CONTEXT_ISOLATION", "STATE_FILE",
		"KNOWLEDGE_SHARING", "LEARNINGS_FILE", "BACKLOG_FILE", "LEARNINGS_MAX", "LEARNINGS_ARCHIVE",
		"MAX_PARALLEL", "AUTO_CONTINUE", "PHASE_GATE",
		"WALKAWAY_MODE", "WALKAWAY_MAX_SKIPS", "WALKAWAY_DECISION_TIMEOUT", "WALKAWAY_SCOPE_DECISIONS",
		"LOCK_HEARTBEAT_INTERVAL", "SERVICE_IDLE_THRESHOLD", "SERVICE_IDLE_ACTION",
		"MAX_ITERATIONS",
	}

	for _, key := range envVars {
		if value := os.Getenv(key); value != "" {
			c.setValue(key, value)
		}
	}

	// Collect MODULE_* config
	for _, env := range os.Environ() {
		if strings.HasPrefix(env, "MODULE_") && !strings.HasPrefix(env, "MODULE_TIMEOUT") && !strings.HasPrefix(env, "MODULE_TERMINAL_BELL") {
			parts := strings.SplitN(env, "=", 2)
			if len(parts) == 2 {
				c.ModuleConfig[parts[0]] = parts[1]
			}
		}
	}
}

// setValue sets a config value by key name.
func (c *Config) setValue(key, value string) {
	switch key {
	// Booleans
	case "USE_OPENCODE":
		c.UseOpenCode = parseBool(value)
	case "CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS":
		c.ClaudeDangerouslySkipPermissions = parseBool(value)
	case "QUIET_WORKERS":
		c.QuietWorkers = parseBool(value)
	case "SUPERVISOR_PRD_SCOPED":
		c.SupervisorPRDScoped = parseBool(value)
	case "MODULE_TERMINAL_BELL":
		c.ModuleTerminalBell = parseBool(value)
	case "RISK_REPORT_ENABLED":
		c.RiskReportEnabled = parseBool(value)
	case "RISK_HISTORY_SCAN":
		c.RiskHistoryScan = parseBool(value)
	case "VERIFICATION_ENABLED":
		c.VerificationEnabled = parseBool(value)
	case "TODO_SCAN_ENABLED":
		c.TodoScanEnabled = parseBool(value)
	case "VERIFICATION_WARN_GREP_ONLY":
		c.VerificationWarnGrepOnly = parseBool(value)
	case "MANUAL_VERIFICATION_ENABLED":
		c.ManualVerificationEnabled = parseBool(value)
	case "CRITERIA_LINT_ENABLED":
		c.CriteriaLintEnabled = parseBool(value)
	case "VERIFICATION_SCAFFOLD_ENABLED":
		c.VerificationScaffoldEnabled = parseBool(value)
	case "E2E_DETECTION_ENABLED":
		c.E2EDetectionEnabled = parseBool(value)
	case "CROSS_PRD_CONTEXT_ENABLED":
		c.CrossPRDContextEnabled = parseBool(value)
	case "SMART_RETRY_ENABLED":
		c.SmartRetryEnabled = parseBool(value)
	case "ESCALATION_ENABLED":
		c.EscalationEnabled = parseBool(value)
	case "ESCALATION_TO_EXEC":
		c.EscalationToExec = parseBool(value)
	case "REVIEW_ENABLED":
		c.ReviewEnabled = parseBool(value)
	case "REVIEW_JUNIOR_ONLY":
		c.ReviewJuniorOnly = parseBool(value)
	case "PHASE_REVIEW_ENABLED":
		c.PhaseReviewEnabled = parseBool(value)
	case "CONTEXT_ISOLATION":
		c.ContextIsolation = parseBool(value)
	case "KNOWLEDGE_SHARING":
		c.KnowledgeSharing = parseBool(value)
	case "LEARNINGS_ARCHIVE":
		c.LearningsArchive = parseBool(value)
	case "AUTO_CONTINUE":
		c.AutoContinue = parseBool(value)
	case "WALKAWAY_MODE":
		c.WalkawayMode = parseBool(value)
	case "WALKAWAY_SCOPE_DECISIONS":
		c.WalkawayScopeDecisions = parseBool(value)

	// Strings
	case "OPENCODE_MODEL":
		c.OpenCodeModel = value
	case "EXECUTIVE_CMD":
		c.ExecutiveCmd = value
	case "EXECUTIVE_AGENT":
		c.ExecutiveAgent = value
	case "SOUS_CMD":
		c.SousCmd = value
	case "SOUS_AGENT":
		c.SousAgent = value
	case "LINE_CMD":
		c.LineCmd = value
	case "LINE_AGENT":
		c.LineAgent = value
	case "OPENCODE_SERVER":
		c.OpenCodeServer = value
	case "ACTIVITY_LOG":
		c.ActivityLog = value
	case "WORKER_LOG_DIR":
		c.WorkerLogDir = value
	case "SUPERVISOR_STATUS_FILE":
		c.SupervisorStatusFile = value
	case "SUPERVISOR_EVENTS_FILE":
		c.SupervisorEventsFile = value
	case "SUPERVISOR_CMD_FILE":
		c.SupervisorCmdFile = value
	case "RISK_WARN_THRESHOLD":
		c.RiskWarnThreshold = value
	case "DEFAULT_BRANCH":
		c.DefaultBranch = value
	case "TEST_CMD":
		c.TestCmd = value
	case "SMART_RETRY_CUSTOM_PATTERNS":
		c.SmartRetryCustomPatterns = value
	case "SMART_RETRY_STRATEGIES_FILE":
		c.SmartRetryStrategiesFile = value
	case "STATE_FILE":
		c.StateFile = value
	case "LEARNINGS_FILE":
		c.LearningsFile = value
	case "BACKLOG_FILE":
		c.BacklogFile = value
	case "PHASE_GATE":
		c.PhaseGate = value
	case "PHASE_REVIEW_ACTION":
		c.PhaseReviewAction = value

	// Integers
	case "MAP_STALE_COMMITS":
		c.MapStaleCommits = parseInt(value)
	case "CROSS_PRD_MAX_RELATED":
		c.CrossPRDMaxRelated = parseInt(value)
	case "SMART_RETRY_APPROACH_HISTORY_MAX":
		c.SmartRetryApproachHistoryMax = parseInt(value)
	case "SMART_RETRY_SESSION_FAILURES_MAX":
		c.SmartRetrySessionFailuresMax = parseInt(value)
	case "SMART_RETRY_AUTO_LEARNING_THRESHOLD":
		c.SmartRetryAutoLearningThreshold = parseInt(value)
	case "ESCALATION_AFTER":
		c.EscalationAfter = parseInt(value)
	case "ESCALATION_TO_EXEC_AFTER":
		c.EscalationToExecAfter = parseInt(value)
	case "WORKER_CRASH_EXIT_CODE":
		c.WorkerCrashExitCode = parseInt(value)
	case "PHASE_REVIEW_AFTER":
		c.PhaseReviewAfter = parseInt(value)
	case "LEARNINGS_MAX":
		c.LearningsMax = parseInt(value)
	case "MAX_PARALLEL":
		c.MaxParallel = parseInt(value)
	case "WALKAWAY_MAX_SKIPS":
		c.WalkawayMaxSkips = parseInt(value)
	case "MAX_ITERATIONS":
		c.MaxIterations = parseInt(value)

	// Floats
	case "COST_RATE_LINE":
		c.CostRateLine = parseFloat(value)
	case "COST_RATE_SOUS":
		c.CostRateSous = parseFloat(value)
	case "COST_RATE_EXECUTIVE":
		c.CostRateExecutive = parseFloat(value)
	case "COST_WARN_THRESHOLD":
		c.CostWarnThreshold = parseFloat(value)

	// Durations (in seconds unless specified)
	case "ACTIVITY_LOG_INTERVAL":
		c.ActivityLogInterval = parseDurationSeconds(value)
	case "TASK_TIMEOUT_WARNING_JUNIOR":
		c.TaskTimeoutWarningJunior = parseDurationMinutes(value)
	case "TASK_TIMEOUT_WARNING_SENIOR":
		c.TaskTimeoutWarningSenior = parseDurationMinutes(value)
	case "STATUS_WATCH_INTERVAL":
		c.StatusWatchInterval = parseDurationSeconds(value)
	case "SUPERVISOR_CMD_POLL_INTERVAL":
		c.SupervisorCmdPollInterval = parseDurationSeconds(value)
	case "SUPERVISOR_CMD_TIMEOUT":
		c.SupervisorCmdTimeout = parseDurationSeconds(value)
	case "MODULE_TIMEOUT":
		c.ModuleTimeout = parseDurationSeconds(value)
	case "TEST_TIMEOUT":
		c.TestTimeout = parseDurationSeconds(value)
	case "VERIFICATION_TIMEOUT":
		c.VerificationTimeout = parseDurationSeconds(value)
	case "TASK_TIMEOUT_JUNIOR":
		c.TaskTimeoutJunior = parseDurationSeconds(value)
	case "TASK_TIMEOUT_SENIOR":
		c.TaskTimeoutSenior = parseDurationSeconds(value)
	case "TASK_TIMEOUT_EXECUTIVE":
		c.TaskTimeoutExecutive = parseDurationSeconds(value)
	case "WORKER_HEALTH_CHECK_INTERVAL":
		c.WorkerHealthCheckInterval = parseDurationSeconds(value)
	case "WALKAWAY_DECISION_TIMEOUT":
		c.WalkawayDecisionTimeout = parseDurationSeconds(value)
	case "LOCK_HEARTBEAT_INTERVAL":
		c.LockHeartbeatInterval = parseDurationSeconds(value)
	case "SERVICE_IDLE_THRESHOLD":
		c.ServiceIdleThreshold = parseDurationSeconds(value)

	// Service Idle Action (string)
	case "SERVICE_IDLE_ACTION":
		c.ServiceIdleAction = value

	// String arrays
	case "MODULES":
		if value != "" {
			c.Modules = strings.Split(value, ",")
			for i := range c.Modules {
				c.Modules[i] = strings.TrimSpace(c.Modules[i])
			}
		}
	}
}

// Validate checks the configuration for errors.
func (c *Config) Validate() []string {
	var warnings []string

	// Validate phase gate values
	validPhaseGates := map[string]bool{"continue": true, "pause": true, "review": true}
	if !validPhaseGates[c.PhaseGate] {
		warnings = append(warnings, fmt.Sprintf("PHASE_GATE '%s' invalid, using 'continue'", c.PhaseGate))
		c.PhaseGate = "continue"
	}

	// Validate phase review action
	validActions := map[string]bool{"continue": true, "pause": true, "remediate": true}
	if !validActions[c.PhaseReviewAction] {
		warnings = append(warnings, fmt.Sprintf("PHASE_REVIEW_ACTION '%s' invalid, using 'continue'", c.PhaseReviewAction))
		c.PhaseReviewAction = "continue"
	}

	// Validate risk threshold
	validRisks := map[string]bool{"": true, "low": true, "medium": true, "high": true}
	if !validRisks[c.RiskWarnThreshold] {
		warnings = append(warnings, fmt.Sprintf("RISK_WARN_THRESHOLD '%s' invalid, disabling", c.RiskWarnThreshold))
		c.RiskWarnThreshold = ""
	}

	// Validate service idle action
	validIdleActions := map[string]bool{"warn": true, "abort": true, "heal": true}
	if !validIdleActions[c.ServiceIdleAction] {
		warnings = append(warnings, fmt.Sprintf("SERVICE_IDLE_ACTION '%s' invalid, using 'warn'", c.ServiceIdleAction))
		c.ServiceIdleAction = "warn"
	}

	// Validate numeric ranges
	if c.MaxParallel < 0 {
		warnings = append(warnings, "MAX_PARALLEL must be >= 0, using 0")
		c.MaxParallel = 0
	}

	if c.EscalationAfter < 1 {
		warnings = append(warnings, "ESCALATION_AFTER must be >= 1, using 3")
		c.EscalationAfter = 3
	}

	if c.EscalationToExecAfter < 1 {
		warnings = append(warnings, "ESCALATION_TO_EXEC_AFTER must be >= 1, using 5")
		c.EscalationToExecAfter = 5
	}

	if c.MaxIterations < 1 {
		warnings = append(warnings, "MAX_ITERATIONS must be >= 1, using 50")
		c.MaxIterations = 50
	}

	return warnings
}

// Path returns the path the config was loaded from, if any.
func (c *Config) Path() string {
	return c.configPath
}

// Helper functions for parsing

func parseBool(s string) bool {
	s = strings.ToLower(strings.TrimSpace(s))
	return s == "true" || s == "1" || s == "yes"
}

func parseInt(s string) int {
	i, _ := strconv.Atoi(strings.TrimSpace(s))
	return i
}

func parseFloat(s string) float64 {
	f, _ := strconv.ParseFloat(strings.TrimSpace(s), 64)
	return f
}

func parseDurationSeconds(s string) time.Duration {
	i := parseInt(s)
	return time.Duration(i) * time.Second
}

func parseDurationMinutes(s string) time.Duration {
	i := parseInt(s)
	return time.Duration(i) * time.Minute
}
