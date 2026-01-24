// Package classify handles error classification for smart retry.
package classify

import (
	"regexp"
	"strings"
)

// Category represents an error category.
type Category string

const (
	CategorySyntax      Category = "syntax"
	CategoryIntegration Category = "integration"
	CategoryEnvironment Category = "environment"
	CategoryLogic       Category = "logic"
	CategoryUnknown     Category = "unknown"
)

// Pattern represents an error pattern with its category.
type Pattern struct {
	Regex    *regexp.Regexp
	Category Category
}

// Classifier classifies error output into categories.
type Classifier struct {
	patterns []Pattern
}

// DefaultPatterns returns the default error patterns.
var DefaultPatterns = []struct {
	Pattern  string
	Category Category
}{
	// Syntax errors
	{`(?i)syntax error`, CategorySyntax},
	{`(?i)parse error`, CategorySyntax},
	{`(?i)unexpected token`, CategorySyntax},
	{`(?i)unexpected end of`, CategorySyntax},
	{`(?i)invalid syntax`, CategorySyntax},
	{`(?i)cannot parse`, CategorySyntax},
	{`(?i)compilation failed`, CategorySyntax},
	{`(?i)compile error`, CategorySyntax},
	{`(?i)SyntaxError:`, CategorySyntax},
	{`(?i)TypeError:.*not a function`, CategorySyntax},
	{`(?i)undefined:`, CategorySyntax},
	{`(?i)undeclared name`, CategorySyntax},
	{`(?i)cannot find symbol`, CategorySyntax},
	{`(?i)illegal character`, CategorySyntax},
	{`(?i)missing .* before`, CategorySyntax},
	{`(?i)expected .* but found`, CategorySyntax},

	// Integration errors
	{`(?i)connection refused`, CategoryIntegration},
	{`(?i)ECONNREFUSED`, CategoryIntegration},
	{`(?i)network error`, CategoryIntegration},
	{`(?i)timeout`, CategoryIntegration},
	{`(?i)timed out`, CategoryIntegration},
	{`(?i)ETIMEDOUT`, CategoryIntegration},
	{`(?i)connection reset`, CategoryIntegration},
	{`(?i)ECONNRESET`, CategoryIntegration},
	{`(?i)no route to host`, CategoryIntegration},
	{`(?i)host unreachable`, CategoryIntegration},
	{`(?i)dns lookup failed`, CategoryIntegration},
	{`(?i)ENOTFOUND`, CategoryIntegration},
	{`(?i)503 Service Unavailable`, CategoryIntegration},
	{`(?i)502 Bad Gateway`, CategoryIntegration},
	{`(?i)504 Gateway Timeout`, CategoryIntegration},
	{`(?i)API error`, CategoryIntegration},
	{`(?i)rate limit`, CategoryIntegration},
	{`(?i)too many requests`, CategoryIntegration},
	{`(?i)service unavailable`, CategoryIntegration},
	{`(?i)connection closed`, CategoryIntegration},
	{`(?i)socket hang up`, CategoryIntegration},

	// Environment errors
	{`(?i)permission denied`, CategoryEnvironment},
	{`(?i)EACCES`, CategoryEnvironment},
	{`(?i)no such file or directory`, CategoryEnvironment},
	{`(?i)ENOENT`, CategoryEnvironment},
	{`(?i)file not found`, CategoryEnvironment},
	{`(?i)command not found`, CategoryEnvironment},
	{`(?i)not found:`, CategoryEnvironment},
	{`(?i)cannot find module`, CategoryEnvironment},
	{`(?i)module not found`, CategoryEnvironment},
	{`(?i)no module named`, CategoryEnvironment},
	{`(?i)package .* is not installed`, CategoryEnvironment},
	{`(?i)missing dependency`, CategoryEnvironment},
	{`(?i)disk full`, CategoryEnvironment},
	{`(?i)ENOSPC`, CategoryEnvironment},
	{`(?i)out of memory`, CategoryEnvironment},
	{`(?i)ENOMEM`, CategoryEnvironment},
	{`(?i)environment variable .* not set`, CategoryEnvironment},
	{`(?i)config file not found`, CategoryEnvironment},

	// Logic errors
	{`(?i)assertion failed`, CategoryLogic},
	{`(?i)AssertionError`, CategoryLogic},
	{`(?i)test failed`, CategoryLogic},
	{`(?i)expected .* but got`, CategoryLogic},
	{`(?i)expected .* to equal`, CategoryLogic},
	{`(?i)does not match`, CategoryLogic},
	{`(?i)mismatch`, CategoryLogic},
	{`(?i)wrong .* returned`, CategoryLogic},
	{`(?i)invalid .* value`, CategoryLogic},
	{`(?i)incorrect result`, CategoryLogic},
	{`(?i)FAIL:`, CategoryLogic},
	{`(?i)--- FAIL`, CategoryLogic},
	{`(?i)✗`, CategoryLogic},
	{`(?i)error in test`, CategoryLogic},
}

