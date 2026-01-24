# Commands

Complete reference for Brigade CLI commands.

> All commands work with both `./brigade.sh` (Bash) and `./brigade-go` (Go).

## Setup

### init

First-time setup wizard. Checks tools, creates config.

```bash
./brigade.sh init
```

### demo

Preview what Brigade does without executing.

```bash
./brigade.sh demo
```

## Planning

### plan

Generate a PRD via Executive Chef.

```bash
./brigade.sh plan "Add user authentication with JWT"
```

The Executive Chef will:
1. Ask clarifying questions about scope
2. Analyze your codebase
3. Generate a PRD with tasks

### template

Generate PRD from a template.

```bash
./brigade.sh template                  # List templates
./brigade.sh template api users        # REST API for "users"
./brigade.sh template auth             # Auth system
```

### validate

Validate PRD structure and quality.

```bash
./brigade.sh validate brigade/tasks/prd.json
```

Checks: JSON syntax, required fields, dependency cycles, acceptance criteria quality, verification coverage.

### map

Generate codebase analysis (auto-included in future planning).

```bash
./brigade.sh map
```

Creates `codebase-map.md` with structure, patterns, and tech stack.

## Execution

### service

Execute all tasks in a PRD.

```bash
./brigade.sh service brigade/tasks/prd.json
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
./brigade.sh --only US-001,US-003 service prd.json   # Run specific tasks
./brigade.sh --skip US-007 service prd.json          # Skip specific tasks
./brigade.sh --from US-003 service prd.json          # Start from task
./brigade.sh --until US-005 service prd.json         # Run up to task
```

### ticket

Run a single task.

```bash
./brigade.sh ticket brigade/tasks/prd.json US-001
```

### resume

Resume after interruption.

```bash
./brigade.sh resume                         # Auto-detect, prompt retry/skip
./brigade.sh resume brigade/tasks/prd.json  # Specify PRD
./brigade.sh resume retry                   # Retry failed task
./brigade.sh resume skip                    # Skip and continue
```

### iterate

Quick tweak on completed PRD.

```bash
./brigade.sh iterate "make the button blue"
```

Creates a micro-PRD and executes it.

## Monitoring

### status

Check progress.

```bash
./brigade.sh status                    # Current state
./brigade.sh status --watch            # Auto-refresh every 30s
./brigade.sh status --json             # Machine-readable JSON
./brigade.sh status --brief            # Ultra-compact JSON
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
./brigade.sh summary brigade/tasks/prd.json
```

### cost

Show estimated cost breakdown.

```bash
./brigade.sh cost brigade/tasks/prd.json
```

### risk

Pre-execution risk assessment.

```bash
./brigade.sh risk brigade/tasks/prd.json
./brigade.sh risk --history brigade/tasks/prd.json  # Include historical patterns
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success / COMPLETE |
| 1 | General error / needs iteration |
| 32 | BLOCKED - task cannot proceed |
| 33 | ALREADY_DONE - prior task completed this |
| 34 | ABSORBED_BY - work absorbed by another task |

