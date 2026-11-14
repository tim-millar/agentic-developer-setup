.DEFAULT_GOAL := check

.PHONY: setup
setup:
	bundle install
	bundle exec lefthook install

.PHONY: lint
lint:
	bundle exec standardrb lib scripts test

.PHONY: format
format:
	bundle exec standardrb --fix lib scripts test

.PHONY: validate
validate:
	bundle exec ruby scripts/validate_framework.rb

.PHONY: test
test:
	bundle exec ruby -Ilib -Itest -e 'require_relative "test/support/check_timing" if ENV["ADS_TEST_TIMING"] == "1"; Dir["test/**/*_test.rb"].sort.each { |file| require File.expand_path(file) }'

.PHONY: test-launcher
test-launcher:
	bundle exec ruby -Itest test/launcher_test.rb

.PHONY: test-claude-runtime
test-claude-runtime:
	bundle exec ruby -Itest -e 'Dir["test/claude_explore_*_test.rb"].sort.each { |file| require File.expand_path(file) }'

.PHONY: test-outcomes
test-outcomes:
	bundle exec ruby -Ilib -Itest test/agent_run_outcomes_test.rb

.PHONY: test-usage
test-usage:
	bundle exec ruby -Ilib -Itest test/run_usage_test.rb

.PHONY: test-assessment
test-assessment:
	bundle exec ruby -Ilib -Itest -e 'files = ["test/assessment_test.rb", *Dir["test/assessment/**/*_test.rb"]].sort; files.each { |file| require File.expand_path(file) }'

.PHONY: check
check:
	bundle exec ruby scripts/time_check.rb lint $(MAKE) lint
	bundle exec ruby scripts/time_check.rb test $(MAKE) test
	bundle exec ruby scripts/time_check.rb validate $(MAKE) validate

.PHONY: hook-pre-commit
hook-pre-commit:
	$(MAKE) lint

.PHONY: hook-pre-push
hook-pre-push:
	$(MAKE) check

.PHONY: assess
assess:
	@test -n "$(REPO)" || { echo "REPO is required" >&2; exit 2; }
	bundle exec ruby scripts/assess_repository.rb "$(REPO)"

.PHONY: adoption-inspect
adoption-inspect:
	@test -n "$(REPO)" || { echo "REPO is required" >&2; exit 2; }
	@if test -n "$(FRAMEWORK_SOURCE)"; then bundle exec ruby scripts/inspect_adoption.rb "$(REPO)" --framework-source "$(FRAMEWORK_SOURCE)"; else bundle exec ruby scripts/inspect_adoption.rb "$(REPO)"; fi

.PHONY: check-reference-service
check-reference-service:
	bundle exec ruby scripts/time_check.rb reference-setup $(MAKE) -C examples/reference-service setup
	UV_OFFLINE=1 bundle exec ruby scripts/time_check.rb reference-verify $(MAKE) -C examples/reference-service verify

.PHONY: test-adoption
test-adoption:
	bundle exec ruby -Ilib -Itest -e '["test/manage_adoption_test.rb", *Dir["test/adoption/**/*_test.rb"]].sort.each { |file| require File.expand_path(file) }'

.PHONY: demo-adoption
demo-adoption:
	bundle exec ruby scripts/examples/initial_adoption.rb
	bundle exec ruby scripts/examples/update_inherited.rb

.PHONY: assess-adapters
assess-adapters:
	@test -n "$(REPO)" || { echo "REPO is required" >&2; exit 2; }
	bundle exec ruby scripts/assess_adapters.rb "$(REPO)"

.PHONY: test-adapters
test-adapters:
	bundle exec ruby -Ilib -Itest -e 'Dir["test/adapters/**/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
