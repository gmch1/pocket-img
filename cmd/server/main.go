package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
	_ "time/tzdata"

	"phone-image-host/internal/backend"
	"phone-image-host/internal/tunnel"
)

func main() {
	tokens, err := configuredTokens()
	if err != nil {
		log.Fatal(err)
	}
	adminSpaceID, err := configuredAdminSpace(tokens)
	if err != nil {
		log.Fatal(err)
	}

	cookieSecure := envBool("PIH_COOKIE_SECURE", true)
	cfg := backend.Config{
		DataDir:              envString("PIH_DATA_DIR", "./data"),
		Tokens:               tokens,
		AdminSpaceID:         adminSpaceID,
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
	}

	app, err := backend.New(cfg)
	if err != nil {
		log.Fatalf("initialize backend: %v", err)
	}
	defer app.Close()

	server := &http.Server{
		Addr:              envString("PIH_ADDR", "127.0.0.1:8080"),
		Handler:           app.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       envDuration("PIH_READ_TIMEOUT", 60*time.Second),
		WriteTimeout:      envDuration("PIH_WRITE_TIMEOUT", 120*time.Second),
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    64 << 10,
	}

	runContext, stopSignals := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stopSignals()

	go func() {
		log.Printf("backend listening on http://%s (data=%s, spaces=%d)", server.Addr, cfg.DataDir, len(cfg.Tokens))
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("serve: %v", err)
		}
	}()

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

	<-runContext.Done()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		log.Printf("shutdown: %v", err)
	}
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
