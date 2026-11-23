SHELL := /bin/bash
COMPOSE ?= docker compose
COMPOSE_FILES := -f docker-compose.yml
TIGERVNC_FILES := -f docker-compose.yml -f compose/docker-compose.tigervnc.yml
GPU_FILES := -f docker-compose.yml -f compose/docker-compose.gpu.yml
ENV_FILE := .env

.DEFAULT_GOAL := help

.PHONY: help setup build up down restart logs ps shell health backup restore \
        update up-tigervnc up-gpu config smoke clean

help: ## Show available commands
	@awk 'BEGIN {FS = ":.*## "; printf "\nMunnaVPS commands:\n\n"} \
	     /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2} \
	     END {printf "\n"}' $(MAKEFILE_LIST)

$(ENV_FILE):
	@printf 'Missing .env. Run: make setup\n' >&2
	@exit 1

setup: ## Create .env, generate a password, prepare data dirs (ARGS="--domain x")
	./scripts/setup.sh $(ARGS)

build: $(ENV_FILE) ## Build the desktop image
	$(COMPOSE) $(COMPOSE_FILES) build

up: $(ENV_FILE) ## Build and start the stack
	$(COMPOSE) $(COMPOSE_FILES) up -d --build

down: ## Stop and remove containers (data is kept)
	$(COMPOSE) $(COMPOSE_FILES) down --remove-orphans

restart: $(ENV_FILE) ## Restart all services
	$(COMPOSE) $(COMPOSE_FILES) restart

logs: ## Follow logs from all services
	$(COMPOSE) $(COMPOSE_FILES) logs -f --tail=200

ps: ## Show container status
	$(COMPOSE) $(COMPOSE_FILES) ps

shell: ## Open a shell in the desktop container
	$(COMPOSE) $(COMPOSE_FILES) exec desktop bash

health: ## Check container health and the public endpoint
	./scripts/healthcheck.sh

backup: ## Archive the desktop home directory into backups/
	./scripts/backup.sh

restore: ## Restore an archive: make restore FILE=backups/xxx.tar.gz
	@if [ -z "$(FILE)" ]; then printf 'Usage: make restore FILE=backups/xxx.tar.gz\n' >&2; exit 1; fi
	./scripts/restore.sh "$(FILE)"

update: ## Rebuild with newer upstream images and recreate
	./scripts/update.sh

up-tigervnc: $(ENV_FILE) ## Run the TigerVNC + noVNC fallback backend
	$(COMPOSE) $(TIGERVNC_FILES) up -d --build

up-gpu: $(ENV_FILE) ## Run with /dev/dri passthrough (Intel/AMD hosts)
	$(COMPOSE) $(GPU_FILES) up -d --build

config: $(ENV_FILE) ## Print the merged compose configuration
	$(COMPOSE) $(COMPOSE_FILES) config

smoke: ## Build, start, and verify the stack on localhost:18080
	./tests/smoke.sh

clean: ## Stop everything and remove project containers/networks
	$(COMPOSE) $(COMPOSE_FILES) down --remove-orphans
