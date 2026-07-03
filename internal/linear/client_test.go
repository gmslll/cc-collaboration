package linear

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestFormatGraphQLErrorsIncludesValidationDetail(t *testing.T) {
	ext := json.RawMessage(`{
		"validationErrors": [
			{
				"children": [
					{
						"constraints": {
							"isUuid": "eq must be a UUID"
						}
					}
				]
			}
		]
	}`)
	got := formatGraphQLErrors([]graphqlError{{
		Message:    "Argument Validation Error",
		Extensions: ext,
	}})
	if !strings.Contains(got, "Argument Validation Error") || !strings.Contains(got, "eq must be a UUID") {
		t.Fatalf("formatGraphQLErrors() = %q", got)
	}
}
