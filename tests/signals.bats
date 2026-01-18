#!/usr/bin/env bats
# Tests for worker signal detection

load test_helper

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  OUTPUT_FILE="$TEST_TMPDIR/output.txt"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ═══════════════════════════════════════════════════════════════════════════════
# COMPLETE signal tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "detects COMPLETE signal" {
  echo "Task completed successfully" > "$OUTPUT_FILE"
  echo "<promise>COMPLETE</promise>" >> "$OUTPUT_FILE"

  run grep -q "<promise>COMPLETE</promise>" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
}

@test "COMPLETE signal with surrounding text" {
  echo "Done with work <promise>COMPLETE</promise> all good" > "$OUTPUT_FILE"

  run grep -q "<promise>COMPLETE</promise>" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# BLOCKED signal tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "detects BLOCKED signal" {
  echo "Cannot proceed" > "$OUTPUT_FILE"
  echo "<promise>BLOCKED</promise>" >> "$OUTPUT_FILE"

  run grep -q "<promise>BLOCKED</promise>" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# ALREADY_DONE signal tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "detects ALREADY_DONE signal" {
  echo "This was already completed by US-001" > "$OUTPUT_FILE"
  echo "<promise>ALREADY_DONE</promise>" >> "$OUTPUT_FILE"

  run grep -q "<promise>ALREADY_DONE</promise>" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# ABSORBED_BY signal tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "detects ABSORBED_BY signal" {
  echo "Work absorbed by prior task" > "$OUTPUT_FILE"
  echo "<promise>ABSORBED_BY:US-001</promise>" >> "$OUTPUT_FILE"

  run grep -oq "<promise>ABSORBED_BY:" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
}

@test "extracts task ID from ABSORBED_BY signal" {
  echo "<promise>ABSORBED_BY:US-042</promise>" > "$OUTPUT_FILE"

  absorbed_by=$(grep -o "<promise>ABSORBED_BY:[^<]*</promise>" "$OUTPUT_FILE" | sed 's/<promise>ABSORBED_BY://;s/<\/promise>//')
  [ "$absorbed_by" = "US-042" ]
}

@test "ABSORBED_BY with complex task ID" {
  echo "<promise>ABSORBED_BY:TASK-123-ABC</promise>" > "$OUTPUT_FILE"

  absorbed_by=$(grep -o "<promise>ABSORBED_BY:[^<]*</promise>" "$OUTPUT_FILE" | sed 's/<promise>ABSORBED_BY://;s/<\/promise>//')
  [ "$absorbed_by" = "TASK-123-ABC" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Learning extraction tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "detects learning tag" {
  echo "Found something useful" > "$OUTPUT_FILE"
  echo "<learning>Always use unique temp paths in tests</learning>" >> "$OUTPUT_FILE"

  run grep -q "<learning>" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
}

@test "extracts learning content" {
  echo "<learning>Important pattern here</learning>" > "$OUTPUT_FILE"

  learning=$(sed -n 's/.*<learning>\(.*\)<\/learning>.*/\1/p' "$OUTPUT_FILE")
  [ "$learning" = "Important pattern here" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Signal priority tests (what happens with multiple signals)
# ═══════════════════════════════════════════════════════════════════════════════

@test "COMPLETE takes precedence when checking order" {
  # In fire_ticket, COMPLETE is checked first
  echo "<promise>COMPLETE</promise>" > "$OUTPUT_FILE"
  echo "<promise>BLOCKED</promise>" >> "$OUTPUT_FILE"

  # COMPLETE should be detected
  run grep -q "<promise>COMPLETE</promise>" "$OUTPUT_FILE"
  [ "$status" -eq 0 ]
}

@test "no signal detected when output is empty" {
  echo "" > "$OUTPUT_FILE"

  run grep -q "<promise>COMPLETE</promise>" "$OUTPUT_FILE"
  [ "$status" -ne 0 ]

  run grep -q "<promise>BLOCKED</promise>" "$OUTPUT_FILE"
  [ "$status" -ne 0 ]
}

@test "no signal detected with partial tag" {
  echo "<promise>COMPLE" > "$OUTPUT_FILE"

  run grep -q "<promise>COMPLETE</promise>" "$OUTPUT_FILE"
  [ "$status" -ne 0 ]
}
