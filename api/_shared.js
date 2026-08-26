// ═══════════════════════════════════════════════════════════════════════════
// api/_shared.js — helpers used by every ConsignmentBiz server endpoint.
//
// Files under /api whose name starts with "_" are not routed by Vercel, so this
// is importable but never reachable as a URL.
//
// EVERYTHING HERE RUNS WITH THE SERVICE ROLE. cb_tenants, cb_city_claims and
// cb_billing have no insert policy for anon or authenticated (schema §9) — only
// service_role, which bypasses RLS, may write them. That is deliberate: a buyer
// cannot self-provision or claim a city no matter what they send.
//
// Mirrors GarageSaleBiz's api/_shared.js. EstateSaleBiz has no /api directory
// and no webhook — its Stripe surface is hardcoded buy.stripe.com Payment Links
// with provisioning done from the buyer's browser after redirect, which is the
// pattern GSB was built to replace.
// ═══════════════════════════════════════════════════════════════════════════

import { createClient } from '@supabase/supabase-js';

// ── ENVIRONMENT ─────────────────────────────────────────────────────────────
// Every one of these is set in Vercel → Settings → Environment Variables.
// NOTHING here is ever hardcoded, and none of these names appear in any .html.
// ⚠ SUPABASE_URL MUST BE A BARE ORIGIN — https://<ref>.supabase.co, no path,
// no trailing slash. supabase-js appends "/rest/v1" to whatever it is given, so:
//
//   "https://x.supabase.co/"         -> https://x.supabase.co//rest/v1/table
//   "https://x.supabase.co/rest/v1"  -> https://x.supabase.co/rest/v1/rest/v1/table
//
// Both make PostgREST answer PGRST125 "Invalid path specified in request URL",
// which reads like a malformed QUERY but is really a malformed BASE URL — the
// table name and filters are never even reached. Normalised here so a stray
// slash in the Vercel dashboard cannot break every endpoint.
//
// (SITE_URL below was already trimmed this way; SUPABASE_URL was not. That
// inconsistency is what let this through.)
export const SUPABASE_URL = String(process.env.SUPABASE_URL || '')
  .trim()
  .replace(/\/+$/, '')          // trailing slashes
  .replace(/\/rest\/v1$/i, '')  // a pasted REST path
  .replace(/\/+$/, '');         // and any slash that exposed

export const SERVICE_ROLE_KEY      = process.env.SUPABASE_SERVICE_ROLE_KEY || '';
export const STRIPE_SECRET_KEY     = process.env.STRIPE_SECRET_KEY || '';
export const STRIPE_PRICE_ID       = process.env.STRIPE_PRICE_ID || '';
export const STRIPE_WEBHOOK_SECRET = process.env.STRIPE_WEBHOOK_SECRET || '';
export const BREVO_API_KEY         = process.env.BREVO_API_KEY || '';
// Optional. EstateSaleBiz's welcome mail uses a Brevo template; if this is
// unset, sendBrevo falls back to the inline HTML the caller supplies, so
// provisioning works before the template exists.
export const BREVO_TEMPLATE_ID     = process.env.BREVO_TEMPLATE_ID || '';
export const SITE_URL = (process.env.PUBLIC_SITE_URL || 'https://consignmentbiz.com').replace(/\/+$/, '');

// Floor for a legitimate purchase, in cents.
//
// ⚠ MUST SIT BELOW THE LIST PRICE. ConsignmentBiz is $197 = 19700 cents, so the
// default here is 15000. GarageSaleBiz defaults this to 20000 because its price
// is $249 — inheriting that number would put the floor ABOVE our price and
// reject every real payment as amount_too_low.
export const MIN_AMOUNT_CENTS = Number(process.env.STRIPE_MIN_AMOUNT_CENTS || '15000');

export const SUPPORT_EMAIL = 'info@kingdom-creatives.com';
export const APEX          = 'consignmentbiz.com';

