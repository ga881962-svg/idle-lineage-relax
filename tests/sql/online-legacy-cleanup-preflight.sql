-- Read-only preflight. `canonical_dependency_count=0` is required before
-- dropping character_event_log in a separately approved migration.
select jsonb_build_object(
  'canonical_dependency_count',count(*),
  'dependent_functions',coalesce(jsonb_agg(n.nspname||'.'||p.proname order by n.nspname,p.proname),'[]'::jsonb)
) as legacy_cleanup_preflight
from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.prosrc ilike '%character_event_log%'
  and p.proname not in ('save_character_checkpoint','secure_save_character_checkpoint','player_market_list','player_market_buy','player_market_cancel','player_market_browse','player_market_reclaim_expired');
