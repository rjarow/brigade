# Brigade Reference

> **This is the source of truth.** Individual doc files are generated from this file.
> Run `./docs/generate.sh` to regenerate after edits.

<!-- section: index -->
# Brigade

**Multi-model AI orchestration for coding tasks.**

Brigade routes coding tasks to the right AI based on complexity. Using a kitchen metaphor: an Executive Chef (Opus) plans and reviews, a Sous Chef (Sonnet) handles complex work, and Line Cooks (cheaper models) handle routine tasks.

## Quick Start

Brigade has two implementations with identical CLI - use whichever you prefer:

```bash
# Bash version (works out of the box)
./brigade.sh init
./brigade.sh plan "Add user authentication with JWT"
./brigade.sh service

# Go version (build first, then same commands)
go build -o brigade-go ./cmd/brigade
./brigade-go init
./brigade-go plan "Add user authentication with JWT"
./brigade-go service
```

Both versions share the same config files, PRD format, and state files.

## The Kitchen

| Role | Model | Responsibility |
|------|-------|----------------|
| **Executive Chef** | Opus | Plans PRDs, reviews work, handles rare escalations |
| **Sous Chef** | Sonnet | Complex tasks, architecture, security |
| **Line Cook** | GLM/cheaper | Routine tasks, tests, boilerplate |

Tasks are routed by complexity:
- `junior` tasks go to Line Cook
- `senior` tasks go to Sous Chef
- `auto` lets Brigade decide

Workers escalate automatically when stuck:

```
Line Cook fails 3x → Sous Chef takes over
Sous Chef fails 5x → Executive Chef steps in
```

<!-- section: getting-started -->
# Getting Started

Get your kitchen running in 5 minutes.

## Quick Start (Claude Code)

The easiest way to use Brigade is through Claude Code.

**1. Clone Brigade into your project:**
```bash
cd your-project
git clone https://github.com/rjarow/brigade.git
```

**2. Start Claude Code and use the skill:**
```
You: /brigade plan "Add user authentication with JWT"

Claude: I'll help you plan that feature. A few questions first...
        [Interviews you about scope]
        [Generates PRD with tasks]
        Ready to execute?

You: yes

Claude: [Runs service, reports progress]
        Done! 8/8 tasks complete.
```

### Skill Commands

| Command | What it does |
|---------|--------------|
| `/brigade` | Show options |
| `/brigade plan "X"` | Plan a feature |
| `/brigade run` | Execute PRD |
| `/brigade status` | Check progress |
| `/brigade quick "X"` | One-off task, no PRD |

## CLI Usage

For automation, CI/CD, or terminal use.

### Choose Your Version

| Version | Install | Best For |
|---------|---------|----------|
| **Bash** | Works out of the box | Default, production-tested |
| **Go** | `go build -o brigade-go ./cmd/brigade` | Better errors, type safety |

### Prerequisites

**For Bash version:**
- **Claude CLI** (`claude`) - required
- **jq** - for JSON processing
- **bash** 4.0+

**For Go version:**
- **Go 1.21+** - to build
- **Claude CLI** (`claude`) - required

### First Run

```bash
./brigade.sh init    # Setup wizard
./brigade.sh demo    # See what it does
```

### Your First Feature

```bash
# 1. Plan
./brigade.sh plan "Add user authentication"

# 2. Review
cat brigade/tasks/prd-*.json | jq

# 3. Execute
./brigade.sh service

# 4. Monitor
./brigade.sh status --watch
```

### Handling Interruptions

Ctrl+C anytime. Resume later:

```bash
./brigade.sh resume          # Auto-detect, prompt retry/skip
./brigade.sh resume retry    # Retry failed task
./brigade.sh resume skip     # Skip and continue
```

<!-- section: commands -->
# Commands

Complete reference for Brigade CLI commands.

> All commands work with both `./brigade.sh` (Bash) and `./brigade-go` (Go).

## Setup

### init

First-time setup wizard. Checks tools, creates config.

```bash
./brigade.sh init
```

### demo

Preview what Brigade does without executing.

```bash
./brigade.sh demo
```

## Planning

### plan

Generate a PRD via Executive Chef.

```bash
./brigade.sh plan "Add user authentication with JWT"
```

The Executive Chef will:
1. Ask clarifying questions about scope
2. Analyze your codebase
3. Generate a PRD with tasks

### template

Generate PRD from a template.

```bash
./brigade.sh template                  # List templates
./brigade.sh template api users        # REST API for "users"
./brigade.sh template auth             # Auth system
```