// Slugs that must never become a tenant subdomain: they are real pages at the
// repo root, or reserved infrastructure labels. A buyer typing "admin" would
// otherwise be handed admin.consignmentbiz.com.
export const RESERVED_SLUGS = new Set([
  'www', 'api', 'admin', 'app', 'demo', 'mail', 'ftp', 'blog', 'help', 'support',
  'status', 'staging', 'dev', 'test', 'assets', 'static', 'cdn', 'dashboard',
  'account', 'billing', 'login', 'signup', 'intake', 'consign', 'item', 'about',
  'terms', 'privacy', 'refund', 'owner', 'kingdom', 'consignmentbiz',
]);

// ── SUPABASE ────────────────────────────────────────────────────────────────
export function adminClient() {
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    throw new Error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are not configured');
  }
  // Fails loudly at startup rather than as an opaque PGRST125 on the first
  // query. Anything with a path left after normalisation is a real
  // misconfiguration, not a stray slash we can silently absorb.
  if (!/^https?:\/\/[^/]+$/i.test(SUPABASE_URL)) {
    throw new Error(
      `SUPABASE_URL must be a bare origin with no path — got "${SUPABASE_URL}". ` +
      'Use https://<project-ref>.supabase.co (no trailing slash, no /rest/v1).'
    );
  }
  return createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

// PostgREST returns { code, message, details, hint }. Logging all four turns the
// next failure of this kind into a one-read diagnosis instead of a guess —
// PGRST125 in particular says nothing useful without the URL it was given.
export function logPostgrestError(where, err) {
  console.error(`${where} failed:`, JSON.stringify({
    code: err?.code, message: err?.message, details: err?.details, hint: err?.hint,
    supabase_url: SUPABASE_URL,
  }));
}

// ── HTTP ────────────────────────────────────────────────────────────────────
export const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};

export function json(body, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json', ...extraHeaders },
  });
}

export function preflight() {
  return new Response('ok', { headers: CORS_HEADERS });
}

// Every payment rejection returns 402 with the same recovery instruction, so a
// real buyer who trips a check always knows what to do next — and is told
// plainly they will not be charged twice.
export function paymentRequired(reason, detail) {
  console.warn('payment gate rejected:', reason, detail || '');
  return json({
    ok: false,
    error: 'payment_unverified',
    reason,
    message:
      "We couldn't verify a completed purchase for this link. " +
      `If you've already paid, email ${SUPPORT_EMAIL} and we'll finish setting up ` +
      "your account right away — you won't be charged twice.",
  }, 402);
}

// ── CITY / SLUG NORMALISATION ───────────────────────────────────────────────
// ⚠ THIS MIRRORS THE DATABASE, IT IS NOT THE GUARANTEE.
//
// The authority is the partial unique index in schema §3.4:
//     create unique index cb_city_claims_unique_active
//       on cb_city_claims (lower(city_label), upper(state))
//       where status in ('claimed','reserved');
//
// So the stored uniqueness key is literally lower(city) + upper(state) — no
// abbreviation expansion, no punctuation stripping. These functions do exactly
// that and nothing more.
//
// KNOWN LIMITATION, deliberately not "fixed" here: because the index does no
// normalisation beyond lower(), "St. Louis" and "Saint Louis" are DIFFERENT
// territories, and both could be sold. GarageSaleBiz solves this with a
// gsb_norm_city() trigger; ConsignmentBiz has no equivalent. Adding a smarter
// normaliser HERE without one in the database would be worse than none — the
// pre-check would disagree with the index, so a taken city would read as
// available and only fail after payment. Fix it in the schema or not at all.
export function normCity(s) {
  return String(s == null ? '' : s).trim().replace(/\s+/g, ' ').toLowerCase();
}
export function normState(s) {
  return String(s == null ? '' : s).trim().toUpperCase();
}

export function slugify(s) {
  return String(s == null ? '' : s)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40);
}

