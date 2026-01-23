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
  # Also clean up PID registry file
  rm -f "$BRIGADE_PID_REGISTRY" 2>/dev/null
}

# Track worker process PIDs for cleanup on interrupt
# Using file-based registry to persist across subshells
BRIGADE_WORKER_PIDS=()
BRIGADE_PID_REGISTRY="/tmp/brigade-pids-$$.txt"

# Register a worker PID (persists across subshells)
register_worker_pid() {
  local pid="$1"
  BRIGADE_WORKER_PIDS+=("$pid")
  echo "$pid" >> "$BRIGADE_PID_REGISTRY"
}

# Unregister a worker PID
unregister_worker_pid() {
  local pid="$1"
  BRIGADE_WORKER_PIDS=("${BRIGADE_WORKER_PIDS[@]/$pid}")
  if [ -f "$BRIGADE_PID_REGISTRY" ]; then
    # Remove the PID from the file (portable sed)
    local tmp_file=$(mktemp)
    grep -v "^${pid}$" "$BRIGADE_PID_REGISTRY" > "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$BRIGADE_PID_REGISTRY"
  fi
}

# Get all registered PIDs (from file, handles subshell isolation)
get_registered_pids() {
  if [ -f "$BRIGADE_PID_REGISTRY" ]; then
    cat "$BRIGADE_PID_REGISTRY" 2>/dev/null | sort -u
  fi
}

cleanup_on_interrupt() {
  echo ""
  echo -e "${YELLOW}Interrupted - cleaning up...${NC}"

  # Kill any tracked worker processes (from file registry for subshell safety)
  local all_pids=$(get_registered_pids)
  for pid in $all_pids; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
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

  # Clean up PID registry file
  rm -f "$BRIGADE_PID_REGISTRY"

  cleanup_modules

  # Save partial worker output to log if interrupted mid-task
  if [ -n "$CURRENT_WORKER_LOG" ] && [ -n "$CURRENT_OUTPUT_FILE" ] && [ -f "$CURRENT_OUTPUT_FILE" ]; then
    {
      cat "$CURRENT_OUTPUT_FILE"
      echo ""
      echo "═══════════════════════════════════════════════════════════"
      echo "INTERRUPTED: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "═══════════════════════════════════════════════════════════"
    } >> "$CURRENT_WORKER_LOG"
    echo -e "${GRAY}Partial output saved to: $CURRENT_WORKER_LOG${NC}"
  fi

  cleanup_temp_files

  # Release service lock if held
  if [ -n "$BRIGADE_SERVICE_LOCK_FILE" ] && [ -f "$BRIGADE_SERVICE_LOCK_FILE" ]; then
    local lock_pid
    lock_pid=$(cat "$BRIGADE_SERVICE_LOCK_FILE" 2>/dev/null)
    if [ "$lock_pid" = "$$" ]; then
      rm -f "$BRIGADE_SERVICE_LOCK_FILE"
      echo -e "${GRAY}Released service lock${NC}"
    fi
  fi

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

# Service instance lock - prevents multiple services from running on the same PRD
# Uses a lockfile with PID to detect stale locks from crashed processes
# Usage: acquire_service_lock "$prd_path"  /  release_service_lock "$prd_path"
BRIGADE_SERVICE_LOCK_FILE=""

acquire_service_lock() {
  local prd_path="$1"
  local prd_dir=$(dirname "$prd_path")
  local prd_name=$(basename "$prd_path" .json)
  local lock_file="$prd_dir/.service-${prd_name}.lock"

  BRIGADE_SERVICE_LOCK_FILE="$lock_file"

  if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
    echo "[DEBUG] acquire_service_lock: attempting $lock_file (pid=$$)" >&2
  fi

  # Check if lock file exists
  if [ -f "$lock_file" ]; then
    local lock_pid
    lock_pid=$(cat "$lock_file" 2>/dev/null)

    # Check if the PID is still running
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      echo -e "${RED}Error: Another service is already running on this PRD${NC}" >&2
      echo -e "${GRAY}Lock held by PID $lock_pid${NC}" >&2
      echo -e "${GRAY}Lock file: $lock_file${NC}" >&2
      echo "" >&2
      echo -e "${GRAY}If this is a stale lock from a crashed process, remove it:${NC}" >&2
      echo -e "${GRAY}  rm $lock_file${NC}" >&2
      return 1
    else
      # Stale lock - remove it
      if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
        echo "[DEBUG] acquire_service_lock: removing stale lock (pid=$lock_pid no longer running)" >&2
      fi
      rm -f "$lock_file"
    fi
  fi

  # Create lock file with our PID
  echo "$$" > "$lock_file"

  if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
    echo "[DEBUG] acquire_service_lock: acquired $lock_file (pid=$$)" >&2
  fi

  return 0
}

release_service_lock() {
  local prd_path="$1"

  # Use saved lock file path if available, otherwise compute it
  local lock_file="$BRIGADE_SERVICE_LOCK_FILE"
  if [ -z "$lock_file" ]; then
    local prd_dir=$(dirname "$prd_path")
    local prd_name=$(basename "$prd_path" .json)
    lock_file="$prd_dir/.service-${prd_name}.lock"
  fi

  if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
    echo "[DEBUG] release_service_lock: releasing $lock_file (pid=$$)" >&2
  fi

  # Only remove if we own it (our PID is in the file)
  if [ -f "$lock_file" ]; then
    local lock_pid
    lock_pid=$(cat "$lock_file" 2>/dev/null)
    if [ "$lock_pid" = "$$" ]; then
      rm -f "$lock_file"
    fi
  fi

  BRIGADE_SERVICE_LOCK_FILE=""
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
  register_worker_pid "$pid"

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
      unregister_worker_pid "$pid"

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
      unregister_worker_pid "$pid"
      return 124  # Standard timeout exit code
    fi

    # Sleep for health check interval
    sleep "$check_interval"
    elapsed=$((elapsed + check_interval))

    # Check timeout warning (only once per task)
    # Uses globals set by fire_ticket: CURRENT_WORKER, CURRENT_TASK_ID, CURRENT_PRD_PATH
    if [ -n "$CURRENT_TASK_ID" ] && [ -n "$CURRENT_WORKER" ]; then
      check_task_timeout_warning "$CURRENT_WORKER" "$elapsed" "$CURRENT_TASK_ID" "$CURRENT_PRD_PATH"
    fi

    # Activity heartbeat (every ACTIVITY_LOG_INTERVAL seconds)
    if [ -n "$ACTIVITY_LOG" ] && [ -n "$CURRENT_TASK_ID" ]; then
      local since_heartbeat=$((elapsed % ACTIVITY_LOG_INTERVAL))
      if [ "$since_heartbeat" -lt "$check_interval" ] && [ "$elapsed" -ge "$ACTIVITY_LOG_INTERVAL" ]; then
        write_activity_heartbeat "$CURRENT_PRD_PATH" "$CURRENT_TASK_ID" "$CURRENT_WORKER" "$elapsed"
      fi
    fi

    # Supervisor status heartbeat (every 30 seconds)
    if [ -n "$SUPERVISOR_STATUS_FILE" ] && [ -n "$CURRENT_PRD_PATH" ]; then
      local status_interval=30
      local since_status=$((elapsed % status_interval))
      if [ "$since_status" -lt "$check_interval" ] && [ "$elapsed" -ge "$status_interval" ]; then
        write_supervisor_status "$CURRENT_PRD_PATH"
      fi
    fi

    # Output stall detection (no new output for N seconds)
    # Uses CURRENT_WORKER_LOG set by fire_ticket; warns once per task
    local stall_threshold="${OUTPUT_STALL_THRESHOLD:-300}"
    if [ "$stall_threshold" -gt 0 ] && [ -n "$CURRENT_WORKER_LOG" ] && [ -f "$CURRENT_WORKER_LOG" ]; then
      if [ "${CURRENT_STALL_WARNING_SHOWN:-false}" != "true" ]; then
        # Get log file mtime (cross-platform: macOS uses -f %m, Linux uses -c %Y)
        local log_mtime
        if [[ "$OSTYPE" == darwin* ]]; then
          log_mtime=$(stat -f %m "$CURRENT_WORKER_LOG" 2>/dev/null || echo 0)
        else
          log_mtime=$(stat -c %Y "$CURRENT_WORKER_LOG" 2>/dev/null || echo 0)
        fi
        local now=$(date +%s)
        local stall_time=$((now - log_mtime))
        if [ "$stall_time" -gt "$stall_threshold" ]; then
          local stall_mins=$((stall_time / 60))
          log_event "WARN" "⚠️ ${CURRENT_TASK_ID:-task} output stalled (no output for ${stall_mins}m)"
          emit_supervisor_event "output_stall" "${CURRENT_TASK_ID:-unknown}" "$stall_time"
          CURRENT_STALL_WARNING_SHOWN=true
        fi
      fi
    fi

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
AUTO_CONTINUE_WARN_STALE=true  # Warn when PRD has existing state file

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
MANUAL_VERIFICATION_ENABLED=false  # Prompt for human verification on tasks with manualVerification: true
OUTPUT_RED_FLAG_ENABLED=true       # Scan worker output for red flags ("not implemented", "placeholder", etc.)

# Visibility defaults
ACTIVITY_LOG=""                    # Path to activity heartbeat log (empty = disabled)
ACTIVITY_LOG_INTERVAL=30           # Seconds between heartbeat writes
TASK_TIMEOUT_WARNING_JUNIOR=10     # Minutes before warning for junior tasks (0 = disabled)
TASK_TIMEOUT_WARNING_SENIOR=20     # Minutes before warning for senior tasks
WORKER_LOG_DIR=""                  # Directory for per-task worker logs (empty = disabled)
STATUS_WATCH_INTERVAL=30           # Seconds between status refreshes in watch mode
OUTPUT_STALL_THRESHOLD=300         # Seconds without output before warning (5 minutes, 0 = disabled)
SUPERVISOR_STATUS_FILE=""          # Write compact status JSON on state changes (empty = disabled)
SUPERVISOR_EVENTS_FILE=""          # Append-only JSONL event stream (empty = disabled)
SUPERVISOR_CMD_FILE=""             # Command ingestion file (empty = disabled)
SUPERVISOR_PRD_SCOPED=true         # Auto-scope supervisor files by PRD (safe for parallel execution)
SUPERVISOR_CMD_POLL_INTERVAL=2     # Seconds between polls when waiting for command
SUPERVISOR_CMD_TIMEOUT=300         # Max seconds to wait for supervisor command (0 = wait forever)

# Codebase map defaults
MAP_STALE_COMMITS=20               # Regenerate map if this many commits behind HEAD (0 = disable)

# Cost estimation defaults (duration-based)
COST_RATE_LINE=0.05                # $/minute for Line Cook
COST_RATE_SOUS=0.15                # $/minute for Sous Chef
COST_RATE_EXECUTIVE=0.30           # $/minute for Executive Chef
COST_WARN_THRESHOLD=""             # Warn if PRD exceeds this cost (empty = disabled)

# Risk assessment defaults (P9)
RISK_REPORT_ENABLED=true           # Show risk summary before service execution
RISK_HISTORY_SCAN=false            # Include historical escalation patterns
RISK_WARN_THRESHOLD=""             # Warn at this risk level: low, medium, high (empty = disabled)

# Runtime state (set during execution)
LAST_REVIEW_FEEDBACK=""       # Feedback from failed executive review, passed to worker on retry
LAST_VERIFICATION_FEEDBACK="" # Feedback from failed verification commands, passed to worker on retry
LAST_TODO_WARNINGS=""         # Warnings from TODO scan, passed to worker on retry
LAST_MANUAL_VERIFICATION_FEEDBACK=""  # Feedback from rejected manual verification
LAST_OUTPUT_WARNINGS=""       # Red flag phrases found in worker output, passed to review
CURRENT_TASK_START_TIME=0          # Epoch timestamp when current task started
CURRENT_TASK_WARNING_SHOWN=false   # Whether timeout warning was shown for current task
CURRENT_STALL_WARNING_SHOWN=false  # Whether output stall warning was shown for current task
CURRENT_PRD_PATH=""                # Current PRD being processed (for visibility features)
CURRENT_TASK_ID=""                 # Current task being worked (for visibility features)
CURRENT_WORKER=""                  # Current worker (for visibility features)
LAST_HEARTBEAT_TIME=0              # Last time heartbeat was written

# Module system defaults
MODULES=""                         # Comma-separated list of modules to enable
MODULE_TIMEOUT=5                   # Seconds before killing hung module handler
BRIGADE_LOADED_MODULES=""          # Runtime: space-separated list of loaded modules

# Partial execution filters (set via command line flags)
FILTER_ONLY=""                     # Comma-separated task IDs to run exclusively
FILTER_SKIP=""                     # Comma-separated task IDs to skip
FILTER_FROM=""                     # Start from this task ID (inclusive)
FILTER_UNTIL=""                    # Run up to this task ID (inclusive)

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

    # Emit task_slow event for proactive notification modules
    emit_supervisor_event "task_slow" "$task_id" "$worker" "$elapsed_mins" "$warning_threshold"

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

  # Strip trailing slashes from WORKER_LOG_DIR to avoid double-slash paths
  local log_dir="${WORKER_LOG_DIR%/}"

  # Ensure directory exists
  mkdir -p "$log_dir"

  echo "${log_dir}/${prd_prefix}-${task_id}-${worker}-${timestamp}.log"
}

# ═══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

print_banner() {
  echo ""
  echo -e "🍳 ${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo -e "   ${BOLD}Brigade Kitchen${NC} - AI Chefs at Your Service"
  echo -e "   ${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo ""
}

print_usage() {
  echo -e "🍳 ${BOLD}Brigade Kitchen${NC} - Quick Reference"
  echo ""
  echo "Commands:"
  echo "  plan <description>     Plan a new feature (Executive Chef)"
  echo "  service [prd.json]     Cook all dishes in a PRD"
  echo "  status                 Check kitchen status"
  echo "  resume                 Continue after interruption"
  echo ""
  echo "Getting Started:"
  echo "  init                   Guided setup wizard"
  echo "  demo                   Try a demo (dry-run)"
  echo ""
  echo "Monitoring:"
  echo "  supervise              Supervisor mode quick reference"
  echo ""
  echo "Run './brigade.sh help --all' for the full menu."
}

print_usage_full() {
  echo "Usage: ./brigade.sh [options] <command> [args]"
  echo ""
  echo "Commands:"
  echo "  plan <description>         Generate PRD from feature description (Executive Chef)"
  echo "  service [prd.json]         Run full service (defaults to brigade/tasks/latest.json)"
  echo "  resume [prd.json] [action] Resume after interruption (action: retry|skip)"
  echo "  ticket <prd.json> <id>     Run single ticket"
  echo "  status [options] [prd.json] Show kitchen status (auto-detects active PRD)"
  echo "                              Options: --all (show all escalations), --watch/-w (auto-refresh)"
  echo "  summary [prd.json] [file]  Generate markdown summary report from state"
  echo "  cost [prd.json]            Show estimated cost breakdown (duration-based)"
  echo "  risk [options] [prd.json]  Assess PRD risk and complexity"
  echo "                              Options: --history (include historical escalation patterns)"
  echo "  map [output.md]            Generate codebase map (default: brigade/codebase-map.md)"
  echo "  explore <question>         Research feasibility without generating PRD"
  echo "  iterate <description>     Quick tweak on completed PRD (creates micro-PRD)"
  echo "  template [name] [resource] Generate PRD from template (no args = list templates)"
  echo "  analyze <prd.json>         Analyze tasks and suggest routing"
  echo "  validate <prd.json>        Validate PRD structure and dependencies"
  echo "  opencode-models            List available OpenCode models"
  echo ""
  echo "Getting Started:"
  echo "  init                       Guided setup wizard"
  echo "  demo                       Try a demo (dry-run mode)"
  echo ""
  echo "Monitoring:"
  echo "  supervise                  Supervisor mode quick reference"
  echo ""
  echo "Options:"
  echo "  --max-iterations <n>       Max iterations per task (default: 50)"
  echo "  --dry-run                  Show what would be done without executing"
  echo "  --auto-continue            Chain multiple PRDs for unattended execution"
  echo "  --phase-gate <mode>        Between-PRD behavior: review|continue|pause (default: continue)"
  echo "  --sequential               Disable parallel execution (debug parallel issues)"
  echo "  --walkaway                 AI decides retry/skip on failures (unattended mode)"
  echo ""
  echo "Partial Execution (filter which tasks run):"
  echo "  --only <ids>               Run only specified tasks (comma-separated)"
  echo "  --skip <ids>               Skip specified tasks (comma-separated)"
  echo "  --from <id>                Start from task (inclusive)"
  echo "  --until <id>               Run up to task (inclusive)"
  echo ""
  echo "Examples:"
  echo "  ./brigade.sh plan \"Add user authentication with JWT\""
  echo "  ./brigade.sh service                                 # Uses brigade/tasks/latest.json"
  echo "  ./brigade.sh service brigade/tasks/prd.json          # Specific PRD"
  echo "  ./brigade.sh --auto-continue service brigade/tasks/prd-*.json  # Chain numbered PRDs"
  echo "  ./brigade.sh status                                  # Auto-detect active PRD"
  echo "  ./brigade.sh --only US-001,US-003 service prd.json   # Run specific tasks"
  echo "  ./brigade.sh --skip US-007 service prd.json          # Skip a task"
  echo "  ./brigade.sh --from US-003 service prd.json          # Start from task"
  echo "  ./brigade.sh --dry-run --only US-001 service prd.json # Preview filtered plan"
}

# First-run welcome message for new users
print_welcome() {
  echo ""
  echo -e "🍳 ${BOLD}Welcome to Brigade Kitchen!${NC}"
  echo ""
  echo "Looks like this is your first time here. Let's get cooking!"
  echo ""
  echo "  Quick start:"
  echo -e "    ${CYAN}./brigade.sh plan \"Add user authentication\"${NC}"
  echo ""
  echo "  Or try a demo:"
  echo -e "    ${CYAN}./brigade.sh demo${NC}"
  echo ""
  echo "  Need setup help?"
  echo -e "    ${CYAN}./brigade.sh init${NC}"
  echo ""
}

# Kitchen-themed error messages
# Usage: kitchen_error <type> <details>
kitchen_error() {
  local type="$1"
  local details="$2"

  case "$type" in
    "blocked")
      echo ""
      echo -e "🔥 ${RED}Kitchen fire!${NC} $details"
      echo ""
      echo "   Options:"
      echo -e "     ${CYAN}./brigade.sh resume${NC}        - Let the next chef try"
      echo -e "     ${CYAN}./brigade.sh resume skip${NC}   - Skip this dish"
      echo ""
      ;;
    "no_prd")
      echo ""
      echo -e "🍽️ ${YELLOW}Empty plate!${NC} No PRD found."
      echo ""
      echo -e "   Start with: ${CYAN}./brigade.sh plan \"your feature\"${NC}"
      echo ""
      ;;
    "verification_failed")
      echo ""
      echo -e "🔥 ${RED}Kitchen fire!${NC} $details didn't pass the taste test."
      echo ""
      echo -e "   Run '${CYAN}./brigade.sh resume${NC}' to try again."
      echo ""
      ;;
    "timeout")
      echo ""
      echo -e "⏰ ${YELLOW}Order taking too long!${NC} $details"
      echo ""
      echo -e "   The kitchen will try a more experienced chef."
      echo ""
      ;;
    *)
      echo -e "${RED}Error:${NC} $details"
      ;;
  esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# COST ESTIMATION
