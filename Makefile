.PHONY: help build release install uninstall run test test-offline fmt fmt-check check clean

ZIG    ?= zig
PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin

# Colors
GREEN  := \033[0;32m
YELLOW := \033[0;33m
BLUE   := \033[0;34m
CYAN   := \033[0;36m
RED    := \033[0;31m
RESET  := \033[0m
BOLD   := \033[1m

.DEFAULT_GOAL := help

## Build:

build: ## Debug build
	@printf "$(BLUE)Building (debug)...$(RESET)\n"
	@$(ZIG) build
	@printf "$(GREEN)Built ./zig-out/bin/metalbrew$(RESET)\n"

release: ## Optimized build (ReleaseSafe)
	@printf "$(BLUE)Building (ReleaseSafe)...$(RESET)\n"
	@$(ZIG) build -Doptimize=ReleaseSafe
	@printf "$(GREEN)Built ./zig-out/bin/metalbrew$(RESET)\n"

install: release ## Build release and install metalbrew into $(PREFIX)/bin
	@printf "$(BLUE)Installing to $(BINDIR)/metalbrew...$(RESET)\n"
	@mkdir -p "$(BINDIR)"
	@cp -f zig-out/bin/metalbrew "$(BINDIR)/metalbrew"
	@printf "$(GREEN)Installed $(BINDIR)/metalbrew$(RESET)\n"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) printf "$(YELLOW)Note: $(BINDIR) is not on your PATH — add it to use 'metalbrew' directly.$(RESET)\n";; esac

uninstall: ## Remove the installed binary
	@rm -f "$(BINDIR)/metalbrew"
	@printf "$(GREEN)Removed $(BINDIR)/metalbrew$(RESET)\n"

## Run:

run: ## Run the dev build (pass args with ARGS="info wget")
	@$(ZIG) build run -- $(ARGS)

## Quality:

test: ## Run the full test suite (network tests skip on failure)
	@printf "$(BLUE)Running tests...$(RESET)\n"
	@$(ZIG) build test --summary all
	@printf "$(GREEN)Tests OK$(RESET)\n"

test-offline: ## Run tests with the two network tests force-skipped
	@printf "$(BLUE)Running tests (offline)...$(RESET)\n"
	@METALBREW_SKIP_NET=1 $(ZIG) build test --summary all
	@printf "$(GREEN)Tests OK$(RESET)\n"

fmt: ## Format all Zig sources
	@$(ZIG) fmt build.zig src
	@printf "$(GREEN)Formatted$(RESET)\n"

fmt-check: ## Check formatting without writing
	@$(ZIG) fmt --check build.zig src

check: fmt-check test-offline ## CI-style checks (format + offline tests)
	@printf "$(GREEN)$(BOLD)All checks passed$(RESET)\n"

## Housekeeping:

clean: ## Remove build artefacts
	@printf "$(YELLOW)Cleaning...$(RESET)\n"
	@rm -rf .zig-cache zig-out
	@printf "$(GREEN)Clean$(RESET)\n"

## Help:

help: ## Show this help message
	@printf "$(BOLD)metalbrew Makefile$(RESET)\n\n"
	@printf "$(YELLOW)Usage:$(RESET)\n  make $(CYAN)<target>$(RESET)\n"
	@awk 'BEGIN {FS = ":.*##"} \
		/^## / { printf "\n$(BOLD)%s$(RESET)\n", substr($$0, 4); next } \
		/^[a-zA-Z0-9_-]+:.*##/ { printf "  $(CYAN)%-14s$(RESET) %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\n"
