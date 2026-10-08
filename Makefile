# Installs the `hangar` command. Built next to the old binary and renamed over it, so running
# session keepers (which run this binary) keep their old copy.
BIN ?= $(HOME)/.local/bin/hangar

install:
	cd backend && go build -ldflags "-X main.version=$$(git describe --tags --always --dirty)" -o $(BIN).new . && mv -f $(BIN).new $(BIN)
	@echo "installed $(BIN)"

.PHONY: install
