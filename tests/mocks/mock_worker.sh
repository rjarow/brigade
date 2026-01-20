#!/usr/bin/env bash
# Mock worker for integration testing
# Behavior is controlled by environment variables or task ID patterns

# Read the prompt from stdin or -p argument
PROMPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      PROMPT="$2"
      shift 2
      ;;
    --dangerously-skip-permissions)
      shift
      ;;
    --model)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# If no -p, read from stdin
if [ -z "$PROMPT" ]; then
  PROMPT=$(cat)
fi

# Extract task ID from prompt (look for US-XXX pattern)
TASK_ID=$(echo "$PROMPT" | grep -oE 'US-[0-9]+' | head -1)

# Check for mock behavior overrides
MOCK_BEHAVIOR="${MOCK_BEHAVIOR:-auto}"
MOCK_DELAY="${MOCK_DELAY:-0}"

# Sleep if delay requested
if [ "$MOCK_DELAY" -gt 0 ]; then
  sleep "$MOCK_DELAY"
fi

# Determine behavior based on task ID or MOCK_BEHAVIOR
case "$MOCK_BEHAVIOR" in
  complete)
    echo "Mock worker completing task $TASK_ID"
    echo "<promise>COMPLETE</promise>"
    exit 0
    ;;
  blocked)
    echo "Mock worker blocked on task $TASK_ID"
    echo "<promise>BLOCKED</promise>"
    echo "Cannot proceed - fundamental issue"
    exit 0
    ;;
  already_done)
    echo "Mock worker found $TASK_ID already done"
    echo "<promise>ALREADY_DONE</promise>"
    exit 0
    ;;
  timeout)
    # Simulate a hung process - sleep longer than expected
    sleep 3600
    ;;
  crash)
    # Simulate a crash
    kill -9 $$
    ;;
  fail_then_complete)
    # First call fails, subsequent calls complete
    ATTEMPT_FILE="/tmp/mock_worker_${TASK_ID}_attempts"
    ATTEMPTS=$(cat "$ATTEMPT_FILE" 2>/dev/null || echo 0)
    ATTEMPTS=$((ATTEMPTS + 1))
    echo "$ATTEMPTS" > "$ATTEMPT_FILE"

    if [ "$ATTEMPTS" -lt 2 ]; then
      echo "Mock worker failing on attempt $ATTEMPTS for $TASK_ID"
      exit 1
    else
      echo "Mock worker completing on attempt $ATTEMPTS for $TASK_ID"
      echo "<promise>COMPLETE</promise>"
      rm -f "$ATTEMPT_FILE"
      exit 0
    fi
    ;;
  auto|*)
    # Auto behavior based on task ID
    case "$TASK_ID" in
      US-001|US-002|US-003)
        echo "Mock worker completing task $TASK_ID"
        echo "<promise>COMPLETE</promise>"
        exit 0
        ;;
      US-BLOCKED*)
        echo "Mock worker blocked on task $TASK_ID"
        echo "<promise>BLOCKED</promise>"
        exit 0
        ;;
      US-FAIL*)
        echo "Mock worker failing on task $TASK_ID"
        exit 1
        ;;
      *)
        echo "Mock worker completing task $TASK_ID (default)"
        echo "<promise>COMPLETE</promise>"
        exit 0
        ;;
    esac
    ;;
esac
