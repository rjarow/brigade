#!/bin/bash
# Brigade - Multi-model AI orchestration framework
# https://github.com/yourusername/brigade

set -e

# Temp file tracking for cleanup (only when running as main script)
BRIGADE_TEMP_FILES=()

cleanup_temp_files() {
  for f in "${BRIGADE_TEMP_FILES[@]}"; do
    rm -f "$f" 2>/dev/null
  done
}

# Track worker process PIDs for cleanup on interrupt
BRIGADE_WORKER_PIDS=()

cleanup_on_interrupt() {
  echo ""
  echo -e "${YELLOW}Interrupted - cleaning up...${NC}"

  # Kill any tracked worker processes
  for pid in "${BRIGADE_WORKER_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      echo -e "${GRAY}Killing worker process $pid${NC}"
      # Try graceful kill first, then force
      kill "$pid" 2>/dev/null
      sleep 0.5
      kill -9 "$pid" 2>/dev/null
    fi
  done

  # Also kill any child processes of this script
  local children=$(jobs -p 2>/dev/null)
  if [ -n "$children" ]; then
    echo -e "${GRAY}Killing background jobs${NC}"
    kill $children 2>/dev/null
    sleep 0.5
    kill -9 $children 2>/dev/null
  fi

  cleanup_temp_files
  echo -e "${YELLOW}Cleanup complete. Run './brigade.sh resume' to continue.${NC}"
  exit 130  # Standard exit code for Ctrl+C
}

# Only set trap when running as main script (not when sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap cleanup_temp_files EXIT
  trap cleanup_on_interrupt INT TERM
fi

# Wrapper for mktemp that tracks files for cleanup
brigade_mktemp() {
  local tmp=$(mktemp)
  BRIGADE_TEMP_FILES+=("$tmp")
  echo "$tmp"
}

# Cross-platform file locking using mkdir (atomic on all POSIX systems)
# Usage: acquire_lock <file_path>  /  release_lock <file_path>
acquire_lock() {
  local lock_path="$1.lock"
  local max_wait=30  # seconds
  local waited=0

  if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
    echo "[DEBUG] acquire_lock: attempting $lock_path (pid=$$)" >&2
  fi

  while ! mkdir "$lock_path" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    if [ $waited -gt $((max_wait * 10)) ]; then
      echo "Warning: Lock acquisition timeout for $lock_path, forcing" >&2
      rmdir "$lock_path" 2>/dev/null
    fi
    # Debug: log contention every second
    if [ "${BRIGADE_DEBUG:-false}" == "true" ] && [ $((waited % 10)) -eq 0 ]; then
      echo "[DEBUG] acquire_lock: waiting ${waited}00ms for $lock_path (pid=$$)" >&2
    fi
  done

  if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
    echo "[DEBUG] acquire_lock: acquired $lock_path after ${waited}00ms (pid=$$)" >&2
  fi
}

release_lock() {
  local lock_path="$1.lock"
  if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
    echo "[DEBUG] release_lock: releasing $lock_path (pid=$$)" >&2
  fi
  rmdir "$lock_path" 2>/dev/null
}

# Cross-platform timeout execution with health monitoring (works on macOS and Linux)
# Usage: run_with_timeout <seconds> <command> [args...]
# Returns: command exit code, 124 if timed out, WORKER_CRASH_EXIT_CODE if crashed
#
# IMPORTANT: This function monitors the worker process to detect crashes.
# If the worker process dies unexpectedly, it's detected and treated as a crash.
run_with_timeout() {
  local timeout_secs="$1"
  shift

  # Always use background monitoring for health checks
  # This ensures we detect crashes even when the process dies without closing pipes

  "$@" &
  local pid=$!
  BRIGADE_WORKER_PIDS+=("$pid")

  if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
    echo "[DEBUG] run_with_timeout: started pid=$pid, timeout=${timeout_secs}s" >&2
  fi

  local elapsed=0
  local check_interval="${WORKER_HEALTH_CHECK_INTERVAL:-5}"
  [ "$check_interval" -lt 1 ] && check_interval=1

  local last_check_time=$(date +%s)

  while true; do
    # Check if process is still running
    if ! kill -0 "$pid" 2>/dev/null; then
      # Process is gone - get exit code
      wait "$pid" 2>/dev/null
      local exit_code=$?
      BRIGADE_WORKER_PIDS=("${BRIGADE_WORKER_PIDS[@]/$pid}")

      if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
        echo "[DEBUG] run_with_timeout: pid=$pid exited with code=$exit_code after ${elapsed}s" >&2
      fi

      # Check if this was an unexpected crash (non-zero, non-timeout)
      # We consider it a crash if it exited quickly with a signal-related code
      if [ "$exit_code" -gt 128 ] && [ "$elapsed" -lt 5 ]; then
        # Exit code > 128 typically means killed by signal
        local signal=$((exit_code - 128))
        echo -e "${RED}Worker crashed (signal $signal) after ${elapsed}s${NC}" >&2
        return "${WORKER_CRASH_EXIT_CODE:-125}"
      fi

      return $exit_code
    fi

    # Check timeout
    if [ "$timeout_secs" -gt 0 ] && [ "$elapsed" -ge "$timeout_secs" ]; then
      echo -e "${RED}Timeout reached (${timeout_secs}s), killing worker...${NC}" >&2

      # Graceful kill first
      kill "$pid" 2>/dev/null
      sleep 2

      # Force kill if still running
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        sleep 1
      fi

      wait "$pid" 2>/dev/null
      BRIGADE_WORKER_PIDS=("${BRIGADE_WORKER_PIDS[@]/$pid}")
      return 124  # Standard timeout exit code
    fi

    # Sleep for health check interval
    sleep "$check_interval"
    elapsed=$((elapsed + check_interval))

    # Periodic health check logging (debug mode)
    if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
      local now=$(date +%s)
      if [ $((now - last_check_time)) -ge 30 ]; then
        echo "[DEBUG] run_with_timeout: pid=$pid still running, elapsed=${elapsed}s" >&2
        last_check_time=$now
      fi
    fi
  done
}

# Legacy function for backwards compatibility
# Prefer run_with_timeout for new code
run_with_timeout_legacy() {
  local timeout_secs="$1"
  shift

  # Try GNU timeout first (Linux, or macOS with coreutils)
  if command -v timeout &>/dev/null; then
    timeout --kill-after=30 "$timeout_secs" "$@"
    return $?
  fi

  # Try gtimeout (macOS with coreutils: brew install coreutils)
  if command -v gtimeout &>/dev/null; then
    gtimeout --kill-after=30 "$timeout_secs" "$@"
    return $?
  fi

  # Fall through to run_with_timeout
  run_with_timeout "$timeout_secs" "$@"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/brigade.config"
KITCHEN_DIR="$SCRIPT_DIR/kitchen"
CHEF_DIR="$SCRIPT_DIR/chef"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# Defaults (all Claude - works out of the box if you have claude CLI)
EXECUTIVE_CMD="claude --model opus"
EXECUTIVE_AGENT="claude"
SOUS_CMD="claude --model sonnet"
SOUS_AGENT="claude"
LINE_CMD="claude --model sonnet"  # Default to Sonnet; configure OpenCode for cost savings
LINE_AGENT="claude"
TEST_CMD=""
TEST_TIMEOUT=120                 # Seconds before considering test hung
MAX_ITERATIONS=50
DRY_RUN=false

# Simple toggle for OpenCode (set in config or via --opencode flag)
USE_OPENCODE=false

# Agent-specific defaults
OPENCODE_MODEL=""
OPENCODE_SERVER=""
CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS=true

# Escalation defaults
ESCALATION_ENABLED=true
ESCALATION_AFTER=3           # Line Cook → Sous Chef after N iterations
ESCALATION_TO_EXEC=true      # Allow Sous Chef → Executive Chef (rare)
ESCALATION_TO_EXEC_AFTER=5   # Sous Chef → Executive Chef after N iterations

# Task timeout defaults (per-complexity, in seconds)
TASK_TIMEOUT_JUNIOR=900      # 15 minutes for junior/line cook tasks
TASK_TIMEOUT_SENIOR=1800     # 30 minutes for senior/sous chef tasks
TASK_TIMEOUT_EXECUTIVE=3600  # 60 minutes for executive tasks (rare)

# Worker health check defaults
WORKER_HEALTH_CHECK_INTERVAL=5  # Seconds between health checks (0 = disable)
WORKER_CRASH_EXIT_CODE=125      # Exit code when worker crashes (vs 124 for timeout)

# Executive review defaults
REVIEW_ENABLED=true
REVIEW_JUNIOR_ONLY=true

# Phase review defaults (Executive Chef checks overall progress)
PHASE_REVIEW_ENABLED=false   # Off by default, enable for larger projects
PHASE_REVIEW_AFTER=5         # Review every N completed tasks
PHASE_REVIEW_ACTION=continue # continue | pause | remediate

# Auto-continue defaults (chain multiple PRDs)
AUTO_CONTINUE=false          # Chain numbered PRDs without user intervention
PHASE_GATE="continue"        # review | continue | pause (between PRDs)

# Walkaway mode defaults (autonomous execution without human input)
WALKAWAY_MODE=false          # Use AI to decide retry/skip on failures
WALKAWAY_MAX_SKIPS=3         # Max consecutive skips before pausing (prevent runaway)
WALKAWAY_DECISION_TIMEOUT=120  # Seconds to wait for AI decision
WALKAWAY_SCOPE_DECISIONS=true   # Let exec chef decide on scope questions in walkaway mode

# Context isolation defaults
CONTEXT_ISOLATION=true
STATE_FILE="brigade-state.json"

# Knowledge sharing defaults
KNOWLEDGE_SHARING=true
LEARNINGS_FILE="brigade-learnings.md"
BACKLOG_FILE="brigade-backlog.md"
LEARNINGS_MAX=50                   # Max learnings per file (0 = unlimited, prunes oldest when exceeded)
LEARNINGS_ARCHIVE=true             # Archive learnings on PRD completion

# Parallel execution defaults
MAX_PARALLEL=3

# Verification defaults
VERIFICATION_ENABLED=true          # Run verification commands after COMPLETE signal
VERIFICATION_TIMEOUT=60            # Timeout per verification command in seconds
TODO_SCAN_ENABLED=true             # Scan changed files for TODO/FIXME before marking complete
VERIFICATION_WARN_GREP_ONLY=true   # Warn if PRD only has grep-based verification (no execution)

# Visibility defaults
ACTIVITY_LOG=""                    # Path to activity heartbeat log (empty = disabled)
ACTIVITY_LOG_INTERVAL=30           # Seconds between heartbeat writes
TASK_TIMEOUT_WARNING_JUNIOR=10     # Minutes before warning for junior tasks (0 = disabled)
TASK_TIMEOUT_WARNING_SENIOR=20     # Minutes before warning for senior tasks
WORKER_LOG_DIR=""                  # Directory for per-task worker logs (empty = disabled)
STATUS_WATCH_INTERVAL=30           # Seconds between status refreshes in watch mode
SUPERVISOR_STATUS_FILE=""          # Write compact status JSON on state changes (empty = disabled)
SUPERVISOR_EVENTS_FILE=""          # Append-only JSONL event stream (empty = disabled)
SUPERVISOR_CMD_FILE=""             # Command ingestion file (empty = disabled)
SUPERVISOR_CMD_POLL_INTERVAL=2     # Seconds between polls when waiting for command
SUPERVISOR_CMD_TIMEOUT=300         # Max seconds to wait for supervisor command (0 = wait forever)

# Codebase map defaults
MAP_STALE_COMMITS=20               # Regenerate map if this many commits behind HEAD (0 = disable)

# Runtime state (set during execution)
LAST_REVIEW_FEEDBACK=""       # Feedback from failed executive review, passed to worker on retry
LAST_VERIFICATION_FEEDBACK="" # Feedback from failed verification commands, passed to worker on retry
LAST_TODO_WARNINGS=""         # Warnings from TODO scan, passed to worker on retry
CURRENT_TASK_START_TIME=0          # Epoch timestamp when current task started
CURRENT_TASK_WARNING_SHOWN=false   # Whether timeout warning was shown for current task
CURRENT_PRD_PATH=""                # Current PRD being processed (for visibility features)
CURRENT_TASK_ID=""                 # Current task being worked (for visibility features)
CURRENT_WORKER=""                  # Current worker (for visibility features)
LAST_HEARTBEAT_TIME=0              # Last time heartbeat was written

# ═══════════════════════════════════════════════════════════════════════════════
# LOGGING
# ═══════════════════════════════════════════════════════════════════════════════

# Timestamp format for logs (ISO 8601 with local time)
timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

# Log an event with timestamp - for key milestones directors need to see
log_event() {
  local level="$1"
  local message="$2"
  local ts=$(timestamp)

  case "$level" in
    "INFO")
      echo -e "${GRAY}[$ts]${NC} $message"
      ;;
    "START")
      echo -e "${CYAN}[$ts]${NC} ${BOLD}▶ $message${NC}"
      ;;
    "SUCCESS")
      echo -e "${GREEN}[$ts]${NC} ✓ $message"
      ;;
    "WARN")
      echo -e "${YELLOW}[$ts]${NC} ⚠ $message"
      ;;
    "ERROR")
      echo -e "${RED}[$ts]${NC} ✗ $message"
      ;;
    "ESCALATE")
      echo -e "${YELLOW}[$ts]${NC} ↑ $message"
      ;;
    "REVIEW")
      echo -e "${CYAN}[$ts]${NC} 👁 $message"
      ;;
    *)
      echo -e "${GRAY}[$ts]${NC} $message"
      ;;
  esac
}

# Write activity heartbeat to log file
# Usage: write_activity_heartbeat "$prd_path" "$task_id" "$worker" "$elapsed_secs"
write_activity_heartbeat() {
  [ -z "$ACTIVITY_LOG" ] && return 0

  local prd_path="$1"
  local task_id="$2"
  local worker="$3"
  local elapsed_secs="$4"

  local ts=$(date "+%H:%M:%S")
  local display_id=$(format_task_id "$prd_path" "$task_id")
  local worker_name=$(get_worker_name "$worker")
  local mins=$((elapsed_secs / 60))
  local secs=$((elapsed_secs % 60))

  # Ensure directory exists
  local log_dir=$(dirname "$ACTIVITY_LOG")
  [ -n "$log_dir" ] && [ "$log_dir" != "." ] && mkdir -p "$log_dir"

  echo "[$ts] $display_id: $worker_name working (${mins}m ${secs}s)" >> "$ACTIVITY_LOG"
}

# Check and log timeout warning for current task
# Usage: check_task_timeout_warning "$worker" "$elapsed_secs" "$task_id" "$prd_path"
check_task_timeout_warning() {
  [ "$CURRENT_TASK_WARNING_SHOWN" == "true" ] && return 0

  local worker="$1"
  local elapsed_secs="$2"
  local task_id="$3"
  local prd_path="$4"

  local elapsed_mins=$((elapsed_secs / 60))
  local warning_threshold=0

  case "$worker" in
    "line") warning_threshold="$TASK_TIMEOUT_WARNING_JUNIOR" ;;
    "sous") warning_threshold="$TASK_TIMEOUT_WARNING_SENIOR" ;;
    "executive") warning_threshold="$TASK_TIMEOUT_WARNING_SENIOR" ;;
  esac

  [ "$warning_threshold" -eq 0 ] && return 0

  if [ "$elapsed_mins" -ge "$warning_threshold" ]; then
    local display_id=$(format_task_id "$prd_path" "$task_id")
    local worker_name=$(get_worker_name "$worker")
    log_event "WARN" "$display_id running ${elapsed_mins}m (expected ~${warning_threshold}m for $worker_name)"

    # Also write to activity log if enabled
    if [ -n "$ACTIVITY_LOG" ]; then
      local ts=$(date "+%H:%M:%S")
      echo "[$ts] ⚠️ $display_id running ${elapsed_mins}m (expected ~${warning_threshold}m for $worker_name)" >> "$ACTIVITY_LOG"
    fi

    CURRENT_TASK_WARNING_SHOWN=true
  fi
}

# Get worker log file path for a task
# Usage: get_worker_log_path "$prd_path" "$task_id" "$worker"
get_worker_log_path() {
  [ -z "$WORKER_LOG_DIR" ] && echo "" && return 0

  local prd_path="$1"
  local task_id="$2"
  local worker="$3"

  local prd_prefix=$(get_prd_prefix "$prd_path")
  local timestamp=$(date "+%Y-%m-%d-%H%M%S")

  # Ensure directory exists
  mkdir -p "$WORKER_LOG_DIR"

  echo "${WORKER_LOG_DIR}/${prd_prefix}-${task_id}-${worker}-${timestamp}.log"
}

# ═══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

print_banner() {
  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}  ${BOLD}Brigade${NC} - Multi-model AI Orchestration              ${CYAN}║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

print_usage() {
  echo "Usage: ./brigade.sh [options] <command> [args]"
  echo ""
  echo "Commands:"
  echo "  plan <description>         Generate PRD from feature description (Director/Opus)"
  echo "  service [prd.json]         Run full service (defaults to brigade/tasks/latest.json)"
  echo "  resume [prd.json] [action] Resume after interruption (action: retry|skip)"
  echo "  ticket <prd.json> <id>     Run single ticket"
  echo "  status [options] [prd.json] Show kitchen status (auto-detects active PRD)"
  echo "                              Options: --all (show all escalations), --watch/-w (auto-refresh)"
  echo "  summary [prd.json] [file]  Generate markdown summary report from state"
  echo "  map [output.md]            Generate codebase map (default: brigade/codebase-map.md)"
  echo "  analyze <prd.json>         Analyze tasks and suggest routing"
  echo "  validate <prd.json>        Validate PRD structure and dependencies"
  echo "  opencode-models            List available OpenCode models"
  echo ""
  echo "Options:"
  echo "  --max-iterations <n>       Max iterations per task (default: 50)"
  echo "  --dry-run                  Show what would be done without executing"
  echo "  --auto-continue            Chain multiple PRDs for unattended execution"
  echo "  --phase-gate <mode>        Between-PRD behavior: review|continue|pause (default: continue)"
  echo "  --sequential               Disable parallel execution (debug parallel issues)"
  echo "  --walkaway                 AI decides retry/skip on failures (unattended mode)"
  echo ""
  echo "Examples:"
  echo "  ./brigade.sh plan \"Add user authentication with JWT\""
  echo "  ./brigade.sh service                                 # Uses brigade/tasks/latest.json"
  echo "  ./brigade.sh service brigade/tasks/prd.json          # Specific PRD"
  echo "  ./brigade.sh --auto-continue service brigade/tasks/prd-*.json  # Chain numbered PRDs"
  echo "  ./brigade.sh status                                  # Auto-detect active PRD"
}

# Spinner for QUIET_WORKERS mode - shows activity while worker runs in background
# Usage: run_with_spinner "message" "output_file" command args...
# Returns the exit code of the command
# Uses global CURRENT_PRD_PATH, CURRENT_TASK_ID, CURRENT_WORKER for heartbeat/warnings
run_with_spinner() {
  local message="$1"
  local output_file="$2"
  shift 2

  # Braille spinner frames (smooth animation)
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local frame_count=${#frames[@]}
  local frame_idx=0

  # Start the command in background, redirecting output to file
  "$@" > "$output_file" 2>&1 &
  local pid=$!

  # Track PID for cleanup on interrupt
  BRIGADE_WORKER_PIDS+=("$pid")

  local start_time=$(date +%s)
  LAST_HEARTBEAT_TIME=$start_time

  # Hide cursor
  tput civis 2>/dev/null || true

  # Spinner loop
  while kill -0 $pid 2>/dev/null; do
    local now=$(date +%s)
    local elapsed=$((now - start_time))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))

    # Format time
    local time_str
    if [ $mins -gt 0 ]; then
      time_str="${mins}m ${secs}s"
    else
      time_str="${secs}s"
    fi

    # Print spinner with message and time
    printf "\r${CYAN}%s${NC} %s ${GRAY}(%s)${NC}  " "${frames[$frame_idx]}" "$message" "$time_str"

    # Activity heartbeat (every ACTIVITY_LOG_INTERVAL seconds)
    if [ -n "$ACTIVITY_LOG" ] && [ -n "$CURRENT_TASK_ID" ]; then
      local since_heartbeat=$((now - LAST_HEARTBEAT_TIME))
      if [ "$since_heartbeat" -ge "$ACTIVITY_LOG_INTERVAL" ]; then
        write_activity_heartbeat "$CURRENT_PRD_PATH" "$CURRENT_TASK_ID" "$CURRENT_WORKER" "$elapsed"
        LAST_HEARTBEAT_TIME=$now
      fi
    fi

    # Check timeout warning (only once per task)
    if [ -n "$CURRENT_TASK_ID" ]; then
      check_task_timeout_warning "$CURRENT_WORKER" "$elapsed" "$CURRENT_TASK_ID" "$CURRENT_PRD_PATH"
    fi

    frame_idx=$(( (frame_idx + 1) % frame_count ))
    sleep 0.1
  done

  # Get exit code
  wait $pid
  local exit_code=$?
  local end_time=$(date +%s)
  local total_elapsed=$((end_time - start_time))

  # Remove PID from tracking (process completed)
  BRIGADE_WORKER_PIDS=("${BRIGADE_WORKER_PIDS[@]/$pid}")

  # Show cursor
  tput cnorm 2>/dev/null || true

  # Clear the spinner line
  printf "\r%-80s\r" ""

  # Detect crash (signal-related exit code and quick exit)
  if [ "$exit_code" -gt 128 ] && [ "$total_elapsed" -lt 5 ]; then
    local signal=$((exit_code - 128))
    echo -e "${RED}Worker crashed (signal $signal) after ${total_elapsed}s${NC}"
    return "${WORKER_CRASH_EXIT_CODE:-125}"
  fi

  return $exit_code
}

load_config() {
  local quiet="${1:-false}"

  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    [ "$quiet" != "true" ] && echo -e "${GRAY}Loaded config from $CONFIG_FILE${NC}"
  else
    [ "$quiet" != "true" ] && echo -e "${YELLOW}Warning: No brigade.config found, using defaults${NC}"
  fi

  # Apply USE_OPENCODE if set in config
  if [ "$USE_OPENCODE" = true ]; then
    LINE_CMD="opencode run"
    LINE_AGENT="opencode"
    [ "$quiet" != "true" ] && echo -e "${CYAN}Using OpenCode for junior tasks (USE_OPENCODE=true)${NC}"
  fi

  # Validate config values
  validate_config "$quiet"
}

validate_config() {
  local quiet="${1:-false}"
  local warnings=0

  # Numeric validations
  if [ "$MAX_PARALLEL" -lt 0 ] 2>/dev/null; then
    [ "$quiet" != "true" ] && echo -e "${YELLOW}Warning: MAX_PARALLEL=$MAX_PARALLEL invalid, using 0${NC}" >&2
    MAX_PARALLEL=0
    ((warnings++))
  fi

  if [ "$MAX_ITERATIONS" -lt 1 ] 2>/dev/null; then
    [ "$quiet" != "true" ] && echo -e "${YELLOW}Warning: MAX_ITERATIONS=$MAX_ITERATIONS invalid, using 50${NC}" >&2
    MAX_ITERATIONS=50
    ((warnings++))
  fi

  if [ "$ESCALATION_AFTER" -lt 1 ] 2>/dev/null; then
    [ "$quiet" != "true" ] && echo -e "${YELLOW}Warning: ESCALATION_AFTER=$ESCALATION_AFTER invalid, using 3${NC}" >&2
    ESCALATION_AFTER=3
    ((warnings++))
  fi

  if [ "$ESCALATION_TO_EXEC_AFTER" -lt 1 ] 2>/dev/null; then
    [ "$quiet" != "true" ] && echo -e "${YELLOW}Warning: ESCALATION_TO_EXEC_AFTER=$ESCALATION_TO_EXEC_AFTER invalid, using 5${NC}" >&2
    ESCALATION_TO_EXEC_AFTER=5
    ((warnings++))
  fi

  if [ "$TEST_TIMEOUT" -lt 1 ] 2>/dev/null; then
    [ "$quiet" != "true" ] && echo -e "${YELLOW}Warning: TEST_TIMEOUT=$TEST_TIMEOUT invalid, using 120${NC}" >&2
    TEST_TIMEOUT=120
    ((warnings++))
  fi

  if [ "$PHASE_REVIEW_AFTER" -lt 1 ] 2>/dev/null; then
    [ "$quiet" != "true" ] && echo -e "${YELLOW}Warning: PHASE_REVIEW_AFTER=$PHASE_REVIEW_AFTER invalid, using 5${NC}" >&2
    PHASE_REVIEW_AFTER=5
    ((warnings++))
  fi

  # Enum validations
  case "$PHASE_REVIEW_ACTION" in
    continue|pause|remediate) ;;
    *)
      [ "$quiet" != "true" ] && echo -e "${YELLOW}Warning: PHASE_REVIEW_ACTION=$PHASE_REVIEW_ACTION invalid, using continue${NC}" >&2
      PHASE_REVIEW_ACTION=continue
      ((warnings++))
      ;;
  esac

  case "$PHASE_GATE" in
    continue|pause|review) ;;
    *)
      [ "$quiet" != "true" ] && echo -e "${YELLOW}Warning: PHASE_GATE=$PHASE_GATE invalid, using continue${NC}" >&2
      PHASE_GATE=continue
      ((warnings++))
      ;;
  esac

  return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# PRD HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

# Get short PRD prefix for task ID display (e.g., "auth" from "prd-add-auth.json")
# Used to disambiguate tasks across multiple PRDs
get_prd_prefix() {
  local prd_path="$1"
  # Extract from filename: prd-add-user-auth.json → add-user-auth
  local basename=$(basename "$prd_path" .json)
  local prefix="${basename#prd-}"  # Remove "prd-" prefix
  # Truncate to reasonable length
  echo "${prefix:0:20}"
}

# Format task ID with PRD prefix for display (e.g., "auth/US-001")
format_task_id() {
  local prd_path="$1"
  local task_id="$2"
  local prefix=$(get_prd_prefix "$prd_path")
  echo "${prefix}/${task_id}"
}

# Quick validation for essential PRD structure (called before service)
validate_prd_quick() {
  local prd_path="$1"

  # Check valid JSON
  if ! jq empty "$prd_path" 2>/dev/null; then
    echo -e "${RED}Invalid JSON in PRD${NC}"
    return 1
  fi

  # Check tasks array exists
  local task_count=$(jq '.tasks | length' "$prd_path" 2>/dev/null)
  if [ -z "$task_count" ] || [ "$task_count" == "null" ] || [ "$task_count" -eq 0 ]; then
    echo -e "${RED}No tasks found in PRD${NC}"
    return 1
  fi

  # Check for duplicate IDs
  local unique_ids=$(jq -r '.tasks[].id' "$prd_path" | sort -u | wc -l | tr -d ' ')
  local total_ids=$(jq -r '.tasks[].id' "$prd_path" | wc -l | tr -d ' ')
  if [ "$unique_ids" != "$total_ids" ]; then
    echo -e "${RED}Duplicate task IDs found${NC}"
    return 1
  fi

  # Check all dependsOn references are valid
  local all_ids=$(jq -r '.tasks[].id' "$prd_path")
  for task_id in $all_ids; do
    local deps=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .dependsOn // [] | .[]' "$prd_path" 2>/dev/null)
    for dep in $deps; do
      if ! echo "$all_ids" | grep -q "^${dep}$"; then
        echo -e "${RED}Task $task_id depends on non-existent: $dep${NC}"
        return 1
      fi
    done
  done

  return 0
}

get_task_count() {
  local prd_path="$1"
  jq '.tasks | length' "$prd_path"
}

get_pending_tasks() {
  local prd_path="$1"
  jq -r '.tasks[] | select(.passes == false) | .id' "$prd_path"
}

get_task_by_id() {
  local prd_path="$1"
  local task_id="$2"
  jq ".tasks[] | select(.id == \"$task_id\")" "$prd_path"
}

get_task_complexity() {
  local prd_path="$1"
  local task_id="$2"
  jq -r ".tasks[] | select(.id == \"$task_id\") | .complexity // \"auto\"" "$prd_path"
}

get_task_dependencies() {
  local prd_path="$1"
  local task_id="$2"
  jq -r ".tasks[] | select(.id == \"$task_id\") | .dependsOn[]?" "$prd_path"
}

check_dependencies_met() {
  local prd_path="$1"
  local task_id="$2"

  local deps=$(get_task_dependencies "$prd_path" "$task_id")
  if [ -z "$deps" ]; then
    return 0  # No dependencies
  fi

  for dep in $deps; do
    local dep_passes=$(jq -r ".tasks[] | select(.id == \"$dep\") | .passes" "$prd_path")
    if [ "$dep_passes" != "true" ]; then
      return 1  # Dependency not met
    fi
  done

  return 0  # All dependencies met
}

get_next_task() {
  local prd_path="$1"

  for task_id in $(get_pending_tasks "$prd_path"); do
    if check_dependencies_met "$prd_path" "$task_id"; then
      echo "$task_id"
      return 0
    fi
  done

  return 1  # No available tasks
}

