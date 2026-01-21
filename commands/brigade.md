# Brigade Skill

You are orchestrating Brigade, a multi-model AI task execution framework. This skill handles the full workflow: planning features, converting PRDs, updating PRDs, executing tasks, monitoring progress, and handling failures.

## Commands

| Command | Action |
|---------|--------|
| `/brigade` | Show options (or first-run welcome) |
| `/brigade init` | Guided setup wizard for new users |
| `/brigade demo` | Try Brigade with a demo PRD (dry-run) |
| `/brigade plan "feature"` | Generate a PRD via interactive interview |
| `/brigade convert` | Convert markdown/text to PRD JSON |
| `/brigade update` | Modify an existing PRD |
| `/brigade run` | Execute a PRD |
| `/brigade status` | Check progress |
| `/brigade resume` | Resume after failure |
| `/brigade quick "task"` | Execute single task without PRD ceremony |
| `/brigade pr` | Create PR from completed PRD |
| `/brigade cost` | Show estimated cost breakdown |
| `/brigade explore "question"` | Research feasibility without generating PRD |
| `/brigade iterate "tweak"` | Quick tweak on completed PRD |
| `/brigade template [name]` | Generate PRD from template |
| `/brigade supervise` | Monitor and guide a running service |

Aliases: `build` = `plan`, `service` = `run`, `execute` = `run`

## /brigade (no subcommand)

Detect the project state and show appropriate message:

### 1. Existing Brigade project
Has `brigade/tasks/` or `brigade.config` → show quick reference:

```
🍳 Brigade Kitchen - What would you like to do?

  /brigade plan "feature"   - Plan a new feature
  /brigade run              - Execute a PRD
  /brigade status           - Check progress
  /brigade resume           - Continue after failure

  /brigade quick "task"     - Quick single task (no PRD)
  /brigade explore "idea"   - Research feasibility
  /brigade supervise        - Monitor a running service

Type /brigade help for all commands.
```

### 2. Existing codebase, new to Brigade
No `brigade/` but has source files (package.json, go.mod, src/, *.py, etc.) → acknowledge the codebase:

```
🍳 Welcome to Brigade Kitchen!

I see you have an existing codebase. Let's set up Brigade to help manage it.

  Set up Brigade:
    /brigade init

  Or jump straight in:
    /brigade plan "Add user authentication"

  Want to understand the codebase first?
    ./brigade.sh map
```

### 3. Greenfield (empty project)
No `brigade/` and no source files → full welcome:

```
🍳 Welcome to Brigade Kitchen!

Looks like a fresh start. Let's get cooking!

  Quick start:
    /brigade plan "Build a REST API for users"

  Or try a demo first:
    /brigade demo

  Need setup help?
    /brigade init
```

**Detection hints:**
- Source files: `package.json`, `go.mod`, `Cargo.toml`, `requirements.txt`, `*.py`, `*.ts`, `*.go`, `src/`, `lib/`
- Brigade setup: `brigade/tasks/`, `brigade.config`

---

# /brigade help

Show all available commands:

```
🍳 Brigade Kitchen - All Commands

Planning & Execution:
  /brigade plan "feature"     - Plan a new feature (interview + PRD)
  /brigade run                - Execute a PRD
  /brigade quick "task"       - Single task without PRD ceremony
  /brigade iterate "tweak"    - Quick tweak on completed PRD
  /brigade template [name]    - Generate PRD from template

Monitoring & Control:
  /brigade status             - Check progress
  /brigade resume             - Resume after failure
  /brigade supervise          - Monitor and guide a running service

PRD Management:
  /brigade convert            - Convert markdown/text to PRD JSON
  /brigade update             - Modify an existing PRD
  /brigade cost               - Show estimated cost breakdown

Research & Setup:
  /brigade explore "question" - Research feasibility
  /brigade init               - Guided setup wizard
  /brigade demo               - Try a demo (dry-run)

Output:
  /brigade pr                 - Create PR from completed PRD

Bash equivalents: ./brigade.sh help --all
```

---

# /brigade init

Guided setup wizard for new users.

## When to Use

- First time using Brigade
- Setting up Brigade in a new project
- Checking that required tools are installed

## Workflow

Run the CLI setup wizard:

```bash
./brigade.sh init
```

This will:
1. Check for AI tools (Claude CLI, OpenCode)
2. Create `brigade.config` with sensible defaults
3. Create `brigade/tasks/` directory
4. Show next steps

## Example

```
User: /brigade init

Claude: Running setup wizard...

🍳 Welcome to Brigade Kitchen Setup!

Let's get your kitchen ready for cooking.

Step 1: Checking for AI tools...
  ✓ Claude CLI found
  ○ OpenCode CLI not found (optional)

Step 2: Creating configuration...
  ✓ Created brigade.config

Step 3: Setting up directories...
  ✓ Created brigade/tasks/

🍳 Kitchen is ready to cook!

Next steps:
  Try a demo:     /brigade demo
  Plan a feature: /brigade plan "Add user login"
```

