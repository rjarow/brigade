# Supervisor Integration

Brigade supports external AI supervisors that monitor execution and make decisions. This enables building chat interfaces where users never touch the terminal.

## Architecture

```
User (natural language)
    |
Supervisor (Claude, custom AI)
    |
    |--- reads status.json, events.jsonl
    |--- writes cmd.json
    |
Brigade (execution engine)
    |
Workers (task-level AI)
```

The supervisor has wide context and talks to the user. Brigade handles execution. Workers have task-level context only.

## File-Based Integration

All supervisor communication is file-based. No webhooks or network connections required.

### Status File

Compact JSON written on every state change:

```bash
SUPERVISOR_STATUS_FILE="brigade/tasks/status.json"
```

Format:

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

| Field | Description |
|-------|-------------|
| `done` | Completed tasks |
| `total` | Total tasks in PRD |
| `current` | Current task ID |
| `worker` | Current worker tier (line/sous/exec) |
| `elapsed` | Seconds since task started |
| `attention` | True if human attention needed |

### Events File

Append-only JSONL stream for real-time monitoring:

```bash
SUPERVISOR_EVENTS_FILE="brigade/tasks/events.jsonl"
```

Tail this file to receive events as they happen:

```bash
tail -f brigade/tasks/events.jsonl | jq
```

#### Event Types

| Event | Fields | Description |
|-------|--------|-------------|
| `service_start` | prd, total_tasks | PRD execution begins |
| `task_start` | task_id, worker | Task assigned to worker |
| `task_complete` | task_id, worker, duration | Task completed |
| `escalation` | task_id, from, to | Task escalated to higher tier |
| `review` | task_id, result | Executive review completed |
| `attention` | task_id, reason | Human attention needed |
| `decision_needed` | decision_id, type, task_id, context | Supervisor decision requested |
| `decision_received` | decision_id, action | Decision was processed |
| `scope_decision` | task_id, question, decision | Scope question answered |
| `service_complete` | completed, failed, duration | PRD finished |

### Command File

Supervisor writes commands here for Brigade to execute:

```bash
SUPERVISOR_CMD_FILE="brigade/tasks/cmd.json"
```

Format:

```json
{
  "decision": "d-123",
  "action": "retry",
  "reason": "Transient network error",
  "guidance": "Try mocking the API instead"
}
```

#### Actions

| Action | Description |
|--------|-------------|
| `retry` | Retry the task, optionally with guidance |
| `skip` | Skip this task and continue |
| `abort` | Stop PRD execution |
| `pause` | Pause execution (resume with `./brigade.sh resume`) |

## Configuration

```bash
# Status snapshot (read by supervisor)
SUPERVISOR_STATUS_FILE="brigade/tasks/status.json"

# Event stream (tailed by supervisor)
SUPERVISOR_EVENTS_FILE="brigade/tasks/events.jsonl"

# Command ingestion (written by supervisor)
SUPERVISOR_CMD_FILE="brigade/tasks/cmd.json"

# How often to poll for commands (seconds)
SUPERVISOR_CMD_POLL_INTERVAL=2

# Max wait for supervisor decision (0 = forever)
# Falls back to walkaway mode if timeout and WALKAWAY_MODE=true
SUPERVISOR_CMD_TIMEOUT=300

# Scope files by PRD prefix for parallel execution
# auth.state.json → auth-events.jsonl
SUPERVISOR_PRD_SCOPED=true
```

## Building a Supervisor

### Minimal Example

```python
import json
import time
from pathlib import Path

STATUS_FILE = Path("brigade/tasks/status.json")
EVENTS_FILE = Path("brigade/tasks/events.jsonl")
CMD_FILE = Path("brigade/tasks/cmd.json")

def read_status():
    if STATUS_FILE.exists():
        return json.loads(STATUS_FILE.read_text())
    return None

def tail_events():
    """Yield new events as they appear."""
    if not EVENTS_FILE.exists():
        EVENTS_FILE.touch()

    with open(EVENTS_FILE) as f:
        f.seek(0, 2)  # End of file
        while True:
            line = f.readline()
            if line:
                yield json.loads(line)
            else:
                time.sleep(0.5)

def send_command(decision_id, action, reason="", guidance=""):
    CMD_FILE.write_text(json.dumps({
        "decision": decision_id,
        "action": action,
        "reason": reason,
        "guidance": guidance
    }))

# Main loop
for event in tail_events():
    if event["event"] == "decision_needed":
        # AI decides what to do
        decision = analyze_failure(event["context"])
        send_command(
            event["decision_id"],
            decision["action"],
            decision["reason"],
            decision.get("guidance", "")
        )
```

### Claude as Supervisor

Claude Code can act as the supervisor:

```
User: "Build the auth system"

Claude: [Plans PRD via ./brigade.sh plan]
        "I've created a 13-task PRD. Ready to execute?"

User: "Go ahead, run it overnight"

Claude: [Starts ./brigade.sh --walkaway service prd.json]
        [Tails events file for updates]
        [Makes decisions when needed]
        "Done! 12 of 13 tasks completed. US-007 was skipped
         because the external API wasn't available. Want me
         to retry that one now?"
```

This pattern makes Claude the natural language frontend. Users chat, never touch the terminal.

## Polling vs Watching

For minimal token usage:

1. **Poll status** - Read `status.json` periodically (every 30s)
2. **Watch events** - Tail `events.jsonl` only when expecting activity
3. **Use `--brief`** - `./brigade.sh status --brief` returns compact JSON

The `--brief` format:

```json
{"done":5,"total":13,"current":"US-006","worker":"line","elapsed":45}
```

## Parallel PRD Execution

With `SUPERVISOR_PRD_SCOPED=true`, multiple PRDs can run simultaneously:

```
brigade/tasks/auth-events.jsonl     (prd-auth.json)
brigade/tasks/payments-events.jsonl (prd-payments.json)
```

Each PRD gets isolated supervisor files based on its prefix.

## Integration with Walkaway Mode

Supervisor and walkaway mode work together:

```
Decision Priority:
1. Supervisor command (if cmd.json written within timeout)
2. Executive Chef walkaway decision (if WALKAWAY_MODE=true)
3. Interactive prompt (fallback)
```

For fully autonomous execution with oversight:

```bash
WALKAWAY_MODE=true
SUPERVISOR_CMD_TIMEOUT=30  # Wait 30s for supervisor, then use walkaway
```
