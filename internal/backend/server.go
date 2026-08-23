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
	"log"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"phone-image-host/internal/webui"
)

const sessionCookieName = "pih_session"

type credential struct {
	ownerID     string
	fingerprint [sha256.Size]byte
}

type principalContextKey struct{}

type Server struct {
	cfg            Config
	store          *store
	processor      *processor
	handler        http.Handler
	queueSlots     chan struct{}
	processSlots   chan struct{}
	location       *time.Location
	thumbnailCtx   context.Context
	thumbnailStop  context.CancelFunc
	thumbnailWake  chan struct{}
	rateLimits     *rateLimiter
	galleryEvents  *galleryEvents
	clientDownload *clientDownload
	workerWG       sync.WaitGroup
	thumbnailMu    sync.Mutex
	closeOnce      sync.Once
	closeErr       error
}

func New(cfg Config) (*Server, error) {
	if cfg.DataDir == "" {
		return nil, errors.New("data directory is required")
	}
	if err := normalizeFNOSConfig(&cfg.FNOS); err != nil {
		return nil, err
	}
	var credentials []credential
	var err error
	if len(cfg.Tokens) == 0 {
		if !cfg.FNOS.Enabled {
			return nil, errors.New("at least one configured token is required")
		}
	} else {
		credentials, err = configuredCredentials(cfg.Tokens)
		if err != nil {
			return nil, err
		}
	}
	if cfg.SessionTTL <= 0 {
		cfg.SessionTTL = 7 * 24 * time.Hour
	}
	if cfg.DefaultQuotaBytes <= 0 {
		cfg.DefaultQuotaBytes = defaultUserQuotaBytes
	}
	if cfg.DefaultRetentionDays <= 0 {
		cfg.DefaultRetentionDays = defaultRetentionDays
	}
	if cfg.CleanupInterval <= 0 {
		cfg.CleanupInterval = time.Hour
	}
	if cfg.MaxUploadBytes <= 0 {
		cfg.MaxUploadBytes = 25 << 20
	}
	if cfg.MaxPixels <= 0 {
		cfg.MaxPixels = 20_000_000
	}
	if cfg.ThumbnailMax <= 0 {
		cfg.ThumbnailMax = 640
	}
	if cfg.WebPQuality <= 0 {
		cfg.WebPQuality = 82
	}
	if cfg.ThumbQuality <= 0 {
		cfg.ThumbQuality = 75
	}
	if cfg.QueueDepth <= 0 {
		cfg.QueueDepth = 8
	}
	cfg.RateLimits = cfg.RateLimits.withDefaults()
	if len(credentials) > 0 {
		if !validOwnerID(cfg.AdminSpaceID) {
			return nil, errors.New("a valid admin space id is required")
		}
		adminConfigured := false
		for _, configured := range credentials {
			if configured.ownerID == cfg.AdminSpaceID {
				adminConfigured = true
				break
			}
		}
		if !adminConfigured {
			return nil, fmt.Errorf("admin space %q is not one of the configured token spaces", cfg.AdminSpaceID)
		}
	}
	clientDownload, err := loadClientDownload(cfg.FNOS.DownloadsDir)
	if err != nil {
		return nil, err
	}

	for _, directory := range []string{
		cfg.DataDir,
		filepath.Join(cfg.DataDir, "tmp"),
		filepath.Join(cfg.DataDir, "objects"),
		filepath.Join(cfg.DataDir, "thumbnails"),
	} {
		if err := os.MkdirAll(directory, 0o750); err != nil {
			return nil, err
		}
	}

	database, err := openStore(cfg.DataDir)
	if err != nil {
		return nil, err
	}
	location, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		database.close()
		return nil, err
	}

	thumbnailCtx, thumbnailStop := context.WithCancel(context.Background())
	server := &Server{
		cfg:            cfg,
		store:          database,
		processor:      newProcessor(cfg),
		queueSlots:     make(chan struct{}, cfg.QueueDepth),
		processSlots:   make(chan struct{}, 1),
		location:       location,
		thumbnailCtx:   thumbnailCtx,
		thumbnailStop:  thumbnailStop,
		thumbnailWake:  make(chan struct{}, 1),
		rateLimits:     newRateLimiter(cfg.RateLimits),
		galleryEvents:  newGalleryEvents(),
		clientDownload: clientDownload,
	}
	legacyImages, err := server.store.hasLegacyImages(context.Background())
	if err != nil {
		server.Close()
		return nil, fmt.Errorf("inspect legacy image ownership: %w", err)
	}
	if legacyImages {
		legacyOwner := ""
		if len(credentials) == 1 {
			legacyOwner = credentials[0].ownerID
		} else {
			for _, candidate := range credentials {
				if candidate.ownerID == "default" {
					legacyOwner = candidate.ownerID
					break
				}
			}
		}
		if legacyOwner == "" {
			server.Close()
			return nil, errors.New("legacy single-token images require one configured space or a space named default")
		}
		adopted, err := server.store.adoptLegacyOwner(context.Background(), legacyOwner)
		if err != nil {
			server.Close()
			return nil, fmt.Errorf("adopt legacy image ownership: %w", err)
		}
		if adopted {
			records, err := server.store.listAllImagesForOwner(context.Background(), legacyOwner)
			if err != nil {
				server.Close()
				return nil, fmt.Errorf("load legacy images: %w", err)
			}
			if err := server.processor.migrateLegacyFiles(records); err != nil {
				server.Close()
				return nil, fmt.Errorf("migrate legacy image files: %w", err)
			}
		}
	}
	// An FNOS-only deployment has no static token source. In that mode, keep
	// accounts already stored in /data enabled so an existing Linux data
	// directory remains reachable with its old tokens. FNOS identities are
	// provisioned separately because there is no safe way to guess ownership.
	if len(credentials) > 0 {
		if err := server.store.syncUsers(
			context.Background(), credentials, cfg.AdminSpaceID, cfg.DefaultQuotaBytes, cfg.DefaultRetentionDays,
		); err != nil {
			server.Close()
			return nil, fmt.Errorf("sync configured users: %w", err)
		}
	}
	if err := server.store.deleteExpiredSessions(context.Background(), time.Now()); err != nil {
		server.Close()
		return nil, err
	}
	server.handler = server.routes()
	server.workerWG.Add(2)
	go server.runThumbnailWorker()
	go server.runCleanupWorker()
	return server, nil
}

