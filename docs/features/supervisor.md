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