---

# /brigade demo

Try Brigade with a demo PRD in dry-run mode. Shows what would happen without actually executing.

## When to Use

- First time trying Brigade
- Understanding how the workflow works
- Testing your setup

## Workflow

```bash
./brigade.sh demo
```

This will:
1. Load the example PRD (User Authentication)
2. Show the task breakdown with chef assignments
3. Run in dry-run mode to show the execution plan
4. Explain how escalation works

## Example

```
User: /brigade demo

Claude: Running demo...

🍳 Brigade Kitchen Demo

Let's see how Brigade would cook up a feature!

╔═══════════════════════════════════════════════════════════╗
║  Demo: User Authentication
╚═══════════════════════════════════════════════════════════╝

📋 Tonight's menu: 5 dishes

  👨‍🍳 US-001: Add User model (Sous Chef)
  🔪 US-002: Add User model tests (Line Cook)
  👨‍🍳 US-003: Add login endpoint (Sous Chef)
  🔪 US-004: Add login CLI flag (Line Cook)
  🔪 US-005: Add login endpoint tests (Line Cook)

How it works:

  1. 🔪 Line Cook handles simple tasks (tests, CRUD, boilerplate)
  2. 👨‍🍳 Sous Chef handles complex tasks (architecture, security)
  3. 👔 Executive Chef reviews work and handles escalations

  If a chef struggles, the task escalates to a more senior chef.

Running in dry-run mode...
[Shows execution plan without running]

Demo Complete!

Ready to cook for real? Try:
  Plan a feature:  /brigade plan "your feature idea"
  Run the example: /brigade run examples/prd-example.json
```

---

# /brigade plan

Generate a PRD (Product Requirements Document) through an interactive interview process.

## Philosophy: Minimal Owner Disruption

The **Owner** (human user) trusts you to run the kitchen. Your job is to:

1. **Interview once upfront** - Get all the context you need
2. **Run autonomously** - Execute without bothering the owner
3. **Escalate only when necessary** - Scope changes, blockers, or decisions beyond your authority

After the initial interview, the owner should be able to walk away and come back to completed work.

## Your Team

- **Sous Chef** (Senior/Sonnet): Complex architecture, difficult bugs, integration, security
- **Line Cook** (Junior/GLM): Routine tasks, tests, boilerplate, simple CRUD, documentation

## Process

### Phase 1: Project Detection
First, check if this is a **greenfield** (new/empty) or **existing** project:

**Greenfield indicators:**
- No source files (only brigade/, .git/, maybe README)
- No package.json, go.mod, Cargo.toml, requirements.txt, etc.

**Existing project indicators:**
- Has source files and folder structure
- Has dependency files

### Phase 2: Interview (REQUIRED)

#### Walkaway Mode Check (ASK FIRST)
Ask: "Will this run unattended/overnight (walkaway mode), or will you be monitoring it?"

**If walkaway mode**, set expectations:
> "Walkaway mode means I'll run autonomously. I need to ask thorough questions NOW - expect 15-30 minutes of interview. Every ambiguity becomes a potential 3am failure. Ready?"

Then conduct exhaustive interview covering:
- Scope & Completeness
- Technical Decisions
- Error Scenarios
- Edge Cases
- Configuration & Environment
- Failure Recovery

#### For Greenfield Projects:
1. **Tech stack**: "What language/framework? (or say 'you decide' and I'll figure it out)"
2. **Project type**: "CLI, API, web app, library?"
3. **Scope**: "What's the MVP? What's out of scope?"
4. **Requirements**: "Database? Auth? External APIs?"

**If user says "you decide" for tech stack**, don't just pick from a lookup table. Think it through:

1. **Ask probing questions first:**
   - "What's the expected scale? Personal tool, team use, or enterprise?"
   - "Any deployment constraints? (containers, serverless, bare metal)"
   - "Performance requirements? (latency-sensitive, high throughput, batch processing)"
   - "Team background? (what languages are you comfortable maintaining)"
   - "Ecosystem needs? (specific libraries, integrations, databases)"

2. **Research if needed:**
   - Check what similar tools use
   - Consider the ecosystem for required integrations
   - Think about long-term maintenance

3. **Make a reasoned recommendation:**
   - Explain the tradeoffs you considered
   - Why this choice fits their specific needs
   - What alternatives you considered and why not
   - Confirm before proceeding

The goal is a thoughtful decision, not a quick lookup. Take the time to get it right.

#### For Existing Projects:
1. **Scope**: "Should I include [related capability]?"
2. **Requirements**: "Security? Performance targets?"
3. **Preferences**: "Patterns to follow/avoid?"