# ═══════════════════════════════════════════════════════════════════════════════

# Calculate estimated cost for a task based on duration and worker tier
# Usage: calculate_task_cost <duration_seconds> <worker>
# Returns: cost in dollars (4 decimal places)
calculate_task_cost() {
  local duration="$1"  # seconds
  local worker="$2"    # line|sous|executive

  local rate
  case "$worker" in
    line) rate="${COST_RATE_LINE:-0.05}" ;;
    sous) rate="${COST_RATE_SOUS:-0.15}" ;;
    executive) rate="${COST_RATE_EXECUTIVE:-0.30}" ;;
    *) rate="0.10" ;;  # fallback for unknown workers
  esac

  # cost = duration_seconds / 60 * rate_per_minute
  echo "scale=4; $duration / 60 * $rate" | bc
}

# Format duration seconds to human-readable string
# Usage: format_duration_hms <seconds>
# Returns: "Xh Ym Zs" or "Ym Zs" or "Zs"
format_duration_hms() {
  local seconds="$1"
  local hours=$((seconds / 3600))
  local mins=$(((seconds % 3600) / 60))
  local secs=$((seconds % 60))

  if [ "$hours" -gt 0 ]; then
    echo "${hours}h ${mins}m ${secs}s"
  elif [ "$mins" -gt 0 ]; then
    echo "${mins}m ${secs}s"
  else
    echo "${secs}s"
  fi
}

