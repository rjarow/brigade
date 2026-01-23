# Getting Started

Get your kitchen running in 5 minutes.

## Quick Start (Claude Code)

The easiest way to use Brigade is through Claude Code.

**1. Clone Brigade into your project:**
```bash
cd your-project
git clone https://github.com/rjarow/brigade.git
```

**2. Install the skill:**
```bash
./brigade.sh install-commands
```

**3. Start cooking:**
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

---

## CLI Usage (Power Users)

For automation, CI/CD, or if you prefer the terminal.

### Prerequisites

- **Claude CLI** (`claude`) - required
- **jq** - for JSON processing
- **bash** 4.0+

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

---

## Configuration

Brigade works with zero config. For common tweaks:

```bash
cp brigade.config.minimal brigade.config
```

Uncomment what you need:
- **Cost savings** - Use OpenCode for routine tasks
- **Testing** - Run tests after each task
- **Quiet mode** - Spinner instead of full output
- **Walkaway** - Autonomous overnight runs

See [Configuration](configuration.md) for all options.

## Next Steps

- [How It Works](how-it-works.md) - Understand the flow
- [Writing PRDs](writing-prds.md) - Manual PRD creation
- [Walkaway Mode](features/walkaway-mode.md) - Autonomous execution
- [CLI Reference](reference/commands.md) - All commands
