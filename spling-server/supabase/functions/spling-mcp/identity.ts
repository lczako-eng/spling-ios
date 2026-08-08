// ============================================================================
// Who is this? — the sign-in layer.
//
// OAuth (auth.ts) answers "may this assistant act for someone". It does not
// answer "who". Until this file existed, /authorize minted a fresh random
// subject per grant, which meant the same person re-connecting on a new phone
// arrived as a stranger: no language, no history, no allergens. For a product
// whose whole value is that you never have to explain yourself twice, that is
// not a rough edge, it is the product failing.
//
// So identity is delegated, to the two buttons almost everyone already has —
// Google and Apple — with an email link for everyone else. That third option
// is not a footnote. The people Spling is built for include those least likely
// to hold a Google or Apple account: an 85-year-old, someone in supported
// living whose device is managed by a care home, a newcomer three weeks into
// the country. A sign-in wall that only speaks Silicon Valley would exclude
// exactly the users this exists for.
//
// Apple is also not optional in the other direction: App Store review requires
// Sign in with Apple wherever another third-party sign-in is offered, and
// there is an iOS app in this repo's future.
//
// The provider is Supabase Auth (already in the stack, so no new vendor and no
// new place for personal data to sit). The subject Spling stores is the
// Supabase user id and nothing else — no email, no name, no provider token
// ever lands in a Spling table.
//
// Everything here except the two network calls at the bottom is pure, so the
// parts where a mistake leaks an account are testable with no database.
// ============================================================================

import { OAuthError, sha256 } from "./auth.ts";

// deno-lint-ignore no-explicit-any
const env = (k: string): string => (globalThis as any).Deno?.env?.get(k) ?? "";

/**
 * How long a parked authorization request stays live. Generous on purpose: the
 * email-link path means switching apps, finding the message, and pressing a
 * link — and the people this is built for are not always fast at that. Half an
 * hour is long enough not to punish them, short enough that an abandoned
 * request is not lying around all day.
 */
export const PENDING_TTL_S = 60 * 30;

export type ProviderId = "google" | "apple" | "email";

export const PROVIDERS: ReadonlyArray<ProviderId> = ["google", "apple", "email"];

/**
 * Only these three, and only ever from this list. Supabase's authorize endpoint
 * will happily start a flow for any provider named in a query string, so the
 * name has to be pinned here rather than passed through from the form.
 */
export function normalizeProvider(raw: unknown): ProviderId {
  const p = String(raw ?? "").toLowerCase().trim();
  if (p === "google" || p === "apple" || p === "email") return p;
  throw new OAuthError("invalid_request", "Choose Google, Apple, or an email link.");
}

/**
 * Deliberately permissive. This is not a validity oracle — Supabase will decide
 * whether the address exists by whether the link arrives. It rejects the shapes
 * that are obviously not an address, and bounds the length so nothing absurd
 * reaches the mailer.
 */
export function isEmail(raw: unknown): boolean {
  const s = String(raw ?? "").trim();
  if (s.length < 6 || s.length > 254) return false;
  if (/\s/.test(s)) return false;
  return /^[^@]+@[^@.]+(\.[^@.]+)+$/.test(s);
}

/**
 * Where the identity provider sends the person back. Built from the server's
 * own issuer, never from anything the client sent — an attacker-supplied value
 * here would turn Supabase into a delivery service for someone else's session.
 */
export function callbackUrl(issuer: string, rid: string): string {
  return `${issuer}/auth/callback?rid=${encodeURIComponent(rid)}`;
}

/** Supabase Auth's hosted flow, with PKCE so the code is useless if intercepted. */
export function providerAuthorizeUrl(input: {
  supabaseUrl: string;
  provider: "google" | "apple";
  callback: string;
  codeChallenge: string;
}): string {
  const u = new URL(`${input.supabaseUrl.replace(/\/+$/, "")}/auth/v1/authorize`);
  u.searchParams.set("provider", input.provider);
  u.searchParams.set("redirect_to", input.callback);
  u.searchParams.set("code_challenge", input.codeChallenge);
  u.searchParams.set("code_challenge_method", "s256");
  return u.toString();
}

/**
 * A Supabase user id is the subject. Anything else — a missing id, a truncated
 * one, an error body that happens to parse — must fail loudly rather than
 * become a subject that could collide with someone else's.
 */
export function subjectOfSupabaseUser(user: unknown): string {
  const id = (user as { id?: unknown } | null)?.id;
  const ok = typeof id === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id);
  if (!ok) throw new OAuthError("access_denied", "Sign-in did not complete.");
  return (id as string).toLowerCase();
}

// ---------------------------------------------------------------------------
// pages
//
// Real HTML, real form, no JavaScript. Someone on a care-home tablet with a
// screen reader and a locked-down browser has to be able to finish this.
// ---------------------------------------------------------------------------

export function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

