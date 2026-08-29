.DEFAULT_GOAL := check

.PHONY: validate
validate:
	ruby scripts/validate_framework.rb

.PHONY: test
test:
	ruby -Itest -e 'Dir["test/**/*_test.rb"].sort.each { |file| require File.expand_path(file) }'

.PHONY: test-launcher
test-launcher:
	ruby -Itest test/launcher_test.rb

.PHONY: test-claude-runtime
test-claude-runtime:
	ruby -Itest test/claude_explore_runtime_test.rb

.PHONY: check
check:
	$(MAKE) test
	$(MAKE) validate

.PHONY: check-reference-service
check-reference-service:
	$(MAKE) -C examples/reference-service setup
	UV_OFFLINE=1 $(MAKE) -C examples/reference-service verify
