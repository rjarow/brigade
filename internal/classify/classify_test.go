package classify

import (
	"testing"
)

func TestClassify(t *testing.T) {
	c := NewClassifier()

	tests := []struct {
		output   string
		expected Category
	}{
		// Syntax errors
		{"SyntaxError: unexpected token '}'", CategorySyntax},
		{"parse error: invalid syntax", CategorySyntax},
		{"compilation failed: undefined reference", CategorySyntax},

		// Integration errors
		{"Error: connection refused", CategoryIntegration},
		{"ECONNREFUSED: could not connect to server", CategoryIntegration},
		{"timeout waiting for response", CategoryIntegration},
		{"503 Service Unavailable", CategoryIntegration},

		// Environment errors
		{"Error: permission denied", CategoryEnvironment},
		{"ENOENT: no such file or directory", CategoryEnvironment},
		{"command not found: npm", CategoryEnvironment},
		{"Error: cannot find module 'express'", CategoryEnvironment},

		// Logic errors
		{"AssertionError: expected 5 but got 3", CategoryLogic},
		{"--- FAIL: TestAdd (0.00s)", CategoryLogic},
		{"test failed: expected true", CategoryLogic},

		// Unknown
		{"some random output", CategoryUnknown},
	}

	for _, tt := range tests {
		got := c.Classify(tt.output)
		if got != tt.expected {
			t.Errorf("Classify(%q) = %s, want %s", tt.output, got, tt.expected)
		}
	}
}

func TestAddCustomPattern(t *testing.T) {
	c := NewClassifier()

	// Add custom pattern
	err := c.AddPattern(`MyCustomError`, CategoryLogic)
	if err != nil {
		t.Fatalf("AddPattern failed: %v", err)
	}

	got := c.Classify("Error: MyCustomError occurred")
	if got != CategoryLogic {
		t.Errorf("expected CategoryLogic, got %s", got)
	}
}

func TestAddPatternsFromString(t *testing.T) {
	c := NewClassifier()

	err := c.AddPatternsFromString("CustomSyntaxError:syntax,NetworkTimeout:integration")
	if err != nil {
		t.Fatalf("AddPatternsFromString failed: %v", err)
	}

	if c.Classify("CustomSyntaxError: invalid") != CategorySyntax {
		t.Error("custom syntax pattern not matched")
	}

	if c.Classify("NetworkTimeout: failed") != CategoryIntegration {
		t.Error("custom integration pattern not matched")
	}
}

func TestExtractErrorMessage(t *testing.T) {
	tests := []struct {
		output   string
		maxLen   int
		contains string
	}{
		{"error: something bad", 100, "error: something bad"},
		{"Line 1\nerror: the actual error\nLine 3", 100, "error: the actual error"},
		{"FAIL TestSomething", 100, "FAIL TestSomething"},
	}

	for _, tt := range tests {
		got := ExtractErrorMessage(tt.output, tt.maxLen)
		if got != tt.contains {
			t.Errorf("ExtractErrorMessage(%q) = %q, want to contain %q", tt.output, got, tt.contains)
		}
	}
}

func TestSuggestions(t *testing.T) {
	tests := []struct {
		category Category
		contains string
	}{
		{CategorySyntax, "Check language version"},
		{CategoryIntegration, "Mock the service"},
		{CategoryEnvironment, "Check file paths"},
		{CategoryLogic, "Re-read acceptance criteria"},
	}

	for _, tt := range tests {
		got := Suggestions(tt.category)
		if got == "" {
			t.Errorf("Suggestions(%s) returned empty", tt.category)
		}
	}
}

func TestIsRetryable(t *testing.T) {
	if !IsRetryable(CategoryIntegration) {
		t.Error("integration errors should be retryable")
	}

	if IsRetryable(CategoryEnvironment) {
		t.Error("environment errors should not be retryable")
	}

	if !IsRetryable(CategorySyntax) {
		t.Error("syntax errors should be retryable")
	}

	if !IsRetryable(CategoryLogic) {
		t.Error("logic errors should be retryable")
	}
}
