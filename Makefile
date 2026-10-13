SHELL   := /usr/bin/env bash
ROOT    := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
STYLUAC := $(ROOT)/.stylua.toml
SELENEC := $(ROOT)/selene.toml

.PHONY: check format format-check lint test help

check: format-check lint test

# Headless tests write lock files to a temporary CLAUDE_CONFIG_DIR, never ~/.claude
test:
	@tmp_dir="$$(mktemp -d)" || exit $$?; trap 'rm -rf "$$tmp_dir"' EXIT; \
		cd "$(ROOT)" && XDG_CACHE_HOME="$$tmp_dir/cache" CLAUDE_CONFIG_DIR="$$tmp_dir/claude" \
		nvim --headless -u NONE -l "tests/headless.lua"

format:
	@stylua --config-path "$(STYLUAC)" "$(ROOT)"

format-check:
	@stylua --check --config-path "$(STYLUAC)" "$(ROOT)"

lint:
	@selene --config "$(SELENEC)" "$(ROOT)/lua" "$(ROOT)/plugin" "$(ROOT)/tests"

help:
	@echo "Available targets:"
	@echo "  check        - Check formatting, lint, and run tests"
	@echo "  format       - Format Lua files with stylua"
	@echo "  format-check - Check Lua formatting with stylua"
	@echo "  lint         - Lint Lua files with selene"
	@echo "  test         - Run dependency-free headless tests"
