package main

import (
	"bytes"
	"crypto/rand"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"phone-image-host/internal/backend"
)

func initEnvironment(t *testing.T) string {
	t.Helper()
	clearTokenEnvironment(t)
	t.Setenv("PIH_ADMIN_SPACE_ID", "")
	t.Setenv("PIH_FNOS_SOCKET", "")
	dir := t.TempDir()
	t.Setenv("PIH_DATA_DIR", dir)
	return filepath.Join(dir, "tokens.json")
}

func TestInitCreatesDisplaysAndReusesCredentials(t *testing.T) {
	path := initEnvironment(t)
	var out bytes.Buffer
	if err := runInit(nil, &out); err != nil {
		t.Fatal(err)
	}
	tokens, err := configuredTokens()
	if err != nil {
		t.Fatal(err)
	}
	if len(tokens["admin"]) != 64 || !strings.Contains(out.String(), tokens["admin"]) {
		t.Fatal("missing generated credential in installer output")
	}
	before, _ := os.ReadFile(path)
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o600 {
		t.Fatal("incorrect credential permissions")
	}
	if err := os.WriteFile(filepath.Join(filepath.Dir(path), "metadata.sqlite3"), []byte("existing data"), 0o600); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := runInit(nil, &out); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(before, after) || !strings.Contains(out.String(), tokens["admin"]) {
		t.Fatal("reinstallation changed credentials")
	}
}

func TestInitProtectsExistingDataAndInvalidFiles(t *testing.T) {
	for _, kind := range []string{"data", "invalid", "permissions", "symlink", "explicit-missing", "conflict"} {
		t.Run(kind, func(t *testing.T) {
			path := initEnvironment(t)
			switch kind {
			case "data":
				if err := os.WriteFile(filepath.Join(filepath.Dir(path), "metadata.sqlite3"), []byte("keep"), 0o600); err != nil {
					t.Fatal(err)
				}
			case "invalid":
				if err := os.WriteFile(path, []byte("broken"), 0o600); err != nil {
					t.Fatal(err)
				}
			case "permissions":
				if err := os.WriteFile(path, []byte(`{"admin":"keep"}`), 0o644); err != nil {
					t.Fatal(err)
				}
			case "symlink":
				if err := os.Symlink(filepath.Join(filepath.Dir(path), "missing"), path); err != nil {
					t.Fatal(err)
				}
			case "explicit-missing":
				t.Setenv("PIH_TOKENS_FILE", path)
			case "conflict":
				t.Setenv("PIH_TOKEN", "keep")
				t.Setenv("PIH_TOKENS", `{"admin":"other"}`)
			}
			before, _ := os.ReadFile(path)
			var out bytes.Buffer
			if err := runInit(nil, &out); err == nil {
				t.Fatal("expected initialization failure")
			}
			if out.Len() != 0 {
				t.Fatal("failed initialization printed credentials")
			}
			after, _ := os.ReadFile(path)
			if !bytes.Equal(before, after) {
				t.Fatal("overwrote existing configuration")
			}
			if kind == "data" || kind == "explicit-missing" || kind == "conflict" {
				if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
					t.Fatal("created credentials after failure")
				}
			}
		})
	}
}

func TestInitRandomFailureAndRetry(t *testing.T) {
	path := initEnvironment(t)
	if _, _, err := initializeTokens(path, strings.NewReader("")); err == nil {
		t.Fatal("expected random failure")
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("published credentials on failure")
	}
	if _, _, err := initializeTokens(path, rand.Reader); err != nil {
		t.Fatal(err)
	}
}

func TestInitConcurrentInstallers(t *testing.T) {
	path := initEnvironment(t)
	var wg sync.WaitGroup
	results := make(chan string, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			tokens, _, err := initializeTokens(path, rand.Reader)
			if err == nil {
				results <- tokens["admin"]
			}
		}()
	}
	wg.Wait()
	close(results)
	stored, err := readManagedTokens(path)
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for token := range results {
		count++
		if token != stored["admin"] {
			t.Fatal("concurrent installers returned different credentials")
		}
	}
	if count == 0 {
		t.Fatal("no installer succeeded")
	}
}

func TestInitPreservesLegacyAndRejectsFNOS(t *testing.T) {
	path := initEnvironment(t)
	t.Setenv("PIH_TOKEN", "legacy-token")
	var out bytes.Buffer
	if err := runInit(nil, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "default") || !strings.Contains(out.String(), "legacy-token") {
		t.Fatal("legacy identity changed")
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("created a second token source")
	}
	t.Setenv("PIH_FNOS_SOCKET", "/tmp/fnos.sock")
	out.Reset()
	if err := runInit(nil, &out); err == nil || out.Len() != 0 {
		t.Fatal("initialized fnOS credentials")
	}
}

func TestInstalledTokenAuthenticates(t *testing.T) {
	initEnvironment(t)
	var output bytes.Buffer
	if err := runInit(nil, &output); err != nil {
		t.Fatal(err)
	}
	tokens, err := configuredTokens()
	if err != nil {
		t.Fatal(err)
	}
	app, err := backend.New(backend.Config{DataDir: os.Getenv("PIH_DATA_DIR"), Tokens: tokens, AdminSpaceID: "admin"})
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	req := httptest.NewRequest(http.MethodPost, "http://localhost/api/auth/session", nil)
	req.Header.Set("Authorization", "Bearer "+tokens["admin"])
	response := httptest.NewRecorder()
	app.Handler().ServeHTTP(response, req)
	if response.Code < 200 || response.Code >= 300 || len(response.Result().Cookies()) == 0 {
		t.Fatalf("installed token cannot establish a session: status=%d", response.Code)
	}
}

func TestInitWriteFailureAndInterruptedFile(t *testing.T) {
	path := initEnvironment(t)
	if err := os.WriteFile(filepath.Join(filepath.Dir(path), ".pocketimg-token-interrupted"), []byte("partial"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := initializeTokens(path, rand.Reader); err == nil {
		t.Fatal("ignored interrupted state")
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("created credentials after interrupted write")
	}
	// A regular file cannot be used as the output's parent directory.
	blocked := filepath.Join(t.TempDir(), "blocked")
	if err := os.WriteFile(blocked, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := initializeTokens(filepath.Join(blocked, "tokens.json"), rand.Reader); err == nil {
		t.Fatal("expected write failure")
	}
}

func TestInitExplicitConfigurations(t *testing.T) {
	for _, source := range []string{"file", "inline"} {
		t.Run(source, func(t *testing.T) {
			path := initEnvironment(t)
			value := `{"alice":"alice-token","bob":"bob-token"}`
			t.Setenv("PIH_ADMIN_SPACE_ID", "bob")
			if source == "file" {
				custom := filepath.Join(t.TempDir(), "custom.json")
				if err := os.WriteFile(custom, []byte(value), 0o600); err != nil {
					t.Fatal(err)
				}
				t.Setenv("PIH_TOKENS_FILE", custom)
			} else {
				t.Setenv("PIH_TOKENS", value)
			}
			var output bytes.Buffer
			if err := runInit(nil, &output); err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(output.String(), "bob-token") || strings.Contains(output.String(), "alice-token") {
				t.Fatal("did not select only administrator credential")
			}
			if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("created competing configuration")
			}
		})
	}
}
