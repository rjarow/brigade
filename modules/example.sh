#!/bin/bash
# Example Brigade module - copy this to create your own
# Enable in brigade.config: MODULES="example"

# REQUIRED: Declare which events this module handles
# Available: service_start, task_start, task_complete, task_blocked,
#            task_absorbed, task_already_done, escalation, review,
#            verification, attention, decision_needed, decision_received,
#            scope_decision, service_complete
module_example_events() {
  echo "task_complete service_complete"
}

# OPTIONAL: Initialize module (return non-zero to disable)
module_example_init() {
  # Validate required config
  # if [ -z "$MODULE_EXAMPLE_API_KEY" ]; then
  #   echo "[example] MODULE_EXAMPLE_API_KEY not set" >&2
  #   return 1
  # fi
  return 0
}

# OPTIONAL: Cleanup on exit
module_example_cleanup() {
  :  # Nothing to clean up
}

# EVENT HANDLERS: module_<name>_on_<event>()
# Args match emit_supervisor_event() - see event type for specifics

module_example_on_task_complete() {
  local task_id="$1"
  local worker="$2"
  local duration="$3"
  echo "[example] Task $task_id completed by $worker in ${duration}s"
}

module_example_on_service_complete() {
  local completed="$1"
  local failed="$2"
  local duration="$3"
  echo "[example] Service finished: $completed done, $failed failed, ${duration}s total"
}