// NewClassifier creates a new error classifier with default patterns.
func NewClassifier() *Classifier {
	c := &Classifier{}

	// Add default patterns
	for _, p := range DefaultPatterns {
		regex, err := regexp.Compile(p.Pattern)
		if err != nil {
			continue // Skip invalid patterns
		}
		c.patterns = append(c.patterns, Pattern{
			Regex:    regex,
			Category: p.Category,
		})
	}

	return c
}

// AddPattern adds a custom pattern.
func (c *Classifier) AddPattern(pattern string, category Category) error {
	regex, err := regexp.Compile(pattern)
	if err != nil {
		return err
	}
	c.patterns = append(c.patterns, Pattern{
		Regex:    regex,
		Category: category,
	})
	return nil
}

// AddPatternsFromString parses and adds patterns from a comma-separated string.
// Format: "pattern1:category1,pattern2:category2"
func (c *Classifier) AddPatternsFromString(s string) error {
	if s == "" {
		return nil
	}

	pairs := strings.Split(s, ",")
	for _, pair := range pairs {
		parts := strings.SplitN(strings.TrimSpace(pair), ":", 2)
		if len(parts) != 2 {
			continue
		}
		pattern := strings.TrimSpace(parts[0])
		category := Category(strings.TrimSpace(parts[1]))

		if err := c.AddPattern(pattern, category); err != nil {
			return err
		}
	}
	return nil
}

// Classify analyzes error output and returns the most likely category.
func (c *Classifier) Classify(output string) Category {
	// Count matches for each category
	counts := make(map[Category]int)

	for _, p := range c.patterns {
		if p.Regex.MatchString(output) {
			counts[p.Category]++
		}
	}

	// Find category with most matches
	maxCount := 0
	maxCategory := CategoryUnknown

	for cat, count := range counts {
		if count > maxCount {
			maxCount = count
			maxCategory = cat
		}
	}

	return maxCategory
}

// ClassifyWithMatches returns the category and the patterns that matched.
func (c *Classifier) ClassifyWithMatches(output string) (Category, []string) {
	counts := make(map[Category]int)
	var matches []string

	for _, p := range c.patterns {
		if p.Regex.MatchString(output) {
			counts[p.Category]++
			matches = append(matches, p.Regex.String())
		}
	}

	maxCount := 0
	maxCategory := CategoryUnknown

	for cat, count := range counts {
		if count > maxCount {
			maxCount = count
			maxCategory = cat
		}
	}

	return maxCategory, matches
}

// ExtractErrorMessage attempts to extract a concise error message from output.
func ExtractErrorMessage(output string, maxLen int) string {
	lines := strings.Split(output, "\n")

	// Look for lines that look like error messages
	errorPatterns := []*regexp.Regexp{
		regexp.MustCompile(`(?i)^error:`),
		regexp.MustCompile(`(?i)^Error:`),
		regexp.MustCompile(`(?i)^err:`),
		regexp.MustCompile(`(?i)failed:`),
		regexp.MustCompile(`(?i)^FAIL`),
		regexp.MustCompile(`(?i)^panic:`),
	}

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		for _, pattern := range errorPatterns {
			if pattern.MatchString(line) {
				if len(line) > maxLen {
					return line[:maxLen] + "..."
				}
				return line
			}
		}
	}

	// Fall back to last non-empty line
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if line != "" {
			if len(line) > maxLen {
				return line[:maxLen] + "..."
			}
			return line
		}
	}

	return "Unknown error"
}

// Suggestions returns retry suggestions for a category.
func Suggestions(category Category) string {
	switch category {
	case CategorySyntax:
		return "Try: Check language version, verify imports, review compiler output"
	case CategoryIntegration:
		return "Try: Mock the service, use test doubles, verify service is running"
	case CategoryEnvironment:
		return "Try: Check file paths, verify permissions, ensure dependencies installed"
	case CategoryLogic:
		return "Try: Re-read acceptance criteria, check edge cases, verify test setup"
	default:
		return "Try: Review the error output carefully and take a different approach"
	}
}

// IsRetryable returns true if the error category is typically retryable.
func IsRetryable(category Category) bool {
	switch category {
	case CategoryIntegration:
		return true // Network issues often resolve
	case CategoryEnvironment:
		return false // Usually requires human intervention
	case CategorySyntax:
		return true // Can be fixed by trying different code
	case CategoryLogic:
		return true // Can be fixed by trying different logic
	default:
		return true
	}
}

// ShouldEscalate returns true if the error category suggests escalation.
func ShouldEscalate(category Category, attempts int) bool {
	// Environment errors should escalate quickly
	if category == CategoryEnvironment && attempts >= 1 {
		return true
	}

	// Integration errors might resolve, give more attempts
	if category == CategoryIntegration && attempts >= 3 {
		return true
	}

	// Syntax/logic errors suggest the approach isn't working
	if (category == CategorySyntax || category == CategoryLogic) && attempts >= 2 {
		return true
	}

	return false
}
