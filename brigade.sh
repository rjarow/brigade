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

# Defaults
EXECUTIVE_CMD="claude --model opus"
SOUS_CMD="claude --model sonnet"
LINE_CMD="opencode -p"
TEST_CMD=""
MAX_ITERATIONS=50

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
  echo "Usage: ./brigade.sh <command> [options]"
  echo ""
  echo "Commands:"
  echo "  service <prd.json>         Run full service (all tasks)"
  echo "  ticket <prd.json> <id>     Run single ticket"
  echo "  status <prd.json>          Show kitchen status"
  echo "  analyze <prd.json>         Analyze tasks and suggest routing"
  echo ""
  echo "Options:"
  echo "  --max-iterations <n>       Max iterations per task (default: 50)"
  echo "  --dry-run                  Show what would be done without executing"
  echo ""
  echo "Examples:"
  echo "  ./brigade.sh service tasks/prd.json"
  echo "  ./brigade.sh ticket tasks/prd.json US-001"
  echo "  ./brigade.sh status tasks/prd.json"
}

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo -e "${GRAY}Loaded config from $CONFIG_FILE${NC}"
  else
    echo -e "${YELLOW}Warning: No brigade.config found, using defaults${NC}"
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

mark_task_complete() {
  local prd_path="$1"
  local task_id="$2"

  local tmp_file=$(mktemp)
  jq "(.tasks[] | select(.id == \"$task_id\") | .passes) = true" "$prd_path" > "$tmp_file"
  mv "$tmp_file" "$prd_path"

  echo -e "${GREEN}✓ Marked $task_id as complete${NC}"
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

  cat <<EOF
$chef_prompt

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

BEGIN WORK:
EOF
}

fire_ticket() {
  local prd_path="$1"
  local task_id="$2"
  local worker="$3"

  local worker_name=$(get_worker_name "$worker")
  local worker_cmd=$(get_worker_cmd "$worker")
  local chef_prompt_file="$CHEF_DIR/${worker}.md"

  local chef_prompt=""
  if [ -f "$chef_prompt_file" ]; then
    chef_prompt=$(cat "$chef_prompt_file")
  fi

  local task_title=$(jq -r ".tasks[] | select(.id == \"$task_id\") | .title" "$prd_path")

  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}FIRING: $task_id - $task_title${NC}"
  echo -e "${GRAY}Worker: $worker_name${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo ""

  local full_prompt=$(build_prompt "$prd_path" "$task_id" "$chef_prompt")
  local output_file=$(mktemp)

  # Execute worker
  local start_time=$(date +%s)

  if [[ "$worker_cmd" == *"claude"* ]]; then
    # Claude CLI
    if $worker_cmd --dangerously-skip-permissions -p "$full_prompt" 2>&1 | tee "$output_file"; then
      echo -e "${GREEN}Worker completed${NC}"
    else
      echo -e "${YELLOW}Worker exited${NC}"
    fi
  elif [[ "$worker_cmd" == *"opencode"* ]]; then
    # OpenCode CLI
    if $worker_cmd "$full_prompt" 2>&1 | tee "$output_file"; then
      echo -e "${GREEN}Worker completed${NC}"
    else
      echo -e "${YELLOW}Worker exited${NC}"
    fi
  else
    # Generic command
    if echo "$full_prompt" | $worker_cmd 2>&1 | tee "$output_file"; then
      echo -e "${GREEN}Worker completed${NC}"
    else
      echo -e "${YELLOW}Worker exited${NC}"
    fi
  fi

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))

  echo -e "${GRAY}Duration: ${duration}s${NC}"

  # Check for completion signal
  if grep -q "<promise>COMPLETE</promise>" "$output_file" 2>/dev/null; then
    echo -e "${GREEN}✓ Task signaled COMPLETE${NC}"
    rm -f "$output_file"
    return 0
  elif grep -q "<promise>BLOCKED</promise>" "$output_file" 2>/dev/null; then
    echo -e "${RED}✗ Task is BLOCKED${NC}"
    rm -f "$output_file"
    return 2
  else
    echo -e "${YELLOW}⚠ No completion signal - may need another iteration${NC}"
    rm -f "$output_file"
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
  echo ""
  echo -e "  Total tickets:    $total"
  echo -e "  ${GREEN}Complete:${NC}         $complete"
  echo -e "  ${YELLOW}Pending:${NC}          $pending"
  echo ""

  if [ "$pending" -gt 0 ]; then
    echo -e "${BOLD}Pending Tickets:${NC}"
    jq -r '.tasks[] | select(.passes == false) | "  \(.id): \(.title) [\(.complexity // "auto")]"' "$prd_path"
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

  # Route and fire
  local worker=$(route_task "$prd_path" "$task_id")

  for ((i=1; i<=MAX_ITERATIONS; i++)); do
    echo -e "${GRAY}Iteration $i/$MAX_ITERATIONS${NC}"

    fire_ticket "$prd_path" "$task_id" "$worker"
    local result=$?

    if [ $result -eq 0 ]; then
      # Run tests if configured
      if [ -n "$TEST_CMD" ]; then
        echo -e "${CYAN}Running tests...${NC}"
        if $TEST_CMD; then
          echo -e "${GREEN}Tests passed${NC}"
          mark_task_complete "$prd_path" "$task_id"
          return 0
        else
          echo -e "${YELLOW}Tests failed, continuing...${NC}"
        fi
      else
        mark_task_complete "$prd_path" "$task_id"
        return 0
      fi
    elif [ $result -eq 2 ]; then
      # Blocked
      echo -e "${RED}Task is blocked, stopping${NC}"
      return 1
    fi
    # Otherwise continue iterating
  done

  echo -e "${RED}Max iterations reached for $task_id${NC}"
  return 1
}

cmd_service() {
  local prd_path="$1"

  if [ ! -f "$prd_path" ]; then
    echo -e "${RED}Error: PRD file not found: $prd_path${NC}"
    exit 1
  fi

  local feature_name=$(jq -r '.featureName' "$prd_path")
  local total=$(get_task_count "$prd_path")

  echo -e "${BOLD}Starting service: $feature_name${NC}"
  echo -e "Total tickets: $total"
  echo ""

  local service_start=$(date +%s)
  local completed=0

  while true; do
    local next_task=$(get_next_task "$prd_path")

    if [ -z "$next_task" ]; then
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
  echo -e "${GREEN}║  SERVICE COMPLETE                                         ║${NC}"
  echo -e "${GREEN}║  Completed: $completed tasks                                      ║${NC}"
  echo -e "${GREEN}║  Duration: ${hours}h ${minutes}m                                        ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
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

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
  print_banner
  load_config

  local command="${1:-}"
  shift || true

  case "$command" in
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
