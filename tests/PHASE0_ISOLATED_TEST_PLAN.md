# Phase 0 isolated integration verification

Use a brand-new Supabase project or `supabase start` database. Never point
these commands at the project configured in `supabase/config.toml`, which is
the current production-linked project.

## Prerequisites

1. Provision an isolated project/database and link it with the native
   credentials stored by `npx.cmd supabase login`.
2. On a fresh project, run `tests/sql/phase0-isolated-bootstrap.sql`, then run
   only the reviewed Phase-0 SQL draft
   `supabase/migrations/202608160003_server_action_foundation.sql` using
   `npx.cmd supabase db query --linked`. Do not run `db push` from this root:
   unrelated unfinished migrations are deliberately present.
3. Use the isolated project database-owner query path only for this suite. The SQL rolls all
   fixture and assertion work back; it does not touch non-test rows.

## Commands

```powershell
npx.cmd supabase db query --linked -f tests/sql/phase0-isolated-bootstrap.sql
npx.cmd supabase db query --linked -f supabase/migrations/202608160003_server_action_foundation.sql
npx.cmd supabase db query --linked -f tests/sql/phase0-foundation.sql
powershell -ExecutionPolicy Bypass -File tests/phase0-concurrency.ps1
npx.cmd supabase db query --linked -f tests/sql/phase0-isolated-cleanup.sql
```

The single-session suite covers A, B, D–M, and O. The second command uses two
independent connections for C, I, and N. A test failure stops immediately.

Before the concurrent command, set `SUPABASE_DB_PASSWORD` only in that
PowerShell process. The CLI's native login credential authenticates management
API calls, but two independent `db query` processes also need the isolated
project's database password. The harness refreshes the fake session immediately
before it starts, satisfying both `last_seen_at` and `expires_at` guards without
relaxing the production session function.

## Security inspection

Before accepting the environment, verify:

- `server_feature_flags`, `server_action_requests`, and
  `server_migration_markers` have RLS enabled and no direct authenticated/anon
  table privileges.
- Foundation functions are `SECURITY DEFINER`, set `search_path = public`, and
  are executable by `authenticated` but not `anon`/`public`.
- Edge routes call RPC with the authenticated user's JWT, not the service-role
  client: the helpers deliberately use `auth.uid()` and active-game-session
  validation. The service role remains for server administration only.

## Acceptance criteria

All A–O assertions pass on the isolated database twice, including the
concurrency run. No lock timeout/deadlock is permitted. Only then is Phase 0
eligible for a separately approved production migration; feature flags remain
off after that migration.
