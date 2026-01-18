# Brigade Update PRD Skill

You are updating an existing Brigade PRD (Product Requirements Document). Parse the user's natural language request to understand what changes they want, then apply them.

## Example Invocations

- `/brigade-update-prd Add a caching layer task to prd-api.json`
- `/brigade-update-prd Mark US-003 as needing re-work`
- `/brigade-update-prd Remove US-005 from the auth PRD`
- `/brigade-update-prd Change the test command to "npm test"`
- `/brigade-update-prd Add acceptance criteria to US-002: "handles empty input"`
- `/brigade-update-prd Make US-004 depend on US-002`

## Workflow

### Step 1: Find the PRD

1. Look for a PRD path in the user's request (e.g., `brigade/tasks/prd-auth.json`)
2. If not specified, check for PRD files in `brigade/tasks/` directory
3. If multiple PRDs exist and it's ambiguous, list them and ask which one to update
4. Read and parse the PRD JSON

### Step 2: Understand the Request

Parse what the user wants to do. Support these modification types:

| Request Pattern | Action |
|-----------------|--------|
| "Add task...", "Insert task..." | Add new task |
| "Remove/delete task US-XXX" | Remove task |
| "Modify/update/change US-XXX" | Edit task fields |
| "Re-open US-XXX", "Reset US-XXX" | Set passes to false |
| "Add criteria to US-XXX" | Append to acceptanceCriteria |
| "Make US-XXX depend on US-YYY" | Update dependsOn |
| "Change complexity of US-XXX to senior" | Update complexity |
| "Update test command to..." | Update testCommand |
| "Change feature name to..." | Update featureName |
| "Update description..." | Update description |

If the request is unclear, ask clarifying questions.

### Step 3: Apply Changes

#### Adding a Task

When adding a task:
1. Generate the next available task ID (e.g., if US-005 exists, use US-006)
2. Ask for or infer:
   - Title (required)
   - Description (default to user story format)
   - Acceptance criteria (at least 1)
   - Dependencies (which existing tasks it depends on)
   - Complexity: `junior`, `senior`, or `auto`
3. Set `passes: false`

```json
{
  "id": "US-006",
  "title": "Add caching layer",
  "description": "As a developer, I want API responses cached to improve performance",
  "acceptanceCriteria": [
    "GET requests are cached for 5 minutes",
    "Cache can be invalidated manually",
    "Cache hit/miss logged for debugging"
  ],
  "dependsOn": ["US-003"],
  "complexity": "senior",
  "passes": false
}
```

#### Removing a Task

Before removing:
1. Check if other tasks depend on this one
2. If yes, warn the user and ask how to handle:
   - Remove the dependency references too
   - Cancel the removal
3. Remove the task from the tasks array

#### Modifying a Task

Update only the fields specified:
- `title`: New title string
- `description`: New description string
- `acceptanceCriteria`: Replace array or append to it
- `dependsOn`: Replace array or add/remove specific IDs
- `complexity`: Change to `junior`, `senior`, or `auto`

#### Re-opening a Task

Set `passes` back to `false` so the task will be executed again:
```json
"passes": false
```

#### Updating Metadata

Update top-level PRD fields:
- `featureName`: Display name for the feature
- `branchName`: Git branch name (should be kebab-case)
- `description`: Feature description
- `testCommand`: Command to run tests
- `constraints`: Array of constraints/anti-patterns

### Step 4: Validate

Before saving, validate:

1. **Unique IDs**: No duplicate task IDs
2. **Valid dependencies**: All `dependsOn` references point to existing task IDs
3. **No circular dependencies**: Task A can't depend on B if B depends on A (directly or indirectly)
4. **Required fields**: Each task has `id`, `title`, `acceptanceCriteria`, `complexity`, `passes`
5. **Valid JSON**: Output must be valid JSON

If validation fails, explain the issue and ask how to fix it.

### Step 5: Save and Report

1. Write the updated PRD back to the same file
2. Show a summary of changes made:
   ```
   Updated brigade/tasks/prd-api.json:
   - Added task US-006: "Add caching layer" (senior)
   - Updated US-003 dependencies: now depends on [US-001, US-002]
   ```
3. If tasks were modified or re-opened, suggest the command to run:
   ```
   To execute: ./brigade.sh service brigade/tasks/prd-api.json
   ```

## PRD JSON Structure Reference

```json
{
  "featureName": "Feature Name",
  "branchName": "feature/kebab-case",
  "createdAt": "YYYY-MM-DD",
  "description": "Brief description",
  "testCommand": "npm test",
  "constraints": ["constraint 1", "constraint 2"],
  "tasks": [
    {
      "id": "US-001",
      "title": "Task title",
      "description": "User story or description",
      "acceptanceCriteria": ["criterion 1", "criterion 2"],
      "dependsOn": [],
      "complexity": "junior|senior|auto",
      "passes": false
    }
  ]
}
```

## Complexity Guidelines

When adding or changing task complexity:

- **junior**: Tests, boilerplate, simple CRUD, config changes, docs, following established patterns
- **senior**: Architecture decisions, security-sensitive code, complex logic, integration, ambiguous requirements
- **auto**: Let Brigade's heuristics decide based on task content

## Tips

- Support compound requests: "Add task X and make US-002 depend on it"
- When adding related tasks (e.g., implementation + tests), offer to add both
- If user says "re-run" or "redo" a task, that means set `passes: false`
- Preserve existing field values when only modifying specific fields
- Keep task IDs sequential when possible, but gaps are OK
