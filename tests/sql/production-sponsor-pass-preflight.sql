-- Read-only production preflight for 202608160011_sponsor_passes_canonical.sql.
-- Do not run a migration if any required dependency is false.
select jsonb_build_object(
  'player_characters', to_regclass('public.player_characters') is not null,
  'account_wallets', to_regclass('public.account_wallets') is not null,
  'game_account_sessions', to_regclass('public.game_account_sessions') is not null,
  'assert_active_game_session', to_regprocedure('public.assert_active_game_session(uuid)') is not null,
  'sponsor_passes_existing', to_regclass('public.sponsor_passes') is not null,
  'sponsor_pass_purchases_existing', to_regclass('public.sponsor_pass_purchases') is not null,
  'sponsor_pass_status_existing', to_regprocedure('public.sponsor_pass_status(uuid,uuid)') is not null,
  'sponsor_pass_purchase_existing', to_regprocedure('public.sponsor_pass_purchase(uuid,uuid,text,uuid)') is not null,
  'migration_011_recorded', exists(
    select 1 from supabase_migrations.schema_migrations
    where version = '202608160011'
  )
) as sponsor_pass_preflight;
