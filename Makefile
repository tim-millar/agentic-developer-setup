.DEFAULT_GOAL := check

.PHONY: validate
validate:
	ruby scripts/validate_framework.rb

.PHONY: test
test:
	ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].sort.each { |file| require File.expand_path(file) }'

.PHONY: test-launcher
test-launcher:
	ruby -Itest test/launcher_test.rb

.PHONY: test-claude-runtime
test-claude-runtime:
	ruby -Itest test/claude_explore_runtime_test.rb

.PHONY: test-assessment
test-assessment:
	ruby -Ilib -Itest -e 'files = ["test/assessment_test.rb", *Dir["test/assessment/**/*_test.rb"]].sort; files.each { |file| require File.expand_path(file) }'

.PHONY: check
check:
	$(MAKE) test
	$(MAKE) validate

.PHONY: assess
assess:
	@test -n "$(REPO)" || { echo "REPO is required" >&2; exit 2; }
	ruby scripts/assess_repository.rb "$(REPO)"

.PHONY: check-reference-service
check-reference-service:
	$(MAKE) -C examples/reference-service setup
	UV_OFFLINE=1 $(MAKE) -C examples/reference-service verify
