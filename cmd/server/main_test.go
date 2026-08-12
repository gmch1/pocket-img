package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
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

func TestEnvironmentDuration(t *testing.T) {
	t.Setenv("PIH_TEST_TIMEOUT", "")
	if value := envDuration("PIH_TEST_TIMEOUT", time.Minute); value != time.Minute {
		t.Fatalf("fallback duration=%s", value)
	}
	t.Setenv("PIH_TEST_TIMEOUT", "3m30s")
	if value := envDuration("PIH_TEST_TIMEOUT", time.Minute); value != 3*time.Minute+30*time.Second {
		t.Fatalf("configured duration=%s", value)
	}
}

func TestConfiguredAdminSpace(t *testing.T) {
	t.Run("single token defaults to its space", func(t *testing.T) {
		t.Setenv("PIH_ADMIN_SPACE_ID", "")
		value, err := configuredAdminSpace(map[string]string{"phone": "token"})
		if err != nil || value != "phone" {
			t.Fatalf("admin=%q err=%v", value, err)
		}
	})
	t.Run("multiple tokens require an explicit admin", func(t *testing.T) {
		t.Setenv("PIH_ADMIN_SPACE_ID", "")
		if _, err := configuredAdminSpace(map[string]string{"alice": "a", "bob": "b"}); err == nil {
			t.Fatal("expected explicit admin error")
		}
	})
	t.Run("explicit admin must exist", func(t *testing.T) {
		t.Setenv("PIH_ADMIN_SPACE_ID", "missing")
		if _, err := configuredAdminSpace(map[string]string{"alice": "a"}); err == nil {
			t.Fatal("expected unknown admin error")
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
