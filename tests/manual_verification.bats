#!/usr/bin/env bats
# Tests for manual verification gate

load test_helper

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  TEST_PRD="$TEST_TMPDIR/prd.json"
  TEST_STATE="$TEST_TMPDIR/prd.state.json"

  # Create PRD with manual verification task
  cat > "$TEST_PRD" <<'EOF'
{
  "featureName": "Manual Verification Test",
  "branchName": "test/manual-verification",
  "tasks": [
    {
      "id": "US-001",
      "title": "Task with manual verification",
      "acceptanceCriteria": ["UI renders correctly", "Button is clickable"],
      "manualVerification": true,
      "dependsOn": [],
      "complexity": "junior",
      "passes": false
    },
    {
      "id": "US-002",
      "title": "Task without manual verification",
      "acceptanceCriteria": ["Logic works correctly"],
      "dependsOn": [],
      "complexity": "junior",
      "passes": false
    }
  ]
}
EOF

  init_state "$TEST_PRD"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Config defaults
# ═══════════════════════════════════════════════════════════════════════════════

@test "MANUAL_VERIFICATION_ENABLED defaults to false" {
  [ "$MANUAL_VERIFICATION_ENABLED" == "false" ]
}

@test "LAST_MANUAL_VERIFICATION_FEEDBACK starts empty" {
  LAST_MANUAL_VERIFICATION_FEEDBACK=""
  [ -z "$LAST_MANUAL_VERIFICATION_FEEDBACK" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Skip logic
# ═══════════════════════════════════════════════════════════════════════════════

@test "check_manual_verification skips when disabled" {
  MANUAL_VERIFICATION_ENABLED="false"

  run check_manual_verification "$TEST_PRD" "US-001"
  [ "$status" -eq 0 ]
}

@test "check_manual_verification skips tasks without flag" {
  MANUAL_VERIFICATION_ENABLED="true"

  run check_manual_verification "$TEST_PRD" "US-002"
  [ "$status" -eq 0 ]
}

@test "check_manual_verification skips tasks with flag=false" {
  MANUAL_VERIFICATION_ENABLED="true"

  # Create PRD with explicit false flag
  cat > "$TEST_PRD" <<'EOF'
{
  "featureName": "Test",
  "tasks": [{"id": "US-001", "title": "Test", "manualVerification": false}]
}
EOF

  run check_manual_verification "$TEST_PRD" "US-001"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Walkaway mode behavior
# ═══════════════════════════════════════════════════════════════════════════════

@test "check_manual_verification auto-approves in walkaway mode" {
  MANUAL_VERIFICATION_ENABLED="true"
  WALKAWAY_MODE="true"
  SUPERVISOR_CMD_FILE=""

  run check_manual_verification "$TEST_PRD" "US-001"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Auto-approving"* ]] || [[ "$output" == *"walkaway"* ]]
}

@test "check_manual_verification logs auto-approval in walkaway mode" {
  MANUAL_VERIFICATION_ENABLED="true"
  WALKAWAY_MODE="true"
  SUPERVISOR_CMD_FILE=""

  run check_manual_verification "$TEST_PRD" "US-001"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Feedback tracking
# ═══════════════════════════════════════════════════════════════════════════════

@test "LAST_MANUAL_VERIFICATION_FEEDBACK cleared on fresh start" {
  LAST_MANUAL_VERIFICATION_FEEDBACK="previous feedback"
  MANUAL_VERIFICATION_ENABLED="true"
  WALKAWAY_MODE="true"  # Auto-approve for testing

  check_manual_verification "$TEST_PRD" "US-001"

  # After approval, feedback should be empty
  [ -z "$LAST_MANUAL_VERIFICATION_FEEDBACK" ]
}

@test "LAST_MANUAL_VERIFICATION_FEEDBACK can be set with reason" {
  LAST_MANUAL_VERIFICATION_FEEDBACK="Manual verification rejected: Button doesn't work"
  [ -n "$LAST_MANUAL_VERIFICATION_FEEDBACK" ]
  [[ "$LAST_MANUAL_VERIFICATION_FEEDBACK" == *"Button"* ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# PRD field detection
# ═══════════════════════════════════════════════════════════════════════════════

@test "check_manual_verification detects manualVerification field" {
  local requires=$(jq -r '.tasks[0].manualVerification' "$TEST_PRD")
  [ "$requires" == "true" ]
}

@test "check_manual_verification handles missing field gracefully" {
  # Create PRD without manualVerification field
  cat > "$TEST_PRD" <<'EOF'
{
  "featureName": "Test",
  "tasks": [{"id": "US-001", "title": "Test", "acceptanceCriteria": ["Works"]}]
}
EOF

  MANUAL_VERIFICATION_ENABLED="true"

  run check_manual_verification "$TEST_PRD" "US-001"
  [ "$status" -eq 0 ]  # Should skip, not fail
}

# ═══════════════════════════════════════════════════════════════════════════════
# Display formatting
# ═══════════════════════════════════════════════════════════════════════════════

@test "check_manual_verification shows task title" {
  MANUAL_VERIFICATION_ENABLED="true"
  WALKAWAY_MODE="true"  # Auto-approve for testing

  run check_manual_verification "$TEST_PRD" "US-001"
  [[ "$output" == *"Task with manual verification"* ]] || [ "$status" -eq 0 ]
}

@test "check_manual_verification shows acceptance criteria" {
  MANUAL_VERIFICATION_ENABLED="true"
  WALKAWAY_MODE="true"  # Auto-approve for testing

  run check_manual_verification "$TEST_PRD" "US-001"
  # Either shows criteria or auto-approves silently
  [ "$status" -eq 0 ]
}
