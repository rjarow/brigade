# Getting Started with Brigade

This guide will get you up and running with Brigade in 5 minutes.

## Prerequisites

**Required:**
- **Claude CLI** (`claude`) - that's it!
- **jq** - for JSON processing
- **bash** 4.0+

**Optional (for cost savings):**
- **OpenCode** (`opencode`) - for Line Cook junior tasks (cheaper than Claude)

## Installation

Brigade can be dropped into any project - existing or new.

### New Project (Greenfield)

The simplest way to start. You don't need to set up anything - Brigade handles it all.

```bash
# Create your project
mkdir my-idea && cd my-idea
git init

# Add Brigade
git clone https://github.com/yourusername/brigade.git

# Start planning - Brigade will ask about language, framework, everything
./brigade/brigade.sh plan "Build a CLI tool that does X"
```

That's it. No config file needed. Brigade uses Claude for all workers by default.

**For cost savings**, use OpenCode for junior tasks:

First, configure OpenCode to auto-approve (required for non-interactive use):
```bash
# Add to ~/.config/opencode/opencode.json
{
  "permission": "allow"
}
```

Then enable in Brigade config:
```bash
# brigade/brigade.config
USE_OPENCODE=true
OPENCODE_MODEL="zai-coding-plan/glm-4.7"
```

Run `./brigade.sh opencode-models` to see available models.

Brigade will:
1. **Detect** that this is an empty project
2. **Interview you** about tech stack, requirements, scope
3. **Generate a PRD** that starts with project setup (language, test framework, etc.)
4. **Execute** everything - you come back to a working project with tests

### Existing Project

```bash
cd your-project

# Option 1: Clone as subdirectory
git clone https://github.com/yourusername/brigade.git

# Option 2: Clone and symlink (recommended for development)
git clone https://github.com/yourusername/brigade.git ~/brigade
ln -s ~/brigade ./brigade

# Option 3: Add as git submodule
git submodule add https://github.com/yourusername/brigade.git brigade
```

## Configuration (Optional)

Brigade works out of the box with just Claude CLI. Config is only needed if you want to:
- Use OpenCode for junior tasks (cost savings)
- Customize escalation/review settings
- Set a test command

```bash
cp brigade/brigade.config.example brigade/brigade.config
```

Edit `brigade/brigade.config`:

```bash
# Workers - defaults use Claude for everything
EXECUTIVE_CMD="claude --model opus"      # Director (plans, reviews)
SOUS_CMD="claude --model sonnet"         # Senior (complex tasks)
LINE_CMD="claude --model sonnet"         # Junior (routine tasks)

# COST OPTIMIZATION: Use OpenCode for junior tasks
# LINE_CMD="opencode run --command"
# LINE_AGENT="opencode"

# Test command (auto-detected from project setup tasks)
TEST_CMD=""  # Leave empty - setup tasks configure this

# Escalation
ESCALATION_ENABLED=true
ESCALATION_AFTER=3

# Executive review
REVIEW_ENABLED=true
REVIEW_JUNIOR_ONLY=true
```

## Your First Feature

### Step 1: Plan the Feature

Tell Brigade what you want to build:

```bash
./brigade/brigade.sh plan "Add user authentication with JWT"
```

The Executive Chef (Opus) will:

1. **Interview you** - Ask clarifying questions about scope and requirements
2. **Analyze your codebase** - Understand project structure and patterns
3. **Generate a PRD** - Create a task breakdown with proper complexity assignments

Output:
```
═══════════════════════════════════════════════════════════
EXECUTIVE CHEF: Planning Phase
Feature: Add user authentication with JWT
═══════════════════════════════════════════════════════════

[Director explores codebase, asks questions, generates PRD...]

╔═══════════════════════════════════════════════════════════╗
║  PRD GENERATED                                            ║
╚═══════════════════════════════════════════════════════════╝

File: brigade/tasks/prd-add-user-authentication-with-jwt.json
Tasks: 7 total (4 senior, 3 junior)

Next steps:
  1. Review the PRD: cat brigade/tasks/prd-add-user-authentication-with-jwt.json | jq
  2. Run service:    ./brigade.sh service brigade/tasks/prd-add-user-authentication-with-jwt.json
```

### Step 2: Review the PRD

