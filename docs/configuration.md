# Configuration Guide

Brigade is configured via `brigade.config` in your project's brigade directory.

## Configuration File

Create `brigade/brigade.config`:

```bash
# ═══════════════════════════════════════════════════════════════════════════════
# WORKERS
# ═══════════════════════════════════════════════════════════════════════════════

# Executive Chef - directs and reviews (currently used for analysis)
EXECUTIVE_CMD="claude --model opus"

# Sous Chef - handles complex/senior tasks
SOUS_CMD="claude --model sonnet"

# Line Cook - handles routine/junior tasks
LINE_CMD="opencode -p"

# ═══════════════════════════════════════════════════════════════════════════════
# TESTING
# ═══════════════════════════════════════════════════════════════════════════════

# Run after each task to verify completion
# Leave empty to skip testing
TEST_CMD="go test ./..."

# ═══════════════════════════════════════════════════════════════════════════════
# LIMITS
# ═══════════════════════════════════════════════════════════════════════════════

# Max iterations per task before giving up
MAX_ITERATIONS=50
```

## Worker Commands

### Claude CLI

```bash
SOUS_CMD="claude --model sonnet"
EXECUTIVE_CMD="claude --model opus"
```

Available models:
- `opus` - Most capable, best for complex reasoning
- `sonnet` - Balanced capability and speed
- `haiku` - Fastest, good for simple tasks

### OpenCode

```bash
LINE_CMD="opencode -p"
```

OpenCode flags:
- `-p` - Pass prompt directly (required for non-interactive mode)
- `-q` - Quiet mode (hide spinner)
- `-f json` - Output as JSON

### Other AI CLIs

Any CLI that accepts a prompt can work:

```bash
# GPT-4 via CLI
LINE_CMD="gpt4cli --prompt"

# Local Ollama
LINE_CMD="ollama run codellama"

# Custom wrapper script
LINE_CMD="./scripts/my-ai-wrapper.sh"
```

## Test Commands

### Language-Specific Examples

```bash
# Go
TEST_CMD="go test ./..."

# Node.js
TEST_CMD="npm test"

# Python
TEST_CMD="pytest"

# Rust
TEST_CMD="cargo test"

# Ruby
TEST_CMD="bundle exec rspec"

# Multiple commands
TEST_CMD="npm run lint && npm test"
```

### Skipping Tests

Leave empty to skip test verification:

```bash
TEST_CMD=""
```

⚠️ Without tests, Brigade only relies on the AI's `<promise>COMPLETE</promise>` signal.

## Iteration Limits

```bash
MAX_ITERATIONS=50
```

This is the maximum number of times Brigade will re-run a task before giving up. Each iteration:
1. Sends the same prompt to the worker
2. Worker sees updated codebase from previous attempts
3. Worker tries again to complete the task

If you're hitting limits often, your tasks may be too large or ambiguous.

## Environment Variables

You can use environment variables in your config:

```bash
SOUS_CMD="claude --model ${CLAUDE_MODEL:-sonnet}"
TEST_CMD="${PROJECT_TEST_CMD:-npm test}"
```

## Per-Project Configuration

The config file is loaded from `brigade/brigade.config` relative to where you run Brigade. This means each project can have its own configuration.

Typical setup:
```
my-project/
├── brigade/           # Symlink to Brigade repo
│   └── brigade.config # Project-specific config (gitignored in Brigade repo)
├── tasks/
│   └── prd-feature.json
└── src/
```

## Chef Prompts

Customize worker behavior by editing:
- `chef/sous.md` - Senior developer prompt
- `chef/line.md` - Junior developer prompt
- `chef/executive.md` - Director prompt

These are Markdown files that get prepended to task details.