const PAGE_CSS = `
  :root{ --ink:#0B0A12; --paper:#F5F3EE; --purple:#5E3DCC; --muted:#4C4964; --hair:rgba(11,10,18,.14); }
  *{ box-sizing:border-box; margin:0; padding:0; }
  body{ font-family: system-ui, -apple-system, "Segoe UI", sans-serif; background:var(--paper);
        color:var(--ink); font-size:1.0625rem; line-height:1.6; padding:32px 20px; }
  main{ max-width:34rem; margin:0 auto; }
  h1{ font-size:1.6rem; line-height:1.2; margin-bottom:14px; }
  h2{ font-size:1.05rem; margin:26px 0 10px; }
  p{ margin-bottom:14px; }
  ul{ margin:0 0 20px 1.2em; }
  li{ margin-bottom:8px; }
  .who{ font-weight:700; }
  .note{ color:var(--muted); font-size:.95rem; }
  button{ font: inherit; font-weight:700; color:#fff; background:var(--purple);
          border:1px solid var(--purple); border-radius:10px; padding:15px 26px;
          width:100%; cursor:pointer; margin-bottom:12px;
          display:flex; align-items:center; justify-content:center; gap:10px; }
  button:hover{ filter:brightness(.94); }
  button:focus-visible{ outline:3px solid var(--ink); outline-offset:3px; }
  button.google{ background:#fff; color:#1F1F1F; border-color:var(--hair); }
  button.apple{ background:#000; color:#fff; border-color:#000; }
  button.secondary{ background:transparent; color:var(--ink); border-color:var(--hair); }
  label{ display:block; font-weight:600; margin-bottom:6px; }
  input[type=email]{ font:inherit; width:100%; padding:14px 14px; margin-bottom:12px;
          border:1px solid var(--hair); border-radius:10px; background:#fff; color:var(--ink); }
  input[type=email]:focus-visible{ outline:3px solid var(--ink); outline-offset:2px; }
  .card{ border:1px solid var(--hair); border-left:3px solid var(--purple);
         border-radius:10px; padding:18px 20px; margin-bottom:22px; background:#fff; }
  .rule{ border:0; border-top:1px solid var(--hair); margin:24px 0; }
  .err{ border-left-color:#B3261E; }
  svg{ flex:none; }
`;

function page(title: string, body: string): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>${PAGE_CSS}</style>
</head>
<body>
<main>
${body}
</main>
</body>
</html>`;
}

// Inline marks, so the page makes no outbound request — nothing here reports
// back to anyone that a particular person is signing in to Spling.
const GOOGLE_MARK =
  `<svg width="18" height="18" viewBox="0 0 48 48" aria-hidden="true" focusable="false">` +
  `<path fill="#4285F4" d="M45 24c0-1.6-.1-2.7-.4-3.9H24v7.1h12c-.2 1.9-1.5 4.7-4.4 6.6l6.7 5.2C42.2 35.5 45 30.3 45 24z"/>` +
  `<path fill="#34A853" d="M24 46c5.9 0 10.9-2 14.5-5.3l-6.9-5.4c-1.8 1.3-4.3 2.2-7.6 2.2-5.8 0-10.8-3.8-12.5-9.1l-7.1 5.5C8 41.2 15.4 46 24 46z"/>` +
  `<path fill="#FBBC05" d="M11.5 28.4A13.5 13.5 0 0 1 10.8 24c0-1.5.3-3 .7-4.4l-7.1-5.5A22 22 0 0 0 2 24c0 3.5.8 6.9 2.4 9.9z"/>` +
  `<path fill="#EA4335" d="M24 9.5c4.1 0 6.9 1.8 8.5 3.3l6.2-6C34.9 3.4 29.9 1 24 1 15.4 1 8 5.9 4.4 13.1l7.1 5.5C13.2 13.3 18.2 9.5 24 9.5z"/></svg>`;

const APPLE_MARK =
  `<svg width="17" height="20" viewBox="0 0 14 17" aria-hidden="true" focusable="false" fill="currentColor">` +
  `<path d="M11.6 9c0-1.9 1.6-2.8 1.6-2.9-.9-1.3-2.2-1.5-2.7-1.5-1.2-.1-2.3.7-2.9.7-.6 0-1.5-.7-2.5-.7C3.8 4.6 2.6 5.4 2 6.6c-1.3 2.3-.3 5.6.9 7.5.6.9 1.3 1.9 2.3 1.9.9 0 1.2-.6 2.3-.6s1.4.6 2.4.6c1 0 1.6-.9 2.2-1.8.7-1 1-2.1 1-2.1s-1.5-.6-1.5-2.3zM9.8 3.3c.5-.6.9-1.5.8-2.4-.8 0-1.7.5-2.3 1.2-.5.6-.9 1.5-.8 2.4.9.1 1.8-.5 2.3-1.2z"/></svg>`;

/**
 * The sign-in screen. For many of the people this is built for it is the first
 * thing they will ever see of Spling, so it says what will happen in words
 * their assistant could read aloud unchanged.
 */
export function signInPage(input: {
  clientName: string;
  action: string;
  rid: string;
  error?: string;
}): string {
  const err = input.error
    ? `<div class="card err"><p>${escapeHtml(input.error)}</p></div>`
    : "";
  const rid = `<input type="hidden" name="rid" value="${escapeHtml(input.rid)}">`;

  return page("Sign in to Spling", `
  <h1>Sign in to Spling</h1>
  <p>You are connecting Spling to <span class="who">${escapeHtml(input.clientName)}</span>.
  We will ask what it may see on the next screen.</p>
  <p>Signing in is how Spling remembers <strong>your</strong> language, the way you prefer
  to communicate, and any allergies — so you never have to explain them again.</p>
  ${err}

  <form method="POST" action="${escapeHtml(input.action)}">
    ${rid}
    <button type="submit" name="provider" value="google" class="google">${GOOGLE_MARK}<span>Continue with Google</span></button>
    <button type="submit" name="provider" value="apple" class="apple">${APPLE_MARK}<span>Continue with Apple</span></button>
  </form>

  <hr class="rule">

  <form method="POST" action="${escapeHtml(input.action)}">
    ${rid}
    <h2>Or get a link by email</h2>
    <label for="email">Your email address</label>
    <input type="email" id="email" name="email" autocomplete="email" inputmode="email"
           required placeholder="you@example.com">
    <button type="submit" name="provider" value="email">Email me a link</button>
    <p class="note">No password to make up, and none to forget. We email you a link,
    you press it, and you are signed in.</p>
  </form>

  <p class="note">Spling never sees your password, and never handles your card.
  You can take your profile with you or delete it at any time.</p>
