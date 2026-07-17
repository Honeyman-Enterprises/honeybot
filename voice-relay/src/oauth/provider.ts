/**
 * OAuthServerProvider — the authorization server, Google upstream.
 *
 * Ported from the security-reviewed Python provider, adapted to the TS SDK
 * interface (verified against @modelcontextprotocol/sdk@1.x):
 *   - authorize(client, params, res) writes the redirect to Google onto res;
 *   - the SDK verifies PKCE via challengeForAuthorizationCode();
 *   - verifyAccessToken() returns AuthInfo with extra.slackUid, which the
 *     tool reads.
 *
 * Safety (see docs/voice-relay-oauth.md): identity comes only from Google's
 * verified email → Slack UID, gated by allowed domain + Slack membership;
 * codes are one-time + client-bound; refresh rotates; the SDK owns PKCE +
 * redirect_uri validation. The Google callback route calls
 * completeGoogleCallback() (not part of the SDK interface).
 */

import { randomBytes } from "node:crypto";
import type { Response } from "express";
import type {
  AuthorizationParams,
  OAuthServerProvider,
} from "@modelcontextprotocol/sdk/server/auth/provider.js";
import type { OAuthRegisteredClientsStore } from "@modelcontextprotocol/sdk/server/auth/clients.js";
import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js";
import { InvalidTokenError } from "@modelcontextprotocol/sdk/server/auth/errors.js";
import type {
  OAuthClientInformationFull,
  OAuthTokenRevocationRequest,
  OAuthTokens,
} from "@modelcontextprotocol/sdk/shared/auth.js";

import { exchangeCodeForEmail, googleAuthUrl } from "./google.js";
import { OAuthStore } from "./store.js";

const ACCESS_TTL_MS = 3_600_000; // 1h
const REFRESH_TTL_MS = 30 * 24 * 3_600_000; // 30d
const CODE_TTL_MS = 300_000; // 5m

/** Domain/membership denial — the callback route maps this to 403. */
export class ForbiddenError extends Error {}

export type ExchangeEmail = (opts: {
  code: string;
  clientId: string;
  clientSecret: string;
  redirectUri: string;
}) => Promise<string>;

export interface ProviderOptions {
  publicUrl: string;
  googleClientId: string;
  googleClientSecret: string;
  allowedDomains: Set<string>;
  resolveUid: (email: string) => Promise<string>;
  store: OAuthStore;
  /** Injectable Google exchange (defaults to the real one; tests supply a fake). */
  exchangeEmail?: ExchangeEmail;
}

export class HoneybotOAuthProvider implements OAuthServerProvider {
  private readonly googleRedirect: string;
  private readonly exchangeEmail: ExchangeEmail;

  constructor(private readonly opts: ProviderOptions) {
    this.googleRedirect = `${opts.publicUrl.replace(/\/+$/, "")}/oauth/callback`;
    this.exchangeEmail = opts.exchangeEmail ?? exchangeCodeForEmail;
  }

  get clientsStore(): OAuthRegisteredClientsStore {
    const store = this.opts.store;
    return {
      getClient(clientId: string): OAuthClientInformationFull | undefined {
        return store.getClient(clientId);
      },
      registerClient(client: OAuthClientInformationFull): OAuthClientInformationFull {
        store.putClient(client);
        return client;
      },
    };
  }

  async authorize(
    client: OAuthClientInformationFull,
    params: AuthorizationParams,
    res: Response,
  ): Promise<void> {
    // The SDK already validated params.redirectUri against the client's
    // registered redirect_uris. Stash under our single-use state, go to Google.
    const state = token(24);
    this.opts.store.putPending(state, {
      clientId: client.client_id,
      redirectUri: params.redirectUri,
      codeChallenge: params.codeChallenge,
      clientState: params.state ?? "",
      scopes: params.scopes ?? [],
    });
    res.redirect(
      googleAuthUrl({
        clientId: this.opts.googleClientId,
        redirectUri: this.googleRedirect,
        state,
      }),
    );
  }

