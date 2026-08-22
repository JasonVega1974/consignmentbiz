-- ═══════════════════════════════════════════════════════════════════════════
-- CONSIGNMENTBIZ — SUPABASE SCHEMA
-- Table prefix: cb_        Owner: Kingdom Creatives LLC
--
-- ⚠ BEFORE YOU RUN THIS FILE: enable pg_cron in the Supabase dashboard
--   (Database → Extensions → search "pg_cron" → toggle ON).
--   §7 schedules the reservation-release job and WILL error mid-script if the
--   extension is not enabled first. Details in the §7 header.
--
-- Run in Supabase → SQL Editor → New query → Run. Idempotent: every object uses
-- create-if-not-exists / create-or-replace, and every policy is dropped by name
-- before being re-created, so this file is safe to re-run end to end.
--
-- ORDER MATTERS, and not only for readability. Sections run top to bottom:
--   extensions → trigger fn → TABLES → rls helpers → indexes → triggers →
--   reservation release → RPCs → RLS policies → views → storage → seed → verify.
-- The RLS helper functions (§4) sit AFTER the tables on purpose: they are
-- `language sql`, whose bodies Postgres resolves at CREATE time, so they cannot
-- be declared before the tables they query. Full explanation in the §4 header.
--
-- Mirrors EstateSaleBiz conventions (client_id text tenant key, tenant-scoped
-- RLS, public read via security-definer views) with four deliberate departures
-- documented inline: §4 helper functions, §3.10 payouts, §3.7 reservations,
-- §3.5 category lookup table.
-- ═══════════════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════════════
-- 1 · EXTENSIONS
-- ═══════════════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;   -- gen_random_uuid()

-- pg_cron: enable it in the DASHBOARD first (Database → Extensions → pg_cron).
-- On Supabase this statement succeeds only once the extension is available to
-- the project; enabling via the dashboard is the supported path and also
-- installs it into the correct schema. Left here so the dependency is explicit
-- and so a re-run on an already-enabled project is a no-op.
create extension if not exists pg_cron;    -- scheduled reservation release (§7)


-- ═══════════════════════════════════════════════════════════════════════════
-- 2 · SHARED TRIGGER FUNCTION — updated_at
--
-- Safe to define here: plpgsql bodies are only syntax-checked at CREATE time,
-- and this one touches no tables anyway. Contrast §4, which must wait.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.cb_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end $$;


-- ═══════════════════════════════════════════════════════════════════════════
-- 3 · TABLES
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 3.1 · TENANTS — one row per purchased territory ────────────────────────
-- Public-readable by design (same reasoning as esb_tenants): every column here
-- is already displayed on the tenant's storefront. No secrets, no keys.
-- client_id is NOT a secret — it appears in every public REST query string.
-- Access control lives in the RLS policies on cb_items/cb_photos, not in
-- hiding this id.
create table if not exists public.cb_tenants (
  id                        uuid primary key default gen_random_uuid(),
  client_id                 text not null unique,
  city_label                text not null,
  state                     text not null,
  business_name             text,
  tagline                   text,
  about_text                text,
  logo_url                  text,
  primary_color             text not null default '#6b7a90',
  public_email              text,
  public_phone              text,
  pickup_address            text,
  hours_text                text,
  custom_domain             text unique,
  custom_domain_status      text not null default 'none',

  -- Consignment terms (PLAN.md §5 Q2 — resolved: operators DO split proceeds)
  --
  -- ► DIRECTION, FIXED PLATFORM-WIDE: every *_payout_percentage column in this
  --   schema is THE CONSIGNOR'S SHARE — the percent paid OUT to them.
  --   60.00 means the consignor receives 60%, the shop keeps 40%.
  --   The shop's cut is always (100 - payout_percentage); it is never stored,
  --   so the two halves cannot drift out of sync.
  --   Every UI label must name the direction explicitly ("Consignor receives
  --   ___%"), never a bare "split" or "60/40" that an operator could read
  --   backwards and underpay someone.
  default_payout_percentage numeric(5,2) not null default 50.00,
  payout_terms_text         text,

  -- Reservation policy (PLAN.md §5 Q3 — resolved: auto-expiry, default 3 days)
  reserve_hold_days         integer not null default 3,

  is_active                 boolean not null default true,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),

  constraint cb_tenants_state_len   check (char_length(state) = 2),
  constraint cb_tenants_domain_stat check (custom_domain_status in ('none','pending','active')),
  constraint cb_tenants_payout_pct  check (default_payout_percentage >= 0 and default_payout_percentage <= 100),
  constraint cb_tenants_hold_days   check (reserve_hold_days >= 1 and reserve_hold_days <= 30)
);

-- ── 3.2 · PLATFORM ADMINS — backs cb_is_admin() ────────────────────────────
-- NEW vs EstateSaleBiz, which has no SQL-level admin concept (its owner
-- dashboard is PIN-gated in the page, not the database). Kept as its own table
-- rather than a role='admin' value on cb_client_users, because the platform
-- owner is not a tenant and should not need a cb_tenants row to be an admin.
create table if not exists public.cb_platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  label      text,
  created_at timestamptz not null default now()
);

-- ── 3.3 · CLIENT USERS — auth.users → tenant mapping ───────────────────────
create table if not exists public.cb_client_users (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  client_id    text not null references public.cb_tenants(client_id) on delete cascade,
  display_name text,
  role         text not null default 'operator',
  created_at   timestamptz not null default now(),

  constraint cb_client_users_role   check (role in ('operator','staff')),
  constraint cb_client_users_unique unique (user_id, client_id)
);

-- ── 3.4 · CITY CLAIMS — territory exclusivity ──────────────────────────────
-- The unique constraint on (lower(city_label), state) IS the exclusivity
-- mechanism. Two concurrent purchases for the same city cannot both commit;
-- the loser gets a unique violation, which cb_claim_city() (§8) converts into
-- a clean "already claimed" result rather than a raw 23505 to the client.
create table if not exists public.cb_city_claims (
  id         uuid primary key default gen_random_uuid(),
  city_label text not null,
  state      text not null,
  client_id  text references public.cb_tenants(client_id) on delete set null,
  status     text not null default 'claimed',
  claimed_at timestamptz not null default now(),
  released_at timestamptz,

  constraint cb_city_claims_state_len check (char_length(state) = 2),
  constraint cb_city_claims_status    check (status in ('claimed','reserved','released'))
);

