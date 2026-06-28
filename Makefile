# Build the freeunit-drupal image matrix from a single Dockerfile.
#
#   make              # build all PHP versions
#   make php8.3       # build one variant
#   make latest       # build the default PHP and tag it :latest
#   make test         # build the default PHP and run the integration smoke test
#   make lint         # run all installed linters
#   make scan         # CVE-scan the default image (trivy/grype if installed)
#
# Override any variable on the command line, e.g. track the floating freeunit-php
# suite tag instead of the pinned released build the Dockerfile defaults to:
#   make BASE_TAG=trixie php8.4

IMAGE        ?= freeunit-drupal
PHP_VERSIONS ?= 8.3 8.4 8.5

# Single source of truth: the defaults live in the Dockerfile ARGs and are read
# from there, so a bump is one edit (in the Dockerfile). The captured value stops
# at the first whitespace, so trailing spaces or a future inline comment on the
# ARG line can't leak into image tags; the $(or ...,$(error ...)) makes a failed
# extraction loud: if the line format drifts (quotes, spaces around =) the build
# aborts instead of using an empty value.
BASE_IMAGE  ?= $(or $(shell sed -n 's/^ARG BASE_IMAGE=\([^[:space:]]*\).*/\1/p' Dockerfile),$(error could not read ARG BASE_IMAGE from Dockerfile))
BASE_TAG    ?= $(or $(shell sed -n 's/^ARG BASE_TAG=\([^[:space:]]*\).*/\1/p' Dockerfile),$(error could not read ARG BASE_TAG from Dockerfile))
DEFAULT_PHP ?= $(or $(shell sed -n 's/^ARG PHP_VER=\([^[:space:]]*\).*/\1/p' Dockerfile),$(error could not read ARG PHP_VER from Dockerfile))

# Extra flags forwarded to every `docker build` (empty by default). CI sets this
# to wire buildx layer caching, e.g. DOCKER_BUILD_EXTRA="--cache-from type=gha ..."
DOCKER_BUILD_EXTRA ?=

TARGETS := $(addprefix php,$(PHP_VERSIONS))

SHELL_SCRIPTS := $(shell find rootfs test -type f -name '*.sh' 2>/dev/null)

DEFAULT_IMAGE := $(IMAGE):$(BASE_TAG)-php$(DEFAULT_PHP)

.PHONY: help all latest test scan lint lint-dockerfile lint-shell lint-md lint-typos \
  print-php-matrix print-default-php $(TARGETS)

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
	@echo "Track the floating substrate with: make BASE_TAG=trixie php8.4"

all: $(TARGETS) ## Build all PHP versions (default goal)

# Machine-readable views of the build matrix for the workflows' fromJSON()
# consumers, so PHP_VERSIONS above stays the single source of truth and the
# workflow matrices cannot drift from it (jq is preinstalled on the runners).
print-php-matrix: ## Print PHP_VERSIONS as a JSON array (consumed by CI)
	@printf '%s\n' $(PHP_VERSIONS) | jq -Rcn '[inputs]'

print-default-php: ## Print the default PHP version (consumed by CI)
	@echo $(DEFAULT_PHP)

# The image tag mirrors the substrate it is built on: $(BASE_TAG)-php$*. BASE_TAG
# defaults to a pinned freeunit-php build, so the tag is correspondingly stable;
# override BASE_TAG=trixie to build on (and tag against) the floating suite tag.
$(TARGETS): php%:
	docker build $(DOCKER_BUILD_EXTRA) \
	  --build-arg BASE_IMAGE=$(BASE_IMAGE) \
	  --build-arg BASE_TAG=$(BASE_TAG) \
	  --build-arg PHP_VER=$* \
	  -t $(IMAGE):$(BASE_TAG)-php$* \
	  .

latest: php$(DEFAULT_PHP) ## Build default PHP and tag it :latest
	docker tag $(DEFAULT_IMAGE) $(IMAGE):latest

# Build the default variant and run the end-to-end smoke test against it.
test: php$(DEFAULT_PHP) ## Build default PHP and run the smoke test
	./test/smoke.sh $(DEFAULT_IMAGE)

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
lint: lint-dockerfile lint-shell lint-md lint-typos ## Run every installed linter

lint-dockerfile:
	@if command -v hadolint >/dev/null 2>&1; then \
	  echo "hadolint Dockerfile"; hadolint Dockerfile; \
	else echo "hadolint not installed, skipping Dockerfile lint"; fi

lint-shell:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  echo "shellcheck $(SHELL_SCRIPTS)"; shellcheck $(SHELL_SCRIPTS); \
	else echo "shellcheck not installed, skipping shell lint"; fi

lint-md:
	@if command -v rumdl >/dev/null 2>&1; then \
	  echo "rumdl check ."; rumdl check .; \
	else echo "rumdl not installed, skipping markdown lint"; fi

lint-typos:
	@if command -v typos >/dev/null 2>&1; then \
	  echo "typos"; typos; \
	else echo "typos not installed, skipping spell check"; fi
