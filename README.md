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
- **Cost optimization**: Use expensive models only when needed
- **Right tool for the job**: Architecture decisions need senior thinking, boilerplate doesn't
- **Automatic escalation**: Junior failures auto-escalate to senior
- **Quality control**: Executive Chef reviews work before marking complete
- **Multi-model**: Mix Claude, OpenCode, GPT, local models - whatever works

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
./brigade/brigade.sh service tasks/prd-*.json
```

No config file needed. Brigade uses Claude for all workers by default.

**Want cost savings?** Two options:

```bash
# Option 1: Flag (one-off)
./brigade/brigade.sh --opencode plan "Build X"

# Option 2: Config (permanent)
echo "USE_OPENCODE=true" > brigade/brigade.config
./brigade/brigade.sh plan "Build X"
```

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
cat tasks/prd-add-user-authentication-with-jwt.json | jq

# Execute with your multi-model team
./brigade/brigade.sh service tasks/prd-add-user-authentication-with-jwt.json
```

### Using Claude Code Skills

Brigade includes Claude Code skills for interactive PRD generation.

**Install skills** (from your project root):
```bash
mkdir -p .claude/skills
ln -s "$(pwd)/brigade/.claude/skills/brigade-generate-prd.md" .claude/skills/
ln -s "$(pwd)/brigade/.claude/skills/brigade-convert-prd-to-json.md" .claude/skills/
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
4. Save it to `tasks/` for execution

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
./brigade.sh service tasks/prd.json

# Run single ticket
./brigade.sh ticket tasks/prd.json US-001

# Check kitchen status
./brigade.sh status tasks/prd.json

# Analyze routing
./brigade.sh analyze tasks/prd.json

# Use OpenCode for junior tasks (cost savings)
./brigade.sh --opencode plan "Build X"
./brigade.sh --opencode service tasks/prd.json
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

1. **Route** based on complexity → Line Cook or Sous Chef
2. **Execute** task with worker prompt
3. **Escalate** if Line Cook fails 3x → Sous Chef
4. **Test** if TEST_CMD configured
5. **Review** Executive Chef checks quality (optional)
6. **Complete** or iterate

### 3. Quality Gates

- **Completion signals**: Workers output `<promise>COMPLETE</promise>`
- **Test verification**: Actual tests run, not just AI confidence
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

**Note**: Tests are mandatory. Every PRD must include test requirements in acceptance criteria AND dedicated test tasks.

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

Brigade maintains state in `brigade-state.json`:

```bash
./brigade.sh status tasks/prd.json
```

Shows:
- Task completion status
- Escalation history
- Review results
- Session stats

## Documentation

- [Getting Started](docs/getting-started.md)
- [How It Works](docs/how-it-works.md)
- [Configuration](docs/configuration.md)
- [Writing PRDs](docs/writing-prds.md)

## License

MIT
