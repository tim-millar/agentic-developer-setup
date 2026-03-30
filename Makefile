.DEFAULT_GOAL := help

SHELL := /bin/sh

# --------------------------------------------------------------------
# Repository command bindings
#
# Fill these in per repository. The standard targets below provide a
# common command surface for developers, agents, hooks, and CI.
# --------------------------------------------------------------------

SETUP_CMD ?=
UP_CMD ?=
DEV_CMD ?=
BUILD_CMD ?=
LOGS_CMD ?=
BASH_CMD ?=
CONSOLE_CMD ?=
MIGRATE_CMD ?=
TEST_CMD ?=
LINT_CMD ?=
FORMAT_CMD ?=
TYPECHECK_CMD ?=
E2E_CMD ?=
SECURITY_CMD ?=
COVERAGE_CMD ?=
CLEAN_CMD ?=
HOOK_PRE_COMMIT_CMD ?=
HOOK_PRE_PUSH_CMD ?=

# --------------------------------------------------------------------
# CI-specific command bindings
#
# These are optional overlays for cases where CI should use a different
# command than local development. If not set, CI targets fall back to
# the corresponding local command.
# --------------------------------------------------------------------

CI_LINT_CMD ?=
CI_TEST_CMD ?=
CI_TYPECHECK_CMD ?=
CI_BUILD_CMD ?=
CI_E2E_CMD ?=
CI_SECURITY_CMD ?=
CI_COVERAGE_CMD ?=

# --------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------

define run_or_fail
	@if [ -n "$($(1))" ]; then \
		echo "==> $(2)"; \
		$(value $(1)); \
	else \
		echo "Error: target '$@' is not configured in this repository."; \
		echo "Set $(1) in the Makefile for this repo."; \
		exit 1; \
	fi
endef

define run_if_configured
	@if [ -n "$($(1))" ]; then \
		echo "==> $(2)"; \
		$(value $(1)); \
	else \
		echo "Skipping '$@': $(1) is not configured."; \
	fi
endef

define run_overlay_or_base
	@if [ -n "$($(1))" ]; then \
		echo "==> $(3)"; \
		$(value $(1)); \
	elif [ -n "$($(2))" ]; then \
		echo "==> $(3)"; \
		$(value $(2)); \
	else \
		echo "Error: target '$@' is not configured in this repository."; \
		echo "Set either $(1) or $(2) in the Makefile for this repo."; \
		exit 1; \
	fi
endef

define run_overlay_if_configured
	@if [ -n "$($(1))" ]; then \
		echo "==> $(3)"; \
		$(value $(1)); \
	elif [ -n "$($(2))" ]; then \
		echo "==> $(3)"; \
		$(value $(2)); \
	else \
		echo "Skipping '$@': neither $(1) nor $(2) is configured."; \
	fi
endef

.PHONY: help
help:
	@echo ""
	@echo "Standard repository commands"
	@echo ""
	@echo "Core workflow:"
	@echo "  make setup        Prepare the local development environment"
	@echo "  make test         Run tests"
	@echo "  make lint         Run linting"
	@echo "  make verify       Run the standard local verification suite"
	@echo ""
	@echo "Recommended quality gates:"
	@echo "  make format       Run code formatting"
	@echo "  make typecheck    Run static type checks"
	@echo "  make clean        Remove generated local artifacts or stop local services"
	@echo ""
	@echo "Optional operational targets:"
	@echo "  make up           Start local services or app runtime"
	@echo "  make dev          Start the main local development workflow"
	@echo "  make build        Build the application or package"
	@echo "  make logs         Stream all relevant logs"
	@echo "  make bash         Open a shell in the main app/container environment"
	@echo "  make console      Open the application or framework console"
	@echo "  make migrate      Run database or persistence migrations"
	@echo ""
	@echo "Optional extended checks:"
	@echo "  make e2e          Run end-to-end or integration tests"
	@echo "  make security     Run security or dependency checks"
	@echo "  make coverage     Run tests with coverage reporting"
	@echo ""
	@echo "CI-oriented targets:"
	@echo "  make ci-lint      Run lint checks in CI mode"
	@echo "  make ci-test      Run tests in CI mode"
	@echo "  make ci-typecheck Run type checks in CI mode"
	@echo "  make ci-build     Run build checks in CI mode"
	@echo "  make ci-e2e       Run end-to-end tests in CI mode"
	@echo "  make ci-security  Run security checks in CI mode"
	@echo "  make ci-coverage  Run coverage checks in CI mode"
	@echo ""
	@echo "CI targets use CI_*_CMD if configured, otherwise they fall back"
	@echo "to the corresponding local command."

