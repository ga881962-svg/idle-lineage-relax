-- The RETURNS TABLE column "id" is a PL/pgSQL output variable.  Qualify the
-- ownership lookup columns so PostgreSQL never resolves them against it.
begin;

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
  if not exists (
    select 1
      from public.player_characters as pc
     where pc.id = p_character_id
       and pc.user_id = auth.uid()
  ) then
    raise exception 'CHARACTER_NOT_FOUND';
  end if;

  perform public.player_market_reclaim_expired();

  return query
    select m.id, m.item, m.quantity, m.unit_price_diamonds, m.price_diamonds,
      m.created_at, m.expires_at, 'S1'::text, (m.seller_user_id = auth.uid())
      from public.player_market_listings as m
     where m.status = 'active'
       and m.expires_at > now()
       and m.seller_user_id <> auth.uid()
     order by m.created_at desc
     limit 100;
end;
$$;

commit;
