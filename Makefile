SHELL := /usr/bin/env bash

.PHONY: build test test-local test-fork coverage audit artifacts release-check deploy-preflight

build:
	forge build --sizes

test: test-local test-fork

test-local:
	forge test --no-match-path 'test/fork/*' -vv

test-fork:
	forge test --match-path 'test/fork/*' -vv

coverage:
	tools/coverage-gate.sh

audit:
	npm run validate:upgrades
	slither . --filter-paths 'lib|test|script' --exclude-dependencies --exclude assembly,low-level-calls,unindexed-event-address

artifacts:
	tools/release-artifacts.sh write

release-check:
	tools/release-gate.sh

deploy-preflight:
	tools/deploy-preflight.sh
