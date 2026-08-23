package backend

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/gif"
	"image/png"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gen2brain/webp"
)

const testToken = "4a44c6f0-7f3c-4df4-a456-ec2dc9a8a911-very-long-test-token"
const secondTestToken = "bc60e8ca-476e-4f8f-809b-5d3381f65255-another-long-test-token"

type testBackend struct {
	server *Server
	http   *httptest.Server
	client *http.Client
}

func newTestBackend(t *testing.T) *testBackend {
	t.Helper()
	return newTestBackendWithTokens(t, t.TempDir(), map[string]string{"alice": testToken})
}

func newTestBackendWithTokens(t *testing.T, dataDir string, tokens map[string]string) *testBackend {
	t.Helper()
	return newTestBackendWithConfig(t, testConfig(dataDir, tokens))
}

func newTestBackendWithConfig(t *testing.T, cfg Config) *testBackend {
	t.Helper()
	app, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(app.Handler())
	backend := &testBackend{
		server: app,
		http:   httpServer,
		client: newCookieClient(t),
	}
	t.Cleanup(func() {
		httpServer.Close()
		if err := app.Close(); err != nil {
			t.Errorf("close backend: %v", err)
		}
	})
	return backend
}

func testConfig(dataDir string, tokens map[string]string) Config {
	adminSpaceID := "alice"
	if _, exists := tokens[adminSpaceID]; !exists {
		for candidate := range tokens {
			adminSpaceID = candidate
			break
		}
	}
	return Config{
		DataDir:              dataDir,
		Tokens:               tokens,
		AdminSpaceID:         adminSpaceID,
		CookieSecure:         false,
		SessionTTL:           time.Hour,
		DefaultQuotaBytes:    defaultUserQuotaBytes,
		DefaultRetentionDays: defaultRetentionDays,
		CleanupInterval:      time.Hour,
		MaxUploadBytes:       2 << 20,
		MaxPixels:            5_000_000,
		ThumbnailMax:         640,
		WebPQuality:          82,
		ThumbQuality:         75,
		QueueDepth:           2,
	}
}

func newCookieClient(t *testing.T) *http.Client {
	t.Helper()
	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	return &http.Client{Jar: jar}
}

func TestSameOriginUsesThePreservedHost(t *testing.T) {
	request := httptest.NewRequest(http.MethodDelete, "http://backend/api/images", nil)
	request.Host = "img.example.com"
	request.Header.Set("Origin", "https://img.example.com")
	if !sameOrigin(request) {
		t.Fatal("matching public host was rejected")
	}

	request.Header.Set("Origin", "https://attacker.example")
	request.Header.Set("X-Forwarded-Host", "attacker.example")
	if sameOrigin(request) {
		t.Fatal("untrusted forwarded host bypassed the origin check")
	}
}

func TestBrowserSecurityHeaders(t *testing.T) {
	backend := newTestBackend(t)
	response, err := http.Get(backend.http.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.Header.Get("X-Frame-Options") != "DENY" {
		t.Fatalf("X-Frame-Options=%q", response.Header.Get("X-Frame-Options"))
	}
	if !strings.Contains(response.Header.Get("Content-Security-Policy"), "frame-ancestors 'none'") {
		t.Fatalf("Content-Security-Policy=%q", response.Header.Get("Content-Security-Policy"))
	}
	if !strings.Contains(response.Header.Get("Content-Security-Policy"), "media-src 'self' blob:") {
		t.Fatalf("Content-Security-Policy does not allow hosted video: %q", response.Header.Get("Content-Security-Policy"))
	}
}

func TestGalleryEventSubscriptionsAreIsolatedAndCoalesced(t *testing.T) {
	events := newGalleryEvents()
	alice, unsubscribeAlice := events.subscribe("alice")
	defer unsubscribeAlice()
	bob, unsubscribeBob := events.subscribe("bob")
	defer unsubscribeBob()

	events.notify("alice")
	events.notify("alice")
	select {
	case <-alice:
	default:
		t.Fatal("alice did not receive her gallery event")
	}
	select {
	case <-alice:
		t.Fatal("burst events were not coalesced")
	default:
	}
	select {
	case <-bob:
		t.Fatal("bob received alice's gallery event")
	default:
	}
}

func TestGalleryEventStreamNotifiesAfterUpload(t *testing.T) {
	backend := newTestBackend(t)

	unauthorized, err := http.Get(backend.http.URL + "/api/images/events")
	if err != nil {
		t.Fatal(err)
	}
	unauthorized.Body.Close()
	if unauthorized.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthorized stream status=%d", unauthorized.StatusCode)
	}

	backend.login(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, backend.http.URL+"/api/images/events", nil)
	if err != nil {
		t.Fatal(err)
	}
	response, err := backend.client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("stream status=%d", response.StatusCode)
	}
	if response.Header.Get("Content-Type") != "text/event-stream" {
		t.Fatalf("stream content type=%q", response.Header.Get("Content-Type"))
	}
	if !strings.Contains(response.Header.Get("Cache-Control"), "no-store") {
		t.Fatalf("stream cache control=%q", response.Header.Get("Cache-Control"))
	}

	reader := bufio.NewReader(response.Body)
	for {
		event, err := readSSEEvent(reader)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(event, "event: ready") {
			break
		}
	}

	received := make(chan error, 1)
	go func() {
		for {
			event, err := readSSEEvent(reader)
			if err != nil {
				received <- err
				return
			}
			if strings.Contains(event, "event: gallery") {
				received <- nil
				return
			}
		}
	}()
	backend.upload(t, "sse.png", makePNG(t, 32, 24))
	select {
	case err := <-received:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("gallery event was not delivered after upload")
	}
}

