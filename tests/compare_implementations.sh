#!/bin/bash
#
# Compare Bash and Go implementations for feature parity
#
# Usage: ./tests/compare_implementations.sh
#
# Runs identical commands against both implementations and reports differences.
# Exit code 0 = parity, 1 = differences found

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BASH_CMD="$ROOT_DIR/brigade.sh"
GO_CMD="$ROOT_DIR/brigade-go"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Track results
PASSED=0
FAILED=0
SKIPPED=0

# Test fixture PRD
FIXTURE_PRD="$SCRIPT_DIR/fixtures/parity-test.json"

# Create fixture if it doesn't exist
mkdir -p "$SCRIPT_DIR/fixtures"
if [ ! -f "$FIXTURE_PRD" ]; then
  cat > "$FIXTURE_PRD" << 'EOF'
{
  "featureName": "Parity Test",
  "branchName": "test/parity",
  "createdAt": "2026-01-23",
  "tasks": [
    {
      "id": "US-001",
      "title": "First task",
      "acceptanceCriteria": ["Criterion 1"],
      "verification": [{"type": "pattern", "cmd": "echo ok"}],
      "dependsOn": [],
      "complexity": "junior",
      "passes": false
    },
    {
      "id": "US-002",
      "title": "Second task",
      "acceptanceCriteria": ["Criterion 2"],
      "verification": [{"type": "unit", "cmd": "echo ok"}],
      "dependsOn": ["US-001"],
      "complexity": "senior",
      "passes": false
    }
  ]
}
EOF
fi

# Check if Go binary exists
if [ ! -f "$GO_CMD" ]; then
  echo -e "${YELLOW}Go binary not found. Building...${NC}"
  (cd "$ROOT_DIR" && go build -o brigade-go ./cmd/brigade) || {
    echo -e "${RED}Failed to build Go binary${NC}"
    exit 1
  }
fi

compare_output() {
  local description="$1"
  local bash_args="$2"
  local go_args="${3:-$bash_args}"  # Use same args by default

  echo -n "Testing: $description... "

  # Run both commands, capture output and exit codes
  set +e
  bash_out=$("$BASH_CMD" $bash_args 2>&1)
  bash_exit=$?
  go_out=$("$GO_CMD" $go_args 2>&1)
  go_exit=$?
  set -e

  # Compare outputs (normalize whitespace for minor differences)
  bash_normalized=$(echo "$bash_out" | sed 's/[[:space:]]*$//' | sort)
  go_normalized=$(echo "$go_out" | sed 's/[[:space:]]*$//' | sort)

  if [ "$bash_normalized" = "$go_normalized" ] && [ "$bash_exit" = "$go_exit" ]; then
    echo -e "${GREEN}PASS${NC}"
    ((PASSED++))
    return 0
  else
    echo -e "${RED}FAIL${NC}"
    ((FAILED++))

    if [ "$bash_exit" != "$go_exit" ]; then
      echo "  Exit codes differ: bash=$bash_exit, go=$go_exit"
    fi

    if [ "$bash_normalized" != "$go_normalized" ]; then
      echo "  Output differs:"
      echo "  --- bash ---"
      echo "$bash_out" | head -5 | sed 's/^/  /'
      echo "  --- go ---"
      echo "$go_out" | head -5 | sed 's/^/  /'
    fi
    return 1
  fi
}

compare_json() {
  local description="$1"
  local bash_args="$2"
  local go_args="${3:-$bash_args}"

  echo -n "Testing: $description... "

  set +e
  bash_out=$("$BASH_CMD" $bash_args 2>&1)
  bash_exit=$?
  go_out=$("$GO_CMD" $go_args 2>&1)
  go_exit=$?
  set -e

  # Parse and compare JSON (ignores key ordering)
  if command -v jq &>/dev/null; then
    bash_json=$(echo "$bash_out" | jq -S '.' 2>/dev/null || echo "$bash_out")
    go_json=$(echo "$go_out" | jq -S '.' 2>/dev/null || echo "$go_out")

    if [ "$bash_json" = "$go_json" ] && [ "$bash_exit" = "$go_exit" ]; then
      echo -e "${GREEN}PASS${NC}"
      ((PASSED++))
      return 0
    fi
  fi

  # Fallback to string comparison
  if [ "$bash_out" = "$go_out" ] && [ "$bash_exit" = "$go_exit" ]; then
    echo -e "${GREEN}PASS${NC}"
    ((PASSED++))
    return 0
  fi

  echo -e "${RED}FAIL${NC}"
  ((FAILED++))
  echo "  Exit codes: bash=$bash_exit, go=$go_exit"
  echo "  --- bash ---"
  echo "$bash_out" | head -10 | sed 's/^/  /'
  echo "  --- go ---"
  echo "$go_out" | head -10 | sed 's/^/  /'
  return 1
}

skip_test() {
  local description="$1"
  local reason="$2"
  echo -e "Testing: $description... ${YELLOW}SKIP${NC} ($reason)"
  ((SKIPPED++))
}

echo "========================================"
echo "Brigade Implementation Parity Test"
echo "========================================"
echo ""
echo "Bash: $BASH_CMD"
echo "Go:   $GO_CMD"
echo ""

# Help and version
compare_output "--help flag" "--help"
compare_output "--version flag" "--version" "--version" || true  # May differ, that's ok

# Validation
compare_output "validate command" "validate $FIXTURE_PRD"

# Status (no active PRD, should handle gracefully)
compare_json "status --json (no PRD)" "status --json"
compare_json "status --brief (no PRD)" "status --brief"

# Dry run
compare_output "dry-run service" "--dry-run service $FIXTURE_PRD"

# Cost (requires state, may skip)
skip_test "cost command" "requires completed tasks with duration"

# Template list
compare_output "template list" "template"

echo ""
echo "========================================"
echo "Results"
echo "========================================"
echo -e "Passed:  ${GREEN}$PASSED${NC}"
echo -e "Failed:  ${RED}$FAILED${NC}"
echo -e "Skipped: ${YELLOW}$SKIPPED${NC}"
echo ""

if [ $FAILED -gt 0 ]; then
  echo -e "${RED}Feature parity check FAILED${NC}"
  echo "Fix the differences above before committing."
  exit 1
else
  echo -e "${GREEN}Feature parity check PASSED${NC}"
  exit 0
fi
