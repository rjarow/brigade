#!/usr/bin/env bats
# Tests for state management functions

load test_helper

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  PRD_FILE="$TEST_TMPDIR/prd.json"
  # Don't override STATE_FILE - use the default from brigade.sh
  # State file will be at $TEST_TMPDIR/brigade-state.json

  create_test_prd "$PRD_FILE"
  create_test_state "$TEST_TMPDIR/brigade-state.json"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ═══════════════════════════════════════════════════════════════════════════════
# State file path tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "get_state_path returns correct path" {
  result=$(get_state_path "$PRD_FILE")
  [ "$result" = "$TEST_TMPDIR/brigade-state.json" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# State initialization tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "init_state creates state file" {
  rm -f "$TEST_TMPDIR/brigade-state.json"
  [ ! -f "$TEST_TMPDIR/brigade-state.json" ]

  init_state "$PRD_FILE"

  [ -f "$TEST_TMPDIR/brigade-state.json" ]
}

@test "init_state sets sessionId" {
  rm -f "$TEST_TMPDIR/brigade-state.json"
  init_state "$PRD_FILE"

  session_id=$(jq -r '.sessionId' "$TEST_TMPDIR/brigade-state.json")
  [ -n "$session_id" ]
  [ "$session_id" != "null" ]
}

@test "init_state does not overwrite existing state" {
  echo '{"sessionId": "keep-me", "taskHistory": []}' > "$TEST_TMPDIR/brigade-state.json"

  init_state "$PRD_FILE"

  session_id=$(jq -r '.sessionId' "$TEST_TMPDIR/brigade-state.json")
  [ "$session_id" = "keep-me" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Task state update tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "update_state_task sets currentTask" {
  update_state_task "$PRD_FILE" "US-001" "line" "started"

  current=$(jq -r '.currentTask' "$TEST_TMPDIR/brigade-state.json")
  [ "$current" = "US-001" ]
}

@test "update_state_task adds to taskHistory" {
  update_state_task "$PRD_FILE" "US-001" "line" "started"

  history_len=$(jq '.taskHistory | length' "$TEST_TMPDIR/brigade-state.json")
  [ "$history_len" -eq 1 ]

  task_id=$(jq -r '.taskHistory[0].taskId' "$TEST_TMPDIR/brigade-state.json")
  [ "$task_id" = "US-001" ]
}

@test "update_state_task records worker" {
  update_state_task "$PRD_FILE" "US-001" "sous" "started"

  worker=$(jq -r '.taskHistory[0].worker' "$TEST_TMPDIR/brigade-state.json")
  [ "$worker" = "sous" ]
}

@test "update_state_task records status" {
  update_state_task "$PRD_FILE" "US-001" "line" "completed"

  status=$(jq -r '.taskHistory[0].status' "$TEST_TMPDIR/brigade-state.json")
  [ "$status" = "completed" ]
}

@test "multiple updates append to history" {
  update_state_task "$PRD_FILE" "US-001" "line" "started"
  update_state_task "$PRD_FILE" "US-001" "line" "iteration_1"
  update_state_task "$PRD_FILE" "US-001" "line" "completed"

  history_len=$(jq '.taskHistory | length' "$TEST_TMPDIR/brigade-state.json")
  [ "$history_len" -eq 3 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Escalation recording tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "record_escalation adds escalation entry" {
  record_escalation "$PRD_FILE" "US-001" "line" "sous" "Max iterations reached"

  esc_len=$(jq '.escalations | length' "$TEST_TMPDIR/brigade-state.json")
  [ "$esc_len" -eq 1 ]
}

@test "record_escalation captures from/to workers" {
  record_escalation "$PRD_FILE" "US-001" "line" "sous" "Blocked"

  from=$(jq -r '.escalations[0].from' "$TEST_TMPDIR/brigade-state.json")
  to=$(jq -r '.escalations[0].to' "$TEST_TMPDIR/brigade-state.json")

  [ "$from" = "line" ]
  [ "$to" = "sous" ]
}

@test "record_escalation captures reason" {
  record_escalation "$PRD_FILE" "US-001" "sous" "executive" "Complex issue"

  reason=$(jq -r '.escalations[0].reason' "$TEST_TMPDIR/brigade-state.json")
  [ "$reason" = "Complex issue" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Absorption recording tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "record_absorption adds absorption entry" {
  record_absorption "$PRD_FILE" "US-002" "US-001"

  abs_len=$(jq '.absorptions | length' "$TEST_TMPDIR/brigade-state.json")
  [ "$abs_len" -eq 1 ]
}

@test "record_absorption captures taskId and absorbedBy" {
  record_absorption "$PRD_FILE" "US-003" "US-001"

  task_id=$(jq -r '.absorptions[0].taskId' "$TEST_TMPDIR/brigade-state.json")
  absorbed_by=$(jq -r '.absorptions[0].absorbedBy' "$TEST_TMPDIR/brigade-state.json")

  [ "$task_id" = "US-003" ]
  [ "$absorbed_by" = "US-001" ]
}

@test "record_absorption includes timestamp" {
  record_absorption "$PRD_FILE" "US-002" "US-001"

  timestamp=$(jq -r '.absorptions[0].timestamp' "$TEST_TMPDIR/brigade-state.json")
  [ -n "$timestamp" ]
  [ "$timestamp" != "null" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Review recording tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "record_review adds review entry" {
  record_review "$PRD_FILE" "US-001" "PASS" "All criteria met"

  rev_len=$(jq '.reviews | length' "$TEST_TMPDIR/brigade-state.json")
  [ "$rev_len" -eq 1 ]
}

@test "record_review captures result and reason" {
  record_review "$PRD_FILE" "US-001" "FAIL" "Tests not passing"

  result=$(jq -r '.reviews[0].result' "$TEST_TMPDIR/brigade-state.json")
  reason=$(jq -r '.reviews[0].reason' "$TEST_TMPDIR/brigade-state.json")

  [ "$result" = "FAIL" ]
  [ "$reason" = "Tests not passing" ]
}
