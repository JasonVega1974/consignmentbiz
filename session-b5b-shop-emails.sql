-- ═══════════════════════════════════════════════════════════════════════════
-- SESSION B5b — SHOP TRANSACTION EMAILS
--
-- Three flows: reserve confirmation, expiry reminder, operator sale alert.
-- Run this AFTER supabase-schema.sql. It is idempotent.
--
-- ┌───────────────────────────────────────────────────────────────────────┐
-- │ WHY AN OUTBOX AND NOT A DIRECT SEND                                   │
-- │                                                                       │
-- │ Nothing in this file talks to Brevo. The database decides WHAT to     │
-- │ send and writes a row; api/send-emails.js decides HOW and drains it.  │
-- │                                                                       │
-- │ The reason is atomicity. cb_reserve_item() already runs in a          │
-- │ transaction that locks the item row, so queueing the confirmation     │
-- │ inside that transaction means the email intent commits with the hold  │
-- │ or not at all. A buyer can close the tab the instant they submit and  │
-- │ still get their email — which is exactly the failure EstateSaleBiz    │
-- │ hit by provisioning from the browser, and the reason CB's Stripe      │
-- │ flow is a webhook.                                                    │
-- │                                                                       │
-- │ It also makes retries free: an unsent row is simply still there.      │
-- └───────────────────────────────────────────────────────────────────────┘
--
-- IDEMPOTENCY: every queue path writes ON CONFLICT (dedupe_key) DO NOTHING.
--   reserve  → one per (item, hold expiry)   — a re-reservation has a new expiry
--   reminder → one per (item, hold expiry)   — the hourly job cannot double-send
--   sale     → one per item                  — a re-sold item never re-alerts
--
-- PRIVACY: this table holds buyer names, email addresses and phone numbers.
--   RLS is enabled with NO policies, so anon and authenticated can read
--   nothing. Only service_role (which bypasses RLS) can reach it.
-- ═══════════════════════════════════════════════════════════════════════════


-- ── 1 · THE OUTBOX ─────────────────────────────────────────────────────────
create table if not exists public.cb_email_outbox (
  id          uuid primary key default gen_random_uuid(),
  client_id   text not null references public.cb_tenants(client_id) on delete cascade,
  kind        text not null,
  to_email    text not null,
  to_name     text,

  -- Everything the email needs to render, captured AT QUEUE TIME. Deliberate:
  -- an email is a record of what was true when it was sent. If the operator
  -- re-prices the item tomorrow, yesterday's confirmation must not silently
  -- change with it — and the sender needs no joins.
  payload     jsonb not null default '{}'::jsonb,

  dedupe_key  text not null unique,
  attempts    integer not null default 0,
  last_error  text,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz,

  constraint cb_email_outbox_kind
    check (kind in ('reserve_confirmation','expiry_reminder','sale_alert'))
);

-- The sender's only query: oldest unsent first. Partial, so it stays small
-- however much has already gone out.
create index if not exists cb_email_outbox_pending
  on public.cb_email_outbox (created_at)
  where sent_at is null;

create index if not exists cb_email_outbox_client
  on public.cb_email_outbox (client_id);

alter table public.cb_email_outbox enable row level security;
-- No policies, on purpose. See the PRIVACY note above.

revoke all on public.cb_email_outbox from anon, authenticated;


-- ── 2 · RESERVE CONFIRMATION ───────────────────────────────────────────────
-- cb_reserve_item() reproduced in full with one INSERT added before the
-- return. Everything above that insert is unchanged from supabase-schema.sql.
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
  v_item   public.cb_items%rowtype;
  v_days   integer;
  v_until  timestamptz;
  v_tenant public.cb_tenants%rowtype;
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

  select * into v_tenant from public.cb_tenants where client_id = v_item.client_id;
  v_days  := v_tenant.reserve_hold_days;
  v_until := now() + make_interval(days => coalesce(v_days, 3));

  update public.cb_items
     set status            = 'reserved',
         reserved_until    = v_until,
         reserved_by       = p_name,
         reserved_by_email = p_email,
         reserved_by_phone = p_phone,
         reserved_at       = now()
   where id = p_item_id;

  -- ── ADDED IN B5b ────────────────────────────────────────────────────────
  -- Same transaction as the UPDATE above: the buyer cannot end up holding an
  -- item with no confirmation queued, and a rollback takes both away.
  -- A failure here must not cost the buyer their reservation, so the insert
  -- is guarded — a missing email is worth logging, not worth refusing a hold.
  begin
    insert into public.cb_email_outbox (client_id, kind, to_email, to_name, dedupe_key, payload)
    values (
      v_item.client_id,
      'reserve_confirmation',
      p_email,
      p_name,
      'reserve:' || p_item_id::text || ':' || extract(epoch from v_until)::bigint::text,
      jsonb_build_object(
        'item_name',      v_item.name,
        'item_price',     v_item.price,
        'reserved_until', v_until,
        'hold_days',      coalesce(v_days, 3),
        'buyer_name',     p_name,
        'shop_name',      coalesce(v_tenant.business_name, 'the shop'),
        'shop_email',     v_tenant.public_email,
        'shop_phone',     v_tenant.public_phone,
        'shop_address',   v_tenant.pickup_address,
        'shop_hours',     v_tenant.hours_text
      )
    )
    on conflict (dedupe_key) do nothing;
  exception when others then
    raise warning 'cb_reserve_item: could not queue confirmation for %: %', p_item_id, sqlerrm;
  end;
  -- ────────────────────────────────────────────────────────────────────────

  return jsonb_build_object('ok', true, 'reserved_until', v_until,
                            'hold_days', coalesce(v_days, 3));
