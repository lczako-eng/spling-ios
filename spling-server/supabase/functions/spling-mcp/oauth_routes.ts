// ============================================================================
// The OAuth endpoints.
//
// One design note that matters more than the protocol details: the consent
// screen is the first thing many of our users will ever see of Spling, and for
// some of them reading it is the hard part. So it is written in plain language,
// says exactly what is being shared, and does not use a phrase like "authorize
// third-party client access to your resource scopes". It is also a real HTML
// page with a real button — no JavaScript required to sign in.
// ============================================================================

import {
  ACCESS_TTL_S, CODE_TTL_S, OAuthError, REFRESH_TTL_S,
  authorizationServerMetadata, issuerFrom, narrowScopes, pickRedirectUri,
  protectedResourceMetadata, randomToken, sha256, safeEqual, validateRegistration,
  verifyPkce,
} from "./auth.ts";
import {
  attachSubject, consumePending, createClient, findAnyToken, findToken, getClient,
  getPending, markCodeConsumed, revokeAllForSubject, revokeGrant, revokeToken,
  storeCode, storePending, storeToken, takeCode,
} from "./oauth_store.ts";
import {
  PENDING_TTL_S, callbackUrl, challengeFor, escapeHtml, exchangeForSubject, isEmail,
  linkSentPage, normalizeProvider, sendMagicLink, signInPage, supabaseAuthorizeUrl,
  troublePage,
} from "./identity.ts";

const JSON_HEADERS = { "Content-Type": "application/json", "Cache-Control": "no-store" };

function json(body: unknown, status = 200, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), { status, headers: { ...JSON_HEADERS, ...extra } });
}

function oauthErrorResponse(e: unknown) {
  if (e instanceof OAuthError) {
    return json({ error: e.code, error_description: e.message }, e.status);
  }
  return json({ error: "server_error", error_description: "The request could not be completed." }, 500);
}

function html(body: string, status = 200) {
  return new Response(body, {
    status,
    headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" },
  });
}

/**
 * Every dead end a person can reach in a browser looks the same and says the
 * same thing. An expired reference, a forged one and a failed sign-in are
 * different to us and identical to them — which is the point: the differences
 * are only useful to someone probing.
 */
function trouble(message = "That sign-in link is no longer valid.") {
  return html(troublePage(message), 400);
}

// ---------------------------------------------------------------------------
// the consent screen
// ---------------------------------------------------------------------------