Check what was generated:

```bash
cat brigade/tasks/prd-add-user-authentication-with-jwt.json | jq
```

You can edit the PRD if needed:
- Adjust complexity assignments
- Add/remove tasks
- Modify acceptance criteria
- Reorder dependencies

**Verify test coverage**: Every PRD should include:
- Test requirements in implementation task acceptance criteria
- Dedicated test tasks for each major component
- Test tasks should depend on their implementation tasks

### Step 3: Execute

Run the full service:

```bash
./brigade/brigade.sh service brigade/tasks/prd-add-user-authentication-with-jwt.json
```

Brigade will:
1. Execute each task in dependency order
2. Route to Line Cook or Sous Chef based on complexity
3. Escalate junior failures to senior
4. Run tests after each task
5. Have Executive Chef review before marking complete

### Step 4: Monitor Progress

Check status:

```bash
./brigade/brigade.sh status brigade/tasks/prd-add-user-authentication-with-jwt.json
```

Output:
```
Kitchen Status: User Authentication with JWT
═══════════════════════════════════════════════════════════

📊 Progress: [████████░░░░░░░░░░░░] 57% (4/7)

Tasks:
  ✓ US-001: Add User model
  ✓ US-002: Add User model tests
  ✓ US-003: Add JWT utilities [Sous Chef] ⬆
  ✓ US-004: Add login endpoint
  → US-005: Add auth middleware [Sous Chef]
  ◐ US-006: Add logout endpoint [Line Cook] awaiting review
  ○ US-007: Add endpoint tests [Line Cook]

Session Stats:
  Total time:       2h 15m
  Current run:      0h 45m
  Escalations:      1
  Absorptions:      0
  Reviews:          4 (4 passed, 0 failed)

Escalation History:
  2025-01-17 14:23 US-003: line → sous
```

**Status Markers:**
| Marker | Meaning |
|--------|---------|
| `✓` | Reviewed and confirmed complete |
| `→` | Currently in progress |
| `◐` | Worked on, awaiting review |
| `○` | Not started yet |
| `⬆` | Was escalated to higher tier |

Worker assignments show who will handle each pending task.

## Using Claude Code (Recommended)

The easiest way to use Brigade is through Claude Code with the `/brigade` skill. Claude becomes your supervisor - handling planning, execution, and progress reporting in natural language.

### Install the Skill

```bash
./brigade/install-commands.sh
```

This symlinks Brigade's commands to `~/.claude/commands/`.

### The Simplest Workflow

```
You: /brigade plan "Add user authentication with JWT"

Claude: I'll help you plan this feature. Will this run unattended
        (walkaway mode) or will you be monitoring?

You: walkaway - I want to run this overnight

Claude: Walkaway mode means I'll run autonomously. I need to ask
        thorough questions NOW. [Asks detailed questions about scope,
        error handling, edge cases...]

You: [Answer questions]

Claude: PRD saved with 8 tasks. Ready to execute?

You: yes

Claude: Starting in walkaway mode. Brigade will handle decisions
        autonomously. I'll report when it's done.

        [Later...]

        Complete! 8/8 tasks done in 45 minutes.
        Branch `feature/auth` ready for review.
```

### Available Commands

| Command | What It Does |
|---------|--------------|
| `/brigade` | Show all options |
| `/brigade plan "X"` | Plan a feature (interview + generate PRD) |
| `/brigade run` | Execute a PRD |
| `/brigade status` | Check progress in natural language |
| `/brigade resume` | Handle failures (retry/skip/investigate) |
| `/brigade update` | Modify an existing PRD |
| `/brigade convert` | Convert markdown/text to PRD JSON |

### Why This Works

**Walkaway philosophy**: Interview thoroughly once, then autonomous execution. You shouldn't need to babysit.

**Token efficiency**: Claude uses `--brief` status and event streaming. No bloated context, no repeated full status calls.

**Natural language**: Progress reported as "5/8 done, working on auth middleware" not raw JSON.

## Commands Reference

