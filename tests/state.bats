#!/usr/bin/env bats
# Tests for state management functions

load test_helper

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  PRD_FILE="$TEST_TMPDIR/prd.json"
  # State file is now per-PRD: prd.json → prd.state.json
  STATE_FILE_PATH="$TEST_TMPDIR/prd.state.json"

  create_test_prd "$PRD_FILE"
  create_test_state "$STATE_FILE_PATH"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ═══════════════════════════════════════════════════════════════════════════════
# State file path tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "get_state_path returns correct path" {
  result=$(get_state_path "$PRD_FILE")
  [ "$result" = "$STATE_FILE_PATH" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# State initialization tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "init_state creates state file" {
  rm -f "$STATE_FILE_PATH"
  [ ! -f "$STATE_FILE_PATH" ]

  init_state "$PRD_FILE"

  [ -f "$STATE_FILE_PATH" ]
}

@test "init_state sets sessionId" {
  rm -f "$STATE_FILE_PATH"
  init_state "$PRD_FILE"

  session_id=$(jq -r '.sessionId' "$STATE_FILE_PATH")
  [ -n "$session_id" ]
  [ "$session_id" != "null" ]
}

@test "init_state does not overwrite existing state" {
  echo '{"sessionId": "keep-me", "taskHistory": []}' > "$STATE_FILE_PATH"

  init_state "$PRD_FILE"

  session_id=$(jq -r '.sessionId' "$STATE_FILE_PATH")
  [ "$session_id" = "keep-me" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Task state update tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "update_state_task sets currentTask" {
  update_state_task "$PRD_FILE" "US-001" "line" "started"

  current=$(jq -r '.currentTask' "$STATE_FILE_PATH")
  [ "$current" = "US-001" ]
}

@test "update_state_task adds to taskHistory" {
  update_state_task "$PRD_FILE" "US-001" "line" "started"

  history_len=$(jq '.taskHistory | length' "$STATE_FILE_PATH")
  [ "$history_len" -eq 1 ]

  task_id=$(jq -r '.taskHistory[0].taskId' "$STATE_FILE_PATH")
  [ "$task_id" = "US-001" ]
}

@test "update_state_task records worker" {
  update_state_task "$PRD_FILE" "US-001" "sous" "started"

  worker=$(jq -r '.taskHistory[0].worker' "$STATE_FILE_PATH")
  [ "$worker" = "sous" ]
}

@test "update_state_task records status" {
  update_state_task "$PRD_FILE" "US-001" "line" "completed"

  status=$(jq -r '.taskHistory[0].status' "$STATE_FILE_PATH")
  [ "$status" = "completed" ]
}

@test "multiple updates append to history" {
  update_state_task "$PRD_FILE" "US-001" "line" "started"
  update_state_task "$PRD_FILE" "US-001" "line" "iteration_1"
  update_state_task "$PRD_FILE" "US-001" "line" "completed"

  history_len=$(jq '.taskHistory | length' "$STATE_FILE_PATH")
  [ "$history_len" -eq 3 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Escalation recording tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "record_escalation adds escalation entry" {
  record_escalation "$PRD_FILE" "US-001" "line" "sous" "Max iterations reached"

  esc_len=$(jq '.escalations | length' "$STATE_FILE_PATH")
  [ "$esc_len" -eq 1 ]
}

@test "record_escalation captures from/to workers" {
  record_escalation "$PRD_FILE" "US-001" "line" "sous" "Blocked"

  from=$(jq -r '.escalations[0].from' "$STATE_FILE_PATH")
  to=$(jq -r '.escalations[0].to' "$STATE_FILE_PATH")

  [ "$from" = "line" ]
  [ "$to" = "sous" ]
}

@test "record_escalation captures reason" {
  record_escalation "$PRD_FILE" "US-001" "sous" "executive" "Complex issue"

  reason=$(jq -r '.escalations[0].reason' "$STATE_FILE_PATH")
  [ "$reason" = "Complex issue" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Absorption recording tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "record_absorption adds absorption entry" {
  record_absorption "$PRD_FILE" "US-002" "US-001"

  abs_len=$(jq '.absorptions | length' "$STATE_FILE_PATH")
  [ "$abs_len" -eq 1 ]
}

@test "record_absorption captures taskId and absorbedBy" {
  record_absorption "$PRD_FILE" "US-003" "US-001"

  task_id=$(jq -r '.absorptions[0].taskId' "$STATE_FILE_PATH")
  absorbed_by=$(jq -r '.absorptions[0].absorbedBy' "$STATE_FILE_PATH")

  [ "$task_id" = "US-003" ]
  [ "$absorbed_by" = "US-001" ]
}

@test "record_absorption includes timestamp" {
  record_absorption "$PRD_FILE" "US-002" "US-001"

  timestamp=$(jq -r '.absorptions[0].timestamp' "$STATE_FILE_PATH")
  [ -n "$timestamp" ]
  [ "$timestamp" != "null" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Review recording tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "record_review adds review entry" {
  record_review "$PRD_FILE" "US-001" "PASS" "All criteria met"

  rev_len=$(jq '.reviews | length' "$STATE_FILE_PATH")
  [ "$rev_len" -eq 1 ]
}

@test "record_review captures result and reason" {
  record_review "$PRD_FILE" "US-001" "FAIL" "Tests not passing"

  result=$(jq -r '.reviews[0].result' "$STATE_FILE_PATH")
  reason=$(jq -r '.reviews[0].reason' "$STATE_FILE_PATH")

  [ "$result" = "FAIL" ]
  [ "$reason" = "Tests not passing" ]
}
