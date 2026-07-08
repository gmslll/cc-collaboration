# cc-handoff build / release Makefile.
#
# VERSION (read from the file of the same name) is embedded into every binary
# via -ldflags so `cc-handoff version` and the MCP server startup log report
# the same string. Bump VERSION + add a CHANGELOG entry before `make release-tag`.

VERSION     := $(shell cat VERSION)
LDFLAGS     := -X 'github.com/cc-collaboration/internal/version.Version=$(VERSION)'
INSTALL_DIR ?= /usr/local/bin

.PHONY: all build cli relay mcp web relay-linux relay-linux-arm64 cli-windows-amd64 cli-windows-arm64 mcp-windows-amd64 mcp-windows-arm64 windows app-run app-macos app-apk package package-macos package-android install test e2e deploy clean version release-tag

all: build

build: cli relay mcp

cli:
	go build -ldflags "$(LDFLAGS)" -o bin/cc-handoff ./cmd/cc-handoff

# web builds the Flutter Web client (the browser version of the phone's remote
# workspace) and stages it into internal/relay/app, where the relay embeds it via
# //go:embed and serves it at /app/. The bundle is gitignored (a tracked .gitkeep
# keeps the embed compilable on a fresh clone); this regenerates it. The relay
# targets depend on it so the embedded client is always current — for a fast
# Go-only relay build that skips this, run `go build ./cmd/relay` directly.
web:
	cd app && flutter build web -t lib/main_web.dart --base-href /app/ --dart-define=APP_VERSION=$(VERSION)
	rm -rf internal/relay/app
	mkdir -p internal/relay/app
	cp -R app/build/web/. internal/relay/app/
	touch internal/relay/app/.gitkeep

relay: web
	go build -ldflags "$(LDFLAGS)" -o bin/cc-relay ./cmd/relay

mcp:
	go build -ldflags "$(LDFLAGS)" -o bin/cc-handoff-mcp ./cmd/cc-handoff-mcp

# Cross-builds for a Linux VPS. Depend on `web` so the shipped binary embeds the
# current client bundle (built on this machine, then cross-compiled in).
relay-linux: web
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o bin/cc-relay-linux-amd64 ./cmd/relay

relay-linux-arm64: web
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o bin/cc-relay-linux-arm64 ./cmd/relay

# Cross-builds for Windows. Receivers run cli + mcp; the relay is backend-only
# and not built for Windows.
cli-windows-amd64:
	GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o bin/cc-handoff-windows-amd64.exe ./cmd/cc-handoff

cli-windows-arm64:
	GOOS=windows GOARCH=arm64 CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o bin/cc-handoff-windows-arm64.exe ./cmd/cc-handoff

mcp-windows-amd64:
	GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o bin/cc-handoff-mcp-windows-amd64.exe ./cmd/cc-handoff-mcp

mcp-windows-arm64:
	GOOS=windows GOARCH=arm64 CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o bin/cc-handoff-mcp-windows-arm64.exe ./cmd/cc-handoff-mcp

# Aggregate: build all Windows binaries (amd64 + arm64) for cli and mcp.
windows: cli-windows-amd64 cli-windows-arm64 mcp-windows-amd64 mcp-windows-arm64

# GUI client (Flutter, in app/). It's a separate Dart project that talks to the
# relay over HTTP and shells the cc-handoff CLI for local ops — build/run it from
# app/ with the flutter tool; these are convenience wrappers. See app/README.md.
app-run:
	cd app && flutter run -d macos

app-macos:
	cd app && flutter build macos --release

app-apk:
	cd app && flutter build apk --release

# Distributable packages (GUI + embedded cc-handoff CLI) into dist/. macOS and
# Android build here; the Windows desktop app must be packaged on Windows with
# scripts/package.ps1 (this also cross-builds the Windows CLI for it).
package:
	bash scripts/package.sh all

package-macos:
	bash scripts/package.sh macos

package-android:
	bash scripts/package.sh android

install: cli mcp
	install -m 755 bin/cc-handoff $(INSTALL_DIR)/cc-handoff
	install -m 755 bin/cc-handoff-mcp $(INSTALL_DIR)/cc-handoff-mcp

test:
	go test ./...

e2e: build
	bash scripts/e2e.sh

# One-shot deploy: cross-builds, ships, installs, restarts. Idempotent.
#   make deploy HOST=user@your-vps
#   make deploy HOST=user@your-vps SSH_OPTS="-p 2222 -i ~/.ssh/id_ed25519"
deploy:
	@if [ -z "$(HOST)" ]; then echo "usage: make deploy HOST=user@host"; exit 2; fi
	bash scripts/deploy.sh $(HOST)

clean:
	rm -rf bin/

version:
	@echo $(VERSION)

# release-tag: cuts an annotated v$(VERSION) tag locally after test+build pass
# and CHANGELOG has the matching entry. Push manually with
# `git push origin v$(VERSION)` once you've reviewed.
release-tag: test build
	@if git rev-parse v$(VERSION) >/dev/null 2>&1; then \
		echo "tag v$(VERSION) already exists; bump VERSION first"; exit 1; \
	fi
	@if ! grep -q "^## \[$(VERSION)\]" CHANGELOG.md; then \
		echo "CHANGELOG.md has no entry for [$(VERSION)]; add one before tagging"; exit 1; \
	fi
	git tag -a v$(VERSION) -m "cc-handoff v$(VERSION)"
	@echo "tagged v$(VERSION) — review with: git show v$(VERSION)"
	@echo "push with: git push origin v$(VERSION)"
