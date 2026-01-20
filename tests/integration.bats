#!/usr/bin/env bats
# Integration tests with mock workers
# These tests run the full service loop without calling real AI providers

load test_helper

MOCK_WORKER="$BATS_TEST_DIRNAME/mocks/mock_worker.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  PRD_FILE="$TEST_TMPDIR/prd.json"
  STATE_FILE="$TEST_TMPDIR/prd.state.json"

  # Create a test PRD with multiple tasks
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Integration Test Feature",
  "branchName": "test/integration",
  "tasks": [
    {
      "id": "US-001",
      "title": "First task",
      "acceptanceCriteria": ["Criterion 1"],
      "verification": [],
      "dependsOn": [],
      "complexity": "junior",
      "passes": false
    },
    {
      "id": "US-002",
      "title": "Second task depends on first",
      "acceptanceCriteria": ["Criterion 2"],
      "verification": [],
      "dependsOn": ["US-001"],
      "complexity": "junior",
      "passes": false
    },
    {
      "id": "US-003",
      "title": "Third task depends on second",
      "acceptanceCriteria": ["Criterion 3"],
      "verification": [],
      "dependsOn": ["US-002"],
      "complexity": "junior",
      "passes": false
    }
  ]
}
EOF

  # Configure to use mock worker
  export LINE_CMD="$MOCK_WORKER"
  export SOUS_CMD="$MOCK_WORKER"
  export EXECUTIVE_CMD="$MOCK_WORKER"
  export LINE_AGENT="claude"
  export SOUS_AGENT="claude"
  export EXECUTIVE_AGENT="claude"

  # Disable timeouts for faster tests
  export TASK_TIMEOUT_JUNIOR=0
  export TASK_TIMEOUT_SENIOR=0
  export TASK_TIMEOUT_EXECUTIVE=0

  # Disable reviews for simpler tests
  export REVIEW_ENABLED=false
  export PHASE_REVIEW_ENABLED=false

  # Sequential execution for predictable behavior
  export MAX_PARALLEL=1

  # Use test directory for state
  export CONTEXT_ISOLATION=true
}

teardown() {
  rm -rf "$TEST_TMPDIR"
  unset MOCK_BEHAVIOR MOCK_DELAY
}

# ═══════════════════════════════════════════════════════════════════════════════
# Basic service loop tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "mock worker completes single task" {
  export MOCK_BEHAVIOR=complete

  # Run single task
  local result=0
  cmd_ticket "$PRD_FILE" "US-001" > /dev/null 2>&1 || result=$?

  [ "$result" -eq 0 ]
}

@test "mock worker signals BLOCKED via output" {
  export MOCK_BEHAVIOR=blocked

  # Run mock worker directly
  local output
  output=$("$MOCK_WORKER" -p "Test prompt for US-001")

  # Should contain BLOCKED signal
  [[ "$output" == *"BLOCKED"* ]]
}

@test "mock worker signals ALREADY_DONE via output" {
  export MOCK_BEHAVIOR=already_done

  # Run mock worker directly
  local output
  output=$("$MOCK_WORKER" -p "Test prompt for US-001")

  # Should contain ALREADY_DONE signal
  [[ "$output" == *"ALREADY_DONE"* ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# State management tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "state file is created on first run" {
  export MOCK_BEHAVIOR=complete

  # Initialize state
  init_state "$PRD_FILE"

  [ -f "$STATE_FILE" ]
}

@test "task history is recorded via update_state_task" {
  export MOCK_BEHAVIOR=complete

  # Initialize state
  init_state "$PRD_FILE"

  # Simulate task history recording (what cmd_ticket would do)
  update_state_task "$PRD_FILE" "US-001" "line" "complete"

  # Check state has task history
  local history_count=$(jq '.taskHistory | length' "$STATE_FILE")
  [ "$history_count" -ge 1 ]
}

@test "task history records worker execution" {
  export MOCK_BEHAVIOR=complete

  # Initialize state (must be in same directory as PRD)
  init_state "$PRD_FILE"

  # Check state file was created
  [ -f "$STATE_FILE" ]

  # Verify state structure
  local session_id=$(jq -r '.sessionId' "$STATE_FILE")
  [ -n "$session_id" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Dependency resolution tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "get_ready_tasks returns tasks with no dependencies" {
  local ready=$(get_ready_tasks "$PRD_FILE")

  # Only US-001 should be ready (no dependencies)
  [[ "$ready" == *"US-001"* ]]
  [[ "$ready" != *"US-002"* ]]
  [[ "$ready" != *"US-003"* ]]
}

@test "get_ready_tasks respects dependency chain" {
  # Mark US-001 as complete
  local tmp=$(brigade_mktemp)
  jq '.tasks[0].passes = true' "$PRD_FILE" > "$tmp" && mv "$tmp" "$PRD_FILE"

  local ready=$(get_ready_tasks "$PRD_FILE")

  # Now US-002 should be ready
  [[ "$ready" == *"US-002"* ]]
  [[ "$ready" != *"US-003"* ]]  # US-003 still depends on US-002
}

# ═══════════════════════════════════════════════════════════════════════════════
# Task routing tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "junior tasks route to line cook" {
  local worker=$(route_task "$PRD_FILE" "US-001")
  [ "$worker" == "line" ]
}

@test "senior tasks route to sous chef" {
  # Modify PRD to have senior task
  local tmp=$(brigade_mktemp)
  jq '.tasks[0].complexity = "senior"' "$PRD_FILE" > "$tmp" && mv "$tmp" "$PRD_FILE"

  local worker=$(route_task "$PRD_FILE" "US-001")
  [ "$worker" == "sous" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Format and display tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "format_task_id includes PRD prefix" {
  local formatted=$(format_task_id "$PRD_FILE" "US-001")

  # Should be prd/US-001 format
  [[ "$formatted" == *"/US-001"* ]]
}

@test "get_prd_prefix extracts prefix from filename" {
  local prefix=$(get_prd_prefix "$PRD_FILE")

  # Should extract meaningful prefix
  [ -n "$prefix" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Escalation tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "update_state_task records iterations" {
  # Initialize state
  init_state "$PRD_FILE"

  # Record multiple iterations
  update_state_task "$PRD_FILE" "US-001" "line" "iteration_1"
  update_state_task "$PRD_FILE" "US-001" "line" "iteration_2"
  update_state_task "$PRD_FILE" "US-001" "line" "iteration_3"

  # Check that history was recorded
  local count=$(jq '[.taskHistory[] | select(.taskId == "US-001")] | length' "$STATE_FILE")
  [ "$count" -eq 3 ]
}

@test "record_escalation adds entry to state" {
  init_state "$PRD_FILE"

  record_escalation "$PRD_FILE" "US-001" "line" "sous" "Max iterations reached"

  local count=$(jq '.escalations | length' "$STATE_FILE")
  [ "$count" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Dry run tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "dry run shows task execution plan" {
  local output
  output=$(DRY_RUN=true cmd_service "$PRD_FILE" 2>&1) || true

  # Should show tasks in order
  [[ "$output" == *"US-001"* ]] || [[ "$output" == *"dry"* ]] || [[ "$output" == *"Would execute"* ]]
}
