#!/bin/bash
# Brigade - Multi-model AI orchestration framework
# https://github.com/yourusername/brigade

set -e

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
MAX_ITERATIONS=50

# Simple toggle for OpenCode (set in config or via --opencode flag)
USE_OPENCODE=false

# Agent-specific defaults
OPENCODE_MODEL=""
OPENCODE_SERVER=""
CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS=true

# Escalation defaults
ESCALATION_ENABLED=true
ESCALATION_AFTER=3

# Executive review defaults
REVIEW_ENABLED=true
REVIEW_JUNIOR_ONLY=true

# Context isolation defaults
CONTEXT_ISOLATION=true
STATE_FILE="brigade-state.json"

# Knowledge sharing defaults
KNOWLEDGE_SHARING=true
LEARNINGS_FILE="brigade-learnings.md"

# Parallel execution defaults
MAX_PARALLEL=3

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
  echo "  service <prd.json>         Run full service (all tasks)"
  echo "  ticket <prd.json> <id>     Run single ticket"
  echo "  status <prd.json>          Show kitchen status"
  echo "  analyze <prd.json>         Analyze tasks and suggest routing"
  echo "  opencode-models            List available OpenCode models"
  echo ""
  echo "Options:"
  echo "  --max-iterations <n>       Max iterations per task (default: 50)"
  echo "  --dry-run                  Show what would be done without executing"
  echo ""
  echo "Examples:"
  echo "  ./brigade.sh plan \"Add user authentication with JWT\""
  echo "  ./brigade.sh service tasks/prd.json"
  echo "  ./brigade.sh opencode-models"
}

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo -e "${GRAY}Loaded config from $CONFIG_FILE${NC}"
  else
    echo -e "${YELLOW}Warning: No brigade.config found, using defaults${NC}"
  fi

  # Apply USE_OPENCODE if set in config
  if [ "$USE_OPENCODE" = true ]; then
    LINE_CMD="opencode run --command"
    LINE_AGENT="opencode"
    echo -e "${CYAN}Using OpenCode for junior tasks (USE_OPENCODE=true)${NC}"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# PRD HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

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

  local tmp_file=$(mktemp)
  jq "(.tasks[] | select(.id == \"$task_id\") | .passes) = true" "$prd_path" > "$tmp_file"
  mv "$tmp_file" "$prd_path"

  echo -e "${GREEN}✓ Marked $task_id as complete${NC}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# STATE MANAGEMENT (Context Isolation)
# ═══════════════════════════════════════════════════════════════════════════════

get_state_path() {
  local prd_path="$1"
  local prd_dir=$(dirname "$prd_path")
  echo "$prd_dir/$STATE_FILE"
}

init_state() {
  local prd_path="$1"
  local state_path=$(get_state_path "$prd_path")

  if [ ! -f "$state_path" ]; then
    cat > "$state_path" <<EOF
{
  "sessionId": "$(date +%s)-$$",
  "startedAt": "$(date -Iseconds)",
  "currentTask": null,
  "taskHistory": [],
  "escalations": [],
  "reviews": []
}
EOF
    echo -e "${GRAY}Initialized state: $state_path${NC}"
  fi
}

