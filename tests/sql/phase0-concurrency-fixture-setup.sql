-- Committed fixture setup for the independent-backend tests only.  It is
-- deliberately outside phase0-foundation.sql, whose final rollback correctly
-- removes all work in its assertion batch.
insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-4111-8111-111111111111','authenticated','authenticated','phase0-owner@example.invalid','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now()),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-4222-8222-222222222222','authenticated','authenticated','phase0-other@example.invalid','',now(),'{"provider":"email","providers":["email"]}','{}',now(),now())
on conflict (id) do nothing;

insert into public.player_characters(id,user_id,slot,name,class_id,level,state)
values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111',1,'Phase0Owner','knight',1,'{}'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','22222222-2222-4222-8222-222222222222',1,'Phase0Other','knight',1,'{}')
on conflict (id) do nothing;

insert into public.character_checkpoints(character_id,revision,state,saved_at)
values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',7,'{"p":{"classicMode":false}}',now()),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',3,'{"p":{"classicMode":true}}',now())
on conflict (character_id) do update set revision=excluded.revision,state=excluded.state,saved_at=excluded.saved_at;

insert into public.game_account_sessions(user_id,session_token,device_id,issued_at,last_seen_at,expires_at,invalidated_at)
values
  ('11111111-1111-4111-8111-111111111111','aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-0000-4000-8000-000000000002',now(),now(),now()+interval '15 minutes',null),
  ('22222222-2222-4222-8222-222222222222','bbbbbbbb-0000-4000-8000-000000000001','bbbbbbbb-0000-4000-8000-000000000002',now(),now(),now()+interval '15 minutes',null)
on conflict (user_id) do update set session_token=excluded.session_token,device_id=excluded.device_id,issued_at=excluded.issued_at,last_seen_at=excluded.last_seen_at,expires_at=excluded.expires_at,invalidated_at=null;
