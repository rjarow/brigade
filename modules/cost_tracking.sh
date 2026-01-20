#!/bin/bash
# Cost/duration tracking - logs to CSV for analysis
# Config: MODULE_COST_TRACKING_OUTPUT (default: brigade/costs.csv)

module_cost_tracking_events() {
  echo "task_start task_complete service_start service_complete"
}

module_cost_tracking_init() {
  COST_OUTPUT="${MODULE_COST_TRACKING_OUTPUT:-brigade/costs.csv}"

  # Create directory if needed
  local dir=$(dirname "$COST_OUTPUT")
  [ -n "$dir" ] && [ "$dir" != "." ] && mkdir -p "$dir"

  # Write header if new file
  if [ ! -f "$COST_OUTPUT" ]; then
    echo "timestamp,event,prd,task_id,worker,duration" > "$COST_OUTPUT"
  fi
  return 0
}

module_cost_tracking_on_service_start() {
  local prd="$1" total="$2"
  echo "$(date -Iseconds),service_start,$prd,,,$total" >> "$COST_OUTPUT"
}

module_cost_tracking_on_task_start() {
  local task="$1" worker="$2"
  echo "$(date -Iseconds),task_start,,$task,$worker,0" >> "$COST_OUTPUT"
}

module_cost_tracking_on_task_complete() {
  local task="$1" worker="$2" duration="$3"
  echo "$(date -Iseconds),task_complete,,$task,$worker,$duration" >> "$COST_OUTPUT"
}

module_cost_tracking_on_service_complete() {
  local completed="$1" failed="$2" duration="$3"
  echo "$(date -Iseconds),service_complete,,,$completed/$failed,$duration" >> "$COST_OUTPUT"
}