  /** Google's redirect handler (custom route). Returns the client redirect URL. */
  async completeGoogleCallback(code: string, state: string): Promise<string> {
    const pending = this.opts.store.popPending(state);
    if (!pending) throw new Error("unknown or expired authorization state");

    const email = await this.exchangeEmail({
      code,
      clientId: this.opts.googleClientId,
      clientSecret: this.opts.googleClientSecret,
      redirectUri: this.googleRedirect,
    });
    const domain = email.split("@").pop() ?? "";
    if (!this.opts.allowedDomains.has(domain)) {
      throw new ForbiddenError(`email domain not allowed: ${email}`);
    }
    const uid = await this.opts.resolveUid(email);
    if (!uid) throw new ForbiddenError(`no Slack user for ${email}`);

    const ourCode = token(24);
    this.opts.store.putCode(ourCode, {
      code: ourCode,
      clientId: pending.clientId,
      redirectUri: pending.redirectUri,
      codeChallenge: pending.codeChallenge,
      scopes: pending.scopes,
      slackUid: uid,
      email,
      expiresAt: Date.now() + CODE_TTL_MS,
    });
    return redirectWithCode(pending.redirectUri, ourCode, pending.clientState);
  }

  async challengeForAuthorizationCode(
    client: OAuthClientInformationFull,
    authorizationCode: string,
  ): Promise<string> {
    const c = this.opts.store.getCode(authorizationCode);
    if (!c || c.clientId !== client.client_id || c.expiresAt < Date.now()) {
      throw new Error("invalid authorization code");
    }
    return c.codeChallenge;
  }

  async exchangeAuthorizationCode(
    client: OAuthClientInformationFull,
    authorizationCode: string,
  ): Promise<OAuthTokens> {
    // PKCE + redirect_uri already validated by the SDK. One-time use.
    const c = this.opts.store.getCode(authorizationCode);
    if (!c || c.clientId !== client.client_id || c.expiresAt < Date.now()) {
      throw new Error("invalid authorization code");
    }
    this.opts.store.popCode(authorizationCode);
    return this.issue(client.client_id, c.scopes, c.slackUid, c.email);
  }

  async exchangeRefreshToken(
    client: OAuthClientInformationFull,
    refreshToken: string,
    scopes?: string[],
  ): Promise<OAuthTokens> {
    const rec = this.opts.store.getRefresh(refreshToken);
    if (!rec || rec.clientId !== client.client_id) {
      throw new Error("unknown refresh token");
    }
    this.opts.store.revoke(refreshToken); // rotate
    return this.issue(client.client_id, scopes?.length ? scopes : rec.scopes, rec.slackUid, rec.email);
  }

  async verifyAccessToken(accessToken: string): Promise<AuthInfo> {
    const rec = this.opts.store.getAccess(accessToken);
    if (!rec || (rec.expiresAt && rec.expiresAt < Date.now())) {
      throw new InvalidTokenError("invalid or expired token");
    }
    return {
      token: accessToken,
      clientId: rec.clientId,
      scopes: rec.scopes,
      expiresAt: Math.floor(rec.expiresAt / 1000),
      extra: { slackUid: rec.slackUid, email: rec.email },
    };
  }

  async revokeToken(
    _client: OAuthClientInformationFull,
    request: OAuthTokenRevocationRequest,
  ): Promise<void> {
    this.opts.store.revoke(request.token);
  }

  private issue(clientId: string, scopes: string[], slackUid: string, email: string): OAuthTokens {
    const access = token(32);
    const refresh = token(32);
    const now = Date.now();
    this.opts.store.putAccess(access, {
      slackUid,
      email,
      clientId,
      scopes,
      expiresAt: now + ACCESS_TTL_MS,
      refreshToken: refresh,
    });
    this.opts.store.putRefresh(refresh, {
      slackUid,
      email,
      clientId,
      scopes,
      expiresAt: now + REFRESH_TTL_MS,
    });
    return {
      access_token: access,
      token_type: "Bearer",
      expires_in: Math.floor(ACCESS_TTL_MS / 1000),
      scope: scopes.length ? scopes.join(" ") : undefined,
      refresh_token: refresh,
    };
  }
}

function token(bytes: number): string {
  return randomBytes(bytes).toString("base64url");
}

function redirectWithCode(redirectUri: string, code: string, clientState?: string): string {
  const sep = redirectUri.includes("?") ? "&" : "?";
  const q = new URLSearchParams({ code });
  if (clientState) q.set("state", clientState);
  return `${redirectUri}${sep}${q.toString()}`;
}
