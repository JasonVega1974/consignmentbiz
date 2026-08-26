-- ═══════════════════════════════════════════════════════════════════════════
-- SEED — PUBLIC DEMO SHOP  (client_id = 'testshop')
--
-- ┌───────────────────────────────────────────────────────────────────────┐
-- │ READ THIS FIRST — THE SEED IS NOT FAILING.                            │
-- │                                                                       │
-- │ Checked against the live database on 2026-08-25, through the public   │
-- │ API, before this revision was written:                                │
-- │                                                                       │
-- │   cb_public_tenants?client_id=eq.testshop     → 1 row, Meridian, ID   │
-- │   cb_public_items?client_id=eq.testshop       → 11 rows               │
-- │   cb_public_photos?client_id=eq.testshop      → 8 rows                │
-- │   cb_public_tenants?client_id=eq.maplemarrow  → []                    │
-- │                                                                       │
-- │ The tenant and the items ARE inserted. What does not exist is         │
-- │ 'maplemarrow' — and it never will, because no statement in this file  │
-- │ creates it. The client_id is 'testshop'. "Marrow & Maple" is the      │
-- │ shop's BUSINESS NAME, not its slug. index.html links to               │
-- │ demo.html?tenant=testshop, and 'maplemarrow' appears nowhere in the   │
-- │ repository.                                                           │
-- │                                                                       │
-- │ If you want the slug to be 'maplemarrow', that is a rename, not a     │
-- │ fix — see STEP 4. Do not run it without reading it.                   │
-- └───────────────────────────────────────────────────────────────────────┘
--
-- WHY IT LOOKED SILENT
--   Every insert here ends in ON CONFLICT DO UPDATE. On a second run nothing
--   is inserted — rows are updated — and the SQL editor reports "Success. No
--   rows returned", which reads exactly like nothing happened. Every statement
--   below now ends in RETURNING, so the editor prints what it touched and you
--   can see the difference between "did nothing" and "updated eight rows".
--
-- ON RLS
--   RLS is almost certainly not involved. The Supabase SQL editor connects as
--   'postgres', which owns these tables and bypasses RLS; and an RLS refusal
--   on INSERT raises 42501 — it is loud, never silent. STEP 1 checks the one
--   case where owner-bypass does not apply (FORCE ROW LEVEL SECURITY).
--
--   You asked for a bypass, so STEP 2 wraps the writes in a transaction with
--   SET LOCAL ROLE service_role. That is scoped to the transaction and reverts
--   on COMMIT or ROLLBACK, so there is never a window where the tables are
--   unprotected.
--
--   I have deliberately NOT used ALTER TABLE … DISABLE ROW LEVEL SECURITY.
--   It is table-wide and persistent: if any statement between the disable and
--   the re-enable raises, RLS stays off, and the anon key that would then read
--   every row is published in plain text inside demo.html. The transaction
--   above achieves the same thing and cannot leave the door open.
-- ═══════════════════════════════════════════════════════════════════════════


-- ═══ STEP 1 · DIAGNOSTICS (read-only — run this on its own first) ═════════

-- 1a. What is actually in the tables right now, ignoring every view.
select 'tenants matching testshop'    as check, count(*)::text as result from public.cb_tenants where client_id = 'testshop'
union all
select 'tenants matching maplemarrow',        count(*)::text from public.cb_tenants where client_id = 'maplemarrow'
union all
select 'items on testshop',                   count(*)::text from public.cb_items   where client_id = 'testshop'
union all
select 'photos on testshop',                  count(*)::text from public.cb_photos  where client_id = 'testshop'
union all
select 'ALL tenant slugs',  coalesce(string_agg(client_id, ', ' order by client_id), '(none)') from public.cb_tenants;

-- 1b. Who am I, and do I bypass RLS?
--     Expect: current_user = postgres, bypassrls = true.
select current_user,
       (select rolbypassrls from pg_roles where rolname = current_user) as bypasses_rls,
       (select rolsuper     from pg_roles where rolname = current_user) as is_superuser;

-- 1c. Is RLS FORCED on any of these tables? Forcing is the only setting that
--     makes the owner subject to its own policies. Expect forced = false.
select relname                as table_name,
       relrowsecurity         as rls_enabled,
       relforcerowsecurity    as rls_forced
from pg_class
where relnamespace = 'public'::regnamespace
  and relname in ('cb_tenants','cb_items','cb_photos')
order by relname;

-- 1d. The purchase_mode constraint, from the constraint itself.
select conname, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid = 'public.cb_items'::regclass and contype = 'c'
order by conname;


