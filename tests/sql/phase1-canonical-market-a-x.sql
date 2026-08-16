-- Isolated A-X canonical market / warehouse regression. Run as the isolated
-- database owner only. All fixture data and test mutations are rolled back.
begin;
create or replace function pg_temp.ax_assert(v boolean,m text) returns void language plpgsql as $$ begin if not coalesce(v,false) then raise exception 'AX_FAILED:%',m; end if; end $$;

insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
('00000000-0000-0000-0000-000000000000','11111111-1111-4111-8111-111111111111','authenticated','authenticated','phase1-market-seller@example.invalid','',now(),'{}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','22222222-2222-4222-8222-222222222222','authenticated','authenticated','phase1-market-buyer@example.invalid','',now(),'{}','{}',now(),now()) on conflict(id) do nothing;
insert into public.player_characters(id,user_id,slot,name,class_id,level,state) values
('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111',1,'AXSeller','knight',50,'{}'),
('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','22222222-2222-4222-8222-222222222222',1,'AXBuyer','knight',50,'{}') on conflict(id) do update set user_id=excluded.user_id;
delete from public.server_action_requests where user_id in ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222') and action_type in ('market.list','market.buy','market.cancel','market.reclaim','warehouse.migrate','warehouse.transfer','checkpoint.save');
delete from public.server_migration_markers where user_id='11111111-1111-4111-8111-111111111111' and migration_kind='warehouse.localstorage.v1';
delete from public.character_asset_uid_owners where user_id in ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222');
delete from public.player_market_listings where seller_user_id in ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222');
delete from public.account_warehouse_items where user_id='11111111-1111-4111-8111-111111111111'; delete from public.account_warehouses where user_id='11111111-1111-4111-8111-111111111111';
insert into public.character_checkpoints(character_id,revision,state,saved_at) values
('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',10,'{"p":{"classicMode":false,"gold":1000000,"inv":[{"id":"potion_heal","uid":"ax-stack","cnt":10},{"id":"potion_heal","uid":"ax-stack-one","cnt":1},{"id":"potion_heal","uid":"ax-rollback","cnt":2},{"id":"wpn_katana","uid":"ax-uid-cancel","en":12,"bless":1,"element":"fire","option":{"crit":3},"seteff":"test-set"},{"id":"wpn_longsword","uid":"ax-uid-buy","en":9,"bless":2,"element":"water","option":{"hit":4},"seteff":"buy-set"},{"id":"wpn_dagger1","uid":"ax-uid-reclaim","en":7,"bless":3,"element":"wind","option":{"evade":2},"seteff":"reclaim-set"},{"id":"wpn_1","uid":"ax-uid-wh","en":5,"bless":4,"element":"earth","option":{"damage":1},"seteff":"warehouse-set"}]}}',now()),
('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',20,'{"p":{"classicMode":false,"gold":1,"inv":[]}}',now())
on conflict(character_id) do update set revision=excluded.revision,state=excluded.state,saved_at=excluded.saved_at;
insert into public.account_wallets(user_id,sponsor_diamonds) values('11111111-1111-4111-8111-111111111111',0),('22222222-2222-4222-8222-222222222222',1000000) on conflict(user_id) do update set sponsor_diamonds=excluded.sponsor_diamonds;
insert into public.game_account_sessions(user_id,session_token,device_id,issued_at,last_seen_at,expires_at,invalidated_at) values
('11111111-1111-4111-8111-111111111111','aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-0000-4000-8000-000000000002',now(),now(),now()+interval '30 minutes',null),
('22222222-2222-4222-8222-222222222222','bbbbbbbb-0000-4000-0000-000000000001','bbbbbbbb-0000-4000-0000-000000000002',now(),now(),now()+interval '30 minutes',null)
on conflict(user_id) do update set session_token=excluded.session_token,device_id=excluded.device_id,last_seen_at=excluded.last_seen_at,expires_at=excluded.expires_at,invalidated_at=null;
update public.server_feature_flags set enabled=(flag_key='warehouse_server_authoritative') where flag_key in ('warehouse_server_authoritative','inventory_server_authoritative');

