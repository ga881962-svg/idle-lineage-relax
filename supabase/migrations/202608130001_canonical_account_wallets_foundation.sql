-- Canonical sponsor-diamond wallet baseline.  The historical definition was
-- kept only in online-schema.sql, so a fresh isolated database lacked the
-- wallet required by canonical secure_market_buy and secure_market_wallet.
create table if not exists public.account_wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  sponsor_diamonds bigint not null default 0 check (sponsor_diamonds>=0),
  updated_at timestamptz not null default now()
);
alter table public.account_wallets enable row level security;
revoke all on public.account_wallets from public,anon,authenticated;