func readSSEEvent(reader *bufio.Reader) (string, error) {
	var lines []string
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			return "", err
		}
		line = strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")
		if line == "" && len(lines) > 0 {
			return strings.Join(lines, "\n"), nil
		}
		if line != "" {
			lines = append(lines, line)
		}
	}
}

func (backend *testBackend) login(t *testing.T) {
	t.Helper()
	backend.loginClient(t, backend.client, testToken)
}

func (backend *testBackend) loginClient(t *testing.T, client *http.Client, token string) {
	t.Helper()
	request, err := http.NewRequest(http.MethodPost, backend.http.URL+"/api/auth/session", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("login status=%d body=%s", response.StatusCode, body)
	}
	cookies := response.Cookies()
	if len(cookies) != 1 || cookies[0].Name != sessionCookieName {
		t.Fatalf("unexpected session cookies: %#v", cookies)
	}
	if !cookies[0].HttpOnly || cookies[0].Path != "/api" || cookies[0].SameSite != http.SameSiteStrictMode {
		t.Fatalf("unsafe session cookie attributes: %#v", cookies[0])
	}
}

func (backend *testBackend) upload(t *testing.T, name string, content []byte) imageResponse {
	t.Helper()
	return backend.uploadClient(t, backend.client, name, content)
}

func (backend *testBackend) uploadClient(t *testing.T, client *http.Client, name string, content []byte) imageResponse {
	t.Helper()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", name)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write(content); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	request, err := http.NewRequest(http.MethodPost, backend.http.URL+"/api/images", &body)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", writer.FormDataContentType())
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusCreated {
		responseBody, _ := io.ReadAll(response.Body)
		t.Fatalf("upload status=%d body=%s", response.StatusCode, responseBody)
	}
	var result struct {
		Image imageResponse `json:"image"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	return result.Image
}

func (backend *testBackend) waitForThumbnail(t *testing.T, id string) imageResponse {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		record, found, err := backend.server.store.getImageByID(context.Background(), id)
		if err != nil {
			t.Fatal(err)
		}
		if found && record.ThumbnailSize > 0 {
			return record.response()
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("thumbnail for %s was not generated", id)
	return imageResponse{}
}

func TestStaticImageEndToEnd(t *testing.T) {
	backend := newTestBackend(t)

	unauthorized, err := http.Post(backend.http.URL+"/api/images", "application/octet-stream", bytes.NewReader(nil))
	if err != nil {
		t.Fatal(err)
	}
	unauthorized.Body.Close()
	if unauthorized.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthorized upload status=%d", unauthorized.StatusCode)
	}

	backend.login(t)
	source := makePNG(t, 1280, 720)
	result := backend.upload(t, "screenshot.png", source)
	if result.MediaType != "image/webp" || result.Animated || result.Width != 1280 || result.Height != 720 {
		t.Fatalf("unexpected image metadata: %#v", result)
	}
	if result.URL[len(result.URL)-5:] != ".webp" {
		t.Fatalf("static image was not converted to webp: %s", result.URL)
	}
	if result.ThumbnailSize != 0 || result.ThumbnailURL != result.URL {
		t.Fatalf("upload waited for the thumbnail: %#v", result)
	}

	publicResponse, err := http.Get(backend.http.URL + result.URL)
	if err != nil {
		t.Fatal(err)
	}
	if publicResponse.StatusCode != http.StatusOK || publicResponse.Header.Get("Content-Type") != "image/webp" {
		publicResponse.Body.Close()
		t.Fatalf("public image status=%d type=%s", publicResponse.StatusCode, publicResponse.Header.Get("Content-Type"))
	}
	fullConfig, err := webp.DecodeConfig(publicResponse.Body)
	publicResponse.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	if fullConfig.Width != 1280 || fullConfig.Height != 720 {
		t.Fatalf("full dimensions=%dx%d", fullConfig.Width, fullConfig.Height)
	}

	ready := backend.waitForThumbnail(t, result.ID)
	thumbnailResponse, err := http.Get(backend.http.URL + ready.ThumbnailURL)
	if err != nil {
		t.Fatal(err)
	}
	thumbnailConfig, err := webp.DecodeConfig(thumbnailResponse.Body)
	thumbnailResponse.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	if thumbnailConfig.Width != 640 || thumbnailConfig.Height != 360 {
		t.Fatalf("thumbnail dimensions=%dx%d", thumbnailConfig.Width, thumbnailConfig.Height)
	}

	listResponse, err := backend.client.Get(backend.http.URL + "/api/images?range=today")
	if err != nil {
		t.Fatal(err)
	}
	var list struct {
		Images []imageResponse `json:"images"`
	}
	if err := json.NewDecoder(listResponse.Body).Decode(&list); err != nil {
		listResponse.Body.Close()
		t.Fatal(err)
	}
	listResponse.Body.Close()
	if len(list.Images) != 1 || list.Images[0].ID != result.ID {
		t.Fatalf("unexpected image list: %#v", list.Images)
	}

	deleteBody, _ := json.Marshal(map[string]any{"ids": []string{result.ID}})
	deleteRequest, err := http.NewRequest(http.MethodDelete, backend.http.URL+"/api/images", bytes.NewReader(deleteBody))
	if err != nil {
		t.Fatal(err)
	}
	deleteRequest.Header.Set("Content-Type", "application/json")
	deleteResponse, err := backend.client.Do(deleteRequest)
	if err != nil {
		t.Fatal(err)
	}
	deleteResponse.Body.Close()
	if deleteResponse.StatusCode != http.StatusOK {
		t.Fatalf("delete status=%d", deleteResponse.StatusCode)
	}

	missing, err := http.Get(backend.http.URL + result.URL)
	if err != nil {
		t.Fatal(err)
	}
	missing.Body.Close()
	if missing.StatusCode != http.StatusNotFound {
		t.Fatalf("deleted public image status=%d", missing.StatusCode)
	}
}

func TestGIFIsPreservedAndGetsWebPThumbnail(t *testing.T) {
	backend := newTestBackend(t)
	backend.login(t)
	source := makeGIF(t)
	result := backend.upload(t, "animation.gif", source)
	if result.MediaType != "image/gif" || !result.Animated || result.URL[len(result.URL)-4:] != ".gif" {
		t.Fatalf("unexpected gif metadata: %#v", result)
	}
	if result.ThumbnailSize != 0 || result.ThumbnailURL != result.URL {
		t.Fatalf("gif upload waited for the thumbnail: %#v", result)
	}

	publicResponse, err := http.Get(backend.http.URL + result.URL)
	if err != nil {
		t.Fatal(err)
	}
	stored, err := io.ReadAll(publicResponse.Body)
	publicResponse.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(source, stored) {
		t.Fatal("gif bytes changed during storage")
	}

	ready := backend.waitForThumbnail(t, result.ID)
	thumbnailResponse, err := http.Get(backend.http.URL + ready.ThumbnailURL)
	if err != nil {
		t.Fatal(err)
	}
	_, err = webp.Decode(thumbnailResponse.Body)
	thumbnailResponse.Body.Close()
	if err != nil {
		t.Fatalf("decode gif thumbnail: %v", err)
	}
}

func TestH264MP4IsValidatedPreservedAndServedWithRange(t *testing.T) {
	backend := newTestBackend(t)
	backend.login(t)
	source := makeH264MP4(t, 1280, 720)

	// A misleading name is intentional: detection must use the file contents.
	result := backend.upload(t, "recording.png", source)
	if result.MediaType != "video/mp4" || result.Width != 1280 || result.Height != 720 || result.Animated {
		t.Fatalf("unexpected video metadata: %#v", result)
	}
	if !strings.HasSuffix(result.URL, ".mp4") || result.ThumbnailSize != thumbnailSkippedSize || result.ThumbnailURL != result.URL {
		t.Fatalf("unexpected video URLs or thumbnail state: %#v", result)
	}

	record, found, err := backend.server.store.getImageByID(t.Context(), result.ID)
	if err != nil || !found {
		t.Fatalf("load stored video: found=%v err=%v", found, err)
	}
	if record.ThumbnailSize != thumbnailSkippedSize || record.ThumbnailAttempts != 0 {
		t.Fatalf("video entered thumbnail processing: %#v", record)
	}
	pending, err := backend.server.store.listPendingThumbnails(t.Context(), time.Now(), 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 0 {
		t.Fatalf("video was queued for image thumbnail generation: %#v", pending)
	}
	if _, err := os.Stat(backend.server.processor.thumbnailPath("alice", result.ID)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("video unexpectedly has an image thumbnail: %v", err)
	}

	publicResponse, err := http.Get(backend.http.URL + result.URL)
	if err != nil {
		t.Fatal(err)
	}
	stored, readErr := io.ReadAll(publicResponse.Body)
	publicResponse.Body.Close()
	if readErr != nil {
		t.Fatal(readErr)
	}
	if publicResponse.StatusCode != http.StatusOK || publicResponse.Header.Get("Content-Type") != "video/mp4" {
		t.Fatalf("public video status=%d type=%q", publicResponse.StatusCode, publicResponse.Header.Get("Content-Type"))
	}
	if !bytes.Equal(stored, source) {
		t.Fatal("MP4 bytes changed during storage")
	}

	rangeRequest, err := http.NewRequest(http.MethodGet, backend.http.URL+result.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	rangeRequest.Header.Set("Range", "bytes=4-15")
	rangeResponse, err := http.DefaultClient.Do(rangeRequest)
	if err != nil {
		t.Fatal(err)
	}
	rangeBody, readErr := io.ReadAll(rangeResponse.Body)
	rangeResponse.Body.Close()
	if readErr != nil {
		t.Fatal(readErr)
	}
	if rangeResponse.StatusCode != http.StatusPartialContent || rangeResponse.Header.Get("Content-Type") != "video/mp4" {
		t.Fatalf("range status=%d type=%q", rangeResponse.StatusCode, rangeResponse.Header.Get("Content-Type"))
	}
	if rangeResponse.Header.Get("Content-Range") != fmt.Sprintf("bytes 4-15/%d", len(source)) {
		t.Fatalf("Content-Range=%q", rangeResponse.Header.Get("Content-Range"))
	}
	if !bytes.Equal(rangeBody, source[4:16]) {
		t.Fatalf("range body=%x want=%x", rangeBody, source[4:16])
	}

	images := listForClient(t, backend, backend.client)
	if len(images) != 1 || images[0].MediaType != "video/mp4" || images[0].ID != result.ID {
		t.Fatalf("video list response=%#v", images)
	}
}

func TestMP4UploadDoesNotTrustFileNameAndEnforcesPixelLimit(t *testing.T) {
	backend := newTestBackend(t)
	backend.login(t)

	renamedImage := backend.upload(t, "fake-video.mp4", makePNG(t, 32, 24))
	if renamedImage.MediaType != "image/webp" || !strings.HasSuffix(renamedImage.URL, ".webp") {
		t.Fatalf("image file name was trusted: %#v", renamedImage)
	}

	malformed := makeMP4Box(t, "ftyp", []byte("mp42\x00\x00\x00\x00isom"))
	malformedResponse := uploadRequest(t, backend.http.URL, backend.client, malformed)
	malformedResponse.Body.Close()
	if malformedResponse.StatusCode != http.StatusUnsupportedMediaType {
		t.Fatalf("malformed MP4 status=%d", malformedResponse.StatusCode)
	}

	cfg := testConfig(t.TempDir(), map[string]string{"alice": testToken})
	cfg.MaxPixels = 100
	limited := newTestBackendWithConfig(t, cfg)
	limited.login(t)
	tooLarge := uploadRequest(t, limited.http.URL, limited.client, makeH264MP4(t, 20, 10))
	tooLarge.Body.Close()
	if tooLarge.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized MP4 dimensions status=%d", tooLarge.StatusCode)
	}
}

func TestStaticWebPIsValidatedAndStoredWithoutReencoding(t *testing.T) {
	backend := newTestBackend(t)
	backend.login(t)
	source := makeWebP(t, 640, 360)
	result := backend.upload(t, "browser-compressed.webp", source)
	if result.Animated || result.Width != 640 || result.Height != 360 {
		t.Fatalf("unexpected webp metadata: %#v", result)
	}
	if result.ThumbnailSize != 0 || result.ThumbnailURL != result.URL {
		t.Fatalf("webp upload waited for the thumbnail: %#v", result)
	}

	publicResponse, err := http.Get(backend.http.URL + result.URL)
	if err != nil {
		t.Fatal(err)
	}
	stored, err := io.ReadAll(publicResponse.Body)
	publicResponse.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(source, stored) {
		t.Fatal("safe static webp was unexpectedly re-encoded")
	}

	ready := backend.waitForThumbnail(t, result.ID)
	thumbnailResponse, err := http.Get(backend.http.URL + ready.ThumbnailURL)
	if err != nil {
		t.Fatal(err)
	}
	_, err = webp.Decode(thumbnailResponse.Body)
	thumbnailResponse.Body.Close()
	if err != nil {
		t.Fatalf("decode webp thumbnail: %v", err)
	}
}

func TestPendingThumbnailIsRecoveredOnStartup(t *testing.T) {
	dataDir := t.TempDir()
	cfg := testConfig(dataDir, map[string]string{"alice": testToken})
	if err := os.MkdirAll(filepath.Join(dataDir, "tmp"), 0o750); err != nil {
		t.Fatal(err)
	}
	tempPath := filepath.Join(dataDir, "tmp", "pending.webp")
	if err := os.WriteFile(tempPath, makeWebP(t, 800, 600), 0o640); err != nil {
		t.Fatal(err)
	}
	record, err := newProcessor(cfg).process(tempPath, "alice")
	if err != nil {
		t.Fatal(err)
	}
	database, err := openStore(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	if err := database.insertImage(context.Background(), record); err != nil {
		database.close()
		t.Fatal(err)
	}
	if err := database.close(); err != nil {
		t.Fatal(err)
	}

	app, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		stored, found, err := app.store.getImageByID(context.Background(), record.ID)
		if err != nil {
			t.Fatal(err)
		}
		if found && stored.ThumbnailSize > 0 {
			if _, err := os.Stat(app.processor.thumbnailPath("alice", record.ID)); err != nil {
				t.Fatalf("recovered thumbnail is missing: %v", err)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("pending thumbnail was not recovered after startup")
}

func TestSpacesAreIsolatedButPublicImagesRemainPublic(t *testing.T) {
	backend := newTestBackendWithTokens(t, t.TempDir(), map[string]string{
		"alice": testToken,
		"bob":   secondTestToken,
	})
	aliceClient := backend.client
	bobClient := newCookieClient(t)
	backend.loginClient(t, aliceClient, testToken)
	backend.loginClient(t, bobClient, secondTestToken)

	source := makePNG(t, 320, 200)
	aliceImage := backend.uploadClient(t, aliceClient, "alice.png", source)
	if _, err := os.Stat(backend.server.processor.fullPath("alice", aliceImage.ID, "webp")); err != nil {
		t.Fatalf("alice image was not stored in alice partition: %v", err)
	}
	if _, err := os.Stat(backend.server.processor.fullPath("bob", aliceImage.ID, "webp")); !os.IsNotExist(err) {
		t.Fatalf("alice image unexpectedly exists in bob partition: %v", err)
	}

	if images := listForClient(t, backend, bobClient); len(images) != 0 {
		t.Fatalf("bob can see alice images: %#v", images)
	}
	if deleted := deleteForClient(t, backend, bobClient, aliceImage.ID); deleted != 0 {
		t.Fatalf("bob deleted %d alice images", deleted)
	}
	publicResponse, err := http.Get(backend.http.URL + aliceImage.URL)
	if err != nil {
		t.Fatal(err)
	}
	publicResponse.Body.Close()
	if publicResponse.StatusCode != http.StatusOK {
		t.Fatalf("public alice image status=%d", publicResponse.StatusCode)
	}

	bobImage := backend.uploadClient(t, bobClient, "bob.png", source)
	aliceImages := listForClient(t, backend, aliceClient)
	bobImages := listForClient(t, backend, bobClient)
	if len(aliceImages) != 1 || aliceImages[0].ID != aliceImage.ID {
		t.Fatalf("unexpected alice list: %#v", aliceImages)
	}
	if len(bobImages) != 1 || bobImages[0].ID != bobImage.ID {
		t.Fatalf("unexpected bob list: %#v", bobImages)
	}
}

func TestTokenRotationInvalidatesSessionsWithoutLosingImages(t *testing.T) {
	dataDir := t.TempDir()
	client := newCookieClient(t)

	firstApp, err := New(testConfig(dataDir, map[string]string{"alice": testToken}))
	if err != nil {
		t.Fatal(err)
	}
	firstHTTP := httptest.NewServer(firstApp.Handler())
	first := &testBackend{server: firstApp, http: firstHTTP, client: client}
	first.login(t)
	imageValue := first.upload(t, "before-rotation.png", makePNG(t, 320, 200))
	firstHTTP.Close()
	if err := firstApp.Close(); err != nil {
		t.Fatal(err)
	}

	secondApp, err := New(testConfig(dataDir, map[string]string{"alice": secondTestToken}))
	if err != nil {
		t.Fatal(err)
	}
	defer secondApp.Close()
	secondHTTP := httptest.NewServer(secondApp.Handler())
	defer secondHTTP.Close()
	second := &testBackend{server: secondApp, http: secondHTTP, client: client}

	listResponse, err := client.Get(secondHTTP.URL + "/api/images")
	if err != nil {
		t.Fatal(err)
	}
	listResponse.Body.Close()
	if listResponse.StatusCode != http.StatusUnauthorized {
		t.Fatalf("old session survived token rotation: status=%d", listResponse.StatusCode)
	}
	if status := loginStatus(t, secondHTTP.URL, client, testToken); status != http.StatusUnauthorized {
		t.Fatalf("old token status=%d", status)
	}
	second.loginClient(t, client, secondTestToken)
	images := listForClient(t, second, client)
	if len(images) != 1 || images[0].ID != imageValue.ID {
		t.Fatalf("rotated token lost image ownership: %#v", images)
	}
	publicResponse, err := http.Get(secondHTTP.URL + imageValue.URL)
	if err != nil {
		t.Fatal(err)
	}
	publicResponse.Body.Close()
	if publicResponse.StatusCode != http.StatusOK {
		t.Fatalf("public image after rotation status=%d", publicResponse.StatusCode)
	}
}

func TestSwitchingTokenRevokesTheReplacedSession(t *testing.T) {
	backend := newTestBackendWithTokens(t, t.TempDir(), map[string]string{
		"alice": testToken,
		"bob":   secondTestToken,
	})
	backend.loginClient(t, backend.client, testToken)
	baseURL, err := url.Parse(backend.http.URL + "/api/images")
	if err != nil {
		t.Fatal(err)
	}
	cookies := backend.client.Jar.Cookies(baseURL)
	if len(cookies) != 1 {
		t.Fatalf("alice cookies=%#v", cookies)
	}
	aliceHash := sha256.Sum256([]byte(cookies[0].Value))

	backend.loginClient(t, backend.client, secondTestToken)
	if ownerID, valid, err := backend.server.store.sessionOwner(t.Context(), aliceHash[:], time.Now()); err != nil || valid {
		t.Fatalf("replaced session owner=%q valid=%v err=%v", ownerID, valid, err)
	}
	if images := listForClient(t, backend, backend.client); len(images) != 0 {
		t.Fatalf("switched bob session has unexpected images: %#v", images)
	}
}

func TestLegacySingleTokenDatabaseAndFilesAreMigrated(t *testing.T) {
	dataDir := t.TempDir()
	database, err := sql.Open("sqlite", filepath.Join(dataDir, "metadata.sqlite3"))
	if err != nil {
		t.Fatal(err)
	}
	legacySchema := []string{
		`CREATE TABLE images (
			id TEXT PRIMARY KEY, extension TEXT NOT NULL, media_type TEXT NOT NULL,
			width INTEGER NOT NULL, height INTEGER NOT NULL, byte_size INTEGER NOT NULL,
			thumbnail_size INTEGER NOT NULL, animated INTEGER NOT NULL, created_at_ms INTEGER NOT NULL
		)`,
		`CREATE TABLE sessions (
			token_hash BLOB PRIMARY KEY, token_fingerprint BLOB NOT NULL, expires_at_ms INTEGER NOT NULL
		)`,
	}
	for _, statement := range legacySchema {
		if _, err := database.Exec(statement); err != nil {
			database.Close()
			t.Fatal(err)
		}
	}
	id := "0123456789abcdef0123456789abcdef"
	if _, err := database.Exec(`INSERT INTO images(
		id, extension, media_type, width, height, byte_size, thumbnail_size, animated, created_at_ms
	) VALUES (?, 'webp', 'image/webp', 10, 10, 4, 4, 0, ?)`, id, time.Now().UnixMilli()); err != nil {
		database.Close()
		t.Fatal(err)
	}
	if err := database.Close(); err != nil {
		t.Fatal(err)
	}
	legacyFull := filepath.Join(dataDir, "objects", id[:2], id[2:4], id+".webp")
	legacyThumbnail := filepath.Join(dataDir, "thumbnails", id[:2], id[2:4], id+".webp")
	for _, path := range []string{legacyFull, legacyThumbnail} {
		if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("webp"), 0o640); err != nil {
			t.Fatal(err)
		}
	}

	app, err := New(testConfig(dataDir, map[string]string{"alice": testToken}))
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	record, found, err := app.store.getImageByID(t.Context(), id)
	if err != nil || !found {
		t.Fatalf("migrated image lookup found=%v err=%v", found, err)
	}
	if record.OwnerID != "alice" {
		t.Fatalf("migrated owner=%q", record.OwnerID)
	}
	for _, path := range []string{
		app.processor.fullPath("alice", id, "webp"),
		app.processor.thumbnailPath("alice", id),
	} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("migrated file %s: %v", path, err)
		}
	}
	for _, path := range []string{legacyFull, legacyThumbnail} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("legacy file still present at %s: %v", path, err)
		}
	}
}

func TestAdministratorCreatesUserToken(t *testing.T) {
	dataDir := t.TempDir()
	backend := newTestBackendWithTokens(t, dataDir, map[string]string{"alice": testToken, "bob": secondTestToken})
	backend.login(t)

	body, err := json.Marshal(map[string]string{"space_id": "guest"})
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(http.MethodPost, backend.http.URL+"/api/admin/users", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := backend.client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusCreated {
		responseBody, _ := io.ReadAll(response.Body)
		t.Fatalf("create user status=%d body=%s", response.StatusCode, responseBody)
	}
	var created struct {
		User  accountResponse `json:"user"`
		Token string          `json:"token"`
	}
	if err := json.NewDecoder(response.Body).Decode(&created); err != nil {
		t.Fatal(err)
	}
	if created.User.SpaceID != "guest" || created.User.IsAdmin || created.User.QuotaBytes != defaultUserQuotaBytes || created.User.RetentionDays != defaultRetentionDays {
		t.Fatalf("unexpected created user: %#v", created.User)
	}
	if len(created.Token) != 64 {
		t.Fatalf("generated token length=%d", len(created.Token))
	}

	guestClient := newCookieClient(t)
	if status := loginStatus(t, backend.http.URL, guestClient, created.Token); status != http.StatusNoContent {
		t.Fatalf("guest login status=%d", status)
	}
	if images := listForClient(t, backend, guestClient); len(images) != 0 {
		t.Fatalf("new guest space is not empty: %#v", images)
	}

	bobClient := newCookieClient(t)
	backend.loginClient(t, bobClient, secondTestToken)
	forbidden, err := http.NewRequest(http.MethodPost, backend.http.URL+"/api/admin/users", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	forbidden.Header.Set("Content-Type", "application/json")
	forbiddenResponse, err := bobClient.Do(forbidden)
	if err != nil {
		t.Fatal(err)
	}
	forbiddenResponse.Body.Close()
	if forbiddenResponse.StatusCode != http.StatusForbidden {
		t.Fatalf("non-admin create status=%d", forbiddenResponse.StatusCode)
	}
}

func TestUploadQuotaIsEnforcedBeforeMetadataCommit(t *testing.T) {
	backend := newTestBackend(t)
	backend.login(t)
	if _, err := backend.server.store.db.Exec(`UPDATE users SET quota_bytes = 1 WHERE id = 'alice'`); err != nil {
		t.Fatal(err)
	}

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", "quota.png")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write(makePNG(t, 16, 16)); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(http.MethodPost, backend.http.URL+"/api/images", &body)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", writer.FormDataContentType())
	response, err := backend.client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("quota response status=%d", response.StatusCode)
	}
	account, found, err := backend.server.store.account(t.Context(), "alice")
	if err != nil || !found {
		t.Fatalf("account lookup found=%v err=%v", found, err)
	}
	if account.ImageCount != 0 || account.UsedBytes != 0 {
		t.Fatalf("quota rejection left usage: %#v", account)
	}
}

func TestDynamicallyCreatedUserSurvivesRestart(t *testing.T) {
	dataDir := t.TempDir()
	cfg := testConfig(dataDir, map[string]string{"alice": testToken})
	first, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	guestToken := "persistent-guest-token-with-enough-random-test-material"
	fingerprint := sha256.Sum256([]byte(guestToken))
	created, err := first.store.createAccount(t.Context(), "guest", fingerprint[:], defaultUserQuotaBytes, defaultRetentionDays)
	if err != nil || !created {
		t.Fatalf("create dynamic user created=%v err=%v", created, err)
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}

	second, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	httpServer := httptest.NewServer(second.Handler())
	defer httpServer.Close()
	if status := loginStatus(t, httpServer.URL, newCookieClient(t), guestToken); status != http.StatusNoContent {
		t.Fatalf("dynamic user login after restart status=%d", status)
	}
}

func TestExpiredImagesArePermanentlyCleaned(t *testing.T) {
	backend := newTestBackend(t)
	backend.login(t)
	imageValue := backend.upload(t, "expired.png", makePNG(t, 32, 24))
	backend.waitForThumbnail(t, imageValue.ID)
	createdAt := time.Now().AddDate(0, 0, -(defaultRetentionDays + 1)).UnixMilli()
	if _, err := backend.server.store.db.Exec(`UPDATE images SET created_at_ms = ? WHERE id = ?`, createdAt, imageValue.ID); err != nil {
		t.Fatal(err)
	}

	backend.server.cleanupExpiredImages(time.Now())
	if _, found, err := backend.server.store.getImageByID(t.Context(), imageValue.ID); err != nil || found {
		t.Fatalf("expired metadata found=%v err=%v", found, err)
	}
	publicResponse, err := http.Get(backend.http.URL + imageValue.URL)
	if err != nil {
		t.Fatal(err)
	}
	publicResponse.Body.Close()
	if publicResponse.StatusCode != http.StatusNotFound {
		t.Fatalf("expired public image status=%d", publicResponse.StatusCode)
	}
}

func TestConfiguredCredentialsValidation(t *testing.T) {
	tests := []map[string]string{
		nil,
		{"bad/space": testToken},
		{"alice": ""},
		{"alice": testToken, "bob": testToken},
	}
	for _, tokens := range tests {
		if _, err := configuredCredentials(tokens); err == nil {
			t.Fatalf("expected invalid token configuration: %#v", tokens)
		}
	}
}

func listForClient(t *testing.T, backend *testBackend, client *http.Client) []imageResponse {
	t.Helper()
	response, err := client.Get(backend.http.URL + "/api/images?range=all")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("list status=%d body=%s", response.StatusCode, body)
	}
	var result struct {
		Images []imageResponse `json:"images"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	return result.Images
}