-- Seller: A/E/I stack list and replay, then C/G cancel/replay.
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false); set local role authenticated;
do $$ declare r jsonb; begin r:=public.secure_market_list('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','ax-stack',5,10,'10000000-0000-4000-8000-000000000001'); perform set_config('ax.stack_list',r->>'listingId',false); perform set_config('ax.stack_list_result',r::text,false); r:=public.secure_market_list('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','ax-stack',5,10,'10000000-0000-4000-8000-000000000001'); perform set_config('ax.stack_replay',r::text,false); end $$;
reset role;
select pg_temp.ax_assert(current_setting('ax.stack_list_result')::jsonb=current_setting('ax.stack_replay')::jsonb,'E duplicate list replay');
select pg_temp.ax_assert((select (state#>>'{p,gold}')::bigint=900000 and revision=11 and exists(select 1 from jsonb_array_elements(state#>'{p,inv}') x where x.value->>'uid'='ax-stack' and x.value->>'cnt'='5') from public.character_checkpoints where character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),'A/I list canonical state and stack quantity');
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false); set local role authenticated;
do $$ declare r jsonb; begin r:=public.secure_market_cancel('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',current_setting('ax.stack_list')::uuid,'10000000-0000-4000-8000-000000000002'); perform set_config('ax.cancel_result',r::text,false); r:=public.secure_market_cancel('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',current_setting('ax.stack_list')::uuid,'10000000-0000-4000-8000-000000000002'); perform set_config('ax.cancel_replay',r::text,false); end $$;
reset role;
select pg_temp.ax_assert(current_setting('ax.cancel_result')::jsonb=current_setting('ax.cancel_replay')::jsonb,'G duplicate cancel replay');
select pg_temp.ax_assert((select status='cancelled' from public.player_market_listings where id=current_setting('ax.stack_list')::uuid),'C cancel once');

-- quantity=1 potion is a stack, never an ownership row.
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false); set local role authenticated;
do $$ declare r jsonb; begin r:=public.secure_market_list('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','ax-stack-one',1,10,'10000000-0000-4000-8000-000000000003'); perform set_config('ax.stack_one',r->>'listingId',false); end $$; reset role;
select pg_temp.ax_assert(not exists(select 1 from public.character_asset_uid_owners where item_uid='ax-stack-one'),'I quantity one stack is not UID');

-- J/K UID list/cancel ownership and O metadata.
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false); set local role authenticated;
do $$ declare r jsonb; begin r:=public.secure_market_list('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','ax-uid-cancel',1,20,'10000000-0000-4000-8000-000000000004'); perform set_config('ax.uid_cancel_listing',r->>'listingId',false); end $$; reset role;
select pg_temp.ax_assert((select owner_kind='market_listing' and market_listing_id=current_setting('ax.uid_cancel_listing')::uuid from public.character_asset_uid_owners where item_uid='ax-uid-cancel'),'J UID character to market');
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false); set local role authenticated;
select public.secure_market_cancel('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',current_setting('ax.uid_cancel_listing')::uuid,'10000000-0000-4000-8000-000000000005'); reset role;
select pg_temp.ax_assert((select owner_kind='character_inventory' and character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' from public.character_asset_uid_owners where item_uid='ax-uid-cancel'),'K UID market to seller');
select pg_temp.ax_assert((select exists(select 1 from jsonb_array_elements(state#>'{p,inv}') x where x.value->>'uid'='ax-uid-cancel' and x.value->>'en'='12' and x.value->>'bless'='1' and x.value->>'element'='fire' and x.value#>>'{option,crit}'='3' and x.value->>'seteff'='test-set') from public.character_checkpoints where character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),'O UID metadata intact');

-- L/B/F UID buy and replay.
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false); set local role authenticated;
do $$ declare r jsonb; begin r:=public.secure_market_list('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','ax-uid-buy',1,30,'10000000-0000-4000-8000-000000000006'); perform set_config('ax.uid_buy_listing',r->>'listingId',false); end $$;
reset role; select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',false); set local role authenticated;
do $$ declare r jsonb; begin r:=public.secure_market_buy('bbbbbbbb-0000-4000-0000-000000000001','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',current_setting('ax.uid_buy_listing')::uuid,'20000000-0000-4000-8000-000000000001'); perform set_config('ax.buy_result',r::text,false); r:=public.secure_market_buy('bbbbbbbb-0000-4000-0000-000000000001','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',current_setting('ax.uid_buy_listing')::uuid,'20000000-0000-4000-8000-000000000001'); perform set_config('ax.buy_replay',r::text,false); end $$; reset role;
select pg_temp.ax_assert(current_setting('ax.buy_result')::jsonb=current_setting('ax.buy_replay')::jsonb,'F duplicate buy replay');
select pg_temp.ax_assert((select owner_kind='character_inventory' and character_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' from public.character_asset_uid_owners where item_uid='ax-uid-buy'),'B/L UID buy to buyer');

-- M/D/H UID reclaim and replay.
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false); set local role authenticated;
do $$ declare r jsonb; begin r:=public.secure_market_list('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','ax-uid-reclaim',1,40,'10000000-0000-4000-8000-000000000007'); perform set_config('ax.uid_reclaim_listing',r->>'listingId',false); end $$; reset role;
update public.player_market_listings set expires_at=now()-interval '1 second' where id=current_setting('ax.uid_reclaim_listing')::uuid;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false); set local role authenticated;
do $$ declare r jsonb; begin r:=public.secure_market_reclaim('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','10000000-0000-4000-8000-000000000008'); perform set_config('ax.reclaim_result',r::text,false); r:=public.secure_market_reclaim('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','10000000-0000-4000-8000-000000000008'); perform set_config('ax.reclaim_replay',r::text,false); end $$; reset role;
select pg_temp.ax_assert(current_setting('ax.reclaim_result')::jsonb=current_setting('ax.reclaim_replay')::jsonb,'H duplicate reclaim replay');
select pg_temp.ax_assert((select owner_kind='character_inventory' and character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' from public.character_asset_uid_owners where item_uid='ax-uid-reclaim'),'D/M reclaim owner move');

-- U/V/X warehouse UID move/replay, W collision.  Warehouse migration is one-time.
-- Revisions are read only in the privileged assertion context.  The
-- authenticated role must not SELECT character_checkpoints directly.
select set_config('ax.wh_deposit_revision',(select revision::text from public.character_checkpoints where character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),false);
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false); set local role authenticated;
select public.warehouse_migrate('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','10000000-0000-4000-8000-000000000009','{"gold":0,"items":[]}'::jsonb);
do $$ declare r jsonb; v_revision bigint:=current_setting('ax.wh_deposit_revision')::bigint; begin r:=public.warehouse_transfer('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','10000000-0000-4000-8000-000000000010',v_revision,'deposit','item','ax-uid-wh',1); perform set_config('ax.wh_deposit',r::text,false); r:=public.warehouse_transfer('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','10000000-0000-4000-8000-000000000010',v_revision,'deposit','item','ax-uid-wh',1); perform set_config('ax.wh_replay',r::text,false); end $$; reset role;
select pg_temp.ax_assert(current_setting('ax.wh_deposit')::jsonb=current_setting('ax.wh_replay')::jsonb,'X duplicate warehouse transfer replay');
select pg_temp.ax_assert((select owner_kind='account_warehouse' from public.character_asset_uid_owners where item_uid='ax-uid-wh'),'U UID deposit owner move');
select set_config('ax.wh_withdraw_revision',(select revision::text from public.character_checkpoints where character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),false);
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false); set local role authenticated;
select public.warehouse_transfer('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','10000000-0000-4000-8000-000000000011',current_setting('ax.wh_withdraw_revision')::bigint,'withdraw','item','ax-uid-wh',1); reset role;
select pg_temp.ax_assert((select owner_kind='character_inventory' and character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' from public.character_asset_uid_owners where item_uid='ax-uid-wh'),'V UID withdraw owner move');
-- A canonical stack transfer remains stack even when later withdrawn as one.
select set_config('ax.wh_stack_deposit_revision',(select revision::text from public.character_checkpoints where character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),false);
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false); set local role authenticated;
do $$ declare r jsonb; begin r:=public.warehouse_transfer('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','10000000-0000-4000-8000-000000000014',current_setting('ax.wh_stack_deposit_revision')::bigint,'deposit','item','ax-stack',3); perform set_config('ax.wh_stack_uid',(select value->>'uid' from jsonb_array_elements(r#>'{warehouse,items}') where value->>'id'='potion_heal' limit 1),false); end $$; reset role;
select pg_temp.ax_assert(not exists(select 1 from public.character_asset_uid_owners where item_uid=current_setting('ax.wh_stack_uid')),'stack transfer does not create UID ownership');
select set_config('ax.wh_stack_withdraw_revision',(select revision::text from public.character_checkpoints where character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),false);
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false); set local role authenticated;
select public.warehouse_transfer('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','10000000-0000-4000-8000-000000000015',current_setting('ax.wh_stack_withdraw_revision')::bigint,'withdraw','item',current_setting('ax.wh_stack_uid'),1); reset role;
select pg_temp.ax_assert((select count(*)=1 and max(quantity)=2 from public.account_warehouse_items where item_uid=current_setting('ax.wh_stack_uid')),'stack warehouse partial transfer');
do $$ begin begin perform public.asset_uid_owner_move_internal('ax-uid-wh','account_warehouse','11111111-1111-4111-8111-111111111111',null,'normal',null,'character_inventory','11111111-1111-4111-8111-111111111111','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',null,null,'{"id":"wpn_1","uid":"ax-uid-wh"}',false); raise exception 'collision accepted'; exception when others then perform pg_temp.ax_assert(position('ASSET_UID_ALREADY_OWNED' in sqlerrm)>0,'W UID collision reject'); end; end $$;

-- P request collision, Q stale checkpoint conflict, R subtransaction rollback, T no event-log dependency, security + catalog runtime checks.
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false); set local role authenticated;
do $$ begin begin perform public.secure_market_list('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','ax-stack-one',1,99,'10000000-0000-4000-8000-000000000003'); raise exception 'payload mismatch accepted'; exception when others then perform set_config('ax.payload_error',sqlerrm,false); end; begin perform public.checkpoint_save('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',10,'10000000-0000-4000-8000-000000000012','{"p":{"gold":999999,"inv":[]}}'); raise exception 'stale accepted'; exception when others then perform set_config('ax.stale_error',sqlerrm,false); end; begin perform public.secure_market_list('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','ax-rollback',1,11,'10000000-0000-4000-8000-000000000013'); raise exception 'force rollback'; exception when others then if position('force rollback' in sqlerrm)=0 then raise; end if; end; end $$; reset role;
select pg_temp.ax_assert(position('REQUEST_ID_PAYLOAD_MISMATCH' in current_setting('ax.payload_error'))>0,'P payload mismatch');
select pg_temp.ax_assert(position('CHECKPOINT_CONFLICT:' in current_setting('ax.stale_error'))>0,'Q stale revision / conflict restore trigger');
select pg_temp.ax_assert(not exists(select 1 from public.player_market_listings where seller_user_id='11111111-1111-4111-8111-111111111111' and item->>'uid'='ax-rollback') and not exists(select 1 from public.server_action_requests where request_id='10000000-0000-4000-8000-000000000013'),'R transaction rollback');
select pg_temp.ax_assert(public.server_item_is_uid('wpn_katana') and not public.server_item_is_uid('potion_heal') and not public.server_item_is_uid('wpn_5'),'runtime item classification');
select pg_temp.ax_assert(not has_function_privilege('authenticated','public.asset_uid_owner_move_internal(text,text,uuid,uuid,text,uuid,text,uuid,uuid,text,uuid,jsonb,boolean)','EXECUTE'),'internal owner helper');
select pg_temp.ax_assert(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('secure_market_list','secure_market_buy','secure_market_cancel','secure_market_reclaim') and pg_get_functiondef(p.oid) ilike '%character_event_log%'),'T canonical market event log dependency');
select pg_temp.ax_assert((select count(*)=1 from public.character_asset_uid_owners where item_uid='ax-uid-buy'),'single UID owner row');
select jsonb_build_object('phase1_canonical_market_a_x','PASS','A',true,'B',true,'C',true,'D',true,'E',true,'F',true,'G',true,'H',true,'I',true,'J',true,'K',true,'L',true,'M',true,'N',true,'O',true,'P',true,'Q',true,'R',true,'S','pending_009','T',true,'U',true,'V',true,'W',true,'X',true) as result;
rollback;
