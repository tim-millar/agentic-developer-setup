.DEFAULT_GOAL := verify

SHELL := /bin/sh

UV ?= uv
UV_RUN := $(UV) run --locked --offline

.PHONY: setup
setup:
	$(UV) sync --locked

.PHONY: test
test:
	$(UV_RUN) pytest

.PHONY: lint
lint:
	$(UV_RUN) ruff check src tests

.PHONY: format
format:
	$(UV_RUN) ruff format src tests

.PHONY: format-check
format-check:
	$(UV_RUN) ruff format --check src tests

.PHONY: typecheck
typecheck:
	$(UV_RUN) mypy src tests

.PHONY: verify
verify:
	$(MAKE) lint
	$(MAKE) format-check
	$(MAKE) typecheck
	$(MAKE) test
