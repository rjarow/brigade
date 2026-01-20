#!/usr/bin/env bats
# Tests for the module system

load test_helper

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  TEST_MODULE_DIR="$TEST_TMPDIR/modules"
  mkdir -p "$TEST_MODULE_DIR"

  # Reset module state
  MODULES=""
  BRIGADE_LOADED_MODULES=""

  # Override SCRIPT_DIR to use test module directory
  SCRIPT_DIR="$TEST_TMPDIR"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ═══════════════════════════════════════════════════════════════════════════════
# load_modules tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "load_modules: skips when MODULES empty" {
  MODULES=""
  load_modules true
  [ -z "$BRIGADE_LOADED_MODULES" ]
}

@test "load_modules: loads valid module" {
  cat > "$TEST_MODULE_DIR/test.sh" <<'EOF'
module_test_events() { echo "task_complete"; }
module_test_on_task_complete() { echo "called"; }
EOF

  MODULES="test"
  load_modules true

  [[ "$BRIGADE_LOADED_MODULES" == *"test"* ]]
}

@test "load_modules: warns on missing module" {
  MODULES="nonexistent"

  run load_modules false
  [[ "$output" == *"not found"* ]]
  [ -z "$BRIGADE_LOADED_MODULES" ]
}

@test "load_modules: skips module without events function" {
  cat > "$TEST_MODULE_DIR/bad.sh" <<'EOF'
# Missing module_bad_events function
module_bad_init() { return 0; }
EOF

  MODULES="bad"
  run load_modules false

  [[ "$output" == *"missing"* ]]
  [ -z "$BRIGADE_LOADED_MODULES" ]
}

@test "load_modules: skips module with failed init" {
  cat > "$TEST_MODULE_DIR/failing.sh" <<'EOF'
module_failing_events() { echo "task_complete"; }
module_failing_init() { return 1; }
EOF

  MODULES="failing"
  run load_modules false

  [[ "$output" == *"init failed"* ]]
  [ -z "$BRIGADE_LOADED_MODULES" ]
}

@test "load_modules: loads multiple modules" {
  cat > "$TEST_MODULE_DIR/one.sh" <<'EOF'
module_one_events() { echo "task_complete"; }
EOF
  cat > "$TEST_MODULE_DIR/two.sh" <<'EOF'
module_two_events() { echo "service_complete"; }
EOF

  MODULES="one,two"
  load_modules true

  [[ "$BRIGADE_LOADED_MODULES" == *"one"* ]]
  [[ "$BRIGADE_LOADED_MODULES" == *"two"* ]]
}

@test "load_modules: trims whitespace in module names" {
  cat > "$TEST_MODULE_DIR/test.sh" <<'EOF'
module_test_events() { echo "task_complete"; }
EOF

  MODULES=" test , "
  load_modules true

  [[ "$BRIGADE_LOADED_MODULES" == *"test"* ]]
}

@test "load_modules: caches module events" {
  cat > "$TEST_MODULE_DIR/test.sh" <<'EOF'
module_test_events() { echo "task_complete service_complete"; }
EOF

  MODULES="test"
  load_modules true

  [ "$BRIGADE_MODULE_TEST_EVENTS" = "task_complete service_complete" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# module_registered_for_event tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "module_registered_for_event: returns true for registered event" {
  BRIGADE_MODULE_TEST_EVENTS="task_complete service_complete"

  module_registered_for_event "test" "task_complete"
}

@test "module_registered_for_event: returns false for unregistered event" {
  BRIGADE_MODULE_TEST_EVENTS="service_complete"

  ! module_registered_for_event "test" "task_complete"
}

@test "module_registered_for_event: handles edge cases (partial match)" {
  BRIGADE_MODULE_TEST_EVENTS="task_complete"

  # Should not match partial event names
  ! module_registered_for_event "test" "task"
}

# ═══════════════════════════════════════════════════════════════════════════════
# dispatch_to_modules tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "dispatch_to_modules: skips when no modules loaded" {
  BRIGADE_LOADED_MODULES=""

  # Should not error
  dispatch_to_modules "task_complete" "US-001" "line" "120"
}

@test "dispatch_to_modules: calls registered handler" {
  local marker="$TEST_TMPDIR/called"

  cat > "$TEST_MODULE_DIR/marker.sh" <<EOF
module_marker_events() { echo "task_complete"; }
module_marker_on_task_complete() { touch "$marker"; }
EOF

  MODULES="marker"
  load_modules true

  dispatch_to_modules "task_complete" "US-001" "line" "120"
  sleep 0.5  # Give async handler time to run

  [ -f "$marker" ]
}

@test "dispatch_to_modules: ignores unregistered events" {
  local marker="$TEST_TMPDIR/called"

  cat > "$TEST_MODULE_DIR/selective.sh" <<EOF
module_selective_events() { echo "service_complete"; }
module_selective_on_task_complete() { touch "$marker"; }
EOF

  MODULES="selective"
  load_modules true

  dispatch_to_modules "task_complete" "US-001" "line" "120"
  sleep 0.5

  [ ! -f "$marker" ]
}

@test "dispatch_to_modules: passes arguments to handler" {
  local output_file="$TEST_TMPDIR/args"

  cat > "$TEST_MODULE_DIR/args.sh" <<EOF
module_args_events() { echo "task_complete"; }
module_args_on_task_complete() { echo "\$1 \$2 \$3" > "$output_file"; }
EOF

  MODULES="args"
  load_modules true

  dispatch_to_modules "task_complete" "US-001" "line" "120"
  sleep 0.5

  [ -f "$output_file" ]
  grep -q "US-001 line 120" "$output_file"
}

# ═══════════════════════════════════════════════════════════════════════════════
# cleanup_modules tests
# ═══════════════════════════════════════════════════════════════════════════════

@test "cleanup_modules: calls cleanup function if present" {
  local marker="$TEST_TMPDIR/cleaned"

  cat > "$TEST_MODULE_DIR/clean.sh" <<EOF
module_clean_events() { echo "task_complete"; }
module_clean_cleanup() { touch "$marker"; }
EOF

  MODULES="clean"
  load_modules true
  cleanup_modules

  [ -f "$marker" ]
}

@test "cleanup_modules: handles missing cleanup function" {
  cat > "$TEST_MODULE_DIR/noclean.sh" <<'EOF'
module_noclean_events() { echo "task_complete"; }
# No cleanup function
EOF

  MODULES="noclean"
  load_modules true

  # Should not error
  cleanup_modules
}

@test "cleanup_modules: continues after failed cleanup" {
  local marker="$TEST_TMPDIR/second_cleaned"

  cat > "$TEST_MODULE_DIR/fail.sh" <<'EOF'
module_fail_events() { echo "task_complete"; }
module_fail_cleanup() { return 1; }
EOF

  cat > "$TEST_MODULE_DIR/second.sh" <<EOF
module_second_events() { echo "task_complete"; }
module_second_cleanup() { touch "$marker"; }
EOF

  MODULES="fail,second"
  load_modules true
  cleanup_modules

  [ -f "$marker" ]
}
