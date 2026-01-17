# Convert PRD to JSON Skill

You are converting a PRD (Product Requirements Document) from various formats into Brigade's JSON format.

## Supported Input Formats

- Markdown PRDs
- Plain text feature descriptions
- Bullet point task lists
- User stories
- Jira/Linear exports
- Informal notes

## Output Format

Convert to this exact JSON structure:

```json
{
  "featureName": "Feature Name",
  "branchName": "feature/kebab-case-name",
  "createdAt": "YYYY-MM-DD",
  "description": "Brief description of the feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Short descriptive title",
      "description": "As a [user], I want [feature] so that [benefit]",
      "acceptanceCriteria": [
        "Specific, verifiable criterion 1",
        "Specific, verifiable criterion 2"
      ],
      "dependsOn": [],
      "complexity": "junior|senior|auto",
      "passes": false
    }
  ]
}
```

## Conversion Rules

1. **Task IDs**: Use sequential `US-001`, `US-002`, etc.

2. **Titles**: Keep concise (5-10 words), action-oriented

3. **Descriptions**: Convert to user story format if not already

4. **Acceptance Criteria**:
   - Make each criterion specific and verifiable
   - Split vague requirements into specific checkpoints
   - Add implicit criteria that are necessary

5. **Dependencies**:
   - Infer logical dependencies from task order
   - Models/schemas before code that uses them
   - Core features before tests
   - Foundation before integration

6. **Complexity Assignment**:
   - `"junior"`: Tests, boilerplate, simple CRUD, config, docs
   - `"senior"`: Architecture, security, integration, complex logic
   - `"auto"`: When unclear

7. **All tasks start with**: `"passes": false`

## Workflow

1. Read the input PRD/description
2. Identify distinct tasks
3. Determine logical dependencies
4. Assign complexity based on task nature
5. Generate proper acceptance criteria
6. Output valid JSON

## Example Conversion

Input:
```
Feature: Password Reset
- Add password reset request endpoint
- Send reset email with token
- Add reset confirmation page
- Tests
```

Output:
```json
{
  "featureName": "Password Reset",
  "branchName": "feature/password-reset",
  "createdAt": "2025-01-17",
  "description": "Allow users to reset their password via email",
  "tasks": [
    {
      "id": "US-001",
      "title": "Add password reset token model",
      "description": "As a developer, I need a model to store reset tokens securely",
      "acceptanceCriteria": [
        "ResetToken model with user_id, token_hash, expires_at, used_at fields",
        "Token expires after 1 hour",
        "Token can only be used once"
      ],
      "dependsOn": [],
      "complexity": "senior",
      "passes": false
    },
    {
      "id": "US-002",
      "title": "Add password reset request endpoint",
      "description": "As a user, I want to request a password reset so I can regain access",
      "acceptanceCriteria": [
        "POST /auth/reset-password accepts email",
        "Generates secure random token",
        "Returns 200 even if email not found (security)",
        "Rate limited to prevent abuse"
      ],
      "dependsOn": ["US-001"],
      "complexity": "senior",
      "passes": false
    },
    {
      "id": "US-003",
      "title": "Send password reset email",
      "description": "As a user, I want to receive an email with reset instructions",
      "acceptanceCriteria": [
        "Email contains secure reset link",
        "Link expires after 1 hour",
        "Email template is professional"
      ],
      "dependsOn": ["US-002"],
      "complexity": "senior",
      "passes": false
    },
    {
      "id": "US-004",
      "title": "Add password reset confirmation endpoint",
      "description": "As a user, I want to set a new password using my reset token",
      "acceptanceCriteria": [
        "POST /auth/reset-password/confirm accepts token and new password",
        "Validates token is not expired or used",
        "Updates user password",
        "Invalidates token after use"
      ],
      "dependsOn": ["US-001"],
      "complexity": "senior",
      "passes": false
    },
    {
      "id": "US-005",
      "title": "Add password reset tests",
      "description": "As a developer, I want tests covering the reset flow",
      "acceptanceCriteria": [
        "Test reset request creates token",
        "Test reset with valid token succeeds",
        "Test reset with expired token fails",
        "Test reset with used token fails"
      ],
      "dependsOn": ["US-002", "US-004"],
      "complexity": "junior",
      "passes": false
    }
  ]
}
```