get_ready_tasks() {
  # Get all tasks that are ready to run (dependencies met, not complete)
  local prd_path="$1"
  local ready_tasks=""

  for task_id in $(get_pending_tasks "$prd_path"); do
    if check_dependencies_met "$prd_path" "$task_id"; then
      ready_tasks="$ready_tasks $task_id"
    fi
  done

  echo "$ready_tasks" | xargs  # Trim whitespace
}

can_run_parallel() {
  # Check if two tasks can run in parallel (no file conflicts)
  # For now, we assume tasks with same dependencies can run in parallel
  # A more sophisticated check would analyze target files
  local prd_path="$1"
  local task1="$2"
  local task2="$3"

  # Same complexity level is a good heuristic for parallelism
  local complexity1=$(get_task_complexity "$prd_path" "$task1")
  local complexity2=$(get_task_complexity "$prd_path" "$task2")

  # Junior tasks can always run in parallel with each other
  if [ "$complexity1" == "junior" ] && [ "$complexity2" == "junior" ]; then
    return 0
  fi

  # For now, only parallelize junior tasks
  return 1
}

mark_task_complete() {
  local prd_path="$1"
  local task_id="$2"

  if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
    echo "[DEBUG] mark_task_complete: starting for $task_id (pid=$$)" >&2
  fi

  # Update PRD (with file locking for parallel safety)
  acquire_lock "$prd_path"
  local tmp_file=$(brigade_mktemp)

  # Use set +e locally to prevent jq failures from killing the subshell
  set +e
  jq "(.tasks[] | select(.id == \"$task_id\") | .passes) = true" "$prd_path" > "$tmp_file"
  local jq_exit=$?
  set -e

  if [ $jq_exit -ne 0 ]; then
    echo -e "${RED}Error: jq failed updating PRD for $task_id (exit=$jq_exit)${NC}" >&2
    release_lock "$prd_path"
    return 1
  fi

  # Verify tmp_file has content before overwriting
  if [ ! -s "$tmp_file" ]; then
    echo -e "${RED}Error: jq produced empty output for $task_id${NC}" >&2
    release_lock "$prd_path"
    return 1
  fi

  mv "$tmp_file" "$prd_path"
  release_lock "$prd_path"

  if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
    echo "[DEBUG] mark_task_complete: PRD updated for $task_id" >&2
  fi

  # Clear currentTask from state file (with file locking)
  local state_path=$(get_state_path "$prd_path")
  if [ -f "$state_path" ]; then
    acquire_lock "$state_path"
    ensure_valid_state "$state_path" "$prd_path"
    tmp_file=$(brigade_mktemp)

    set +e
    jq '.currentTask = null' "$state_path" > "$tmp_file"
    jq_exit=$?
    set -e

    if [ $jq_exit -eq 0 ] && [ -s "$tmp_file" ]; then
      mv "$tmp_file" "$state_path"
    else
      echo -e "${YELLOW}Warning: Could not update state file for $task_id${NC}" >&2
    fi

    release_lock "$state_path"
  fi

  if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
    echo "[DEBUG] mark_task_complete: done for $task_id" >&2
  fi

  # Update supervisor status file
  write_supervisor_status "$prd_path"

  echo -e "${GREEN}✓ Marked $task_id as complete${NC}"
}

update_latest_symlink() {
  local prd_path="$1"
  local prd_dir=$(dirname "$prd_path")
  local prd_name=$(basename "$prd_path")
  local latest_link="$prd_dir/latest.json"

  # Remove existing symlink if present
  [ -L "$latest_link" ] && rm -f "$latest_link"

  # Create new symlink
  ln -s "$prd_name" "$latest_link"
  echo -e "${GRAY}Updated $latest_link → $prd_name${NC}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# STATE MANAGEMENT (Context Isolation)
# ═══════════════════════════════════════════════════════════════════════════════

get_state_path() {
  local prd_path="$1"
  local prd_dir=$(dirname "$prd_path")
  local prd_name=$(basename "$prd_path" .json)
  echo "$prd_dir/${prd_name}.state.json"
}

# Find active PRD - looks for state files with currentTask set, or most recent PRD
find_active_prd() {
  # Check brigade/tasks first, then fallback paths (for running from inside brigade/)
  local search_dirs=("brigade/tasks" "tasks" "." "../brigade/tasks" "../tasks" "..")

  # First, look for per-PRD state files (*.state.json) with an active currentTask
  for dir in "${search_dirs[@]}"; do
    if [ -d "$dir" ]; then
      for state_file in "$dir"/*.state.json; do
        if [ -f "$state_file" ] 2>/dev/null; then
          local current=$(jq -r '.currentTask // empty' "$state_file" 2>/dev/null)
          if [ -n "$current" ]; then
            # Derive PRD path from state file name (foo.state.json → foo.json)
            local prd="${state_file%.state.json}.json"
            if [ -f "$prd" ] && jq -e '.tasks' "$prd" >/dev/null 2>&1; then
              echo "$prd"
              return 0
            fi
          fi
        fi
      done
    fi
  done

  # No active task found, look for PRDs with pending tasks that HAVE state files (already started)
  for dir in "${search_dirs[@]}"; do
    if [ -d "$dir" ]; then
      for prd in "$dir"/prd*.json "$dir"/*.json; do
        # Skip state files
        [[ "$prd" == *.state.json ]] && continue
        local state_file="${prd%.json}.state.json"
        if [ -f "$prd" ] && [ -f "$state_file" ] && jq -e '.tasks' "$prd" >/dev/null 2>&1; then
          local pending=$(jq '[.tasks[] | select(.passes == false)] | length' "$prd" 2>/dev/null)
          if [ "$pending" -gt 0 ]; then
            echo "$prd"
            return 0
          fi
        fi
      done
    fi
  done

  # Then look for orphan PRDs (pending tasks but no state file)
  for dir in "${search_dirs[@]}"; do
    if [ -d "$dir" ]; then
      for prd in "$dir"/prd*.json "$dir"/*.json; do
        # Skip state files
        [[ "$prd" == *.state.json ]] && continue
        local state_file="${prd%.json}.state.json"
        if [ -f "$prd" ] 2>/dev/null && [ ! -f "$state_file" ] && jq -e '.tasks' "$prd" >/dev/null 2>&1; then
          local pending=$(jq '[.tasks[] | select(.passes == false)] | length' "$prd" 2>/dev/null)
          if [ "$pending" -gt 0 ]; then
            echo "$prd"
            return 0
          fi
        fi
      done
    fi
  done

  # Last resort: any PRD file (not state file)
  for dir in "${search_dirs[@]}"; do
    if [ -d "$dir" ]; then
      for prd in "$dir"/prd*.json "$dir"/*.json; do
        # Skip state files
        [[ "$prd" == *.state.json ]] && continue
        if [ -f "$prd" ] 2>/dev/null && jq -e '.tasks' "$prd" >/dev/null 2>&1; then
          echo "$prd"
          return 0
        fi
      done
    fi
  done

  return 1
}

validate_state() {
  local state_path="$1"

  if [ ! -f "$state_path" ]; then
    return 0  # No state file is valid (will be created)
  fi

  # Check for valid JSON
  if ! jq empty "$state_path" 2>/dev/null; then
    echo -e "${RED}Error: State file has invalid JSON: $state_path${NC}"
    echo -e "${YELLOW}Backing up corrupted file to ${state_path}.corrupted${NC}"
    cp "$state_path" "${state_path}.corrupted"
    rm "$state_path"
    echo -e "${GRAY}State file removed. Run service again to start fresh.${NC}"
    return 1
  fi

  # Check for required fields (be lenient - just warn if missing)
  local has_history=$(jq 'has("taskHistory")' "$state_path" 2>/dev/null)
  if [ "$has_history" != "true" ]; then
    echo -e "${YELLOW}Warning: State file missing taskHistory, may be from older version${NC}"
  fi

  return 0
}

init_state() {
  local prd_path="$1"
  local state_path=$(get_state_path "$prd_path")

  # Fast path: if valid state exists, skip locking
  if [ -f "$state_path" ]; then
    if validate_state "$state_path" 2>/dev/null; then
      return 0  # Valid state exists
    fi
  fi

  # Lock for initialization (parallel tasks may race here)
  acquire_lock "$state_path"

  # Re-check after acquiring lock (another task may have created it)
  if [ -f "$state_path" ]; then
    if validate_state "$state_path" 2>/dev/null; then
      release_lock "$state_path"
      return 0  # Another task created valid state while we waited
    fi
    # State was corrupted, remove it
    cp "$state_path" "${state_path}.corrupted" 2>/dev/null || true
    rm -f "$state_path"
  fi

  # Create fresh state file
  cat > "$state_path" <<EOF
{
  "sessionId": "$(date +%s)-$$",
  "startedAt": "$(date -Iseconds)",
  "lastStartTime": "$(date -Iseconds)",
  "currentTask": null,
  "taskHistory": [],
  "escalations": [],
  "reviews": [],
  "absorptions": []
}
EOF

  release_lock "$state_path"
  echo -e "${GRAY}Initialized state: $state_path${NC}"
}

# Ensure state file is valid JSON before read/write operations
# If corrupted, backs up and reinitializes. Must be called AFTER acquiring lock.
ensure_valid_state() {
  local state_path="$1"
  local prd_path="$2"

  if [ ! -f "$state_path" ]; then
    # No file, will be created by caller
    return 0
  fi

  if ! jq empty "$state_path" 2>/dev/null; then
    echo -e "${RED}Warning: State file corrupted, reinitializing${NC}" >&2
    log_event "WARN" "State file corrupted: $state_path - backing up and reinitializing"
    cp "$state_path" "${state_path}.corrupted.$(date +%s)" 2>/dev/null || true

    # Create fresh state (we already hold the lock)
    cat > "$state_path" <<EOF
{
  "sessionId": "$(date +%s)-$$",
  "startedAt": "$(date -Iseconds)",
  "lastStartTime": "$(date -Iseconds)",
  "currentTask": null,
  "taskHistory": [],
  "escalations": [],
  "reviews": [],
  "absorptions": []
}
EOF
    echo -e "${YELLOW}State file reinitialized - some history may be lost${NC}" >&2
  fi
}

update_last_start_time() {
  local prd_path="$1"

  if [ "$CONTEXT_ISOLATION" != "true" ]; then
    return
  fi

  local state_path=$(get_state_path "$prd_path")
  if [ -f "$state_path" ]; then
    acquire_lock "$state_path"
    ensure_valid_state "$state_path" "$prd_path"
    local tmp_file=$(brigade_mktemp)
    jq --arg ts "$(date -Iseconds)" '.lastStartTime = $ts' "$state_path" > "$tmp_file"
    mv "$tmp_file" "$state_path"
    release_lock "$state_path"
  fi
}

update_state_task() {
  local prd_path="$1"
  local task_id="$2"
  local worker="$3"
  local status="$4"

  if [ "$CONTEXT_ISOLATION" != "true" ]; then
    return 0
  fi

  local state_path=$(get_state_path "$prd_path")

  acquire_lock "$state_path"
  ensure_valid_state "$state_path" "$prd_path"
  local tmp_file=$(brigade_mktemp)

  # Use set +e locally to prevent jq failures from killing the subshell
  set +e
  jq --arg task "$task_id" --arg worker "$worker" --arg status "$status" --arg ts "$(date -Iseconds)" \
    '.currentTask = $task | .taskHistory += [{"taskId": $task, "worker": $worker, "status": $status, "timestamp": $ts}]' \
    "$state_path" > "$tmp_file"
  local jq_exit=$?
  set -e

  if [ $jq_exit -eq 0 ] && [ -s "$tmp_file" ]; then
    mv "$tmp_file" "$state_path"
  else
    echo -e "${YELLOW}Warning: Could not update state for $task_id:$status (jq exit=$jq_exit)${NC}" >&2
    rm -f "$tmp_file"
  fi

  release_lock "$state_path"

  # Update supervisor status file
  write_supervisor_status "$prd_path"

  return 0
}

record_escalation() {
  local prd_path="$1"
  local task_id="$2"
  local from_worker="$3"
  local to_worker="$4"
  local reason="$5"

  if [ "$CONTEXT_ISOLATION" != "true" ]; then
    return
  fi

  local state_path=$(get_state_path "$prd_path")

  acquire_lock "$state_path"
  ensure_valid_state "$state_path" "$prd_path"
  local tmp_file=$(brigade_mktemp)
  jq --arg task "$task_id" --arg from "$from_worker" --arg to "$to_worker" --arg reason "$reason" --arg ts "$(date -Iseconds)" \
    '.escalations += [{"taskId": $task, "from": $from, "to": $to, "reason": $reason, "timestamp": $ts}]' \
    "$state_path" > "$tmp_file"
  mv "$tmp_file" "$state_path"
  release_lock "$state_path"

  # Emit supervisor event and update status
  emit_supervisor_event "escalation" "$task_id" "$from_worker" "$to_worker"
  write_supervisor_status "$prd_path"
}

record_review() {
  local prd_path="$1"
  local task_id="$2"
  local result="$3"
  local reason="$4"

  if [ "$CONTEXT_ISOLATION" != "true" ]; then
    return
  fi

  local state_path=$(get_state_path "$prd_path")

  acquire_lock "$state_path"
  ensure_valid_state "$state_path" "$prd_path"
  local tmp_file=$(brigade_mktemp)
  jq --arg task "$task_id" --arg result "$result" --arg reason "$reason" --arg ts "$(date -Iseconds)" \
    '.reviews += [{"taskId": $task, "result": $result, "reason": $reason, "timestamp": $ts}]' \
    "$state_path" > "$tmp_file"
  mv "$tmp_file" "$state_path"
  release_lock "$state_path"

  # Emit supervisor event and update status
  emit_supervisor_event "review" "$task_id" "$result"
  write_supervisor_status "$prd_path"
}

record_absorption() {
  local prd_path="$1"
  local task_id="$2"
  local absorbed_by="$3"

  if [ "$CONTEXT_ISOLATION" != "true" ]; then
    return
  fi

  local state_path=$(get_state_path "$prd_path")

  acquire_lock "$state_path"
  ensure_valid_state "$state_path" "$prd_path"
  local tmp_file=$(brigade_mktemp)
  jq --arg task "$task_id" --arg absorbed_by "$absorbed_by" --arg ts "$(date -Iseconds)" \
    '.absorptions += [{"taskId": $task, "absorbedBy": $absorbed_by, "timestamp": $ts}]' \
    "$state_path" > "$tmp_file"
  mv "$tmp_file" "$state_path"
  release_lock "$state_path"
}

record_phase_review() {
  local prd_path="$1"
  local completed_count="$2"
  local total_count="$3"
  local status="$4"
  local output_file="$5"

  if [ "$CONTEXT_ISOLATION" != "true" ]; then
    return
  fi

  local state_path=$(get_state_path "$prd_path")

  # Extract the phase_review content from output (outside lock to minimize lock time)
  local review_content=""
  if [ -f "$output_file" ]; then
    review_content=$(sed -n '/<phase_review>/,/<\/phase_review>/p' "$output_file" 2>/dev/null | head -50)
  fi

  acquire_lock "$state_path"
  ensure_valid_state "$state_path" "$prd_path"
  local tmp_file=$(brigade_mktemp)
  jq --arg completed "$completed_count" --arg total "$total_count" \
     --arg status "$status" --arg content "$review_content" --arg ts "$(date -Iseconds)" \
    '.phaseReviews += [{"completedTasks": ($completed | tonumber), "totalTasks": ($total | tonumber), "status": $status, "content": $content, "timestamp": $ts}]' \
    "$state_path" > "$tmp_file"
  mv "$tmp_file" "$state_path"
  release_lock "$state_path"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SUPERVISOR INTEGRATION
# ═══════════════════════════════════════════════════════════════════════════════

# Write compact status JSON to SUPERVISOR_STATUS_FILE
# Called after state changes so supervisors can poll the file instead of running commands
write_supervisor_status() {
  local prd_path="$1"

  # Skip if not configured
  [ -z "$SUPERVISOR_STATUS_FILE" ] && return 0

  local state_path=$(get_state_path "$prd_path")
  local total=$(get_task_count "$prd_path")
  local done=$(jq '[.tasks[] | select(.passes == true)] | length' "$prd_path")

  # Get current task info
  local current=""
  local worker=""
  local elapsed=0
  local attention=false
  local reason=""

  if [ -f "$state_path" ]; then
    current=$(jq -r '.currentTask // empty' "$state_path")

    if [ -n "$current" ]; then
      local last_entry=$(jq -r --arg task "$current" \
        '[.taskHistory[] | select(.taskId == $task)] | last // {}' "$state_path")
      worker=$(echo "$last_entry" | jq -r '.worker // empty')
      local status=$(echo "$last_entry" | jq -r '.status // empty')

      # Calculate elapsed time
      local start_ts=$(echo "$last_entry" | jq -r '.timestamp // empty')
      if [ -n "$start_ts" ]; then
        local start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${start_ts%.*}" "+%s" 2>/dev/null || \
                           date -d "${start_ts}" "+%s" 2>/dev/null || echo 0)
        local now_epoch=$(date "+%s")
        elapsed=$((now_epoch - start_epoch))
        [ $elapsed -lt 0 ] && elapsed=0
      fi

      # Check attention conditions
      case "$status" in
        blocked) attention=true; reason="blocked" ;;
        verification_failed) attention=true; reason="verification_failed" ;;
        review_failed) attention=true; reason="review_failed" ;;
        skipped) attention=true; reason="skipped" ;;
      esac
    fi

    # Check for executive escalation
    if [ "$attention" = "false" ]; then
      local prd_task_ids=$(jq -r '[.tasks[].id] | @json' "$prd_path")
      local exec_escalations=$(jq --argjson ids "$prd_task_ids" \
        '[(.escalations // [])[] | select(.taskId as $tid | $ids | index($tid)) | select(.to == "executive")] | length' \
        "$state_path" 2>/dev/null || echo 0)
      if [ "$exec_escalations" -gt 0 ]; then
        attention=true
        reason="escalated_to_executive"
      fi
    fi
  fi

  # Write atomically (tmp file + mv)
  local tmp_file=$(brigade_mktemp)
  if [ "$attention" = "true" ]; then
    printf '{"done":%d,"total":%d,"current":%s,"worker":%s,"elapsed":%d,"attention":true,"reason":"%s"}\n' \
      "$done" "$total" \
      "$([ -n "$current" ] && echo "\"$current\"" || echo "null")" \
      "$([ -n "$worker" ] && echo "\"$worker\"" || echo "null")" \
      "$elapsed" "$reason" > "$tmp_file"
  else
    printf '{"done":%d,"total":%d,"current":%s,"worker":%s,"elapsed":%d,"attention":false}\n' \
      "$done" "$total" \
      "$([ -n "$current" ] && echo "\"$current\"" || echo "null")" \
      "$([ -n "$worker" ] && echo "\"$worker\"" || echo "null")" \
      "$elapsed" > "$tmp_file"
  fi
  mv "$tmp_file" "$SUPERVISOR_STATUS_FILE"
}

# Emit event to SUPERVISOR_EVENTS_FILE (append-only JSONL)
# Events: service_start, task_start, task_complete, escalation, review, attention, service_complete
emit_supervisor_event() {
  local event_type="$1"
  shift

  # Skip if not configured
  [ -z "$SUPERVISOR_EVENTS_FILE" ] && return 0

  local ts=$(date -Iseconds)

  # Build event JSON based on type
  case "$event_type" in
    service_start)
      local prd="$1" total="$2"
      printf '{"ts":"%s","event":"service_start","prd":"%s","total":%d}\n' "$ts" "$prd" "$total"
      ;;
    task_start)
      local task="$1" worker="$2"
      printf '{"ts":"%s","event":"task_start","task":"%s","worker":"%s"}\n' "$ts" "$task" "$worker"
      ;;
    task_complete)
      local task="$1" worker="$2" duration="$3"
      printf '{"ts":"%s","event":"task_complete","task":"%s","worker":"%s","duration":%d}\n' "$ts" "$task" "$worker" "$duration"
      ;;
    task_blocked)
      local task="$1" worker="$2"
      printf '{"ts":"%s","event":"task_blocked","task":"%s","worker":"%s"}\n' "$ts" "$task" "$worker"
      ;;
    task_absorbed)
      local task="$1" absorbed_by="$2"
      printf '{"ts":"%s","event":"task_absorbed","task":"%s","absorbed_by":"%s"}\n' "$ts" "$task" "$absorbed_by"
      ;;
    task_already_done)
      local task="$1"
      printf '{"ts":"%s","event":"task_already_done","task":"%s"}\n' "$ts" "$task"
      ;;
    escalation)
      local task="$1" from="$2" to="$3"
      printf '{"ts":"%s","event":"escalation","task":"%s","from":"%s","to":"%s"}\n' "$ts" "$task" "$from" "$to"
      ;;
    review)
      local task="$1" result="$2"
      printf '{"ts":"%s","event":"review","task":"%s","result":"%s"}\n' "$ts" "$task" "$result"
      ;;
    verification)
      local task="$1" result="$2"
      printf '{"ts":"%s","event":"verification","task":"%s","result":"%s"}\n' "$ts" "$task" "$result"
      ;;
    attention)
      local task="$1" reason="$2"
      printf '{"ts":"%s","event":"attention","task":"%s","reason":"%s"}\n' "$ts" "$task" "$reason"
      ;;
    service_complete)
      local completed="$1" failed="$2" duration="$3"
      printf '{"ts":"%s","event":"service_complete","completed":%d,"failed":%d,"duration":%d}\n' "$ts" "$completed" "$failed" "$duration"
      ;;
    decision_needed)
      # Decision needed event - supervisor should respond via SUPERVISOR_CMD_FILE
      # Args: decision_id, decision_type, task_id, context_json
      local decision_id="$1" decision_type="$2" task_id="$3" context="$4"
      printf '{"ts":"%s","event":"decision_needed","id":"%s","type":"%s","task":"%s","context":%s}\n' "$ts" "$decision_id" "$decision_type" "$task_id" "$context"
      ;;
    decision_received)
      # Decision received from supervisor
      local decision_id="$1" action="$2"
      printf '{"ts":"%s","event":"decision_received","id":"%s","action":"%s"}\n' "$ts" "$decision_id" "$action"
      ;;
    scope_decision)
      # Scope question decided by exec chef in walkaway mode
      local task="$1" question="$2" decision="$3"
      printf '{"ts":"%s","event":"scope_decision","task":"%s","question":"%s","decision":"%s"}\n' "$ts" "$task" "$question" "$decision"
      ;;
    *)
      printf '{"ts":"%s","event":"%s"}\n' "$ts" "$event_type"
      ;;
  esac >> "$SUPERVISOR_EVENTS_FILE"
}

# Generate unique decision ID
generate_decision_id() {
  printf "d-%s-%04d" "$(date +%s)" "$$"
}

# Wait for supervisor command or fall back to alternative decision methods
# Args: decision_type, task_id, context_json, prd_path, [last_worker]
# Returns: 0=retry, 1=skip, 2=abort
# Sets: DECISION_REASON, DECISION_GUIDANCE
wait_for_decision() {
  local decision_type="$1"
  local task_id="$2"
  local context="$3"
  local prd_path="$4"
  local last_worker="${5:-unknown}"

  DECISION_REASON=""
  DECISION_GUIDANCE=""

  local decision_id=$(generate_decision_id)

  # If supervisor is configured, use supervisor mode
  if [ -n "$SUPERVISOR_CMD_FILE" ]; then
    return $(wait_for_supervisor_command "$decision_id" "$decision_type" "$task_id" "$context" "$prd_path")
  fi

  # Otherwise, fall back to walkaway mode or interactive
  if [ "$WALKAWAY_MODE" == "true" ]; then
    # Extract failure reason from context
    local failure_reason=$(echo "$context" | jq -r '.failureReason // "failed"' 2>/dev/null)
    local iteration_count=$(echo "$context" | jq -r '.iterations // 0' 2>/dev/null)

    walkaway_decide_resume "$prd_path" "$task_id" "$failure_reason" "$iteration_count" "$last_worker"
    local result=$?
    DECISION_REASON="$WALKAWAY_DECISION_REASON"
    return $result
  fi

  # Interactive fallback
  echo -e "What would you like to do?"
  echo -e "  ${CYAN}retry${NC} - Retry the interrupted task from scratch"
  echo -e "  ${CYAN}skip${NC}  - Mark as failed and continue to next task"
  echo ""
  read -p "Enter choice [retry/skip]: " action

  case "$action" in
    retry|r)
      DECISION_REASON="User chose to retry"
      return 0
      ;;
    skip|s)
      DECISION_REASON="User chose to skip"
      return 1
      ;;
    *)
      echo -e "${RED}Invalid choice. Defaulting to retry.${NC}"
      DECISION_REASON="Invalid choice, defaulted to retry"
      return 0
      ;;
  esac
}

# Wait for command from supervisor via SUPERVISOR_CMD_FILE
# Args: decision_id, decision_type, task_id, context_json, prd_path
# Returns: 0=retry, 1=skip, 2=abort
wait_for_supervisor_command() {
  local decision_id="$1"
  local decision_type="$2"
  local task_id="$3"
  local context="$4"
  local prd_path="$5"

  local display_id=$(format_task_id "$prd_path" "$task_id")

  # Emit decision_needed event
  emit_supervisor_event "decision_needed" "$decision_id" "$decision_type" "$display_id" "$context"

  log_event "SUPERVISOR" "Waiting for decision: $decision_id ($decision_type for $display_id)"
  echo -e "${CYAN}Waiting for supervisor decision...${NC}"
  echo -e "${GRAY}Decision ID: $decision_id${NC}"
  echo -e "${GRAY}Command file: $SUPERVISOR_CMD_FILE${NC}"

  local start_time=$(date +%s)
  local cmd_found=false

  # Poll for command file
  while true; do
    # Check timeout
    if [ "$SUPERVISOR_CMD_TIMEOUT" -gt 0 ]; then
      local elapsed=$(($(date +%s) - start_time))
      if [ "$elapsed" -ge "$SUPERVISOR_CMD_TIMEOUT" ]; then
        echo -e "${YELLOW}⚠ Supervisor command timeout (${elapsed}s), falling back to walkaway mode${NC}"

        # Fall back to walkaway mode
        if [ "$WALKAWAY_MODE" == "true" ]; then
          local failure_reason=$(echo "$context" | jq -r '.failureReason // "failed"' 2>/dev/null)
          local iteration_count=$(echo "$context" | jq -r '.iterations // 0' 2>/dev/null)
          local last_worker=$(echo "$context" | jq -r '.lastWorker // "unknown"' 2>/dev/null)

          walkaway_decide_resume "$prd_path" "$task_id" "$failure_reason" "$iteration_count" "$last_worker"
          local result=$?
          DECISION_REASON="Supervisor timeout, walkaway decided: $WALKAWAY_DECISION_REASON"
          return $result
        fi

        # No walkaway mode - abort
        DECISION_REASON="Supervisor timeout, no fallback available"
        return 2
      fi
    fi

    # Check for command file
    if [ -f "$SUPERVISOR_CMD_FILE" ]; then
      # Read and parse command
      local cmd_content=$(cat "$SUPERVISOR_CMD_FILE")
      local cmd_decision_id=$(echo "$cmd_content" | jq -r '.decision // ""' 2>/dev/null)

      # Check if this command is for our decision
      if [ "$cmd_decision_id" == "$decision_id" ]; then
        local action=$(echo "$cmd_content" | jq -r '.action // ""' 2>/dev/null)
        local reason=$(echo "$cmd_content" | jq -r '.reason // ""' 2>/dev/null)
        local guidance=$(echo "$cmd_content" | jq -r '.guidance // ""' 2>/dev/null)

        # Remove the command file to prevent re-reading
        rm -f "$SUPERVISOR_CMD_FILE"

        # Emit decision_received event
        emit_supervisor_event "decision_received" "$decision_id" "$action"

        log_event "SUPERVISOR" "Received decision: $action"
        echo -e "${GREEN}Supervisor decision received: $action${NC}"

        DECISION_REASON="${reason:-Supervisor decision: $action}"
        DECISION_GUIDANCE="$guidance"

        case "$action" in
          retry)
            return 0
            ;;
          skip)
            return 1
            ;;
          abort)
            return 2
            ;;
          pause)
            echo -e "${YELLOW}Supervisor requested pause. Waiting for resume...${NC}"
            # Recursive wait for actual decision
            wait_for_supervisor_command "$decision_id" "$decision_type" "$task_id" "$context" "$prd_path"
            return $?
            ;;
          *)
            echo -e "${RED}Unknown action: $action. Defaulting to retry.${NC}"
            DECISION_REASON="Unknown supervisor action, defaulted to retry"
            return 0
            ;;
        esac
      fi
    fi

    # Sleep before next poll
    sleep "$SUPERVISOR_CMD_POLL_INTERVAL"
  done
}

# ═══════════════════════════════════════════════════════════════════════════════
# KNOWLEDGE SHARING
# ═══════════════════════════════════════════════════════════════════════════════

get_learnings_path() {
  local prd_path="$1"
  local prd_dir=$(dirname "$prd_path")
  echo "$prd_dir/$LEARNINGS_FILE"
}

init_learnings() {
  local prd_path="$1"
  local learnings_path=$(get_learnings_path "$prd_path")

  if [ ! -f "$learnings_path" ]; then
    local feature_name=$(jq -r '.featureName' "$prd_path")
    cat > "$learnings_path" <<EOF
# Brigade Learnings: $feature_name

This file contains learnings shared between workers. Each worker can read this
to learn from previous attempts and share knowledge with the team.

---

EOF
    echo -e "${GRAY}Initialized learnings: $learnings_path${NC}"
  fi
}

get_learnings() {
  local prd_path="$1"

  if [ "$KNOWLEDGE_SHARING" != "true" ]; then
    echo ""
    return
  fi

  local learnings_path=$(get_learnings_path "$prd_path")
  if [ -f "$learnings_path" ]; then
    cat "$learnings_path"
  fi
}

# Prune oldest learnings if file exceeds LEARNINGS_MAX
prune_learnings() {
  local prd_path="$1"

  # Skip if disabled (0 = unlimited)
  [ "$LEARNINGS_MAX" -eq 0 ] 2>/dev/null && return
  [ "$LEARNINGS_MAX" -lt 1 ] 2>/dev/null && return

  local learnings_path=$(get_learnings_path "$prd_path")
  [ ! -f "$learnings_path" ] && return

  # Count learning entries
  local count=$(grep -c '^## \[' "$learnings_path" 2>/dev/null || echo "0")

  # Prune oldest entries until we're at the limit
  while [ "$count" -gt "$LEARNINGS_MAX" ]; do
    # Find the line number of the first learning entry (after header)
    local first_learning_line=$(grep -n '^## \[' "$learnings_path" | head -1 | cut -d: -f1)
    [ -z "$first_learning_line" ] && break

    # Find the line number of the next --- after this learning
    local end_line=$(tail -n +"$first_learning_line" "$learnings_path" | grep -n '^---$' | head -1 | cut -d: -f1)
    [ -z "$end_line" ] && break

    # Calculate absolute line number of end
    end_line=$((first_learning_line + end_line - 1))

    # Remove the learning section (from first_learning_line to end_line, inclusive)
    local tmp_file=$(brigade_mktemp)
    sed "${first_learning_line},${end_line}d" "$learnings_path" > "$tmp_file"
    mv "$tmp_file" "$learnings_path"

    # Recount
    count=$(grep -c '^## \[' "$learnings_path" 2>/dev/null || echo "0")
  done
}

# Archive learnings file on PRD completion
archive_learnings() {
  local prd_path="$1"

  # Skip if disabled
  [ "$LEARNINGS_ARCHIVE" != "true" ] && return

  local learnings_path=$(get_learnings_path "$prd_path")
  [ ! -f "$learnings_path" ] && return

  # Check if there are any learnings to archive
  local count=$(grep -c '^## \[' "$learnings_path" 2>/dev/null || echo "0")
  [ "$count" -eq 0 ] && return

  # Create archive directory
  local prd_dir=$(dirname "$prd_path")
  local archive_dir="$prd_dir/archive"
  mkdir -p "$archive_dir"

  # Generate archive filename: learnings-{prd-prefix}-{date}.md
  local prd_prefix=$(get_prd_prefix "$prd_path")
  local archive_date=$(date "+%Y%m%d-%H%M%S")
  local archive_file="$archive_dir/learnings-${prd_prefix}-${archive_date}.md"

  # Copy learnings to archive
  cp "$learnings_path" "$archive_file"
  echo -e "${GRAY}📚 Learnings archived: $archive_file ($count entries)${NC}"

  # Reset learnings file (keep header, remove entries)
  local feature_name=$(jq -r '.featureName' "$prd_path" 2>/dev/null || echo "Unknown")
  cat > "$learnings_path" <<EOF
# Brigade Learnings: $feature_name

This file contains learnings shared between workers. Each worker can read this
to learn from previous attempts and share knowledge with the team.

---

EOF
}

add_learning() {
  local prd_path="$1"
  local task_id="$2"
  local worker="$3"
  local learning_type="$4"  # success, failure, note
  local content="$5"

  if [ "$KNOWLEDGE_SHARING" != "true" ]; then
    return
  fi

  local learnings_path=$(get_learnings_path "$prd_path")

  # Deduplicate: check if similar learning already exists
  # Extract first 50 chars as a signature to check for duplicates
  local signature=$(echo "$content" | head -c 50 | tr -d '\n')
  if [ -f "$learnings_path" ] && grep -qF "$signature" "$learnings_path" 2>/dev/null; then
    # Similar learning already exists, skip
    return
  fi

  local timestamp=$(date "+%Y-%m-%d %H:%M")
  local worker_name=$(get_worker_name "$worker")

  cat >> "$learnings_path" <<EOF

## [$learning_type] $task_id - $worker_name ($timestamp)

$content

---
EOF

  # Prune oldest if we exceed the limit
  prune_learnings "$prd_path"
}

extract_learnings_from_output() {
  local output_file="$1"
  local prd_path="$2"
  local task_id="$3"
  local worker="$4"

  if [ "$KNOWLEDGE_SHARING" != "true" ]; then
    return
  fi

  # Extract any <learning>...</learning> tags from worker output
  if grep -q "<learning>" "$output_file" 2>/dev/null; then
    local learning=$(sed -n 's/.*<learning>\(.*\)<\/learning>.*/\1/p' "$output_file" | head -5)
    if [ -n "$learning" ]; then
      add_learning "$prd_path" "$task_id" "$worker" "note" "$learning"
      echo -e "${CYAN}📝 Learning captured${NC}"
    fi
  fi
}

search_learnings() {
  local prd_path="$1"
  local task_id="$2"

  if [ "$KNOWLEDGE_SHARING" != "true" ]; then
    echo ""
    return
  fi

  local learnings_path=$(get_learnings_path "$prd_path")
  if [ ! -f "$learnings_path" ]; then
    echo ""
    return
  fi

  # Get task title and acceptance criteria for keyword extraction
  local task_json=$(get_task_by_id "$prd_path" "$task_id")
  local title=$(echo "$task_json" | jq -r '.title // ""')
  local criteria=$(echo "$task_json" | jq -r '.acceptanceCriteria // [] | join(" ")')

  # Extract meaningful keywords (3+ chars, not common words)
  local text="$title $criteria"
  local stopwords="the|and|for|are|but|not|you|all|can|has|have|will|with|this|that|from|they|been|would|there|their|what|about|which|when|make|like|into|just|over|such|more|some|than|them|then|these|only|come|made|find|here|many|your|those|being|most"

  # Get unique keywords (lowercase, 3+ chars, not stopwords)
  local keywords=$(echo "$text" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alpha:]' '\n' | \
    grep -v "^$" | awk 'length >= 3' | grep -vE "^($stopwords)$" | sort -u | head -10)

  if [ -z "$keywords" ]; then
    echo ""
    return
  fi

  # Search learnings file for sections matching keywords
  # Each section starts with "## [" and ends with "---"
  local results=""
  local match_count=0

  # Read file in sections (split on "## [")
  local current_section=""
  local in_section=false

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == "## ["* ]]; then
      # Score and save previous section if it exists
      if [ -n "$current_section" ]; then
        local score=0
        local section_lower=$(echo "$current_section" | tr '[:upper:]' '[:lower:]')
        for kw in $keywords; do
          if echo "$section_lower" | grep -q "$kw"; then
            score=$((score + 1))
          fi
        done
        if [ $score -gt 0 ]; then
          results="${results}${score}|${current_section}
