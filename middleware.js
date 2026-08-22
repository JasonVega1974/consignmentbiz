// Routing Middleware — runs BEFORE the filesystem, so it can override the site
// root even though index.html exists there. vercel.json `rewrites` cannot do
// this: they are fallback-only (applied only when no file matches the path), so
// a rewrite whose source is "/" is silently skipped because "/" serves
// index.html. Middleware runs earlier and branches on the request host.
//
// Mirrors EstateSaleBiz's middleware.js, with one deliberate change: ESB
// hardcodes its Supabase URL and anon key as module constants. Here both come
// from Vercel environment variables, so rotating the key is a dashboard change
// rather than a code edit. Set in Vercel → Settings → Environment Variables:
//   SUPABASE_URL        e.g. https://<project-ref>.supabase.co
//   SUPABASE_ANON_KEY   the anon/publishable key
//
// ONLY the site root is intercepted. Every other tenant page (item.html,
// consign.html, about.html) is a real file at the repo root, so
// {operator}.consignmentbiz.com/item.html?id=… already serves the right file
// with no rewrite. Root is the sole collision, because index.html lives there.
import { rewrite, next } from '@vercel/functions';

export const config = {
  matcher: '/',                 // only intercept the site root
};

const APEX = 'consignmentbiz.com';

// The tenant storefront. Named demo.html to mirror EstateSaleBiz exactly —
// it serves EVERY tenant, not a demo. Do not rename without updating this.
const STOREFRONT = '/demo.html';

export default async function middleware(request) {
  const host = (request.headers.get('host') || '').toLowerCase().split(':')[0];

  // A single-label subdomain that is NOT www → serve the tenant storefront at "/".
  // (www exclusion is done here in JS, avoiding Vercel's RE2 no-lookahead limit.)
  if (host.endsWith('.' + APEX) && host !== 'www.' + APEX) {
    return rewrite(new URL(STOREFRONT, request.url));
  }

  // apex, www, *.vercel.app, localhost → unchanged (funnel / index.html)
  if (host === APEX || host === 'www.' + APEX || host.endsWith('.vercel.app') || host === 'localhost') {
    return next();
  }

  // Anything else is a candidate custom domain. Only route it to the tenant
  // storefront if it's a known, active custom_domain — an unrecognized host (or
  // one still "pending") falls through to the funnel instead of a
  // half-configured storefront.
  //
  // Queries the PUBLIC VIEW, not cb_tenants: anon has no select policy on the
  // base table by design (see schema §9), so the view is the only readable
  // path. cb_public_tenants already filters to is_active tenants and only
  // emits custom_domain once its status is 'active', so a row coming back here
  // means "active tenant, verified domain" without needing a status filter.
  //
  // Fails open to next() on any error — a missing env var or a Supabase hiccup
  // shows the funnel, which is a better failure than a 500 for a real visitor.
  const SUPABASE_URL = process.env.SUPABASE_URL;
  const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return next();

  try {
    const res = await fetch(
      `${SUPABASE_URL}/rest/v1/cb_public_tenants` +
      `?custom_domain=eq.${encodeURIComponent(host)}` +
      `&select=custom_domain&limit=1`,
      { headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` } }
    );
    const rows = await res.json();
    if (Array.isArray(rows) && rows.length) {
      return rewrite(new URL(STOREFRONT, request.url));
    }
  } catch (e) { /* on any error, fall through to the funnel */ }

  return next();
}
