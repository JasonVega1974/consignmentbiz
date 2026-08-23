-- ═══════════════════════════════════════════════════════════════════════════
-- FIX 1 — anon consignment write path (42501 on insert)
--
-- SYMPTOM
--   POST /rest/v1/cb_consignors as anon → 401, PostgREST code 42501
--   ("new row violates row-level security policy"), despite a payload that
--   satisfies every visible condition of the WITH CHECK.
--
-- ROOT CAUSE
--   An RLS policy expression is evaluated AS THE CALLING ROLE. Any table named
--   inside the expression is still subject to its own RLS. All three anon
--   INSERT policies did an exists() against a table anon cannot read:
--
--     anon submits consignor            → exists(... from cb_tenants ...)
--     anon submits consignment item     → exists(... from cb_tenants ...)
--     anon submits photo for pending…   → exists(... from cb_items ...)
--
--   anon has NO select policy on cb_tenants or cb_items — by design (schema §9,
--   "Public reads go through the §10 views"). So each subquery returns zero
--   rows, exists() is false, the WITH CHECK fails, and Postgres raises 42501.
--   The submitted data was never the problem.
--
-- FIX
--   Move each existence check into a SECURITY DEFINER function. Those run with
--   the function owner's rights and therefore bypass the base-table RLS that
--   anon cannot satisfy — the same pattern already used by cb_is_tenant() and
--   cb_is_admin() in schema §4. The policies keep exactly the same semantics;
--   only the mechanism of the lookup changes.
--
-- Idempotent. Safe to re-run. Run in Supabase → SQL Editor.
-- ═══════════════════════════════════════════════════════════════════════════


-- ── 1 · HELPER FUNCTIONS ────────────────────────────────────────────────────
-- Must be created BEFORE the policies below reference them. Both are
-- `language sql`, whose bodies are resolved at CREATE time, so the tables they
-- name must already exist — they do, on the live database.

-- "Is this an active tenant that accepts public submissions?"
-- Leaks only whether a client_id exists and is active — already public via
-- cb_public_tenants, so this exposes nothing new to anon.
create or replace function public.cb_tenant_accepts_submissions(p_client_id text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.cb_tenants
    where client_id = p_client_id
      and is_active
  );
$$;

-- "Is this item a still-unreviewed submission belonging to this tenant?"
-- Gates photo uploads onto pending items only. Leaks whether a given item UUID
-- is pending for a given client_id; UUIDs are unguessable and the caller just
-- created the row, so this is not a meaningful disclosure.
create or replace function public.cb_item_is_pending_submission(p_item_id uuid, p_client_id text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.cb_items
    where id = p_item_id
      and client_id = p_client_id
      and status = 'pending'
  );
$$;

-- anon must be able to CALL these — they are invoked by anon inside the
-- policies below. Revoke from PUBLIC so nothing else picks them up implicitly.
revoke execute on function public.cb_tenant_accepts_submissions(text)            from public;
revoke execute on function public.cb_item_is_pending_submission(uuid,text)       from public;
grant  execute on function public.cb_tenant_accepts_submissions(text)            to anon, authenticated;
grant  execute on function public.cb_item_is_pending_submission(uuid,text)       to anon, authenticated;


-- ── 2 · REPLACE THE THREE POLICIES ──────────────────────────────────────────
-- Postgres has no "create or replace policy", so each is dropped by name first.
-- Every other conjunct is byte-identical to the original: only the exists()
-- subquery is swapped for the function call.

drop policy if exists "anon submits consignor" on public.cb_consignors;
create policy "anon submits consignor" on public.cb_consignors
  for insert to anon
  with check (
    payout_percentage is null                       -- cannot forge their own split
    and public.cb_tenant_accepts_submissions(client_id)
  );

drop policy if exists "anon submits consignment item" on public.cb_items;
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
    and public.cb_tenant_accepts_submissions(client_id)
  );

drop policy if exists "anon submits photo for pending item" on public.cb_photos;
create policy "anon submits photo for pending item" on public.cb_photos
  for insert to anon
  with check (
    public.cb_item_is_pending_submission(item_id, client_id)
  );


-- ── 3 · TABLE-LEVEL GRANTS (belt and braces) ────────────────────────────────
-- A policy without the underlying table privilege raises the SAME 42501, so
-- these are stated explicitly rather than relying on Supabase's default
-- privileges. No-op if the defaults already cover it.
--
-- INSERT ONLY. Do NOT add select here: anon reading these base tables is
-- exactly what the §10 public views exist to prevent.
grant insert on public.cb_consignors to anon;
grant insert on public.cb_items      to anon;
grant insert on public.cb_photos     to anon;


-- ── 4 · VERIFY ──────────────────────────────────────────────────────────────

-- 4.1 · The helper now answers true for an active tenant, even as anon.
--       EXPECT: tenant_ok = true.
--       Wrapped in a transaction because SET LOCAL outside one is a no-op that
--       only emits a warning — the role would never actually change.
begin;
  set local role anon;
  select public.cb_tenant_accepts_submissions('testshop') as tenant_ok;
rollback;

-- 4.2 · Policy ledger — all three PERMISSIVE, anon, INSERT only.
select tablename, policyname, cmd, permissive, roles
from pg_policies
where schemaname = 'public'
  and tablename in ('cb_consignors','cb_items','cb_photos')
order by tablename, policyname;

-- 4.3 · anon holds INSERT and NOT select on the write-path tables.
--       EXPECT: exactly one INSERT row per table, no SELECT rows.
select table_name, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('cb_consignors','cb_items','cb_photos')
  and grantee = 'anon'
order by table_name, privilege_type;

-- 4.4 · End-to-end rehearsal as anon. Rolls back, so it leaves nothing behind.
--       EXPECT: both inserts succeed. If 42501 persists, the cause is NOT this.
begin;
  set local role anon;
  insert into public.cb_consignors (id, client_id, name, email)
  values ('00000000-0000-4000-8000-00000000cb01', 'testshop', 'RLS Rehearsal', 'test@example.com');

  insert into public.cb_items (id, client_id, consignor_id, status, name, price)
  values ('00000000-0000-4000-8000-00000000cb02', 'testshop',
          '00000000-0000-4000-8000-00000000cb01', 'pending', 'RLS Rehearsal Item', 0);
rollback;

-- ═══════════════════════════════════════════════════════════════════════════
-- DONE. Re-test the consign.html submission after this runs.
-- ═══════════════════════════════════════════════════════════════════════════
