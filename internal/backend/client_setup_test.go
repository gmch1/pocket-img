package backend

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestFNOSGatewaySSOAndTCPTrustBoundary(t *testing.T) {
	cfg := fnosTestConfig(t.TempDir())
	cfg.FNOS.PublicBaseURL = "https://media.example.test"
	app, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	directHTTP := httptest.NewServer(app.Handler())
	fnosHTTP := httptest.NewServer(app.FNOSHandler())
	t.Cleanup(func() {
		fnosHTTP.Close()
		directHTTP.Close()
		if err := app.Close(); err != nil {
			t.Errorf("close backend: %v", err)
		}
	})

	missingIdentity := mustRequest(t, http.MethodGet, fnosHTTP.URL+"/app/pocket-img/api/images", nil)
	missingResponse, err := http.DefaultClient.Do(missingIdentity)
	if err != nil {
		t.Fatal(err)
	}
	missingResponse.Body.Close()
	if missingResponse.StatusCode != http.StatusUnauthorized {
		t.Fatalf("missing FNOS identity status=%d", missingResponse.StatusCode)
	}

	spoofedTCP := mustRequest(t, http.MethodGet, directHTTP.URL+"/api/images", nil)
	setFNOSHeaders(spoofedTCP, "1000", "Alice", true)
	spoofedResponse, err := http.DefaultClient.Do(spoofedTCP)
	if err != nil {
		t.Fatal(err)
	}
	spoofedResponse.Body.Close()
	if spoofedResponse.StatusCode != http.StatusUnauthorized {
		t.Fatalf("spoofed TCP FNOS headers status=%d", spoofedResponse.StatusCode)
	}

	firstList := doFNOSRequest(t, fnosHTTP.URL, http.MethodGet, "/api/images?range=all", "1000", "Alice", false, nil)
	defer firstList.Body.Close()
	if firstList.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(firstList.Body)
		t.Fatalf("FNOS list status=%d body=%s", firstList.StatusCode, body)
	}
	var firstGallery struct {
		Images  []imageResponse `json:"images"`
		Account accountResponse `json:"account"`
	}
	if err := json.NewDecoder(firstList.Body).Decode(&firstGallery); err != nil {
		t.Fatal(err)
	}
	if firstGallery.Account.SpaceID != fnosOwnerID("1000") || firstGallery.Account.DisplayName != "Alice" || firstGallery.Account.IsAdmin {
		t.Fatalf("unexpected FNOS account: %#v", firstGallery.Account)
	}

	forbiddenAdmin := doFNOSRequest(t, fnosHTTP.URL, http.MethodGet, "/api/admin/users", "1000", "Alice", false, nil)
	forbiddenAdmin.Body.Close()
	if forbiddenAdmin.StatusCode != http.StatusForbidden {
		t.Fatalf("ordinary FNOS user admin status=%d", forbiddenAdmin.StatusCode)
	}
	allowedAdmin := doFNOSRequest(t, fnosHTTP.URL, http.MethodGet, "/api/admin/users", "1000", "Alice", true, nil)
	allowedAdmin.Body.Close()
	if allowedAdmin.StatusCode != http.StatusOK {
		t.Fatalf("FNOS administrator status=%d", allowedAdmin.StatusCode)
	}

	setupResponse := doFNOSRequest(t, fnosHTTP.URL, http.MethodGet, "/api/client-setup", "1000", "Alice Renamed", true, nil)
	defer setupResponse.Body.Close()
	var setup struct {
		Mode            string          `json:"mode"`
		ManagementURL   string          `json:"management_url"`
		ServiceURL      string          `json:"service_url"`
		TokenConfigured bool            `json:"token_configured"`
		User            accountResponse `json:"user"`
	}
	if err := json.NewDecoder(setupResponse.Body).Decode(&setup); err != nil {
		t.Fatal(err)
	}
	if setupResponse.StatusCode != http.StatusOK || setup.Mode != "fnos" || setup.ManagementURL != "/app/pocket-img/" || setup.ServiceURL != cfg.FNOS.PublicBaseURL {
		t.Fatalf("unexpected setup response: status=%d value=%#v", setupResponse.StatusCode, setup)
	}
	if setup.TokenConfigured || setup.User.SpaceID != firstGallery.Account.SpaceID || setup.User.DisplayName != "Alice Renamed" || !setup.User.IsAdmin {
		t.Fatalf("FNOS identity was not updated stably: %#v", setup)
	}

	createdTokenResponse := doFNOSRequest(t, fnosHTTP.URL, http.MethodPost, "/api/client-setup/token", "1000", "Alice Renamed", true, nil)
	defer createdTokenResponse.Body.Close()
	var createdToken struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(createdTokenResponse.Body).Decode(&createdToken); err != nil {
		t.Fatal(err)
	}
	if createdTokenResponse.StatusCode != http.StatusCreated || len(createdToken.Token) != 64 || createdTokenResponse.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("unexpected generated token response: status=%d token_length=%d cache=%q", createdTokenResponse.StatusCode, len(createdToken.Token), createdTokenResponse.Header.Get("Cache-Control"))
	}

	directClient := newCookieClient(t)
	testValue := &testBackend{server: app, http: directHTTP, client: directClient}
	testValue.loginClient(t, directClient, createdToken.Token)
	uploaded := testValue.uploadClient(t, directClient, "fnos.png", makePNG(t, 48, 32))

	listed := doFNOSRequest(t, fnosHTTP.URL, http.MethodGet, "/api/images?range=all", "1000", "Alice Renamed", true, nil)
	defer listed.Body.Close()
	var listedGallery struct {
		Images  []imageResponse `json:"images"`
		Account accountResponse `json:"account"`
	}
	if err := json.NewDecoder(listed.Body).Decode(&listedGallery); err != nil {
		t.Fatal(err)
	}
	if len(listedGallery.Images) != 1 || listedGallery.Images[0].ID != uploaded.ID {
		t.Fatalf("FNOS gallery images=%#v", listedGallery.Images)
	}
	listedImage := listedGallery.Images[0]
	if listedImage.URL != cfg.FNOS.PublicBaseURL+"/i/"+uploaded.ID+".webp" {
		t.Fatalf("public URL=%q", listedImage.URL)
	}
	if listedImage.DisplayURL != "/app/pocket-img/i/"+uploaded.ID+".webp" || !strings.HasPrefix(listedImage.ThumbnailURL, "/app/pocket-img/") {
		t.Fatalf("gateway display URLs=%#v", listedImage)
	}

	secondUser := doFNOSRequest(t, fnosHTTP.URL, http.MethodGet, "/api/images?range=all", "2000", "Bob", false, nil)
	defer secondUser.Body.Close()
	var secondGallery struct {
		Images  []imageResponse `json:"images"`
		Account accountResponse `json:"account"`
	}
	if err := json.NewDecoder(secondUser.Body).Decode(&secondGallery); err != nil {
		t.Fatal(err)
	}
	if len(secondGallery.Images) != 0 || secondGallery.Account.SpaceID == firstGallery.Account.SpaceID {
		t.Fatalf("FNOS users are not isolated: %#v", secondGallery)
	}

	directAccount := listAccountForClient(t, directHTTP.URL, directClient)
	if directAccount.IsAdmin {
		t.Fatal("a FNOS administrator's TCP client token inherited administrator privileges")
	}

	revokeResponse := doFNOSRequest(t, fnosHTTP.URL, http.MethodDelete, "/api/client-setup/token", "1000", "Alice Renamed", true, nil)
	revokeResponse.Body.Close()
	if revokeResponse.StatusCode != http.StatusNoContent {
		t.Fatalf("revoke status=%d", revokeResponse.StatusCode)
	}
	afterRevoke, err := directClient.Get(directHTTP.URL + "/api/images")
	if err != nil {
		t.Fatal(err)
	}
	afterRevoke.Body.Close()
	if afterRevoke.StatusCode != http.StatusUnauthorized {
		t.Fatalf("client session survived revocation: status=%d", afterRevoke.StatusCode)
	}
	if status := loginStatus(t, directHTTP.URL, newCookieClient(t), createdToken.Token); status != http.StatusUnauthorized {
		t.Fatalf("revoked client token status=%d", status)
	}
}

