-- =============================================================================
-- Vird data model
-- =============================================================================
-- This file is the source of truth for the data model (docs/design.md v1.3,
-- "Domain model", as amended by docs/decisions.md). Migrations are generated
-- from it and sqlc reads it for Go types. Where design.md and this file differ,
-- this file wins and docs/decisions.md says why.
--
-- Requires Postgres 15+ and pgvector 0.5+.
--
-- Conventions
--   * Every table has created_at. Entity tables have a uuid id. Join tables
--     have a composite primary key.
--   * Ownership is normalized. Only direct children of users carry user_id.
--     Every other row reaches its user through parent foreign keys, and
--     row-level security walks that chain. There is one ownership mechanism.
--   * The store layer names the current user per request, transaction-local:
--         SELECT set_config('vird.user_id', '<uuid>', true);
--     vird_user_id() reads it. Unset means no rows are visible: fail closed.
--   * Foreign-key checks bypass row-level security, so a policy's USING clause
--     alone would let a row reference another user's garment by id. Every
--     policy's WITH CHECK therefore also verifies that each cross-tree
--     reference (garment, device, fit, suggestion) belongs to the current user.
--   * Roles are created outside this file, by the bootstrap script or the
--     managed-Postgres console, never by a migration:
--         vird_app     LOGIN, no BYPASSRLS. Serves user requests. Needs USAGE
--                      on the schema and SELECT/INSERT/UPDATE/DELETE on tables.
--         vird_system  LOGIN, BYPASSRLS. Runs migrations, the asset sweeper,
--                      embedding backfills, and account creation. Never serves
--                      a user request.
--     Row-level security is FORCEd on every table, so even the table owner is
--     filtered unless it has BYPASSRLS. Superusers bypass RLS no matter what;
--     do not run the app as one, including in development.
--   * Enums are Postgres enums. Add a value with
--         ALTER TYPE <enum> ADD VALUE '<value>';
--     in its own migration; a new value cannot be used in the transaction that
--     adds it. A new garment_category must also be added to garment_role(), or
--     inserting that category fails on the NOT NULL role column.
--   * Money is price_minor plus an ISO 4217 currency. Instants are timestamptz.
--     A "day" is a date computed from an instant and an IANA time zone name.
--   * Optional free text is NULL, never ''. jsonb is used only for payloads
--     whose shape is versioned elsewhere: a weather provider's snapshot, the
--     inputs behind a recognizer_version's score, an event's detail.
--   * Object storage keys are stored, never URLs. Raw camera frames are never
--     stored anywhere and have no table.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Extensions
-- -----------------------------------------------------------------------------

-- pgvector is not a trusted extension, so creating it needs a superuser.
-- Enable it from the managed-Postgres console (or as the superuser in
-- docker-compose) before the first migration; this statement then no-ops.
CREATE EXTENSION IF NOT EXISTS vector;


-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------

-- What a garment is. Grouped by the outfit_role that garment_role() assigns.
-- The other_* values are the escape hatch for anything the detector or the
-- user cannot place; they still map to a role so suggest can use them.
CREATE TYPE garment_category AS ENUM (
    -- top
    't_shirt', 'shirt', 'polo', 'blouse', 'tank_top', 'sweater', 'sweatshirt',
    'hoodie', 'cardigan', 'overshirt', 'other_top',
    -- bottom
    'jeans', 'trousers', 'chinos', 'shorts', 'skirt', 'sweatpants', 'leggings',
    'other_bottom',
    -- one_piece
    'dress', 'jumpsuit', 'other_one_piece',
    -- outerwear
    'jacket', 'blazer', 'coat', 'vest', 'other_outerwear',
    -- footwear
    'sneakers', 'boots', 'loafers', 'dress_shoes', 'sandals', 'other_footwear',
    -- accessory
    'hat', 'beanie', 'scarf', 'gloves', 'belt', 'bag', 'sunglasses', 'watch',
    'jewelry', 'socks', 'tie', 'other_accessory'
);

-- The slot a garment fills in an outfit. suggest composes and swaps per role.
-- Layering within a role (tee under sweater) is outfit_items.layer_position.
CREATE TYPE outfit_role AS ENUM (
    'top', 'bottom', 'one_piece', 'outerwear', 'footwear', 'accessory'
);

-- Coarse colour used by deterministic code (request words like "dark",
-- colour compatibility, style-profile exclusions). garments.color holds the
-- free-text shade.
CREATE TYPE color_family AS ENUM (
    'black', 'white', 'grey', 'cream', 'beige', 'tan', 'brown', 'navy', 'blue',
    'green', 'olive', 'red', 'burgundy', 'pink', 'orange', 'yellow', 'purple',
    'multi'
);

CREATE TYPE garment_fit AS ENUM ('relaxed', 'regular', 'slim');

CREATE TYPE season AS ENUM ('spring', 'summer', 'fall', 'winter');

CREATE TYPE garment_pattern AS ENUM (
    'solid', 'striped', 'checked', 'plaid', 'floral', 'graphic', 'textured',
    'other'
);

-- Dominant material. Deterministic code maps request words ("comfy") onto
-- this and garment_fit.
CREATE TYPE garment_material AS ENUM (
    'cotton', 'linen', 'wool', 'cashmere', 'silk', 'denim', 'leather', 'suede',
    'polyester', 'nylon', 'fleece', 'viscose', 'other'
);

-- Where an image came from. Used for garments.created_from and
-- garment_exemplars.capture_source; the two share one value set by design.
CREATE TYPE capture_source AS ENUM ('catalog', 'phone_fit', 'mirror');

-- Why an exemplar exists. Everything but 'initial' is a promotion of a
-- recognition candidate's crop.
CREATE TYPE exemplar_creation_reason AS ENUM (
    'initial', 'confirmation', 'correction', 'new_garment'
);

CREATE TYPE observed_fit_source AS ENUM ('mirror', 'phone');

-- open: analysis assets alive, corrections accepted. confirmed: an outfit was
-- logged from it. discarded: closed without logging, by the user or by TTL.
CREATE TYPE observed_fit_status AS ENUM ('open', 'confirmed', 'discarded');