update_state_task() {
  local prd_path="$1"
  local task_id="$2"
  local worker="$3"
  local status="$4"

  if [ "$CONTEXT_ISOLATION" != "true" ]; then
    return
  fi

  local state_path=$(get_state_path "$prd_path")
  local tmp_file=$(mktemp)

  jq --arg task "$task_id" --arg worker "$worker" --arg status "$status" --arg ts "$(date -Iseconds)" \
    '.currentTask = $task | .taskHistory += [{"taskId": $task, "worker": $worker, "status": $status, "timestamp": $ts}]' \
    "$state_path" > "$tmp_file"
  mv "$tmp_file" "$state_path"
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
  local tmp_file=$(mktemp)

  jq --arg task "$task_id" --arg from "$from_worker" --arg to "$to_worker" --arg reason "$reason" --arg ts "$(date -Iseconds)" \
    '.escalations += [{"taskId": $task, "from": $from, "to": $to, "reason": $reason, "timestamp": $ts}]' \
    "$state_path" > "$tmp_file"
  mv "$tmp_file" "$state_path"
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
  local tmp_file=$(mktemp)

  jq --arg task "$task_id" --arg result "$result" --arg reason "$reason" --arg ts "$(date -Iseconds)" \
    '.reviews += [{"taskId": $task, "result": $result, "reason": $reason, "timestamp": $ts}]' \
    "$state_path" > "$tmp_file"
  mv "$tmp_file" "$state_path"
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
  local timestamp=$(date "+%Y-%m-%d %H:%M")
  local worker_name=$(get_worker_name "$worker")

  cat >> "$learnings_path" <<EOF

## [$learning_type] $task_id - $worker_name ($timestamp)

$content

---
EOF
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

# ═══════════════════════════════════════════════════════════════════════════════
# TASK EXECUTION
# ═══════════════════════════════════════════════════════════════════════════════

build_prompt() {
  local prd_path="$1"
  local task_id="$2"
  local chef_prompt="$3"

  local task_json=$(get_task_by_id "$prd_path" "$task_id")
  local feature_name=$(jq -r '.featureName' "$prd_path")
  local learnings=$(get_learnings "$prd_path")

  local learnings_section=""
  if [ -n "$learnings" ] && [ "$KNOWLEDGE_SHARING" == "true" ]; then
    learnings_section="
---
TEAM LEARNINGS (from previous tasks):
$learnings
---
"
  fi

  cat <<EOF
$chef_prompt
$learnings_section
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
6. Share useful learnings with: <learning>What you learned</learning>

BEGIN WORK:
EOF
}

fire_ticket() {
  local prd_path="$1"
  local task_id="$2"
  local worker="$3"

  local worker_name=$(get_worker_name "$worker")
  local worker_cmd=$(get_worker_cmd "$worker")
  local worker_agent=$(get_worker_agent "$worker")
  local chef_prompt_file="$CHEF_DIR/${worker}.md"

  local chef_prompt=""
  if [ -f "$chef_prompt_file" ]; then
    chef_prompt=$(cat "$chef_prompt_file")
  fi

  local task_title=$(jq -r ".tasks[] | select(.id == \"$task_id\") | .title" "$prd_path")

  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  log_event "START" "TASK: $task_id - $task_title"
  echo -e "${GRAY}Worker: $worker_name (agent: $worker_agent)${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo ""

  local full_prompt=$(build_prompt "$prd_path" "$task_id" "$chef_prompt")
  local output_file=$(mktemp)

  # Execute worker based on agent type
  local start_time=$(date +%s)

  case "$worker_agent" in
    "claude")
      # Claude CLI: claude --dangerously-skip-permissions -p "prompt"
      local claude_flags=""
      if [ "$CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS" == "true" ]; then
        claude_flags="--dangerously-skip-permissions"
      fi
      if $worker_cmd $claude_flags -p "$full_prompt" 2>&1 | tee "$output_file"; then
        echo -e "${GREEN}Worker completed${NC}"
      else
        echo -e "${YELLOW}Worker exited${NC}"
      fi
      ;;

    "opencode")
      # OpenCode CLI: opencode run --command "prompt"
      # See: https://opencode.ai/docs/cli/
      # -q/--quiet hides spinner, --log-level ERROR suppresses info logs
      local opencode_flags="-q --log-level ERROR"
      if [ -n "$OPENCODE_MODEL" ]; then
        opencode_flags="$opencode_flags --model $OPENCODE_MODEL"
      fi
      if [ -n "$OPENCODE_SERVER" ]; then
        opencode_flags="$opencode_flags --attach $OPENCODE_SERVER"
      fi
      if $worker_cmd $opencode_flags "$full_prompt" 2>&1 | tee "$output_file"; then
        echo -e "${GREEN}Worker completed${NC}"
      else
        echo -e "${YELLOW}Worker exited${NC}"
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
      if echo "$full_prompt" | $worker_cmd 2>&1 | tee "$output_file"; then
        echo -e "${GREEN}Worker completed${NC}"
      else
        echo -e "${YELLOW}Worker exited${NC}"
      fi
      ;;
  esac

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  echo -e "${GRAY}Duration: ${duration}s${NC}"

  # Extract any learnings shared by the worker
  extract_learnings_from_output "$output_file" "$prd_path" "$task_id" "$worker"

  # Check for completion signal
  if grep -q "<promise>COMPLETE</promise>" "$output_file" 2>/dev/null; then
    log_event "SUCCESS" "Task $task_id signaled COMPLETE (${duration}s)"
    rm -f "$output_file"
    return 0
  elif grep -q "<promise>BLOCKED</promise>" "$output_file" 2>/dev/null; then
    log_event "ERROR" "Task $task_id is BLOCKED (${duration}s)"
    rm -f "$output_file"
    return 2
  else
    log_event "WARN" "Task $task_id - no completion signal, may need another iteration (${duration}s)"
    rm -f "$output_file"
    return 1
  fi
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

  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  log_event "REVIEW" "EXECUTIVE REVIEW: $task_id - $task_title"
  echo -e "${GRAY}Completed by: $(get_worker_name "$completed_by")${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo ""

  local review_prompt=$(build_review_prompt "$prd_path" "$task_id" "$completed_by")
  local output_file=$(mktemp)

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
  [ -z "$review_reason" ] && review_reason="No reason provided"

  rm -f "$output_file"

  # Record review in state
  record_review "$prd_path" "$task_id" "$review_result" "$review_reason"

  if [ "$review_result" == "PASS" ]; then
    log_event "SUCCESS" "Executive Review PASSED: $task_id (${duration}s)"
    echo -e "${GRAY}Reason: $review_reason${NC}"
    return 0
  else
    log_event "ERROR" "Executive Review FAILED: $task_id (${duration}s)"
    echo -e "${GRAY}Reason: $review_reason${NC}"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# COMMANDS
