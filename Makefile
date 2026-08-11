.PHONY: frontend-install frontend-test frontend-build test build build-arm64 android-test android-debug android-release

GO ?= go
NPM ?= npm
GO_BUILD_FLAGS := -tags=nodynamic -trimpath -ldflags="-s -w"

frontend-install:
	cd frontend && $(NPM) ci

frontend-test:
	cd frontend && $(NPM) test

frontend-build:
	cd frontend && $(NPM) run build

test: frontend-test frontend-build
	GOTOOLCHAIN=auto $(GO) test -tags=nodynamic ./...

build: frontend-build
	mkdir -p dist
	GOTOOLCHAIN=auto CGO_ENABLED=0 $(GO) build $(GO_BUILD_FLAGS) -o dist/phone-image-host-linux-amd64 ./cmd/server

build-arm64: frontend-build
	mkdir -p dist
	GOTOOLCHAIN=auto CGO_ENABLED=0 GOOS=linux GOARCH=arm64 $(GO) build $(GO_BUILD_FLAGS) -o dist/phone-image-host-linux-arm64 ./cmd/server

android-test: frontend-build
	cd android && ./gradlew testDebugUnitTest

android-debug: frontend-build
	cd android && ./gradlew assembleDebug

android-release: frontend-build
	cd android && ./gradlew assembleRelease
