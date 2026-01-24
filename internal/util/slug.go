// Package util provides shared utilities for Brigade.
package util

import (
	"regexp"
	"strings"
)

// Slugify converts a string to a URL-friendly slug.
// It lowercases, replaces non-alphanumeric with dashes, collapses multiple dashes,
// and trims leading/trailing dashes.
func Slugify(s string, maxLen int) string {
	// Lowercase
	slug := strings.ToLower(s)

	// Replace non-alphanumeric with dashes
	reg := regexp.MustCompile(`[^a-z0-9]+`)
	slug = reg.ReplaceAllString(slug, "-")

	// Collapse multiple dashes
	reg = regexp.MustCompile(`-+`)
	slug = reg.ReplaceAllString(slug, "-")

	// Trim leading/trailing dashes
	slug = strings.Trim(slug, "-")

	// Truncate at word boundary (dash)
	if len(slug) > maxLen {
		slug = slug[:maxLen]
		// Trim trailing dash after truncation
		slug = strings.TrimSuffix(slug, "-")
	}

	return slug
}

// ToCapitalized returns the string with the first letter uppercase.
func ToCapitalized(s string) string {
	if len(s) == 0 {
		return s
	}
	return strings.ToUpper(string(s[0])) + s[1:]
}

// ToSingular performs simple singularization of common plural endings.
func ToSingular(s string) string {
	if strings.HasSuffix(s, "ies") {
		return s[:len(s)-3] + "y"
	}
	if (strings.HasSuffix(s, "ses") || strings.HasSuffix(s, "xes")) {
		return s[:len(s)-2]
	}
	if strings.HasSuffix(s, "s") && !strings.HasSuffix(s, "ss") {
		return s[:len(s)-1]
	}
	return s
}
