package store

import (
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// The first migration is docs/schema.sql verbatim; `make migrations`
// refreshes the copy. Once a second migration exists the schema file is no
// longer one migration's worth of DDL, and this test gives way to one that
// applies every migration to a database and diffs the result against the
// schema file.
func TestInitMigrationIsSchema(t *testing.T) {
	want, err := os.ReadFile(filepath.Join("..", "..", "docs", "schema.sql"))
	if err != nil {
		t.Fatal(err)
	}
	got, err := Migrations.ReadFile("migrations/000001_init.up.sql")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatal("migrations/000001_init.up.sql differs from docs/schema.sql; run `make migrations`")
	}
}

// Every table, type and function an up migration creates, its down
// migration drops, and nothing else. Policies, triggers and indexes go with
// their tables and are not checked.
func TestDownMigrationsDropWhatUpCreates(t *testing.T) {
	kinds := []struct {
		kind         string
		create, drop *regexp.Regexp
	}{
		{"table", regexp.MustCompile(`(?m)^CREATE TABLE (\w+)`), regexp.MustCompile(`(?m)^DROP TABLE (\w+)`)},
		{"type", regexp.MustCompile(`(?m)^CREATE TYPE (\w+)`), regexp.MustCompile(`(?m)^DROP TYPE (\w+)`)},
		{"function", regexp.MustCompile(`(?m)^CREATE FUNCTION (\w+)`), regexp.MustCompile(`(?m)^DROP FUNCTION (\w+)`)},
	}

	ups, err := fs.Glob(Migrations, "migrations/*.up.sql")
	if err != nil {
		t.Fatal(err)
	}
	if len(ups) == 0 {
		t.Fatal("no up migrations embedded")
	}
	for _, upPath := range ups {
		downPath := strings.TrimSuffix(upPath, ".up.sql") + ".down.sql"
		up, err := Migrations.ReadFile(upPath)
		if err != nil {
			t.Fatal(err)
		}
		down, err := Migrations.ReadFile(downPath)
		if err != nil {
			t.Fatalf("%s has no down migration: %v", upPath, err)
		}
		for _, k := range kinds {
			t.Run(filepath.Base(upPath)+"/"+k.kind, func(t *testing.T) {
				created := names(k.create, up)
				dropped := names(k.drop, down)
				for _, name := range created {
					if !slices.Contains(dropped, name) {
						t.Errorf("%s %s is created but never dropped", k.kind, name)
					}
				}
				for _, name := range dropped {
					if !slices.Contains(created, name) {
						t.Errorf("%s %s is dropped but never created", k.kind, name)
					}
				}
				if len(created) == 0 {
					t.Errorf("no %s created; the pattern may be stale", k.kind)
				}
			})
		}
	}
}

func names(re *regexp.Regexp, sql []byte) []string {
	var out []string
	for _, m := range re.FindAllSubmatch(sql, -1) {
		out = append(out, string(m[1]))
	}
	return out
}
