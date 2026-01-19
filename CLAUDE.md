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

# Run tests (requires bats-core)
./tests/run_tests.sh
```

## Architecture

### Core Script
- `brigade.sh` - Main orchestrator (~2100 lines bash). Handles routing, escalation, review, state management, and parallel execution.

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

| Function | Line ~  | Purpose |
|----------|---------|---------|
| `validate_prd_quick` | 165 | Quick PRD validation before service |
| `get_ready_tasks` | 270 | Find tasks ready to execute (deps met) |
| `fire_ticket` | 720 | Execute a single task with a worker |
| `executive_review` | 880 | Run Executive Chef review on completed work |
| `cmd_service` | 1500 | Main service loop - orchestrates everything |
| `cmd_validate` | 1920 | Full PRD validation command |

## Task Routing

Tasks are routed based on `complexity` field in PRD:
- `"junior"` → Line Cook (tests, boilerplate, CRUD, docs)
- `"senior"` → Sous Chef (architecture, security, integration)
- `"auto"` → Heuristics decide

## Escalation Flow

1. Line Cook fails `ESCALATION_AFTER` times (default: 3) → Sous Chef takes over
2. Sous Chef fails `ESCALATION_TO_EXEC_AFTER` times (default: 5) → Executive Chef takes over
3. Task signals `<promise>BLOCKED</promise>` → Immediate escalation to next tier

## State Files

The entire `brigade/` directory is typically gitignored. Working files are in `brigade/tasks/`:
- `brigade/tasks/prd-*.json` - PRD files
- `brigade/tasks/prd-*.state.json` - Per-PRD state files (session state, task history, escalations, phaseReviews)
- `brigade/tasks/brigade-learnings.md` - Knowledge shared between workers

Each PRD gets its own state file: `prd-feature.json` → `prd-feature.state.json`. This isolates state per-PRD and avoids confusion when multiple PRDs exist in the same directory.

State files contain: `sessionId`, `startedAt`, `lastStartTime`, `currentTask`, `taskHistory`, `escalations`, `reviews`, `absorptions`, `phaseReviews`.

## Status Markers

The `status` command uses these markers:
- `✓` - Reviewed and confirmed complete
- `→` - Currently in progress
- `◐` - Worked on, awaiting review
- `○` - Not started yet
- `⬆` - Was escalated to higher tier

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
  "tasks": [
    {
      "id": "US-001",
      "title": "Task title",
      "acceptanceCriteria": ["Criterion 1", "Criterion 2"],
      "verification": ["grep -q 'pattern' file.ts", "npm test -- --grep 'test'"],
      "dependsOn": [],
      "complexity": "junior|senior|auto",
      "passes": false
    }
  ]
}
```

**Note:** The `verification` field is optional. When present, commands are run after worker signals COMPLETE - all must pass (exit 0) for task to be marked done. See ROADMAP.md for implementation status.

## Worker Communication Signals

Workers signal status via XML tags in their output:

| Signal | Return Code | Meaning |
|--------|-------------|---------|
| `<promise>COMPLETE</promise>` | 0 | Task completed successfully |
| `<promise>ALREADY_DONE</promise>` | 3 | Prior task already did this work |
| `<promise>ABSORBED_BY:US-XXX</promise>` | 4 | Work absorbed by specific prior task |
| `<promise>BLOCKED</promise>` | 2 | Cannot proceed, needs escalation |
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
