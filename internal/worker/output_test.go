package worker

import (
	"testing"
)

func TestParseOutput(t *testing.T) {
	tests := []struct {
		name         string
		output       string
		wantPromise  Promise
		wantApproach string
		wantAbsorbed string
	}{
		{
			name:        "complete",
			output:      "Did the work\n<promise>COMPLETE</promise>",
			wantPromise: PromiseComplete,
		},
		{
			name:        "blocked",
			output:      "Cannot proceed\n<promise>BLOCKED</promise>",
			wantPromise: PromiseBlocked,
		},
		{
			name:        "already done",
			output:      "<promise>ALREADY_DONE</promise>",
			wantPromise: PromiseAlreadyDone,
		},
		{
			name:         "absorbed by",
			output:       "<promise>ABSORBED_BY:US-002</promise>",
			wantPromise:  PromiseAbsorbedBy,
			wantAbsorbed: "US-002",
		},
		{
			name:         "with approach",
			output:       "<approach>Try direct API call</approach>\nWorking...\n<promise>COMPLETE</promise>",
			wantPromise:  PromiseComplete,
			wantApproach: "Try direct API call",
		},
		{
			name:        "no promise",
			output:      "Still working on it",
			wantPromise: PromiseNeedsIteration,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := ParseOutput(tt.output)

			if result.Promise != tt.wantPromise {
				t.Errorf("Promise = %s, want %s", result.Promise, tt.wantPromise)
			}

			if tt.wantApproach != "" && result.Approach != tt.wantApproach {
				t.Errorf("Approach = %q, want %q", result.Approach, tt.wantApproach)
			}

			if tt.wantAbsorbed != "" && result.AbsorbedBy != tt.wantAbsorbed {
				t.Errorf("AbsorbedBy = %q, want %q", result.AbsorbedBy, tt.wantAbsorbed)
			}
		})
	}
}

func TestExtractLearnings(t *testing.T) {
	output := `
Working on the task...
<learning>The API requires authentication headers</learning>
More work...
<learning>Rate limiting is 100 req/min</learning>
Done.
`

	learnings := ExtractLearnings(output)
	if len(learnings) != 2 {
		t.Errorf("expected 2 learnings, got %d", len(learnings))
	}

	if learnings[0] != "The API requires authentication headers" {
		t.Errorf("unexpected first learning: %s", learnings[0])
	}
}

func TestExtractBacklog(t *testing.T) {
	output := `
Working...
<backlog>Add caching to improve performance</backlog>
<backlog>Consider adding retry logic</backlog>
Done.
`

	items := ExtractBacklog(output)
	if len(items) != 2 {
		t.Errorf("expected 2 backlog items, got %d", len(items))
	}
}

func TestExtractScopeQuestion(t *testing.T) {
	output := `
Starting the task...
<scope-question>Should we use OAuth or JWT for authentication?</scope-question>
Waiting for decision.
`

	question := ExtractScopeQuestion(output)
	if question != "Should we use OAuth or JWT for authentication?" {
		t.Errorf("unexpected scope question: %s", question)
	}
}

func TestStripTags(t *testing.T) {
	output := `
<approach>Test approach</approach>
Actual content here.
<promise>COMPLETE</promise>
<learning>Some learning</learning>
`

	stripped := StripTags(output)
	if stripped != "Actual content here." {
		t.Errorf("StripTags didn't remove all tags: %q", stripped)
	}
}

func TestHasPromise(t *testing.T) {
	if !HasPromise("<promise>COMPLETE</promise>") {
		t.Error("should detect COMPLETE promise")
	}

	if HasPromise("no promise here") {
		t.Error("should not detect promise when none exists")
	}
}

func TestContainsCompleteSignal(t *testing.T) {
	if !ContainsCompleteSignal("<promise>COMPLETE</promise>") {
		t.Error("should detect complete signal")
	}

	if ContainsCompleteSignal("<promise>BLOCKED</promise>") {
		t.Error("should not detect complete in BLOCKED")
	}
}

func TestContainsBlockedSignal(t *testing.T) {
	if !ContainsBlockedSignal("<promise>BLOCKED</promise>") {
		t.Error("should detect blocked signal")
	}

	if ContainsBlockedSignal("<promise>COMPLETE</promise>") {
		t.Error("should not detect blocked in COMPLETE")
	}
}
