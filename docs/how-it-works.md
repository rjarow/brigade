# How Brigade Works

Brigade is a multi-model AI orchestration framework that routes tasks to different AI models based on complexity, with automatic escalation, executive review, and state tracking.

## Philosophy: Minimal Owner Disruption

The **Owner** (human user) should be minimally interrupted:

| Principle | What It Means |
|-----------|---------------|
| **Interview once** | Director asks thorough questions upfront |
| **Autonomous execution** | Team works without bothering the owner |
| **Internal escalation** | Worker failures escalate within the team, not to owner |
| **Owner escalation only when necessary** | Scope changes, missing access, blocking decisions |

### When the Owner Gets Interrupted

**YES - Escalate to Owner:**
- Scope needs to increase beyond what was agreed
- Missing credentials or access
- Fundamental blockers requiring business decisions
- Multiple valid approaches where owner preference matters

**NO - Handle Internally:**
- Technical implementation details
- Which worker handles what
- Code patterns (analyze and match)
- Task ordering and dependencies
- Worker failures (escalate Line Cook → Sous Chef)

## The Kitchen Metaphor

Brigade uses kitchen terminology because the workflow mirrors a professional kitchen:

| Kitchen | Brigade | Description |
|---------|---------|-------------|
| Executive Chef | Opus | Plans features, reviews work, makes judgment calls |
| Sous Chef | Sonnet | Handles complex dishes (tasks) |
| Line Cook | GLM/local | Handles routine prep work |
| Ticket | Task | Individual unit of work |
| The Pass | Review | Quality check before completion |
| Service | Full run | Complete execution of all tasks |
| 86'd | Blocked | Task cannot be completed |
| Fire | Start | Begin working on a task |
| Escalate | Promote | Move task to higher tier |

## Complete Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                     1. PLANNING PHASE                           │
│                     (Executive Chef / Opus)                     │
│                                                                 │
│  User Request ──► Interview ──► Codebase Analysis ──► PRD      │
│                                                                 │
│  ./brigade.sh plan "Add user authentication"                   │
│  or: /brigade-generate-prd Add user authentication                     │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                     2. EXECUTION PHASE                          │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ For each task (in dependency order):                      │  │
│  │                                                           │  │
│  │              ┌───────────────┐                            │  │
│  │              │ Pre-flight    │ Run tests first - skip if  │  │
│  │              │ Check         │ already passing            │  │
│  │              └───────┬───────┘                            │  │
│  │                      ▼                                    │  │
│  │  ┌─────────────┐  escalate   ┌─────────────┐  escalate   │  │
│  │  │ LINE COOK   │───────────► │ SOUS CHEF   │───────────► │  │
│  │  │ (junior)    │ N fails or  │ (senior)    │ N fails or  │  │
│  │  │             │ timeout     │             │ timeout     │  │
│  │  └──────┬──────┘ or blocked  └──────┬──────┘ or blocked  │  │
│  │         │                           │                     │  │
│  │         │    ┌─────────────┐        │                     │  │
│  │         │    │ EXEC CHEF   │◄───────┘                     │  │
│  │         │    │ (rare)      │                              │  │
│  │         │    └──────┬──────┘                              │  │
│  │         └───────────┼───────────────────────────┘         │  │
│  │                     ▼                                     │  │
│  │              ┌───────────────┐                            │  │
│  │              │ Run Tests     │ (if TEST_CMD configured)   │  │
│  │              └───────┬───────┘                            │  │
│  │                      ▼                                    │  │
│  │              ┌───────────────┐                            │  │
│  │              │ EXEC REVIEW   │ (if REVIEW_ENABLED)        │  │
│  │              │ (Opus)        │                            │  │
│  │              └───────┬───────┘                            │  │
│  │                      ▼                                    │  │
│  │              ┌───────────────┐                            │  │
│  │              │ Mark Complete │                            │  │
│  │              └───────────────┘                            │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Phase 1: Planning

When you run `./brigade.sh plan "..."` or use `/brigade-generate-prd`:

### 1.1 Interview

The Executive Chef (Opus) asks clarifying questions:

- What's the scope of this feature?
- Are there specific requirements or constraints?
- Any preferred approaches or patterns to follow?
- What should be prioritized?

This ensures the generated PRD matches your actual intent.

### 1.2 Codebase Analysis

The Director explores your project:

- **Structure**: Where do models go? Controllers? Tests?
- **Patterns**: How is error handling done? What's the naming convention?
- **Stack**: What frameworks and libraries are in use?
- **Tests**: What testing patterns exist?

This ensures tasks fit your existing codebase.

### 1.3 PRD Generation

The Director creates a structured PRD:

```json
{
  "featureName": "User Authentication",
  "tasks": [
    {
      "id": "US-001",
      "title": "Add User model",
      "complexity": "senior",    // Architectural decision
      "acceptanceCriteria": [
        "User model has id, email, password_hash fields",
        "Unit tests for validation logic"
      ],
      "dependsOn": []
    },
    {
      "id": "US-002",
      "title": "Add User model tests",
      "complexity": "junior",    // Follows patterns
      "acceptanceCriteria": [
        "Test user creation with valid data",
        "Test email validation rejects invalid formats"
      ],
      "dependsOn": ["US-001"]
    }
  ]
}
```

Tasks are:
- Atomic and well-scoped
- Properly assigned complexity
- Ordered by dependencies
- Have specific acceptance criteria
- **Include test requirements** (both in acceptance criteria AND as dedicated test tasks)

## Phase 2: Execution

### 2.1 Task Routing

Each task is routed based on complexity:

| Complexity | Worker | Characteristics |
|------------|--------|-----------------|
| `junior` | Line Cook (GLM) | Clear requirements, existing patterns |
| `senior` | Sous Chef (Sonnet) | Judgment calls, architecture, security |
| `auto` | Heuristics | Brigade decides based on task |

### 2.2 Firing a Ticket

When a task is fired:

1. Worker receives:
   - Chef prompt (`chef/sous.md` or `chef/line.md`)
   - Task details (title, description, acceptance criteria)
   - Project context

2. Worker implements the task

3. Worker signals completion:
   - `<promise>COMPLETE</promise>` - Task done
   - `<promise>BLOCKED</promise>` - Cannot proceed

### 2.3 Automatic Escalation

Brigade has a three-tier escalation system. All thresholds are configurable (defaults shown):

**Tier 1: Line Cook → Sous Chef**
```
Line Cook attempts task
         ↓ (after 3 fails OR 15m timeout OR BLOCKED signal)
    ESCALATION
         ↓
Sous Chef takes over
```

**Tier 2: Sous Chef → Executive Chef** (rare)
```
Sous Chef attempts task
         ↓ (after 5 fails OR 30m timeout OR BLOCKED signal)
    ESCALATION
         ↓
Executive Chef takes over
```

Escalation also triggers immediately on BLOCKED signal:
```
Worker: <promise>BLOCKED</promise>
         ↓
    IMMEDIATE ESCALATION to next tier
```

Configuration:
```bash
# Iteration-based escalation
ESCALATION_ENABLED=true
ESCALATION_AFTER=3                 # Line Cook → Sous Chef after N fails
ESCALATION_TO_EXEC=true            # Enable Sous Chef → Executive Chef
ESCALATION_TO_EXEC_AFTER=5         # Sous Chef → Exec Chef after N fails

# Time-based escalation (independent of iterations)
TASK_TIMEOUT_JUNIOR=900            # 15 minutes for Line Cook
TASK_TIMEOUT_SENIOR=1800           # 30 minutes for Sous Chef
TASK_TIMEOUT_EXECUTIVE=3600        # 60 minutes for Executive Chef
```

Timer resets when a task escalates to a new tier.

### 2.4 Test Verification

If `TEST_CMD` is configured:

```
Task signals COMPLETE
         ↓
    Run tests
         ↓
   ┌─────┴─────┐
   │           │
 Pass        Fail
   │           │
   ▼           ▼
Continue    Iterate
```

This ensures the task actually works, not just that the AI thinks it does.

### 2.5 Executive Review

If `REVIEW_ENABLED=true`:

After a task completes (and tests pass), the Executive Chef reviews:

1. Were all acceptance criteria met?
2. Does the code follow project patterns?
3. Are there obvious bugs or issues?

```
Task + Tests Pass
         ↓
 Executive Review
         ↓
   ┌─────┴─────┐
   │           │
 PASS        FAIL
   │           │
   ▼           ▼
Complete    Iterate
```

Configuration:
```bash
REVIEW_ENABLED=true
REVIEW_JUNIOR_ONLY=true  # Only review Line Cook work
```

## State Management

Brigade tracks state in `brigade-state.json`:

```json
{
  "sessionId": "1705512345-1234",
  "startedAt": "2025-01-17T10:00:00Z",
  "lastStartTime": "2025-01-18T14:30:00Z",
  "currentTask": null,
  "taskHistory": [
    {"taskId": "US-001", "worker": "sous", "status": "completed", "timestamp": "..."},
    {"taskId": "US-002", "worker": "line", "status": "completed", "timestamp": "..."}
  ],
  "escalations": [
    {"taskId": "US-002", "from": "line", "to": "sous", "reason": "...", "timestamp": "..."}
  ],
  "reviews": [
    {"taskId": "US-002", "result": "PASS", "reason": "All criteria met"}
  ],
  "absorptions": [
    {"taskId": "US-005", "absorbedBy": "US-003", "timestamp": "..."}
  ]
}
```

- **startedAt**: When the state file was first created (total time)
- **lastStartTime**: When the current run started (current run time)
- **currentTask**: Set during execution, cleared on completion (used by `resume`)
- **absorptions**: Tasks that were absorbed by other tasks

View with:
```bash
./brigade.sh status brigade/tasks/prd.json      # Current PRD stats
./brigade.sh status --all                       # Include escalations from other PRDs
```

The state file is validated on load - corrupted JSON is backed up and reset.

## Routing Logic

### Complexity Levels

Each task can have a `complexity` field:

- **`junior`** or **`line`**: Route to Line Cook
- **`senior`** or **`sous`**: Route to Sous Chef
- **`auto`** (default): Use heuristics to decide

### Auto-Routing Heuristics

When complexity is `auto`, Brigade analyzes the task:

**Route to Line Cook if:**
- Title contains "test", "boilerplate", "simple", "add flag"
- 3 or fewer acceptance criteria
- Task follows clear patterns

**Route to Sous Chef if:**
- Title contains "architecture", "design", "complex", "refactor"
- 4+ acceptance criteria
- Task requires judgment calls

## Worker Prompts

Each worker type has a prompt template in `chef/`:

- `chef/executive.md` - Director/reviewer instructions
- `chef/sous.md` - Senior developer instructions
- `chef/line.md` - Junior developer instructions

These prompts are prepended to the task details when firing a ticket.

## Completion Signals

Workers signal completion status via special tags:

```
<promise>COMPLETE</promise>           - Task finished successfully
<promise>BLOCKED</promise>            - Task cannot proceed (triggers escalation)
<promise>ALREADY_DONE</promise>       - Task was already completed (skips tests/review)
<promise>ABSORBED_BY:US-XXX</promise> - Work was done by another task (credits that task)
```

**ALREADY_DONE** is used when:
- A prior task already implemented this functionality
- The acceptance criteria are already satisfied
- No new code changes are needed

**ABSORBED_BY** is used when:
- Another specific task did this work as part of its implementation
- Credits the absorbing task for tracking purposes

Brigade also detects **empty git diffs** - if a worker signals COMPLETE but made no changes, it's automatically treated as ALREADY_DONE.

If no signal is found, Brigade iterates again (up to MAX_ITERATIONS).

## Dependency Management

Tasks can depend on other tasks:

```json
{
  "id": "US-003",
  "dependsOn": ["US-001", "US-002"]
}
```

Brigade will not start a task until all dependencies have `passes: true`.

## PRD Persistence

Task completion is saved directly to the PRD JSON file:

```json
{
  "id": "US-001",
  "passes": true  // Updated when task completes
}
```

This means:
- You can stop and resume at any time
- Progress survives crashes
- You can manually mark tasks complete/incomplete