func configuredCredentials(tokens map[string]string) ([]credential, error) {
	if len(tokens) == 0 {
		return nil, errors.New("at least one configured token is required")
	}
	ownerIDs := make([]string, 0, len(tokens))
	for ownerID := range tokens {
		ownerIDs = append(ownerIDs, ownerID)
	}
	sort.Strings(ownerIDs)

	credentials := make([]credential, 0, len(tokens))
	seen := make(map[[sha256.Size]byte]string, len(tokens))
	for _, ownerID := range ownerIDs {
		if !validOwnerID(ownerID) {
			return nil, fmt.Errorf("invalid space id %q: use 1-64 letters, numbers, underscores, or hyphens", ownerID)
		}
		token := tokens[ownerID]
		if token == "" {
			return nil, fmt.Errorf("token for space %q is empty", ownerID)
		}
		fingerprint := sha256.Sum256([]byte(token))
		if existing, duplicate := seen[fingerprint]; duplicate {
			return nil, fmt.Errorf("spaces %q and %q use the same token", existing, ownerID)
		}
		seen[fingerprint] = ownerID
		credentials = append(credentials, credential{ownerID: ownerID, fingerprint: fingerprint})
	}
	return credentials, nil
}

func validOwnerID(value string) bool {
	if len(value) < 1 || len(value) > 64 {
		return false
	}
	for _, character := range value {
		if character >= 'a' && character <= 'z' ||
			character >= 'A' && character <= 'Z' ||
			character >= '0' && character <= '9' ||
			character == '_' || character == '-' {
			continue
		}
		return false
	}
	return true
}

func (s *Server) Handler() http.Handler {
	return s.handler
}

func (s *Server) Close() error {
	s.closeOnce.Do(func() {
		s.thumbnailStop()
		s.workerWG.Wait()
		s.closeErr = s.store.close()
	})
	return s.closeErr
}

func (s *Server) wakeThumbnailWorker() {
	select {
	case s.thumbnailWake <- struct{}{}:
	default:
	}
}

func (s *Server) runThumbnailWorker() {
	defer s.workerWG.Done()
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()

	for {
		s.processPendingThumbnails()
		select {
		case <-s.thumbnailCtx.Done():
			return
		case <-s.thumbnailWake:
		case <-ticker.C:
		}
	}
}