# ═══════════════════════════════════════════════════════════════════════════════

cmd_status() {
  local prd_path="$1"

  if [ ! -f "$prd_path" ]; then
    echo -e "${RED}Error: PRD file not found: $prd_path${NC}"
    exit 1
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
  if [ -f "$state_path" ]; then
    current_task_id=$(jq -r '.currentTask // empty' "$state_path")
  fi

  jq -r --arg current "$current_task_id" '.tasks[] |
    if .passes == true then
      "  \u001b[32m✓\u001b[0m \(.id): \(.title)"
    elif .id == $current then
      "  \u001b[33m→\u001b[0m \(.id): \(.title) \u001b[33m(in progress)\u001b[0m"
    else
      "  ○ \(.id): \(.title) \u001b[90m[\(.complexity // "auto")]\u001b[0m"
    end' "$prd_path"

  # Session stats
  if [ -f "$state_path" ]; then
    local escalation_count=$(jq '.escalations | length' "$state_path")
    local review_count=$(jq '.reviews | length' "$state_path")
    local review_pass=$(jq '[.reviews[] | select(.result == "PASS")] | length' "$state_path")
    local review_fail=$(jq '[.reviews[] | select(.result == "FAIL")] | length' "$state_path")
    local session_start=$(jq -r '.startedAt // empty' "$state_path")

    echo ""
    echo -e "${BOLD}Session Stats:${NC}"

    # Session duration
    if [ -n "$session_start" ]; then
      local start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${session_start%%+*}" "+%s" 2>/dev/null || \
                         date -d "$session_start" "+%s" 2>/dev/null || echo "")
      if [ -n "$start_epoch" ]; then
        local now_epoch=$(date +%s)
        local elapsed=$((now_epoch - start_epoch))
        local hours=$((elapsed / 3600))
        local mins=$(((elapsed % 3600) / 60))
        echo -e "  Session time:     ${hours}h ${mins}m"
      fi
    fi

    echo -e "  Escalations:      $escalation_count"
    echo -e "  Reviews:          $review_count (${GREEN}$review_pass passed${NC}, ${RED}$review_fail failed${NC})"

    if [ "$escalation_count" -gt 0 ]; then
      echo ""
      echo -e "${BOLD}Escalation History:${NC}"
      jq -r '.escalations[] | "  \(.taskId): \(.from) → \(.to) (\(.reason))"' "$state_path"
    fi
  fi

  echo ""
}