// ── STRIPE ──────────────────────────────────────────────────────────────────
// Stripe's API is form-encoded, including nested keys like metadata[client_id]
// and line_items[0][price]. Written out rather than pulled from the SDK: every
// Stripe call here is a plain fetch, so there is no SDK version to keep in step
// with the API version, and nothing extra to install.
export function stripeForm(obj, prefix = '', out = new URLSearchParams()) {
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined || v === null) continue;
    const key = prefix ? `${prefix}[${k}]` : k;
    if (Array.isArray(v)) {
      v.forEach((item, i) => {
        if (item !== null && typeof item === 'object') stripeForm(item, `${key}[${i}]`, out);
        else out.append(`${key}[${i}]`, String(item));
      });
    } else if (typeof v === 'object') {
      stripeForm(v, key, out);
    } else {
      out.append(key, String(v));
    }
  }
  return out;
}

export async function stripePost(path, body) {
  const res = await fetch(`https://api.stripe.com/v1/${path}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${STRIPE_SECRET_KEY}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: stripeForm(body).toString(),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(data?.error?.message || `stripe ${res.status}`);
    err.stripeStatus = res.status;
    err.stripeCode = data?.error?.code;
    throw err;
  }
  return data;
}

// Retrieve a Checkout Session and decide whether it represents a real,
// completed, correctly-priced, UNREFUNDED one-time purchase.
// Returns { session, charge } or { fail: Response }.
export async function verifyStripeSession(sessionId) {
  if (!STRIPE_SECRET_KEY) {
    // Misconfiguration, not the buyer's fault — fail closed and shout in logs.
    console.error('STRIPE_SECRET_KEY is not set; refusing to treat anything as paid.');
    return { fail: paymentRequired('stripe_not_configured') };
  }

  let res;
  try {
    res = await fetch(
      `https://api.stripe.com/v1/checkout/sessions/${encodeURIComponent(sessionId)}`,
      { headers: { Authorization: `Bearer ${STRIPE_SECRET_KEY}` } },
    );
  } catch (e) {
    console.error('Stripe fetch failed:', e);
    return { fail: paymentRequired('stripe_unreachable') };
  }
  if (!res.ok) {
    // 404 = no such session: fabricated, or from a different Stripe account.
    const body = await res.text().catch(() => '');
    return { fail: paymentRequired('session_not_found', `http ${res.status} ${body.slice(0, 200)}`) };
  }

  const session = await res.json();

  // One-time purchases only. Rejects by SHAPE rather than by maintaining a list
  // of price ids that could drift out of sync with Stripe.
  if (session.mode !== 'payment') {
    return { fail: paymentRequired('not_one_time_payment', `mode=${session.mode}`) };
  }
  // Rejects unpaid, expired, and 100%-off 'no_payment_required' sessions.
  if (session.payment_status !== 'paid') {
    return { fail: paymentRequired('not_paid', `payment_status=${session.payment_status}`) };
  }
  if (typeof session.amount_total !== 'number' || session.amount_total < MIN_AMOUNT_CENTS) {
    return { fail: paymentRequired('amount_too_low', `amount_total=${session.amount_total}`) };
  }
  if (session.currency && String(session.currency).toLowerCase() !== 'usd') {
    return { fail: paymentRequired('unexpected_currency', `currency=${session.currency}`) };
  }

  // ── REFUND GATE ──────────────────────────────────────────────────────────
  // STRIPE DOES NOT CHANGE payment_status WHEN A PAYMENT IS REFUNDED. A fully
  // refunded session still reads 'paid', so every check above passes it.
  // Refund state is not on the Checkout Session at all — it lives on the
  // Charge, which hangs off the PaymentIntent. Hence the second call.
  const piId = typeof session.payment_intent === 'string'
    ? session.payment_intent
    : session.payment_intent?.id;
  if (!piId) {
    // mode === 'payment' should always carry a PaymentIntent, so this is
    // anomalous. Fail closed: absence of evidence that a payment was refunded
    // is not evidence that it was not.
    return { fail: paymentRequired('no_payment_intent', `session=${sessionId}`) };
  }

  let piRes;
  try {
    // expand[]=latest_charge returns the Charge inline, so refund state arrives
    // in ONE extra call rather than two.
    //
    // PERMISSIONS: a restricted key needs PaymentIntents:Read AND Charges:Read.
    // This gate fails closed, so a 403 here rejects EVERY buyer rather than only
    // refunded ones. Use a full secret key unless you have a reason not to.
    piRes = await fetch(
      `https://api.stripe.com/v1/payment_intents/${encodeURIComponent(piId)}?expand[]=latest_charge`,
      { headers: { Authorization: `Bearer ${STRIPE_SECRET_KEY}` } },
    );
  } catch (e) {
    console.error('Stripe payment_intent fetch failed:', e);
    return { fail: paymentRequired('stripe_pi_unreachable') };
  }
  if (!piRes.ok) {
    const body = await piRes.text().catch(() => '');
    console.error('Stripe payment_intent read failed:', piRes.status, body.slice(0, 200));
    return { fail: paymentRequired('stripe_pi_unreachable', `http ${piRes.status}`) };
  }
  const pi = await piRes.json();

  // TWO SHAPES, deliberately. No Stripe-Version header is sent, so the response
  // follows the ACCOUNT'S default API version:
  //   modern -> pi.latest_charge (expanded to an object by the request above)
  //   legacy -> pi.charges.data[0]  (the `charges` array was removed in a major
  //             release and does not exist on current versions)
  // Reading only pi.charges.data[0] throws a TypeError on a modern account,
  // surfacing as a 500 that blocks every buyer, not merely refunded ones.
  const charge = (pi.latest_charge && typeof pi.latest_charge === 'object')
    ? pi.latest_charge
    : (pi.charges?.data?.[0] ?? null);

  if (!charge) {
    return { fail: paymentRequired('no_charge_on_payment_intent', `pi=${piId} status=${pi.status}`) };
  }
  if (charge.refunded === true) {
    return { fail: paymentRequired('payment_refunded', `pi=${piId} charge=${charge.id}`) };
  }
  // Belt and braces: a PARTIAL refund leaves refunded=false while
  // amount_refunded is non-zero. Someone refunded $150 of $197 must not keep a
  // full territory.
  if (typeof charge.amount_refunded === 'number' && charge.amount_refunded > 0) {
    return {
      fail: paymentRequired('payment_refunded',
        `pi=${piId} charge=${charge.id} partial amount_refunded=${charge.amount_refunded}`),
    };
  }

  console.log('verified purchase:', sessionId,
    'amount=', session.amount_total,
    'refund_status=', `refunded=${charge.refunded} amount_refunded=${charge.amount_refunded ?? 0}`);

  return { session, charge };
}

