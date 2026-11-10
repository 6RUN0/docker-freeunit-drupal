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

SHELL_SCRIPTS := $(shell find rootfs test -type f -name '*.sh' 2>/dev/null)

# Scripts that run inside the image, under its /bin/sh (dash): they must parse
# as POSIX sh. The tests under test/ are bash and run on the host.
POSIX_SCRIPTS := $(shell find rootfs -type f -name '*.sh' 2>/dev/null)

DEFAULT_IMAGE := $(IMAGE):local-php$(DEFAULT_PHP)

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
lint: lint-dockerfile lint-shell lint-posix lint-md lint-typos ## Run every installed linter

lint-dockerfile:
	@if command -v hadolint >/dev/null 2>&1; then \
	  echo "hadolint Dockerfile"; hadolint Dockerfile; \
	else echo "hadolint not installed, skipping Dockerfile lint"; fi

lint-shell:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  echo "shellcheck $(SHELL_SCRIPTS)"; shellcheck $(SHELL_SCRIPTS); \
	else echo "shellcheck not installed, skipping shell lint"; fi

lint-posix:
	@if command -v dash >/dev/null 2>&1; then \
	  echo "dash -n $(POSIX_SCRIPTS)"; \
	  for f in $(POSIX_SCRIPTS); do dash -n "$$f" || exit 1; done; \
	else echo "dash not installed, skipping dash syntax check"; fi
	@if command -v busybox >/dev/null 2>&1; then \
	  echo "busybox sh -n $(POSIX_SCRIPTS)"; \
	  for f in $(POSIX_SCRIPTS); do busybox sh -n "$$f" || exit 1; done; \
	else echo "busybox not installed, skipping busybox sh syntax check"; fi

lint-md:
	@if command -v rumdl >/dev/null 2>&1; then \
	  echo "rumdl check ."; rumdl check .; \
	else echo "rumdl not installed, skipping markdown lint"; fi

lint-typos:
	@if command -v typos >/dev/null 2>&1; then \
	  echo "typos"; typos; \
	else echo "typos not installed, skipping spell check"; fi
