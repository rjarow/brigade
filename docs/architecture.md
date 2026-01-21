# Architecture

For developers working on Brigade itself.

## System Overview

```
┌─────────────────────────────────────────────────────────────┐
│  USER: ./brigade.sh plan|service|status|resume              │
└─────────────────────┬───────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────┐
│  ORCHESTRATOR (brigade.sh)                                   │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐    │
│  │ Router   │  │ State    │  │Escalation│  │ Review   │    │
│  │complexity│  │.state.json│  │tier mgmt │  │exec/phase│    │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘    │
│       └─────────────┴─────────────┴─────────────┘           │
│                         │                                    │
│  ┌──────────────────────▼────────────────────────────────┐  │
│  │  WORKER DISPATCHER: fire_ticket() → signal detection   │  │
│  └──────────────────────┬────────────────────────────────┘  │
└─────────────────────────┼───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│  WORKERS                                                     │
│  ┌──────────┐      ┌──────────┐      ┌──────────────┐       │
│  │LINE COOK │ ──►  │SOUS CHEF │ ──►  │EXECUTIVE CHEF│       │
│  │junior    │      │senior    │      │rare          │       │
│  │LINE_CMD  │      │SOUS_CMD  │      │EXECUTIVE_CMD │       │
│  └──────────┘      └──────────┘      └──────────────┘       │
└─────────────────────────────────────────────────────────────┘
```

## Task Execution Flow

```
PRD.json
    │
    ▼
get_ready_tasks() → find tasks with met dependencies
    │
    ▼
route_task() → determine worker (line/sous)
    │
    ▼
fire_ticket() → execute with timeout
    │
    ▼
Signal Detection: COMPLETE | BLOCKED | ALREADY_DONE | ABSORBED_BY
    │
    ▼
Verification → Tests → Executive Review
    │
    ▼
mark_task_complete() → update PRD.json
```

## State Structure

Per-PRD state files: `prd-X.json` → `prd-X.state.json`

```json
{
  "sessionId": "unique-session-id",
  "startedAt": "2025-01-18T10:00:00Z",
  "lastStartTime": "2025-01-18T14:30:00Z",
  "currentTask": "US-003",
  "taskHistory": [{"taskId": "US-001", "worker": "line", "status": "complete"}],
  "escalations": [{"taskId": "US-002", "from": "line", "to": "sous"}],
  "reviews": [{"taskId": "US-001", "result": "PASS"}],
  "phaseReviews": [...],
  "scopeDecisions": [...]
}
```

## Worker Signals

| Signal | Code | Meaning |
|--------|------|---------|
| `<promise>COMPLETE</promise>` | 0 | Done, run verification |
| `<promise>BLOCKED</promise>` | 32 | Cannot proceed, escalate |
| `<promise>ALREADY_DONE</promise>` | 33 | Prior work did this |
| `<promise>ABSORBED_BY:US-XXX</promise>` | 34 | Prior task did this |
| `<learning>...</learning>` | - | Share knowledge |
| `<backlog>...</backlog>` | - | Log out-of-scope item |
| `<scope-question>...</scope-question>` | - | Ask about requirements |

## File Structure

```
brigade/
├── brigade.sh           # Main orchestrator
├── brigade.config       # User config (optional)
├── chef/
│   ├── executive.md     # Executive Chef prompt
│   ├── sous.md          # Sous Chef prompt
│   └── line.md          # Line Cook prompt
├── commands/            # Claude Code skills
├── modules/             # Optional extensions
├── tasks/               # Working directory (gitignored)
│   ├── prd-*.json
│   ├── prd-*.state.json
│   ├── brigade-learnings.md
│   └── brigade-backlog.md
├── logs/                # Worker output logs
└── tests/
    ├── *.bats           # Test files
    └── mocks/           # Mock workers
```

## Supervisor Integration

For external AI oversight:

```
Brigade                              Supervisor
   │                                     │
   ├── writes events.jsonl ─────────────►│
   │   (task_start, complete, etc.)      │
   │                                     │
   │◄── reads cmd.json ──────────────────┤
   │   (retry, skip, abort)              │
   │                                     │
   └── writes status.json ──────────────►│
       (compact state snapshot)          │
```

## Configuration Hierarchy

```
Defaults (brigade.sh)
    └─► brigade.config
         └─► Environment variables
              └─► PRD settings ("walkaway": true)
                   └─► CLI flags (--walkaway)
```

## Testing

```bash
./tests/run_tests.sh        # All tests
bats tests/state.bats       # Specific file
BRIGADE_DEBUG=true bats ... # With debug output
```

Test files: `state.bats`, `routing.bats`, `review.bats`, `resume.bats`, `verification.bats`, `walkaway.bats`, `supervisor.bats`, `integration.bats`
