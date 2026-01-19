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
  echo "  service [prd.json]         Run full service (defaults to brigade/tasks/latest.json)"
  echo "  resume [prd.json] [action] Resume after interruption (action: retry|skip)"
  echo "  ticket <prd.json> <id>     Run single ticket"
  echo "  status [--all] [prd.json]  Show kitchen status (auto-detects active PRD)"
  echo "  analyze <prd.json>         Analyze tasks and suggest routing"
  echo "  validate <prd.json>        Validate PRD structure and dependencies"
  echo "  opencode-models            List available OpenCode models"
  echo ""
  echo "Options:"
  echo "  --max-iterations <n>       Max iterations per task (default: 50)"
  echo "  --dry-run                  Show what would be done without executing"
  echo "  --auto-continue            Chain multiple PRDs for unattended execution"
  echo "  --phase-gate <mode>        Between-PRD behavior: review|continue|pause (default: continue)"
  echo ""
  echo "Examples:"
  echo "  ./brigade.sh plan \"Add user authentication with JWT\""
  echo "  ./brigade.sh service                                 # Uses brigade/tasks/latest.json"
  echo "  ./brigade.sh service brigade/tasks/prd.json          # Specific PRD"
  echo "  ./brigade.sh --auto-continue service brigade/tasks/prd-*.json  # Chain numbered PRDs"
  echo "  ./brigade.sh status                                  # Auto-detect active PRD"
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
    LINE_CMD="opencode run"
    LINE_AGENT="opencode"
    echo -e "${CYAN}Using OpenCode for junior tasks (USE_OPENCODE=true)${NC}"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# PRD HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

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

  # Update PRD
  local tmp_file=$(mktemp)
  jq "(.tasks[] | select(.id == \"$task_id\") | .passes) = true" "$prd_path" > "$tmp_file"
  mv "$tmp_file" "$prd_path"

  # Clear currentTask from state file
  local state_path=$(get_state_path "$prd_path")
  if [ -f "$state_path" ]; then
    tmp_file=$(mktemp)
    jq '.currentTask = null' "$state_path" > "$tmp_file"
    mv "$tmp_file" "$state_path"
  fi

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
  echo "$prd_dir/$STATE_FILE"
}

