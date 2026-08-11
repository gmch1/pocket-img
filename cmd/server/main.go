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
)

func main() {
	tokens, err := configuredTokens()
	if err != nil {
		log.Fatal(err)
	}

	cookieSecure := envBool("PIH_COOKIE_SECURE", true)
	cfg := backend.Config{
		DataDir:        envString("PIH_DATA_DIR", "./data"),
		Tokens:         tokens,
		CookieSecure:   cookieSecure,
		SessionTTL:     7 * 24 * time.Hour,
		MaxUploadBytes: 25 << 20,
		MaxPixels:      20_000_000,
		ThumbnailMax:   640,
		WebPQuality:    82,
		ThumbQuality:   75,
		QueueDepth:     8,
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
		ReadTimeout:       60 * time.Second,
		WriteTimeout:      120 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		log.Printf("backend listening on http://%s (data=%s, spaces=%d)", server.Addr, cfg.DataDir, len(cfg.Tokens))
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("serve: %v", err)
		}
	}()

	<-stop
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		log.Printf("shutdown: %v", err)
	}
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
