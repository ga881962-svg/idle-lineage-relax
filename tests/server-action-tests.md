# Phase 0 database test matrix

Run these only in an isolated Supabase/PostgreSQL test environment.

- Same `(user, action_type, request_id, request_hash)` returns the stored completed result.
- Same request ID with another hash returns `REQUEST_ID_PAYLOAD_MISMATCH`.
- An action that fails records one deterministic `failed` response; its retry
  returns that response rather than running the mutation again.
- Concurrent same request creates one ledger row and one action result.
- `server_action_context` rejects stale checkpoint revision.
- Each disabled feature flag returns `FEATURE_DISABLED`.
- Enabled flag reads succeed without changing assets.
- Concurrent `server_migration_begin` (with valid active sessions) creates one marker; a second request is rejected while running.
- Reusing a migration request with a different source hash returns
  `MIGRATION_SOURCE_MISMATCH`.
- Completed migration returns its metadata and never accepts a second import.
- Flag rollback leaves completed marker/assets untouched.
- Conflicting actions acquire the documented order without a deadlock.
