# Nothing here needs Go, sqlc, migrate or psql installed. Each target uses the
# local binary when one is on PATH and the pinned image in compose.yaml
# otherwise (Docker via Colima on this machine).

COMPOSE := docker compose

ifneq ($(shell command -v go 2>/dev/null),)
GO := go -C backend
else
GO := $(COMPOSE) run --rm go
endif

ifneq ($(shell command -v sqlc 2>/dev/null),)
SQLC := sqlc -f backend/sqlc.yaml
else
SQLC := $(COMPOSE) run --rm sqlc
endif

.PHONY: db migrate sqlc migrations test tidy down

## db: start Postgres (pgvector) and wait until it accepts connections
db:
	$(COMPOSE) up -d --wait postgres

## migrate: apply migrations as vird_system. ARGS overrides the migrate
## command, e.g. make migrate ARGS="down 1" or ARGS=version
ARGS ?= up
migrate: db
	$(COMPOSE) run --rm migrate $(ARGS)

## sqlc: regenerate backend/store from docs/schema.sql and store/queries
sqlc:
	$(SQLC) generate

## migrations: refresh the first migration, which is docs/schema.sql verbatim.
## This rule goes away with the second migration; from then on schema changes
## are new migration files and docs/schema.sql is updated to match.
migrations: backend/store/migrations/000001_init.up.sql
backend/store/migrations/000001_init.up.sql: docs/schema.sql
	cp $< $@

## test: vet and test the backend
test:
	$(GO) vet ./...
	$(GO) test ./...

## tidy: go mod tidy
tidy:
	$(GO) mod tidy

## down: stop the compose services (data volume is kept)
down:
	$(COMPOSE) down
