-- Refresh, rather than bypass, the deterministic fixture session immediately
-- before the two independent connections start. This satisfies both deployed
-- generations of assert_active_game_session: legacy last_seen_at freshness and
-- current expires_at validity.
do $$
begin
  update public.game_account_sessions
     set last_seen_at=now(), expires_at=now()+interval '15 minutes', invalidated_at=null
  where user_id='11111111-1111-4111-8111-111111111111'
     and session_token='aaaaaaaa-0000-4000-8000-000000000001';
  if not found then raise exception 'PHASE0_FIXTURE_SESSION_MISSING'; end if;
  perform set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
  perform public.assert_active_game_session('aaaaaaaa-0000-4000-8000-000000000001');
end $$;
