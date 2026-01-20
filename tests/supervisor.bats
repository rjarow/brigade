#!/usr/bin/env bats
# Tests for supervisor mode functionality

load test_helper

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  PRD_FILE="$TEST_TMPDIR/prd.json"
  STATE_FILE="$TEST_TMPDIR/prd.state.json"
  EVENTS_FILE="$TEST_TMPDIR/events.jsonl"
  CMD_FILE="$TEST_TMPDIR/cmd.json"

  create_test_prd "$PRD_FILE"
  create_test_state "$STATE_FILE"

  # Set supervisor config
  SUPERVISOR_EVENTS_FILE="$EVENTS_FILE"
  SUPERVISOR_CMD_FILE="$CMD_FILE"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
  SUPERVISOR_EVENTS_FILE=""
  SUPERVISOR_CMD_FILE=""
}

# ═══════════════════════════════════════════════════════════════════════════════
# Supervisor config defaults
# ═══════════════════════════════════════════════════════════════════════════════

@test "SUPERVISOR_CMD_FILE defaults to empty" {
  # Reset to check default
  unset SUPERVISOR_CMD_FILE
  source "$BATS_TEST_DIRNAME/../brigade.sh" 2>/dev/null || true
  [ -z "$SUPERVISOR_CMD_FILE" ] || [ "$SUPERVISOR_CMD_FILE" == "" ]
}

@test "SUPERVISOR_CMD_POLL_INTERVAL has default value" {
  [ "$SUPERVISOR_CMD_POLL_INTERVAL" -eq 2 ]
}

