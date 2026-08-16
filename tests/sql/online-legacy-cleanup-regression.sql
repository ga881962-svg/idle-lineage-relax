-- Run only after 009 revoke and 010 drop in the isolated test project.
-- This is a post-cleanup catalog assertion; it does not create fixtures or
-- exercise deprecated entry points.
create temporary function pg_temp.assert_true(p_ok boolean,p_label text)
returns void language plpgsql as $$ begin
  if not coalesce(p_ok,false) then raise exception 'LEGACY_CLEANUP_ASSERTION_FAILED: %',p_label; end if;
end $$;

select pg_temp.assert_true(
  not exists(
    select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and (
      p.oid=pg_catalog.to_regprocedure('public.save_character_checkpoint(uuid,bigint,jsonb)') or
      p.oid=pg_catalog.to_regprocedure('public.secure_save_character_checkpoint(uuid,uuid,bigint,jsonb,uuid)') or
      p.oid=pg_catalog.to_regprocedure('public.player_market_list(uuid,text,integer)') or
      p.oid=pg_catalog.to_regprocedure('public.player_market_buy(uuid,uuid)') or
      p.oid=pg_catalog.to_regprocedure('public.player_market_cancel(uuid,uuid)') or
      p.oid=pg_catalog.to_regprocedure('public.player_market_browse()') or
      p.oid=pg_catalog.to_regprocedure('public.player_market_reclaim_expired()') or
      p.oid=pg_catalog.to_regprocedure('public.secure_market_list(uuid,uuid,text,integer,uuid)')
    )
  ),
  'all legacy write entry points dropped'
);

select pg_temp.assert_true(
  pg_catalog.to_regprocedure('public.checkpoint_save(uuid,uuid,bigint,uuid,jsonb)') is not null and
  pg_catalog.to_regprocedure('public.warehouse_transfer(uuid,uuid,uuid,bigint,text,text,text,bigint)') is not null and
  pg_catalog.to_regprocedure('public.secure_market_list(uuid,uuid,text,integer,integer,uuid)') is not null and
  pg_catalog.to_regprocedure('public.secure_market_buy(uuid,uuid,uuid,uuid)') is not null and
  pg_catalog.to_regprocedure('public.secure_market_cancel(uuid,uuid,uuid,uuid)') is not null and
  pg_catalog.to_regprocedure('public.secure_market_reclaim(uuid,uuid,uuid)') is not null,
  'canonical write entry points remain'
);

select pg_temp.assert_true(
  not exists(
    select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prosrc ilike '%character_event_log%'
  ),
  'no remaining function dependency on character_event_log'
);

select jsonb_build_object('online_legacy_cleanup','PASS') as result;