func (s *Server) runCleanupWorker() {
	defer s.workerWG.Done()
	ticker := time.NewTicker(s.cfg.CleanupInterval)
	defer ticker.Stop()

	for {
		now := time.Now()
		if err := s.store.deleteExpiredSessions(s.thumbnailCtx, now); err != nil && s.thumbnailCtx.Err() == nil {
			log.Printf("expired session cleanup failed: %v", err)
		}
		s.cleanupExpiredImages(now)
		select {
		case <-s.thumbnailCtx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (s *Server) cleanupExpiredImages(now time.Time) {
	const batchSize = 100
	for {
		records, err := s.store.listExpiredImages(s.thumbnailCtx, now, batchSize)
		if err != nil {
			if s.thumbnailCtx.Err() == nil {
				log.Printf("expired image scan failed: %v", err)
			}
			return
		}
		failed := false
		changedOwners := make(map[string]struct{})
		for _, record := range records {
			if s.thumbnailCtx.Err() != nil {
				return
			}
			s.thumbnailMu.Lock()
			err := s.processor.removeFiles(record.OwnerID, record.ID, record.Extension)
			if err == nil {
				err = s.store.deleteImage(s.thumbnailCtx, record.OwnerID, record.ID)
			}
			s.thumbnailMu.Unlock()
			if err != nil && s.thumbnailCtx.Err() == nil {
				failed = true
				log.Printf("expired image cleanup failed for %s: %v", record.ID, err)
			} else if err == nil {
				changedOwners[record.OwnerID] = struct{}{}
			}
		}
		for ownerID := range changedOwners {
			s.galleryEvents.notify(ownerID)
		}
		if failed || len(records) < batchSize {
			return
		}
	}
}

func (s *Server) processPendingThumbnails() {
	const batchSize = 50
	for {
		records, err := s.store.listPendingThumbnails(s.thumbnailCtx, time.Now(), batchSize)
		if err != nil {
			if s.thumbnailCtx.Err() == nil {
				log.Printf("thumbnail queue scan failed: %v", err)
			}
			return
		}
		for _, record := range records {
			if s.thumbnailCtx.Err() != nil {
				return
			}
			s.processThumbnail(record)
		}
		if len(records) < batchSize {
			return
		}
	}
}

func (s *Server) processThumbnail(record imageRecord) {
	s.thumbnailMu.Lock()
	defer s.thumbnailMu.Unlock()
	if s.thumbnailCtx.Err() != nil {
		return
	}

	size, err := s.processor.generateThumbnail(record)
	debug.FreeOSMemory()
	if err != nil {
		delay := time.Minute << min(record.ThumbnailAttempts, 6)
		permanent, storeErr := s.store.recordThumbnailFailure(s.thumbnailCtx, record, time.Now().Add(delay))
		if storeErr != nil {
			log.Printf("thumbnail failure state update failed for %s: %v", record.ID, storeErr)
			return
		}
		if permanent {
			log.Printf("thumbnail generation permanently disabled for %s after %d attempts: %v", record.ID, thumbnailMaxAttempts, err)
		} else {
			log.Printf("thumbnail generation failed for %s; retrying later: %v", record.ID, err)
		}
		return
	}
	result, err := s.store.commitThumbnailWithinQuota(s.thumbnailCtx, record.OwnerID, record.ID, size)
	if err != nil {
		_ = os.Remove(s.processor.thumbnailPath(record.OwnerID, record.ID))
		if s.thumbnailCtx.Err() == nil {
			log.Printf("thumbnail metadata update failed for %s: %v", record.ID, err)
		}
		return
	}
	if result != thumbnailCommitted {
		_ = os.Remove(s.processor.thumbnailPath(record.OwnerID, record.ID))
	} else {
		s.galleryEvents.notify(record.OwnerID)
	}
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("POST /api/auth/session", s.createSession)
	mux.Handle("DELETE /api/auth/session", s.requireSession(http.HandlerFunc(s.deleteSession)))
	mux.Handle("GET /api/images", s.requireSession(http.HandlerFunc(s.listImages)))
	mux.Handle("GET /api/images/events", s.requireSession(http.HandlerFunc(s.streamGalleryEvents)))
	mux.Handle("POST /api/images", s.requireSession(http.HandlerFunc(s.uploadImage)))
	mux.Handle("DELETE /api/images", s.requireSession(http.HandlerFunc(s.deleteImages)))
	mux.Handle("GET /api/admin/users", s.requireAdmin(http.HandlerFunc(s.listUsers)))
	mux.Handle("POST /api/admin/users", s.requireAdmin(http.HandlerFunc(s.createUser)))
	mux.Handle("GET /api/client-setup", s.requireSession(http.HandlerFunc(s.clientSetup)))
	mux.Handle("POST /api/client-setup/token", s.requireSession(http.HandlerFunc(s.rotateClientToken)))
	mux.Handle("DELETE /api/client-setup/token", s.requireSession(http.HandlerFunc(s.revokeClientToken)))
	mux.HandleFunc("GET /downloads/{name}", s.serveClientDownload)
	mux.HandleFunc("GET /i/{name}", s.serveFullImage)
	mux.HandleFunc("GET /t/{name}", s.serveThumbnail)
	mux.Handle("GET /", webui.Handler())
	return s.securityHeaders(mux)
}

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_, _ = io.WriteString(w, `{"status":"ok"}`)
}

func (s *Server) createSession(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	source := requestSource(r)
	if allowed, retryAfter := s.rateLimits.allowLoginSource(now, source); !allowed {
		s.rateLimits.reject(w, now, "login_source", "", "", source, retryAfter)
		return
	}
	presented := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	matched, ok, err := s.matchCredential(r.Context(), presented)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "validate token")
		return
	}
	if !ok {
		writeError(w, http.StatusUnauthorized, "invalid token")
		return
	}
	if allowed, retryAfter := s.rateLimits.allowLoginOwner(now, matched.ownerID); !allowed {
		s.rateLimits.reject(w, now, "login_owner", matched.ownerID, "", source, retryAfter)
		return
	}

	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		writeError(w, http.StatusInternalServerError, "create session")
		return
	}
	encoded := base64.RawURLEncoding.EncodeToString(raw)
	hash := sha256.Sum256([]byte(encoded))
	expires := now.Add(s.cfg.SessionTTL)
	var replacedHash []byte
	if currentCookie, err := r.Cookie(sessionCookieName); err == nil && currentCookie.Value != "" {
		currentHash := sha256.Sum256([]byte(currentCookie.Value))
		replacedHash = currentHash[:]
	}
	if err := s.store.createSession(r.Context(), matched.ownerID, hash[:], matched.fingerprint[:], expires, replacedHash); err != nil {
		writeError(w, http.StatusInternalServerError, "store session")
		return
	}

	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookieName,
		Value:    encoded,
		Path:     "/api",
		Expires:  expires,
		MaxAge:   int(s.cfg.SessionTTL.Seconds()),
		HttpOnly: true,
		Secure:   s.cfg.CookieSecure,
		SameSite: http.SameSiteStrictMode,
	})
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) matchCredential(ctx context.Context, presented string) (credential, bool, error) {
	if presented == "" {
		return credential{}, false, nil
	}
	presentedHash := sha256.Sum256([]byte(presented))
	return s.store.credentialByFingerprint(ctx, presentedHash[:])
}

