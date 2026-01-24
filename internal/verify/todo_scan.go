package verify

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// TodoMarker represents a TODO/FIXME/HACK marker found in code.
type TodoMarker struct {
	File     string
	Line     int
	Type     string // TODO, FIXME, HACK, XXX
	Text     string
	Context  string // Surrounding line content
}

// TodoScanResult holds the results of a TODO scan.
type TodoScanResult struct {
	Markers  []TodoMarker
	Scanned  int // Number of files scanned
	Duration int // Milliseconds
}

// HasMarkers returns true if any markers were found.
func (r *TodoScanResult) HasMarkers() bool {
	return len(r.Markers) > 0
}

// Count returns the number of markers found.
func (r *TodoScanResult) Count() int {
	return len(r.Markers)
}

// ByType returns markers of a specific type.
func (r *TodoScanResult) ByType(markerType string) []TodoMarker {
	var result []TodoMarker
	for _, m := range r.Markers {
		if m.Type == markerType {
			result = append(result, m)
		}
	}
	return result
}

// TodoScanner scans files for TODO/FIXME markers.
type TodoScanner struct {
	// Pattern to match TODO markers
	pattern *regexp.Regexp

	// Extensions to scan (empty means all)
	extensions map[string]bool

	// Directories to skip
	skipDirs map[string]bool
}

// NewTodoScanner creates a new TODO scanner.
func NewTodoScanner() *TodoScanner {
	return &TodoScanner{
		pattern: regexp.MustCompile(`(?i)\b(TODO|FIXME|HACK|XXX)\b[:\s]*(.*)$`),
		extensions: map[string]bool{
			".go":   true,
			".js":   true,
			".ts":   true,
			".jsx":  true,
			".tsx":  true,
			".py":   true,
			".rb":   true,
			".java": true,
			".kt":   true,
			".swift": true,
			".rs":   true,
			".c":    true,
			".cpp":  true,
			".h":    true,
			".hpp":  true,
			".cs":   true,
			".php":  true,
			".sh":   true,
			".bash": true,
			".zsh":  true,
			".yaml": true,
			".yml":  true,
			".json": true,
			".md":   true,
		},
		skipDirs: map[string]bool{
			"node_modules": true,
			"vendor":       true,
			".git":         true,
			"dist":         true,
			"build":        true,
			"target":       true,
			"__pycache__":  true,
			".next":        true,
			".nuxt":        true,
		},
	}
}

// ScanFiles scans specific files for TODO markers.
func (s *TodoScanner) ScanFiles(files []string) (*TodoScanResult, error) {
	result := &TodoScanResult{}

	for _, file := range files {
		markers, err := s.scanFile(file)
		if err != nil {
			continue // Skip files that can't be read
		}
		result.Markers = append(result.Markers, markers...)
		result.Scanned++
	}

	return result, nil
}

// ScanDirectory scans a directory for TODO markers.
func (s *TodoScanner) ScanDirectory(dir string) (*TodoScanResult, error) {
	result := &TodoScanResult{}

	err := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil // Skip errors
		}

		// Skip directories
		if info.IsDir() {
			if s.skipDirs[info.Name()] {
				return filepath.SkipDir
			}
			return nil
		}

		// Check extension
		ext := filepath.Ext(path)
		if len(s.extensions) > 0 && !s.extensions[ext] {
			return nil
		}

		markers, err := s.scanFile(path)
		if err != nil {
			return nil // Skip files that can't be read
		}
		result.Markers = append(result.Markers, markers...)
		result.Scanned++

		return nil
	})

	return result, err
}

// ScanChangedFiles scans only files that have changed according to git.
func (s *TodoScanner) ScanChangedFiles(dir string) (*TodoScanResult, error) {
	// This would normally use git to get changed files
	// For now, just scan the directory
	return s.ScanDirectory(dir)
}

// scanFile scans a single file for TODO markers.
func (s *TodoScanner) scanFile(path string) ([]TodoMarker, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var markers []TodoMarker
	scanner := bufio.NewScanner(file)
	lineNum := 0

	for scanner.Scan() {
		lineNum++
		line := scanner.Text()

		matches := s.pattern.FindStringSubmatch(line)
		if len(matches) >= 3 {
			markers = append(markers, TodoMarker{
				File:    path,
				Line:    lineNum,
				Type:    strings.ToUpper(matches[1]),
				Text:    strings.TrimSpace(matches[2]),
				Context: strings.TrimSpace(line),
			})
		}
	}

	return markers, scanner.Err()
}

// SetExtensions sets the file extensions to scan.
func (s *TodoScanner) SetExtensions(exts []string) {
	s.extensions = make(map[string]bool)
	for _, ext := range exts {
		if !strings.HasPrefix(ext, ".") {
			ext = "." + ext
		}
		s.extensions[ext] = true
	}
}

// AddSkipDir adds a directory to skip.
func (s *TodoScanner) AddSkipDir(dir string) {
	s.skipDirs[dir] = true
}

// SetPattern sets a custom pattern for TODO markers.
func (s *TodoScanner) SetPattern(pattern string) error {
	re, err := regexp.Compile(pattern)
	if err != nil {
		return err
	}
	s.pattern = re
	return nil
}

// FormatMarkers formats markers for display.
func FormatMarkers(markers []TodoMarker) string {
	if len(markers) == 0 {
		return "No TODO/FIXME markers found."
	}

	var sb strings.Builder
	sb.WriteString("Found TODO/FIXME markers:\n")
	for _, m := range markers {
		sb.WriteString("  ")
		sb.WriteString(m.File)
		sb.WriteString(":")
		sb.WriteString(string(rune(m.Line + '0')))
		sb.WriteString(": [")
		sb.WriteString(m.Type)
		sb.WriteString("] ")
		sb.WriteString(m.Text)
		sb.WriteString("\n")
	}
	return sb.String()
}

// FilterNewMarkers returns markers that appear in newMarkers but not in baseline.
func FilterNewMarkers(newMarkers, baseline []TodoMarker) []TodoMarker {
	baselineSet := make(map[string]bool)
	for _, m := range baseline {
		key := m.File + ":" + m.Type + ":" + m.Text
		baselineSet[key] = true
	}

	var result []TodoMarker
	for _, m := range newMarkers {
		key := m.File + ":" + m.Type + ":" + m.Text
		if !baselineSet[key] {
			result = append(result, m)
		}
	}
	return result
}
