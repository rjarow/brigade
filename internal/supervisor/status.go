// Package supervisor handles supervisor integration for monitoring Brigade.
package supervisor

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Status represents the compact status for supervisor polling.
type Status struct {
	Done      int    `json:"done"`
	Total     int    `json:"total"`
	Current   string `json:"current,omitempty"`
	Worker    string `json:"worker,omitempty"`
	Elapsed   int    `json:"elapsed,omitempty"` // Seconds since task started
	Attention bool   `json:"attention"`
}

// StatusWriter writes status updates to a file.
type StatusWriter struct {
	path        string
	prdPrefix   string
	scopeByPRD  bool
}

// NewStatusWriter creates a new status writer.
func NewStatusWriter(path string, prdPrefix string, scopeByPRD bool) *StatusWriter {
	return &StatusWriter{
		path:       path,
		prdPrefix:  prdPrefix,
		scopeByPRD: scopeByPRD,
	}
}

// Path returns the actual file path (scoped if enabled).
func (w *StatusWriter) Path() string {
	if w.scopeByPRD && w.prdPrefix != "" {
		dir := filepath.Dir(w.path)
		base := filepath.Base(w.path)
		ext := filepath.Ext(base)
		name := base[:len(base)-len(ext)]
		return filepath.Join(dir, fmt.Sprintf("%s-%s%s", w.prdPrefix, name, ext))
	}
	return w.path
}

// Write writes a status update atomically.
func (w *StatusWriter) Write(status *Status) error {
	if w.path == "" {
		return nil
	}

	data, err := json.Marshal(status)
	if err != nil {
		return fmt.Errorf("marshaling status: %w", err)
	}

	return w.writeAtomic(data)
}

// WriteProgress writes a progress status.
func (w *StatusWriter) WriteProgress(done, total int, currentTask, worker string, taskStartTime time.Time, attention bool) error {
	status := &Status{
		Done:      done,
		Total:     total,
		Current:   currentTask,
		Worker:    worker,
		Attention: attention,
	}

	if !taskStartTime.IsZero() {
		status.Elapsed = int(time.Since(taskStartTime).Seconds())
	}

	return w.Write(status)
}

// writeAtomic writes data to the file atomically.
func (w *StatusWriter) writeAtomic(data []byte) error {
	path := w.Path()

	// Ensure directory exists
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("creating directory: %w", err)
	}

	// Write to temp file
	tmpFile, err := os.CreateTemp(dir, ".status-*.json")
	if err != nil {
		return fmt.Errorf("creating temp file: %w", err)
	}
	tmpPath := tmpFile.Name()

	if _, err := tmpFile.Write(data); err != nil {
		tmpFile.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("writing temp file: %w", err)
	}
	if err := tmpFile.Close(); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("closing temp file: %w", err)
	}

	// Rename to final path
	if err := os.Rename(tmpPath, path); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("renaming temp file: %w", err)
	}

	return nil
}

// Read reads the current status.
func (w *StatusWriter) Read() (*Status, error) {
	path := w.Path()

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	var status Status
	if err := json.Unmarshal(data, &status); err != nil {
		return nil, err
	}

	return &status, nil
}

// Clear removes the status file.
func (w *StatusWriter) Clear() error {
	path := w.Path()
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// Enabled returns true if the status writer is enabled.
func (w *StatusWriter) Enabled() bool {
	return w.path != ""
}
