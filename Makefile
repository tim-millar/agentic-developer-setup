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
	bundle exec ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].sort.each { |file| require File.expand_path(file) }'

.PHONY: test-launcher
test-launcher:
	bundle exec ruby -Itest test/launcher_test.rb

.PHONY: test-claude-runtime
test-claude-runtime:
	bundle exec ruby -Itest test/claude_explore_runtime_test.rb

.PHONY: test-assessment
test-assessment:
	bundle exec ruby -Ilib -Itest -e 'files = ["test/assessment_test.rb", *Dir["test/assessment/**/*_test.rb"]].sort; files.each { |file| require File.expand_path(file) }'

.PHONY: check
check:
	$(MAKE) lint
	$(MAKE) test
	$(MAKE) validate

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

.PHONY: check-reference-service
check-reference-service:
	$(MAKE) -C examples/reference-service setup
	UV_OFFLINE=1 $(MAKE) -C examples/reference-service verify
