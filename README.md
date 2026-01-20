# Brigade

Multi-model AI orchestration framework. Route tasks to the right AI based on complexity.

```
┌─────────────────────────────────────────────────────────────────┐
│                     USER REQUEST                                │
│            "Add user authentication"                            │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                 EXECUTIVE CHEF (Opus)                           │
│  • Interviews user for requirements                             │
│  • Analyzes codebase                                            │
│  • Generates PRD with tasks                                     │
│  • Assigns complexity (junior/senior)                           │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                    EXECUTION PHASE                              │
│                                                                 │
│  ┌─────────────────┐    escalate     ┌─────────────────┐       │
│  │  LINE COOK      │ ──────────────► │   SOUS CHEF     │       │
│  │  (GLM/OpenCode) │  after 3 fails  │   (Sonnet)      │       │
│  │  Junior tasks   │   or blocked    │   Senior tasks  │       │
│  └────────┬────────┘                 └────────┬────────┘       │
│           │                                   │                 │
│           └───────────────┬───────────────────┘                 │
│                           ▼                                     │
│              ┌─────────────────────────┐                        │
│              │   EXECUTIVE REVIEW      │                        │
│              │   (Opus)                │                        │
│              │   Quality gate          │                        │
│              └─────────────────────────┘                        │
└─────────────────────────────────────────────────────────────────┘
```

## Why Brigade?

- **Minimal owner disruption**: Interview once, then autonomous execution
- **Fresh context per task**: Each worker starts clean - no context pollution between tasks
- **Cost optimization**: Use expensive models only when needed
- **Right tool for the job**: Architecture decisions need senior thinking, boilerplate doesn't
- **Automatic escalation**: Junior failures auto-escalate to senior
- **Quality control**: Verification commands + tests + Executive Chef review
- **Multi-model**: Mix Claude, OpenCode, GPT, local models - whatever works
- **Knowledge sharing**: Workers share learnings without sharing bloated context

## Philosophy

The **Owner** (you) should be minimally disrupted:

1. **Interview once** - Director asks all the right questions upfront
2. **Autonomous execution** - Team works without bothering you
3. **Escalate only when necessary** - Scope changes, blockers, or decisions beyond their authority

After the initial interview, you can walk away and come back to completed work.

## Quick Start

### New Project (Greenfield) - Zero Setup

Don't know what language to use? No problem. Brigade handles everything.

**Prerequisites:** Just the `claude` CLI. That's it.

```bash
# Create empty project
mkdir my-idea && cd my-idea
git init

# Add Brigade
git clone https://github.com/yourusername/brigade.git

# Start the interview - Brigade asks about tech stack, requirements, everything
./brigade/brigade.sh plan "Build a CLI tool that syncs files to S3"

# Brigade will:
# 1. Ask what language/framework you want
# 2. Ask about scope and requirements
# 3. Generate PRD with setup tasks (project init, test framework) + feature tasks
# 4. Execute everything autonomously

# Run it
./brigade/brigade.sh service brigade/tasks/prd-*.json
```

No config file needed. Brigade uses Claude for all workers by default.

**Want cost savings?** Configure OpenCode in `brigade/brigade.config`:

```bash
USE_OPENCODE=true
OPENCODE_MODEL="zai-coding-plan/glm-4.7"
```

Run `opencode models` to see all available models. Common options:
- `zai-coding-plan/glm-4.7` - GLM 4.7 (fast, cheap)
- `opencode/glm-4.7-free` - GLM 4.7 free tier
- `anthropic/claude-sonnet-4-5` - Claude Sonnet 4.5 via OpenCode

### Existing Project

```bash
# Clone Brigade into your project
cd your-project
git clone https://github.com/yourusername/brigade.git

# Configure for your stack
cp brigade/brigade.config.example brigade/brigade.config
vim brigade/brigade.config  # Set your test command, etc.

# Plan a feature (Director interviews you, analyzes codebase, generates PRD)
./brigade/brigade.sh plan "Add user authentication with JWT"

# Review the generated PRD
cat brigade/tasks/prd-add-user-authentication-with-jwt.json | jq

# Execute with your multi-model team
./brigade/brigade.sh service brigade/tasks/prd-add-user-authentication-with-jwt.json
```

### Using Claude Code Skills

Brigade includes Claude Code skills for interactive PRD generation.

**Install commands** (one-time, works across all projects):
```bash
./brigade/install-commands.sh
```

**Updating:** Since these are symlinks, just `git pull` in `brigade/` to get updates. No re-installation needed.