func (s *Server) deleteSession(w http.ResponseWriter, r *http.Request) {
	cookie, _ := r.Cookie(sessionCookieName)
	if cookie != nil {
		hash := sha256.Sum256([]byte(cookie.Value))
		_ = s.store.deleteSession(r.Context(), hash[:])
	}
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookieName,
		Value:    "",
		Path:     "/api",
		MaxAge:   -1,
		HttpOnly: true,
		Secure:   s.cfg.CookieSecure,
		SameSite: http.SameSiteStrictMode,
	})
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) requireSession(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !sameOrigin(r) {
			writeError(w, http.StatusForbidden, "cross-origin request rejected")
			return
		}
		if identity, ok := fnosIdentityFromRequest(r); ok {
			authenticatedRequest, err := s.authenticateFNOSRequest(r, identity)
			if err != nil {
				writeError(w, http.StatusInternalServerError, "validate FNOS account")
				return
			}
			next.ServeHTTP(w, authenticatedRequest)
			return
		}
		cookie, err := r.Cookie(sessionCookieName)
		if err != nil || cookie.Value == "" {
			writeError(w, http.StatusUnauthorized, "session required")
			return
		}
		hash := sha256.Sum256([]byte(cookie.Value))
		value, valid, err := s.store.sessionPrincipal(r.Context(), hash[:], time.Now())
		if err != nil {
			writeError(w, http.StatusInternalServerError, "validate session")
			return
		}
		if !valid {
			writeError(w, http.StatusUnauthorized, "session expired")
			return
		}
		contextWithPrincipal := context.WithValue(r.Context(), principalContextKey{}, value)
		next.ServeHTTP(w, r.WithContext(contextWithPrincipal))
	})
}

