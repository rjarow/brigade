# Configuration

All settings go in `brigade.config`. Everything is optional - Brigade works without it.

## Workers

| Option | Default | Description |
|--------|---------|-------------|
| `EXECUTIVE_CMD` | `claude --model opus` | Command for Executive Chef (planning, reviews) |
| `SOUS_CMD` | `claude --model sonnet` | Command for Sous Chef (complex tasks) |
| `LINE_CMD` | `claude --model sonnet` | Command for Line Cook (routine tasks) |
| `USE_OPENCODE` | `false` | Use OpenCode for Line Cook tasks |
| `OPENCODE_MODEL` | `zai-coding-plan/glm-4.7` | Model when USE_OPENCODE=true |
| `CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS` | `true` | Auto-approve Claude in non-interactive mode |

## Testing

| Option | Default | Description |
|--------|---------|-------------|
| `TEST_CMD` | *(empty)* | Command to run after each task (e.g., `npm test`) |
| `TEST_TIMEOUT` | `120` | Seconds before flagging test as hung |

## Verification

| Option | Default | Description |
|--------|---------|-------------|
| `VERIFICATION_ENABLED` | `true` | Run verification commands from PRD |
| `VERIFICATION_TIMEOUT` | `60` | Per-command timeout in seconds |
| `TODO_SCAN_ENABLED` | `true` | Block completion if TODO/FIXME markers found |
| `VERIFICATION_WARN_GREP_ONLY` | `true` | Warn if PRD only has grep-based verification |
| `MANUAL_VERIFICATION_ENABLED` | `false` | Enable manual verification gate for UI tasks |

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
| `TASK_TIMEOUT_WARNING_JUNIOR` | `10` | Minutes before warning (junior) |
| `TASK_TIMEOUT_WARNING_SENIOR` | `20` | Minutes before warning (senior) |

## Reviews

| Option | Default | Description |
|--------|---------|-------------|
| `REVIEW_ENABLED` | `true` | Executive Chef reviews completed work |
| `REVIEW_JUNIOR_ONLY` | `true` | Only review Line Cook work |
| `PHASE_REVIEW_ENABLED` | `false` | Periodic reviews during long PRDs |
| `PHASE_REVIEW_AFTER` | `5` | Review every N tasks |
| `PHASE_REVIEW_ACTION` | `continue` | Action on issues: `continue`, `pause`, `remediate` |

## Walkaway Mode

| Option | Default | Description |
|--------|---------|-------------|
| `WALKAWAY_MODE` | `false` | AI decides retry/skip on failures |
| `WALKAWAY_MAX_SKIPS` | `3` | Max consecutive skips before pausing |
| `WALKAWAY_DECISION_TIMEOUT` | `120` | Seconds for AI decision |
| `WALKAWAY_SCOPE_DECISIONS` | `true` | Let exec chef decide scope questions |

## Smart Retry

| Option | Default | Description |
|--------|---------|-------------|
| `SMART_RETRY_ENABLED` | `true` | Enable failure classification and approach tracking |
| `SMART_RETRY_CUSTOM_PATTERNS` | *(empty)* | Custom `pattern:category` pairs |
| `SMART_RETRY_STRATEGIES_FILE` | *(empty)* | JSON file with custom suggestions |
| `SMART_RETRY_APPROACH_HISTORY_MAX` | `3` | Max approaches shown in retry prompt |
| `SMART_RETRY_SESSION_FAILURES_MAX` | `5` | Max session failures tracked |
| `SMART_RETRY_AUTO_LEARNING_THRESHOLD` | `3` | Auto-add to learnings after N failures |

## PRD Quality (P15)

| Option | Default | Description |
|--------|---------|-------------|
| `CRITERIA_LINT_ENABLED` | `true` | Lint acceptance criteria for vague language |
| `VERIFICATION_SCAFFOLD_ENABLED` | `true` | Suggest verification commands |
| `E2E_DETECTION_ENABLED` | `true` | Detect UI tasks without E2E tests |
| `CROSS_PRD_CONTEXT_ENABLED` | `true` | Include related PRD context in prompts |
| `CROSS_PRD_MAX_RELATED` | `3` | Max related PRDs in context |

## Supervisor Integration

