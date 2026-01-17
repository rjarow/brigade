# How Brigade Works

Brigade is a multi-model AI orchestration framework that routes tasks to different AI models based on complexity, then verifies completion through tests and signals.

## The Kitchen Metaphor

Brigade uses kitchen terminology because the workflow mirrors a professional kitchen:

| Kitchen | Brigade | Description |
|---------|---------|-------------|
| Executive Chef | Opus/GPT-4 | Directs, reviews, makes judgment calls |
| Sous Chef | Sonnet/GPT-4 | Handles complex dishes (tasks) |
| Line Cook | GLM/local models | Handles routine prep work |
| Ticket | Task | Individual unit of work |
| The Pass | Review | Quality check before completion |
| Service | Full run | Complete execution of all tasks |
| 86'd | Blocked | Task cannot be completed |
| Fire | Start | Begin working on a task |

## Execution Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. LOAD PRD                                                     │
│    Read tasks, build dependency graph                           │
└─────────────────────────┬───────────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────────┐
│ 2. GET NEXT TASK                                                │
│    Find task where: passes=false AND all dependencies met       │
└─────────────────────────┬───────────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────────┐
│ 3. ROUTE TASK                                                   │
│    Based on complexity: junior → Line Cook, senior → Sous Chef  │
└─────────────────────────┬───────────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────────┐
│ 4. FIRE TICKET                                                  │
│    Send task + chef prompt to worker AI                         │
└─────────────────────────┬───────────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────────┐
│ 5. CHECK COMPLETION                                             │
│    Look for <promise>COMPLETE</promise> or BLOCKED signal       │
└─────────────────────────┬───────────────────────────────────────┘
                          │
              ┌───────────┴───────────┐
              │                       │
      ┌───────▼───────┐       ┌───────▼───────┐
      │ COMPLETE      │       │ NOT COMPLETE  │
      │ Run tests     │       │ Iterate again │
      └───────┬───────┘       └───────┬───────┘
              │                       │
      ┌───────▼───────┐               │
      │ Tests pass?   │               │
      │ Mark complete │◄──────────────┘
      │ Next task     │  (up to MAX_ITERATIONS)
      └───────────────┘
```

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

### Manual Override

You can always set explicit complexity in your PRD:

```json
{
  "id": "US-005",
  "title": "Implement caching layer",
  "complexity": "senior",
  ...
}
```

## Worker Prompts

Each worker type has a prompt template in `chef/`:

- `chef/sous.md` - Senior developer instructions
- `chef/line.md` - Junior developer instructions
- `chef/executive.md` - Director/reviewer instructions

These prompts are prepended to the task details when firing a ticket.

## Completion Signals

Workers signal completion status via special tags:

```
<promise>COMPLETE</promise>  - Task finished successfully
<promise>BLOCKED</promise>   - Task cannot proceed (with explanation)
```

If neither signal is found, Brigade iterates again (up to MAX_ITERATIONS).

## Test Integration

If `TEST_CMD` is configured:

1. After `COMPLETE` signal, tests are run
2. If tests pass → task marked complete
3. If tests fail → iterate again

This ensures tasks actually work, not just that the AI thinks they do.

## Dependency Management

Tasks can depend on other tasks:

```json
{
  "id": "US-003",
  "dependsOn": ["US-001", "US-002"],
  ...
}
```

Brigade will not start a task until all dependencies have `passes: true`.

## State Persistence

Task completion is saved directly to the PRD JSON file:

```json
{
  "id": "US-001",
  "passes": true,  // Updated when task completes
  ...
}
```

This means:
- You can stop and resume at any time
- Progress survives crashes
- You can manually mark tasks complete/incomplete
