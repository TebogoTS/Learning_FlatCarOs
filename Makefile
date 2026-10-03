# Top-level Makefile for the Flatcar deep-dive repository.
#
#   make help        list targets
#   make validate    everything that can run without VMs: tests, lint, transpile, policy checks
#   make lab04-up    run a target of a lab (pattern: lab<NN>-<target>), see labs/<lab>/README.md
#
# Versions come from versions.env (see VERSIONS.md for provenance).

include versions.env
export

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

GO ?= go
export GOTOOLCHAIN ?= local
BIN := tools/bin
LABS := 01-first-boot-kvm 02-updates-and-rollback 03-sysext 04-kthw-on-flatcar 05-rke2-on-flatcar
SH_FILES := $(shell find labs tools -name '*.sh' -not -path '*/.state/*' 2>/dev/null | sort)

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_%-]+:.*## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Lab targets: make lab01-<target> ... lab05-<target> (labs: $(LABS))"

.PHONY: tools
tools: ## Build the Go helpers (butanecheck, nodegen) into tools/bin
	@mkdir -p $(BIN)
	$(GO) build -o $(BIN)/butanecheck ./tools/butanecheck
	$(GO) build -o $(BIN)/nodegen ./tools/nodegen

.PHONY: butane
butane: ## Download and verify the pinned Butane binary into tools/bin
	@tools/scripts/fetch-butane.sh

.PHONY: test
test: ## Run go vet and go test for the Go tools
	$(GO) vet ./...
	$(GO) test ./...

.PHONY: selftest
selftest: ## Offline self-test of the lab shell helpers
	@bash labs/lib/selftest.sh

.PHONY: lint-sh
lint-sh: ## shellcheck every shell script
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed; falling back to bash -n"; for f in $(SH_FILES); do bash -n "$$f"; done; exit 0; }
	shellcheck -x -P SCRIPTDIR $(SH_FILES)

.PHONY: render-ci
render-ci: tools ## Render every lab's Butane templates with fixture values into build/
	@rm -rf build && mkdir -p build
	@for l in $(LABS); do \
		if [ -f labs/$$l/Makefile ] && grep -q '^render-ci:' labs/$$l/Makefile; then \
			echo "== render-ci $$l"; $(MAKE) --no-print-directory -C labs/$$l render-ci || exit 1; \
		fi; \
	done

.PHONY: check
check: tools butane render-ci ## Transpile everything with the pinned Butane and run policy checks
	@tools/scripts/check-butane.sh

.PHONY: validate
validate: test selftest lint-sh check ## Run every check that needs no VM

.PHONY: check-mermaid
check-mermaid: ## Parse-check every Mermaid diagram (needs node, npm, a Chromium; see the script header)
	@tools/scripts/check-mermaid.sh

.PHONY: clean
clean: ## Remove build outputs (keeps lab VM state)
	rm -rf build $(BIN)

# lab<NN>-<target>  ->  make -C labs/<NN-name> <target>
define LAB_RULE
lab$(word 1,$(subst -, ,$(1)))-%:
	$$(MAKE) --no-print-directory -C labs/$(1) $$*
endef
$(foreach l,$(LABS),$(eval $(call LAB_RULE,$(l))))
