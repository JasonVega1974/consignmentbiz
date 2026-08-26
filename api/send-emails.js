// ═══════════════════════════════════════════════════════════════════════════
// POST /api/send-emails
//
// Drains cb_email_outbox. A scheduler calls this; the browser never does.
//
// ── WHY A DRAINER AND NOT A SEND-ON-DEMAND ENDPOINT ─────────────────────────
// The obvious shape is /api/send-reserve-email, called from item.html once the
// reserve RPC returns ok. Two problems with that, both fatal:
//
//   1. It is EstateSaleBiz's mistake again. A buyer who closes the tab between
//      the RPC committing and the fetch firing holds an item and never hears
//      about it. CB's Stripe flow is a webhook for exactly this reason.
//   2. An endpoint that emails whoever the caller names is a spam relay. It
//      would have to re-read everything from the database to be safe, at which
//      point the request body is doing no work.
//
// So the database queues rows inside the transaction that caused them, and
// this drains the queue. An unsent row is a retry; there is nothing to lose.
//
// ── ON THE SENDER ───────────────────────────────────────────────────────────
// Buyer-facing mail goes out as the SHOP, not as ConsignmentBiz — but only as
// far as Brevo permits. We cannot put the operator's own address in the
// envelope: Brevo rejects unverified senders, and a forged From would fail
// SPF/DKIM at the recipient and land in spam. So:
//
//     sender  = { name: "<shop name>", email: info@kingdom-creatives.com }
//     replyTo = { name: "<shop name>", email: <tenant.public_email> }
//
// The buyer sees the shop's name in their inbox and a reply reaches the shop.
// True from-the-shop sending needs per-operator domain authentication in
// Brevo, which is a different piece of work.
// ═══════════════════════════════════════════════════════════════════════════

import {
  adminClient, sendBrevo, ownerAlert, escHtml, json,
  logPostgrestError, SUPPORT_EMAIL, SITE_URL,
} from './_shared.js';

export const config = { runtime: 'nodejs' };

export default { fetch: handler };

// How many to take per invocation. Vercel functions have a wall-clock budget
// and Brevo rate-limits; a bounded batch that runs again in five minutes beats
// one that times out halfway and leaves rows in an unknown state.
const BATCH = 25;

// Give up after this many tries and tell the owner. Without a ceiling a
// permanently bad address is retried until the end of time, and the failure is
// invisible because nothing ever errors loudly.
const MAX_ATTEMPTS = 3;

const SEND_SECRET = process.env.SEND_EMAILS_SECRET || '';

