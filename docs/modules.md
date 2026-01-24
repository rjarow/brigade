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

