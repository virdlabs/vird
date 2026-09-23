// Package store owns Postgres (with pgvector) and object storage for Vird.
//
// The data model lives in docs/schema.sql. sqlc reads that file and writes
// models.go, one Go type per table and per enum, together with the query
// methods in *.sql.go from the SQL under queries/. Regenerate with
// `make sqlc`; never edit the generated files.
//
// Rules the rest of the backend relies on:
//
//   - Every user-facing transaction starts with Queries.BindUser. Row-level
//     security is forced on every table and reads that binding; an unbound
//     transaction sees no rows. There is one ownership mechanism: child rows
//     carry no user_id, the policies walk parent keys.
//   - Requests connect as vird_app, which cannot bypass row-level security.
//     vird_system, which can, runs migrations, the asset sweeper and
//     embedding backfills only.
//   - A user session never hard-deletes a garment. The garments policy grants
//     no DELETE, so such a statement affects zero rows; the store treats that
//     as a bug. Users delete by setting deleted_at.
//   - Nothing writes outfits, outfit_items or wash_events until the user
//     confirms. Logging is idempotent on outfits.idempotency_key.
//   - Object storage keys are stored, never URLs. Raw camera frames are never
//     stored and have no table.
//
// Enum columns are typed (Season, ColorFamily, ...) rather than strings. pgx
// does not know these Postgres types until they are registered on the
// connection, and scanning an enum array such as garments.season_tags fails
// without that; the connection setup that registers them, and pgvector's
// binary codec, comes with the backend skeleton.
package store
