# Brigade Architecture

## System Overview

```
+-------------------------------------------------------------------------+
|                           USER INTERFACE                                 |
|  ./brigade.sh plan|service|status|resume|ticket|validate|map            |
+-----------------------------------+-------------------------------------+
                                    |
+-----------------------------------v-------------------------------------+
|                           ORCHESTRATOR (brigade.sh)                      |
|  +-------------+  +--------------+  +-------------+  +--------------+   |
|  | Task Router |  | State Manager|  | Escalation  |  | Review Engine|   |
|  | complexity  |  | .state.json  |  | tier mgmt   |  | exec review  |   |
|  | heuristics  |  | history      |  | timeouts    |  | phase review |   |
|  +------+------+  +------+-------+  +------+------+  +------+-------+   |
|         |                |                 |                |           |
|  +------v-----------------v-----------------v----------------v-------+  |
|  |                      WORKER DISPATCHER                            |  |
|  |  fire_ticket() -> run_with_timeout() -> signal detection          |  |
|  +------+------------------------------------------------------------+  |
+---------+---------------------------------------------------------------+
          |
+---------v---------------------------------------------------------------+
|                           WORKER TIER                                    |
|  +-------------+      +-------------+      +---------------------+      |
|  | LINE COOK   |      | SOUS CHEF   |      | EXECUTIVE CHEF      |      |
|  | (junior)    | ---> | (senior)    | ---> | (rare escalation)   |      |
|  |             |      |             |      |                     |      |
|  | LINE_CMD    |      | SOUS_CMD    |      | EXECUTIVE_CMD       |      |
|  | chef/line.md|      | chef/sous.md|      | chef/executive.md   |      |
|  +-------------+      +-------------+      +---------------------+      |
+---------+---------------------------------------------------------------+
          |
+---------v---------------------------------------------------------------+
|                           EXTERNAL TOOLS                                 |
|  +-------------+  +-------------+  +-------------+  +-------------+     |
|  | Claude CLI  |  | OpenCode    |  | Git         |  | Test Runner |     |
|  | claude      |  | opencode    |  | git diff    |  | TEST_CMD    |     |
|  +-------------+  +-------------+  +-------------+  +-------------+     |
+-------------------------------------------------------------------------+
```

## Key Components

### Task Router (`route_task()`)

Routes tasks to appropriate worker tier based on complexity:

```
PRD task.complexity
       |
       +---> "junior" ---> Line Cook (LINE_CMD)
       |
       +---> "senior" ---> Sous Chef (SOUS_CMD)
       |
       +---> "auto"   ---> Heuristics based on title/criteria
```

**Heuristics for "auto":**
- Tasks with words like "architecture", "security", "design" -> senior
- Tasks with many acceptance criteria (>5) -> senior
- Tasks with words like "test", "add", "simple" -> junior

### State Manager

Maintains per-PRD state files: `prd-X.json` -> `prd-X.state.json`

**State structure:**
```json
{
  "sessionId": "unique-session-id",
  "startedAt": "2025-01-18T10:00:00Z",
  "lastStartTime": "2025-01-18T14:30:00Z",
  "currentTask": "US-003",
  "taskHistory": [
    {"taskId": "US-001", "worker": "line", "status": "complete", "timestamp": "..."}
  ],
  "escalations": [
    {"taskId": "US-002", "from": "line", "to": "sous", "reason": "Max iterations"}
  ],
  "reviews": [
    {"taskId": "US-001", "result": "PASS", "reason": "Meets criteria"}
  ],
  "phaseReviews": [...],
  "walkawayDecisions": [...],
  "scopeDecisions": [...]
}
```

### Escalation Engine

Three-tier escalation with configurable triggers:

```
Line Cook (junior tasks)
    |
    +-- After ESCALATION_AFTER failures (default: 3)
    +-- After TASK_TIMEOUT_JUNIOR (default: 15 min)
    +-- On BLOCKED signal
    |
    v
Sous Chef (senior tasks)
    |
    +-- After ESCALATION_TO_EXEC_AFTER failures (default: 5)
    +-- After TASK_TIMEOUT_SENIOR (default: 30 min)
    +-- On BLOCKED signal
    |
    v
Executive Chef (rare, for truly stuck tasks)
```

### Worker Dispatcher (`fire_ticket()`)

Manages worker execution lifecycle:

1. **Build prompt** from chef template + task + learnings + feedback
2. **Run worker** with timeout via `run_with_timeout()`
3. **Monitor health** via PID checks (detect crashes)
4. **Parse output** for completion signals
5. **Extract learnings** and backlog items

### Review Engine

Two types of review:

**Executive Review (`executive_review()`):**
- Per-task quality gate
- Reviews work against acceptance criteria
- Returns PASS/FAIL with reason
- Configurable: skip senior work, junior only, etc.

**Phase Review (`phase_review()`):**
- Periodic progress check (every N completions)
- Reviews overall progress, not individual tasks
- Can trigger remediation actions

## Data Flow

