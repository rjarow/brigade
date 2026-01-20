# Troubleshooting Guide

Common issues and solutions when using Brigade.

## Worker Issues

### Task keeps iterating without progress

**Symptoms:** Same task runs repeatedly, worker can't complete

**Solutions:**
1. Check acceptance criteria are achievable - vague criteria lead to endless iteration
2. Enable debug mode: `BRIGADE_DEBUG=true ./brigade.sh service prd.json`
3. Review worker logs: `ls brigade/logs/`
4. Check if tests are flaky: run `TEST_CMD` manually

### Worker times out

**Symptoms:** "Task timed out after Xm" message, escalation triggered

**Solutions:**
1. Increase timeout: `TASK_TIMEOUT_JUNIOR=1800` (30 min in seconds)
2. Break task into smaller pieces
3. Check if worker is stuck on interactive prompt (tests spawning editors)

### Worker crashes

**Symptoms:** "Worker process died unexpectedly" message, exit code 125

**Causes:**
- Memory exhaustion
- Killed by system (OOM)
- Bug in worker tool (claude/opencode)

**Solutions:**
1. Check system memory during runs
2. Reduce `MAX_PARALLEL` to limit concurrent workers
3. Check worker tool logs for errors

### Tests hang indefinitely

**Symptoms:** Test timeout, "terminal activity detected" warning

**Causes:**
- Tests spawning interactive processes (vim, less, nano)
- Infinite loops in test code
- Tests waiting for user input

**Solutions:**
1. Run tests in CI mode: `CI=true npm test`
2. Mock interactive commands in tests
3. Set `TEST_TIMEOUT` appropriately (default: 120s)

## State Issues

### "currentTask is stale" warning

**Symptoms:** Resume finds task that doesn't exist in PRD

**Cause:** The task was removed from PRD after an interruption.

**Solution:** Use `skip` action to proceed:
```bash
./brigade.sh resume prd.json skip
```

### Corrupted state file

**Symptoms:** jq parse errors, "state file appears corrupted" warning

**Solution:** Brigade auto-backs up corrupt state and creates fresh:
```bash
ls brigade/tasks/*.state.json.backup.*  # View backups
```

To restore a backup:
```bash
cp brigade/tasks/prd.state.json.backup.12345 brigade/tasks/prd.state.json
```

### State file locked

**Symptoms:** "Could not acquire lock" message, operations fail

**Cause:** Previous Brigade process didn't release lock (crash, force kill)

**Solution:**
```bash
# Check for stale lock files
ls brigade/tasks/*.lock

# Remove if Brigade is not running
rm brigade/tasks/*.lock
```

## Escalation Issues

### Task keeps escalating

**Symptoms:** Task goes Line Cook -> Sous Chef -> Executive Chef quickly

**Causes:**
- Task may be fundamentally blocked (missing dependencies, credentials)
- Acceptance criteria too vague
- Worker doesn't understand task

**Solutions:**
1. Check if task needs external access (APIs, credentials)
2. Clarify acceptance criteria
3. Increase iteration limits: `ESCALATION_AFTER=5`

### BLOCKED signal without clear reason

**Symptoms:** Worker signals BLOCKED, no explanation in output

**Solutions:**
1. Check worker output logs for context: `cat brigade/logs/*-{task_id}-*.log`
2. Worker may need credentials or access you haven't provided
3. Run task manually to see full output

### All tasks escalating to Executive Chef

**Symptoms:** Even simple tasks reach Executive Chef tier

**Cause:** Executive Chef is handling too much, likely config issue

**Solutions:**
1. Check `ESCALATION_AFTER` value (default: 3)
2. Verify mock workers aren't failing unintentionally
3. Check `SOUS_CMD` is correctly configured

## Verification Issues

### Verification fails but code looks correct

**Symptoms:** "Verification failed" message, task iterates

**Solutions:**
1. Run verification commands manually to see error output
2. Check command paths are correct (relative vs absolute)
3. Verify grep patterns match expected output exactly

### "grep-only verification" warning

**Symptoms:** Warning at service start about pattern-only verification

**Cause:** PRD only has `grep` commands, no execution tests

**Solution:** Add execution-based tests:
```json
"verification": [
  {"type": "pattern", "cmd": "grep -q 'function' file.ts"},
  {"type": "unit", "cmd": "npm test -- --grep 'specific test'"}
]
```

### TODO markers blocking completion

**Symptoms:** "Found incomplete markers in changed files" warning

**Cause:** Code contains TODO/FIXME comments

**Solutions:**
1. Worker should complete the TODOs
2. Use `<backlog>description</backlog>` to acknowledge out-of-scope items
3. Disable with `TODO_SCAN_ENABLED=false` (not recommended)

## Configuration Issues

### "Config value X invalid, using default"

**Symptoms:** Warning on startup about config values

**Solution:** Check `brigade.config` syntax:
- Numeric values must be positive integers
- Boolean values: `true` or `false` (lowercase)
- Enum values must match exactly

### Workers not using configured model

**Symptoms:** Wrong model being used despite config

**Solutions:**
1. Ensure config file is at `brigade/brigade.config` (correct path)
2. Check for typos in variable names
3. Config is hot-reloaded between tasks - changes take effect immediately

### OpenCode not found

**Symptoms:** "command not found: opencode" error

**Solutions:**
1. Install OpenCode: see their documentation
2. Check it's in your PATH: `which opencode`
3. Fall back to claude: remove `LINE_CMD` override

## Parallel Execution Issues

### Tasks completing out of order

**Symptoms:** Dependent tasks starting before dependencies complete

**Cause:** Usually not an issue - Brigade respects `dependsOn`

**Debug:**
```bash
# Force sequential execution
./brigade.sh --sequential service prd.json

# Or set in config
MAX_PARALLEL=1
```

### Lock contention warnings

**Symptoms:** "Waiting for lock" messages in debug output

**Cause:** Multiple parallel workers accessing state file

**Solution:** This is normal - Brigade uses file locking. If frequent:
```bash
# Reduce parallelism
MAX_PARALLEL=2
```

## Walkaway Mode Issues

### Too many consecutive skips

**Symptoms:** "Aborting after X consecutive skips" message

**Cause:** Safety rail triggered - multiple tasks failing in a row

**Solutions:**
1. Check if there's a fundamental blocker
2. Increase limit: `WALKAWAY_MAX_SKIPS=5`
3. Run manually to investigate failures

### Scope decisions not recorded

**Symptoms:** Worker asked scope question but no decision in state

**Cause:** `WALKAWAY_SCOPE_DECISIONS=false` or exec chef failed

**Solution:** Check state file for `scopeDecisions` array

## Debug Mode

Enable verbose debugging:

```bash
BRIGADE_DEBUG=true ./brigade.sh service prd.json
```

Shows:
- Lock acquisition/release timing
- Signal detection in worker output
- Task completion flow details
- Worker process IDs and health checks

## Getting Help

1. Check worker logs: `brigade/logs/`
2. Check state file: `brigade/tasks/prd.state.json`
3. Run `./brigade.sh status --json` for machine-readable state
4. Enable debug mode for verbose output
5. File issues at the project repository
