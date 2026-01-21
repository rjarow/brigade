# Configuration

All settings go in `brigade/brigade.config`. Everything is optional - Brigade works without it.

## Quick Reference

```bash
# Workers - who does what
EXECUTIVE_CMD="claude --model opus"    # Plans, reviews
SOUS_CMD="claude --model sonnet"       # Complex tasks
LINE_CMD="opencode -p"                 # Routine tasks

# Testing
TEST_CMD="npm test"                    # Runs after each task
TEST_TIMEOUT=120                       # Seconds before flagging as hung

# Escalation
ESCALATION_AFTER=3                     # Line Cook → Sous Chef threshold
ESCALATION_TO_EXEC_AFTER=5             # Sous Chef → Exec Chef threshold

# Timeouts (seconds, 0 = disabled)
TASK_TIMEOUT_JUNIOR=900                # 15 min for Line Cook
TASK_TIMEOUT_SENIOR=1800               # 30 min for Sous Chef
TASK_TIMEOUT_EXECUTIVE=3600            # 60 min for Exec Chef

# Reviews
REVIEW_ENABLED=true                    # Exec Chef reviews completed work
REVIEW_JUNIOR_ONLY=true                # Only review Line Cook work

# Output
QUIET_WORKERS=false                    # Spinner instead of streaming output

# Iterations
MAX_ITERATIONS=50                      # Retries before giving up
```

## Workers

Any CLI that accepts a prompt works:

```bash
# Claude CLI
SOUS_CMD="claude --model sonnet"
EXECUTIVE_CMD="claude --model opus"

# OpenCode (cheaper for routine work)
LINE_CMD="opencode -p"

# GPT-4
LINE_CMD="gpt4cli --prompt"

# Local Ollama
LINE_CMD="ollama run codellama"

# Custom wrapper
LINE_CMD="./scripts/my-ai-wrapper.sh"
```

## Testing

```bash
# Language examples
TEST_CMD="go test ./..."        # Go
TEST_CMD="npm test"             # Node.js
TEST_CMD="pytest"               # Python
TEST_CMD="cargo test"           # Rust
TEST_CMD="npm run lint && npm test"  # Multiple commands

# Skip testing (not recommended)
TEST_CMD=""
```

## Verification

Per-task commands defined in the PRD:

```json
{
  "id": "US-001",
  "verification": [
    "grep -q 'class User' src/models/user.ts",
    "npm test -- --grep 'User model'"
  ]
}
```

```bash
VERIFICATION_ENABLED=true      # Default: true
VERIFICATION_TIMEOUT=60        # Per-command timeout
```

## Monitoring

```bash
# Activity heartbeat (tail -f brigade/tasks/activity.log)
ACTIVITY_LOG="brigade/tasks/activity.log"
ACTIVITY_LOG_INTERVAL=30

# Worker logs for debugging
WORKER_LOG_DIR="brigade/logs/"

# Timeout warnings (minutes, 0 = disabled)
TASK_TIMEOUT_WARNING_JUNIOR=10
TASK_TIMEOUT_WARNING_SENIOR=20

# Status watch refresh interval
STATUS_WATCH_INTERVAL=30
```

## Phase Reviews

Periodic Executive Chef reviews during long PRD execution:

```bash
PHASE_REVIEW_ENABLED=false
PHASE_REVIEW_AFTER=5           # Review every N tasks

# continue = log and proceed
# pause = stop for manual review
# remediate = add corrective tasks
PHASE_REVIEW_ACTION=continue
```

## Auto-Continue

Chain multiple PRDs for overnight execution:

```bash
./brigade.sh --auto-continue service brigade/tasks/prd-*.json
```

```bash
AUTO_CONTINUE=false

# continue = proceed immediately
# pause = stop after each PRD
# review = Exec Chef reviews before next
PHASE_GATE="continue"
```

## Modules

Optional extensions that hook into Brigade events:

```bash
MODULES="telegram,cost_tracking"
MODULE_TIMEOUT=5

# Telegram
MODULE_TELEGRAM_BOT_TOKEN="your-token"
MODULE_TELEGRAM_CHAT_ID="your-chat"

# Cost tracking
MODULE_COST_TRACKING_OUTPUT="brigade/costs.csv"
```

See [modules.md](modules.md) for writing custom modules.

## Environment Variables

Use env vars for flexibility:

```bash
SOUS_CMD="claude --model ${CLAUDE_MODEL:-sonnet}"
TEST_CMD="${PROJECT_TEST_CMD:-npm test}"
```

## Validation

Invalid values trigger warnings and fall back to defaults:

```
Warning: ESCALATION_AFTER=-1 invalid, using 3
```