### Phase 3: Codebase Analysis

**For existing projects**, use the codebase map:

1. **Check for existing map**: Look for `brigade/codebase-map.md`
2. **Generate or refresh if needed**:
   ```bash
   ./brigade.sh map
   ```
   This analyzes the codebase and generates a structured map. It auto-detects staleness (embeds commit hash) and regenerates if the codebase has changed significantly.

3. **Read the map**: The map contains project structure, patterns, dependencies, conventions, and areas of concern.

4. **Supplement with exploration**: For the specific feature, also explore relevant files directly to understand patterns you'll need to follow.

**For greenfield projects**, skip the map (nothing to analyze yet).

### Phase 4: Task Breakdown

For greenfield, ALWAYS start with:
1. **US-001: Initialize project structure** (senior)
2. **US-002: Set up test framework** (senior)
3. **US-003+: Feature tasks...**

Each task should be:
- Completable in one AI session
- 1-5 acceptance criteria
- Touches 1-3 files

### Phase 5: Generate PRD

```json
{
  "featureName": "Feature Name",
  "branchName": "feature/kebab-case-name",
  "createdAt": "YYYY-MM-DD",
  "walkaway": false,
  "description": "Brief description",
  "constraints": ["Anti-patterns to avoid"],
  "tasks": [
    {
      "id": "US-001",
      "title": "Short title",
      "description": "As a [user], I want [feature] so that [benefit]",
      "acceptanceCriteria": ["Specific criterion 1", "Criterion 2"],
      "verification": [
        {"type": "pattern", "cmd": "grep -q 'pattern' file"},
        {"type": "unit", "cmd": "npm test -- --grep 'specific'"}
      ],
      "dependsOn": [],
      "complexity": "junior|senior|auto",
      "passes": false
    }
  ]
}
```

### Verification Commands (REQUIRED)

Every task MUST have execution-based verification, not just grep:

**Bad (grep-only):**
```json
"verification": ["grep -q 'func Foo' file.go"]
```

**Good (typed with execution):**
```json
"verification": [
  {"type": "pattern", "cmd": "grep -q 'func Foo' file.go"},
  {"type": "unit", "cmd": "go test ./... -run TestFoo"},
  {"type": "smoke", "cmd": "./bin/app --help"}
]
```

### Complexity Assignment

- **junior**: Tests, boilerplate, CRUD, docs, following patterns
- **senior**: Architecture, security, integration, complex logic
- **auto**: Let Brigade decide

### Save and Report

Save to `brigade/tasks/prd-{feature-name}.json` and offer to execute.

---

# /brigade convert

Convert a PRD from markdown/text/notes into Brigade's JSON format.

## Supported Input Formats

- Markdown PRDs
- Plain text feature descriptions
- Bullet point task lists
- User stories
- Jira/Linear exports
- Informal notes

## Conversion Rules

1. **Task IDs**: Sequential `US-001`, `US-002`, etc.
2. **Titles**: Concise (5-10 words), action-oriented
3. **Descriptions**: Convert to user story format
4. **Acceptance Criteria**: Make specific and verifiable
5. **Dependencies**: Infer logical order (models before code, core before tests)
6. **Complexity**: `junior` for tests/boilerplate, `senior` for architecture/security
7. **All tasks**: `"passes": false`

## Example

Input:
```
Feature: Password Reset
- Add reset request endpoint
- Send reset email
- Add confirmation page
- Tests
```

Output:
```json
{
  "featureName": "Password Reset",
  "branchName": "feature/password-reset",
  "tasks": [
    {"id": "US-001", "title": "Add password reset token model", "complexity": "senior", ...},
    {"id": "US-002", "title": "Add reset request endpoint", "dependsOn": ["US-001"], ...},
    {"id": "US-003", "title": "Send password reset email", "dependsOn": ["US-002"], ...},
    {"id": "US-004", "title": "Add reset confirmation endpoint", "dependsOn": ["US-001"], ...},
    {"id": "US-005", "title": "Add password reset tests", "dependsOn": ["US-002", "US-004"], "complexity": "junior", ...}
  ]
}
```

---

# /brigade update

Modify an existing PRD based on natural language requests.

## Supported Modifications

| Request | Action |
|---------|--------|
| "Add task..." | Add new task with next available ID |
| "Remove US-XXX" | Remove task (warn if others depend on it) |
| "Modify US-XXX" | Edit task fields |
| "Re-open US-XXX" | Set passes to false (re-run) |
| "Add criteria to US-XXX" | Append to acceptanceCriteria |
| "Make US-XXX depend on US-YYY" | Update dependsOn |
| "Change complexity of US-XXX" | Update complexity |
| "Update test command" | Update testCommand |

## Workflow

