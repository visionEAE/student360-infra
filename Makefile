# Student 360° — orchestration of the sibling repositories.
# All repos are expected side by side:  <folder>/student360-infra, <folder>/student360-common, ...
# Targets grow with each phase; see docs/implementation-plan.md.

SHELL := /bin/bash
ROOT := $(abspath ..)
ORG := visionEAE
SERVICES := auth-service gateway core-service lms-service support-service
JAVA_REPOS := common $(SERVICES)
ALL_REPOS := infra $(JAVA_REPOS) frontend
COMPOSE := docker compose --env-file .env -f infra/docker-compose.yml

# run-<service> is a pattern rule and must NOT be listed in .PHONY: make skips implicit
# rules for phony targets.
.PHONY: help hooks env keys up down reset logs psql check-isolation clone build-common build-all verify-all demo test

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

hooks: ## Activate lefthook (commit convention) and the commit template in every sibling repo
	@command -v lefthook >/dev/null || { echo "lefthook is required: npm install -g lefthook"; exit 1; }
	@for r in $(ALL_REPOS); do \
	  d=$(ROOT)/student360-$$r; test -d $$d/.git || continue; \
	  (cd $$d && lefthook install >/dev/null && git config commit.template .gitmessage); \
	  echo "hooks: student360-$$r"; done

env: ## Create .env from .env.example if missing
	@test -f .env || (cp .env.example .env && echo "Created .env — edit the placeholder values.")

keys: ## Generate the RSA key pair used by auth-service (git-ignored)
	@mkdir -p secrets
	@test -f secrets/jwt-private.pem || openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out secrets/jwt-private.pem 2>/dev/null
	@openssl pkey -in secrets/jwt-private.pem -pubout -out secrets/jwt-public.pem
	@echo "Keys in secrets/ (never committed)."

up: env ## Start PostgreSQL and Adminer
	$(COMPOSE) up -d --wait
	@echo "PostgreSQL on localhost:$${POSTGRES_PORT:-5432} · Adminer on http://localhost:$${ADMINER_PORT:-8090}"

down: ## Stop the local infrastructure (keeps the data volume)
	$(COMPOSE) down

reset: ## Stop and DROP the data volume (re-runs init-db on next `make up`)
	$(COMPOSE) down -v

logs: ## Tail infrastructure logs
	$(COMPOSE) logs -f

psql: env ## Open a psql shell as the superuser
	$(COMPOSE) exec postgres psql -U postgres -d student360

check-isolation: env ## Prove schema isolation and the append-only audit table (phase gate 0.A)
	@scripts/check-isolation.sh

clone: ## Clone every sibling repository that is missing
	@for r in $(ALL_REPOS); do \
	  test -d $(ROOT)/student360-$$r || gh repo clone $(ORG)/student360-$$r $(ROOT)/student360-$$r; done

build-common: ## Install student360-common into ~/.m2 so services can resolve it
	mvn -q -f $(ROOT)/student360-common/pom.xml -DskipTests install

build-all: build-common ## Build every Java repository without tests
	@for r in $(SERVICES); do \
	  test -f $(ROOT)/student360-$$r/pom.xml && mvn -q -f $(ROOT)/student360-$$r/pom.xml -DskipTests package || true; done

verify-all: ## Run `mvn verify` in every Java repository that has a build
	@for r in $(JAVA_REPOS); do \
	  test -f $(ROOT)/student360-$$r/pom.xml && (echo "== student360-$$r ==" && mvn -q -f $(ROOT)/student360-$$r/pom.xml verify) || true; done

# `make run-auth-service` etc. Loads .env so each service gets its credentials without any
# per-repo copies of secrets.
run-%: env
	@set -a && source .env && set +a && \
	  export JWT_PRIVATE_KEY_PATH=$(abspath secrets/jwt-private.pem) && \
	  mvn -q -f $(ROOT)/student360-$*/pom.xml spring-boot:run -Dspring-boot.run.profiles=dev
