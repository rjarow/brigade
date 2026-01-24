# Getting Started

Get your kitchen running in 5 minutes.

## Quick Start (Claude Code)

The easiest way to use Brigade is through Claude Code.

**1. Clone Brigade into your project:**
```bash
cd your-project
git clone https://github.com/rjarow/brigade.git
```

**2. Start Claude Code and use the skill:**
```
You: /brigade plan "Add user authentication with JWT"

Claude: I'll help you plan that feature. A few questions first...
        [Interviews you about scope]
        [Generates PRD with tasks]
        Ready to execute?

You: yes

Claude: [Runs service, reports progress]
        Done! 8/8 tasks complete.
```

### Skill Commands

| Command | What it does |
|---------|--------------|
| `/brigade` | Show options |
| `/brigade plan "X"` | Plan a feature |
| `/brigade run` | Execute PRD |
| `/brigade status` | Check progress |
| `/brigade quick "X"` | One-off task, no PRD |

## CLI Usage

For automation, CI/CD, or terminal use.

### Prerequisites

- **Go 1.21+** - to build Brigade
- **Claude CLI** (`claude`) - required for AI workers

### First Run

```bash
go build -o brigade-go ./cmd/brigade
./brigade-go init    # Setup wizard
./brigade-go demo    # See what it does
```

### Your First Feature

```bash
# 1. Plan
./brigade-go plan "Add user authentication"

# 2. Review
cat brigade/tasks/prd-*.json | jq

# 3. Execute
./brigade-go service

# 4. Monitor
./brigade-go status --watch
```

### Handling Interruptions

Ctrl+C anytime. Resume later:

```bash
./brigade-go resume          # Auto-detect, prompt retry/skip
./brigade-go resume retry    # Retry failed task
./brigade-go resume skip     # Skip and continue
```

