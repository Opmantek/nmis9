# Container lifecycle for the dev and production Docker Compose stacks.
# OMK-12826: prod-setup generates a strong MONGODB_PASSWORD into the prod
# .env; prod-up refuses to start until that has been done (see
# conf-default/docker/.env and admin/setup_mongodb.pl's deny set).

DEV_COMPOSE  = docker-dev/compose-dev.yaml
DEV_ENV      = docker-dev/.env-dev
PROD_COMPOSE = conf-default/docker/compose.yaml
PROD_ENV     = conf-default/docker/.env

.PHONY: dev-up dev-down dev-logs prod-setup prod-up prod-down prod-logs help

help:  ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sort | awk 'BEGIN{FS=":.*##"}{printf "  %-12s %s\n",$$1,$$2}'

dev-up:   ## start the dev stack
	docker compose -f $(DEV_COMPOSE) --env-file $(DEV_ENV) up -d

dev-down: ## stop the dev stack
	docker compose -f $(DEV_COMPOSE) --env-file $(DEV_ENV) down

dev-logs: ## follow dev logs
	docker compose -f $(DEV_COMPOSE) --env-file $(DEV_ENV) logs -f

prod-setup: ## generate a strong MONGODB_PASSWORD into the prod .env (run once before prod-up)
	@grep -q '^MONGODB_PASSWORD=CHANGE_ME' $(PROD_ENV) || { echo "ERROR: MONGODB_PASSWORD already set; refusing to overwrite (delete the line or reset to the CHANGE_ME placeholder to regenerate)"; exit 1; }; \
	 pw=$$(perl -e 'open(my $$f,"<:raw","/dev/urandom") or exit 1; read($$f,my $$b,24)==24 or exit 1; print unpack("H*",$$b)'); \
	 [ $${#pw} -eq 48 ] || { echo "ERROR: could not generate password"; exit 1; }; \
	 sed -i.bak "s/^MONGODB_PASSWORD=.*/MONGODB_PASSWORD=$$pw/" $(PROD_ENV) && rm -f $(PROD_ENV).bak; \
	 chmod 600 $(PROD_ENV); \
	 echo "Wrote a generated MONGODB_PASSWORD to $(PROD_ENV)"

prod-up: ## start the production stack (requires prod-setup first)
	@grep -q '^MONGODB_PASSWORD=CHANGE_ME' $(PROD_ENV) && { echo "ERROR: run 'make prod-setup' first"; exit 1; }; \
	 docker compose -f $(PROD_COMPOSE) --env-file $(PROD_ENV) up -d

prod-down: ## stop the production stack
	docker compose -f $(PROD_COMPOSE) --env-file $(PROD_ENV) down

prod-logs: ## follow production logs
	docker compose -f $(PROD_COMPOSE) --env-file $(PROD_ENV) logs -f
