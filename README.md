# Brigade

Multi-model AI orchestration framework. Route tasks to the right AI based on complexity.

```
┌─────────────────────────────────────────────────────┐
│  Executive Chef (Opus)                              │
│  Analyzes tasks, delegates, reviews output          │
└──────────────┬────────────────────┬─────────────────┘
               │                    │
       ┌───────▼───────┐    ┌───────▼───────┐
       │  Sous Chef    │    │  Line Cook    │
       │  (Sonnet)     │    │  (GLM/etc)    │
       │               │    │               │
       │  Complex work │    │  Routine work │
       └───────────────┘    └───────────────┘
```

## Why Brigade?

- **Cost optimization**: Use expensive models only when needed
- **Right tool for the job**: Architecture decisions need senior thinking, boilerplate doesn't
- **Quality control**: Executive Chef reviews all work before marking complete
- **Multi-model**: Mix Claude, OpenCode, GPT, local models - whatever works

## Installation

```bash
# Clone into your project
git clone https://github.com/yourusername/brigade.git
cd your-project
ln -s /path/to/brigade ./brigade

# Or copy directly
cp -r /path/to/brigade ./brigade
```

## Configuration

Create `brigade/brigade.config` in your project:

```bash
# Executive Chef (director) - analyzes and routes tasks
EXECUTIVE_CMD="claude --model opus"

# Sous Chef (senior) - complex tasks
SOUS_CMD="claude --model sonnet"

# Line Cook (junior) - routine tasks
LINE_CMD="opencode -p"

# Test command to verify tasks
TEST_CMD="go test ./..."
```

## Usage

```bash
# Run full service (all tasks)
./brigade/brigade.sh service tasks/prd.json

# Run single ticket
./brigade/brigade.sh ticket tasks/prd.json US-001

# Check kitchen status
./brigade/brigade.sh status tasks/prd.json
```

## PRD Format

Same JSON format as Ralph:

```json
{
  "featureName": "My Feature",
  "branchName": "feature/my-feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Add user model",
      "description": "As a developer...",
      "acceptanceCriteria": ["Criterion 1", "Criterion 2"],
      "dependsOn": [],
      "complexity": "junior",
      "passes": false
    }
  ]
}
```

### Complexity Levels

- `junior` - Route to Line Cook (routine, boilerplate, simple tests)
- `senior` - Route to Sous Chef (architecture, complex bugs, integration)
- `auto` - Let Executive Chef decide (default)

## Kitchen Terminology

| Term | Meaning |
|------|---------|
| Service | A full run through all tasks |
| Ticket | Individual task |
| The Pass | Review stage before marking complete |
| 86'd | Task failed/blocked |
| Mise en place | Setup and configuration |
| Fire | Start working on a task |

## How It Works

1. **Executive Chef** reads the PRD and analyzes each task
2. Based on complexity, routes to **Sous Chef** or **Line Cook**
3. Worker completes the task and outputs results
4. **Executive Chef** reviews at **The Pass**
5. If approved, task marked complete; if not, reassigned or escalated
6. Repeat until service complete

## License

MIT
