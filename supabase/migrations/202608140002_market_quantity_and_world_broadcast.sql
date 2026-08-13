-- Compatible marketplace quantity/unit-price upgrade and ephemeral world chat.
-- This migration only adds metadata and replaces RPC functions. It does not
-- delete checkpoints, wallets, listings, or the legacy world_messages table.
begin;

alter table public.player_market_listings
  add column if not exists quantity integer,
  add column if not exists unit_price_diamonds integer,
  add column if not exists pricing_version smallint not null default 2;

-- Existing listings were historically whole-item bundles. Keep their original
-- total price untouched and represent them as one legacy bundle, so no seller
-- is charged differently and no item count is discarded.
update public.player_market_listings
set quantity = coalesce(quantity, 1),
    unit_price_diamonds = coalesce(unit_price_diamonds, price_diamonds),
    pricing_version = coalesce(pricing_version, 1)
where quantity is null or unit_price_diamonds is null;

alter table public.player_market_listings
  alter column quantity set default 1,
  alter column quantity set not null,
  alter column unit_price_diamonds set default 1,
  alter column unit_price_diamonds set not null;

alter table public.player_market_listings
  drop constraint if exists player_market_listings_quantity_check,
  add constraint player_market_listings_quantity_check check (quantity >= 1 and quantity <= 99999),
  drop constraint if exists player_market_listings_unit_price_check,
  add constraint player_market_listings_unit_price_check check (unit_price_diamonds >= 1 and unit_price_diamonds <= 999999);

create index if not exists player_market_seller_active_expiry_idx
  on public.player_market_listings(seller_user_id, status, expires_at);

-- Browse needs a new result shape. Keep the old RPC intact for an already-open
-- client, and introduce a versioned RPC for the new page instead of dropping
-- an existing database function.
create or replace function public.secure_market_browse_v2(p_session_token uuid, p_character_id uuid)
returns table(
  id uuid,
  item jsonb,
  quantity integer,
  unit_price_diamonds integer,
  price_diamonds integer,
  created_at timestamptz,
  expires_at timestamptz,
  source text,
  is_own boolean
)
language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_active_game_session(p_session_token);
  if not exists (select 1 from public.player_characters where id = p_character_id and user_id = auth.uid()) then
    raise exception 'CHARACTER_NOT_FOUND';
  end if;
  perform public.player_market_reclaim_expired();
  return query
    select m.id, m.item, m.quantity, m.unit_price_diamonds, m.price_diamonds,
      m.created_at, m.expires_at, 'S1'::text, (m.seller_user_id = auth.uid())
    from public.player_market_listings m
    -- Personal listings have their own tab.  Keeping them out of Browse also
    -- prevents an accidental attempt to purchase one's own order.
    where m.status = 'active' and m.expires_at > now()
      and m.seller_user_id <> auth.uid()
    order by m.created_at desc
    limit 100;
end;
$$;

create or replace function public.secure_market_mine(p_session_token uuid, p_character_id uuid)
returns table(
  id uuid,
  item jsonb,
  quantity integer,
  unit_price_diamonds integer,
  price_diamonds integer,
  created_at timestamptz,
  expires_at timestamptz,
  source text,
  is_own boolean
)
language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_active_game_session(p_session_token);
  if not exists (select 1 from public.player_characters where id = p_character_id and user_id = auth.uid()) then
    raise exception 'CHARACTER_NOT_FOUND';
  end if;
  perform public.player_market_reclaim_expired();
  return query
    select m.id, m.item, m.quantity, m.unit_price_diamonds, m.price_diamonds,
      m.created_at, m.expires_at, 'S1'::text, true
    from public.player_market_listings m
    where m.seller_user_id = auth.uid() and m.status = 'active' and m.expires_at > now()
    order by m.created_at desc;
end;
$$;