@test "SUPERVISOR_CMD_TIMEOUT has default value" {
  [ "$SUPERVISOR_CMD_TIMEOUT" -eq 300 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# generate_decision_id tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "generate_decision_id creates unique ID" {
  local id1=$(generate_decision_id)
  local id2=$(generate_decision_id)

  # Both should start with d-
  [[ "$id1" == d-* ]]
  [[ "$id2" == d-* ]]
}

@test "generate_decision_id includes timestamp" {
  local id=$(generate_decision_id)

  # Should contain a timestamp (10 digits for epoch seconds)
  [[ "$id" =~ d-[0-9]{10} ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# emit_supervisor_event tests (decision_needed)
# ═══════════════════════════════════════════════════════════════════════════════

@test "emit_supervisor_event emits decision_needed event" {
  local context='{"failureReason":"timeout","iterations":3}'
  emit_supervisor_event "decision_needed" "d-001" "max_iterations" "US-001" "$context"

  [ -f "$EVENTS_FILE" ]
  local event=$(tail -1 "$EVENTS_FILE")
  [[ "$event" == *'"event":"decision_needed"'* ]]
  [[ "$event" == *'"id":"d-001"'* ]]
  [[ "$event" == *'"type":"max_iterations"'* ]]
}

@test "emit_supervisor_event emits decision_received event" {
  emit_supervisor_event "decision_received" "d-001" "retry"

  [ -f "$EVENTS_FILE" ]
  local event=$(tail -1 "$EVENTS_FILE")
  [[ "$event" == *'"event":"decision_received"'* ]]
  [[ "$event" == *'"action":"retry"'* ]]
}

@test "emit_supervisor_event emits scope_decision event" {
  emit_supervisor_event "scope_decision" "US-001" "Should use OAuth?" "Use JWT instead"

  [ -f "$EVENTS_FILE" ]
  local event=$(tail -1 "$EVENTS_FILE")
  [[ "$event" == *'"event":"scope_decision"'* ]]
  [[ "$event" == *'"question":"Should use OAuth?"'* ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# wait_for_decision tests (without supervisor - fallback to interactive)
# ═══════════════════════════════════════════════════════════════════════════════

@test "wait_for_decision falls back to walkaway mode when no supervisor" {
  # Disable supervisor
  SUPERVISOR_CMD_FILE=""
  WALKAWAY_MODE=true

  # Mock walkaway_decide_resume to return 0 (retry)
  walkaway_decide_resume() {
    WALKAWAY_DECISION_REASON="Test retry"
    return 0
  }

  local context='{"failureReason":"failed","iterations":1}'
  wait_for_decision "max_iterations" "US-001" "$context" "$PRD_FILE" "line"
  local result=$?

  [ "$result" -eq 0 ]
  [ "$DECISION_REASON" == "Test retry" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Scope decision tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "record_scope_decision adds entry to state" {
  record_scope_decision "$PRD_FILE" "US-001" "Use OAuth or JWT?" "Use JWT" "Simpler implementation"

  local count=$(jq '.scopeDecisions | length' "$STATE_FILE")
  [ "$count" -eq 1 ]
}

@test "record_scope_decision captures question correctly" {
  record_scope_decision "$PRD_FILE" "US-001" "Use OAuth or JWT?" "Use JWT" "Simpler"

  local question=$(jq -r '.scopeDecisions[0].question' "$STATE_FILE")
  [ "$question" == "Use OAuth or JWT?" ]
}

@test "record_scope_decision captures decision correctly" {
  record_scope_decision "$PRD_FILE" "US-001" "Use OAuth or JWT?" "Use JWT" "Simpler"

  local decision=$(jq -r '.scopeDecisions[0].decision' "$STATE_FILE")
  [ "$decision" == "Use JWT" ]
}

@test "record_scope_decision flags for human review" {
  record_scope_decision "$PRD_FILE" "US-001" "Use OAuth?" "Yes" "Standard"

  local reviewed=$(jq -r '.scopeDecisions[0].reviewedByHuman' "$STATE_FILE")
  [ "$reviewed" == "false" ]
}

@test "mark_scope_decision_reviewed updates flag" {
  record_scope_decision "$PRD_FILE" "US-001" "Use OAuth?" "Yes" "Standard"
  mark_scope_decision_reviewed "$PRD_FILE" 0

  local reviewed=$(jq -r '.scopeDecisions[0].reviewedByHuman' "$STATE_FILE")
  [ "$reviewed" == "true" ]
}

@test "get_pending_scope_decisions returns unreviewed decisions" {
  record_scope_decision "$PRD_FILE" "US-001" "Question 1" "Answer 1" "Reason 1"
  record_scope_decision "$PRD_FILE" "US-002" "Question 2" "Answer 2" "Reason 2"
  mark_scope_decision_reviewed "$PRD_FILE" 0

  local pending=$(get_pending_scope_decisions "$PRD_FILE")
  local count=$(echo "$pending" | jq 'length')
  [ "$count" -eq 1 ]

  local remaining=$(echo "$pending" | jq -r '.[0].question')
  [ "$remaining" == "Question 2" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# build_scope_decision_prompt tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "build_scope_decision_prompt includes task info" {
  local prompt=$(build_scope_decision_prompt "$PRD_FILE" "US-001" "Use OAuth or JWT?" "")

  [[ "$prompt" == *"US-001"* ]]
  [[ "$prompt" == *"SCOPE QUESTION"* ]]
  [[ "$prompt" == *"Use OAuth or JWT?"* ]]
}

@test "build_scope_decision_prompt includes feature name" {
  local prompt=$(build_scope_decision_prompt "$PRD_FILE" "US-001" "Question" "")

  [[ "$prompt" == *"Test Feature"* ]]
}

@test "build_scope_decision_prompt includes walkaway mode notice" {
  local prompt=$(build_scope_decision_prompt "$PRD_FILE" "US-001" "Question" "")

  [[ "$prompt" == *"WALKAWAY MODE ACTIVE"* ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# extract_scope_questions_from_output tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "extract_scope_questions_from_output returns 0 when no questions" {
  local output_file="$TEST_TMPDIR/output.txt"
  echo "Some output without scope questions" > "$output_file"

  extract_scope_questions_from_output "$output_file" "$PRD_FILE" "US-001" "line"
  local result=$?

  [ "$result" -eq 0 ]
}

@test "extract_scope_questions_from_output detects scope question tag" {
  local output_file="$TEST_TMPDIR/output.txt"
  echo "Working on task... <scope-question>Should I use OAuth?</scope-question>" > "$output_file"

  # Without walkaway or supervisor, should return 1 (needs human)
  WALKAWAY_MODE=false
  SUPERVISOR_CMD_FILE=""

  # Capture return code without letting bats fail on non-zero
  local result=0
  extract_scope_questions_from_output "$output_file" "$PRD_FILE" "US-001" "line" || result=$?

  [ "$result" -eq 1 ]
}

@test "WALKAWAY_SCOPE_DECISIONS defaults to true" {
  [ "$WALKAWAY_SCOPE_DECISIONS" == "true" ]
}
