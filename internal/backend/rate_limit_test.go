package backend

import (
	"bytes"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestRateLimitDefaults(t *testing.T) {
	cfg := (RateLimitConfig{}).withDefaults()
	if cfg.LoginPerMinute != 10 || cfg.LoginBurst != 5 {
		t.Fatalf("login defaults=%+v", cfg)
	}
	if cfg.LoginGlobalPerMinute != 120 || cfg.LoginGlobalBurst != 30 {
		t.Fatalf("global login defaults=%+v", cfg)
	}
	if cfg.UploadPerHour != 500 || cfg.UploadConcurrentPerOwner != 2 {
		t.Fatalf("upload defaults=%+v", cfg)
	}
	if cfg.OriginalPerHour != 500 {
		t.Fatalf("original defaults=%+v", cfg)
	}
	if cfg.ThumbnailPerImagePerMinute != 5 || cfg.ThumbnailPerImagePerHour != 10 || cfg.ThumbnailPerOwnerPerHour != 2000 {
		t.Fatalf("thumbnail defaults=%+v", cfg)
	}
}

func TestThumbnailRollingWindowsAndOwnerIsolation(t *testing.T) {
	cfg := (RateLimitConfig{}).withDefaults()
	limiter := newRateLimiter(cfg)
	now := time.Unix(1_800_000_000, 0)

	for range 5 {
		if allowed, _ := limiter.allowThumbnail(now, "alice", "image-a"); !allowed {
			t.Fatal("initial thumbnail request was rejected")
		}
	}
	if allowed, retryAfter := limiter.allowThumbnail(now, "alice", "image-a"); allowed || retryAfter != time.Minute {
		t.Fatalf("minute limit allowed=%v retry=%s", allowed, retryAfter)
	}
	if allowed, _ := limiter.allowThumbnail(now, "bob", "image-a"); !allowed {
		t.Fatal("one owner consumed another owner's thumbnail budget")
	}

	now = now.Add(time.Minute)
	for range 5 {
		if allowed, _ := limiter.allowThumbnail(now, "alice", "image-a"); !allowed {
			t.Fatal("thumbnail minute budget did not roll forward")
		}
	}
	if allowed, retryAfter := limiter.allowThumbnail(now, "alice", "image-a"); allowed || retryAfter != 59*time.Minute {
		t.Fatalf("hour limit allowed=%v retry=%s", allowed, retryAfter)
	}
}

func TestThumbnailOwnerAggregateLimit(t *testing.T) {
	cfg := (RateLimitConfig{}).withDefaults()
	cfg.ThumbnailPerOwnerPerHour = 2
	limiter := newRateLimiter(cfg)
	now := time.Unix(1_800_000_000, 0)

	if allowed, _ := limiter.allowThumbnail(now, "alice", "image-a"); !allowed {
		t.Fatal("first thumbnail request was rejected")
	}
	if allowed, _ := limiter.allowThumbnail(now, "alice", "image-b"); !allowed {
		t.Fatal("second thumbnail request was rejected")
	}
	if allowed, retryAfter := limiter.allowThumbnail(now, "alice", "image-c"); allowed || retryAfter != time.Hour {
		t.Fatalf("owner aggregate allowed=%v retry=%s", allowed, retryAfter)
	}
	if allowed, _ := limiter.allowThumbnail(now, "bob", "image-c"); !allowed {
		t.Fatal("one owner consumed another owner's aggregate budget")
	}
}

func TestLoginTokenBucketBurstAndRefill(t *testing.T) {
	limiter := newRateLimiter((RateLimitConfig{}).withDefaults())
	now := time.Unix(1_800_000_000, 0)
	for range 5 {
		if allowed, _ := limiter.allowLoginSource(now, "192.0.2.10"); !allowed {
			t.Fatal("login burst was rejected early")
		}
	}
	if allowed, retryAfter := limiter.allowLoginSource(now, "192.0.2.10"); allowed || retryAfter != 6*time.Second {
		t.Fatalf("login source limit allowed=%v retry=%s", allowed, retryAfter)
	}
	if allowed, _ := limiter.allowLoginSource(now, "192.0.2.11"); !allowed {
		t.Fatal("one source consumed another source's login budget")
	}
	if allowed, _ := limiter.allowLoginSource(now.Add(6*time.Second), "192.0.2.10"); !allowed {
		t.Fatal("login token bucket did not refill")
	}
}

func TestUploadConcurrencyIsPerOwner(t *testing.T) {
	limiter := newRateLimiter((RateLimitConfig{}).withDefaults())
	releaseOne, acquired := limiter.acquireUpload("alice")
	if !acquired {
		t.Fatal("first upload slot was rejected")
	}
	releaseTwo, acquired := limiter.acquireUpload("alice")
	if !acquired {
		t.Fatal("second upload slot was rejected")
	}
	if _, acquired := limiter.acquireUpload("alice"); acquired {
		t.Fatal("third upload slot was accepted")
	}
	bobRelease, acquired := limiter.acquireUpload("bob")
	if !acquired {
		t.Fatal("one owner consumed another owner's upload slots")
	}
	releaseOne()
	releaseOne()
	thirdRelease, acquired := limiter.acquireUpload("alice")
	if !acquired {
		t.Fatal("released upload slot was not reusable")
	}
	thirdRelease()
	releaseTwo()
	bobRelease()
}

func TestRequestSourceTrustsExplicitHeaderOnlyFromLoopback(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, "http://backend/api/auth/session", nil)
	request.RemoteAddr = "127.0.0.1:1234"
	request.Header.Set(clientIPHeader, "203.0.113.9")
	if source := requestSource(request); source != "203.0.113.9" {
		t.Fatalf("loopback proxy source=%q", source)
	}

	request.RemoteAddr = "192.0.2.20:1234"
	if source := requestSource(request); source != "192.0.2.20" {
		t.Fatalf("untrusted forwarded source=%q", source)
	}
}

