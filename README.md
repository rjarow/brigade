# Brigade Kitchen 🍳

**You describe what you want. The chefs cook it up.**

Brigade is an AI kitchen that turns your feature requests into working code. An Executive Chef plans the work, Line Cooks handle the routine stuff, and a Sous Chef tackles the tricky bits. If someone struggles, they call for backup.

```
You: "Add user authentication"
     ↓
🧑‍🍳 Executive Chef plans the menu (8 tasks)
     ↓
🔪 Line Cook preps US-001... done!
🔪 Line Cook preps US-002... stuck → 📢 calls Sous Chef
👨‍🍳 Sous Chef handles US-002... done!
     ↓
✅ Order up! 8 dishes served.
```

## Quick Start

```bash
# Add Brigade to your project
git clone https://github.com/yourusername/brigade.git

# First time? Try the demo
./brigade.sh demo

# Plan a feature
./brigade.sh plan "Add user authentication"

# Cook it
./brigade.sh service
```

**What you'll see:**
```
🍳 Firing up the kitchen for: User Authentication
📋 Menu: 8 dishes to prepare

🔪 Prepping US-001 - Add user model
🍽️ US-001 plated! (32s)
👨‍🍳 Executive Chef approves!

🔪 Prepping US-002 - Add login endpoint
📢 Calling in the Sous Chef for US-002
🍽️ US-002 plated! (2m 15s)

...

✅ Order up! 8 dishes served, kitchen clean.
```

## Using with Claude Code

The easiest way - just chat:

```
You: /brigade plan "Add user auth with JWT"

Claude: I'll help plan this. A few questions...
        [Asks about scope, requirements]

        PRD ready with 8 tasks. Run it?

You: yes

Claude: 🍳 Firing up the kitchen...
        [Reports progress naturally]

        Done! 8/8 complete. Branch ready for review.
```

Install the skill: `./brigade/install-commands.sh`

## The Kitchen

| Chef | Model | Handles |
|------|-------|---------|
| 🧑‍🍳 Executive Chef | Opus | Plans features, reviews work |
| 👨‍🍳 Sous Chef | Sonnet | Complex tasks, architecture |
| 🔪 Line Cook | GLM/Sonnet | Tests, boilerplate, CRUD |

**Automatic escalation:** Line Cook fails 3x → Sous Chef takes over → still stuck → Executive Chef steps in.

## Commands

```bash
./brigade.sh init          # Setup wizard
./brigade.sh demo          # Try it out
./brigade.sh plan "..."    # Plan a feature
./brigade.sh service       # Cook the PRD
./brigade.sh status        # Check progress
./brigade.sh resume        # Continue after interruption
```

## Docs

- **[Getting Started](docs/getting-started.md)** - Full setup guide
- **[How It Works](docs/how-it-works.md)** - The execution flow
- **[Configuration](docs/configuration.md)** - All the knobs
- **[Writing PRDs](docs/writing-prds.md)** - Task breakdown tips
- **[Troubleshooting](docs/troubleshooting.md)** - Common issues

## Philosophy

**Walkaway development:** Interview once, then autonomous execution. You shouldn't need to babysit.

**Fresh context:** Each task starts clean. No context pollution, no token bloat.

**Right chef for the job:** Architecture needs senior thinking. Boilerplate doesn't.

## License

MIT
