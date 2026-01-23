# Walkaway Mode

Walkaway mode enables fully autonomous execution. Instead of prompting you on failures, Executive Chef makes retry/skip decisions automatically. Perfect for overnight runs.

## Enabling Walkaway Mode

Three ways to enable:

```bash
# 1. CLI flag
./brigade.sh --walkaway service prd.json

# 2. Configuration
WALKAWAY_MODE=true

# 3. PRD-level setting
{
  "featureName": "My Feature",
  "walkaway": true,
  "tasks": [...]
}
```

## What Happens in Walkaway Mode

When a task fails repeatedly:

1. **Executive Chef analyzes the failure** - looks at error output, iteration count, and task requirements
2. **Makes a decision** - retry with guidance, skip and continue, or abort the service
3. **Records the decision** - stored in state for auditability
4. **Continues execution** - no human prompt required

### Decision Types

| Decision | When Used |
|----------|-----------|
| **retry** | Transient errors, worker confusion, fixable issues |
| **skip** | Fundamental blockers, missing dependencies, out-of-scope issues |
| **abort** | Critical failures, security concerns, cascade risk |

## Safety Rails

Walkaway mode includes protections against runaway failures:

### Consecutive Skip Limit

```bash
WALKAWAY_MAX_SKIPS=3  # Default
```

If 3 tasks are skipped consecutively, Brigade pauses and requires human intervention. This prevents cascading failures when something is fundamentally broken.

### Scope Decisions

Workers can ask scope questions:

```xml
<scope-question>Should I use OAuth or JWT for authentication?</scope-question>
```

In walkaway mode:

```bash
WALKAWAY_SCOPE_DECISIONS=true  # Default
```

Executive Chef makes the decision and flags it for human review later. All scope decisions are recorded in the state file.

### Decision Timeout

```bash
WALKAWAY_DECISION_TIMEOUT=120  # Seconds
```

If Executive Chef can't decide within the timeout, Brigade pauses for human input.

## Supervisor Fallback

Walkaway mode works with [Supervisor Integration](supervisor.md):

```
Priority Order:
1. Supervisor (if configured and responding)
2. Executive Chef walkaway decision
3. Human prompt (if all else fails)
```

Configure supervisor files and walkaway mode together for robust autonomous execution:

```bash
WALKAWAY_MODE=true
SUPERVISOR_STATUS_FILE="brigade/tasks/status.json"
SUPERVISOR_EVENTS_FILE="brigade/tasks/events.jsonl"
SUPERVISOR_CMD_FILE="brigade/tasks/cmd.json"
```

## When to Use

**Good candidates for walkaway:**

- Well-defined PRDs with clear acceptance criteria
- Tasks with strong verification commands
- Overnight execution of planned work
- CI/CD integration

**Not recommended for:**

- Exploratory work with unclear scope
- PRDs with vague acceptance criteria
- Tasks requiring human judgment (UI/UX decisions)
- First run of a new PRD (run interactively first to catch issues)

## PRD Requirements

Walkaway PRDs have stricter requirements:

### Verification Depth

PRDs with only grep-based verification are **blocked** at service start:

```json
// This will be rejected in walkaway mode:
{
  "verification": ["grep -q 'function' file.ts"]
}

// Add execution tests:
{
  "verification": [
    {"type": "pattern", "cmd": "grep -q 'function' file.ts"},
    {"type": "unit", "cmd": "npm test -- --grep 'specific test'"}
  ]
}
```

### Acceptance Criteria

Vague criteria lead to endless iteration. Be specific:

```json
// Bad - vague
"acceptanceCriteria": ["Works correctly", "Handles errors"]

// Good - verifiable
"acceptanceCriteria": [
  "POST /auth/login returns 200 with valid credentials",
  "Returns 401 and error message on invalid credentials"
]
```

## Monitoring Walkaway Runs

### Activity Log

```bash
ACTIVITY_LOG="brigade/tasks/activity.log"
tail -f brigade/tasks/activity.log
```

### Status Watch

```bash
./brigade.sh status --watch
```

### Decision History

Decisions are stored in the state file:

```bash
jq '.walkawayDecisions' brigade/tasks/prd.state.json
```

## Configuration Reference

```bash
# Enable walkaway mode
WALKAWAY_MODE=false

# Max consecutive skips before pausing
WALKAWAY_MAX_SKIPS=3

# Decision timeout (seconds)
WALKAWAY_DECISION_TIMEOUT=120

# Allow exec chef to decide scope questions
WALKAWAY_SCOPE_DECISIONS=true
```

## Best Practices

1. **Run interactively first** - Test your PRD manually before enabling walkaway
2. **Add strong verification** - Execution tests, not just grep patterns
3. **Monitor the first walkaway run** - Watch logs for unexpected decisions
4. **Review scope decisions** - Check state file after completion
5. **Set up notifications** - Use modules like `telegram` or `webhook` for alerts
