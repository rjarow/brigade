# Brigade

**Multi-model AI orchestration for coding tasks.**

Brigade routes coding tasks to the right AI based on complexity. Using a kitchen metaphor: an Executive Chef (Opus) plans and reviews, a Sous Chef (Sonnet) handles complex work, and Line Cooks (cheaper models) handle routine tasks.

## Quick Start

Brigade has two implementations with identical CLI - use whichever you prefer:

```bash
# Bash version (works out of the box)
./brigade.sh init
./brigade.sh plan "Add user authentication with JWT"
./brigade.sh service

# Go version (build first, then same commands)
go build -o brigade-go ./cmd/brigade
./brigade-go init
./brigade-go plan "Add user authentication with JWT"
./brigade-go service
```

Both versions share the same config files, PRD format, and state files.

## Key Features

### Walkaway Development

Interview once during planning, then autonomous execution. Workers escalate to each other, not to you. Configure `--walkaway` and let it run overnight.

[Learn more about Walkaway Mode](features/walkaway-mode.md)

### Smart Retries

Brigade learns from failures instead of repeating them. Errors are classified, approaches tracked, and retry prompts enriched with what was already tried.

[Learn more about Smart Retries](features/smart-retries.md)

### Multi-Model Support

Mix and match AI providers. Use Opus for planning, Sonnet for complex work, and cheaper models like GLM for routine tasks.

```bash
# Example mixed configuration
EXECUTIVE_CMD="claude --model opus"
SOUS_CMD="claude --model sonnet"
LINE_CMD="opencode --model zai-coding-plan/glm-4.7"
```

### Supervisor Integration

Build AI supervisors that monitor Brigade with minimal token overhead. File-based integration means no webhooks required.

[Learn more about Supervisor Integration](features/supervisor.md)

## The Kitchen Metaphor

| Role | Model | Responsibility |
|------|-------|----------------|
| **Executive Chef** | Opus | Plans PRDs, reviews work, handles rare escalations |
| **Sous Chef** | Sonnet | Complex tasks, architecture, security |
| **Line Cook** | GLM/cheaper | Routine tasks, tests, boilerplate |

Tasks are routed by complexity:
- `junior` tasks go to Line Cook
- `senior` tasks go to Sous Chef
- `auto` lets Brigade decide

Workers escalate automatically when stuck:

```
Line Cook fails 3x → Sous Chef takes over
Sous Chef fails 5x → Executive Chef steps in
```

## Next Steps

- [Getting Started](getting-started.md) - Install and run your first feature
- [How It Works](how-it-works.md) - Understand the execution flow
- [Writing PRDs](writing-prds.md) - Create effective task plans
- [Configuration](configuration.md) - Customize the kitchen