.PHONY: setup
setup:
	$(call run_or_fail,SETUP_CMD,Running setup)

.PHONY: up
up:
	$(call run_if_configured,UP_CMD,Starting local services)

.PHONY: dev
dev:
	$(call run_if_configured,DEV_CMD,Starting development workflow)

.PHONY: build
build:
	$(call run_if_configured,BUILD_CMD,Running build)

.PHONY: logs
logs:
	$(call run_if_configured,LOGS_CMD,Streaming logs)

.PHONY: bash
bash:
	$(call run_if_configured,BASH_CMD,Opening shell)

.PHONY: console
console:
	$(call run_if_configured,CONSOLE_CMD,Opening application console)

.PHONY: migrate
migrate:
	$(call run_if_configured,MIGRATE_CMD,Running migrations)

.PHONY: test
test:
	$(call run_or_fail,TEST_CMD,Running tests)

.PHONY: lint
lint:
	$(call run_or_fail,LINT_CMD,Running lint checks)

.PHONY: format
format:
	$(call run_if_configured,FORMAT_CMD,Running code formatter)

.PHONY: typecheck
typecheck:
	$(call run_if_configured,TYPECHECK_CMD,Running type checks)

.PHONY: e2e
e2e:
	$(call run_if_configured,E2E_CMD,Running end-to-end tests)

.PHONY: security
security:
	$(call run_if_configured,SECURITY_CMD,Running security checks)

.PHONY: coverage
coverage:
	$(call run_if_configured,COVERAGE_CMD,Running coverage checks)

.PHONY: verify
verify:
	@echo "==> Running standard local verification suite"
	@$(MAKE) lint
	@$(MAKE) test
	@if [ -n "$(TYPECHECK_CMD)" ]; then $(MAKE) typecheck; fi

.PHONY: ci-lint
ci-lint:
	$(call run_overlay_or_base,CI_LINT_CMD,LINT_CMD,Running CI lint checks)

.PHONY: ci-test
ci-test:
	$(call run_overlay_or_base,CI_TEST_CMD,TEST_CMD,Running CI test suite)

.PHONY: ci-typecheck
ci-typecheck:
	$(call run_overlay_if_configured,CI_TYPECHECK_CMD,TYPECHECK_CMD,Running CI type checks)

.PHONY: ci-build
ci-build:
	$(call run_overlay_if_configured,CI_BUILD_CMD,BUILD_CMD,Running CI build checks)

.PHONY: ci-e2e
ci-e2e:
	$(call run_overlay_if_configured,CI_E2E_CMD,E2E_CMD,Running CI end-to-end tests)

.PHONY: ci-security
ci-security:
	$(call run_overlay_if_configured,CI_SECURITY_CMD,SECURITY_CMD,Running CI security checks)

.PHONY: ci-coverage
ci-coverage:
	$(call run_overlay_if_configured,CI_COVERAGE_CMD,COVERAGE_CMD,Running CI coverage checks)

.PHONY: hook-pre-commit
hook-pre-commit:
	@echo "==> Running pre-commit checks"
	@if [ -n "$(HOOK_PRE_COMMIT_CMD)" ]; then \
		$(HOOK_PRE_COMMIT_CMD); \
	else \
		$(MAKE) lint; \
	fi

.PHONY: hook-pre-push
hook-pre-push:
	@echo "==> Running pre-push checks"
	@if [ -n "$(HOOK_PRE_PUSH_CMD)" ]; then \
		$(HOOK_PRE_PUSH_CMD); \
	else \
		$(MAKE) test; \
	fi
