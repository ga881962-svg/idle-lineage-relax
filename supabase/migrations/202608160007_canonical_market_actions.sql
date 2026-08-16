-- Online canonical market and UID ownership actions.  Legacy revocation/drop is deliberately a
-- later, separately-tested cleanup step.

create table if not exists public.server_rule_catalogs (
  catalog_key text primary key,
  version integer not null check (version > 0),
  source_hash text not null check (source_hash ~ '^[a-f0-9]{64}$'),
  payload_hash text not null check (payload_hash ~ '^[a-f0-9]{64}$'),
  payload jsonb not null,
  generated_at timestamptz not null default now()
);
alter table public.server_rule_catalogs enable row level security;
revoke all on public.server_rule_catalogs from public, anon, authenticated;

alter table public.character_asset_uid_owners
  add column if not exists market_listing_id uuid references public.player_market_listings(id) on delete cascade;
alter table public.character_asset_uid_owners drop constraint if exists character_asset_uid_owners_owner_kind_check;
alter table public.character_asset_uid_owners drop constraint if exists character_asset_uid_owners_check;
alter table public.character_asset_uid_owners drop constraint if exists character_asset_uid_owners_domain_check;
alter table public.character_asset_uid_owners add constraint character_asset_uid_owners_owner_kind_check
  check (owner_kind in ('character_inventory','account_warehouse','market_listing'));
alter table public.character_asset_uid_owners add constraint character_asset_uid_owners_domain_check check (
  (owner_kind='character_inventory' and character_id is not null and mode_bucket is null and market_listing_id is null)
  or (owner_kind='account_warehouse' and character_id is null and mode_bucket is not null and market_listing_id is null)
  or (owner_kind='market_listing' and character_id is null and mode_bucket is null and market_listing_id is not null)
);

create or replace function public.server_item_is_uid(p_item_id text)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare v_uid boolean;
begin
  select (c.payload #>> array['items', p_item_id, 'uidOwnership'])::boolean into v_uid
    from public.server_rule_catalogs c where c.catalog_key='item.classification';
  if not found or v_uid is null then raise exception 'ITEM_CLASSIFICATION_MISSING:%',coalesce(p_item_id,''); end if;
  return v_uid;
end $$;
revoke all on function public.server_item_is_uid(text) from public, anon, authenticated;

create or replace function public.asset_uid_owner_move_internal(
  p_item_uid text, p_from_kind text, p_from_user uuid, p_from_character uuid,
  p_from_mode text, p_from_listing uuid, p_to_kind text, p_to_user uuid,
  p_to_character uuid, p_to_mode text, p_to_listing uuid, p_item jsonb,
  p_allow_initial_character_claim boolean default false
) returns void language plpgsql security definer set search_path=public as $$
declare r public.character_asset_uid_owners%rowtype; v_hash text;
begin
  if coalesce(p_item_uid,'')='' or jsonb_typeof(p_item)<>'object'
     or p_from_kind not in ('character_inventory','account_warehouse','market_listing')
     or p_to_kind not in ('character_inventory','account_warehouse','market_listing') then
    raise exception 'INVALID_ASSET_UID_OWNER_MOVE';
  end if;
  if (p_from_kind='character_inventory' and (p_from_character is null or p_from_mode is not null or p_from_listing is not null))
     or (p_from_kind='account_warehouse' and (p_from_character is not null or p_from_mode not in ('normal','classic') or p_from_listing is not null))
     or (p_from_kind='market_listing' and (p_from_character is not null or p_from_mode is not null or p_from_listing is null))
     or (p_to_kind='character_inventory' and (p_to_character is null or p_to_mode is not null or p_to_listing is not null))
     or (p_to_kind='account_warehouse' and (p_to_character is not null or p_to_mode not in ('normal','classic') or p_to_listing is not null))
     or (p_to_kind='market_listing' and (p_to_character is not null or p_to_mode is not null or p_to_listing is null)) then
    raise exception 'INVALID_ASSET_UID_OWNER_DOMAIN';
  end if;
  v_hash:=pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_item::text,'UTF8'::name),'sha256'::text),'hex'::text);
  select * into r from public.character_asset_uid_owners where item_uid=p_item_uid for update;
  if not found then
    if not p_allow_initial_character_claim or p_from_kind<>'character_inventory' then
      raise exception 'ASSET_UID_OWNER_MISSING:%',p_item_uid;
    end if;
    insert into public.character_asset_uid_owners(item_uid,owner_kind,user_id,character_id,mode_bucket,market_listing_id,item_fingerprint)
      values(p_item_uid,p_to_kind,p_to_user,case when p_to_kind='character_inventory' then p_to_character end,
             case when p_to_kind='account_warehouse' then p_to_mode end,
             case when p_to_kind='market_listing' then p_to_listing end,v_hash);
    return;
  end if;
  if r.owner_kind<>p_from_kind or r.user_id<>p_from_user
     or r.character_id is distinct from p_from_character or r.mode_bucket is distinct from p_from_mode
     or r.market_listing_id is distinct from p_from_listing then
    raise exception 'ASSET_UID_ALREADY_OWNED:%',p_item_uid;
  end if;
  update public.character_asset_uid_owners set owner_kind=p_to_kind,user_id=p_to_user,
    character_id=case when p_to_kind='character_inventory' then p_to_character end,
    mode_bucket=case when p_to_kind='account_warehouse' then p_to_mode end,
    market_listing_id=case when p_to_kind='market_listing' then p_to_listing end,
    item_fingerprint=v_hash,updated_at=now() where item_uid=p_item_uid;