async function handler(request) {
  if (request.method !== 'POST' && request.method !== 'GET') {
    return json({ ok: false, error: 'method_not_allowed' }, 405);
  }

  // Vercel Cron sends GET with its own bearer; pg_net sends POST with ours.
  // Either must prove it is not a stranger — this endpoint sends mail.
  if (!authorised(request)) {
    console.error('send-emails: unauthorised call');
    return json({ ok: false, error: 'unauthorised' }, 401);
  }

  let admin;
  try { admin = adminClient(); }
  catch (e) {
    console.error('send-emails: no service-role client:', e.message);
    return json({ ok: false, error: 'server_misconfigured' }, 500);
  }

  // CLAIM, don't select. cb_claim_email_batch() does FOR UPDATE SKIP LOCKED
  // and increments attempts in the same statement, which PostgREST cannot
  // express on its own. Two overlapping drains therefore take disjoint rows
  // instead of both sending the same emails — and a run that dies mid-flight
  // has already spent the attempt, so a row that kills the worker cannot be
  // retried forever.
  const { data: rows, error } = await admin.rpc('cb_claim_email_batch', {
    p_limit: BATCH,
    p_max_attempts: MAX_ATTEMPTS,
  });

  if (error) {
    logPostgrestError('send-emails claim', error);
    return json({ ok: false, error: 'db_claim_failed' }, 500);
  }
  if (!rows || rows.length === 0) return json({ ok: true, sent: 0, failed: 0, pending: 0 });

  let sent = 0, failed = 0;

  for (const row of rows) {
    let built;
    try { built = build(row); }
    catch (e) {
      // A malformed payload will never render, however many times we try, so
      // burn the remaining attempts now rather than retrying for a day.
      await admin.from('cb_email_outbox')
        .update({ attempts: MAX_ATTEMPTS, last_error: 'render failed: ' + e.message })
        .eq('id', row.id);
      await ownerAlert('Shop email could not be rendered', [
        'kind:      ' + row.kind,
        'to:        ' + row.to_email,
        'client_id: ' + row.client_id,
        'outbox id: ' + row.id,
        'error:     ' + e.message,
        '',
        'The payload is malformed. This will not be retried.',
      ]);
      failed++;
      continue;
    }

    const ok = await sendBrevo(built);

    if (ok) {
      const { error: upErr } = await admin.from('cb_email_outbox')
        .update({ sent_at: new Date().toISOString(), last_error: null })
        .eq('id', row.id);
      // Sent but not marked: the next run sends it again. A duplicate email is
      // a far smaller problem than a silent one, so this is logged, not fixed.
      if (upErr) logPostgrestError('send-emails mark-sent', upErr);
      sent++;
    } else {
      await admin.from('cb_email_outbox')
        .update({ last_error: 'brevo send returned false' })
        .eq('id', row.id);
      failed++;
      // row.attempts is the count INCLUDING this one, so this fires on the
      // third failure rather than after a fourth that never happens.
      if (row.attempts >= MAX_ATTEMPTS) {
        await ownerAlert('Shop email gave up after ' + MAX_ATTEMPTS + ' attempts', [
          'kind:      ' + row.kind,
          'to:        ' + row.to_email,
          'client_id: ' + row.client_id,
          'outbox id: ' + row.id,
          '',
          'It will not be retried. Check the address and the Brevo logs.',
        ]);
      }
    }
  }

  const { count } = await admin
    .from('cb_email_outbox')
    .select('id', { count: 'exact', head: true })
    .is('sent_at', null)
    .lt('attempts', MAX_ATTEMPTS);

  console.log(`send-emails: sent ${sent}, failed ${failed}, still pending ${count ?? '?'}`);
  return json({ ok: true, sent, failed, pending: count ?? null });
}

function authorised(request) {
  if (!SEND_SECRET) {
    // Fail closed. An unauthenticated mail sender is worse than a broken one.
    console.error('send-emails: SEND_EMAILS_SECRET is not set');
    return false;
  }
  const header = request.headers.get('x-send-secret');          // pg_net
  const bearer = (request.headers.get('authorization') || '')   // Vercel Cron
    .replace(/^Bearer\s+/i, '');
  return header === SEND_SECRET || bearer === SEND_SECRET;
}

/* ── RENDERING ─────────────────────────────────────────────────────────────
   Inline styles only, and a table for layout. Gmail strips <style> blocks and
   ignores flex and grid, so anything structural has to be a table cell and
   anything visual has to be an attribute on the element it applies to.
   Fraunces will not load in most clients either — the stack falls back to
   Georgia, which is close enough in colour and weight to hold the character.
──────────────────────────────────────────────────────────────────────────── */
const BG = '#0f1a14', PANEL = '#16261c', LINE = 'rgba(242,233,220,.12)';
const TX = '#f2e9dc', TX2 = '#b3a291', TX3 = '#7d6b5c', BRASS = '#c9a24b';
const SERIF = "Georgia,'Times New Roman',serif";
const SANS = "'Helvetica Neue',Helvetica,Arial,sans-serif";