**Use skills** in Claude Code:
```
/brigade-generate-prd Add user authentication with OAuth and JWT tokens
```

The skill will:
1. Ask clarifying questions about your requirements
2. Explore your codebase to understand patterns
3. Generate a properly structured PRD
4. Save it to `brigade/tasks/` for execution

## Configuration (Optional)

Brigade works out of the box with just the `claude` CLI. No config needed.

To customize workers or enable cost optimization, create `brigade/brigade.config`:

```bash
# Workers - configure which agent handles each role
EXECUTIVE_CMD="claude --model opus"
EXECUTIVE_AGENT="claude"              # claude, opencode, codex, gemini, aider, local

SOUS_CMD="claude --model sonnet"
SOUS_AGENT="claude"

LINE_CMD="opencode run --command"     # OpenCode for cost-efficient junior work
LINE_AGENT="opencode"

# Agent-specific settings (provider/model format)
OPENCODE_MODEL="z-ai/glm-4.7"        # GLM 4.7 via Z.AI provider
# OPENCODE_SERVER="http://localhost:4096"  # Optional: server for faster cold starts

# Test command to verify tasks
TEST_CMD="npm test"  # or: go test ./..., pytest, cargo test

# Escalation: auto-promote to senior after N junior failures
ESCALATION_ENABLED=true
ESCALATION_AFTER=3

# Executive review after task completion
REVIEW_ENABLED=true
REVIEW_JUNIOR_ONLY=true  # Only review junior work (saves Opus calls)

# Knowledge sharing between workers
KNOWLEDGE_SHARING=true

# Parallel junior workers
MAX_PARALLEL=3
```

### Supported Agents

| Agent | Status | Best For |
|-------|--------|----------|
| `claude` | Ready | Executive, Senior (Opus/Sonnet) |
| `opencode` | Ready | Junior tasks (GLM, DeepSeek) |
| `codex` | Coming Soon | OpenAI Codex |
| `gemini` | Coming Soon | Google Gemini |
| `aider` | Coming Soon | Aider |
| `local` | Coming Soon | Ollama local models |

## Commands

```bash
# Plan a feature (Director generates PRD)
./brigade.sh plan "Add feature description here"

# Run full service (all tasks)
./brigade.sh service brigade/tasks/prd.json

# Chain multiple PRDs for overnight/unattended execution
./brigade.sh --auto-continue service brigade/tasks/prd-*.json

# Resume after interruption (retry or skip failed task)
./brigade.sh resume                              # Auto-detect PRD
./brigade.sh resume brigade/tasks/prd.json retry # Retry the task
./brigade.sh resume brigade/tasks/prd.json skip  # Skip and continue

# Run single ticket
./brigade.sh ticket brigade/tasks/prd.json US-001

# Check kitchen status
./brigade.sh status brigade/tasks/prd.json       # Show current PRD stats
./brigade.sh status --watch                      # Auto-refresh every 30s
./brigade.sh status --all                        # Include escalations from other PRDs

# Validate PRD structure
./brigade.sh validate brigade/tasks/prd.json

# Preview execution without running
./brigade.sh --dry-run service brigade/tasks/prd.json

# Analyze routing
./brigade.sh analyze brigade/tasks/prd.json
```

## The Flow

### 1. Planning Phase (Director/Opus)

When you run `./brigade.sh plan "..."` or `/brigade-generate-prd`:

1. **Interview**: Director asks clarifying questions
   - What's the scope?
   - Any specific requirements?
   - Preferred approaches?

2. **Analysis**: Director explores your codebase
   - Project structure
   - Existing patterns
   - Tech stack
   - Test conventions

3. **PRD Generation**: Creates task breakdown
   - Atomic, well-scoped tasks
   - Appropriate complexity assignments
   - Dependency ordering
   - Specific acceptance criteria

### 2. Execution Phase

For each task:

1. **Pre-flight check** - Run tests first; skip task if already passing
2. **Route** based on complexity → Line Cook or Sous Chef
3. **Execute** task with fresh context (no pollution from previous tasks)
4. **Escalate** automatically:
   - Line Cook fails 3x or times out (15m) → Sous Chef
   - Sous Chef fails 5x or times out (30m) → Executive Chef
   - Worker signals `BLOCKED` → Immediate escalation
5. **Verify** - Run verification commands if defined in PRD
6. **Test** if TEST_CMD configured
7. **Review** Executive Chef checks quality (optional)
8. **Complete** or iterate