func authenticatedOwner(r *http.Request) string {
	return authenticatedPrincipal(r).OwnerID
}

func authenticatedPrincipal(r *http.Request) principal {
	value, _ := r.Context().Value(principalContextKey{}).(principal)
	return value
}

func (s *Server) requireAdmin(next http.Handler) http.Handler {
	return s.requireSession(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !authenticatedPrincipal(r).IsAdmin {
			writeError(w, http.StatusForbidden, "administrator required")
			return
		}
		next.ServeHTTP(w, r)
	}))
}

func (s *Server) uploadImage(w http.ResponseWriter, r *http.Request) {
	ownerID := authenticatedOwner(r)
	now := time.Now()
	releaseUpload, acquired := s.rateLimits.acquireUpload(ownerID)
	if !acquired {
		s.rateLimits.reject(w, now, "upload_concurrency", ownerID, "", "", time.Second)
		return
	}
	defer releaseUpload()
	if allowed, retryAfter := s.rateLimits.allowUpload(now, ownerID); !allowed {
		s.rateLimits.reject(w, now, "upload_hour", ownerID, "", "", retryAfter)
		return
	}
	select {
	case s.queueSlots <- struct{}{}:
		defer func() { <-s.queueSlots }()
	default:
		writeError(w, http.StatusServiceUnavailable, "image queue is full")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, s.cfg.MaxUploadBytes+(1<<20))
	tempPath, err := s.receiveUpload(r)
	if err != nil {
		if errors.Is(err, errUploadTooLarge) {
			writeError(w, http.StatusRequestEntityTooLarge, err.Error())
		} else {
			writeError(w, http.StatusBadRequest, err.Error())
		}
		return
	}
	defer os.Remove(tempPath)

	select {
	case s.processSlots <- struct{}{}:
		defer func() { <-s.processSlots }()
	case <-r.Context().Done():
		writeError(w, http.StatusRequestTimeout, "request cancelled")
		return
	}

	record, err := s.processor.process(tempPath, ownerID)
	// Uploads are comparatively infrequent and image decoding creates a large,
	// short-lived pixel buffer. Return that memory to the OS before the process
	// becomes idle again instead of retaining the peak-sized Go heap.
	debug.FreeOSMemory()
	if err != nil {
		switch {
		case errors.Is(err, errImageTooLarge), errors.Is(err, errVideoTooLarge):
			writeError(w, http.StatusRequestEntityTooLarge, err.Error())
		case errors.Is(err, errUnsupportedImage), errors.Is(err, errUnsupportedVideo):
			writeError(w, http.StatusUnsupportedMediaType, err.Error())
		default:
			writeError(w, http.StatusUnprocessableEntity, err.Error())
		}
		return
	}
	created, err := s.store.insertImageWithinQuota(r.Context(), record)
	if err != nil {
		_ = s.processor.removeFiles(record.OwnerID, record.ID, record.Extension)
		writeError(w, http.StatusInternalServerError, "store image metadata")
		return
	}
	if !created {
		_ = s.processor.removeFiles(record.OwnerID, record.ID, record.Extension)
		writeError(w, http.StatusRequestEntityTooLarge, "storage quota exceeded")
		return
	}

	if record.ThumbnailSize == thumbnailPendingSize {
		s.wakeThumbnailWorker()
	}
	s.galleryEvents.notify(ownerID)
	writeJSON(w, http.StatusCreated, map[string]any{"image": s.responseForRequest(r, record)})
}

var errUploadTooLarge = errors.New("upload exceeds configured size limit")

func (s *Server) receiveUpload(r *http.Request) (string, error) {
	reader, err := r.MultipartReader()
	if err != nil {
		return "", fmt.Errorf("multipart body required: %w", err)
	}
	for {
		part, err := reader.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return "", err
		}
		if part.FormName() != "file" || part.FileName() == "" {
			part.Close()
			continue
		}
		path, err := s.copyPart(part)
		part.Close()
		return path, err
	}
	return "", errors.New("multipart file field named 'file' is required")
}