end $$;

revoke execute on function public.cb_reserve_item(uuid,text,text,text) from public;
grant  execute on function public.cb_reserve_item(uuid,text,text,text) to anon, authenticated;


-- ── 3 · OPERATOR SALE ALERT ────────────────────────────────────────────────
-- A SEPARATE trigger rather than an edit to cb_create_payout_on_sold(), so a
-- fault in the email path can never stop a payout row being written.
--
-- ⚠ ORDER MATTERS. This reads cb_payouts, which the payout trigger creates on
--   the same transition. PostgreSQL fires AFTER triggers in NAME order, and
--   'cb_items_payout_trg' sorts before 'cb_items_sale_alert_trg', so the
--   payout exists by the time this runs. Renaming either trigger breaks that,
--   and the symptom would be a sale alert with no payout figure — not an
--   error. The lookup below tolerates a missing payout for exactly that
--   reason, but the ordering is what makes it correct.
create or replace function public.cb_queue_sale_alert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant   public.cb_tenants%rowtype;
  v_payout   public.cb_payouts%rowtype;
  v_consignor text;
  v_to       text;
  v_to_name  text;
begin
  if new.status <> 'sold' then
    return null;
  end if;
  if tg_op = 'UPDATE' and old.status = 'sold' then
    return null;                      -- already sold; not a new transition
  end if;

  select * into v_tenant from public.cb_tenants where client_id = new.client_id;

  -- The operator's address is their sign-in address. role = 'operator'
  -- deliberately excludes 'staff': a shop assistant marking something sold
  -- should not redirect the owner's sales notifications to themselves.
  select u.email, cu.display_name
    into v_to, v_to_name
    from public.cb_client_users cu
    join auth.users u on u.id = cu.user_id
   where cu.client_id = new.client_id
     and cu.role = 'operator'
   order by cu.created_at
   limit 1;

  if v_to is null then
    raise warning 'cb_queue_sale_alert: no operator user for %, skipping', new.client_id;
    return null;
  end if;

  -- Written by cb_create_payout_on_sold() moments ago; absent when the item
  -- had no consignor, which is a legitimate case (the operator's own stock).
  select * into v_payout from public.cb_payouts where item_id = new.id;

  if v_payout.consignor_id is not null then
    select name into v_consignor from public.cb_consignors where id = v_payout.consignor_id;
  end if;

  insert into public.cb_email_outbox (client_id, kind, to_email, to_name, dedupe_key, payload)
  values (
    new.client_id,
    'sale_alert',
    v_to,
    v_to_name,
    'sale:' || new.id::text,
    jsonb_build_object(
      'item_name',       new.name,
      'item_price',      new.price,
      'shop_name',       coalesce(v_tenant.business_name, 'your shop'),
      -- amount_owed is THE CONSIGNOR'S SHARE, frozen at the moment of sale.
      -- Never recompute it here: the whole point of the payout row is that a
      -- later price edit cannot change what somebody is already owed.
      'payout_owed',     v_payout.amount_owed,
      'payout_pct',      v_payout.payout_percentage,
      'consignor_name',  v_consignor,
      'has_consignor',   (v_payout.consignor_id is not null)
    )
  )
  on conflict (dedupe_key) do nothing;

  return null;
exception when others then
  -- A sale must never fail because an email could not be queued.
  raise warning 'cb_queue_sale_alert failed for item %: %', new.id, sqlerrm;
  return null;
end $$;

drop trigger if exists cb_items_sale_alert_trg on public.cb_items;
create trigger cb_items_sale_alert_trg
  after insert or update of status on public.cb_items
  for each row execute function public.cb_queue_sale_alert();


-- ── 4 · EXPIRY REMINDER ────────────────────────────────────────────────────
-- Queues a reminder for every hold expiring in roughly 24 hours.
--
-- The 23–25h window is wider than the hourly cadence on purpose: an exactly
-- 24h window would let a hold whose expiry falls between two runs slip
-- through unreminded. The overlap means some holds match on two consecutive
-- runs, which is harmless — dedupe_key is (item, expiry), so the second
-- attempt inserts nothing.
create or replace function public.cb_queue_expiry_reminders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  with queued as (
    insert into public.cb_email_outbox (client_id, kind, to_email, to_name, dedupe_key, payload)
    select
      i.client_id,
      'expiry_reminder',
      i.reserved_by_email,
      i.reserved_by,
      'expiry:' || i.id::text || ':' || extract(epoch from i.reserved_until)::bigint::text,
      jsonb_build_object(
        'item_name',      i.name,
        'item_price',     i.price,
        'reserved_until', i.reserved_until,
        'buyer_name',     i.reserved_by,
        'shop_name',      coalesce(t.business_name, 'the shop'),
        'shop_email',     t.public_email,
        'shop_phone',     t.public_phone,
        'shop_address',   t.pickup_address,
        'shop_hours',     t.hours_text
      )
    from public.cb_items i
    join public.cb_tenants t on t.client_id = i.client_id and t.is_active
    where i.status = 'reserved'
      and i.reserved_until is not null
      and i.reserved_until >  now() + interval '23 hours'
      and i.reserved_until <= now() + interval '25 hours'
      and i.reserved_by_email is not null
      and btrim(i.reserved_by_email) <> ''
    on conflict (dedupe_key) do nothing
    returning 1
  )
  select count(*) into v_count from queued;
  return v_count;
end $$;

revoke execute on function public.cb_queue_expiry_reminders() from public, anon, authenticated;


-- ── 5 · SCHEDULE ───────────────────────────────────────────────────────────
-- Hourly, offset from the release sweep at :07 so the two never contend for
-- the same rows. Mirrors the cron block in supabase-schema.sql §7.
select cron.unschedule('cb-queue-expiry-reminders')
  where exists (select 1 from cron.job where jobname = 'cb-queue-expiry-reminders');

select cron.schedule(
  'cb-queue-expiry-reminders',
  '23 * * * *',
  $cron$ select public.cb_queue_expiry_reminders(); $cron$
);


-- ═══════════════════════════════════════════════════════════════════════════
-- 6 · THE DRIVER — PICK ONE. Your message left both options bracketed and
--     unselected, so both are here and neither is active by default.
--
--     Nothing above this line differs between them. The outbox, the RPC, the
--     trigger and the reminder job are identical either way; only the thing
--     that pokes /api/send-emails changes.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 6a · VERCEL PRO — nothing to run here ─────────────────────────────────
--   Use vercel.json (shipped alongside this file) and skip 6b entirely.
--   Vercel calls /api/send-emails on its own schedule.

-- ── 6b · HOBBY PLAN — pg_net, keep it in the database ─────────────────────
--   Vercel's hobby tier allows one cron run per DAY, which is useless for a
--   reserve confirmation. This drives it from Postgres instead, every five
--   minutes, and needs no paid plan.
--
--   Enable pg_net first: Dashboard → Database → Extensions → pg_net → ON.
--
--   ⚠ Set the secret BEFORE scheduling, or every request 401s:
--       alter database postgres set app.send_emails_secret = 'the-same-value-as-SEND_EMAILS_SECRET';
--
-- create extension if not exists pg_net;
--
-- select cron.unschedule('cb-drain-email-outbox')
--   where exists (select 1 from cron.job where jobname = 'cb-drain-email-outbox');
--
-- select cron.schedule(
--   'cb-drain-email-outbox',
--   '*/5 * * * *',
--   $cron$
--     select net.http_post(
--       url     := 'https://consignmentbiz.com/api/send-emails',
--       headers := jsonb_build_object(
--                    'Content-Type', 'application/json',
--                    'x-send-secret', current_setting('app.send_emails_secret', true)
--                  ),
--       body    := '{}'::jsonb
--     );
--   $cron$
-- );


-- ═══════════════════════════════════════════════════════════════════════════
-- 7 · VERIFY
-- ═══════════════════════════════════════════════════════════════════════════

-- Both triggers present, and in the order the sale alert depends on.
select tgname, tgenabled
from pg_trigger
where tgrelid = 'public.cb_items'::regclass and not tgisinternal
order by tgname;
-- Expect cb_items_payout_trg BEFORE cb_items_sale_alert_trg. If that order
-- ever inverts, sale alerts lose their payout figure.

-- Outbox is unreachable without service_role.
select count(*) as policies_on_outbox
from pg_policies where schemaname = 'public' and tablename = 'cb_email_outbox';
-- Expect 0, with RLS enabled — deny-all to anon and authenticated.

select relrowsecurity as rls_enabled
from pg_class where oid = 'public.cb_email_outbox'::regclass;

-- Both scheduled jobs.
select jobname, schedule, active from cron.job
where jobname in ('cb-release-expired-reservations','cb-queue-expiry-reminders','cb-drain-email-outbox')
order by jobname;

-- Queue state.
select kind, count(*) filter (where sent_at is null) as pending,
              count(*) filter (where sent_at is not null) as sent,
              max(attempts) as worst_attempts
from public.cb_email_outbox group by kind order by kind;

-- Dry run of the reminder scan without queueing anything.
select i.name, i.reserved_until, i.reserved_by_email
from public.cb_items i
where i.status = 'reserved'
  and i.reserved_until >  now() + interval '23 hours'
  and i.reserved_until <= now() + interval '25 hours';
