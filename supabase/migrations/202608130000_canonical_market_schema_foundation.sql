-- Canonical online market schema baseline.
-- Historical market table creation lived in online-player-market.sql rather
-- than migrations.  This file makes a fresh database reconstructible without
-- restoring any legacy market/checkpoint writer.

create table if not exists public.player_market_listings (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  seller_user_id uuid not null references auth.users(id) on delete cascade,
  seller_character_id uuid not null references public.player_characters(id) on delete cascade,
  seller_name text not null,
  item jsonb not null check (jsonb_typeof(item)='object' and coalesce(item->>'id','')<>''),
  quantity integer not null default 1 check (quantity between 1 and 99999),
  unit_price_diamonds integer not null default 1 check (unit_price_diamonds between 1 and 999999),
  price_diamonds integer not null check (price_diamonds between 1 and 2147483647),
  pricing_version smallint not null default 2 check (pricing_version=2),
  status text not null default 'active' check (status in ('active','sold','cancelled','expired')),
  buyer_user_id uuid references auth.users(id) on delete set null,
  buyer_character_id uuid references public.player_characters(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now()+interval '7 days'),
  sold_at timestamptz,
  cancelled_at timestamptz,
  expired_at timestamptz,
  listing_fee_gold bigint not null default 100000 check (listing_fee_gold>=0)
);

create index if not exists player_market_active_created_idx
  on public.player_market_listings(status,created_at desc);
create index if not exists player_market_seller_active_idx
  on public.player_market_listings(seller_user_id,status);
create index if not exists player_market_active_expiry_idx
  on public.player_market_listings(status,expires_at);
create index if not exists player_market_seller_active_expiry_idx
  on public.player_market_listings(seller_user_id,status,expires_at);

alter table public.player_market_listings enable row level security;
revoke all on public.player_market_listings from public,anon,authenticated;
