package module

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Dispatcher dispatches events to modules.
type Dispatcher struct {
	modules []*Module
	timeout time.Duration
	logger  *slog.Logger

	// Tracking for cleanup
	mu       sync.Mutex
	running  map[*exec.Cmd]bool
}

// NewDispatcher creates a new event dispatcher.
func NewDispatcher(modules []*Module, timeout time.Duration, logger *slog.Logger) *Dispatcher {
	if logger == nil {
		logger = slog.Default()
	}
	return &Dispatcher{
		modules: modules,
		timeout: timeout,
		logger:  logger,
		running: make(map[*exec.Cmd]bool),
	}
}

// Dispatch sends an event to all modules that handle it.
// Events are dispatched asynchronously and don't block.
func (d *Dispatcher) Dispatch(event *Event) {
	for _, module := range d.modules {
		if !module.Enabled {
			continue
		}
		if !module.HandlesEvent(event.Type) {
			continue
		}

		// Dispatch asynchronously
		go d.dispatchToModule(module, event)
	}
}

// DispatchSync sends an event and waits for all handlers to complete.
func (d *Dispatcher) DispatchSync(ctx context.Context, event *Event) []error {
	var wg sync.WaitGroup
	errCh := make(chan error, len(d.modules))

	for _, module := range d.modules {
		if !module.Enabled {
			continue
		}
		if !module.HandlesEvent(event.Type) {
			continue
		}

		wg.Add(1)
		go func(m *Module) {
			defer wg.Done()
			if err := d.dispatchToModuleSync(ctx, m, event); err != nil {
				errCh <- err
			}
		}(module)
	}

	wg.Wait()
	close(errCh)

	var errors []error
	for err := range errCh {
		errors = append(errors, err)
	}
	return errors
}

// dispatchToModule dispatches an event to a single module asynchronously.
func (d *Dispatcher) dispatchToModule(module *Module, event *Event) {
	ctx, cancel := context.WithTimeout(context.Background(), d.timeout)
	defer cancel()

	if err := d.dispatchToModuleSync(ctx, module, event); err != nil {
		d.logger.Warn("module event handler failed",
			"module", module.Name,
			"event", event.Type,
			"error", err)
	}
}

// dispatchToModuleSync dispatches an event to a module and waits for completion.
func (d *Dispatcher) dispatchToModuleSync(ctx context.Context, module *Module, event *Event) error {
	// Build command
	cmd := exec.CommandContext(ctx, module.Path, "--event", string(event.Type))
	cmd.Dir = filepath.Dir(module.Path)

	// Set environment
	cmd.Env = os.Environ()
	for key, value := range module.Config {
		envKey := "MODULE_" + strings.ToUpper(module.Name) + "_" + key
		cmd.Env = append(cmd.Env, envKey+"="+value)
	}

	// Pass event data as JSON on stdin
	eventJSON, err := event.JSON()
	if err != nil {
		return fmt.Errorf("marshaling event: %w", err)
	}
	cmd.Stdin = bytes.NewReader(eventJSON)

	// Capture output for debugging
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	// Track running command
	d.mu.Lock()
	d.running[cmd] = true
	d.mu.Unlock()

	defer func() {
		d.mu.Lock()
		delete(d.running, cmd)
		d.mu.Unlock()
	}()

	// Run the command
	if err := cmd.Run(); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return fmt.Errorf("timeout after %v", d.timeout)
		}
		stderrStr := stderr.String()
		if stderrStr != "" {
			return fmt.Errorf("%w: %s", err, stderrStr)
		}
		return err
	}

	return nil
}

// Cleanup kills any running module handlers.
func (d *Dispatcher) Cleanup() {
	d.mu.Lock()
	defer d.mu.Unlock()

	for cmd := range d.running {
		if cmd.Process != nil {
			cmd.Process.Kill()
		}
	}
}

// Modules returns the list of loaded modules.
func (d *Dispatcher) Modules() []*Module {
	return d.modules
}

// EnabledModules returns only enabled modules.
func (d *Dispatcher) EnabledModules() []*Module {
	var enabled []*Module
	for _, m := range d.modules {
		if m.Enabled {
			enabled = append(enabled, m)
		}
	}
	return enabled
}

// ModulesByEvent returns modules that handle a specific event.
func (d *Dispatcher) ModulesByEvent(eventType EventType) []*Module {
	var modules []*Module
	for _, m := range d.modules {
		if m.Enabled && m.HandlesEvent(eventType) {
			modules = append(modules, m)
		}
	}
	return modules
}

// HasHandlers returns true if any module handles the given event type.
func (d *Dispatcher) HasHandlers(eventType EventType) bool {
	return len(d.ModulesByEvent(eventType)) > 0
}

// Manager manages the module lifecycle.
type Manager struct {
	loader     *Loader
	dispatcher *Dispatcher
	logger     *slog.Logger
}

// NewManager creates a new module manager.
func NewManager(modulesDir string, config map[string]string, timeout time.Duration, logger *slog.Logger) *Manager {
	return &Manager{
		loader: NewLoader(modulesDir, config),
		logger: logger,
	}
}

// Load loads and initializes the specified modules.
func (m *Manager) Load(names []string) error {
	modules, err := m.loader.LoadModules(names)
	if err != nil {
		return err
	}

	// Initialize modules
	for _, module := range modules {
		if err := m.loader.InitModule(module); err != nil {
			m.logger.Warn("module init failed, disabling",
				"module", module.Name,
				"error", err)
		}
	}

	// Filter to enabled modules only
	var enabled []*Module
	for _, module := range modules {
		if module.Enabled {
			enabled = append(enabled, module)
			m.logger.Info("module loaded",
				"module", module.Name,
				"events", module.Events)
		}
	}

	timeout := 5 * time.Second
	if len(names) > 0 {
		// Use configured timeout
		timeout = m.loader.QueryTimeout
	}

	m.dispatcher = NewDispatcher(enabled, timeout, m.logger)
	return nil
}

// Dispatch sends an event to all modules.
func (m *Manager) Dispatch(event *Event) {
	if m.dispatcher != nil {
		m.dispatcher.Dispatch(event)
	}
}

// DispatchSync sends an event and waits for completion.
func (m *Manager) DispatchSync(ctx context.Context, event *Event) []error {
	if m.dispatcher != nil {
		return m.dispatcher.DispatchSync(ctx, event)
	}
	return nil
}

// Cleanup cleans up the module manager.
func (m *Manager) Cleanup() {
	if m.dispatcher != nil {
		m.dispatcher.Cleanup()
	}
}

// Modules returns the loaded modules.
func (m *Manager) Modules() []*Module {
	if m.dispatcher != nil {
		return m.dispatcher.Modules()
	}
	return nil
}