### validate

Validate PRD structure and quality.

```bash
./brigade.sh validate brigade/tasks/prd.json
```

Checks: JSON syntax, required fields, dependency cycles, acceptance criteria quality, verification coverage.

### map

Generate codebase analysis (auto-included in future planning).

```bash
./brigade.sh map
```

Creates `codebase-map.md` with structure, patterns, and tech stack.

## Execution

### service

Execute all tasks in a PRD.

```bash
./brigade.sh service brigade/tasks/prd.json
```

#### Flags

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview execution without running |
| `--walkaway` | AI decides retry/skip on failures |
| `--auto-continue` | Chain multiple PRDs |
| `--sequential` | Force sequential execution (no parallelism) |

#### Partial Execution

```bash
./brigade.sh --only US-001,US-003 service prd.json   # Run specific tasks
./brigade.sh --skip US-007 service prd.json          # Skip specific tasks
./brigade.sh --from US-003 service prd.json          # Start from task
./brigade.sh --until US-005 service prd.json         # Run up to task
```

### ticket

Run a single task.

```bash
./brigade.sh ticket brigade/tasks/prd.json US-001
```

### resume

Resume after interruption.

```bash
./brigade.sh resume                         # Auto-detect, prompt retry/skip
./brigade.sh resume brigade/tasks/prd.json  # Specify PRD
./brigade.sh resume retry                   # Retry failed task
./brigade.sh resume skip                    # Skip and continue
```

### iterate

Quick tweak on completed PRD.

```bash
./brigade.sh iterate "make the button blue"
```

Creates a micro-PRD and executes it.

## Monitoring

### status

Check progress.

```bash
./brigade.sh status                    # Current state
./brigade.sh status --watch            # Auto-refresh every 30s
./brigade.sh status --json             # Machine-readable JSON
./brigade.sh status --brief            # Ultra-compact JSON
```

#### Status Symbols

| Symbol | Meaning |
|--------|---------|
| `✓` | Complete and reviewed |
| `→` | Currently in progress |
| `◐` | Worked on, awaiting review |
| `○` | Not started |
| `⬆` | Was escalated |

### summary

Generate markdown report from state.

```bash
./brigade.sh summary brigade/tasks/prd.json
```

### cost

Show estimated cost breakdown.

```bash
./brigade.sh cost brigade/tasks/prd.json
```

### risk

Pre-execution risk assessment.

```bash
./brigade.sh risk brigade/tasks/prd.json
./brigade.sh risk --history brigade/tasks/prd.json  # Include historical patterns
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success / COMPLETE |
| 1 | General error / needs iteration |
| 32 | BLOCKED - task cannot proceed |
| 33 | ALREADY_DONE - prior task completed this |
| 34 | ABSORBED_BY - work absorbed by another task |

<!-- section: how-it-works -->
# How Brigade Works

The kitchen runs itself. Here's what's happening behind the scenes.

## The Flow

```
You: "Add user authentication"
          ↓
   ┌──────────────────────────┐
   │  PLANNING (Executive Chef) │
   │  Interview → Analyze → PRD │
   └────────────┬─────────────┘
                ↓
   ┌──────────────────────────┐
   │  EXECUTION (per task)     │
   │                           │
   │  Line Cook tries it       │
   │       ↓ (stuck?)          │
   │  Sous Chef takes over     │
   │       ↓ (still stuck?)    │
   │  Executive Chef steps in  │
   │       ↓                   │
   │  Tests run → Review       │
   └────────────┬─────────────┘
                ↓
         ✅ Order up!
```

## Planning Phase

When you run `./brigade.sh plan "..."`:

1. **Interview** - Executive Chef asks clarifying questions upfront
2. **Analysis** - Explores your codebase (structure, patterns, stack)
3. **PRD** - Generates tasks with acceptance criteria and dependencies

Each task gets:
- Clear scope and acceptance criteria
- Complexity assignment (junior/senior)
- Dependencies on other tasks
- Verification commands

## Execution Phase

### Task Routing

| Complexity | Who Cooks | Best For |
|------------|-----------|----------|
| `junior` | Line Cook | Tests, CRUD, boilerplate |
| `senior` | Sous Chef | Architecture, security, judgment calls |
| `auto` | Kitchen decides | Analyzes task to pick |

### Automatic Escalation

Workers escalate within the team, not to you:

```
Line Cook fails 3x (or times out, or says BLOCKED)
    → Sous Chef takes over

