# Troubleshooting

## Quick Fixes

| Symptom | Fix |
|---------|-----|
| Task loops without progress | Acceptance criteria too vague - make them specific and verifiable |
| "command not found: opencode" | Install OpenCode or set `USE_OPENCODE=false` |
| "Could not acquire lock" | Remove stale lock: `rm brigade/tasks/*.lock` |
| Worker times out | Increase timeout or break task into smaller pieces |

## Debug Mode

When something goes wrong, enable debug output:

```bash
BRIGADE_DEBUG=true ./brigade.sh service prd.json
```

Shows lock timing, signal detection, and task flow details.

## Worker Logs

All worker output is captured when `WORKER_LOG_DIR` is set:

```bash
# Enable logging
WORKER_LOG_DIR="brigade/logs/"

# View logs
ls brigade/logs/
cat brigade/logs/auth-US-003-sous-*.log
```

## Common Issues

### Task keeps iterating

Usually caused by vague acceptance criteria:

```json
// Bad - unverifiable
"acceptanceCriteria": ["Works correctly", "Handles errors"]

// Good - specific
"acceptanceCriteria": [
  "POST /login returns 200 with valid credentials",
  "Returns 401 and error message on invalid credentials"
]
```

### Rapid escalation

If tasks escalate quickly through all tiers:

1. Check if the task needs credentials or external access
2. Review acceptance criteria for clarity
3. Run the task manually to see full output

### Walkaway aborts early

"Aborting after X consecutive skips" means multiple tasks failed in a row.

1. Check for a fundamental blocker (missing dependency, wrong branch)
2. Run interactively to investigate: `./brigade.sh service prd.json`

## State Recovery

### After crash or force-quit

```bash
# Check for stale locks
ls brigade/tasks/*.lock

# Remove if Brigade isn't running
rm brigade/tasks/*.lock

# Resume
./brigade.sh resume
```

### Corrupted state

Brigade auto-backs up corrupt state files:

```bash
ls brigade/tasks/*.state.json.backup.*
cp brigade/tasks/prd.state.json.backup.12345 brigade/tasks/prd.state.json
```

## Getting Help

1. Enable debug mode
2. Check worker logs
3. Run `./brigade.sh status --json`
4. File issues at the project repository
