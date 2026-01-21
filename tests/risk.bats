#!/usr/bin/env bats
# Tests for risk assessment functions (P9)

load test_helper

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  PRD_FILE="$TEST_TMPDIR/prd.json"

  # Enable risk reporting for tests
  RISK_REPORT_ENABLED=true
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Task risk scoring tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "calculate_task_risk scores auth tasks high" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Auth Feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Add JWT authentication",
      "acceptanceCriteria": ["Auth works"],
      "dependsOn": [],
      "complexity": "senior",
      "verification": [],
      "passes": false
    }
  ]
}
EOF

  score=$(calculate_task_risk "$PRD_FILE" "US-001")
  # Should score: auth(3) + no verification(2) + senior(1) = 6+
  [ "$score" -ge 5 ]
}

@test "calculate_task_risk scores payment tasks high" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Payment Feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Add Stripe payment processing",
      "acceptanceCriteria": ["Payments work"],
      "dependsOn": [],
      "complexity": "senior",
      "verification": [],
      "passes": false
    }
  ]
}
EOF

  score=$(calculate_task_risk "$PRD_FILE" "US-001")
  # Should score: payment(3) + no verification(2) + senior(1) = 6+
  [ "$score" -ge 5 ]
}

@test "calculate_task_risk scores simple tasks low" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Simple Feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Add button component",
      "acceptanceCriteria": ["Button renders"],
      "dependsOn": [],
      "complexity": "junior",
      "verification": [{"type": "unit", "cmd": "npm test"}],
      "passes": false
    }
  ]
}
EOF

  score=$(calculate_task_risk "$PRD_FILE" "US-001")
  # Simple task with unit test should score low
  [ "$score" -le 2 ]
}

@test "calculate_task_risk adds points for missing verification" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Test Feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Simple task",
      "acceptanceCriteria": ["Done"],
      "dependsOn": [],
      "complexity": "junior",
      "verification": [],
      "passes": false
    }
  ]
}
EOF

  score=$(calculate_task_risk "$PRD_FILE" "US-001")
  # Missing verification adds 2 points
  [ "$score" -ge 2 ]
}

@test "calculate_task_risk adds points for grep-only verification" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Test Feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Simple task",
      "acceptanceCriteria": ["Done"],
      "dependsOn": [],
      "complexity": "junior",
      "verification": [{"type": "pattern", "cmd": "grep -q 'test' file.ts"}],
      "passes": false
    }
  ]
}
EOF

  score=$(calculate_task_risk "$PRD_FILE" "US-001")
  # Grep-only adds 1 point
  [ "$score" -ge 1 ]
}

@test "calculate_task_risk scores external integrations" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Integration Feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Connect to third-party API webhook",
      "acceptanceCriteria": ["API connected"],
      "dependsOn": [],
      "complexity": "senior",
      "verification": [],
      "passes": false
    }
  ]
}
EOF

  score=$(calculate_task_risk "$PRD_FILE" "US-001")
  # External integration (api=2, webhook=2, third-party=2) + no verify(2) + senior(1) = 9+
  [ "$score" -ge 5 ]
}

@test "calculate_task_risk scores data operations" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Data Feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Run database migration",
      "acceptanceCriteria": ["Migration complete"],
      "dependsOn": [],
      "complexity": "senior",
      "verification": [],
      "passes": false
    }
  ]
}
EOF

  score=$(calculate_task_risk "$PRD_FILE" "US-001")
  # Data op (migration=2, database=2) + no verify(2) + senior(1) = 7+
  [ "$score" -ge 5 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Risk factors tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "get_task_risk_factors identifies auth code" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Auth Feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Implement JWT token validation",
      "acceptanceCriteria": ["Tokens validated"],
      "dependsOn": [],
      "complexity": "senior",
      "verification": [],
      "passes": false
    }
  ]
}
EOF

  factors=$(get_task_risk_factors "$PRD_FILE" "US-001")
  echo "$factors" | grep -qi "auth"
}

