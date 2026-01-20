#!/usr/bin/env bats
# Tests for verification type classification and coverage

load test_helper

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  PRD_FILE="$TEST_TMPDIR/prd.json"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ═══════════════════════════════════════════════════════════════════════════════
# classify_task_type tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "classify_task_type identifies 'add' as create" {
  result=$(classify_task_type "Add user authentication")
  [ "$result" = "create" ]
}

@test "classify_task_type identifies 'create' as create" {
  result=$(classify_task_type "Create login endpoint")
  [ "$result" = "create" ]
}

@test "classify_task_type identifies 'implement' as create" {
  result=$(classify_task_type "Implement password hashing")
  [ "$result" = "create" ]
}

@test "classify_task_type identifies 'connect' as integrate" {
  result=$(classify_task_type "Connect search view to results")
  [ "$result" = "integrate" ]
}

@test "classify_task_type identifies 'integrate' as integrate" {
  result=$(classify_task_type "Integrate auth with API gateway")
  [ "$result" = "integrate" ]
}

@test "classify_task_type identifies 'wire' as integrate" {
  result=$(classify_task_type "Wire up download button")
  [ "$result" = "integrate" ]
}

@test "classify_task_type identifies 'hook up' as integrate" {
  result=$(classify_task_type "Hook up event handlers")
  [ "$result" = "integrate" ]
}

@test "classify_task_type identifies 'flow' as feature" {
  result=$(classify_task_type "User login flow")
  [ "$result" = "feature" ]
}

@test "classify_task_type identifies 'workflow' as feature" {
  result=$(classify_task_type "Complete checkout workflow")
  [ "$result" = "feature" ]
}

@test "classify_task_type identifies 'user can' as feature" {
  result=$(classify_task_type "User can download tracks")
  [ "$result" = "feature" ]
}

@test "classify_task_type returns unknown for generic title" {
  result=$(classify_task_type "Fix bug in parser")
  [ "$result" = "unknown" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# get_verification_types tests (object format)
# ═══════════════════════════════════════════════════════════════════════════════

@test "get_verification_types extracts types from object format" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Test",
  "tasks": [{
    "id": "US-001",
    "title": "Test task",
    "verification": [
      {"type": "pattern", "cmd": "grep -q 'foo' file.go"},
      {"type": "unit", "cmd": "go test ./..."},
      {"type": "integration", "cmd": "go test -run TestFlow ./..."}
    ]
  }]
}
EOF

  result=$(get_verification_types "$PRD_FILE" "US-001")
  [[ "$result" == *"pattern"* ]]
  [[ "$result" == *"unit"* ]]
  [[ "$result" == *"integration"* ]]
}

@test "get_verification_types infers types from string format" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Test",
  "tasks": [{
    "id": "US-001",
    "title": "Test task",
    "verification": [
      "grep -q 'foo' file.go",
      "go test ./internal/..."
    ]
  }]
}
EOF

  result=$(get_verification_types "$PRD_FILE" "US-001")
  [[ "$result" == *"pattern"* ]]
  [[ "$result" == *"unit"* ]]
}

@test "get_verification_types returns empty for no verification" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Test",
  "tasks": [{
    "id": "US-001",
    "title": "Test task"
  }]
}
EOF

  result=$(get_verification_types "$PRD_FILE" "US-001")
  [ -z "$result" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# check_verification_coverage tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "check_verification_coverage passes for create task with unit tests" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Test",
  "tasks": [{
    "id": "US-001",
    "title": "Add user model",
    "verification": [
      {"type": "unit", "cmd": "go test ./..."}
    ]
  }]
}
EOF

  run check_verification_coverage "$PRD_FILE" "US-001"
  [ "$status" -eq 0 ]
}

@test "check_verification_coverage warns for integrate task with only unit tests" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Test",
  "tasks": [{
    "id": "US-001",
    "title": "Connect auth to gateway",
    "verification": [
      {"type": "unit", "cmd": "go test ./..."}
    ]
  }]
}
EOF

  # Capture return code without failing due to set -e
  local result=0
  check_verification_coverage "$PRD_FILE" "US-001" || result=$?
  [ "$result" -eq 1 ]
  [[ "$VERIFICATION_COVERAGE_WARNING" == *"integration"* ]]
}

@test "check_verification_coverage passes for integrate task with integration tests" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Test",
  "tasks": [{
    "id": "US-001",
    "title": "Wire up event handlers",
    "verification": [
      {"type": "integration", "cmd": "go test -run TestIntegration ./..."}
    ]
  }]
}
EOF

  run check_verification_coverage "$PRD_FILE" "US-001"
  [ "$status" -eq 0 ]
}

@test "check_verification_coverage warns for feature task without smoke/integration" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Test",
  "tasks": [{
    "id": "US-001",
    "title": "User can download tracks",
    "verification": [
      {"type": "pattern", "cmd": "grep -q 'download' file.go"}
    ]
  }]
}
EOF

  # Capture return code without failing due to set -e
  local result=0
  check_verification_coverage "$PRD_FILE" "US-001" || result=$?
  [ "$result" -eq 1 ]
  [[ "$VERIFICATION_COVERAGE_WARNING" == *"smoke or integration"* ]]
}

@test "check_verification_coverage passes for feature task with smoke test" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Test",
  "tasks": [{
    "id": "US-001",
    "title": "User login flow",
    "verification": [
      {"type": "smoke", "cmd": "./app --help"}
    ]
  }]
}
EOF

  run check_verification_coverage "$PRD_FILE" "US-001"
  [ "$status" -eq 0 ]
}

@test "check_verification_coverage skips tasks without verification" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Test",
  "tasks": [{
    "id": "US-001",
    "title": "Connect everything"
  }]
}
EOF

  run check_verification_coverage "$PRD_FILE" "US-001"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# get_verification_commands tests (backward compatibility)
# ═══════════════════════════════════════════════════════════════════════════════

@test "get_verification_commands extracts cmds from string format" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Test",
  "tasks": [{
    "id": "US-001",
    "title": "Test task",
    "verification": ["grep -q 'foo' file.go", "go test ./..."]
  }]
}
EOF

  result=$(get_verification_commands "$PRD_FILE" "US-001")
  [[ "$result" == *"grep -q 'foo' file.go"* ]]
  [[ "$result" == *"go test ./..."* ]]
}

@test "get_verification_commands extracts cmds from object format" {
  cat > "$PRD_FILE" <<'EOF'
{
  "featureName": "Test",
  "tasks": [{
    "id": "US-001",
    "title": "Test task",
    "verification": [
      {"type": "pattern", "cmd": "grep -q 'foo' file.go"},
      {"type": "unit", "cmd": "go test ./..."}
    ]
  }]
}
EOF

  result=$(get_verification_commands "$PRD_FILE" "US-001")
  [[ "$result" == *"grep -q 'foo' file.go"* ]]
  [[ "$result" == *"go test ./..."* ]]
}
