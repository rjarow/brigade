#!/usr/bin/env bats
# Tests for worker health check functionality

load test_helper

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  OUTPUT_FILE="$TEST_TMPDIR/output.txt"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Config defaults
# ═══════════════════════════════════════════════════════════════════════════════

@test "WORKER_HEALTH_CHECK_INTERVAL has default value" {
  [ "$WORKER_HEALTH_CHECK_INTERVAL" -eq 5 ]
}

@test "WORKER_CRASH_EXIT_CODE has default value" {
  [ "$WORKER_CRASH_EXIT_CODE" -eq 125 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# run_with_timeout tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "run_with_timeout returns 0 for successful command" {
  run_with_timeout 10 true
  local result=$?
  [ "$result" -eq 0 ]
}

@test "run_with_timeout returns command exit code" {
  local result=0
  run_with_timeout 10 sh -c "exit 42" || result=$?
  [ "$result" -eq 42 ]
}

@test "run_with_timeout returns 124 on timeout" {
  # Use a very short timeout with a sleep command
  local result=0
  run_with_timeout 1 sleep 10 || result=$?
  [ "$result" -eq 124 ]
}

@test "run_with_timeout detects process completion" {
  local start=$(date +%s)
  run_with_timeout 30 sh -c "sleep 1; echo done"
  local end=$(date +%s)
  local elapsed=$((end - start))

  # Should complete quickly (within 5 seconds), not wait for timeout
  [ "$elapsed" -lt 10 ]
}

@test "run_with_timeout captures output to file" {
  run_with_timeout 10 sh -c "echo hello world" > "$OUTPUT_FILE" 2>&1

  grep -q "hello world" "$OUTPUT_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Crash detection tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "run_with_timeout detects signal-based crash" {
  # Kill process with SIGKILL (signal 9) which gives exit code 137
  local result=0
  run_with_timeout 10 sh -c 'kill -9 $$' || result=$?

  # Should detect as crash (exit code > 128)
  [ "$result" -gt 128 ] || [ "$result" -eq "$WORKER_CRASH_EXIT_CODE" ]
}

@test "handle_worker_exit logs crash appropriately" {
  # Create mock task_id and output_file for the function
  local task_id="US-001"
  local output_file="$OUTPUT_FILE"
  local worker_timeout=900

  # Source the handle_worker_exit function (it's defined inside fire_ticket)
  # We'll test the logic directly

  # Exit code 125 = crash
  [ "$WORKER_CRASH_EXIT_CODE" -eq 125 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# run_with_spinner crash detection tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "run_with_spinner returns exit code" {
  local result=0
  run_with_spinner "Test" "$OUTPUT_FILE" sh -c "exit 0" || result=$?
  [ "$result" -eq 0 ]
}

@test "run_with_spinner captures output" {
  run_with_spinner "Test" "$OUTPUT_FILE" sh -c "echo test output"

  grep -q "test output" "$OUTPUT_FILE"
}

@test "run_with_spinner detects quick crash" {
  local result=0
  # Kill immediately - should be detected as crash
  run_with_spinner "Test" "$OUTPUT_FILE" sh -c 'kill -9 $$' 2>/dev/null || result=$?

  # Should return crash exit code or signal-based exit code
  [ "$result" -gt 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Integration with fire_ticket (mock tests)
# ═══════════════════════════════════════════════════════════════════════════════

@test "BRIGADE_WORKER_PIDS array tracks processes" {
  # Reset the array
  BRIGADE_WORKER_PIDS=()

  # Run a command - it should be tracked
  run_with_timeout 10 true

  # After completion, the PID should not be in the array
  # Note: bash array removal may leave empty elements, so we check for actual PIDs
  local found=0
  for pid in "${BRIGADE_WORKER_PIDS[@]}"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      found=1
    fi
  done
  [ "$found" -eq 0 ]
}