-- Case-insensitive exclusivity: 'Nampa'/'nampa'/'NAMPA' are one territory.
create unique index if not exists cb_city_claims_unique_active
  on public.cb_city_claims (lower(city_label), upper(state))
  where status in ('claimed','reserved');

-- ── 3.5 · CATEGORIES — fixed taxonomy (PLAN.md §5 Q5 — resolved) ───────────
--
-- LOOKUP TABLE, not a check constraint. Reasoning is in the summary; the short
-- version: you said you want to tune the list. A check constraint makes every
-- tune an ALTER TABLE (validation scan + migration + a redeploy of the three
-- HTML files that hard-code the option lists). A lookup table makes it an
-- INSERT, and lets demo.html / consign.html / admin.html render their category
-- pickers FROM the table so they can never drift out of sync.
--
-- Platform-global rows (client_id null) are the shipped taxonomy. A tenant may
-- add its own rows with its client_id set — a shop that is all mid-century
-- furniture can add sub-categories without affecting anyone else.
create table if not exists public.cb_categories (
  id            uuid primary key default gen_random_uuid(),
  client_id     text references public.cb_tenants(client_id) on delete cascade,
  slug          text not null,
  label         text not null,
  display_order integer not null default 0,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),

  constraint cb_categories_slug_fmt check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);

-- Global slugs unique among themselves; tenant slugs unique within the tenant.
create unique index if not exists cb_categories_global_slug
  on public.cb_categories (slug) where client_id is null;
create unique index if not exists cb_categories_tenant_slug
  on public.cb_categories (client_id, slug) where client_id is not null;

-- ── 3.6 · CONSIGNORS — lightweight identity, no auth account ───────────────
-- PLAN.md §5 Q4 resolved: consignors never log in. They exist only as contact
-- rows the operator owns, created from the public consign.html submission.
create table if not exists public.cb_consignors (
  id                 uuid primary key default gen_random_uuid(),
  client_id          text not null references public.cb_tenants(client_id) on delete cascade,
  name               text not null,
  email              text,
  phone              text,
  -- CONSIGNOR'S SHARE — percent paid OUT to this consignor (see §3.1).
  -- Per-consignor override of cb_tenants.default_payout_percentage; null = use
  -- the tenant default. A negotiated 70 (consignor keeps 70%, shop 30%) for one
  -- prolific seller lives here.
  payout_percentage  numeric(5,2),
  notes              text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint cb_consignors_payout_pct check (payout_percentage is null or (payout_percentage >= 0 and payout_percentage <= 100))
);

-- ── 3.7 · ITEMS — the core inventory table ─────────────────────────────────
-- No sale_id / no event scoping: this is a standing storefront, per PLAN.md §1.
--
-- STATUS LIFECYCLE
--   pending    → submitted via consign.html, awaiting operator review
--   rejected   → operator declined it (terminal)
--   approved   → operator accepted it, not yet listed publicly
--   available  → live on the storefront
--   reserved   → held for a buyer until reserved_until (PLAN.md §5 Q3)
--   sold       → terminal; shown on the storefront as sold-out, never deleted
--
-- RESERVATION COLUMNS live on the item rather than in a cb_reservations table.
-- That is what you specified, and it is the right call at this scale: one
-- active hold per item, no history requirement, no join on the hot storefront
-- read path. If you later want a full reservation audit trail (who held what,
-- how often holds lapse), that becomes a separate table and these columns
-- become a denormalized cache of the active row.
create table if not exists public.cb_items (
  id                uuid primary key default gen_random_uuid(),
  client_id         text not null references public.cb_tenants(client_id) on delete cascade,
  consignor_id      uuid references public.cb_consignors(id) on delete set null,
  category_slug     text,

  name              text not null,
  condition         text,
  description       text,
  dimensions        text,
  price             numeric(10,2) not null,
  asking_price      numeric(10,2),          -- what the consignor hoped for; operator-facing only

  purchase_mode     text not null default 'fixed_price',
  status            text not null default 'pending',

  -- CONSIGNOR'S SHARE for this item — percent paid OUT to them (see §3.1).
  -- Resolved at approval time from consignor override → tenant default, and
  -- FROZEN on the row from then on: changing the tenant default later must
  -- never retroactively rewrite what an existing consignor is owed.
  -- cb_items_before_write() (§6.2) does the resolution.
  payout_percentage numeric(5,2),

  -- Reservation (PLAN.md §5 Q3)
  reserved_until    timestamptz,
  reserved_by       text,                   -- buyer name as given at reserve time
  reserved_by_email text,
  reserved_by_phone text,
  reserved_at       timestamptz,

  approved_at       timestamptz,
  approved_by       uuid references auth.users(id) on delete set null,
  sold_at           timestamptz,
  display_order     integer not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint cb_items_price_pos   check (price >= 0),
  constraint cb_items_mode        check (purchase_mode in ('fixed_price','reserve_pickup')),
  constraint cb_items_status      check (status in ('pending','rejected','approved','available','reserved','sold')),
  constraint cb_items_payout_pct  check (payout_percentage is null or (payout_percentage >= 0 and payout_percentage <= 100)),
  -- A reserved item must carry an expiry. Prevents an infinite hold created by
  -- a partial UPDATE that sets status but forgets reserved_until.
  constraint cb_items_reserve_expiry check (status <> 'reserved' or reserved_until is not null)
);

-- Category FK is deliberately NOT a hard reference: an item may carry a slug
-- from either the global set (client_id null) or its own tenant's set, which a
-- single FK cannot express. cb_items_category_valid() (§6) enforces it instead.

-- ── 3.8 · PHOTOS — multi-photo per item (PLAN.md §5 Q6) ────────────────────
create table if not exists public.cb_photos (
  id            uuid primary key default gen_random_uuid(),
  client_id     text not null references public.cb_tenants(client_id) on delete cascade,
  item_id       uuid not null references public.cb_items(id) on delete cascade,
  photo_url     text not null,
  display_order integer not null default 0,
  is_featured   boolean not null default false,
  created_at    timestamptz not null default now()
);

-- At most one featured photo per item.
create unique index if not exists cb_photos_one_featured
  on public.cb_photos (item_id) where is_featured;

