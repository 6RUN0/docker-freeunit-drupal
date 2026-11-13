# Build the freeunit-drupal image matrix from a single Dockerfile.
#
#   make              # build all PHP versions
#   make php8.3       # build one variant
#   make latest       # build the default PHP and tag it :latest
#   make test         # build the default PHP, run the smoke and the scripts tests
#   make test-example # build the default PHP, run the e2e test of examples/drupal
#   make lint         # run all installed linters
#   make scan         # CVE-scan the default image (trivy/grype if installed)
#
# Override any variable on the command line, e.g. track the floating freeunit-php
# suite tag instead of the pinned release and digest the Dockerfile defaults to:
#   make BASE_TAG=trixie BASE_DIGEST= php8.4

IMAGE        ?= freeunit-drupal
PHP_VERSIONS ?= 8.3 8.4 8.5

# Single source of truth: the defaults live in the Dockerfile ARGs and are read
# from there, so a bump is one edit (in the Dockerfile). The captured value stops
# at the first whitespace, so trailing spaces or a future inline comment on the
# ARG line can't leak into image tags; the $(or ...,$(error ...)) makes a failed
# extraction loud: if the line format drifts (quotes, spaces around =) the build
# aborts instead of using an empty value.
DOCKERFILE_BASE_IMAGE := $(or $(shell sed -n 's/^ARG BASE_IMAGE=\([^[:space:]]*\).*/\1/p' Dockerfile),$(error could not read ARG BASE_IMAGE from Dockerfile))
DOCKERFILE_BASE_TAG   := $(or $(shell sed -n 's/^ARG BASE_TAG=\([^[:space:]]*\).*/\1/p' Dockerfile),$(error could not read ARG BASE_TAG from Dockerfile))
BASE_IMAGE  ?= $(DOCKERFILE_BASE_IMAGE)
BASE_TAG    ?= $(DOCKERFILE_BASE_TAG)
DEFAULT_PHP ?= $(or $(shell sed -n 's/^ARG PHP_VER=\([^[:space:]]*\).*/\1/p' Dockerfile),$(error could not read ARG PHP_VER from Dockerfile))

# Base digest for one PHP line: the Dockerfile entry BASE_DIGEST_PHP<XY> (8.4 ->
# BASE_DIGEST_PHP84). An empty entry aborts the build instead of silently
# pulling the base by its mutable tag. BASE_DIGEST given on the command line
# (empty included) replaces the table for every PHP line. The table belongs to
# the Dockerfile's BASE_IMAGE:BASE_TAG: with either overridden and no
# BASE_DIGEST, BuildKit would resolve the table digest and ignore the tag, so
# the build would silently use the pinned base; that aborts too. Arg: <X.Y>
base_digest_entry = $(or $(shell sed -n 's/^ARG BASE_DIGEST_PHP$(subst .,,$(1))=\([^[:space:]]*\).*/\1/p' Dockerfile),$(error ARG BASE_DIGEST_PHP$(subst .,,$(1)) in Dockerfile is empty; set it to the digest of $(BASE_IMAGE):$(BASE_TAG)-php$(1), or pass BASE_DIGEST= to build from the tag only))
base_digest_table = $(if $(filter $(DOCKERFILE_BASE_IMAGE):$(DOCKERFILE_BASE_TAG),$(BASE_IMAGE):$(BASE_TAG)),$(call base_digest_entry,$(1)),$(error the digest table pins $(DOCKERFILE_BASE_IMAGE):$(DOCKERFILE_BASE_TAG), not $(BASE_IMAGE):$(BASE_TAG); pass BASE_DIGEST= to build from the tag only, or BASE_DIGEST=<digest of $(BASE_IMAGE):$(BASE_TAG)-php$(1)>))
base_digest = $(if $(filter undefined,$(origin BASE_DIGEST)),$(call base_digest_table,$(1)),$(BASE_DIGEST))

# Extra flags forwarded to every `docker build` (empty by default). CI sets this
# to wire buildx layer caching, e.g. DOCKER_BUILD_EXTRA="--cache-from type=gha ..."
DOCKER_BUILD_EXTRA ?=

TARGETS := $(addprefix php,$(PHP_VERSIONS))

