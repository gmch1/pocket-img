package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"

	"phone-image-host/internal/backend"
)

func defaultTokensPath() string {
	return filepath.Join(envString("PIH_DATA_DIR", "./data"), "tokens.json")
}

func readManagedTokens(path string) (map[string]string, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, fmt.Errorf("read installed credentials %s (run the installer for a new instance, restore configuration for an existing instance): %w", path, err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		return nil, fmt.Errorf("installed credentials %s must be a regular file with mode 0600", path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var tokens map[string]string
	if err := json.Unmarshal(data, &tokens); err != nil {
		return nil, fmt.Errorf("invalid installed credentials %s", path)
	}
	if err := backend.ValidateTokens(tokens); err != nil {
		return nil, err
	}
	return tokens, nil
}

func runInit(args []string, out io.Writer) error {
	flags := flag.NewFlagSet("init", flag.ContinueOnError)
	output := flags.String("output", defaultTokensPath(), "managed credential file")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("usage: pocketimg init [--output PATH]")
	}
	if os.Getenv("PIH_FNOS_SOCKET") != "" {
		return errors.New("fnOS uses platform login; static credential initialization is not needed")
	}
	tokens, path, err := initializeTokens(*output, rand.Reader)
	if err != nil {
		return err
	}
	admin, err := configuredAdminSpace(tokens)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(out, "管理员空间：%s\n登录 Token：%s\n凭证位置：%s\n", admin, tokens[admin], path)
	return err
}

func initializeTokens(output string, random io.Reader) (map[string]string, string, error) {
	if os.Getenv("PIH_TOKEN") != "" || os.Getenv("PIH_TOKENS") != "" || os.Getenv("PIH_TOKENS_FILE") != "" {
		tokens, err := configuredTokens()
		if err == nil {
			err = backend.ValidateTokens(tokens)
		}
		path := os.Getenv("PIH_TOKENS_FILE")
		if err == nil && path != "" {
			configuredPath, pathErr := filepath.Abs(path)
			managedPath, outputErr := filepath.Abs(output)
			if pathErr == nil && outputErr == nil && configuredPath == managedPath {
				tokens, err = readManagedTokens(configuredPath)
			}
		}
		if path == "" {
			path = "现有环境配置（未生成新文件）"
		}
		return tokens, path, err
	}
	path, err := filepath.Abs(output)
	if err != nil {
		return nil, "", err
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, "", err
	}
	// Keep the lock inode after release, so concurrent processes cannot lock
	// different inodes. flock is released automatically after a crash.
	lock, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, "", err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return nil, "", errors.New("another installer is initializing credentials; retry after it finishes")
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	if _, err := os.Lstat(path); err == nil {
		tokens, err := readManagedTokens(path)
		return tokens, path, err
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, "", err
	}
	dataDir, err := filepath.Abs(envString("PIH_DATA_DIR", "./data"))
	if err != nil {
		return nil, "", err
	}
	entries, err := os.ReadDir(dataDir)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, "", err
	}
	for _, entry := range entries {
		if filepath.Join(dataDir, entry.Name()) == path+".lock" {
			continue
		}
		return nil, "", fmt.Errorf("data directory %s is not empty but credentials are missing; restore the original configuration", dataDir)
	}
	admin := envString("PIH_ADMIN_SPACE_ID", "admin")
	raw := make([]byte, 32)
	if _, err := io.ReadFull(random, raw); err != nil {
		return nil, "", fmt.Errorf("generate token: %w", err)
	}
	tokens := map[string]string{admin: hex.EncodeToString(raw)}
	if err := backend.ValidateTokens(tokens); err != nil {
		return nil, "", err
	}
	data, err := json.MarshalIndent(tokens, "", "  ")
	if err != nil {
		return nil, "", err
	}
	tmp, err := os.CreateTemp(dir, ".pocketimg-token-*")
	if err != nil {
		return nil, "", err
	}
	defer os.Remove(tmp.Name())
	defer tmp.Close()
	if err := tmp.Chmod(0o600); err != nil {
		return nil, "", err
	}
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		return nil, "", err
	}
	if err := tmp.Sync(); err != nil {
		return nil, "", err
	}
	if err := tmp.Close(); err != nil {
		return nil, "", err
	}
	// A hard link publishes a complete file atomically without replacing an
	// existing destination, including one created outside our installer lock.
	if err := os.Link(tmp.Name(), path); err != nil {
		return nil, "", fmt.Errorf("publish credentials without overwrite: %w", err)
	}
	if err := os.Remove(tmp.Name()); err != nil {
		return nil, "", err
	}
	directory, err := os.Open(dir)
	if err != nil {
		return nil, "", err
	}
	defer directory.Close()
	if err := directory.Sync(); err != nil {
		return nil, "", err
	}
	return tokens, path, nil
}
