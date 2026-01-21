# Getting Started 🍳

Get your kitchen running in 5 minutes.

## Prerequisites

- **Claude CLI** (`claude`) - required
- **jq** - for JSON processing
- **bash** 4.0+

**Optional:** OpenCode (`opencode`) for cheaper Line Cook tasks.

## Installation

### Option 1: Clone into your project

```bash
cd your-project
git clone https://github.com/yourusername/brigade.git
```

### Option 2: Symlink (for Brigade development)

```bash
git clone https://github.com/yourusername/brigade.git ~/brigade
ln -s ~/brigade ./brigade
```

## First Run

```bash
# Setup wizard - checks tools, creates config
./brigade.sh init

# Or try a demo first
./brigade.sh demo
```

## Your First Feature

### 1. Plan it

```bash
./brigade.sh plan "Add user authentication with JWT"
```

The Executive Chef will:
- Ask clarifying questions about scope
- Analyze your codebase
- Generate a PRD with tasks

### 2. Review it

```bash
cat brigade/tasks/prd-*.json | jq
```

Each task has:
- Clear acceptance criteria
- Complexity assignment (junior/senior)
- Dependencies on other tasks

### 3. Cook it

```bash
./brigade.sh service
```

Watch the kitchen work:
```
🍳 Firing up the kitchen for: User Authentication
📋 Menu: 8 dishes to prepare

🔪 Prepping US-001 - Add user model
🍽️ US-001 plated! (45s)
👨‍🍳 Executive Chef approves!
...
✅ Order up! 8 dishes served, kitchen clean.
```

### 4. Check progress

```bash
./brigade.sh status          # Current state
./brigade.sh status --watch  # Auto-refresh
```

## Using with Claude Code

Chat naturally instead of running commands:

```
You: /brigade plan "Add user auth"
Claude: [Interviews you, generates PRD]
        Ready to cook?

You: yes
Claude: [Runs service, reports progress]
        Done! 8/8 tasks complete.
```

**Install the skill:**
```bash
./brigade.sh install-commands.sh
```

**Key commands:**
| Command | What it does |
|---------|--------------|
| `/brigade` | Show options |
| `/brigade plan "X"` | Plan a feature |
| `/brigade run` | Execute PRD |
| `/brigade status` | Check progress |
| `/brigade quick "X"` | One-off task, no PRD |

## Handling Interruptions

Ctrl+C anytime. Resume later:

```bash
./brigade.sh resume          # Auto-detect, ask retry/skip
./brigade.sh resume retry    # Retry the failed task
./brigade.sh resume skip     # Skip and continue
```

## Cost Savings

Use cheaper models for Line Cook work:

```bash
# In brigade.config
USE_OPENCODE=true
OPENCODE_MODEL="zai-coding-plan/glm-4.7"
```

See available models: `./brigade.sh opencode-models`

## Next Steps

- **[How It Works](how-it-works.md)** - Understand the execution flow
- **[Configuration](configuration.md)** - Tune the kitchen
- **[Writing PRDs](writing-prds.md)** - Manual PRD creation