# Format cost as currency
# Usage: format_cost <amount>
# Returns: "$X.XX"
format_cost() {
  local amount="$1"
  # Format to 2 decimal places
  printf "\$%.2f" "$amount"
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
  register_worker_pid "$pid"

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
  unregister_worker_pid "$pid"

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

  # Load enabled modules
  load_modules "$quiet"
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
# MODULE SYSTEM
# ═══════════════════════════════════════════════════════════════════════════════

# Load enabled modules from modules/ directory
load_modules() {
  BRIGADE_LOADED_MODULES=""

  [ -z "$MODULES" ] && return 0

  local module_dir="$SCRIPT_DIR/modules"
  [ ! -d "$module_dir" ] && return 0

  local quiet="${1:-false}"

  IFS=',' read -ra module_list <<< "$MODULES"
  for module in "${module_list[@]}"; do
    module=$(echo "$module" | xargs)  # Trim whitespace
    [ -z "$module" ] && continue

    local module_file="$module_dir/${module}.sh"

    if [ ! -f "$module_file" ]; then
      [ "$quiet" != "true" ] && echo -e "${YELLOW}Warning: Module not found: $module${NC}" >&2
      continue
    fi

    # Source module
    if ! source "$module_file" 2>/dev/null; then
      [ "$quiet" != "true" ] && echo -e "${YELLOW}Warning: Module $module failed to source${NC}" >&2
      continue
    fi

    # Check for required events function
    local events_fn="module_${module}_events"
    if ! declare -f "$events_fn" > /dev/null 2>&1; then
      [ "$quiet" != "true" ] && echo -e "${YELLOW}Warning: Module $module missing ${events_fn}()${NC}" >&2
      continue
    fi

    # Call init if present
    local init_fn="module_${module}_init"
    if declare -f "$init_fn" > /dev/null 2>&1; then
      if ! "$init_fn" 2>/dev/null; then
        [ "$quiet" != "true" ] && echo -e "${YELLOW}Warning: Module $module init failed${NC}" >&2
        continue
      fi
    fi

    # Register module and cache its events
    BRIGADE_LOADED_MODULES="$BRIGADE_LOADED_MODULES $module"
    local events=$("$events_fn")
    local module_upper=$(echo "$module" | tr '[:lower:]' '[:upper:]')
    eval "BRIGADE_MODULE_${module_upper}_EVENTS=\"$events\""

    [ "${BRIGADE_DEBUG:-false}" == "true" ] && \
      echo "[DEBUG] Loaded module: $module (events: $events)" >&2
  done

  BRIGADE_LOADED_MODULES=$(echo "$BRIGADE_LOADED_MODULES" | xargs)

  if [ -n "$BRIGADE_LOADED_MODULES" ] && [ "$quiet" != "true" ]; then
    echo -e "${GRAY}Modules loaded: $BRIGADE_LOADED_MODULES${NC}"
  fi
}

# Check if module is registered for an event
module_registered_for_event() {
  local module="$1"
  local event="$2"
  local module_upper=$(echo "$module" | tr '[:lower:]' '[:upper:]')
  local events_var="BRIGADE_MODULE_${module_upper}_EVENTS"
  local events="${!events_var}"
  [[ " $events " == *" $event "* ]]
}

# Dispatch event to all registered modules
dispatch_to_modules() {
  local event_type="$1"
  shift

  # Skip if no modules loaded
  [ -z "$BRIGADE_LOADED_MODULES" ] && return 0

  for module in $BRIGADE_LOADED_MODULES; do
    # Check if module registered for this event
    if module_registered_for_event "$module" "$event_type"; then
      local handler="module_${module}_on_${event_type}"
      if declare -f "$handler" > /dev/null 2>&1; then
        # Run handler in subshell (non-blocking, isolated)
        # The subshell inherits functions so we can call the handler directly
        (
          "$handler" "$@"
        ) 2>/dev/null &

        [ "${BRIGADE_DEBUG:-false}" == "true" ] && \
          echo "[DEBUG] Dispatched $event_type to $module" >&2
      fi
    fi
  done

  # Don't wait - modules run async
  return 0
}

# Cleanup modules on exit
cleanup_modules() {
  for module in $BRIGADE_LOADED_MODULES; do
    local cleanup_fn="module_${module}_cleanup"
    if declare -f "$cleanup_fn" > /dev/null 2>&1; then
      "$cleanup_fn" 2>/dev/null || true
    fi
  done
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

# Apply PRD-scoping to supervisor files (enables safe parallel execution)
# Transforms: brigade/tasks/events.jsonl → brigade/tasks/auth-events.jsonl
init_supervisor_files_for_prd() {
  local prd_path="$1"

  [ "$SUPERVISOR_PRD_SCOPED" != "true" ] && return 0

  local prefix=$(get_prd_prefix "$prd_path")

  # Scope status file: dir/status.json → dir/prefix-status.json
  if [ -n "$SUPERVISOR_STATUS_FILE" ]; then
    local dir=$(dirname "$SUPERVISOR_STATUS_FILE")
    local base=$(basename "$SUPERVISOR_STATUS_FILE")
    SUPERVISOR_STATUS_FILE="${dir}/${prefix}-${base}"
  fi

  # Scope events file: dir/events.jsonl → dir/prefix-events.jsonl
  if [ -n "$SUPERVISOR_EVENTS_FILE" ]; then
    local dir=$(dirname "$SUPERVISOR_EVENTS_FILE")
    local base=$(basename "$SUPERVISOR_EVENTS_FILE")
    SUPERVISOR_EVENTS_FILE="${dir}/${prefix}-${base}"
  fi

  # Scope cmd file: dir/cmd.json → dir/prefix-cmd.json
  if [ -n "$SUPERVISOR_CMD_FILE" ]; then
    local dir=$(dirname "$SUPERVISOR_CMD_FILE")
    local base=$(basename "$SUPERVISOR_CMD_FILE")
    SUPERVISOR_CMD_FILE="${dir}/${prefix}-${base}"
  fi
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
  local all_pending=$(jq -r '.tasks[] | select(.passes == false) | .id' "$prd_path")

  # Apply partial execution filters if any are active
  if has_active_filters; then
    for task_id in $all_pending; do
      if should_run_task "$prd_path" "$task_id"; then
        echo "$task_id"
      fi
    done
  else
    echo "$all_pending"
  fi
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

# ═══════════════════════════════════════════════════════════════════════════════
# PARTIAL EXECUTION FILTERS
# ═══════════════════════════════════════════════════════════════════════════════

# Get the index (1-based) of a task in the PRD task list
# Returns empty if task not found
get_task_order() {
  local prd_path="$1"
  local task_id="$2"
  local index=1

  for id in $(jq -r '.tasks[].id' "$prd_path"); do
    if [ "$id" == "$task_id" ]; then
      echo "$index"
      return 0
    fi
    index=$((index + 1))
  done

  echo ""
  return 1
}

# Check if a task passes all partial execution filters
# Returns 0 if task should run, 1 if task should be skipped
should_run_task() {
  local prd_path="$1"
  local task_id="$2"

  # No filters = run all tasks
  if [ -z "$FILTER_ONLY" ] && [ -z "$FILTER_SKIP" ] && [ -z "$FILTER_FROM" ] && [ -z "$FILTER_UNTIL" ]; then
    return 0
  fi

  # --only filter: task must be in the list
  if [ -n "$FILTER_ONLY" ]; then
    if ! echo ",$FILTER_ONLY," | grep -q ",$task_id,"; then
      return 1
    fi
  fi

  # --skip filter: task must NOT be in the list
  if [ -n "$FILTER_SKIP" ]; then
    if echo ",$FILTER_SKIP," | grep -q ",$task_id,"; then
      return 1
    fi
  fi

  # --from filter: task must be at or after the specified task
  if [ -n "$FILTER_FROM" ]; then
    local from_order=$(get_task_order "$prd_path" "$FILTER_FROM")
    local task_order=$(get_task_order "$prd_path" "$task_id")
    if [ -n "$from_order" ] && [ -n "$task_order" ]; then
      if [ "$task_order" -lt "$from_order" ]; then
        return 1
      fi
    fi
  fi

  # --until filter: task must be at or before the specified task
  if [ -n "$FILTER_UNTIL" ]; then
    local until_order=$(get_task_order "$prd_path" "$FILTER_UNTIL")
    local task_order=$(get_task_order "$prd_path" "$task_id")
    if [ -n "$until_order" ] && [ -n "$task_order" ]; then
      if [ "$task_order" -gt "$until_order" ]; then
        return 1
      fi
    fi
  fi

  return 0
}

# Validate that all task IDs in filters exist in the PRD
# Returns 0 if valid, 1 if invalid (prints error)
validate_task_filters() {
  local prd_path="$1"
  local all_ids=$(jq -r '.tasks[].id' "$prd_path" | tr '\n' ',' | sed 's/,$//')
  local valid=0

  # Check --only tasks
  if [ -n "$FILTER_ONLY" ]; then
    for task_id in $(echo "$FILTER_ONLY" | tr ',' ' '); do
      if ! echo ",$all_ids," | grep -q ",$task_id,"; then
        echo -e "${RED}Error: Task ID '$task_id' in --only does not exist in PRD${NC}"
        valid=1
      fi
    done
  fi

  # Check --skip tasks
  if [ -n "$FILTER_SKIP" ]; then
    for task_id in $(echo "$FILTER_SKIP" | tr ',' ' '); do
      if ! echo ",$all_ids," | grep -q ",$task_id,"; then
        echo -e "${RED}Error: Task ID '$task_id' in --skip does not exist in PRD${NC}"
        valid=1
      fi
    done
  fi

  # Check --from task
  if [ -n "$FILTER_FROM" ]; then
    if ! echo ",$all_ids," | grep -q ",$FILTER_FROM,"; then
      echo -e "${RED}Error: Task ID '$FILTER_FROM' in --from does not exist in PRD${NC}"
      valid=1
    fi
  fi

  # Check --until task
  if [ -n "$FILTER_UNTIL" ]; then
    if ! echo ",$all_ids," | grep -q ",$FILTER_UNTIL,"; then
      echo -e "${RED}Error: Task ID '$FILTER_UNTIL' in --until does not exist in PRD${NC}"
      valid=1
    fi
  fi

  return $valid
}

# Validate that filtered task set has all dependencies met
# Returns 0 if valid, 1 if invalid (prints error with hints)
validate_filter_dependencies() {
  local prd_path="$1"
  local valid=0

  # Get all task IDs in the filtered set
  for task_id in $(jq -r '.tasks[].id' "$prd_path"); do
    # Skip tasks that won't run
    if ! should_run_task "$prd_path" "$task_id"; then
      continue
    fi

    # Skip tasks already completed
    local passes=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .passes' "$prd_path")
    if [ "$passes" == "true" ]; then
      continue
    fi

    # Check each dependency
    for dep in $(get_task_dependencies "$prd_path" "$task_id"); do
      local dep_passes=$(jq -r --arg id "$dep" '.tasks[] | select(.id == $id) | .passes' "$prd_path")

      # If dependency is not complete and not in the filtered run set, error
      if [ "$dep_passes" != "true" ]; then
        if ! should_run_task "$prd_path" "$dep"; then
          echo -e "${RED}Error: Task $task_id depends on $dep which is not complete and not in run set${NC}"
          echo -e "${GRAY}Hint: Add $dep to --only, or use --skip to skip $task_id instead${NC}"
          valid=1
        fi
      fi
    done
  done

  return $valid
}

# Check if any partial execution filters are active
has_active_filters() {
  [ -n "$FILTER_ONLY" ] || [ -n "$FILTER_SKIP" ] || [ -n "$FILTER_FROM" ] || [ -n "$FILTER_UNTIL" ]
}

# Get display string for active filters
get_filter_display() {
  local parts=""
  [ -n "$FILTER_ONLY" ] && parts="${parts}only:$FILTER_ONLY "
  [ -n "$FILTER_SKIP" ] && parts="${parts}skip:$FILTER_SKIP "
  [ -n "$FILTER_FROM" ] && parts="${parts}from:$FILTER_FROM "
  [ -n "$FILTER_UNTIL" ] && parts="${parts}until:$FILTER_UNTIL "
  echo "$parts" | xargs
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
  # IMPORTANT: Only clear if currentTask matches this task_id to avoid
  # corrupting state during parallel execution (multiple tasks running)
  local state_path=$(get_state_path "$prd_path")
  if [ -f "$state_path" ]; then
    acquire_lock "$state_path"
    ensure_valid_state "$state_path" "$prd_path"

    # Check if currentTask matches this task before clearing
    local current_task=$(jq -r '.currentTask // ""' "$state_path" 2>/dev/null)
    if [ "$current_task" = "$task_id" ]; then
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
    elif [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
      echo "[DEBUG] mark_task_complete: skipping currentTask clear for $task_id (current=$current_task)" >&2
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

  # First priority: Honor latest.json symlink if it exists and is valid
  for dir in "${search_dirs[@]}"; do
    local latest="$dir/latest.json"
    if [ -L "$latest" ]; then
      # Resolve symlink and validate the target
      local target
      if target=$(readlink "$latest" 2>/dev/null); then
        # Handle both absolute and relative symlinks
        if [[ "$target" != /* ]]; then
          target="$dir/$target"
        fi
        if [ -f "$target" ] && jq -e '.tasks' "$target" >/dev/null 2>&1; then
          echo "$target"
          return 0
        fi
      fi
    fi
  done

  # Second priority: look for per-PRD state files (*.state.json) with an active currentTask
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
  local duration="${5:-}"  # Optional duration in seconds (for complete status)

  if [ "$CONTEXT_ISOLATION" != "true" ]; then
    return 0
  fi

  local state_path=$(get_state_path "$prd_path")

  acquire_lock "$state_path"
  ensure_valid_state "$state_path" "$prd_path"
  local tmp_file=$(brigade_mktemp)

  # Use set +e locally to prevent jq failures from killing the subshell
  set +e

  # Include duration in taskHistory entry if provided (for completed tasks)
  if [ -n "$duration" ]; then
    jq --arg task "$task_id" --arg worker "$worker" --arg status "$status" --arg ts "$(date -Iseconds)" --argjson dur "$duration" \
      '.currentTask = $task | .taskHistory += [{"taskId": $task, "worker": $worker, "status": $status, "timestamp": $ts, "duration": $dur}]' \
      "$state_path" > "$tmp_file"
  else
    jq --arg task "$task_id" --arg worker "$worker" --arg status "$status" --arg ts "$(date -Iseconds)" \
      '.currentTask = $task | .taskHistory += [{"taskId": $task, "worker": $worker, "status": $status, "timestamp": $ts}]' \
      "$state_path" > "$tmp_file"
  fi
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
  local last_update=$(date -Iseconds)
  if [ "$attention" = "true" ]; then
    printf '{"done":%d,"total":%d,"current":%s,"worker":%s,"elapsed":%d,"attention":true,"reason":"%s","lastUpdate":"%s"}\n' \
      "$done" "$total" \
      "$([ -n "$current" ] && echo "\"$current\"" || echo "null")" \
      "$([ -n "$worker" ] && echo "\"$worker\"" || echo "null")" \
      "$elapsed" "$reason" "$last_update" > "$tmp_file"
  else
    printf '{"done":%d,"total":%d,"current":%s,"worker":%s,"elapsed":%d,"attention":false,"lastUpdate":"%s"}\n' \
      "$done" "$total" \
      "$([ -n "$current" ] && echo "\"$current\"" || echo "null")" \
      "$([ -n "$worker" ] && echo "\"$worker\"" || echo "null")" \
      "$elapsed" "$last_update" > "$tmp_file"
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
    task_slow)
      # Task taking longer than expected warning
      local task="$1" elapsed="$2" expected="$3"
      printf '{"ts":"%s","event":"task_slow","task":"%s","elapsed":%d,"expected":%d}\n' "$ts" "$task" "$elapsed" "$expected"
      ;;
    *)
      printf '{"ts":"%s","event":"%s"}\n' "$ts" "$event_type"
      ;;
  esac >> "$SUPERVISOR_EVENTS_FILE"

  # Dispatch to modules (runs async in background)
  dispatch_to_modules "$event_type" "$@"
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

  # Include manual verification feedback if previous attempt was rejected
  local manual_verification_feedback_section=""
  if [ -n "$LAST_MANUAL_VERIFICATION_FEEDBACK" ]; then
    manual_verification_feedback_section="
---
⚠️ PREVIOUS ATTEMPT FAILED MANUAL VERIFICATION:
$LAST_MANUAL_VERIFICATION_FEEDBACK
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

  # Include iteration context if this is an iteration task
  local iteration_context_section=""
  if [ -n "$ITERATION_PARENT_PRD" ] && [ -f "$ITERATION_PARENT_PRD" ]; then
    local parent_feature=$(jq -r '.featureName // "Unknown"' "$ITERATION_PARENT_PRD")
    local parent_tasks=$(jq -r '.tasks[] | "- \(.id): \(.title)"' "$ITERATION_PARENT_PRD" 2>/dev/null | head -20)
    iteration_context_section="
---
ITERATION CONTEXT (this is a quick tweak on completed work):
Parent PRD: $parent_feature ($ITERATION_PARENT_PRD)
Parent tasks completed:
$parent_tasks

This is a small iteration/tweak on the completed feature. Focus only on the specific change requested.
---
"
  fi

  # Include cross-PRD context if enabled (P15)
  local cross_prd_section=""
  if [ "${CROSS_PRD_CONTEXT_ENABLED:-true}" == "true" ]; then
    local cross_prd_context=$(get_cross_prd_context "$prd_path" "$task_id")
    if [ -n "$cross_prd_context" ]; then
      cross_prd_section="
---
$cross_prd_context
Note: Check related PRDs for patterns to follow or conflicts to avoid.
---
"
    fi
  fi

  cat <<EOF
$chef_prompt
$learnings_section$review_feedback_section$verification_feedback_section$todo_feedback_section$manual_verification_feedback_section$verification_section$iteration_context_section$cross_prd_section
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

  # Set global context for visibility features (heartbeat, timeout warnings, crash logging)
  CURRENT_PRD_PATH="$prd_path"
  CURRENT_TASK_ID="$task_id"
  CURRENT_WORKER="$worker"
  CURRENT_TASK_WARNING_SHOWN=false
  CURRENT_STALL_WARNING_SHOWN=false
  CURRENT_TASK_START_TIME=$(date +%s)
  CURRENT_WORKER_LOG=""
  CURRENT_OUTPUT_FILE=""

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
  log_event "START" "🔪 Prepping $display_id - $task_title"
  echo -e "${GRAY}Chef: $worker_name${NC}"
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

  # Set globals for interrupt handler (allows saving partial output on Ctrl+C)
  CURRENT_OUTPUT_FILE="$output_file"
  CURRENT_WORKER_LOG="$worker_log"

  # Execute worker based on agent type
  local start_time=$(date +%s)

  # Create worker log BEFORE execution starts (captures crash data)
  if [ -n "$worker_log" ]; then
    {
      echo "═══════════════════════════════════════════════════════════"
      echo "Task: $display_id - $task_title"
      echo "Worker: $worker_name ($worker_agent)"
      echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "═══════════════════════════════════════════════════════════"
      echo ""
    } > "$worker_log"
  fi

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

  # Append output to worker log file if enabled (header already written before execution)
  if [ -n "$worker_log" ] && [ -f "$output_file" ]; then
    {
      cat "$output_file"
      echo ""
      echo "═══════════════════════════════════════════════════════════"
      echo "Completed: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Duration: ${duration}s"
      echo "═══════════════════════════════════════════════════════════"
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
  CURRENT_OUTPUT_FILE=""
  CURRENT_WORKER_LOG=""

  # Extract any learnings shared by the worker
  extract_learnings_from_output "$output_file" "$prd_path" "$task_id" "$worker"

  # Extract any backlog items (out-of-scope discoveries)
  extract_backlog_from_output "$output_file" "$prd_path" "$task_id" "$worker"

  # Handle any scope questions (in walkaway mode, exec chef decides)
  extract_scope_questions_from_output "$output_file" "$prd_path" "$task_id" "$worker"

  # Scan for red flags in worker output (incomplete work indicators)
  # Sets LAST_OUTPUT_WARNINGS if found - passed to executive review for consideration
  LAST_OUTPUT_WARNINGS=""
  if [ "${OUTPUT_RED_FLAG_ENABLED:-true}" == "true" ] && [ -f "$output_file" ]; then
    # Pattern matches common phrases indicating incomplete work
    # Use grep -ai for case-insensitive, binary-safe matching
    local red_flag_pattern='not implement\|placeholder\|incomplete\|skipping\|left as\|stub\|dummy\|mock data\|hardcoded\|todo.*implement'
    local red_flags=$(grep -ai "$red_flag_pattern" "$output_file" 2>/dev/null | head -5)
    if [ -n "$red_flags" ]; then
      LAST_OUTPUT_WARNINGS="$red_flags"
      log_event "WARN" "⚠️ $display_id output contains potential red flags:"
      echo "$red_flags" | while read -r line; do
        echo -e "  ${YELLOW}→ $line${NC}" | head -c 200  # Truncate long lines
        echo ""
      done
      emit_supervisor_event "output_red_flag" "$task_id" "$worker"
    fi
  fi

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
  # Use grep -a for binary-safe scanning (worker output may contain binary data)
  if grep -aq "<promise>COMPLETE</promise>" "$output_file" 2>/dev/null; then
    log_event "SUCCESS" "🍽️ $display_id plated! (${duration}s)"
    emit_supervisor_event "task_complete" "$task_id" "$worker" "$duration"
    rm -f "$output_file"
    return 0
  elif grep -aq "<promise>ALREADY_DONE</promise>" "$output_file" 2>/dev/null; then
    log_event "SUCCESS" "🍽️ $display_id already on the pass! (${duration}s)"
    emit_supervisor_event "task_already_done" "$task_id"
    rm -f "$output_file"
    return 33  # ALREADY_DONE (distinct from jq exit code 3)
  elif grep -aoq "<promise>ABSORBED_BY:" "$output_file" 2>/dev/null; then
    # Extract the absorbing task ID (e.g., ABSORBED_BY:US-001 -> US-001)
    LAST_ABSORBED_BY=$(grep -ao "<promise>ABSORBED_BY:[^<]*</promise>" "$output_file" | sed 's/<promise>ABSORBED_BY://;s/<\/promise>//')
    local absorbed_display=$(format_task_id "$prd_path" "$LAST_ABSORBED_BY")
    log_event "SUCCESS" "Task $display_id ABSORBED BY $absorbed_display (${duration}s)"
    emit_supervisor_event "task_absorbed" "$task_id" "$LAST_ABSORBED_BY"
    rm -f "$output_file"
    return 34  # ABSORBED_BY
  elif grep -aq "<promise>BLOCKED</promise>" "$output_file" 2>/dev/null; then
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
  log_event "INFO" "🧪 Taste testing $display_id ($cmd_count check(s))..."
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
    log_event "ERROR" "🔥 Taste test failed! $fail_count of $cmd_count check(s) didn't pass"
    LAST_VERIFICATION_FEEDBACK="Verification commands failed:${failed_cmds}

Please fix these issues and ensure all verification commands pass before signaling COMPLETE."
    return 1
  else
    log_event "SUCCESS" "✅ Taste test passed! $pass_count of $cmd_count check(s)"
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

# ═══════════════════════════════════════════════════════════════════════════════
# PRD QUALITY & VERIFICATION DEPTH (P15)
# ═══════════════════════════════════════════════════════════════════════════════

# Pattern matching for vague/ambiguous acceptance criteria phrases
# Returns warnings (one per line) to stdout
lint_acceptance_criteria() {
  local criterion="$1"
  local task_id="$2"
  local criterion_lower=$(echo "$criterion" | tr '[:upper:]' '[:lower:]')

  # "shown" without context
  if echo "$criterion_lower" | grep -qE '\bshown\b' && ! echo "$criterion_lower" | grep -qE '(shown when|shown by default|shown if|shown after|shown on|shown in)'; then
    printf '%s: "shown" is ambiguous - specify when/where/how it'\''s shown\n' "$task_id"
  fi

  # "supports X" without enabled state
  if echo "$criterion_lower" | grep -qE '\bsupports?\b' && ! echo "$criterion_lower" | grep -qE '(by default|enabled|disabled|opt.?in|opt.?out|when configured)'; then
    printf '%s: "supports" is ambiguous - specify if enabled by default or opt-in\n' "$task_id"
  fi

  # "works correctly/properly"
  if echo "$criterion_lower" | grep -qE '\b(works?\s+(correctly|properly)|correctly\s+works?|properly\s+works?)\b'; then
    printf '%s: "works correctly/properly" is vague - specify expected behavior\n' "$task_id"
  fi

  # "handles errors" without specifics
  if echo "$criterion_lower" | grep -qE '\bhandles?\s+(errors?|exceptions?|failures?)\b' && ! echo "$criterion_lower" | grep -qE '(returns|displays|shows|logs|emits|throws|with message|error code|status)'; then
    printf '%s: "handles errors" is vague - specify error response/behavior\n' "$task_id"
  fi

  # "user can X" without method
  if echo "$criterion_lower" | grep -qE '\buser\s+can\b' && ! echo "$criterion_lower" | grep -qE '(via|using|by clicking|through|in the|from the|with the|button|menu|command|api|cli)'; then
    printf '%s: "user can" is vague - specify via what interface (UI/CLI/API)\n' "$task_id"
  fi

  # Subjective terms
  if echo "$criterion_lower" | grep -qE '\b(appropriate|suitable|reasonable|adequate|sufficient|good|nice|clean|proper)\b'; then
    local match=$(echo "$criterion_lower" | grep -oE '\b(appropriate|suitable|reasonable|adequate|sufficient|good|nice|clean|proper)\b' | head -1)
    printf '%s: "%s" is subjective - specify measurable criteria\n' "$task_id" "$match"
  fi

  # "should be" phrasing (uncertainty)
  if echo "$criterion_lower" | grep -qE '\bshould\s+be\b'; then
    printf '%s: "should be" implies uncertainty - use declarative language ("is", "returns", "displays")\n' "$task_id"
  fi

  # Empty or very short criteria
  local word_count=$(echo "$criterion" | wc -w | tr -d ' ')
  if [ "$word_count" -lt 3 ]; then
    printf '%s: Criterion is too brief (%d words) - provide more detail\n' "$task_id" "$word_count"
  fi
}

# Lint all acceptance criteria for a task
# Returns: 0 if no warnings, 1 if warnings found
# Side effect: sets TASK_CRITERIA_WARNINGS (newline-separated)
lint_task_criteria() {
  local prd_path="$1"
  local task_id="$2"
  TASK_CRITERIA_WARNINGS=""

  local criteria=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .acceptanceCriteria[]?' "$prd_path" 2>/dev/null)

  if [ -z "$criteria" ]; then
    return 0
  fi

  while IFS= read -r criterion; do
    [ -z "$criterion" ] && continue
    local warnings=$(lint_acceptance_criteria "$criterion" "$task_id")
    if [ -n "$warnings" ]; then
      # $() strips trailing newlines, so add one back when appending
      TASK_CRITERIA_WARNINGS="${TASK_CRITERIA_WARNINGS}${warnings}
"
    fi
  done <<< "$criteria"

  if [ -n "$TASK_CRITERIA_WARNINGS" ]; then
    return 1
  fi
  return 0
}

# Suggest verification commands based on task title and project stack
# Returns suggestions to stdout
suggest_verification() {
  local prd_path="$1"
  local task_id="$2"

  local task_title=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .title // ""' "$prd_path")
  local title_lower=$(echo "$task_title" | tr '[:upper:]' '[:lower:]')
  local suggestions=""

  # Detect project stack
  local stack=""
  if [ -f "go.mod" ]; then
    stack="go"
  elif [ -f "package.json" ]; then
    stack="node"
  elif [ -f "requirements.txt" ] || [ -f "setup.py" ] || [ -f "pyproject.toml" ]; then
    stack="python"
  elif [ -f "Cargo.toml" ]; then
    stack="rust"
  elif [ -f "Gemfile" ]; then
    stack="ruby"
  fi

  # CLI/Command/Flag patterns
  if echo "$title_lower" | grep -qE '\b(cli|command|flag|option|argument|args)\b'; then
    case "$stack" in
      go) suggestions="${suggestions}  {\"type\": \"smoke\", \"cmd\": \"go build ./... && ./bin/app --help\"}\n" ;;
      node) suggestions="${suggestions}  {\"type\": \"smoke\", \"cmd\": \"npm run build && node ./dist/cli.js --help\"}\n" ;;
      python) suggestions="${suggestions}  {\"type\": \"smoke\", \"cmd\": \"python -m app --help\"}\n" ;;
      rust) suggestions="${suggestions}  {\"type\": \"smoke\", \"cmd\": \"cargo build && ./target/debug/app --help\"}\n" ;;
      *) suggestions="${suggestions}  {\"type\": \"smoke\", \"cmd\": \"./app --help\"}\n" ;;
    esac
  fi

  # API/Endpoint/Handler patterns
  if echo "$title_lower" | grep -qE '\b(api|endpoint|handler|route|controller|rest)\b'; then
    case "$stack" in
      go) suggestions="${suggestions}  {\"type\": \"integration\", \"cmd\": \"go test -run TestAPI ./...\"}\n" ;;
      node) suggestions="${suggestions}  {\"type\": \"integration\", \"cmd\": \"npm test -- --grep \\\"API\\\"\"}\n" ;;
      python) suggestions="${suggestions}  {\"type\": \"integration\", \"cmd\": \"pytest -k api\"}\n" ;;
      rust) suggestions="${suggestions}  {\"type\": \"integration\", \"cmd\": \"cargo test api\"}\n" ;;
      *) suggestions="${suggestions}  {\"type\": \"integration\", \"cmd\": \"# Add API test command\"}\n" ;;
    esac
  fi

  # Model/Schema/Database patterns
  if echo "$title_lower" | grep -qE '\b(model|schema|database|db|migration|entity|table)\b'; then
    case "$stack" in
      go) suggestions="${suggestions}  {\"type\": \"unit\", \"cmd\": \"go test -run TestModel ./internal/models/...\"}\n" ;;
      node) suggestions="${suggestions}  {\"type\": \"unit\", \"cmd\": \"npm test -- --grep \\\"model\\\"\"}\n" ;;
      python) suggestions="${suggestions}  {\"type\": \"unit\", \"cmd\": \"pytest -k model\"}\n" ;;
      *) suggestions="${suggestions}  {\"type\": \"unit\", \"cmd\": \"# Add model test command\"}\n" ;;
    esac
  fi

  # Auth/Login/JWT patterns
  if echo "$title_lower" | grep -qE '\b(auth|login|jwt|oauth|session|token|password)\b'; then
    case "$stack" in
      go) suggestions="${suggestions}  {\"type\": \"unit\", \"cmd\": \"go test -run TestAuth ./internal/auth/...\"}\n  {\"type\": \"integration\", \"cmd\": \"go test -run TestLoginFlow ./internal/app/...\"}\n" ;;
      node) suggestions="${suggestions}  {\"type\": \"unit\", \"cmd\": \"npm test -- --grep \\\"auth\\\"\"}\n  {\"type\": \"integration\", \"cmd\": \"npm test -- --grep \\\"login flow\\\"\"}\n" ;;
      python) suggestions="${suggestions}  {\"type\": \"unit\", \"cmd\": \"pytest -k auth\"}\n  {\"type\": \"integration\", \"cmd\": \"pytest -k login\"}\n" ;;
      *) suggestions="${suggestions}  {\"type\": \"unit\", \"cmd\": \"# Add auth unit tests\"}\n  {\"type\": \"integration\", \"cmd\": \"# Add auth integration tests\"}\n" ;;
    esac
  fi

  # Integration/Connect/Wire patterns
  if echo "$title_lower" | grep -qE '\b(integrat|connect|wire|link|hook|bind)\b'; then
    case "$stack" in
      go) suggestions="${suggestions}  {\"type\": \"integration\", \"cmd\": \"go test -tags=integration ./...\"}\n" ;;
      node) suggestions="${suggestions}  {\"type\": \"integration\", \"cmd\": \"npm run test:integration\"}\n" ;;
      python) suggestions="${suggestions}  {\"type\": \"integration\", \"cmd\": \"pytest -m integration\"}\n" ;;
      *) suggestions="${suggestions}  {\"type\": \"integration\", \"cmd\": \"# Add integration test command\"}\n" ;;
    esac
  fi

  # Feature/Flow/User patterns (need smoke tests)
  if echo "$title_lower" | grep -qE '\b(feature|flow|workflow|user can|user sees|full|complete|end.to.end)\b'; then
    case "$stack" in
      go) suggestions="${suggestions}  {\"type\": \"smoke\", \"cmd\": \"go test -tags=smoke ./...\"}\n" ;;
      node) suggestions="${suggestions}  {\"type\": \"smoke\", \"cmd\": \"npm run test:e2e\"}\n" ;;
      python) suggestions="${suggestions}  {\"type\": \"smoke\", \"cmd\": \"pytest -m smoke\"}\n" ;;
      *) suggestions="${suggestions}  {\"type\": \"smoke\", \"cmd\": \"# Add smoke/e2e test command\"}\n" ;;
    esac
  fi

  # Default suggestion if nothing matched
  if [ -z "$suggestions" ]; then
    case "$stack" in
      go) suggestions="  {\"type\": \"unit\", \"cmd\": \"go test ./...\"}\n" ;;
      node) suggestions="  {\"type\": \"unit\", \"cmd\": \"npm test\"}\n" ;;
      python) suggestions="  {\"type\": \"unit\", \"cmd\": \"pytest\"}\n" ;;
      rust) suggestions="  {\"type\": \"unit\", \"cmd\": \"cargo test\"}\n" ;;
      ruby) suggestions="  {\"type\": \"unit\", \"cmd\": \"bundle exec rspec\"}\n" ;;
      *) suggestions="  {\"type\": \"unit\", \"cmd\": \"# Add test command\"}\n" ;;
    esac
  fi

  echo -e "$suggestions"
}

# Detect if project is a web app (React/Vue/Svelte/HTMX)
# Returns: 0 if web app, 1 otherwise
# Side effect: sets WEB_APP_TYPE
detect_web_app() {
  WEB_APP_TYPE=""

  # Check package.json for React/Vue/Svelte/Next.js
  if [ -f "package.json" ]; then
    local deps=$(cat package.json | jq -r '.dependencies // {} | keys[]' 2>/dev/null)
    local dev_deps=$(cat package.json | jq -r '.devDependencies // {} | keys[]' 2>/dev/null)
    local all_deps="$deps $dev_deps"

    if echo "$all_deps" | grep -qE '^react$'; then
      WEB_APP_TYPE="react"
      return 0
    fi
    if echo "$all_deps" | grep -qE '^vue$'; then
      WEB_APP_TYPE="vue"
      return 0
    fi
    if echo "$all_deps" | grep -qE '^svelte$'; then
      WEB_APP_TYPE="svelte"
      return 0
    fi
    if echo "$all_deps" | grep -qE '^next$'; then
      WEB_APP_TYPE="nextjs"
      return 0
    fi
    if echo "$all_deps" | grep -qE '^nuxt$'; then
      WEB_APP_TYPE="nuxt"
      return 0
    fi
  fi

  # Check for HTMX in templates (common patterns)
  if find . -maxdepth 4 -type f \( -name "*.html" -o -name "*.tmpl" -o -name "*.templ" -o -name "*.gohtml" -o -name "*.jinja2" \) 2>/dev/null | head -20 | xargs grep -l 'hx-' 2>/dev/null | grep -q .; then
    WEB_APP_TYPE="htmx"
    return 0
  fi

  # Check for vanilla JS DOM manipulation in significant JS files
  if find . -maxdepth 3 -type f -name "*.js" ! -path "*/node_modules/*" 2>/dev/null | head -20 | xargs grep -lE '(document\.(getElementById|querySelector|createElement)|addEventListener|innerHTML|\.onclick)' 2>/dev/null | grep -q .; then
    WEB_APP_TYPE="vanilla"
    return 0
  fi

  return 1
}

# Check if project has E2E testing setup
# Returns: 0 if has E2E, 1 otherwise
# Side effect: sets E2E_FRAMEWORK
has_e2e_testing() {
  E2E_FRAMEWORK=""

  # Playwright
  if [ -f "playwright.config.ts" ] || [ -f "playwright.config.js" ]; then
    E2E_FRAMEWORK="playwright"
    return 0
  fi

  # Cypress
  if [ -f "cypress.config.ts" ] || [ -f "cypress.config.js" ] || [ -d "cypress" ]; then
    E2E_FRAMEWORK="cypress"
    return 0
  fi

  # Selenium (check for common test files)
  if find . -maxdepth 3 -type f \( -name "*selenium*" -o -name "*webdriver*" \) ! -path "*/node_modules/*" 2>/dev/null | grep -q .; then
    E2E_FRAMEWORK="selenium"
    return 0
  fi

  # Puppeteer
  if [ -f "package.json" ] && grep -q '"puppeteer"' package.json 2>/dev/null; then
    E2E_FRAMEWORK="puppeteer"
    return 0
  fi

  return 1
}

# Check if PRD has UI-related tasks that need E2E testing
# Returns: 0 if UI tasks found, 1 otherwise
# Side effect: sets UI_TASK_COUNT and UI_TASK_IDS
has_ui_tasks() {
  local prd_path="$1"
  UI_TASK_COUNT=0
  UI_TASK_IDS=""

  local all_ids=$(jq -r '.tasks[].id' "$prd_path" 2>/dev/null)

  for task_id in $all_ids; do
    local title=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .title // ""' "$prd_path")
    local criteria=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .acceptanceCriteria[]?' "$prd_path" 2>/dev/null | tr '\n' ' ')
    local combined=$(echo "$title $criteria" | tr '[:upper:]' '[:lower:]')

    # UI-related keywords
    if echo "$combined" | grep -qE '\b(user sees|user clicks|clicks|button|form|modal|dropdown|filter|display|render|shows|visible|ui|interface|page|view|component|screen)\b'; then
      UI_TASK_COUNT=$((UI_TASK_COUNT + 1))
      UI_TASK_IDS="${UI_TASK_IDS}${task_id} "
    fi
  done

  if [ "$UI_TASK_COUNT" -gt 0 ]; then
    return 0
  fi
  return 1
}

# Find PRDs with keyword overlap to the current task
# Returns: related PRD info to stdout
find_related_prds() {
  local prd_path="$1"
  local task_id="$2"
  local max_related="${CROSS_PRD_MAX_RELATED:-3}"

  # Get current task keywords from title
  local task_title=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .title // ""' "$prd_path" 2>/dev/null)
  local keywords=$(echo "$task_title" | tr '[:upper:]' '[:lower:]' | grep -oE '\b[a-z]{3,}\b' | sort -u | head -10)

  if [ -z "$keywords" ]; then
    return
  fi

  # Get PRD directory
  local prd_dir=$(dirname "$prd_path")
  local current_prd=$(basename "$prd_path")

  # Find other PRDs in same directory
  local other_prds=$(find "$prd_dir" -maxdepth 1 -name "prd-*.json" ! -name "$current_prd" 2>/dev/null)

  if [ -z "$other_prds" ]; then
    return
  fi

  # Score each PRD by keyword overlap
  local scored_prds=""
  for other_prd in $other_prds; do
    local other_name=$(basename "$other_prd")
    local other_feature=$(jq -r '.featureName // ""' "$other_prd" 2>/dev/null)
    local other_titles=$(jq -r '.tasks[].title' "$other_prd" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    local score=0

    for keyword in $keywords; do
      if echo "$other_feature $other_titles" | grep -qi "$keyword"; then
        score=$((score + 1))
      fi
    done

    if [ "$score" -gt 0 ]; then
      # Determine status
      local state_path="${other_prd%.json}.state.json"
      local status="pending"
      if [ -f "$state_path" ]; then
        local total=$(jq '.tasks | length' "$other_prd" 2>/dev/null || echo "0")
        local done=$(jq '[.tasks[] | select(.passes == true)] | length' "$other_prd" 2>/dev/null || echo "0")
        if [ "$done" -eq "$total" ] && [ "$total" -gt 0 ]; then
          status="complete"
        elif [ "$done" -gt 0 ]; then
          status="in-progress"
        fi
      fi

      scored_prds="${scored_prds}${score}|${other_name}|${other_feature}|${status}\n"
    fi
  done

  # Sort by score and return top N
  if [ -n "$scored_prds" ]; then
    echo -e "$scored_prds" | sort -t'|' -k1 -nr | head -$max_related
  fi
}

# Build cross-PRD context section for worker prompt
get_cross_prd_context() {
  local prd_path="$1"
  local task_id="$2"

  local related=$(find_related_prds "$prd_path" "$task_id")

  if [ -z "$related" ]; then
    return
  fi

  local context="RELATED PRDs (may have relevant patterns or conflicts):\n"
  local prd_dir=$(dirname "$prd_path")

  while IFS='|' read -r score name feature status; do
    [ -z "$name" ] && continue
    context="${context}- ${feature} (${name}) [${status}]\n"

    # If complete, check for learnings
    if [ "$status" = "complete" ]; then
      local learnings_path=$(get_learnings_path "${prd_dir}/${name}")
      if [ -f "$learnings_path" ]; then
        local recent_learnings=$(grep -A2 "^## \[" "$learnings_path" 2>/dev/null | head -6)
        if [ -n "$recent_learnings" ]; then
          context="${context}  Recent learnings:\n"
          context="${context}$(echo "$recent_learnings" | sed 's/^/    /')\n"
        fi
      fi
    fi
  done <<< "$related"

  echo -e "$context"
}

# ═══════════════════════════════════════════════════════════════════════════════
# RISK ASSESSMENT (P9)
# ═══════════════════════════════════════════════════════════════════════════════

# Risk scoring weights (points per factor)
RISK_WEIGHT_AUTH=3          # Auth/security keywords
RISK_WEIGHT_PAYMENT=3       # Payment/billing keywords
RISK_WEIGHT_EXTERNAL=2      # External integrations
RISK_WEIGHT_DATA=2          # Data operations
RISK_WEIGHT_NO_VERIFY=2     # Missing verification
RISK_WEIGHT_GREP_ONLY=1     # Pattern-only verification
RISK_WEIGHT_SENIOR=1        # Senior complexity
RISK_WEIGHT_AUTO=1          # Auto complexity (uncertain)
RISK_WEIGHT_HIGH_DEPS=1     # More than 3 dependencies

# Calculate risk score for a single task
# Usage: calculate_task_risk <prd_path> <task_id>
# Returns: risk score (integer)
calculate_task_risk() {
  local prd_path="$1"
  local task_id="$2"
  local score=0

  local task_json=$(jq --arg id "$task_id" '.tasks[] | select(.id == $id)' "$prd_path")
  local title=$(echo "$task_json" | jq -r '.title // ""')
  local title_lower=$(echo "$title" | tr '[:upper:]' '[:lower:]')
  local complexity=$(echo "$task_json" | jq -r '.complexity // "auto"')
  local deps_count=$(echo "$task_json" | jq '.dependsOn | length // 0')
  local verification=$(echo "$task_json" | jq '.verification // []')

  # Auth/security keywords (3 points each occurrence)
  # Match partial words: "authentication" matches "auth", "authorize" matches "auth"
  local auth_matches=$(echo "$title_lower" | grep -oiE '(auth|password|token|jwt|oauth|credential|login|session|permission|access.control|secure|encrypt)' | wc -l)
  score=$((score + auth_matches * RISK_WEIGHT_AUTH))

  # Payment/billing keywords (3 points each)
  local payment_matches=$(echo "$title_lower" | grep -oiE '(payment|billing|stripe|transaction|checkout|refund|subscription|pricing|invoice|charge)' | wc -l)
  score=$((score + payment_matches * RISK_WEIGHT_PAYMENT))

  # External integrations (2 points each)
  local external_matches=$(echo "$title_lower" | grep -oiE '(api|webhook|third.party|external|integrat|sdk|oauth|sso|connect)' | wc -l)
  score=$((score + external_matches * RISK_WEIGHT_EXTERNAL))

  # Data operations (2 points each)
  local data_matches=$(echo "$title_lower" | grep -oiE '(migrat|delete|drop|database|schema|backup|restore|seed|purge|truncate)' | wc -l)
  score=$((score + data_matches * RISK_WEIGHT_DATA))

  # Missing verification (2 points)
  local verify_len=$(echo "$verification" | jq 'length')
  if [ "$verify_len" -eq 0 ]; then
    score=$((score + RISK_WEIGHT_NO_VERIFY))
  else
    # Check for grep-only verification (1 point)
    local has_execution=false
    local i=0
    while [ $i -lt "$verify_len" ]; do
      local item=$(echo "$verification" | jq ".[$i]")
      local item_type=$(echo "$item" | jq -r 'type')
      local cmd=""
      if [ "$item_type" == "string" ]; then
        cmd=$(echo "$item" | jq -r '.')
      else
        cmd=$(echo "$item" | jq -r '.cmd // ""')
      fi
      # Check if it's an execution test (not just grep/test)
      if ! echo "$cmd" | grep -qE '^[[:space:]]*(grep|egrep|fgrep|test|stat|\[|ls[[:space:]])'; then
        has_execution=true
        break
      fi
      i=$((i + 1))
    done
    if [ "$has_execution" == "false" ]; then
      score=$((score + RISK_WEIGHT_GREP_ONLY))
    fi
  fi

  # Complexity (1 point for senior or auto)
  if [ "$complexity" == "senior" ]; then
    score=$((score + RISK_WEIGHT_SENIOR))
  elif [ "$complexity" == "auto" ]; then
    score=$((score + RISK_WEIGHT_AUTO))
  fi

  # High dependencies (1 point if more than 3)
  if [ "$deps_count" -gt 3 ]; then
    score=$((score + RISK_WEIGHT_HIGH_DEPS))
  fi

  echo "$score"
}

# Get human-readable risk factors for a task
# Usage: get_task_risk_factors <prd_path> <task_id>
# Returns: comma-separated list of factors
get_task_risk_factors() {
  local prd_path="$1"
  local task_id="$2"
  local factors=""

  local task_json=$(jq --arg id "$task_id" '.tasks[] | select(.id == $id)' "$prd_path")
  local title=$(echo "$task_json" | jq -r '.title // ""')
  local title_lower=$(echo "$title" | tr '[:upper:]' '[:lower:]')
  local complexity=$(echo "$task_json" | jq -r '.complexity // "auto"')
  local deps_count=$(echo "$task_json" | jq '.dependsOn | length // 0')
  local verification=$(echo "$task_json" | jq '.verification // []')

  # Auth/security
  if echo "$title_lower" | grep -qiE '(auth|password|token|jwt|oauth|credential|login|session|permission|access.control|secure|encrypt)'; then
    factors="${factors}authentication code, "
  fi

  # Payment
  if echo "$title_lower" | grep -qiE '(payment|billing|stripe|transaction|checkout|refund|subscription|pricing|invoice|charge)'; then
    factors="${factors}payment processing, "
  fi

  # External
  if echo "$title_lower" | grep -qiE '(api|webhook|third.party|external|integrat|sdk|sso|connect)'; then
    factors="${factors}external integration, "
  fi

  # Data
  if echo "$title_lower" | grep -qiE '(migrat|delete|drop|database|schema|backup|restore|seed|purge|truncate)'; then
    factors="${factors}data operation, "
  fi

  # Missing verification
  local verify_len=$(echo "$verification" | jq 'length')
  if [ "$verify_len" -eq 0 ]; then
    factors="${factors}no verification, "
  else
    # Check for grep-only
    local has_execution=false
    local i=0
    while [ $i -lt "$verify_len" ]; do
      local item=$(echo "$verification" | jq ".[$i]")
      local item_type=$(echo "$item" | jq -r 'type')
      local cmd=""
      if [ "$item_type" == "string" ]; then
        cmd=$(echo "$item" | jq -r '.')
      else
        cmd=$(echo "$item" | jq -r '.cmd // ""')
      fi
      if ! echo "$cmd" | grep -qE '^[[:space:]]*(grep|egrep|fgrep|test|stat|\[|ls[[:space:]])'; then
        has_execution=true
        break
      fi
      i=$((i + 1))
    done
    if [ "$has_execution" == "false" ]; then
      factors="${factors}pattern-only verification, "
    fi
  fi

  # Complexity
  if [ "$complexity" == "senior" ]; then
    factors="${factors}senior complexity, "
  elif [ "$complexity" == "auto" ]; then
    factors="${factors}auto complexity, "
  fi

  # High deps
  if [ "$deps_count" -gt 3 ]; then
    factors="${factors}high dependencies, "
  fi

  # Trim trailing comma and space
  echo "$factors" | sed 's/, $//'
}

# Calculate aggregate PRD risk score
# Usage: calculate_prd_risk <prd_path>
# Returns: total risk score
calculate_prd_risk() {
  local prd_path="$1"
  local total=0

  local all_ids=$(jq -r '.tasks[].id' "$prd_path")
  for task_id in $all_ids; do
    local task_score=$(calculate_task_risk "$prd_path" "$task_id")
    total=$((total + task_score))
  done

  echo "$total"
}

# Get risk level label from score
# Usage: get_risk_level <score>
# Returns: LOW, MEDIUM, HIGH, or CRITICAL
get_risk_level() {
  local score="$1"
  if [ "$score" -le 5 ]; then
    echo "LOW"
  elif [ "$score" -le 12 ]; then
    echo "MEDIUM"
  elif [ "$score" -le 20 ]; then
    echo "HIGH"
  else
    echo "CRITICAL"
  fi
}

# Get flagged tasks (tasks with risk score > 0)
# Usage: get_flagged_tasks <prd_path>
# Returns: space-separated list of task IDs with score > 0
get_flagged_tasks() {
  local prd_path="$1"
  local flagged=""

  local all_ids=$(jq -r '.tasks[].id' "$prd_path")
  for task_id in $all_ids; do
    local task_score=$(calculate_task_risk "$prd_path" "$task_id")
    if [ "$task_score" -gt 0 ]; then
      flagged="$flagged $task_id"
    fi
  done

  echo "$flagged" | xargs
}

# Analyze historical escalation patterns from state files
# Usage: analyze_historical_escalations [prd_path]
# Returns: JSON with escalation patterns
analyze_historical_escalations() {
  local target_dir="${1:-brigade/tasks}"
  local state_files=$(find "$target_dir" -name "*.state.json" 2>/dev/null)

  if [ -z "$state_files" ]; then
    echo '{"escalations":[],"patterns":{}}'
    return
  fi

  local auth_escalations=0
  local payment_escalations=0
  local integration_escalations=0
  local data_escalations=0
  local other_escalations=0

  for state_file in $state_files; do
    [ ! -f "$state_file" ] && continue

    # Get associated PRD (same name without .state)
    local prd_file="${state_file%.state.json}.json"
    [ ! -f "$prd_file" ] && continue

    # Get escalations from state
    local escalations=$(jq -r '.escalations // {} | to_entries[] | .key' "$state_file" 2>/dev/null)
    for task_id in $escalations; do
      local title=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .title // ""' "$prd_file" 2>/dev/null)
      local title_lower=$(echo "$title" | tr '[:upper:]' '[:lower:]')

      if echo "$title_lower" | grep -qE '\b(auth|password|token|jwt|oauth|credential|login|session)\b'; then
        auth_escalations=$((auth_escalations + 1))
      elif echo "$title_lower" | grep -qE '\b(payment|billing|stripe|transaction|checkout)\b'; then
        payment_escalations=$((payment_escalations + 1))
      elif echo "$title_lower" | grep -qE '\b(api|webhook|third-party|external|integration|sdk)\b'; then
        integration_escalations=$((integration_escalations + 1))
      elif echo "$title_lower" | grep -qE '\b(migration|delete|drop|database|schema)\b'; then
        data_escalations=$((data_escalations + 1))
      else
        other_escalations=$((other_escalations + 1))
      fi
    done
  done

  # Build JSON output
  jq -n \
    --argjson auth "$auth_escalations" \
    --argjson payment "$payment_escalations" \
    --argjson integration "$integration_escalations" \
    --argjson data "$data_escalations" \
    --argjson other "$other_escalations" \
    '{
      patterns: {
        auth: $auth,
        payment: $payment,
        integration: $integration,
        data: $data,
        other: $other
      },
      total: ($auth + $payment + $integration + $data + $other)
    }'
}

# Print brief risk summary (for pre-flight display)
# Usage: print_risk_summary <prd_path>
print_risk_summary() {
  local prd_path="$1"

  if [ "$RISK_REPORT_ENABLED" != "true" ]; then
    return
  fi

  local total_score=$(calculate_prd_risk "$prd_path")
  local level=$(get_risk_level "$total_score")
  local flagged=$(get_flagged_tasks "$prd_path")
  local flagged_count=$(echo "$flagged" | wc -w | xargs)

  # Color based on level
  local color="$GREEN"
  local symbol="✓"
  case "$level" in
    MEDIUM) color="$YELLOW"; symbol="⚠" ;;
    HIGH)   color="$YELLOW"; symbol="⚠" ;;
    CRITICAL) color="$RED"; symbol="⚠" ;;
  esac

  echo -e "${color}${symbol} Risk: $level (score: $total_score)${NC}"
  if [ "$flagged_count" -gt 0 ]; then
    echo -e "  ${GRAY}Flagged tasks: $flagged${NC}"
  fi

  # Warn if threshold exceeded
  if [ -n "$RISK_WARN_THRESHOLD" ]; then
    case "$RISK_WARN_THRESHOLD" in
      low)     [ "$level" != "LOW" ] && echo -e "${YELLOW}⚠ Risk level exceeds threshold ($RISK_WARN_THRESHOLD)${NC}" ;;
      medium)  [[ "$level" == "HIGH" || "$level" == "CRITICAL" ]] && echo -e "${YELLOW}⚠ Risk level exceeds threshold ($RISK_WARN_THRESHOLD)${NC}" ;;
      high)    [ "$level" == "CRITICAL" ] && echo -e "${YELLOW}⚠ Risk level exceeds threshold ($RISK_WARN_THRESHOLD)${NC}" ;;
    esac
  fi
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

# Check if task requires manual verification and prompt user
# Returns 0 if verified (or not required), 1 if needs iteration (user rejected)
# Sets: LAST_MANUAL_VERIFICATION_FEEDBACK
check_manual_verification() {
  local prd_path="$1"
  local task_id="$2"

  LAST_MANUAL_VERIFICATION_FEEDBACK=""

  if [ "$MANUAL_VERIFICATION_ENABLED" != "true" ]; then
    return 0
  fi

  # Check if task has manualVerification flag
  local requires_manual
  requires_manual=$(jq -r ".tasks[] | select(.id == \"$task_id\") | .manualVerification // false" "$prd_path")
  if [ "$requires_manual" != "true" ]; then
    return 0
  fi

  local display_id=$(format_task_id "$prd_path" "$task_id")
  local task_title
  task_title=$(jq -r ".tasks[] | select(.id == \"$task_id\") | .title" "$prd_path")
  local criteria
  criteria=$(jq -r ".tasks[] | select(.id == \"$task_id\") | .acceptanceCriteria | join(\"\n  - \")" "$prd_path")

  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
  log_event "VERIFY" "MANUAL VERIFICATION: $display_id"
  echo -e "${CYAN}║  Manual verification required for this task               ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${YELLOW}Task: $task_title${NC}"
  echo ""
  echo -e "Acceptance Criteria:"
  echo -e "  - $criteria"
  echo ""

  # Build context for decision
  local context
  context=$(jq -n --arg task "$task_id" --arg title "$task_title" \
    '{taskId: $task, title: $title, type: "manual_verification"}')

  # In walkaway mode without supervisor, auto-approve (user opted into autonomous execution)
  if [ "$WALKAWAY_MODE" == "true" ] && [ -z "$SUPERVISOR_CMD_FILE" ]; then
    echo -e "${YELLOW}Walkaway mode: Auto-approving manual verification${NC}"
    log_event "INFO" "Manual verification auto-approved (walkaway mode)"
    return 0
  fi

  # With supervisor configured, emit attention event and wait for decision
  if [ -n "$SUPERVISOR_CMD_FILE" ]; then
    emit_supervisor_event "attention" "$display_id" "manual_verification" "Task requires manual verification"

    local decision_id
    decision_id=$(generate_decision_id)
    emit_supervisor_event "decision_needed" "$display_id" "manual_verification" "$context"

    wait_for_supervisor_command "$decision_id"
    local result=$?

    if [ $result -eq 0 ]; then
      log_event "SUCCESS" "Manual verification approved: $display_id"
      return 0
    else
      LAST_MANUAL_VERIFICATION_FEEDBACK="Manual verification rejected: $DECISION_REASON"
      log_event "WARN" "Manual verification rejected: $display_id - $DECISION_REASON"
      return 1
    fi
  fi

  # Interactive mode: prompt user
  echo -e "Please verify that the acceptance criteria are met."
  echo -e "  ${GREEN}y${NC} - Verified, proceed to review"
  echo -e "  ${RED}n${NC} - Not verified, iterate with feedback"
  echo ""
  read -p "Mark as verified? [y/n]: " response

  case "$response" in
    y|Y|yes|Yes)
      log_event "SUCCESS" "Manual verification approved: $display_id"
      return 0
      ;;
    n|N|no|No)
      read -p "Feedback for worker (optional): " feedback
      if [ -n "$feedback" ]; then
        LAST_MANUAL_VERIFICATION_FEEDBACK="Manual verification rejected: $feedback"
      else
        LAST_MANUAL_VERIFICATION_FEEDBACK="Manual verification rejected by user"
      fi
      log_event "WARN" "Manual verification rejected: $display_id"
      return 1
      ;;
    *)
      echo -e "${YELLOW}Invalid input, defaulting to verified${NC}"
      return 0
      ;;
  esac
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

  # Acquire review lock to serialize reviews during parallel execution
  # This prevents multiple tasks from triggering overlapping executive reviews
  local state_path=$(get_state_path "$prd_path")
  local review_lock_path="${state_path%.json}.review"
  acquire_lock "$review_lock_path"

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
    log_event "SUCCESS" "👨‍🍳 Executive Chef approves $display_id! (${duration}s)"
    echo -e "${GRAY}Reason: $review_reason${NC}"
    LAST_REVIEW_FEEDBACK=""  # Clear any previous feedback
    LAST_VERIFICATION_FEEDBACK=""
    LAST_TODO_WARNINGS=""
    LAST_MANUAL_VERIFICATION_FEEDBACK=""
    release_lock "$review_lock_path"
    return 0
  else
    log_event "ERROR" "👨‍🍳 Executive Chef sent $display_id back to the kitchen (${duration}s)"
    echo -e "${GRAY}Reason: $review_reason${NC}"
    # Store feedback so it can be passed to worker on retry
    LAST_REVIEW_FEEDBACK="$review_reason"
    release_lock "$review_lock_path"
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

  # Count iterations for current task
  local iteration=0
  if [ -n "$current" ] && [ -f "$state_path" ]; then
    iteration=$(jq --arg task "$current" \
      '[.taskHistory[] | select(.taskId == $task)] | length' "$state_path" 2>/dev/null || echo 0)
  fi

  # Build compact JSON (single line, no pretty-printing)
  if [ "$attention" = "true" ]; then
    printf '{"done":%d,"total":%d,"current":%s,"worker":%s,"elapsed":%d,"iteration":%d,"attention":true,"reason":"%s"}\n' \
      "$done" "$total" \
      "$([ -n "$current" ] && echo "\"$current\"" || echo "null")" \
      "$([ -n "$worker" ] && echo "\"$worker\"" || echo "null")" \
      "$elapsed" "$iteration" "$reason"
  else
    printf '{"done":%d,"total":%d,"current":%s,"worker":%s,"elapsed":%d,"iteration":%d,"attention":false}\n' \
      "$done" "$total" \
      "$([ -n "$current" ] && echo "\"$current\"" || echo "null")" \
      "$([ -n "$worker" ] && echo "\"$worker\"" || echo "null")" \
      "$elapsed" "$iteration"
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

          # Count iterations for this task
          local iteration_count=$(jq --arg task "$current_task" \
            '[.taskHistory[] | select(.taskId == $task)] | length' "$state_path")

          echo ""
          echo -e "${YELLOW}🔥 CURRENTLY COOKING:${NC}"
          echo -e "   ${BOLD}$current_task${NC}: $task_title"
          echo -e "   ${GRAY}Worker: $worker_name | Iteration: $iteration_count${NC}"

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
  local bar=""
  local bar_empty=""
  [ "$filled" -gt 0 ] && bar=$(printf "█%.0s" $(seq 1 $filled))
  [ "$empty" -gt 0 ] && bar_empty=$(printf "░%.0s" $(seq 1 $empty))

  echo -e "${BOLD}📊 Progress:${NC} [${GREEN}${bar}${NC}${bar_empty}] ${pct}% ($complete/$total)"
  echo ""

  # Task list with status indicators
  echo -e "${BOLD}Tasks:${NC}"
  local current_task_id=""
  local current_worker=""
  local current_iteration=0
  local absorptions_json="[]"
  local escalations_json="[]"
  local worked_tasks_json="[]"
  local iterations_json="{}"
  if [ -f "$state_path" ]; then
    current_task_id=$(jq -r '.currentTask // empty' "$state_path")
    absorptions_json=$(jq -c '.absorptions // []' "$state_path")
    escalations_json=$(jq -c '.escalations // []' "$state_path")
    # Get unique task IDs that have been worked on
    worked_tasks_json=$(jq -c '[.taskHistory[].taskId] | unique' "$state_path")
    # Get iteration counts per task
    iterations_json=$(jq -c '[.taskHistory[].taskId] | group_by(.) | map({(.[0]): length}) | add // {}' "$state_path")
    # Get current worker from last history entry
    if [ -n "$current_task_id" ]; then
      current_worker=$(jq -r --arg task "$current_task_id" \
        '[.taskHistory[] | select(.taskId == $task)] | last | .worker // "line"' "$state_path")
      current_iteration=$(jq --arg task "$current_task_id" \
        '[.taskHistory[] | select(.taskId == $task)] | length' "$state_path")
    fi
  fi

  jq -r --arg current "$current_task_id" --arg current_worker "$current_worker" --argjson current_iter "$current_iteration" \
      --argjson absorptions "$absorptions_json" --argjson escalations "$escalations_json" \
      --argjson worked "$worked_tasks_json" --argjson iterations "$iterations_json" '.tasks[] |
    .id as $id |
    .complexity as $complexity |
    # Get iteration count for this task
    ($iterations[$id] // 0) as $iter_count |
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
    # Iteration display (only show if > 1)
    (if $iter_count > 1 then " (iter \($iter_count))" else "" end) as $iter_display |
    if .passes == true and $absorption != null then
      "  \u001b[32m✓\u001b[0m \(.id): \(.title) \u001b[90m(absorbed by \($absorption.absorbedBy))\u001b[0m"
    elif .passes == true then
      "  \u001b[32m✓\u001b[0m \(.id): \(.title)\(if $iter_count > 1 then " \u001b[90m(\($iter_count) iterations)\u001b[0m" else "" end)"
    elif .id == $current then
      "  \u001b[33m→\u001b[0m \(.id): \(.title) \u001b[33m[\($current_worker | if . == "line" then "Line Cook" elif . == "sous" then "Sous Chef" elif . == "executive" then "Exec Chef" else . end) · iter \($current_iter)]\u001b[0m\(if $last_esc != null then " \u001b[33m⬆\u001b[0m" else "" end)"
    elif $has_history then
      "  \u001b[36m◐\u001b[0m \(.id): \(.title) \u001b[90m[\($worker_name)] awaiting review\($iter_display)\u001b[0m\(if $last_esc != null then " \u001b[33m⬆\u001b[0m" else "" end)"
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

  # Mini legend
  echo ""
  echo -e "${GRAY}Legend: ✓ complete  → in progress  ◐ awaiting review  ○ not started  ⬆ escalated${NC}"
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
  LAST_MANUAL_VERIFICATION_FEEDBACK=""

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
      log_event "ESCALATE" "📢 Calling in the Sous Chef for $display_id"
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
      log_event "ESCALATE" "📢 Calling in the Executive Chef for $display_id (rare)"
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
          log_event "ESCALATE" "⏰ Line Cook timed out - calling Sous Chef for $display_id"
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
          log_event "ESCALATE" "⏰ Sous Chef timed out - calling Executive Chef for $display_id"
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

      # Check manual verification if required for this task
      if ! check_manual_verification "$prd_path" "$task_id"; then
        echo -e "${YELLOW}Manual verification failed, continuing iterations...${NC}"
        update_state_task "$prd_path" "$task_id" "$worker" "manual_verification_failed"
        # Continue to next iteration - LAST_MANUAL_VERIFICATION_FEEDBACK is set
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
          # Calculate task duration for cost tracking
          local task_duration=0
          if [ "$CURRENT_TASK_START_TIME" -gt 0 ]; then
            task_duration=$(($(date +%s) - CURRENT_TASK_START_TIME))
          fi
          update_state_task "$prd_path" "$task_id" "$worker" "complete" "$task_duration"
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
        log_event "ESCALATE" "🔥 Line Cook blocked - calling Sous Chef for $display_id"
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
        log_event "ESCALATE" "🔥 Sous Chef blocked - calling Executive Chef for $display_id"
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

    # Sort PRDs by modification time (newest first) for predictable execution order
    # This ensures recently modified PRDs are processed first
    IFS=$'\n' sorted_prds=($(ls -t "${prd_files[@]}" 2>/dev/null)); unset IFS
    # Fallback to alphabetical if ls -t fails
    if [ ${#sorted_prds[@]} -eq 0 ]; then
      IFS=$'\n' sorted_prds=($(sort <<<"${prd_files[*]}")); unset IFS
    fi

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

      # Warn about stale state (existing completed tasks from previous run)
      if [ "${AUTO_CONTINUE_WARN_STALE:-true}" == "true" ]; then
        local state_file="${current_prd%.json}.state.json"
        if [ -f "$state_file" ]; then
          local completed_count
          completed_count=$(jq '[.taskHistory[]? | select(.status == "complete")] | length' "$state_file" 2>/dev/null || echo 0)
          if [ "$completed_count" -gt 0 ]; then
            echo -e "${YELLOW}⚠ PRD has existing state with $completed_count completed task(s)${NC}"
            echo -e "${GRAY}  Using existing state. To start fresh: rm $state_file${NC}"
          fi
        fi
      fi

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

  # Acquire service instance lock (prevents multiple services on same PRD)
  if ! acquire_service_lock "$prd_path"; then
    exit 1
  fi

  # Initialize PRD-scoped supervisor files (for safe parallel execution)
  init_supervisor_files_for_prd "$prd_path"

  # Validate partial execution filters if any are active
  if has_active_filters; then
    echo -e "${GRAY}Validating partial execution filters...${NC}"

    # Check that all task IDs in filters exist
    if ! validate_task_filters "$prd_path"; then
      echo -e "${RED}Filter validation failed. Check task IDs.${NC}"
      exit 1
    fi

    # Check that filtered task set has valid dependencies
    if ! validate_filter_dependencies "$prd_path"; then
      echo -e "${RED}Filter dependency validation failed.${NC}"
      exit 1
    fi

    echo -e "${GREEN}✓${NC} Filters valid ($(get_filter_display))"
  fi

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

    # Show active filters if any
    if has_active_filters; then
      echo -e "${BOLD}Active Filters:${NC} $(get_filter_display)"
      echo ""
    fi

    # Show task execution order
    echo -e "${BOLD}Execution Plan:${NC}"
    local task_num=0
    jq -r '.tasks[] | "\(.id)|\(.title)|\(.complexity // "auto")|\(.dependsOn | if length == 0 then "-" else join(",") end)|\(.passes)"' "$prd_path" | \
    while IFS='|' read -r id title complexity deps passes; do
      task_num=$((task_num + 1))
      if [ "$passes" == "true" ]; then
        echo -e "  ${GREEN}✓${NC} $id: $title ${GRAY}[done]${NC}"
      elif has_active_filters && ! should_run_task "$prd_path" "$id"; then
        echo -e "  ${GRAY}⊘ $id: $title [filtered out]${NC}"
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

  log_event "START" "🍳 Firing up the kitchen for: $feature_name"
  emit_supervisor_event "service_start" "$(basename "$prd_path")" "$total"
  echo -e "📋 Menu: $total dishes to prepare"
  echo -e "${GRAY}Escalation: $([ "$ESCALATION_ENABLED" == "true" ] && echo "ON (after $ESCALATION_AFTER iterations)" || echo "OFF")${NC}"
  echo -e "${GRAY}Executive Review: $([ "$REVIEW_ENABLED" == "true" ] && echo "ON" || echo "OFF")${NC}"
  echo -e "${GRAY}Knowledge Sharing: $([ "$KNOWLEDGE_SHARING" == "true" ] && echo "ON" || echo "OFF")${NC}"
  echo -e "${GRAY}Parallel Workers: $([ "$MAX_PARALLEL" -gt 1 ] && echo "$MAX_PARALLEL" || echo "OFF")${NC}"

  # Show risk summary if enabled
  print_risk_summary "$prd_path"

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
            # Disable set -e in subshell to ensure clean exit handling
            set +e
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
        # IMPORTANT: Disable set -e to ensure we wait for ALL pids even if some fail
        set +e
        local all_success=true
        local failed_tasks=""
        local waited_count=0
        local total_parallel=${#task_pid_map}

        if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
          echo "[DEBUG] Parallel wait: expecting to wait for $(echo $task_pid_map | wc -w) tasks" >&2
        fi

        for mapping in $task_pid_map; do
          local task_id=$(echo "$mapping" | cut -d: -f1)
          local pid=$(echo "$mapping" | cut -d: -f2)
          local parallel_display_id=$(format_task_id "$prd_path" "$task_id")

          if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
            echo "[DEBUG] Parallel wait: waiting for $task_id (PID: $pid)" >&2
          fi

          wait "$pid"
          local exit_code=$?
          waited_count=$((waited_count + 1))

          if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
            echo "[DEBUG] Parallel wait: $task_id (PID: $pid) exited with $exit_code ($waited_count waited)" >&2
          fi

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
        set -e

        if [ "${BRIGADE_DEBUG:-false}" == "true" ]; then
          echo "[DEBUG] Parallel wait complete: waited for $waited_count tasks" >&2
        fi

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
  echo -e "${GREEN}║              ✅ Order Up! Kitchen Clean! ✅               ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}Feature:${NC}     $feature_name"
  [ -n "$branch_name" ] && echo -e "${BOLD}Branch:${NC}      $branch_name"
  echo ""
  echo -e "${BOLD}Summary:${NC}"
  echo -e "  Dishes served:     $completed/$total_tasks"
  echo -e "  Time in kitchen:   ${hours}h ${minutes}m"
  echo -e "  Escalations:       $escalation_count"
  echo -e "  Absorptions:       $absorption_count"
  [ "$review_count" -gt 0 ] && echo -e "  Reviews:           $review_pass/$review_count passed"
  echo ""

  log_event "SUCCESS" "✅ Order up! $completed dishes served, kitchen clean."
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

  # Release service instance lock
  release_service_lock "$prd_path"
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

  # P15: Acceptance criteria linting
  if [ "${CRITERIA_LINT_ENABLED:-true}" == "true" ]; then
    echo ""
    echo -e "${GRAY}Checking acceptance criteria quality...${NC}"
    local criteria_lint_warnings=0

    for task_id in $all_ids; do
      if ! lint_task_criteria "$prd_path" "$task_id"; then
        # Print each warning on its own line
        while IFS= read -r warning; do
          [ -z "$warning" ] && continue
          echo -e "  ${YELLOW}⚠${NC} $warning"
          criteria_lint_warnings=$((criteria_lint_warnings + 1))
        done <<< "$TASK_CRITERIA_WARNINGS"
      fi
    done

    if [ "$criteria_lint_warnings" -gt 0 ]; then
      warnings=$((warnings + 1))
      echo -e "  ${GRAY}Tip: Specific acceptance criteria lead to better verification${NC}"
    else
      echo -e "${GREEN}✓${NC} Acceptance criteria are specific and testable"
    fi
  fi

  # P15: Verification scaffolding suggestions
  if [ "${VERIFICATION_SCAFFOLD_ENABLED:-true}" == "true" ]; then
    local tasks_without_verification=$(jq -r '.tasks[] | select(.verification == null or (.verification | length) == 0) | .id' "$prd_path")
    if [ -n "$tasks_without_verification" ]; then
      echo ""
      echo -e "${GRAY}Suggested verification commands for tasks without verification:${NC}"
      for task_id in $tasks_without_verification; do
        local suggestions=$(suggest_verification "$prd_path" "$task_id")
        if [ -n "$suggestions" ]; then
          local task_title=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .title' "$prd_path" | head -c 50)
          echo -e "  ${CYAN}$task_id${NC}: $task_title"
          echo -e "$suggestions"
        fi
      done
    fi
  fi

  # P15: E2E detection for web apps
  if [ "${E2E_DETECTION_ENABLED:-true}" == "true" ]; then
    if detect_web_app; then
      if has_ui_tasks "$prd_path"; then
        if ! has_e2e_testing; then
          echo ""
          echo -e "${YELLOW}⚠${NC} Web app ($WEB_APP_TYPE) with UI tasks but no E2E testing setup detected"
          echo -e "  ${GRAY}$UI_TASK_COUNT tasks reference UI elements: $UI_TASK_IDS${NC}"
          echo -e "  ${GRAY}Consider adding Playwright or Cypress for browser-based verification:${NC}"
          case "$WEB_APP_TYPE" in
            react|vue|svelte|nextjs|nuxt)
              echo -e "    npm install -D @playwright/test"
              echo -e "    npx playwright install"
              ;;
            htmx)
              echo -e "    # For HTMX apps, Playwright works well:"
              echo -e "    npm install -D @playwright/test"
              ;;
            vanilla)
              echo -e "    npm install -D @playwright/test"
              ;;
          esac
          warnings=$((warnings + 1))
        else
          echo -e "${GREEN}✓${NC} Web app has E2E testing setup ($E2E_FRAMEWORK)"
        fi
      fi
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

cmd_cost() {
  local prd_path="$1"

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

  local feature_name=$(jq -r '.featureName // "Unknown"' "$prd_path")
  local total_tasks=$(jq '.tasks | length' "$prd_path")
  local completed_tasks=$(jq '[.tasks[] | select(.passes == true)] | length' "$prd_path")

  # Aggregate durations by worker tier from taskHistory
  # Each entry has: taskId, worker, status, timestamp, and optionally duration
  local line_duration=0
  local sous_duration=0
  local exec_duration=0
  local line_tasks=0
  local sous_tasks=0
  local exec_tasks=0

  # Parse taskHistory to sum durations by worker
  # Look for entries with status "complete" and a duration field
  while IFS='|' read -r worker duration; do
    [ -z "$worker" ] && continue
    local dur=${duration:-0}

    case "$worker" in
      line)
        line_duration=$((line_duration + dur))
        ((line_tasks++))
        ;;
      sous)
        sous_duration=$((sous_duration + dur))
        ((sous_tasks++))
        ;;
      executive)
        exec_duration=$((exec_duration + dur))
        ((exec_tasks++))
        ;;
    esac
  done < <(jq -r '.taskHistory[]? | select(.status == "complete" and .duration) | "\(.worker)|\(.duration)"' "$state_path" 2>/dev/null)

  # Calculate costs
  local line_cost=$(calculate_task_cost "$line_duration" "line")
  local sous_cost=$(calculate_task_cost "$sous_duration" "sous")
  local exec_cost=$(calculate_task_cost "$exec_duration" "executive")

  # Total cost (use bc for floating point addition)
  local total_cost=$(echo "$line_cost + $sous_cost + $exec_cost" | bc)
  local total_duration=$((line_duration + sous_duration + exec_duration))

  # Get PRD prefix for display
  local prd_prefix=$(get_prd_prefix "$prd_path")

  # Output report
  echo ""
  echo -e "${BOLD}Cost Summary: ${prd_prefix}${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "Feature:   ${CYAN}$feature_name${NC}"
  echo -e "Tasks:     $completed_tasks/$total_tasks complete"
  echo -e "Duration:  $(format_duration_hms $total_duration)"
  echo -e "Estimated: ${GREEN}$(format_cost $total_cost)${NC}"
  echo ""
  echo "By Worker:"

  if [ "$line_tasks" -gt 0 ]; then
    echo -e "  Line Cook:      $(format_cost $line_cost)  ($line_tasks tasks, $(format_duration_hms $line_duration))"
  else
    echo -e "  Line Cook:      \$0.00  (0 tasks)"
  fi

  if [ "$sous_tasks" -gt 0 ]; then
    echo -e "  Sous Chef:      $(format_cost $sous_cost)  ($sous_tasks tasks, $(format_duration_hms $sous_duration))"
  else
    echo -e "  Sous Chef:      \$0.00  (0 tasks)"
  fi

  if [ "$exec_tasks" -gt 0 ]; then
    echo -e "  Executive Chef: $(format_cost $exec_cost)  ($exec_tasks tasks, $(format_duration_hms $exec_duration))"
  else
    echo -e "  Executive Chef: \$0.00  (0 tasks)"
  fi

  echo ""
  echo -e "${GRAY}Note: Estimates based on configured rates (\$${COST_RATE_LINE}/min line, \$${COST_RATE_SOUS}/min sous, \$${COST_RATE_EXECUTIVE}/min exec).${NC}"
  echo -e "${GRAY}      Actual costs depend on your provider. Configure rates in brigade.config.${NC}"

  # Warn if threshold exceeded
  if [ -n "$COST_WARN_THRESHOLD" ]; then
    if (( $(echo "$total_cost > $COST_WARN_THRESHOLD" | bc -l) )); then
      echo ""
      echo -e "${YELLOW}⚠️  Cost exceeds threshold (\$${COST_WARN_THRESHOLD})${NC}"
    fi
  fi

  # If no duration data found, explain why
  if [ "$total_duration" -eq 0 ]; then
    echo ""
    echo -e "${YELLOW}No duration data found.${NC}"
    echo -e "${GRAY}Duration tracking was added recently. Re-run tasks to collect cost data.${NC}"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# RISK ASSESSMENT COMMAND
# ═══════════════════════════════════════════════════════════════════════════════

cmd_risk() {
  local include_history=false
  local prd_path=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --history|-h)
        include_history=true
        shift
        ;;
      *)
        if [ -z "$prd_path" ]; then
          prd_path="$1"
        fi
        shift
        ;;
    esac
  done

  # Default to latest PRD
  if [ -z "$prd_path" ]; then
    prd_path=$(find_active_prd)
    if [ -z "$prd_path" ]; then
      prd_path="brigade/tasks/latest.json"
    fi
  fi

  # Validate PRD exists
  if [ ! -f "$prd_path" ]; then
    echo -e "${RED}PRD not found: $prd_path${NC}"
    exit 1
  fi

  local feature_name=$(jq -r '.featureName // "Unknown"' "$prd_path")
  local prd_prefix=$(get_prd_prefix "$prd_path")
  local total_score=$(calculate_prd_risk "$prd_path")
  local level=$(get_risk_level "$total_score")

  # Color based on level
  local level_color="$GREEN"
  case "$level" in
    MEDIUM) level_color="$YELLOW" ;;
    HIGH) level_color="$YELLOW" ;;
    CRITICAL) level_color="$RED" ;;
  esac

  echo ""
  echo -e "${BOLD}Risk Assessment: $prd_prefix${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "Feature: $feature_name"
  echo ""
  echo -e "Overall Risk: ${level_color}$level${NC} (score: $total_score)"
  echo ""
  echo -e "${BOLD}Task Risk Breakdown:${NC}"
  echo ""

  # Header
  printf "  ${GRAY}%-10s %-45s %5s  %-s${NC}\n" "Task" "Title" "Score" "Factors"
  printf "  ${GRAY}%-10s %-45s %5s  %-s${NC}\n" "────" "─────" "─────" "───────"

  # Task rows
  local all_ids=$(jq -r '.tasks[].id' "$prd_path")
  local flagged_tasks=""

  for task_id in $all_ids; do
    local title=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .title // ""' "$prd_path")
    local task_score=$(calculate_task_risk "$prd_path" "$task_id")
    local factors=$(get_task_risk_factors "$prd_path" "$task_id")

    # Truncate title if too long
    if [ ${#title} -gt 42 ]; then
      title="${title:0:39}..."
    fi

    # Color high-risk tasks
    local score_color=""
    if [ "$task_score" -ge 5 ]; then
      score_color="$YELLOW"
      flagged_tasks="$flagged_tasks $task_id"
    elif [ "$task_score" -ge 3 ]; then
      score_color="$YELLOW"
      flagged_tasks="$flagged_tasks $task_id"
    fi

    if [ -n "$score_color" ]; then
      printf "  ${score_color}%-10s %-45s %5s${NC}  %s\n" "$task_id" "$title" "$task_score" "$factors"
    else
      printf "  %-10s %-45s %5s  %s\n" "$task_id" "$title" "$task_score" "$factors"
    fi
  done

  # Flagged tasks detail
  flagged_tasks=$(echo "$flagged_tasks" | xargs)
  if [ -n "$flagged_tasks" ]; then
    echo ""
    echo -e "${BOLD}Flagged Tasks (require attention):${NC}"
    for task_id in $flagged_tasks; do
      local title=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .title // ""' "$prd_path")
      local factors=$(get_task_risk_factors "$prd_path" "$task_id")
      echo -e "  ${YELLOW}⚠ $task_id: $title${NC}"
      # Print each factor on its own line (split on ", ")
      echo "$factors" | tr ',' '\n' | while read -r factor; do
        factor=$(echo "$factor" | sed 's/^[[:space:]]*//')
        [ -n "$factor" ] && echo -e "    ${GRAY}• $factor${NC}"
      done
    done
  fi

  # Historical analysis
  if [ "$include_history" == "true" ]; then
    echo ""
    echo -e "${BOLD}Historical Escalation Patterns:${NC}"
    local prd_dir=$(dirname "$prd_path")
    local history=$(analyze_historical_escalations "$prd_dir")
    local total_esc=$(echo "$history" | jq '.total')

    if [ "$total_esc" -eq 0 ]; then
      echo -e "  ${GRAY}No historical escalation data available.${NC}"
    else
      local auth_esc=$(echo "$history" | jq '.patterns.auth')
      local payment_esc=$(echo "$history" | jq '.patterns.payment')
      local integration_esc=$(echo "$history" | jq '.patterns.integration')
      local data_esc=$(echo "$history" | jq '.patterns.data')
      local other_esc=$(echo "$history" | jq '.patterns.other')

      echo -e "  Total escalations: $total_esc"
      [ "$auth_esc" -gt 0 ] && echo -e "  ${YELLOW}⚠ Auth tasks: $auth_esc escalations${NC}"
      [ "$payment_esc" -gt 0 ] && echo -e "  ${YELLOW}⚠ Payment tasks: $payment_esc escalations${NC}"
      [ "$integration_esc" -gt 0 ] && echo -e "  ${YELLOW}⚠ Integration tasks: $integration_esc escalations${NC}"
      [ "$data_esc" -gt 0 ] && echo -e "  ${YELLOW}⚠ Data tasks: $data_esc escalations${NC}"
      [ "$other_esc" -gt 0 ] && echo -e "  ${GRAY}Other: $other_esc escalations${NC}"
    fi
  fi

  # Recommendations
  echo ""
  echo -e "${BOLD}Recommendations:${NC}"
  case "$level" in
    LOW)
      echo -e "  ${GREEN}✓ Low risk. Straightforward execution expected.${NC}"
      ;;
    MEDIUM)
      echo -e "  ${YELLOW}⚠ Some complexity detected.${NC}"
      echo -e "  ${GRAY}Consider: monitoring flagged tasks during execution.${NC}"
      ;;
    HIGH)
      echo -e "  ${YELLOW}⚠ Significant complexity detected.${NC}"
      echo -e "  ${GRAY}Consider: review flagged tasks, ensure integration tests.${NC}"
      ;;
    CRITICAL)
      echo -e "  ${RED}⚠ Complex PRD with multiple risk factors.${NC}"
      echo -e "  ${GRAY}Recommend: attended execution, consider breaking into smaller PRDs.${NC}"
      ;;
  esac

  echo ""
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

cmd_explore() {
  local question="$*"

  if [ -z "$question" ]; then
    echo -e "${RED}Error: Please provide a question to explore${NC}"
    echo "Usage: ./brigade.sh explore \"question\""
    echo ""
    echo "Examples:"
    echo "  ./brigade.sh explore \"could we add real-time sync with websockets?\""
    echo "  ./brigade.sh explore \"is it possible to support offline mode?\""
    exit 1
  fi

  # Ensure explorations directory exists
  mkdir -p "brigade/explorations"

  # Generate filename from question
  local date_prefix=$(date +%Y-%m-%d)
  local slug=$(echo "$question" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | cut -c1-40 | sed 's/-$//')
  local output_file="brigade/explorations/${date_prefix}-${slug}.md"

  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  log_event "START" "EXPLORATION: $question"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo ""

  # Load researcher prompt
  local researcher_prompt="$CHEF_DIR/researcher.md"
  if [ ! -f "$researcher_prompt" ]; then
    echo -e "${RED}Error: Researcher prompt not found: $researcher_prompt${NC}"
    exit 1
  fi

  # Build exploration prompt
  local prompt=""
  prompt+="$(cat "$researcher_prompt")"
  prompt+=$'\n\n'
  prompt+="---"$'\n'

  # Include codebase map if available
  if [ -f "brigade/codebase-map.md" ]; then
    prompt+="CODEBASE CONTEXT"$'\n\n'
    prompt+="$(cat brigade/codebase-map.md)"
    prompt+=$'\n\n'
    prompt+="---"$'\n'
  else
    echo -e "${GRAY}Tip: Run './brigade.sh map' first to include codebase context in exploration.${NC}"
    echo ""
  fi

  prompt+="EXPLORATION REQUEST"$'\n\n'
  prompt+="Question: $question"$'\n'
  prompt+="Output File: $output_file"$'\n'
  prompt+="Date: $(date +%Y-%m-%d)"$'\n\n'
  prompt+="Research this question and save your findings to the output file."$'\n'
  prompt+="When complete, output: <exploration_complete>$output_file</exploration_complete>"$'\n\n'
  prompt+="BEGIN RESEARCH:"

  local temp_output=$(brigade_mktemp)
  local start_time=$(date +%s)

  echo -e "${GRAY}Invoking Researcher (Executive model)...${NC}"
  echo ""

  # Run with Executive (uses same model, different prompt)
  if $EXECUTIVE_CMD --dangerously-skip-permissions -p "$prompt" 2>&1 | tee "$temp_output"; then
    : # Success
  fi

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))
  echo ""
  echo -e "${GRAY}Duration: ${duration}s${NC}"

  # Check for completion signal
  if grep -q "<exploration_complete>" "$temp_output" 2>/dev/null; then
    local result_file=$(sed -n 's/.*<exploration_complete>\(.*\)<\/exploration_complete>.*/\1/p' "$temp_output" | head -1)

    if [ -n "$result_file" ] && [ -f "$result_file" ]; then
      echo ""
      echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
      log_event "SUCCESS" "EXPLORATION COMPLETE: $result_file (${duration}s)"
      echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
      echo ""
      echo -e "${BOLD}Next steps:${NC}"
      echo -e "  View report:    ${CYAN}cat $result_file${NC}"
      echo -e "  Plan feature:   ${CYAN}./brigade.sh plan \"[feature description]\"${NC}"
    else
      echo ""
      echo -e "${YELLOW}Exploration signal received but file not found: $result_file${NC}"
    fi
  elif [ -f "$output_file" ]; then
    # File exists but no signal - still consider it a success
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    log_event "SUCCESS" "EXPLORATION COMPLETE: $output_file (${duration}s)"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}Next steps:${NC}"
    echo -e "  View report:    ${CYAN}cat $output_file${NC}"
    echo -e "  Plan feature:   ${CYAN}./brigade.sh plan \"[feature description]\"${NC}"
  else
    echo ""
    echo -e "${YELLOW}Exploration output:${NC}"
    echo -e "${GRAY}(No output file generated - see above for results)${NC}"
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
# ITERATION MODE
# ═══════════════════════════════════════════════════════════════════════════════

# Find the most recently completed PRD (all tasks pass, has state file)
find_completed_prd() {
  local latest_prd=""
  local latest_time=0

  for state_file in brigade/tasks/prd-*.state.json; do
    [ ! -f "$state_file" ] && continue

    # Get corresponding PRD file
    local prd_file="${state_file%.state.json}.json"
    [ ! -f "$prd_file" ] && continue

    # Check if all tasks are complete
    local pending=$(jq '[.tasks[] | select(.passes == false)] | length' "$prd_file" 2>/dev/null)
    [ "$pending" != "0" ] && continue

    # Get modification time of state file
    local mtime=$(stat -f "%m" "$state_file" 2>/dev/null || stat -c "%Y" "$state_file" 2>/dev/null)
    if [ -n "$mtime" ] && [ "$mtime" -gt "$latest_time" ]; then
      latest_time="$mtime"
      latest_prd="$prd_file"
    fi
  done

  echo "$latest_prd"
}

# Check if description sounds like a substantial change (vs. a tweak)
is_substantial_change() {
  local description="$1"
  local desc_lower=$(echo "$description" | tr '[:upper:]' '[:lower:]')

  # Keywords that suggest substantial work
  local substantial_keywords="add new|implement|create|refactor|rewrite|redesign|overhaul|migrate|integrate"
  if echo "$desc_lower" | grep -qE "$substantial_keywords"; then
    return 0  # Substantial
  fi

  # Word count heuristic
  local word_count=$(echo "$description" | wc -w | tr -d ' ')
  if [ "$word_count" -gt 15 ]; then
    return 0  # Substantial
  fi

  return 1  # Tweak
}

cmd_iterate() {
  local description="${1:-}"

  if [ -z "$description" ]; then
    echo -e "${RED}Error: Missing iteration description${NC}"
    echo ""
    echo "Usage: ./brigade.sh iterate \"description of tweak\""
    echo ""
    echo "Examples:"
    echo "  ./brigade.sh iterate \"make the button blue instead of green\""
    echo "  ./brigade.sh iterate \"fix typo in error message\""
    exit 1
  fi

  # Find most recently completed PRD
  local parent_prd=$(find_completed_prd)

  if [ -z "$parent_prd" ]; then
    echo -e "${RED}Error: No completed PRD found${NC}"
    echo ""
    echo -e "${GRAY}Iteration mode requires a completed PRD to iterate on.${NC}"
    echo -e "${GRAY}Run './brigade.sh service prd.json' first to complete a PRD.${NC}"
    exit 1
  fi

  local parent_name=$(jq -r '.featureName // "Unknown"' "$parent_prd")
  local parent_branch=$(jq -r '.branchName // ""' "$parent_prd")

  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  ITERATION MODE                                           ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}Parent PRD:${NC} $parent_name"
  echo -e "${GRAY}$parent_prd${NC}"
  echo ""
  echo -e "${BOLD}Tweak:${NC} $description"
  echo ""

  # Warn if this looks substantial
  if is_substantial_change "$description"; then
    echo -e "${YELLOW}⚠ This description sounds substantial.${NC}"
    echo -e "${GRAY}Iteration mode is for quick tweaks. For larger changes, consider:${NC}"
    echo -e "${GRAY}  ./brigade.sh plan \"$description\"${NC}"
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo -e "${GRAY}Aborted.${NC}"
      exit 0
    fi
    echo ""
  fi

  # Generate iteration PRD
  local timestamp=$(date +%s)
  local parent_prefix=$(get_prd_prefix "$parent_prd")
  local iter_prd="brigade/tasks/prd-${parent_prefix}-iter-${timestamp}.json"

  # Create minimal iteration PRD
  cat > "$iter_prd" << EOF
{
  "featureName": "Iteration: $description",
  "branchName": "$parent_branch",
  "iteration": true,
  "parentPrd": "$parent_prd",
  "tasks": [
    {
      "id": "ITER-001",
      "title": "$description",
      "acceptanceCriteria": ["Change implemented as described"],
      "dependsOn": [],
      "complexity": "junior",
      "passes": false
    }
  ]
}
EOF

  echo -e "${GREEN}✓${NC} Created iteration PRD: $iter_prd"
  echo ""

  # Set parent context for worker
  export ITERATION_PARENT_PRD="$parent_prd"

  # Execute the iteration task
  log_event "START" "Iteration task"

  # Run the ticket directly
  if cmd_ticket "$iter_prd" "ITER-001"; then
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    log_event "SUCCESS" "Iteration complete"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Offer to clean up
    read -p "Remove iteration PRD? (Y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      rm -f "$iter_prd"
      rm -f "${iter_prd%.json}.state.json"
      echo -e "${GREEN}✓${NC} Cleaned up iteration files"
    else
      echo -e "${GRAY}Kept: $iter_prd${NC}"
    fi
  else
    echo ""
    echo -e "${YELLOW}Iteration task did not complete successfully.${NC}"
    echo -e "${GRAY}PRD preserved: $iter_prd${NC}"
    echo -e "${GRAY}Resume with: ./brigade.sh resume $iter_prd${NC}"
    exit 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# PRD TEMPLATES
# ═══════════════════════════════════════════════════════════════════════════════

# Convert string to capitalized (first letter uppercase)
to_capitalized() {
  local str="$1"
  echo "$(echo "${str:0:1}" | tr '[:lower:]' '[:upper:]')${str:1}"
}

# Convert string to uppercase
to_uppercase() {
  echo "$1" | tr '[:lower:]' '[:upper:]'
}

# Simple singularization (handles common cases)
to_singular() {
  local str="$1"
  # Handle common plural endings
  if [[ "$str" =~ ies$ ]]; then
    echo "${str%ies}y"
  elif [[ "$str" =~ es$ ]] && [[ "$str" =~ [sx]es$ ]]; then
    echo "${str%es}"
  elif [[ "$str" =~ s$ ]] && [[ ! "$str" =~ ss$ ]]; then
    echo "${str%s}"
  else
    echo "$str"
  fi
}

# Find template file (project templates take precedence over built-in)
find_template() {
  local name="$1"

  # Check project templates first
  if [ -f "brigade/templates/${name}.json" ]; then
    echo "brigade/templates/${name}.json"
    return 0
  fi

  # Check built-in templates
  if [ -f "$SCRIPT_DIR/templates/${name}.json" ]; then
    echo "$SCRIPT_DIR/templates/${name}.json"
    return 0
  fi

  return 1
}

# Check if template requires a resource name (has {{name}} placeholders)
template_requires_resource() {
  local template_file="$1"
  grep -q '{{name}}' "$template_file" 2>/dev/null
}

# Get template description from first line comment or featureName
get_template_description() {
  local template_file="$1"
  # Try to extract from description field, fall back to featureName
  local desc=$(jq -r '.description // .featureName // "No description"' "$template_file" 2>/dev/null)
  # Remove placeholders for display
  echo "$desc" | sed 's/{{[^}]*}}/X/g'
}

# List all available templates
list_templates() {
  echo -e "${BOLD}Available Templates${NC}"
  echo ""

  local found=false

  # List project templates
  if [ -d "brigade/templates" ] && [ "$(ls -A brigade/templates/*.json 2>/dev/null)" ]; then
    echo -e "${CYAN}Project templates (brigade/templates/):${NC}"
    for template in brigade/templates/*.json; do
      local name=$(basename "$template" .json)
      local desc=$(get_template_description "$template")
      local resource_note=""
      template_requires_resource "$template" && resource_note=" ${GRAY}(requires resource name)${NC}"
      echo -e "  ${GREEN}$name${NC} - $desc$resource_note"
    done
    echo ""
    found=true
  fi

  # List built-in templates
  if [ -d "$SCRIPT_DIR/templates" ] && [ "$(ls -A "$SCRIPT_DIR/templates"/*.json 2>/dev/null)" ]; then
    echo -e "${CYAN}Built-in templates:${NC}"
    for template in "$SCRIPT_DIR/templates"/*.json; do
      local name=$(basename "$template" .json)
      # Skip if overridden by project template
      if [ -f "brigade/templates/${name}.json" ]; then
        continue
      fi
      local desc=$(get_template_description "$template")
      local resource_note=""
      template_requires_resource "$template" && resource_note=" ${GRAY}(requires resource name)${NC}"
      echo -e "  ${GREEN}$name${NC} - $desc$resource_note"
    done
    echo ""
    found=true
  fi

  if [ "$found" != "true" ]; then
    echo -e "${YELLOW}No templates found.${NC}"
    echo ""
    echo -e "Create templates in ${CYAN}brigade/templates/${NC} or ${CYAN}$SCRIPT_DIR/templates/${NC}"
  fi

  echo -e "${GRAY}Usage: ./brigade.sh template <name> [resource_name]${NC}"
}

# Interpolate template with resource name
interpolate_template() {
  local template_file="$1"
  local resource="$2"

  local content=$(cat "$template_file")

  if [ -n "$resource" ]; then
    local name="$resource"
    local Name=$(to_capitalized "$resource")
    local NAME=$(to_uppercase "$resource")
    local name_singular=$(to_singular "$resource")
    local Name_singular=$(to_capitalized "$name_singular")

    # Replace all placeholder variants
    content=$(echo "$content" | sed "s/{{name}}/$name/g")
    content=$(echo "$content" | sed "s/{{Name}}/$Name/g")
    content=$(echo "$content" | sed "s/{{NAME}}/$NAME/g")
    content=$(echo "$content" | sed "s/{{name_singular}}/$name_singular/g")
    content=$(echo "$content" | sed "s/{{Name_singular}}/$Name_singular/g")
  fi

  echo "$content"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ONBOARDING COMMANDS
# ═══════════════════════════════════════════════════════════════════════════════

# Interactive setup wizard for new users
cmd_init() {
  echo ""
  echo -e "🍳 ${BOLD}Welcome to Brigade Kitchen Setup!${NC}"
  echo ""
  echo "Let's get your kitchen ready for cooking."
  echo ""

  # Check for Claude CLI
  echo -e "${BOLD}Step 1: Checking for AI tools...${NC}"
  local claude_found=false
  local opencode_found=false

  if command -v claude &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Claude CLI found"
    claude_found=true
  else
    echo -e "  ${YELLOW}○${NC} Claude CLI not found"
  fi

  if command -v opencode &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} OpenCode CLI found"
    opencode_found=true
  else
    echo -e "  ${GRAY}○${NC} OpenCode CLI not found (optional - for cost savings)"
  fi

  echo ""

  if [ "$claude_found" != "true" ] && [ "$opencode_found" != "true" ]; then
    echo -e "${RED}No AI tools found!${NC}"
    echo ""
    echo "Brigade needs at least one AI CLI tool to work."
    echo ""
    echo "Install Claude CLI:"
    echo -e "  ${CYAN}npm install -g @anthropic-ai/claude-code${NC}"
    echo ""
    echo "Or OpenCode:"
    echo -e "  ${CYAN}go install github.com/sst/opencode@latest${NC}"
    echo ""
    return 1
  fi

  # Create config file
  echo -e "${BOLD}Step 2: Creating configuration...${NC}"

  if [ -f "brigade.config" ]; then
    echo -e "  ${YELLOW}!${NC} brigade.config already exists"
    read -p "  Overwrite? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo -e "  ${GRAY}Keeping existing config.${NC}"
    else
      create_default_config
    fi
  else
    create_default_config
  fi

  # Create directories
  echo ""
  echo -e "${BOLD}Step 3: Setting up directories...${NC}"
  mkdir -p brigade/tasks
  mkdir -p brigade/notes
  mkdir -p brigade/logs
  echo -e "  ${GREEN}✓${NC} Created brigade/tasks/"
  echo -e "  ${GREEN}✓${NC} Created brigade/notes/"
  echo -e "  ${GREEN}✓${NC} Created brigade/logs/"

  # Check/update .gitignore
  echo ""
  echo -e "${BOLD}Step 4: Checking .gitignore...${NC}"

  if [ -f ".gitignore" ]; then
    # Check if brigade/ is already ignored
    if grep -q "^brigade/" .gitignore 2>/dev/null || grep -q "^brigade$" .gitignore 2>/dev/null; then
      echo -e "  ${GREEN}✓${NC} brigade/ already in .gitignore"
    else
      echo -e "  ${YELLOW}!${NC} brigade/ not in .gitignore"
      echo ""
      echo "  The brigade/ directory contains working files (PRDs, state, logs)"
      echo "  that shouldn't be committed to your repo."
      echo ""
      read -p "  Add 'brigade/' to .gitignore? (Y/n) " -n 1 -r
      echo ""
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo "" >> .gitignore
        echo "# Brigade working directory" >> .gitignore
        echo "brigade/" >> .gitignore
        echo -e "  ${GREEN}✓${NC} Added brigade/ to .gitignore"
      else
        echo -e "  ${YELLOW}!${NC} Skipped. Remember to add manually:"
        echo -e "      ${CYAN}echo 'brigade/' >> .gitignore${NC}"
      fi
    fi
  else
    echo -e "  ${YELLOW}!${NC} No .gitignore found"
    echo ""
    read -p "  Create .gitignore with brigade/? (Y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      echo "# Brigade working directory" > .gitignore
      echo "brigade/" >> .gitignore
      echo -e "  ${GREEN}✓${NC} Created .gitignore with brigade/"
    else
      echo -e "  ${YELLOW}!${NC} Skipped. Remember to add manually:"
      echo -e "      ${CYAN}echo 'brigade/' >> .gitignore${NC}"
    fi
  fi

  # Final message
  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║              🍳 Kitchen is ready to cook! 🍳              ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo "Next steps:"
  echo ""
  echo -e "  Try a demo:    ${CYAN}./brigade.sh demo${NC}"
  echo -e "  Plan a feature: ${CYAN}./brigade.sh plan \"Add user login\"${NC}"
  echo ""
}

# Helper function to create default config
create_default_config() {
  cat > brigade.config << 'EOF'
# Brigade Kitchen Configuration
# See brigade.config.example for all options

# Quiet mode: suppress worker conversation output
QUIET_WORKERS=false

# Executive review: have Opus review completed work
REVIEW_ENABLED=true

# Escalation: promote tasks to higher tiers on failure
ESCALATION_ENABLED=true
ESCALATION_AFTER=3
EOF
  echo -e "  ${GREEN}✓${NC} Created brigade.config"
}

# Demo command: show what Brigade can do without actually running
cmd_demo() {
  echo ""
  echo -e "🍳 ${BOLD}Brigade Kitchen Demo${NC}"
  echo ""
  echo "Let's see how Brigade would cook up a feature!"
  echo ""

  # Check for example PRD
  local example_prd=""
  if [ -f "examples/prd-example.json" ]; then
    example_prd="examples/prd-example.json"
  elif [ -f "$SCRIPT_DIR/examples/prd-example.json" ]; then
    example_prd="$SCRIPT_DIR/examples/prd-example.json"
  fi

  if [ -z "$example_prd" ]; then
    echo -e "${YELLOW}Demo PRD not found.${NC}"
    echo ""
    echo "Let's create a simple one for the demo..."
    echo ""

    # Create a minimal demo PRD
    mkdir -p brigade/tasks
    cat > brigade/tasks/prd-demo.json << 'EOF'
{
  "featureName": "Hello World Demo",
  "branchName": "demo/hello-world",
  "tasks": [
    {
      "id": "US-001",
      "title": "Create greeting function",
      "acceptanceCriteria": ["Function returns 'Hello, World!'"],
      "dependsOn": [],
      "complexity": "junior",
      "passes": false
    },
    {
      "id": "US-002",
      "title": "Add tests for greeting",
      "acceptanceCriteria": ["Test verifies greeting output"],
      "dependsOn": ["US-001"],
      "complexity": "junior",
      "passes": false
    }
  ]
}
EOF
    example_prd="brigade/tasks/prd-demo.json"
    echo -e "${GREEN}✓${NC} Created demo PRD: $example_prd"
    echo ""
  fi

  local feature_name=$(jq -r '.featureName' "$example_prd")
  local task_count=$(jq '.tasks | length' "$example_prd")

  echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  Demo: $feature_name"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  echo -e "📋 ${BOLD}Tonight's menu:${NC} $task_count dishes"
  echo ""

  # Show tasks
  local tasks=$(jq -r '.tasks[] | "\(.id)|\(.title)|\(.complexity)"' "$example_prd")
  while IFS='|' read -r id title complexity; do
    local chef_emoji="🔪"
    local chef_name="Line Cook"
    if [ "$complexity" == "senior" ]; then
      chef_emoji="👨‍🍳"
      chef_name="Sous Chef"
    fi
    echo -e "  $chef_emoji $id: $title ${GRAY}($chef_name)${NC}"
  done <<< "$tasks"

  echo ""
  echo -e "${BOLD}How it works:${NC}"
  echo ""
  echo "  1. 🔪 Line Cook handles simple tasks (tests, CRUD, boilerplate)"
  echo "  2. 👨‍🍳 Sous Chef handles complex tasks (architecture, security)"
  echo "  3. 👔 Executive Chef reviews work and handles escalations"
  echo ""
  echo "  If a chef struggles, the task escalates to a more senior chef."
  echo ""

  echo -e "${BOLD}Running in dry-run mode...${NC}"
  echo ""

  # Run dry-run service
  DRY_RUN=true cmd_service "$example_prd"

  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║                   Demo Complete!                          ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo "Ready to cook for real? Try:"
  echo ""
  echo -e "  Plan a feature:  ${CYAN}./brigade.sh plan \"your feature idea\"${NC}"
  echo -e "  Run the example: ${CYAN}./brigade.sh service $example_prd${NC}"
  echo ""
}

cmd_supervise() {
  local supervisor_md="$SCRIPT_DIR/chef/supervisor.md"

  echo -e "🧑‍🍳 ${BOLD}Supervisor Mode${NC}"
  echo ""

  if [ -f "$supervisor_md" ]; then
    echo "Full supervisor instructions: $supervisor_md"
    echo ""
  fi

  echo -e "${BOLD}Quick Reference:${NC}"
  echo ""
  echo "  Status check:     ./brigade.sh status --brief"
  echo "  Detailed status:  ./brigade.sh status --json"
  echo "  Watch events:     tail -f brigade/tasks/events.jsonl"
  echo ""
  echo -e "${BOLD}Intervene via cmd.json:${NC}"
  echo ""
  echo "  Write to: brigade/tasks/cmd.json"
  echo ""
  echo "  Actions:"
  echo "    retry  - Try again (add 'guidance' field to help worker)"
  echo "    skip   - Move on to next task"
  echo "    abort  - Stop everything"
  echo "    pause  - Stop and wait for investigation"
  echo ""
  echo "  Example:"
  echo '    {"decision":"d-123","action":"retry","guidance":"Check the OpenAPI spec"}'
  echo ""
  echo -e "${BOLD}When to intervene:${NC}"
  echo ""
  echo "  ✓ 'attention' events - Brigade needs you"
  echo "  ✓ 'decision_needed' - Waiting for your input"
  echo "  ✓ Multiple failures on same task"
  echo "  ✗ Normal task_start/task_complete - let it run"
  echo "  ✗ Single escalation - that's normal"
  echo ""

  if [ -f "$supervisor_md" ]; then
    echo -e "For complete documentation: ${CYAN}cat $supervisor_md${NC}"
  fi
}

cmd_template() {
  local template_name="${1:-}"
  local resource_name="${2:-}"

  # No args = list templates
  if [ -z "$template_name" ]; then
    list_templates
    return 0
  fi

  # Find template file
  local template_file=$(find_template "$template_name")
  if [ -z "$template_file" ]; then
    echo -e "${RED}Error: Template not found: $template_name${NC}"
    echo ""
    list_templates
    exit 1
  fi

  # Check if resource name is required
  if template_requires_resource "$template_file" && [ -z "$resource_name" ]; then
    echo -e "${RED}Error: Template '$template_name' requires a resource name${NC}"
    echo ""
    echo -e "Usage: ${CYAN}./brigade.sh template $template_name <resource_name>${NC}"
    echo ""
    echo "Examples:"
    echo "  ./brigade.sh template $template_name users"
    echo "  ./brigade.sh template $template_name products"
    echo "  ./brigade.sh template $template_name orders"
    exit 1
  fi

  # Determine output filename
  local output_name="${resource_name:-$template_name}"
  local output_path="brigade/tasks/prd-${output_name}.json"

  # Check if output already exists
  if [ -f "$output_path" ]; then
    echo -e "${YELLOW}Warning: $output_path already exists${NC}"
    read -p "Overwrite? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo -e "${GRAY}Aborted.${NC}"
      exit 0
    fi
  fi

  # Ensure output directory exists
  mkdir -p "$(dirname "$output_path")"

  # Generate PRD from template
  interpolate_template "$template_file" "$resource_name" > "$output_path"

  # Validate the generated PRD
  if ! jq empty "$output_path" 2>/dev/null; then
    echo -e "${RED}Error: Generated invalid JSON. Template may have syntax errors.${NC}"
    rm -f "$output_path"
    exit 1
  fi

  local feature_name=$(jq -r '.featureName' "$output_path")
  local task_count=$(jq '.tasks | length' "$output_path")

  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║  PRD GENERATED FROM TEMPLATE                              ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}Feature:${NC}  $feature_name"
  echo -e "${BOLD}Template:${NC} $template_name"
  echo -e "${BOLD}Tasks:${NC}    $task_count"
  echo -e "${BOLD}Output:${NC}   $output_path"
  echo ""
  echo -e "${GRAY}Next steps:${NC}"
  echo -e "  Review:   ${CYAN}cat $output_path | jq${NC}"
  echo -e "  Validate: ${CYAN}./brigade.sh validate $output_path${NC}"
  echo -e "  Execute:  ${CYAN}./brigade.sh service $output_path${NC}"
  echo -e "  Dry-run:  ${CYAN}./brigade.sh --dry-run service $output_path${NC}"
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
      --only)
        FILTER_ONLY="$2"
        shift 2
        ;;
      --skip)
        FILTER_SKIP="$2"
        shift 2
        ;;
      --from)
        FILTER_FROM="$2"
        shift 2
        ;;
      --until)
        FILTER_UNTIL="$2"
        shift 2
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
    "cost")
      cmd_cost "$@"
      ;;
    "risk")
      cmd_risk "$@"
      ;;
    "map")
      cmd_map "$@"
      ;;
    "explore")
      cmd_explore "$@"
      ;;
    "iterate")
      cmd_iterate "$@"
      ;;
    "template")
      cmd_template "$@"
      ;;
    "opencode-models")
      cmd_opencode_models "$@"
      ;;
    "init")
      cmd_init "$@"
      ;;
    "demo")
      cmd_demo "$@"
      ;;
    "supervise")
      cmd_supervise "$@"
      ;;
    "help"|"--help"|"-h")
      # Check for --all flag for full help
      if [ "${1:-}" == "--all" ]; then
        print_usage_full
      else
        print_usage
      fi
      ;;
    "")
      # Empty command: check for first-run scenario
      if [ ! -d "brigade/tasks" ] && [ ! -f "brigade.config" ]; then
        print_welcome
      else
        print_usage
      fi
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
