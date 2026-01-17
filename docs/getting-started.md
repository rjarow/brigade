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

**For cost savings**, use OpenCode/GLM for junior tasks:
```bash
# Option 1: Flag (one-off)
./brigade/brigade.sh --opencode plan "Build a CLI tool that does X"

# Option 2: Config (permanent)
echo "USE_OPENCODE=true" > brigade/brigade.config
./brigade/brigade.sh plan "Build a CLI tool that does X"
```

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

File: tasks/prd-add-user-authentication-with-jwt.json
Tasks: 7 total (4 senior, 3 junior)

Next steps:
  1. Review the PRD: cat tasks/prd-add-user-authentication-with-jwt.json | jq
  2. Run service:    ./brigade.sh service tasks/prd-add-user-authentication-with-jwt.json
```

### Step 2: Review the PRD

Check what was generated:

```bash
cat tasks/prd-add-user-authentication-with-jwt.json | jq
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
./brigade/brigade.sh service tasks/prd-add-user-authentication-with-jwt.json
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
./brigade/brigade.sh status tasks/prd-add-user-authentication-with-jwt.json
```

Output:
```
Kitchen Status: User Authentication with JWT

  Total tickets:    7
  Complete:         4
  Pending:          3

Pending Tickets:
  US-005: Add auth middleware [senior]
  US-006: Add logout endpoint [junior]
  US-007: Add endpoint tests [junior]

Session Stats:
  Escalations:      1
  Reviews:          3 (3 passed, 0 failed)

Escalation History:
  US-003: line → sous (3 iterations failed)
```

## Using Claude Code Skills

Brigade includes Claude Code skills for interactive PRD generation.

### Install Commands

Run the install script (one-time, works across all projects):

```bash
./brigade/install-commands.sh
```

This symlinks Brigade's commands to `~/.claude/commands/` where Claude Code discovers them.

**Updating:** Since these are symlinks, just `git pull` in `brigade/` to get updates. No re-installation needed.

### Use Commands

Now in Claude Code:

```
/brigade-generate-prd Add user authentication with OAuth and JWT tokens
```

The skill will:
1. Ask you clarifying questions
2. Explore your codebase (or detect greenfield)
3. Generate and save the PRD
4. Show you next steps

## Commands Reference

```bash
# Plan a feature (Director generates PRD)
./brigade.sh plan "Add feature description here"

# Run full service
./brigade.sh service tasks/prd.json

# Run single ticket
./brigade.sh ticket tasks/prd.json US-001

# Check kitchen status
./brigade.sh status tasks/prd.json

# Analyze task routing
./brigade.sh analyze tasks/prd.json
```

## What Happens During Execution

```
┌───────────────────────────────────────────────────────────────┐
│ 1. Load PRD                                                   │
│    Read tasks, build dependency graph                         │
└─────────────────────────┬─────────────────────────────────────┘
                          ▼
┌───────────────────────────────────────────────────────────────┐
│ 2. Get next task                                              │
│    Find task where: passes=false AND all dependencies met     │
└─────────────────────────┬─────────────────────────────────────┘
                          ▼
┌───────────────────────────────────────────────────────────────┐
│ 3. Route task                                                 │
│    junior → Line Cook,  senior → Sous Chef                    │
└─────────────────────────┬─────────────────────────────────────┘
                          ▼
┌───────────────────────────────────────────────────────────────┐
│ 4. Fire ticket                                                │
│    Send task + chef prompt to worker                          │
└─────────────────────────┬─────────────────────────────────────┘
                          ▼
┌───────────────────────────────────────────────────────────────┐
│ 5. Check for escalation                                       │
│    Line Cook fails 3x? → Escalate to Sous Chef                │
└─────────────────────────┬─────────────────────────────────────┘
                          ▼
┌───────────────────────────────────────────────────────────────┐
│ 6. Run tests (if configured)                                  │
│    Tests fail? → Iterate again                                │
└─────────────────────────┬─────────────────────────────────────┘
                          ▼
┌───────────────────────────────────────────────────────────────┐
│ 7. Executive review (if enabled)                              │
│    Review fails? → Iterate again                              │
└─────────────────────────┬─────────────────────────────────────┘
                          ▼
┌───────────────────────────────────────────────────────────────┐
│ 8. Mark complete, move to next task                           │
│    Repeat until all tasks done                                │
└───────────────────────────────────────────────────────────────┘
```

## Stop and Resume

Brigade saves progress to the PRD file. You can:

- **Stop anytime**: Ctrl+C
- **Resume later**: Run the same service command
- **Manual override**: Edit `"passes": true/false` in the PRD

## Next Steps

- Read [How It Works](./how-it-works.md) for deeper understanding
- Read [Configuration Guide](./configuration.md) for all options
- Read [Writing PRDs](./writing-prds.md) for PRD best practices
