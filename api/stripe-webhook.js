// ═══════════════════════════════════════════════════════════════════════════
// POST /api/stripe-webhook
//
// Stripe calls this; the browser never does. It is the point at which a payment
// becomes a held territory.
//
// Event handled:
//   checkout.session.completed → claim the city + record the payment
//
// ── WHY THE WEBHOOK AND NOT THE BROWSER ─────────────────────────────────────
// EstateSaleBiz provisioned from the buyer's own browser after the redirect
// back from Stripe. That works right up until the buyer closes the tab, loses
// signal, or has an ad blocker in the way — at which point they have paid and
// nothing exists, and the only record is inside Stripe. Doing it here means the
// outcome does not depend on the buyer's browser surviving the round trip.
//
// ── STATUS CODES ARE PART OF THE DESIGN ─────────────────────────────────────
// Stripe retries any non-2xx for up to three days with backoff. That is a
// feature for transient problems and a liability for permanent ones:
//
//   400  bad or missing signature      — never retry, nothing to fix
//   500  database or network failure   — RETRY, the next attempt may work
//   200  city already claimed, or already processed — do NOT retry; either a
//        human is needed or the work is already done
//
// Returning 500 on a city conflict would retry a permanent failure hundreds of
// times and bury the one log line that matters.
//
// ── SCOPE: B4 ONLY ──────────────────────────────────────────────────────────
// This records the money and holds the territory. It does NOT provision the
// operator — see the TODO block below.
// ═══════════════════════════════════════════════════════════════════════════

import {
  adminClient, json, verifyStripeSession, verifyStripeSignature,
  STRIPE_WEBHOOK_SECRET, SUPPORT_EMAIL,
} from './_shared.js';

export const config = { runtime: 'nodejs' };

export default { fetch: handler };