### 3. Quality Gates

- **Completion signals**: Workers output `<promise>COMPLETE</promise>`
- **Already done detection**: `<promise>ALREADY_DONE</promise>` skips redundant work
- **Task absorption**: `<promise>ABSORBED_BY:US-XXX</promise>` when prior task did the work
- **Empty diff detection**: Catches workers claiming completion without changes
- **Verification commands**: Custom checks run after COMPLETE (grep for patterns, targeted tests)
- **Test verification**: Full test suite runs after verification passes
- **Executive review**: Opus reviews junior work before approval
- **Escalation**: Failures promote to higher tier automatically

## PRD Format

```json
{
  "featureName": "My Feature",
  "branchName": "feature/my-feature",
  "createdAt": "2025-01-17",
  "description": "Brief description",
  "tasks": [
    {
      "id": "US-001",
      "title": "Add user model",
      "description": "As a developer, I want a User model...",
      "acceptanceCriteria": [
        "User model has id, email, password_hash fields",
        "Email validation works",
        "Unit tests for validation logic"
      ],
      "verification": [
        "grep -q 'class User' src/models/user.ts",
        "npm test -- --grep 'User model'"
      ],
      "dependsOn": [],
      "complexity": "senior",
      "passes": false
    },
    {
      "id": "US-002",
      "title": "Add user model tests",
      "description": "Comprehensive tests for User model",
      "acceptanceCriteria": [
        "Test user creation with valid data",
        "Test email validation rejects invalid formats",
        "Test password hashing works correctly"
      ],
      "dependsOn": ["US-001"],
      "complexity": "junior",
      "passes": false
    }
  ]
}
```

**Note**: The `verification` array is optional but recommended. Commands run after COMPLETE signal - all must pass (exit 0).

### Complexity Levels

| Level | Routes To | Use For |
|-------|-----------|---------|
| `junior` | Line Cook (GLM) | Tests, boilerplate, simple CRUD, docs |
| `senior` | Sous Chef (Sonnet) | Architecture, security, complex logic |
| `auto` | Heuristics decide | When unsure |

## Kitchen Terminology

| Term | Meaning |
|------|---------|
| Service | Full run through all tasks |
| Ticket | Individual task |
| The Pass | Review stage before completion |
| 86'd | Task blocked |
| Fire | Start working on task |
| Escalate | Promote to higher tier |

## State Tracking

Brigade maintains per-PRD state files (`prd-*.state.json`):

```bash
./brigade.sh status                           # Auto-detect active PRD
./brigade.sh status brigade/tasks/prd.json    # Specific PRD
```

### Status Markers

| Marker | Meaning |
|--------|---------|
| `✓` | Reviewed and confirmed complete |
| `→` | Currently in progress |
| `◐` | Worked on, awaiting review |
| `○` | Not started yet |
| `⬆` | Escalated to higher tier |

### Status Output

Shows:
- Progress bar with completion percentage
- Task list with status markers and worker assignments
- Session stats (time, reviews, escalations)

Use `--all` to see escalations from previous PRDs in the same session.

### Quiet Mode

For cleaner logs during long runs:

```bash
QUIET_WORKERS=true  # In brigade.config
```

Shows an animated spinner instead of full conversation output:
```
⠋ US-003: Add user validation (2m 45s)
```

### Monitoring

For long-running or unattended execution:

```bash
# Auto-refreshing status display
./brigade.sh status --watch

# Activity heartbeat log (tail -f friendly)
ACTIVITY_LOG="brigade/tasks/activity.log"

# Per-task worker logs for debugging
WORKER_LOG_DIR="brigade/logs/"

# Timeout warnings before hard timeout
TASK_TIMEOUT_WARNING_JUNIOR=10  # minutes
TASK_TIMEOUT_WARNING_SENIOR=20
```

## Autonomous Execution Modes

Brigade supports three levels of autonomy, which can be combined:

| Mode | Who Decides | Best For |
|------|-------------|----------|
| **Interactive** (default) | Human at terminal | Active development, debugging |
| **Walkaway** | Executive Chef AI | Overnight runs, fire-and-forget |
| **Supervisor** | External AI (Claude, etc.) | AI-managed pipelines, TUI tools |

### Interactive Mode (Default)

Brigade prompts you at the terminal when decisions are needed:
- Task fails after max iterations → "Retry, skip, or abort?"
- Worker asks scope question → Shows question, waits for answer
- Resume after interruption → "Retry or skip the failed task?"

