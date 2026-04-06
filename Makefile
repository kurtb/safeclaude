BINARY    := safeclaude
VERSION   ?= dev
COMMIT    := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
LDFLAGS   := -ldflags "-X github.com/kurtb/safeclaude/internal/version.Version=$(VERSION) -X github.com/kurtb/safeclaude/internal/version.Commit=$(COMMIT)"

.PHONY: build install test test-coverage clean docker

build:
	go build $(LDFLAGS) -o bin/$(BINARY) ./cmd/safeclaude

install:
	go install $(LDFLAGS) ./cmd/safeclaude

test:
	go test ./... -coverprofile=coverage.out -covermode=atomic
	go tool cover -func=coverage.out

test-coverage:
	go test ./... -coverprofile=coverage.out -covermode=atomic
	go tool cover -html=coverage.out -o coverage.html
	@echo "Coverage report: coverage.html"

clean:
	rm -rf bin/ dist/ coverage.out coverage.html

docker:
	docker build -t safeclaude:latest .
