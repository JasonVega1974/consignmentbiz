# ConsignmentBiz — PLAN.md

**Domain:** consignmentbiz.com
**Status:** Scoping only — no code written yet.
**Stack:** Vanilla HTML + Supabase + Stripe + Brevo + Vercel (same as EstateSaleBiz / GarageSaleBiz)
**Table prefix:** `cb_`
**Owner:** Kingdom Creatives LLC / SystemsByVega catalog

---

## 1. Product Definition

Territory-exclusive turnkey platform for operators who run local consignment / vintage resale businesses — think a curated pop-up shop or standing consignment storefront (vintage clothing, furniture, collectibles, home goods) rather than a one-time liquidation event.

**Key difference from EstateSaleBiz/GarageSaleBiz:** those platforms are built around single, time-boxed *sale events* (a weekend estate sale, a garage sale). ConsignmentBiz is built around a **standing inventory storefront** — items are added and sold continuously, not tied to one sale date. This is closer to a small e-commerce shop than an event listing site.

**What's identical to EstateSaleBiz:**
- Territory-exclusive, one operator per city
- Subdomain-per-tenant provisioning (`{operator}.consignmentbiz.com`)
- Buyer flow: browse → item detail → purchase
- Consignor intake form → operator approval queue (mirrors EstateSaleBiz's public intake → admin approval pattern)
- Stripe Checkout for fixed-price purchases (no card-on-file, no bidding — sidesteps the liability class flagged and rejected for LocalAuctionBiz)
- Brevo transactional email (welcome, purchase confirmation, consignor status updates)
- Vercel hosting, Supabase auth/db/storage
- Operator admin dashboard pattern (stat cards, item management, tenant settings)
- `provision-buyer` Edge Function pattern for auth + tenant creation on purchase

**What's genuinely different:**
- **No event/sale date model.** Items live in a continuous storefront, not scoped to a single `sale_id` with start/end dates.
- **Purchase mode is per-item** (per your answer): `fixed_price` (Stripe Checkout, instant) or `reserve_pickup` (buyer reserves, pays operator in person — no Stripe transaction on the platform side).
- **Consignor relationship is ongoing**, not one-time. A consignor may submit items repeatedly over time, so consignors need a lightweight identity (name/contact tied to their submissions) even without a full auth account.
- **Payout/split tracking**, if operators pay consignors a percentage of the sale — flagged as an open question below, since this doesn't exist in EstateSaleBiz's model at all.

---

## 2. Tenant Model

Mirrors EstateSaleBiz exactly:
- One `cb_tenants` row per operator, one `cb_client_users` row linking `auth.users` to a tenant
- Subdomain resolution via Vercel wildcard + middleware hostname lookup (same pattern as EstateSaleBiz/YourLife CC)
- Territory exclusivity enforced via atomic city claim (mirrors `esb_city_claims`)
- Pricing: **$197 one-time** (per your direction — lower entry price point than EstateSaleBiz's $497)
- **Open question:** is there an optional monthly hosting fee, same as the other two platforms, or is $197 the entire lifetime cost? This materially affects whether `cb_billing` needs a recurring Stripe subscription object or just a single one-time payment record.

---

## 3. Pages Needed

**Public-facing:**
- `index.html` — marketing/landing page (mirrors EstateSaleBiz's SystemsByVega catalog page)
- `intake.html` — buyer purchase flow (operator becomes a tenant) — mirrors EstateSaleBiz intake
- `thank-you.html` — post-purchase confirmation
- `{subdomain}.consignmentbiz.com/` — tenant's public storefront (item grid, filter by category/price)
- `{subdomain}.../item.html?id=` — individual item detail page
- `{subdomain}.../consign.html` — public consignor intake form (submit item for approval)
- `{subdomain}.../about.html` — operator's storefront about/contact page

**Operator-facing (authenticated):**
- `admin.html` — operator dashboard: stat cards, item list, consignor approval queue
- `admin-items.html` (or a section of admin.html) — add/edit/remove items, mark sold, set purchase mode per item
- `admin-consignors.html` (or section) — approve/reject submitted items, track consignor contact info
- `admin-settings.html` — tenant branding, contact info, payout terms display (if applicable)

**Internal/owner:**
- `admin-owner.html` — mirrors EstateSaleBiz's owner dashboard (PIN → Supabase login → `cb_is_admin()`)

---

## 4. Proposed Supabase Schema (draft — not final, pending open questions below)

```sql
-- Tenant / operator — one row per purchased territory
create table cb_tenants (
  id uuid primary key default gen_random_uuid(),
  client_id text unique not null,           -- slug, e.g. 'braden'
  city_label text not null,
  state text not null,
  business_name text,
  custom_domain text unique,
  is_active boolean not null default true,
  created_at timestamptz default now()
);

-- Auth linkage — mirrors esb_client_users
create table cb_client_users (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  client_id text not null references cb_tenants(client_id),
  role text not null default 'operator',
  created_at timestamptz default now(),
  unique(user_id, client_id)
);

-- Territory exclusivity — mirrors esb_city_claims
create table cb_city_claims (
  id uuid primary key default gen_random_uuid(),
  city_label text not null,
  state text not null,
  client_id text references cb_tenants(client_id),
  claimed_at timestamptz default now(),
  unique(city_label, state)
);

-- Consignors — lightweight identity, not a full auth account
create table cb_consignors (
  id uuid primary key default gen_random_uuid(),
  client_id text not null references cb_tenants(client_id),
  name text not null,
  email text,
  phone text,
  notes text,
  created_at timestamptz default now()
);

-- Items — the core inventory table, no event/sale_id scoping
create table cb_items (
  id uuid primary key default gen_random_uuid(),
  client_id text not null references cb_tenants(client_id),
  consignor_id uuid references cb_consignors(id),   -- null if operator-sourced
  name text not null,
  category text,
  condition text,
  description text,
  price numeric(10,2) not null,
  purchase_mode text not null default 'fixed_price', -- 'fixed_price' | 'reserve_pickup'
  status text not null default 'pending',            -- pending | approved | rejected | available | sold
  approved_at timestamptz,
  approved_by uuid references auth.users(id),
  sold_at timestamptz,
  created_at timestamptz default now()
);

-- Item photos — mirrors esb_photos
create table cb_photos (
  id uuid primary key default gen_random_uuid(),
  client_id text not null references cb_tenants(client_id),
  item_id uuid not null references cb_items(id) on delete cascade,
  photo_url text not null,
  display_order int default 0,
  is_featured boolean default false,
  created_at timestamptz default now()
);

-- Purchases — for fixed_price items only (Stripe Checkout)
create table cb_purchases (
  id uuid primary key default gen_random_uuid(),
  client_id text not null references cb_tenants(client_id),
  item_id uuid not null references cb_items(id),
  buyer_email text not null,
  stripe_session_id text unique,
  amount numeric(10,2) not null,
  status text not null default 'pending',   -- pending | paid | refunded
  created_at timestamptz default now()
);

-- Platform billing — the $197 one-time tenant purchase itself (mirrors esb_billing)
create table cb_billing (
  id uuid primary key default gen_random_uuid(),
  client_id text not null references cb_tenants(client_id),
  amount numeric(10,2) not null,
  stripe_session_id text unique,
  billing_type text not null default 'one_time',  -- one_time | (subscription, if hosting fee confirmed)
  created_at timestamptz default now()
);
```

**Public read views** (anon-safe, mirror `esb_public_sales`/`esb_public_items` pattern):
- `cb_public_items` — only `status = 'available'` or `'sold'` (sold shown as sold-out, not deleted), safe columns only
- `cb_public_photos` — scoped to items visible in `cb_public_items`

RLS pattern mirrors EstateSaleBiz throughout: tenant-scoped policies via `cb_is_tenant()`, admin via `cb_is_admin()`, public views run with `security_invoker = false` for anon access without exposing base tables directly.

---

## 5. Open Questions (need answers before schema is final)

1. **Monthly hosting fee** — does the $197 include hosting indefinitely, or is there a recurring fee like the other platforms? Affects whether `cb_billing` needs subscription tracking.
2. **Consignor payout split** — do operators pay consignors a percentage of each sale (e.g. 50/50, 60/40)? If yes, need a `payout_percentage` field (per-consignor or per-item) and a way to track what's owed vs. paid out. This is genuinely new — EstateSaleBiz has no analogous flow.
3. **Reserve-and-pickup items** — since no Stripe transaction happens for these, how does the operator mark an item "reserved" vs "sold" without a payment record? Need a manual status-change flow in admin, possibly with a reservation expiry (auto-release after X days if buyer doesn't show).
4. **Consignor accounts** — do consignors ever get their own login to check status/submit items directly, or is it always a one-off public form submission reviewed by the operator? Current draft assumes the latter (simpler, matches your "intake form for approval" answer), but confirm before RLS is designed.
5. **Item categories** — is there a fixed taxonomy (vintage clothing, furniture, collectibles, etc.) the platform should enforce, or free-text category per operator?
6. **Photos per item** — same multi-photo pattern as EstateSaleBiz (one featured + gallery), or single photo per item to keep v1 simpler?

---

*Once questions 1–4 are answered, schema is ready for your review before any SQL is run.*