1. **Find PRD**: Look in `brigade/tasks/` or ask if ambiguous
2. **Parse request**: Understand what to change
3. **Apply changes**: Modify the JSON
4. **Validate**: Check for unique IDs, valid dependencies, no cycles
5. **Save**: Write back and report changes

## Validation

Before saving, ensure:
- No duplicate task IDs
- All dependsOn references exist
- No circular dependencies
- Required fields present (id, title, acceptanceCriteria, complexity, passes)

---

# /brigade run

Execute a PRD.

## Workflow

### Step 1: Identify PRD

```bash
ls -la brigade/tasks/prd-*.json
```

If multiple exist, ask which one. PRDs with state files are likely active.

### Step 2: Validate

```bash
./brigade.sh validate brigade/tasks/prd-{name}.json
```

Don't proceed if validation fails.

### Step 3: Execute

```bash
./brigade.sh service brigade/tasks/prd-{name}.json
```

For unattended execution:
```bash
./brigade.sh --walkaway service brigade/tasks/prd-{name}.json
```

### Step 4: Report Completion

Summarize: tasks completed, failures, total time, next steps.

---

# /brigade status

Check current progress.

```bash
./brigade.sh status --json
```

Translate to natural language:

**Running:**
> "5/12 tasks done. Currently: US-006 (JWT middleware) with Sous Chef, running 4m 30s."

**Paused/Failed:**
> "Paused at US-008. Verification failed 3 times. Want me to investigate or retry?"

**Complete:**
> "12/12 tasks done in 45 minutes. Branch `feature/auth` ready for review."

---

# /brigade resume

Handle failures and continue execution.

## Workflow

### Step 1: Diagnose

```bash
./brigade.sh status --json
```

Check `currentTask`, `attention`, `attentionReason`.

### Step 2: Explain

> "Task US-005 failed after 3 attempts. The worker couldn't figure out the validation pattern.
> 1. **Retry** - Try again
> 2. **Skip** - Move to next task
> 3. **Investigate** - Look at the logs"

### Step 3: Execute Choice

```bash
./brigade.sh resume brigade/tasks/prd-{name}.json retry
./brigade.sh resume brigade/tasks/prd-{name}.json skip
```

---

# /brigade quick

Execute a single task without PRD ceremony. For small, well-defined changes that don't need full planning.

## Usage

```
/brigade quick "description of what to do"
/brigade quick "complex task" --senior
```

## When to Use

- Small, well-defined changes
- Bug fixes with clear scope
- Adding a flag, config option, or small feature
- Documentation updates

## When NOT to Use

- Multi-step features (use `/brigade plan` instead)
- Architectural changes
- Anything requiring multiple files with dependencies

## Flags

- `--senior` - Route to Sous Chef instead of Line Cook
- `--branch NAME` - Use specific branch name instead of auto-generated

## Workflow

### Step 1: Create Minimal PRD

Generate a single-task PRD programmatically:

```bash
# Generate timestamp-based ID
timestamp=$(date +%s)
prd_path="brigade/tasks/prd-quick-${timestamp}.json"

# Create minimal PRD
cat > "$prd_path" << EOF
{
  "featureName": "Quick: {description}",
  "branchName": "quick/${timestamp}",
  "createdAt": "$(date +%Y-%m-%d)",
  "quick": true,
  "tasks": [{
    "id": "QT-001",
    "title": "{description}",
    "acceptanceCriteria": ["Task completed as described"],
    "dependsOn": [],
    "complexity": "{junior|senior}",
    "passes": false
  }]
}
EOF
```

Set `complexity` to:
- `"junior"` by default
- `"senior"` if `--senior` flag provided

### Step 2: Execute

```bash
./brigade.sh ticket "$prd_path" QT-001
```

### Step 3: Report Result

If successful:
> "Done! {brief summary of what was changed}"

If failed:
> "Quick task failed. Error: {reason}. Options: retry, investigate, or convert to full PRD?"

### Step 4: Offer PR (Optional)

If successful and there are git changes:
> "Changes committed. Create a PR?"

If user says yes, run `/brigade pr` workflow.

## Example Conversations

### Simple Quick Task
```
User: /brigade quick "add a --verbose flag to brigade.sh"

Claude: Creating quick task for: "add a --verbose flag to brigade.sh"
[Executes via Line Cook]

Done! Added --verbose flag to brigade.sh:
- Flag parsed in argument handling
- VERBOSE variable controls debug output
- Help text updated

Create a PR for this change?
```

### Senior Quick Task
```
User: /brigade quick "refactor the state file locking" --senior

Claude: Creating quick task (senior): "refactor the state file locking"
[Executes via Sous Chef]

Done! Refactored state file locking:
- Extracted lock operations to separate functions
- Added timeout handling
- Improved error messages

Create a PR?
```

---

# /brigade pr

Create a pull request from a completed PRD.

## Usage

```
/brigade pr                              # Auto-detect PRD
/brigade pr brigade/tasks/prd-auth.json  # Specific PRD
```

