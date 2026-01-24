# Walkaway Mode

Walkaway mode enables fully autonomous execution. Instead of prompting you on failures, Executive Chef makes retry/skip decisions automatically.

## Enabling

Three ways to enable:

```bash
# CLI flag
./brigade-go --walkaway service prd.json

# Configuration
WALKAWAY_MODE=true

# PRD-level setting
{ "walkaway": true, ... }
```

## What Happens

When a task fails repeatedly:

1. **Executive Chef analyzes the failure** - error output, iteration count, task requirements
2. **Makes a decision** - retry with guidance, skip and continue, or abort
3. **Records the decision** - stored in state for auditability
4. **Continues execution** - no human prompt

### Decision Types

| Decision | When Used |
|----------|-----------|
| **retry** | Transient errors, worker confusion, fixable issues |
| **skip** | Fundamental blockers, missing dependencies |
| **abort** | Critical failures, security concerns, cascade risk |

## Safety Rails

### Consecutive Skip Limit

```bash
WALKAWAY_MAX_SKIPS=3  # Default
```

If 3 tasks skip consecutively, Brigade pauses for human intervention.

### Scope Decisions

Workers can ask scope questions with `<scope-question>` tag. In walkaway mode, Executive Chef decides and flags for human review later.

## PRD Requirements

Walkaway PRDs have stricter requirements:

- **Verification depth** - grep-only verification is blocked
- **Clear acceptance criteria** - vague criteria lead to endless iteration

## When to Use

**Good candidates:**
- Well-defined PRDs with clear acceptance criteria
- Tasks with strong verification commands
- Overnight execution

**Not recommended:**
- Exploratory work with unclear scope
- First run of a new PRD

