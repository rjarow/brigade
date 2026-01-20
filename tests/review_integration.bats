#!/usr/bin/env bats
# Integration tests for executive_review and phase_review with mock workers
# These tests actually invoke the review functions with mock EXECUTIVE_CMD

load test_helper

MOCK_WORKER="$BATS_TEST_DIRNAME/mocks/mock_worker.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  TEST_PRD="$TEST_TMPDIR/prd.json"
  TEST_STATE="$TEST_TMPDIR/prd.state.json"

  create_test_prd "$TEST_PRD"
  init_state "$TEST_PRD"

  # Configure mock for executive reviews
  export EXECUTIVE_CMD="$MOCK_WORKER"
  export EXECUTIVE_AGENT="claude"
  export REVIEW_ENABLED="true"
  export REVIEW_JUNIOR_ONLY="false"

  # Disable phase review by default
  export PHASE_REVIEW_ENABLED="false"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
  unset MOCK_BEHAVIOR
}

# ═══════════════════════════════════════════════════════════════════════════════
# executive_review integration tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "executive_review with mock returns PASS correctly" {
  export MOCK_BEHAVIOR=review_pass

  run executive_review "$TEST_PRD" "US-001" "line"
  [ "$status" -eq 0 ]

  # Check review was recorded in state
  local state_path=$(get_state_path "$TEST_PRD")
  local review_count=$(jq '.reviews | length' "$state_path")
  [ "$review_count" -ge 1 ]

  local result=$(jq -r '.reviews[-1].result' "$state_path")
  [ "$result" == "PASS" ]
}

@test "executive_review with mock returns FAIL correctly" {
  export MOCK_BEHAVIOR=review_fail

  run executive_review "$TEST_PRD" "US-001" "line"
  [ "$status" -eq 1 ]

  # Check review was recorded with FAIL
  local state_path=$(get_state_path "$TEST_PRD")
  local result=$(jq -r '.reviews[-1].result' "$state_path")
  [ "$result" == "FAIL" ]
}

@test "executive_review extracts reason from PASS response" {
  export MOCK_BEHAVIOR=review_pass

  run executive_review "$TEST_PRD" "US-001" "line"

  local state_path=$(get_state_path "$TEST_PRD")
  local reason=$(jq -r '.reviews[-1].reason' "$state_path")

  # Mock returns: "Implementation correctly addresses all acceptance criteria"
  [[ "$reason" == *"acceptance criteria"* ]] || [[ "$reason" == *"Implementation"* ]]
}

@test "executive_review extracts reason from FAIL response" {
  export MOCK_BEHAVIOR=review_fail

  run executive_review "$TEST_PRD" "US-001" "line"

  local state_path=$(get_state_path "$TEST_PRD")
  local reason=$(jq -r '.reviews[-1].reason' "$state_path")

  # Mock returns: "Missing error handling in main function"
  [[ "$reason" == *"error handling"* ]] || [[ "$reason" == *"Missing"* ]]
}

@test "executive_review sets LAST_REVIEW_FEEDBACK on FAIL" {
  export MOCK_BEHAVIOR=review_fail
  LAST_REVIEW_FEEDBACK=""

  executive_review "$TEST_PRD" "US-001" "line" || true

  # After FAIL, feedback should be set
  [ -n "$LAST_REVIEW_FEEDBACK" ]
}

@test "executive_review clears LAST_REVIEW_FEEDBACK on PASS" {
  LAST_REVIEW_FEEDBACK="previous feedback"
  export MOCK_BEHAVIOR=review_pass

  executive_review "$TEST_PRD" "US-001" "line"

  # After PASS, feedback should be cleared
  [ -z "$LAST_REVIEW_FEEDBACK" ]
}

@test "executive_review skips senior work when REVIEW_JUNIOR_ONLY=true" {
  export REVIEW_JUNIOR_ONLY="true"
  export MOCK_BEHAVIOR="review_fail"  # Would fail if called

  run executive_review "$TEST_PRD" "US-002" "sous"
  [ "$status" -eq 0 ]

  # No review should be recorded
  local state_path=$(get_state_path "$TEST_PRD")
  local review_count=$(jq '.reviews | length' "$state_path")
  [ "$review_count" -eq 0 ]
}

@test "executive_review reviews junior work when REVIEW_JUNIOR_ONLY=true" {
  export REVIEW_JUNIOR_ONLY="true"
  export MOCK_BEHAVIOR="review_pass"

  run executive_review "$TEST_PRD" "US-001" "line"
  [ "$status" -eq 0 ]

  # Review should be recorded
  local state_path=$(get_state_path "$TEST_PRD")
  local review_count=$(jq '.reviews | length' "$state_path")
  [ "$review_count" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# phase_review integration tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "phase_review invokes at correct interval" {
  export PHASE_REVIEW_ENABLED="true"
  export PHASE_REVIEW_AFTER=2
  export MOCK_BEHAVIOR="complete"

  # At count 2, should trigger (2 % 2 == 0)
  run phase_review "$TEST_PRD" 2
  [ "$status" -eq 0 ]
}

@test "phase_review skips when not at interval" {
  export PHASE_REVIEW_ENABLED="true"
  export PHASE_REVIEW_AFTER=5
  export MOCK_BEHAVIOR="review_fail"  # Would fail if called

  # At count 3, not a multiple of 5
  run phase_review "$TEST_PRD" 3
  [ "$status" -eq 0 ]

  # No phase review should be recorded
  local state_path=$(get_state_path "$TEST_PRD")
  local count=$(jq '.phaseReviews | length' "$state_path" 2>/dev/null || echo 0)
  [ "$count" -eq 0 ]
}

@test "phase_review skips when disabled" {
  export PHASE_REVIEW_ENABLED="false"
  export MOCK_BEHAVIOR="review_fail"  # Would fail if called

  run phase_review "$TEST_PRD" 5
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Multiple reviews accumulate
# ═══════════════════════════════════════════════════════════════════════════════

@test "multiple executive reviews accumulate in state" {
  export MOCK_BEHAVIOR=review_pass

  executive_review "$TEST_PRD" "US-001" "line"
  executive_review "$TEST_PRD" "US-002" "sous"

  local state_path=$(get_state_path "$TEST_PRD")
  local review_count=$(jq '.reviews | length' "$state_path")
  [ "$review_count" -eq 2 ]
}
