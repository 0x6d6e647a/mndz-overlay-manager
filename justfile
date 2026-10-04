# Contributor and agent entry point. `just` with no recipe lists these recipes.
#
# Requires just 1.55 or newer. Flavors and Cabal flags live in scripts/with-flavor.
# Short build, test, and run recipes use the dev flavor. Release recipes are explicit.

# List recipes. Does not launch the manager.
default:
    @just --list

# Run the manager from the dev flavor. Arguments are the manager's own argv.
[positional-arguments]
run *args:
    #!/usr/bin/env bash
    set -euo pipefail
    exec ./scripts/with-flavor dev -- run mndz-overlay-manager -- {{ replace_regex(args, "^--( |$)", "") }}

# Build every component in the dev flavor.
build:
    ./scripts/with-flavor dev -- build all

# Uninstrumented tests in the dev flavor. Optional tasty pattern.
[positional-arguments]
test *pattern:
    #!/usr/bin/env bash
    set -euo pipefail
    pattern="{{ pattern }}"
    if [[ -z "${pattern}" ]]; then
        exec ./scripts/with-flavor dev -- test all
    else
        exec ./scripts/with-flavor dev -- test all --test-options="-p ${pattern}"
    fi

# Run the manager from the release flavor. Arguments are the manager's own argv.
[positional-arguments]
run-release *args:
    #!/usr/bin/env bash
    set -euo pipefail
    exec ./scripts/with-flavor release -- run mndz-overlay-manager -- {{ replace_regex(args, "^--( |$)", "") }}

# Build every component in the release flavor and collect its HIE.
build-release:
    ./scripts/with-flavor release -- build all

# Uninstrumented tests in the release flavor. Optional tasty pattern.
[positional-arguments]
test-release *pattern:
    #!/usr/bin/env bash
    set -euo pipefail
    pattern="{{ pattern }}"
    if [[ -z "${pattern}" ]]; then
        exec ./scripts/with-flavor release -- test all
    else
        exec ./scripts/with-flavor release -- test all --test-options="-p ${pattern}"
    fi

# Debug coverage flavor. No pattern writes the gate reports; a pattern reruns one test.
[positional-arguments]
coverage *pattern:
    #!/usr/bin/env bash
    set -euo pipefail
    pattern="{{ pattern }}"
    if [[ -z "${pattern}" ]]; then
        exec ./scripts/coverage
    else
        exec ./scripts/with-flavor coverage-dev -- test all --test-show-details=direct --test-options="-p ${pattern}"
    fi

# Optimized coverage reports. Not part of the quality gate.
coverage-release:
    COVERAGE_FLAVOR=coverage-release ./scripts/coverage

# Full quality gate. Does not install missing tools.
check:
    hk check

# Format Haskell sources with ormolu. Does not stage files.
format:
    hk fix -S tools-preflight -S ormolu

# Hlint only.
hlint:
    hk check -S hlint --all

# Stan on release-flavor library HIE. Builds that flavor first.
stan: build-release
    hk check -S stan --all

# Weeder on release-flavor HIE. Builds that flavor first.
weeder: build-release
    hk check -S weeder --all

# Install project-local quality tools, then git hooks. Does not build the manager.
init: init-tools init-hooks

init-tools:
    ./scripts/install-dev-tools

init-hooks:
    hk install