-- This is a six-argument overload. The previous five-argument RPC remains
-- available for already loaded clients until the frontend cache expires.
create function public.secure_market_list(
  p_session_token uuid,
  p_character_id uuid,
  p_item_uid text,
  p_quantity integer,
  p_unit_price integer,
  p_request_id uuid
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_state jsonb;
  v_inv jsonb;
  v_item jsonb;
  v_listing_item jsonb;
  v_new_inv jsonb;
  v_revision bigint;
  v_gold bigint;
  v_available integer;
  v_total bigint;
  v_listing public.player_market_listings;
  v_existing jsonb;
begin
  perform public.assert_active_game_session(p_session_token);
  perform public.player_market_reclaim_expired();
  if p_request_id is null then raise exception 'REQUEST_ID_REQUIRED'; end if;
  select payload into v_existing from public.character_event_log
    where character_id = p_character_id and request_id = p_request_id;
  if v_existing is not null then return v_existing; end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 99999 then raise exception 'INVALID_QUANTITY'; end if;
  if p_unit_price is null or p_unit_price < 1 or p_unit_price > 999999 then raise exception 'INVALID_UNIT_PRICE'; end if;
  v_total := p_quantity::bigint * p_unit_price::bigint;
  if v_total > 999999999 then raise exception 'TOTAL_PRICE_TOO_HIGH'; end if;
  if p_item_uid is null or char_length(p_item_uid) < 3 then raise exception 'INVALID_ITEM'; end if;
  if not exists (select 1 from public.player_characters c where c.id = p_character_id and c.user_id = auth.uid()) then
    raise exception 'CHARACTER_NOT_FOUND';
  end if;
  if (select count(*) from public.player_market_listings where seller_user_id = auth.uid() and status = 'active' and expires_at > now()) >= 20 then
    raise exception 'ACTIVE_LISTING_LIMIT';
  end if;
  select state, revision into v_state, v_revision from public.character_checkpoints
    where character_id = p_character_id for update;
  if v_state is null then raise exception 'CHARACTER_NEEDS_FIRST_SAVE'; end if;
  v_gold := coalesce((v_state #>> '{p,gold}')::bigint, 0);
  if v_gold < 100000 then raise exception 'LISTING_FEE_REQUIRED'; end if;
  v_inv := coalesce(v_state #> '{p,inv}', '[]'::jsonb);
  select value into v_item from jsonb_array_elements(v_inv) value
    where value ->> 'uid' = p_item_uid limit 1;
  if v_item is null then raise exception 'ITEM_NOT_FOUND'; end if;
  if coalesce((v_item ->> 'lock')::boolean, false) then raise exception 'ITEM_LOCKED'; end if;
  -- Inventory from early saves can contain a missing or non-numeric stack
  -- field. Treat that safely as one independent item rather than letting a
  -- malformed client value break the whole transaction.
  v_available := greatest(1, coalesce(
    case when coalesce(v_item ->> 'cnt', '') ~ '^[0-9]+$' then (v_item ->> 'cnt')::integer end,
    case when coalesce(v_item ->> 'count', '') ~ '^[0-9]+$' then (v_item ->> 'count')::integer end,
    1
  ));
  if p_quantity > v_available then raise exception 'QUANTITY_EXCEEDS_INVENTORY'; end if;

  -- Split only stackable entries. Independent equipment has one uid and an
  -- available quantity of one, so it cannot be accidentally merged or copied.
  v_listing_item := jsonb_set(v_item, '{cnt}', to_jsonb(p_quantity), true);
  if p_quantity < v_available then
    v_listing_item := jsonb_set(v_listing_item, '{uid}', to_jsonb('market-' || gen_random_uuid()::text), true);
    select coalesce(jsonb_agg(
      case when value ->> 'uid' = p_item_uid
        then jsonb_set(value, '{cnt}', to_jsonb(v_available - p_quantity), true)
        else value end order by ord
    ), '[]'::jsonb) into v_new_inv
    from jsonb_array_elements(v_inv) with ordinality x(value, ord);
  else
    select coalesce(jsonb_agg(value order by ord), '[]'::jsonb) into v_new_inv
    from jsonb_array_elements(v_inv) with ordinality x(value, ord)
    where value ->> 'uid' <> p_item_uid;
  end if;

  v_revision := v_revision + 1;
  update public.character_checkpoints
    set state = jsonb_set(jsonb_set(v_state, '{p,inv}', v_new_inv, true), '{p,gold}', to_jsonb(v_gold - 100000), true),
        revision = v_revision, saved_at = now()
    where character_id = p_character_id;
  insert into public.player_market_listings(
    seller_user_id, seller_character_id, seller_name, item, quantity,
    unit_price_diamonds, price_diamonds, pricing_version, expires_at, listing_fee_gold
  ) values (
    auth.uid(), p_character_id, 'S1', v_listing_item, p_quantity,
    p_unit_price, v_total::integer, 2, now() + interval '7 days', 100000
  ) returning * into v_listing;
  v_existing := jsonb_build_object('listing_id', v_listing.id, 'revision', v_revision, 'expires_at', v_listing.expires_at);
  insert into public.character_event_log(character_id, event_type, request_id, payload)
    values (p_character_id, 'market_list', p_request_id,
      v_existing || jsonb_build_object('item', v_listing_item, 'quantity', p_quantity,
      'unit_price_diamonds', p_unit_price, 'price_diamonds', v_total, 'fee_gold', 100000));
  return v_existing;
end;
$$;

-- Buy, cancel and expiry keep every order atomic. The item JSONB stored on an
-- order already contains exactly the ordered stack quantity.
create or replace function public.secure_market_buy(
  p_session_token uuid, p_character_id uuid, p_listing_id uuid, p_request_id uuid
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_listing public.player_market_listings;
  v_state jsonb;
  v_inv jsonb;
  v_revision bigint;
  v_balance integer;
  v_existing jsonb;
begin
  perform public.assert_active_game_session(p_session_token);
  perform public.player_market_reclaim_expired();
  if p_request_id is null then raise exception 'REQUEST_ID_REQUIRED'; end if;
  select payload into v_existing from public.character_event_log where character_id = p_character_id and request_id = p_request_id;
  if v_existing is not null then return v_existing; end if;
  if not exists (select 1 from public.player_characters where id = p_character_id and user_id = auth.uid()) then raise exception 'CHARACTER_NOT_FOUND'; end if;
  select * into v_listing from public.player_market_listings where id = p_listing_id for update;
  if v_listing.id is null or v_listing.status <> 'active' or v_listing.expires_at <= now() then raise exception 'LISTING_UNAVAILABLE'; end if;
  if v_listing.seller_user_id = auth.uid() then raise exception 'CANNOT_BUY_OWN_LISTING'; end if;
  insert into public.account_wallets(user_id, sponsor_diamonds)
    values (auth.uid(), 0), (v_listing.seller_user_id, 0) on conflict (user_id) do nothing;
  select sponsor_diamonds into v_balance from public.account_wallets where user_id = auth.uid() for update;
  if coalesce(v_balance, 0) < v_listing.price_diamonds then raise exception 'INSUFFICIENT_DIAMONDS'; end if;
  perform 1 from public.account_wallets where user_id = v_listing.seller_user_id for update;
  select state, revision into v_state, v_revision from public.character_checkpoints where character_id = p_character_id for update;
  if v_state is null then raise exception 'CHARACTER_NEEDS_FIRST_SAVE'; end if;
  v_inv := coalesce(v_state #> '{p,inv}', '[]'::jsonb) || jsonb_build_array(v_listing.item);
  v_revision := v_revision + 1;
  update public.character_checkpoints set state = jsonb_set(v_state, '{p,inv}', v_inv, true), revision = v_revision, saved_at = now()
    where character_id = p_character_id;
  update public.account_wallets set sponsor_diamonds = sponsor_diamonds - v_listing.price_diamonds, updated_at = now() where user_id = auth.uid();
  update public.account_wallets set sponsor_diamonds = sponsor_diamonds + v_listing.price_diamonds, updated_at = now() where user_id = v_listing.seller_user_id;
  update public.player_market_listings set status = 'sold', buyer_user_id = auth.uid(), buyer_character_id = p_character_id, sold_at = now() where id = p_listing_id;
  v_existing := jsonb_build_object('item', v_listing.item, 'quantity', v_listing.quantity, 'revision', v_revision,
    'buyer_balance', v_balance - v_listing.price_diamonds);
  insert into public.character_event_log(character_id, event_type, request_id, payload)
    values (p_character_id, 'market_buy', p_request_id, v_existing || jsonb_build_object('listing_id', p_listing_id, 'price_diamonds', v_listing.price_diamonds));
  return v_existing;
end;
$$;

create or replace function public.secure_market_cancel(
  p_session_token uuid, p_character_id uuid, p_listing_id uuid, p_request_id uuid
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_listing public.player_market_listings;
  v_state jsonb;
  v_inv jsonb;
  v_revision bigint;
  v_existing jsonb;
begin
  perform public.assert_active_game_session(p_session_token);
  if p_request_id is null then raise exception 'REQUEST_ID_REQUIRED'; end if;
  select payload into v_existing from public.character_event_log where character_id = p_character_id and request_id = p_request_id;
  if v_existing is not null then return v_existing; end if;
  select * into v_listing from public.player_market_listings where id = p_listing_id for update;
  if v_listing.id is null or v_listing.status <> 'active' or v_listing.seller_user_id <> auth.uid() then raise exception 'LISTING_NOT_CANCELLABLE'; end if;
  if v_listing.seller_character_id <> p_character_id then raise exception 'RETURN_TO_ORIGINAL_CHARACTER'; end if;
  select state, revision into v_state, v_revision from public.character_checkpoints where character_id = p_character_id for update;
  if v_state is null then raise exception 'CHARACTER_CHECKPOINT_NOT_FOUND'; end if;
  v_inv := coalesce(v_state #> '{p,inv}', '[]'::jsonb) || jsonb_build_array(v_listing.item);
  v_revision := v_revision + 1;
  update public.character_checkpoints set state = jsonb_set(v_state, '{p,inv}', v_inv, true), revision = v_revision, saved_at = now()
    where character_id = p_character_id;
  update public.player_market_listings set status = 'cancelled', cancelled_at = now() where id = p_listing_id;
  v_existing := jsonb_build_object('item', v_listing.item, 'quantity', v_listing.quantity, 'revision', v_revision);
  insert into public.character_event_log(character_id, event_type, request_id, payload)
    values (p_character_id, 'market_cancel', p_request_id, v_existing || jsonb_build_object('listing_id', p_listing_id));
  return v_existing;
end;
$$;

grant execute on function public.secure_market_browse_v2(uuid, uuid) to authenticated;
grant execute on function public.secure_market_mine(uuid, uuid) to authenticated;
grant execute on function public.secure_market_list(uuid, uuid, text, integer, integer, uuid) to authenticated;
grant execute on function public.secure_market_buy(uuid, uuid, uuid, uuid) to authenticated;
grant execute on function public.secure_market_cancel(uuid, uuid, uuid, uuid) to authenticated;

-- World chat: no text is ever inserted into public.world_messages. This table
-- only stores a cooldown timestamp and does not contain chat content/history.
create table if not exists public.world_chat_rate_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_sent_at timestamptz not null default to_timestamp(0)
);
alter table public.world_chat_rate_limits enable row level security;
revoke all on table public.world_chat_rate_limits from anon, authenticated;

create or replace function public.consume_world_chat_cooldown(p_user_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_allowed boolean := false;
begin
  if p_user_id is null or auth.uid() <> p_user_id then raise exception 'AUTH_REQUIRED'; end if;
  insert into public.world_chat_rate_limits(user_id, last_sent_at)
    values (p_user_id, now())
    on conflict (user_id) do update set last_sent_at = excluded.last_sent_at
      where public.world_chat_rate_limits.last_sent_at <= now() - interval '2 seconds'
    returning true into v_allowed;
  return coalesce(v_allowed, false);
end;
$$;
revoke all on function public.consume_world_chat_cooldown(uuid) from public;
grant execute on function public.consume_world_chat_cooldown(uuid) to authenticated;

-- Private Realtime topic: authenticated clients can only receive world chat.
-- There is deliberately no permissive INSERT policy for world:global, so a
-- browser cannot spoof a message without first passing idle-api validation.
drop policy if exists "world broadcast receive" on realtime.messages;
create policy "world broadcast receive" on realtime.messages
  for select to authenticated
  using (realtime.topic() = 'world:global' and realtime.messages.extension = 'broadcast');
drop policy if exists "world broadcast client send denied" on realtime.messages;
create policy "world broadcast client send denied" on realtime.messages
  as restrictive for insert to authenticated
  with check (realtime.topic() <> 'world:global');

commit;
