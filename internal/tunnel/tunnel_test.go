package tunnel

import (
	"crypto/ed25519"
	"crypto/rand"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
)

func validConfig(directory string) Config {
	return Config{
		ServerAddr:     "example.com:22",
		User:           "pocketimg-phone",
		RemoteAddr:     "127.0.0.1:18081",
		LocalAddr:      "127.0.0.1:8080",
		PrivateKeyPath: filepath.Join(directory, "device-key"),
		PublicKeyPath:  filepath.Join(directory, "device-key.pub"),
		StatusPath:     filepath.Join(directory, "status.json"),
		HostKeySHA256:  "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
	}
}

func TestConfigRequiresLoopbackForwarding(t *testing.T) {
	cfg := validConfig(t.TempDir())
	if err := cfg.Validate(); err != nil {
		t.Fatalf("valid config: %v", err)
	}
	cfg.RemoteAddr = "0.0.0.0:18081"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "loopback") {
		t.Fatalf("remote listener validation error=%v", err)
	}
	cfg = validConfig(t.TempDir())
	cfg.LocalAddr = "192.168.1.1:8080"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "loopback") {
		t.Fatalf("local target validation error=%v", err)
	}
}

func TestEnsureDeviceKeyIsStableAndPrivate(t *testing.T) {
	cfg := validConfig(t.TempDir())
	first, err := ensureDeviceKey(cfg)
	if err != nil {
		t.Fatal(err)
	}
	second, err := ensureDeviceKey(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if string(first.PublicKey().Marshal()) != string(second.PublicKey().Marshal()) {
		t.Fatal("device key changed between loads")
	}
	info, err := os.Stat(cfg.PrivateKeyPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("private key mode=%o", info.Mode().Perm())
	}
	public, err := os.ReadFile(cfg.PublicKeyPath)
	if err != nil {
		t.Fatal(err)
	}
	parsed, _, _, _, err := ssh.ParseAuthorizedKey(public)
	if err != nil {
		t.Fatal(err)
	}
	if string(parsed.Marshal()) != string(first.PublicKey().Marshal()) {
		t.Fatal("public key file does not match private key")
	}
}

func TestFingerprintCallbackRejectsUnexpectedHost(t *testing.T) {
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	key, err := ssh.NewPublicKey(public)
	if err != nil {
		t.Fatal(err)
	}
	expected := ssh.FingerprintSHA256(key)
	callback := fingerprintCallback(expected)
	if err := callback("example.com:22", &net.TCPAddr{}, key); err != nil {
		t.Fatalf("expected fingerprint rejected: %v", err)
	}
	otherPublic, _, _ := ed25519.GenerateKey(rand.Reader)
	otherKey, _ := ssh.NewPublicKey(otherPublic)
	if err := callback("example.com:22", &net.TCPAddr{}, otherKey); err == nil {
		t.Fatal("unexpected fingerprint accepted")
	}
}