`);
}

/** Shown after a magic link is sent. Deliberately does not confirm the address exists. */
export function linkSentPage(): string {
  return page("Check your email", `
  <h1>Check your email</h1>
  <div class="card">
    <p>If that address can receive mail, a sign-in link is on its way to it now.</p>
    <p>Open the email and press the link. It works for a short time only, so if it
    has been a while, come back here and ask for a new one.</p>
  </div>
  <p class="note">You can close this page once you have pressed the link.</p>
`);
}

/** The only failure page. It never explains which part failed, to anyone. */
export function troublePage(message: string): string {
  return page("Something went wrong", `
  <h1>That didn't work</h1>
  <div class="card err"><p>${escapeHtml(message)}</p></div>
  <p>Nothing was connected and nothing was shared. Ask your assistant to try connecting
  Spling again.</p>
`);
}

// ---------------------------------------------------------------------------
// the two network calls
// ---------------------------------------------------------------------------

function supabaseAuth(): { url: string; anonKey: string } {
  const url = env("SUPABASE_URL").replace(/\/+$/, "");
  const anonKey = env("SUPABASE_ANON_KEY");
  if (!url || !anonKey) {
    throw new OAuthError("server_error", "Sign-in is not configured on this server.", 500);
  }
  return { url, anonKey };
}

export function supabaseAuthorizeUrl(provider: "google" | "apple", callback: string, codeChallenge: string): string {
  return providerAuthorizeUrl({ supabaseUrl: supabaseAuth().url, provider, callback, codeChallenge });
}

/**
 * Ask Supabase to email a sign-in link. The response is ignored on purpose:
 * telling the caller whether an address is registered turns this endpoint into
 * an account-enumeration oracle.
 */
export async function sendMagicLink(email: string, callback: string, codeChallenge: string): Promise<void> {
  const { url, anonKey } = supabaseAuth();
  const target = new URL(`${url}/auth/v1/otp`);
  target.searchParams.set("redirect_to", callback);
  await fetch(target.toString(), {
    method: "POST",
    headers: { apikey: anonKey, "Content-Type": "application/json" },
    body: JSON.stringify({
      email,
      create_user: true,
      code_challenge: codeChallenge,
      code_challenge_method: "s256",
    }),
  }).catch(() => {});
}

/** Exchange the provider's code for the Supabase user, and keep only their id. */
export async function exchangeForSubject(authCode: string, codeVerifier: string): Promise<string> {
  const { url, anonKey } = supabaseAuth();
  const res = await fetch(`${url}/auth/v1/token?grant_type=pkce`, {
    method: "POST",
    headers: { apikey: anonKey, "Content-Type": "application/json" },
    body: JSON.stringify({ auth_code: authCode, code_verifier: codeVerifier }),
  });
  if (!res.ok) throw new OAuthError("access_denied", "Sign-in did not complete.");
  const body = await res.json().catch(() => null);
  // Only the id is read. The access token, refresh token, email and provider
  // tokens in this response are deliberately dropped on the floor — Spling has
  // no use for them and no business storing them.
  return subjectOfSupabaseUser(body?.user);
}

/** The PKCE pair Spling holds on behalf of the person while they are away signing in. */
export async function challengeFor(verifier: string): Promise<string> {
  return await sha256(verifier);
}