function shell(shopName, heading, bodyHtml, footerHtml) {
  return `<!DOCTYPE html>
<html><body style="margin:0;padding:0;background:${BG};">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${BG};padding:28px 12px;">
<tr><td align="center">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:${PANEL};border:1px solid ${LINE};border-radius:12px;">
    <tr><td style="padding:22px 26px 0;border-bottom:1px solid ${LINE};">
      <p style="margin:0 0 16px;font-family:${SERIF};font-size:17px;font-weight:bold;color:${BRASS};">${escHtml(shopName)}</p>
    </td></tr>
    <tr><td style="padding:26px;">
      <h1 style="margin:0 0 16px;font-family:${SERIF};font-size:23px;line-height:1.25;color:${TX};font-weight:normal;">${heading}</h1>
      ${bodyHtml}
    </td></tr>
    <tr><td style="padding:18px 26px 24px;border-top:1px solid ${LINE};">
      ${footerHtml}
    </td></tr>
  </table>
  <p style="margin:16px 0 0;font-family:${SANS};font-size:11px;color:${TX3};">Powered by ConsignmentBiz</p>
</td></tr>
</table>
</body></html>`;
}

const p = (t) => `<p style="margin:0 0 12px;font-family:${SANS};font-size:14px;line-height:1.65;color:${TX2};">${t}</p>`;

// A labelled figure. Two cells rather than one styled line, because Outlook
// collapses margins on stacked block elements unpredictably.
const row = (label, value) =>
  `<tr>
     <td style="padding:7px 0;font-family:${SANS};font-size:12px;color:${TX3};">${escHtml(label)}</td>
     <td style="padding:7px 0;font-family:${SERIF};font-size:15px;color:${TX};text-align:right;">${escHtml(value)}</td>
   </tr>`;

const table = (rowsHtml) =>
  `<table role="presentation" width="100%" cellpadding="0" cellspacing="0"
          style="margin:4px 0 18px;border-top:1px solid ${LINE};border-bottom:1px solid ${LINE};">${rowsHtml}</table>`;

function money(v) {
  const n = Number(v);
  return Number.isFinite(n) ? '$' + n.toFixed(2).replace(/\.00$/, '') : String(v ?? '');
}

// Dates render in the SHOP's words, not the server's locale. No timezone is
// stored per tenant, so this states the date plainly and leaves the precise
// hour to the shop — a buyer who needs the exact minute will call.
function when(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso ?? '');
  return d.toLocaleDateString('en-US', {
    weekday: 'long', month: 'long', day: 'numeric', timeZone: 'UTC',
  });
}

function contactBlock(d) {
  const bits = [];
  if (d.shop_email) bits.push(`<a href="mailto:${escHtml(d.shop_email)}" style="color:${BRASS};">${escHtml(d.shop_email)}</a>`);
  if (d.shop_phone) bits.push(escHtml(d.shop_phone));
  const lines = [];
  if (bits.length) lines.push(p('Reach the shop at ' + bits.join(' or ') + '.'));
  if (d.shop_address) lines.push(p('Collect from ' + escHtml(d.shop_address) + (d.shop_hours ? ', ' + escHtml(d.shop_hours) : '') + '.'));
  return lines.join('');
}