SECTION_BREAK
"
        fi
      fi
      current_section="$line"
      in_section=true
    elif [ "$in_section" == "true" ]; then
      current_section="${current_section}
${line}"
      if [ "$line" == "---" ]; then
        in_section=false
      fi
    fi
  done < "$learnings_path"

  # Handle last section
  if [ -n "$current_section" ]; then
    local score=0
    local section_lower=$(echo "$current_section" | tr '[:upper:]' '[:lower:]')
    for kw in $keywords; do
      if echo "$section_lower" | grep -q "$kw"; then
        score=$((score + 1))
      fi
    done
    if [ $score -gt 0 ]; then
      results="${results}${score}|${current_section}"
    fi
  fi

  # Sort by score (descending) and take top 3
  if [ -n "$results" ]; then
    echo "$results" | sed 's/SECTION_BREAK/\n/g' | grep -v "^$" | \
      sort -t'|' -k1 -rn | head -3 | cut -d'|' -f2-
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# BACKLOG CAPTURE
# ═══════════════════════════════════════════════════════════════════════════════

get_backlog_path() {
  local prd_path="$1"
  local prd_dir=$(dirname "$prd_path")
  echo "$prd_dir/$BACKLOG_FILE"
}

add_backlog_item() {
  local prd_path="$1"
  local task_id="$2"
  local worker="$3"
  local item="$4"

  local backlog_path=$(get_backlog_path "$prd_path")
  local feature_name=$(jq -r '.featureName' "$prd_path")
  local timestamp=$(date "+%Y-%m-%d %H:%M")

  # Initialize file if needed
  if [ ! -f "$backlog_path" ]; then
    cat > "$backlog_path" <<EOF
# Brigade Backlog: $feature_name

Out-of-scope items discovered during execution. Review after PRD completion
to inform future planning.

---

EOF
  fi

  # Append the backlog item (include feature name for multi-PRD clarity)
  cat >> "$backlog_path" <<EOF
## [$feature_name / $task_id] $timestamp
**Reported by:** $(get_worker_name "$worker")

$item

---

EOF
}

extract_backlog_from_output() {
  local output_file="$1"
  local prd_path="$2"
  local task_id="$3"
  local worker="$4"

  # Extract any <backlog>...</backlog> tags from worker output
  if grep -q "<backlog>" "$output_file" 2>/dev/null; then
    local item=$(sed -n 's/.*<backlog>\(.*\)<\/backlog>.*/\1/p' "$output_file" | head -5)
    if [ -n "$item" ]; then
      add_backlog_item "$prd_path" "$task_id" "$worker" "$item"
      echo -e "${YELLOW}📋 Backlog item captured${NC}"
    fi
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# SCOPE DECISIONS (Walkaway Mode)
# ═══════════════════════════════════════════════════════════════════════════════

# Record scope decision to state file for later review
record_scope_decision() {
  local prd_path="$1"
  local task_id="$2"
  local question="$3"
  local decision="$4"
  local rationale="$5"

  local state_path=$(get_state_path "$prd_path")
  if [ ! -f "$state_path" ]; then
    return 0
  fi

  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")

  # Acquire lock for atomic state update
  acquire_lock "$state_path"

  local tmp_file=$(brigade_mktemp)
  jq --arg task "$task_id" \
     --arg question "$question" \
     --arg decision "$decision" \
     --arg rationale "$rationale" \
     --arg ts "$timestamp" \
     '.scopeDecisions = (.scopeDecisions // []) + [{
       "taskId": $task,
       "question": $question,
       "decision": $decision,
       "rationale": $rationale,
       "timestamp": $ts,
       "reviewedByHuman": false
     }]' "$state_path" > "$tmp_file"
  mv "$tmp_file" "$state_path"

  release_lock "$state_path"

  # Emit event for supervisor
  emit_supervisor_event "scope_decision" "$task_id" "$question" "$decision"
}

# Build prompt for exec chef to decide on a scope question
build_scope_decision_prompt() {
  local prd_path="$1"
  local task_id="$2"
  local question="$3"
  local context="$4"

  local feature_name=$(jq -r '.featureName' "$prd_path")
  local task_title=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .title' "$prd_path")
  local task_ac=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .acceptanceCriteria | join("\n  - ")' "$prd_path")

  # Get PRD constraints if available
  local constraints=$(jq -r '.constraints // [] | if length > 0 then "CONSTRAINTS:\n" + (map("- " + .) | join("\n")) else "" end' "$prd_path" 2>/dev/null)
  local decisions=$(jq -r '.decisions // {} | if . != {} then "PRIOR DECISIONS:\n" + (to_entries | map("- " + .key + ": " + .value) | join("\n")) else "" end' "$prd_path" 2>/dev/null)

  cat <<EOF
You are the Executive Chef (Director) making a scope decision for a task.

WALKAWAY MODE ACTIVE: Make a judgment call. The human will review later.

FEATURE: $feature_name
TASK: $task_id - $task_title

ACCEPTANCE CRITERIA:
  - $task_ac

${constraints:+$constraints

}${decisions:+$decisions

}SCOPE QUESTION:
$question

${context:+CONTEXT:
$context

}---

Make a decision that:
1. Stays within the spirit of the task and feature goals
2. Is conservative (prefer simpler solutions when unclear)
3. Maintains security and quality standards
4. Can be easily reviewed/reversed later if wrong

Respond with:
<scope-decision>Your decision (what to do)</scope-decision>
<scope-rationale>Brief explanation of why</scope-rationale>
EOF
}

# Ask Executive Chef to decide on a scope question
# Returns the decision text
# Sets: SCOPE_DECISION_RATIONALE
decide_scope_question() {
  local prd_path="$1"
  local task_id="$2"
  local question="$3"
  local context="${4:-}"

  SCOPE_DECISION_RATIONALE=""

  local display_id=$(format_task_id "$prd_path" "$task_id")

  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
  log_event "SCOPE" "Exec Chef deciding scope question for: $display_id"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo -e "${GRAY}Question: $question${NC}"
  echo ""

  local decision_prompt=$(build_scope_decision_prompt "$prd_path" "$task_id" "$question" "$context")
  local output_file=$(brigade_mktemp)

  # Execute with timeout
  if command -v timeout &>/dev/null; then
    timeout "$WALKAWAY_DECISION_TIMEOUT" $EXECUTIVE_CMD --dangerously-skip-permissions -p "$decision_prompt" 2>&1 | tee "$output_file"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$WALKAWAY_DECISION_TIMEOUT" $EXECUTIVE_CMD --dangerously-skip-permissions -p "$decision_prompt" 2>&1 | tee "$output_file"
  else
    $EXECUTIVE_CMD --dangerously-skip-permissions -p "$decision_prompt" 2>&1 | tee "$output_file"
  fi

  # Extract decision and rationale
  local decision=$(sed -n 's/.*<scope-decision>\(.*\)<\/scope-decision>.*/\1/p' "$output_file" 2>/dev/null | head -1)
  SCOPE_DECISION_RATIONALE=$(sed -n 's/.*<scope-rationale>\(.*\)<\/scope-rationale>.*/\1/p' "$output_file" 2>/dev/null | head -1)

  rm -f "$output_file"

  if [ -z "$decision" ]; then
    decision="Continue with conservative approach (no clear decision from exec chef)"
    SCOPE_DECISION_RATIONALE="Exec chef did not provide clear decision signal"
  fi

  # Record decision in state for human review
  record_scope_decision "$prd_path" "$task_id" "$question" "$decision" "$SCOPE_DECISION_RATIONALE"

  log_event "SCOPE" "Decision: $decision"
  echo -e "${GREEN}Scope decision: $decision${NC}"
  echo -e "${GRAY}Rationale: $SCOPE_DECISION_RATIONALE${NC}"
  echo -e "${YELLOW}⚠ Flagged for human review${NC}"

  echo "$decision"
}

# Extract and handle scope questions from worker output
# In walkaway mode, asks exec chef to decide; otherwise logs for human attention
extract_scope_questions_from_output() {
  local output_file="$1"
  local prd_path="$2"
  local task_id="$3"
  local worker="$4"

  # Check for scope questions
  if ! grep -q "<scope-question>" "$output_file" 2>/dev/null; then
    return 0
  fi

  local question=$(sed -n 's/.*<scope-question>\(.*\)<\/scope-question>.*/\1/p' "$output_file" | head -1)
  if [ -z "$question" ]; then
    return 0
  fi

  echo -e "${YELLOW}❓ Scope question detected${NC}"

  if [ "$WALKAWAY_MODE" == "true" ] && [ "$WALKAWAY_SCOPE_DECISIONS" == "true" ]; then
    # In walkaway mode, let exec chef decide
    local decision=$(decide_scope_question "$prd_path" "$task_id" "$question")
    # Decision is recorded in decide_scope_question
    return 0
  elif [ -n "$SUPERVISOR_CMD_FILE" ]; then
    # Emit event for supervisor to handle
    local context='{"question":"'"$question"'","worker":"'"$worker"'"}'
    emit_supervisor_event "decision_needed" "$(generate_decision_id)" "scope_question" "$task_id" "$context"
    log_event "SCOPE" "Scope question emitted for supervisor: $question"
    return 0
  else
    # Log for human attention
    log_event "SCOPE" "Scope question needs human input: $question"
    echo -e "${RED}⚠ Scope question requires human decision:${NC}"
    echo -e "${YELLOW}  $question${NC}"
    emit_supervisor_event "attention" "$task_id" "Scope question: $question"
    return 1  # Signal that human attention is needed
  fi
}

# Get pending scope decisions that need human review
get_pending_scope_decisions() {
  local prd_path="$1"

  local state_path=$(get_state_path "$prd_path")
  if [ ! -f "$state_path" ]; then
    echo "[]"
    return
  fi

  jq '[(.scopeDecisions // [])[] | select(.reviewedByHuman == false)]' "$state_path" 2>/dev/null || echo "[]"
}

# Mark a scope decision as reviewed by human
mark_scope_decision_reviewed() {
  local prd_path="$1"
  local index="$2"

  local state_path=$(get_state_path "$prd_path")
  if [ ! -f "$state_path" ]; then
    return 1
  fi

  acquire_lock "$state_path"

  local tmp_file=$(brigade_mktemp)
  jq --argjson idx "$index" '.scopeDecisions[$idx].reviewedByHuman = true' "$state_path" > "$tmp_file"
  mv "$tmp_file" "$state_path"

  release_lock "$state_path"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ROUTING LOGIC
# ═══════════════════════════════════════════════════════════════════════════════

route_task() {
  local prd_path="$1"
  local task_id="$2"

  local complexity=$(get_task_complexity "$prd_path" "$task_id")

  case "$complexity" in
    "junior"|"line")
      echo "line"
      ;;
    "senior"|"sous")
      echo "sous"
      ;;
    "auto"|*)
      # Let executive chef decide (for now, default to sous for safety)
      echo "sous"
      ;;
  esac
}

get_worker_cmd() {
  local worker="$1"

  case "$worker" in
    "line")
      echo "$LINE_CMD"
      ;;
    "sous")
      echo "$SOUS_CMD"
      ;;
    "executive")
      echo "$EXECUTIVE_CMD"
      ;;
  esac
}

get_worker_agent() {
  local worker="$1"

  case "$worker" in
    "line")
      echo "${LINE_AGENT:-opencode}"
      ;;
    "sous")
      echo "${SOUS_AGENT:-claude}"
      ;;
    "executive")
      echo "${EXECUTIVE_AGENT:-claude}"
      ;;
  esac
}

get_worker_name() {
  local worker="$1"

  case "$worker" in
    "line")
      echo "Line Cook"
      ;;
    "sous")
      echo "Sous Chef"
      ;;
    "executive")
      echo "Executive Chef"
      ;;
  esac
}

get_worker_timeout() {
  local worker="$1"

  case "$worker" in
    "line")
      echo "$TASK_TIMEOUT_JUNIOR"
      ;;
    "sous")
      echo "$TASK_TIMEOUT_SENIOR"
      ;;
    "executive")
      echo "$TASK_TIMEOUT_EXECUTIVE"
      ;;
    *)
      echo "$TASK_TIMEOUT_SENIOR"  # Default to senior timeout
      ;;
  esac
}

get_default_branch() {
  # Use configured value if set
  if [ -n "${DEFAULT_BRANCH:-}" ]; then
    echo "$DEFAULT_BRANCH"
    return
  fi

  # Auto-detect from origin
  local detected=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  if [ -n "$detected" ]; then
    echo "$detected"
    return
  fi

  # Fallback: check if main or master exists
  if git show-ref --verify --quiet refs/heads/main 2>/dev/null; then
    echo "main"
  elif git show-ref --verify --quiet refs/heads/master 2>/dev/null; then
    echo "master"
  else
    # Last resort default
    echo "main"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TASK EXECUTION
# ═══════════════════════════════════════════════════════════════════════════════

build_prompt() {
  local prd_path="$1"
  local task_id="$2"
  local chef_prompt="$3"

  local task_json=$(get_task_by_id "$prd_path" "$task_id")
  local feature_name=$(jq -r '.featureName' "$prd_path")

  # Search for relevant learnings based on task keywords
  local relevant_learnings=$(search_learnings "$prd_path" "$task_id")

  local learnings_section=""
  if [ -n "$relevant_learnings" ] && [ "$KNOWLEDGE_SHARING" == "true" ]; then
    learnings_section="
---
RELEVANT LEARNINGS (from previous tasks - matched by keywords):
$relevant_learnings
---
"
  fi

  # Include review feedback if previous attempt failed review
  local review_feedback_section=""
  if [ -n "$LAST_REVIEW_FEEDBACK" ]; then
    review_feedback_section="
---
⚠️ PREVIOUS ATTEMPT FAILED EXECUTIVE REVIEW:
$LAST_REVIEW_FEEDBACK

Please address this feedback in your implementation.
---
"
  fi

  # Include verification feedback if previous attempt failed verification
  local verification_feedback_section=""
  if [ -n "$LAST_VERIFICATION_FEEDBACK" ]; then
    verification_feedback_section="
---
⚠️ PREVIOUS ATTEMPT FAILED VERIFICATION:
$LAST_VERIFICATION_FEEDBACK
---
"
  fi

  # Include TODO warnings if previous attempt had incomplete markers
  local todo_feedback_section=""
  if [ -n "$LAST_TODO_WARNINGS" ]; then
    todo_feedback_section="
---
⚠️ PREVIOUS ATTEMPT HAD INCOMPLETE TODO/FIXME MARKERS:
$LAST_TODO_WARNINGS
---
"
  fi

  # Include verification commands if present (so worker knows what will be checked)
  local verification_section=""
  if [ "$VERIFICATION_ENABLED" == "true" ]; then
    local verification_cmds=$(get_verification_commands "$prd_path" "$task_id")
    if [ -n "$verification_cmds" ]; then
      verification_section="
---
VERIFICATION COMMANDS (will be run after you signal COMPLETE):
$verification_cmds

Tip: Run these yourself before signaling COMPLETE to ensure they pass.
---
"
    fi
  fi

  cat <<EOF
$chef_prompt
$learnings_section$review_feedback_section$verification_feedback_section$todo_feedback_section$verification_section
---
FEATURE: $feature_name
PRD_FILE: $prd_path

CURRENT TASK:
$task_json

INSTRUCTIONS:
1. Complete the task described above
2. Ensure all acceptance criteria are met
3. Run tests if applicable
4. When complete, output: <promise>COMPLETE</promise>
5. If blocked, output: <promise>BLOCKED</promise> with explanation
6. If already done by a prior task, output: <promise>ALREADY_DONE</promise>
7. If absorbed by a prior task (prior task completed this work), output: <promise>ABSORBED_BY:US-XXX</promise> (replace US-XXX with the task ID)
8. Share useful learnings with: <learning>What you learned</learning>
9. Log out-of-scope discoveries with: <backlog>Description of issue or enhancement</backlog>
10. For scope/requirement ambiguities, ask: <scope-question>Your question about scope or approach</scope-question>

BEGIN WORK:
EOF
}

fire_ticket() {
  local prd_path="$1"
  local task_id="$2"
  local worker="$3"
  local worker_timeout="${4:-0}"  # Timeout in seconds, 0 = no timeout

  # Set global context for visibility features (heartbeat, timeout warnings)
  CURRENT_PRD_PATH="$prd_path"
  CURRENT_TASK_ID="$task_id"
  CURRENT_WORKER="$worker"
  CURRENT_TASK_WARNING_SHOWN=false
  CURRENT_TASK_START_TIME=$(date +%s)

  local worker_name=$(get_worker_name "$worker")
  local worker_cmd=$(get_worker_cmd "$worker")
  local worker_agent=$(get_worker_agent "$worker")
  local chef_prompt_file="$CHEF_DIR/${worker}.md"

  local chef_prompt=""
  if [ -f "$chef_prompt_file" ]; then
    chef_prompt=$(cat "$chef_prompt_file")
  fi

  local task_title=$(jq -r ".tasks[] | select(.id == \"$task_id\") | .title" "$prd_path")
  local display_id=$(format_task_id "$prd_path" "$task_id")

  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  log_event "START" "TASK: $display_id - $task_title"
  echo -e "${GRAY}Worker: $worker_name (agent: $worker_agent)${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo ""

  # Emit supervisor event for task start
  emit_supervisor_event "task_start" "$task_id" "$worker"

  local full_prompt=$(build_prompt "$prd_path" "$task_id" "$chef_prompt")
  local output_file=$(brigade_mktemp)

  # Get worker log file path (empty if logging disabled)
  local worker_log=$(get_worker_log_path "$prd_path" "$task_id" "$worker")
  if [ -n "$worker_log" ]; then
    echo -e "${GRAY}Worker log: $worker_log${NC}"
  fi

  # Execute worker based on agent type
  local start_time=$(date +%s)

  # Show timeout info if set
  if [ "$worker_timeout" -gt 0 ]; then
    local timeout_mins=$((worker_timeout / 60))
    echo -e "${GRAY}Worker timeout: ${timeout_mins}m${NC}"
  fi

  # Helper to handle exit code and timeout/crash detection
  handle_worker_exit() {
    local exit_code=$1
    if [ "$exit_code" -eq 124 ]; then
      echo -e "${RED}Worker TIMED OUT after $((worker_timeout / 60))m${NC}"
      echo "<promise>BLOCKED</promise>" >> "$output_file"
      echo "Worker process timed out and was killed." >> "$output_file"
    elif [ "$exit_code" -eq "${WORKER_CRASH_EXIT_CODE:-125}" ]; then
      echo -e "${RED}Worker CRASHED unexpectedly${NC}"
      echo "<promise>BLOCKED</promise>" >> "$output_file"
      echo "Worker process crashed unexpectedly. This may indicate a bug in the worker or resource exhaustion." >> "$output_file"
      log_event "ERROR" "Worker crashed for task $task_id - will escalate"
    elif [ "$exit_code" -eq 0 ]; then
      echo -e "${GREEN}Worker completed${NC}"
    elif [ "$exit_code" -gt 128 ]; then
      # Killed by signal
      local signal=$((exit_code - 128))
      echo -e "${RED}Worker killed by signal $signal${NC}"
      echo "<promise>BLOCKED</promise>" >> "$output_file"
      echo "Worker was killed by signal $signal." >> "$output_file"
    else
      echo -e "${YELLOW}Worker exited (code: $exit_code)${NC}"
    fi
  }

  case "$worker_agent" in
    "claude")
      # Claude CLI: claude --dangerously-skip-permissions -p "prompt"
      local claude_flags=""
      if [ "$CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS" == "true" ]; then
        claude_flags="--dangerously-skip-permissions"
      fi
      if [ "$QUIET_WORKERS" == "true" ]; then
        if [ "$worker_timeout" -gt 0 ]; then
          run_with_timeout "$worker_timeout" $worker_cmd $claude_flags -p "$full_prompt" > "$output_file" 2>&1
        else
          $worker_cmd $claude_flags -p "$full_prompt" > "$output_file" 2>&1
        fi
        handle_worker_exit $?
      else
        if [ "$worker_timeout" -gt 0 ]; then
          run_with_timeout "$worker_timeout" $worker_cmd $claude_flags -p "$full_prompt" 2>&1 | tee "$output_file"
          handle_worker_exit ${PIPESTATUS[0]}
        else
          $worker_cmd $claude_flags -p "$full_prompt" 2>&1 | tee "$output_file"
          handle_worker_exit ${PIPESTATUS[0]}
        fi
      fi
      ;;

    "opencode")
      # OpenCode CLI: opencode run [options] "prompt"
      # See: https://opencode.ai/docs/cli/
      local opencode_flags="--log-level ERROR --no-print-logs"
      if [ -n "$OPENCODE_MODEL" ]; then
        opencode_flags="$opencode_flags --model $OPENCODE_MODEL"
      fi
      if [ -n "$OPENCODE_SERVER" ]; then
        opencode_flags="$opencode_flags --attach $OPENCODE_SERVER"
      fi
      if [ "$QUIET_WORKERS" == "true" ]; then
        if [ "$worker_timeout" -gt 0 ]; then
          run_with_timeout "$worker_timeout" $worker_cmd $opencode_flags "$full_prompt" > "$output_file" 2>&1
        else
          $worker_cmd $opencode_flags "$full_prompt" > "$output_file" 2>&1
        fi
        handle_worker_exit $?
      else
        if [ "$worker_timeout" -gt 0 ]; then
          run_with_timeout "$worker_timeout" $worker_cmd $opencode_flags "$full_prompt" 2>&1 | tee "$output_file"
          handle_worker_exit ${PIPESTATUS[0]}
        else
          $worker_cmd $opencode_flags "$full_prompt" 2>&1 | tee "$output_file"
          handle_worker_exit ${PIPESTATUS[0]}
        fi
      fi
      ;;

    "codex")
      # OpenAI Codex (coming soon)
      echo -e "${YELLOW}Codex agent not yet implemented${NC}"
      return 1
      ;;

    "gemini")
      # Google Gemini (coming soon)
      echo -e "${YELLOW}Gemini agent not yet implemented${NC}"
      return 1
      ;;

    "aider")
      # Aider (coming soon)
      echo -e "${YELLOW}Aider agent not yet implemented${NC}"
      return 1
      ;;

    "local"|"ollama")
      # Local models via Ollama (coming soon)
      echo -e "${YELLOW}Local/Ollama agent not yet implemented${NC}"
      return 1
      ;;

    *)
      # Generic fallback - pipe prompt to command
      if [ "$QUIET_WORKERS" == "true" ]; then
        if echo "$full_prompt" | $worker_cmd > "$output_file" 2>&1; then
          echo -e "${GREEN}Worker completed${NC}"
        else
          echo -e "${YELLOW}Worker exited${NC}"
        fi
      else
        if echo "$full_prompt" | $worker_cmd 2>&1 | tee "$output_file"; then
          echo -e "${GREEN}Worker completed${NC}"
        else
          echo -e "${YELLOW}Worker exited${NC}"
        fi
      fi
      ;;
  esac

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  echo -e "${GRAY}Duration: ${duration}s${NC}"

  # Copy output to worker log file if enabled (for debugging and post-mortems)
  if [ -n "$worker_log" ] && [ -f "$output_file" ]; then
    {
      echo "═══════════════════════════════════════════════════════════"
      echo "Task: $display_id - $task_title"
      echo "Worker: $worker_name ($worker_agent)"
      echo "Started: $(date -r $start_time '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d @$start_time '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'unknown')"
      echo "Duration: ${duration}s"
      echo "═══════════════════════════════════════════════════════════"
      echo ""
      cat "$output_file"
    } >> "$worker_log"
    echo -e "${GRAY}Output saved to: $worker_log${NC}"
  fi

  # Write final heartbeat
  if [ -n "$ACTIVITY_LOG" ]; then
    local ts=$(date "+%H:%M:%S")
    echo "[$ts] $display_id: completed (${duration}s)" >> "$ACTIVITY_LOG"
  fi

  # Clear global context
  CURRENT_TASK_ID=""

  # Extract any learnings shared by the worker
  extract_learnings_from_output "$output_file" "$prd_path" "$task_id" "$worker"

  # Extract any backlog items (out-of-scope discoveries)
  extract_backlog_from_output "$output_file" "$prd_path" "$task_id" "$worker"

  # Handle any scope questions (in walkaway mode, exec chef decides)
  extract_scope_questions_from_output "$output_file" "$prd_path" "$task_id" "$worker"

  # Check for completion signal
  # Debug: log output file details for parallel execution debugging
  if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
    echo "[DEBUG] $display_id: output_file=$output_file" >&2
    echo "[DEBUG] $display_id: file exists=$(test -f "$output_file" && echo yes || echo no)" >&2
    echo "[DEBUG] $display_id: file size=$(wc -c < "$output_file" 2>/dev/null || echo 0)" >&2
    # Note: grep -c outputs "0" and exits 1 when no matches. Use || true to suppress
    # exit code without adding duplicate output (|| echo 0 would print twice)
    echo "[DEBUG] $display_id: has COMPLETE=$(grep -c '<promise>COMPLETE</promise>' "$output_file" 2>/dev/null || true)" >&2
    echo "[DEBUG] $display_id: has ALREADY_DONE=$(grep -c '<promise>ALREADY_DONE</promise>' "$output_file" 2>/dev/null || true)" >&2
  fi

  # Worker signal exit codes (30-39 range to avoid collision with tool exit codes like jq)
  # 0  = COMPLETE
  # 1  = no signal / needs iteration
  # 32 = BLOCKED
  # 33 = ALREADY_DONE
  # 34 = ABSORBED_BY
  if grep -q "<promise>COMPLETE</promise>" "$output_file" 2>/dev/null; then
    log_event "SUCCESS" "Task $display_id signaled COMPLETE (${duration}s)"
    emit_supervisor_event "task_complete" "$task_id" "$worker" "$duration"
    rm -f "$output_file"
    return 0
  elif grep -q "<promise>ALREADY_DONE</promise>" "$output_file" 2>/dev/null; then
    log_event "SUCCESS" "Task $display_id signaled ALREADY_DONE - completed by prior task (${duration}s)"
    emit_supervisor_event "task_already_done" "$task_id"
    rm -f "$output_file"
    return 33  # ALREADY_DONE (distinct from jq exit code 3)
  elif grep -oq "<promise>ABSORBED_BY:" "$output_file" 2>/dev/null; then
    # Extract the absorbing task ID (e.g., ABSORBED_BY:US-001 -> US-001)
    LAST_ABSORBED_BY=$(grep -o "<promise>ABSORBED_BY:[^<]*</promise>" "$output_file" | sed 's/<promise>ABSORBED_BY://;s/<\/promise>//')
    local absorbed_display=$(format_task_id "$prd_path" "$LAST_ABSORBED_BY")
    log_event "SUCCESS" "Task $display_id ABSORBED BY $absorbed_display (${duration}s)"
    emit_supervisor_event "task_absorbed" "$task_id" "$LAST_ABSORBED_BY"
    rm -f "$output_file"
    return 34  # ABSORBED_BY
  elif grep -q "<promise>BLOCKED</promise>" "$output_file" 2>/dev/null; then
    log_event "ERROR" "Task $display_id is BLOCKED (${duration}s)"
    emit_supervisor_event "task_blocked" "$task_id" "$worker"
    emit_supervisor_event "attention" "$task_id" "blocked"
    rm -f "$output_file"
    return 32  # BLOCKED
  else
    log_event "WARN" "Task $display_id - no completion signal, may need another iteration (${duration}s)"
    # Debug: show last 20 lines of output when no signal found
    if [ "${BRIGADE_DEBUG:-false}" == "true" ] && [ -f "$output_file" ]; then
      echo "[DEBUG] $display_id: Last 20 lines of output:" >&2
      tail -20 "$output_file" >&2
    fi
    rm -f "$output_file"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# VERIFICATION
