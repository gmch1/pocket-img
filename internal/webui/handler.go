package webui

import (
	"context"
	"html"
	"io/fs"
	"net/http"
	"path"
	"strings"
)

type basePathContextKey struct{}

type handler struct {
	files      fs.FS
	fileServer http.Handler
}

func Handler() http.Handler {
	files, err := fs.Sub(assets, "dist")
	if err != nil {
		panic(err)
	}
	return newHandler(files)
}

// WithBasePath tells the embedded UI where its application root is mounted.
// It is used by the trusted FNOS gateway wrapper after it removes the gateway
// prefix from the request passed to the normal application router.
func WithBasePath(r *http.Request, basePath string) *http.Request {
	cleaned := "/" + strings.Trim(path.Clean("/"+basePath), "/")
	if cleaned != "/" {
		cleaned += "/"
	}
	return r.WithContext(
		context.WithValue(r.Context(), basePathContextKey{}, cleaned),
	)
}

func newHandler(files fs.FS) http.Handler {
	return &handler{files: files, fileServer: http.FileServer(http.FS(files))}
}

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	cleanPath := strings.TrimPrefix(path.Clean("/"+r.URL.Path), "/")
	if reservedPath(cleanPath) {
		http.NotFound(w, r)
		return
	}
	if cleanPath == "" {
		h.serveIndex(w, r)
		return
	}
	info, err := fs.Stat(h.files, cleanPath)
	if err != nil || info.IsDir() {
		h.serveIndex(w, r)
		return
	}
	if cleanPath == "index.html" {
		w.Header().Set("Cache-Control", "no-cache")
	} else if strings.HasPrefix(cleanPath, "assets/") {
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	}
	cloned := r.Clone(r.Context())
	cloned.URL.Path = "/" + cleanPath
	h.fileServer.ServeHTTP(w, cloned)
}

func (h *handler) serveIndex(w http.ResponseWriter, r *http.Request) {
	content, err := fs.ReadFile(h.files, "index.html")
	if err != nil {
		http.Error(w, "frontend build is missing", http.StatusServiceUnavailable)
		return
	}
	basePath, _ := r.Context().Value(basePathContextKey{}).(string)
	if basePath == "" {
		basePath = "/"
	}
	content = []byte(strings.Replace(
		string(content),
		`<base href="/" />`,
		`<base href="`+html.EscapeString(basePath)+`" />`,
		1,
	))
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = w.Write(content)
}

func reservedPath(value string) bool {
	for _, prefix := range []string{"api", "downloads", "i", "t"} {
		if value == prefix || strings.HasPrefix(value, prefix+"/") {
			return true
		}
	}
	return false
}
