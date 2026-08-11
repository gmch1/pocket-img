package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestConfiguredTokensSources(t *testing.T) {
	t.Run("legacy", func(t *testing.T) {
		clearTokenEnvironment(t)
		t.Setenv("PIH_TOKEN", "legacy-token")
		tokens, err := configuredTokens()
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(tokens, map[string]string{"default": "legacy-token"}) {
			t.Fatalf("tokens=%#v", tokens)
		}
	})

	t.Run("inline JSON", func(t *testing.T) {
		clearTokenEnvironment(t)
		t.Setenv("PIH_TOKENS", `{"alice":"alice-token","bob":"bob-token"}`)
		tokens, err := configuredTokens()
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(tokens, map[string]string{"alice": "alice-token", "bob": "bob-token"}) {
			t.Fatalf("tokens=%#v", tokens)
		}
	})

	t.Run("JSON file", func(t *testing.T) {
		clearTokenEnvironment(t)
		path := filepath.Join(t.TempDir(), "tokens.json")
		if err := os.WriteFile(path, []byte(`{"phone":"phone-token"}`), 0o600); err != nil {
			t.Fatal(err)
		}
		t.Setenv("PIH_TOKENS_FILE", path)
		tokens, err := configuredTokens()
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(tokens, map[string]string{"phone": "phone-token"}) {
			t.Fatalf("tokens=%#v", tokens)
		}
	})
}

func TestConfiguredTokensRejectsMissingConflictingAndInvalidSources(t *testing.T) {
	t.Run("missing", func(t *testing.T) {
		clearTokenEnvironment(t)
		if _, err := configuredTokens(); err == nil {
			t.Fatal("expected missing token configuration error")
		}
	})

	t.Run("conflicting", func(t *testing.T) {
		clearTokenEnvironment(t)
		t.Setenv("PIH_TOKEN", "legacy")
		t.Setenv("PIH_TOKENS", `{"alice":"token"}`)
		if _, err := configuredTokens(); err == nil {
			t.Fatal("expected conflicting token configuration error")
		}
	})

	t.Run("invalid JSON", func(t *testing.T) {
		clearTokenEnvironment(t)
		t.Setenv("PIH_TOKENS", `{invalid`)
		if _, err := configuredTokens(); err == nil {
			t.Fatal("expected invalid JSON error")
		}
	})
}

func clearTokenEnvironment(t *testing.T) {
	t.Helper()
	t.Setenv("PIH_TOKEN", "")
	t.Setenv("PIH_TOKENS", "")
	t.Setenv("PIH_TOKENS_FILE", "")
}
