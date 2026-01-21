#!/bin/bash
# Terminal alerts for Brigade
# Works over SSH (bell notifications) and local terminals (colored banners)
# Config: MODULE_TERMINAL_BELL=true|false (default: true)

# ANSI colors
TERM_RED='\033[0;31m'
TERM_YELLOW='\033[0;33m'
TERM_GREEN='\033[0;32m'
TERM_CYAN='\033[0;36m'
TERM_BOLD='\033[1m'
TERM_NC='\033[0m'

module_terminal_events() {
  echo "attention escalation task_slow service_complete"
}

module_terminal_init() {
  # Default bell to true if not set
  : "${MODULE_TERMINAL_BELL:=true}"
  return 0
}

_terminal_bell() {
  if [ "$MODULE_TERMINAL_BELL" = "true" ]; then
    printf '\a'
  fi
}

_terminal_banner() {
  local color="$1"
  local title="$2"
  local message="$3"

  echo ""
  echo -e "${color}╔══════════════════════════════════════════════════════════════╗${TERM_NC}"
  echo -e "${color}║${TERM_NC} ${TERM_BOLD}${title}${TERM_NC}"
  echo -e "${color}║${TERM_NC} ${message}"
  echo -e "${color}╚══════════════════════════════════════════════════════════════╝${TERM_NC}"
  echo ""
}

module_terminal_on_attention() {
  local task_id="$1" reason="$2"
  _terminal_bell
  _terminal_banner "$TERM_RED" "ATTENTION NEEDED" "Task $task_id: $reason"
}

module_terminal_on_escalation() {
  local task_id="$1" from="$2" to="$3"
  _terminal_banner "$TERM_YELLOW" "ESCALATION" "Task $task_id: $from -> $to"
}

module_terminal_on_task_slow() {
  local task_id="$1" worker="$2" elapsed="$3" threshold="$4"
  _terminal_bell
  _terminal_banner "$TERM_YELLOW" "TASK RUNNING LONG" "Task $task_id running ${elapsed}m (expected ~${threshold}m for $worker)"
}

module_terminal_on_service_complete() {
  local completed="$1" failed="$2" duration="$3"
  local mins=$((duration / 60))
  _terminal_bell
  if [ "$failed" -eq 0 ]; then
    _terminal_banner "$TERM_GREEN" "SERVICE COMPLETE" "$completed tasks completed in ${mins}m"
  else
    _terminal_banner "$TERM_CYAN" "SERVICE COMPLETE" "$completed done, $failed failed (${mins}m)"
  fi
}
