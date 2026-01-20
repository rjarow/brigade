# Brigade Module System

Brigade supports optional modules that hook into the orchestration lifecycle
without modifying core behavior.

## Quick Start

1. Enable modules in `brigade.config`:
   ```bash
   MODULES="telegram,cost_tracking"
   ```

2. Configure module-specific settings:
   ```bash
   MODULE_TELEGRAM_BOT_TOKEN="your-token"
   MODULE_TELEGRAM_CHAT_ID="your-chat-id"
   ```

3. Run Brigade normally - modules receive events automatically.

## Available Modules

| Module | Description | Config |
|--------|-------------|--------|
| `telegram` | Send notifications to Telegram | `MODULE_TELEGRAM_BOT_TOKEN`, `MODULE_TELEGRAM_CHAT_ID` |
| `cost_tracking` | Log task durations to CSV | `MODULE_COST_TRACKING_OUTPUT` (default: `brigade/costs.csv`) |
| `example` | Template module for reference | None |

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

# OPTIONAL: Cleanup on exit
module_mymodule_cleanup() {
  :
}

# Event handlers - one per event
module_mymodule_on_task_complete() {
  local task_id="$1" worker="$2" duration="$3"
  # Your code here
}
```

## Available Events

| Event | Arguments | When |
|-------|-----------|------|
| `service_start` | prd, total_tasks | PRD execution begins |
| `task_start` | task_id, worker | Task assigned to worker |
| `task_complete` | task_id, worker, duration | Task completed successfully |
| `task_blocked` | task_id, worker | Task hit blocker |
| `task_absorbed` | task_id, absorbed_by | Task absorbed by another |
| `task_already_done` | task_id | Task was already completed |
| `escalation` | task_id, from_worker, to_worker | Task escalated |
| `review` | task_id, result | Executive review completed |
| `verification` | task_id, result | Verification check completed |
| `attention` | task_id, reason | Human attention needed |
| `decision_needed` | decision_id, type, task_id, context | Supervisor decision needed |
| `decision_received` | decision_id, action | Supervisor decision received |
| `scope_decision` | task_id, question, decision | Scope question decided |
| `service_complete` | completed, failed, duration | PRD execution finished |

## Module Behavior

- Modules run **async** (non-blocking) - they don't slow down Brigade
- Module failures are **isolated** - a broken module won't crash Brigade
- Modules have a **timeout** (`MODULE_TIMEOUT`, default 5s)
- Modules are **hot-reloaded** between tasks (edit config, changes apply)

## Debugging

Enable debug output to see module loading and dispatch:
```bash
BRIGADE_DEBUG=true ./brigade.sh service prd.json
```

Output includes:
```
[DEBUG] Loaded module: telegram (events: task_complete escalation attention service_complete)
[DEBUG] Dispatched task_complete to telegram
```

## Example: Custom Slack Module

```bash
#!/bin/bash
# modules/slack.sh - Slack notifications for Brigade

module_slack_events() {
  echo "task_complete escalation service_complete"
}

module_slack_init() {
  if [ -z "$MODULE_SLACK_WEBHOOK_URL" ]; then
    echo "[slack] MODULE_SLACK_WEBHOOK_URL required" >&2
    return 1
  fi
  return 0
}

_slack_send() {
  local message="$1"
  curl -s -X POST "$MODULE_SLACK_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "{\"text\": \"$message\"}" > /dev/null 2>&1 &
}

module_slack_on_task_complete() {
  local task_id="$1" worker="$2" duration="$3"
  _slack_send ":white_check_mark: Task $task_id completed by $worker (${duration}s)"
}

module_slack_on_escalation() {
  local task_id="$1" from="$2" to="$3"
  _slack_send ":arrow_up: Task $task_id escalated: $from -> $to"
}

module_slack_on_service_complete() {
  local completed="$1" failed="$2" duration="$3"
  local mins=$((duration / 60))
  _slack_send ":checkered_flag: Service complete: $completed tasks, $failed failed (${mins}m)"
}
```

Enable with:
```bash
MODULES="slack"
MODULE_SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
```