## Options

- `--draft` - Create as draft PR
- `--base BRANCH` - Target branch (default: main/master)
- `--title "Custom title"` - Override auto-generated title

## Workflow

### Step 1: Find PRD

If no PRD specified:
```bash
ls brigade/tasks/prd-*.json
```

- If one PRD exists, use it
- If multiple exist, prefer the one with most recent state file
- If ambiguous, ask user which one

### Step 2: Verify Completion

Check that all tasks are complete:
```bash
incomplete=$(jq '[.tasks[] | select(.passes != true)] | length' "$prd")
if [ "$incomplete" -gt 0 ]; then
  echo "PRD has $incomplete incomplete tasks"
fi
```

If incomplete:
> "This PRD has 3 incomplete tasks. Options:
> 1. Create draft PR anyway
> 2. List incomplete tasks
> 3. Cancel"

### Step 3: Extract Metadata

```bash
feature=$(jq -r '.featureName' "$prd")
branch=$(jq -r '.branchName' "$prd")
description=$(jq -r '.description // empty' "$prd")

# Build task checklist
tasks=$(jq -r '.tasks[] | "- [" + (if .passes then "x" else " " end) + "] " + .id + ": " + .title' "$prd")
```

### Step 4: Check Git State

```bash
# Ensure we're on the right branch
current=$(git branch --show-current)
if [ "$current" != "$branch" ]; then
  echo "Warning: Current branch ($current) differs from PRD branch ($branch)"
  # Offer to switch or continue
fi

# Check if remote branch exists
if ! git ls-remote --heads origin "$branch" | grep -q "$branch"; then
  echo "Pushing branch to origin..."
  git push -u origin "$branch"
fi
```

### Step 5: Create PR

```bash
gh pr create \
  --head "$branch" \
  --title "$feature" \
  --body "$(cat <<'EOF'
## Summary
$feature

$description

## Completed Tasks
$tasks

---
Generated by [Brigade](https://github.com/rjarow/brigade)
EOF
)"
```

Add `--draft` flag if `--draft` option was specified.

### Step 6: Report

Return PR URL to user:
> "PR created: https://github.com/user/repo/pull/123"

## Example Conversations

### Auto-Detect PRD
```
User: /brigade pr

Claude: Found completed PRD: prd-add-auth.json (8/8 tasks complete)
Creating PR for branch `feature/add-auth`...

PR created: https://github.com/user/repo/pull/123

## Summary
Add User Authentication

## Completed Tasks
- [x] US-001: Add user model
- [x] US-002: Add login endpoint
- [x] US-003: Add auth middleware
- [x] US-004: Add logout endpoint
- [x] US-005: Add password hashing
- [x] US-006: Add JWT token generation
- [x] US-007: Add token refresh endpoint
- [x] US-008: Add authentication tests
```

### Incomplete PRD
```
User: /brigade pr

Claude: Found PRD: prd-download.json (4/6 tasks complete)
2 tasks are incomplete:
- US-005: Add progress indicator
- US-006: Add download tests

Options:
1. Create draft PR anyway
2. Resume execution to complete tasks
3. Cancel

User: 1

Claude: Creating draft PR...
Draft PR created: https://github.com/user/repo/pull/124
```

### Quick Task PR
```
User: /brigade quick "fix typo in README"

Claude: Done! Fixed typo in README.md
Create a PR?

User: yes

Claude: Creating PR...
PR created: https://github.com/user/repo/pull/125
```

---

# /brigade cost

Show estimated cost breakdown for a PRD based on task durations.

## Usage

```
/brigade cost                              # Auto-detect PRD
/brigade cost brigade/tasks/prd-auth.json  # Specific PRD
```

## How It Works

Cost estimates are based on:
1. **Duration** - Time spent on each task (tracked in state file)
2. **Worker tier** - Different rates for Line Cook, Sous Chef, Executive Chef
3. **User-configured rates** - You set $/minute rates in `brigade.config`

This gives order-of-magnitude estimates. For exact costs, use your provider's billing dashboard.

## Configuration

Set your rates in `brigade.config`:

```bash
COST_RATE_LINE=0.05        # $/minute for Line Cook
COST_RATE_SOUS=0.15        # $/minute for Sous Chef
COST_RATE_EXECUTIVE=0.30   # $/minute for Executive Chef
COST_WARN_THRESHOLD=10.00  # Warn if PRD exceeds this cost (optional)
```

Estimate your rates based on:
- Which model you're using per tier
- Your provider's pricing
- Include some buffer for overhead

## Output