Sous Chef fails 5x (or times out, or says BLOCKED)
    → Executive Chef steps in
```

Thresholds are configurable. Timer resets when escalating.

### Fresh Context

Each task starts clean - no conversation history bleeding through. Knowledge is shared explicitly via `<learning>` tags that get stored and retrieved for relevant future tasks.

### Completion Signals

Workers signal status with special tags:

| Signal | Meaning |
|--------|---------|
| `COMPLETE` | Done, run tests and review |
| `BLOCKED` | Can't proceed, escalate me |
| `ALREADY_DONE` | Prior task did this, skip tests |
| `ABSORBED_BY:US-XXX` | Another task covered this |

### Verification

If the PRD has verification commands, they run after `COMPLETE`:
- All pass → continue to review
- Any fail → worker iterates with feedback

### Executive Review

If `REVIEW_ENABLED=true`, Executive Chef reviews completed work:
- Were acceptance criteria met?
- Does it follow project patterns?
- Any obvious issues?

Failed review → worker iterates with feedback.

## State Management

Each PRD gets its own state file: `prd-feature.json` → `prd-feature.state.json`

Contains:
- Session timing
- Task history (who did what, when)
- Escalations and reviews
- Current task (for resume)

## Interrupts

Ctrl+C anytime. Brigade:
1. Kills worker processes gracefully
2. Cleans up temp files
3. Saves state for resume

Run `./brigade.sh resume` to pick up where you left off.

<!-- section: writing-prds -->
# Writing PRDs

A good PRD is the difference between "fire and forget" and "babysitting the AI all night."

## Structure

```json
{
  "featureName": "Feature Name",
  "branchName": "feature/feature-name",
  "walkaway": false,
  "tasks": [
    {
      "id": "US-001",
      "title": "Short descriptive title",
      "description": "As a user, I want X so that Y",
      "acceptanceCriteria": ["Criterion 1", "Criterion 2"],
      "verification": ["grep -q 'pattern' file.ts"],
      "dependsOn": [],
      "complexity": "junior|senior|auto",
      "passes": false
    }
  ]
}
```

## Fields

| Field | Required | Description |
|-------|----------|-------------|
| `featureName` | Yes | Human-readable feature name |
| `branchName` | Yes | Git branch for the feature |
| `walkaway` | No | Enable autonomous execution |
| `tasks` | Yes | Array of task objects |

### Task Fields

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Unique ID (e.g., `US-001`) |
| `title` | Yes | Short descriptive title |
| `description` | No | User story format |
| `acceptanceCriteria` | Yes | Array of verifiable criteria |
| `verification` | No | Commands to verify completion |
| `dependsOn` | Yes | Array of task IDs this depends on |
| `complexity` | Yes | `junior`, `senior`, or `auto` |
| `passes` | Yes | Set to `false` initially |

## Walkaway Mode

Set `"walkaway": true` when the PRD runs unattended. This tells Brigade to:
- Make autonomous retry/skip decisions
- Require more explicit acceptance criteria
- Enforce stricter verification requirements

## Complexity

| Level | Route To | Best For |
|-------|----------|----------|
| `junior` | Line Cook | Tests, CRUD, boilerplate, following patterns |
| `senior` | Sous Chef | Architecture, security, judgment calls |
| `auto` | Heuristics | Let Brigade decide |

## Dependencies

```json
{"id": "US-001", "dependsOn": []},
{"id": "US-002", "dependsOn": ["US-001"]},
{"id": "US-003", "dependsOn": ["US-001"]},     // Parallel with US-002
{"id": "US-004", "dependsOn": ["US-002", "US-003"]}  // Waits for both
```

Avoid circular dependencies - they cause hangs.

## Verification Commands

Optional safety net after worker signals COMPLETE:

```json
"verification": [
  {"type": "pattern", "cmd": "grep -q 'class User' src/models/user.ts"},
  {"type": "unit", "cmd": "npm test -- --grep 'User model'"},
  {"type": "integration", "cmd": "npm test -- --grep 'auth flow'"},
  {"type": "smoke", "cmd": "./bin/app --help"}
]
```

### Verification Types

| Type | Purpose |
|------|---------|
| `pattern` | File/code existence checks |
| `unit` | Unit tests for isolated logic |
| `integration` | Tests that verify components work together |
| `smoke` | Quick checks that the feature runs |

Guidelines:
- **Fast** - Seconds, not minutes
- **Simple** - grep, file checks, targeted tests
- **Deterministic** - No network or timing dependencies

## Good vs Bad

**Acceptance Criteria:**
```json
// Good - verifiable
["POST /auth/login accepts email and password",
 "Returns 401 on invalid credentials"]