-- ═══ STEP 2 · THE SEED (writes — run as one block) ════════════════════════

begin;

-- Scoped bypass. service_role carries BYPASSRLS in Supabase. SET LOCAL means
-- it lasts only until this transaction ends, however it ends.
set local role service_role;


-- ── 2a · THE TENANT ────────────────────────────────────────────────────────
-- Every column set here also appears in the update list. In an earlier
-- revision city_label, state, public_email, public_phone, pickup_address and
-- default_payout_percentage were set on first insert and then silently ignored
-- on every later run — which is how a Meridian, Idaho shop ended up with an
-- About text describing Columbia County, New York.
insert into public.cb_tenants (
  client_id, city_label, state, business_name, tagline, about_text,
  primary_color, public_email, public_phone, hours_text, pickup_address,
  default_payout_percentage, is_active
) values (
  'testshop',
  'Meridian', 'ID',
  'Marrow & Maple',
  'Curated vintage, furniture, and the odd good lamp.',
  'We take consignments from neighbours across the Treasure Valley and sell '
  || 'them to people who will actually use them. Everything here has been '
  || 'looked over by hand, priced honestly, and photographed as it really is '
  || '— chips, wear, and all. If a piece has a fault worth knowing about, it '
  || 'is in the description. Collection from the shop, or we can usually help '
  || 'arrange a van for the larger things.',
  '#2d5c3d',
  'hello@meridianvintage.com',
  '(208) 555-0142',
  'Wed–Sun, 11–6',
  '1420 N Main Street, Meridian, ID',
  50.00,
  true
)
on conflict (client_id) do update set
  city_label                = excluded.city_label,
  state                     = excluded.state,
  business_name             = excluded.business_name,
  tagline                   = excluded.tagline,
  about_text                = excluded.about_text,
  primary_color             = excluded.primary_color,
  public_email              = excluded.public_email,
  public_phone              = excluded.public_phone,
  hours_text                = excluded.hours_text,
  pickup_address            = excluded.pickup_address,
  default_payout_percentage = excluded.default_payout_percentage,
  is_active                 = true
returning client_id, city_label, state, business_name, is_active;
--        ↑ one row printed. If you see nothing here, the statement did not run.


