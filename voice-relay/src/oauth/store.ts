/**
 * Authorization-server state.
 *   clients        DCR registrations (persisted — survive relay restart)
 *   access/refresh tokens (persisted — a connector isn't logged out by a restart)
 *   pending        in-flight /authorize keyed by our Google `state` (in-mem, short)
 *   codes          our issued auth codes (in-mem, short, one-time)
 * Persistence is a single JSON file (atomic, 0600) when a path is given.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { randomBytes } from "node:crypto";
import type { OAuthClientInformationFull } from "@modelcontextprotocol/sdk/shared/auth.js";

export interface TokenRecord {
  slackUid: string;
  email: string;
  clientId: string;
  scopes: string[];
  expiresAt: number; // epoch ms
  refreshToken?: string;
}

export interface PendingAuth {
  clientId: string;
  redirectUri: string;
  codeChallenge: string;
  clientState?: string;
  scopes: string[];
  createdAt: number;
}

export interface StoredCode {
  code: string;
  clientId: string;
  redirectUri: string;
  codeChallenge: string;
  scopes: string[];
  slackUid: string;
  email: string;
  expiresAt: number;
}

export class OAuthStore {
  private clients = new Map<string, OAuthClientInformationFull>();
  private access = new Map<string, TokenRecord>();
  private refresh = new Map<string, TokenRecord>();
  private pending = new Map<string, PendingAuth>();
  private codes = new Map<string, StoredCode>();

  constructor(private readonly path?: string) {
    this.load();
  }

  // ---- clients (persisted) ----
  getClient(clientId: string): OAuthClientInformationFull | undefined {
    return this.clients.get(clientId);
  }
  putClient(client: OAuthClientInformationFull): void {
    this.clients.set(client.client_id, client);
    this.persist();
  }

  // ---- pending authorize (in-memory) ----
  putPending(state: string, data: Omit<PendingAuth, "createdAt">): void {
    this.pending.set(state, { ...data, createdAt: Date.now() });
  }
  popPending(state: string, maxAgeMs = 600_000): PendingAuth | undefined {
    const data = this.pending.get(state);
    this.pending.delete(state);
    if (!data || Date.now() - data.createdAt > maxAgeMs) return undefined;
    return data;
  }

  // ---- authorization codes (in-memory, one-time) ----
  putCode(code: string, obj: StoredCode): void {
    this.codes.set(code, obj);
  }
  getCode(code: string): StoredCode | undefined {
    return this.codes.get(code);
  }
  popCode(code: string): void {
    this.codes.delete(code);
  }

  // ---- tokens (persisted) ----
  putAccess(token: string, rec: TokenRecord): void {
    this.access.set(token, rec);
    this.persist();
  }
  getAccess(token: string): TokenRecord | undefined {
    return this.access.get(token);
  }
  putRefresh(token: string, rec: TokenRecord): void {
    this.refresh.set(token, rec);
    this.persist();
  }
  getRefresh(token: string): TokenRecord | undefined {
    return this.refresh.get(token);
  }
  revoke(token: string): void {
    this.access.delete(token);
    this.refresh.delete(token);
    this.persist();
  }

  // ---- persistence ----
  private load(): void {
    if (!this.path || !existsSync(this.path)) return;
    try {
      const data = JSON.parse(readFileSync(this.path, "utf-8")) as {
        clients?: Record<string, OAuthClientInformationFull>;
        access?: Record<string, TokenRecord>;
        refresh?: Record<string, TokenRecord>;
      };
      for (const [id, c] of Object.entries(data.clients ?? {})) this.clients.set(id, c);
      for (const [t, r] of Object.entries(data.access ?? {})) this.access.set(t, r);
      for (const [t, r] of Object.entries(data.refresh ?? {})) this.refresh.set(t, r);
    } catch {
      /* start empty */
    }
  }

  private persist(): void {
    if (!this.path) return;
    try {
      mkdirSync(dirname(this.path), { recursive: true });
      const payload = {
        clients: Object.fromEntries(this.clients),
        access: Object.fromEntries(this.access),
        refresh: Object.fromEntries(this.refresh),
      };
      const tmp = `${this.path}.${randomBytes(6).toString("hex")}.tmp`;
      writeFileSync(tmp, JSON.stringify(payload), { mode: 0o600 });
      renameSync(tmp, this.path);
    } catch {
      /* best-effort; 1Password remains the durable client seed */
    }
  }
}
