package store

import "embed"

// Migrations holds the golang-migrate files, applied in order. The first one
// is docs/schema.sql verbatim, so the whole data model, row-level security
// included, exists from the first `migrate up`. `make migrate` applies them
// from the command line; the backend binary will embed and apply them at
// deploy time.
//
//go:embed migrations/*.sql
var Migrations embed.FS
