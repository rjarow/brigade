# Brigade

**Multi-model AI orchestration for coding tasks.**

Brigade routes coding tasks to the right AI based on complexity. Using a kitchen metaphor: an Executive Chef (Opus) plans and reviews, a Sous Chef (Sonnet) handles complex work, and Line Cooks (cheaper models) handle routine tasks.

## Quick Start

```bash
# Build the Go binary
go build -o brigade-go ./cmd/brigade

# Setup and run
./brigade-go init
./brigade-go plan "Add user authentication with JWT"
./brigade-go service
```

A legacy Bash version (`brigade.sh`) is also available but Go is recommended for better error messages and reliability.

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

