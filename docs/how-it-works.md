# How Brigade Works

The kitchen runs itself. Here's what's happening behind the scenes.

## The Flow

```
You: "Add user authentication"
          ↓
   ┌──────────────────────────┐
   │  PLANNING (Executive Chef) │
   │  Interview → Analyze → PRD │
   └────────────┬─────────────┘
                ↓
   ┌──────────────────────────┐
   │  EXECUTION (per task)     │
   │                           │
   │  Line Cook tries it       │
   │       ↓ (stuck?)          │
   │  Sous Chef takes over     │
   │       ↓ (still stuck?)    │
   │  Executive Chef steps in  │
   │       ↓                   │
   │  Tests run → Review       │
   └────────────┬─────────────┘
                ↓
         ✅ Order up!
```

## Planning Phase

When you run `./brigade.sh plan "..."`:

1. **Interview** - Executive Chef asks clarifying questions upfront
2. **Analysis** - Explores your codebase (structure, patterns, stack)
3. **PRD** - Generates tasks with acceptance criteria and dependencies

Each task gets:
- Clear scope and acceptance criteria
- Complexity assignment (junior/senior)
- Dependencies on other tasks
- Verification commands

## Execution Phase

### Task Routing

| Complexity | Who Cooks | Best For |
|------------|-----------|----------|
| `junior` | Line Cook | Tests, CRUD, boilerplate |
| `senior` | Sous Chef | Architecture, security, judgment calls |
| `auto` | Kitchen decides | Analyzes task to pick |

### Automatic Escalation

Workers escalate within the team, not to you:

```
Line Cook fails 3x (or times out, or says BLOCKED)
    → Sous Chef takes over

Sous Chef fails 5x (or times out, or says BLOCKED)
    → Executive Chef steps in
```

Thresholds are configurable. Timer resets when escalating.

### Fresh Context

Each task starts clean - no conversation history bleeding through. Knowledge is shared explicitly via `<learning>` tags that get stored and retrieved for relevant future tasks.

### Completion Signals

Workers signal status with special tags:

| Signal | Meaning |
|--------|---------|
| `COMPLETE` | Done, run tests and review |
| `BLOCKED` | Can't proceed, escalate me |
| `ALREADY_DONE` | Prior task did this, skip tests |
| `ABSORBED_BY:US-XXX` | Another task covered this |

### Verification

If the PRD has verification commands, they run after `COMPLETE`:
- All pass → continue to review
- Any fail → worker iterates with feedback

If `TEST_CMD` is configured, tests run the same way.

### Executive Review

If `REVIEW_ENABLED=true`, Executive Chef reviews completed work:
- Were acceptance criteria met?
- Does it follow project patterns?
- Any obvious issues?

Failed review → worker iterates with feedback.

## State Management

Each PRD gets its own state file: `prd-feature.json` → `prd-feature.state.json`

Contains:
- Session timing
- Task history (who did what, when)
- Escalations and reviews
- Current task (for resume)

View with `./brigade.sh status`.

## Interrupts

Ctrl+C anytime. Brigade:
1. Kills worker processes gracefully
2. Cleans up temp files
3. Saves state for resume

Run `./brigade.sh resume` to pick up where you left off.

## Configuration

See [Configuration](configuration.md) for all the knobs. Key ones:

```bash
# In brigade.config
ESCALATION_AFTER=3           # Line Cook → Sous Chef threshold
TASK_TIMEOUT_JUNIOR=900      # 15 min before timeout escalation
REVIEW_ENABLED=true          # Executive Chef reviews work
QUIET_WORKERS=true           # Spinner instead of conversation output
```

## Next Steps

- **[Configuration](configuration.md)** - Tune the kitchen
- **[Writing PRDs](writing-prds.md)** - Manual PRD creation
- **[Troubleshooting](troubleshooting.md)** - When things go wrong