func TestLoginLimitsSourceAndOwningSpace(t *testing.T) {
	tokens := map[string]string{"alice": testToken, "bob": secondTestToken}
	cfg := testConfig(t.TempDir(), tokens)
	cfg.RateLimits = permissiveRateLimits()
	cfg.RateLimits.LoginPerMinute = 60
	cfg.RateLimits.LoginBurst = 1
	backend := newTestBackendWithConfig(t, cfg)

	assertStatus(t, loginRequest(t, backend.http.URL, testToken, "192.0.2.1"), http.StatusNoContent)
	assertRateLimited(t, loginRequest(t, backend.http.URL, testToken, "192.0.2.2"))
	assertStatus(t, loginRequest(t, backend.http.URL, secondTestToken, "192.0.2.3"), http.StatusNoContent)
	assertStatus(t, loginRequest(t, backend.http.URL, "invalid-token", "192.0.2.4"), http.StatusUnauthorized)
	assertRateLimited(t, loginRequest(t, backend.http.URL, "another-invalid-token", "192.0.2.4"))
}

func TestUploadHourlyLimitReturns429PerOwner(t *testing.T) {
	tokens := map[string]string{"alice": testToken, "bob": secondTestToken}
	cfg := testConfig(t.TempDir(), tokens)
	cfg.RateLimits = permissiveRateLimits()
	cfg.RateLimits.UploadPerHour = 1
	backend := newTestBackendWithConfig(t, cfg)
	backend.login(t)
	bobClient := newCookieClient(t)
	backend.loginClient(t, bobClient, secondTestToken)
	content := makePNG(t, 4, 4)

	assertStatus(t, uploadRequest(t, backend.http.URL, backend.client, content), http.StatusCreated)
	limited := uploadRequest(t, backend.http.URL, backend.client, content)
	assertRateLimited(t, limited)
	assertStatus(t, uploadRequest(t, backend.http.URL, bobClient, content), http.StatusCreated)
}

func TestPublicImageLimitUsesOwningSpace(t *testing.T) {
	tokens := map[string]string{"alice": testToken, "bob": secondTestToken}
	cfg := testConfig(t.TempDir(), tokens)
	cfg.RateLimits = permissiveRateLimits()
	cfg.RateLimits.OriginalPerHour = 1
	backend := newTestBackendWithConfig(t, cfg)
	backend.login(t)
	bobClient := newCookieClient(t)
	backend.loginClient(t, bobClient, secondTestToken)
	content := makePNG(t, 4, 4)
	aliceImage := backend.upload(t, "alice.png", content)
	bobImage := backend.uploadClient(t, bobClient, "bob.png", content)

	assertStatus(t, getRequest(t, backend.http.URL+aliceImage.URL), http.StatusOK)
	assertRateLimited(t, getRequest(t, backend.http.URL+aliceImage.URL))
	assertStatus(t, getRequest(t, backend.http.URL+bobImage.URL), http.StatusOK)
}

func TestThumbnailLimitReturns429ForOwningSpace(t *testing.T) {
	cfg := testConfig(t.TempDir(), map[string]string{"alice": testToken})
	cfg.RateLimits = permissiveRateLimits()
	cfg.RateLimits.ThumbnailPerImagePerMinute = 1
	backend := newTestBackendWithConfig(t, cfg)
	backend.login(t)
	image := backend.upload(t, "thumbnail.png", makePNG(t, 4, 4))
	image = backend.waitForThumbnail(t, image.ID)

	assertStatus(t, getRequest(t, backend.http.URL+image.ThumbnailURL), http.StatusOK)
	assertRateLimited(t, getRequest(t, backend.http.URL+image.ThumbnailURL))
}

func permissiveRateLimits() RateLimitConfig {
	return RateLimitConfig{
		LoginPerMinute:             1000,
		LoginBurst:                 100,
		LoginGlobalPerMinute:       1000,
		LoginGlobalBurst:           100,
		UploadPerHour:              1000,
		UploadConcurrentPerOwner:   2,
		OriginalPerHour:            1000,
		ThumbnailPerImagePerMinute: 1000,
		ThumbnailPerImagePerHour:   1000,
		ThumbnailPerOwnerPerHour:   1000,
	}
}

func uploadRequest(t *testing.T, baseURL string, client *http.Client, content []byte) *http.Response {
	t.Helper()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", "rate-limit.png")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write(content); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(http.MethodPost, baseURL+"/api/images", &body)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", writer.FormDataContentType())
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

func loginRequest(t *testing.T, baseURL, token, source string) *http.Response {
	t.Helper()
	request, err := http.NewRequest(http.MethodPost, baseURL+"/api/auth/session", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set(clientIPHeader, source)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

func getRequest(t *testing.T, target string) *http.Response {
	t.Helper()
	response, err := http.Get(target)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

func assertRateLimited(t *testing.T, response *http.Response) {
	t.Helper()
	defer response.Body.Close()
	if response.StatusCode != http.StatusTooManyRequests {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("status=%d body=%s", response.StatusCode, body)
	}
	if response.Header.Get("Retry-After") == "" {
		t.Fatal("429 response omitted Retry-After")
	}
	if response.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("429 Cache-Control=%q", response.Header.Get("Cache-Control"))
	}
}

func assertStatus(t *testing.T, response *http.Response, expected int) {
	t.Helper()
	defer response.Body.Close()
	if response.StatusCode != expected {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("status=%d expected=%d body=%s", response.StatusCode, expected, body)
	}
}
