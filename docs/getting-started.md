# Getting Started with Brigade

This guide will get you up and running with Brigade in 5 minutes.

## Prerequisites

- **Claude CLI** (`claude`) - for Sous Chef and Executive Chef
- **OpenCode** (`opencode`) - for Line Cook (or any other CLI-based AI)
- **jq** - for JSON processing
- **bash** 4.0+

## Installation

### Option 1: Clone into your project

```bash
cd your-project
git clone https://github.com/yourusername/brigade.git
```

### Option 2: Symlink (recommended for development)

```bash
git clone https://github.com/yourusername/brigade.git ~/brigade
cd your-project
ln -s ~/brigade ./brigade
```

### Option 3: Add as git submodule

```bash
cd your-project
git submodule add https://github.com/yourusername/brigade.git brigade
```

## Configuration

Create or edit `brigade/brigade.config`:

```bash
# Workers - customize these for your setup
EXECUTIVE_CMD="claude --model opus"
SOUS_CMD="claude --model sonnet"
LINE_CMD="opencode -p"

# Test command (optional but recommended)
TEST_CMD="npm test"  # or: go test ./..., pytest, cargo test, etc.

# Limits
MAX_ITERATIONS=50
```

## Create Your First PRD

Create `tasks/prd-my-feature.json`:

```json
{
  "featureName": "My Feature",
  "branchName": "feature/my-feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Add basic structure",
      "description": "As a developer, I want the basic file structure",
      "acceptanceCriteria": [
        "Create src/feature.js",
        "Export main function"
      ],
      "dependsOn": [],
      "complexity": "junior",
      "passes": false
    },
    {
      "id": "US-002",
      "title": "Implement core logic",
      "description": "As a user, I want the feature to work",
      "acceptanceCriteria": [
        "Handle edge cases",
        "Return correct results",
        "Add error handling"
      ],
      "dependsOn": ["US-001"],
      "complexity": "senior",
      "passes": false
    }
  ]
}
```

## Run Brigade

```bash
# Check status
./brigade/brigade.sh status tasks/prd-my-feature.json

# Analyze routing
./brigade/brigade.sh analyze tasks/prd-my-feature.json

# Run full service
./brigade/brigade.sh service tasks/prd-my-feature.json

# Run single ticket
./brigade/brigade.sh ticket tasks/prd-my-feature.json US-001
```

## What Happens

1. Brigade reads your PRD
2. For each task (in dependency order):
   - Routes to Line Cook (junior) or Sous Chef (senior) based on complexity
   - Worker receives task + chef prompt + project context
   - Worker implements the task
   - If `TEST_CMD` is set, tests are run
   - On success (`<promise>COMPLETE</promise>`), task is marked done
3. Repeats until all tasks complete

## Next Steps

- Read [How It Works](./how-it-works.md) for deeper understanding
- Read [Configuration Guide](./configuration.md) for all options
- Read [Writing PRDs](./writing-prds.md) for PRD best practices