```bash
# Plan a feature (Director generates PRD)
./brigade.sh plan "Add feature description here"

# Run full service
./brigade.sh service brigade/tasks/prd.json

# Chain multiple PRDs for overnight/unattended execution
./brigade.sh --auto-continue service brigade/tasks/prd-*.json

# Resume after interruption
./brigade.sh resume                    # Auto-detect, prompt for retry/skip
./brigade.sh resume prd.json retry     # Retry the failed task
./brigade.sh resume prd.json skip      # Skip and continue

# Run single ticket
./brigade.sh ticket brigade/tasks/prd.json US-001

# Check kitchen status
./brigade.sh status brigade/tasks/prd.json
./brigade.sh status --watch            # Auto-refresh every 30s
./brigade.sh status --all              # Include escalations from other PRDs

# Validate PRD structure
./brigade.sh validate brigade/tasks/prd.json

# Preview execution without running
./brigade.sh --dry-run service brigade/tasks/prd.json

# Analyze task routing
./brigade.sh analyze brigade/tasks/prd.json
```

## What Happens During Execution

```
┌───────────────────────────────────────────────────────────────┐
│ 1. Load PRD                                                   │
│    Read tasks, build dependency graph, validate structure     │
└─────────────────────────┬─────────────────────────────────────┘
                          ▼
┌───────────────────────────────────────────────────────────────┐
│ 2. Get next task                                              │
│    Find task where: passes=false AND all dependencies met     │
└─────────────────────────┬─────────────────────────────────────┘
                          ▼
┌───────────────────────────────────────────────────────────────┐
│ 3. Pre-flight check                                           │
│    Run tests first - if passing, task may already be done     │
└─────────────────────────┬─────────────────────────────────────┘
                          ▼
┌───────────────────────────────────────────────────────────────┐
│ 4. Route task                                                 │
│    junior → Line Cook,  senior → Sous Chef                    │
└─────────────────────────┬─────────────────────────────────────┘
                          ▼
┌───────────────────────────────────────────────────────────────┐
│ 5. Fire ticket                                                │
│    Send task + chef prompt to worker                          │
└─────────────────────────┬─────────────────────────────────────┘
                          ▼
┌───────────────────────────────────────────────────────────────┐
│ 6. Check for escalation (thresholds configurable)             │
│    Line Cook fails 3x or times out (15m)? → Sous Chef         │
│    Sous Chef fails 5x or times out (30m)? → Executive Chef    │
│    Worker signals BLOCKED? → Immediate escalation             │
└─────────────────────────┬─────────────────────────────────────┘
                          ▼
┌───────────────────────────────────────────────────────────────┐
│ 7. Check completion signals                                   │
│    COMPLETE → run verification, ALREADY_DONE → skip to next   │
│    ABSORBED_BY:US-XXX → mark done, credit other task          │
└─────────────────────────┬─────────────────────────────────────┘
                          ▼
┌───────────────────────────────────────────────────────────────┐
│ 8. Run verification commands (if defined in PRD)              │
│    Any command fails? → Iterate again with feedback           │
└─────────────────────────┬─────────────────────────────────────┘
                          ▼
┌───────────────────────────────────────────────────────────────┐
│ 9. Run tests (if configured)                                  │
│    Tests fail? → Iterate again                                │
└─────────────────────────┬─────────────────────────────────────┘
                          ▼
┌───────────────────────────────────────────────────────────────┐
│ 10. Executive review (if enabled)                             │
│     Review fails? → Iterate again                             │
└─────────────────────────┬─────────────────────────────────────┘
                          ▼
┌───────────────────────────────────────────────────────────────┐
│ 11. Mark complete, show summary, move to next task            │
│     Repeat until all tasks done                               │
└───────────────────────────────────────────────────────────────┘
```

## Stop and Resume

Brigade saves progress to the PRD file and state file. You can:

- **Stop anytime**: Ctrl+C
- **Resume with options**: `./brigade.sh resume` to retry or skip the interrupted task
- **Continue service**: Run the same service command (skips completed tasks)
- **Manual override**: Edit `"passes": true/false` in the PRD

The `resume` command detects interrupted tasks and lets you choose:
- `retry` - Start the task fresh with the same worker
- `skip` - Mark as skipped and continue to next task

## Next Steps

- Read [How It Works](./how-it-works.md) for deeper understanding
- Read [Configuration Guide](./configuration.md) for all options
- Read [Writing PRDs](./writing-prds.md) for PRD best practices
