package worker

import (
	"regexp"
	"strings"
	"time"
)

// Tag patterns for extracting structured data from worker output
var (
	promisePattern       = regexp.MustCompile(`<promise>(.*?)</promise>`)
	learningPattern      = regexp.MustCompile(`(?s)<learning>(.*?)</learning>`)
	backlogPattern       = regexp.MustCompile(`(?s)<backlog>(.*?)</backlog>`)
	approachPattern      = regexp.MustCompile(`(?s)<approach>(.*?)</approach>`)
	scopeQuestionPattern = regexp.MustCompile(`(?s)<scope-question>(.*?)</scope-question>`)
	absorbedByPattern    = regexp.MustCompile(`ABSORBED_BY:(\S+)`)
)

// ParseOutput extracts structured data from worker output.
func ParseOutput(output string) *Result {
	result := &Result{
		Output: output,
	}

	// Extract promise
	if matches := promisePattern.FindStringSubmatch(output); len(matches) > 1 {
		promise := strings.TrimSpace(matches[1])
		switch {
		case promise == "COMPLETE":
			result.Promise = PromiseComplete
		case promise == "BLOCKED":
			result.Promise = PromiseBlocked
		case promise == "ALREADY_DONE":
			result.Promise = PromiseAlreadyDone
		case strings.HasPrefix(promise, "ABSORBED_BY"):
			result.Promise = PromiseAbsorbedBy
			if absMatches := absorbedByPattern.FindStringSubmatch(promise); len(absMatches) > 1 {
				result.AbsorbedBy = absMatches[1]
			}
		default:
			// Unknown promise, treat as needs iteration
			result.Promise = PromiseNeedsIteration
		}
	}

	// Extract learnings
	for _, match := range learningPattern.FindAllStringSubmatch(output, -1) {
		if len(match) > 1 {
			learning := strings.TrimSpace(match[1])
			if learning != "" {
				result.Learnings = append(result.Learnings, learning)
			}
		}
	}

	// Extract backlog items
	for _, match := range backlogPattern.FindAllStringSubmatch(output, -1) {
		if len(match) > 1 {
			item := strings.TrimSpace(match[1])
			if item != "" {
				result.Backlog = append(result.Backlog, item)
			}
		}
	}

	// Extract approach
	if matches := approachPattern.FindStringSubmatch(output); len(matches) > 1 {
		result.Approach = strings.TrimSpace(matches[1])
	}

	// Extract scope question
	if matches := scopeQuestionPattern.FindStringSubmatch(output); len(matches) > 1 {
		result.ScopeQuestion = strings.TrimSpace(matches[1])
	}

	return result
}

// HasPromise returns true if the output contains any promise tag.
func HasPromise(output string) bool {
	return promisePattern.MatchString(output)
}

// ExtractPromise extracts just the promise from output.
func ExtractPromise(output string) Promise {
	if matches := promisePattern.FindStringSubmatch(output); len(matches) > 1 {
		promise := strings.TrimSpace(matches[1])
		switch {
		case promise == "COMPLETE":
			return PromiseComplete
		case promise == "BLOCKED":
			return PromiseBlocked
		case promise == "ALREADY_DONE":
			return PromiseAlreadyDone
		case strings.HasPrefix(promise, "ABSORBED_BY"):
			return PromiseAbsorbedBy
		}
	}
	return PromiseNeedsIteration
}

// ExtractLearnings extracts learning entries from output.
func ExtractLearnings(output string) []string {
	var learnings []string
	for _, match := range learningPattern.FindAllStringSubmatch(output, -1) {
		if len(match) > 1 {
			learning := strings.TrimSpace(match[1])
			if learning != "" {
				learnings = append(learnings, learning)
			}
		}
	}
	return learnings
}

// ExtractBacklog extracts backlog entries from output.
func ExtractBacklog(output string) []string {
	var items []string
	for _, match := range backlogPattern.FindAllStringSubmatch(output, -1) {
		if len(match) > 1 {
			item := strings.TrimSpace(match[1])
			if item != "" {
				items = append(items, item)
			}
		}
	}
	return items
}

// ExtractApproach extracts the approach from output.
func ExtractApproach(output string) string {
	if matches := approachPattern.FindStringSubmatch(output); len(matches) > 1 {
		return strings.TrimSpace(matches[1])
	}
	return ""
}

// ExtractScopeQuestion extracts scope question from output.
func ExtractScopeQuestion(output string) string {
	if matches := scopeQuestionPattern.FindStringSubmatch(output); len(matches) > 1 {
		return strings.TrimSpace(matches[1])
	}
	return ""
}

// StripTags removes all Brigade-specific tags from output for cleaner display.
func StripTags(output string) string {
	result := output
	result = promisePattern.ReplaceAllString(result, "")
	result = learningPattern.ReplaceAllString(result, "")
	result = backlogPattern.ReplaceAllString(result, "")
	result = approachPattern.ReplaceAllString(result, "")
	result = scopeQuestionPattern.ReplaceAllString(result, "")
	return strings.TrimSpace(result)
}

// ContainsBlockedSignal checks for explicit blocked signal.
func ContainsBlockedSignal(output string) bool {
	return strings.Contains(output, "<promise>BLOCKED</promise>")
}

// ContainsCompleteSignal checks for explicit complete signal.
func ContainsCompleteSignal(output string) bool {
	return strings.Contains(output, "<promise>COMPLETE</promise>")
}

// MergeResults merges multiple results (e.g., from continued sessions).
func MergeResults(results ...*Result) *Result {
	if len(results) == 0 {
		return &Result{}
	}

	merged := &Result{
		Promise: PromiseNeedsIteration,
	}

	var outputs []string
	var totalDuration int64

	for _, r := range results {
		if r == nil {
			continue
		}

		outputs = append(outputs, r.Output)
		totalDuration += int64(r.Duration)

		// Take the last promise
		if r.Promise != PromiseNeedsIteration {
			merged.Promise = r.Promise
			merged.AbsorbedBy = r.AbsorbedBy
		}

		// Accumulate learnings and backlog
		merged.Learnings = append(merged.Learnings, r.Learnings...)
		merged.Backlog = append(merged.Backlog, r.Backlog...)

		// Take last approach
		if r.Approach != "" {
			merged.Approach = r.Approach
		}

		// Take last scope question
		if r.ScopeQuestion != "" {
			merged.ScopeQuestion = r.ScopeQuestion
		}

		// Propagate errors
		if r.Error != nil {
			merged.Error = r.Error
		}
		if r.Timeout {
			merged.Timeout = true
		}
		if r.Crashed {
			merged.Crashed = true
		}
	}

	merged.Output = strings.Join(outputs, "\n---\n")
	merged.Duration = time.Duration(totalDuration)

	return merged
}