# ═══════════════════════════════════════════════════════════════════════════════

# Run verification commands for a task
# Supports both old format (string[]) and new format ({type, cmd}[])
# Returns 0 if all pass, 1 if any fail (sets LAST_VERIFICATION_FEEDBACK)
run_verification() {
  local prd_path="$1"
  local task_id="$2"

  # Check if verification is enabled
  if [ "$VERIFICATION_ENABLED" != "true" ]; then
    return 0
  fi

  # Get verification commands for this task
  local verification_json=$(jq -r --arg id "$task_id" \
    '.tasks[] | select(.id == $id) | .verification // []' "$prd_path")

  # Skip if no verification commands
  local cmd_count=$(echo "$verification_json" | jq 'length')
  if [ "$cmd_count" -eq 0 ] || [ "$verification_json" == "[]" ] || [ "$verification_json" == "null" ]; then
    return 0
  fi

  local display_id=$(format_task_id "$prd_path" "$task_id")
  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
  log_event "INFO" "VERIFICATION: Running $cmd_count check(s) for $display_id"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"

  local failed_cmds=""
  local pass_count=0
  local fail_count=0

  # Run each verification command
  # Supports both string format and {type, cmd} object format
  local i=0
  while [ $i -lt "$cmd_count" ]; do
    local item=$(echo "$verification_json" | jq ".[$i]")
    local cmd=""
    local vtype=""

    # Check if item is a string or object
    local item_type=$(echo "$item" | jq -r 'type')
    if [ "$item_type" == "string" ]; then
      cmd=$(echo "$item" | jq -r '.')
      vtype="unknown"
    else
      cmd=$(echo "$item" | jq -r '.cmd // empty')
      vtype=$(echo "$item" | jq -r '.type // "unknown"')
    fi

    i=$((i + 1))
    [ -z "$cmd" ] && continue

    # Show type badge if known
    local type_badge=""
    case "$vtype" in
      pattern)     type_badge="${GRAY}[pattern]${NC} " ;;
      unit)        type_badge="${CYAN}[unit]${NC} " ;;
      integration) type_badge="${MAGENTA}[integration]${NC} " ;;
      smoke)       type_badge="${YELLOW}[smoke]${NC} " ;;
    esac

    echo -e "  ${type_badge}${GRAY}▶ $cmd${NC}"

    # Run with timeout
    local output
    local exit_code
    if command -v timeout &>/dev/null; then
      output=$(timeout "$VERIFICATION_TIMEOUT" bash -c "$cmd" 2>&1)
      exit_code=$?
    elif command -v gtimeout &>/dev/null; then
      output=$(gtimeout "$VERIFICATION_TIMEOUT" bash -c "$cmd" 2>&1)
      exit_code=$?
    else
      output=$(bash -c "$cmd" 2>&1)
      exit_code=$?
    fi

    if [ "$exit_code" -eq 0 ]; then
      echo -e "    ${GREEN}✓ PASS${NC}"
      pass_count=$((pass_count + 1))
    elif [ "$exit_code" -eq 124 ]; then
      echo -e "    ${RED}✗ TIMEOUT (>${VERIFICATION_TIMEOUT}s)${NC}"
      failed_cmds="${failed_cmds}\n- [$vtype] \`$cmd\` - TIMEOUT after ${VERIFICATION_TIMEOUT}s"
      fail_count=$((fail_count + 1))
    else
      echo -e "    ${RED}✗ FAIL (exit $exit_code)${NC}"
      if [ -n "$output" ]; then
        echo -e "    ${GRAY}Output: $(echo "$output" | head -3)${NC}"
      fi
      failed_cmds="${failed_cmds}\n- [$vtype] \`$cmd\` - exit code $exit_code"
      if [ -n "$output" ]; then
        failed_cmds="${failed_cmds}\n  Output: $(echo "$output" | head -3)"
      fi
      fail_count=$((fail_count + 1))
    fi
  done

  echo ""

  if [ "$fail_count" -gt 0 ]; then
    log_event "ERROR" "VERIFICATION FAILED: $fail_count of $cmd_count check(s) failed"
    LAST_VERIFICATION_FEEDBACK="Verification commands failed:${failed_cmds}

Please fix these issues and ensure all verification commands pass before signaling COMPLETE."
    return 1
  else
    log_event "SUCCESS" "VERIFICATION PASSED: $pass_count of $cmd_count check(s)"
    LAST_VERIFICATION_FEEDBACK=""
    return 0
  fi
}

# Get verification commands for a task (for display in prompts)
# Supports both old format (string[]) and new format ({type, cmd}[])
# Returns commands only (no type info) for backward compatibility
get_verification_commands() {
  local prd_path="$1"
  local task_id="$2"

  local verification_json=$(jq -r --arg id "$task_id" \
    '.tasks[] | select(.id == $id) | .verification // []' "$prd_path")

  if [ "$verification_json" == "[]" ] || [ "$verification_json" == "null" ]; then
    echo ""
    return
  fi

  # Extract commands from both formats
  # If item is a string, use it directly; if object, extract .cmd
  echo "$verification_json" | jq -r '.[] | if type == "string" then . else .cmd // empty end'
}

# Classify task type based on title keywords
# Returns: create, integrate, feature, or unknown
# Used to determine what verification types are appropriate
classify_task_type() {
  local title="$1"
  local title_lower=$(echo "$title" | tr '[:upper:]' '[:lower:]')

  # Integration tasks: connect, integrate, wire, hook up, link
  if echo "$title_lower" | grep -qE '\b(connect|integrate|wire|hook\s*up|link|bridge|merge|combine)\b'; then
    echo "integrate"
    return
  fi

  # Feature/flow tasks: flow, workflow, user can, end-to-end, e2e
  if echo "$title_lower" | grep -qE '\b(flow|workflow|user\s*can|end-to-end|e2e|journey|scenario)\b'; then
    echo "feature"
    return
  fi

  # Create tasks: add, create, implement, build, write, make
  if echo "$title_lower" | grep -qE '\b(add|create|implement|build|write|make|introduce|develop)\b'; then
    echo "create"
    return
  fi

  echo "unknown"
}

# Get verification types present in a task
# Returns space-separated list of types: pattern unit integration smoke
get_verification_types() {
  local prd_path="$1"
  local task_id="$2"

  local verification_json=$(jq -r --arg id "$task_id" \
    '.tasks[] | select(.id == $id) | .verification // []' "$prd_path")

  if [ "$verification_json" == "[]" ] || [ "$verification_json" == "null" ]; then
    echo ""
    return
  fi

  local cmd_count=$(echo "$verification_json" | jq 'length')
  local types=""
  local has_pattern=false
  local has_unit=false
  local has_integration=false
  local has_smoke=false
  local has_execution=false

  local i=0
  while [ $i -lt "$cmd_count" ]; do
    local item=$(echo "$verification_json" | jq ".[$i]")
    local item_type=$(echo "$item" | jq -r 'type')
    local vtype=""
    local cmd=""

    if [ "$item_type" == "string" ]; then
      cmd=$(echo "$item" | jq -r '.')
      # Infer type from command pattern for old format
      if echo "$cmd" | grep -qE '^[[:space:]]*(grep|egrep|fgrep|test|stat|\[|ls[[:space:]])'; then
        vtype="pattern"
      elif echo "$cmd" | grep -qE '(go test|npm test|pytest|cargo test|jest|mocha|bats)'; then
        # Check if it's likely an integration test
        if echo "$cmd" | grep -qiE '(integration|e2e|flow|scenario|-run\s+Test.*Flow|-run\s+Test.*Integration)'; then
          vtype="integration"
        else
          vtype="unit"
        fi
      else
        vtype="smoke"  # Assume execution-based
      fi
    else
      vtype=$(echo "$item" | jq -r '.type // "unknown"')
      cmd=$(echo "$item" | jq -r '.cmd // empty')
    fi

    case "$vtype" in
      pattern)     has_pattern=true ;;
      unit)        has_unit=true; has_execution=true ;;
      integration) has_integration=true; has_execution=true ;;
      smoke)       has_smoke=true; has_execution=true ;;
      *)
        # For unknown types, check if command looks like execution
        if [ -n "$cmd" ] && ! echo "$cmd" | grep -qE '^[[:space:]]*(grep|egrep|fgrep|test|stat|\[)'; then
          has_execution=true
        fi
        ;;
    esac

    i=$((i + 1))
  done

  # Build result string
  [ "$has_pattern" == "true" ] && types="$types pattern"
  [ "$has_unit" == "true" ] && types="$types unit"
  [ "$has_integration" == "true" ] && types="$types integration"
  [ "$has_smoke" == "true" ] && types="$types smoke"

  echo "$types" | sed 's/^ //'
}

# Check if task's verification types match its task type
# Returns 0 if OK, 1 if warning (missing required verification type)
# Sets VERIFICATION_COVERAGE_WARNING with details
check_verification_coverage() {
  local prd_path="$1"
  local task_id="$2"

  VERIFICATION_COVERAGE_WARNING=""

  local task_title=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .title' "$prd_path")
  local task_type=$(classify_task_type "$task_title")
  local verification_types=$(get_verification_types "$prd_path" "$task_id")

  # Skip check if no verification at all (separate concern)
  if [ -z "$verification_types" ]; then
    return 0
  fi

  local missing=""

  case "$task_type" in
    integrate)
      # Integration tasks need integration tests
      if ! echo "$verification_types" | grep -q "integration"; then
        missing="integration"
      fi
      ;;
    feature)
      # Feature tasks need smoke or integration tests
      if ! echo "$verification_types" | grep -qE "(smoke|integration)"; then
        missing="smoke or integration"
      fi
      ;;
    create)
      # Create tasks should have unit or integration tests
      if ! echo "$verification_types" | grep -qE "(unit|integration|smoke)"; then
        missing="unit"
      fi
      ;;
  esac

  if [ -n "$missing" ]; then
    VERIFICATION_COVERAGE_WARNING="Task '$task_id' ($task_title) is a '$task_type' task but only has [$verification_types] verification. Consider adding $missing tests."
    return 1
  fi

  return 0
}

# Check all tasks in PRD for verification coverage issues
# Returns 0 if OK, 1 if warnings found (prints warnings)
check_prd_verification_coverage() {
  local prd_path="$1"
  local warnings=0

  local all_ids=$(jq -r '.tasks[].id' "$prd_path")

  for task_id in $all_ids; do
    if ! check_verification_coverage "$prd_path" "$task_id"; then
      echo -e "${YELLOW}⚠${NC} $VERIFICATION_COVERAGE_WARNING"
      warnings=$((warnings + 1))
    fi
  done

  return $warnings
}

# Scan git-changed files for TODO/FIXME/HACK comments that may indicate incomplete work
# Returns 0 if no concerning TODOs found, 1 if found (sets LAST_TODO_WARNINGS)
scan_todos_in_changes() {
  local prd_path="$1"
  local task_id="$2"

  if [ "$TODO_SCAN_ENABLED" != "true" ]; then
    return 0
  fi

  local display_id=$(format_task_id "$prd_path" "$task_id")

  # Get list of files changed (staged and unstaged)
  local changed_files=$(git diff --name-only HEAD 2>/dev/null; git diff --cached --name-only 2>/dev/null)
  changed_files=$(echo "$changed_files" | sort -u | grep -v "^$")

  if [ -z "$changed_files" ]; then
    return 0
  fi

  # Scan for TODO/FIXME/HACK/XXX patterns in changed files
  local todo_findings=""
  local todo_count=0

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    [ ! -f "$file" ] && continue

    # Skip binary files, test files, and documentation
    case "$file" in
      *.md|*.txt|*.json|*.yaml|*.yml|*_test.go|*_test.py|*.test.js|*.test.ts|*.spec.js|*.spec.ts)
        continue
        ;;
    esac

    # Search for concerning patterns (case insensitive)
    local findings=$(grep -n -i -E '\b(TODO|FIXME|HACK|XXX):\s*\S' "$file" 2>/dev/null | head -5)

    if [ -n "$findings" ]; then
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        local linenum=$(echo "$line" | cut -d: -f1)
        local content=$(echo "$line" | cut -d: -f2- | sed 's/^[[:space:]]*//' | cut -c1-80)
        todo_findings="${todo_findings}\n  - $file:$linenum: $content"
        todo_count=$((todo_count + 1))
      done <<< "$findings"
    fi
  done <<< "$changed_files"

  if [ "$todo_count" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
    log_event "WARN" "TODO SCAN: Found $todo_count incomplete marker(s) in changed files"
    echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}⚠ Found TODO/FIXME comments that may indicate incomplete implementation:${NC}"
    echo -e "$todo_findings"
    echo ""
    echo -e "${GRAY}These markers often indicate unfinished work. Consider:${NC}"
    echo -e "${GRAY}  1. Completing the TODO before marking task done${NC}"
    echo -e "${GRAY}  2. Creating a backlog item if it's out of scope${NC}"
    echo ""

    # Store for feedback to worker on retry
    LAST_TODO_WARNINGS="Found incomplete markers in changed files:$todo_findings

These TODO/FIXME comments may indicate the implementation is not complete. Please either:
1. Complete the TODO items before signaling COMPLETE
2. Use <backlog>description</backlog> to log them as future work if truly out of scope"
    return 1
  fi

  LAST_TODO_WARNINGS=""
  return 0
}

# Check if PRD has any execution-based verification (not just grep/file existence checks)
# Returns 0 if OK, 1 if warning (grep-only)
check_verification_quality() {
  local prd_path="$1"

  if [ "$VERIFICATION_WARN_GREP_ONLY" != "true" ]; then
    return 0
  fi

  # Count tasks with verification commands
  local tasks_with_verification=$(jq '[.tasks[] | select(.verification != null and (.verification | length) > 0)] | length' "$prd_path")

  if [ "$tasks_with_verification" -eq 0 ]; then
    # No verification at all - that's a separate concern
    return 0
  fi

  # Check if ALL verification commands are grep/test/stat-based (no execution)
  local all_cmds=$(jq -r '.tasks[].verification[]? // empty' "$prd_path" 2>/dev/null)
  local has_execution=false

  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    # Check if command is NOT a pattern-matching command
    # Pattern-based: grep, test, stat, [, ls, cat (when checking existence)
    # Execution-based: anything that runs the actual binary/feature
    if ! echo "$cmd" | grep -qE '^[[:space:]]*(grep|egrep|fgrep|test|stat|\[|ls[[:space:]]|cat[[:space:]].*\|.*grep|head[[:space:]]|tail[[:space:]])'; then
      # Check it's not just checking file existence
      if ! echo "$cmd" | grep -qE '^\[.*-[fedrwx]'; then
        has_execution=true
        break
      fi
    fi
  done <<< "$all_cmds"

  if [ "$has_execution" != "true" ] && [ -n "$all_cmds" ]; then
    echo -e "${YELLOW}⚠ PRD verification uses only pattern-matching (grep/test), no execution tests${NC}"
    echo -e "${GRAY}  Consider adding at least one command that runs the actual feature:${NC}"
    echo -e "${GRAY}  - ./binary --help                    (smoke test)${NC}"
    echo -e "${GRAY}  - ./binary command --dry-run         (feature test)${NC}"
    echo -e "${GRAY}  - curl http://localhost:8080/health  (API test)${NC}"
    echo ""
    return 1
  fi

  return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# EXECUTIVE REVIEW
# ═══════════════════════════════════════════════════════════════════════════════

build_review_prompt() {
  local prd_path="$1"
  local task_id="$2"
  local completed_by="$3"

  local task_json=$(get_task_by_id "$prd_path" "$task_id")
  local feature_name=$(jq -r '.featureName' "$prd_path")
  local chef_prompt=""

  if [ -f "$CHEF_DIR/executive.md" ]; then
    chef_prompt=$(cat "$CHEF_DIR/executive.md")
  fi

  cat <<EOF
$chef_prompt

---
REVIEW REQUEST

FEATURE: $feature_name
TASK COMPLETED BY: $completed_by

TASK:
$task_json

REVIEW INSTRUCTIONS:
1. Check if all acceptance criteria were met
2. Review the code changes for quality and correctness
3. Verify no obvious bugs or issues were introduced
4. Check that project patterns were followed

OUTPUT FORMAT:
- If approved: <review>PASS</review>
- If changes needed: <review>FAIL</review>
- Always include: <reason>Your explanation here</reason>

BEGIN REVIEW:
EOF
}

executive_review() {
  local prd_path="$1"
  local task_id="$2"
  local completed_by="$3"

  # Check if review is enabled
  if [ "$REVIEW_ENABLED" != "true" ]; then
    return 0  # Skip review, consider passed
  fi

  # Check if we only review junior work
  if [ "$REVIEW_JUNIOR_ONLY" == "true" ] && [ "$completed_by" != "line" ]; then
    echo -e "${GRAY}Skipping review (senior work)${NC}"
    return 0
  fi

  local task_title=$(jq -r ".tasks[] | select(.id == \"$task_id\") | .title" "$prd_path")
  local display_id=$(format_task_id "$prd_path" "$task_id")

  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  log_event "REVIEW" "EXECUTIVE REVIEW: $display_id - $task_title"
  echo -e "${GRAY}Executive Chef reviewing $(get_worker_name "$completed_by")'s work${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo ""

  local review_prompt=$(build_review_prompt "$prd_path" "$task_id" "$completed_by")
  local output_file=$(brigade_mktemp)

  # Execute executive review
  local start_time=$(date +%s)

  if $EXECUTIVE_CMD --dangerously-skip-permissions -p "$review_prompt" 2>&1 | tee "$output_file"; then
    echo -e "${GREEN}Review completed${NC}"
  else
    echo -e "${YELLOW}Review exited${NC}"
  fi

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))
  echo -e "${GRAY}Review duration: ${duration}s${NC}"

  # Extract review result
  local review_result=""
  local review_reason=""

  if grep -q "<review>PASS</review>" "$output_file" 2>/dev/null; then
    review_result="PASS"
  elif grep -q "<review>FAIL</review>" "$output_file" 2>/dev/null; then
    review_result="FAIL"
  else
    # Default to pass if no clear signal (conservative)
    review_result="PASS"
    echo -e "${YELLOW}⚠ No clear review signal, defaulting to PASS${NC}"
  fi

  # Extract reason if present (macOS compatible)
  review_reason=$(sed -n 's/.*<reason>\(.*\)<\/reason>.*/\1/p' "$output_file" 2>/dev/null | head -1)

  # If no explicit reason, generate one from context
  if [ -z "$review_reason" ]; then
    if [ "$review_result" == "PASS" ]; then
      # Try to extract something useful from output
      local summary=$(grep -i "criteria\|pass\|complete\|success" "$output_file" 2>/dev/null | head -1 | cut -c1-100)
      if [ -n "$summary" ]; then
        review_reason="$summary"
      else
        review_reason="All acceptance criteria verified"
      fi
    else
      # For failures, try to find the issue
      local issue=$(grep -i "fail\|error\|issue\|problem\|missing" "$output_file" 2>/dev/null | head -1 | cut -c1-100)
      if [ -n "$issue" ]; then
        review_reason="$issue"
      else
        review_reason="Review failed - check implementation"
      fi
    fi
  fi

  rm -f "$output_file"

  # Record review in state
  record_review "$prd_path" "$task_id" "$review_result" "$review_reason"

  if [ "$review_result" == "PASS" ]; then
    log_event "SUCCESS" "Executive Review PASSED: $display_id (${duration}s)"
    echo -e "${GRAY}Reason: $review_reason${NC}"
    LAST_REVIEW_FEEDBACK=""  # Clear any previous feedback
    LAST_VERIFICATION_FEEDBACK=""
    LAST_TODO_WARNINGS=""
    return 0
  else
    log_event "ERROR" "Executive Review FAILED: $display_id (${duration}s)"
    echo -e "${GRAY}Reason: $review_reason${NC}"
    # Store feedback so it can be passed to worker on retry
    LAST_REVIEW_FEEDBACK="$review_reason"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# WALKAWAY MODE (AI-driven resume decisions)
# ═══════════════════════════════════════════════════════════════════════════════

# Global counter for consecutive skips (reset on successful task)
WALKAWAY_CONSECUTIVE_SKIPS=0

# Build prompt for walkaway decision
build_walkaway_decision_prompt() {
  local prd_path="$1"
  local task_id="$2"
  local failure_reason="$3"
  local iteration_count="$4"
  local last_worker="$5"

  local task_json=$(get_task_by_id "$prd_path" "$task_id")
  local feature_name=$(jq -r '.featureName' "$prd_path")
  local task_title=$(echo "$task_json" | jq -r '.title')

  # Get task history from state
  local state_path=$(get_state_path "$prd_path")
  local task_history=""
  if [ -f "$state_path" ]; then
    task_history=$(jq -r --arg id "$task_id" '
      [.taskHistory[] | select(.taskId == $id)] |
      .[-5:] |
      map("- \(.timestamp | split("T")[1] | split("+")[0] | .[0:8]): \(.worker) - \(.status)") |
      join("\n")' "$state_path" 2>/dev/null || echo "")
  fi

  # Get completed and pending tasks
  local completed_tasks=$(jq -r '[.tasks[] | select(.passes == true) | .id] | join(", ")' "$prd_path")
  local pending_tasks=$(jq -r '[.tasks[] | select(.passes == false) | .id] | join(", ")' "$prd_path")

  cat <<EOF
You are the Executive Chef making an autonomous decision about a failed task in walkaway mode.

FEATURE: $feature_name
FAILED TASK: $task_id - $task_title
LAST WORKER: $(get_worker_name "$last_worker")
ITERATIONS: $iteration_count
FAILURE REASON: $failure_reason

TASK DETAILS:
$task_json

RECENT HISTORY:
$task_history

PROJECT STATUS:
- Completed: $completed_tasks
- Pending: $pending_tasks
- Consecutive skips so far: $WALKAWAY_CONSECUTIVE_SKIPS

DECISION CRITERIA:
1. RETRY if:
   - Failure seems transient (timeout, network, flaky test)
   - Task hasn't been tried many times yet (< 3 iterations at current tier)
   - Error suggests simple fix the worker might find

2. SKIP if:
   - Task has been tried many times without progress
   - Failure is fundamental (missing dependency, wrong approach)
   - Task is blocking but not critical path
   - Worker explicitly signaled BLOCKED

3. ABORT (rare) if:
   - Failure indicates systemic issue affecting all tasks
   - Critical path task with no workaround
   - Already hit max consecutive skips ($WALKAWAY_MAX_SKIPS)

OUTPUT FORMAT (exactly one of these):
<decision>RETRY</decision>
<decision>SKIP</decision>
<decision>ABORT</decision>

<reason>Your brief explanation for the decision</reason>

Make your decision:
EOF
}

# Ask Executive Chef to decide retry/skip/abort
# Returns: 0=retry, 1=skip, 2=abort
# Sets: WALKAWAY_DECISION_REASON
walkaway_decide_resume() {
  local prd_path="$1"
  local task_id="$2"
  local failure_reason="$3"
  local iteration_count="${4:-0}"
  local last_worker="${5:-unknown}"

  WALKAWAY_DECISION_REASON=""

  local display_id=$(format_task_id "$prd_path" "$task_id")

  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
  log_event "WALKAWAY" "Executive Chef deciding: $display_id ($failure_reason)"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  local decision_prompt=$(build_walkaway_decision_prompt "$prd_path" "$task_id" "$failure_reason" "$iteration_count" "$last_worker")
  local output_file=$(brigade_mktemp)

  # Execute with timeout
  local start_time=$(date +%s)

  if command -v timeout &>/dev/null; then
    timeout "$WALKAWAY_DECISION_TIMEOUT" $EXECUTIVE_CMD --dangerously-skip-permissions -p "$decision_prompt" 2>&1 | tee "$output_file"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$WALKAWAY_DECISION_TIMEOUT" $EXECUTIVE_CMD --dangerously-skip-permissions -p "$decision_prompt" 2>&1 | tee "$output_file"
  else
    $EXECUTIVE_CMD --dangerously-skip-permissions -p "$decision_prompt" 2>&1 | tee "$output_file"
  fi

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))
  echo -e "${GRAY}Decision duration: ${duration}s${NC}"

  # Extract decision
  local decision=""
  if grep -q "<decision>RETRY</decision>" "$output_file" 2>/dev/null; then
    decision="RETRY"
  elif grep -q "<decision>SKIP</decision>" "$output_file" 2>/dev/null; then
    decision="SKIP"
  elif grep -q "<decision>ABORT</decision>" "$output_file" 2>/dev/null; then
    decision="ABORT"
  else
    # Default to retry if unclear (conservative)
    decision="RETRY"
    echo -e "${YELLOW}⚠ No clear decision signal, defaulting to RETRY${NC}"
  fi

  # Extract reason
  WALKAWAY_DECISION_REASON=$(sed -n 's/.*<reason>\(.*\)<\/reason>.*/\1/p' "$output_file" 2>/dev/null | head -1)
  if [ -z "$WALKAWAY_DECISION_REASON" ]; then
    WALKAWAY_DECISION_REASON="AI decision: $decision"
  fi

  rm -f "$output_file"

  # Record decision in state
  record_walkaway_decision "$prd_path" "$task_id" "$decision" "$WALKAWAY_DECISION_REASON" "$failure_reason"

  # Log and return appropriate code
  case "$decision" in
    "RETRY")
      log_event "WALKAWAY" "Decision: RETRY - $WALKAWAY_DECISION_REASON"
      echo -e "${GREEN}Decision: RETRY${NC}"
      echo -e "${GRAY}Reason: $WALKAWAY_DECISION_REASON${NC}"
      return 0
      ;;
    "SKIP")
      log_event "WALKAWAY" "Decision: SKIP - $WALKAWAY_DECISION_REASON"
      echo -e "${YELLOW}Decision: SKIP${NC}"
      echo -e "${GRAY}Reason: $WALKAWAY_DECISION_REASON${NC}"
      return 1
      ;;
    "ABORT")
      log_event "WALKAWAY" "Decision: ABORT - $WALKAWAY_DECISION_REASON"
      echo -e "${RED}Decision: ABORT${NC}"
      echo -e "${GRAY}Reason: $WALKAWAY_DECISION_REASON${NC}"
      return 2
      ;;
  esac
}