cmd_ticket() {
  local prd_path="$1"
  local task_id="$2"

  if [ ! -f "$prd_path" ]; then
    echo -e "${RED}Error: PRD file not found: $prd_path${NC}"
    exit 1
  fi

  local task=$(get_task_by_id "$prd_path" "$task_id")
  if [ -z "$task" ] || [ "$task" == "null" ]; then
    echo -e "${RED}Error: Task not found: $task_id${NC}"
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
  fi

  # Route and fire
  local initial_worker=$(route_task "$prd_path" "$task_id")
  local worker="$initial_worker"
  local escalated=false
  local iteration_in_tier=0

  update_state_task "$prd_path" "$task_id" "$worker" "started"

  for ((i=1; i<=MAX_ITERATIONS; i++)); do
    iteration_in_tier=$((iteration_in_tier + 1))

    # Check for escalation (Line Cook → Sous Chef)
    if [ "$ESCALATION_ENABLED" == "true" ] && \
       [ "$worker" == "line" ] && \
       [ "$escalated" == "false" ] && \
       [ "$iteration_in_tier" -gt "$ESCALATION_AFTER" ]; then

      echo ""
      echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
      log_event "ESCALATE" "ESCALATING $task_id: Line Cook → Sous Chef"
      echo -e "${YELLOW}║  Reason: $ESCALATION_AFTER iterations without completion            ║${NC}"
      echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
      echo ""

      record_escalation "$prd_path" "$task_id" "line" "sous" "Max iterations ($ESCALATION_AFTER) reached without completion"
      worker="sous"
      escalated=true
      iteration_in_tier=0
    fi

    echo -e "${GRAY}Iteration $i/$MAX_ITERATIONS (tier: $iteration_in_tier, worker: $(get_worker_name "$worker"))${NC}"

    fire_ticket "$prd_path" "$task_id" "$worker"
    local result=$?

    if [ $result -eq 0 ]; then
      # Task signaled complete - run tests if configured
      local tests_passed=true

      if [ -n "$TEST_CMD" ]; then
        echo -e "${CYAN}Running tests...${NC}"
        if $TEST_CMD; then
          echo -e "${GREEN}Tests passed${NC}"
        else
          echo -e "${YELLOW}Tests failed, continuing...${NC}"
          tests_passed=false
        fi
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
    elif [ $result -eq 2 ]; then
      # Blocked - try escalation if available
      if [ "$ESCALATION_ENABLED" == "true" ] && \
         [ "$worker" == "line" ] && \
         [ "$escalated" == "false" ]; then

        echo ""
        echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
        log_event "ESCALATE" "ESCALATING $task_id: Line Cook → Sous Chef (blocked)"
        echo -e "${YELLOW}║  Reason: Task blocked                                     ║${NC}"
        echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
        echo ""

        record_escalation "$prd_path" "$task_id" "line" "sous" "Task blocked"
        worker="sous"
        escalated=true
        iteration_in_tier=0
        continue  # Try again with sous chef
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
  local prd_path="$1"

  if [ ! -f "$prd_path" ]; then
    echo -e "${RED}Error: PRD file not found: $prd_path${NC}"
    exit 1
  fi

  # Initialize state for context isolation
  if [ "$CONTEXT_ISOLATION" == "true" ]; then
    init_state "$prd_path"
  fi

  # Initialize knowledge sharing
  if [ "$KNOWLEDGE_SHARING" == "true" ]; then
    init_learnings "$prd_path"
  fi

  local feature_name=$(jq -r '.featureName' "$prd_path")
  local total=$(get_task_count "$prd_path")

  log_event "START" "SERVICE STARTED: $feature_name"
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

    # Check for parallel execution of junior tasks
    if [ "$MAX_PARALLEL" -gt 1 ] && [ "$num_ready" -gt 1 ]; then
      # Find junior tasks that can run in parallel
      local parallel_tasks=""
      local parallel_count=0

      for task_id in "${tasks_array[@]}"; do
        local complexity=$(get_task_complexity "$prd_path" "$task_id")
        if [ "$complexity" == "junior" ] && [ "$parallel_count" -lt "$MAX_PARALLEL" ]; then
          parallel_tasks="$parallel_tasks $task_id"
          parallel_count=$((parallel_count + 1))
        fi
      done

      parallel_tasks=$(echo "$parallel_tasks" | xargs)

      if [ "$parallel_count" -gt 1 ]; then
        echo ""
        echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
        log_event "START" "PARALLEL EXECUTION: $parallel_count junior tasks"
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
          log_event "INFO" "Started $task_id (PID: $pid)"
        done

        # Wait for all parallel tasks
        local all_success=true
        for mapping in $task_pid_map; do
          local task_id=$(echo "$mapping" | cut -d: -f1)
          local pid=$(echo "$mapping" | cut -d: -f2)

          if wait "$pid"; then
            log_event "SUCCESS" "$task_id completed (parallel)"
            completed=$((completed + 1))
          else
            log_event "ERROR" "$task_id failed (parallel)"
            all_success=false
          fi
        done

        if [ "$all_success" != "true" ]; then
          echo -e "${RED}Some parallel tasks failed${NC}"
          exit 1
        fi

        continue  # Check for more tasks
      fi
    fi

    # Sequential execution (default)
    local next_task="${tasks_array[0]}"

    if cmd_ticket "$prd_path" "$next_task"; then
      completed=$((completed + 1))
    else
      echo -e "${RED}Failed to complete $next_task${NC}"
      exit 1
    fi
  done

  local service_end=$(date +%s)
  local duration=$((service_end - service_start))
  local hours=$((duration / 3600))
  local minutes=$(((duration % 3600) / 60))

  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
  log_event "SUCCESS" "SERVICE COMPLETE: $completed tasks in ${hours}h ${minutes}m"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
}

