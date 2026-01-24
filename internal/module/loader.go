package module

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Loader discovers and loads modules.
type Loader struct {
	// ModulesDir is the directory containing module executables
	ModulesDir string

	// Config holds module-specific configuration (MODULE_* env vars)
	Config map[string]string

	// Timeout for querying module events
	QueryTimeout time.Duration
}

// NewLoader creates a new module loader.
func NewLoader(modulesDir string, config map[string]string) *Loader {
	return &Loader{
		ModulesDir:   modulesDir,
		Config:       config,
		QueryTimeout: 5 * time.Second,
	}
}

// LoadModules loads the specified modules by name.
func (l *Loader) LoadModules(names []string) ([]*Module, error) {
	var modules []*Module

	for _, name := range names {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}

		module, err := l.loadModule(name)
		if err != nil {
			return nil, fmt.Errorf("loading module %s: %w", name, err)
		}

		modules = append(modules, module)
	}

	return modules, nil
}

// loadModule loads a single module.
func (l *Loader) loadModule(name string) (*Module, error) {
	// Find the module executable
	path := l.findModulePath(name)
	if path == "" {
		return nil, fmt.Errorf("module executable not found")
	}

	// Check if executable
	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("stat: %w", err)
	}
	if info.Mode()&0111 == 0 {
		return nil, fmt.Errorf("not executable")
	}

	// Query events
	events, err := l.queryEvents(path)
	if err != nil {
		return nil, fmt.Errorf("querying events: %w", err)
	}

	// Build module config
	config := l.getModuleConfig(name)

	return &Module{
		Name:    name,
		Path:    path,
		Events:  events,
		Config:  config,
		Enabled: true,
	}, nil
}

// findModulePath finds the path to a module executable.
func (l *Loader) findModulePath(name string) string {
	// Try different extensions/names
	candidates := []string{
		name,
		name + ".sh",
		name + ".py",
		name + ".rb",
		name + ".js",
	}

	for _, candidate := range candidates {
		path := filepath.Join(l.ModulesDir, candidate)
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}

	return ""
}

// queryEvents queries a module for the events it handles.
func (l *Loader) queryEvents(path string) ([]EventType, error) {
	cmd := exec.Command(path, "--events")
	cmd.Dir = filepath.Dir(path)

	var stdout bytes.Buffer
	cmd.Stdout = &stdout

	// Set a timeout
	done := make(chan error, 1)
	go func() {
		done <- cmd.Run()
	}()

	select {
	case err := <-done:
		if err != nil {
			return nil, err
		}
	case <-time.After(l.QueryTimeout):
		if cmd.Process != nil {
			cmd.Process.Kill()
		}
		return nil, fmt.Errorf("timeout querying events")
	}

	// Parse events from output
	output := strings.TrimSpace(stdout.String())
	eventNames := strings.Fields(output)

	var events []EventType
	for _, name := range eventNames {
		eventType := EventType(name)
		// Validate event type
		if isValidEventType(eventType) {
			events = append(events, eventType)
		}
	}

	return events, nil
}

// isValidEventType checks if an event type is valid.
func isValidEventType(et EventType) bool {
	for _, valid := range AllEventTypes() {
		if et == valid {
			return true
		}
	}
	return false
}

// getModuleConfig extracts configuration for a specific module.
func (l *Loader) getModuleConfig(name string) map[string]string {
	config := make(map[string]string)
	prefix := "MODULE_" + strings.ToUpper(name) + "_"

	for key, value := range l.Config {
		if strings.HasPrefix(key, prefix) {
			// Remove prefix and convert to lowercase
			configKey := strings.TrimPrefix(key, prefix)
			config[configKey] = value
		}
	}

	return config
}

// DiscoverModules discovers all available modules in the modules directory.
func (l *Loader) DiscoverModules() ([]string, error) {
	entries, err := os.ReadDir(l.ModulesDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	var modules []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}

		name := entry.Name()
		// Remove common extensions
		name = strings.TrimSuffix(name, ".sh")
		name = strings.TrimSuffix(name, ".py")
		name = strings.TrimSuffix(name, ".rb")
		name = strings.TrimSuffix(name, ".js")

		// Skip example module
		if name == "example" {
			continue
		}

		modules = append(modules, name)
	}

	return modules, nil
}

// InitModule calls the module's init function if it has one.
func (l *Loader) InitModule(module *Module) error {
	// Try to call --init
	cmd := exec.Command(module.Path, "--init")
	cmd.Dir = filepath.Dir(module.Path)

	// Set module config as environment
	cmd.Env = os.Environ()
	for key, value := range module.Config {
		envKey := "MODULE_" + strings.ToUpper(module.Name) + "_" + key
		cmd.Env = append(cmd.Env, envKey+"="+value)
	}

	err := cmd.Run()
	if err != nil {
		// Init failure means module should be disabled
		module.Enabled = false
		return err
	}

	return nil
}
