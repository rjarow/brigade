package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Store handles state file persistence.
type Store struct {
	path string
	lock *Lock
}

// NewStore creates a new state store for the given path.
func NewStore(path string) *Store {
	return &Store{
		path: path,
		lock: NewLock(path),
	}
}

// Load loads state from the file, creating a new state if the file doesn't exist.
func (s *Store) Load() (*State, error) {
	// Check if file exists
	if _, err := os.Stat(s.path); os.IsNotExist(err) {
		state := New()
		state.SetPath(s.path)
		return state, nil
	}

	// Read existing file
	data, err := os.ReadFile(s.path)
	if err != nil {
		return nil, fmt.Errorf("reading state file: %w", err)
	}

	var state State
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, fmt.Errorf("parsing state JSON: %w", err)
	}

	state.SetPath(s.path)
	return &state, nil
}

// Save writes state to the file atomically.
func (s *Store) Save(state *State) error {
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling state: %w", err)
	}

	// Ensure directory exists
	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("creating state directory: %w", err)
	}

	// Atomic write: write to temp file then rename
	tmpFile, err := os.CreateTemp(dir, ".state-*.json")
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

	if err := os.Rename(tmpPath, s.path); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("renaming temp file: %w", err)
	}

	state.SetPath(s.path)
	return nil
}

// LoadLocked loads state with a lock held.
func (s *Store) LoadLocked() (*State, error) {
	if err := s.lock.Acquire(); err != nil {
		return nil, fmt.Errorf("acquiring lock: %w", err)
	}
	// Note: caller must call Unlock() when done

	return s.Load()
}

// SaveLocked saves state with a lock held.
func (s *Store) SaveLocked(state *State) error {
	if err := s.lock.Acquire(); err != nil {
		return fmt.Errorf("acquiring lock: %w", err)
	}
	defer s.lock.Release()

	return s.Save(state)
}

// Unlock releases the lock.
func (s *Store) Unlock() {
	s.lock.Release()
}

// Path returns the store's file path.
func (s *Store) Path() string {
	return s.path
}

// Exists returns true if the state file exists.
func (s *Store) Exists() bool {
	_, err := os.Stat(s.path)
	return err == nil
}

// Delete removes the state file.
func (s *Store) Delete() error {
	return os.Remove(s.path)
}

// LoadOrCreate loads existing state or creates a new one.
// This is a convenience method that always returns a valid state.
func (s *Store) LoadOrCreate() (*State, bool, error) {
	exists := s.Exists()
	state, err := s.Load()
	if err != nil {
		return nil, false, err
	}
	return state, exists, nil
}

// Update atomically updates state using a function.
func (s *Store) Update(fn func(*State) error) error {
	if err := s.lock.Acquire(); err != nil {
		return fmt.Errorf("acquiring lock: %w", err)
	}
	defer s.lock.Release()

	state, err := s.Load()
	if err != nil {
		return err
	}

	if err := fn(state); err != nil {
		return err
	}

	return s.Save(state)
}

// ForPRD creates a store for a PRD's state file.
func ForPRD(prdPath string) *Store {
	// prd-feature.json -> prd-feature.state.json
	statePath := prdPath[:len(prdPath)-5] + ".state.json"
	return NewStore(statePath)
}

// MigrateState migrates state from an old format if necessary.
func MigrateState(state *State) (bool, error) {
	migrated := false

	// Ensure required slices are initialized
	if state.TaskHistory == nil {
		state.TaskHistory = []TaskHistory{}
		migrated = true
	}
	if state.Escalations == nil {
		state.Escalations = []Escalation{}
		migrated = true
	}
	if state.Reviews == nil {
		state.Reviews = []Review{}
		migrated = true
	}
	if state.Absorptions == nil {
		state.Absorptions = []Absorption{}
		migrated = true
	}
	if state.PhaseReviews == nil {
		state.PhaseReviews = []PhaseReview{}
		migrated = true
	}
	if state.SessionFailures == nil {
		state.SessionFailures = []SessionFailure{}
		migrated = true
	}

	return migrated, nil
}

// CopyState creates a deep copy of a state.
func CopyState(s *State) *State {
	if s == nil {
		return nil
	}

	copy := &State{
		SessionID:        s.SessionID,
		StartedAt:        s.StartedAt,
		LastStartTime:    s.LastStartTime,
		CurrentTask:      s.CurrentTask,
		ConsecutiveSkips: s.ConsecutiveSkips,
		path:             s.path,
	}

	// Copy slices
	copy.TaskHistory = make([]TaskHistory, len(s.TaskHistory))
	for i, h := range s.TaskHistory {
		copy.TaskHistory[i] = h
	}

	copy.Escalations = make([]Escalation, len(s.Escalations))
	for i, e := range s.Escalations {
		copy.Escalations[i] = e
	}

	copy.Reviews = make([]Review, len(s.Reviews))
	for i, r := range s.Reviews {
		copy.Reviews[i] = r
	}

	copy.Absorptions = make([]Absorption, len(s.Absorptions))
	for i, a := range s.Absorptions {
		copy.Absorptions[i] = a
	}

	copy.PhaseReviews = make([]PhaseReview, len(s.PhaseReviews))
	for i, p := range s.PhaseReviews {
		copy.PhaseReviews[i] = p
	}

	copy.SessionFailures = make([]SessionFailure, len(s.SessionFailures))
	for i, f := range s.SessionFailures {
		copy.SessionFailures[i] = f
	}

	return copy
}
