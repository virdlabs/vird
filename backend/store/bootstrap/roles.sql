-- Development bootstrap: what the managed-Postgres console does in
-- production. docker-compose runs it once, as the superuser, when the data
-- volume is first created. Migrations never do any of this; see the header
-- of docs/schema.sql.

-- pgvector is not a trusted extension, so this needs the superuser.
CREATE EXTENSION IF NOT EXISTS vector;

-- Runs migrations, the asset sweeper, embedding backfills and account
-- creation. Never serves a user request.
CREATE ROLE vird_system LOGIN PASSWORD 'vird_system' BYPASSRLS;

-- Serves user requests. No BYPASSRLS: every row it sees passed a policy.
CREATE ROLE vird_app LOGIN PASSWORD 'vird_app';

-- vird_system owns the database, and with it the public schema, so
-- migrations can create objects. Tables it creates are readable and
-- writable by vird_app; row-level security does the rest.
ALTER DATABASE vird OWNER TO vird_system;
GRANT USAGE ON SCHEMA public TO vird_app;
ALTER DEFAULT PRIVILEGES FOR ROLE vird_system IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO vird_app;
