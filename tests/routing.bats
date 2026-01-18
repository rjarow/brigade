#!/usr/bin/env bats
# Tests for task routing and dependency logic

load test_helper

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  PRD_FILE="$TEST_TMPDIR/prd.json"
  STATE_FILE="$TEST_TMPDIR/brigade-state.json"

  create_test_prd "$PRD_FILE"
  create_test_state "$STATE_FILE"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Task retrieval tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "get_task_by_id returns correct task" {
  task=$(get_task_by_id "$PRD_FILE" "US-001")

  title=$(echo "$task" | jq -r '.title')
  [ "$title" = "First task" ]
}

@test "get_task_by_id returns null for non-existent task" {
  task=$(get_task_by_id "$PRD_FILE" "US-999")

  [ "$task" = "null" ] || [ -z "$task" ]
}

@test "get_task_count returns correct count" {
  count=$(get_task_count "$PRD_FILE")
  [ "$count" -eq 3 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Complexity routing tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "get_task_complexity returns junior" {
  complexity=$(get_task_complexity "$PRD_FILE" "US-001")
  [ "$complexity" = "junior" ]
}

@test "get_task_complexity returns senior" {
  complexity=$(get_task_complexity "$PRD_FILE" "US-002")
  [ "$complexity" = "senior" ]
}

@test "route_task routes junior to line cook" {
  worker=$(route_task "$PRD_FILE" "US-001")
  [ "$worker" = "line" ]
}

@test "route_task routes senior to sous chef" {
  worker=$(route_task "$PRD_FILE" "US-002")
  [ "$worker" = "sous" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Dependency tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "get_task_dependencies returns empty for no deps" {
  deps=$(get_task_dependencies "$PRD_FILE" "US-001")
  [ -z "$deps" ]
}

@test "get_task_dependencies returns dependency" {
  deps=$(get_task_dependencies "$PRD_FILE" "US-002")
  echo "$deps" | grep -q "US-001"
}

@test "check_dependencies_met returns true when no deps" {
  run check_dependencies_met "$PRD_FILE" "US-001"
  [ "$status" -eq 0 ]
}

@test "check_dependencies_met returns false when dep not complete" {
  run check_dependencies_met "$PRD_FILE" "US-002"
  [ "$status" -ne 0 ]
}

@test "check_dependencies_met returns true when dep complete" {
  # Mark US-001 as complete
  tmp=$(mktemp)
  jq '.tasks[0].passes = true' "$PRD_FILE" > "$tmp"
  mv "$tmp" "$PRD_FILE"

  run check_dependencies_met "$PRD_FILE" "US-002"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Ready tasks tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "get_ready_tasks returns tasks with no deps" {
  ready=$(get_ready_tasks "$PRD_FILE")

  # US-001 and US-003 have no deps, US-002 depends on US-001
  echo "$ready" | grep -q "US-001"
  echo "$ready" | grep -q "US-003"
}

@test "get_ready_tasks excludes tasks with unmet deps" {
  ready=$(get_ready_tasks "$PRD_FILE")

  # US-002 depends on US-001 which is not complete
  ! echo "$ready" | grep -q "US-002"
}

@test "get_ready_tasks includes task after dep complete" {
  # Mark US-001 as complete
  tmp=$(mktemp)
  jq '.tasks[0].passes = true' "$PRD_FILE" > "$tmp"
  mv "$tmp" "$PRD_FILE"

  ready=$(get_ready_tasks "$PRD_FILE")
  echo "$ready" | grep -q "US-002"
}

@test "get_ready_tasks excludes already complete tasks" {
  # Mark US-001 as complete
  tmp=$(mktemp)
  jq '.tasks[0].passes = true' "$PRD_FILE" > "$tmp"
  mv "$tmp" "$PRD_FILE"

  ready=$(get_ready_tasks "$PRD_FILE")
  ! echo "$ready" | grep -q "US-001"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PRD manipulation tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "mark_task_complete sets passes to true" {
  mark_task_complete "$PRD_FILE" "US-001"

  passes=$(jq -r '.tasks[] | select(.id == "US-001") | .passes' "$PRD_FILE")
  [ "$passes" = "true" ]
}

@test "mark_task_complete only affects target task" {
  mark_task_complete "$PRD_FILE" "US-001"

  passes_002=$(jq -r '.tasks[] | select(.id == "US-002") | .passes' "$PRD_FILE")
  [ "$passes_002" = "false" ]
}
