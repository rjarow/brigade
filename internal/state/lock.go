package state

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Lock represents a file-based lock using mkdir (cross-platform compatible).
type Lock struct {
	path    string
	timeout time.Duration
	stale   time.Duration
}

// LockOption configures lock behavior.
type LockOption func(*Lock)

// WithTimeout sets the lock acquisition timeout.
func WithTimeout(d time.Duration) LockOption {
	return func(l *Lock) {
		l.timeout = d
	}
}

// WithStaleAge sets the age at which a lock is considered stale.
func WithStaleAge(d time.Duration) LockOption {
	return func(l *Lock) {
		l.stale = d
	}
}

// NewLock creates a new lock for the given path.
func NewLock(path string, opts ...LockOption) *Lock {
	l := &Lock{
		path:    path + ".lock",
		timeout: 30 * time.Second,
		stale:   5 * time.Minute,
	}
	for _, opt := range opts {
		opt(l)
	}
	return l
}

// Acquire attempts to acquire the lock, blocking up to the timeout.
func (l *Lock) Acquire() error {
	deadline := time.Now().Add(l.timeout)
	pollInterval := 100 * time.Millisecond

	for {
		// Try to create lock directory
		err := os.Mkdir(l.path, 0755)
		if err == nil {
			// Lock acquired, write our PID
			pidFile := filepath.Join(l.path, "pid")
			if err := os.WriteFile(pidFile, []byte(fmt.Sprintf("%d", os.Getpid())), 0644); err != nil {
				// Non-fatal, continue with lock
			}
			return nil
		}

		if !os.IsExist(err) {
			return fmt.Errorf("creating lock directory: %w", err)
		}

		// Lock exists, check if stale
		if l.isStale() {
			if l.tryRemoveStale() {
				continue // Try again immediately
			}
		}

		// Check timeout
		if time.Now().After(deadline) {
			holder := l.getHolder()
			if holder != "" {
				return fmt.Errorf("lock held by PID %s (timeout after %v)", holder, l.timeout)
			}
			return fmt.Errorf("lock acquisition timeout after %v", l.timeout)
		}

		time.Sleep(pollInterval)
	}
}

// Release releases the lock.
func (l *Lock) Release() error {
	return os.RemoveAll(l.path)
}

// TryAcquire attempts to acquire the lock without blocking.
// Returns true if lock was acquired, false otherwise.
func (l *Lock) TryAcquire() bool {
	err := os.Mkdir(l.path, 0755)
	if err == nil {
		// Lock acquired, write our PID
		pidFile := filepath.Join(l.path, "pid")
		os.WriteFile(pidFile, []byte(fmt.Sprintf("%d", os.Getpid())), 0644)
		return true
	}

	if !os.IsExist(err) {
		return false
	}

	// Lock exists, check if stale
	if l.isStale() {
		if l.tryRemoveStale() {
			// Try one more time
			if err := os.Mkdir(l.path, 0755); err == nil {
				pidFile := filepath.Join(l.path, "pid")
				os.WriteFile(pidFile, []byte(fmt.Sprintf("%d", os.Getpid())), 0644)
				return true
			}
		}
	}

	return false
}

// isStale checks if the lock is older than the stale threshold.
func (l *Lock) isStale() bool {
	info, err := os.Stat(l.path)
	if err != nil {
		return false
	}

	age := time.Since(info.ModTime())
	return age > l.stale
}

// tryRemoveStale attempts to remove a stale lock.
func (l *Lock) tryRemoveStale() bool {
	// Check if the holder PID is still running
	holder := l.getHolder()
	if holder != "" {
		pid, err := strconv.Atoi(holder)
		if err == nil && isProcessRunning(pid) {
			return false // Process still running, not stale
		}
	}

	// Try to remove
	if err := os.RemoveAll(l.path); err != nil {
		return false
	}
	return true
}

// getHolder returns the PID of the current lock holder, if available.
func (l *Lock) getHolder() string {
	pidFile := filepath.Join(l.path, "pid")
	data, err := os.ReadFile(pidFile)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// isProcessRunning checks if a process with the given PID is running.
func isProcessRunning(pid int) bool {
	process, err := os.FindProcess(pid)
	if err != nil {
		return false
	}

	// On Unix, FindProcess always succeeds. We need to send signal 0 to check.
	err = process.Signal(syscall.Signal(0))
	return err == nil
}

// ForPath returns a lock for a state file path.
func ForPath(statePath string) *Lock {
	return NewLock(statePath)
}

// WithLock executes a function while holding a lock.
func WithLock(path string, fn func() error, opts ...LockOption) error {
	lock := NewLock(path, opts...)
	if err := lock.Acquire(); err != nil {
		return fmt.Errorf("acquiring lock: %w", err)
	}
	defer lock.Release()

	return fn()
}

// ServiceLock represents a lock for the entire service execution.
type ServiceLock struct {
	*Lock
	prdPath string
}

// NewServiceLock creates a service-level lock for a PRD.
func NewServiceLock(prdPath string) *ServiceLock {
	lockPath := strings.TrimSuffix(prdPath, ".json") + ".service"
	return &ServiceLock{
		Lock:    NewLock(lockPath),
		prdPath: prdPath,
	}
}

// AcquireExclusive acquires an exclusive lock for service execution.
// This prevents multiple brigade instances from processing the same PRD.
func (s *ServiceLock) AcquireExclusive() error {
	if err := s.Acquire(); err != nil {
		return fmt.Errorf("another Brigade instance is processing %s: %w", filepath.Base(s.prdPath), err)
	}
	return nil
}
