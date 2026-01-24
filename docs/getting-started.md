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

### Choose Your Version

| Version | Install | Best For |
|---------|---------|----------|
| **Bash** | Works out of the box | Default, production-tested |
| **Go** | `go build -o brigade-go ./cmd/brigade` | Better errors, type safety |

### Prerequisites

**For Bash version:**
- **Claude CLI** (`claude`) - required
- **jq** - for JSON processing
- **bash** 4.0+

**For Go version:**
- **Go 1.21+** - to build
- **Claude CLI** (`claude`) - required

### First Run

```bash
./brigade.sh init    # Setup wizard
./brigade.sh demo    # See what it does
```

### Your First Feature

```bash
# 1. Plan
./brigade.sh plan "Add user authentication"

# 2. Review
cat brigade/tasks/prd-*.json | jq

# 3. Execute
./brigade.sh service

# 4. Monitor
./brigade.sh status --watch
```

### Handling Interruptions

Ctrl+C anytime. Resume later:

```bash
./brigade.sh resume          # Auto-detect, prompt retry/skip
./brigade.sh resume retry    # Retry failed task
./brigade.sh resume skip     # Skip and continue
```

