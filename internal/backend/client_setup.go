package backend

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"phone-image-host/internal/webui"
)

const (
	fnosUserIDHeader   = "X-Trim-Userid"
	fnosUsernameHeader = "X-Trim-Username"
	fnosAdminHeader    = "X-Trim-Isadmin"
)

type fnosIdentityContextKey struct{}

type fnosIdentity struct {
	subject     string
	displayName string
	isAdmin     bool
	prefix      string
}

type clientDownload struct {
	Filename     string
	Version      string
	SHA256       string
	Architecture string
	MinimumMacOS string
	SizeBytes    int64
	path         string
}

type clientDownloadResponse struct {
	URL          string `json:"url"`
	Filename     string `json:"filename"`
	Version      string `json:"version"`
	SHA256       string `json:"sha256"`
	Architecture string `json:"architecture"`
	MinimumMacOS string `json:"minimum_macos"`
	SizeBytes    int64  `json:"size_bytes"`
}

func normalizeFNOSConfig(cfg *FNOSConfig) error {
	if cfg.ApplicationVersion == "" {
		cfg.ApplicationVersion = "dev"
	}
	if !cfg.Enabled {
		return nil
	}
	if cfg.GatewayPrefix == "" {
		cfg.GatewayPrefix = "/app/pocket-img"
	}
	prefix := "/" + strings.Trim(cfg.GatewayPrefix, "/")
	if prefix == "/" || prefix != cfg.GatewayPrefix || strings.Contains(prefix, "//") {
		return errors.New("FNOS gateway prefix must be an absolute path without a trailing slash")
	}
	if cfg.ServicePort == 0 {
		cfg.ServicePort = 8080
	}
	if cfg.ServicePort < 1 || cfg.ServicePort > 65535 {
		return errors.New("FNOS service port must be between 1 and 65535")
	}
	if cfg.PublicBaseURL == "" {
		return nil
	}
	parsed, err := url.Parse(cfg.PublicBaseURL)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" || parsed.User != nil {
		return errors.New("public base URL must be an absolute HTTP or HTTPS URL")
	}
	if parsed.RawQuery != "" || parsed.Fragment != "" || (parsed.Path != "" && parsed.Path != "/") {
		return errors.New("public base URL must not contain a path, query, or fragment")
	}
	cfg.PublicBaseURL = strings.TrimSuffix(cfg.PublicBaseURL, "/")
	return nil
}

