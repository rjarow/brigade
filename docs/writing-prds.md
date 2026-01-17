# Writing PRDs for Brigade

A well-structured PRD is the key to successful Brigade runs. This guide covers best practices for writing PRDs that work well with AI agents.

## PRD Structure

```json
{
  "featureName": "Feature Name",
  "branchName": "feature/feature-name",
  "createdAt": "2025-01-17",
  "description": "Brief description of the feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Short descriptive title",
      "description": "As a [user], I want [feature] so that [benefit]",
      "acceptanceCriteria": [
        "Criterion 1",
        "Criterion 2"
      ],
      "dependsOn": [],
      "complexity": "junior|senior|auto",
      "passes": false
    }
  ]
}
```

## Task IDs

Use consistent, sequential IDs:
- `US-001`, `US-002`, `US-003` (recommended)
- `TASK-001`, `TASK-002`
- `1`, `2`, `3`

These are used for:
- Dependency references
- Command line targeting (`brigade.sh ticket prd.json US-001`)
- Progress tracking

## Writing Good Titles

**Good titles:**
- "Add User model with validation"
- "Implement login endpoint"
- "Write unit tests for auth service"

**Bad titles:**
- "Do the thing"
- "Fix it"
- "Part 1"

The title should make sense in a list view and in git commits.

## Writing Descriptions

Use the user story format for context:

```
As a [type of user],
I want [some goal],
So that [some reason]
```

Example:
```json
"description": "As a user, I want to reset my password via email so that I can regain access to my account"
```

## Writing Acceptance Criteria

Each criterion should be:
1. **Verifiable** - Can be checked programmatically or manually
2. **Specific** - Not vague or subjective
3. **Independent** - Doesn't depend on other criteria

**Good criteria:**
```json
"acceptanceCriteria": [
  "POST /auth/login accepts email and password",
  "Returns JWT token on successful login",
  "Returns 401 status on invalid credentials",
  "Token expires after 24 hours"
]
```

**Bad criteria:**
```json
"acceptanceCriteria": [
  "Works correctly",
  "Is fast",
  "Handles errors well"
]
```

## Setting Complexity

### Junior (`"complexity": "junior"`)

Route to Line Cook for:
- Writing tests for existing code
- Adding CLI flags or config options
- Boilerplate/scaffolding
- Simple CRUD operations
- Following established patterns
- Documentation updates

**Indicators:**
- Clear, step-by-step requirements
- Similar code exists to copy from
- 3 or fewer acceptance criteria
- No architectural decisions

### Senior (`"complexity": "senior"`)

Route to Sous Chef for:
- Architectural decisions
- Complex algorithms
- Security-sensitive code
- Integration between systems
- Performance optimization
- Ambiguous requirements needing judgment

**Indicators:**
- Multiple valid approaches
- Requires understanding system context
- 4+ acceptance criteria
- Error handling strategy needed

### Auto (`"complexity": "auto"`)

Let Brigade decide based on heuristics. Good for:
- Mixed-complexity PRDs where you don't want to categorize each task
- When you're unsure

## Managing Dependencies

### Dependency Order

Tasks execute in dependency order:

```json
{
  "id": "US-001",
  "title": "Add database schema",
  "dependsOn": []
},
{
  "id": "US-002",
  "title": "Add data access layer",
  "dependsOn": ["US-001"]
},
{
  "id": "US-003",
  "title": "Add API endpoints",
  "dependsOn": ["US-002"]
},
{
  "id": "US-004",
  "title": "Add API tests",
  "dependsOn": ["US-003"]
}
```

### Parallel Tasks

Tasks with the same dependencies can run in any order:

```json
{
  "id": "US-002",
  "dependsOn": ["US-001"]
},
{
  "id": "US-003",
  "dependsOn": ["US-001"]  // Same dep as US-002
},
{
  "id": "US-004",
  "dependsOn": ["US-002", "US-003"]  // Waits for both
}
```

### Avoiding Circular Dependencies

This will cause Brigade to hang:
```json
{
  "id": "US-001",
  "dependsOn": ["US-002"]  // ❌ Circular!
},
{
  "id": "US-002",
  "dependsOn": ["US-001"]  // ❌ Circular!
}
```

## Test Requirements (Mandatory)

Every PRD must include comprehensive test coverage. Tests are not optional.

### 1. Include test criteria in implementation tasks

Add test requirements directly to acceptance criteria:

```json
{
  "id": "US-001",
  "title": "Add User model",
  "acceptanceCriteria": [
    "User model has id, email, password_hash fields",
    "Email validation rejects invalid formats",
    "Unit tests written for validation logic"
  ]
}
```

### 2. Create dedicated test tasks

For each major component, add a test task:

```json
{
  "id": "US-002",
  "title": "Add User model tests",
  "description": "Comprehensive tests for User model",
  "acceptanceCriteria": [
    "Test user creation with valid data",
    "Test email validation rejects invalid emails",
    "Test password hashing works correctly",
    "Test edge cases (empty strings, null values)"
  ],
  "dependsOn": ["US-001"],
  "complexity": "junior"
}
```

### 3. Test coverage by task type

| Task Type | Required Tests |
|-----------|----------------|
| Models/Services | Unit tests for all public methods |
| API endpoints | Integration tests for success + error cases |
| Bug fixes | Regression test proving the fix works |
| Utilities | Unit tests with edge cases |

### 4. Pattern: Implementation → Tests

```
US-001: Add User model (senior)
    ↓
US-002: Add User model tests (junior)
    ↓
US-003: Add login endpoint (senior)
    ↓
US-004: Add login endpoint tests (junior)
```

Test tasks should:
- Depend on their implementation task
- Be assigned `junior` complexity (tests follow patterns)
- Have specific scenarios listed in acceptance criteria

## Task Sizing

### Right-Sized Tasks

Each task should be completable in one AI session:
- 1-5 acceptance criteria
- Touches 1-3 files
- Can be described in 2-3 sentences

### Too Big

Split these up:
```json
// ❌ Too big
{
  "title": "Implement entire authentication system",
  "acceptanceCriteria": [
    "User model",
    "Password hashing",
    "JWT tokens",
    "Login endpoint",
    "Signup endpoint",
    "Password reset",
    "Email verification",
    "Session management",
    "Rate limiting",
    "Tests for everything"
  ]
}
```

### Too Small

Combine these:
```json
// ❌ Too granular
{ "title": "Create auth folder" },
{ "title": "Create user.go file" },
{ "title": "Add User struct" },
{ "title": "Add Email field" },
{ "title": "Add Password field" }
```

## Example PRD

See `examples/prd-example.json` for a complete example with proper structure, dependencies, and complexity annotations.
