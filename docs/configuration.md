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

Run `./brigade-go init` to create a starter config.

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

