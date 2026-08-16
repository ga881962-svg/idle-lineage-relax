-- Apply only after 007 plus its item-classification catalog pass the isolated
-- regression suite.  Online clients use only checkpoint_save, warehouse_* and
-- canonical secure_market_* actions.
revoke all on function public.save_character_checkpoint(uuid,bigint,jsonb) from public,anon,authenticated;
revoke all on function public.secure_save_character_checkpoint(uuid,uuid,bigint,jsonb,uuid) from public,anon,authenticated;
revoke all on function public.player_market_list(uuid,text,integer) from public,anon,authenticated;
revoke all on function public.player_market_buy(uuid,uuid) from public,anon,authenticated;
revoke all on function public.player_market_cancel(uuid,uuid) from public,anon,authenticated;
revoke all on function public.player_market_browse() from public,anon,authenticated;
revoke all on function public.player_market_reclaim_expired() from public,anon,authenticated;
revoke all on function public.secure_market_list(uuid,uuid,text,integer,uuid) from public,anon,authenticated;