# Shell scripts are found by their first line, not by a .sh suffix: the tools
# in rootfs/usr/local/bin have none. examples/drupal/tests joins when present.
SCRIPT_DIRS := $(wildcard rootfs test examples/drupal/tests)
shebang_files = $(shell find $(SCRIPT_DIRS) -type f -exec awk 'FNR == 1 && /$(1)/ { print FILENAME }' {} + 2>/dev/null | LC_ALL=C sort)

# POSIX sh: everything that runs in the image under its /bin/sh (dash), and the
# host-side tests other than the bash smoke test. They must parse under dash
# and busybox ash.
POSIX_SCRIPTS := $(call shebang_files,^#!\/bin\/sh)
SHELL_SCRIPTS := $(POSIX_SCRIPTS) $(call shebang_files,^#!\/usr\/bin\/env bash)

# LINT_REQUIRE=1 turns a missing linter into an error instead of a skip (CI).
LINT_REQUIRE ?=
lint_missing = if [ -n "$(LINT_REQUIRE)" ]; then echo "$(1) not installed (LINT_REQUIRE=1)" >&2; exit 1; else echo "$(1) not installed, skipping"; fi

DEFAULT_IMAGE := $(IMAGE):local-php$(DEFAULT_PHP)

.PHONY: help all latest test test-smoke test-scripts test-example scan lint lint-dockerfile \
  lint-shell lint-posix lint-md lint-typos lint-compose check-fragment print-php-matrix \
  print-default-php $(TARGETS)

# `help` is defined first below, so pin the default goal back to `all` to keep
# a bare `make` building the matrix (as documented in CLAUDE.md and the header).
.DEFAULT_GOAL := all

# Self-documenting: lists every target annotated with a `## ...` comment, so the
# help text is generated from the Makefile itself and never drifts out of sync.
help: ## Show this help
	@echo "Usage: make [target] [VAR=value ...]"
	@echo
	@echo "Targets:"
	@if [ -t 1 ]; then c=$$(printf '\033[36m'); r=$$(printf '\033[0m'); else c=; r=; fi; \
	  grep -E '^[a-zA-Z0-9_.%-]+:.*##' $(MAKEFILE_LIST) \
	  | sort \
	  | awk -v c="$$c" -v r="$$r" 'BEGIN{FS=":.*##"} {printf "  %s%-14s%s %s\n", c, $$1, r, $$2}'
	@echo
	@echo "Build one PHP variant with: make php<ver>  (e.g. make php8.4)"
	@echo "Track the floating substrate with: make BASE_TAG=trixie BASE_DIGEST= php8.4"

all: $(TARGETS) ## Build all PHP versions (default goal)

# Machine-readable views of the build matrix for the workflows' fromJSON()
# consumers, so PHP_VERSIONS above stays the single source of truth and the
# workflow matrices cannot drift from it (jq is preinstalled on the runners).
print-php-matrix: ## Print PHP_VERSIONS as a JSON array (consumed by CI)
	@printf '%s\n' $(PHP_VERSIONS) | jq -Rcn '[inputs]'

print-default-php: ## Print the default PHP version (consumed by CI)
	@echo $(DEFAULT_PHP)

# local-php<X.Y> is a local build tag, never published: release.yml derives the
# published tags (<version>-php<X.Y>, <version>, latest) from the git tag.
$(TARGETS): php%:
	docker build $(DOCKER_BUILD_EXTRA) \
	  --build-arg BASE_IMAGE=$(BASE_IMAGE) \
	  --build-arg BASE_TAG=$(BASE_TAG) \
	  --build-arg BASE_DIGEST=$(call base_digest,$*) \
	  --build-arg PHP_VER=$* \
	  -t $(IMAGE):local-php$* \
	  .

latest: php$(DEFAULT_PHP) ## Build default PHP and tag it :latest
	docker tag $(DEFAULT_IMAGE) $(IMAGE):latest

# Build the default variant and run the smoke test and the tests of the Drupal
# entrypoint scripts against it.
test: test-smoke test-scripts ## Build default PHP, run the smoke and scripts tests

test-smoke: php$(DEFAULT_PHP) ## Build default PHP and run the smoke test
	./test/smoke.sh $(DEFAULT_IMAGE)

test-scripts: php$(DEFAULT_PHP) ## Build default PHP and run the entrypoint scripts tests (TAP)
	./test/scripts.sh $(DEFAULT_IMAGE)

# The example builds FROM the published tag of the next release; the e2e test
# replaces it with the local image. E2E_ARGS=--search adds the OpenSearch
# profile; E2E_AUDIT=report turns a composer audit finding into a TODO.
E2E_ARGS ?=
test-example: php$(DEFAULT_PHP) ## Build default PHP and run the examples/drupal e2e test (TAP)
	./examples/drupal/tests/e2e.sh $(E2E_ARGS) $(DEFAULT_IMAGE)

# CVE-scan the default image. Skipped (not failed) if no scanner is installed.
scan: ## CVE-scan the default image (trivy/grype if installed)
	@if command -v trivy >/dev/null 2>&1; then \
	  echo "trivy image $(DEFAULT_IMAGE)"; \
	  trivy image --severity HIGH,CRITICAL --exit-code 1 $(DEFAULT_IMAGE); \
	elif command -v grype >/dev/null 2>&1; then \
	  echo "grype $(DEFAULT_IMAGE)"; \
	  grype --fail-on high $(DEFAULT_IMAGE); \
	else echo "neither trivy nor grype installed, skipping CVE scan"; fi

# Run every linter that is installed (a missing tool is skipped, not an error;
# an installed tool that reports problems fails the target).
lint: lint-dockerfile lint-shell lint-posix lint-md lint-typos lint-compose check-fragment ## Run every installed linter

DOCKERFILES := Dockerfile test/fixtures/scripts/Dockerfile examples/drupal/Dockerfile

lint-dockerfile:
	@if command -v hadolint >/dev/null 2>&1; then \
	  echo "hadolint $(DOCKERFILES)"; hadolint $(DOCKERFILES); \
	else $(call lint_missing,hadolint); fi

# The POSIX scripts are checked as sh whatever shellcheck infers. The e2e
# test generates secrets: a trace (set -x, sh -x in the shebang) would print
# them before CI masks them.
lint-shell:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  echo "shellcheck $(SHELL_SCRIPTS)"; shellcheck $(SHELL_SCRIPTS) \
	  && echo "shellcheck -s sh $(POSIX_SCRIPTS)" && shellcheck -s sh $(POSIX_SCRIPTS); \
	else $(call lint_missing,shellcheck); fi
	@echo "no command trace in examples/drupal/tests/e2e.sh"; \
	  ! grep -n -E '^#!.*[[:space:]]-[a-z]*x|set[[:space:]]+-[a-z]*x|set[[:space:]]+-o[[:space:]]+xtrace' \
	    examples/drupal/tests/e2e.sh

lint-posix:
	@if command -v dash >/dev/null 2>&1; then \
	  echo "dash -n $(POSIX_SCRIPTS)"; \
	  for f in $(POSIX_SCRIPTS); do dash -n "$$f" || exit 1; done; \
	else $(call lint_missing,dash); fi
	@if command -v busybox >/dev/null 2>&1; then \
	  echo "busybox sh -n $(POSIX_SCRIPTS)"; \
	  for f in $(POSIX_SCRIPTS); do busybox sh -n "$$f" || exit 1; done; \
	else $(call lint_missing,busybox); fi

lint-md:
	@if command -v rumdl >/dev/null 2>&1; then \
	  echo "rumdl check ."; rumdl check .; \
	else echo "rumdl not installed, skipping markdown lint"; fi

lint-typos:
	@if command -v typos >/dev/null 2>&1; then \
	  echo "typos"; typos; \
	else echo "typos not installed, skipping spell check"; fi

# The example compose file must parse with the env file it ships, with and
# without the search profile, and with the e2e override (!reset needs Docker
# Compose 2.24 or later).
EXAMPLE_COMPOSE := docker compose --project-directory examples/drupal \
  --env-file examples/drupal/.env.example -f examples/drupal/docker-compose.yml
lint-compose:
	@if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then \
	  for args in '' '--profile search' '-f examples/drupal/tests/e2e.override.yml' \
	    '-f examples/drupal/tests/e2e.override.yml --profile search'; do \
	    echo "$(EXAMPLE_COMPOSE) $$args config -q"; \
	    $(EXAMPLE_COMPOSE) $$args config -q || exit 1; \
	  done; \
	else $(call lint_missing,docker compose); fi

# The example keeps a copy of the fragment of the image; it must not drift.
check-fragment:
	cmp rootfs/usr/local/share/freeunit-drupal/docker-compose.hardening.yml \
	  examples/drupal/docker-compose.hardening.yml
