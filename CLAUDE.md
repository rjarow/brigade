# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Brigade?

Brigade is a multi-model AI orchestration framework that routes coding tasks to the right AI based on complexity. It uses a kitchen metaphor: an Executive Chef (Opus) plans and reviews, a Sous Chef (Sonnet) handles complex work, and Line Cooks (GLM/cheaper models) handle routine tasks.

## Roadmap

See `ROADMAP.md` for planned features and recent changes. Check it before starting work.

## Key Commands

```bash
# Plan a feature (generates PRD via Executive Chef)
./brigade.sh plan "Add user authentication with JWT"

# Execute all tasks in a PRD
./brigade.sh service brigade/tasks/prd-feature-name.json

# Run a single task
./brigade.sh ticket brigade/tasks/prd.json US-001

# Check progress (auto-detects active PRD)
./brigade.sh status
./brigade.sh status --watch  # Auto-refresh every 30s
./brigade.sh status --json   # Machine-readable JSON for AI supervisors
./brigade.sh status --brief  # Ultra-compact JSON for low-token polling

# Resume after interruption (retry or skip the failed task)
./brigade.sh resume
./brigade.sh resume brigade/tasks/prd.json retry

# Validate PRD structure
./brigade.sh validate brigade/tasks/prd.json

# Generate summary report from state
./brigade.sh summary brigade/tasks/prd.json

# Generate codebase map (auto-included in future planning)
./brigade.sh map

# Preview execution without running
./brigade.sh --dry-run service brigade/tasks/prd.json

# Chain multiple PRDs for unattended execution
./brigade.sh --auto-continue service brigade/tasks/prd-*.json

# Fully autonomous execution (AI decides retry/skip on failures)
./brigade.sh --walkaway service brigade/tasks/prd.json

# Run tests (requires bats-core)
./tests/run_tests.sh
```

## Architecture

### Core Script
- `brigade.sh` - Main orchestrator (~3500 lines bash). Handles routing, escalation, review, state management, and parallel execution.

### Worker Prompts (chef/)
- `executive.md` - Executive Chef (Opus): Plans PRDs, reviews work, handles rare escalations
- `sous.md` - Sous Chef (Sonnet): Complex tasks, architecture, security
- `line.md` - Line Cook (GLM): Routine tasks, tests, boilerplate

### Claude Code Skills (commands/)
- `brigade-generate-prd.md` - Interactive PRD generation skill
- `brigade-convert-prd-to-json.md` - Convert markdown PRDs to JSON
- `brigade-update-prd.md` - Update existing PRDs conversationally

### Configuration
- `brigade.config` - User configuration (optional, works without it). Hot-reloaded between tasks.
- `brigade.config.example` - Full configuration reference

## Key Functions in brigade.sh

When modifying brigade.sh, these are the important functions:

| Function | Purpose |
|----------|---------|
| `get_prd_prefix` | Extract short prefix from PRD filename for display |
| `format_task_id` | Format task ID with PRD prefix (e.g., "auth/US-001") |
| `run_with_timeout` | Cross-platform timeout wrapper (Linux/macOS) |
| `validate_prd_quick` | Quick PRD validation before service |
| `get_ready_tasks` | Find tasks ready to execute (deps met) |
| `fire_ticket` | Execute a single task with a worker |
| `executive_review` | Run Executive Chef review on completed work |
| `cmd_service` | Main service loop - orchestrates everything |
| `cmd_summary` | Generate markdown report from state |
| `cmd_map` | Generate codebase analysis |

## Review Feedback Loop

When executive review fails:
1. Feedback reason stored in `LAST_REVIEW_FEEDBACK`
2. On next iteration, feedback included in worker prompt
3. Worker sees: "⚠️ PREVIOUS ATTEMPT FAILED EXECUTIVE REVIEW: [reason]"
4. Cleared when review passes or new task starts

## Task Routing

Tasks are routed based on `complexity` field in PRD:
- `"junior"` → Line Cook (tests, boilerplate, CRUD, docs)
- `"senior"` → Sous Chef (architecture, security, integration)
- `"auto"` → Heuristics decide

**The tiers are model-agnostic.** Users configure which tool and model to use for each tier:

```bash
# In brigade.config - example configurations:

# All Claude (default)
EXECUTIVE_CMD="claude --model opus"
SOUS_CMD="claude --model sonnet"
LINE_CMD="claude --model sonnet"

# Mixed providers (cost optimized)
EXECUTIVE_CMD="claude --model opus"
SOUS_CMD="opencode --model anthropic/claude-sonnet-4-5"
LINE_CMD="opencode --model openai/gpt-4o-mini"

# All local (via Ollama through OpenCode)
EXECUTIVE_CMD="opencode --model ollama/llama3"
SOUS_CMD="opencode --model ollama/llama3"
LINE_CMD="opencode --model ollama/llama3"
```

