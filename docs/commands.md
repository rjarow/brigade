# Commands

Complete reference for Brigade CLI commands.

> The legacy `./brigade.sh` also supports these commands but Go is recommended.

## Setup

### init

First-time setup wizard. Checks tools, creates config.

```bash
./brigade-go init
```

### demo

Preview what Brigade does without executing.

```bash
./brigade-go demo
```

## Planning

### plan

Generate a PRD via Executive Chef.

```bash
./brigade-go plan "Add user authentication with JWT"
```

The Executive Chef will:
1. Ask clarifying questions about scope
2. Analyze your codebase
3. Generate a PRD with tasks

### template

Generate PRD from a template.

```bash
./brigade-go template                  # List templates
./brigade-go template api users        # REST API for "users"
./brigade-go template auth             # Auth system
```

### validate

Validate PRD structure and quality.

```bash
./brigade-go validate brigade/tasks/prd.json
```

Checks: JSON syntax, required fields, dependency cycles, acceptance criteria quality, verification coverage.

### map

Generate codebase analysis (auto-included in future planning).

```bash
./brigade-go map
```

Creates `codebase-map.md` with structure, patterns, and tech stack.

## Execution

### service

Execute all tasks in a PRD.

```bash
./brigade-go service brigade/tasks/prd.json
```

#### Flags

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview execution without running |
| `--walkaway` | AI decides retry/skip on failures |
| `--auto-continue` | Chain multiple PRDs |
| `--sequential` | Force sequential execution (no parallelism) |

#### Partial Execution

```bash
./brigade-go --only US-001,US-003 service prd.json   # Run specific tasks
./brigade-go --skip US-007 service prd.json          # Skip specific tasks
./brigade-go --from US-003 service prd.json          # Start from task
./brigade-go --until US-005 service prd.json         # Run up to task
```

### ticket

Run a single task.

```bash
./brigade-go ticket brigade/tasks/prd.json US-001
```

### resume

Resume after interruption.

```bash
./brigade-go resume                         # Auto-detect, prompt retry/skip
./brigade-go resume brigade/tasks/prd.json  # Specify PRD
./brigade-go resume retry                   # Retry failed task
./brigade-go resume skip                    # Skip and continue
```

### iterate

Quick tweak on completed PRD.

```bash
./brigade-go iterate "make the button blue"
```

Creates a micro-PRD and executes it.

## Monitoring

### status

Check progress.

```bash
./brigade-go status                    # Current state
./brigade-go status --watch            # Auto-refresh every 30s
./brigade-go status --json             # Machine-readable JSON
./brigade-go status --brief            # Ultra-compact JSON
```

#### Status Symbols

| Symbol | Meaning |
|--------|---------|
| `✓` | Complete and reviewed |
| `→` | Currently in progress |
| `◐` | Worked on, awaiting review |
| `○` | Not started |
| `⬆` | Was escalated |

### summary

Generate markdown report from state.

```bash
./brigade-go summary brigade/tasks/prd.json
```

### cost

Show estimated cost breakdown.

```bash
./brigade-go cost brigade/tasks/prd.json
```

### risk

Pre-execution risk assessment.

```bash
./brigade-go risk brigade/tasks/prd.json
./brigade-go risk --history brigade/tasks/prd.json  # Include historical patterns
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success / COMPLETE |
| 1 | General error / needs iteration |
| 32 | BLOCKED - task cannot proceed |
| 33 | ALREADY_DONE - prior task completed this |
| 34 | ABSORBED_BY - work absorbed by another task |

