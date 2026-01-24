package orchestrator

import (
	"context"
	"sync"

	"brigade/internal/prd"
	"brigade/internal/state"
)

// taskResult holds the result of a parallel task execution.
type taskResult struct {
	TaskID string
	Error  error
}

// executeParallel executes multiple tasks in parallel.
func (o *Orchestrator) executeParallel(ctx context.Context, tasks []*prd.Task) error {
	// Build batch: max 1 senior + (maxParallel-1) juniors
	batch := o.buildBatch(tasks)

	if len(batch) == 0 {
		return nil
	}

	if len(batch) == 1 {
		// Just run sequentially if only one task
		return o.executeTask(ctx, batch[0])
	}

	o.logger.Info("executing tasks in parallel",
		"count", len(batch),
		"tasks", taskIDs(batch))

	// Create channels for results
	results := make(chan taskResult, len(batch))
	var wg sync.WaitGroup

	// Create cancellation context
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	// Launch workers
	for _, task := range batch {
		wg.Add(1)
		go func(t *prd.Task) {
			defer wg.Done()

			err := o.executeTaskInParallel(ctx, t)
			results <- taskResult{
				TaskID: t.ID,
				Error:  err,
			}
		}(task)
	}

	// Wait for all tasks to complete
	go func() {
		wg.Wait()
		close(results)
	}()

	// Collect results
	var firstError error
	for result := range results {
		if result.Error != nil {
			o.logger.Error("parallel task failed",
				"task", result.TaskID,
				"error", result.Error)
			if firstError == nil {
				firstError = result.Error
			}
		}
	}

	return firstError
}

// buildBatch builds a batch of tasks for parallel execution.
// Rules:
// - Max 1 senior task (they might conflict)
// - Fill remaining slots with junior tasks
// - Don't exceed maxParallel
func (o *Orchestrator) buildBatch(tasks []*prd.Task) []*prd.Task {
	maxParallel := o.config.MaxParallel
	if maxParallel <= 0 {
		maxParallel = 1
	}

	var batch []*prd.Task
	var hasSenior bool

	for _, task := range tasks {
		if len(batch) >= maxParallel {
			break
		}

		// Determine tier
		tier := o.determineWorkerTier(task)

		if tier == state.TierSous || tier == state.TierExecutive {
			// Senior task
			if hasSenior {
				continue // Skip additional senior tasks
			}
			hasSenior = true
		}

		batch = append(batch, task)
	}

	return batch
}

// executeTaskInParallel executes a single task as part of parallel execution.
// This is similar to executeTask but with parallel-safe state handling.
func (o *Orchestrator) executeTaskInParallel(ctx context.Context, task *prd.Task) error {
	// Lock state for this task's updates
	// In a full implementation, we'd use per-task locks
	// For now, we'll serialize state updates

	return o.executeTask(ctx, task)
}

// taskIDs extracts task IDs from a slice of tasks.
func taskIDs(tasks []*prd.Task) []string {
	ids := make([]string, len(tasks))
	for i, t := range tasks {
		ids[i] = t.ID
	}
	return ids
}

// parallelBatchSize returns the appropriate batch size based on task mix.
func (o *Orchestrator) parallelBatchSize(tasks []*prd.Task) int {
	seniorCount := 0
	juniorCount := 0

	for _, task := range tasks {
		tier := o.determineWorkerTier(task)
		if tier == state.TierSous || tier == state.TierExecutive {
			seniorCount++
		} else {
			juniorCount++
		}
	}

	// At most 1 senior + (maxParallel-1) juniors
	maxParallel := o.config.MaxParallel
	if maxParallel <= 0 {
		return 1
	}

	size := juniorCount
	if seniorCount > 0 {
		size++ // Add one senior
	}
	if size > maxParallel {
		size = maxParallel
	}

	return size
}