See `brigade.config.example` for full configuration reference.

## Escalation Flow

1. Line Cook fails `ESCALATION_AFTER` times (default: 3) → Sous Chef takes over
2. Sous Chef fails `ESCALATION_TO_EXEC_AFTER` times (default: 5) → Executive Chef takes over
3. Task signals `<promise>BLOCKED</promise>` → Immediate escalation to next tier
4. Worker process exceeds timeout → Killed and treated as BLOCKED

## Process Timeouts

Workers are killed if they exceed their timeout (prevents overnight hangs):
- **Junior (Line Cook)**: 15 minutes (`TASK_TIMEOUT_JUNIOR`)
- **Senior (Sous Chef)**: 30 minutes (`TASK_TIMEOUT_SENIOR`)
- **Executive Chef**: 60 minutes (`TASK_TIMEOUT_EXECUTIVE`)

Uses `timeout` on Linux, `gtimeout` on macOS with coreutils, or fallback background process monitoring.

## Task ID Display

Task IDs are displayed with PRD prefix for clarity across multiple PRDs:
- `add-auth/US-003` instead of just `US-003`
- Prefix extracted from PRD filename: `prd-add-auth.json` → `add-auth`
- Used in all logs, status, escalation messages

## Interrupt Handling

Ctrl+C triggers graceful cleanup:
1. Kills tracked worker processes (SIGTERM, then SIGKILL)
2. Kills background jobs
3. Cleans up temp files
4. Shows: "Run './brigade.sh resume' to continue"

## State Files

The entire `brigade/` directory is typically gitignored. Working files are in `brigade/tasks/`:
- `brigade/tasks/prd-*.json` - PRD files
- `brigade/tasks/prd-*.state.json` - Per-PRD state files
- `brigade/tasks/brigade-learnings.md` - Knowledge shared between workers
- `brigade/tasks/brigade-backlog.md` - Out-of-scope discoveries for future planning
- `brigade/codebase-map.md` - Codebase analysis (from `./brigade.sh map`)

Each PRD gets its own state file: `prd-feature.json` → `prd-feature.state.json`. This isolates state per-PRD and avoids confusion when multiple PRDs exist in the same directory.

State files contain: `sessionId`, `startedAt`, `lastStartTime`, `currentTask`, `taskHistory`, `escalations`, `reviews`, `absorptions`, `phaseReviews`.

## Status Markers

The `status` command uses these markers:
- `✓` - Reviewed and confirmed complete
- `→` - Currently in progress
- `◐` - Worked on, awaiting review
- `○` - Not started yet
- `⬆` - Was escalated to higher tier

## Status Watch Mode

Auto-refreshing status display for monitoring running services:
```bash
./brigade.sh status --watch        # Auto-refresh every 30s
./brigade.sh status --watch --all  # Include all escalations
```

Press Ctrl+C to exit watch mode. Refresh interval configurable via `STATUS_WATCH_INTERVAL`.

## Visibility & Monitoring

Brigade provides several monitoring features for long-running services:

### Activity Heartbeat Log
Periodic status written to a tail-able file:
```bash
# In brigade.config:
ACTIVITY_LOG="brigade/tasks/activity.log"
ACTIVITY_LOG_INTERVAL=30  # seconds

# Monitor:
tail -f brigade/tasks/activity.log
```
Outputs: `[12:45:30] add-auth/US-005: Sous Chef working (3m 45s)`

### Task Timeout Warnings
Warnings when tasks exceed expected duration (separate from hard timeout):
```bash
TASK_TIMEOUT_WARNING_JUNIOR=10  # minutes
TASK_TIMEOUT_WARNING_SENIOR=20
```
Logs: `⚠️ add-auth/US-005 running 45m (expected ~20m for Sous Chef)`

### Worker Output Logging
Persistent logs of all worker conversations for debugging:
```bash
WORKER_LOG_DIR="brigade/logs/"
```
Creates: `add-auth-US-005-sous-2026-01-19-143022.log`

### Supervisor Integration
For AI supervisors or TUI tools to monitor Brigade with minimal token overhead:

```bash
# Compact status JSON written on every state change
SUPERVISOR_STATUS_FILE="brigade/tasks/status.json"

# Append-only JSONL event stream (tail -f friendly)
SUPERVISOR_EVENTS_FILE="brigade/tasks/events.jsonl"
```

**Status file format:**
```json
{"done":3,"total":13,"current":"US-004","worker":"sous","elapsed":125,"attention":false}
```

