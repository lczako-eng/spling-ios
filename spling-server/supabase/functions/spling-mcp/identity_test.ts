// ============================================================================
// Tests for the sign-in layer.
//
// Run: node --experimental-strip-types identity_test.ts
//
// The failure this file guards against is the worst one Spling has: handing one
// person's profile — which is to say one person's allergens — to someone else.
// Every check below is a way that could happen.
// ============================================================================

import {
  PROVIDERS, callbackUrl, isEmail, linkSentPage, normalizeProvider,
  providerAuthorizeUrl, signInPage, subjectOfSupabaseUser, troublePage,
} from "./identity.ts";

let passed = 0;
const failures: string[] = [];
function test(name: string, fn: () => void) {
  try { fn(); passed++; } catch (e) { failures.push(`${name}\n    ${(e as Error).message}`); }
}
function assert(c: unknown, m: string) { if (!c) throw new Error(m); }
function eq(a: unknown, b: unknown, m = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${m}\n    expected: ${y}\n    actual:   ${x}`);
}
function throws(fn: () => unknown, m: string) {
  try { fn(); } catch { return; }
  throw new Error(m);
}

const ISSUER = "https://abc.supabase.co/functions/v1/spling-mcp";
const SUPA = "https://abc.supabase.co";

// ---------------------------------------------------------------------------
// providers — the list is the allowlist
// ---------------------------------------------------------------------------
test("the three ways in are Google, Apple and an email link", () => {
  eq([...PROVIDERS], ["google", "apple", "email"], "providers");
});

test("provider names come from the list, never from the form", () => {
  eq(normalizeProvider("Google"), "google", "case-insensitive");
  eq(normalizeProvider(" apple "), "apple", "trimmed");
  throws(() => normalizeProvider("facebook"), "an unlisted provider must be refused");
  throws(() => normalizeProvider("google&provider=evil"), "no injection through the provider name");
  throws(() => normalizeProvider(undefined), "absent is not a provider");
});

// ---------------------------------------------------------------------------
// the round trip to the identity provider
// ---------------------------------------------------------------------------
test("the callback is built from our own issuer, never from the request", () => {
  const cb = callbackUrl(ISSUER, "rid-123");
  assert(cb.startsWith(ISSUER + "/auth/callback"), `must live under the issuer: ${cb}`);
  eq(new URL(cb).searchParams.get("rid"), "rid-123", "reference carried");
});

test("a reference with URL metacharacters cannot escape the callback", () => {
  const cb = callbackUrl(ISSUER, "a&redirect_to=https://evil.example/x");
  const u = new URL(cb);
  eq(u.origin + u.pathname, ISSUER + "/auth/callback", "path unchanged");
  eq([...u.searchParams.keys()], ["rid"], "no smuggled parameters");
});

test("the provider URL carries PKCE and comes back to us", () => {
  const u = new URL(providerAuthorizeUrl({
    supabaseUrl: SUPA, provider: "google",
    callback: callbackUrl(ISSUER, "r1"), codeChallenge: "CHALLENGE",
  }));
  eq(u.pathname, "/auth/v1/authorize", "hosted flow");
  eq(u.searchParams.get("provider"), "google", "provider");
  eq(u.searchParams.get("code_challenge_method"), "s256", "PKCE, and not plain");
  assert((u.searchParams.get("redirect_to") ?? "").startsWith(ISSUER), "returns to us");
});

test("a trailing slash on the project URL does not double up", () => {
  const u = providerAuthorizeUrl({
    supabaseUrl: SUPA + "/", provider: "apple", callback: callbackUrl(ISSUER, "r"), codeChallenge: "c",
  });
  assert(!u.includes("//auth/v1"), `no doubled slash: ${u}`);
});

// ---------------------------------------------------------------------------
// the subject — a wrong answer here is someone else's profile
// ---------------------------------------------------------------------------
test("the subject is a Supabase user id and nothing else", () => {
  eq(subjectOfSupabaseUser({ id: "3F2504E0-4F89-11D3-9A0C-0305E82C3301" }),
     "3f2504e0-4f89-11d3-9a0c-0305e82c3301", "normalised to lower case so one person is one subject");
});

test("anything that is not a user id fails loudly", () => {
  throws(() => subjectOfSupabaseUser(null), "no user");
  throws(() => subjectOfSupabaseUser({}), "no id");
  throws(() => subjectOfSupabaseUser({ id: "" }), "empty id");
  throws(() => subjectOfSupabaseUser({ id: "not-a-uuid" }), "malformed id");
  throws(() => subjectOfSupabaseUser({ id: 12345 }), "non-string id");
  throws(() => subjectOfSupabaseUser({ error: "invalid_grant" }), "an error body is not an identity");
});

// ---------------------------------------------------------------------------
// email
// ---------------------------------------------------------------------------
test("email checking rejects the shapes that are obviously not addresses", () => {
  assert(isEmail("a@b.co"), "ordinary address");
  assert(isEmail("someone+tag@sub.example.org"), "plus addressing and subdomains");
  assert(!isEmail("nope"), "no @");
  assert(!isEmail("a@b"), "no dot in the domain");
  assert(!isEmail("a b@c.de"), "whitespace");
  assert(!isEmail("a@b.co\nBcc: someone@else.com"), "no header injection into the mailer");
  assert(!isEmail("a".repeat(300) + "@b.co"), "bounded");
  assert(!isEmail(undefined), "absent");
});

// ---------------------------------------------------------------------------
// the pages — these are read by people, sometimes read aloud
// ---------------------------------------------------------------------------
test("the sign-in page offers all three ways in, as a real form", () => {
  const p = signInPage({ clientName: "Claude", action: ISSUER + "/signin", rid: "r1" });
  for (const v of ['value="google"', 'value="apple"', 'value="email"']) {
    assert(p.includes(v), `missing ${v}`);
  }
  assert(p.includes('method="POST"'), "a real form, not a script");
  assert(!/<script/i.test(p), "must work with JavaScript off");
  assert(p.includes('type="email"'), "the email field is typed, so phones show the right keyboard");
  assert(p.includes('<label for="email"'), "the field is labelled, so a screen reader can announce it");
});

test("the sign-in page carries the reference and nothing else about the request", () => {
  const p = signInPage({ clientName: "Claude", action: ISSUER + "/signin", rid: "r1" });
  const hidden = [...p.matchAll(/<input type="hidden" name="([a-z_]+)"/g)].map((m) => m[1]);
  eq([...new Set(hidden)], ["rid"], "client_id, redirect_uri and the challenge stay server-side");
});

test("a client name cannot inject markup into the page", () => {
  const p = signInPage({ clientName: '<img src=x onerror="alert(1)">', action: "/x", rid: "r" });
  assert(!p.includes("<img"), "a registered client name is attacker-controlled and must be escaped");
  assert(p.includes("&lt;img"), "escaped, not dropped");
});

test("an error message cannot inject markup either", () => {
  const p = signInPage({ clientName: "Claude", action: "/x", rid: "r", error: "<b>x</b>" });
  assert(!p.includes("<b>x</b>"), "escaped");
});

test("the 'check your email' page does not confirm the address exists", () => {
  const p = linkSentPage().toLowerCase();
  assert(p.includes("if that address"), "conditional wording — never 'we sent it to you'");
});

test("the failure page says nothing about which part failed", () => {
  const p = troublePage("That sign-in link is no longer valid.");
  for (const leak of ["expired", "client_id", "subject", "token", "database"]) {
    assert(!p.toLowerCase().includes(leak), `must not disclose "${leak}"`);
  }
  assert(p.includes("Nothing was connected"), "says what is true and useful instead");
});

test("the pages make no outbound request", () => {
  for (const p of [
    signInPage({ clientName: "Claude", action: "/x", rid: "r" }),
    linkSentPage(),
    troublePage("no"),
  ]) {
    assert(!/https?:\/\/(?!spling)/i.test(p.replace(/action="[^"]*"/g, "")),
      "no fonts, no logos, no analytics — nobody learns that this person is signing in");
  }
});

console.log(`\nidentity: ${passed} passed, ${failures.length} failed\n`);
if (failures.length) {
  for (const f of failures) console.error("  ✗ " + f + "\n");
  process.exit(1);
}
console.log("  ✓ providers, callbacks, subjects and the sign-in pages all hold\n");
