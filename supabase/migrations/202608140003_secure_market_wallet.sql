-- Marketplace wallet compatibility RPC.
-- The exchange frontend always loads the authenticated buyer balance first.
-- Keep this read behind the same active game-session check as every market
-- mutation; it neither changes inventory nor changes any marketplace rule.
begin;

create or replace function public.secure_market_wallet(p_session_token uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance integer;
begin
  perform public.assert_active_game_session(p_session_token);

  insert into public.account_wallets(user_id, sponsor_diamonds)
  values (auth.uid(), 0)
  on conflict (user_id) do nothing;

  select coalesce(sponsor_diamonds, 0)
    into v_balance
  from public.account_wallets
  where user_id = auth.uid();

  return coalesce(v_balance, 0);
end;
$$;

revoke all on function public.secure_market_wallet(uuid) from public;
grant execute on function public.secure_market_wallet(uuid) to authenticated;

commit;