function build(rowRec) {
  const d = rowRec.payload || {};
  const shop = d.shop_name || 'The shop';

  // Buyer mail leaves as the shop; operator mail is plainly from us, because
  // pretending their own shop emailed them would be absurd.
  const asShop = {
    senderName: shop,
    replyToEmail: d.shop_email || SUPPORT_EMAIL,
    replyToName: shop,
  };

  if (rowRec.kind === 'reserve_confirmation') {
    if (!d.item_name) throw new Error('reserve_confirmation missing item_name');
    return {
      to: rowRec.to_email,
      toName: rowRec.to_name,
      ...asShop,
      subject: `Your ${d.item_name} is held at ${shop}`,
      html: shell(shop, `We're holding it for you.`,
        p(`${escHtml(d.buyer_name || 'Hello')} — ${escHtml(d.item_name)} is reserved in your name. Nobody else can buy it before your hold runs out.`)
        + table(row('Item', d.item_name) + row('Price', money(d.item_price)) + row('Held until', when(d.reserved_until)))
        + p(`<strong style="color:${TX};">Payment happens in person, at pickup.</strong> There is nothing to pay online and no card to enter — bring payment when you collect.`),
        contactBlock(d)
        + p(`<span style="color:${TX3};font-size:12px;">If you can't make it, a quick note frees the piece up for someone else.</span>`)),
      text: [
        `${d.buyer_name || 'Hello'} — ${d.item_name} is reserved in your name at ${shop}.`,
        ``,
        `Item:       ${d.item_name}`,
        `Price:      ${money(d.item_price)}`,
        `Held until: ${when(d.reserved_until)}`,
        ``,
        `Payment happens in person, at pickup. Nothing to pay online.`,
        d.shop_address ? `Collect from ${d.shop_address}${d.shop_hours ? ', ' + d.shop_hours : ''}.` : '',
        d.shop_email ? `Questions: ${d.shop_email}` : '',
        d.shop_phone ? `Phone: ${d.shop_phone}` : '',
      ].filter(Boolean).join('\n'),
    };
  }

  if (rowRec.kind === 'expiry_reminder') {
    if (!d.item_name) throw new Error('expiry_reminder missing item_name');
    return {
      to: rowRec.to_email,
      toName: rowRec.to_name,
      ...asShop,
      subject: `Your hold on ${d.item_name} expires tomorrow`,
      html: shell(shop, `Your hold runs out tomorrow.`,
        p(`${escHtml(d.buyer_name || 'Hello')} — this is a reminder that ${escHtml(d.item_name)} is still held for you, but not for much longer.`)
        + table(row('Item', d.item_name) + row('Price', money(d.item_price)) + row('Hold ends', when(d.reserved_until)))
        + p(`After that it goes back on the shop floor for someone else. Get in touch to arrange collection.`),
        contactBlock(d)),
      text: [
        `${d.buyer_name || 'Hello'} — your hold on ${d.item_name} at ${shop} ends ${when(d.reserved_until)}.`,
        ``,
        `Item:      ${d.item_name}`,
        `Price:     ${money(d.item_price)}`,
        `Hold ends: ${when(d.reserved_until)}`,
        ``,
        `After that it returns to the shop floor. Get in touch to arrange collection.`,
        d.shop_email ? `Email: ${d.shop_email}` : '',
        d.shop_phone ? `Phone: ${d.shop_phone}` : '',
      ].filter(Boolean).join('\n'),
    };
  }

  if (rowRec.kind === 'sale_alert') {
    if (!d.item_name) throw new Error('sale_alert missing item_name');
    // payout_owed is the CONSIGNOR'S share, frozen at the moment of sale by
    // cb_create_payout_on_sold(). Stated with the direction named, because
    // "60%" alone is the one number in this system that reads backwards.
    const payout = d.has_consignor
      ? table(
          row('Item', d.item_name)
          + row('Sold for', money(d.item_price))
          + row('Consignor', d.consignor_name || '—')
          + row(`Owed to consignor (${d.payout_pct ?? '—'}%)`, money(d.payout_owed)))
      : table(row('Item', d.item_name) + row('Sold for', money(d.item_price)) + row('Consignor', 'None — your own stock'));

    return {
      to: rowRec.to_email,
      toName: rowRec.to_name,
      subject: `You just sold ${d.item_name} for ${money(d.item_price)}`,
      html: shell(shop, `That's one out the door.`,
        p(`${escHtml(d.item_name)} is marked sold.`)
        + payout
        + (d.has_consignor
            ? p(`The amount owed was recorded at the moment of sale, so changing the price later can't alter it. Settle up whenever suits — the dashboard tracks what's outstanding.`)
            : p(`No consignor on this one, so the full amount is yours.`)),
        p(`<a href="${SITE_URL}/admin.html" style="color:${BRASS};">Open your dashboard</a>`)),
      text: [
        `${d.item_name} is marked sold for ${money(d.item_price)}.`,
        ``,
        d.has_consignor
          ? `Owed to consignor${d.consignor_name ? ' (' + d.consignor_name + ')' : ''}: ${money(d.payout_owed)} — ${d.payout_pct ?? '—'}% of the sale.`
          : `No consignor on this one, so the full amount is yours.`,
        ``,
        `Dashboard: ${SITE_URL}/admin.html`,
      ].filter(Boolean).join('\n'),
    };
  }

  throw new Error('unknown outbox kind: ' + rowRec.kind);
}