-- ── 3.9 · PURCHASES — fixed_price items only (Stripe Checkout) ─────────────
-- reserve_pickup items never produce a row here: no card touches the platform
-- for those. The operator marks them sold in admin, which fires the payout
-- trigger just the same.
create table if not exists public.cb_purchases (
  id                uuid primary key default gen_random_uuid(),
  client_id         text not null references public.cb_tenants(client_id) on delete cascade,
  item_id           uuid not null references public.cb_items(id) on delete restrict,
  buyer_email       text not null,
  buyer_name        text,
  buyer_phone       text,
  stripe_session_id text unique,
  amount            numeric(10,2) not null,
  status            text not null default 'pending',
  paid_at           timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint cb_purchases_amount_pos check (amount >= 0),
  constraint cb_purchases_status     check (status in ('pending','paid','refunded','failed'))
);

-- ── 3.10 · PAYOUTS — what the operator owes each consignor ─────────────────
-- NEW vs EstateSaleBiz — no analogous flow exists there (PLAN.md §5 Q2).
--
-- One row per sold consignor-sourced item, created automatically by the §6
-- trigger when an item transitions into 'sold'. Shop-owned items (consignor_id
-- null) produce no row — there is nobody to pay.
--
-- amount_owed is STORED, not computed on read, because it must be a historical
-- record: it captures the split as it stood at the moment of sale, immune to
-- any later edit of the item price or the tenant's default percentage.
create table if not exists public.cb_payouts (
  id                uuid primary key default gen_random_uuid(),
  client_id         text not null references public.cb_tenants(client_id) on delete cascade,
  item_id           uuid not null references public.cb_items(id) on delete cascade,
  consignor_id      uuid not null references public.cb_consignors(id) on delete restrict,

  sale_amount       numeric(10,2) not null,   -- item price at time of sale
  payout_percentage numeric(5,2)  not null,   -- CONSIGNOR'S SHARE %, frozen (see §3.1)
  amount_owed       numeric(10,2) not null,   -- what the CONSIGNOR gets: sale_amount * pct / 100
  amount_paid       numeric(10,2) not null default 0,  -- of amount_owed, how much has reached them

  status            text not null default 'owed',
  paid_at           timestamptz,
  payment_method    text,
  payment_reference text,
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint cb_payouts_one_per_item unique (item_id),
  constraint cb_payouts_amounts      check (sale_amount >= 0 and amount_owed >= 0 and amount_paid >= 0),
  constraint cb_payouts_pct          check (payout_percentage >= 0 and payout_percentage <= 100),
  constraint cb_payouts_not_over     check (amount_paid <= amount_owed),
  constraint cb_payouts_status       check (status in ('owed','partial','paid','void'))
);

-- ── 3.11 · BILLING — the $197 territory purchase (PLAN.md §5 Q1 — resolved) ─
-- ONE-TIME ONLY. No subscription object, no recurring hosting fee. The
-- billing_type check below permits exactly one value; if a recurring tier is
-- ever added, widen the constraint and add the Stripe subscription columns
-- then rather than carrying dead nullable columns now.
create table if not exists public.cb_billing (
  id                uuid primary key default gen_random_uuid(),
  client_id         text not null references public.cb_tenants(client_id) on delete cascade,
  amount            numeric(10,2) not null,
  currency          text not null default 'usd',
  stripe_session_id text unique,
  stripe_payment_intent text unique,
  billing_type      text not null default 'one_time',
  status            text not null default 'pending',
  paid_at           timestamptz,
  created_at        timestamptz not null default now(),

  constraint cb_billing_amount_pos check (amount >= 0),
  constraint cb_billing_type       check (billing_type = 'one_time'),
  constraint cb_billing_status     check (status in ('pending','paid','refunded','failed'))
);


-- ═══════════════════════════════════════════════════════════════════════════
-- 4 · RLS HELPER FUNCTIONS
--
-- ⚠ POSITION IS LOAD-BEARING — these MUST come after §3 (tables) and before §9
--   (the policies that call them). Do not move this block back toward the top.
--
--   Both are `language sql`, and Postgres validates SQL-language function
--   bodies at CREATE time (check_function_bodies, on by default): every
--   relation named inside is resolved right then. Defining them before
--   cb_client_users / cb_platform_admins exist fails with
--       ERROR: 42P01: relation "public.cb_client_users" does not exist
--   and takes the rest of the script down with it.
--
--   plpgsql bodies (§2, §6, §7, §8) are only syntax-checked at CREATE time and
--   resolve names at first execution, which is why those functions tolerate any
--   position. That difference is the whole reason this section sits here rather
--   than beside the other function definitions.
--
--   Kept as `language sql` on purpose rather than converted to plpgsql to dodge
--   the ordering: a STABLE sql function is inlinable by the planner, which is
--   exactly what makes it fast inside an RLS predicate. Reordering costs
--   nothing; converting would cost the inlining.
--
-- DEPARTURE FROM ESTATESALEBIZ: ESB has no esb_is_tenant()/esb_is_admin(). It
-- inlines `client_id in (select client_id from esb_client_users where user_id =
-- auth.uid())` into all ~10 policies. PLAN.md §4 specifies cb_is_tenant()/
-- cb_is_admin(), and the function form is strictly better here:
--   • auth.uid() wrapped in a scalar subquery → evaluated ONCE per query as an
--     InitPlan, not once per row (5-10x on large tables per Supabase's guidance)
--   • one definition to audit instead of ten copies that can drift
--   • STABLE lets the planner cache the result within a statement
--
-- SECURITY DEFINER is required: the function reads cb_client_users, which is
-- itself RLS-protected. `set search_path = ''` prevents search-path hijacking,
-- so every reference inside must be schema-qualified.
-- ═══════════════════════════════════════════════════════════════════════════

-- Does the calling user belong to this tenant?
create or replace function public.cb_is_tenant(p_client_id text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.cb_client_users cu
    where cu.client_id = p_client_id
      and cu.user_id = (select auth.uid())
  );
$$;

-- Is the calling user a platform admin (Kingdom Creatives owner-level)?
create or replace function public.cb_is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.cb_platform_admins pa
    where pa.user_id = (select auth.uid())
  );
$$;

-- Both functions are called BY the querying role inside RLS policies, so
-- `authenticated` must retain EXECUTE. anon never needs either — no anon policy
-- references them — so it is revoked explicitly.
revoke execute on function public.cb_is_tenant(text) from public, anon;
revoke execute on function public.cb_is_admin()        from public, anon;
grant  execute on function public.cb_is_tenant(text) to authenticated;
grant  execute on function public.cb_is_admin()        to authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- 5 · INDEXES
--
-- Postgres does not auto-index foreign keys. Every FK below is indexed, both
-- for JOIN speed and so ON DELETE CASCADE does not table-scan. client_id is
-- indexed on every table because it is the RLS predicate column — an unindexed
-- RLS column is the single most common cause of slow multi-tenant queries.
-- ═══════════════════════════════════════════════════════════════════════════

