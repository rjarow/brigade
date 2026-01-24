package orchestrator

import (
	"fmt"
	"os"
	"sync"
	"time"
)

// ActivityLogger writes periodic status updates to a file for monitoring.
type ActivityLogger struct {
	path      string
	interval  time.Duration
	prdPrefix string

	mu            sync.Mutex
	currentTask   string
	currentWorker string
	taskStart     time.Time

	stopChan chan struct{}
	doneChan chan struct{}
}

// NewActivityLogger creates a new activity logger.
func NewActivityLogger(path string, interval time.Duration, prdPrefix string) *ActivityLogger {
	return &ActivityLogger{
		path:      path,
		interval:  interval,
		prdPrefix: prdPrefix,
	}
}

// Start begins the background heartbeat logger.
func (a *ActivityLogger) Start() {
	if a.path == "" {
		return
	}

	a.mu.Lock()
	if a.stopChan != nil {
		a.mu.Unlock()
		return // Already running
	}
	a.stopChan = make(chan struct{})
	a.doneChan = make(chan struct{})
	a.mu.Unlock()

	go func() {
		defer close(a.doneChan)
		ticker := time.NewTicker(a.interval)
		defer ticker.Stop()

		for {
			select {
			case <-ticker.C:
				a.writeHeartbeat()
			case <-a.stopChan:
				return
			}
		}
	}()
}

// Stop halts the background logger.
func (a *ActivityLogger) Stop() {
	a.mu.Lock()
	defer a.mu.Unlock()

	if a.stopChan != nil {
		close(a.stopChan)
		<-a.doneChan
		a.stopChan = nil
		a.doneChan = nil
	}
}

// SetTask updates the current task being worked on.
func (a *ActivityLogger) SetTask(taskID, worker string) {
	a.mu.Lock()
	defer a.mu.Unlock()

	a.currentTask = taskID
	a.currentWorker = worker
	a.taskStart = time.Now()
}

// ClearTask clears the current task.
func (a *ActivityLogger) ClearTask() {
	a.mu.Lock()
	defer a.mu.Unlock()

	a.currentTask = ""
	a.currentWorker = ""
	a.taskStart = time.Time{}
}

// WriteState writes a state transition event.
// Events: SERVICE_START, LOOP_EXIT, SERVICE_END, IDLE, ESCALATION
func (a *ActivityLogger) WriteState(event, reason, detail string) {
	if a.path == "" {
		return
	}

	timestamp := time.Now().Format("15:04:05")
	var line string
	if detail != "" {
		line = fmt.Sprintf("[%s] %s: %s - %s (%s)\n", timestamp, a.prdPrefix, event, reason, detail)
	} else if reason != "" {
		line = fmt.Sprintf("[%s] %s: %s - %s\n", timestamp, a.prdPrefix, event, reason)
	} else {
		line = fmt.Sprintf("[%s] %s: %s\n", timestamp, a.prdPrefix, event)
	}

	a.appendToFile(line)
}

// writeHeartbeat writes the periodic heartbeat entry.
func (a *ActivityLogger) writeHeartbeat() {
	a.mu.Lock()
	task := a.currentTask
	worker := a.currentWorker
	taskStart := a.taskStart
	a.mu.Unlock()

	if task == "" {
		return // No active task, skip heartbeat
	}

	timestamp := time.Now().Format("15:04:05")
	elapsed := time.Since(taskStart).Round(time.Second)

	// Format: [HH:MM:SS] prefix/task: Worker working (Xm Ys)
	line := fmt.Sprintf("[%s] %s/%s: %s working (%s)\n",
		timestamp, a.prdPrefix, task, worker, formatElapsed(elapsed))

	a.appendToFile(line)
}

// appendToFile appends a line to the activity log file.
func (a *ActivityLogger) appendToFile(line string) {
	f, err := os.OpenFile(a.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	f.WriteString(line)
}

// formatElapsed formats a duration as Xm Ys or Xs.
func formatElapsed(d time.Duration) string {
	m := int(d.Minutes())
	s := int(d.Seconds()) % 60

	if m > 0 {
		return fmt.Sprintf("%dm %ds", m, s)
	}
	return fmt.Sprintf("%ds", s)
}