func TestFNOSClientDownloadManifestAndServing(t *testing.T) {
	downloadsDir := t.TempDir()
	archive := []byte("signed macOS archive fixture")
	filename := "PocketIMGShot-0.5.0-macos-arm64.zip"
	if err := os.WriteFile(filepath.Join(downloadsDir, filename), archive, 0o640); err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(archive)
	manifest := map[string]any{
		"schema_version": 1,
		"artifacts": []map[string]any{{
			"id": "pocketimg-shot-macos-arm64", "display_name": "PocketIMG Shot",
			"version": "0.5.0", "platform": "macos", "architecture": "arm64",
			"minimum_os_version": "14.0", "filename": filename,
			"content_type": "application/zip", "sha256": hex.EncodeToString(hash[:]),
		}},
	}
	manifestBytes, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(downloadsDir, "manifest.json"), manifestBytes, 0o640); err != nil {
		t.Fatal(err)
	}

	cfg := fnosTestConfig(t.TempDir())
	cfg.FNOS.DownloadsDir = downloadsDir
	app, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(app.FNOSHandler())
	t.Cleanup(func() {
		server.Close()
		_ = app.Close()
	})

	setupResponse := doFNOSRequest(t, server.URL, http.MethodGet, "/api/client-setup", "1000", "Alice", false, nil)
	defer setupResponse.Body.Close()
	var setup struct {
		Download *clientDownloadResponse `json:"download"`
	}
	if err := json.NewDecoder(setupResponse.Body).Decode(&setup); err != nil {
		t.Fatal(err)
	}
	if setup.Download == nil || setup.Download.Filename != filename || setup.Download.SizeBytes != int64(len(archive)) || setup.Download.URL != "/app/pocket-img/downloads/"+filename {
		t.Fatalf("download setup=%#v", setup.Download)
	}

	downloadResponse := doFNOSRequest(t, server.URL, http.MethodGet, "/downloads/"+filename, "1000", "Alice", false, nil)
	downloadBody, err := io.ReadAll(downloadResponse.Body)
	downloadResponse.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	if downloadResponse.StatusCode != http.StatusOK || !bytes.Equal(downloadBody, archive) {
		t.Fatalf("download status=%d body=%q", downloadResponse.StatusCode, downloadBody)
	}
	if downloadResponse.Header.Get("Content-Type") != "application/zip" || !strings.Contains(downloadResponse.Header.Get("Content-Disposition"), filename) {
		t.Fatalf("download headers: type=%q disposition=%q", downloadResponse.Header.Get("Content-Type"), downloadResponse.Header.Get("Content-Disposition"))
	}
}