@test "get_task_risk_factors identifies payment processing" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Payment Feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Add billing checkout flow",
      "acceptanceCriteria": ["Checkout works"],
      "dependsOn": [],
      "complexity": "senior",
      "verification": [],
      "passes": false
    }
  ]
}
EOF

  factors=$(get_task_risk_factors "$PRD_FILE" "US-001")
  echo "$factors" | grep -qi "payment"
}

@test "get_task_risk_factors identifies missing verification" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Test Feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Simple task",
      "acceptanceCriteria": ["Done"],
      "dependsOn": [],
      "complexity": "junior",
      "verification": [],
      "passes": false
    }
  ]
}
EOF

  factors=$(get_task_risk_factors "$PRD_FILE" "US-001")
  echo "$factors" | grep -qi "verification"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PRD risk level tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "get_risk_level returns LOW for low scores" {
  level=$(get_risk_level 3)
  [ "$level" = "LOW" ]
}

@test "get_risk_level returns MEDIUM for medium scores" {
  level=$(get_risk_level 8)
  [ "$level" = "MEDIUM" ]
}

@test "get_risk_level returns HIGH for high scores" {
  level=$(get_risk_level 15)
  [ "$level" = "HIGH" ]
}

@test "get_risk_level returns CRITICAL for critical scores" {
  level=$(get_risk_level 25)
  [ "$level" = "CRITICAL" ]
}

@test "calculate_prd_risk aggregates task scores" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Multi-task Feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Add authentication",
      "acceptanceCriteria": ["Auth works"],
      "dependsOn": [],
      "complexity": "senior",
      "verification": [],
      "passes": false
    },
    {
      "id": "US-002",
      "title": "Add payment processing",
      "acceptanceCriteria": ["Payments work"],
      "dependsOn": [],
      "complexity": "senior",
      "verification": [],
      "passes": false
    }
  ]
}
EOF

  total=$(calculate_prd_risk "$PRD_FILE")
  # Both tasks should score high, total should be substantial
  [ "$total" -ge 10 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Flagged tasks tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "get_flagged_tasks returns high-risk tasks" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Mixed Feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Add button",
      "acceptanceCriteria": ["Button works"],
      "dependsOn": [],
      "complexity": "junior",
      "verification": [{"type": "unit", "cmd": "npm test"}],
      "passes": false
    },
    {
      "id": "US-002",
      "title": "Add JWT authentication",
      "acceptanceCriteria": ["Auth works"],
      "dependsOn": [],
      "complexity": "senior",
      "verification": [],
      "passes": false
    }
  ]
}
EOF

  flagged=$(get_flagged_tasks "$PRD_FILE")
  echo "$flagged" | grep -q "US-002"
}

@test "get_flagged_tasks excludes low-risk tasks" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Simple Feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Add button",
      "acceptanceCriteria": ["Button works"],
      "dependsOn": [],
      "complexity": "junior",
      "verification": [{"type": "unit", "cmd": "npm test"}],
      "passes": false
    }
  ]
}
EOF

  flagged=$(get_flagged_tasks "$PRD_FILE")
  # Task with score 0 should not be flagged
  [ -z "$flagged" ] || ! echo "$flagged" | grep -q "US-001"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Risk summary tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "print_risk_summary outputs risk level" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Test Feature",
  "tasks": [
    {
      "id": "US-001",
      "title": "Add JWT authentication",
      "acceptanceCriteria": ["Auth works"],
      "dependsOn": [],
      "complexity": "senior",
      "verification": [],
      "passes": false
    }
  ]
}
EOF

  RISK_REPORT_ENABLED=true
  output=$(print_risk_summary "$PRD_FILE")
  echo "$output" | grep -qE "(LOW|MEDIUM|HIGH|CRITICAL)"
}

@test "print_risk_summary respects RISK_REPORT_ENABLED=false" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Test Feature",
  "tasks": [{"id": "US-001", "title": "Task", "complexity": "junior", "verification": [], "passes": false}]
}
EOF

  RISK_REPORT_ENABLED=false
  output=$(print_risk_summary "$PRD_FILE")
  [ -z "$output" ]
}
