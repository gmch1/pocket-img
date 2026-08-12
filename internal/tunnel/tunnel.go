package tunnel

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

const (
	dialTimeout      = 12 * time.Second
	keepAliveEvery   = 30 * time.Second
	keepAliveTimeout = 12 * time.Second
)

var (
	userPattern    = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)
	reconnectDelay = []time.Duration{time.Second, 2 * time.Second, 5 * time.Second, 10 * time.Second, 30 * time.Second, time.Minute}
)

// Config describes one tightly scoped reverse SSH tunnel. Both ends are
// intentionally restricted to loopback so PocketIMG cannot become a generic
// network proxy if its configuration is changed accidentally.
type Config struct {
	ServerAddr       string
	User             string
	RemoteAddr       string
	LocalAddr        string
	PrivateKeyPath   string
	PublicKeyPath    string
	StatusPath       string
	HostKeySHA256    string
	DeviceKeyComment string
}

type Status struct {
	State       string     `json:"state"`
	Message     string     `json:"message,omitempty"`
	Attempt     int        `json:"attempt,omitempty"`
	ConnectedAt *time.Time `json:"connected_at,omitempty"`
	UpdatedAt   time.Time  `json:"updated_at"`
}

func (cfg Config) Validate() error {
	if err := validateAddress("SSH server", cfg.ServerAddr, false); err != nil {
		return err
	}
	if !userPattern.MatchString(cfg.User) {
		return errors.New("SSH user must contain only letters, numbers, dot, underscore, or hyphen")
	}
	if err := validateAddress("remote listener", cfg.RemoteAddr, true); err != nil {
		return err
	}
	if err := validateAddress("local target", cfg.LocalAddr, true); err != nil {
		return err
	}
	for label, path := range map[string]string{
		"private key": cfg.PrivateKeyPath,
		"public key":  cfg.PublicKeyPath,
		"status":      cfg.StatusPath,
	} {
		if strings.TrimSpace(path) == "" {
			return fmt.Errorf("%s path is required", label)
		}
	}
	fingerprint := strings.TrimPrefix(strings.TrimSpace(cfg.HostKeySHA256), "SHA256:")
	if fingerprint == "" {
		return errors.New("SSH host key SHA-256 fingerprint is required")
	}
	if _, err := base64.RawStdEncoding.DecodeString(fingerprint); err != nil {
		return errors.New("SSH host key fingerprint must use the SHA256:base64 format")
	}
	return nil
}

func validateAddress(label, address string, requireLoopback bool) error {
	host, port, err := net.SplitHostPort(address)
	if err != nil || strings.TrimSpace(host) == "" {
		return fmt.Errorf("%s must be a host:port address", label)
	}
	if parsed, err := net.LookupPort("tcp", port); err != nil || parsed < 1 || parsed > 65535 {
		return fmt.Errorf("%s has an invalid port", label)
	}
	if requireLoopback {
		ip := net.ParseIP(host)
		if ip == nil || !ip.IsLoopback() {
			return fmt.Errorf("%s must use a numeric loopback address", label)
		}
	}
	return nil
}

// Run maintains the tunnel until ctx is cancelled. It generates a device-only
// Ed25519 key on first use and reconnects with bounded backoff.
func Run(ctx context.Context, cfg Config) {
	status := statusWriter{path: cfg.StatusPath}
	if err := cfg.Validate(); err != nil {
		status.write(Status{State: "error", Message: err.Error()})
		log.Printf("SSH tunnel configuration rejected: %v", err)
		return
	}

	signer, err := ensureDeviceKey(cfg)
	if err != nil {
		status.write(Status{State: "error", Message: "device key unavailable"})
		log.Printf("SSH tunnel device key failed: %v", err)
		return
	}

	for attempt := 1; ; attempt++ {
		if ctx.Err() != nil {
			status.write(Status{State: "stopped"})
			return
		}
		status.write(Status{State: "connecting", Attempt: attempt})
		connectedAt := time.Time{}
		err = connectAndServe(ctx, cfg, signer, func() {
			connectedAt = time.Now()
			status.write(Status{State: "connected", ConnectedAt: &connectedAt})
		})
		if ctx.Err() != nil {
			status.write(Status{State: "stopped"})
			return
		}

		delay := reconnectDelay[min(attempt-1, len(reconnectDelay)-1)]
		message := safeMessage(err)
		status.write(Status{State: "retrying", Message: message, Attempt: attempt})
		log.Printf("SSH tunnel disconnected; retrying in %s: %s", delay, message)
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			status.write(Status{State: "stopped"})
			return
		case <-timer.C:
		}
		if !connectedAt.IsZero() && time.Since(connectedAt) >= 5*time.Minute {
			attempt = 0
		}
	}
}