func deleteForClient(t *testing.T, backend *testBackend, client *http.Client, ids ...string) int {
	t.Helper()
	body, err := json.Marshal(map[string]any{"ids": ids})
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(http.MethodDelete, backend.http.URL+"/api/images", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		responseBody, _ := io.ReadAll(response.Body)
		t.Fatalf("delete status=%d body=%s", response.StatusCode, responseBody)
	}
	var result struct {
		Deleted int `json:"deleted"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	return result.Deleted
}

func loginStatus(t *testing.T, baseURL string, client *http.Client, token string) int {
	t.Helper()
	request, err := http.NewRequest(http.MethodPost, baseURL+"/api/auth/session", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	return response.StatusCode
}

func makePNG(t *testing.T, width, height int) []byte {
	t.Helper()
	value := image.NewNRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			value.SetNRGBA(x, y, color.NRGBA{
				R: uint8(x % 256),
				G: uint8(y % 256),
				B: uint8((x + y) % 256),
				A: 255,
			})
		}
	}
	var output bytes.Buffer
	if err := png.Encode(&output, value); err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}

func makeGIF(t *testing.T) []byte {
	t.Helper()
	palette := color.Palette{color.Black, color.White, color.RGBA{R: 255, A: 255}}
	first := image.NewPaletted(image.Rect(0, 0, 32, 24), palette)
	second := image.NewPaletted(image.Rect(0, 0, 32, 24), palette)
	for index := range first.Pix {
		first.Pix[index] = uint8(index % 2)
		second.Pix[index] = uint8((index + 1) % 3)
	}
	var output bytes.Buffer
	if err := gif.EncodeAll(&output, &gif.GIF{
		Image:     []*image.Paletted{first, second},
		Delay:     []int{5, 5},
		LoopCount: 0,
	}); err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}
