package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
	_ "time/tzdata"

	"phone-image-host/internal/backend"
	"phone-image-host/internal/tunnel"
)

var version = "dev"

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	fnosSocketPath := os.Getenv("PIH_FNOS_SOCKET")
	fnosEnabled := fnosSocketPath != ""
	tokens, err := configuredTokensForMode(fnosEnabled)
	if err != nil {
		return err
	}
	adminSpaceID := ""
	if len(tokens) > 0 {
		adminSpaceID, err = configuredAdminSpace(tokens)
		if err != nil {
			return err
		}
	}

	cookieSecure := envBool("PIH_COOKIE_SECURE", true)
	cfg := backend.Config{
		DataDir:      envString("PIH_DATA_DIR", "./data"),
		Tokens:       tokens,
		AdminSpaceID: adminSpaceID,
		FNOS: backend.FNOSConfig{
			Enabled:            fnosEnabled,
			GatewayPrefix:      envString("PIH_FNOS_PREFIX", "/app/pocket-img"),
			ServicePort:        envInt("PIH_SERVICE_PORT", 8080),
			PublicBaseURL:      os.Getenv("PIH_PUBLIC_BASE_URL"),
			DownloadsDir:       os.Getenv("PIH_DOWNLOADS_DIR"),
			ApplicationVersion: envString("PIH_VERSION", version),
		},
		CookieSecure:         cookieSecure,
		SessionTTL:           7 * 24 * time.Hour,
		DefaultQuotaBytes:    10 << 30,
		DefaultRetentionDays: 90,
		CleanupInterval:      time.Hour,
		MaxUploadBytes:       25 << 20,
		MaxPixels:            20_000_000,
		ThumbnailMax:         640,
		WebPQuality:          82,
		ThumbQuality:         75,
		QueueDepth:           8,
		RateLimits: backend.RateLimitConfig{
			LoginPerMinute:             10,
			LoginBurst:                 5,
			LoginGlobalPerMinute:       120,
			LoginGlobalBurst:           30,
			UploadPerHour:              500,
			UploadConcurrentPerOwner:   2,
			OriginalPerHour:            500,
			ThumbnailPerImagePerMinute: 5,
			ThumbnailPerImagePerHour:   10,
			ThumbnailPerOwnerPerHour:   2000,
		},
	}

	app, err := backend.New(cfg)
	if err != nil {
		return fmt.Errorf("initialize backend: %w", err)
	}
	defer app.Close()

	tcpServer := &http.Server{
		Addr:              envString("PIH_ADDR", "127.0.0.1:8080"),
		Handler:           app.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       envDuration("PIH_READ_TIMEOUT", 60*time.Second),
		WriteTimeout:      envDuration("PIH_WRITE_TIMEOUT", 120*time.Second),
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    64 << 10,
	}
	servers := []*http.Server{tcpServer}
	var unixListener net.Listener
	if fnosEnabled {
		unixListener, err = listenUnixSocket(fnosSocketPath)
		if err != nil {
			return fmt.Errorf("listen on FNOS gateway socket: %w", err)
		}
		defer func() {
			_ = unixListener.Close()
			if info, statErr := os.Lstat(fnosSocketPath); statErr == nil && info.Mode()&os.ModeSocket != 0 {
				_ = os.Remove(fnosSocketPath)
			}
		}()
		servers = append(servers, &http.Server{
			Handler:           app.FNOSHandler(),
			ReadHeaderTimeout: 5 * time.Second,
			ReadTimeout:       envDuration("PIH_READ_TIMEOUT", 60*time.Second),
			WriteTimeout:      envDuration("PIH_WRITE_TIMEOUT", 120*time.Second),
			IdleTimeout:       60 * time.Second,
			MaxHeaderBytes:    64 << 10,
		})
	}

	runContext, stopSignals := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stopSignals()

	serveErrors := make(chan error, len(servers))
	go func() {
		log.Printf("backend listening on http://%s (data=%s, configured_spaces=%d)", tcpServer.Addr, cfg.DataDir, len(cfg.Tokens))
		if err := tcpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serveErrors <- fmt.Errorf("serve TCP: %w", err)
		}
	}()
	if fnosEnabled {
		unixServer := servers[1]
		go func() {
			log.Printf("FNOS gateway listening on unix://%s (prefix=%s)", fnosSocketPath, cfg.FNOS.GatewayPrefix)
			if err := unixServer.Serve(unixListener); err != nil && !errors.Is(err, http.ErrServerClosed) {
				serveErrors <- fmt.Errorf("serve FNOS gateway: %w", err)
			}
		}()
	}

	if envBool("PIH_TUNNEL_ENABLED", false) {
		tunnelConfig := tunnel.Config{
			ServerAddr:       os.Getenv("PIH_TUNNEL_SERVER"),
			User:             os.Getenv("PIH_TUNNEL_USER"),
			RemoteAddr:       os.Getenv("PIH_TUNNEL_REMOTE_ADDR"),
			LocalAddr:        os.Getenv("PIH_TUNNEL_LOCAL_ADDR"),
			PrivateKeyPath:   os.Getenv("PIH_TUNNEL_PRIVATE_KEY"),
			PublicKeyPath:    os.Getenv("PIH_TUNNEL_PUBLIC_KEY"),
			StatusPath:       os.Getenv("PIH_TUNNEL_STATUS_FILE"),
			HostKeySHA256:    os.Getenv("PIH_TUNNEL_HOST_KEY_SHA256"),
			DeviceKeyComment: os.Getenv("PIH_TUNNEL_KEY_COMMENT"),
		}
		go tunnel.Run(runContext, tunnelConfig)
	}

	var serveErr error
	select {
	case <-runContext.Done():
	case serveErr = <-serveErrors:
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for _, server := range servers {
		if err := server.Shutdown(ctx); err != nil {
			log.Printf("shutdown: %v", err)
		}
	}
	return serveErr
}

