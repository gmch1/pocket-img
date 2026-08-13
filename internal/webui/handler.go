package webui

import (
	"io/fs"
	"net/http"
	"path"
	"strings"
)

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
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = w.Write(content)
}

func reservedPath(value string) bool {
	for _, prefix := range []string{"api", "i", "t"} {
		if value == prefix || strings.HasPrefix(value, prefix+"/") {
			return true
		}
	}
	return false
}