-- cb_tenants.client_id needs no index: the UNIQUE constraint already provides one.
create index if not exists cb_tenants_active_idx        on public.cb_tenants (is_active) where is_active;
create index if not exists cb_tenants_domain_idx        on public.cb_tenants (custom_domain) where custom_domain is not null;

create index if not exists cb_client_users_user_idx     on public.cb_client_users (user_id);
create index if not exists cb_client_users_client_idx   on public.cb_client_users (client_id);

create index if not exists cb_city_claims_client_idx    on public.cb_city_claims (client_id);

create index if not exists cb_categories_client_idx     on public.cb_categories (client_id);
create index if not exists cb_categories_active_idx     on public.cb_categories (is_active, display_order) where is_active;

create index if not exists cb_consignors_client_idx     on public.cb_consignors (client_id);
create index if not exists cb_consignors_email_idx      on public.cb_consignors (client_id, lower(email)) where email is not null;

create index if not exists cb_items_client_idx          on public.cb_items (client_id);
create index if not exists cb_items_consignor_idx       on public.cb_items (consignor_id);
create index if not exists cb_items_approved_by_idx     on public.cb_items (approved_by);
-- Storefront's hot path: "this tenant's live items, newest first."
create index if not exists cb_items_storefront_idx      on public.cb_items (client_id, status, created_at desc);
create index if not exists cb_items_category_idx        on public.cb_items (client_id, category_slug) where category_slug is not null;
-- Approval queue: partial index, so it stays tiny regardless of catalog size.
create index if not exists cb_items_pending_idx         on public.cb_items (client_id, created_at) where status = 'pending';
-- Drives the expiry sweep in §7 — only ever scans live holds.
create index if not exists cb_items_reserved_idx        on public.cb_items (reserved_until) where status = 'reserved';

create index if not exists cb_photos_client_idx         on public.cb_photos (client_id);
create index if not exists cb_photos_item_idx           on public.cb_photos (item_id, display_order);

create index if not exists cb_purchases_client_idx      on public.cb_purchases (client_id);
create index if not exists cb_purchases_item_idx        on public.cb_purchases (item_id);

create index if not exists cb_payouts_client_idx        on public.cb_payouts (client_id);
-- cb_payouts.item_id needs no index: the one-payout-per-item UNIQUE provides one.
create index if not exists cb_payouts_consignor_idx     on public.cb_payouts (consignor_id);
-- "What do I still owe?" — the admin Consignors tab's headline number.
create index if not exists cb_payouts_outstanding_idx   on public.cb_payouts (client_id, consignor_id) where status in ('owed','partial');

create index if not exists cb_billing_client_idx        on public.cb_billing (client_id);


-- ═══════════════════════════════════════════════════════════════════════════
-- 6 · TRIGGERS — payout creation, payout status, category validation, touch
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 6.1 · Category slug must exist, be active, and belong to this tenant ────
create or replace function public.cb_items_category_valid()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.category_slug is null then
    return new;
  end if;
  if not exists (
    select 1 from public.cb_categories c
    where c.slug = new.category_slug
      and c.is_active
      and (c.client_id is null or c.client_id = new.client_id)
  ) then
    raise exception 'Unknown or inactive category slug: %', new.category_slug
      using errcode = '23514';
  end if;
  return new;
end $$;

drop trigger if exists cb_items_category_check on public.cb_items;
create trigger cb_items_category_check
  before insert or update of category_slug, client_id on public.cb_items
  for each row execute function public.cb_items_category_valid();

-- ── 6.2 · Freeze the payout percentage at approval; stamp lifecycle times ───
-- Resolution order: value already on the item → consignor override → tenant
-- default. Once set it is never recomputed, so a later change to the tenant
-- default cannot rewrite what an existing consignor is owed.
create or replace function public.cb_items_before_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pct numeric(5,2);
begin
  new.updated_at := now();

  -- Entering approved/available for the first time → resolve and freeze payout.
  if new.consignor_id is not null
     and new.payout_percentage is null
     and new.status in ('approved','available') then
    select coalesce(cons.payout_percentage, t.default_payout_percentage)
      into v_pct
      from public.cb_tenants t
      left join public.cb_consignors cons on cons.id = new.consignor_id
     where t.client_id = new.client_id;
    new.payout_percentage := v_pct;
  end if;

  if new.status in ('approved','available')
     and (tg_op = 'INSERT' or old.status is distinct from new.status)
     and new.approved_at is null then
    new.approved_at := now();
  end if;

  if new.status = 'sold'
     and (tg_op = 'INSERT' or old.status is distinct from 'sold')
     and new.sold_at is null then
    new.sold_at := now();
  end if;

  -- Leaving 'reserved' for any other status clears the hold fields, so a
  -- released or sold item can never keep a stale reservation on it.
  if tg_op = 'UPDATE' and old.status = 'reserved' and new.status <> 'reserved' then
    new.reserved_until    := null;
    new.reserved_by       := null;
    new.reserved_by_email := null;
    new.reserved_by_phone := null;
    new.reserved_at       := null;
  end if;

  return new;
end $$;

drop trigger if exists cb_items_before_write_trg on public.cb_items;
create trigger cb_items_before_write_trg
  before insert or update on public.cb_items
  for each row execute function public.cb_items_before_write();

-- ── 6.3 · Create the payout row when a consignor item sells ────────────────
create or replace function public.cb_create_payout_on_sold()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pct    numeric(5,2);
  v_amount numeric(10,2);
begin
  if new.status <> 'sold' then
    return null;
  end if;
  if tg_op = 'UPDATE' and old.status = 'sold' then
    return null;                      -- already sold; not a new transition
  end if;
  if new.consignor_id is null then
    return null;                      -- shop-owned: nobody to pay
  end if;

  v_pct    := coalesce(new.payout_percentage, 0);
  v_amount := round(new.price * v_pct / 100.0, 2);

  insert into public.cb_payouts
    (client_id, item_id, consignor_id, sale_amount, payout_percentage, amount_owed, status)
  values
    (new.client_id, new.id, new.consignor_id, new.price, v_pct, v_amount,
     case when v_amount = 0 then 'paid' else 'owed' end)
  on conflict (item_id) do nothing;   -- idempotent: re-selling never double-pays

  return null;