# Record walkaway decision to state file
record_walkaway_decision() {
  local prd_path="$1"
  local task_id="$2"
  local decision="$3"
  local reason="$4"
  local failure_reason="$5"

  local state_path=$(get_state_path "$prd_path")
  if [ ! -f "$state_path" ]; then
    return 0
  fi

  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")

  acquire_lock "$state_path"
  local tmp_file=$(brigade_mktemp)
  jq --arg task "$task_id" \
    --arg decision "$decision" \
    --arg reason "$reason" \
    --arg failure "$failure_reason" \
    --arg ts "$timestamp" \
    '.walkawayDecisions = (.walkawayDecisions // []) + [{
      taskId: $task,
      decision: $decision,
      reason: $reason,
      failureReason: $failure,
      timestamp: $ts
    }]' "$state_path" > "$tmp_file"

  if [ $? -eq 0 ] && [ -s "$tmp_file" ]; then
    mv "$tmp_file" "$state_path"
  else
    rm -f "$tmp_file"
  fi
  release_lock "$state_path"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE REVIEW (Periodic progress check)
# ═══════════════════════════════════════════════════════════════════════════════

phase_review() {
  local prd_path="$1"
  local completed_count="$2"

  if [ "$PHASE_REVIEW_ENABLED" != "true" ]; then
    return 0
  fi

  # Only review at intervals
  if [ $((completed_count % PHASE_REVIEW_AFTER)) -ne 0 ]; then
    return 0
  fi

  local feature_name=$(jq -r '.featureName' "$prd_path")
  local total=$(jq '.tasks | length' "$prd_path")
  local completed=$(jq '[.tasks[] | select(.passes == true)] | length' "$prd_path")
  local pending=$((total - completed))

  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
  log_event "REVIEW" "PHASE REVIEW: $completed/$total tasks complete"
  echo -e "${CYAN}║  Executive Chef checking overall progress against spec    ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  # Build phase review prompt
  local completed_tasks=$(jq -r '.tasks[] | select(.passes == true) | "- \(.id): \(.title)"' "$prd_path")
  local pending_tasks=$(jq -r '.tasks[] | select(.passes == false) | "- \(.id): \(.title) [\(.complexity // "auto")]"' "$prd_path")
  local prd_description=$(jq -r '.description // "No description"' "$prd_path")

  # Different prompts based on action mode
  local phase_prompt=""

  if [ "$PHASE_REVIEW_ACTION" == "remediate" ]; then
    phase_prompt="You are the Executive Chef doing a phase review with REMEDIATION authority.

FEATURE: $feature_name
DESCRIPTION: $prd_description

PROGRESS: $completed of $total tasks complete ($pending remaining)

COMPLETED TASKS:
$completed_tasks

REMAINING TASKS:
$pending_tasks

Please review:
1. Are completed tasks aligned with the PRD spec and acceptance criteria?
2. Is there any drift from the original requirements?
3. Are we on track to deliver the feature as specified?

If you identify issues that need correction, you can add remediation tasks.

Output your assessment AND any remediation tasks:
<phase_review>
STATUS: on_track | minor_concerns | needs_attention
ASSESSMENT: <your analysis>
</phase_review>

If STATUS is needs_attention, also output remediation tasks (or omit if none needed):
<remediation_tasks>
[
  {
    \"id\": \"FIX-001\",
    \"title\": \"Fix: <description of correction>\",
    \"description\": \"Correct the drift by...\",
    \"acceptanceCriteria\": [\"Specific fix criterion\"],
    \"complexity\": \"senior\",
    \"dependsOn\": []
  }
]
</remediation_tasks>"
  else
    phase_prompt="You are the Executive Chef doing a phase review.

FEATURE: $feature_name
DESCRIPTION: $prd_description

PROGRESS: $completed of $total tasks complete ($pending remaining)

COMPLETED TASKS:
$completed_tasks

REMAINING TASKS:
$pending_tasks

Please review:
1. Are completed tasks aligned with the PRD spec and acceptance criteria?
2. Is there any drift from the original requirements?
3. Are we on track to deliver the feature as specified?
4. Any concerns or adjustments needed before continuing?

Output your assessment:
<phase_review>
STATUS: on_track | minor_concerns | needs_attention
ASSESSMENT: <your analysis>
RECOMMENDATIONS: <any suggestions, or 'none'>
</phase_review>"
  fi

  local output_file=$(brigade_mktemp)
  local start_time=$(date +%s)

  if $EXECUTIVE_CMD --dangerously-skip-permissions -p "$phase_prompt" 2>&1 | tee "$output_file"; then
    echo -e "${GREEN}Phase review completed${NC}"
  else
    echo -e "${YELLOW}Phase review exited${NC}"
  fi

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # Extract status (macOS compatible - no -P flag)
  local status=$(sed -n 's/.*STATUS: *\([a-z_]*\).*/\1/p' "$output_file" 2>/dev/null | head -1)
  [ -z "$status" ] && status="unknown"

  # Record phase review to state file
  record_phase_review "$prd_path" "$completed" "$total" "$status" "$output_file"

  case "$status" in
    "on_track")
      log_event "SUCCESS" "Phase Review: ON TRACK (${duration}s)"
      rm -f "$output_file"
      return 0
      ;;
    "minor_concerns")
      log_event "WARN" "Phase Review: MINOR CONCERNS (${duration}s)"
      rm -f "$output_file"
      return 0
      ;;
    "needs_attention")
      log_event "ERROR" "Phase Review: NEEDS ATTENTION (${duration}s)"

      # Handle based on action mode
      case "$PHASE_REVIEW_ACTION" in
        "pause")
          echo ""
          echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
          echo -e "${RED}║  EXECUTION PAUSED - Phase review requires attention       ║${NC}"
          echo -e "${RED}║  Review the concerns above and restart when ready         ║${NC}"
          echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
          rm -f "$output_file"
          exit 2  # Special exit code for paused
          ;;
        "remediate")
          # Extract and apply remediation tasks
          apply_remediation "$prd_path" "$output_file"
          ;;
        *)
          # continue - just log
          echo -e "${YELLOW}Executive Chef flagged concerns - review output above${NC}"
          ;;
      esac
      rm -f "$output_file"
      return 0
      ;;
    *)
      log_event "INFO" "Phase Review completed (${duration}s)"
      rm -f "$output_file"
      return 0
      ;;
  esac
}

# Phase gate between PRDs in auto-continue mode
# Returns: 0=continue, 1=stop, 2=pause
prd_phase_gate() {
  local completed_prd="$1"
  local next_prd="$2"
  local prd_num="$3"
  local total_prds="$4"

  local completed_name=$(jq -r '.featureName' "$completed_prd")
  local next_name=$(jq -r '.featureName' "$next_prd")

  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  PRD PHASE GATE ($prd_num/$total_prds complete)                         ${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${GREEN}✓ Completed:${NC} $completed_name"
  echo -e "${CYAN}→ Next:${NC}      $next_name"
  echo ""

  case "$PHASE_GATE" in
    "continue")
      log_event "INFO" "Phase gate: continuing to next PRD"
      return 0
      ;;
    "pause")
      echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
      echo -e "${YELLOW}║  AUTO-CONTINUE PAUSED                                     ║${NC}"
      echo -e "${YELLOW}║  Run './brigade.sh --auto-continue service ...' to resume ║${NC}"
      echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
      return 2
      ;;
    "review")
      log_event "REVIEW" "Executive Chef reviewing phase transition"

      # Get summary of completed PRD
      local completed_tasks=$(jq -r '[.tasks[] | select(.passes == true)] | length' "$completed_prd")
      local total_tasks=$(jq '.tasks | length' "$completed_prd")
      local next_tasks=$(jq '.tasks | length' "$next_prd")

      local review_prompt="You are the Executive Chef reviewing a phase transition between PRDs.

COMPLETED PRD: $completed_name
Tasks completed: $completed_tasks/$total_tasks

NEXT PRD: $next_name
Tasks planned: $next_tasks

Review the completed work and assess readiness to proceed:
1. Was the completed phase delivered successfully?
2. Are there any concerns or blockers for the next phase?
3. Should we proceed, pause, or stop?

Output your assessment:
<phase_gate>
STATUS: proceed | pause | stop
ASSESSMENT: <your analysis>
</phase_gate>"

      local output_file=$(brigade_mktemp)
      local start_time=$(date +%s)

      if $EXECUTIVE_CMD --dangerously-skip-permissions -p "$review_prompt" 2>&1 | tee "$output_file"; then
        echo -e "${GREEN}Phase gate review completed${NC}"
      fi

      local end_time=$(date +%s)
      local duration=$((end_time - start_time))

      # Extract status
      local status=$(sed -n 's/.*STATUS: *\([a-z]*\).*/\1/p' "$output_file" 2>/dev/null | head -1)
      [ -z "$status" ] && status="proceed"

      rm -f "$output_file"

      case "$status" in
        "proceed")
          log_event "SUCCESS" "Phase gate APPROVED: proceed to next PRD (${duration}s)"
          return 0
          ;;
        "pause")
          log_event "WARN" "Phase gate: PAUSE requested (${duration}s)"
          echo -e "${YELLOW}Executive Chef recommends pausing before next PRD${NC}"
          return 2
          ;;
        "stop")
          log_event "ERROR" "Phase gate: STOP requested (${duration}s)"
          echo -e "${RED}Executive Chef recommends stopping - review concerns above${NC}"
          return 1
          ;;
        *)
          log_event "INFO" "Phase gate completed (${duration}s)"
          return 0
          ;;
      esac
      ;;
    *)
      # Unknown mode, default to continue
      return 0
      ;;
  esac
}

# Apply remediation tasks from Executive Chef
apply_remediation() {
  local prd_path="$1"
  local output_file="$2"

  # Extract remediation tasks JSON
  local remediation_json=$(sed -n '/<remediation_tasks>/,/<\/remediation_tasks>/p' "$output_file" | \
    sed '1d;$d' | tr -d '\n')

  if [ -z "$remediation_json" ] || [ "$remediation_json" == "[]" ]; then
    echo -e "${GRAY}No remediation tasks added${NC}"
    return 0
  fi

  # Validate JSON
  if ! echo "$remediation_json" | jq empty 2>/dev/null; then
    echo -e "${YELLOW}Warning: Could not parse remediation tasks JSON${NC}"
    return 0
  fi

  local task_count=$(echo "$remediation_json" | jq 'length')

  echo ""
  echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
  log_event "INFO" "REMEDIATION: Adding $task_count corrective tasks"
  echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"

  # Add remediation tasks to PRD
  local tmp_prd=$(brigade_mktemp)
  jq --argjson new_tasks "$remediation_json" '.tasks += $new_tasks' "$prd_path" > "$tmp_prd"

  if [ -s "$tmp_prd" ]; then
    mv "$tmp_prd" "$prd_path"

    # List added tasks
    echo "$remediation_json" | jq -r '.[] | "  + \(.id): \(.title) [\(.complexity)]"'
    echo ""
    log_event "SUCCESS" "Remediation tasks added to PRD"
  else
    echo -e "${RED}Failed to add remediation tasks${NC}"
    rm -f "$tmp_prd"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# COMMANDS
# ═══════════════════════════════════════════════════════════════════════════════

# Output ultra-compact JSON status for AI supervisors
# Minimal tokens: {"done":3,"total":13,"current":"US-004","worker":"sous","elapsed":125,"attention":false}
output_status_brief() {
  local prd_path="$1"
  local state_path=$(get_state_path "$prd_path")

  local total=$(get_task_count "$prd_path")
  local done=$(jq '[.tasks[] | select(.passes == true)] | length' "$prd_path")

  # Get current task info
  local current=""
  local worker=""
  local elapsed=0
  local attention=false
  local reason=""

  if [ -f "$state_path" ]; then
    current=$(jq -r '.currentTask // empty' "$state_path")

    if [ -n "$current" ]; then
      # Get worker from last history entry for this task
      local last_entry=$(jq -r --arg task "$current" \
        '[.taskHistory[] | select(.taskId == $task)] | last // {}' "$state_path")
      worker=$(echo "$last_entry" | jq -r '.worker // empty')
      local status=$(echo "$last_entry" | jq -r '.status // empty')

      # Calculate elapsed time
      local start_ts=$(echo "$last_entry" | jq -r '.timestamp // empty')
      if [ -n "$start_ts" ]; then
        local start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${start_ts%.*}" "+%s" 2>/dev/null || \
                           date -d "${start_ts}" "+%s" 2>/dev/null || echo 0)
        local now_epoch=$(date "+%s")
        elapsed=$((now_epoch - start_epoch))
        [ $elapsed -lt 0 ] && elapsed=0
      fi

      # Check attention conditions
      case "$status" in
        blocked)
          attention=true
          reason="blocked"
          ;;
        verification_failed)
          attention=true
          reason="verification_failed"
          ;;
        review_failed)
          attention=true
          reason="review_failed"
          ;;
        skipped)
          attention=true
          reason="skipped"
          ;;
      esac
    fi

    # Check for executive escalation (highest tier failure)
    if [ "$attention" = "false" ]; then
      local prd_task_ids=$(jq -r '[.tasks[].id] | @json' "$prd_path")
      local exec_escalations=$(jq --argjson ids "$prd_task_ids" \
        '[(.escalations // [])[] | select(.taskId as $tid | $ids | index($tid)) | select(.to == "executive")] | length' \
        "$state_path" 2>/dev/null || echo 0)
      if [ "$exec_escalations" -gt 0 ]; then
        attention=true
        reason="escalated_to_executive"
      fi
    fi
  fi

  # Build compact JSON (single line, no pretty-printing)
  if [ "$attention" = "true" ]; then
    printf '{"done":%d,"total":%d,"current":%s,"worker":%s,"elapsed":%d,"attention":true,"reason":"%s"}\n' \
      "$done" "$total" \
      "$([ -n "$current" ] && echo "\"$current\"" || echo "null")" \
      "$([ -n "$worker" ] && echo "\"$worker\"" || echo "null")" \
      "$elapsed" "$reason"
  else
    printf '{"done":%d,"total":%d,"current":%s,"worker":%s,"elapsed":%d,"attention":false}\n' \
      "$done" "$total" \
      "$([ -n "$current" ] && echo "\"$current\"" || echo "null")" \
      "$([ -n "$worker" ] && echo "\"$worker\"" || echo "null")" \
      "$elapsed"
  fi
}

# Output machine-readable JSON status for AI supervisors
# Includes needs_attention flag to reduce polling overhead
output_status_json() {
  local prd_path="$1"
  local state_path=$(get_state_path "$prd_path")

  local feature_name=$(jq -r '.featureName // "Unknown"' "$prd_path")
  local total=$(get_task_count "$prd_path")
  local completed=$(jq '[.tasks[] | select(.passes == true)] | length' "$prd_path")
  local pending=$((total - completed))

  # Determine if attention is needed
  local needs_attention=false
  local attention_reason=""

  # Check state file for attention-worthy conditions
  local current_task=""
  local current_worker=""
  local current_status=""
  local escalation_count=0
  local max_tier_failures=0

  if [ -f "$state_path" ]; then
    current_task=$(jq -r '.currentTask // empty' "$state_path")

    if [ -n "$current_task" ]; then
      # Get current task info from history
      local last_entry=$(jq -r --arg task "$current_task" \
        '[.taskHistory[] | select(.taskId == $task)] | last // {}' "$state_path")
      current_worker=$(echo "$last_entry" | jq -r '.worker // "unknown"')
      current_status=$(echo "$last_entry" | jq -r '.status // "unknown"')
    fi

    # Count escalations for current PRD
    local prd_task_ids=$(jq -r '[.tasks[].id] | @json' "$prd_path")
    escalation_count=$(jq --argjson ids "$prd_task_ids" \
      '[(.escalations // [])[] | select(.taskId as $tid | $ids | index($tid))] | length' "$state_path" 2>/dev/null || echo 0)

    # Check for max-tier failures (escalated to executive and still failing)
    max_tier_failures=$(jq --argjson ids "$prd_task_ids" \
      '[(.escalations // [])[] | select(.taskId as $tid | $ids | index($tid)) | select(.to == "executive")] | length' "$state_path" 2>/dev/null || echo 0)

    # Determine if attention is needed
    if [ "$current_status" = "blocked" ]; then
      needs_attention=true
      attention_reason="Task $current_task is blocked"
    elif [ "$max_tier_failures" -gt 0 ]; then
      needs_attention=true
      attention_reason="Task escalated to Executive Chef tier"
    elif [ "$current_status" = "verification_failed" ]; then
      needs_attention=true
      attention_reason="Task $current_task failed verification"
    elif [ "$current_status" = "review_failed" ]; then
      needs_attention=true
      attention_reason="Task $current_task failed executive review"
    elif [ "$current_status" = "skipped" ]; then
      needs_attention=true
      attention_reason="Task $current_task was skipped"
    fi
  fi

  # Build tasks array
  local tasks_json=$(jq -c --arg current "$current_task" '
    [.tasks[] | {
      id: .id,
      title: .title,
      complexity: (.complexity // "auto"),
      completed: .passes,
      is_current: (.id == $current)
    }]' "$prd_path")

  # Get phase reviews from state
  local phase_reviews_json="[]"
  local phase_review_count=0
  local last_phase_review="null"
  if [ -f "$state_path" ]; then
    phase_review_count=$(jq '(.phaseReviews // []) | length' "$state_path" 2>/dev/null || echo 0)
    [ -z "$phase_review_count" ] && phase_review_count=0
    if [ "$phase_review_count" -gt 0 ]; then
      phase_reviews_json=$(jq -c '[(.phaseReviews // [])[] | {
        completed_tasks: .completedTasks,
        total_tasks: .totalTasks,
        status: .status,
        timestamp: .timestamp
      }]' "$state_path")
      last_phase_review=$(jq -c '(.phaseReviews // []) | last | {
        completed_tasks: .completedTasks,
        total_tasks: .totalTasks,
        status: .status,
        timestamp: .timestamp
      }' "$state_path")
    fi
  fi

  # Output JSON
  jq -n \
    --arg feature "$feature_name" \
    --arg prd "$prd_path" \
    --argjson total "$total" \
    --argjson completed "$completed" \
    --argjson pending "$pending" \
    --arg current_task "$current_task" \
    --arg current_worker "$current_worker" \
    --arg current_status "$current_status" \
    --argjson escalations "$escalation_count" \
    --argjson needs_attention "$needs_attention" \
    --arg attention_reason "$attention_reason" \
    --argjson tasks "$tasks_json" \
    --argjson phase_review_count "$phase_review_count" \
    --argjson last_phase_review "$last_phase_review" \
    --argjson phase_reviews "$phase_reviews_json" \
    '{
      feature_name: $feature,
      prd_path: $prd,
      total_tasks: $total,
      completed_tasks: $completed,
      pending_tasks: $pending,
      current_task: (if $current_task == "" then null else {
        id: $current_task,
        worker: $current_worker,
        status: $current_status
      } end),
      escalations: $escalations,
      phase_reviews: {
        count: $phase_review_count,
        last: $last_phase_review,
        history: $phase_reviews
      },
      needs_attention: $needs_attention,
      attention_reason: (if $attention_reason == "" then null else $attention_reason end),
      tasks: $tasks
    }'
}