**Event types:** `service_start`, `task_start`, `task_complete`, `escalation`, `review`, `attention`, `service_complete`

## Configuration

Key config options (in `brigade.config`):
- `QUIET_WORKERS=true` - Suppress conversation output, show spinner instead
- `PHASE_REVIEW_ENABLED=true` - Periodic Executive Chef reviews
- Config is validated on load; invalid values trigger warnings and use defaults

## PRD Format

```json
{
  "featureName": "Feature Name",
  "branchName": "feature/kebab-case",
  "walkaway": false,
  "tasks": [
    {
      "id": "US-001",
      "title": "Task title",
      "acceptanceCriteria": ["Criterion 1", "Criterion 2"],
      "verification": [
        {"type": "pattern", "cmd": "grep -q 'pattern' file.ts"},
        {"type": "unit", "cmd": "npm test -- --grep 'specific'"},
        {"type": "integration", "cmd": "npm test -- --grep 'flow'"},
        {"type": "smoke", "cmd": "./binary --help"}
      ],
      "dependsOn": [],
      "complexity": "junior|senior|auto",
      "passes": false
    }
  ]
}
```

**Note:** The `verification` field supports both string format (backward compatible) and typed object format (recommended). When present, commands are run after worker signals COMPLETE - all must pass (exit 0) for task to be marked done.

**Verification types:**
- `pattern` - File/code existence checks (grep, test -f)
- `unit` - Unit tests for isolated logic
- `integration` - Tests that verify components work together
- `smoke` - Quick checks that the feature runs at all

**Verification strictness:**
- Brigade validates that verification type matches task type:
  - Tasks with "add/create/implement" → need `unit` or `integration` tests
  - Tasks with "connect/integrate/wire" → need `integration` tests
  - Tasks with "flow/workflow/user can" → need `smoke` or `integration` tests
- Walkaway PRDs (`"walkaway": true`) with grep-only verification are **blocked** at service start
- Changed files are scanned for TODO/FIXME markers - task won't complete until addressed
- **Critical:** Tasks that wire/integrate components need integration or smoke tests, not just unit tests. A task like "add download button" passing unit tests doesn't mean downloads actually work end-to-end.

## Debugging

For parallel execution issues or tracking down bugs:

```bash
# Enable debug output (lock tracing, signal detection, completion flow)
BRIGADE_DEBUG=true ./brigade.sh service prd.json

# Force sequential execution (disable parallel)
./brigade.sh --sequential service prd.json

# Check worker logs
ls -la brigade/logs/
```

**Exit codes (30-39 range to avoid collision with tool codes like jq):**
- 0 = COMPLETE
- 1 = needs iteration
- 32 = BLOCKED
- 33 = ALREADY_DONE
- 34 = ABSORBED_BY

## Worker Communication Signals

Workers signal status via XML tags in their output:

| Signal | Return Code | Meaning |
|--------|-------------|---------|
| `<promise>COMPLETE</promise>` | 0 | Task completed successfully |
| `<promise>ALREADY_DONE</promise>` | 33 | Prior task already did this work |
| `<promise>ABSORBED_BY:US-XXX</promise>` | 34 | Work absorbed by specific prior task |
| `<promise>BLOCKED</promise>` | 32 | Cannot proceed, needs escalation |
| `<learning>...</learning>` | - | Share knowledge with team |
| `<backlog>...</backlog>` | - | Log out-of-scope discovery for future planning |

The `ALREADY_DONE` and `ABSORBED_BY` signals skip tests/review since no new code was written.
The `<backlog>` tag captures items outside current scope without blocking - appended to `brigade-backlog.md`.

## Adding New Signals

To add a new worker signal (like `ABSORBED_BY`):

1. Add grep check in `fire_ticket()` (~line 770):
```bash
elif grep -q "<promise>NEW_SIGNAL</promise>" "$output_file" 2>/dev/null; then
  log_event "..." "..."
  rm -f "$output_file"
  return N  # New return code
```

2. Handle return code in task loop in `cmd_service()` (~line 1390):
```bash
elif [ $result -eq N ]; then
  # Handle the new signal
  update_state_task "$prd_path" "$task_id" "$worker" "new_status"
  mark_task_complete "$prd_path" "$task_id"
  return 0
```

3. Update worker prompts in `chef/*.md` to document new signal

4. Update `build_prompt()` instructions (~line 690)

## Philosophy

**Minimal owner disruption**: Interview once during planning, then autonomous execution. Workers escalate to each other, not to the human owner. Only escalate to owner for scope changes, missing credentials, or fundamental blockers.
