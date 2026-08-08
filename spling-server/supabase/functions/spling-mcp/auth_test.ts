// ============================================================================
// Tests for the OAuth layer.
//
// Run: node --experimental-strip-types auth_test.ts
//
// These guard the parts where a mistake hands someone else's profile away —
// which for this product means someone else's allergens. The pure functions are
// tested directly; the endpoint handlers need a database and are exercised
// against the deployed function.
// ============================================================================

import {
  OAuthError, SCOPES, authorizationServerMetadata, narrowScopes, pickRedirectUri,
  protectedResourceMetadata, randomToken, safeEqual, sha256, validateRedirectUri,
  validateRegistration, verifyPkce, wwwAuthenticate,
} from "./auth.ts";

let passed = 0;
const failures: string[] = [];
function test(name: string, fn: () => void | Promise<void>) {
  const done = () => { passed++; };
  try {
    const r = fn();
    if (r instanceof Promise) return r.then(done, (e) => { failures.push(`${name}\n    ${e.message}`); });
    done();
  } catch (e) { failures.push(`${name}\n    ${(e as Error).message}`); }
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

const tests: Array<void | Promise<void>> = [];

// ---------------------------------------------------------------------------
// PKCE — the thing standing between an intercepted code and someone's profile
// ---------------------------------------------------------------------------
tests.push(test("PKCE S256 accepts a correct verifier", async () => {
  const verifier = randomToken(48);
  const challenge = await sha256(verifier);
  assert(await verifyPkce(verifier, challenge, "S256"), "correct verifier must pass");
}));

tests.push(test("PKCE rejects a wrong verifier", async () => {
  const challenge = await sha256(randomToken(48));
  assert(!(await verifyPkce(randomToken(48), challenge, "S256")), "wrong verifier must fail");
}));

tests.push(test("PKCE refuses 'plain' outright", async () => {
  const verifier = randomToken(48);
  assert(!(await verifyPkce(verifier, verifier, "plain")), "'plain' offers no protection and is removed in OAuth 2.1");
}));

tests.push(test("PKCE enforces verifier length bounds", async () => {
  const short = "abc";
  assert(!(await verifyPkce(short, await sha256(short), "S256")), "a 3-char verifier is brute-forceable");
  const long = "a".repeat(200);
  assert(!(await verifyPkce(long, await sha256(long), "S256")), "over 128 chars is out of spec");
}));

// ---------------------------------------------------------------------------
// redirect URIs — an open redirect here leaks authorization codes
// ---------------------------------------------------------------------------
test("accepts https and loopback redirect URIs", () => {
  validateRedirectUri("https://claude.ai/api/mcp/auth_callback");
  validateRedirectUri("http://localhost:3000/callback");
  validateRedirectUri("http://127.0.0.1:8080/cb");
});

test("rejects plain http on a public host", () => {
  throws(() => validateRedirectUri("http://evil.example.com/cb"), "http off-loopback must be refused");
});

test("rejects wildcards and fragments", () => {
  throws(() => validateRedirectUri("https://*.example.com/cb"), "wildcards must be refused");
  throws(() => validateRedirectUri("https://example.com/cb#frag"), "fragments must be refused");
});

test("rejects a non-absolute URI", () => {
  throws(() => validateRedirectUri("/callback"), "relative URIs must be refused");
});

test("redirect matching is exact — no prefix matching", () => {
  const registered = ["https://claude.ai/api/mcp/auth_callback"];
  eq(pickRedirectUri(registered, registered[0]), registered[0], "exact match");
  throws(
    () => pickRedirectUri(registered, "https://claude.ai/api/mcp/auth_callback.evil.com"),
    "a prefix must not be accepted — that is how codes get stolen",
  );
  throws(() => pickRedirectUri(registered, "https://claude.ai/api/mcp/"), "a shorter prefix must not match");
});

test("a client with several redirect URIs must name one", () => {
  const many = ["https://a.example/cb", "https://b.example/cb"];
  throws(() => pickRedirectUri(many, undefined), "ambiguous redirect must be refused");
  eq(pickRedirectUri(many, many[1]), many[1], "naming one is fine");
  eq(pickRedirectUri([many[0]], undefined), many[0], "a single registered URI needs no naming");
});

// ---------------------------------------------------------------------------
// registration
// ---------------------------------------------------------------------------
test("registration requires at least one redirect URI", () => {
  throws(() => validateRegistration({}), "no redirect_uris");
  throws(() => validateRegistration({ redirect_uris: [] }), "empty redirect_uris");
});

test("registration refuses grant types OAuth 2.1 removed", () => {
  throws(
    () => validateRegistration({ redirect_uris: ["https://a.example/cb"], grant_types: ["implicit"] }),
    "implicit must be refused",
  );
  throws(
    () => validateRegistration({ redirect_uris: ["https://a.example/cb"], grant_types: ["password"] }),
    "password grant must be refused",
  );
});

test("registration defaults to a public client using PKCE", () => {
  const reg = validateRegistration({ redirect_uris: ["https://a.example/cb"] });
  eq(reg.token_endpoint_auth_method, "none", "assistants are public clients");
  eq(reg.grant_types, ["authorization_code", "refresh_token"], "default grants");
});

test("registration truncates an absurd client name", () => {
  const reg = validateRegistration({ redirect_uris: ["https://a.example/cb"], client_name: "x".repeat(5000) });
  assert((reg.client_name ?? "").length <= 200, "name is bounded");
});

// ---------------------------------------------------------------------------
// scopes
// ---------------------------------------------------------------------------
test("scopes are narrowed to what this server grants", () => {
  eq(narrowScopes("spling.order spling.admin"), ["spling.order"], "unknown scopes dropped");
  eq(narrowScopes("nonsense"), [...SCOPES], "nothing recognised falls back to the default set");
  eq(narrowScopes(undefined), [...SCOPES], "absent means default");
});

// ---------------------------------------------------------------------------
// discovery — without these an assistant cannot start a login
// ---------------------------------------------------------------------------
test("authorization server metadata advertises only what is implemented", () => {
  const m = authorizationServerMetadata("https://x.example/functions/v1/spling-mcp");
  eq(m.code_challenge_methods_supported, ["S256"], "never advertise plain");
  eq(m.response_types_supported, ["code"], "code flow only");
  eq(m.grant_types_supported, ["authorization_code", "refresh_token"], "no implicit, no password");
  assert(m.registration_endpoint.endsWith("/register"), "DCR endpoint advertised");
});

test("protected resource metadata points at the authorization server", () => {
  const issuer = "https://x.example/functions/v1/spling-mcp";
  const m = protectedResourceMetadata(issuer);
  eq(m.authorization_servers, [issuer], "authorization server");
  eq(m.bearer_methods_supported, ["header"], "header only — never a query string");
});

test("the 401 challenge tells a client where to look", () => {
  const h = wwwAuthenticate("https://x.example/fn");
  assert(h.startsWith("Bearer "), "scheme");
  assert(h.includes("/.well-known/oauth-protected-resource"), "points at discovery");
});

// ---------------------------------------------------------------------------
// primitives
// ---------------------------------------------------------------------------
test("safeEqual is length-safe and correct", () => {
  assert(safeEqual("abc", "abc"), "equal");
  assert(!safeEqual("abc", "abd"), "differing");
  assert(!safeEqual("abc", "abcd"), "different lengths");
});

tests.push(test("tokens are long, unguessable and URL-safe", async () => {
  const a = randomToken(32), b = randomToken(32);
  assert(a !== b, "not repeating");
  assert(a.length >= 40, `long enough: ${a.length}`);
  assert(/^[A-Za-z0-9_-]+$/.test(a), `URL-safe: ${a}`);
}));

tests.push(test("hashing is stable and not the identity", async () => {
  const t = randomToken(32);
  eq(await sha256(t), await sha256(t), "stable");
  assert((await sha256(t)) !== t, "a stored hash must not be the token itself");
}));

await Promise.all(tests);

console.log(`\noauth: ${passed} passed, ${failures.length} failed\n`);
if (failures.length) {
  for (const f of failures) console.error("  ✗ " + f + "\n");
  process.exit(1);
}
console.log("  ✓ PKCE, redirect matching, registration and discovery all hold\n");