end $$;

drop trigger if exists cb_items_payout_trg on public.cb_items;
create trigger cb_items_payout_trg
  after insert or update of status on public.cb_items
  for each row execute function public.cb_create_payout_on_sold();

-- ── 6.4 · Keep payout status in step with amount_paid ──────────────────────
create or replace function public.cb_payouts_before_write()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  if new.status <> 'void' then
    if new.amount_paid >= new.amount_owed then
      new.status := 'paid';
      if new.paid_at is null then new.paid_at := now(); end if;
    elsif new.amount_paid > 0 then
      new.status := 'partial';
    else
      new.status := 'owed';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists cb_payouts_before_write_trg on public.cb_payouts;
create trigger cb_payouts_before_write_trg
  before insert or update on public.cb_payouts
  for each row execute function public.cb_payouts_before_write();

-- ── 6.5 · updated_at on the remaining tables ───────────────────────────────
drop trigger if exists cb_tenants_touch    on public.cb_tenants;
create trigger cb_tenants_touch    before update on public.cb_tenants
  for each row execute function public.cb_touch_updated_at();

drop trigger if exists cb_consignors_touch on public.cb_consignors;
create trigger cb_consignors_touch before update on public.cb_consignors
  for each row execute function public.cb_touch_updated_at();

drop trigger if exists cb_purchases_touch  on public.cb_purchases;
create trigger cb_purchases_touch  before update on public.cb_purchases
  for each row execute function public.cb_touch_updated_at();


-- ═══════════════════════════════════════════════════════════════════════════
-- 7 · RESERVATION RELEASE (PLAN.md §5 Q3)
--
-- ⚠ REQUIRES pg_cron. Enable it BEFORE running this file:
--     Supabase dashboard → Database → Extensions → search "pg_cron" → toggle ON.
--   If it is not enabled, the cron.unschedule / cron.schedule calls at the end
--   of this section fail with `schema "cron" does not exist` and the script
--   stops here — leaving §8-§13 (RPCs, RLS policies, public views, storage,
--   seed) UNAPPLIED. That is a half-configured database with tables but no
--   policies, so fix the extension and re-run the whole file rather than
--   resuming from the middle.
--
--   To apply everything EXCEPT the schedule (e.g. you want to defer cron),
--   comment out the two cron.* statements at the end of this section. The
--   release function itself has no pg_cron dependency and can be invoked
--   manually: select public.cb_release_expired_reservations();
--
-- TWO-LAYER DESIGN, deliberately. The cron job is the bookkeeper; the view
-- predicate is the truth. Between sweeps an expired hold would otherwise still
-- read as 'reserved' on the storefront, so cb_public_items (§10) computes
-- effective status live. The job then makes it durable so admin lists, the
-- expiry index, and any report agree.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.cb_release_expired_reservations()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  with released as (
    update public.cb_items
       set status = 'available'
     where status = 'reserved'
       and reserved_until is not null
       and reserved_until < now()
    returning 1
  )
  select count(*) into v_count from released;
  -- The §6.2 trigger clears reserved_* on the way out of 'reserved'.
  return v_count;
end $$;

revoke execute on function public.cb_release_expired_reservations() from public, anon, authenticated;

-- Hourly sweep. Hourly, not per-minute: the hold window is measured in days,
-- so an expired item is visibly available immediately (via the view) and
-- bookkeeping catches up within the hour.
select cron.unschedule('cb-release-expired-reservations')
  where exists (select 1 from cron.job where jobname = 'cb-release-expired-reservations');

select cron.schedule(
  'cb-release-expired-reservations',
  '7 * * * *',
  $cron$ select public.cb_release_expired_reservations(); $cron$
);


-- ═══════════════════════════════════════════════════════════════════════════
-- 8 · RPCs — the only write paths open to anon
--
-- anon is NEVER granted UPDATE on cb_items. Reserving an item goes through
-- cb_reserve_item(), which validates the item is actually reservable and sets
-- every hold field atomically. A raw anon UPDATE policy could not prevent a
-- visitor from also rewriting price or status in the same statement.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 8.1 · Atomic city claim ────────────────────────────────────────────────
create or replace function public.cb_claim_city(
  p_city_label text,
  p_state      text,
  p_client_id  text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.cb_city_claims (city_label, state, client_id, status)
  values (p_city_label, upper(p_state), p_client_id, 'claimed');
  return jsonb_build_object('ok', true, 'city', p_city_label, 'state', upper(p_state));
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'reason', 'already_claimed',
                              'city', p_city_label, 'state', upper(p_state));
end $$;

revoke execute on function public.cb_claim_city(text,text,text) from public, anon, authenticated;
-- Called only by the provision-buyer Edge Function using the service_role key,
-- after Stripe confirms payment. Never exposed to a browser.

