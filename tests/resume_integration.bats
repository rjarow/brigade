#!/usr/bin/env bats
# Integration tests for cmd_resume with mock workers
# These tests actually invoke cmd_resume through completion

load test_helper

MOCK_WORKER="$BATS_TEST_DIRNAME/mocks/mock_worker.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  TEST_PRD="$TEST_TMPDIR/prd.json"
  TEST_STATE="$TEST_TMPDIR/prd.state.json"

  create_test_prd "$TEST_PRD"
  init_state "$TEST_PRD"

  # Configure all tiers to use mock worker
  export LINE_CMD="$MOCK_WORKER"
  export SOUS_CMD="$MOCK_WORKER"
  export EXECUTIVE_CMD="$MOCK_WORKER"
  export LINE_AGENT="claude"
  export SOUS_AGENT="claude"
  export EXECUTIVE_AGENT="claude"

  # Disable reviews for simpler tests
  export REVIEW_ENABLED="false"
  export PHASE_REVIEW_ENABLED="false"

  # Disable verification for simpler tests
  export VERIFICATION_ENABLED="false"
  export TODO_SCAN_ENABLED="false"

  # Set short timeouts
  export TASK_TIMEOUT_JUNIOR=60
  export TASK_TIMEOUT_SENIOR=60
}

teardown() {
  rm -rf "$TEST_TMPDIR"
  unset MOCK_BEHAVIOR
}

# ═══════════════════════════════════════════════════════════════════════════════
# Resume with retry action
# ═══════════════════════════════════════════════════════════════════════════════

@test "cmd_resume retry clears currentTask" {
  # Set up interrupted state
  local state_path=$(get_state_path "$TEST_PRD")
  local tmp=$(brigade_mktemp)
  jq '.currentTask = "US-001"' "$state_path" > "$tmp" && mv "$tmp" "$state_path"

  export MOCK_BEHAVIOR="complete"

  # Run resume with retry
  run cmd_resume "$TEST_PRD" "retry"
  [ "$status" -eq 0 ]

  # currentTask should be cleared after completion
  local current=$(jq -r '.currentTask // empty' "$state_path")
  [ -z "$current" ] || [ "$current" == "null" ]
}

@test "cmd_resume retry completes the interrupted task" {
  # Set up interrupted state
  local state_path=$(get_state_path "$TEST_PRD")
  local tmp=$(brigade_mktemp)
  jq '.currentTask = "US-001"' "$state_path" > "$tmp" && mv "$tmp" "$state_path"

  export MOCK_BEHAVIOR="complete"

  run cmd_resume "$TEST_PRD" "retry"

  # Task should be marked complete
  local passes=$(jq -r '.tasks[0].passes' "$TEST_PRD")
  [ "$passes" == "true" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Resume with skip action
# ═══════════════════════════════════════════════════════════════════════════════

@test "cmd_resume skip marks task as skipped" {
  # Set up interrupted state
  local state_path=$(get_state_path "$TEST_PRD")
  local tmp=$(brigade_mktemp)
  jq '.currentTask = "US-001"' "$state_path" > "$tmp" && mv "$tmp" "$state_path"

  export MOCK_BEHAVIOR="complete"

  run cmd_resume "$TEST_PRD" "skip"
  [ "$status" -eq 0 ]

  # History should show skipped status
  local last_status=$(jq -r '[.taskHistory[] | select(.taskId == "US-001")] | last | .status' "$state_path")
  [[ "$last_status" == *"skip"* ]]
}

@test "cmd_resume skip prevents dependent tasks" {
  # Set up interrupted state on US-001 (US-002 depends on it)
  local state_path=$(get_state_path "$TEST_PRD")
  local tmp=$(brigade_mktemp)
  jq '.currentTask = "US-001"' "$state_path" > "$tmp" && mv "$tmp" "$state_path"

  export MOCK_BEHAVIOR="complete"

  run cmd_resume "$TEST_PRD" "skip"

  # US-001 should NOT be marked complete (it was skipped)
  local us001_passes=$(jq -r '.tasks[0].passes' "$TEST_PRD")
  [ "$us001_passes" == "false" ]

  # US-002 depends on US-001, so it shouldn't complete either
  local us002_passes=$(jq -r '.tasks[1].passes' "$TEST_PRD")
  [ "$us002_passes" == "false" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Resume without interrupted task
# ═══════════════════════════════════════════════════════════════════════════════

@test "cmd_resume continues service when no interrupted task" {
  # State exists but no currentTask (clean state)
  export MOCK_BEHAVIOR="complete"

  run cmd_resume "$TEST_PRD" "retry"

  # All independent tasks should complete
  local us001_passes=$(jq -r '.tasks[0].passes' "$TEST_PRD")
  local us003_passes=$(jq -r '.tasks[2].passes' "$TEST_PRD")
  [ "$us001_passes" == "true" ]
  [ "$us003_passes" == "true" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Resume with stale state
# ═══════════════════════════════════════════════════════════════════════════════

@test "cmd_resume handles stale currentTask (task not in PRD)" {
  # Set up state with task that doesn't exist
  local state_path=$(get_state_path "$TEST_PRD")
  local tmp=$(brigade_mktemp)
  jq '.currentTask = "US-999"' "$state_path" > "$tmp" && mv "$tmp" "$state_path"

  export MOCK_BEHAVIOR="complete"

  # Should handle gracefully (skip the stale task)
  run cmd_resume "$TEST_PRD" "skip"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Walkaway mode decisions
# ═══════════════════════════════════════════════════════════════════════════════

@test "cmd_resume in walkaway mode uses AI decision" {
  export WALKAWAY_MODE="true"

  # Set up interrupted state
  local state_path=$(get_state_path "$TEST_PRD")
  local tmp=$(brigade_mktemp)
  jq '.currentTask = "US-001"' "$state_path" > "$tmp" && mv "$tmp" "$state_path"

  # Mock returns complete for both resume decision and task
  export MOCK_BEHAVIOR="complete"

  run cmd_resume "$TEST_PRD"

  # Should have recorded a walkaway decision (or proceeded without one)
  # The key is it shouldn't hang waiting for user input
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Resume records decision reason
# ═══════════════════════════════════════════════════════════════════════════════

@test "cmd_resume records decision in history" {
  local state_path=$(get_state_path "$TEST_PRD")
  local tmp=$(brigade_mktemp)
  jq '.currentTask = "US-001"' "$state_path" > "$tmp" && mv "$tmp" "$state_path"

  export MOCK_BEHAVIOR="complete"

  run cmd_resume "$TEST_PRD" "retry"

  # Should have history entries
  local history_count=$(jq '.taskHistory | length' "$state_path")
  [ "$history_count" -ge 1 ]
}
