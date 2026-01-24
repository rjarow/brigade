# Troubleshooting

## Quick Fixes

| Symptom | Fix |
|---------|-----|
| Task loops without progress | Acceptance criteria too vague - make them specific |
| "command not found: opencode" | Install OpenCode or set `USE_OPENCODE=false` |
| "Could not acquire lock" | Remove stale lock: `rm brigade/tasks/*.lock` |
| Worker times out | Increase timeout or break task into smaller pieces |

## Debug Mode

```bash
BRIGADE_DEBUG=true ./brigade-go service prd.json
```

Shows lock timing, signal detection, and task flow details.

## Worker Logs

```bash
WORKER_LOG_DIR="brigade/logs/"
ls brigade/logs/
cat brigade/logs/auth-US-003-sous-*.log
```

## Common Issues

### Task keeps iterating

Usually caused by vague acceptance criteria:

```json
// Bad
"acceptanceCriteria": ["Works correctly"]

// Good
"acceptanceCriteria": ["POST /login returns 200 with valid credentials"]
```

### Rapid escalation

1. Check if task needs credentials or external access
2. Review acceptance criteria for clarity
3. Run task manually to see full output

### Walkaway aborts early

"Aborting after X consecutive skips" means multiple tasks failed.

1. Check for fundamental blocker (missing dependency, wrong branch)
2. Run interactively to investigate

## State Recovery

### After crash

```bash
rm brigade/tasks/*.lock    # Remove stale locks
./brigade-go resume        # Resume execution
```

### Corrupted state

Brigade auto-backs up corrupt files:

```bash
ls brigade/tasks/*.state.json.backup.*
cp brigade/tasks/prd.state.json.backup.12345 brigade/tasks/prd.state.json
```