-- ── 8.2 · Reserve an item ──────────────────────────────────────────────────
create or replace function public.cb_reserve_item(
  p_item_id uuid,
  p_name    text,
  p_email   text,
  p_phone   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item  public.cb_items%rowtype;
  v_days  integer;
  v_until timestamptz;
begin
  if p_name is null or btrim(p_name) = '' or p_email is null or btrim(p_email) = '' then
    return jsonb_build_object('ok', false, 'reason', 'missing_contact');
  end if;

  -- Lock the row so two simultaneous reservers cannot both win.
  select * into v_item from public.cb_items where id = p_item_id for update;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  if v_item.purchase_mode <> 'reserve_pickup' then
    return jsonb_build_object('ok', false, 'reason', 'not_reservable');
  end if;

  -- An expired hold is treated as available even if the sweep has not run.
  if v_item.status = 'reserved'
     and v_item.reserved_until is not null
     and v_item.reserved_until >= now() then
    return jsonb_build_object('ok', false, 'reason', 'already_reserved');
  end if;
  if v_item.status not in ('available','reserved') then
    return jsonb_build_object('ok', false, 'reason', 'not_available');
  end if;

  select reserve_hold_days into v_days
    from public.cb_tenants where client_id = v_item.client_id;
  v_until := now() + make_interval(days => coalesce(v_days, 3));

  update public.cb_items
     set status            = 'reserved',
         reserved_until    = v_until,
         reserved_by       = p_name,
         reserved_by_email = p_email,
         reserved_by_phone = p_phone,
         reserved_at       = now()
   where id = p_item_id;

  return jsonb_build_object('ok', true, 'reserved_until', v_until,
                            'hold_days', coalesce(v_days, 3));
end $$;

revoke execute on function public.cb_reserve_item(uuid,text,text,text) from public;
grant  execute on function public.cb_reserve_item(uuid,text,text,text) to anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- 9 · ROW LEVEL SECURITY
--
-- Same end state as EstateSaleBiz: anon can READ nothing from any base table
-- (public reads go through the §10 views) and can INSERT only what a public
-- form legitimately submits. Every table is swept name-agnostically first,
-- because policies accumulate across sessions and a hard-coded drop list
-- silently leaves strays in place. RLS stays enabled throughout the sweep, so
-- the tables are deny-all in between — fail-safe, no anon window opens.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.cb_tenants         enable row level security;
alter table public.cb_platform_admins enable row level security;
alter table public.cb_client_users    enable row level security;
alter table public.cb_city_claims     enable row level security;
alter table public.cb_categories      enable row level security;
alter table public.cb_consignors      enable row level security;
alter table public.cb_items           enable row level security;
alter table public.cb_photos          enable row level security;
alter table public.cb_purchases       enable row level security;
alter table public.cb_payouts         enable row level security;
alter table public.cb_billing         enable row level security;

do $$
declare r record;
begin
  for r in
    select policyname, tablename
    from pg_policies
    where schemaname = 'public'
      and tablename in ('cb_tenants','cb_platform_admins','cb_client_users','cb_city_claims',
                        'cb_categories','cb_consignors','cb_items','cb_photos',
                        'cb_purchases','cb_payouts','cb_billing')
  loop
    execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

-- ── cb_tenants ─────────────────────────────────────────────────────────────
create policy "tenant reads own tenant row" on public.cb_tenants
  for select to authenticated using (public.cb_is_tenant(client_id) or public.cb_is_admin());
create policy "tenant updates own tenant row" on public.cb_tenants
  for update to authenticated
  using      (public.cb_is_tenant(client_id) or public.cb_is_admin())
  with check (public.cb_is_tenant(client_id) or public.cb_is_admin());
create policy "admin inserts tenants" on public.cb_tenants
  for insert to authenticated with check (public.cb_is_admin());
create policy "admin deletes tenants" on public.cb_tenants
  for delete to authenticated using (public.cb_is_admin());
-- No anon policy: storefront branding is read through cb_public_tenants (§10).

-- ── cb_platform_admins ─────────────────────────────────────────────────────
-- Read-only even to admins. Rows are added from the dashboard/service_role
-- only, so an admin account cannot quietly promote another account.
create policy "admin reads admin list" on public.cb_platform_admins
  for select to authenticated using (public.cb_is_admin());

-- ── cb_client_users ────────────────────────────────────────────────────────
create policy "user reads own mapping" on public.cb_client_users
  for select to authenticated
  using (user_id = (select auth.uid()) or public.cb_is_admin());
-- No insert/update policy for anyone: mappings are created by the
-- provision-buyer Edge Function via service_role, which bypasses RLS. An
-- operator can never rewrite their own client_id and adopt another territory.

-- ── cb_city_claims ─────────────────────────────────────────────────────────
create policy "admin manages city claims" on public.cb_city_claims
  for all to authenticated
  using (public.cb_is_admin()) with check (public.cb_is_admin());
create policy "tenant reads own claim" on public.cb_city_claims
  for select to authenticated using (client_id is not null and public.cb_is_tenant(client_id));
-- The public availability check on index.html reads cb_public_city_claims (§10).

-- ── cb_categories ──────────────────────────────────────────────────────────
create policy "tenant manages own categories" on public.cb_categories
  for all to authenticated
  using      (client_id is not null and public.cb_is_tenant(client_id))
  with check (client_id is not null and public.cb_is_tenant(client_id));
create policy "admin manages global categories" on public.cb_categories
  for all to authenticated
  using (public.cb_is_admin()) with check (public.cb_is_admin());
create policy "authenticated reads categories" on public.cb_categories
  for select to authenticated
  using (client_id is null or public.cb_is_tenant(client_id) or public.cb_is_admin());

-- ── cb_consignors ──────────────────────────────────────────────────────────
create policy "tenant manages consignors" on public.cb_consignors
  for all to authenticated
  using      (public.cb_is_tenant(client_id) or public.cb_is_admin())
  with check (public.cb_is_tenant(client_id) or public.cb_is_admin());

-- Public consign.html creates the consignor row alongside the item. Write-only:
-- there is no anon SELECT policy, so a visitor can add a row but can never read
-- the consignor list back.
create policy "anon submits consignor" on public.cb_consignors
  for insert to anon
  with check (
    payout_percentage is null                       -- cannot forge their own split
    and exists (
      select 1 from public.cb_tenants t
      where t.client_id = cb_consignors.client_id and t.is_active
    )
  );

-- ── cb_items ───────────────────────────────────────────────────────────────
create policy "tenant manages items" on public.cb_items
  for all to authenticated
  using      (public.cb_is_tenant(client_id) or public.cb_is_admin())
  with check (public.cb_is_tenant(client_id) or public.cb_is_admin());

-- The public consignment submission. Every field a visitor could abuse is
-- pinned: they may only create a pending, unapproved, unsold, unreserved item
-- with no payout percentage, attached to a consignor, for an active tenant.
create policy "anon submits consignment item" on public.cb_items
  for insert to anon
  with check (
    status = 'pending'
    and consignor_id is not null
    and payout_percentage is null
    and approved_at is null
    and approved_by is null
    and sold_at is null
    and reserved_until is null
    and reserved_by is null
    and exists (
      select 1 from public.cb_tenants t
      where t.client_id = cb_items.client_id and t.is_active
    )
  );
-- Note: anon has NO update policy. Reservations go through cb_reserve_item().

-- ── cb_photos ──────────────────────────────────────────────────────────────
create policy "tenant manages photos" on public.cb_photos
  for all to authenticated
  using      (public.cb_is_tenant(client_id) or public.cb_is_admin())
  with check (public.cb_is_tenant(client_id) or public.cb_is_admin());

create policy "anon submits photo for pending item" on public.cb_photos
  for insert to anon
  with check (
    exists (
      select 1 from public.cb_items i
      where i.id = cb_photos.item_id
        and i.client_id = cb_photos.client_id
        and i.status = 'pending'      -- only onto a still-unreviewed submission
    )
  );

-- ── cb_purchases ───────────────────────────────────────────────────────────
create policy "tenant reads purchases" on public.cb_purchases
  for select to authenticated using (public.cb_is_tenant(client_id) or public.cb_is_admin());
create policy "tenant updates purchases" on public.cb_purchases
  for update to authenticated
  using      (public.cb_is_tenant(client_id) or public.cb_is_admin())
  with check (public.cb_is_tenant(client_id) or public.cb_is_admin());
-- No insert policy for anyone: purchase rows are written by the Stripe webhook
-- handler via service_role. A browser must never be able to mint a paid row.

-- ── cb_payouts ─────────────────────────────────────────────────────────────
create policy "tenant manages payouts" on public.cb_payouts
  for all to authenticated
  using      (public.cb_is_tenant(client_id) or public.cb_is_admin())
  with check (public.cb_is_tenant(client_id) or public.cb_is_admin());
-- Consignors have no login (PLAN.md §5 Q4), so there is no consignor-facing
-- read path here. If that ever changes, add a policy keyed to a consignor
-- access token rather than widening this one.

-- ── cb_billing ─────────────────────────────────────────────────────────────
create policy "tenant reads own billing" on public.cb_billing
  for select to authenticated using (public.cb_is_tenant(client_id) or public.cb_is_admin());
create policy "admin manages billing" on public.cb_billing
  for all to authenticated
  using (public.cb_is_admin()) with check (public.cb_is_admin());


-- ═══════════════════════════════════════════════════════════════════════════
-- 10 · PUBLIC READ VIEWS
--
-- Mirrors ESB's fix8-public-views.sql exactly in mechanism: security_invoker =
-- false means the views run with definer (owner) rights and bypass base-table
-- RLS; anon is granted SELECT on the VIEWS ONLY. After this, anon has no direct
-- read path to any cb_ base table.
--
-- Because these views ARE the public surface, the column lists are the security
-- boundary. Anything omitted below is invisible to the internet — noted inline.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Storefront branding ────────────────────────────────────────────────────
create or replace view public.cb_public_tenants
  with (security_invoker = false) as
  select client_id, city_label, state, business_name, tagline, about_text,
         logo_url, primary_color, public_email, public_phone, hours_text,
         custom_domain, reserve_hold_days
  from public.cb_tenants
  where is_active;
-- OMITTED: pickup_address (revealed only after purchase/reservation),
-- default_payout_percentage and payout_terms_text (operator's business terms,
-- not buyer-facing), custom_domain_status, id, timestamps.

-- ── Territory availability for index.html ──────────────────────────────────
create or replace view public.cb_public_city_claims
  with (security_invoker = false) as
  select lower(city_label) as city_key, upper(state) as state, status
  from public.cb_city_claims
  where status in ('claimed','reserved');
-- OMITTED: client_id. A visitor learns a city is taken, never by whom.

-- ── Category taxonomy, so the HTML pickers stay in sync with the DB ────────
create or replace view public.cb_public_categories
  with (security_invoker = false) as
  select client_id, slug, label, display_order
  from public.cb_categories
  where is_active;

-- ── Items ──────────────────────────────────────────────────────────────────
-- effective_status is the live expiry check described in §7: an item whose hold
-- has lapsed reads as 'available' to the public the instant it lapses, without
-- waiting for the hourly sweep.
create or replace view public.cb_public_items
  with (security_invoker = false) as
  select i.id,
         i.client_id,
         i.category_slug,
         i.name,
         i.condition,
         i.description,
         i.dimensions,
         i.price,
         i.purchase_mode,
         case
           when i.status = 'reserved'
                and i.reserved_until is not null
                and i.reserved_until < now() then 'available'
           else i.status
         end as status,
         i.display_order,
         i.sold_at,
         i.created_at
  from public.cb_items i
  join public.cb_tenants t on t.client_id = i.client_id and t.is_active
  where i.status in ('available','reserved','sold');
-- OMITTED: consignor_id and asking_price (never expose who consigned an item
-- or what they hoped to get), payout_percentage, reserved_by/_email/_phone
-- (another buyer's contact details), reserved_until (a countdown invites
-- sniping), approved_by, approved_at.
-- 'pending' and 'rejected' items are excluded by the WHERE clause entirely.

-- ── Photos ─────────────────────────────────────────────────────────────────
create or replace view public.cb_public_photos
  with (security_invoker = false) as
  select p.id, p.client_id, p.item_id, p.photo_url, p.display_order, p.is_featured, p.created_at
  from public.cb_photos p
  join public.cb_items i   on i.id = p.item_id
  join public.cb_tenants t on t.client_id = i.client_id and t.is_active
  where i.status in ('available','reserved','sold');
-- Photos of pending/rejected submissions are never public.

grant select on
  public.cb_public_tenants,
  public.cb_public_city_claims,
  public.cb_public_categories,
  public.cb_public_items,
  public.cb_public_photos
to anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- 11 · STORAGE
--
-- Public bucket, matching ESB's shipped state (its private-bucket migration in
-- supabase-multitenant-rls.sql STEP 5b is still commented out there). Item
-- photos are meant to be seen by shoppers, so public read is correct here and
-- getPublicUrl() works without signed URLs.
--
-- ANON UPLOAD IS HARDENED IN TWO LAYERS, because neither alone is sufficient:
--
--   Layer 1 — BUCKET CONFIG (file_size_limit + allowed_mime_types).
--     This is the REAL enforcement for size and content type. The Storage API
--     validates both server-side, before the object row is ever written. RLS
--     cannot do this job: storage.objects.metadata (which carries size and
--     mimetype) is not reliably populated at the moment the INSERT policy is
--     evaluated, so a WITH CHECK on metadata would be trivially bypassable.
--
--   Layer 2 — POLICY WITH CHECK (path prefix + filename extension).
--     This is what stops the bucket becoming open file hosting. It confines
--     every anon write to the `submissions/` prefix and to image extensions,
--     so anon cannot overwrite an operator's approved item photos elsewhere in
--     the bucket, and cannot park a .zip/.exe/.html payload here even if the
--     declared MIME type is spoofed past layer 1.
--
--   Neither layer catches everything on its own: layer 1 checks the bytes but
--   not the path, layer 2 checks the path but not the bytes. Together the
--   answer to "can anon use this as free file hosting?" is no.
--
-- V2 HARDENING — RECOMMENDED, not required to ship: move the consignor upload
-- behind an Edge Function that takes the file, validates it server-side (magic
-- bytes, not just the declared MIME), writes it with the service_role key, and
-- rate-limits by IP. Then drop the anon INSERT policy entirely and the bucket
-- has no anonymous write path at all. Worth doing once real submission volume
-- exists; the two layers below are the correct v1 position.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── LAYER 1 · Bucket config — 5 MB cap, images only ────────────────────────
-- 5242880 bytes = 5 MB. allowed_mime_types is enforced by the Storage API on
-- upload; an upload declaring anything else is rejected before it lands.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'cb-item-photos',
  'cb-item-photos',
  true,
  5242880,
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do update set
  public             = true,
  file_size_limit    = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
