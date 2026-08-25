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
// ── WHAT THIS DOES END TO END ───────────────────────────────────────────────
//   1  per-step idempotency  2  minimal tenant row  3  atomic city claim
//   4  record the payment    5  create the auth user
//   6  mint a password-setup link  7  map user -> tenant
//   8  populate + activate the tenant
//   9  email the operator    10 email the owner
//
// Steps 1-4 are money and territory: a failure there returns 500 so Stripe
// retries. Steps 9-10 are mail: best-effort, never fail the request.
// ═══════════════════════════════════════════════════════════════════════════

import {
  adminClient, json, verifyStripeSession, verifyStripeSignature,
  sendBrevo, ownerAlert, escHtml, logPostgrestError,
  STRIPE_WEBHOOK_SECRET, SUPPORT_EMAIL, BREVO_TEMPLATE_ID, SITE_URL, APEX,
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
    await ownerAlert('ACTION NEEDED — paid session with incomplete metadata', [
      'A ConsignmentBiz payment completed but the Stripe metadata is incomplete,',
      'so we cannot tell which territory it was for. Nothing has been provisioned.',
      '',
      `Stripe session: ${sessionId}`,
      `Amount:         $${amount}`,
      `Buyer email:    ${session.customer_email || md.operator_email || '(none)'}`,
      `Metadata:       ${JSON.stringify(md)}`,
      '',
      'NEXT: open the session in Stripe, contact the buyer, and either provision',
      'manually or refund.',
    ]);
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

  // ── 1 · IDEMPOTENCY, PER STEP ─────────────────────────────────────────────
  // Stripe redelivers on any non-2xx, and can deliver the same event twice on
  // its own.
  //
  // ⚠ THIS IS DELIBERATELY *NOT* "billing row exists -> stop". B4 did that, and
  // it strands a buyer: if provisioning fails after the billing insert, every
  // retry short-circuits here and the operator is left paid, claimed, and with
  // no login — permanently, because Stripe eventually gives up.
  //
  // Done means BOTH halves: the payment recorded AND the operator mapped. If
  // only the first is true we are resuming a half-finished run, and every step
  // below is written to be safe to repeat.
  let billingExists = false, provisioned = false;
  try {
    const [b, m] = await Promise.all([
      admin.from('cb_billing').select('id').eq('stripe_session_id', sessionId).limit(1),
      admin.from('cb_client_users').select('id').eq('client_id', clientId).limit(1),
    ]);
    if (b.error) throw b.error;
    if (m.error) throw m.error;
    billingExists = !!(b.data && b.data.length);
    provisioned   = !!(m.data && m.data.length);
  } catch (e) {
    logPostgrestError('idempotency check', e);
    return json({ ok: false, error: 'db_error' }, 500);   // retry
  }

  if (billingExists && provisioned) {
    console.log('webhook already fully processed:', sessionId);
    return json({ ok: true, already_processed: true, session_id: sessionId });
  }
  if (billingExists) {
    console.warn('resuming half-finished provisioning for', clientId, sessionId);
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
      if (error.code === '23505') {
        // If we are resuming, this row is OUR earlier partial run — carry on.
        // On a fresh run it is a genuine collision with a different operator:
        // permanent, unfixable by retry, and the buyer has already paid.
        if (billingExists) {
          console.log('tenant row already exists from an earlier attempt:', clientId);
        } else {
          console.error('SLUG COLLISION AFTER PAYMENT — manual follow-up required:',
            sessionId, clientId, `${cityLabel}, ${state}`, session.customer_email || md.operator_email);
          await ownerAlert('ACTION NEEDED — slug collision after payment', [
            'A ConsignmentBiz payment completed but the storefront address was taken',
            'between checkout and provisioning. NOTHING has been provisioned and the',
            'territory has NOT been claimed.',
            '',
            `Requested slug: ${clientId}`,
            `Territory:      ${cityLabel}, ${state}`,
            `Buyer email:    ${session.customer_email || md.operator_email || '(none)'}`,
            `Amount:         $${amount}`,
            `Stripe session: ${sessionId}`,
            '',
            'NEXT: contact the buyer to pick a different storefront address, then',
            'provision manually — or refund.',
          ]);
          return json({ ok: true, skipped: 'slug_taken', session_id: sessionId });
        }
      } else {
        throw error;
      }
    }
  } catch (e) {
    logPostgrestError('tenant insert', e);
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
    logPostgrestError('cb_claim_city', e);
    return json({ ok: false, error: 'db_error' }, 500);   // retry
  }

  if (!claim || claim.ok !== true) {
    // Either we lost the race, or this is a resumed run and the claim already
    // belongs to us. Those look identical from the function's return value, so
    // read the row back before deciding.
    let ours = false;
    try {
      const { data } = await admin
        .from('cb_city_claims').select('client_id')
        .ilike('city_label', cityLabel).eq('state', state)
        .in('status', ['claimed', 'reserved']).limit(1);
      ours = !!(data && data.length && data[0].client_id === clientId);
    } catch (e) { /* fall through to the conflict path — safer than assuming */ }

    if (ours) {
      console.log('city already claimed by this tenant from an earlier attempt:', clientId);
    } else {
      // The buyer has paid for a city someone else now holds. 200 so Stripe
      // stops retrying: this needs a refund and a human, not another attempt.
      console.error('CITY CONFLICT AFTER PAYMENT — REFUND REQUIRED:',
        sessionId, `${cityLabel}, ${state}`, clientId,
        session.customer_email || md.operator_email, `amount=$${amount}`,
        `reason=${claim && claim.reason}`);
      await ownerAlert('REFUND NEEDED — city claimed by someone else after payment', [
        'A ConsignmentBiz payment completed but the territory was claimed by another',
        'operator first. The buyer has paid for a city they cannot have.',
        '',
        `Territory:      ${cityLabel}, ${state}`,
        `Buyer email:    ${session.customer_email || md.operator_email || '(none)'}`,
        `Requested slug: ${clientId}`,
        `Amount:         $${amount}`,
        `Stripe session: ${sessionId}`,
        `Reason:         ${(claim && claim.reason) || 'unknown'}`,
        '',
        'NEXT: refund in Stripe and email the buyer. An inactive cb_tenants row',
        `exists for "${clientId}" with no city claim — delete it once resolved.`,
      ]);
      return json({ ok: true, skipped: 'city_already_claimed', session_id: sessionId });
    }
  }

  // ── 4 · RECORD THE PAYMENT ────────────────────────────────────────────────
  // billing_type is constrained to 'one_time' by the schema (§3.11) — this
  // platform has no subscription, by design.
  if (!billingExists) {
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
      // 23505 on stripe_session_id means a concurrent delivery beat us to it.
      // That is success, not failure — the row we wanted exists.
      if (error && error.code !== '23505') throw error;
    } catch (e) {
      logPostgrestError('billing insert', e);
      return json({ ok: false, error: 'db_error' }, 500);   // retry
    }
  }

  console.log('territory claimed:', clientId, `${cityLabel}, ${state}`, `$${amount}`, sessionId);

  // ═════════════════════════════════════════════════════════════════════════
  // PROVISIONING (B5)
  //
  // Everything below runs with the service-role key. From here on the money is
  // recorded and the territory is held, so a failure is recoverable — but it
  // leaves a buyer who has paid and cannot log in, which is why each failure
  // path returns 500 (so Stripe retries) AND emails an alert.
  //
  // Each step is written to be safe to repeat: the per-step idempotency at the
  // top of this handler means a retry resumes rather than restarting.
  // ═════════════════════════════════════════════════════════════════════════

  const operatorEmail = String(md.operator_email || session.customer_email || '').trim();
  const operatorName  = String(md.operator_name || '').trim();
  const businessName  = String(md.business_name || '').trim();

  if (!operatorEmail) {
    console.error('NO OPERATOR EMAIL — cannot provision:', sessionId, clientId);
    await ownerAlert('ACTION NEEDED — paid territory with no operator email', [
      'Payment recorded and territory claimed, but there is no email address to',
      'create an account for. The operator cannot be contacted automatically.',
      '',
      `Client id:      ${clientId}`,
      `Territory:      ${cityLabel}, ${state}`,
      `Amount:         $${amount}`,
      `Stripe session: ${sessionId}`,
      '',
      'NEXT: find the buyer in Stripe and provision manually.',
    ]);
    return json({ ok: true, skipped: 'no_operator_email', session_id: sessionId });
  }

  // ── 5 · AUTH USER ─────────────────────────────────────────────────────────
  // NO PASSWORD IS SET OR GENERATED. createUser is called without one, so no
  // plaintext password exists anywhere — not in logs, not in email, not in
  // Stripe metadata. The operator sets their own via the recovery link below.
  //
  // email_confirm: true because the payment already proves the address works
  // well enough to transact; making them confirm before they can even set a
  // password adds a second thing to lose in a spam folder.
  let userId = null;
  try {
    const { data, error } = await admin.auth.admin.createUser({
      email: operatorEmail,
      email_confirm: true,
      user_metadata: { client_id: clientId, business_name: businessName, full_name: operatorName },
    });
    if (error) {
      // A repeat buyer, or a resumed run. Not an error — generateLink below
      // returns the existing user, so this is the recovery path, not a branch.
      const already = /already|exists|registered/i.test(error.message || '');
      if (!already) throw error;
      console.log('auth user already exists for', operatorEmail, '— reusing');
    } else {
      userId = data?.user?.id || null;
      console.log('auth user created:', userId, operatorEmail);
    }
  } catch (e) {
    console.error('createUser failed:', e);
    await ownerAlert('ACTION NEEDED — could not create operator account', [
      'Payment recorded and territory claimed, but creating the Supabase auth',
      'user failed. Stripe will retry, but check this if it repeats.',
      '',
      `Email:          ${operatorEmail}`,
      `Client id:      ${clientId}`,
      `Territory:      ${cityLabel}, ${state}`,
      `Stripe session: ${sessionId}`,
      `Error:          ${e.message || e}`,
    ]);
    return json({ ok: false, error: 'auth_error' }, 500);   // retry
  }

  // ── 6 · PASSWORD-SETUP LINK ───────────────────────────────────────────────
  // generateLink MINTS a link and returns it; it does not send anything, which
  // is what lets Brevo do the sending. (inviteUserByEmail would send via
  // Supabase's own SMTP instead.)
  //
  // ⚠ redirectTo MUST be allowlisted in Supabase → Authentication → URL
  //   Configuration → Redirect URLs. If it is not, Supabase silently falls back
  //   to the project's Site URL and the operator lands somewhere that cannot
  //   read the recovery token.
  let setupUrl = null;
  try {
    const { data, error } = await admin.auth.admin.generateLink({
      type: 'recovery',
      email: operatorEmail,
      options: { redirectTo: `${SITE_URL}/set-password.html` },
    });
    if (error) throw error;
    setupUrl = data?.properties?.action_link || null;
    // On the "user already existed" path above, this is where we learn the id.
    if (!userId) userId = data?.user?.id || null;
    if (!setupUrl) throw new Error('generateLink returned no action_link');
  } catch (e) {
    console.error('generateLink failed:', e);
    await ownerAlert('ACTION NEEDED — could not generate setup link', [
      'The operator account exists but no password-setup link could be created,',
      'so no welcome email has been sent.',
      '',
      `Email:          ${operatorEmail}`,
      `Client id:      ${clientId}`,
      `Stripe session: ${sessionId}`,
      `Error:          ${e.message || e}`,
      '',
      'NEXT: send a password reset from the Supabase dashboard.',
    ]);
    return json({ ok: false, error: 'auth_error' }, 500);   // retry
  }

  if (!userId) {
    console.error('no user id resolved for', operatorEmail);
    return json({ ok: false, error: 'auth_error' }, 500);   // retry
  }

  // ── 7 · MAP THE USER TO THE TENANT ────────────────────────────────────────
  // Until this row exists, admin.html's checkAuth() returns 'not_provisioned'
  // and the operator is locked out of their own dashboard. cb_client_users has
  // a UNIQUE (user_id, client_id), so a repeat is a no-op rather than an error.
  try {
    const { error } = await admin.from('cb_client_users').insert({
      user_id: userId,
      client_id: clientId,
      display_name: operatorName || businessName || null,
      role: 'operator',
    });
    if (error && error.code !== '23505') throw error;
  } catch (e) {
    logPostgrestError('cb_client_users insert', e);
    await ownerAlert('ACTION NEEDED — operator not linked to their shop', [
      'The auth account exists but the cb_client_users mapping failed, so the',
      'operator cannot reach their dashboard.',
      '',
      `Email:          ${operatorEmail}`,
      `User id:        ${userId}`,
      `Client id:      ${clientId}`,
      `Stripe session: ${sessionId}`,
    ]);
    return json({ ok: false, error: 'db_error' }, 500);   // retry
  }

  // ── 8 · POPULATE AND ACTIVATE THE TENANT ──────────────────────────────────
  // Stripe metadata is the ONLY record of what the buyer typed at intake —
  // there is no cb_intake table — so this is where it becomes durable.
  //
  // Activation is LAST of the database writes on purpose: the storefront must
  // not go live before the operator can log in and put something in it.
  //
  // Uses update, not upsert: the row was created in step 2, and an upsert here
  // could resurrect a tenant an admin had deliberately deactivated.
  try {
    const payoutPct = Number(md.payout_pct);
    const patch = {
      business_name:  businessName || clientId,
      tagline:        md.tagline || null,
      public_email:   operatorEmail,
      public_phone:   md.operator_phone || null,
      pickup_address: md.pickup_address || null,
      hours_text:     md.hours_text || null,
      is_active:      true,
    };
    // Only write a percentage the buyer actually chose; otherwise leave the
    // column default (50.00) alone. This is the CONSIGNOR's share (schema §3.1).
    if (Number.isFinite(payoutPct) && payoutPct >= 0 && payoutPct <= 100) {
      patch.default_payout_percentage = payoutPct;
    }
    const { error } = await admin.from('cb_tenants').update(patch).eq('client_id', clientId);
    if (error) throw error;
  } catch (e) {
    logPostgrestError('tenant activation', e);
    await ownerAlert('ACTION NEEDED — shop not activated', [
      'The operator account and mapping exist, but the tenant row could not be',
      'populated or activated, so the storefront is still dark.',
      '',
      `Client id:      ${clientId}`,
      `Territory:      ${cityLabel}, ${state}`,
      `Stripe session: ${sessionId}`,
    ]);
    return json({ ok: false, error: 'db_error' }, 500);   // retry
  }

  const storefrontUrl = `https://${clientId}.${APEX}`;
  const adminUrl      = `${SITE_URL}/admin.html`;

  // ── 9 · WELCOME EMAIL ─────────────────────────────────────────────────────
  // BEST-EFFORT from here down. Everything above is committed; a mail failure
  // must not return 500 and make Stripe retry work that is already done.
  //
  // If BREVO_TEMPLATE_ID is set the template receives SETUP_URL as a param and
  // owns the wording; otherwise the inline HTML below is sent.
  await sendBrevo({
    to: operatorEmail,
    toName: operatorName || businessName,
    templateId: BREVO_TEMPLATE_ID || undefined,
    params: BREVO_TEMPLATE_ID ? {
      FIRST_NAME:  (operatorName || '').split(/\s+/)[0] || '',
      COMPANY:     businessName || clientId,
      CITY:        `${cityLabel}, ${state}`,
      SLUG:        clientId,
      SETUP_URL:   setupUrl,
      STOREFRONT_URL: storefrontUrl,
      ADMIN_URL:   adminUrl,
      SUPPORT_EMAIL: SUPPORT_EMAIL,
    } : undefined,
    subject: `Your ConsignmentBiz shop is ready — set your password`,
    html: `
      <div style="font-family:system-ui,-apple-system,Segoe UI,sans-serif;max-width:560px;margin:0 auto;color:#1e2124;line-height:1.65;">
        <h1 style="font-size:22px;margin:0 0 14px;">${escHtml(cityLabel)}, ${escHtml(state)} is yours</h1>
        <p style="margin:0 0 16px;">Hi ${escHtml((operatorName || '').split(/\s+/)[0] || 'there')} — your payment is confirmed and
        <strong>${escHtml(businessName || clientId)}</strong> is set up.</p>
        <p style="margin:0 0 8px;"><strong>One step left:</strong> choose a password.</p>
        <p style="margin:0 0 22px;">
          <a href="${escHtml(setupUrl)}"
             style="display:inline-block;background:#6b7a90;color:#fff;text-decoration:none;padding:13px 26px;border-radius:8px;font-weight:600;">
            Set your password
          </a>
        </p>
        <p style="margin:0 0 16px;font-size:14px;color:#6b6f74;">
          <strong>This link expires in 24 hours</strong> and can only be used once.
          Didn't get it, or has it already expired? Email
          <a href="mailto:${SUPPORT_EMAIL}" style="color:#6b7a90;">${SUPPORT_EMAIL}</a>
          and we'll send you a fresh one.
        </p>
        <hr style="border:none;border-top:1px solid #dddad5;margin:22px 0;">
        <p style="margin:0 0 6px;font-size:14px;">Your storefront: <a href="${escHtml(storefrontUrl)}" style="color:#6b7a90;">${escHtml(storefrontUrl)}</a></p>
        <p style="margin:0 0 18px;font-size:14px;">Your dashboard: <a href="${escHtml(adminUrl)}" style="color:#6b7a90;">${escHtml(adminUrl)}</a></p>
        <p style="margin:0;font-size:13px;color:#9a9ea3;">ConsignmentBiz — a Kingdom Creatives LLC platform</p>
      </div>`,
    text: [
      `${cityLabel}, ${state} is yours.`,
      '',
      `Your payment is confirmed and ${businessName || clientId} is set up.`,
      'One step left — choose a password:',
      setupUrl,
      '',
      'This link expires in 24 hours and can only be used once.',
      `Didn't get it, or has it already expired? Email ${SUPPORT_EMAIL} and we'll send a fresh one.`,
      '',
      `Storefront: ${storefrontUrl}`,
      `Dashboard:  ${adminUrl}`,
    ].join('\n'),
  });

  // ── 10 · OWNER NOTIFICATION ───────────────────────────────────────────────
  await ownerAlert(`New operator — ${businessName || clientId} (${cityLabel}, ${state})`, [
    'New territory sold on ConsignmentBiz.',
    '',
    `Business:       ${businessName || '(none given)'}`,
    `Contact:        ${operatorName || '(none given)'}`,
    `Email:          ${operatorEmail}`,
    `Phone:          ${md.operator_phone || '(none)'}`,
    `Territory:      ${cityLabel}, ${state}`,
    `Client id:      ${clientId}`,
    `Amount:         $${amount}`,
    `Stripe session: ${sessionId}`,
    '',
    `Storefront:     ${storefrontUrl}`,
    `Dashboard:      ${adminUrl}`,
    '',
    'Provisioned automatically. The operator has been emailed a password-setup',
    'link that expires in 24 hours.',
  ]);

  console.log('provisioned:', clientId, operatorEmail, userId);

  return json({
    ok: true,
    claimed: `${cityLabel}, ${state}`,
    client_id: clientId,
    user_id: userId,
    provisioned: true,
  });
}
