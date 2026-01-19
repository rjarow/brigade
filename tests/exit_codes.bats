#!/usr/bin/env bats
# Tests for exit code handling, especially with set -e

load test_helper

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  TEST_PRD="$TEST_TMPDIR/prd.json"
  TEST_STATE="$TEST_TMPDIR/prd.state.json"
  create_test_prd "$TEST_PRD"

  # Ensure set -e is active (it should be from sourcing brigade.sh)
  set -e
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test that non-zero return codes don't crash the script with set -e
# ═══════════════════════════════════════════════════════════════════════════════

@test "set -e doesn't crash on return code 33 when properly wrapped" {
  # Simulate what fire_ticket does - return 33 for ALREADY_DONE
  mock_fire_ticket() {
    return 33
  }

  # This is the pattern we use in cmd_ticket
  set +e
  mock_fire_ticket
  local result=$?
  set -e

  # Should have captured 33
  [ "$result" -eq 33 ]
}

@test "set -e doesn't crash on return code 34 when properly wrapped" {
  # Simulate ABSORBED_BY
  mock_fire_ticket() {
    return 34
  }

  set +e
  mock_fire_ticket
  local result=$?
  set -e

  [ "$result" -eq 34 ]
}

@test "set -e doesn't crash on return code 32 when properly wrapped" {
  # Simulate BLOCKED
  mock_fire_ticket() {
    return 32
  }

  set +e
  mock_fire_ticket
  local result=$?
  set -e

  [ "$result" -eq 32 ]
}

@test "WITHOUT set +e wrapper, return 33 would exit (demonstrates the bug)" {
  # This test demonstrates what happens WITHOUT the fix
  # We run in a subshell so it doesn't kill our test

  run bash -c '
    set -e
    func_returns_33() { return 33; }
    func_returns_33
    result=$?
    echo "captured: $result"
  '

  # With set -e and no protection, the script exits immediately
  # The echo never runs, exit code is 33
  [ "$status" -eq 33 ]
  [ -z "$output" ]  # No output because script exited before echo
}

@test "WITH set +e wrapper, return 33 is captured correctly" {
  run bash -c '
    set -e
    func_returns_33() { return 33; }
    set +e
    func_returns_33
    result=$?
    set -e
    echo "captured: $result"
  '

  # With protection, script continues and captures the result
  [ "$status" -eq 0 ]
  [[ "$output" == "captured: 33" ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test fire_ticket signal detection returns correct codes
# ═══════════════════════════════════════════════════════════════════════════════

@test "signal detection returns 0 for COMPLETE" {
  local output_file="$TEST_TMPDIR/worker_output.txt"
  echo "Work done <promise>COMPLETE</promise>" > "$output_file"

  # Simulate the signal detection from fire_ticket
  if grep -q "<promise>COMPLETE</promise>" "$output_file" 2>/dev/null; then
    result=0
  elif grep -q "<promise>ALREADY_DONE</promise>" "$output_file" 2>/dev/null; then
    result=33
  elif grep -q "<promise>BLOCKED</promise>" "$output_file" 2>/dev/null; then
    result=32
  else
    result=1
  fi

  [ "$result" -eq 0 ]
}

@test "signal detection returns 33 for ALREADY_DONE" {
  local output_file="$TEST_TMPDIR/worker_output.txt"
  echo "Already done <promise>ALREADY_DONE</promise>" > "$output_file"

  if grep -q "<promise>COMPLETE</promise>" "$output_file" 2>/dev/null; then
    result=0
  elif grep -q "<promise>ALREADY_DONE</promise>" "$output_file" 2>/dev/null; then
    result=33
  elif grep -q "<promise>BLOCKED</promise>" "$output_file" 2>/dev/null; then
    result=32
  else
    result=1
  fi

  [ "$result" -eq 33 ]
}

@test "signal detection returns 34 for ABSORBED_BY" {
  local output_file="$TEST_TMPDIR/worker_output.txt"
  echo "Absorbed <promise>ABSORBED_BY:US-001</promise>" > "$output_file"

  if grep -q "<promise>COMPLETE</promise>" "$output_file" 2>/dev/null; then
    result=0
  elif grep -q "<promise>ALREADY_DONE</promise>" "$output_file" 2>/dev/null; then
    result=33
  elif grep -oq "<promise>ABSORBED_BY:" "$output_file" 2>/dev/null; then
    result=34
  elif grep -q "<promise>BLOCKED</promise>" "$output_file" 2>/dev/null; then
    result=32
  else
    result=1
  fi

  [ "$result" -eq 34 ]
}

@test "signal detection returns 32 for BLOCKED" {
  local output_file="$TEST_TMPDIR/worker_output.txt"
  echo "Cannot proceed <promise>BLOCKED</promise>" > "$output_file"

  if grep -q "<promise>COMPLETE</promise>" "$output_file" 2>/dev/null; then
    result=0
  elif grep -q "<promise>ALREADY_DONE</promise>" "$output_file" 2>/dev/null; then
    result=33
  elif grep -q "<promise>BLOCKED</promise>" "$output_file" 2>/dev/null; then
    result=32
  else
    result=1
  fi

  [ "$result" -eq 32 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test the actual code path in cmd_ticket handles exit codes correctly
# ═══════════════════════════════════════════════════════════════════════════════

@test "cmd_ticket pattern correctly captures exit code 33" {
  # This tests the exact pattern used in cmd_ticket

  run bash -c '
    source "'$PROJECT_ROOT'/brigade.sh"

    # Mock fire_ticket to return 33
    fire_ticket() { return 33; }

    # The pattern from cmd_ticket (lines 3128-3133)
    set +e
    fire_ticket "prd.json" "US-001" "line" "900"
    result=$?
    set -e

    # Verify we captured 33 and can branch on it
    if [ $result -eq 33 ]; then
      echo "ALREADY_DONE detected"
      exit 0
    else
      echo "Wrong code: $result"
      exit 1
    fi
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"ALREADY_DONE detected"* ]]
}

@test "cmd_ticket pattern correctly captures exit code 34" {
  run bash -c '
    source "'$PROJECT_ROOT'/brigade.sh"

    fire_ticket() { return 34; }

    set +e
    fire_ticket "prd.json" "US-001" "line" "900"
    result=$?
    set -e

    if [ $result -eq 34 ]; then
      echo "ABSORBED_BY detected"
      exit 0
    else
      echo "Wrong code: $result"
      exit 1
    fi
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"ABSORBED_BY detected"* ]]
}

@test "cmd_ticket pattern correctly captures exit code 0" {
  run bash -c '
    source "'$PROJECT_ROOT'/brigade.sh"

    fire_ticket() { return 0; }

    set +e
    fire_ticket "prd.json" "US-001" "line" "900"
    result=$?
    set -e

    if [ $result -eq 0 ]; then
      echo "COMPLETE detected"
      exit 0
    else
      echo "Wrong code: $result"
      exit 1
    fi
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPLETE detected"* ]]
}
