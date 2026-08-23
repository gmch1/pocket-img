package webui

import (
	"errors"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

func fixtureHandler() http.Handler {
	return newHandler(fstest.MapFS{
		"index.html": &fstest.MapFile{Data: []byte(`<!doctype html><base href="/" /><div id="root"></div>`)},
	})
}

func TestHandlerServesIndexAndSPAFallback(t *testing.T) {
	handler := fixtureHandler()
	for _, requestPath := range []string{"/", "/gallery/deep-link"} {
		request := httptest.NewRequest(http.MethodGet, requestPath, nil)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != http.StatusOK {
			t.Fatalf("path=%s status=%d body=%s", requestPath, response.Code, response.Body.String())
		}
		if !strings.Contains(response.Body.String(), `id="root"`) {
			t.Fatalf("path=%s did not serve the frontend index", requestPath)
		}
		if response.Header().Get("Cache-Control") != "no-cache" {
			t.Fatalf("path=%s cache=%q", requestPath, response.Header().Get("Cache-Control"))
		}
	}
}

func TestHandlerDoesNotMaskReservedBackendPaths(t *testing.T) {
	handler := fixtureHandler()
	for _, requestPath := range []string{"/api/unknown", "/downloads/client.zip", "/i/unknown.webp", "/t/unknown.webp"} {
		request := httptest.NewRequest(http.MethodGet, requestPath, nil)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != http.StatusNotFound {
			t.Fatalf("path=%s status=%d", requestPath, response.Code)
		}
	}
}

func TestHandlerInjectsGatewayBasePath(t *testing.T) {
	handler := fixtureHandler()
	request := httptest.NewRequest(http.MethodGet, "http://backend/", nil)
	request = WithBasePath(request, "/app/pocket-img")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if !strings.Contains(response.Body.String(), `<base href="/app/pocket-img/" />`) {
		t.Fatalf("gateway base path was not injected: %s", response.Body.String())
	}
}

func TestEmbeddedFrontendBuildWhenPresent(t *testing.T) {
	content, err := fs.ReadFile(assets, "dist/index.html")
	if err != nil {
		if !errors.Is(err, fs.ErrNotExist) {
			t.Fatalf("read embedded index: %v", err)
		}
		t.Skip("frontend build is not present; run make frontend-build")
	}
	if !strings.Contains(string(content), `id="root"`) {
		t.Fatal("embedded frontend index is invalid")
	}
}
