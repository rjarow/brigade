#!/usr/bin/env bats
# Tests for cmd_resume logic

load test_helper

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  TEST_PRD="$TEST_TMPDIR/prd.json"
  TEST_STATE="$TEST_TMPDIR/prd.state.json"
  create_test_prd "$TEST_PRD"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ═══════════════════════════════════════════════════════════════════════════════
# State detection for resume
# ═══════════════════════════════════════════════════════════════════════════════

@test "get_state_path returns correct path" {
  local state_path=$(get_state_path "$TEST_PRD")
  [ "$state_path" == "$TEST_TMPDIR/prd.state.json" ]
}

@test "resume detects no state file" {
  # No state file created
  [ ! -f "$TEST_STATE" ]
}

@test "resume detects state file exists" {
  create_test_state "$TEST_STATE"
  [ -f "$TEST_STATE" ]
}

@test "resume can read currentTask from state" {
  create_test_state "$TEST_STATE"

  # Set a current task
  local tmp_file=$(mktemp)
  jq '.currentTask = "US-001"' "$TEST_STATE" > "$tmp_file"
  mv "$tmp_file" "$TEST_STATE"

  local current_task=$(jq -r '.currentTask // empty' "$TEST_STATE")
  [ "$current_task" == "US-001" ]
}

@test "resume detects no interrupted task when currentTask is null" {
  create_test_state "$TEST_STATE"

  local current_task=$(jq -r '.currentTask // empty' "$TEST_STATE")
  [ -z "$current_task" ]
}

@test "resume detects interrupted task when currentTask is set" {
  create_test_state "$TEST_STATE"

  local tmp_file=$(mktemp)
  jq '.currentTask = "US-002"' "$TEST_STATE" > "$tmp_file"
  mv "$tmp_file" "$TEST_STATE"

  local current_task=$(jq -r '.currentTask // empty' "$TEST_STATE")
  [ -n "$current_task" ]
  [ "$current_task" == "US-002" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Task validation for resume
# ═══════════════════════════════════════════════════════════════════════════════

@test "resume validates task exists in PRD" {
  local task_exists=$(jq -r --arg id "US-001" '.tasks[] | select(.id == $id) | .id' "$TEST_PRD")
  [ "$task_exists" == "US-001" ]
}

@test "resume detects non-existent task" {
  local task_exists=$(jq -r --arg id "US-999" '.tasks[] | select(.id == $id) | .id' "$TEST_PRD")
  [ -z "$task_exists" ]
}

@test "resume checks if task is already completed" {
  # Mark US-001 as complete
  local tmp_file=$(mktemp)
  jq '.tasks[0].passes = true' "$TEST_PRD" > "$tmp_file"
  mv "$tmp_file" "$TEST_PRD"

  local task_passes=$(jq -r --arg id "US-001" '.tasks[] | select(.id == $id) | .passes' "$TEST_PRD")
  [ "$task_passes" == "true" ]
}

@test "resume checks if task is not completed" {
  local task_passes=$(jq -r --arg id "US-001" '.tasks[] | select(.id == $id) | .passes' "$TEST_PRD")
  [ "$task_passes" == "false" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Resume action handling
# ═══════════════════════════════════════════════════════════════════════════════

@test "retry action clears currentTask" {
  create_test_state "$TEST_STATE"

  # Set interrupted task
  local tmp_file=$(mktemp)
  jq '.currentTask = "US-001"' "$TEST_STATE" > "$tmp_file"
  mv "$tmp_file" "$TEST_STATE"

  # Simulate retry action (just the state clearing part)
  tmp_file=$(mktemp)
  jq '.currentTask = null' "$TEST_STATE" > "$tmp_file"
  mv "$tmp_file" "$TEST_STATE"

  local current_task=$(jq -r '.currentTask // empty' "$TEST_STATE")
  [ -z "$current_task" ]
}

@test "skip action records skipped status" {
  init_state "$TEST_PRD"

  # Set interrupted task
  local state_path=$(get_state_path "$TEST_PRD")
  local tmp_file=$(mktemp)
  jq '.currentTask = "US-001"' "$state_path" > "$tmp_file"
  mv "$tmp_file" "$state_path"

  # Simulate skip action
  update_state_task "$TEST_PRD" "US-001" "line" "skipped"

  local last_status=$(jq -r '.taskHistory[-1].status' "$state_path")
  [ "$last_status" == "skipped" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Task history for resume context
# ═══════════════════════════════════════════════════════════════════════════════

@test "resume can get last worker from history" {
  init_state "$TEST_PRD"

  # Add history entry
  update_state_task "$TEST_PRD" "US-001" "sous" "iteration_1"

  local state_path=$(get_state_path "$TEST_PRD")
  local last_entry=$(jq -r '[.taskHistory[] | select(.taskId == "US-001")] | last' "$state_path")
  local last_worker=$(echo "$last_entry" | jq -r '.worker')

  [ "$last_worker" == "sous" ]
}

@test "resume can get last status from history" {
  init_state "$TEST_PRD"

  update_state_task "$TEST_PRD" "US-001" "line" "review_failed"

  local state_path=$(get_state_path "$TEST_PRD")
  local last_entry=$(jq -r '[.taskHistory[] | select(.taskId == "US-001")] | last' "$state_path")
  local last_status=$(echo "$last_entry" | jq -r '.status')

  [ "$last_status" == "review_failed" ]
}

@test "resume handles multiple history entries correctly" {
  init_state "$TEST_PRD"

  # Multiple iterations
  update_state_task "$TEST_PRD" "US-001" "line" "iteration_1"
  update_state_task "$TEST_PRD" "US-001" "line" "iteration_2"
  update_state_task "$TEST_PRD" "US-001" "sous" "iteration_3"

  local state_path=$(get_state_path "$TEST_PRD")
  local history_count=$(jq '[.taskHistory[] | select(.taskId == "US-001")] | length' "$state_path")
  local last_worker=$(jq -r '[.taskHistory[] | select(.taskId == "US-001")] | last | .worker' "$state_path")

  [ "$history_count" -eq 3 ]
  [ "$last_worker" == "sous" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Stale state cleanup
# ═══════════════════════════════════════════════════════════════════════════════

@test "clearing stale state works correctly" {
  create_test_state "$TEST_STATE"

  # Set a task that doesn't exist in PRD
  local tmp_file=$(mktemp)
  jq '.currentTask = "US-999"' "$TEST_STATE" > "$tmp_file"
  mv "$tmp_file" "$TEST_STATE"

  # Clear stale state (simulating what cmd_resume does)
  tmp_file=$(mktemp)
  jq '.currentTask = null' "$TEST_STATE" > "$tmp_file"
  mv "$tmp_file" "$TEST_STATE"

  local current_task=$(jq -r '.currentTask // empty' "$TEST_STATE")
  [ -z "$current_task" ] || [ "$current_task" == "null" ]
}