cmd_status() {
  local show_all_escalations=false
  local watch_mode=false
  local json_mode=false
  local brief_mode=false
  local alert_only_mode=false
  local prd_path=""

  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --all)
        show_all_escalations=true
        shift
        ;;
      --watch|-w)
        watch_mode=true
        shift
        ;;
      --json|-j)
        json_mode=true
        shift
        ;;
      --brief|-b)
        brief_mode=true
        shift
        ;;
      --alert-only|-a)
        alert_only_mode=true
        shift
        ;;
      *)
        prd_path="$1"
        shift
        ;;
    esac
  done

  # Auto-detect PRD if not provided
  if [ -z "$prd_path" ]; then
    prd_path=$(find_active_prd)
    if [ -z "$prd_path" ]; then
      echo -e "${YELLOW}No active PRD found.${NC}"
      echo -e "${GRAY}Searched: brigade/tasks/, tasks/, ., ../brigade/tasks/, ../tasks/${NC}"
      echo ""
      echo -e "To create a PRD:  ${CYAN}./brigade.sh plan \"your feature description\"${NC}"
      echo -e "Or specify one:   ${CYAN}./brigade.sh status path/to/prd.json${NC}"
      exit 1
    fi
    # Only show "Found" message in human-readable mode
    if [ "$json_mode" = "false" ] && [ "$brief_mode" = "false" ] && [ "$alert_only_mode" = "false" ]; then
      echo -e "${GRAY}Found: $prd_path${NC}"
    fi
  fi

  if [ ! -f "$prd_path" ]; then
    if [ "$json_mode" = "true" ] || [ "$brief_mode" = "true" ] || [ "$alert_only_mode" = "true" ]; then
      echo '{"error": "PRD file not found", "attention": true}'
      exit 1
    fi
    echo -e "${RED}Error: PRD file not found: $prd_path${NC}"
    exit 1
  fi

  # Alert-only mode: output brief JSON only if attention is needed
  if [ "$alert_only_mode" = "true" ]; then
    local brief_output=$(output_status_brief "$prd_path")
    if echo "$brief_output" | grep -q '"attention":true'; then
      echo "$brief_output"
    fi
    # Output nothing if no attention needed
    return 0
  fi

  # Brief mode: output ultra-compact JSON and exit
  if [ "$brief_mode" = "true" ]; then
    output_status_brief "$prd_path"
    return 0
  fi

  # JSON mode: output machine-readable status and exit
  if [ "$json_mode" = "true" ]; then
    output_status_json "$prd_path"
    return 0
  fi

  # Watch mode setup
  if [ "$watch_mode" = "true" ]; then
    echo -e "${CYAN}Watch mode: refreshing every ${STATUS_WATCH_INTERVAL}s (Ctrl+C to exit)${NC}"
    sleep 1
  fi

  # Main display loop (runs once unless in watch mode)
  while true; do
    # Clear screen in watch mode
    if [ "$watch_mode" = "true" ]; then
      clear
      echo -e "${GRAY}[$(date '+%H:%M:%S')] Auto-refreshing every ${STATUS_WATCH_INTERVAL}s (Ctrl+C to exit)${NC}"
    fi

    # Warn if PRD has no state file (never started)
    local state_path="${prd_path%.json}.state.json"
    if [ ! -f "$state_path" ]; then
      echo -e "${YELLOW}Note: No state file for this PRD (never started)${NC}"
      echo -e "${GRAY}Run: ./brigade.sh service $prd_path${NC}"
      echo ""
    fi

    local feature_name=$(jq -r '.featureName' "$prd_path")
  local total=$(get_task_count "$prd_path")
  local complete=$(jq '[.tasks[] | select(.passes == true)] | length' "$prd_path")
  local pending=$((total - complete))

  echo ""
  echo -e "${BOLD}Kitchen Status: $feature_name${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"

  # Show currently cooking task if service is running
  local state_path=$(get_state_path "$prd_path")
  if [ -f "$state_path" ]; then
    # Validate state file JSON
    if ! validate_state "$state_path"; then
      echo -e "${YELLOW}State file was corrupted and has been reset.${NC}"
    fi
  fi
  if [ -f "$state_path" ]; then
    local current_task=$(jq -r '.currentTask // empty' "$state_path")

    if [ -n "$current_task" ]; then
      # Get last history entry for current task to find worker and start time
      local last_entry=$(jq -r --arg task "$current_task" \
        '[.taskHistory[] | select(.taskId == $task)] | last' "$state_path")

      if [ "$last_entry" != "null" ]; then
        local worker=$(echo "$last_entry" | jq -r '.worker // "unknown"')
        local status=$(echo "$last_entry" | jq -r '.status // "unknown"')
        local started_at=$(echo "$last_entry" | jq -r '.timestamp // empty')

        # Only show if task is in progress (not completed/blocked)
        if [ "$status" = "started" ] || [ "$status" = "review_failed" ]; then
          local task_title=$(jq -r --arg id "$current_task" '.tasks[] | select(.id == $id) | .title' "$prd_path")
          local worker_name=$(get_worker_name "$worker")

          echo ""
          echo -e "${YELLOW}🔥 CURRENTLY COOKING:${NC}"
          echo -e "   ${BOLD}$current_task${NC}: $task_title"
          echo -e "   ${GRAY}Worker: $worker_name${NC}"

          # Calculate running time if we have a start timestamp
          if [ -n "$started_at" ]; then
            local start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${started_at%%+*}" "+%s" 2>/dev/null || \
                               date -d "$started_at" "+%s" 2>/dev/null || echo "")
            if [ -n "$start_epoch" ]; then
              local now_epoch=$(date +%s)
              local elapsed=$((now_epoch - start_epoch))
              local mins=$((elapsed / 60))
              local secs=$((elapsed % 60))
              echo -e "   ${GRAY}Running: ${mins}m ${secs}s${NC}"
            fi
          fi
          echo ""
        fi
      fi
    fi
  fi

  # Progress bar
  local pct=0
  if [ "$total" -gt 0 ]; then
    pct=$((complete * 100 / total))
  fi
  local filled=$((pct / 5))
  local empty=$((20 - filled))
  local bar=$(printf "█%.0s" $(seq 1 $filled 2>/dev/null) || echo "")
  local bar_empty=$(printf "░%.0s" $(seq 1 $empty 2>/dev/null) || echo "")

  echo -e "${BOLD}📊 Progress:${NC} [${GREEN}${bar}${NC}${bar_empty}] ${pct}% ($complete/$total)"
  echo ""

  # Task list with status indicators
  echo -e "${BOLD}Tasks:${NC}"
  local current_task_id=""
  local current_worker=""
  local absorptions_json="[]"
  local escalations_json="[]"
  local worked_tasks_json="[]"
  if [ -f "$state_path" ]; then
    current_task_id=$(jq -r '.currentTask // empty' "$state_path")
    absorptions_json=$(jq -c '.absorptions // []' "$state_path")
    escalations_json=$(jq -c '.escalations // []' "$state_path")
    # Get unique task IDs that have been worked on
    worked_tasks_json=$(jq -c '[.taskHistory[].taskId] | unique' "$state_path")
    # Get current worker from last history entry
    if [ -n "$current_task_id" ]; then
      current_worker=$(jq -r --arg task "$current_task_id" \
        '[.taskHistory[] | select(.taskId == $task)] | last | .worker // "line"' "$state_path")
    fi
  fi

  jq -r --arg current "$current_task_id" --arg current_worker "$current_worker" \
      --argjson absorptions "$absorptions_json" --argjson escalations "$escalations_json" \
      --argjson worked "$worked_tasks_json" '.tasks[] |
    .id as $id |
    .complexity as $complexity |
    # Check if this task was absorbed
    ($absorptions | map(select(.taskId == $id)) | first // null) as $absorption |
    # Check escalation status - get the highest tier this task reached
    ($escalations | map(select(.taskId == $id)) | last // null) as $last_esc |
    # Determine worker: escalated tasks show current tier, others show complexity
    (if $last_esc != null then $last_esc.to
     elif $complexity == "senior" then "sous"
     elif $complexity == "junior" then "line"
     else "line" end) as $worker |
    # Worker display names
    ({"line": "Line Cook", "sous": "Sous Chef", "executive": "Exec Chef"}[$worker] // $worker) as $worker_name |
    # Escalation indicator
    (if $last_esc != null then " ⬆" else "" end) as $esc_indicator |
    # Check if task has been worked on (has history)
    ($worked | index($id) != null) as $has_history |
    if .passes == true and $absorption != null then
      "  \u001b[32m✓\u001b[0m \(.id): \(.title) \u001b[90m(absorbed by \($absorption.absorbedBy))\u001b[0m"
    elif .passes == true then
      "  \u001b[32m✓\u001b[0m \(.id): \(.title)"
    elif .id == $current then
      "  \u001b[33m→\u001b[0m \(.id): \(.title) \u001b[33m[\($current_worker | if . == "line" then "Line Cook" elif . == "sous" then "Sous Chef" elif . == "executive" then "Exec Chef" else . end)]\u001b[0m\(if $last_esc != null then " \u001b[33m⬆\u001b[0m" else "" end)"
    elif $has_history then
      "  \u001b[36m◐\u001b[0m \(.id): \(.title) \u001b[90m[\($worker_name)] awaiting review\u001b[0m\(if $last_esc != null then " \u001b[33m⬆\u001b[0m" else "" end)"
    else
      "  ○ \(.id): \(.title) \u001b[90m[\($worker_name)]\u001b[0m\(if $last_esc != null then " \u001b[33m⬆\u001b[0m" else "" end)"
    end' "$prd_path"

  # Session stats
  if [ -f "$state_path" ]; then
    local session_start=$(jq -r '.startedAt // empty' "$state_path")
    local last_start=$(jq -r '.lastStartTime // empty' "$state_path")

    # Get task IDs from current PRD for filtering
    local prd_task_ids=$(jq -r '[.tasks[].id] | @json' "$prd_path")

    # Filter reviews by current PRD task IDs
    local review_count=$(jq --argjson ids "$prd_task_ids" \
      '[(.reviews // [])[] | select(.taskId as $tid | $ids | index($tid))] | length' "$state_path" 2>/dev/null || echo 0)
    local review_pass=$(jq --argjson ids "$prd_task_ids" \
      '[(.reviews // [])[] | select(.taskId as $tid | $ids | index($tid)) | select(.result == "PASS")] | length' "$state_path" 2>/dev/null || echo 0)
    local review_fail=$(jq --argjson ids "$prd_task_ids" \
      '[(.reviews // [])[] | select(.taskId as $tid | $ids | index($tid)) | select(.result == "FAIL")] | length' "$state_path")

    # Filter absorptions by current PRD task IDs
    local absorption_count=$(jq --argjson ids "$prd_task_ids" \
      '[(.absorptions // [])[] | select(.taskId as $tid | $ids | index($tid))] | length' "$state_path" 2>/dev/null || echo 0)
    [ -z "$absorption_count" ] && absorption_count=0

    echo ""
    echo -e "${BOLD}Session Stats:${NC}"

    # Time tracking - show both total and current run if lastStartTime exists
    local now_epoch=$(date +%s)
    if [ -n "$session_start" ]; then
      local start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${session_start%%+*}" "+%s" 2>/dev/null || \
                         date -d "$session_start" "+%s" 2>/dev/null || echo "")
      if [ -n "$start_epoch" ]; then
        local total_elapsed=$((now_epoch - start_epoch))
        local total_hours=$((total_elapsed / 3600))
        local total_mins=$(((total_elapsed % 3600) / 60))

        # If we have lastStartTime, show both total and current run
        if [ -n "$last_start" ]; then
          local last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${last_start%%+*}" "+%s" 2>/dev/null || \
                            date -d "$last_start" "+%s" 2>/dev/null || echo "")
          if [ -n "$last_epoch" ]; then
            local run_elapsed=$((now_epoch - last_epoch))
            local run_hours=$((run_elapsed / 3600))
            local run_mins=$(((run_elapsed % 3600) / 60))
            echo -e "  Total time:       ${total_hours}h ${total_mins}m"
            echo -e "  Current run:      ${run_hours}h ${run_mins}m"
          else
            echo -e "  Total time:       ${total_hours}h ${total_mins}m"
          fi
        else
          echo -e "  Total time:       ${total_hours}h ${total_mins}m"
        fi
      fi
    fi

    # Count escalations - filter by current PRD unless --all
    local escalation_count
    local prd_escalation_count
    local total_escalation_count=$(jq '(.escalations // []) | length' "$state_path" 2>/dev/null || echo 0)
    [ -z "$total_escalation_count" ] && total_escalation_count=0
    if [ "$show_all_escalations" = "true" ]; then
      escalation_count=$total_escalation_count
    else
      prd_escalation_count=$(jq --argjson ids "$prd_task_ids" \
        '[(.escalations // [])[] | select(.taskId as $tid | $ids | index($tid))] | length' "$state_path" 2>/dev/null || echo 0)
      [ -z "$prd_escalation_count" ] && prd_escalation_count=0
      escalation_count=$prd_escalation_count
    fi

    echo -e "  Escalations:      $escalation_count$([ "$show_all_escalations" = "false" ] && [ "$total_escalation_count" != "$prd_escalation_count" ] && echo " (${total_escalation_count} total, use --all)")"
    echo -e "  Absorptions:      $absorption_count"
    echo -e "  Reviews:          $review_count (${GREEN}$review_pass passed${NC}, ${RED}$review_fail failed${NC})"

    # Show escalation history - filter by current PRD unless --all
    if [ "$escalation_count" -gt 0 ]; then
      echo ""
      if [ "$show_all_escalations" = "true" ]; then
        echo -e "${BOLD}Escalation History (all):${NC}"
        jq -r '(.escalations // [])[] |
          (.timestamp | split("T") | .[0] + " " + (.[1] | split("+")[0] | split("-")[0] | .[0:5])) as $time |
          "  \($time) \(.taskId): \(.from) → \(.to)"' "$state_path"
      else
        echo -e "${BOLD}Escalation History:${NC}"
        jq -r --argjson ids "$prd_task_ids" \
          '(.escalations // [])[] | select(.taskId as $tid | $ids | index($tid)) |
          (.timestamp | split("T") | .[0] + " " + (.[1] | split("+")[0] | split("-")[0] | .[0:5])) as $time |
          "  \($time) \(.taskId): \(.from) → \(.to)"' "$state_path"
      fi
    fi

    if [ "$absorption_count" -gt 0 ]; then
      echo ""
      echo -e "${BOLD}Absorbed Tasks:${NC}"
      jq -r --argjson ids "$prd_task_ids" \
        '(.absorptions // [])[] | select(.taskId as $tid | $ids | index($tid)) | "  \(.taskId) ← absorbed by \(.absorbedBy)"' "$state_path"
    fi

    # Phase reviews summary
    local phase_review_count=$(jq '(.phaseReviews // []) | length' "$state_path" 2>/dev/null || echo 0)
    [ -z "$phase_review_count" ] && phase_review_count=0
    if [ "$phase_review_count" -gt 0 ]; then
      echo ""
      echo -e "${BOLD}Phase Reviews:${NC} $phase_review_count"

      if [ "$show_all_escalations" = "true" ]; then
        # Show all phase reviews with --all flag
        jq -r '.phaseReviews // [] | to_entries[] |
          .value as $r |
          ($r.timestamp | split("T") | .[0] + " " + (.[1] | split("+")[0] | split("-")[0] | .[0:5])) as $time |
          (if $r.status == "CONTINUE" then "\u001b[32m✓\u001b[0m" else "\u001b[33m⏸\u001b[0m" end) as $icon |
          "  \($icon) \($time) [\($r.completedTasks)/\($r.totalTasks) tasks] \($r.status)"' "$state_path"
      else
        # Show only the last phase review
        jq -r '.phaseReviews // [] | last |
          (if . == null then empty else
            (.timestamp | split("T") | .[0] + " " + (.[1] | split("+")[0] | split("-")[0] | .[0:5])) as $time |
            (if .status == "CONTINUE" then "\u001b[32m✓\u001b[0m" else "\u001b[33m⏸\u001b[0m" end) as $icon |
            "  Last: \($icon) \($time) [\(.completedTasks)/\(.totalTasks) tasks] \(.status)"
          end)' "$state_path"
        if [ "$phase_review_count" -gt 1 ]; then
          echo -e "  ${GRAY}(use --all to see all $phase_review_count reviews)${NC}"
        fi
      fi
    fi
  fi

  echo ""

    # Break out of loop unless in watch mode
    if [ "$watch_mode" != "true" ]; then
      break
    fi

    # Sleep before next refresh
    sleep "$STATUS_WATCH_INTERVAL"
  done
}

cmd_resume() {
  local prd_path=""
  local action=""

  # Parse arguments (supports --retry-all, --skip-all flags)
  while [ $# -gt 0 ]; do
    case "$1" in
      --retry-all|--retry)
        action="retry"
        shift
        ;;
      --skip-all|--skip)
        action="skip"
        shift
        ;;
      *)
        # Could be prd_path or action word
        if [ -z "$prd_path" ] && [[ "$1" == *.json ]]; then
          prd_path="$1"
        elif [ -z "$prd_path" ] && [ -f "$1" ]; then
          prd_path="$1"
        elif [ -z "$action" ] && [[ "$1" == "retry" || "$1" == "skip" ]]; then
          action="$1"
        elif [ -z "$prd_path" ]; then
          prd_path="$1"
        fi
        shift
        ;;
    esac
  done

  # Auto-detect PRD if not provided
  if [ -z "$prd_path" ]; then
    prd_path=$(find_active_prd)
    if [ -z "$prd_path" ]; then
      echo -e "${YELLOW}No active PRD found.${NC}"
      echo ""
      echo -e "To create a PRD:  ${CYAN}./brigade.sh plan \"your feature description\"${NC}"
      echo -e "Or specify one:   ${CYAN}./brigade.sh resume path/to/prd.json${NC}"
      exit 1
    fi
    echo -e "${GRAY}Found: $prd_path${NC}"
  fi

  if [ ! -f "$prd_path" ]; then
    echo -e "${RED}Error: PRD file not found: $prd_path${NC}"
    echo -e "${GRAY}Check the path or run: ./brigade.sh plan \"your feature\"${NC}"
    exit 1
  fi

  local state_path=$(get_state_path "$prd_path")
  if [ ! -f "$state_path" ]; then
    echo -e "${YELLOW}No state file found - nothing to resume.${NC}"
    echo -e "${GRAY}Start fresh: ./brigade.sh service $prd_path${NC}"
    exit 0
  fi

  # Validate state file JSON
  if ! validate_state "$state_path"; then
    exit 1
  fi

  # Check for interrupted task
  local current_task=$(jq -r '.currentTask // empty' "$state_path")
  if [ -z "$current_task" ]; then
    echo -e "${YELLOW}No interrupted task found.${NC}"
    echo -e "${GRAY}Run './brigade.sh service $prd_path' to continue.${NC}"
    exit 0
  fi

  # Check if the current task exists in the PRD
  local task_exists=$(jq -r --arg id "$current_task" '.tasks[] | select(.id == $id) | .id' "$prd_path")
  if [ -z "$task_exists" ]; then
    echo -e "${YELLOW}Task $current_task not found in PRD (stale state).${NC}"
    # Clear currentTask from state
    local tmp_file=$(brigade_mktemp)
    jq '.currentTask = null' "$state_path" > "$tmp_file"
    mv "$tmp_file" "$state_path"
    echo -e "${GRAY}Cleared stale state. Run './brigade.sh service $prd_path' to continue.${NC}"
    exit 0
  fi

  # Check if the current task is already completed
  local task_passes=$(jq -r --arg id "$current_task" '.tasks[] | select(.id == $id) | .passes' "$prd_path")
  if [ "$task_passes" == "true" ]; then
    echo -e "${GREEN}Task $current_task is already completed.${NC}"
    # Clear currentTask from state
    local tmp_file=$(brigade_mktemp)
    jq '.currentTask = null' "$state_path" > "$tmp_file"
    mv "$tmp_file" "$state_path"
    echo -e "${GRAY}Run './brigade.sh service $prd_path' to continue.${NC}"
    exit 0
  fi

  # Get info about the interrupted task
  local task_title=$(jq -r --arg id "$current_task" '.tasks[] | select(.id == $id) | .title' "$prd_path")
  local last_entry=$(jq -r --arg task "$current_task" '[.taskHistory[] | select(.taskId == $task)] | last' "$state_path")
  local last_worker=$(echo "$last_entry" | jq -r '.worker // "unknown"')
  local last_status=$(echo "$last_entry" | jq -r '.status // "unknown"')
  local last_time=$(echo "$last_entry" | jq -r '.timestamp // "unknown"')

  echo ""
  echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║  INTERRUPTED TASK DETECTED                                ║${NC}"
  echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}Task:${NC}   $current_task - $task_title"
  echo -e "${BOLD}Worker:${NC} $(get_worker_name "$last_worker")"
  echo -e "${BOLD}Status:${NC} $last_status"
  echo -e "${BOLD}Time:${NC}   $last_time"
  echo ""

  # Determine action
  if [ -z "$action" ]; then
    # Build context for decision
    local iteration_count=$(echo "$last_entry" | jq -r '.status | if startswith("iteration_") then (. | sub("iteration_"; "") | tonumber) else 0 end' 2>/dev/null || echo 0)
    local context=$(cat <<EOF
{"failureReason":"$last_status","iterations":$iteration_count,"lastWorker":"$last_worker","taskTitle":"$task_title"}
EOF
)

    # Use wait_for_decision which handles supervisor, walkaway, and interactive modes
    wait_for_decision "resume_interrupted" "$current_task" "$context" "$prd_path" "$last_worker"
    local decision=$?

    case $decision in
      0) action="retry" ;;
      1) action="skip" ;;
      2)
        echo -e "${RED}ABORT: Decision to abort the resume${NC}"
        if [ -n "$DECISION_REASON" ]; then
          echo -e "${GRAY}Reason: $DECISION_REASON${NC}"
        fi
        exit 1
        ;;
    esac
  fi

  case "$action" in
    "retry"|"r")
      echo ""
      log_event "RESUME" "Retrying interrupted task: $current_task"
      # Clear currentTask to allow fresh start
      local tmp_file=$(brigade_mktemp)
      jq '.currentTask = null' "$state_path" > "$tmp_file"
      mv "$tmp_file" "$state_path"
      # Run the service - it will pick up from where we left off
      cmd_service "$prd_path"
      ;;
    "skip"|"s")
      echo ""
      log_event "RESUME" "Skipping interrupted task: $current_task"
      # Mark task as blocked/skipped in state
      update_state_task "$prd_path" "$current_task" "$last_worker" "skipped"
      # Clear currentTask
      local tmp_file=$(brigade_mktemp)
      jq '.currentTask = null' "$state_path" > "$tmp_file"
      mv "$tmp_file" "$state_path"
      echo -e "${YELLOW}Task $current_task skipped.${NC}"
      echo -e "${GRAY}Note: Dependent tasks may be blocked.${NC}"
      echo ""
      echo -e "Run './brigade.sh service $prd_path' to continue with remaining tasks."
      ;;
    *)
      echo -e "${RED}Invalid choice. Use 'retry' or 'skip'.${NC}"
      exit 1
      ;;
  esac
}

cmd_ticket() {
  local prd_path="$1"
  local task_id="$2"

  # Hot-reload config between tasks
  load_config >/dev/null 2>&1

  if [ ! -f "$prd_path" ]; then
    echo -e "${RED}Error: PRD file not found: $prd_path${NC}"
    echo -e "${GRAY}Check the path or run: ./brigade.sh plan \"your feature\"${NC}"
    exit 1
  fi

  local task=$(get_task_by_id "$prd_path" "$task_id")
  if [ -z "$task" ] || [ "$task" == "null" ]; then
    echo -e "${RED}Error: Task not found: $task_id${NC}"
    echo -e "${GRAY}Available tasks: $(jq -r '.tasks[].id' "$prd_path" | tr '\n' ' ')${NC}"
    exit 1
  fi

  # Check dependencies
  if ! check_dependencies_met "$prd_path" "$task_id"; then
    echo -e "${RED}Error: Dependencies not met for $task_id${NC}"
    echo "Waiting on:"
    get_task_dependencies "$prd_path" "$task_id" | while read dep; do
      local dep_passes=$(jq -r ".tasks[] | select(.id == \"$dep\") | .passes" "$prd_path")
      if [ "$dep_passes" != "true" ]; then
        echo "  - $dep"
      fi
    done
    exit 1
  fi

  # Initialize state if context isolation is enabled
  if [ "$CONTEXT_ISOLATION" == "true" ]; then
    init_state "$prd_path"
    update_last_start_time "$prd_path"
  fi

  # Route and fire
  local initial_worker=$(route_task "$prd_path" "$task_id")
  local worker="$initial_worker"
  local escalation_tier=0  # 0=none, 1=line→sous, 2=sous→exec
  local iteration_in_tier=0
  local display_id=$(format_task_id "$prd_path" "$task_id")

  update_state_task "$prd_path" "$task_id" "$worker" "started"

  # Clear any previous feedback (fresh start)
  LAST_REVIEW_FEEDBACK=""
  LAST_VERIFICATION_FEEDBACK=""
  LAST_TODO_WARNINGS=""

  # Track task start time for timeout checking
  local task_start_epoch=$(date +%s)

  # Pre-flight check: if tests already pass, task may be done
  if [ -n "$TEST_CMD" ]; then
    echo -e "${GRAY}Pre-flight check: running tests to see if task is already complete...${NC}"
    if timeout 30 bash -c "$TEST_CMD" >/dev/null 2>&1; then
      echo -e "${GREEN}✓ Tests already pass - task appears complete${NC}"
      log_event "SUCCESS" "Task $display_id: pre-flight tests pass → ALREADY_DONE"
      update_state_task "$prd_path" "$task_id" "$worker" "preflight_already_done"
      mark_task_complete "$prd_path" "$task_id"
      return 0
    else
      echo -e "${GRAY}Pre-flight: tests don't pass yet, proceeding with worker${NC}"
    fi
  fi

  for ((i=1; i<=MAX_ITERATIONS; i++)); do
    iteration_in_tier=$((iteration_in_tier + 1))

    # Check for escalation (Line Cook → Sous Chef)
    if [ "$ESCALATION_ENABLED" == "true" ] && \
       [ "$worker" == "line" ] && \
       [ "$escalation_tier" -eq 0 ] && \
       [ "$iteration_in_tier" -gt "$ESCALATION_AFTER" ]; then

      echo ""
      echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
      log_event "ESCALATE" "ESCALATING $display_id: Line Cook → Sous Chef"
      echo -e "${YELLOW}║  Reason: $ESCALATION_AFTER iterations without completion            ║${NC}"
      echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
      echo ""

      record_escalation "$prd_path" "$task_id" "line" "sous" "Max iterations ($ESCALATION_AFTER) reached without completion"
      worker="sous"
      escalation_tier=1
      iteration_in_tier=0
    fi

    # Check for escalation (Sous Chef → Executive Chef) - rare
    if [ "$ESCALATION_TO_EXEC" == "true" ] && \
       [ "$worker" == "sous" ] && \
       [ "$escalation_tier" -lt 2 ] && \
       [ "$iteration_in_tier" -gt "$ESCALATION_TO_EXEC_AFTER" ]; then

      echo ""
      echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
      log_event "ESCALATE" "ESCALATING $display_id: Sous Chef → Executive Chef (rare)"
      echo -e "${RED}║  Reason: $ESCALATION_TO_EXEC_AFTER iterations without completion            ║${NC}"
      echo -e "${RED}║  This is unusual - Executive Chef stepping in             ║${NC}"
      echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
      echo ""

      record_escalation "$prd_path" "$task_id" "sous" "executive" "Max iterations ($ESCALATION_TO_EXEC_AFTER) reached without completion"
      worker="executive"
      escalation_tier=2
      iteration_in_tier=0
    fi

    # Check for task timeout (escalate if task is taking too long)
    local worker_timeout=$(get_worker_timeout "$worker")
    if [ "$worker_timeout" -gt 0 ]; then
      local now_epoch=$(date +%s)
      local task_elapsed=$((now_epoch - task_start_epoch))

      if [ "$task_elapsed" -ge "$worker_timeout" ]; then
        local elapsed_mins=$((task_elapsed / 60))
        local timeout_mins=$((worker_timeout / 60))

        # Escalate if not already at executive tier
        if [ "$worker" == "line" ] && [ "$escalation_tier" -eq 0 ]; then
          echo ""
          echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
          log_event "ESCALATE" "ESCALATING $display_id: Line Cook → Sous Chef (timeout)"
          echo -e "${YELLOW}║  Reason: Task timeout (${elapsed_mins}m > ${timeout_mins}m limit)          ║${NC}"
          echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
          echo ""

          record_escalation "$prd_path" "$task_id" "line" "sous" "Task timeout (${elapsed_mins}m exceeded ${timeout_mins}m limit)"
          worker="sous"
          escalation_tier=1
          iteration_in_tier=0
          task_start_epoch=$(date +%s)  # Reset timer for new worker tier
        elif [ "$worker" == "sous" ] && [ "$ESCALATION_TO_EXEC" == "true" ] && [ "$escalation_tier" -lt 2 ]; then
          echo ""
          echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
          log_event "ESCALATE" "ESCALATING $display_id: Sous Chef → Executive Chef (timeout)"
          echo -e "${RED}║  Reason: Task timeout (${elapsed_mins}m > ${timeout_mins}m limit)          ║${NC}"
          echo -e "${RED}║  This is unusual - Executive Chef stepping in             ║${NC}"
          echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
          echo ""

          record_escalation "$prd_path" "$task_id" "sous" "executive" "Task timeout (${elapsed_mins}m exceeded ${timeout_mins}m limit)"
          worker="executive"
          escalation_tier=2
          iteration_in_tier=0
          task_start_epoch=$(date +%s)  # Reset timer for new worker tier
        elif [ "$worker" == "executive" ]; then
          echo -e "${RED}⚠ Executive Chef timeout (${elapsed_mins}m > ${timeout_mins}m) - no higher tier to escalate to${NC}"
          log_event "WARN" "Task $display_id: Executive Chef timeout but no higher tier available"
        fi
      fi
    fi

    echo -e "${GRAY}Iteration $i/$MAX_ITERATIONS (tier: $iteration_in_tier, worker: $(get_worker_name "$worker"))${NC}"

    # Track each iteration attempt
    update_state_task "$prd_path" "$task_id" "$worker" "iteration_$i"

    # Get timeout for current worker tier
    local worker_timeout=$(get_worker_timeout "$worker")

    # Capture exit code explicitly - set -e would otherwise exit on non-zero
    # return codes like 33 (ALREADY_DONE) before we can handle them
    set +e
    fire_ticket "$prd_path" "$task_id" "$worker" "$worker_timeout"
    local result=$?
    set -e

    if [ $result -eq 0 ]; then
      # Task signaled complete - check if worker actually changed anything
      local git_diff_empty=false
      if git diff --quiet HEAD 2>/dev/null; then
        # No changes - worker said COMPLETE but didn't modify anything
        if git diff --cached --quiet 2>/dev/null; then
          git_diff_empty=true
        fi
      fi

      if [ "$git_diff_empty" == "true" ]; then
        echo -e "${YELLOW}⚠ Worker signaled COMPLETE but git diff is empty${NC}"
        echo -e "${YELLOW}  Task was likely already done - converting to ALREADY_DONE${NC}"
        log_event "WARN" "Task $display_id: COMPLETE with empty diff → treating as ALREADY_DONE"
        add_learning "$prd_path" "$task_id" "$worker" "workflow" \
          "Task $task_id was already complete but worker didn't signal ALREADY_DONE. Check acceptance criteria before writing code."
        # Skip tests/review since nothing changed
        update_state_task "$prd_path" "$task_id" "$worker" "already_done_detected"
        mark_task_complete "$prd_path" "$task_id"
        return 0
      fi

      # Run verification commands if present
      local verification_passed=true
      if ! run_verification "$prd_path" "$task_id"; then
        verification_passed=false
        echo -e "${YELLOW}Verification failed, continuing iterations...${NC}"
        update_state_task "$prd_path" "$task_id" "$worker" "verification_failed"
        # Continue to next iteration - LAST_VERIFICATION_FEEDBACK is set
        continue
      fi

      # Scan changed files for TODO/FIXME that may indicate incomplete work
      if ! scan_todos_in_changes "$prd_path" "$task_id"; then
        echo -e "${YELLOW}TODO scan found incomplete markers, continuing iterations...${NC}"
        update_state_task "$prd_path" "$task_id" "$worker" "todo_warnings"
        # Continue to next iteration - LAST_TODO_WARNINGS is set
        continue
      fi

      # Run tests if configured
      local tests_passed=true

      if [ -n "$TEST_CMD" ]; then
        echo -e "${CYAN}Running tests (timeout: ${TEST_TIMEOUT}s)...${NC}"
        local test_output=$(brigade_mktemp)
        local test_start=$(date +%s)

        # Use timeout if available (GNU coreutils), otherwise run directly
        if command -v timeout >/dev/null 2>&1; then
          timeout "$TEST_TIMEOUT" bash -c "$TEST_CMD" 2>&1 | tee "$test_output"
          local test_exit=${PIPESTATUS[0]}
        else
          # macOS fallback: use perl for timeout
          perl -e 'alarm shift; exec @ARGV' "$TEST_TIMEOUT" bash -c "$TEST_CMD" 2>&1 | tee "$test_output"
          local test_exit=${PIPESTATUS[0]}
        fi

        local test_end=$(date +%s)
        local test_duration=$((test_end - test_start))

        if [ $test_exit -eq 0 ]; then
          echo -e "${GREEN}Tests passed (${test_duration}s)${NC}"
        else
          # Detect hanging vs failing
          # Exit code 124 = timeout (GNU), 142 = SIGALRM (perl)
          if [ $test_exit -eq 124 ] || [ $test_exit -eq 142 ] || [ $test_duration -ge $((TEST_TIMEOUT - 5)) ]; then
            echo -e "${RED}Tests appear HUNG (${test_duration}s, exit $test_exit)${NC}"
            # Check for terminal/editor indicators
            if grep -qE '\x1b\[|Warning:.*terminal|not a terminal|vim|emacs|nano|editor' "$test_output" 2>/dev/null; then
              echo -e "${YELLOW}⚠ Detected terminal/editor activity - test may be spawning interactive process${NC}"
              add_learning "$prd_path" "$task_id" "$worker" "test_issue" \
                "Tests hung after ${test_duration}s with terminal activity detected. Likely spawning an editor (vim/nano) or interactive process. Don't test functions with exec.Command directly - extract and test the logic separately."
            else
              echo -e "${YELLOW}⚠ Test timed out without obvious terminal activity - check for infinite loops or blocking I/O${NC}"
            fi
          else
            echo -e "${YELLOW}Tests failed (exit $test_exit, ${test_duration}s)${NC}"
          fi
          tests_passed=false
        fi
        rm -f "$test_output"
      fi

      if [ "$tests_passed" == "true" ]; then
        # Executive review before marking complete
        if executive_review "$prd_path" "$task_id" "$worker"; then
          update_state_task "$prd_path" "$task_id" "$worker" "completed"
          mark_task_complete "$prd_path" "$task_id"
          return 0
        else
          echo -e "${YELLOW}Review failed, continuing iterations...${NC}"
          update_state_task "$prd_path" "$task_id" "$worker" "review_failed"
        fi
      fi
    elif [ $result -eq 33 ]; then
      # Already done by prior task - mark complete without tests/review
      if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
        echo "[DEBUG] $display_id: fire_ticket returned 33 (ALREADY_DONE), proceeding to mark complete" >&2
      fi
      echo -e "${GREEN}Task was already completed by a prior task${NC}"
      if ! update_state_task "$prd_path" "$task_id" "$worker" "already_done"; then
        echo "[DEBUG] $display_id: update_state_task failed" >&2
      fi
      if ! mark_task_complete "$prd_path" "$task_id"; then
        echo "[DEBUG] $display_id: mark_task_complete failed" >&2
      fi
      if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
        echo "[DEBUG] $display_id: ALREADY_DONE handling complete, returning 0" >&2
      fi
      return 0
    elif [ $result -eq 34 ]; then
      # Absorbed by another task - mark complete without tests/review
      echo -e "${GREEN}Task was absorbed by $LAST_ABSORBED_BY${NC}"
      update_state_task "$prd_path" "$task_id" "$worker" "absorbed"
      record_absorption "$prd_path" "$task_id" "$LAST_ABSORBED_BY"
      mark_task_complete "$prd_path" "$task_id"
      return 0
    elif [ $result -eq 32 ]; then
      # Blocked - try escalation if available
      if [ "$ESCALATION_ENABLED" == "true" ] && \
         [ "$worker" == "line" ] && \
         [ "$escalation_tier" -eq 0 ]; then

        echo ""
        echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
        log_event "ESCALATE" "ESCALATING $display_id: Line Cook → Sous Chef (blocked)"
        echo -e "${YELLOW}║  Reason: Task blocked                                     ║${NC}"
        echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
        echo ""

        record_escalation "$prd_path" "$task_id" "line" "sous" "Task blocked"
        worker="sous"
        escalation_tier=1
        iteration_in_tier=0
        continue  # Try again with sous chef
      fi

      # Sous Chef blocked - escalate to Executive Chef
      if [ "$ESCALATION_TO_EXEC" == "true" ] && \
         [ "$worker" == "sous" ] && \
         [ "$escalation_tier" -lt 2 ]; then

        echo ""
        echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
        log_event "ESCALATE" "ESCALATING $display_id: Sous Chef → Executive Chef (blocked)"
        echo -e "${RED}║  Reason: Sous Chef blocked - calling in Executive         ║${NC}"
        echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
        echo ""

        record_escalation "$prd_path" "$task_id" "sous" "executive" "Task blocked"
        worker="executive"
        escalation_tier=2
        iteration_in_tier=0
        continue  # Try again with executive chef
      fi

      update_state_task "$prd_path" "$task_id" "$worker" "blocked"
      echo -e "${RED}Task is blocked, stopping${NC}"
      return 1
    fi
    # Otherwise continue iterating
  done

  update_state_task "$prd_path" "$task_id" "$worker" "max_iterations"
  echo -e "${RED}Max iterations reached for $task_id${NC}"
  return 1
}