-- The `do update` matters: if the bucket already exists from an earlier run,
-- a bare `do nothing` would silently leave it uncapped and accepting any type.

-- ── Public read ────────────────────────────────────────────────────────────
drop policy if exists "public read cb item photos" on storage.objects;
create policy "public read cb item photos" on storage.objects
  for select using (bucket_id = 'cb-item-photos');

-- ── LAYER 2 · anon upload — confined to submissions/, images only ──────────
-- Needed for consign.html's photo upload, which happens before any account
-- exists. Every anon-writable path is pinned here.
drop policy if exists "anon upload cb item photos" on storage.objects;
create policy "anon upload cb item photos" on storage.objects
  for insert to anon
  with check (
    bucket_id = 'cb-item-photos'
    -- Confine anon writes to one folder. Operator-uploaded photos live outside
    -- it, so a visitor can never overwrite or displace approved item imagery.
    and (storage.foldername(name))[1] = 'submissions'
    -- Extension allowlist. Belt to layer 1's MIME braces: blocks .html (stored
    -- XSS off a public bucket URL), .svg (scriptable), archives, executables.
    and name ~* '\.(jpe?g|png|webp)$'
    -- No path traversal or nested trickery in the object key.
    and name !~ '\.\.'
  );

-- ── Operator upload/delete — full bucket, authenticated only ───────────────
drop policy if exists "authenticated upload cb item photos" on storage.objects;
create policy "authenticated upload cb item photos" on storage.objects
  for insert to authenticated with check (bucket_id = 'cb-item-photos');

