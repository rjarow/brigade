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

## Walkaway Mode

Set `"walkaway": true` when the PRD runs unattended. This tells Brigade to:
- Make autonomous retry/skip decisions
- Require more explicit acceptance criteria
- Interview more thoroughly during planning

## Task IDs

Sequential IDs: `US-001`, `US-002`, etc. Used for dependencies, targeting, and tracking.

## Good vs Bad

**Titles:**
- "Add User model with validation"
- "Implement login endpoint"

**Acceptance Criteria:**
```json
// Good - verifiable
["POST /auth/login accepts email and password",
 "Returns 401 on invalid credentials"]

// Bad - vague
["Works correctly", "Handles errors well"]
```

## Complexity

| Level | Route To | Best For |
|-------|----------|----------|
| `junior` | Line Cook | Tests, CRUD, boilerplate, following patterns |
| `senior` | Sous Chef | Architecture, security, judgment calls |
| `auto` | Heuristics | Let Brigade decide |

**Junior indicators:** Clear steps, similar code exists, 3 or fewer criteria.
**Senior indicators:** Multiple approaches, system context needed, 4+ criteria.

## Dependencies

```json
{"id": "US-001", "dependsOn": []},
{"id": "US-002", "dependsOn": ["US-001"]},
{"id": "US-003", "dependsOn": ["US-001"]},     // Parallel with US-002
{"id": "US-004", "dependsOn": ["US-002", "US-003"]}  // Waits for both
```

Avoid circular dependencies - they cause hangs.

## Task Sizing

**Right-sized:**
- 1-5 acceptance criteria
- Touches 1-3 files
- Describable in 2-3 sentences

**Too big:** "Implement entire authentication system" with 10 criteria.
**Too small:** Separate tasks for each struct field.

## Test Requirements

Every PRD needs tests. Two approaches:

**1. Tests in acceptance criteria:**
```json
{
  "title": "Add User model",
  "acceptanceCriteria": [
    "User model has id, email, password_hash fields",
    "Unit tests written for validation logic"
  ]
}
```

**2. Dedicated test tasks:**
```json
{"id": "US-001", "title": "Add User model", "complexity": "senior"},
{"id": "US-002", "title": "Add User model tests", "dependsOn": ["US-001"], "complexity": "junior"}
```

## Verification Commands

Optional safety net after worker signals COMPLETE:

```json
"verification": [
  "grep -q 'class User' src/models/user.ts",
  "npm test -- --grep 'User model' --exit"
]
```

Guidelines:
- **Fast** - Seconds, not minutes
- **Simple** - grep, file checks, targeted tests
- **Deterministic** - No network or timing dependencies
- **Read-only** - Never modify files

Workers see these commands and can self-check before signaling done.

## Example

See `examples/prd-example.json` for a complete working PRD.
