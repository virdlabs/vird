-- name: BindUser :exec
-- BindUser names the user the current transaction acts for. Row-level
-- security on every table reads this setting and fails closed, so it must be
-- the first statement of every user-facing transaction. The setting is
-- transaction-local (is_local = true): it ends with the transaction and never
-- leaks to the next request on the same pooled connection.
SELECT set_config('vird.user_id', (@user_id::uuid)::text, true);