function consentPage(input: {
  clientName: string;
  action: string;
  rid: string;
}): string {
  // The only thing the browser carries between the two halves of this flow is
  // the reference. Everything the code is minted from — client, redirect URI,
  // PKCE challenge, subject — is read back from the row on the server, so a
  // page in the middle has nothing worth tampering with.
  const hidden = `<input type="hidden" name="rid" value="${escapeHtml(input.rid)}">`;

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Connect Spling</title>
<style>
  :root{ --ink:#0B0A12; --paper:#F5F3EE; --purple:#5E3DCC; --muted:#4C4964; --hair:rgba(11,10,18,.14); }
  *{ box-sizing:border-box; margin:0; padding:0; }
  body{ font-family: system-ui, -apple-system, "Segoe UI", sans-serif; background:var(--paper);
        color:var(--ink); font-size:1.0625rem; line-height:1.6; padding:32px 20px; }
  main{ max-width:34rem; margin:0 auto; }
  h1{ font-size:1.6rem; line-height:1.2; margin-bottom:14px; }
  p{ margin-bottom:14px; }
  ul{ margin:0 0 20px 1.2em; }
  li{ margin-bottom:8px; }
  .who{ font-weight:700; }
  .note{ color:var(--muted); font-size:.95rem; }
  button{ font: inherit; font-weight:700; color:#fff; background:var(--purple);
          border:1px solid var(--purple); border-radius:10px; padding:15px 26px;
          width:100%; cursor:pointer; margin-bottom:12px; }
  button:hover{ background:#5235B4; }
  button.secondary{ background:transparent; color:var(--ink); border-color:var(--hair); }
  button:focus-visible{ outline:3px solid var(--ink); outline-offset:3px; }
  .card{ border:1px solid var(--hair); border-left:3px solid var(--purple);
         border-radius:10px; padding:18px 20px; margin-bottom:22px; background:#fff; }
</style>
</head>
<body>
<main>
  <h1>Connect Spling to <span class="who">${escapeHtml(input.clientName)}</span>?</h1>

  <div class="card">
    <p>If you say yes, ${escapeHtml(input.clientName)} will be able to:</p>
    <ul>
      <li>See the language you order in, and how you prefer to communicate</li>
      <li>See your allergies and dietary needs, so they can be applied for you</li>
      <li>Place orders and requests on your behalf, and read them back</li>
    </ul>
    <p class="note">It cannot see or use your card details. Spling never handles them.
    You can disconnect at any time, and take your profile with you.</p>
  </div>

  <form method="POST" action="${escapeHtml(input.action)}">
      ${hidden}
    <button type="submit" name="decision" value="allow">Yes, connect Spling</button>
    <button type="submit" name="decision" value="deny" class="secondary">No, not now</button>
  </form>
</main>
</body>
</html>`;
}

// ---------------------------------------------------------------------------
// router — returns null when the path is not an OAuth route
// ---------------------------------------------------------------------------

export async function handleOAuth(req: Request): Promise<Response | null> {
  const url = new URL(req.url);
  const path = url.pathname;
  const issuer = issuerFrom(req);

  // ---- discovery -----------------------------------------------------------
  if (path.endsWith("/.well-known/oauth-authorization-server")) {
    return json(authorizationServerMetadata(issuer));
  }
  if (path.endsWith("/.well-known/oauth-protected-resource")) {
    return json(protectedResourceMetadata(issuer));
  }

  // ---- dynamic client registration (RFC 7591) ------------------------------
  if (path.endsWith("/register") && req.method === "POST") {
    try {
      const reg = validateRegistration(await req.json().catch(() => ({})));
      const clientId = `spling_${randomToken(16)}`;
      const isPublic = (reg.token_endpoint_auth_method ?? "none") === "none";
      const secret = isPublic ? null : randomToken(32);

      await createClient({
        client_id: clientId,
        client_secret_hash: secret ? await sha256(secret) : null,
        client_name: reg.client_name ?? "Unnamed client",
        redirect_uris: reg.redirect_uris,
        grant_types: reg.grant_types ?? ["authorization_code", "refresh_token"],
        scope: reg.scope ?? "",
      });

      return json({
        client_id: clientId,
        ...(secret ? { client_secret: secret } : {}),
        client_name: reg.client_name,
        redirect_uris: reg.redirect_uris,
        grant_types: reg.grant_types,
        token_endpoint_auth_method: reg.token_endpoint_auth_method,
        scope: reg.scope,
      }, 201);
    } catch (e) {
      return oauthErrorResponse(e);
    }
  }

  // ---- authorize, first half: park the request and ask who this is ---------
  //
  // The assistant's request is validated once, here, and then written down. The
  // person is about to leave for Google or Apple, and whatever comes back must
  // be checked against what was agreed before they left — not against whatever
  // the returning browser claims.
  if (path.endsWith("/authorize") && req.method === "GET") {
    try {
      const p = url.searchParams;
      const clientId = p.get("client_id") ?? "";
      const client = await getClient(clientId);
      if (!client) throw new OAuthError("invalid_client", "Unknown client_id.");

      const redirectUri = pickRedirectUri(client.redirect_uris, p.get("redirect_uri") ?? undefined);
      const challenge = p.get("code_challenge") ?? "";
      const method = p.get("code_challenge_method") ?? "";

      if (p.get("response_type") !== "code") {
        throw new OAuthError("unsupported_response_type", "Only the authorization code flow is supported.");
      }
      if (!challenge || method !== "S256") {
        // PKCE is mandatory in OAuth 2.1, and 'plain' offers no protection.
        throw new OAuthError("invalid_request", "PKCE with code_challenge_method=S256 is required.");
      }

      const rid = randomToken(32);
      await storePending({
        rid,
        client_id: clientId,
        client_name: client.client_name,
        redirect_uri: redirectUri,
        state: p.get("state") ?? "",
        scopes: narrowScopes(p.get("scope") ?? undefined),
        code_challenge: challenge,
        // Ours, not the assistant's — held on the person's behalf while they are
        // away at the identity provider.
        provider_verifier: randomToken(48),
        ttlSeconds: PENDING_TTL_S,
      });

      return html(signInPage({ clientName: client.client_name, action: `${issuer}/signin`, rid }));
    } catch (e) {
      return oauthErrorResponse(e);
    }
  }

  // ---- sign in: hand off to Google, Apple, or the mailer -------------------
  if (path.endsWith("/signin") && req.method === "POST") {
    const p = new URLSearchParams(await req.text());
    const rid = p.get("rid") ?? "";
    const pending = await getPending(rid).catch(() => null);
    if (!pending) return trouble();

    try {
      const provider = normalizeProvider(p.get("provider"));
      const callback = callbackUrl(issuer, rid);
      const challenge = await challengeFor(pending.provider_verifier);

      if (provider === "email") {
        const email = (p.get("email") ?? "").trim();
        if (!isEmail(email)) {
          return html(signInPage({
            clientName: pending.client_name,
            action: `${issuer}/signin`,
            rid,
            error: "That does not look like an email address. Try again, or use one of the buttons above.",
          }), 400);
        }
        await sendMagicLink(email, callback, challenge);
        // Always the same page, whether or not the address is known. Anything
        // else turns this endpoint into a way to ask "does this person use
        // Spling?" — which, for this user base, is a question worth protecting.
        return html(linkSentPage());
      }

      return Response.redirect(supabaseAuthorizeUrl(provider, callback, challenge), 302);
    } catch (e) {
      return trouble(e instanceof OAuthError ? e.message : "Sign-in could not be started.");
    }
  }

  // ---- back from the identity provider: now we know who ---------------------
  if (path.endsWith("/auth/callback") && req.method === "GET") {
    const rid = url.searchParams.get("rid") ?? "";
    const pending = await getPending(rid).catch(() => null);
    if (!pending) return trouble();

    if (url.searchParams.get("error")) {
      return trouble("Sign-in was cancelled, or the provider refused it.");
    }
    const authCode = url.searchParams.get("code") ?? "";
    if (!authCode) return trouble();

    try {
      const subject = await exchangeForSubject(authCode, pending.provider_verifier);
      await attachSubject(rid, subject);
      return html(consentPage({ clientName: pending.client_name, action: `${issuer}/authorize`, rid }));
    } catch {
      return trouble("Sign-in did not complete. Nothing was connected.");
    }
  }

  // ---- authorize, second half: the person answers the consent screen -------
  if (path.endsWith("/authorize") && req.method === "POST") {
    const p = new URLSearchParams(await req.text());
    const rid = p.get("rid") ?? "";
    const pending = await getPending(rid).catch(() => null);
    if (!pending) return trouble();

    const target = new URL(pending.redirect_uri);
    if (pending.state) target.searchParams.set("state", pending.state);

    // Single use either way: answered is answered, and a reference that has
    // been spent cannot be replayed into a second code.
    await consumePending(rid);

    if (p.get("decision") !== "allow") {
      target.searchParams.set("error", "access_denied");
      return Response.redirect(target.toString(), 302);
    }
    if (!pending.subject) {
      // A consent posted without a completed sign-in. There is no one to issue
      // a code for, so there is nothing to do but stop.
      return trouble("You need to sign in before connecting.");
    }

    const code = randomToken(32);
    await storeCode({
      code,
      client_id: pending.client_id,
      subject: pending.subject,
      redirect_uri: pending.redirect_uri,
      scopes: pending.scopes,
      code_challenge: pending.code_challenge,
      ttlSeconds: CODE_TTL_S,
    });

    target.searchParams.set("code", code);
    return Response.redirect(target.toString(), 302);
  }

  // ---- token ---------------------------------------------------------------
  if (path.endsWith("/token") && req.method === "POST") {
    try {
      const p = new URLSearchParams(await req.text());
      const grantType = p.get("grant_type");
      const clientId = p.get("client_id") ?? "";
      const client = await getClient(clientId);
      if (!client) throw new OAuthError("invalid_client", "Unknown client_id.", 401);

      if (client.client_secret_hash) {
        const presented = p.get("client_secret") ?? "";
        if (!safeEqual(await sha256(presented), client.client_secret_hash)) {
          throw new OAuthError("invalid_client", "Client authentication failed.", 401);
        }
      }

      if (grantType === "authorization_code") {
        const code = p.get("code") ?? "";
        const row = await takeCode(code);
        if (!row) throw new OAuthError("invalid_grant", "That code is not valid.");

        if (row.consumed_at) {
          // A code presented twice is an attack signal, not a retry. We cannot
          // tell which presentation was genuine, and we do not know which grant
          // family the attacker holds — so every live token for that person
          // goes, and they sign in again.
          await revokeAllForSubject(row.subject);
          throw new OAuthError("invalid_grant", "That code was already used.");
        }
        if (new Date(row.expires_at).getTime() <= Date.now()) {
          throw new OAuthError("invalid_grant", "That code has expired.");
        }
        if (row.client_id !== clientId) throw new OAuthError("invalid_grant", "Code was issued to another client.");
        if (row.redirect_uri !== (p.get("redirect_uri") ?? row.redirect_uri)) {
          throw new OAuthError("invalid_grant", "redirect_uri does not match the one used to authorize.");
        }
        if (!(await verifyPkce(p.get("code_verifier") ?? "", row.code_challenge, "S256"))) {
          throw new OAuthError("invalid_grant", "PKCE verification failed.");
        }

        await markCodeConsumed(row.code_hash);

        const grantId = crypto.randomUUID();
        const access = randomToken(32);
        const refresh = randomToken(32);
        await storeToken({ token: access, kind: "access", client_id: clientId, subject: row.subject, scopes: row.scopes, grant_id: grantId, ttlSeconds: ACCESS_TTL_S });
        await storeToken({ token: refresh, kind: "refresh", client_id: clientId, subject: row.subject, scopes: row.scopes, grant_id: grantId, ttlSeconds: REFRESH_TTL_S });

        return json({
          access_token: access,
          token_type: "Bearer",
          expires_in: ACCESS_TTL_S,
          refresh_token: refresh,
          scope: row.scopes.join(" "),
        });
      }

      if (grantType === "refresh_token") {
        const presented = p.get("refresh_token") ?? "";
        const row = await findToken(presented, "refresh");
        if (!row) {
          // A refresh token that was valid and has already been spent means two
          // parties hold it, and we cannot tell which one is here. Rotation
          // alone would lock out whichever arrived second — possibly the real
          // person while a thief keeps a live family. So the family ends, and
          // the person signs in again.
          const spent = await findAnyToken(presented, "refresh");
          if (spent?.revoked_at) await revokeGrant(spent.grant_id);
          throw new OAuthError("invalid_grant", "That refresh token is not valid.");
        }
        if (row.client_id !== clientId) throw new OAuthError("invalid_grant", "Token was issued to another client.");

        // Rotation: the presented refresh token dies here, and its replacement
        // is the only live one in the family.
        await revokeToken(presented);

        const access = randomToken(32);
        const refresh = randomToken(32);
        await storeToken({ token: access, kind: "access", client_id: clientId, subject: row.subject, scopes: row.scopes, grant_id: row.grant_id, ttlSeconds: ACCESS_TTL_S });
        await storeToken({ token: refresh, kind: "refresh", client_id: clientId, subject: row.subject, scopes: row.scopes, grant_id: row.grant_id, ttlSeconds: REFRESH_TTL_S });

        return json({
          access_token: access,
          token_type: "Bearer",
          expires_in: ACCESS_TTL_S,
          refresh_token: refresh,
          scope: row.scopes.join(" "),
        });
      }

      throw new OAuthError("unsupported_grant_type", `"${grantType}" is not supported.`);
    } catch (e) {
      return oauthErrorResponse(e);
    }
  }

  // ---- revoke --------------------------------------------------------------
  if (path.endsWith("/revoke") && req.method === "POST") {
    const p = new URLSearchParams(await req.text());
    const token = p.get("token") ?? "";
    if (token) await revokeToken(token).catch(() => {});
    // RFC 7009: always 200, so a caller cannot probe which tokens exist.
    return json({});
  }

  return null;
}

/** Resolve a request's bearer to a subject, or null. */
export async function subjectFromAccessToken(req: Request): Promise<string | null> {
  const auth = req.headers.get("authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return null;
  const row = await findToken(auth.slice(7).trim(), "access").catch(() => null);
  return row?.subject ?? null;
}
