-- One active game session per account.  Run through Supabase migration tooling.
alter table public.game_account_sessions
  add column if not exists expires_at timestamptz;

update public.game_account_sessions
set expires_at = coalesce(expires_at, greatest(last_seen_at, issued_at, created_at) + interval '15 minutes')
where expires_at is null;

alter table public.game_account_sessions
  alter column expires_at set default (now() + interval '15 minutes'),
  alter column expires_at set not null;

create index if not exists game_account_sessions_active_expiry_idx
  on public.game_account_sessions(user_id, session_token, expires_at)
  where invalidated_at is null;

create or replace function public.assert_active_game_session(p_session_token uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'SESSION_REQUIRED';
  end if;

  perform 1
  from public.game_account_sessions s
  where s.user_id = auth.uid()
    and s.session_token = p_session_token
    and s.invalidated_at is null
    and s.expires_at > now()
  for key share;

  if not found then
    raise exception 'SESSION_REPLACED';
  end if;
end;
$$;

create or replace function public.secure_save_character_checkpoint(
  p_session_token uuid,
  p_character_id uuid,
  p_revision bigint,
  p_state jsonb,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current_revision bigint;
  v_next_revision bigint;
  v_existing jsonb;
begin
  perform public.assert_active_game_session(p_session_token);

  if not exists (
    select 1 from public.player_characters c
    where c.id = p_character_id and c.user_id = auth.uid()
  ) then
    raise exception 'CHARACTER_NOT_FOUND';
  end if;

  select payload into v_existing
  from public.character_event_log
  where character_id = p_character_id and request_id = p_request_id;
  if v_existing is not null then
    return v_existing;
  end if;

  select revision into v_current_revision
  from public.character_checkpoints
  where character_id = p_character_id
  for update;

  if found then
    if p_revision <> v_current_revision then
      raise exception 'CHECKPOINT_CONFLICT:%', v_current_revision;
    end if;
    v_next_revision := v_current_revision + 1;
    update public.character_checkpoints
    set revision = v_next_revision, state = p_state, saved_at = now()
    where character_id = p_character_id;
  else
    if p_revision <> 0 then
      raise exception 'CHECKPOINT_CONFLICT:0';
    end if;
    v_next_revision := 1;
    insert into public.character_checkpoints(character_id, revision, state, saved_at)
    values (p_character_id, v_next_revision, p_state, now());
  end if;

  v_existing := jsonb_build_object('revision', v_next_revision);
  insert into public.character_event_log(character_id, event_type, request_id, payload)
  values (p_character_id, 'checkpoint.saved', p_request_id, v_existing);
  return v_existing;
end;
$$;

revoke all on function public.secure_save_character_checkpoint(uuid,uuid,bigint,jsonb,uuid) from public;
grant execute on function public.secure_save_character_checkpoint(uuid,uuid,bigint,jsonb,uuid) to authenticated;
