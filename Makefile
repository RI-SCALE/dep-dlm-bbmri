SHELL       := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

SERVICES    ?=

COMPOSE_FILE := docker-compose.yml
COMPOSE      := docker compose -f $(COMPOSE_FILE)

OIDC_ISSUER           ?= https://login.aai.lifescience-ri.eu/oidc/
OIDC_TOKEN_URL        ?=
OIDC_CLIENT_ID        ?=
OIDC_CLIENT_SECRET    ?=
OIDC_GRANT_TYPE       ?= client_credentials
OIDC_EXPECTED_SCOPE   ?= openid profile eduperson_entitlement offline_access
OIDC_TEAPOT_AUD_SCOPE ?=

TEST_OIDC_ENV := OIDC_ISSUER='$(OIDC_ISSUER)' OIDC_TOKEN_URL='$(OIDC_TOKEN_URL)' \
  OIDC_CLIENT_ID='$(OIDC_CLIENT_ID)' OIDC_CLIENT_SECRET='$(OIDC_CLIENT_SECRET)' \
  OIDC_GRANT_TYPE='$(OIDC_GRANT_TYPE)' OIDC_EXPECTED_SCOPE='$(OIDC_EXPECTED_SCOPE)' \
  OIDC_TEAPOT_AUD_SCOPE='$(OIDC_TEAPOT_AUD_SCOPE)'

EXEC_RUCIO := docker exec compose-rucio-client-1

define require_oidc
	@[ -n "$(OIDC_CLIENT_ID)" ] && [ -n "$(OIDC_CLIENT_SECRET)" ] || \
	  { echo "ERROR: OIDC_CLIENT_ID and OIDC_CLIENT_SECRET must be set."; \
	    echo "  make $@ OIDC_CLIENT_ID=... OIDC_CLIENT_SECRET=..."; \
	    exit 1; }
endef

.PHONY: help
help: ## Show this help
	@echo ''
	@echo 'dep-dlm-bbmri'
	@echo ''
	@echo 'Usage:'
	@echo '  make <target> [SERVICES="svc1 svc2"]'
	@echo ''
	@awk 'BEGIN {FS = ":.*?## "} \
	    /^[a-zA-Z0-9_%-]+:.*?## / { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
	    /^## / { sub(/^## /, ""); printf "\n\033[1m%s\033[0m\n", $$0 }' $(MAKEFILE_LIST)

## Setup

.PHONY: certs
certs: ## Generate CA and host certificates
	./scripts/generate-certs.sh

.PHONY: init
init: ## Init testbed accounts, RSEs, OIDC seed
	$(call require_oidc)
	$(TEST_OIDC_ENV) ./scripts/init-testbed.sh

## IdP token verification

.PHONY: verify-idp-token
verify-idp-token: ## Verify OIDC token flow against LS AAI. Needs OIDC_CLIENT_SECRET.
	$(call require_oidc)
	./scripts/verify-idp-token.sh \
	  --issuer $(OIDC_ISSUER) \
	  --client-id $(OIDC_CLIENT_ID) \
	  --scope "$(OIDC_EXPECTED_SCOPE)"

## Lifecycle

.PHONY: start
start: ## Start the stack
	$(COMPOSE) up -d $(SERVICES)

.PHONY: stop
stop: ## Stop the stack, remove volumes
	$(COMPOSE) down -v

.PHONY: restart
restart: stop start ## Tear down and start again

.PHONY: ps
ps: ## Show running services
	$(COMPOSE) ps

.PHONY: logs
logs: ## Tail logs (SERVICES="..." for a subset)
	$(COMPOSE) logs --tail=100 $(SERVICES)

## Tests / Demo

.PHONY: test-rucio-transfers
test-rucio-transfers: ## Rucio E2E transfer test
	$(EXEC_RUCIO) bash -c "$(TEST_OIDC_ENV) pytest /tests/test_rucio_transfers.py -v"

.PHONY: test-rucio-deletion
test-rucio-deletion: ## Rucio E2E deletion test
	$(EXEC_RUCIO) bash -c "$(TEST_OIDC_ENV) pytest /tests/test_rucio_deletion.py -v"

.PHONY: probe-teapot
probe-teapot: ## Teapot WebDAV probe with OIDC tokens
	$(EXEC_RUCIO) bash -c "$(TEST_OIDC_ENV) pytest /tests/probe_teapot.py -v"

.PHONY: probe-xrootd
probe-xrootd: ## XRootD probe with SciTokens
	$(EXEC_RUCIO) bash -c "$(TEST_OIDC_ENV) pytest /tests/probe_xrootd.py -v"

## Cleanup

.PHONY: clear-artifacts
clear-artifacts: ## Remove certs, volumes, Python artifacts
	$(COMPOSE) down -v --remove-orphans 2>/dev/null || true
	find certs \
	    ! -name 'rucio_ca.pem' \
	    ! -name 'rucio_ca.key.pem' \
	    ! -name 'tls_ca_bundle.pem' \
	    \( -name '*.pem' -o -name '*.key' -o -name '*.namespaces' -o -name '*.signing_policy' \
	     -o -name '*.csr' -o -name '*.srl' -o -name '*.r0' -o -name '*.0' \) \
	    -delete 2>/dev/null || true
	@find . -type d \( -name '__pycache__' -o -name '.pytest_cache' \) -exec rm -rf {} + 2>/dev/null || true
	@echo "Cleaned certs (preserved rucio_ca.pem, rucio_ca.key.pem, tls_ca_bundle.pem), compose volumes, __pycache__/.pytest_cache"

.PHONY: cleanup
cleanup: ## Delete rules/replicas/distances (and RSEs unless KEEP_RSES=1) created by init/tests
	$(TEST_OIDC_ENV) ./scripts/cleanup-testbed.sh