-- ── 2b · THE STOCK ─────────────────────────────────────────────────────────
-- Fixed uuids so photos can reference items without a lookup, and so re-running
-- updates the same eight rows instead of appending eight more.
--
-- payout_percentage is THE CONSIGNOR'S SHARE, per the platform-wide direction
-- fixed in the schema. 60.00 means the consignor receives 60%.
insert into public.cb_items (
  id, client_id, name, description, category_slug, condition,
  price, payout_percentage, purchase_mode, status, approved_at,
  reserved_until, reserved_by, reserved_at, sold_at
) values
  ('a0000000-0000-4000-8000-000000000001', 'testshop',
   'Walnut sideboard, 1962',
   'Danish-style sideboard in solid walnut, three drawers over a cupboard, '
   || 'original brass pulls. One shallow water ring on the top surface, shown '
   || 'in the photographs and not polished out. Structurally sound, drawers '
   || 'run smoothly. Collection only — it is heavier than it looks.',
   'furniture', 'Very good — one shallow ring to the top',
   240.00, 60.00, 'fixed_price', 'available', now() - interval '9 days',
   null, null, null, null),

  ('a0000000-0000-4000-8000-000000000002', 'testshop',
   'Camel wool overcoat',
   'Single-breasted overcoat in a heavy camel wool, fully lined, horn buttons '
   || 'all present. Cut generously — fits like a modern large. No moth damage, '
   || 'no odour, one small repair to the left pocket seam done properly by hand.',
   'vintage-clothing', 'Excellent — one hand-repaired pocket seam',
   85.00, 55.00, 'fixed_price', 'available', now() - interval '6 days',
   null, null, null, null),

  -- The one live hold. reserved_until is in the future so cb_public_items
  -- reports 'reserved' rather than flipping it back to 'available'.
  ('a0000000-0000-4000-8000-000000000003', 'testshop',
   'Ginger jars, pair',
   'Matched pair of blue-and-white lidded ginger jars, hand-painted, both lids '
   || 'original and a good fit. One has a hairline to the foot rim that does '
   || 'not go through — it will hold dry goods but I would not fill it with '
   || 'water. Priced for the pair.',
   'home-decor', 'Good — hairline to one foot rim',
   310.00, 60.00, 'fixed_price', 'reserved', now() - interval '12 days',
   now() + interval '3 days', 'R. Okafor', now() - interval '1 day', null),

  ('a0000000-0000-4000-8000-000000000004', 'testshop',
   'Valve radio, 1958',
   'Wooden-cased valve set, dial glass intact, original cloth grille. It powers '
   || 'up and lights, and it picks up AM — but it has not been rewired and the '
   || 'capacitors are original, so have it looked at before you leave it '
   || 'switched on. Sold as a working-condition set, not as restored.',
   'collectibles-antiques', 'Working, unrestored — original wiring',
   95.00, 60.00, 'fixed_price', 'available', now() - interval '4 days',
   null, null, null, null),

  ('a0000000-0000-4000-8000-000000000005', 'testshop',
   'Mid-century chairs and side table',
   'Pair of bentwood-framed lounge chairs in their original tan leatherette, '
   || 'with a matching three-legged side table. The leatherette is honest — '
   || 'creased and worn at the front edge of both seats, no splits or tears. '
   || 'Frames are tight, no wobble. Sold as the set of three.',
   'furniture', 'Good — honest wear to both seats',
   430.00, 60.00, 'fixed_price', 'available', now() - interval '15 days',
   null, null, null, null),

  -- Sold stock stays visible on purpose: it is the proof that things move.
  -- sold_at is set, without which the payout ledger has nothing to date.
  ('a0000000-0000-4000-8000-000000000006', 'testshop',
   'Gilt salon chair',
   'Carved and gilded salon chair with its original blue silk seat. The gilding '
   || 'has rubbed back to the gesso on the crest and both arm ends — attractive '
   || 'as it is, and easily restored if that is not to your taste. Joints are '
   || 'firm. A decorative chair, not one for daily use.',
   'collectibles-antiques', 'Fair — gilding rubbed, structurally sound',
   180.00, 65.00, 'fixed_price', 'sold', now() - interval '21 days',
   null, null, null, now() - interval '5 days'),

  ('a0000000-0000-4000-8000-000000000007', 'testshop',
   'Brass table lamp with silk shade',
   'Turned brass column lamp, rewired to modern standards with a new flex and '
   || 'plug, PAT tested. The pleated silk shade is the original and shows light '
   || 'foxing at the top edge, visible in the photograph. Takes a standard '
   || 'screw-fit bulb, not included.',
   'lighting', 'Very good — rewired, light foxing to shade',
   64.00, 60.00, 'fixed_price', 'available', now() - interval '3 days',
   null, null, null, null),

  -- The one reserve-and-collect piece, because a 6x9 rug is not something
  -- anyone posts. purchase_mode permits only 'fixed_price' or 'reserve_pickup'
  -- — confirm with STEP 1d.
  ('a0000000-0000-4000-8000-000000000008', 'testshop',
   'Persian-pattern wool rug, 6×9',
   'Hand-knotted wool rug on a dark indigo ground, floral medallion field. '
   || 'Roughly 6ft by 9ft. Even low pile throughout with no bald patches; both '
   || 'ends have been overcast to stop further fraying. Professionally cleaned '
   || 'last month — it has no smell at all, which is rarer than it should be.',
   'rugs-textiles', 'Good — even low pile, ends secured',
   520.00, 55.00, 'reserve_pickup', 'available', now() - interval '8 days',
   null, null, null, null)
on conflict (id) do update set
  name              = excluded.name,
  description       = excluded.description,
  category_slug     = excluded.category_slug,
  condition         = excluded.condition,
  price             = excluded.price,
  payout_percentage = excluded.payout_percentage,
  purchase_mode     = excluded.purchase_mode,
  status            = excluded.status,
  reserved_until    = excluded.reserved_until,
  reserved_by       = excluded.reserved_by,
  reserved_at       = excluded.reserved_at,
  sold_at           = excluded.sold_at
returning id, name, price, status, purchase_mode;
--        ↑ eight rows printed.