func loadClientDownload(directory string) (*clientDownload, error) {
	if directory == "" {
		return nil, nil
	}
	manifestPath := filepath.Join(directory, "manifest.json")
	content, err := os.ReadFile(manifestPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read client download manifest: %w", err)
	}
	var manifest struct {
		SchemaVersion int `json:"schema_version"`
		Artifacts     []struct {
			ID               string `json:"id"`
			DisplayName      string `json:"display_name"`
			Version          string `json:"version"`
			Platform         string `json:"platform"`
			Architecture     string `json:"architecture"`
			MinimumOSVersion string `json:"minimum_os_version"`
			Filename         string `json:"filename"`
			ContentType      string `json:"content_type"`
			SHA256           string `json:"sha256"`
		} `json:"artifacts"`
	}
	decoder := json.NewDecoder(strings.NewReader(string(content)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&manifest); err != nil {
		return nil, fmt.Errorf("parse client download manifest: %w", err)
	}
	if manifest.SchemaVersion != 1 {
		return nil, fmt.Errorf("unsupported client download manifest schema version %d", manifest.SchemaVersion)
	}
	var value *struct {
		ID               string `json:"id"`
		DisplayName      string `json:"display_name"`
		Version          string `json:"version"`
		Platform         string `json:"platform"`
		Architecture     string `json:"architecture"`
		MinimumOSVersion string `json:"minimum_os_version"`
		Filename         string `json:"filename"`
		ContentType      string `json:"content_type"`
		SHA256           string `json:"sha256"`
	}
	for index := range manifest.Artifacts {
		candidate := &manifest.Artifacts[index]
		if candidate.Platform == "macos" && candidate.Architecture == "arm64" {
			if value != nil {
				return nil, errors.New("client download manifest contains multiple macOS arm64 artifacts")
			}
			value = candidate
		}
	}
	if value == nil {
		return nil, errors.New("client download manifest does not contain a macOS arm64 artifact")
	}
	if value.Filename == "" || filepath.Base(value.Filename) != value.Filename || strings.Contains(value.Filename, `\`) || !strings.HasSuffix(strings.ToLower(value.Filename), ".zip") {
		return nil, errors.New("client download filename must be a plain .zip filename")
	}
	if value.ID == "" || value.DisplayName == "" || value.Version == "" || value.MinimumOSVersion == "" || value.ContentType != "application/zip" {
		return nil, errors.New("client download id, display_name, version, minimum_os_version, and application/zip content type are required")
	}
	expectedHash := strings.ToLower(value.SHA256)
	decodedHash, err := hex.DecodeString(expectedHash)
	if err != nil || len(decodedHash) != sha256.Size {
		return nil, errors.New("client download sha256 must contain 64 hexadecimal characters")
	}
	archivePath := filepath.Join(directory, value.Filename)
	archive, err := os.Open(archivePath)
	if err != nil {
		return nil, fmt.Errorf("open client download: %w", err)
	}
	hasher := sha256.New()
	size, copyErr := io.Copy(hasher, archive)
	closeErr := archive.Close()
	if copyErr != nil {
		return nil, fmt.Errorf("hash client download: %w", copyErr)
	}
	if closeErr != nil {
		return nil, fmt.Errorf("close client download: %w", closeErr)
	}
	if actual := hex.EncodeToString(hasher.Sum(nil)); actual != expectedHash {
		return nil, fmt.Errorf("client download sha256 mismatch: got %s", actual)
	}
	return &clientDownload{
		Filename: value.Filename, Version: value.Version, SHA256: expectedHash,
		Architecture: value.Architecture, MinimumMacOS: value.MinimumOSVersion,
		SizeBytes: size, path: archivePath,
	}, nil
}

// FNOSHandler exposes the same application through the FNOS unified gateway.
// Identity headers are consumed only inside this explicitly trusted listener;
// Handler(), used by TCP, never interprets them.
func (s *Server) FNOSHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.cfg.FNOS.Enabled {
			http.NotFound(w, r)
			return
		}
		prefix := s.cfg.FNOS.GatewayPrefix
		if r.URL.Path == prefix {
			target := prefix + "/"
			if r.URL.RawQuery != "" {
				target += "?" + r.URL.RawQuery
			}
			http.Redirect(w, r, target, http.StatusPermanentRedirect)
			return
		}
		if !strings.HasPrefix(r.URL.Path, prefix+"/") {
			http.NotFound(w, r)
			return
		}
		identity, err := parseFNOSIdentity(r, prefix)
		if err != nil {
			writeError(w, http.StatusUnauthorized, err.Error())
			return
		}

		cloned := r.Clone(context.WithValue(r.Context(), fnosIdentityContextKey{}, identity))
		cloned.Header = r.Header.Clone()
		cloned.Header.Del(fnosUserIDHeader)
		cloned.Header.Del(fnosUsernameHeader)
		cloned.Header.Del(fnosAdminHeader)
		cloned.URL.Path = strings.TrimPrefix(r.URL.Path, prefix)
		if cloned.URL.Path == "" {
			cloned.URL.Path = "/"
		}
		cloned.URL.RawPath = ""
		cloned = webui.WithBasePath(cloned, prefix)
		s.handler.ServeHTTP(w, cloned)
	})
}

func parseFNOSIdentity(r *http.Request, prefix string) (fnosIdentity, error) {
	subject := strings.TrimSpace(r.Header.Get(fnosUserIDHeader))
	if subject == "" || len(subject) > 256 {
		return fnosIdentity{}, errors.New("FNOS user identity is missing or invalid")
	}
	isAdmin, err := strconv.ParseBool(strings.TrimSpace(r.Header.Get(fnosAdminHeader)))
	if err != nil {
		return fnosIdentity{}, errors.New("FNOS administrator identity is missing or invalid")
	}
	displayName := strings.TrimSpace(r.Header.Get(fnosUsernameHeader))
	displayRunes := []rune(displayName)
	if len(displayRunes) > 128 {
		displayName = string(displayRunes[:128])
	}
	return fnosIdentity{subject: subject, displayName: displayName, isAdmin: isAdmin, prefix: prefix}, nil
}

func fnosIdentityFromRequest(r *http.Request) (fnosIdentity, bool) {
	identity, ok := r.Context().Value(fnosIdentityContextKey{}).(fnosIdentity)
	return identity, ok
}

func fnosOwnerID(subject string) string {
	hash := sha256.Sum256([]byte("fnos\x00" + subject))
	return "fnos-" + base64.RawURLEncoding.EncodeToString(hash[:])
}

func (s *Server) authenticateFNOSRequest(r *http.Request, identity fnosIdentity) (*http.Request, error) {
	ownerID, err := s.store.upsertExternalAccount(
		r.Context(), "fnos", identity.subject, fnosOwnerID(identity.subject), identity.displayName,
		identity.isAdmin, s.cfg.DefaultQuotaBytes, s.cfg.DefaultRetentionDays,
	)
	if err != nil {
		return nil, err
	}
	value := principal{OwnerID: ownerID, IsAdmin: identity.isAdmin}
	return r.WithContext(context.WithValue(r.Context(), principalContextKey{}, value)), nil
}

func (s *Server) clientSetup(w http.ResponseWriter, r *http.Request) {
	identity, ok := fnosIdentityFromRequest(r)
	if !ok {
		http.NotFound(w, r)
		return
	}
	ownerID := authenticatedOwner(r)
	account, found, err := s.store.account(r.Context(), ownerID)
	if err != nil || !found {
		writeError(w, http.StatusInternalServerError, "load FNOS account")
		return
	}
	account.IsAdmin = identity.isAdmin
	configured, err := s.store.accountHasCredential(r.Context(), ownerID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "load client credential")
		return
	}
	response := struct {
		Mode               string                  `json:"mode"`
		ApplicationVersion string                  `json:"app_version"`
		ManagementURL      string                  `json:"management_url"`
		ServiceURL         string                  `json:"service_url"`
		TokenConfigured    bool                    `json:"token_configured"`
		User               accountResponse         `json:"user"`
		Download           *clientDownloadResponse `json:"download,omitempty"`
	}{
		Mode: "fnos", ApplicationVersion: s.cfg.FNOS.ApplicationVersion,
		ManagementURL: identity.prefix + "/", ServiceURL: s.publicBaseURL(r),
		TokenConfigured: configured, User: account.response(),
	}
	if value := s.clientDownload; value != nil {
		response.Download = &clientDownloadResponse{
			URL:      identity.prefix + "/downloads/" + url.PathEscape(value.Filename),
			Filename: value.Filename, Version: value.Version, SHA256: value.SHA256,
			Architecture: value.Architecture, MinimumMacOS: value.MinimumMacOS,
			SizeBytes: value.SizeBytes,
		}
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, response)
}

func (s *Server) rotateClientToken(w http.ResponseWriter, r *http.Request) {
	if _, ok := fnosIdentityFromRequest(r); !ok {
		http.NotFound(w, r)
		return
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		writeError(w, http.StatusInternalServerError, "generate client token")
		return
	}
	token := hex.EncodeToString(raw)
	fingerprint := sha256.Sum256([]byte(token))
	updated, err := s.store.replaceAccountCredential(r.Context(), authenticatedOwner(r), fingerprint[:])
	if err != nil || !updated {
		writeError(w, http.StatusInternalServerError, "store client token")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusCreated, map[string]string{"token": token})
}

func (s *Server) revokeClientToken(w http.ResponseWriter, r *http.Request) {
	if _, ok := fnosIdentityFromRequest(r); !ok {
		http.NotFound(w, r)
		return
	}
	if _, err := s.store.revokeAccountCredential(r.Context(), authenticatedOwner(r)); err != nil {
		writeError(w, http.StatusInternalServerError, "revoke client token")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) serveClientDownload(w http.ResponseWriter, r *http.Request) {
	value := s.clientDownload
	if value == nil || r.PathValue("name") != value.Filename {
		http.NotFound(w, r)
		return
	}
	file, err := os.Open(value.path)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": value.Filename}))
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	http.ServeContent(w, r, value.Filename, info.ModTime(), file)
}

func (s *Server) publicBaseURL(r *http.Request) string {
	if s.cfg.FNOS.PublicBaseURL != "" {
		return s.cfg.FNOS.PublicBaseURL
	}
	host := r.Host
	if parsedHost, _, err := net.SplitHostPort(host); err == nil {
		host = parsedHost
	} else {
		host = strings.Trim(host, "[]")
	}
	return "http://" + net.JoinHostPort(host, strconv.Itoa(s.cfg.FNOS.ServicePort))
}

func (s *Server) responseForRequest(r *http.Request, record imageRecord) imageResponse {
	response := record.response()
	identity, ok := fnosIdentityFromRequest(r)
	if !ok {
		return response
	}
	displayURL := identity.prefix + response.URL
	thumbnailURL := identity.prefix + response.ThumbnailURL
	response.URL = s.publicBaseURL(r) + response.URL
	response.DisplayURL = displayURL
	response.ThumbnailURL = thumbnailURL
	return response
}