CREATE TYPE analysis_asset_kind AS ENUM ('garment_crop', 'phone_photo');

-- pending:   recognition asked (middle score) or offered to add (low score)
--            and the user has not answered.
-- auto:      high score, accepted silently. Stays 'auto' only until a
--            correction; corrections.prior_resolution remembers it was silent.
-- confirmed: the user accepted best_match.
-- corrected: the user chose a different existing garment.
-- new:       the user added the detected garment to the closet.
-- unknown:   not in the closet and not added.
CREATE TYPE candidate_resolution AS ENUM (
    'pending', 'auto', 'confirmed', 'corrected', 'new', 'unknown'
);

CREATE TYPE recommendation_event_type AS ENUM (
    'shown', 'accepted', 'rejected', 'item_swapped', 'logged_as_is',
    'logged_with_changes', 'thumbs_down'
);

-- Image classes that can leave the backend for an inference provider.
CREATE TYPE image_kind AS ENUM (
    'raw_frame', 'phone_photo', 'garment_crop', 'catalog_photo'
);

CREATE TYPE image_purpose AS ENUM ('detect', 'embed', 'critique', 'segment');


-- -----------------------------------------------------------------------------
-- Functions used by column defaults, constraints and generated columns
-- -----------------------------------------------------------------------------

-- The user the store layer bound to this transaction, or NULL.
CREATE FUNCTION vird_user_id() RETURNS uuid
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$ SELECT nullif(current_setting('vird.user_id', true), '')::uuid $$;

-- The calendar day of an instant in an IANA time zone. Declared IMMUTABLE so
-- it can back a stored generated column; strictly it depends on the server's
-- time zone database, but a stored value is computed when the row is written,
-- which is exactly the day the user saw. An unknown zone name raises.
CREATE FUNCTION local_date(ts timestamptz, tz text) RETURNS date
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $$ SELECT (ts AT TIME ZONE tz)::date $$;