cmd_service() {
  # Auto-continue mode: chain multiple PRDs
  if [ "$AUTO_CONTINUE" == "true" ] && [ $# -gt 1 ]; then
    local prd_files=("$@")
    local total_prds=${#prd_files[@]}

    # Sort PRDs by filename for deterministic order (prd-001, prd-002, etc.)
    IFS=$'\n' sorted_prds=($(sort <<<"${prd_files[*]}")); unset IFS

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  AUTO-CONTINUE MODE: $total_prds PRDs queued                        ${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}Execution order:${NC}"
    local idx=1
    for prd in "${sorted_prds[@]}"; do
      local name=$(jq -r '.featureName // "Unknown"' "$prd" 2>/dev/null || echo "Unknown")
      echo -e "  $idx. $(basename "$prd"): $name"
      idx=$((idx + 1))
    done
    echo ""
    echo -e "${GRAY}Phase gate between PRDs: $PHASE_GATE${NC}"
    echo ""

    local completed=0
    local auto_start=$(date +%s)

    for ((i=0; i<${#sorted_prds[@]}; i++)); do
      local current_prd="${sorted_prds[$i]}"
      local prd_num=$((i + 1))

      echo ""
      echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
      log_event "START" "AUTO-CONTINUE: PRD $prd_num/$total_prds - $(basename "$current_prd")"
      echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"

      # Run single PRD (disable auto-continue to prevent recursion)
      AUTO_CONTINUE=false
      if cmd_service "$current_prd"; then
        completed=$((completed + 1))

        # Phase gate before next PRD (if not the last one)
        if [ $i -lt $((${#sorted_prds[@]} - 1)) ]; then
          local next_prd="${sorted_prds[$((i + 1))]}"
          prd_phase_gate "$current_prd" "$next_prd" "$prd_num" "$total_prds"
          local gate_result=$?

          if [ $gate_result -eq 1 ]; then
            echo -e "${RED}Auto-continue stopped by phase gate${NC}"
            break
          elif [ $gate_result -eq 2 ]; then
            echo -e "${YELLOW}Auto-continue paused at PRD $prd_num${NC}"
            break
          fi
        fi
      else
        echo -e "${RED}PRD $prd_num failed - stopping auto-continue${NC}"
        break
      fi
    done

    local auto_end=$(date +%s)
    local duration=$((auto_end - auto_start))
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    log_event "SUCCESS" "AUTO-CONTINUE COMPLETE: $completed/$total_prds PRDs in ${hours}h ${minutes}m"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"

    return 0
  fi

  local prd_path="$1"

  # Default to brigade/tasks/latest.json if no PRD specified
  if [ -z "$prd_path" ]; then
    if [ -L "brigade/tasks/latest.json" ] && [ -f "brigade/tasks/latest.json" ]; then
      prd_path="brigade/tasks/latest.json"
      echo -e "${GRAY}Using $prd_path${NC}"
    elif [ -L "tasks/latest.json" ] && [ -f "tasks/latest.json" ]; then
      # Fallback for legacy location
      prd_path="tasks/latest.json"
      echo -e "${GRAY}Using $prd_path${NC}"
    elif [ -L "../brigade/tasks/latest.json" ] && [ -f "../brigade/tasks/latest.json" ]; then
      prd_path="../brigade/tasks/latest.json"
      echo -e "${GRAY}Using $prd_path${NC}"
    else
      echo -e "${RED}Error: No PRD specified and brigade/tasks/latest.json not found${NC}"
      echo ""
      echo -e "To create a PRD:  ${CYAN}./brigade.sh plan \"your feature description\"${NC}"
      echo -e "Or specify one:   ${CYAN}./brigade.sh service path/to/prd.json${NC}"
      exit 1
    fi
  fi

  if [ ! -f "$prd_path" ]; then
    echo -e "${RED}Error: PRD file not found: $prd_path${NC}"
    echo -e "${GRAY}Check the path or run: ./brigade.sh plan \"your feature\"${NC}"
    exit 1
  fi

  # Validate PRD before running
  echo -e "${GRAY}Validating PRD...${NC}"
  if ! validate_prd_quick "$prd_path"; then
    echo -e "${RED}PRD validation failed. Run './brigade.sh validate $prd_path' for details.${NC}"
    exit 1
  fi
  echo -e "${GREEN}✓${NC} PRD valid"

  # Check verification quality (warn if only grep-based, no execution tests)
  check_verification_quality "$prd_path"

  # Check for walkaway mode (from PRD or --walkaway flag)
  local is_walkaway=$(jq -r '.walkaway // false' "$prd_path")
  if [ "$is_walkaway" == "true" ]; then
    # Enable walkaway mode from PRD
    if [ "$WALKAWAY_MODE" != "true" ]; then
      WALKAWAY_MODE=true
      echo -e "${CYAN}Walkaway mode enabled (from PRD)${NC}"
    fi

    # Block walkaway PRDs with grep-only verification
    if ! check_verification_quality "$prd_path" 2>/dev/null; then
      echo ""
      echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
      echo -e "${RED}║  BLOCKED: Walkaway PRD requires execution-based tests     ║${NC}"
      echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
      echo ""
      echo -e "${GRAY}Walkaway mode runs unattended - grep-only verification is unsafe.${NC}"
      echo -e "${GRAY}Add at least one of these to each task's verification:${NC}"
      echo -e "${GRAY}  - Unit test:        npm test --grep 'feature'${NC}"
      echo -e "${GRAY}  - Integration test: go test -run TestIntegration ./...${NC}"
      echo -e "${GRAY}  - Smoke test:       ./binary --help${NC}"
      echo ""
      echo -e "${GRAY}Or set \"walkaway\": false in the PRD for attended execution.${NC}"
      exit 1
    fi
  fi

  # Update latest symlink
  update_latest_symlink "$prd_path"

  local feature_name=$(jq -r '.featureName' "$prd_path")
  local total=$(get_task_count "$prd_path")

  # Dry-run mode - show execution plan without running
  if [ "$DRY_RUN" == "true" ]; then
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  DRY RUN - Execution Plan (nothing will be executed)      ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}Feature:${NC} $feature_name"
    echo -e "${BOLD}PRD:${NC} $prd_path"
    echo ""

    # Show config
    echo -e "${BOLD}Configuration:${NC}"
    echo -e "  Executive Chef: ${CYAN}$EXECUTIVE_CMD${NC}"
    echo -e "  Sous Chef:      ${CYAN}$SOUS_CMD${NC}"
    echo -e "  Line Cook:      ${CYAN}$LINE_CMD${NC}"
    echo -e "  Test Command:   ${CYAN}${TEST_CMD:-"(none)"}${NC}"
    echo -e "  Max Iterations: $MAX_ITERATIONS"
    echo -e "  Escalation:     $([ "$ESCALATION_ENABLED" == "true" ] && echo "Line→Sous after $ESCALATION_AFTER, Sous→Exec after $ESCALATION_TO_EXEC_AFTER" || echo "OFF")"
    echo -e "  Exec Review:    $([ "$REVIEW_ENABLED" == "true" ] && echo "ON (junior only: $REVIEW_JUNIOR_ONLY)" || echo "OFF")"
    echo -e "  Phase Review:   $([ "$PHASE_REVIEW_ENABLED" == "true" ] && echo "Every $PHASE_REVIEW_AFTER tasks ($PHASE_REVIEW_ACTION)" || echo "OFF")"
    echo ""

    # Show task execution order
    echo -e "${BOLD}Execution Plan:${NC}"
    local task_num=0
    jq -r '.tasks[] | "\(.id)|\(.title)|\(.complexity // "auto")|\(.dependsOn | if length == 0 then "-" else join(",") end)|\(.passes)"' "$prd_path" | \
    while IFS='|' read -r id title complexity deps passes; do
      task_num=$((task_num + 1))
      if [ "$passes" == "true" ]; then
        echo -e "  ${GREEN}✓${NC} $id: $title ${GRAY}[done]${NC}"
      else
        local worker="?"
        case "$complexity" in
          "junior") worker="Line Cook" ;;
          "senior") worker="Sous Chef" ;;
          "auto") worker="Auto-route" ;;
        esac
        local dep_str=""
        [ "$deps" != "-" ] && dep_str=" ${GRAY}(after: $deps)${NC}"
        echo -e "  ○ $id: $title → ${CYAN}$worker${NC}$dep_str"
      fi
    done
    echo ""

    # Show parallel execution waves
    echo -e "${BOLD}Execution Waves (parallel groups):${NC}"
    local wave=1
    local processed=""
    local all_ids=$(jq -r '.tasks[] | select(.passes == false) | .id' "$prd_path")
    local remaining="$all_ids"

    while [ -n "$remaining" ]; do
      local wave_tasks=""
      local next_remaining=""

      for task_id in $remaining; do
        local deps=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .dependsOn // [] | .[]' "$prd_path" 2>/dev/null)
        local can_run=true

        # Check if all dependencies are either done or processed
        for dep in $deps; do
          if ! echo "$processed" | grep -q "^${dep}$" && \
             ! jq -r --arg id "$dep" '.tasks[] | select(.id == $id) | .passes' "$prd_path" | grep -q "true"; then
            can_run=false
            break
          fi
        done

        if [ "$can_run" == "true" ]; then
          wave_tasks="$wave_tasks $task_id"
        else
          next_remaining="$next_remaining $task_id"
        fi
      done

      if [ -n "$wave_tasks" ]; then
        local wave_count=$(echo $wave_tasks | wc -w | tr -d ' ')
        local parallel_note=""
        [ "$wave_count" -gt 1 ] && [ "$MAX_PARALLEL" -gt 1 ] && parallel_note=" ${GREEN}(can run in parallel)${NC}"
        echo -e "  Wave $wave:$parallel_note"
        for task_id in $wave_tasks; do
          local title=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .title' "$prd_path")
          local complexity=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .complexity // "auto"' "$prd_path")
          echo -e "    - $task_id: $title ${GRAY}[$complexity]${NC}"
          processed="$processed
$task_id"
        done
        wave=$((wave + 1))
      fi

      remaining=$(echo $next_remaining)
      # Safety check to prevent infinite loop
      [ "$remaining" == "$next_remaining" ] && break
    done
    echo ""

    # Show summary
    local pending=$(jq '[.tasks[] | select(.passes == false)] | length' "$prd_path")
    local junior_count=$(jq '[.tasks[] | select(.passes == false and .complexity == "junior")] | length' "$prd_path")
    local senior_count=$(jq '[.tasks[] | select(.passes == false and .complexity == "senior")] | length' "$prd_path")

    echo -e "${BOLD}Summary:${NC}"
    echo -e "  Pending tasks:  $pending (in $((wave - 1)) waves)"
    echo -e "  Junior tasks:   $junior_count → Line Cook ($LINE_AGENT)"
    echo -e "  Senior tasks:   $senior_count → Sous Chef ($SOUS_AGENT)"
    echo -e "  Max parallel:   $MAX_PARALLEL"
    if [ "$REVIEW_ENABLED" == "true" ]; then
      local review_count=$junior_count
      [ "$REVIEW_JUNIOR_ONLY" != "true" ] && review_count=$pending
      echo -e "  Exec reviews:   ~$review_count (Opus calls)"
    fi
    echo ""
    echo -e "${GRAY}Run without --dry-run to execute${NC}"
    return 0
  fi

  # Initialize state for context isolation
  if [ "$CONTEXT_ISOLATION" == "true" ]; then
    init_state "$prd_path"
    update_last_start_time "$prd_path"
  fi

  # Initialize knowledge sharing
  if [ "$KNOWLEDGE_SHARING" == "true" ]; then
    init_learnings "$prd_path"
  fi

  # Setup feature branch
  local branch_name=$(jq -r '.branchName // empty' "$prd_path")
  if [ -n "$branch_name" ]; then
    local current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ "$current_branch" != "$branch_name" ]; then
      if git show-ref --verify --quiet "refs/heads/$branch_name"; then
        echo -e "${GRAY}Checking out existing branch: $branch_name${NC}"
        git checkout "$branch_name"
      else
        echo -e "${GRAY}Creating feature branch: $branch_name${NC}"
        git checkout -b "$branch_name"
      fi
    else
      echo -e "${GRAY}Already on branch: $branch_name${NC}"
    fi
  fi

  log_event "START" "SERVICE STARTED: $feature_name"
  emit_supervisor_event "service_start" "$(basename "$prd_path")" "$total"
  echo -e "Total tickets: $total"
  echo -e "${GRAY}Escalation: $([ "$ESCALATION_ENABLED" == "true" ] && echo "ON (after $ESCALATION_AFTER iterations)" || echo "OFF")${NC}"
  echo -e "${GRAY}Executive Review: $([ "$REVIEW_ENABLED" == "true" ] && echo "ON" || echo "OFF")${NC}"
  echo -e "${GRAY}Knowledge Sharing: $([ "$KNOWLEDGE_SHARING" == "true" ] && echo "ON" || echo "OFF")${NC}"
  echo -e "${GRAY}Parallel Workers: $([ "$MAX_PARALLEL" -gt 1 ] && echo "$MAX_PARALLEL" || echo "OFF")${NC}"
  echo ""

  local service_start=$(date +%s)
  local completed=0

  while true; do
    local ready_tasks=$(get_ready_tasks "$prd_path")

    if [ -z "$ready_tasks" ]; then
      # Check if all done or blocked
      local pending=$(jq '[.tasks[] | select(.passes == false)] | length' "$prd_path")
      if [ "$pending" -eq 0 ]; then
        break  # All done
      else
        echo -e "${RED}No available tasks - remaining tasks may be blocked${NC}"
        cmd_status "$prd_path"
        exit 1
      fi
    fi

    # Convert to array
    local tasks_array=($ready_tasks)
    local num_ready=${#tasks_array[@]}

    # Check for parallel execution
    if [ "$MAX_PARALLEL" -gt 1 ] && [ "$num_ready" -gt 1 ]; then
      # Build parallel batch: include ONE senior task (if ready) + junior tasks
      # This prevents senior tasks from starving when many juniors are ready
      local parallel_tasks=""
      local parallel_count=0
      local senior_task=""
      local junior_tasks=""

      # First pass: separate senior and junior tasks
      for task_id in "${tasks_array[@]}"; do
        local complexity=$(get_task_complexity "$prd_path" "$task_id")
        if [ "$complexity" == "senior" ] && [ -z "$senior_task" ]; then
          senior_task="$task_id"
        elif [ "$complexity" == "junior" ]; then
          junior_tasks="$junior_tasks $task_id"
        fi
      done

      # Add senior task first (if any) - gets priority slot
      if [ -n "$senior_task" ]; then
        parallel_tasks="$senior_task"
        parallel_count=1
      fi

      # Fill remaining slots with junior tasks
      for task_id in $junior_tasks; do
        if [ "$parallel_count" -lt "$MAX_PARALLEL" ]; then
          parallel_tasks="$parallel_tasks $task_id"
          parallel_count=$((parallel_count + 1))
        fi
      done

      parallel_tasks=$(echo "$parallel_tasks" | xargs)

      if [ "$parallel_count" -gt 1 ]; then
        echo ""
        echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
        local senior_note=""
        [ -n "$senior_task" ] && senior_note=" (includes 1 senior)"
        log_event "START" "PARALLEL EXECUTION: $parallel_count tasks${senior_note}"
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
        echo ""

        # Run tasks in parallel
        local pids=""
        local task_pid_map=""

        for task_id in $parallel_tasks; do
          (
            cmd_ticket "$prd_path" "$task_id"
            exit $?
          ) &
          local pid=$!
          pids="$pids $pid"
          task_pid_map="$task_pid_map $task_id:$pid"
          local parallel_display_id=$(format_task_id "$prd_path" "$task_id")
          log_event "INFO" "Started $parallel_display_id (PID: $pid)"
        done

        # Wait for all parallel tasks
        local all_success=true
        local failed_tasks=""
        for mapping in $task_pid_map; do
          local task_id=$(echo "$mapping" | cut -d: -f1)
          local pid=$(echo "$mapping" | cut -d: -f2)
          local parallel_display_id=$(format_task_id "$prd_path" "$task_id")

          wait "$pid"
          local exit_code=$?

          # Exit codes: 0=COMPLETE, 33=ALREADY_DONE, 34=ABSORBED_BY - all are success
          if [ $exit_code -eq 0 ] || [ $exit_code -eq 33 ] || [ $exit_code -eq 34 ]; then
            log_event "SUCCESS" "$parallel_display_id completed (parallel)"
            completed=$((completed + 1))
          else
            log_event "ERROR" "$parallel_display_id failed (parallel, exit=$exit_code)"
            all_success=false
            failed_tasks="$failed_tasks $task_id"
          fi
        done

        if [ "$all_success" != "true" ]; then
          echo -e "${RED}Some parallel tasks failed${NC}"

          # Handle failure decisions - supervisor, walkaway, or exit
          if [ -n "$SUPERVISOR_CMD_FILE" ] || [ "$WALKAWAY_MODE" == "true" ]; then
            for failed_task in $failed_tasks; do
              local state_path=$(get_state_path "$prd_path")
              local last_entry=$(jq -r --arg task "$failed_task" '[.taskHistory[] | select(.taskId == $task)] | last' "$state_path" 2>/dev/null)
              local last_status=$(echo "$last_entry" | jq -r '.status // "failed"')
              local last_worker=$(echo "$last_entry" | jq -r '.worker // "unknown"')
              local task_title=$(jq -r --arg id "$failed_task" '.tasks[] | select(.id == $id) | .title' "$prd_path")

              # Build context for decision
              local context=$(cat <<EOF
{"failureReason":"$last_status","iterations":0,"lastWorker":"$last_worker","taskTitle":"$task_title"}
EOF
)

              wait_for_decision "max_iterations" "$failed_task" "$context" "$prd_path" "$last_worker"
              local decision=$?

              case $decision in
                0)  # RETRY - will be picked up in next iteration
                  log_event "DECISION" "Will retry task $failed_task in next iteration"
                  local tmp_file=$(brigade_mktemp)
                  jq '.currentTask = null' "$state_path" > "$tmp_file" && mv "$tmp_file" "$state_path"
                  ;;
                1)  # SKIP
                  WALKAWAY_CONSECUTIVE_SKIPS=$((WALKAWAY_CONSECUTIVE_SKIPS + 1))
                  log_event "DECISION" "Skipping task $failed_task (consecutive skips: $WALKAWAY_CONSECUTIVE_SKIPS)"

                  if [ "$WALKAWAY_CONSECUTIVE_SKIPS" -ge "$WALKAWAY_MAX_SKIPS" ]; then
                    echo -e "${RED}PAUSED: Max consecutive skips reached${NC}"
                    exit 1
                  fi

                  update_state_task "$prd_path" "$failed_task" "$last_worker" "skipped_decision"
                  ;;
                2)  # ABORT
                  echo -e "${RED}ABORT: Decision to abort the run${NC}"
                  exit 1
                  ;;
              esac
            done
            echo -e "${YELLOW}Continuing with remaining tasks...${NC}"
          else
            exit 1
          fi
        else
          WALKAWAY_CONSECUTIVE_SKIPS=0  # Reset on success
        fi

        # Phase review at intervals (after parallel batch)
        phase_review "$prd_path" "$completed"

        continue  # Check for more tasks
      fi
    fi

    # Sequential execution (default)
    local next_task="${tasks_array[0]}"

    if cmd_ticket "$prd_path" "$next_task"; then
      completed=$((completed + 1))
      WALKAWAY_CONSECUTIVE_SKIPS=0  # Reset on success
      # Phase review at intervals
      phase_review "$prd_path" "$completed"
    else
      echo -e "${RED}Failed to complete $next_task${NC}"

      # Handle failure decisions - supervisor, walkaway, or exit
      if [ -n "$SUPERVISOR_CMD_FILE" ] || [ "$WALKAWAY_MODE" == "true" ]; then
        # Get failure info from state
        local state_path=$(get_state_path "$prd_path")
        local last_entry=$(jq -r --arg task "$next_task" '[.taskHistory[] | select(.taskId == $task)] | last' "$state_path" 2>/dev/null)
        local last_status=$(echo "$last_entry" | jq -r '.status // "failed"')
        local last_worker=$(echo "$last_entry" | jq -r '.worker // "unknown"')
        local iteration_count=$(echo "$last_entry" | jq -r '.status | if startswith("iteration_") then (. | sub("iteration_"; "") | tonumber) else 0 end' 2>/dev/null || echo 0)
        local task_title=$(jq -r --arg id "$next_task" '.tasks[] | select(.id == $id) | .title' "$prd_path")

        # Build context for decision
        local context=$(cat <<EOF
{"failureReason":"$last_status","iterations":$iteration_count,"lastWorker":"$last_worker","taskTitle":"$task_title"}
EOF
)

        wait_for_decision "max_iterations" "$next_task" "$context" "$prd_path" "$last_worker"
        local decision=$?

        case $decision in
          0)  # RETRY
            log_event "DECISION" "Retrying task $next_task"
            # Clear currentTask to allow fresh start
            local tmp_file=$(brigade_mktemp)
            jq '.currentTask = null' "$state_path" > "$tmp_file" && mv "$tmp_file" "$state_path"
            continue  # Loop again, will pick up same task
            ;;
          1)  # SKIP
            WALKAWAY_CONSECUTIVE_SKIPS=$((WALKAWAY_CONSECUTIVE_SKIPS + 1))
            log_event "DECISION" "Skipping task $next_task (consecutive skips: $WALKAWAY_CONSECUTIVE_SKIPS)"

            # Check safety rail
            if [ "$WALKAWAY_CONSECUTIVE_SKIPS" -ge "$WALKAWAY_MAX_SKIPS" ]; then
              echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
              echo -e "${RED}║  PAUSED: Max consecutive skips reached                    ║${NC}"
              echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
              log_event "DECISION" "PAUSED: $WALKAWAY_CONSECUTIVE_SKIPS consecutive skips"
              echo ""
              echo -e "Run './brigade.sh resume $prd_path' to continue manually."
              exit 1
            fi

            # Mark task as skipped and continue
            update_state_task "$prd_path" "$next_task" "$last_worker" "skipped_decision"
            local tmp_file=$(brigade_mktemp)
            jq '.currentTask = null' "$state_path" > "$tmp_file" && mv "$tmp_file" "$state_path"
            echo -e "${YELLOW}Task $next_task skipped, continuing...${NC}"
            continue  # Loop again, will get next available task
            ;;
          2)  # ABORT
            echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║  ABORT: Decision to abort the run                         ║${NC}"
            echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
            echo -e "${GRAY}Reason: $DECISION_REASON${NC}"
            exit 1
            ;;
        esac
      else
        exit 1
      fi
    fi
  done

  local service_end=$(date +%s)
  local duration=$((service_end - service_start))
  local hours=$((duration / 3600))
  local minutes=$(((duration % 3600) / 60))

  # Get PRD info for summary
  local feature_name=$(jq -r '.featureName // "Unknown"' "$prd_path")
  local branch_name=$(jq -r '.branchName // empty' "$prd_path")
  local total_tasks=$(jq '.tasks | length' "$prd_path")

  # Get stats from state file
  local state_path=$(get_state_path "$prd_path")
  local escalation_count=0
  local absorption_count=0
  local review_count=0
  local review_pass=0
  if [ -f "$state_path" ]; then
    escalation_count=$(jq '(.escalations // []) | length' "$state_path" 2>/dev/null || echo 0)
    absorption_count=$(jq '(.absorptions // []) | length' "$state_path" 2>/dev/null || echo 0)
    review_count=$(jq '(.reviews // []) | length' "$state_path" 2>/dev/null || echo 0)
    review_pass=$(jq '[(.reviews // [])[] | select(.result == "PASS")] | length' "$state_path" 2>/dev/null || echo 0)
  fi

  # Archive learnings from this PRD run
  archive_learnings "$prd_path"

  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║                    🎉 PRD COMPLETE 🎉                     ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}Feature:${NC}     $feature_name"
  [ -n "$branch_name" ] && echo -e "${BOLD}Branch:${NC}      $branch_name"
  echo ""
  echo -e "${BOLD}Summary:${NC}"
  echo -e "  Tasks completed:   $completed/$total_tasks"
  echo -e "  Time taken:        ${hours}h ${minutes}m"
  echo -e "  Escalations:       $escalation_count"
  echo -e "  Absorptions:       $absorption_count"
  [ "$review_count" -gt 0 ] && echo -e "  Reviews:           $review_pass/$review_count passed"
  echo ""

  log_event "SUCCESS" "SERVICE COMPLETE: $feature_name - $completed tasks in ${hours}h ${minutes}m"
  local failed_tasks=$((total_tasks - completed))
  emit_supervisor_event "service_complete" "$completed" "$failed_tasks" "$duration"

  # Merge feature branch to default branch
  local merge_status="none"  # none, success, failed, pushed
  local default_branch=""
  local stashed=false
  if [ -n "$branch_name" ]; then
    local current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ "$current_branch" == "$branch_name" ]; then
      default_branch=$(get_default_branch)

      # Check for uncommitted changes that would block checkout
      if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        echo -e "${YELLOW}Uncommitted changes detected, stashing before merge...${NC}"
        if git stash push -m "brigade-auto-stash-before-merge"; then
          stashed=true
          echo -e "${GREEN}✓ Changes stashed${NC}"
        else
          echo -e "${RED}Failed to stash changes - merge aborted${NC}"
          merge_status="failed"
        fi
      fi

      if [ "$merge_status" != "failed" ]; then
        echo -e "${CYAN}Merging $branch_name to $default_branch...${NC}"
      fi
      if [ "$merge_status" != "failed" ] && git checkout "$default_branch" && git merge "$branch_name" --no-edit; then
        echo -e "${GREEN}✓ Merged $branch_name to $default_branch${NC}"
        merge_status="success"
        if git push origin "$default_branch" 2>/dev/null; then
          echo -e "${GREEN}✓ Pushed to origin/$default_branch${NC}"
          merge_status="pushed"
          # Clean up feature branch (local and remote)
          if git branch -d "$branch_name" 2>/dev/null; then
            echo -e "${GREEN}✓ Deleted local branch $branch_name${NC}"
          fi
          if git push origin --delete "$branch_name" 2>/dev/null; then
            echo -e "${GREEN}✓ Deleted remote branch origin/$branch_name${NC}"
          fi
        fi
      else
        echo -e "${RED}Merge failed - resolve conflicts manually${NC}"
        merge_status="failed"
        git checkout "$branch_name"
      fi

      # Restore stashed changes if we stashed earlier
      if [ "$stashed" = "true" ]; then
        echo -e "${CYAN}Restoring stashed changes...${NC}"
        if git stash pop; then
          echo -e "${GREEN}✓ Stashed changes restored${NC}"
        else
          echo -e "${YELLOW}⚠ Could not auto-restore stash (may have conflicts). Run: git stash pop${NC}"
        fi
      fi
      echo ""
    fi
  fi

  # Show next steps based on what happened
  echo -e "${BOLD}Next Steps:${NC}"
  echo -e "  • Run ${CYAN}./brigade.sh status${NC} to review detailed stats"
  echo -e "  • Check ${CYAN}git log --oneline -10${NC} to review commits"

  case "$merge_status" in
    "pushed")
      echo -e "  • ${GREEN}✓ Merged, pushed, and cleaned up $branch_name${NC}"
      ;;
    "success")
      echo -e "  • ${GREEN}✓ Merged to $default_branch${NC} - push when ready: ${CYAN}git push origin $default_branch${NC}"
      echo -e "  • After push, delete branch: ${CYAN}git branch -d $branch_name && git push origin --delete $branch_name${NC}"
      ;;
    "failed")
      echo -e "  • ${RED}⚠ Merge had conflicts${NC} - resolve and retry: ${CYAN}git checkout $default_branch && git merge $branch_name${NC}"
      ;;
    *)
      if [ -n "$branch_name" ]; then
        echo -e "  • Create PR or merge to main when ready"
      fi
      ;;
  esac

  echo -e "  • For chained PRDs, use ${CYAN}./brigade.sh --auto-continue service prd-*.json${NC}"
  echo ""
}