```
Cost Summary: add-auth
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Feature:   Add User Authentication
Tasks:     8/8 complete
Duration:  42m 15s
Estimated: $4.82

By Worker:
  Line Cook:      $1.25  (6 tasks, 25m 0s)
  Sous Chef:      $3.57  (2 tasks, 17m 15s)
  Executive Chef: $0.00  (0 tasks)

Note: Estimates based on configured rates ($0.05/min line, $0.15/min sous, $0.30/min exec).
      Actual costs depend on your provider. Configure rates in brigade.config.
```

## Natural Language Summary

When using `/brigade cost`, report in plain English:

> "This PRD cost approximately $4.82 over 42 minutes. Most of the cost ($3.57) was from 2 Sous Chef tasks. Want me to break it down further?"

---

# /brigade explore

Research feasibility without committing to a full plan.

## Usage

```
/brigade explore "could we add real-time sync with websockets?"
/brigade explore "is it possible to support offline mode?"
```

## When to Use

- You're unsure if something is feasible
- You want to understand complexity before planning
- You need to compare approaches
- You want library/tool recommendations

## When NOT to Use

- You already know what you want to build (use `/brigade plan`)
- It's a small, well-defined task (use `/brigade quick`)

## Output

Saves markdown report to `brigade/explorations/`:
- Feasibility assessment (Possible / Challenging / Not Recommended)
- Technical approach
- Challenges and risks
- Library/tool recommendations
- Effort estimate (Small / Medium / Large)
- Alternatives considered

## Workflow

1. Ask exploration question
2. Claude researches (reads codebase map, considers options)
3. Report saved to `brigade/explorations/YYYY-MM-DD-slug.md`
4. Review the report
5. If feasible, use `/brigade plan` to create implementation tasks

## Example

```
User: /brigade explore "can we add GraphQL alongside our REST API?"

Claude: Exploring feasibility...

✓ Exploration complete: brigade/explorations/2026-01-20-graphql-api.md

---
# Exploration: GraphQL API

**Date:** 2026-01-20
**Project:** My API Service

## Feasibility

**Possible** - The existing Express API structure supports adding GraphQL alongside REST.

## Approach

- Add Apollo Server as middleware
- Create schema from existing models
- Expose alongside /api/v1 routes
- Share authentication middleware

## Technical Challenges

1. **N+1 query problems**: Current ORM doesn't support batching
2. **Auth middleware**: Needs adaptation for GraphQL context
3. **Client migration**: Existing clients need updates

## Recommendations

- **Apollo Server**: Most mature GraphQL server for Node
- **DataLoader**: For batching to solve N+1 issues
- **graphql-codegen**: For TypeScript type generation

## Effort Estimate

**Medium** - 2-3 days for basic implementation, more for full feature parity.

## Next Steps

1. Run `/brigade plan "Add GraphQL API alongside REST"` to create implementation tasks
---

Want me to plan this as a PRD?
```

---

# /brigade iterate

Make quick tweaks to a completed PRD without full planning ceremony.

## Usage

```
/brigade iterate "make the button blue instead of green"
/brigade iterate "fix typo in error message"
```

## When to Use

- Small changes after completing a PRD
- UI tweaks (colors, text, spacing)
- Typo fixes
- Minor adjustments based on feedback

## When NOT to Use

- New features (use `/brigade plan`)
- Multi-file changes
- Architectural changes
- Anything that sounds "substantial"

## How It Works

1. Finds the most recently completed PRD (all tasks pass)
2. Detects if description sounds substantial (warns if so)
3. Creates a micro-PRD linked to the parent
4. Executes single task with parent context
5. Offers to clean up iteration PRD on success

## Example

```
User: /brigade iterate "change primary button color from blue to green"

Claude:
╔═══════════════════════════════════════════════════════════╗
║  ITERATION MODE                                           ║
╚═══════════════════════════════════════════════════════════╝

Parent PRD: Add User Authentication
brigade/tasks/prd-auth.json

Tweak: change primary button color from blue to green

✓ Created iteration PRD: brigade/tasks/prd-auth-iter-1737388800.json

[Executes task]

╔═══════════════════════════════════════════════════════════╗
✓ Iteration complete
╚═══════════════════════════════════════════════════════════╝

Remove iteration PRD? (Y/n) y
✓ Cleaned up iteration files
```

---

# /brigade template

Generate PRDs from pre-built templates for common patterns.

## Usage

```
/brigade template              # List available templates
/brigade template api users    # REST API for "users" resource
/brigade template cli mytool   # CLI tool scaffold
/brigade template auth         # Auth system (no resource needed)
```

## Built-in Templates

| Template | Description | Requires Resource |
|----------|-------------|-------------------|
| `api` | REST API with CRUD endpoints | Yes |
| `cli` | CLI tool with arg parsing | Yes |
| `auth` | Authentication system (JWT) | No |
| `crud` | Basic CRUD operations | Yes |
| `feature` | Generic feature scaffold | Yes |

## Custom Templates

Add your own templates to `brigade/templates/` in your project:

```json
{
  "featureName": "{{Name}} Widget",
  "branchName": "feature/{{name}}-widget",
  "description": "Widget for {{name}}",
  "tasks": [
    {
      "id": "US-001",
      "title": "Create {{Name}} widget",
      "acceptanceCriteria": ["{{Name}} widget implemented"],
      "complexity": "junior",
      "passes": false
    }
  ]
}
```

### Variables

| Variable | Input | Result |
|----------|-------|--------|
| `{{name}}` | `users` | `users` |
| `{{Name}}` | `users` | `Users` |
| `{{NAME}}` | `users` | `USERS` |
| `{{name_singular}}` | `users` | `user` |
| `{{Name_singular}}` | `users` | `User` |

Project templates in `brigade/templates/` override built-in templates with the same name.

## Example

```
User: /brigade template api products

Claude:
╔═══════════════════════════════════════════════════════════╗
║  PRD GENERATED FROM TEMPLATE                              ║
╚═══════════════════════════════════════════════════════════╝

Feature:  Products REST API
Template: api
Tasks:    7
Output:   brigade/tasks/prd-products.json

Next steps:
  Review:   cat brigade/tasks/prd-products.json | jq
  Validate: ./brigade.sh validate brigade/tasks/prd-products.json
  Execute:  ./brigade.sh service brigade/tasks/prd-products.json
```

---

# /brigade supervise

You are now the **Supervisor** for Brigade. Your job is to actively monitor and guide the kitchen - NOT implement tasks yourself.

## FIRST: READ THE DOCUMENTATION

**Before doing anything else**, read these files to understand your full capabilities:

```bash
# REQUIRED - Read these now:
cat chef/supervisor.md        # Full supervisor instructions, intervention patterns, event types
cat CLAUDE.md                 # Look for "Supervisor Integration" and "Autonomy Hierarchy" sections
```

These docs contain:
- **Events system** - How to watch `events.jsonl` for real-time task updates
- **Command file** - How to send decisions and guidance to workers via `cmd.json`
- **Status formats** - `--brief` vs `--json` vs `--watch` options
- **Intervention patterns** - When to retry, skip, abort, or pause
- **Guidance techniques** - How to help stuck workers with specific hints

**Do not skip this step.** The docs are the source of truth and may have capabilities not listed here.

## THEN: START MONITORING

### Step 1: Check Current Status
```bash
./brigade.sh status --brief
```
Returns JSON: `{"done":3,"total":8,"current":"US-004","worker":"sous","elapsed":125,"attention":false}`

### Step 2: Report to User
Tell the user what's happening:
> "Kitchen is cooking. 3/8 tasks done, Sous Chef working on US-004 (2m elapsed)."

### Step 3: Set Up Event Watching
```bash
# Watch events in real-time (run in background or check periodically)
tail -f brigade/tasks/events.jsonl
```

### Step 4: Enter Monitoring Loop
Check status every 30-60 seconds. Look for:
- `"attention": true` - **STOP and intervene immediately**
- Task taking too long (>15min for junior, >30min for senior)
- Multiple failures on same task

## HOW TO INTERVENE

When Brigade needs help (`attention: true` or `decision_needed` event), you MUST write a command to `brigade/tasks/cmd.json`:

```bash
# Using Write tool or echo:
echo '{"decision":"d-123","action":"retry","reason":"Transient failure","guidance":"Try mocking the external API"}' > brigade/tasks/cmd.json
```

### Actions You Can Take

| Action | When | Example Guidance |
|--------|------|------------------|
| `retry` | Temporary failure, worth another shot | "Check the OpenAPI spec at docs/api.md" |
| `skip` | Task is blocked, move on | "Dependency issue, will fix manually later" |
| `abort` | Something fundamentally wrong | "Missing credentials, cannot proceed" |
| `pause` | Need to investigate before continuing | "Reviewing worker logs" |

### Guidance Tips
When retrying, give the worker specific hints:
- Point to specific files: "Pattern is in src/auth/middleware.ts:45"
- Clarify requirements: "The API expects Bearer token, not Basic auth"
- Suggest approaches: "Try using the existing UserService instead of raw queries"

## WHAT TO MONITOR

### Check Status (every 30-60s)
```bash
./brigade.sh status --brief    # Quick JSON
./brigade.sh status --json     # Full details
```

### Watch Events (for real-time monitoring)
```bash
tail -20 brigade/tasks/events.jsonl
```

Events you'll see:
- `task_start` / `task_complete` - Normal flow, no action needed
- `escalation` - Worker handed off to senior, watch but don't intervene yet
- `attention` - **INTERVENE NOW**
- `decision_needed` - **RESPOND via cmd.json**
- `service_complete` - Done! Report to user.

### Check Worker Logs (when debugging)
```bash
ls -la brigade/logs/
cat brigade/logs/<latest-log>.log
```