-- True when Postgres recognizes tz as a time zone name.
CREATE FUNCTION is_valid_timezone(tz text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE STRICT
    AS $$
BEGIN
    PERFORM local_date('2000-01-01T00:00:00Z'::timestamptz, tz);
    RETURN true;
EXCEPTION WHEN invalid_parameter_value THEN
    RETURN false;
END
$$;

-- The outfit_role a category fills by default. Backs garments.role. Returns
-- NULL for an unmapped category, which the NOT NULL column turns into an
-- error at insert time rather than a silent gap in suggest.
CREATE FUNCTION garment_role(c garment_category) RETURNS outfit_role
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
    SELECT CASE
        WHEN c IN ('t_shirt', 'shirt', 'polo', 'blouse', 'tank_top', 'sweater',
                   'sweatshirt', 'hoodie', 'cardigan', 'overshirt', 'other_top')
            THEN 'top'
        WHEN c IN ('jeans', 'trousers', 'chinos', 'shorts', 'skirt',
                   'sweatpants', 'leggings', 'other_bottom')
            THEN 'bottom'
        WHEN c IN ('dress', 'jumpsuit', 'other_one_piece')
            THEN 'one_piece'
        WHEN c IN ('jacket', 'blazer', 'coat', 'vest', 'other_outerwear')
            THEN 'outerwear'
        WHEN c IN ('sneakers', 'boots', 'loafers', 'dress_shoes', 'sandals',
                   'other_footwear')
            THEN 'footwear'
        WHEN c IN ('hat', 'beanie', 'scarf', 'gloves', 'belt', 'bag',
                   'sunglasses', 'watch', 'jewelry', 'socks', 'tie',
                   'other_accessory')
            THEN 'accessory'
    END::outfit_role
$$;


-- -----------------------------------------------------------------------------
-- Users and devices
-- -----------------------------------------------------------------------------

CREATE TABLE users (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Sign in with Apple subject. NULL for the fixed dev account.
    apple_sub        text,
    -- IANA name. Every "day" in this schema is computed against it.
    timezone         text        NOT NULL,
    -- City as the user typed it, plus the coordinates it resolved to.
    weather_location text,
    weather_lat      double precision,
    weather_lon      double precision,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT users_apple_sub_nonempty
        CHECK (apple_sub IS NULL OR apple_sub <> ''),
    CONSTRAINT users_timezone_valid
        CHECK (is_valid_timezone(timezone)),
    CONSTRAINT users_weather_all_or_none
        CHECK ((weather_location IS NULL) = (weather_lat IS NULL)
           AND (weather_location IS NULL) = (weather_lon IS NULL)),
    CONSTRAINT users_weather_lat_range
        CHECK (weather_lat IS NULL OR weather_lat BETWEEN -90 AND 90),
    CONSTRAINT users_weather_lon_range
        CHECK (weather_lon IS NULL OR weather_lon BETWEEN -180 AND 180)
);

CREATE UNIQUE INDEX users_apple_sub_key
    ON users (apple_sub) WHERE apple_sub IS NOT NULL;


-- A paired mirror. The pairing handshake (pending device, six-digit code) is
-- not modelled until the device phase; see docs/design.md "Device pairing".
CREATE TABLE devices (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    -- Raw public key bytes generated on the device at first boot.
    public_key bytea       NOT NULL,
    name       text        NOT NULL,
    paired_at  timestamptz NOT NULL DEFAULT now(),
    -- Set on revoke. The device credential is invalid from this instant.
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT devices_name_nonempty
        CHECK (name <> ''),
    CONSTRAINT devices_public_key_nonempty
        CHECK (octet_length(public_key) > 0),
    CONSTRAINT devices_revoked_after_paired
        CHECK (revoked_at IS NULL OR revoked_at >= paired_at)
);

CREATE INDEX devices_user_id_idx ON devices (user_id);

-- One active pairing per key. A revoked row keeps its key for the audit trail;
-- a re-flashed device pairs again with a fresh row.
CREATE UNIQUE INDEX devices_active_public_key_key
    ON devices (public_key) WHERE revoked_at IS NULL;


-- -----------------------------------------------------------------------------
-- Closet
-- -----------------------------------------------------------------------------

-- One item the user owns. Every attribute deterministic code (suggest,
-- context) reads is a column here; nothing is parsed out of free text.
CREATE TABLE garments (
    id               uuid             PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id          uuid             NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    category         garment_category NOT NULL,
    -- Slot this garment fills by default; derived from category so the two
    -- cannot drift. outfit_items.role records the slot actually played.
    role             outfit_role      NOT NULL GENERATED ALWAYS AS (garment_role(category)) STORED,
    name             text             NOT NULL,
    brand            text,
    -- Free-text shade ("washed black"). color_family is what code uses.
    color            text,
    color_family     color_family     NOT NULL,
    pattern          garment_pattern,
    material         garment_material,
    -- NULL where fit is meaningless (most footwear and accessories).
    fit              garment_fit,
    -- Empty means no seasonal restriction.
    season_tags      season[]         NOT NULL DEFAULT '{}',
    -- 1 (lightest) to 5 (warmest). NULL where warmth is meaningless.
    warmth           smallint,
    -- Wears before this item counts as needing a wash. NULL means the
    -- category default in code applies.
    wash_after_wears smallint,
    -- Minor units of currency (cents). Both set or both NULL.
    price_minor      bigint,
    currency         text,
    created_from     capture_source   NOT NULL,
    -- Archived: still owned, never suggested, still recognized.
    archived_at      timestamptz,
    -- Deleted: gone from the closet and its images purged, but the row stays
    -- so outfits that include it keep their history. A garment that was ever
    -- worn or suggested cannot be hard-deleted: the deferred keys on
    -- outfit_items and suggested_outfit_items refuse it at commit.
    deleted_at       timestamptz,
    created_at       timestamptz      NOT NULL DEFAULT now(),
    updated_at       timestamptz      NOT NULL DEFAULT now(),

    CONSTRAINT garments_name_nonempty
        CHECK (name <> ''),
    CONSTRAINT garments_warmth_range
        CHECK (warmth IS NULL OR warmth BETWEEN 1 AND 5),
    CONSTRAINT garments_wash_after_wears_positive
        CHECK (wash_after_wears IS NULL OR wash_after_wears > 0),
    CONSTRAINT garments_price_and_currency_together
        CHECK ((price_minor IS NULL) = (currency IS NULL)),
    CONSTRAINT garments_price_nonnegative
        CHECK (price_minor IS NULL OR price_minor >= 0),
    CONSTRAINT garments_currency_iso4217
        CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$'),
    CONSTRAINT garments_deleted_implies_archived
        CHECK (deleted_at IS NULL OR archived_at IS NOT NULL)
);

CREATE INDEX garments_user_id_idx ON garments (user_id);


-- One retained image of a garment. Created only by an explicit user action:
-- adding a garment, confirming or correcting a match. Deleting the row is
-- the signal to delete the object at image_key.
CREATE TABLE garment_exemplars (
    id              uuid                     PRIMARY KEY DEFAULT gen_random_uuid(),
    garment_id      uuid                     NOT NULL REFERENCES garments (id) ON DELETE CASCADE,
    -- Key in the private (retained) bucket.
    image_key       text                     NOT NULL,
    capture_source  capture_source           NOT NULL,
    creation_reason exemplar_creation_reason NOT NULL,
    -- Crop quality in [0, 1] as judged by recognition. NULL if not scored.
    quality         double precision,
    -- The recognition candidate whose crop was promoted into this exemplar.
    -- NULL for 'initial' exemplars, or if the candidate row is gone. At most
    -- one exemplar per candidate, so promotion is idempotent. The foreign
    -- key is added after recognition_candidates is defined.
    candidate_id    uuid,
    created_at      timestamptz              NOT NULL DEFAULT now(),

    CONSTRAINT garment_exemplars_image_key_key
        UNIQUE (image_key),
    CONSTRAINT garment_exemplars_quality_range
        CHECK (quality IS NULL OR quality BETWEEN 0 AND 1),
    CONSTRAINT garment_exemplars_initial_has_no_candidate
        CHECK (creation_reason <> 'initial' OR candidate_id IS NULL)
);

CREATE INDEX garment_exemplars_garment_id_idx ON garment_exemplars (garment_id);

CREATE UNIQUE INDEX garment_exemplars_candidate_id_key
    ON garment_exemplars (candidate_id) WHERE candidate_id IS NOT NULL;


-- Registry of embedding models that have been used, with their dimension.
-- Which one is active is configuration, not data. Introducing a model is a
-- row here, a backfill of exemplar_embeddings, a benchmark run, and a config
-- change. Readable by everyone; written only by vird_system.
CREATE TABLE embedding_models (
    name       text        PRIMARY KEY,
    dims       integer     NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT embedding_models_name_nonempty
        CHECK (name <> ''),
    CONSTRAINT embedding_models_dims_range
        CHECK (dims BETWEEN 1 AND 16000)
);


-- One representation of an exemplar under one model. One image, many rows.
-- The column is an untyped vector so one table serves every model; a trigger
-- enforces the model's dimension. Search is exact (no ANN index yet).
CREATE TABLE exemplar_embeddings (
    exemplar_id uuid        NOT NULL REFERENCES garment_exemplars (id) ON DELETE CASCADE,
    model       text        NOT NULL REFERENCES embedding_models (name),
    embedding   vector      NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (exemplar_id, model)
);

CREATE INDEX exemplar_embeddings_model_idx ON exemplar_embeddings (model);


-- -----------------------------------------------------------------------------
-- Observation and recognition (before confirmation)
-- -----------------------------------------------------------------------------

-- What a camera or photo saw, before the user confirmed anything. Lives in
-- the session across turns so a follow-up correction still has its crops.
-- Nothing here touches wear or wash history.
CREATE TABLE observed_fits (
    id         uuid                PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid                NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    -- The mirror that produced it. NULL for phone fits.
    device_id  uuid                REFERENCES devices (id) ON DELETE SET NULL,
    -- Gateway session for the mirror, app session for the phone. At most one
    -- open fit per session.
    session_id text                NOT NULL,
    source     observed_fit_source NOT NULL,
    status     observed_fit_status NOT NULL DEFAULT 'open',
    -- Hard cap on how long analysis assets may live: never more than
    -- 30 minutes after the fit was created. The sweeper closes the fit and
    -- deletes its assets at this instant if it is still open.
    expires_at timestamptz         NOT NULL DEFAULT (now() + interval '30 minutes'),
    closed_at  timestamptz,
    created_at timestamptz         NOT NULL DEFAULT now(),

    CONSTRAINT observed_fits_session_id_nonempty
        CHECK (session_id <> ''),
    CONSTRAINT observed_fits_phone_has_no_device
        CHECK (source <> 'phone' OR device_id IS NULL),
    CONSTRAINT observed_fits_ttl_at_most_30_minutes
        CHECK (expires_at <= created_at + interval '30 minutes'),
    CONSTRAINT observed_fits_closed_iff_not_open
        CHECK ((status = 'open') = (closed_at IS NULL))
);

CREATE INDEX observed_fits_user_created_idx
    ON observed_fits (user_id, created_at DESC);

CREATE UNIQUE INDEX observed_fits_one_open_per_session_key
    ON observed_fits (user_id, session_id) WHERE status = 'open';

CREATE INDEX observed_fits_open_expires_at_idx
    ON observed_fits (expires_at) WHERE status = 'open';


-- A temporary image derived during analysis: a garment crop, or the photo a
-- phone user submitted. Lives in the TTL bucket. The row is deleted together
-- with the object when the fit closes or the asset expires, whichever comes
-- first. Promotion (confirm, add, log) copies the object into retained
-- storage as a garment_exemplar or an outfit history photo; it never
-- extends the asset's life.
CREATE TABLE analysis_assets (
    id              uuid                PRIMARY KEY DEFAULT gen_random_uuid(),
    observed_fit_id uuid                NOT NULL REFERENCES observed_fits (id) ON DELETE CASCADE,
    kind            analysis_asset_kind NOT NULL,
    -- Key in the TTL bucket.
    object_key      text                NOT NULL,
    expires_at      timestamptz         NOT NULL DEFAULT (now() + interval '30 minutes'),
    created_at      timestamptz         NOT NULL DEFAULT now(),

    CONSTRAINT analysis_assets_object_key_key
        UNIQUE (object_key),
    CONSTRAINT analysis_assets_ttl_at_most_30_minutes
        CHECK (expires_at <= created_at + interval '30 minutes')
);

CREATE INDEX analysis_assets_observed_fit_id_idx ON analysis_assets (observed_fit_id);

CREATE INDEX analysis_assets_expires_at_idx ON analysis_assets (expires_at);


-- One detected garment in a fit and what recognition made of it. Recognition
-- never force-fits: best_match may be NULL, the runners-up are in
-- recognition_alternatives, and score is the composite recognition score,
-- not a raw similarity. Thresholds on score decide auto / ask / unknown.
CREATE TABLE recognition_candidates (
    id                    uuid                 PRIMARY KEY DEFAULT gen_random_uuid(),
    observed_fit_id       uuid                 NOT NULL REFERENCES observed_fits (id) ON DELETE CASCADE,
    -- The crop. NULL once the asset has expired and been deleted.
    analysis_asset_id     uuid                 REFERENCES analysis_assets (id) ON DELETE SET NULL,
    -- What the detector thought it was, before matching.
    detected_category     garment_category,
    -- Top match, or NULL when the score is below the unknown threshold.
    best_match_garment_id uuid                 REFERENCES garments (id) ON DELETE SET NULL,
    -- Composite recognition score in [0, 1].
    score                 double precision     NOT NULL,
    -- The inputs the score formula saw (top-1 similarity, margin, exemplar
    -- agreement, category consistency, crop quality). Shape is defined by
    -- recognizer_version; kept so a match can be re-scored offline.
    score_inputs          jsonb,
    -- Names the detector, embedding model, score formula and threshold set
    -- in code that produced this row.
    recognizer_version    text                 NOT NULL,
    resolution            candidate_resolution NOT NULL DEFAULT 'pending',
    -- The garment this candidate finally stands for, once resolved. Equals
    -- best_match for auto/confirmed, the correction target for corrected/new,
    -- NULL for pending/unknown or if the garment row is gone.
    resolved_garment_id   uuid                 REFERENCES garments (id) ON DELETE SET NULL,
    resolved_at           timestamptz,
    -- OpenTelemetry trace of the assistant turn that produced this row.
    trace_id              text,
    created_at            timestamptz          NOT NULL DEFAULT now(),

    CONSTRAINT recognition_candidates_score_range
        CHECK (score BETWEEN 0 AND 1),
    CONSTRAINT recognition_candidates_recognizer_version_nonempty
        CHECK (recognizer_version <> ''),
    CONSTRAINT recognition_candidates_resolved_at_iff_resolved
        CHECK ((resolution = 'pending') = (resolved_at IS NULL)),
    CONSTRAINT recognition_candidates_unresolved_has_no_garment
        CHECK (resolution NOT IN ('pending', 'unknown') OR resolved_garment_id IS NULL),
    -- Either side may be NULL: ON DELETE SET NULL clears the two columns in
    -- separate updates, and a CHECK that compared them strictly would fail
    -- between the two and block the delete.
    CONSTRAINT recognition_candidates_accepted_matches_best
        CHECK (resolution NOT IN ('auto', 'confirmed')
            OR best_match_garment_id IS NULL
            OR resolved_garment_id IS NULL
            OR resolved_garment_id = best_match_garment_id)
);

CREATE INDEX recognition_candidates_observed_fit_id_idx
    ON recognition_candidates (observed_fit_id);

CREATE INDEX recognition_candidates_analysis_asset_id_idx
    ON recognition_candidates (analysis_asset_id);

CREATE INDEX recognition_candidates_best_match_garment_id_idx
    ON recognition_candidates (best_match_garment_id);

CREATE INDEX recognition_candidates_resolved_garment_id_idx
    ON recognition_candidates (resolved_garment_id);

-- Forward reference from garment_exemplars, now that candidates exist.
ALTER TABLE garment_exemplars
    ADD CONSTRAINT garment_exemplars_candidate_id_fkey
    FOREIGN KEY (candidate_id) REFERENCES recognition_candidates (id) ON DELETE SET NULL;


-- The ranked runners-up for a candidate, excluding best_match. When
-- best_match is NULL these are the nearest garments that fell below the
-- threshold, offered as "or is it one of these?". Rank 1 is the closest.
CREATE TABLE recognition_alternatives (
    candidate_id uuid             NOT NULL REFERENCES recognition_candidates (id) ON DELETE CASCADE,
    garment_id   uuid             NOT NULL REFERENCES garments (id) ON DELETE CASCADE,
    rank         smallint         NOT NULL,
    -- Raw similarity under the recognizer's embedding model.
    similarity   double precision NOT NULL,
    created_at   timestamptz      NOT NULL DEFAULT now(),

    PRIMARY KEY (candidate_id, garment_id),
    CONSTRAINT recognition_alternatives_rank_positive
        CHECK (rank >= 1),
    CONSTRAINT recognition_alternatives_rank_key
        UNIQUE (candidate_id, rank)
);

CREATE INDEX recognition_alternatives_garment_id_idx
    ON recognition_alternatives (garment_id);


-- The user overriding a match. Confirming best_match is not a correction
-- (the candidate just becomes 'confirmed'); choosing another garment,
-- adding a new one, or saying "none of mine" is. The candidate's crop is
-- promoted to a garment_exemplar of to_garment_id when it is not NULL.
CREATE TABLE corrections (
    id               uuid                 PRIMARY KEY DEFAULT gen_random_uuid(),
    candidate_id     uuid                 NOT NULL REFERENCES recognition_candidates (id) ON DELETE CASCADE,
    -- The candidate's resolution before this correction. 'auto' here is a
    -- false silent match, the metric recognition is tuned against.
    prior_resolution candidate_resolution NOT NULL,
    -- best_match at the time, or NULL if recognition had said unknown.
    from_garment_id  uuid                 REFERENCES garments (id) ON DELETE SET NULL,
    -- The garment the user chose, whether existing or created for this
    -- correction. NULL means "not one of mine, and don't add it".
    to_garment_id    uuid                 REFERENCES garments (id) ON DELETE SET NULL,
    created_at       timestamptz          NOT NULL DEFAULT now(),

    CONSTRAINT corrections_changes_something
        CHECK (from_garment_id IS NULL OR to_garment_id IS NULL
            OR from_garment_id <> to_garment_id)
);

CREATE INDEX corrections_candidate_id_idx ON corrections (candidate_id);

CREATE INDEX corrections_from_garment_id_idx ON corrections (from_garment_id);

CREATE INDEX corrections_to_garment_id_idx ON corrections (to_garment_id);


-- -----------------------------------------------------------------------------
-- Suggestions
-- -----------------------------------------------------------------------------
-- Persist exactly what was shown. Code filters and scores a shortlist; the
-- model ranks and explains three outfits from it.

CREATE TABLE suggestions (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id          uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    -- What the user asked, if anything beyond "what should I wear".
    request_text     text,
    -- The weather the request was scored against, as returned by the
    -- provider. NULL when the user has no weather location.
    weather_snapshot jsonb,
    -- The ranking model and the prompt it was given.
    model            text        NOT NULL,
    prompt_version   text        NOT NULL,
    -- Names the constraint, penalty and shortlist configuration in code, the
    -- deterministic half of the pipeline, the way recognizer_version does.
    suggest_version  text        NOT NULL,
    -- OpenTelemetry trace of the assistant turn.
    trace_id         text,
    created_at       timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT suggestions_model_nonempty
        CHECK (model <> ''),
    CONSTRAINT suggestions_prompt_version_nonempty
        CHECK (prompt_version <> ''),
    CONSTRAINT suggestions_suggest_version_nonempty
        CHECK (suggest_version <> '')
);

CREATE INDEX suggestions_user_created_idx ON suggestions (user_id, created_at DESC);


-- One of the outfits shown for a suggestion, in the order shown.
CREATE TABLE suggested_outfits (
    id            uuid             PRIMARY KEY DEFAULT gen_random_uuid(),
    suggestion_id uuid             NOT NULL REFERENCES suggestions (id) ON DELETE CASCADE,
    -- 1 is the top pick.
    rank          smallint         NOT NULL,
    -- The deterministic score code gave this combination.
    score         double precision NOT NULL,
    -- The model's one-line reason, as shown.
    explanation   text             NOT NULL,
    created_at    timestamptz      NOT NULL DEFAULT now(),

    CONSTRAINT suggested_outfits_rank_positive
        CHECK (rank >= 1),
    CONSTRAINT suggested_outfits_rank_key
        UNIQUE (suggestion_id, rank),
    CONSTRAINT suggested_outfits_explanation_nonempty
        CHECK (explanation <> '')
);


-- The garments in a suggested outfit, one row per role. Immutable once
-- shown; a swap is a recommendation_event, and what the user finally wore is
-- the outfit logged from it.
CREATE TABLE suggested_outfit_items (
    suggested_outfit_id uuid        NOT NULL REFERENCES suggested_outfits (id) ON DELETE CASCADE,
    -- Deferred for the same reason as outfit_items.garment_id.
    garment_id          uuid        NOT NULL REFERENCES garments (id)
                                    ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED,
    role                outfit_role NOT NULL,
    -- Display order within the outfit.
    position            smallint    NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (suggested_outfit_id, garment_id),
    CONSTRAINT suggested_outfit_items_position_positive
        CHECK (position >= 1),
    CONSTRAINT suggested_outfit_items_position_key
        UNIQUE (suggested_outfit_id, position)
);

CREATE INDEX suggested_outfit_items_garment_id_idx
    ON suggested_outfit_items (garment_id);


-- What the user did with one shown outfit. Append-only.
-- detail by type: item_swapped {role, from_garment_id, to_garment_id};
-- logged_as_is / logged_with_changes {outfit_id}; thumbs_down {reason}.
CREATE TABLE recommendation_events (
    id                  uuid                      PRIMARY KEY DEFAULT gen_random_uuid(),
    suggested_outfit_id uuid                      NOT NULL REFERENCES suggested_outfits (id) ON DELETE CASCADE,
    type                recommendation_event_type NOT NULL,
    detail              jsonb,
    created_at          timestamptz               NOT NULL DEFAULT now()
);

CREATE INDEX recommendation_events_suggested_outfit_created_idx
    ON recommendation_events (suggested_outfit_id, created_at);


-- -----------------------------------------------------------------------------
-- Outfits and wear history (after confirmation)
-- -----------------------------------------------------------------------------
-- There is no wear table. A wear is an outfit_items row on an outfit. Wear
-- count, last worn and wears since wash derive from outfits, outfit_items and
-- wash_events.

-- A confirmed set of garments worn together. Written only when the user
-- confirms: "log it" on an observed fit, logging a suggested outfit, or a
-- manual entry.
CREATE TABLE outfits (
    id                       uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                  uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    -- The fit this outfit confirmed. At most one outfit per fit.
    from_observed_fit_id     uuid        REFERENCES observed_fits (id) ON DELETE SET NULL,
    -- The suggestion card this outfit was logged from, if any.
    from_suggested_outfit_id uuid        REFERENCES suggested_outfits (id) ON DELETE SET NULL,
    -- Supplied by the client; derived from the observed fit when there is
    -- one. Replays return the existing outfit.
    idempotency_key          text        NOT NULL,
    -- Key in the private bucket of the retained fit-check photo, if the user
    -- logged with it.
    history_photo_key        text,
    -- When the outfit was worn. Orders a wear against a same-day wash_event
    -- and allows backdated logging.
    worn_at                  timestamptz NOT NULL,
    -- When the user logged it.
    logged_at                timestamptz NOT NULL DEFAULT now(),
    -- users.timezone at logging time, copied by the store layer so the day
    -- below is fixed even if the user later changes time zone. An unknown
    -- zone name is rejected by the generated column below (SQLSTATE 22023),
    -- which Postgres computes before any CHECK constraint would run.
    timezone                 text        NOT NULL,
    -- The user-local calendar day of worn_at. What History shows.
    logged_on                date        NOT NULL GENERATED ALWAYS AS (local_date(worn_at, timezone)) STORED,
    created_at               timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT outfits_idempotency_key_nonempty
        CHECK (idempotency_key <> ''),
    CONSTRAINT outfits_idempotency_key_key
        UNIQUE (user_id, idempotency_key),
    CONSTRAINT outfits_history_photo_key_key
        UNIQUE (history_photo_key)
);

CREATE UNIQUE INDEX outfits_from_observed_fit_id_key
    ON outfits (from_observed_fit_id) WHERE from_observed_fit_id IS NOT NULL;

CREATE INDEX outfits_from_suggested_outfit_id_idx
    ON outfits (from_suggested_outfit_id);

CREATE INDEX outfits_user_logged_on_idx ON outfits (user_id, logged_on DESC);

CREATE INDEX outfits_user_worn_at_idx ON outfits (user_id, worn_at DESC);


-- One garment in an outfit; also the record of a wear. A garment that
-- appears here cannot be hard-deleted: soft-delete it instead.
CREATE TABLE outfit_items (
    outfit_id      uuid        NOT NULL REFERENCES outfits (id) ON DELETE CASCADE,
    -- NO ACTION rather than CASCADE so history never silently loses an item.
    -- Deferred rather than immediate because deleting a user cascades to
    -- garments before outfits, and an immediate check would fail mid-cascade
    -- while the outfit_items rows still exist. The price is that an illegal
    -- hard delete of a worn garment errors at COMMIT; a transaction can run
    -- SET CONSTRAINTS ALL IMMEDIATE to get the error at the statement.
    garment_id     uuid        NOT NULL REFERENCES garments (id)
                               ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED,
    -- The slot this garment played in this outfit. NULL when unknown; the
    -- garment's own role is the default.
    role           outfit_role,
    -- Layer order within the role, 1 innermost. Requires role.
    layer_position smallint,
    created_at     timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (outfit_id, garment_id),
    CONSTRAINT outfit_items_layer_position_positive
        CHECK (layer_position IS NULL OR layer_position >= 1),
    CONSTRAINT outfit_items_layer_requires_role
        CHECK (layer_position IS NULL OR role IS NOT NULL)
);

CREATE INDEX outfit_items_garment_id_idx ON outfit_items (garment_id);


-- A garment was washed. Wears since wash = outfit_items whose outfit's
-- worn_at is after the latest washed_at.
CREATE TABLE wash_events (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    garment_id uuid        NOT NULL REFERENCES garments (id) ON DELETE CASCADE,
    washed_at  timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX wash_events_garment_washed_at_idx
    ON wash_events (garment_id, washed_at DESC);


-- -----------------------------------------------------------------------------
-- Style profile
-- -----------------------------------------------------------------------------

-- Rules the assistant follows. Hard rules are structured and applied by
-- code; notes are free text injected into the assistant's prompt.
CREATE TABLE style_profiles (
    user_id                 uuid               PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    excluded_categories     garment_category[] NOT NULL DEFAULT '{}',
    excluded_color_families color_family[]     NOT NULL DEFAULT '{}',
    notes                   text[]             NOT NULL DEFAULT '{}',
    created_at              timestamptz        NOT NULL DEFAULT now(),
    updated_at              timestamptz        NOT NULL DEFAULT now()
);


-- Garments the user never wants suggested. A join table rather than an id
-- array so a deleted garment cannot leave a dangling exclusion.
CREATE TABLE style_profile_excluded_garments (
    user_id    uuid        NOT NULL REFERENCES style_profiles (user_id) ON DELETE CASCADE,
    garment_id uuid        NOT NULL REFERENCES garments (id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (user_id, garment_id)
);

CREATE INDEX style_profile_excluded_garments_garment_id_idx
    ON style_profile_excluded_garments (garment_id);


-- -----------------------------------------------------------------------------
-- Privacy audit
-- -----------------------------------------------------------------------------

-- Every image that left the backend for an inference provider, with when and
-- why. Shown on the privacy page. Append-only for users; the row's
-- created_at is the send time.
CREATE TABLE image_audit_log (
    id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid          NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    -- The fit the image belonged to, for fit-check images.
    observed_fit_id uuid          REFERENCES observed_fits (id) ON DELETE SET NULL,
    -- The garment, for catalog photos sent to the segmentation fallback.
    garment_id      uuid          REFERENCES garments (id) ON DELETE SET NULL,
    -- The mirror that captured it, for raw frames.
    device_id       uuid          REFERENCES devices (id) ON DELETE SET NULL,
    image_kind      image_kind    NOT NULL,
    purpose         image_purpose NOT NULL,
    -- Provider identifier as configured in code.
    provider        text          NOT NULL,
    created_at      timestamptz   NOT NULL DEFAULT now(),

    CONSTRAINT image_audit_log_provider_nonempty
        CHECK (provider <> '')
);

CREATE INDEX image_audit_log_user_created_idx
    ON image_audit_log (user_id, created_at DESC);

CREATE INDEX image_audit_log_observed_fit_id_idx ON image_audit_log (observed_fit_id);

CREATE INDEX image_audit_log_garment_id_idx ON image_audit_log (garment_id);

CREATE INDEX image_audit_log_device_id_idx ON image_audit_log (device_id);


-- -----------------------------------------------------------------------------
-- Triggers
-- -----------------------------------------------------------------------------

CREATE FUNCTION set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END
$$;

CREATE TRIGGER users_set_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER garments_set_updated_at
    BEFORE UPDATE ON garments
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER style_profiles_set_updated_at
    BEFORE UPDATE ON style_profiles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- An embedding must have the dimension its model is registered with.
CREATE FUNCTION check_embedding_dims() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    expected integer;
BEGIN
    SELECT dims INTO expected FROM embedding_models WHERE name = NEW.model;
    IF expected IS NULL THEN
        RAISE EXCEPTION 'unknown embedding model %', NEW.model
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF vector_dims(NEW.embedding) <> expected THEN
        RAISE EXCEPTION 'embedding for model % has % dimensions, expected %',
            NEW.model, vector_dims(NEW.embedding), expected
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER exemplar_embeddings_check_dims
    BEFORE INSERT OR UPDATE OF model, embedding ON exemplar_embeddings
    FOR EACH ROW EXECUTE FUNCTION check_embedding_dims();


-- -----------------------------------------------------------------------------
-- Row-level security
-- -----------------------------------------------------------------------------
-- One policy per table. USING walks parent keys up to the user. WITH CHECK
-- does the same and additionally proves every cross-tree reference belongs
-- to the same user, because foreign-key checks do not go through RLS.
-- The owns_* helpers run as the caller, so their lookups are themselves
-- filtered by the parent table's policy.

CREATE FUNCTION owns_device(d uuid) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$ SELECT EXISTS (SELECT 1 FROM devices WHERE id = d AND user_id = vird_user_id()) $$;

CREATE FUNCTION owns_garment(g uuid) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$ SELECT EXISTS (SELECT 1 FROM garments WHERE id = g AND user_id = vird_user_id()) $$;

CREATE FUNCTION owns_exemplar(e uuid) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
    SELECT EXISTS (
        SELECT 1
        FROM garment_exemplars x
        JOIN garments g ON g.id = x.garment_id
        WHERE x.id = e AND g.user_id = vird_user_id())
$$;

CREATE FUNCTION owns_observed_fit(f uuid) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$ SELECT EXISTS (SELECT 1 FROM observed_fits WHERE id = f AND user_id = vird_user_id()) $$;

CREATE FUNCTION owns_candidate(c uuid) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
    SELECT EXISTS (
        SELECT 1
        FROM recognition_candidates rc
        JOIN observed_fits f ON f.id = rc.observed_fit_id
        WHERE rc.id = c AND f.user_id = vird_user_id())
$$;

CREATE FUNCTION owns_outfit(o uuid) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$ SELECT EXISTS (SELECT 1 FROM outfits WHERE id = o AND user_id = vird_user_id()) $$;

CREATE FUNCTION owns_suggestion(s uuid) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$ SELECT EXISTS (SELECT 1 FROM suggestions WHERE id = s AND user_id = vird_user_id()) $$;

CREATE FUNCTION owns_suggested_outfit(so uuid) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
    SELECT EXISTS (
        SELECT 1
        FROM suggested_outfits x
        JOIN suggestions s ON s.id = x.suggestion_id
        WHERE x.id = so AND s.user_id = vird_user_id())
$$;


ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE users FORCE ROW LEVEL SECURITY;
CREATE POLICY users_self ON users
    FOR ALL
    USING (id = vird_user_id())
    WITH CHECK (id = vird_user_id());

ALTER TABLE devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE devices FORCE ROW LEVEL SECURITY;
CREATE POLICY devices_owner ON devices
    FOR ALL
    USING (user_id = vird_user_id())
    WITH CHECK (user_id = vird_user_id());

ALTER TABLE garments ENABLE ROW LEVEL SECURITY;
ALTER TABLE garments FORCE ROW LEVEL SECURITY;
CREATE POLICY garments_owner ON garments
    FOR ALL
    USING (user_id = vird_user_id())
    WITH CHECK (user_id = vird_user_id());

ALTER TABLE garment_exemplars ENABLE ROW LEVEL SECURITY;
ALTER TABLE garment_exemplars FORCE ROW LEVEL SECURITY;
CREATE POLICY garment_exemplars_owner ON garment_exemplars
    FOR ALL
    USING (owns_garment(garment_id))
    WITH CHECK (owns_garment(garment_id)
        AND (candidate_id IS NULL OR owns_candidate(candidate_id)));

ALTER TABLE embedding_models ENABLE ROW LEVEL SECURITY;
ALTER TABLE embedding_models FORCE ROW LEVEL SECURITY;
CREATE POLICY embedding_models_read ON embedding_models
    FOR SELECT
    USING (true);

ALTER TABLE exemplar_embeddings ENABLE ROW LEVEL SECURITY;
ALTER TABLE exemplar_embeddings FORCE ROW LEVEL SECURITY;
CREATE POLICY exemplar_embeddings_owner ON exemplar_embeddings
    FOR ALL
    USING (owns_exemplar(exemplar_id))
    WITH CHECK (owns_exemplar(exemplar_id));

ALTER TABLE observed_fits ENABLE ROW LEVEL SECURITY;
ALTER TABLE observed_fits FORCE ROW LEVEL SECURITY;
CREATE POLICY observed_fits_owner ON observed_fits
    FOR ALL
    USING (user_id = vird_user_id())
    WITH CHECK (user_id = vird_user_id()
        AND (device_id IS NULL OR owns_device(device_id)));

ALTER TABLE analysis_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE analysis_assets FORCE ROW LEVEL SECURITY;
CREATE POLICY analysis_assets_owner ON analysis_assets
    FOR ALL
    USING (owns_observed_fit(observed_fit_id))
    WITH CHECK (owns_observed_fit(observed_fit_id));

ALTER TABLE recognition_candidates ENABLE ROW LEVEL SECURITY;
ALTER TABLE recognition_candidates FORCE ROW LEVEL SECURITY;
CREATE POLICY recognition_candidates_owner ON recognition_candidates
    FOR ALL
    USING (owns_observed_fit(observed_fit_id))
    WITH CHECK (owns_observed_fit(observed_fit_id)
        AND (analysis_asset_id IS NULL OR EXISTS (
                SELECT 1 FROM analysis_assets a
                WHERE a.id = analysis_asset_id
                  AND a.observed_fit_id = recognition_candidates.observed_fit_id))
        AND (best_match_garment_id IS NULL OR owns_garment(best_match_garment_id))
        AND (resolved_garment_id IS NULL OR owns_garment(resolved_garment_id)));

ALTER TABLE recognition_alternatives ENABLE ROW LEVEL SECURITY;
ALTER TABLE recognition_alternatives FORCE ROW LEVEL SECURITY;
CREATE POLICY recognition_alternatives_owner ON recognition_alternatives
    FOR ALL
    USING (owns_candidate(candidate_id))
    WITH CHECK (owns_candidate(candidate_id) AND owns_garment(garment_id));

ALTER TABLE corrections ENABLE ROW LEVEL SECURITY;
ALTER TABLE corrections FORCE ROW LEVEL SECURITY;
CREATE POLICY corrections_owner ON corrections
    FOR ALL
    USING (owns_candidate(candidate_id))
    WITH CHECK (owns_candidate(candidate_id)
        AND (from_garment_id IS NULL OR owns_garment(from_garment_id))
        AND (to_garment_id IS NULL OR owns_garment(to_garment_id)));

ALTER TABLE suggestions ENABLE ROW LEVEL SECURITY;
ALTER TABLE suggestions FORCE ROW LEVEL SECURITY;
CREATE POLICY suggestions_owner ON suggestions
    FOR ALL
    USING (user_id = vird_user_id())
    WITH CHECK (user_id = vird_user_id());

ALTER TABLE suggested_outfits ENABLE ROW LEVEL SECURITY;
ALTER TABLE suggested_outfits FORCE ROW LEVEL SECURITY;
CREATE POLICY suggested_outfits_owner ON suggested_outfits
    FOR ALL
    USING (owns_suggestion(suggestion_id))
    WITH CHECK (owns_suggestion(suggestion_id));

ALTER TABLE suggested_outfit_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE suggested_outfit_items FORCE ROW LEVEL SECURITY;
CREATE POLICY suggested_outfit_items_owner ON suggested_outfit_items
    FOR ALL
    USING (owns_suggested_outfit(suggested_outfit_id))
    WITH CHECK (owns_suggested_outfit(suggested_outfit_id) AND owns_garment(garment_id));

ALTER TABLE recommendation_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE recommendation_events FORCE ROW LEVEL SECURITY;
CREATE POLICY recommendation_events_owner ON recommendation_events
    FOR ALL
    USING (owns_suggested_outfit(suggested_outfit_id))
    WITH CHECK (owns_suggested_outfit(suggested_outfit_id));

ALTER TABLE outfits ENABLE ROW LEVEL SECURITY;
ALTER TABLE outfits FORCE ROW LEVEL SECURITY;
CREATE POLICY outfits_owner ON outfits
    FOR ALL
    USING (user_id = vird_user_id())
    WITH CHECK (user_id = vird_user_id()
        AND (from_observed_fit_id IS NULL OR owns_observed_fit(from_observed_fit_id))
        AND (from_suggested_outfit_id IS NULL OR owns_suggested_outfit(from_suggested_outfit_id)));

ALTER TABLE outfit_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE outfit_items FORCE ROW LEVEL SECURITY;
CREATE POLICY outfit_items_owner ON outfit_items
    FOR ALL
    USING (owns_outfit(outfit_id))
    WITH CHECK (owns_outfit(outfit_id) AND owns_garment(garment_id));

ALTER TABLE wash_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE wash_events FORCE ROW LEVEL SECURITY;
CREATE POLICY wash_events_owner ON wash_events
    FOR ALL
    USING (owns_garment(garment_id))
    WITH CHECK (owns_garment(garment_id));

ALTER TABLE style_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE style_profiles FORCE ROW LEVEL SECURITY;
CREATE POLICY style_profiles_owner ON style_profiles
    FOR ALL
    USING (user_id = vird_user_id())
    WITH CHECK (user_id = vird_user_id());

ALTER TABLE style_profile_excluded_garments ENABLE ROW LEVEL SECURITY;
ALTER TABLE style_profile_excluded_garments FORCE ROW LEVEL SECURITY;
CREATE POLICY style_profile_excluded_garments_owner ON style_profile_excluded_garments
    FOR ALL
    USING (user_id = vird_user_id())
    WITH CHECK (user_id = vird_user_id() AND owns_garment(garment_id));

-- Users can read and append their audit log, never edit or delete it.
-- Account deletion still removes it through the users cascade, which
-- bypasses RLS.
ALTER TABLE image_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE image_audit_log FORCE ROW LEVEL SECURITY;
CREATE POLICY image_audit_log_read ON image_audit_log
    FOR SELECT
    USING (user_id = vird_user_id());
CREATE POLICY image_audit_log_append ON image_audit_log
    FOR INSERT
    WITH CHECK (user_id = vird_user_id()
        AND (observed_fit_id IS NULL OR owns_observed_fit(observed_fit_id))
        AND (garment_id IS NULL OR owns_garment(garment_id))
        AND (device_id IS NULL OR owns_device(device_id)));
