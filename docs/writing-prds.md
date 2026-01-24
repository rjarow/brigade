# Writing PRDs

A good PRD is the difference between "fire and forget" and "babysitting the AI all night."

## Structure

```json
{
  "featureName": "Feature Name",
  "branchName": "feature/feature-name",
  "walkaway": false,
  "tasks": [
    {
      "id": "US-001",
      "title": "Short descriptive title",
      "description": "As a user, I want X so that Y",
      "acceptanceCriteria": ["Criterion 1", "Criterion 2"],
      "verification": ["grep -q 'pattern' file.ts"],
      "dependsOn": [],
      "complexity": "junior|senior|auto",
      "passes": false
    }
  ]
}
```

## Fields

| Field | Required | Description |
|-------|----------|-------------|
| `featureName` | Yes | Human-readable feature name |
| `branchName` | Yes | Git branch for the feature |
| `walkaway` | No | Enable autonomous execution |
| `tasks` | Yes | Array of task objects |

### Task Fields

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Unique ID (e.g., `US-001`) |
| `title` | Yes | Short descriptive title |
| `description` | No | User story format |
| `acceptanceCriteria` | Yes | Array of verifiable criteria |
| `verification` | No | Commands to verify completion |
| `dependsOn` | Yes | Array of task IDs this depends on |
| `complexity` | Yes | `junior`, `senior`, or `auto` |
| `passes` | Yes | Set to `false` initially |

## Walkaway Mode

Set `"walkaway": true` when the PRD runs unattended. This tells Brigade to:
- Make autonomous retry/skip decisions
- Require more explicit acceptance criteria
- Enforce stricter verification requirements

## Complexity

| Level | Route To | Best For |
|-------|----------|----------|
| `junior` | Line Cook | Tests, CRUD, boilerplate, following patterns |
| `senior` | Sous Chef | Architecture, security, judgment calls |
| `auto` | Heuristics | Let Brigade decide |

## Dependencies

```json
{"id": "US-001", "dependsOn": []},
{"id": "US-002", "dependsOn": ["US-001"]},
{"id": "US-003", "dependsOn": ["US-001"]},     // Parallel with US-002
{"id": "US-004", "dependsOn": ["US-002", "US-003"]}  // Waits for both
```

Avoid circular dependencies - they cause hangs.

## Verification Commands

Optional safety net after worker signals COMPLETE:

```json
"verification": [
  {"type": "pattern", "cmd": "grep -q 'class User' src/models/user.ts"},
  {"type": "unit", "cmd": "npm test -- --grep 'User model'"},
  {"type": "integration", "cmd": "npm test -- --grep 'auth flow'"},
  {"type": "smoke", "cmd": "./bin/app --help"}
]
```

### Verification Types

| Type | Purpose |
|------|---------|
| `pattern` | File/code existence checks |
| `unit` | Unit tests for isolated logic |
| `integration` | Tests that verify components work together |
| `smoke` | Quick checks that the feature runs |

Guidelines:
- **Fast** - Seconds, not minutes
- **Simple** - grep, file checks, targeted tests
- **Deterministic** - No network or timing dependencies

## Good vs Bad

**Acceptance Criteria:**
```json
// Good - verifiable
["POST /auth/login accepts email and password",
 "Returns 401 on invalid credentials"]

// Bad - vague
["Works correctly", "Handles errors well"]
```

**Task Sizing:**
- 1-5 acceptance criteria
- Touches 1-3 files
- Describable in 2-3 sentences