func listenUnixSocket(socketPath string) (net.Listener, error) {
	if !filepath.IsAbs(socketPath) {
		return nil, errors.New("socket path must be absolute")
	}
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o750); err != nil {
		return nil, err
	}
	if info, err := os.Lstat(socketPath); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || info.Mode()&os.ModeSocket == 0 {
			return nil, errors.New("refusing to replace a non-socket FNOS gateway path")
		}
		connection, dialErr := net.DialTimeout("unix", socketPath, 250*time.Millisecond)
		if dialErr == nil {
			connection.Close()
			return nil, errors.New("FNOS gateway socket is already in use")
		}
		if err := os.Remove(socketPath); err != nil {
			return nil, fmt.Errorf("remove stale socket: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(socketPath, 0o660); err != nil {
		listener.Close()
		_ = os.Remove(socketPath)
		return nil, err
	}
	return listener, nil
}

func configuredAdminSpace(tokens map[string]string) (string, error) {
	configured := os.Getenv("PIH_ADMIN_SPACE_ID")
	if configured != "" {
		if _, exists := tokens[configured]; !exists {
			return "", fmt.Errorf("PIH_ADMIN_SPACE_ID %q is not present in the configured token map", configured)
		}
		return configured, nil
	}
	if len(tokens) == 1 {
		for spaceID := range tokens {
			return spaceID, nil
		}
	}
	if _, exists := tokens["admin"]; exists {
		return "admin", nil
	}
	return "", errors.New("PIH_ADMIN_SPACE_ID is required when multiple token spaces are configured")
}

func configuredTokens() (map[string]string, error) {
	return configuredTokensForMode(false)
}

func configuredTokensForMode(allowEmpty bool) (map[string]string, error) {
	legacy := os.Getenv("PIH_TOKEN")
	inline := os.Getenv("PIH_TOKENS")
	path := os.Getenv("PIH_TOKENS_FILE")
	sources := 0
	for _, value := range []string{legacy, inline, path} {
		if value != "" {
			sources++
		}
	}
	if sources == 0 {
		if allowEmpty {
			return map[string]string{}, nil
		}
		return nil, errors.New("configure PIH_TOKENS_FILE, PIH_TOKENS, or legacy PIH_TOKEN")
	}
	if sources > 1 {
		return nil, errors.New("configure only one of PIH_TOKENS_FILE, PIH_TOKENS, or PIH_TOKEN")
	}
	if legacy != "" {
		return map[string]string{"default": legacy}, nil
	}

	data := []byte(inline)
	if path != "" {
		var err error
		data, err = os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read PIH_TOKENS_FILE: %w", err)
		}
	}
	var tokens map[string]string
	if err := json.Unmarshal(data, &tokens); err != nil {
		return nil, fmt.Errorf("parse configured tokens as a JSON object: %w", err)
	}
	if len(tokens) == 0 {
		return nil, errors.New("configured token map must not be empty")
	}
	return tokens, nil
}

func envInt(key string, fallback int) int {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		log.Fatalf("%s must be an integer: %v", key, err)
	}
	return parsed
}

func envString(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func envBool(key string, fallback bool) bool {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		log.Fatalf("%s must be a boolean: %v", key, err)
	}
	return parsed
}

func envDuration(key string, fallback time.Duration) time.Duration {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	parsed, err := time.ParseDuration(value)
	if err != nil || parsed <= 0 {
		log.Fatalf("%s must be a positive duration: %q", key, value)
	}
	return parsed
}
