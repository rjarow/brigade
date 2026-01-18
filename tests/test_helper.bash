#!/usr/bin/env bash
# Test helper for brigade.sh tests
# Sources brigade.sh functions without running main

# Get the directory of this script
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$TEST_DIR")"

# Source brigade.sh (main won't run due to source guard)
source "$PROJECT_ROOT/brigade.sh"

# Override config for testing
CONTEXT_ISOLATION="true"
KNOWLEDGE_SHARING="true"
ESCALATION_ENABLED="true"
ESCALATION_AFTER=3
REVIEW_ENABLED="false"

# Create a temporary PRD for testing
create_test_prd() {
  local prd_file="$1"
  cat > "$prd_file" <<'EOF'
{
  "featureName": "Test Feature",
  "branchName": "test/feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "First task",
      "acceptanceCriteria": ["Criterion 1"],
      "dependsOn": [],
      "complexity": "junior",
      "passes": false
    },
    {
      "id": "US-002",
      "title": "Second task with dependency",
      "acceptanceCriteria": ["Criterion 2"],
      "dependsOn": ["US-001"],
      "complexity": "senior",
      "passes": false
    },
    {
      "id": "US-003",
      "title": "Third task parallel",
      "acceptanceCriteria": ["Criterion 3"],
      "dependsOn": [],
      "complexity": "junior",
      "passes": false
    }
  ]
}
EOF
}

# Create a test state file
create_test_state() {
  local state_file="$1"
  cat > "$state_file" <<'EOF'
{
  "sessionId": "test-123",
  "startedAt": "2025-01-18T10:00:00+00:00",
  "currentTask": null,
  "taskHistory": [],
  "escalations": [],
  "reviews": [],
  "absorptions": []
}
EOF
}

# Create test learnings file
create_test_learnings() {
  local learnings_file="$1"
  cat > "$learnings_file" <<'EOF'
# Brigade Learnings: Test Feature

---

## [note] US-001 - Line Cook (2025-01-18 10:00)

Socket tests pattern: Use temp directory + test name for unique paths.

---

## [note] US-002 - Sous Chef (2025-01-18 11:00)

Database connection pooling: Always close connections in defer/finally.

---
EOF
}