-- ── 2c · THE PHOTOGRAPHS ───────────────────────────────────────────────────
-- cb_photos_one_featured is a partial unique index on (item_id) where
-- is_featured, so a second featured row for the same item raises 23505.
-- URLs are absolute and resolve only once the site is deployed.
insert into public.cb_photos (id, client_id, item_id, photo_url, display_order, is_featured) values
  ('b0000000-0000-4000-8000-000000000001', 'testshop', 'a0000000-0000-4000-8000-000000000001',
   'https://consignmentbiz.com/images/item-sideboard.jpg',   0, true),
  ('b0000000-0000-4000-8000-000000000002', 'testshop', 'a0000000-0000-4000-8000-000000000002',
   'https://consignmentbiz.com/images/item-overcoat.jpg',    0, true),
  ('b0000000-0000-4000-8000-000000000003', 'testshop', 'a0000000-0000-4000-8000-000000000003',
   'https://consignmentbiz.com/images/item-ginger-jars.jpg', 0, true),
  ('b0000000-0000-4000-8000-000000000004', 'testshop', 'a0000000-0000-4000-8000-000000000004',
   'https://consignmentbiz.com/images/item-radio.jpg',       0, true),
  ('b0000000-0000-4000-8000-000000000005', 'testshop', 'a0000000-0000-4000-8000-000000000005',
   'https://consignmentbiz.com/images/item-dining-set.jpg',  0, true),
  ('b0000000-0000-4000-8000-000000000006', 'testshop', 'a0000000-0000-4000-8000-000000000006',
   'https://consignmentbiz.com/images/item-salon-chair.jpg', 0, true),
  ('b0000000-0000-4000-8000-000000000007', 'testshop', 'a0000000-0000-4000-8000-000000000007',
   'https://consignmentbiz.com/images/item-lamp.jpg',        0, true),
  ('b0000000-0000-4000-8000-000000000008', 'testshop', 'a0000000-0000-4000-8000-000000000008',
   'https://consignmentbiz.com/images/item-rug.jpg',         0, true)
on conflict (id) do update set
  photo_url   = excluded.photo_url,
  is_featured = true
returning item_id, photo_url;
--        ↑ eight rows printed.

commit;
-- The role reverts here automatically. Nothing to undo.


-- ═══ STEP 3 · VERIFY ══════════════════════════════════════════════════════

select 'tenant'           as thing, count(*) from public.cb_tenants      where client_id = 'testshop'
union all
select 'items',            count(*) from public.cb_items       where client_id = 'testshop'
union all
select 'photos',           count(*) from public.cb_photos      where client_id = 'testshop'
union all
select 'city claims (0!)', count(*) from public.cb_city_claims  where client_id = 'testshop';

-- No claim on the demo city under ANY account. A row here means Meridian has
-- genuinely been sold and the demo should move to a different city.
select client_id, city_label, state, status
from public.cb_city_claims
where lower(city_label) = 'meridian' and upper(state) = 'ID';

-- What the public actually sees, through the same view the storefront reads.
select name, status, price, purchase_mode
from public.cb_public_items
where client_id = 'testshop'
order by created_at desc;


-- ═══ STEP 4 · OPTIONAL, DESTRUCTIVE — read before running ═════════════════

-- 4a. THREE OLDER DEMO ITEMS that predate this seed and now duplicate it.
--     The shop currently holds eleven items, not eight:
--
--       84108969-891b-45f1-aa24-dd606150a917  Wool Overcoat, Camel        $140
--       f3112bd1-f095-4d3f-ab65-0580d54db6ed  Mid-Century Walnut Dresser  $485
--       7c4d093b-984b-4701-814f-554dfbde94e9  Brass Table Lamp             $95
--
--     Each has a near-twin above — a camel overcoat at $85, a walnut sideboard
--     at $240, a brass lamp at $64 — so a visitor sees the same piece listed
--     twice at two prices. Deleting an item cascades to its photos.
--
-- begin;
--   set local role service_role;
--   delete from public.cb_items
--    where client_id = 'testshop'
--      and id in ('84108969-891b-45f1-aa24-dd606150a917',
--                 'f3112bd1-f095-4d3f-ab65-0580d54db6ed',
--                 '7c4d093b-984b-4701-814f-554dfbde94e9')
--   returning id, name;
-- commit;


-- 4b. RENAME THE SLUG to 'maplemarrow', if that is what you actually wanted.
--     This is NOT a fix for anything — nothing is broken — it is a change of
--     identity, and it breaks links until you also update the site.
--
--     client_id is referenced by cb_items, cb_photos, cb_consignors,
--     cb_client_users, cb_billing and cb_city_claims. Those foreign keys are
--     ON DELETE CASCADE, not ON UPDATE CASCADE, so an UPDATE of the parent key
--     will be REJECTED while children exist. Renaming means inserting the new
--     tenant, repointing every child, then deleting the old row — which is a
--     migration, not a one-liner.
--
--     ⚠ You must also change index.html, which links to
--       demo.html?tenant=testshop in the "See a live demo shop" button.
--
--     Say the word and I will write that migration properly. Do not improvise
--     it against live data.
