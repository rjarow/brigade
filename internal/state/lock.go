package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

// lockInfo represents the JSON lock file format.
type lockInfo struct {
	PID       int   `json:"pid"`
	Heartbeat int64 `json:"heartbeat"`
}

// Lock represents a file-based lock using mkdir (cross-platform compatible).
type Lock struct {
	path              string
	timeout           time.Duration
	stale             time.Duration
	heartbeatInterval time.Duration
	force             bool
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

// WithHeartbeatInterval sets the heartbeat update interval.
func WithHeartbeatInterval(d time.Duration) LockOption {
	return func(l *Lock) {
		l.heartbeatInterval = d
	}
}

// WithForce enables force override of existing locks.
func WithForce(force bool) LockOption {
	return func(l *Lock) {
		l.force = force
	}
}

// NewLock creates a new lock for the given path.
func NewLock(path string, opts ...LockOption) *Lock {
	l := &Lock{
		path:              path + ".lock",
		timeout:           30 * time.Second,
		stale:             5 * time.Minute,
		heartbeatInterval: 30 * time.Second,
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

	// Force override existing lock if requested
	if l.force {
		os.RemoveAll(l.path)
	}

	for {
		// Try to create lock directory
		err := os.Mkdir(l.path, 0755)
		if err == nil {
			// Lock acquired, write our lock info
			if err := l.writeLockInfo(); err != nil {
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
	// Force override existing lock if requested
	if l.force {
		os.RemoveAll(l.path)
	}

	err := os.Mkdir(l.path, 0755)
	if err == nil {
		// Lock acquired, write our lock info
		l.writeLockInfo()
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
				l.writeLockInfo()
				return true
			}
		}
	}

	return false
}

// writeLockInfo writes the JSON lock info file.
func (l *Lock) writeLockInfo() error {
	info := lockInfo{
		PID:       os.Getpid(),
		Heartbeat: time.Now().Unix(),
	}
	data, err := json.Marshal(info)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(l.path, "pid"), data, 0644)
}

// readLockInfo reads the lock info, supporting both JSON and plain PID formats.
func (l *Lock) readLockInfo() (*lockInfo, error) {
	pidFile := filepath.Join(l.path, "pid")
	data, err := os.ReadFile(pidFile)
	if err != nil {
		return nil, err
	}

	// Try JSON first
	var info lockInfo
	if err := json.Unmarshal(data, &info); err == nil {
		return &info, nil
	}

	// Fall back to plain PID format for backward compatibility
	var pid int
	if _, err := fmt.Sscanf(string(data), "%d", &pid); err == nil {
		return &lockInfo{PID: pid, Heartbeat: 0}, nil
	}

	return nil, fmt.Errorf("invalid lock file format")
}

// isStale checks if the lock is stale based on heartbeat or file age.
func (l *Lock) isStale() bool {
	info, err := l.readLockInfo()
	if err != nil {
		// Can't read lock info, consider stale
		return true
	}

	// Check if process is running
	if !isProcessRunning(info.PID) {
		return true
	}

	// If heartbeat is set, check heartbeat freshness (>2x interval = stale)
	if info.Heartbeat > 0 && l.heartbeatInterval > 0 {
		age := time.Since(time.Unix(info.Heartbeat, 0))
		if age > l.heartbeatInterval*2 {
			return true
		}
	}

	// Fall back to directory modification time
	dirInfo, err := os.Stat(l.path)
	if err != nil {
		return false
	}
	return time.Since(dirInfo.ModTime()) > l.stale
}

// tryRemoveStale attempts to remove a stale lock.
func (l *Lock) tryRemoveStale() bool {
	// Double-check that holder PID is not running
	info, err := l.readLockInfo()
	if err == nil && isProcessRunning(info.PID) {
		return false // Process still running, not stale
	}

	// Try to remove
	if err := os.RemoveAll(l.path); err != nil {
		return false
	}
	return true
}

// getHolder returns the PID of the current lock holder as a string.
func (l *Lock) getHolder() string {
	info, err := l.readLockInfo()
	if err != nil {
		return ""
	}
	return fmt.Sprintf("%d", info.PID)
}

// UpdateHeartbeat updates the heartbeat timestamp.
func (l *Lock) UpdateHeartbeat() error {
	return l.writeLockInfo()
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

// ServiceLock represents a lock for the entire service execution with heartbeat support.
type ServiceLock struct {
	*Lock
	prdPath string

	// Heartbeat management
	mu            sync.Mutex
	stopHeartbeat chan struct{}
	heartbeatDone chan struct{}
}

// NewServiceLock creates a service-level lock for a PRD.
func NewServiceLock(prdPath string, opts ...LockOption) *ServiceLock {
	lockPath := prdPath[:len(prdPath)-len(filepath.Ext(prdPath))] + ".service"
	return &ServiceLock{
		Lock:    NewLock(lockPath, opts...),
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

// StartHeartbeat starts a background goroutine that updates the heartbeat.
func (s *ServiceLock) StartHeartbeat(interval time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.stopHeartbeat != nil {
		// Already running
		return
	}

	s.stopHeartbeat = make(chan struct{})
	s.heartbeatDone = make(chan struct{})

	go func() {
		defer close(s.heartbeatDone)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()

		for {
			select {
			case <-ticker.C:
				s.Lock.UpdateHeartbeat()
			case <-s.stopHeartbeat:
				return
			}
		}
	}()
}

// StopHeartbeat stops the heartbeat goroutine.
func (s *ServiceLock) StopHeartbeat() {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.stopHeartbeat != nil {
		close(s.stopHeartbeat)
		<-s.heartbeatDone
		s.stopHeartbeat = nil
		s.heartbeatDone = nil
	}
}

// Release stops the heartbeat and releases the lock.
func (s *ServiceLock) Release() error {
	s.StopHeartbeat()
	return s.Lock.Release()
}