func connectAndServe(ctx context.Context, cfg Config, signer ssh.Signer, onConnected func()) error {
	raw, err := (&net.Dialer{Timeout: dialTimeout, KeepAlive: keepAliveEvery}).DialContext(ctx, "tcp", cfg.ServerAddr)
	if err != nil {
		return fmt.Errorf("connect SSH server: %w", err)
	}
	defer raw.Close()

	clientConfig := &ssh.ClientConfig{
		User:              cfg.User,
		Auth:              []ssh.AuthMethod{ssh.PublicKeys(signer)},
		HostKeyCallback:   fingerprintCallback(cfg.HostKeySHA256),
		HostKeyAlgorithms: []string{ssh.KeyAlgoED25519},
		Timeout:           dialTimeout,
	}
	connection, channels, requests, err := ssh.NewClientConn(raw, cfg.ServerAddr, clientConfig)
	if err != nil {
		return fmt.Errorf("SSH handshake: %w", err)
	}
	client := ssh.NewClient(connection, channels, requests)
	defer client.Close()

	listener, err := client.Listen("tcp", cfg.RemoteAddr)
	if err != nil {
		return fmt.Errorf("open remote listener: %w", err)
	}
	defer listener.Close()
	onConnected()

	acceptErr := make(chan error, 1)
	acceptDone := make(chan struct{})
	var forwards sync.WaitGroup
	go func() {
		defer close(acceptDone)
		for {
			remote, acceptErrValue := listener.Accept()
			if acceptErrValue != nil {
				acceptErr <- acceptErrValue
				return
			}
			forwards.Add(1)
			go func() {
				defer forwards.Done()
				forwardConnection(ctx, remote, cfg.LocalAddr)
			}()
		}
	}()

	keepAliveErr := make(chan error, 1)
	go func() { keepAliveErr <- keepAlive(ctx, client) }()

	select {
	case <-ctx.Done():
		err = ctx.Err()
	case err = <-acceptErr:
		err = fmt.Errorf("remote listener: %w", err)
	case err = <-keepAliveErr:
		err = fmt.Errorf("SSH keepalive: %w", err)
	}
	listener.Close()
	client.Close()
	<-acceptDone
	forwards.Wait()
	return err
}

func keepAlive(ctx context.Context, client *ssh.Client) error {
	ticker := time.NewTicker(keepAliveEvery)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			result := make(chan error, 1)
			go func() {
				_, _, err := client.SendRequest("keepalive@openssh.com", true, nil)
				result <- err
			}()
			select {
			case <-ctx.Done():
				return ctx.Err()
			case err := <-result:
				if err != nil {
					return err
				}
			case <-time.After(keepAliveTimeout):
				return errors.New("timeout")
			}
		}
	}
}

func forwardConnection(ctx context.Context, remote net.Conn, localAddress string) {
	defer remote.Close()
	local, err := (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, "tcp", localAddress)
	if err != nil {
		return
	}
	defer local.Close()

	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(local, remote)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(remote, local)
		done <- struct{}{}
	}()
	select {
	case <-ctx.Done():
	case <-done:
	}
}

func fingerprintCallback(expected string) ssh.HostKeyCallback {
	expected = strings.TrimSpace(expected)
	if !strings.HasPrefix(expected, "SHA256:") {
		expected = "SHA256:" + expected
	}
	return func(_ string, _ net.Addr, key ssh.PublicKey) error {
		actual := ssh.FingerprintSHA256(key)
		if actual != expected {
			return fmt.Errorf("host key mismatch: got %s", actual)
		}
		return nil
	}
}

func ensureDeviceKey(cfg Config) (ssh.Signer, error) {
	privateBytes, err := os.ReadFile(cfg.PrivateKeyPath)
	if errors.Is(err, os.ErrNotExist) {
		public, private, generateErr := ed25519.GenerateKey(rand.Reader)
		if generateErr != nil {
			return nil, generateErr
		}
		encoded, marshalErr := x509.MarshalPKCS8PrivateKey(private)
		if marshalErr != nil {
			return nil, marshalErr
		}
		privateBytes = pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: encoded})
		if err := atomicWrite(cfg.PrivateKeyPath, privateBytes, 0o600); err != nil {
			return nil, err
		}
		_ = public
	} else if err != nil {
		return nil, err
	}

	signer, err := ssh.ParsePrivateKey(privateBytes)
	if err != nil {
		return nil, err
	}
	comment := strings.TrimSpace(cfg.DeviceKeyComment)
	if comment == "" {
		comment = "pocketimg-device"
	}
	publicLine := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(signer.PublicKey()))) + " " + comment + "\n"
	if err := atomicWrite(cfg.PublicKeyPath, []byte(publicLine), 0o600); err != nil {
		return nil, err
	}
	return signer, nil
}

func atomicWrite(path string, data []byte, mode os.FileMode) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(directory, ".pocketimg-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(mode); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return err
	}
	return os.Chmod(path, mode)
}

type statusWriter struct {
	path string
	mu   sync.Mutex
}

func (writer *statusWriter) write(status Status) {
	writer.mu.Lock()
	defer writer.mu.Unlock()
	status.UpdatedAt = time.Now()
	data, err := json.Marshal(status)
	if err != nil {
		return
	}
	if err := atomicWrite(writer.path, append(data, '\n'), 0o600); err != nil {
		log.Printf("write SSH tunnel status: %v", err)
	}
}

func safeMessage(err error) string {
	if err == nil {
		return "connection closed"
	}
	message := strings.Join(strings.Fields(err.Error()), " ")
	if len(message) > 240 {
		message = message[:240]
	}
	return message
}