async function handler(request) {
  if (request.method !== 'POST') return json({ ok: false, error: 'method_not_allowed' }, 405);

  // RAW BODY FIRST, before anything parses it. The signature is computed over
  // the exact bytes Stripe sent; re-serialising a parsed object reorders keys
  // and fails verification every time.
  const rawBody = await request.text();
  const sig = request.headers.get('stripe-signature');

  const verdict = await verifyStripeSignature(rawBody, sig, STRIPE_WEBHOOK_SECRET);
  if (!verdict.ok) {
    // 400, not 500: a bad signature is never fixed by retrying.
    console.error('webhook signature rejected:', verdict.reason);
    return json({ ok: false, error: 'bad_signature', reason: verdict.reason }, 400);
  }

  let event;
  try { event = JSON.parse(rawBody); }
  catch (e) { return json({ ok: false, error: 'bad_json' }, 400); }

  // Anything we do not handle is acknowledged, not retried.
  if (event.type !== 'checkout.session.completed') {
    console.log('webhook ignored event:', event.type);
    return json({ ok: true, ignored: event.type });
  }

  const sessionId = event.data?.object?.id;
  if (!sessionId) return json({ ok: false, error: 'no_session_id' }, 400);

  // SECOND, INDEPENDENT GATE. The signature proves Stripe sent this; the API
  // read proves the payment is real, correctly priced, and not refunded. A
  // refunded session still reports payment_status:'paid', so this matters.
  const verified = await verifyStripeSession(sessionId);
  if (verified.fail) {
    // 200 deliberately: an unverifiable session will not become verifiable on
    // retry, and Stripe hammering us for three days helps nobody.
    console.error('webhook session failed verification:', sessionId);
    return json({ ok: true, skipped: 'unverified_session', session_id: sessionId });
  }
  const session = verified.session;
  const md = session.metadata || {};

  const clientId  = String(md.client_id || '').trim();
  const cityLabel = String(md.city_label || '').trim();
  const state     = String(md.state || '').trim().toUpperCase();
  const amount    = (session.amount_total || 0) / 100;

  if (!clientId || !cityLabel || !state) {
    // Money was taken and we cannot tell what for. Nothing to retry — the
    // metadata will not appear on a second delivery.
    console.error('PAID SESSION WITH INCOMPLETE METADATA — manual follow-up required:',
      sessionId, JSON.stringify(md));
    return json({ ok: true, skipped: 'incomplete_metadata', session_id: sessionId });
  }

  let admin;
  try { admin = adminClient(); }
  catch (e) {
    // Config problem, genuinely transient from Stripe's point of view once
    // fixed — 500 so the retry lands after the env var is set.
    console.error(e);
    return json({ ok: false, error: 'not_configured' }, 500);
  }

  // ── 1 · IDEMPOTENCY ───────────────────────────────────────────────────────
  // Stripe redelivers on any non-2xx, and can deliver the same event twice on
  // its own. cb_billing.stripe_session_id is UNIQUE, so it is the natural key.
  try {
    const { data, error } = await admin
      .from('cb_billing').select('id').eq('stripe_session_id', sessionId).limit(1);
    if (error) throw error;
    if (data && data.length) {
      console.log('webhook already processed:', sessionId);
      return json({ ok: true, already_processed: true, session_id: sessionId });
    }
  } catch (e) {
    console.error('idempotency check failed:', e);
    return json({ ok: false, error: 'db_error' }, 500);   // retry
  }

  // ── 2 · MINIMAL TENANT ROW ────────────────────────────────────────────────
  // NOT provisioning — this is the smallest row the foreign keys will accept.
  //
  // Both cb_city_claims.client_id and cb_billing.client_id reference
  // cb_tenants(client_id), and cb_billing.client_id is NOT NULL. So neither the
  // claim nor the payment record can be written until this row exists. Only
  // client_id / city_label / state lack defaults; everything else is left to
  // the schema.
  //
  // is_active = false is load-bearing: cb_public_tenants filters on is_active,
  // so the storefront stays dark and unreachable until B5 finishes setup.
  try {
    const { error } = await admin.from('cb_tenants').insert({
      client_id:  clientId,
      city_label: cityLabel,
      state:      state,
      is_active:  false,
    });
    if (error) {
      // 23505 = the slug was taken between checkout creation and now. Permanent:
      // a retry cannot resolve it, and the buyer has already paid.
      if (error.code === '23505') {
        console.error('SLUG COLLISION AFTER PAYMENT — manual follow-up required:',
          sessionId, clientId, `${cityLabel}, ${state}`, session.customer_email || md.operator_email);
        return json({ ok: true, skipped: 'slug_taken', session_id: sessionId });
      }
      throw error;
    }
  } catch (e) {
    console.error('tenant insert failed:', e);
    return json({ ok: false, error: 'db_error' }, 500);   // retry
  }

  // ── 3 · ATOMIC CITY CLAIM ─────────────────────────────────────────────────
  // THE real defence against a double-claim. cb_claim_city() (schema §8.1) does
  // a single INSERT guarded by the partial unique index on
  // (lower(city_label), upper(state)) and converts the unique violation into a
  // clean {ok:false, reason:'already_claimed'} rather than a raw 23505.
  //
  // Two buyers who both passed the pre-check in create-checkout meet here, and
  // Postgres decides. There is no window in which both succeed.
  let claim;
  try {
    const { data, error } = await admin.rpc('cb_claim_city', {
      p_city_label: cityLabel,
      p_state: state,
      p_client_id: clientId,
    });
    if (error) throw error;
    claim = data;
  } catch (e) {
    console.error('cb_claim_city failed:', e);
    return json({ ok: false, error: 'db_error' }, 500);   // retry
  }

  if (!claim || claim.ok !== true) {
    // Lost the race. The buyer has paid for a city someone else now holds.
    // 200 so Stripe stops; this needs a refund and a human, not a retry.
    //
    // ⚠ NO ALERT CHANNEL IN B4 — Brevo is out of scope, so this reaches Vercel
    // logs only. It IS recoverable and visible: the inactive cb_tenants row
    // exists with no matching city claim, which shows as an anomaly in the
    // owner dashboard. B5 should email on this path.
    console.error('CITY CONFLICT AFTER PAYMENT — REFUND REQUIRED:',
      sessionId, `${cityLabel}, ${state}`, clientId,
      session.customer_email || md.operator_email, `amount=$${amount}`,
      `reason=${claim && claim.reason}`);
    return json({ ok: true, skipped: 'city_already_claimed', session_id: sessionId });
  }

  // ── 4 · RECORD THE PAYMENT ────────────────────────────────────────────────
  // billing_type is constrained to 'one_time' by the schema (§3.11) — this
  // platform has no subscription, by design.
  try {
    const { error } = await admin.from('cb_billing').insert({
      client_id:             clientId,
      amount:                amount,
      currency:              (session.currency || 'usd').toLowerCase(),
      stripe_session_id:     sessionId,
      stripe_payment_intent: typeof session.payment_intent === 'string'
                               ? session.payment_intent : session.payment_intent?.id || null,
      billing_type:          'one_time',
      status:                'paid',
      paid_at:               new Date().toISOString(),
    });
    if (error) throw error;
  } catch (e) {
    // The city is claimed but the payment is unrecorded. Retrying is right: the
    // idempotency check above will not short-circuit (no billing row yet), the
    // tenant insert will 23505 and bail... so log loudly rather than rely on it.
    console.error('BILLING INSERT FAILED AFTER CITY CLAIM — manual follow-up required:',
      sessionId, clientId, `amount=$${amount}`, e);
    return json({ ok: false, error: 'db_error' }, 500);
  }

  console.log('territory claimed:', clientId, `${cityLabel}, ${state}`, `$${amount}`, sessionId);

  // ═════════════════════════════════════════════════════════════════════════
  // TODO — B5 · provision-buyer
  //
  // Everything below is DELIBERATELY NOT DONE HERE. At this point the buyer has
  // paid, the territory is held, and the payment is recorded — but they have no
  // way to log in and no storefront. B5 must:
  //
  //   1. Create the auth.users account (admin.auth.admin.createUser) for
  //      metadata.operator_email, with a generated password or a magic link.
  //   2. Insert the cb_client_users row mapping that uid -> client_id.
  //      Until this exists, admin.html's checkAuth() returns 'not_provisioned'
  //      and the operator is blocked from their own dashboard.
  //   3. Populate the rest of cb_tenants from session.metadata, which is the
  //      only record of it: business_name, tagline, public_email,
  //      public_phone, pickup_address, hours_text, default_payout_percentage.
  //      ⚠ There is no cb_intake table — if metadata is lost, that data is
  //        gone. Consider adding one, or re-collecting in the dashboard.
  //   4. Flip cb_tenants.is_active = true so the storefront goes live.
  //   5. Send the welcome / login email via Brevo.
  //   6. Email the owner on the two failure paths above (slug collision, city
  //      conflict), which currently only reach these logs.
  //
  // Until B5 ships, finishing a purchase is a manual step: create the auth
  // user, insert the mapping, fill the tenant row, set is_active = true.
  // ═════════════════════════════════════════════════════════════════════════

  return json({
    ok: true,
    claimed: `${cityLabel}, ${state}`,
    client_id: clientId,
    provisioning: 'pending_b5',
    note: `Territory held and payment recorded. Operator account not yet created — see ${SUPPORT_EMAIL}.`,
  });
}