func TestFNOSConfigurationAndIdentityValidation(t *testing.T) {
	invalidConfigs := []FNOSConfig{
		{Enabled: true, GatewayPrefix: "/"},
		{Enabled: true, GatewayPrefix: "app/pocket-img"},
		{Enabled: true, GatewayPrefix: "/app/pocket-img/"},
		{Enabled: true, GatewayPrefix: "/app/pocket-img", ServicePort: 70000},
		{Enabled: true, GatewayPrefix: "/app/pocket-img", PublicBaseURL: "https://example.test/path"},
	}
	for _, value := range invalidConfigs {
		cfg := value
		if err := normalizeFNOSConfig(&cfg); err == nil {
			t.Fatalf("expected invalid FNOS config: %#v", value)
		}
	}
	if fnosOwnerID("用户/1000") != fnosOwnerID("用户/1000") || fnosOwnerID("用户/1000") == fnosOwnerID("用户/1001") {
		t.Fatal("FNOS owner ID derivation is not stable and isolated")
	}
}

func TestFNOSModePreservesAccountsFromExistingLinuxData(t *testing.T) {
	dataDir := t.TempDir()
	linuxApp, err := New(testConfig(dataDir, map[string]string{"alice": testToken}))
	if err != nil {
		t.Fatal(err)
	}
	if err := linuxApp.Close(); err != nil {
		t.Fatal(err)
	}

	fnosApp, err := New(fnosTestConfig(dataDir))
	if err != nil {
		t.Fatal(err)
	}
	directHTTP := httptest.NewServer(fnosApp.Handler())
	t.Cleanup(func() {
		directHTTP.Close()
		_ = fnosApp.Close()
	})

	client := newCookieClient(t)
	if status := loginStatus(t, directHTTP.URL, client, testToken); status != http.StatusNoContent {
		t.Fatalf("existing Linux token was disabled in FNOS mode: status=%d", status)
	}
	account := listAccountForClient(t, directHTTP.URL, client)
	if account.SpaceID != "alice" || !account.IsAdmin {
		t.Fatalf("existing Linux account changed: %#v", account)
	}
}

func fnosTestConfig(dataDir string) Config {
	cfg := testConfig(dataDir, map[string]string{"alice": testToken})
	cfg.Tokens = nil
	cfg.AdminSpaceID = ""
	cfg.FNOS = FNOSConfig{
		Enabled: true, GatewayPrefix: "/app/pocket-img", ServicePort: 18080,
		ApplicationVersion: "0.5.0",
	}
	return cfg
}

func doFNOSRequest(t *testing.T, serverURL, method, path, userID, username string, isAdmin bool, body io.Reader) *http.Response {
	t.Helper()
	request := mustRequest(t, method, serverURL+"/app/pocket-img"+path, body)
	setFNOSHeaders(request, userID, username, isAdmin)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

func setFNOSHeaders(request *http.Request, userID, username string, isAdmin bool) {
	request.Header.Set(fnosUserIDHeader, userID)
	request.Header.Set(fnosUsernameHeader, username)
	request.Header.Set(fnosAdminHeader, strings.ToLower(strconv.FormatBool(isAdmin)))
}

func mustRequest(t *testing.T, method, target string, body io.Reader) *http.Request {
	t.Helper()
	request, err := http.NewRequest(method, target, body)
	if err != nil {
		t.Fatal(err)
	}
	return request
}

func listAccountForClient(t *testing.T, serverURL string, client *http.Client) accountResponse {
	t.Helper()
	response, err := client.Get(serverURL + "/api/images?range=all")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("list account status=%d body=%s", response.StatusCode, body)
	}
	var result struct {
		Account accountResponse `json:"account"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	return result.Account
}
