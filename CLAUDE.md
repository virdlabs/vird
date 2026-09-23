# Vird

A mirror-mounted assistant that sees what you're wearing, talks with you about it, and remembers every outfit. Three parts, one backend: a Raspberry Pi device on the mirror, an iPhone app, and a Go service that knows the user's closet.

The full design is in `docs/design.md` (v1.3, frozen). Read it before changing any architecture, schema, or protocol. `docs/schema.sql` is the source of truth for the data model. Record design changes as one line in `docs/decisions.md`.

## Current phase

Phase 1 of the build order in `docs/design.md`: schema, backend skeleton, recognition package and benchmark, then the iPhone app. **No device code, no `proto/` protocol, no `gateway` package until the phone loop (recognize → correct → critique → log → suggest) is in daily use and the recognition benchmark passes.** If asked to start device work early, point at this rule.

## Repo layout

```
ios/        SwiftUI app (iPhone only)
backend/    Go, one binary, packages: api, gateway, assistant, recognition, suggest, context, store
device/     Python on the Pi (not started)
proto/      device <-> backend message contract (not started)
docs/       design.md, schema.sql, decisions.md
```

## Rules that are not up for debate

- `api` and `gateway` are transport only. Anything that means something (intent, recognition, critique, suggest, log) goes through `assistant`. Phone and mirror must hit the same code.
- Recognition never force-fits. Every detected garment returns `best_match`, `alternatives`, and a composite `score`; low score means unknown, not the closest item.
- The suggestion model never sees the whole closet. Code applies hard constraints and soft penalties, keeps a shortlist of ten, and the model ranks and explains. It cannot name a garment outside the shortlist.
- Nothing writes to outfits, wear history, or wash state until the user confirms. ObservedFit → confirmation → Outfit. Logging is idempotent on the observed fit.
- Raw mirror frames are never written to storage. Analysis assets live in the TTL bucket and are deleted when the ObservedFit closes or after 30 minutes. Retained images exist only after an explicit confirm, add, or log.
- Ownership is normalized through parent foreign keys. Child tables do not carry `user_id`. RLS walks the chain and is on from the first migration.
- Every attribute deterministic code uses must exist as a column on `garments`. Do not parse free text in `suggest`.
- One trace per assistant turn from day one. Add spans, don't add print statements.

## Stack and conventions

- Go 1.25+ (pgx v5.11 and pgvector-go require it), standard library HTTP, `pgx`, `sqlc` for queries, `golang-migrate` for migrations generated from `docs/schema.sql`. Table-driven tests. No ORM.
- Postgres with `pgvector` (exact search; no ANN index yet). S3-compatible object storage with a TTL bucket for analysis assets.
- OpenTelemetry for tracing, Prometheus for metrics.
- SwiftUI, iOS 18+, Swift concurrency. Vision framework for subject lift on catalog photos only.
- Deploy is one process on Fly.io with managed Postgres. No Kubernetes.
- Money is `price_minor` + `currency`. Dates that mean "a day" are user-local (`users.timezone`). Enums are Postgres enums, not free strings.
- Prefer small PRs that touch one package. Update `docs/decisions.md` in the same PR when a rule above changes.

## Commands

Nothing has to be installed: each target uses a local `go`, `sqlc` or `migrate` when one is on PATH and the pinned images in `compose.yaml` otherwise.

```
make db           # start docker-compose postgres (pgvector, roles bootstrapped)
make migrate      # apply migrations as vird_system; ARGS="down 1", ARGS=version
make sqlc         # regenerate backend/store from docs/schema.sql and store/queries
make migrations   # refresh the first migration, a verbatim copy of docs/schema.sql
make test         # go vet + go test ./...
make down         # stop compose services, keep the data volume
```

Not yet: `make dev` (run the backend, arrives with the skeleton) and `make bench` (recognition benchmark, `backend/recognition/bench`).

## Working with me

- Before implementing a feature, name the packages it touches and the entities from `docs/schema.sql` it reads or writes. If it needs an entity that isn't there, stop and propose the schema change first.
- When the design doc and the code disagree, say so; don't silently pick one.
- Recognition changes must include a benchmark run against the calibration set. Never tune against the test set.
