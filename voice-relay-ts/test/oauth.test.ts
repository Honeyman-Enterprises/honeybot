import assert from "node:assert/strict";
import { test } from "node:test";
import type { Response } from "express";
import type { OAuthClientInformationFull } from "@modelcontextprotocol/sdk/shared/auth.js";
import type { AuthorizationParams } from "@modelcontextprotocol/sdk/server/auth/provider.js";

import { ForbiddenError, HoneybotOAuthProvider } from "../src/oauth/provider.js";
import { OAuthStore } from "../src/oauth/store.js";

const CLIENT_REDIRECT = "https://claude.ai/api/mcp/auth_callback";
const ERIC = "U09NS7DSK8U";

function client(id = "mcp-client-1"): OAuthClientInformationFull {
  return { client_id: id, redirect_uris: [CLIENT_REDIRECT] } as OAuthClientInformationFull;
}

function provider(over?: {
  uidMap?: Record<string, string>;
  email?: string;
  store?: OAuthStore;
}): HoneybotOAuthProvider {
  const uidMap = over?.uidMap ?? { "eric@honeymanenterprises.com": ERIC };
  return new HoneybotOAuthProvider({
    publicUrl: "https://voice.example",
    googleClientId: "gid",
    googleClientSecret: "gsecret",
    allowedDomains: new Set(["honeymanenterprises.com"]),
    resolveUid: async (e) => uidMap[e.toLowerCase()] ?? "",
    store: over?.store ?? new OAuthStore(),
    exchangeEmail: async () => over?.email ?? "eric@honeymanenterprises.com",
  });
}

function params(): AuthorizationParams {
  return { state: "client-state-xyz", scopes: [], codeChallenge: "chal123", redirectUri: CLIENT_REDIRECT };
}

function fakeRes(): Response & { url?: string } {
  const r = { redirect(u: string) { (r as { url?: string }).url = u; } };
  return r as unknown as Response & { url?: string };
}

async function authorizeAndCallback(p: HoneybotOAuthProvider): Promise<string> {
  const res = fakeRes();
  await p.authorize(client(), params(), res);
  assert.ok(res.url && res.url.startsWith("https://accounts.google.com/"), res.url);
  const state = new URL(res.url).searchParams.get("state");
  assert.ok(state);
  return p.completeGoogleCallback("google-code", state);
}

function codeFrom(redirect: string): string {
  const c = new URL(redirect).searchParams.get("code");
  assert.ok(c);
  return c;
}

test("full happy path: authorize -> callback -> code -> token -> verify (uid carried)", async () => {
  const p = provider();
  const redirect = await authorizeAndCallback(p);
  assert.ok(redirect.startsWith(CLIENT_REDIRECT), redirect);
  assert.ok(redirect.includes("state=client-state-xyz"), redirect);
  const code = codeFrom(redirect);
  assert.equal(await p.challengeForAuthorizationCode(client(), code), "chal123");
  const tokens = await p.exchangeAuthorizationCode(client(), code);
  assert.ok(tokens.access_token && tokens.refresh_token);
  await assert.rejects(() => p.challengeForAuthorizationCode(client(), code)); // one-time
  const info = await p.verifyAccessToken(tokens.access_token);
  assert.equal(info.extra?.["slackUid"], ERIC);
});

test("callback rejects a disallowed domain", async () => {
  const p = provider({ uidMap: { "x@evil.com": "UEVIL" }, email: "x@evil.com" });
  await assert.rejects(() => authorizeAndCallback(p), (e) => e instanceof ForbiddenError);
});

test("callback rejects an email with no Slack user", async () => {
  const p = provider({ uidMap: {}, email: "ghost@honeymanenterprises.com" });
  await assert.rejects(() => authorizeAndCallback(p), (e) => e instanceof ForbiddenError);
});

test("callback rejects an unknown/forged state", async () => {
  const p = provider();
  await assert.rejects(() => p.completeGoogleCallback("code", "forged-state"));
});

test("a different client cannot use another's code", async () => {
  const p = provider();
  const code = codeFrom(await authorizeAndCallback(p));
  await assert.rejects(() => p.challengeForAuthorizationCode(client("attacker"), code));
});

test("refresh rotates (old refresh token revoked)", async () => {
  const p = provider();
  const code = codeFrom(await authorizeAndCallback(p));
  const t1 = await p.exchangeAuthorizationCode(client(), code);
  const t2 = await p.exchangeRefreshToken(client(), t1.refresh_token!, []);
  assert.notEqual(t2.access_token, t1.access_token);
  await assert.rejects(() => p.exchangeRefreshToken(client(), t1.refresh_token!, []));
});

test("verifyAccessToken rejects an unknown token", async () => {
  const p = provider();
  await assert.rejects(() => p.verifyAccessToken("nope"));
});
