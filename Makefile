.DEFAULT_GOAL := check

.PHONY: validate
validate:
	ruby scripts/validate_framework.rb

.PHONY: test
test:
	ruby -Itest -e 'Dir["test/**/*_test.rb"].sort.each { |file| require File.expand_path(file) }'

.PHONY: check
check:
	$(MAKE) test
	$(MAKE) validate
