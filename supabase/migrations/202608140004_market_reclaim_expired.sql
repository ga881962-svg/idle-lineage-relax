-- Return every expired active marketplace listing to its original character.
-- This is intentionally a narrow compatibility migration: browse/list/buy
-- already call player_market_reclaim_expired(), but the function itself was
-- missing from the deployed migration chain.
begin;

create or replace function public.player_market_reclaim_expired()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_listing public.player_market_listings;
  v_state jsonb;
  v_inventory jsonb;
  v_revision bigint;
  v_reclaimed integer := 0;
begin
  -- Lock each listing before touching its checkpoint. SKIP LOCKED makes
  -- concurrent browse/list/buy calls harmless: only one transaction can
  -- return a particular expired item.
  for v_listing in
    select *
      from public.player_market_listings
     where status = 'active'
       and expires_at <= now()
     for update skip locked
  loop
    select state, revision
      into v_state, v_revision
      from public.character_checkpoints
     where character_id = v_listing.seller_character_id
     for update;

    -- Do not mark an order expired if its original checkpoint is absent;
    -- preserving the listing is safer than silently losing its item.
    if v_state is null then
      continue;
    end if;

    v_inventory := coalesce(v_state #> '{p,inv}', '[]'::jsonb)
      || jsonb_build_array(v_listing.item);
    v_revision := v_revision + 1;

    update public.character_checkpoints
       set state = jsonb_set(v_state, '{p,inv}', v_inventory, true),
           revision = v_revision,
           saved_at = now()
     where character_id = v_listing.seller_character_id;

    update public.player_market_listings
       set status = 'expired'
     where id = v_listing.id;

    v_reclaimed := v_reclaimed + 1;
  end loop;

  return v_reclaimed;
end;
$$;

revoke all on function public.player_market_reclaim_expired() from public;

commit;
