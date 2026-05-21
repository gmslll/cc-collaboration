# cc-handoff build / release Makefile.
#
# VERSION (read from the file of the same name) is embedded into every binary
# via -ldflags so `cc-handoff version` and the MCP server startup log report
# the same string. Bump VERSION + add a CHANGELOG entry before `make release-tag`.

VERSION     := $(shell cat VERSION)
LDFLAGS     := -X 'github.com/cc-collaboration/internal/version.Version=$(VERSION)'
INSTALL_DIR ?= /usr/local/bin

.PHONY: all build cli relay mcp desktop desktop-darwin-package desktop-windows-package relay-linux relay-linux-arm64 cli-windows-amd64 cli-windows-arm64 mcp-windows-amd64 mcp-windows-arm64 windows install test e2e deploy clean version release-tag

DESKTOP_APPID ?= ai.claude.cc-handoff
DESKTOP_ICON  ?= $(CURDIR)/assets/icon.png

all: build

build: cli relay mcp

cli:
	go build -ldflags "$(LDFLAGS)" -o bin/cc-handoff ./cmd/cc-handoff

relay:
	go build -ldflags "$(LDFLAGS)" -o bin/cc-relay ./cmd/relay

mcp:
	go build -ldflags "$(LDFLAGS)" -o bin/cc-handoff-mcp ./cmd/cc-handoff-mcp

# Native desktop client (Fyne). Requires CGO + a C toolchain. Cross-compile
# targets below (desktop-windows-package) rely on mingw-w64 / fyne-cross.
desktop:
	go build -ldflags "$(LDFLAGS)" -o bin/cc-handoff-desktop ./cmd/cc-handoff-desktop

# `fyne` CLI required: go install fyne.io/fyne/v2/cmd/fyne@latest
# Produces bin/cc-handoff.app (macOS) or bin/cc-handoff.exe (Windows). The
# binary inside the .app stays unsigned; first launch on a fresh mac needs
# right-click → Open to bypass Gatekeeper. Add Developer ID signing later.
desktop-darwin-package:
	cd cmd/cc-handoff-desktop && fyne package \
		-os darwin -name cc-handoff -appID $(DESKTOP_APPID) \
		-appVersion $(VERSION) -icon $(DESKTOP_ICON) -release
	mkdir -p bin
	rm -rf bin/cc-handoff.app
	mv cmd/cc-handoff-desktop/cc-handoff.app bin/

# Windows packaging from macOS needs mingw-w64 (`brew install mingw-w64`) or
# fyne-cross. Easiest CI path: run this target on a Windows runner.
desktop-windows-package:
	cd cmd/cc-handoff-desktop && fyne package \
		-os windows -name cc-handoff -appID $(DESKTOP_APPID) \
		-appVersion $(VERSION) -icon $(DESKTOP_ICON)
	mkdir -p bin
	mv cmd/cc-handoff-desktop/cc-handoff.exe bin/cc-handoff-desktop.exe

# Cross-builds for a Linux VPS.
relay-linux:
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o bin/cc-relay-linux-amd64 ./cmd/relay

relay-linux-arm64:
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
