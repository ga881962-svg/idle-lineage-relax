-- Phase 1 isolated fixture. Run only as the database owner on the isolated
-- wladrgqkrmsjazhvxowi project. It is intentionally deterministic and may be
-- rerun before every assertion/concurrency round.
insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values ('00000000-0000-0000-0000-000000000000','11111111-1111-4111-8111-111111111111','authenticated','authenticated','phase1-owner@example.invalid','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now())
on conflict (id) do nothing;

insert into public.player_characters(id,user_id,slot,name,class_id,level,state) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111',1,'Phase1A','knight',50,'{}'),
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc','11111111-1111-4111-8111-111111111111',2,'Phase1B','prince',50,'{}')
on conflict (id) do nothing;

delete from public.server_action_requests where user_id='11111111-1111-4111-8111-111111111111' and action_type in ('warehouse.migrate','warehouse.transfer','checkpoint.save');
delete from public.server_migration_markers where user_id='11111111-1111-4111-8111-111111111111' and migration_kind='warehouse.localstorage.v1';
delete from public.account_warehouse_items where user_id='11111111-1111-4111-8111-111111111111';
delete from public.account_warehouses where user_id='11111111-1111-4111-8111-111111111111';

insert into public.character_checkpoints(character_id,revision,state,saved_at) values
('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',10,
 '{"p":{"classicMode":false,"gold":4672844,"inv":[{"id":"test_stack","uid":"phase1-stack-a","cnt":100},{"id":"test_weapon","uid":"phase1-equip-a","cnt":1,"en":12,"bless":1,"element":"fire","option":{"crit":3},"seteff":"sherine"}]}}',now()),
('cccccccc-cccc-4ccc-8ccc-cccccccccccc',20,
 '{"p":{"classicMode":false,"gold":100,"inv":[]}}',now())
on conflict(character_id) do update set revision=excluded.revision,state=excluded.state,saved_at=excluded.saved_at;

insert into public.game_account_sessions(user_id,session_token,device_id,issued_at,last_seen_at,expires_at,invalidated_at)
values('11111111-1111-4111-8111-111111111111','aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-0000-4000-8000-000000000002',now(),now(),now()+interval '15 minutes',null)
on conflict(user_id) do update set session_token=excluded.session_token,device_id=excluded.device_id,last_seen_at=excluded.last_seen_at,expires_at=excluded.expires_at,invalidated_at=null;

update public.server_feature_flags set enabled=true,updated_at=now() where flag_key in ('warehouse_server_authoritative','inventory_server_authoritative');
select json_build_object('fixture','phase1-ready','owner','11111111-1111-4111-8111-111111111111','a_revision',10,'b_revision',20,'session_token','aaaaaaaa-0000-4000-8000-000000000001') as phase1_fixture;
