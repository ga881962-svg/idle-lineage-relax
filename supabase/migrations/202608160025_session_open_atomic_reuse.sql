-- Keep the Session v19 rule while making same-device session.open atomic.
-- One account still has one active session; a concurrent same-device open
-- receives the existing token instead of replacing it.
create or replace function public.open_game_account_session(
  p_device_id uuid,
  p_session_token uuid,
  p_ip_hash text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_token uuid;
begin
  if auth.uid() is null then raise exception 'SESSION_REQUIRED'; end if;
  if p_device_id is null or p_session_token is null then raise exception 'INVALID_SESSION_OPEN'; end if;
  insert into public.game_account_sessions as s (user_id,session_token,device_id,ip_hash,issued_at,last_seen_at,expires_at,invalidated_at)
  values (auth.uid(),p_session_token,p_device_id,p_ip_hash,now(),now(),now()+interval '15 minutes',null)
  on conflict (user_id) do update
    set session_token = case when s.device_id=excluded.device_id and s.invalidated_at is null and s.expires_at>now() then s.session_token else excluded.session_token end,
        device_id = case when s.device_id=excluded.device_id and s.invalidated_at is null and s.expires_at>now() then s.device_id else excluded.device_id end,
        ip_hash = case when s.device_id=excluded.device_id and s.invalidated_at is null and s.expires_at>now() then s.ip_hash else excluded.ip_hash end,
        issued_at = case when s.device_id=excluded.device_id and s.invalidated_at is null and s.expires_at>now() then s.issued_at else excluded.issued_at end,
        last_seen_at=now(), expires_at=now()+interval '15 minutes', invalidated_at=null
  returning session_token into v_token;
  return jsonb_build_object('sessionToken',v_token,'reused',v_token<>p_session_token);
end;
$$;
revoke all on function public.open_game_account_session(uuid,uuid,text) from public, anon;
grant execute on function public.open_game_account_session(uuid,uuid,text) to authenticated;
