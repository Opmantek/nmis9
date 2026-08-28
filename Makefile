# Container lifecycle for the dev and production Docker Compose stacks.
# OMK-12826: prod-setup generates strong, distinct MONGODB_PASSWORD (mongo
# root/admin) and MONGODB_APP_PASSWORD (scoped nmis9RW app user) into the prod
# .env; prod-up refuses to start until both are set to non-default values (the
# deny set is shared from installer_hooks/common_dbpassword.sh).

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

prod-setup: ## generate strong, distinct MONGODB_PASSWORD and MONGODB_APP_PASSWORD into the prod .env (run once before prod-up)
	@grep -q '^MONGODB_PASSWORD=CHANGE_ME' $(PROD_ENV) || { echo "ERROR: MONGODB_PASSWORD already set; refusing to overwrite (reset it to the CHANGE_ME placeholder to regenerate)"; exit 1; }; \
	 grep -q '^MONGODB_APP_PASSWORD=CHANGE_ME' $(PROD_ENV) || { echo "ERROR: MONGODB_APP_PASSWORD already set; refusing to overwrite (reset it to the CHANGE_ME placeholder to regenerate)"; exit 1; }; \
	 pw=$$(perl -e 'open(my $$f,"<:raw","/dev/urandom") or exit 1; read($$f,my $$b,24)==24 or exit 1; print unpack("H*",$$b)'); \
	 apppw=$$(perl -e 'open(my $$f,"<:raw","/dev/urandom") or exit 1; read($$f,my $$b,24)==24 or exit 1; print unpack("H*",$$b)'); \
	 { [ $${#pw} -eq 48 ] && [ $${#apppw} -eq 48 ] && [ "$$pw" != "$$apppw" ]; } || { echo "ERROR: could not generate two distinct passwords"; exit 1; }; \
	 sed -i.bak -e "s/^MONGODB_PASSWORD=.*/MONGODB_PASSWORD=$$pw/" -e "s/^MONGODB_APP_PASSWORD=.*/MONGODB_APP_PASSWORD=$$apppw/" $(PROD_ENV) && rm -f $(PROD_ENV).bak; \
	 chmod 600 $(PROD_ENV); \
	 echo "Wrote generated MONGODB_PASSWORD and MONGODB_APP_PASSWORD to $(PROD_ENV)"

prod-up: ## start the production stack (requires prod-setup first)
	@. installer_hooks/common_dbpassword.sh; \
	 rootpw=$$(sed -n 's/^MONGODB_PASSWORD=//p' $(PROD_ENV)); \
	 apppw=$$(sed -n 's/^MONGODB_APP_PASSWORD=//p' $(PROD_ENV)); \
	 if nmis_dbpassword_is_insecure "$$rootpw"; then echo "ERROR: MONGODB_PASSWORD is empty or a known default; run 'make prod-setup' first"; exit 1; fi; \
	 if nmis_dbpassword_is_insecure "$$apppw"; then echo "ERROR: MONGODB_APP_PASSWORD is empty or a known default; run 'make prod-setup' first"; exit 1; fi; \
	 if [ "$$rootpw" = "$$apppw" ]; then echo "ERROR: MONGODB_PASSWORD and MONGODB_APP_PASSWORD must differ; run 'make prod-setup'"; exit 1; fi; \
	 docker compose -f $(PROD_COMPOSE) --env-file $(PROD_ENV) up -d

prod-down: ## stop the production stack
	docker compose -f $(PROD_COMPOSE) --env-file $(PROD_ENV) down

prod-logs: ## follow production logs
	docker compose -f $(PROD_COMPOSE) --env-file $(PROD_ENV) logs -f