// Bad - vague
["Works correctly", "Handles errors well"]
```

**Task Sizing:**
- 1-5 acceptance criteria
- Touches 1-3 files
- Describable in 2-3 sentences

<!-- section: configuration -->
# Configuration

All settings go in `brigade.config`. Everything is optional - Brigade works without it.

## Config File Location

Place `brigade.config` inside the Brigade directory:

```
your-project/
├── brigade/              # Brigade installation
│   ├── brigade.sh
│   ├── brigade.config    # ← Config here
│   └── ...
├── src/
└── ...
```

Run `./brigade.sh init` to create a starter config.

## Workers

| Option | Default | Description |
|--------|---------|-------------|
| `EXECUTIVE_CMD` | `claude --model opus` | Command for Executive Chef |
| `SOUS_CMD` | `claude --model sonnet` | Command for Sous Chef |
| `LINE_CMD` | `claude --model sonnet` | Command for Line Cook |
| `USE_OPENCODE` | `false` | Use OpenCode for Line Cook |
| `OPENCODE_MODEL` | `zai-coding-plan/glm-4.7` | Model when USE_OPENCODE=true |

## Escalation

| Option | Default | Description |
|--------|---------|-------------|
| `ESCALATION_ENABLED` | `true` | Enable automatic escalation |
| `ESCALATION_AFTER` | `3` | Iterations before Line Cook → Sous Chef |
| `ESCALATION_TO_EXEC` | `true` | Enable escalation to Executive Chef |
| `ESCALATION_TO_EXEC_AFTER` | `5` | Iterations before Sous Chef → Executive Chef |

## Timeouts

| Option | Default | Description |
|--------|---------|-------------|
| `TASK_TIMEOUT_JUNIOR` | `900` | Line Cook timeout (15 min) |
| `TASK_TIMEOUT_SENIOR` | `1800` | Sous Chef timeout (30 min) |
| `TASK_TIMEOUT_EXECUTIVE` | `3600` | Executive Chef timeout (60 min) |

## Reviews

| Option | Default | Description |
|--------|---------|-------------|
| `REVIEW_ENABLED` | `true` | Executive Chef reviews work |
| `REVIEW_JUNIOR_ONLY` | `true` | Only review Line Cook work |
| `PHASE_REVIEW_ENABLED` | `false` | Periodic reviews during long PRDs |
| `PHASE_REVIEW_AFTER` | `5` | Review every N tasks |

## Verification

| Option | Default | Description |
|--------|---------|-------------|
| `VERIFICATION_ENABLED` | `true` | Run verification commands |
| `VERIFICATION_TIMEOUT` | `60` | Per-command timeout |
| `TODO_SCAN_ENABLED` | `true` | Block on TODO/FIXME markers |
| `VERIFICATION_WARN_GREP_ONLY` | `true` | Warn on grep-only verification |

## Walkaway Mode

| Option | Default | Description |
|--------|---------|-------------|
| `WALKAWAY_MODE` | `false` | AI decides retry/skip |
| `WALKAWAY_MAX_SKIPS` | `3` | Max consecutive skips |
| `WALKAWAY_DECISION_TIMEOUT` | `120` | Seconds for AI decision |
| `WALKAWAY_SCOPE_DECISIONS` | `true` | Let exec chef decide scope questions |

## Smart Retry

| Option | Default | Description |
|--------|---------|-------------|
| `SMART_RETRY_ENABLED` | `true` | Enable failure classification |
| `SMART_RETRY_CUSTOM_PATTERNS` | *(empty)* | Custom `pattern:category` pairs |
| `SMART_RETRY_APPROACH_HISTORY_MAX` | `3` | Max approaches in retry prompt |

## Supervisor Integration

| Option | Default | Description |
|--------|---------|-------------|
| `SUPERVISOR_STATUS_FILE` | *(empty)* | Path for status JSON |
| `SUPERVISOR_EVENTS_FILE` | *(empty)* | Path for JSONL events |
| `SUPERVISOR_CMD_FILE` | *(empty)* | Path for command ingestion |
| `SUPERVISOR_CMD_TIMEOUT` | `300` | Max wait for supervisor |

## Monitoring

| Option | Default | Description |
|--------|---------|-------------|
| `QUIET_WORKERS` | `false` | Show spinner instead of output |
| `ACTIVITY_LOG` | *(empty)* | Path for heartbeat log |
| `WORKER_LOG_DIR` | *(empty)* | Directory for worker logs |

## Modules

| Option | Default | Description |
|--------|---------|-------------|
| `MODULES` | *(empty)* | Comma-separated module list |
| `MODULE_TIMEOUT` | `5` | Max seconds per handler |

## Parallel Execution

| Option | Default | Description |
|--------|---------|-------------|
| `MAX_PARALLEL` | `3` | Max concurrent workers |

## Limits

| Option | Default | Description |
|--------|---------|-------------|
| `MAX_ITERATIONS` | `50` | Max iterations per task |

<!-- section: features/walkaway-mode -->
# Walkaway Mode

Walkaway mode enables fully autonomous execution. Instead of prompting you on failures, Executive Chef makes retry/skip decisions automatically.

## Enabling

Three ways to enable:

```bash
# CLI flag
./brigade.sh --walkaway service prd.json

