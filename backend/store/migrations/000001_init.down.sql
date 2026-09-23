-- Reverses 000001_init.up.sql. Tables go in reverse dependency order so no
-- CASCADE is needed; policies, triggers and indexes go with their tables.
-- The vector extension is not dropped: it was created outside migrations.

DROP TABLE image_audit_log;
DROP TABLE style_profile_excluded_garments;
DROP TABLE style_profiles;
DROP TABLE wash_events;
DROP TABLE outfit_items;
DROP TABLE outfits;
DROP TABLE recommendation_events;
DROP TABLE suggested_outfit_items;
DROP TABLE suggested_outfits;
DROP TABLE suggestions;
DROP TABLE corrections;
DROP TABLE recognition_alternatives;
DROP TABLE exemplar_embeddings;
DROP TABLE garment_exemplars;
DROP TABLE recognition_candidates;
DROP TABLE analysis_assets;
DROP TABLE observed_fits;
DROP TABLE embedding_models;
DROP TABLE garments;
DROP TABLE devices;
DROP TABLE users;

DROP FUNCTION owns_suggested_outfit(uuid);
DROP FUNCTION owns_suggestion(uuid);
DROP FUNCTION owns_outfit(uuid);
DROP FUNCTION owns_candidate(uuid);
DROP FUNCTION owns_observed_fit(uuid);
DROP FUNCTION owns_exemplar(uuid);
DROP FUNCTION owns_garment(uuid);
DROP FUNCTION owns_device(uuid);
DROP FUNCTION check_embedding_dims();
DROP FUNCTION set_updated_at();
DROP FUNCTION garment_role(garment_category);
DROP FUNCTION is_valid_timezone(text);
DROP FUNCTION local_date(timestamptz, text);
DROP FUNCTION vird_user_id();

DROP TYPE image_purpose;
DROP TYPE image_kind;
DROP TYPE recommendation_event_type;
DROP TYPE candidate_resolution;
DROP TYPE analysis_asset_kind;
DROP TYPE observed_fit_status;
DROP TYPE observed_fit_source;
DROP TYPE exemplar_creation_reason;
DROP TYPE capture_source;
DROP TYPE garment_material;
DROP TYPE garment_pattern;
DROP TYPE season;
DROP TYPE garment_fit;
DROP TYPE color_family;
DROP TYPE outfit_role;
DROP TYPE garment_category;
