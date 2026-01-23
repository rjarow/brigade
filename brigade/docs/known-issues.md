# Known Issues

Tracking reliability issues discovered during real-world usage.

## Active Issues

### KI-001: Worker Stall Without Attention Signal

**Reported:** 2026-01-22
**Severity:** High
**Status:** Open

**Symptoms:**
- Task ran 83+ minutes with no progress
- All verification tests passing but `passes: false` in state
- State showed `iteration_1` but task never advanced
- `attention: false` despite being stuck
- `current: null` in status but workers weren't actually running

**Recovery:** Required `pkill -f brigade` and service restart

**Root Cause (suspected):**
Worker process may have completed internally but died before writing `<promise>COMPLETE</promise>` signal, leaving state in limbo. No watchdog detected the stall.

**Related:** P14 Worker Reliability roadmap item

---

## Issue Template

```markdown
### KI-XXX: Title

**Reported:** YYYY-MM-DD
**Severity:** Low | Medium | High | Critical
**Status:** Open | Investigating | Fixed (version)

**Symptoms:**
- What was observed

**Recovery:** How it was resolved

**Root Cause:**
What went wrong

**Fix:**
Link to commit/PR if fixed
```