| Option | Default | Description |
|--------|---------|-------------|
| `SUPERVISOR_STATUS_FILE` | *(empty)* | Path for compact status JSON |
| `SUPERVISOR_EVENTS_FILE` | *(empty)* | Path for JSONL event stream |
| `SUPERVISOR_CMD_FILE` | *(empty)* | Path for command ingestion |
| `SUPERVISOR_CMD_POLL_INTERVAL` | `2` | Seconds between command polls |
| `SUPERVISOR_CMD_TIMEOUT` | `300` | Max wait for supervisor (0 = forever) |
| `SUPERVISOR_PRD_SCOPED` | `true` | Scope files by PRD prefix |

## Monitoring

| Option | Default | Description |
|--------|---------|-------------|
| `QUIET_WORKERS` | `false` | Show spinner instead of output |
| `ACTIVITY_LOG` | *(empty)* | Path for heartbeat log |
| `ACTIVITY_LOG_INTERVAL` | `30` | Seconds between heartbeats |
| `WORKER_LOG_DIR` | *(empty)* | Directory for worker logs |
| `STATUS_WATCH_INTERVAL` | `30` | Refresh interval for `status --watch` |

## Worker Health

| Option | Default | Description |
|--------|---------|-------------|
| `WORKER_HEALTH_CHECK_INTERVAL` | `5` | Seconds between health checks |
| `WORKER_CRASH_EXIT_CODE` | `125` | Exit code for crashed workers |

## Knowledge Sharing

| Option | Default | Description |
|--------|---------|-------------|
| `KNOWLEDGE_SHARING` | `true` | Enable learning sharing between workers |
| `LEARNINGS_FILE` | `brigade-learnings.md` | Learnings file name |
| `BACKLOG_FILE` | `brigade-backlog.md` | Backlog file name |
| `LEARNINGS_MAX` | `50` | Max learnings per file (0 = unlimited) |
| `LEARNINGS_ARCHIVE` | `true` | Archive learnings on PRD completion |

## Context & State

| Option | Default | Description |
|--------|---------|-------------|
| `CONTEXT_ISOLATION` | `true` | Fresh sessions per task |
| `STATE_FILE` | `brigade-state.json` | State file name |

## Parallel Execution

| Option | Default | Description |
|--------|---------|-------------|
| `MAX_PARALLEL` | `3` | Max concurrent workers (0 = sequential) |

## Auto-Continue

| Option | Default | Description |
|--------|---------|-------------|
| `AUTO_CONTINUE` | `false` | Chain multiple PRDs |
| `PHASE_GATE` | `continue` | Between PRDs: `continue`, `pause`, `review` |

## Cost Estimation

| Option | Default | Description |
|--------|---------|-------------|
| `COST_RATE_LINE` | `0.05` | $/minute for Line Cook |
| `COST_RATE_SOUS` | `0.15` | $/minute for Sous Chef |
| `COST_RATE_EXECUTIVE` | `0.30` | $/minute for Executive Chef |
| `COST_WARN_THRESHOLD` | *(empty)* | Warn if PRD exceeds this amount |

## Risk Assessment

| Option | Default | Description |
|--------|---------|-------------|
| `RISK_REPORT_ENABLED` | `true` | Show risk summary before execution |
| `RISK_HISTORY_SCAN` | `false` | Include historical escalation patterns |
| `RISK_WARN_THRESHOLD` | *(empty)* | Warn at level: `low`, `medium`, `high` |

## Modules

| Option | Default | Description |
|--------|---------|-------------|
| `MODULES` | *(empty)* | Comma-separated module list |
| `MODULE_TIMEOUT` | `5` | Max seconds per handler |
| `MODULE_TERMINAL_BELL` | `true` | Ring bell on alerts |
| `MODULE_TELEGRAM_BOT_TOKEN` | *(empty)* | Telegram bot token |
| `MODULE_TELEGRAM_CHAT_ID` | *(empty)* | Telegram chat ID |
| `MODULE_WEBHOOK_URL` | *(empty)* | Webhook URL |
| `MODULE_WEBHOOK_FORMAT` | `slack` | Format: `slack`, `discord`, `json` |
| `MODULE_COST_TRACKING_OUTPUT` | `brigade/costs.csv` | Cost tracking output file |

## Git & Codebase

| Option | Default | Description |
|--------|---------|-------------|
| `DEFAULT_BRANCH` | *(auto-detect)* | Default branch for merging |
| `MAP_STALE_COMMITS` | `20` | Regenerate map after N commits |

## Limits

| Option | Default | Description |
|--------|---------|-------------|
| `MAX_ITERATIONS` | `50` | Max iterations per task |
