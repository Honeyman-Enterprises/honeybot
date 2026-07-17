/**
 * Bearer voice-token store (static-bearer MCP + Siri path).
 *
 * Source of truth is 1Password; the relay learns the map two ways: the
 * VOICE_TOKEN_MAP env seed (cold start) and honeybot's voice-token skill
 * PUTting the full map to /admin/tokens (live, persisted to a volume file so
 * a fresh token survives a restart). resolve() is fail-closed.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { randomBytes } from "node:crypto";

export class UnknownToken extends Error {
  constructor(message = "unrecognized voice token") {
    super(message);
    this.name = "UnknownToken";
  }
}

export class TokenStore {
  private map: Record<string, string>;

  constructor(
    private readonly envMap: Record<string, string>,
    private readonly storePath?: string,
  ) {
    this.map = this.load();
  }

  private load(): Record<string, string> {
    if (this.storePath && existsSync(this.storePath)) {
      try {
        const data: unknown = JSON.parse(readFileSync(this.storePath, "utf-8"));
        if (data && typeof data === "object" && !Array.isArray(data)) {
          const out: Record<string, string> = {};
          for (const [k, v] of Object.entries(data as Record<string, unknown>)) {
            out[String(k)] = String(v);
          }
          return out;
        }
      } catch {
        /* fall through to the env seed */
      }
    }
    return { ...this.envMap };
  }

  /** 'no token' and 'wrong token' both throw — indistinguishable to callers. */
  resolve(token: string): string {
    const uid = this.map[(token ?? "").trim()];
    if (!uid) throw new UnknownToken();
    return uid;
  }

  /** Replace the whole map (admin push) and persist. Returns active count. */
  replace(newMap: Record<string, string>): number {
    const clean: Record<string, string> = {};
    for (const [k, v] of Object.entries(newMap)) {
      const key = String(k).trim();
      const val = String(v).trim();
      if (key && val) clean[key] = val;
    }
    this.map = clean;
    this.persist(clean);
    return Object.keys(clean).length;
  }

  private persist(data: Record<string, string>): void {
    if (!this.storePath) return;
    try {
      mkdirSync(dirname(this.storePath), { recursive: true });
      const tmp = `${this.storePath}.${randomBytes(6).toString("hex")}.tmp`;
      writeFileSync(tmp, JSON.stringify(data), { mode: 0o600 });
      renameSync(tmp, this.storePath);
    } catch {
      /* best-effort; op:// remains the durable truth */
    }
  }

  count(): number {
    return Object.keys(this.map).length;
  }

  masked(): Record<string, string> {
    const out: Record<string, string> = {};
    for (const [tok, uid] of Object.entries(this.map)) {
      out[tok.length <= 8 ? "****" : `${tok.slice(0, 4)}…${tok.slice(-4)}`] = uid;
    }
    return out;
  }
}
