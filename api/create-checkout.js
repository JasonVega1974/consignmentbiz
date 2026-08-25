// ═══════════════════════════════════════════════════════════════════════════
// POST /api/create-checkout
//
// Validates the territory and slug, then creates a $197 one-time Stripe
// Checkout Session. Returns { ok: true, url } for the browser to redirect to.
//
// ── WHY THE CHECKS HAPPEN HERE, BEFORE STRIPE ───────────────────────────────
// Every rejection at this stage is a form error. The same rejection after
// payment is a refund, a support email, and a buyer who thinks they own a city
// they don't. Checking the city and the slug before the Session exists turns
// the expensive failures into cheap ones.
//
// THIS IS NOT THE GUARANTEE. Two buyers can pass this check seconds apart and
// both reach Stripe. The real defence against a double-claim is the partial
// unique index behind cb_claim_city() (schema §3.4), which is atomic and
// enforced by Postgres. This endpoint exists to make that race rare, not to
// prevent it.
// ═══════════════════════════════════════════════════════════════════════════

import {
  adminClient, json, preflight, normCity, normState, slugify, logPostgrestError,
  stripePost, RESERVED_SLUGS, STRIPE_PRICE_ID, SITE_URL, SUPPORT_EMAIL,
} from './_shared.js';

export const config = { runtime: 'nodejs' };

export default { fetch: handler };

// Stripe metadata: max 50 keys, 500 chars per value. Truncated defensively —
// a value over the limit rejects the whole Session creation.
const META_MAX = 480;
const meta = (v) => (v == null ? undefined : String(v).slice(0, META_MAX));

async function handler(request) {
  if (request.method === 'OPTIONS') return preflight();
  if (request.method !== 'POST') return json({ ok: false, error: 'method_not_allowed' }, 405);

  if (!STRIPE_PRICE_ID) {
    console.error('STRIPE_PRICE_ID is not set');
    return json({ ok: false, error: 'not_configured',
      message: `Checkout isn't configured yet. Please email ${SUPPORT_EMAIL}.` }, 500);
  }

  let body;
  try { body = await request.json(); }
  catch (e) { return json({ ok: false, error: 'bad_json' }, 400); }

  // ── VALIDATE ──────────────────────────────────────────────────────────────
  const cityLabel = String(body.city_label || '').trim();
  const state     = normState(body.state);
  const email     = String(body.operator_email || '').trim();
  const clientId  = slugify(body.client_id || body.business_name || '');

  if (!cityLabel)            return json({ ok: false, error: 'missing_city',  message: 'Enter the city you want to claim.' }, 400);
  if (!/^[A-Z]{2}$/.test(state)) return json({ ok: false, error: 'bad_state', message: 'Enter a two-letter state code.' }, 400);
  if (!email || !email.includes('@')) return json({ ok: false, error: 'bad_email', message: 'Enter a valid email address.' }, 400);
  if (!clientId || clientId.length < 3) {
    return json({ ok: false, error: 'bad_slug',
      message: 'Choose a storefront address of at least 3 letters or numbers.' }, 400);
  }
  if (RESERVED_SLUGS.has(clientId)) {
    return json({ ok: false, error: 'reserved_slug',
      message: `"${clientId}" is reserved. Please choose a different storefront address.` }, 409);
  }

  let admin;
  try { admin = adminClient(); }
  catch (e) {
    console.error(e);
    return json({ ok: false, error: 'not_configured',
      message: `Checkout isn't configured yet. Please email ${SUPPORT_EMAIL}.` }, 500);
  }

  // ── CITY AVAILABILITY ─────────────────────────────────────────────────────
  // Matches the unique index exactly: lower(city_label) + upper(state), and
  // only rows whose status still holds the territory.
  try {
    const { data, error } = await admin
      .from('cb_city_claims')
      .select('id,status')                       // no space: it encodes as %20
      .ilike('city_label', cityLabel)
      .eq('state', state)
      .in('status', ['claimed', 'reserved'])
      .limit(1);
    if (error) throw error;
    if (data && data.length) {
      return json({ ok: false, error: 'city_taken',
        message: `${cityLabel}, ${state} has already been claimed. Territories are one operator per city.` }, 409);
    }
  } catch (e) {
    logPostgrestError('city availability check', e);
    return json({ ok: false, error: 'lookup_failed',
      message: 'We could not check that territory just now. Please try again.' }, 500);
  }

  // ── SLUG AVAILABILITY ─────────────────────────────────────────────────────
  // cb_tenants.client_id is UNIQUE, so a collision would otherwise fail in the
  // webhook — after payment. Caught here it is a form error.
  try {
    const { data, error } = await admin
      .from('cb_tenants').select('client_id').eq('client_id', clientId).limit(1);
    if (error) throw error;
    if (data && data.length) {
      return json({ ok: false, error: 'slug_taken',
        message: `"${clientId}.consignmentbiz.com" is already in use. Please choose another.` }, 409);
    }
  } catch (e) {
    logPostgrestError('slug availability check', e);
    return json({ ok: false, error: 'lookup_failed',
      message: 'We could not check that address just now. Please try again.' }, 500);
  }

  // ── CREATE SESSION ────────────────────────────────────────────────────────
  // No promotion codes on this flow (allow_promotion_codes deliberately unset):
  // a discounted session could drop below MIN_AMOUNT_CENTS and be rejected by
  // the webhook AFTER the buyer has paid. Add promo support alongside a matched
  // floor, not before.
  let session;
  try {
    session = await stripePost('checkout/sessions', {
      mode: 'payment',
      line_items: [{ price: STRIPE_PRICE_ID, quantity: 1 }],
      customer_email: email,
      success_url: `${SITE_URL}/thank-you.html?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${SITE_URL}/intake.html?cancelled=1`,

      // The webhook reads everything it needs from here. There is no cb_intake
      // table in this schema, so metadata is the ONLY record of what the buyer
      // entered until the webhook writes it — see the note in stripe-webhook.js.
      metadata: {
        client_id:       meta(clientId),
        city_label:      meta(cityLabel),
        state:           meta(state),
        business_name:   meta(body.business_name),
        operator_name:   meta(body.operator_name),
        operator_email:  meta(email),
        operator_phone:  meta(body.operator_phone),
        tagline:         meta(body.tagline),
        pickup_address:  meta(body.pickup_address),
        hours_text:      meta(body.hours_text),
        payout_pct:      meta(body.payout_pct),
        categories:      meta(Array.isArray(body.categories) ? body.categories.join(',') : body.categories),
      },
    });
  } catch (e) {
    console.error('Stripe session creation failed:', e.stripeCode || '', e.message);
    return json({ ok: false, error: 'stripe_error',
      message: `We couldn't start checkout. Please try again, or email ${SUPPORT_EMAIL}.` }, 502);
  }

  if (!session?.url) {
    console.error('Stripe returned no url for session', session?.id);
    return json({ ok: false, error: 'stripe_error',
      message: `We couldn't start checkout. Please email ${SUPPORT_EMAIL}.` }, 502);
  }

  console.log('checkout created:', session.id, clientId, `${cityLabel}, ${state}`);
  return json({ ok: true, url: session.url, session_id: session.id });
}