func (s *Server) copyPart(part *multipart.Part) (string, error) {
	file, err := os.CreateTemp(filepath.Join(s.cfg.DataDir, "tmp"), "upload-*")
	if err != nil {
		return "", err
	}
	path := file.Name()
	remove := true
	defer func() {
		file.Close()
		if remove {
			_ = os.Remove(path)
		}
	}()

	written, err := io.Copy(file, io.LimitReader(part, s.cfg.MaxUploadBytes+1))
	if err != nil {
		return "", err
	}
	if written > s.cfg.MaxUploadBytes {
		return "", errUploadTooLarge
	}
	if err := file.Sync(); err != nil {
		return "", err
	}
	if err := file.Close(); err != nil {
		return "", err
	}
	remove = false
	return path, nil
}

func (s *Server) listImages(w http.ResponseWriter, r *http.Request) {
	limit := 50
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 || parsed > 100 {
			writeError(w, http.StatusBadRequest, "limit must be between 1 and 100")
			return
		}
		limit = parsed
	}
	since, err := s.rangeStart(r.URL.Query().Get("range"), time.Now())
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	records, err := s.store.listImages(r.Context(), authenticatedOwner(r), since, limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "list images")
		return
	}
	images := make([]imageResponse, 0, len(records))
	for _, record := range records {
		images = append(images, s.responseForRequest(r, record))
	}
	account, found, err := s.store.account(r.Context(), authenticatedOwner(r))
	if err != nil || !found {
		writeError(w, http.StatusInternalServerError, "load account")
		return
	}
	accountValue := account.response()
	accountValue.IsAdmin = authenticatedPrincipal(r).IsAdmin
	writeJSON(w, http.StatusOK, map[string]any{"images": images, "account": accountValue})
}

func (s *Server) streamGalleryEvents(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}
	updates, unsubscribe := s.galleryEvents.subscribe(authenticatedOwner(r))
	defer unsubscribe()

	// The process-wide write timeout is appropriate for uploads, but an SSE
	// response intentionally remains open until the browser disconnects.
	_ = http.NewResponseController(w).SetWriteDeadline(time.Time{})
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache, no-store")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	_, _ = io.WriteString(w, "retry: 5000\n\nevent: ready\ndata: {}\n\n")
	flusher.Flush()

	heartbeat := time.NewTicker(20 * time.Second)
	defer heartbeat.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-s.thumbnailCtx.Done():
			return
		case <-updates:
			if _, err := io.WriteString(w, "event: gallery\ndata: {}\n\n"); err != nil {
				return
			}
			flusher.Flush()
		case <-heartbeat.C:
			if _, err := io.WriteString(w, ": keep-alive\n\n"); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

func (s *Server) listUsers(w http.ResponseWriter, r *http.Request) {
	records, err := s.store.listAccounts(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "list users")
		return
	}
	users := make([]accountResponse, 0, len(records))
	for _, record := range records {
		users = append(users, record.response())
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": users})
}