# Configuration
WALKAWAY_MODE=true

# PRD-level setting
{ "walkaway": true, ... }
```

## What Happens

When a task fails repeatedly:

1. **Executive Chef analyzes the failure** - error output, iteration count, task requirements
2. **Makes a decision** - retry with guidance, skip and continue, or abort
3. **Records the decision** - stored in state for auditability
4. **Continues execution** - no human prompt

### Decision Types

| Decision | When Used |
|----------|-----------|
| **retry** | Transient errors, worker confusion, fixable issues |
| **skip** | Fundamental blockers, missing dependencies |
| **abort** | Critical failures, security concerns, cascade risk |

## Safety Rails

### Consecutive Skip Limit

```bash
WALKAWAY_MAX_SKIPS=3  # Default
```

If 3 tasks skip consecutively, Brigade pauses for human intervention.

### Scope Decisions

Workers can ask scope questions with `<scope-question>` tag. In walkaway mode, Executive Chef decides and flags for human review later.

## PRD Requirements

Walkaway PRDs have stricter requirements:

- **Verification depth** - grep-only verification is blocked
- **Clear acceptance criteria** - vague criteria lead to endless iteration

## When to Use

**Good candidates:**
- Well-defined PRDs with clear acceptance criteria
- Tasks with strong verification commands
- Overnight execution

**Not recommended:**
- Exploratory work with unclear scope
- First run of a new PRD

<!-- section: features/smart-retries -->
# Smart Retries

Brigade learns from failures instead of repeating them.

## Error Classification

Failures are categorized automatically:

| Category | Examples |
|----------|----------|
| **syntax** | Parse errors, compilation failures |
| **integration** | Network errors, API failures, timeouts |
| **environment** | Missing files, permission denied |
| **logic** | Test failures, assertion errors |

## Approach Tracking

Workers declare strategy using `<approach>`:

```xml
<approach>Direct API integration with retry logic</approach>
```

On retry, previous approaches appear:

```
PREVIOUS APPROACHES (avoid repeating these):
- Direct API integration → integration: Connection refused
- Raw HTTP requests → integration: timeout

Try a DIFFERENT approach.
```

## Strategy Suggestions

Based on error category, workers receive suggestions:

| Category | Suggestions |
|----------|-------------|
| **integration** | Mock the service, use test doubles |
| **environment** | Check file paths, verify permissions |
| **syntax** | Check language version, verify imports |
| **logic** | Re-read acceptance criteria, check edge cases |

## Escalation Context

When escalating, the new worker sees what was tried:

```
=== ESCALATION CONTEXT ===
Escalated from Line Cook after multiple failures.

Attempted approaches:
- line: Direct API call → integration
- line: Retry with timeout → integration

Do NOT repeat these approaches.
===========================
```

## Configuration

```bash
SMART_RETRY_ENABLED=true
SMART_RETRY_CUSTOM_PATTERNS="MyError:logic,ServiceDown:integration"
SMART_RETRY_APPROACH_HISTORY_MAX=3
```

<!-- section: features/supervisor -->
# Supervisor Integration

Brigade supports external AI supervisors that monitor execution and make decisions.

## Architecture

```
User (natural language)
    |
Supervisor (Claude, custom AI)
    |--- reads status.json, events.jsonl
    |--- writes cmd.json
    |
Brigade (execution engine)
    |
