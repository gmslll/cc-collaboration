.PHONY: all build cli relay mcp relay-linux relay-linux-arm64 test e2e deploy clean

all: build

build: cli relay mcp

cli:
	go build -o bin/cc-handoff ./cmd/cc-handoff

relay:
	go build -o bin/cc-relay ./cmd/relay

mcp:
	go build -o bin/cc-handoff-mcp ./cmd/cc-handoff-mcp

# Cross-builds for a Linux VPS.
relay-linux:
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o bin/cc-relay-linux-amd64 ./cmd/relay

relay-linux-arm64:
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o bin/cc-relay-linux-arm64 ./cmd/relay

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
