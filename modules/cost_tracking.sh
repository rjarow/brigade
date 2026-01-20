#!/bin/bash
# Cost/duration tracking - logs to CSV for analysis
# Config: MODULE_COST_TRACKING_OUTPUT (default: brigade/costs.csv)
# Uses COST_RATE_LINE, COST_RATE_SOUS, COST_RATE_EXECUTIVE from brigade.config

module_cost_tracking_events() {
  echo "task_start task_complete service_start service_complete"
}

module_cost_tracking_init() {
  COST_OUTPUT="${MODULE_COST_TRACKING_OUTPUT:-brigade/costs.csv}"

  # Create directory if needed
  local dir=$(dirname "$COST_OUTPUT")
  [ -n "$dir" ] && [ "$dir" != "." ] && mkdir -p "$dir"

  # Write header if new file (includes cost_usd column)
  if [ ! -f "$COST_OUTPUT" ]; then
    echo "timestamp,event,prd,task_id,worker,duration,cost_usd" > "$COST_OUTPUT"
  fi
  return 0
}

# Calculate cost estimate based on duration and worker tier
# Uses global COST_RATE_* variables from brigade.config
_cost_tracking_calc() {
  local duration="$1"
  local worker="$2"

  local rate
  case "$worker" in
    line) rate="${COST_RATE_LINE:-0.05}" ;;
    sous) rate="${COST_RATE_SOUS:-0.15}" ;;
    executive) rate="${COST_RATE_EXECUTIVE:-0.30}" ;;
    *) rate="0.10" ;;
  esac

  # cost = duration_seconds / 60 * rate_per_minute
  echo "scale=4; $duration / 60 * $rate" | bc
}

module_cost_tracking_on_service_start() {
  local prd="$1" total="$2"
  echo "$(date -Iseconds),service_start,$prd,,,," >> "$COST_OUTPUT"
}

module_cost_tracking_on_task_start() {
  local task="$1" worker="$2"
  echo "$(date -Iseconds),task_start,,$task,$worker,0," >> "$COST_OUTPUT"
}

module_cost_tracking_on_task_complete() {
  local task="$1" worker="$2" duration="$3"
  local cost=$(_cost_tracking_calc "$duration" "$worker")
  echo "$(date -Iseconds),task_complete,,$task,$worker,$duration,$cost" >> "$COST_OUTPUT"
}

module_cost_tracking_on_service_complete() {
  local completed="$1" failed="$2" duration="$3"
  echo "$(date -Iseconds),service_complete,,,$completed/$failed,$duration," >> "$COST_OUTPUT"
}