### Walkaway Mode

Brigade's built-in Executive Chef makes decisions autonomously:

```bash
./brigade.sh --walkaway service prd.json
# Or set in PRD: "walkaway": true
```

**What happens:**
- Task fails → Exec Chef analyzes error context, decides retry/skip/abort
- Scope question → Exec Chef makes judgment call based on PRD context
- All decisions logged to state file (`walkawayDecisions`, `scopeDecisions`)

**Safety rails:**
- `WALKAWAY_MAX_SKIPS=3` - Aborts if too many consecutive skips (prevents runaway)
- Decisions recorded for human review later

**Example:** You start Brigade before bed, wake up to completed PRD or a clear stopping point.

### Supervisor Mode

An external AI (or tool) monitors Brigade and sends commands:

```bash
# In brigade.config:
SUPERVISOR_STATUS_FILE="brigade/tasks/status.json"   # Compact status JSON
SUPERVISOR_EVENTS_FILE="brigade/tasks/events.jsonl"  # Event stream (tail -f)
SUPERVISOR_CMD_FILE="brigade/tasks/cmd.json"         # Command ingestion
```

**How it works:**
1. Brigade writes events to `events.jsonl` (task starts, completions, failures)
2. Supervisor tails the event stream
3. When `decision_needed` event appears, supervisor writes command to `cmd.json`
4. Brigade reads command and continues

**Example supervisor setup with Claude:**
```bash
# Terminal 1: Start Brigade with supervisor config
SUPERVISOR_EVENTS_FILE=events.jsonl SUPERVISOR_CMD_FILE=cmd.json \
  ./brigade.sh service prd.json

# Terminal 2: Claude monitors and decides
claude "Monitor events.jsonl. When you see decision_needed events,
        analyze the context and write your decision to cmd.json.
        Format: {\"decision\":\"d-XXX\",\"action\":\"retry|skip\",\"reason\":\"...\"}"
```

### Combining Modes

Walkaway and Supervisor work together with **supervisor taking priority**:

```bash
# Supervisor handles decisions when available, walkaway as fallback
SUPERVISOR_CMD_FILE="cmd.json" ./brigade.sh --walkaway service prd.json
```

**Decision priority:**
1. If supervisor configured → Wait for supervisor command (with timeout)
2. If walkaway mode → Exec Chef decides
3. Otherwise → Prompt human interactively

**Use case:** Supervisor AI handles most decisions, but if it crashes or times out, walkaway mode keeps things moving.

### Choosing a Mode

| Scenario | Recommended Mode |
|----------|------------------|
| Active development | Interactive |
| Overnight run, simple PRD | Walkaway |
| Overnight run, complex PRD | Walkaway + review decisions next day |
| AI-managed pipeline | Supervisor |
| AI pipeline with fallback | Supervisor + Walkaway |
| TUI/dashboard monitoring | Supervisor (events for display) |

## Worker Health & Timeouts

Workers are killed if they exceed timeout (prevents overnight hangs):

| Worker | Default Timeout |
|--------|----------------|
| Junior (Line Cook) | 15 minutes |
| Senior (Sous Chef) | 30 minutes |
| Executive Chef | 60 minutes |

Crashed workers (vs timed out) trigger immediate escalation. Configure in `brigade.config`:
```bash
TASK_TIMEOUT_JUNIOR=900   # seconds
WORKER_HEALTH_CHECK_INTERVAL=5  # seconds between PID checks
```

## Manual Verification Gate

For UI/TUI work where automated tests can't verify visual behavior:

```json
{
  "id": "US-005",
  "title": "Add settings modal",
  "manualVerification": true,
  "acceptanceCriteria": ["Modal opens on click", "Settings save correctly"]
}
```

Set `MANUAL_VERIFICATION_ENABLED=true` to prompt for human confirmation. In walkaway mode without supervisor, this auto-approves.

## Context Isolation

Each worker starts with **fresh context** - no pollution from previous tasks. This prevents:
- Context window overflow on large PRDs
- Confusion from unrelated prior work
- Hallucinations based on stale information

Knowledge is shared explicitly via the learnings file, not implicitly via conversation history.

## Documentation

- [Getting Started](docs/getting-started.md)
- [How It Works](docs/how-it-works.md)
- [Configuration](docs/configuration.md)
- [Writing PRDs](docs/writing-prds.md)
- [Architecture](docs/architecture.md)
- [Troubleshooting](docs/troubleshooting.md)

## License

MIT
