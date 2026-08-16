-- Phase 1 checkpoint save foundation.  This replaces the never-deployed
-- character_event_log based draft with the Phase 0 action ledger.  It does
-- not make arbitrary client checkpoint state server authoritative; it only
-- makes the compatibility checkpoint write revision-safe and idempotent.

-- Browser warehouse values are legacy UI/cache data.  Once warehouse transfer
-- is server-authoritative, a generic checkpoint write must never restore or
-- replace such a mirror.  Preserve a pre-existing cache value (if any) only
-- as a server-held compatibility projection; otherwise omit it.
create or replace function public.checkpoint__preserve_warehouse_mirror(
  p_incoming jsonb,
  p_current jsonb
) returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_result jsonb;
  v_incoming_p jsonb;
  v_current_p jsonb;
  v_root_mirror jsonb;
  v_p_mirror jsonb;
begin
  if jsonb_typeof(p_incoming) <> 'object' then
    raise exception 'INVALID_CHECKPOINT_STATE';
  end if;

  v_result := p_incoming - array['warehouse','warehouseGold','warehouseItems'];
  v_incoming_p := case when jsonb_typeof(v_result->'p') = 'object'
    then (v_result->'p') - array['warehouse','warehouseGold','warehouseItems']
    else null end;
  v_current_p := case when jsonb_typeof(p_current->'p') = 'object'
    then p_current->'p' else '{}'::jsonb end;

  select coalesce(jsonb_object_agg(key,value),'{}'::jsonb)
    into v_root_mirror
    from jsonb_each(case when jsonb_typeof(p_current) = 'object' then p_current else '{}'::jsonb end)
   where key = any(array['warehouse','warehouseGold','warehouseItems']);
  select coalesce(jsonb_object_agg(key,value),'{}'::jsonb)
    into v_p_mirror
    from jsonb_each(v_current_p)
   where key = any(array['warehouse','warehouseGold','warehouseItems']);

  v_result := v_result || v_root_mirror;
  if v_incoming_p is not null then
    v_result := jsonb_set(v_result,'{p}',v_incoming_p || v_p_mirror,true);
  end if;
  return v_result;
end;
$$;

create or replace function public.checkpoint_save(
  p_session_token uuid,
  p_character_id uuid,
  p_expected_revision bigint,
  p_request_id uuid,
  p_state jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_context jsonb;
  v_mode text;
  v_checkpoint public.character_checkpoints%rowtype;
  v_known public.server_action_requests%rowtype;
  v_hash text;
  v_started jsonb;
  v_state jsonb;
  v_next_revision bigint;
  v_result jsonb;
begin
  if p_request_id is null or p_expected_revision is null or jsonb_typeof(p_state) <> 'object' then
    raise exception 'INVALID_CHECKPOINT_SAVE';
  end if;

  -- server_action_context authenticates the session, verifies ownership and
  -- holds the checkpoint row lock before this action obtains its ledger row.
  -- This is the documented lock order: session -> checkpoint -> ledger.
  v_context := public.server_action_context(p_session_token,p_character_id,null);
  v_mode := v_context->>'modeBucket';
  select * into v_checkpoint
    from public.character_checkpoints
   where character_id=p_character_id
   for update;
  if not found then
    raise exception 'CHECKPOINT_NOT_FOUND';
  end if;

  v_hash := pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        jsonb_build_object(
          'characterId',p_character_id,
          'expectedRevision',p_expected_revision,
          'state',p_state
        )::text,
        'UTF8'::name
      ),
      'sha256'::text
    ),
    'hex'::text
  );

  -- A retry is valid even though its original expected revision has already
  -- advanced.  A changed payload under the same request ID is always refused.
  select * into v_known
    from public.server_action_requests
   where user_id=auth.uid() and action_type='checkpoint.save' and request_id=p_request_id
   for update;
  if found then
    if v_known.request_hash <> v_hash then
      raise exception 'REQUEST_ID_PAYLOAD_MISMATCH';
    end if;
    if v_known.status='completed' then
      return v_known.result;
    end if;
    if v_known.status='failed' then
      raise exception '%',coalesce(v_known.error_code,'CHECKPOINT_SAVE_FAILED');
    end if;
    raise exception 'ACTION_IN_PROGRESS';
  end if;

  if v_checkpoint.revision <> p_expected_revision then
    raise exception 'CHECKPOINT_CONFLICT:%',v_checkpoint.revision;
  end if;

  v_started := public.server_action_begin(
    p_session_token,'checkpoint.save',p_request_id,v_hash,v_mode,p_character_id
  );
  if v_started->>'state'='completed' then
    return v_started->'result';
  end if;
  if v_started->>'state'='failed' then
    raise exception '%',coalesce(v_started->>'errorCode','CHECKPOINT_SAVE_FAILED');
  end if;

  v_state := public.checkpoint__preserve_warehouse_mirror(p_state,v_checkpoint.state);
  v_next_revision := public.server_action_next_revision(v_checkpoint.revision);
  update public.character_checkpoints
     set state=v_state,
         revision=v_next_revision,
         saved_at=now()
   where character_id=p_character_id;

  v_result := jsonb_build_object('revision',v_next_revision);
  perform public.server_action_complete(p_session_token,'checkpoint.save',p_request_id,v_result);
  return v_result;
end;
$$;

revoke all on function public.checkpoint__preserve_warehouse_mirror(jsonb,jsonb) from public,anon,authenticated;
revoke all on function public.checkpoint_save(uuid,uuid,bigint,uuid,jsonb) from public,anon;
grant execute on function public.checkpoint_save(uuid,uuid,bigint,uuid,jsonb) to authenticated;