// ── BREVO ───────────────────────────────────────────────────────────────────
// HTTP shape mirrors EstateSaleBiz's provision-buyer exactly: same endpoint,
// same three headers, same sender/to structure, and the same choice between a
// templateId+params send and a subject+textContent send.
//
// EVERY SEND IS BEST-EFFORT AND NEVER THROWS. ESB's comment states the contract:
// "Never fails the signup: the buyer's account and tenant already exist either
// way." By the time any of these fire, money has changed hands and the database
// is already correct — a mail failure must never turn that into an error the
// buyer sees, or into a 500 that makes Stripe retry work that is already done.
export async function sendBrevo({
  to, toName, subject, html, text, templateId, params,
  senderName, replyToEmail, replyToName,
}) {
  if (!BREVO_API_KEY) { console.log('Brevo not configured — skipping send:', subject || templateId); return false; }
  try {
    const body = {
      // The address is always ours and always verified; only the name a
      // recipient sees changes, so a shop's mail arrives looking like the
      // shop's without failing authentication.
      sender: { name: senderName || 'ConsignmentBiz', email: SUPPORT_EMAIL },
      replyTo: {
        email: replyToEmail || SUPPORT_EMAIL,
        name:  replyToName  || senderName || 'ConsignmentBiz Support',
      },
      to: [{ email: to, ...(toName ? { name: toName } : {}) }],
    };
    if (templateId) {
      body.templateId = Number(templateId);
      if (params) body.params = params;
    } else {
      if (subject) body.subject = subject;
      if (html) body.htmlContent = html;
      if (text) body.textContent = text;
    }

    const res = await fetch('https://api.brevo.com/v3/smtp/email', {
      method: 'POST',
      headers: { 'api-key': BREVO_API_KEY, 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      const b = await res.text().catch(() => '');
      console.error('Brevo send failed:', res.status, b.slice(0, 300));
      return false;
    }
    console.log('Brevo sent:', subject || `template ${templateId}`, '->', to);
    return true;
  } catch (e) {
    console.error('Brevo send threw:', e);
    return false;
  }
}

// Owner-facing alert. Plain text on purpose — these are read on a phone at
// speed, and every one of them means something needs a human.
export function ownerAlert(subject, lines) {
  return sendBrevo({
    to: SUPPORT_EMAIL,
    subject,
    text: Array.isArray(lines) ? lines.join('\n') : String(lines),
  });
}

// ── ESCAPING ────────────────────────────────────────────────────────────────
// Buyer-supplied text (business name, contact name) goes into an HTML email
// body, so it passes through here first.
export function escHtml(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// ── STRIPE WEBHOOK SIGNATURE ────────────────────────────────────────────────
// Verifies the Stripe-Signature header against the RAW request body.
//
// THE RAW BODY IS NOT OPTIONAL AND NOT INTERCHANGEABLE WITH THE PARSED ONE.
// The signature is computed over the exact bytes Stripe sent; re-serialising a
// parsed object reorders keys and changes whitespace, so JSON.stringify(body)
// fails verification every time. The handler reads request.text() first.
//
// WITHOUT THIS CHECK the webhook is an unauthenticated public URL that claims
// territories. Anyone who guessed it could POST a fabricated
// checkout.session.completed and take a city off the market for free. The
// endpoint re-verifies the session against the Stripe API afterwards, which is a
// second independent gate — but this is the first, and it is the cheap one.
export async function verifyStripeSignature(rawBody, sigHeader, secret, toleranceSeconds = 300) {
  if (!secret) { console.error('STRIPE_WEBHOOK_SECRET is not set'); return { ok: false, reason: 'no_secret' }; }
  if (!sigHeader) return { ok: false, reason: 'no_signature_header' };

  let timestamp = null;
  const v1s = [];
  for (const part of String(sigHeader).split(',')) {
    const [k, val] = part.split('=', 2).map(x => (x || '').trim());
    if (k === 't') timestamp = val;
    else if (k === 'v1') v1s.push(val);
  }
  if (!timestamp || v1s.length === 0) return { ok: false, reason: 'malformed_signature_header' };

  // Replay window. Without it a signature captured once stays valid forever, so
  // a single intercepted delivery could be replayed indefinitely.
  const age = Math.abs(Math.floor(Date.now() / 1000) - Number(timestamp));
  if (!Number.isFinite(age) || age > toleranceSeconds) {
    return { ok: false, reason: `timestamp_outside_tolerance (${age}s)` };
  }

  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${timestamp}.${rawBody}`));
  const expected = Array.from(new Uint8Array(mac)).map(b => b.toString(16).padStart(2, '0')).join('');

  // Constant-time compare against each supplied v1. Stripe sends more than one
  // during a secret rotation, so all candidates must be tried.
  const matched = v1s.some(sig => timingSafeEqualHex(sig, expected));
  return matched ? { ok: true } : { ok: false, reason: 'signature_mismatch' };
}

// Length-independent, branch-free comparison. A plain === on a secret-derived
// string leaks timing information about how many leading characters matched.
function timingSafeEqualHex(a, b) {
  const A = String(a || ''), B = String(b || '');
  if (A.length !== B.length) return false;
  let diff = 0;
  for (let i = 0; i < A.length; i++) diff |= A.charCodeAt(i) ^ B.charCodeAt(i);
  return diff === 0;
}