# Find active PRD - looks for state files with currentTask set, or most recent PRD
find_active_prd() {
  # Check brigade/tasks first, then fallback paths (for running from inside brigade/)
  local search_dirs=("brigade/tasks" "tasks" "." "../brigade/tasks" "../tasks" "..")

  # First, look for state files with an active currentTask
  for dir in "${search_dirs[@]}"; do
    if [ -d "$dir" ]; then
      for state_file in "$dir"/$STATE_FILE "$dir"/*/$STATE_FILE; do
        if [ -f "$state_file" ] 2>/dev/null; then
          local current=$(jq -r '.currentTask // empty' "$state_file" 2>/dev/null)
          if [ -n "$current" ]; then
            # Found active state, find corresponding PRD
            local state_dir=$(dirname "$state_file")
            for prd in "$state_dir"/*.json; do
              if [ -f "$prd" ] && jq -e '.tasks' "$prd" >/dev/null 2>&1; then
                echo "$prd"
                return 0
              fi
            done
          fi
        fi
      done
    fi
  done

  # No active task found, look for most recent PRD with pending tasks
  for dir in "${search_dirs[@]}"; do
    if [ -d "$dir" ]; then
      for prd in "$dir"/prd*.json "$dir"/*.json; do
        if [ -f "$prd" ] 2>/dev/null && jq -e '.tasks' "$prd" >/dev/null 2>&1; then
          local pending=$(jq '[.tasks[] | select(.passes == false)] | length' "$prd" 2>/dev/null)
          if [ "$pending" -gt 0 ]; then
            echo "$prd"
            return 0
          fi
        fi
      done
    fi
  done

  # Last resort: any PRD file
  for dir in "${search_dirs[@]}"; do
    if [ -d "$dir" ]; then
      for prd in "$dir"/prd*.json "$dir"/*.json; do
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

  # Validate existing state file
  if [ -f "$state_path" ]; then
    if ! validate_state "$state_path"; then
      # State was corrupted and removed, create fresh
      :
    else
      return 0  # Valid state exists
    fi
  fi

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
  echo -e "${GRAY}Initialized state: $state_path${NC}"
}

update_last_start_time() {
  local prd_path="$1"

  if [ "$CONTEXT_ISOLATION" != "true" ]; then
    return
  fi

  local state_path=$(get_state_path "$prd_path")
  if [ -f "$state_path" ]; then
    local tmp_file=$(mktemp)
    jq --arg ts "$(date -Iseconds)" '.lastStartTime = $ts' "$state_path" > "$tmp_file"
    mv "$tmp_file" "$state_path"
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

record_absorption() {
  local prd_path="$1"
  local task_id="$2"
  local absorbed_by="$3"

  if [ "$CONTEXT_ISOLATION" != "true" ]; then
    return
  fi

  local state_path=$(get_state_path "$prd_path")
  local tmp_file=$(mktemp)

  jq --arg task "$task_id" --arg absorbed_by "$absorbed_by" --arg ts "$(date -Iseconds)" \
    '.absorptions += [{"taskId": $task, "absorbedBy": $absorbed_by, "timestamp": $ts}]' \
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
6. If already done by a prior task, output: <promise>ALREADY_DONE</promise>
7. If absorbed by a prior task (prior task completed this work), output: <promise>ABSORBED_BY:US-XXX</promise> (replace US-XXX with the task ID)
8. Share useful learnings with: <learning>What you learned</learning>

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
      # OpenCode CLI: opencode run [options] "prompt"
      # See: https://opencode.ai/docs/cli/
      local opencode_flags="--log-level ERROR"
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
  elif grep -q "<promise>ALREADY_DONE</promise>" "$output_file" 2>/dev/null; then
    log_event "SUCCESS" "Task $task_id signaled ALREADY_DONE - completed by prior task (${duration}s)"
    rm -f "$output_file"
    return 3  # Special return code for already done
  elif grep -oq "<promise>ABSORBED_BY:" "$output_file" 2>/dev/null; then
    # Extract the absorbing task ID (e.g., ABSORBED_BY:US-001 -> US-001)
    LAST_ABSORBED_BY=$(grep -o "<promise>ABSORBED_BY:[^<]*</promise>" "$output_file" | sed 's/<promise>ABSORBED_BY://;s/<\/promise>//')
    log_event "SUCCESS" "Task $task_id ABSORBED BY $LAST_ABSORBED_BY (${duration}s)"
    rm -f "$output_file"
    return 4  # Special return code for absorbed
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
  echo -e "${GRAY}Executive Chef reviewing $(get_worker_name "$completed_by")'s work${NC}"
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

  local output_file=$(mktemp)
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

      local output_file=$(mktemp)
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
  local tmp_prd=$(mktemp)
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

cmd_status() {
  local show_all_escalations=false
  local prd_path=""

  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --all)
        show_all_escalations=true
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
      echo "Usage: ./brigade.sh status [prd.json]"
      exit 1
    fi
    echo -e "${GRAY}Found: $prd_path${NC}"
  fi

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
  local absorptions_json="[]"
  if [ -f "$state_path" ]; then
    current_task_id=$(jq -r '.currentTask // empty' "$state_path")
    absorptions_json=$(jq -c '.absorptions // []' "$state_path")
  fi

  jq -r --arg current "$current_task_id" --argjson absorptions "$absorptions_json" '.tasks[] |
    # Check if this task was absorbed
    .id as $id |
    ($absorptions | map(select(.taskId == $id)) | first // null) as $absorption |
    if .passes == true and $absorption != null then
      "  \u001b[32m✓\u001b[0m \(.id): \(.title) \u001b[90m(absorbed by \($absorption.absorbedBy))\u001b[0m"
    elif .passes == true then
      "  \u001b[32m✓\u001b[0m \(.id): \(.title)"
    elif .id == $current then
      "  \u001b[33m→\u001b[0m \(.id): \(.title) \u001b[33m(in progress)\u001b[0m"
    else
      "  ○ \(.id): \(.title) \u001b[90m[\(.complexity // "auto")]\u001b[0m"
    end' "$prd_path"

  # Session stats
  if [ -f "$state_path" ]; then
    local review_count=$(jq '.reviews | length' "$state_path")
    local review_pass=$(jq '[.reviews[] | select(.result == "PASS")] | length' "$state_path")
    local review_fail=$(jq '[.reviews[] | select(.result == "FAIL")] | length' "$state_path")
    local session_start=$(jq -r '.startedAt // empty' "$state_path")
    local last_start=$(jq -r '.lastStartTime // empty' "$state_path")

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

    local absorption_count=$(jq '.absorptions | length' "$state_path")

    # Get task IDs from current PRD for filtering
    local prd_task_ids=$(jq -r '[.tasks[].id] | @json' "$prd_path")

    # Count escalations - filter by current PRD unless --all
    local escalation_count
    local prd_escalation_count
    local total_escalation_count=$(jq '.escalations | length' "$state_path")
    if [ "$show_all_escalations" = "true" ]; then
      escalation_count=$total_escalation_count
    else
      prd_escalation_count=$(jq --argjson ids "$prd_task_ids" \
        '[.escalations[] | select(.taskId as $tid | $ids | index($tid))] | length' "$state_path")
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
        jq -r '.escalations[] | "  \(.taskId): \(.from) → \(.to) (\(.reason))"' "$state_path"
      else
        echo -e "${BOLD}Escalation History:${NC}"
        jq -r --argjson ids "$prd_task_ids" \
          '.escalations[] | select(.taskId as $tid | $ids | index($tid)) | "  \(.taskId): \(.from) → \(.to) (\(.reason))"' "$state_path"
      fi
    fi

    if [ "$absorption_count" -gt 0 ]; then
      echo ""
      echo -e "${BOLD}Absorbed Tasks:${NC}"
      jq -r '.absorptions[] | "  \(.taskId) ← absorbed by \(.absorbedBy)"' "$state_path"
    fi
  fi

  echo ""
}

cmd_resume() {
  local prd_path="$1"
  local action="$2"  # "retry" or "skip" (optional)

  # Auto-detect PRD if not provided
  if [ -z "$prd_path" ]; then
    prd_path=$(find_active_prd)
    if [ -z "$prd_path" ]; then
      echo -e "${YELLOW}No active PRD found.${NC}"
      echo "Usage: ./brigade.sh resume [prd.json] [retry|skip]"
      exit 1
    fi
    echo -e "${GRAY}Found: $prd_path${NC}"
  fi

  if [ ! -f "$prd_path" ]; then
    echo -e "${RED}Error: PRD file not found: $prd_path${NC}"
    exit 1
  fi

  local state_path=$(get_state_path "$prd_path")
  if [ ! -f "$state_path" ]; then
    echo -e "${YELLOW}No state file found - nothing to resume.${NC}"
    echo -e "${GRAY}Run './brigade.sh service $prd_path' to start fresh.${NC}"
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
    local tmp_file=$(mktemp)
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
    local tmp_file=$(mktemp)
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
    echo -e "What would you like to do?"
    echo -e "  ${CYAN}retry${NC} - Retry the interrupted task from scratch"
    echo -e "  ${CYAN}skip${NC}  - Mark as failed and continue to next task"
    echo ""
    read -p "Enter choice [retry/skip]: " action
  fi

  case "$action" in
    "retry"|"r")
      echo ""
      log_event "RESUME" "Retrying interrupted task: $current_task"
      # Clear currentTask to allow fresh start
      local tmp_file=$(mktemp)
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
      local tmp_file=$(mktemp)
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
    update_last_start_time "$prd_path"
  fi

  # Route and fire
  local initial_worker=$(route_task "$prd_path" "$task_id")
  local worker="$initial_worker"
  local escalation_tier=0  # 0=none, 1=line→sous, 2=sous→exec
  local iteration_in_tier=0

  update_state_task "$prd_path" "$task_id" "$worker" "started"

  # Track task start time for timeout checking
  local task_start_epoch=$(date +%s)

  # Pre-flight check: if tests already pass, task may be done
  if [ -n "$TEST_CMD" ]; then
    echo -e "${GRAY}Pre-flight check: running tests to see if task is already complete...${NC}"
    if timeout 30 bash -c "$TEST_CMD" >/dev/null 2>&1; then
      echo -e "${GREEN}✓ Tests already pass - task appears complete${NC}"
      log_event "SUCCESS" "Task $task_id: pre-flight tests pass → ALREADY_DONE"
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
      log_event "ESCALATE" "ESCALATING $task_id: Line Cook → Sous Chef"
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
      log_event "ESCALATE" "ESCALATING $task_id: Sous Chef → Executive Chef (rare)"
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
          log_event "ESCALATE" "ESCALATING $task_id: Line Cook → Sous Chef (timeout)"
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
          log_event "ESCALATE" "ESCALATING $task_id: Sous Chef → Executive Chef (timeout)"
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
          log_event "WARN" "Task $task_id: Executive Chef timeout but no higher tier available"
        fi
      fi
    fi

    echo -e "${GRAY}Iteration $i/$MAX_ITERATIONS (tier: $iteration_in_tier, worker: $(get_worker_name "$worker"))${NC}"

    # Track each iteration attempt
    update_state_task "$prd_path" "$task_id" "$worker" "iteration_$i"

    fire_ticket "$prd_path" "$task_id" "$worker"
    local result=$?

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
        log_event "WARN" "Task $task_id: COMPLETE with empty diff → treating as ALREADY_DONE"
        add_learning "$prd_path" "$task_id" "$worker" "workflow" \
          "Task $task_id was already complete but worker didn't signal ALREADY_DONE. Check acceptance criteria before writing code."
        # Skip tests/review since nothing changed
        update_state_task "$prd_path" "$task_id" "$worker" "already_done_detected"
        mark_task_complete "$prd_path" "$task_id"
        return 0
      fi

      # Run tests if configured
      local tests_passed=true

      if [ -n "$TEST_CMD" ]; then
        echo -e "${CYAN}Running tests (timeout: ${TEST_TIMEOUT}s)...${NC}"
        local test_output=$(mktemp)
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
    elif [ $result -eq 3 ]; then
      # Already done by prior task - mark complete without tests/review
      echo -e "${GREEN}Task was already completed by a prior task${NC}"
      update_state_task "$prd_path" "$task_id" "$worker" "already_done"
      mark_task_complete "$prd_path" "$task_id"
      return 0
    elif [ $result -eq 4 ]; then
      # Absorbed by another task - mark complete without tests/review
      echo -e "${GREEN}Task was absorbed by $LAST_ABSORBED_BY${NC}"
      update_state_task "$prd_path" "$task_id" "$worker" "absorbed"
      record_absorption "$prd_path" "$task_id" "$LAST_ABSORBED_BY"
      mark_task_complete "$prd_path" "$task_id"
      return 0
    elif [ $result -eq 2 ]; then
      # Blocked - try escalation if available
      if [ "$ESCALATION_ENABLED" == "true" ] && \
         [ "$worker" == "line" ] && \
         [ "$escalation_tier" -eq 0 ]; then

        echo ""
        echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
        log_event "ESCALATE" "ESCALATING $task_id: Line Cook → Sous Chef (blocked)"
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
        log_event "ESCALATE" "ESCALATING $task_id: Sous Chef → Executive Chef (blocked)"
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
      echo "Usage: ./brigade.sh service [prd.json]"
      exit 1
    fi
  fi

  if [ ! -f "$prd_path" ]; then
    echo -e "${RED}Error: PRD file not found: $prd_path${NC}"
    exit 1
  fi

  # Validate PRD before running
  echo -e "${GRAY}Validating PRD...${NC}"
  if ! validate_prd_quick "$prd_path"; then
    echo -e "${RED}PRD validation failed. Run './brigade.sh validate $prd_path' for details.${NC}"
    exit 1
  fi
  echo -e "${GREEN}✓${NC} PRD valid"

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

        # Phase review at intervals (after parallel batch)
        phase_review "$prd_path" "$completed"

        continue  # Check for more tasks
      fi
    fi

    # Sequential execution (default)
    local next_task="${tasks_array[0]}"

    if cmd_ticket "$prd_path" "$next_task"; then
      completed=$((completed + 1))
      # Phase review at intervals
      phase_review "$prd_path" "$completed"
    else
      echo -e "${RED}Failed to complete $next_task${NC}"
      exit 1
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
    escalation_count=$(jq '.escalations | length' "$state_path" 2>/dev/null || echo 0)
    absorption_count=$(jq '.absorptions | length' "$state_path" 2>/dev/null || echo 0)
    review_count=$(jq '.reviews | length' "$state_path" 2>/dev/null || echo 0)
    review_pass=$(jq '[.reviews[] | select(.result == "PASS")] | length' "$state_path" 2>/dev/null || echo 0)
  fi

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

  # Merge feature branch to default branch
  local merge_status="none"  # none, success, failed, pushed
  local default_branch=""
  if [ -n "$branch_name" ]; then
    local current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ "$current_branch" == "$branch_name" ]; then
      default_branch=$(get_default_branch)
      echo -e "${CYAN}Merging $branch_name to $default_branch...${NC}"
      if git checkout "$default_branch" && git merge "$branch_name" --no-edit; then
        echo -e "${GREEN}✓ Merged $branch_name to $default_branch${NC}"
        merge_status="success"
        if git push origin "$default_branch" 2>/dev/null; then
          echo -e "${GREEN}✓ Pushed to origin/$default_branch${NC}"
          merge_status="pushed"
        fi
        git checkout "$branch_name"  # Return to feature branch
      else
        echo -e "${RED}Merge failed - resolve conflicts manually${NC}"
        merge_status="failed"
        git checkout "$branch_name"
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
      echo -e "  • ${GREEN}✓ Already merged and pushed to $default_branch${NC}"
      echo -e "  • Delete feature branch if no longer needed: ${CYAN}git branch -d $branch_name${NC}"
      ;;
    "success")
      echo -e "  • ${GREEN}✓ Merged to $default_branch${NC} - push when ready: ${CYAN}git push origin $default_branch${NC}"
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

  # Generate filename from description
  local slug=$(echo "$description" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | cut -c1-40)
  local prd_file="brigade/tasks/prd-${slug}.json"
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
      echo -e "${BOLD}Next steps:${NC}"
      echo -e "  1. Review the PRD: ${CYAN}cat $generated_file | jq${NC}"
      echo -e "  2. Run service:    ${CYAN}./brigade.sh service${NC}"
      echo ""
    else
      echo -e "${YELLOW}PRD file not found at expected location: $generated_file${NC}"
    fi
  elif [ -f "$prd_file" ]; then
    # PRD might have been created without the signal
    update_latest_symlink "$prd_file"
    echo ""
    echo -e "${GREEN}PRD may have been generated: $prd_file${NC}"
    echo -e "Run: ${CYAN}./brigade.sh service${NC}"
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
      --auto-continue)
        AUTO_CONTINUE=true
        shift
        ;;
      --phase-gate)
        PHASE_GATE="$2"
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