drop policy if exists "authenticated delete cb item photos" on storage.objects;
create policy "authenticated delete cb item photos" on storage.objects
  for delete to authenticated using (bucket_id = 'cb-item-photos');


-- ═══════════════════════════════════════════════════════════════════════════
-- 12 · SEED — starter category taxonomy (PLAN.md §5 Q5)
--
-- TUNE THIS LIST. These are the platform-global categories (client_id null)
-- every tenant inherits. Slugs are the stable key stored on cb_items; labels
-- are display-only and safe to reword any time. Renaming a label never touches
-- an item row — that is the main reason this is a table and not a check
-- constraint.
--
-- To add:     insert into cb_categories (slug, label, display_order) values ('lighting','Lighting',90);
-- To retire:  update cb_categories set is_active = false where slug = 'electronics';
--             (deactivating keeps existing items valid and readable; deleting
--              would orphan their category_slug)
-- ═══════════════════════════════════════════════════════════════════════════

insert into public.cb_categories (client_id, slug, label, display_order) values
  (null, 'furniture',              'Furniture',                10),
  (null, 'vintage-clothing',       'Vintage Clothing',         20),
  (null, 'jewelry-accessories',    'Jewelry & Accessories',    30),
  (null, 'home-decor',             'Home Decor',               40),
  (null, 'kitchen-dining',         'Kitchen & Dining',         50),
  (null, 'art-wall-decor',         'Art & Wall Decor',         60),
  (null, 'collectibles-antiques',  'Collectibles & Antiques',  70),
  (null, 'rugs-textiles',          'Rugs & Textiles',          80),
  (null, 'lighting',               'Lighting',                 90),
  (null, 'books-media',            'Books & Media',           100),
  (null, 'toys-games',             'Toys & Games',            110),
  (null, 'tools-hardware',         'Tools & Hardware',        120),
  (null, 'outdoor-garden',         'Outdoor & Garden',        130),
  (null, 'electronics',            'Electronics',             140),
  (null, 'other',                  'Other',                   999)
on conflict do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- 13 · VERIFY — run after the file completes; confirm against the ledger
-- ═══════════════════════════════════════════════════════════════════════════

-- 13.1 · Every policy that now exists.
select tablename, policyname, cmd, roles
from pg_policies
where schemaname = 'public' and tablename like 'cb_%'
order by tablename, policyname;

-- EXPECTED — the ONLY policies granting anon anything, all INSERT-only:
--   cb_consignors : anon submits consignor
--   cb_items      : anon submits consignment item
--   cb_photos     : anon submits photo for pending item
-- NO policy anywhere grants anon SELECT. Public reads go through the §10 views.

-- 13.2 · Confirm RLS is on for every table (rls_enabled must be true for all).
select relname as table_name, relrowsecurity as rls_enabled
from pg_class
where relnamespace = 'public'::regnamespace
  and relname like 'cb_%'
  and relkind = 'r'
order by relname;

-- 13.3 · Confirm no foreign key is missing its index (must return zero rows).
select conrelid::regclass as table_name, a.attname as unindexed_fk_column
from pg_constraint c
join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
where c.contype = 'f'
  and conrelid::regclass::text like 'cb_%'
  and not exists (
    select 1 from pg_index i
    where i.indrelid = c.conrelid and a.attnum = any(i.indkey)
  );

-- 13.4 · Confirm the reservation sweep is scheduled.
select jobname, schedule, active from cron.job where jobname = 'cb-release-expired-reservations';

-- 13.4b · Confirm the storage bucket is actually capped and type-restricted.
-- EXPECTED: file_size_limit = 5242880, allowed_mime_types = {image/jpeg,image/png,image/webp}
-- If either is null the bucket is accepting anything — re-run §11.
select id, public, file_size_limit, allowed_mime_types
from storage.buckets where id = 'cb-item-photos';

-- 13.5 · Confirm the seeded taxonomy.
select slug, label, display_order from public.cb_categories where client_id is null order by display_order;

-- ═══════════════════════════════════════════════════════════════════════════
-- DONE.
-- Next steps, in order:
--   1. Create your owner auth user (Authentication → Users → Add user).
--   2. insert into cb_platform_admins (user_id, label)
--        values ('<YOUR-AUTH-UID>', 'Jason Vega');
--   3. Verify cb_is_admin() returns true for that session.
--   4. Wire provision-buyer to call cb_claim_city() with the service_role key.
-- ═══════════════════════════════════════════════════════════════════════════