end $$;
revoke all on function public.asset_uid_owner_move_internal(text,text,uuid,uuid,text,uuid,text,uuid,uuid,text,uuid,jsonb,boolean) from public,anon,authenticated;

create or replace function public.market__request_hash(p_payload jsonb)
returns text language sql immutable security definer set search_path=public as $$
 select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_payload::text,'UTF8'::name),'sha256'::text),'hex'::text)
$$;
revoke all on function public.market__request_hash(jsonb) from public,anon,authenticated;

create or replace function public.market__add_item(p_inv jsonb,p_item jsonb)
returns jsonb language sql immutable set search_path=public as $$ select coalesce(p_inv,'[]'::jsonb)||jsonb_build_array(p_item) $$;

create or replace function public.secure_market_list(p_session_token uuid,p_character_id uuid,p_item_uid text,p_quantity integer,p_unit_price integer,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare c public.character_checkpoints%rowtype; v_mode text; v_hash text; v_start jsonb; v_inv jsonb; v_item jsonb; v_listing_item jsonb; l public.player_market_listings%rowtype; v_gold bigint; v_count integer; v_uid boolean; v_result jsonb;
begin
 if p_request_id is null or p_quantity<1 or p_quantity>99999 or p_unit_price<1 or p_unit_price>999999 or coalesce(p_item_uid,'')='' then raise exception 'INVALID_MARKET_LIST'; end if;
 if p_quantity::bigint*p_unit_price::bigint>2147483647 then raise exception 'TOTAL_PRICE_TOO_HIGH'; end if;
 v_mode:=public.server_action_context(p_session_token,p_character_id,null)->>'modeBucket';
 v_hash:=public.market__request_hash(jsonb_build_object('characterId',p_character_id,'itemUid',p_item_uid,'quantity',p_quantity,'unitPrice',p_unit_price));
 v_start:=public.server_action_begin(p_session_token,'market.list',p_request_id,v_hash,v_mode,p_character_id);
 if v_start->>'state'='completed' then return v_start->'result'; end if; if v_start->>'state'<>'running' then raise exception '%',coalesce(v_start->>'errorCode','MARKET_LIST_FAILED'); end if;
 select * into c from public.character_checkpoints where character_id=p_character_id for update;
 v_gold:=coalesce((c.state#>>'{p,gold}')::bigint,0); if v_gold<100000 then raise exception 'LISTING_FEE_REQUIRED'; end if;
 v_inv:=coalesce(c.state#>'{p,inv}','[]'::jsonb); select value into v_item from jsonb_array_elements(v_inv) where value->>'uid'=p_item_uid limit 1;
 if v_item is null or coalesce((v_item->>'lock')::boolean,false) then raise exception 'ITEM_NOT_LISTABLE'; end if;
 v_uid:=public.server_item_is_uid(v_item->>'id');
 v_count:=greatest(1,coalesce(nullif(v_item->>'cnt','')::integer,nullif(v_item->>'count','')::integer,1));
 if (v_uid and (p_quantity<>1 or v_count<>1)) or p_quantity>v_count then raise exception 'QUANTITY_EXCEEDS_INVENTORY'; end if;
 if p_quantity<v_count then
   v_listing_item:=jsonb_set(jsonb_set(v_item,'{uid}',to_jsonb('market-'||pg_catalog.gen_random_uuid()::text),true),'{cnt}',to_jsonb(p_quantity),true);
   select coalesce(jsonb_agg(case when value->>'uid'=p_item_uid then jsonb_set(value,'{cnt}',to_jsonb(v_count-p_quantity),true) else value end order by ord),'[]'::jsonb) into v_inv from jsonb_array_elements(v_inv) with ordinality x(value,ord);
 else
   v_listing_item:=case when v_uid then v_item else jsonb_set(v_item,'{cnt}',to_jsonb(p_quantity),true) end;
   select coalesce(jsonb_agg(value order by ord),'[]'::jsonb) into v_inv from jsonb_array_elements(v_inv) with ordinality x(value,ord) where value->>'uid'<>p_item_uid;
 end if;
 insert into public.player_market_listings(seller_user_id,seller_character_id,seller_name,item,quantity,unit_price_diamonds,price_diamonds,pricing_version,expires_at,listing_fee_gold)
 values(auth.uid(),p_character_id,'S1',v_listing_item,p_quantity,p_unit_price,(p_quantity::bigint*p_unit_price)::integer,2,now()+interval '7 days',100000) returning * into l;
 if v_uid then perform public.asset_uid_owner_move_internal(p_item_uid,'character_inventory',auth.uid(),p_character_id,null,null,'market_listing',auth.uid(),null,null,l.id,v_listing_item,true); end if;
 c.state:=jsonb_set(jsonb_set(c.state,'{p,inv}',v_inv,true),'{p,gold}',to_jsonb(v_gold-100000),true); c.revision:=public.server_action_next_revision(c.revision);
 update public.character_checkpoints set state=c.state,revision=c.revision,saved_at=now() where character_id=p_character_id;
 v_result:=jsonb_build_object('listingId',l.id,'revision',c.revision,'state',c.state,'expiresAt',l.expires_at);
 perform public.server_action_complete(p_session_token,'market.list',p_request_id,v_result); return v_result;
end $$;

create or replace function public.secure_market_buy(p_session_token uuid,p_character_id uuid,p_listing_id uuid,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare c public.character_checkpoints%rowtype; l public.player_market_listings%rowtype; v_mode text; v_hash text; v_start jsonb; v_balance integer; v_uid boolean; v_result jsonb;
begin
 if p_request_id is null or p_listing_id is null then raise exception 'INVALID_MARKET_BUY'; end if;
 v_mode:=public.server_action_context(p_session_token,p_character_id,null)->>'modeBucket'; v_hash:=public.market__request_hash(jsonb_build_object('characterId',p_character_id,'listingId',p_listing_id));
 v_start:=public.server_action_begin(p_session_token,'market.buy',p_request_id,v_hash,v_mode,p_character_id); if v_start->>'state'='completed' then return v_start->'result'; end if; if v_start->>'state'<>'running' then raise exception '%',coalesce(v_start->>'errorCode','MARKET_BUY_FAILED'); end if;
 select * into c from public.character_checkpoints where character_id=p_character_id for update; select * into l from public.player_market_listings where id=p_listing_id for update;
 if l.id is null or l.status<>'active' or l.expires_at<=now() or l.seller_user_id=auth.uid() then raise exception 'LISTING_UNAVAILABLE'; end if;
 insert into public.account_wallets(user_id,sponsor_diamonds) values(auth.uid(),0),(l.seller_user_id,0) on conflict(user_id) do nothing;
 select sponsor_diamonds into v_balance from public.account_wallets where user_id=auth.uid() for update; perform 1 from public.account_wallets where user_id=l.seller_user_id for update;
 if coalesce(v_balance,0)<l.price_diamonds then raise exception 'INSUFFICIENT_DIAMONDS'; end if;
 v_uid:=public.server_item_is_uid(l.item->>'id');
 if v_uid then perform public.asset_uid_owner_move_internal(l.item->>'uid','market_listing',l.seller_user_id,null,null,l.id,'character_inventory',auth.uid(),p_character_id,null,null,l.item,false); end if;
 c.state:=jsonb_set(c.state,'{p,inv}',public.market__add_item(c.state#>'{p,inv}',l.item),true); c.revision:=public.server_action_next_revision(c.revision);
 update public.character_checkpoints set state=c.state,revision=c.revision,saved_at=now() where character_id=p_character_id;
 update public.account_wallets set sponsor_diamonds=sponsor_diamonds-l.price_diamonds,updated_at=now() where user_id=auth.uid(); update public.account_wallets set sponsor_diamonds=sponsor_diamonds+l.price_diamonds,updated_at=now() where user_id=l.seller_user_id;
 update public.player_market_listings set status='sold',buyer_user_id=auth.uid(),buyer_character_id=p_character_id,sold_at=now() where id=p_listing_id;
 v_result:=jsonb_build_object('listingId',p_listing_id,'revision',c.revision,'state',c.state); perform public.server_action_complete(p_session_token,'market.buy',p_request_id,v_result); return v_result;
end $$;

create or replace function public.secure_market_cancel(p_session_token uuid,p_character_id uuid,p_listing_id uuid,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare c public.character_checkpoints%rowtype; l public.player_market_listings%rowtype; v_mode text; v_hash text; v_start jsonb; v_uid boolean; v_result jsonb;
begin
 if p_request_id is null or p_listing_id is null then raise exception 'INVALID_MARKET_CANCEL'; end if;
 v_mode:=public.server_action_context(p_session_token,p_character_id,null)->>'modeBucket'; v_hash:=public.market__request_hash(jsonb_build_object('characterId',p_character_id,'listingId',p_listing_id));
 v_start:=public.server_action_begin(p_session_token,'market.cancel',p_request_id,v_hash,v_mode,p_character_id); if v_start->>'state'='completed' then return v_start->'result'; end if; if v_start->>'state'<>'running' then raise exception '%',coalesce(v_start->>'errorCode','MARKET_CANCEL_FAILED'); end if;
 select * into c from public.character_checkpoints where character_id=p_character_id for update; select * into l from public.player_market_listings where id=p_listing_id for update;
 if l.id is null or l.status<>'active' or l.seller_user_id<>auth.uid() or l.seller_character_id<>p_character_id then raise exception 'LISTING_NOT_CANCELLABLE'; end if;
 v_uid:=public.server_item_is_uid(l.item->>'id'); if v_uid then perform public.asset_uid_owner_move_internal(l.item->>'uid','market_listing',auth.uid(),null,null,l.id,'character_inventory',auth.uid(),p_character_id,null,null,l.item,false); end if;
 c.state:=jsonb_set(c.state,'{p,inv}',public.market__add_item(c.state#>'{p,inv}',l.item),true); c.revision:=public.server_action_next_revision(c.revision);
 update public.character_checkpoints set state=c.state,revision=c.revision,saved_at=now() where character_id=p_character_id; update public.player_market_listings set status='cancelled',cancelled_at=now() where id=p_listing_id;
 v_result:=jsonb_build_object('listingId',p_listing_id,'revision',c.revision,'state',c.state); perform public.server_action_complete(p_session_token,'market.cancel',p_request_id,v_result); return v_result;
end $$;

create or replace function public.secure_market_reclaim(p_session_token uuid,p_character_id uuid,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare c public.character_checkpoints%rowtype; l public.player_market_listings%rowtype; v_mode text; v_hash text; v_start jsonb; v_inv jsonb; v_count integer:=0; v_result jsonb;
begin
 if p_request_id is null then raise exception 'INVALID_MARKET_RECLAIM'; end if;
 v_mode:=public.server_action_context(p_session_token,p_character_id,null)->>'modeBucket'; v_hash:=public.market__request_hash(jsonb_build_object('characterId',p_character_id,'kind','expired'));
 v_start:=public.server_action_begin(p_session_token,'market.reclaim',p_request_id,v_hash,v_mode,p_character_id); if v_start->>'state'='completed' then return v_start->'result'; end if; if v_start->>'state'<>'running' then raise exception '%',coalesce(v_start->>'errorCode','MARKET_RECLAIM_FAILED'); end if;
 select * into c from public.character_checkpoints where character_id=p_character_id for update; v_inv:=coalesce(c.state#>'{p,inv}','[]'::jsonb);
 for l in select * from public.player_market_listings where seller_user_id=auth.uid() and seller_character_id=p_character_id and status='active' and expires_at<=now() for update loop
   if public.server_item_is_uid(l.item->>'id') then perform public.asset_uid_owner_move_internal(l.item->>'uid','market_listing',auth.uid(),null,null,l.id,'character_inventory',auth.uid(),p_character_id,null,null,l.item,false); end if;
   v_inv:=public.market__add_item(v_inv,l.item); update public.player_market_listings set status='expired',expired_at=now() where id=l.id; v_count:=v_count+1;
 end loop;
 if v_count>0 then c.state:=jsonb_set(c.state,'{p,inv}',v_inv,true); c.revision:=public.server_action_next_revision(c.revision); update public.character_checkpoints set state=c.state,revision=c.revision,saved_at=now() where character_id=p_character_id; end if;
 v_result:=jsonb_build_object('reclaimed',v_count,'revision',c.revision,'state',c.state); perform public.server_action_complete(p_session_token,'market.reclaim',p_request_id,v_result); return v_result;
end $$;

-- Read models must not invoke the legacy reclaim function.  Expiry is handled
-- explicitly by secure_market_reclaim, which is ledgered and revision-safe.
create or replace function public.secure_market_browse_v2(p_session_token uuid,p_character_id uuid)
returns table(id uuid,item jsonb,quantity integer,unit_price_diamonds integer,price_diamonds integer,created_at timestamptz,expires_at timestamptz,source text,is_own boolean)
language plpgsql security definer set search_path=public as $$
begin
 perform public.server_action_context(p_session_token,p_character_id,null);
 return query select m.id,m.item,m.quantity,m.unit_price_diamonds,m.price_diamonds,m.created_at,m.expires_at,'S1'::text,false
   from public.player_market_listings m where m.status='active' and m.expires_at>now() and m.seller_user_id<>auth.uid() order by m.created_at desc limit 100;
end $$;
create or replace function public.secure_market_mine(p_session_token uuid,p_character_id uuid)
returns table(id uuid,item jsonb,quantity integer,unit_price_diamonds integer,price_diamonds integer,created_at timestamptz,expires_at timestamptz,source text,is_own boolean)
language plpgsql security definer set search_path=public as $$
begin
 perform public.server_action_context(p_session_token,p_character_id,null);
 return query select m.id,m.item,m.quantity,m.unit_price_diamonds,m.price_diamonds,m.created_at,m.expires_at,'S1'::text,true
   from public.player_market_listings m where m.status='active' and m.expires_at>now() and m.seller_user_id=auth.uid() order by m.created_at desc;
end $$;

-- Replaces only warehouse_transfer so UID movement shares the same registry.
create or replace function public.warehouse_transfer(
 p_session_token uuid,p_character_id uuid,p_request_id uuid,p_expected_revision bigint,
 p_direction text,p_asset text,p_item_uid text default null,p_quantity bigint default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_hash text; v_known public.server_action_requests%rowtype; v_context jsonb; v_mode text;
  v_checkpoint public.character_checkpoints%rowtype; v_warehouse public.account_warehouses%rowtype;
  v_state jsonb; v_inv jsonb; v_item jsonb; v_wh_item public.account_warehouse_items%rowtype;
  v_qty bigint; v_count bigint; v_gold bigint; v_new_uid text; v_result jsonb; v_started jsonb; v_uid boolean;
begin
 perform public.server_action_require_flag('warehouse_server_authoritative');
 if p_direction not in ('deposit','withdraw') or p_asset not in ('gold','item') or p_request_id is null or p_expected_revision is null then raise exception 'INVALID_WAREHOUSE_TRANSFER'; end if;
 v_hash:=public.market__request_hash(jsonb_build_object('characterId',p_character_id,'revision',p_expected_revision,'direction',p_direction,'asset',p_asset,'itemUid',p_item_uid,'quantity',p_quantity));
 select * into v_known from public.server_action_requests where user_id=auth.uid() and action_type='warehouse.transfer' and request_id=p_request_id;
 if found then
   if v_known.request_hash<>v_hash then raise exception 'REQUEST_ID_PAYLOAD_MISMATCH'; end if;
   if v_known.status='completed' then return v_known.result; end if;
   if v_known.status='failed' then raise exception '%',coalesce(v_known.error_code,'WAREHOUSE_TRANSFER_FAILED'); end if;
 end if;
 v_context:=public.server_action_context(p_session_token,p_character_id,null); v_mode:=v_context->>'modeBucket';
 if not public.warehouse__migration_completed(auth.uid(),v_mode) then raise exception 'WAREHOUSE_MIGRATION_REQUIRED'; end if;
 select * into v_checkpoint from public.character_checkpoints where character_id=p_character_id for update;
 if v_checkpoint.revision<>p_expected_revision then
   select * into v_known from public.server_action_requests where user_id=auth.uid() and action_type='warehouse.transfer' and request_id=p_request_id;
   if found and v_known.request_hash=v_hash and v_known.status='completed' then return v_known.result; end if;
   raise exception 'CHECKPOINT_CONFLICT:%',v_checkpoint.revision;
 end if;
 select * into v_warehouse from public.account_warehouses where user_id=auth.uid() and mode_bucket=v_mode for update;
 if not found then raise exception 'WAREHOUSE_NOT_MIGRATED'; end if;
 v_started:=public.server_action_begin(p_session_token,'warehouse.transfer',p_request_id,v_hash,v_mode,p_character_id);
 if v_started->>'state'='completed' then return v_started->'result'; end if; if v_started->>'state'<>'running' then raise exception '%',coalesce(v_started->>'errorCode','WAREHOUSE_TRANSFER_FAILED'); end if;
 v_state:=v_checkpoint.state; v_inv:=coalesce(v_state#>'{p,inv}','[]'::jsonb); v_gold:=coalesce((v_state#>>'{p,gold}')::bigint,0); v_qty:=coalesce(p_quantity,0); if v_qty<1 then raise exception 'INVALID_AMOUNT'; end if;
 if p_asset='gold' then
   if p_direction='deposit' then if v_gold<v_qty then raise exception 'INSUFFICIENT_GOLD'; end if; v_gold:=v_gold-v_qty; v_warehouse.gold:=v_warehouse.gold+v_qty;
   else if v_warehouse.gold<v_qty then raise exception 'INSUFFICIENT_WAREHOUSE_GOLD'; end if; v_gold:=v_gold+v_qty; v_warehouse.gold:=v_warehouse.gold-v_qty; end if;
   v_state:=jsonb_set(v_state,'{p,gold}',to_jsonb(v_gold),true);
 elsif p_direction='deposit' then
   select value into v_item from jsonb_array_elements(v_inv) where value->>'uid'=p_item_uid limit 1;
   if v_item is null or coalesce((v_item->>'lock')::boolean,false) then raise exception 'ITEM_NOT_TRANSFERABLE'; end if;
   v_uid:=public.server_item_is_uid(v_item->>'id'); v_count:=greatest(1,coalesce((v_item->>'cnt')::bigint,1));
   if (v_uid and (v_qty<>1 or v_count<>1)) or v_qty>v_count then raise exception 'INSUFFICIENT_ITEM_QUANTITY'; end if;
   if v_qty=v_count then v_inv:=(select coalesce(jsonb_agg(value),'[]'::jsonb) from jsonb_array_elements(v_inv) where value->>'uid'<>p_item_uid); v_new_uid:=p_item_uid;
   else v_new_uid:='wh-'||pg_catalog.gen_random_uuid()::text; v_inv:=(select coalesce(jsonb_agg(case when value->>'uid'=p_item_uid then jsonb_set(value,'{cnt}',to_jsonb(v_count-v_qty),true) else value end),'[]'::jsonb) from jsonb_array_elements(v_inv)); end if;
   if not v_uid then v_item:=jsonb_set(jsonb_set(v_item,'{uid}',to_jsonb(v_new_uid),true),'{cnt}',to_jsonb(v_qty),true); end if;
   if (select count(*) from public.account_warehouse_items where user_id=auth.uid() and mode_bucket=v_mode)>=5000 then raise exception 'WAREHOUSE_FULL'; end if;
   insert into public.account_warehouse_items(user_id,mode_bucket,item_uid,item,locked,metadata) values(auth.uid(),v_mode,v_new_uid,v_item,false,v_item-'uid'-'id'-'cnt');
   if v_uid then perform public.asset_uid_owner_move_internal(p_item_uid,'character_inventory',auth.uid(),p_character_id,null,null,'account_warehouse',auth.uid(),null,v_mode,null,v_item,true); end if;
   v_state:=jsonb_set(v_state,'{p,inv}',v_inv,true);
 else
   select * into v_wh_item from public.account_warehouse_items where user_id=auth.uid() and mode_bucket=v_mode and item_uid=p_item_uid for update;
   if not found then raise exception 'WAREHOUSE_ITEM_NOT_FOUND'; end if; if v_wh_item.locked then raise exception 'WAREHOUSE_ITEM_LOCKED'; end if;
   v_item:=v_wh_item.item; v_uid:=public.server_item_is_uid(v_item->>'id'); v_count:=v_wh_item.quantity;
   if (v_uid and (v_qty<>1 or v_count<>1)) or v_qty>v_count then raise exception 'INSUFFICIENT_WAREHOUSE_ITEM'; end if;
   if jsonb_array_length(v_inv)>=5000 then raise exception 'INVENTORY_FULL'; end if;
   if v_qty=v_count then if exists(select 1 from jsonb_array_elements(v_inv) where value->>'uid'=p_item_uid) then raise exception 'DUPLICATE_ITEM_UID'; end if; delete from public.account_warehouse_items where id=v_wh_item.id;
   else v_new_uid:='wh-'||pg_catalog.gen_random_uuid()::text; update public.account_warehouse_items set item=jsonb_set(item,'{cnt}',to_jsonb(v_count-v_qty),true),updated_at=now() where id=v_wh_item.id; v_item:=jsonb_set(v_item,'{uid}',to_jsonb(v_new_uid),true); end if;
   if not v_uid then v_item:=jsonb_set(v_item,'{cnt}',to_jsonb(v_qty),true); end if; v_inv:=v_inv||jsonb_build_array(v_item);
   if v_uid then perform public.asset_uid_owner_move_internal(p_item_uid,'account_warehouse',auth.uid(),null,v_mode,null,'character_inventory',auth.uid(),p_character_id,null,null,v_item,false); end if;
   v_state:=jsonb_set(v_state,'{p,inv}',v_inv,true);
 end if;
 update public.account_warehouses set gold=v_warehouse.gold,revision=public.server_action_next_revision(v_warehouse.revision),updated_at=now() where user_id=auth.uid() and mode_bucket=v_mode;
 update public.character_checkpoints set state=v_state,revision=public.server_action_next_revision(v_checkpoint.revision),saved_at=now() where character_id=p_character_id;
 v_result:=jsonb_build_object('revision',public.server_action_next_revision(v_checkpoint.revision),'state',v_state,'warehouse',public.warehouse__state(auth.uid(),v_mode)||jsonb_build_object('authoritative',true));
 perform public.server_action_complete(p_session_token,'warehouse.transfer',p_request_id,v_result); return v_result;
end $$;

-- Canonical grants; legacy revoke/drop happens after regression separately.
revoke all on function public.server_item_is_uid(text),public.asset_uid_owner_move_internal(text,text,uuid,uuid,text,uuid,text,uuid,uuid,text,uuid,jsonb,boolean),public.market__request_hash(jsonb),public.market__add_item(jsonb,jsonb) from public,anon,authenticated;
revoke all on function public.secure_market_list(uuid,uuid,text,integer,integer,uuid),public.secure_market_buy(uuid,uuid,uuid,uuid),public.secure_market_cancel(uuid,uuid,uuid,uuid),public.secure_market_reclaim(uuid,uuid,uuid) from public,anon;
grant execute on function public.secure_market_list(uuid,uuid,text,integer,integer,uuid),public.secure_market_buy(uuid,uuid,uuid,uuid),public.secure_market_cancel(uuid,uuid,uuid,uuid),public.secure_market_reclaim(uuid,uuid,uuid) to authenticated;
grant execute on function public.secure_market_browse_v2(uuid,uuid),public.secure_market_mine(uuid,uuid) to authenticated;
revoke all on function public.warehouse_transfer(uuid,uuid,uuid,bigint,text,text,text,bigint) from public,anon;
grant execute on function public.warehouse_transfer(uuid,uuid,uuid,bigint,text,text,text,bigint) to authenticated;
