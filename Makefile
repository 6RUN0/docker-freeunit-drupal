# Build the freeunit-drupal image matrix from a single Dockerfile.
#
#   make              # build all PHP versions
#   make php8.3       # build one variant
#   make latest       # build the default PHP and tag it :latest
#   make test         # build the default PHP and run the integration smoke test
#   make lint         # run all installed linters
#   make scan         # CVE-scan the default image (trivy/grype if installed)
#
# Override any variable on the command line, e.g. pin the freeunit-php substrate
# to a released build instead of the floating suite tag:
#   make BASE_TAG=trixie-1.35.5-build4 php8.4

IMAGE        ?= freeunit-drupal
PHP_VERSIONS ?= 8.3 8.4 8.5

# Single source of truth: the defaults live in the Dockerfile ARGs and are read
# from there, so a bump is one edit (in the Dockerfile). The $(or ...,$(error ...))
# makes a failed extraction loud: if an ARG line format drifts (quotes, inline
# comment, spaces around =) the build aborts instead of using an empty value.
BASE_IMAGE  ?= $(or $(shell sed -n 's/^ARG BASE_IMAGE=//p' Dockerfile),$(error could not read ARG BASE_IMAGE from Dockerfile))
BASE_TAG    ?= $(or $(shell sed -n 's/^ARG BASE_TAG=//p' Dockerfile),$(error could not read ARG BASE_TAG from Dockerfile))
DEFAULT_PHP ?= $(or $(shell sed -n 's/^ARG PHP_VER=//p' Dockerfile),$(error could not read ARG PHP_VER from Dockerfile))

# Extra flags forwarded to every `docker build` (empty by default). CI sets this
# to wire buildx layer caching, e.g. DOCKER_BUILD_EXTRA="--cache-from type=gha ..."
DOCKER_BUILD_EXTRA ?=

TARGETS := $(addprefix php,$(PHP_VERSIONS))

SHELL_SCRIPTS := $(shell find rootfs test -type f -name '*.sh' 2>/dev/null)

DEFAULT_IMAGE := $(IMAGE):$(BASE_TAG)-php$(DEFAULT_PHP)

.PHONY: all latest test scan lint lint-dockerfile lint-shell lint-md lint-typos $(TARGETS)

all: $(TARGETS)

# The image tag mirrors the substrate it is built on: $(BASE_TAG)-php$*. With the
# default BASE_TAG=trixie this floats to the newest freeunit-php; override BASE_TAG
# with a pinned base build to get a correspondingly immutable tag.
$(TARGETS): php%:
	docker build $(DOCKER_BUILD_EXTRA) \
	  --build-arg BASE_IMAGE=$(BASE_IMAGE) \
	  --build-arg BASE_TAG=$(BASE_TAG) \
	  --build-arg PHP_VER=$* \
	  -t $(IMAGE):$(BASE_TAG)-php$* \
	  .

latest: php$(DEFAULT_PHP)
	docker tag $(DEFAULT_IMAGE) $(IMAGE):latest

# Build the default variant and run the end-to-end smoke test against it.
test: php$(DEFAULT_PHP)
	./test/smoke.sh $(DEFAULT_IMAGE)

# CVE-scan the default image. Skipped (not failed) if no scanner is installed.
scan:
	@if command -v trivy >/dev/null 2>&1; then \
	  echo "trivy image $(DEFAULT_IMAGE)"; \
	  trivy image --severity HIGH,CRITICAL --exit-code 1 $(DEFAULT_IMAGE); \
	elif command -v grype >/dev/null 2>&1; then \
	  echo "grype $(DEFAULT_IMAGE)"; \
	  grype --fail-on high $(DEFAULT_IMAGE); \
	else echo "neither trivy nor grype installed, skipping CVE scan"; fi

# Run every linter that is installed (a missing tool is skipped, not an error;
# an installed tool that reports problems fails the target).
lint: lint-dockerfile lint-shell lint-md lint-typos

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
	  echo "rumdl check *.md"; rumdl check ./*.md ./examples/*.md ./examples/*/*.md; \
	else echo "rumdl not installed, skipping markdown lint"; fi

lint-typos:
	@if command -v typos >/dev/null 2>&1; then \
	  echo "typos"; typos; \
	else echo "typos not installed, skipping spell check"; fi