func (s *Server) createUser(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	var request struct {
		SpaceID string `json:"space_id"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid user request")
		return
	}
	request.SpaceID = strings.TrimSpace(request.SpaceID)
	if !validOwnerID(request.SpaceID) {
		writeError(w, http.StatusBadRequest, "space_id must use 1-64 letters, numbers, underscores, or hyphens")
		return
	}

	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		writeError(w, http.StatusInternalServerError, "create user token")
		return
	}
	token := hex.EncodeToString(raw)
	fingerprint := sha256.Sum256([]byte(token))
	created, err := s.store.createAccount(
		r.Context(), request.SpaceID, fingerprint[:], s.cfg.DefaultQuotaBytes, s.cfg.DefaultRetentionDays,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "create user")
		return
	}
	if !created {
		writeError(w, http.StatusConflict, "space_id already exists")
		return
	}
	account := accountRecord{
		SpaceID: request.SpaceID, QuotaBytes: s.cfg.DefaultQuotaBytes,
		RetentionDays: s.cfg.DefaultRetentionDays, Enabled: true,
		CreatedAtMilli: time.Now().UTC().UnixMilli(),
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusCreated, map[string]any{"user": account.response(), "token": token})
}

func (s *Server) rangeStart(value string, now time.Time) (int64, error) {
	local := now.In(s.location)
	startToday := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, s.location)
	switch value {
	case "", "all":
		return 0, nil
	case "today":
		return startToday.UTC().UnixMilli(), nil
	case "7d":
		return startToday.AddDate(0, 0, -6).UTC().UnixMilli(), nil
	case "30d":
		return startToday.AddDate(0, 0, -29).UTC().UnixMilli(), nil
	default:
		return 0, errors.New("range must be today, 7d, 30d, or all")
	}
}

func (s *Server) deleteImages(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	var request struct {
		IDs []string `json:"ids"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid delete request")
		return
	}
	if len(request.IDs) == 0 || len(request.IDs) > 100 {
		writeError(w, http.StatusBadRequest, "ids must contain between 1 and 100 values")
		return
	}
	seen := make(map[string]struct{}, len(request.IDs))
	ids := make([]string, 0, len(request.IDs))
	for _, id := range request.IDs {
		if !validID(id) {
			writeError(w, http.StatusBadRequest, "invalid image id")
			return
		}
		if _, exists := seen[id]; !exists {
			seen[id] = struct{}{}
			ids = append(ids, id)
		}
	}

	ownerID := authenticatedOwner(r)
	s.thumbnailMu.Lock()
	defer s.thumbnailMu.Unlock()
	records, err := s.store.getImages(r.Context(), ownerID, ids)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "load images")
		return
	}
	for _, record := range records {
		if err := s.processor.removeFiles(record.OwnerID, record.ID, record.Extension); err != nil {
			writeError(w, http.StatusInternalServerError, "delete image files")
			return
		}
	}
	if err := s.store.deleteImages(r.Context(), ownerID, ids); err != nil {
		writeError(w, http.StatusInternalServerError, "delete image metadata")
		return
	}
	if len(records) > 0 {
		s.galleryEvents.notify(ownerID)
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": len(records)})
}

func (s *Server) serveFullImage(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	extension := strings.TrimPrefix(filepath.Ext(name), ".")
	id := strings.TrimSuffix(name, "."+extension)
	if !validID(id) || (extension != "webp" && extension != "gif" && extension != "mp4") {
		http.NotFound(w, r)
		return
	}
	record, found, err := s.store.getImageByID(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "load image metadata")
		return
	}
	if !found || record.Extension != extension {
		http.NotFound(w, r)
		return
	}
	now := time.Now()
	if allowed, retryAfter := s.rateLimits.allowOriginal(now, record.OwnerID); !allowed {
		s.rateLimits.reject(w, now, "original_hour", record.OwnerID, id, "", retryAfter)
		return
	}
	s.serveFile(w, r, s.processor.fullPath(record.OwnerID, id, extension), record.MediaType)
}

func (s *Server) serveThumbnail(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if filepath.Ext(name) != ".webp" {
		http.NotFound(w, r)
		return
	}
	id := strings.TrimSuffix(name, ".webp")
	if !validID(id) {
		http.NotFound(w, r)
		return
	}
	record, found, err := s.store.getImageByID(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "load image metadata")
		return
	}
	if !found {
		http.NotFound(w, r)
		return
	}
	now := time.Now()
	if allowed, retryAfter := s.rateLimits.allowThumbnail(now, record.OwnerID, id); !allowed {
		s.rateLimits.reject(w, now, "thumbnail", record.OwnerID, id, "", retryAfter)
		return
	}
	s.serveFile(w, r, s.processor.thumbnailPath(record.OwnerID, id), "image/webp")
}

func (s *Server) serveFile(w http.ResponseWriter, r *http.Request, path, mediaType string) {
	file, err := os.Open(path)
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
	w.Header().Set("Content-Type", mediaType)
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	http.ServeContent(w, r, filepath.Base(path), info.ModTime(), file)
}

func (s *Server) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		frameAncestors := "'none'"
		frameOption := "DENY"
		if _, ok := fnosIdentityFromRequest(r); ok {
			frameAncestors = "'self'"
			frameOption = "SAMEORIGIN"
		}
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; worker-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors "+frameAncestors+"; form-action 'self'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", frameOption)
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		next.ServeHTTP(w, r)
	})
}

func sameOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	parsed, err := url.Parse(origin)
	if err != nil {
		return false
	}
	return strings.EqualFold(parsed.Host, r.Host)
}

func validID(id string) bool {
	if len(id) != 32 {
		return false
	}
	_, err := hex.DecodeString(id)
	return err == nil
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
