# Configuration Guide

Brigade is configured via `brigade.config` in your project's brigade directory.

## Configuration File

Create `brigade/brigade.config`:

```bash
# ═══════════════════════════════════════════════════════════════════════════════
# WORKERS
# ═══════════════════════════════════════════════════════════════════════════════

# Executive Chef - directs and reviews (currently used for analysis)
EXECUTIVE_CMD="claude --model opus"

# Sous Chef - handles complex/senior tasks
SOUS_CMD="claude --model sonnet"

# Line Cook - handles routine/junior tasks
LINE_CMD="opencode -p"

# ═══════════════════════════════════════════════════════════════════════════════
# TESTING
# ═══════════════════════════════════════════════════════════════════════════════

# Run after each task to verify completion
# Leave empty to skip testing
TEST_CMD="go test ./..."

# ═══════════════════════════════════════════════════════════════════════════════
# LIMITS
# ═══════════════════════════════════════════════════════════════════════════════

# Max iterations per task before giving up
MAX_ITERATIONS=50
```

## Worker Commands

### Claude CLI

```bash
SOUS_CMD="claude --model sonnet"
EXECUTIVE_CMD="claude --model opus"
```

Available models:
- `opus` - Most capable, best for complex reasoning
- `sonnet` - Balanced capability and speed
- `haiku` - Fastest, good for simple tasks

### OpenCode

```bash
LINE_CMD="opencode -p"
```

OpenCode flags:
- `-p` - Pass prompt directly (required for non-interactive mode)
- `-q` - Quiet mode (hide spinner)
- `-f json` - Output as JSON

### Other AI CLIs

Any CLI that accepts a prompt can work:

```bash
# GPT-4 via CLI
LINE_CMD="gpt4cli --prompt"

# Local Ollama
LINE_CMD="ollama run codellama"

# Custom wrapper script
LINE_CMD="./scripts/my-ai-wrapper.sh"
```

## Test Commands

### Language-Specific Examples

```bash
# Go
TEST_CMD="go test ./..."

# Node.js
TEST_CMD="npm test"

# Python
TEST_CMD="pytest"

# Rust
TEST_CMD="cargo test"

# Ruby
TEST_CMD="bundle exec rspec"

# Multiple commands
TEST_CMD="npm run lint && npm test"
```

### Test Timeout

```bash
# Timeout for test execution (default: 120 seconds)
TEST_TIMEOUT=120
```

Tests exceeding this are flagged as "hung" - likely spawning interactive processes.

### Skipping Tests

Leave empty to skip test verification:

```bash
TEST_CMD=""
```

⚠️ Without tests, Brigade only relies on the AI's `<promise>COMPLETE</promise>` signal.

## Escalation

```bash
# Enable automatic escalation (default: true)
ESCALATION_ENABLED=true

# Line Cook → Sous Chef after N iterations (default: 3)
ESCALATION_AFTER=3

# Enable Sous Chef → Executive Chef escalation (default: true)
ESCALATION_TO_EXEC=true

# Sous Chef → Executive Chef after N iterations (default: 5)
ESCALATION_TO_EXEC_AFTER=5
```

## Task Timeouts

Auto-escalate tasks that exceed time limits (independent of TEST_TIMEOUT):

```bash
# Junior/Line Cook tasks (default: 15 minutes)
TASK_TIMEOUT_JUNIOR=900

# Senior/Sous Chef tasks (default: 30 minutes)
TASK_TIMEOUT_SENIOR=1800

# Executive Chef tasks (default: 60 minutes)
TASK_TIMEOUT_EXECUTIVE=3600
```

Set to 0 to disable timeout for that complexity level. Timer resets when a task escalates to a new tier.

## Executive Review

```bash
# Enable Executive Chef review after task completion (default: true)
REVIEW_ENABLED=true

# Only review junior work - saves Opus API calls (default: true)
REVIEW_JUNIOR_ONLY=true
```

## Iteration Limits

```bash
MAX_ITERATIONS=50
```

This is the maximum number of times Brigade will re-run a task before giving up. Each iteration:
1. Sends the same prompt to the worker
2. Worker sees updated codebase from previous attempts
3. Worker tries again to complete the task

If you're hitting limits often, your tasks may be too large or ambiguous.

## Environment Variables

You can use environment variables in your config:

```bash
SOUS_CMD="claude --model ${CLAUDE_MODEL:-sonnet}"
TEST_CMD="${PROJECT_TEST_CMD:-npm test}"
```

## Per-Project Configuration

The config file is loaded from `brigade/brigade.config` relative to where you run Brigade. This means each project can have its own configuration.

Typical setup:
```
my-project/
├── brigade/           # Symlink to Brigade repo
│   └── brigade.config # Project-specific config (gitignored in Brigade repo)
├── tasks/
│   └── prd-feature.json
└── src/
```

## Auto-Continue Mode

Chain multiple numbered PRDs for overnight/unattended execution:

```bash
# Execute PRDs in order (prd-001.json, prd-002.json, etc.)
./brigade.sh --auto-continue service brigade/tasks/prd-*.json
```

### Configuration

```bash
# Enable auto-continue by default
AUTO_CONTINUE=false

# Phase gate behavior between PRDs:
#   continue  - Proceed immediately (default)
#   pause     - Stop after each PRD for manual restart
#   review    - Executive Chef reviews before next PRD
PHASE_GATE="continue"
```

### Phase Gate Modes

| Mode | Behavior |
|------|----------|
| `continue` | Proceed to next PRD immediately |
| `pause` | Stop and wait for manual restart |
| `review` | Executive Chef reviews completion before proceeding |

Use `--phase-gate` flag to override:

```bash
./brigade.sh --auto-continue --phase-gate review service brigade/tasks/prd-*.json
```

## Chef Prompts

Customize worker behavior by editing:
- `chef/sous.md` - Senior developer prompt
- `chef/line.md` - Junior developer prompt
- `chef/executive.md` - Director prompt

These are Markdown files that get prepended to task details.
