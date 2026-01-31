.PHONY: build install uninstall test lint clean build-all

BINARY := moltstream
VERSION := 0.1.0
GOFLAGS := -ldflags="-s -w -X main.Version=$(VERSION)"
INSTALL_DIR := $(HOME)/.local/bin

build:
	go build $(GOFLAGS) -o $(BINARY) ./cmd/moltstream

install: build
	@mkdir -p $(INSTALL_DIR)
	cp $(BINARY) $(INSTALL_DIR)/
	@echo "✅ Installed to $(INSTALL_DIR)/$(BINARY)"
	@echo ""
	@echo "Make sure $(INSTALL_DIR) is in your PATH"
	@echo "Then run:"
	@echo "  mkdir -p ~/.config/moltstream"
	@echo "  cp config.example.yaml ~/.config/moltstream/config.yaml"

uninstall:
	rm -f $(INSTALL_DIR)/$(BINARY)
	@echo "✅ Uninstalled"

test:
	go test -v ./...

lint:
	golangci-lint run

clean:
	rm -f $(BINARY)
	rm -rf dist/

build-all:
	@mkdir -p dist
	GOOS=darwin GOARCH=arm64 go build $(GOFLAGS) -o dist/$(BINARY)-darwin-arm64 ./cmd/moltstream
	GOOS=darwin GOARCH=amd64 go build $(GOFLAGS) -o dist/$(BINARY)-darwin-amd64 ./cmd/moltstream
	GOOS=linux GOARCH=amd64 go build $(GOFLAGS) -o dist/$(BINARY)-linux-amd64 ./cmd/moltstream
	GOOS=linux GOARCH=arm64 go build $(GOFLAGS) -o dist/$(BINARY)-linux-arm64 ./cmd/moltstream
	@echo "✅ Built binaries in dist/"

# Development helpers
dev:
	go run ./cmd/moltstream

deps:
	go mod download
	go mod tidy
