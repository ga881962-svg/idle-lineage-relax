-- Remove only deterministic Phase 0 isolated-test fixtures.
delete from public.server_action_requests
where user_id in ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222');
delete from public.server_migration_markers
where user_id in ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222');
delete from public.game_account_sessions
where user_id in ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222');
delete from auth.users
where id in ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222');
update public.server_feature_flags set enabled=false;
