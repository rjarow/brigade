#!/usr/bin/env bats
# Tests for walkaway mode functionality

load test_helper

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  PRD_FILE="$TEST_TMPDIR/prd.json"
  STATE_FILE="$TEST_TMPDIR/prd.state.json"

  create_test_prd "$PRD_FILE"
  create_test_state "$STATE_FILE"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Walkaway config defaults
# ═══════════════════════════════════════════════════════════════════════════════

@test "WALKAWAY_MODE defaults to false" {
  [ "$WALKAWAY_MODE" == "false" ]
}

@test "WALKAWAY_MAX_SKIPS has default value" {
  [ "$WALKAWAY_MAX_SKIPS" -eq 3 ]
}

@test "WALKAWAY_CONSECUTIVE_SKIPS starts at 0" {
  [ "$WALKAWAY_CONSECUTIVE_SKIPS" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# record_walkaway_decision tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "record_walkaway_decision adds entry to state" {
  record_walkaway_decision "$PRD_FILE" "US-001" "RETRY" "Transient failure" "timeout"

  local count=$(jq '.walkawayDecisions | length' "$STATE_FILE")
  [ "$count" -eq 1 ]
}

@test "record_walkaway_decision captures decision correctly" {
  record_walkaway_decision "$PRD_FILE" "US-001" "SKIP" "Fundamental issue" "blocked"

  local decision=$(jq -r '.walkawayDecisions[0].decision' "$STATE_FILE")
  [ "$decision" == "SKIP" ]
}

@test "record_walkaway_decision captures reason correctly" {
  record_walkaway_decision "$PRD_FILE" "US-001" "RETRY" "Will try again" "failed"

  local reason=$(jq -r '.walkawayDecisions[0].reason' "$STATE_FILE")
  [ "$reason" == "Will try again" ]
}

@test "record_walkaway_decision captures failure reason" {
  record_walkaway_decision "$PRD_FILE" "US-001" "SKIP" "Too many attempts" "max_iterations"

  local failure=$(jq -r '.walkawayDecisions[0].failureReason' "$STATE_FILE")
  [ "$failure" == "max_iterations" ]
}

@test "multiple walkaway decisions append to array" {
  record_walkaway_decision "$PRD_FILE" "US-001" "RETRY" "First try" "failed"
  record_walkaway_decision "$PRD_FILE" "US-001" "SKIP" "Giving up" "max_iterations"

  local count=$(jq '.walkawayDecisions | length' "$STATE_FILE")
  [ "$count" -eq 2 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# build_walkaway_decision_prompt tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "build_walkaway_decision_prompt includes task info" {
  local prompt=$(build_walkaway_decision_prompt "$PRD_FILE" "US-001" "blocked" "3" "line")

  [[ "$prompt" == *"US-001"* ]]
  [[ "$prompt" == *"blocked"* ]]
}

@test "build_walkaway_decision_prompt includes consecutive skips" {
  WALKAWAY_CONSECUTIVE_SKIPS=2
  local prompt=$(build_walkaway_decision_prompt "$PRD_FILE" "US-001" "failed" "1" "sous")

  [[ "$prompt" == *"Consecutive skips so far: 2"* ]]
}

@test "build_walkaway_decision_prompt includes decision criteria" {
  local prompt=$(build_walkaway_decision_prompt "$PRD_FILE" "US-001" "timeout" "1" "line")

  [[ "$prompt" == *"RETRY if"* ]]
  [[ "$prompt" == *"SKIP if"* ]]
  [[ "$prompt" == *"ABORT"* ]]
}
