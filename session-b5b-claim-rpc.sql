-- ═══════════════════════════════════════════════════════════════════════════
-- SESSION B5b — ADDENDUM: ATOMIC OUTBOX CLAIM
--
-- Run AFTER session-b5b-shop-emails.sql. Adds one function; changes nothing
-- that already exists. Idempotent.
--
-- ┌───────────────────────────────────────────────────────────────────────┐
-- │ WHY THIS EXISTS                                                       │
-- │                                                                       │
-- │ PostgREST cannot express FOR UPDATE SKIP LOCKED. A plain              │
-- │   .select().is('sent_at', null).limit(25)                             │
-- │ takes no locks, so two overlapping drains read the SAME rows and send │
-- │ the SAME emails. With a five-minute cron that needs only one slow run │
-- │ to overrun its window — a Brevo timeout is enough.                    │
-- │                                                                       │
-- │ SKIP LOCKED is the fix: the second worker steps over rows the first   │
-- │ already holds instead of blocking behind them, so both make progress  │
-- │ on different rows.                                                    │
-- └───────────────────────────────────────────────────────────────────────┘
--
-- ⚠ ATTEMPTS INCREMENT AT CLAIM, NOT AT FAILURE. This is deliberate and it
--   is the whole reason the counter can be trusted. If the sender is killed
--   mid-flight — Vercel wall-clock timeout, deploy, OOM — nothing gets to
--   write "that failed". Counting on the way out means a row that reliably
--   kills the worker still exhausts its attempts and stops, instead of being
--   retried forever and taking every run down with it.
--
--   The cost is that a crash between claim and send burns an attempt on an
--   email that was never tried. Three attempts rather than one is what
--   absorbs that, and losing an attempt is cheaper than an infinite loop.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.cb_claim_email_batch(
  p_limit        integer default 25,
  p_max_attempts integer default 3
)
returns setof public.cb_email_outbox
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with claimed as (
    select o.id
      from public.cb_email_outbox o
     where o.sent_at is null
       and o.attempts < p_max_attempts
     order by o.created_at
     for update skip locked
     limit greatest(p_limit, 0)
  )
  update public.cb_email_outbox o
     set attempts = o.attempts + 1
    from claimed c
   where o.id = c.id
  returning o.*;
end $$;

-- Never reachable from a browser. The outbox holds buyer contact details, and
-- this function both reads and mutates it.
revoke execute on function public.cb_claim_email_batch(integer, integer)
  from public, anon, authenticated;


-- ── VERIFY ─────────────────────────────────────────────────────────────────

-- Exists, and returns the outbox row type.
select p.proname, pg_get_function_result(p.oid) as returns
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname = 'cb_claim_email_batch';

-- Nobody but service_role can execute it. Expect zero rows.
select grantee, privilege_type
from information_schema.routine_privileges
where routine_schema = 'public'
  and routine_name = 'cb_claim_email_batch'
  and grantee in ('anon','authenticated','public');

-- Dry run. On an empty outbox this returns nothing and changes nothing;
-- on a populated one it CLAIMS rows, so do not run it idly in production.
-- select id, kind, to_email, attempts from public.cb_claim_email_batch(5, 3);
