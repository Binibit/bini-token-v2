SHELL := /usr/bin/env bash

.PHONY: build test test-local test-cli test-anvil test-fork coverage audit artifacts release-check deploy-preflight

build:
	forge build --sizes

test: test-local test-cli test-fork

test-local:
	forge test --no-match-path 'test/fork/*' -vv

test-cli:
	python3 -m unittest discover -s test_cli -p 'test_*.py' -v

test-anvil:
	tools/test-release-anvil.sh

test-fork:
	tools/test-mainnet-fork.sh

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
