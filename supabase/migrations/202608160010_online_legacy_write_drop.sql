-- Apply only after 008 has been verified against the isolated online client.
-- character_event_log is deliberately NOT dropped here: execute the catalog
-- dependency check in tests/sql/online-legacy-cleanup-preflight.sql first.
-- Retire the old cron entry as well.  Leaving it behind after the target
-- function is dropped would create an hourly failing job.  The catalog guard
-- keeps this migration portable to test databases without pg_cron.
do $$
begin
  if pg_catalog.to_regnamespace('cron') is not null then
    execute $sql$select cron.unschedule(jobid) from cron.job where jobname='player-market-expiry'$sql$;
  end if;
end $$;

drop function if exists public.save_character_checkpoint(uuid,bigint,jsonb);
drop function if exists public.secure_save_character_checkpoint(uuid,uuid,bigint,jsonb,uuid);
drop function if exists public.player_market_list(uuid,text,integer);
drop function if exists public.player_market_buy(uuid,uuid);
drop function if exists public.player_market_cancel(uuid,uuid);
drop function if exists public.player_market_browse();
drop function if exists public.player_market_reclaim_expired();
drop function if exists public.secure_market_list(uuid,uuid,text,integer,uuid);