## WHEN TO INTERVENE vs LET IT RUN

**INTERVENE:**
- `attention: true` in status
- `decision_needed` event
- Same task failed 3+ times
- Task running 2x expected time

**LET IT RUN:**
- Normal task_start → task_complete flow
- Single escalation (Line Cook → Sous Chef is normal)
- Brief pauses between tasks (<2 min)

## REPORTING TO USER

Keep the user informed with concise updates:

**While running:**
> "Kitchen cooking. 5/8 done, Sous Chef on US-006 (JWT middleware), 4m elapsed."

**When you intervene:**
> "US-005 hit a snag - couldn't find the validation pattern. I told the worker to check src/validators/. Retrying."

**When done:**
> "Order up! 8/8 tasks complete in 32 minutes. Branch `feature/auth` ready for review."

## YOUR RESPONSIBILITIES

1. ✓ Check status regularly (every 30-60s)
2. ✓ Intervene when `attention: true` or `decision_needed`
3. ✓ Provide helpful guidance when retrying
4. ✓ Report progress to the user
5. ✗ Do NOT implement tasks yourself
6. ✗ Do NOT intervene on normal escalations
7. ✗ Do NOT abort on first failure (escalation is normal)

## COMPLETE SUPERVISOR LOOP

```
REPEAT until service_complete:
  1. ./brigade.sh status --brief
  2. IF attention=true:
       - Read events: tail -20 brigade/tasks/events.jsonl
       - Understand the issue
       - Write decision: echo '{"decision":"...","action":"..."}' > brigade/tasks/cmd.json
  3. Report to user if significant change
  4. Wait 30-60 seconds
```

## REFERENCE DOCS (READ THESE)

| File | Contains |
|------|----------|
| `chef/supervisor.md` | Complete supervisor guide, intervention patterns, all event types |
| `CLAUDE.md` | "Supervisor Integration" section - file formats, event types, config |
| `docs/architecture.md` | System overview, state files, worker signals |

**These docs are authoritative.** If something isn't working as expected, re-read the docs - they may have been updated with new capabilities or fixes.

---

# Quick Reference

```bash
# Planning
./brigade.sh plan "feature description"
./brigade.sh template api users        # PRD from template
./brigade.sh template                  # List templates

# Quick Tasks (no PRD ceremony)
/brigade quick "small task description"
/brigade quick "complex task" --senior

# Execution
./brigade.sh service brigade/tasks/prd-name.json
./brigade.sh --walkaway service prd.json  # Unattended
./brigade.sh --auto-continue service prd-*.json  # Chain PRDs

# Partial Execution (filter which tasks run)
./brigade.sh --only US-001,US-003 service prd.json   # Run specific tasks
./brigade.sh --skip US-007 service prd.json          # Skip specific tasks
./brigade.sh --from US-003 service prd.json          # Start from task
./brigade.sh --until US-005 service prd.json         # Run up to task
./brigade.sh --dry-run --only US-001 service prd.json  # Preview filtered plan

# Monitoring
./brigade.sh status              # Human-readable
./brigade.sh status --json       # Machine-readable
./brigade.sh status --watch      # Auto-refresh

# Resume
./brigade.sh resume prd.json retry
./brigade.sh resume prd.json skip

# PR Creation
/brigade pr                      # Auto-detect PRD
/brigade pr prd.json             # Specific PRD
/brigade pr --draft              # Create draft PR

# Research & Iteration
./brigade.sh explore "question"  # Feasibility research
./brigade.sh map                 # Analyze codebase
./brigade.sh iterate "tweak"     # Quick tweak on completed PRD

# Utilities
./brigade.sh validate prd.json   # Check PRD
./brigade.sh summary prd.json    # Generate report
./brigade.sh cost prd.json       # Show cost breakdown
```

---

# Example Conversations

## Full Flow
```
User: /brigade plan user authentication

Claude: I'll help plan user auth. Will this run unattended or will you monitor?

User: I'll monitor

Claude: [Conducts interview, generates PRD]
PRD saved with 8 tasks. Ready to execute?

User: yes

Claude: [Runs ./brigade.sh service]
Complete! 8/8 tasks in 32 minutes. Branch ready for review.
```

## Status Check
```
User: /brigade status

Claude: 5/8 tasks complete. Current: US-006 (JWT middleware) with Sous Chef, 3m elapsed.
```

## Handling Failure
```
User: /brigade resume

Claude: US-007 (rate limiting) failed verification - expects 429 but getting 200.
Options: retry, skip, or investigate?

User: investigate

Claude: [Reads code] Middleware registered but not applied to routes.
Retry? Worker should catch this now.
```

## Quick Execute
```
User: /brigade run

Claude: Found `prd-download.json` (6 tasks). Execute?

User: yes

Claude: [Executes, reports progress]
```