```
PRD.json
    |
    v
get_ready_tasks() ---> find tasks with met dependencies
    |
    v
route_task() ---> determine worker tier (line/sous)
    |
    v
fire_ticket() ---> execute with timeout
    |
    v
+------------------+
| Worker Process   |
| (external CLI)   |
+--------+---------+
         |
+--------v---------------------------+
|       Signal Detection             |
|  COMPLETE | BLOCKED | ALREADY_DONE |
|  ABSORBED_BY | scope-question      |
+--------+---------------------------+
         |
+--------v---------------------------+
|     Verification Pipeline          |
|  run_verification()                |
|  scan_todos()                      |
|  check_manual_verification()       |
|  run tests (TEST_CMD)              |
|  executive_review()                |
+--------+---------------------------+
         |
+--------v--------+
| mark_task_complete()
| Update PRD.json |
+-----------------+
```

## File Structure

```
brigade/
|-- brigade.sh              # Main orchestrator (~6300 lines)
|-- brigade.config          # User configuration (optional)
|-- chef/
|   |-- executive.md        # Executive Chef prompt
|   |-- sous.md             # Sous Chef prompt
|   +-- line.md             # Line Cook prompt
|-- commands/               # Claude Code skills
|   |-- brigade-generate-prd.md
|   |-- brigade-convert-prd-to-json.md
|   +-- brigade-update-prd.md
|-- docs/
|   |-- getting-started.md
|   |-- how-it-works.md
|   |-- configuration.md
|   |-- writing-prds.md
|   |-- troubleshooting.md
|   +-- architecture.md
|-- tasks/                  # Working directory (gitignored)
|   |-- prd-*.json          # PRD files
|   |-- prd-*.state.json    # State files
|   |-- brigade-learnings.md
|   +-- brigade-backlog.md
|-- logs/                   # Worker output logs (optional)
+-- tests/
    |-- *.bats              # Test files
    |-- test_helper.bash    # Test utilities
    +-- mocks/
        +-- mock_worker.sh  # Mock worker for testing
```

## Worker Communication

### Output Signals

Workers communicate via XML tags in output:

| Signal | Return Code | Meaning |
|--------|-------------|---------|
| `<promise>COMPLETE</promise>` | 0 | Task done, run verification |
| `<promise>BLOCKED</promise>` | 32 | Cannot proceed, escalate |
| `<promise>ALREADY_DONE</promise>` | 33 | Prior work did this |
| `<promise>ABSORBED_BY:US-XXX</promise>` | 34 | Prior task did this work |
| `<learning>...</learning>` | - | Share knowledge with team |
| `<backlog>...</backlog>` | - | Log out-of-scope discovery |
| `<scope-question>...</scope-question>` | - | Ask about ambiguous requirements |

### Feedback Loop

When verification or review fails:

```
Worker signals COMPLETE
        |
        v
Verification fails (run_verification returns 1)
        |
        v
LAST_VERIFICATION_FEEDBACK = "grep pattern not found"
        |
        v
Next iteration: build_prompt() includes feedback
        |
        v
Worker sees: "PREVIOUS ATTEMPT FAILED VERIFICATION: ..."
```

## Supervisor Integration

For external AI oversight:

```
Brigade                              Supervisor
   |                                     |
   +-- writes events.jsonl ------------>|
   |   (task_start, complete, etc.)     |
   |                                     |
   |<-- reads cmd.json ------------------|
   |   (retry, skip, abort)              |
   |                                     |
   +-- writes status.json ------------->|
       (compact state snapshot)          |
```

**Event types:**
- `service_start` - Brigade started
- `task_start` - Task execution began
- `task_complete` - Task finished
- `escalation` - Worker escalated
- `review` - Executive review result
- `attention` - Human attention needed
- `decision_needed` - Waiting for decision
- `decision_received` - Got decision
- `scope_decision` - Scope question resolved
- `service_complete` - All tasks done

## Configuration Hierarchy

```
Defaults (in brigade.sh)
    |
    +-- Overridden by brigade.config
         |
         +-- Overridden by environment variables
              |
              +-- Overridden by PRD settings ("walkaway": true)
                   |
                   +-- Overridden by CLI flags (--walkaway)
```

## Testing Architecture

```
tests/
|-- test_helper.bash    # Sources brigade.sh, sets test defaults
|-- state.bats          # State management tests
|-- routing.bats        # Task routing tests
|-- review.bats         # Review logic tests (skip conditions)
|-- resume.bats         # Resume logic tests
|-- verification.bats   # Verification tests
|-- walkaway.bats       # Walkaway mode tests
|-- supervisor.bats     # Supervisor integration tests
|-- health_check.bats   # Worker health monitoring tests
|-- integration.bats    # End-to-end with mock workers
|-- manual_verification.bats  # Manual verification gate tests
+-- mocks/
    +-- mock_worker.sh  # Configurable mock (complete, blocked, etc.)
```

**Running tests:**
```bash
./tests/run_tests.sh        # All tests
bats tests/state.bats       # Specific file
BRIGADE_DEBUG=true bats ... # With debug output
```
