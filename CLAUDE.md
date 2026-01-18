# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Brigade?

Brigade is a multi-model AI orchestration framework that routes coding tasks to the right AI based on complexity. It uses a kitchen metaphor: an Executive Chef (Opus) plans and reviews, a Sous Chef (Sonnet) handles complex work, and Line Cooks (GLM/cheaper models) handle routine tasks.

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

# Validate PRD structure
./brigade.sh validate brigade/tasks/prd.json

# Preview execution without running
./brigade.sh --dry-run service brigade/tasks/prd.json
```

## Architecture

### Core Script
- `brigade.sh` - Main orchestrator (~2000 lines bash). Handles routing, escalation, review, state management, and parallel execution.

### Worker Prompts (chef/)
- `executive.md` - Executive Chef (Opus): Plans PRDs, reviews work, handles rare escalations
- `sous.md` - Sous Chef (Sonnet): Complex tasks, architecture, security
- `line.md` - Line Cook (GLM): Routine tasks, tests, boilerplate

### Claude Code Skills (commands/)
- `brigade-generate-prd.md` - Interactive PRD generation skill
- `brigade-convert-prd-to-json.md` - Convert markdown PRDs to JSON

### Configuration
- `brigade.config` - User configuration (optional, works without it). Hot-reloaded between tasks.
- `brigade.config.example` - Full configuration reference

## Task Routing

Tasks are routed based on `complexity` field in PRD:
- `"junior"` → Line Cook (tests, boilerplate, CRUD, docs)
- `"senior"` → Sous Chef (architecture, security, integration)
- `"auto"` → Heuristics decide

## Escalation Flow

1. Line Cook fails `ESCALATION_AFTER` times (default: 3) → Sous Chef takes over
2. Sous Chef fails `ESCALATION_TO_EXEC_AFTER` times (default: 5) → Executive Chef takes over
3. Task signals `<promise>BLOCKED</promise>` → Immediate escalation to next tier

Configuration in `brigade.config`:
```bash
ESCALATION_ENABLED=true       # Enable Line Cook → Sous Chef
ESCALATION_AFTER=3            # Iterations before escalating

ESCALATION_TO_EXEC=true       # Enable Sous Chef → Executive Chef
ESCALATION_TO_EXEC_AFTER=5    # Iterations before escalating
```

## State Files

The entire `brigade/` directory is typically gitignored (it's a cloned tool, not part of your project). Working files are kept in `brigade/tasks/`:
- `brigade/tasks/prd-*.json` - PRD files
- `brigade/tasks/brigade-state.json` - Session state, task history, escalations
- `brigade/tasks/brigade-learnings.md` - Knowledge shared between workers via `<learning>` tags

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
      "dependsOn": [],
      "complexity": "junior|senior|auto",
      "passes": false
    }
  ]
}
```

## Worker Communication

Workers signal completion/blocking via XML tags:
- `<promise>COMPLETE</promise>` - Task completed successfully
- `<promise>BLOCKED</promise>` - Cannot proceed, needs escalation
- `<learning>...</learning>` - Share knowledge with team

## Philosophy

**Minimal owner disruption**: Interview once during planning, then autonomous execution. Workers escalate to each other, not to the human owner. Only escalate to owner for scope changes, missing credentials, or fundamental blockers.
