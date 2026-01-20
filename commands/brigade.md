# Brigade Skill

You are orchestrating Brigade, a multi-model AI task execution framework. This skill handles the full workflow: planning features, converting PRDs, updating PRDs, executing tasks, monitoring progress, and handling failures.

## Commands

| Command | Action |
|---------|--------|
| `/brigade` | Show options |
| `/brigade plan "feature"` | Generate a PRD via interactive interview |
| `/brigade convert` | Convert markdown/text to PRD JSON |
| `/brigade update` | Modify an existing PRD |
| `/brigade run` | Execute a PRD |
| `/brigade status` | Check progress |
| `/brigade resume` | Resume after failure |

Aliases: `build` = `plan`, `service` = `run`, `execute` = `run`

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
1. **Tech stack**: "What language/framework? (or say 'you decide' and I'll recommend based on the feature)"
2. **Project type**: "CLI, API, web app, library?"
3. **Scope**: "What's the MVP? What's out of scope?"
4. **Requirements**: "Database? Auth? External APIs?"

**If user says "you decide" for tech stack**, recommend based on feature type:
- **CLI tools** → Go (fast, single binary, great stdlib) or Rust (if performance-critical)
- **REST APIs** → Go (simple, performant) or Node/Express (if team knows JS)
- **Web apps** → Node + React/Next.js (ecosystem, hiring)
- **Scripts/automation** → Python (readability, libraries)
- **Libraries** → Match the target ecosystem

Explain your recommendation briefly, then confirm before proceeding.

#### For Existing Projects:
1. **Scope**: "Should I include [related capability]?"
2. **Requirements**: "Security? Performance targets?"
3. **Preferences**: "Patterns to follow/avoid?"

### Phase 3: Codebase Analysis
Explore project structure, patterns, dependencies, test patterns.

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

# Quick Reference

```bash
# Planning
./brigade.sh plan "feature description"

# Execution
./brigade.sh service brigade/tasks/prd-name.json
./brigade.sh --walkaway service prd.json  # Unattended
./brigade.sh --auto-continue service prd-*.json  # Chain PRDs

# Monitoring
./brigade.sh status              # Human-readable
./brigade.sh status --json       # Machine-readable
./brigade.sh status --watch      # Auto-refresh

# Resume
./brigade.sh resume prd.json retry
./brigade.sh resume prd.json skip

# Utilities
./brigade.sh validate prd.json   # Check PRD
./brigade.sh summary prd.json    # Generate report
./brigade.sh map                 # Analyze codebase
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