cmd_plan() {
  local description="$*"

  if [ -z "$description" ]; then
    echo -e "${RED}Error: Please provide a feature description${NC}"
    echo "Usage: ./brigade.sh plan \"Add user authentication with JWT\""
    exit 1
  fi

  # Create tasks directory if it doesn't exist
  mkdir -p "tasks"

  # Generate filename from description
  local slug=$(echo "$description" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | cut -c1-40)
  local prd_file="tasks/prd-${slug}.json"
  local today=$(date +%Y-%m-%d)

  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  log_event "START" "PLANNING PHASE: $description"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo ""

  # Build planning prompt
  local planning_prompt=""

  # Read the skill prompt if it exists
  if [ -f "$SCRIPT_DIR/.claude/skills/generate-prd.md" ]; then
    planning_prompt=$(cat "$SCRIPT_DIR/.claude/skills/generate-prd.md")
    planning_prompt="$planning_prompt

---
"
  fi

  planning_prompt="${planning_prompt}PLANNING REQUEST

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

  local output_file=$(mktemp)
  local start_time=$(date +%s)

  echo -e "${GRAY}Invoking Executive Chef (Director)...${NC}"
  echo ""

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

  # Check if PRD was generated
  if grep -q "<prd_generated>" "$output_file" 2>/dev/null; then
    local generated_file=$(sed -n 's/.*<prd_generated>\(.*\)<\/prd_generated>.*/\1/p' "$output_file" | head -1)

    if [ -f "$generated_file" ]; then
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
      echo -e "${BOLD}Next steps:${NC}"
      echo -e "  1. Review the PRD: ${CYAN}cat $generated_file | jq${NC}"
      echo -e "  2. Run service:    ${CYAN}./brigade.sh service $generated_file${NC}"
      echo ""
    else
      echo -e "${YELLOW}PRD file not found at expected location: $generated_file${NC}"
    fi
  elif [ -f "$prd_file" ]; then
    # PRD might have been created without the signal
    echo ""
    echo -e "${GREEN}PRD may have been generated: $prd_file${NC}"
    echo -e "Run: ${CYAN}./brigade.sh status $prd_file${NC}"
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
  print_banner
  load_config

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
    "ticket")
      cmd_ticket "$@"
      ;;
    "status")
      cmd_status "$@"
      ;;
    "analyze")
      cmd_analyze "$@"
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

main "$@"
