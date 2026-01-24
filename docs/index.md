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

## The Kitchen

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