cmd_plan() {
  local description="$*"

  if [ -z "$description" ]; then
    echo -e "${RED}Error: Please provide a feature description${NC}"
    echo "Usage: ./brigade.sh plan \"Add user authentication with JWT\""
    exit 1
  fi

  # Create tasks directory if it doesn't exist
  mkdir -p "brigade/tasks"

  # Generate filename from description (truncate at word boundary, no trailing dash)
  local slug=$(echo "$description" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | cut -c1-50 | sed 's/-$//')
  local prd_file="brigade/tasks/prd-${slug}.json"
  local today=$(date +%Y-%m-%d)

  # Count existing PRDs for context
  local existing_prds=$(ls brigade/tasks/prd-*.json 2>/dev/null | grep -v '\.state\.json' | wc -l | tr -d ' ')
  local prd_number=$((existing_prds + 1))

  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  log_event "START" "PLANNING PHASE: $description"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo ""

  # Build planning prompt
  local planning_prompt=""

  # Read the skill prompt - check multiple locations
  local skill_file=""
  if [ -f "$SCRIPT_DIR/commands/brigade-generate-prd.md" ]; then
    skill_file="$SCRIPT_DIR/commands/brigade-generate-prd.md"
  elif [ -f "$SCRIPT_DIR/.claude/skills/generate-prd.md" ]; then
    skill_file="$SCRIPT_DIR/.claude/skills/generate-prd.md"
  fi

  if [ -n "$skill_file" ]; then
    planning_prompt=$(cat "$skill_file")
    planning_prompt="$planning_prompt

---
"
  fi

  # Include codebase map if available, checking for staleness
  local codebase_map=""
  check_map_staleness "brigade/codebase-map.md"
  local staleness=$?

  if [ $staleness -eq 2 ]; then
    # No map exists - remind user
    echo -e "${GRAY}Tip: Run './brigade.sh map' to generate a codebase map for better planning context.${NC}"
    echo ""
  elif [ $staleness -eq 1 ]; then
    # Map is stale - auto-regenerate
    if [ "$MAP_COMMITS_BEHIND" -eq -1 ]; then
      echo -e "${YELLOW}Codebase map exists but has no commit tracking (old format). Regenerating...${NC}"
    else
      echo -e "${YELLOW}Codebase map is ${MAP_COMMITS_BEHIND} commits behind HEAD. Regenerating...${NC}"
    fi
    echo ""
    cmd_map "brigade/codebase-map.md"
    echo ""
  fi

  if [ -f "brigade/codebase-map.md" ]; then
    codebase_map="
---
CODEBASE MAP (generated by ./brigade.sh map):
$(cat brigade/codebase-map.md)
---
"
  fi

  planning_prompt="${planning_prompt}${codebase_map}PLANNING REQUEST

Feature Description: $description
Output File: $prd_file
Today's Date: $today

INSTRUCTIONS:
1. Analyze the codebase to understand project structure and patterns
2. Break down the feature into well-scoped tasks
3. Assign appropriate complexity (junior/senior) to each task
4. Define dependencies between tasks
5. Write specific, verifiable acceptance criteria

OUTPUT:
Generate the PRD JSON and save it to: $prd_file

After generating, output:
<prd_generated>$prd_file</prd_generated>

BEGIN PLANNING:"

  local output_file=$(brigade_mktemp)
  local start_time=$(date +%s)

  echo -e "${GRAY}Invoking Executive Chef (Director)...${NC}"
  echo -e "${GRAY}Running in quick mode (no interview). For full interview, use /brigade-generate-prd in Claude Code.${NC}"
  echo ""

  # Run with -p for non-interactive quick planning
  if $EXECUTIVE_CMD --dangerously-skip-permissions -p "$planning_prompt" 2>&1 | tee "$output_file"; then
    echo ""
    echo -e "${GREEN}Planning completed${NC}"
  else
    echo ""
    echo -e "${YELLOW}Planning exited${NC}"
  fi

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))
  echo -e "${GRAY}Duration: ${duration}s${NC}"

  # Check if PRD was generated - first try signal, then check file exists
  local generated_file=""
  if grep -q "<prd_generated>" "$output_file" 2>/dev/null; then
    generated_file=$(sed -n 's/.*<prd_generated>\(.*\)<\/prd_generated>.*/\1/p' "$output_file" | head -1)
  elif [ -f "$prd_file" ]; then
    generated_file="$prd_file"
  fi

  if [ -n "$generated_file" ] && [ -f "$generated_file" ]; then
    # Update latest symlink
    update_latest_symlink "$generated_file"

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    log_event "SUCCESS" "PRD GENERATED: $generated_file (${duration}s)"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Show summary
    local task_count=$(jq '.tasks | length' "$generated_file" 2>/dev/null || echo "?")
    local junior_count=$(jq '[.tasks[] | select(.complexity == "junior")] | length' "$generated_file" 2>/dev/null || echo "?")
    local senior_count=$(jq '[.tasks[] | select(.complexity == "senior")] | length' "$generated_file" 2>/dev/null || echo "?")

    echo -e "Tasks: $task_count total (${CYAN}$senior_count senior${NC}, ${GREEN}$junior_count junior${NC})"
    echo ""

    # Show PRD count context
    local total_prds=$(ls brigade/tasks/prd-*.json 2>/dev/null | grep -v '\.state\.json' | wc -l | tr -d ' ')

    echo -e "${BOLD}Next steps:${NC}"
    echo -e "  1. Review the PRD: ${CYAN}cat $generated_file | jq${NC}"
    if [ "$total_prds" -gt 1 ]; then
      echo -e "  2. Run this PRD:   ${CYAN}./brigade.sh service $generated_file${NC}"
      echo -e "  3. Run all PRDs:   ${CYAN}./brigade.sh --auto-continue service brigade/tasks/prd-*.json${NC}"
      echo ""
      echo -e "${GRAY}This is PRD $total_prds of $total_prds in brigade/tasks/${NC}"
    else
      echo -e "  2. Run service:    ${CYAN}./brigade.sh service $generated_file${NC}"
    fi
  else
    echo ""
    echo -e "${YELLOW}PRD generation may have failed. Check output above.${NC}"
  fi

  rm -f "$output_file"
}

cmd_analyze() {
  local prd_path="$1"

  if [ ! -f "$prd_path" ]; then
    echo -e "${RED}Error: PRD file not found: $prd_path${NC}"
    exit 1
  fi

  echo -e "${BOLD}Task Analysis:${NC}"
  echo ""

  jq -r '.tasks[] | "\(.id)|\(.title)|\(.complexity // "auto")|\(.acceptanceCriteria | length)"' "$prd_path" | \
  while IFS='|' read -r id title complexity criteria_count; do
    local suggested="sous"

    # Simple heuristics for auto-routing
    if [ "$complexity" == "auto" ]; then
      # Junior indicators
      if [[ "$title" =~ [Tt]est ]] || \
         [[ "$title" =~ [Bb]oilerplate ]] || \
         [[ "$title" =~ [Aa]dd.*[Ff]lag ]] || \
         [[ "$title" =~ [Ss]imple ]] || \
         [ "$criteria_count" -le 3 ]; then
        suggested="line"
      fi
      echo -e "  $id: $title"
      echo -e "    ${GRAY}Criteria: $criteria_count | Suggested: ${CYAN}$suggested${NC}"
    else
      echo -e "  $id: $title"
      echo -e "    ${GRAY}Criteria: $criteria_count | Assigned: ${CYAN}$complexity${NC}"
    fi
  done

  echo ""
}

cmd_validate() {
  local prd_path="$1"

  if [ ! -f "$prd_path" ]; then
    echo -e "${RED}Error: PRD file not found: $prd_path${NC}"
    exit 1
  fi

  echo ""
  echo -e "${BOLD}Validating PRD:${NC} $prd_path"
  echo ""

  local errors=0
  local warnings=0

  # Check JSON structure
  if ! jq empty "$prd_path" 2>/dev/null; then
    echo -e "${RED}✗ Invalid JSON${NC}"
    exit 1
  fi
  echo -e "${GREEN}✓${NC} Valid JSON"

  # Check required fields
  local feature_name=$(jq -r '.featureName // empty' "$prd_path")
  if [ -z "$feature_name" ]; then
    echo -e "${RED}✗ Missing featureName${NC}"
    errors=$((errors + 1))
  else
    echo -e "${GREEN}✓${NC} Has featureName: $feature_name"
  fi

  # Check tasks array exists
  local task_count=$(jq '.tasks | length' "$prd_path" 2>/dev/null)
  if [ -z "$task_count" ] || [ "$task_count" == "null" ]; then
    echo -e "${RED}✗ Missing or invalid tasks array${NC}"
    errors=$((errors + 1))
  else
    echo -e "${GREEN}✓${NC} Has $task_count tasks"
  fi

  # Check for duplicate task IDs
  local unique_ids=$(jq -r '.tasks[].id' "$prd_path" | sort -u | wc -l | tr -d ' ')
  local total_ids=$(jq -r '.tasks[].id' "$prd_path" | wc -l | tr -d ' ')
  if [ "$unique_ids" != "$total_ids" ]; then
    echo -e "${RED}✗ Duplicate task IDs found${NC}"
    jq -r '.tasks[].id' "$prd_path" | sort | uniq -d | while read -r dup; do
      echo -e "    Duplicate: $dup"
    done
    errors=$((errors + 1))
  else
    echo -e "${GREEN}✓${NC} All task IDs unique"
  fi

  # Check for missing task fields
  local missing_fields=$(jq -r '.tasks[] | select(.id == null or .title == null) | .id // "unnamed"' "$prd_path")
  if [ -n "$missing_fields" ]; then
    echo -e "${RED}✗ Tasks missing id or title${NC}"
    errors=$((errors + 1))
  fi

  # Check for circular dependencies
  echo -e "${GRAY}Checking for circular dependencies...${NC}"
  local has_cycle=false

  # Get all task IDs
  local all_ids=$(jq -r '.tasks[].id' "$prd_path")

  # For each task, follow dependency chain and check for cycles
  for task_id in $all_ids; do
    local visited=""
    local current="$task_id"
    local depth=0
    local max_depth=$task_count

    while [ $depth -lt $max_depth ]; do
      # Check if we've seen this task before in this chain
      if echo "$visited" | grep -q "^${current}$"; then
        echo -e "${RED}✗ Circular dependency detected involving: $task_id${NC}"
        has_cycle=true
        errors=$((errors + 1))
        break
      fi

      visited="$visited
$current"

      # Get dependencies of current task
      local deps=$(jq -r --arg id "$current" '.tasks[] | select(.id == $id) | .dependsOn // [] | .[]' "$prd_path" 2>/dev/null | head -1)

      if [ -z "$deps" ]; then
        break  # No more dependencies
      fi

      current="$deps"
      depth=$((depth + 1))
    done

    if [ "$has_cycle" == "true" ]; then
      break
    fi
  done

  if [ "$has_cycle" != "true" ]; then
    echo -e "${GREEN}✓${NC} No circular dependencies"
  fi

  # Check for invalid dependency references
  for task_id in $all_ids; do
    local deps=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .dependsOn // [] | .[]' "$prd_path" 2>/dev/null)
    for dep in $deps; do
      if ! echo "$all_ids" | grep -q "^${dep}$"; then
        echo -e "${RED}✗ Task $task_id depends on non-existent task: $dep${NC}"
        errors=$((errors + 1))
      fi
    done
  done
  echo -e "${GREEN}✓${NC} All dependency references valid"

  # Check for tasks without acceptance criteria
  local no_criteria=$(jq -r '.tasks[] | select(.acceptanceCriteria == null or (.acceptanceCriteria | length) == 0) | .id' "$prd_path")
  if [ -n "$no_criteria" ]; then
    echo -e "${YELLOW}⚠${NC} Tasks without acceptance criteria:"
    echo "$no_criteria" | while read -r id; do
      echo -e "    $id"
    done
    warnings=$((warnings + 1))
  fi

  # Check for tasks missing complexity field
  local no_complexity=$(jq -r '.tasks[] | select(.complexity == null or .complexity == "") | .id' "$prd_path")
  if [ -n "$no_complexity" ]; then
    echo -e "${YELLOW}⚠${NC} Tasks missing complexity field (will default to 'auto'):"
    echo "$no_complexity" | while read -r id; do
      echo -e "    $id"
    done
    warnings=$((warnings + 1))
  else
    echo -e "${GREEN}✓${NC} All tasks have complexity assigned"
  fi

  # Check for invalid complexity values
  local invalid_complexity=$(jq -r '.tasks[] | select(.complexity != null and .complexity != "" and .complexity != "junior" and .complexity != "senior" and .complexity != "auto" and .complexity != "line" and .complexity != "sous") | "\(.id): \(.complexity)"' "$prd_path")
  if [ -n "$invalid_complexity" ]; then
    echo -e "${RED}✗ Tasks with invalid complexity values:${NC}"
    echo "$invalid_complexity" | while read -r line; do
      echo -e "    $line"
    done
    errors=$((errors + 1))
  fi

  # Check verification commands
  local has_verification=$(jq -r '[.tasks[] | select(.verification != null and (.verification | length) > 0)] | length' "$prd_path")
  local total_tasks=$(jq '.tasks | length' "$prd_path")
  if [ "$has_verification" -gt 0 ]; then
    echo -e "${GREEN}✓${NC} $has_verification of $total_tasks tasks have verification commands"

    # Check for potentially dangerous verification commands
    local dangerous_cmds=$(jq -r '.tasks[] | select(.verification != null) | .id as $id | .verification[] | select(test("rm -rf|rm -r|rmdir|>/dev|dd if=|mkfs|format|deltree|del /")) | "\($id): \(.)"' "$prd_path" 2>/dev/null)
    if [ -n "$dangerous_cmds" ]; then
      echo -e "${RED}✗ Potentially dangerous verification commands found:${NC}"
      echo "$dangerous_cmds" | while read -r line; do
        echo -e "    $line"
      done
      errors=$((errors + 1))
    fi
  else
    echo -e "${GRAY}ℹ${NC} No verification commands defined (optional)"
  fi

  # Check verification type coverage (task type vs verification type)
  if [ "$has_verification" -gt 0 ]; then
    echo ""
    echo -e "${GRAY}Checking verification type coverage...${NC}"
    local coverage_warnings=0

    for task_id in $all_ids; do
      if ! check_verification_coverage "$prd_path" "$task_id"; then
        echo -e "  ${YELLOW}⚠${NC} $VERIFICATION_COVERAGE_WARNING"
        coverage_warnings=$((coverage_warnings + 1))
      fi
    done

    if [ "$coverage_warnings" -gt 0 ]; then
      warnings=$((warnings + coverage_warnings))
    else
      echo -e "${GREEN}✓${NC} Verification types match task types"
    fi
  fi

  # Check walkaway mode + grep-only verification (blocking combination)
  local is_walkaway=$(jq -r '.walkaway // false' "$prd_path")
  if [ "$is_walkaway" == "true" ]; then
    if ! check_verification_quality "$prd_path" 2>/dev/null; then
      echo -e "${RED}✗ Walkaway PRD has grep-only verification - unsafe for unattended execution${NC}"
      echo -e "  ${GRAY}Walkaway mode requires at least one execution-based verification command${NC}"
      echo -e "  ${GRAY}Add unit, integration, or smoke tests to each task${NC}"
      errors=$((errors + 1))
    fi
  fi

  # Summary
  echo ""
  if [ $errors -eq 0 ] && [ $warnings -eq 0 ]; then
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  PRD VALID - Ready for execution                          ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
  elif [ $errors -eq 0 ]; then
    echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  PRD VALID with $warnings warning(s)                              ║${NC}"
    echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
  else
    echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  PRD INVALID - $errors error(s) found                            ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
    exit 1
  fi
}

cmd_summary() {
  local prd_path="$1"
  local output_file="$2"

  # Auto-detect PRD if not provided
  if [ -z "$prd_path" ]; then
    prd_path=$(find_active_prd)
    if [ -z "$prd_path" ]; then
      echo -e "${RED}Error: No PRD found. Specify a PRD path.${NC}"
      exit 1
    fi
  fi

  if [ ! -f "$prd_path" ]; then
    echo -e "${RED}Error: PRD file not found: $prd_path${NC}"
    exit 1
  fi

  local state_path="${prd_path%.json}.state.json"
  if [ ! -f "$state_path" ]; then
    echo -e "${RED}Error: No state file found for this PRD.${NC}"
    echo -e "${GRAY}State file expected at: $state_path${NC}"
    echo -e "${GRAY}Run service first: ./brigade.sh service $prd_path${NC}"
    exit 1
  fi

  local feature_name=$(jq -r '.featureName' "$prd_path")
  local branch_name=$(jq -r '.branchName // "N/A"' "$prd_path")
  local total_tasks=$(jq '.tasks | length' "$prd_path")
  local completed_tasks=$(jq '[.tasks[] | select(.passes == true)] | length' "$prd_path")

  # Time calculations
  local started_at=$(jq -r '.startedAt // empty' "$state_path")
  local last_start=$(jq -r '.lastStartTime // empty' "$state_path")

  # Generate markdown report
  local report=""
  report+="# Brigade Summary: $feature_name\n\n"
  report+="**PRD:** \`$prd_path\`\n"
  report+="**Branch:** \`$branch_name\`\n"
  report+="**Generated:** $(date '+%Y-%m-%d %H:%M')\n\n"

  # Progress
  local pct=$((completed_tasks * 100 / total_tasks))
  report+="## Progress\n\n"
  report+="- **Tasks:** $completed_tasks / $total_tasks ($pct%)\n"
  if [ -n "$started_at" ]; then
    report+="- **Started:** $started_at\n"
  fi
  if [ -n "$last_start" ]; then
    report+="- **Last Run:** $last_start\n"
  fi
  report+="\n"

  # Task completion timeline
  report+="## Task Timeline\n\n"
  report+="| Task | Title | Worker | Status | Time |\n"
  report+="|------|-------|--------|--------|------|\n"

  # Get task history grouped by task
  jq -r '.tasks[] | "\(.id)|\(.title)|\(.passes)"' "$prd_path" | while IFS='|' read -r task_id title passes; do
    local worker=$(jq -r --arg id "$task_id" '[.taskHistory[] | select(.taskId == $id)] | last | .worker // "—"' "$state_path")
    local status="○ Pending"
    if [ "$passes" == "true" ]; then
      status="✓ Complete"
    fi
    local timestamp=$(jq -r --arg id "$task_id" '[.taskHistory[] | select(.taskId == $id)] | last | .timestamp // "—"' "$state_path")
    local time_short=$(echo "$timestamp" | cut -d'T' -f1 2>/dev/null || echo "—")
    local worker_name=""
    case "$worker" in
      "line") worker_name="Line Cook" ;;
      "sous") worker_name="Sous Chef" ;;
      "executive") worker_name="Exec Chef" ;;
      *) worker_name="$worker" ;;
    esac
    echo "| $task_id | ${title:0:40} | $worker_name | $status | $time_short |"
  done > /tmp/brigade_summary_tasks.tmp
  report+=$(cat /tmp/brigade_summary_tasks.tmp)
  report+="\n\n"
  rm -f /tmp/brigade_summary_tasks.tmp

  # Escalations
  local escalation_count=$(jq '.escalations | length' "$state_path")
  if [ "$escalation_count" -gt 0 ]; then
    report+="## Escalations ($escalation_count)\n\n"
    jq -r '.escalations[] | "- **\(.taskId)**: \(.from) → \(.to) — \(.reason // "No reason")"' "$state_path" | while read -r line; do
      echo "$line"
    done > /tmp/brigade_summary_esc.tmp
    report+=$(cat /tmp/brigade_summary_esc.tmp)
    report+="\n\n"
    rm -f /tmp/brigade_summary_esc.tmp
  fi

  # Reviews
  local review_count=$(jq '.reviews | length' "$state_path")
  if [ "$review_count" -gt 0 ]; then
    local pass_count=$(jq '[.reviews[] | select(.result == "PASS")] | length' "$state_path")
    local fail_count=$(jq '[.reviews[] | select(.result == "FAIL")] | length' "$state_path")
    report+="## Executive Reviews ($review_count)\n\n"
    report+="- **Passed:** $pass_count\n"
    report+="- **Failed:** $fail_count\n\n"

    if [ "$fail_count" -gt 0 ]; then
      report+="### Failed Reviews\n\n"
      jq -r '.reviews[] | select(.result == "FAIL") | "- **\(.taskId)**: \(.reason // "No reason")"' "$state_path" | while read -r line; do
        echo "$line"
      done > /tmp/brigade_summary_rev.tmp
      report+=$(cat /tmp/brigade_summary_rev.tmp)
      report+="\n\n"
      rm -f /tmp/brigade_summary_rev.tmp
    fi
  fi

  # Absorptions
  local absorption_count=$(jq '.absorptions | length' "$state_path")
  if [ "$absorption_count" -gt 0 ]; then
    report+="## Task Absorptions ($absorption_count)\n\n"
    jq -r '.absorptions[] | "- **\(.taskId)** absorbed by **\(.absorbedBy)**"' "$state_path" | while read -r line; do
      echo "$line"
    done > /tmp/brigade_summary_abs.tmp
    report+=$(cat /tmp/brigade_summary_abs.tmp)
    report+="\n\n"
    rm -f /tmp/brigade_summary_abs.tmp
  fi

  # Learnings (if file exists)
  local learnings_path=$(get_learnings_path "$prd_path")
  if [ -f "$learnings_path" ]; then
    local learning_count=$(grep -c "^## \[" "$learnings_path" 2>/dev/null || echo "0")
    if [ "$learning_count" -gt 0 ]; then
      report+="## Learnings ($learning_count)\n\n"
      report+="See full learnings in: \`$learnings_path\`\n\n"
    fi
  fi

  # Backlog (if file exists)
  local backlog_path=$(get_backlog_path "$prd_path")
  if [ -f "$backlog_path" ]; then
    local backlog_count=$(grep -c "^## \[" "$backlog_path" 2>/dev/null || echo "0")
    if [ "$backlog_count" -gt 0 ]; then
      report+="## Backlog Items ($backlog_count)\n\n"
      report+="See full backlog in: \`$backlog_path\`\n\n"
    fi
  fi

  report+="---\n\n"
  report+="_Generated by Brigade_\n"

  # Output
  if [ -n "$output_file" ]; then
    echo -e "$report" > "$output_file"
    echo -e "${GREEN}Summary written to: $output_file${NC}"
  else
    echo -e "$report"
  fi
}

# Check if codebase map is stale (too many commits behind HEAD)
# Returns: 0 = fresh, 1 = stale, 2 = no map exists
# Sets MAP_COMMITS_BEHIND to the number of commits behind
check_map_staleness() {
  local map_file="${1:-brigade/codebase-map.md}"
  MAP_COMMITS_BEHIND=0

  # No map exists
  if [ ! -f "$map_file" ]; then
    return 2
  fi

  # Staleness check disabled
  if [ "$MAP_STALE_COMMITS" -eq 0 ] 2>/dev/null; then
    return 0
  fi

  # Extract commit hash from map file (40 hex chars)
  local map_commit=$(grep -oE '[a-f0-9]{40}' "$map_file" 2>/dev/null | head -1)

  # No commit hash found (old format map)
  if [ -z "$map_commit" ]; then
    MAP_COMMITS_BEHIND=-1  # Unknown, treat as stale
    return 1
  fi

  # Count commits since map was generated
  MAP_COMMITS_BEHIND=$(git rev-list --count "$map_commit"..HEAD 2>/dev/null || echo "-1")

  # Git command failed (commit no longer in history?)
  if [ "$MAP_COMMITS_BEHIND" -eq -1 ]; then
    return 1
  fi

  # Check if stale
  if [ "$MAP_COMMITS_BEHIND" -ge "$MAP_STALE_COMMITS" ]; then
    return 1
  fi

  return 0
}

cmd_map() {
  local output_file="${1:-brigade/codebase-map.md}"

  echo -e "${BOLD}Generating codebase map...${NC}"
  echo ""

  # Ensure output directory exists
  mkdir -p "$(dirname "$output_file")"

  local map_prompt="Analyze this codebase and generate a comprehensive codebase map in markdown format.

Include the following sections:

## Tech Stack
- Languages and versions
- Frameworks and libraries
- Build tools

## Architecture
- High-level architecture pattern (MVC, microservices, monolith, etc.)
- Key directories and their purposes
- Entry points

## Conventions
- Naming conventions (files, functions, variables)
- Code organization patterns
- Import/export patterns

## Testing
- Test framework(s) used
- Test file locations and naming
- How to run tests

## Configuration
- Config file locations
- Environment variables used
- Build/deploy configuration

## Technical Debt
- Areas that could use improvement
- Outdated patterns or dependencies
- Missing tests or documentation

Be specific and reference actual files/directories in the codebase.
Output the result as markdown that can be saved to a file."

  local temp_output=$(brigade_mktemp)

  echo -e "${GRAY}Running Executive Chef analysis...${NC}"
  echo ""

  if $EXECUTIVE_CMD --dangerously-skip-permissions -p "$map_prompt" 2>&1 | tee "$temp_output"; then
    # Extract just the markdown content (skip any preamble)
    # Look for content starting with # or ##
    local map_content=$(sed -n '/^#/,$p' "$temp_output")

    if [ -n "$map_content" ]; then
      # Embed commit hash for staleness tracking
      local commit_hash=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
      {
        echo "$map_content"
        echo ""
        echo "<!-- Generated at commit: $commit_hash -->"
      } > "$output_file"
      echo ""
      echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
      echo -e "${GREEN}║  Codebase map generated: $output_file${NC}"
      echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
      echo ""
      echo -e "${GRAY}This map will be auto-included in future planning sessions.${NC}"
    else
      echo -e "${YELLOW}Warning: Could not extract markdown from output${NC}"
      cat "$temp_output" > "$output_file"
    fi
  else
    echo -e "${RED}Error generating codebase map${NC}"
  fi

  rm -f "$temp_output"
}

cmd_opencode_models() {
  echo -e "${BOLD}Available OpenCode Models${NC}"
  echo -e "${GRAY}Use these values for OPENCODE_MODEL in brigade.config${NC}"
  echo ""

  if ! command -v opencode &> /dev/null; then
    echo -e "${RED}Error: opencode CLI not found${NC}"
    echo ""
    echo "Install OpenCode: https://opencode.ai"
    exit 1
  fi

  # Show current config
  if [ -n "$OPENCODE_MODEL" ]; then
    echo -e "${CYAN}Current config: OPENCODE_MODEL=\"$OPENCODE_MODEL\"${NC}"
    echo ""
  fi

  echo -e "${BOLD}GLM models (cost-effective):${NC}"
  opencode models 2>&1 | grep -E "(zai-coding-plan|opencode/glm)"
  echo ""
  echo -e "${BOLD}Claude models (via OpenCode):${NC}"
  opencode models 2>&1 | grep "anthropic/claude" | head -10
  echo ""
  echo -e "${GRAY}Run 'opencode models' for full list${NC}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
  # Check for quiet modes that suppress banner (status --json, status --brief, status --alert-only)
  local quiet_mode=false
  if [[ "$*" == *"status"*"--json"* ]] || [[ "$*" == *"status"*"-j"* ]] || \
     [[ "$*" == *"status"*"--brief"* ]] || [[ "$*" == *"status"*"-b"* ]] || \
     [[ "$*" == *"status"*"--alert-only"* ]] || [[ "$*" == *"status"*"-a"* ]]; then
    quiet_mode=true
  fi

  [ "$quiet_mode" != "true" ] && print_banner
  load_config "$quiet_mode"

  # Parse global options
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --max-iterations)
        MAX_ITERATIONS="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --auto-continue)
        AUTO_CONTINUE=true
        shift
        ;;
      --phase-gate)
        PHASE_GATE="$2"
        shift 2
        ;;
      --sequential)
        MAX_PARALLEL=1
        echo -e "${YELLOW}Sequential mode: parallel execution disabled${NC}"
        shift
        ;;
      --walkaway)
        WALKAWAY_MODE=true
        echo -e "${CYAN}Walkaway mode: AI will decide retry/skip on failures${NC}"
        shift
        ;;
      *)
        echo -e "${RED}Unknown option: $1${NC}"
        print_usage
        exit 1
        ;;
    esac
  done

  local command="${1:-}"
  shift || true

  case "$command" in
    "plan")
      cmd_plan "$@"
      ;;
    "service")
      cmd_service "$@"
      ;;
    "resume")
      cmd_resume "$@"
      ;;
    "ticket")
      cmd_ticket "$@"
      ;;
    "status")
      cmd_status "$@"
      ;;
    "analyze")
      cmd_analyze "$@"
      ;;
    "validate")
      cmd_validate "$@"
      ;;
    "summary")
      cmd_summary "$@"
      ;;
    "map")
      cmd_map "$@"
      ;;
    "opencode-models")
      cmd_opencode_models "$@"
      ;;
    "help"|"--help"|"-h"|"")
      print_usage
      ;;
    *)
      echo -e "${RED}Unknown command: $command${NC}"
      print_usage
      exit 1
      ;;
  esac
}

# Only run main if script is executed directly (not sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