Workers (task-level AI)
```

## File-Based Integration

### Status File

Compact JSON on every state change:

```json
{
  "done": 3,
  "total": 13,
  "current": "US-004",
  "worker": "sous",
  "elapsed": 125,
  "attention": false
}
```

### Events File

Append-only JSONL stream:

```bash
tail -f brigade/tasks/events.jsonl | jq
```

Event types: `service_start`, `task_start`, `task_complete`, `escalation`, `review`, `attention`, `decision_needed`, `decision_received`, `service_complete`

### Command File

Supervisor writes commands:

```json
{
  "decision": "d-123",
  "action": "retry",
  "reason": "Transient error",
  "guidance": "Try mocking the API"
}
```

Actions: `retry`, `skip`, `abort`, `pause`

## Configuration

```bash
SUPERVISOR_STATUS_FILE="brigade/tasks/status.json"
SUPERVISOR_EVENTS_FILE="brigade/tasks/events.jsonl"
SUPERVISOR_CMD_FILE="brigade/tasks/cmd.json"
SUPERVISOR_CMD_POLL_INTERVAL=2
SUPERVISOR_CMD_TIMEOUT=300
```

<!-- section: modules -->
# Modules

Brigade supports optional modules that hook into the orchestration lifecycle.

## Enabling

```bash
MODULES="telegram,cost_tracking"
MODULE_TELEGRAM_BOT_TOKEN="your-token"
MODULE_TELEGRAM_CHAT_ID="your-chat-id"
```

## Available Modules

| Module | Description |
|--------|-------------|
| `telegram` | Telegram notifications |
| `desktop` | Desktop notifications (macOS/Linux) |
| `terminal` | Terminal bell + colored banners |
| `webhook` | Webhooks for Slack/Discord |
| `cost_tracking` | Log task durations to CSV |

## Writing Custom Modules

Create `modules/mymodule.sh`:

```bash
#!/bin/bash

# REQUIRED: Declare events to receive
module_mymodule_events() {
  echo "task_complete escalation service_complete"
}

# OPTIONAL: Initialize (return non-zero to disable)
module_mymodule_init() {
  [ -z "$MODULE_MYMODULE_API_KEY" ] && return 1
  return 0
}

# Event handlers
module_mymodule_on_task_complete() {
  local task_id="$1" worker="$2" duration="$3"
  # Your code here
}
```

## Events

| Event | Arguments |
|-------|-----------|
| `service_start` | prd, total_tasks |
| `task_start` | task_id, worker |
| `task_complete` | task_id, worker, duration |
| `task_blocked` | task_id, worker |
| `escalation` | task_id, from_worker, to_worker |
| `review` | task_id, result |
| `attention` | task_id, reason |
| `service_complete` | completed, failed, duration |

## Behavior

- **Async** - Non-blocking, don't slow down Brigade
- **Isolated** - Module failures don't crash core
- **Timeout** - Killed after `MODULE_TIMEOUT` seconds

<!-- section: troubleshooting -->
# Troubleshooting

## Quick Fixes

| Symptom | Fix |
|---------|-----|
| Task loops without progress | Acceptance criteria too vague - make them specific |
| "command not found: opencode" | Install OpenCode or set `USE_OPENCODE=false` |
| "Could not acquire lock" | Remove stale lock: `rm brigade/tasks/*.lock` |
| Worker times out | Increase timeout or break task into smaller pieces |

## Debug Mode

```bash
BRIGADE_DEBUG=true ./brigade.sh service prd.json
```

Shows lock timing, signal detection, and task flow details.

## Worker Logs

```bash
WORKER_LOG_DIR="brigade/logs/"
ls brigade/logs/
cat brigade/logs/auth-US-003-sous-*.log
```

## Common Issues

### Task keeps iterating

Usually caused by vague acceptance criteria:

```json
// Bad
"acceptanceCriteria": ["Works correctly"]

// Good
"acceptanceCriteria": ["POST /login returns 200 with valid credentials"]
```

### Rapid escalation

1. Check if task needs credentials or external access
2. Review acceptance criteria for clarity
3. Run task manually to see full output

### Walkaway aborts early

"Aborting after X consecutive skips" means multiple tasks failed.

1. Check for fundamental blocker (missing dependency, wrong branch)
2. Run interactively to investigate

## State Recovery

### After crash

```bash
rm brigade/tasks/*.lock    # Remove stale locks
./brigade.sh resume        # Resume execution
```

### Corrupted state

Brigade auto-backs up corrupt files:

```bash
ls brigade/tasks/*.state.json.backup.*
cp brigade/tasks/prd.state.json.backup.12345 brigade/tasks/prd.state.json
```
