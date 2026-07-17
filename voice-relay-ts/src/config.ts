/** Environment-driven configuration (ports/timeouts via compose, secrets via .env.runtime). */

export interface Config {
  port: number;
  fastAckMs: number;
  agentTimeoutMs: number;
  honeybotApiUrl: string;
  honeybotApiKey: string;
  honeybotModel: string;
  slackBotToken: string;
  tokenMap: Record<string, string>; // cold-start bearer token -> Slack UID
  ackMessage: string;
  tokenStorePath: string;
  adminKey: string;
  // --- MCP OAuth (self-hosted AS, Google upstream) ---
  publicUrl: string;
  oauthGoogleClientId: string;
  oauthGoogleClientSecret: string;
  oauthAllowedDomains: Set<string>;
  oauthStorePath: string;
}

/** Dormant until a Google client is configured; MCP then falls back to bearer. */
export function oauthEnabled(c: Config): boolean {
  return Boolean(c.oauthGoogleClientId && c.oauthGoogleClientSecret);
}

function num(name: string, def: number): number {
  const raw = process.env[name];
  const n = raw === undefined ? def : Number(raw);
  return Number.isFinite(n) ? n : def;
}

function str(name: string, def = ""): string {
  return process.env[name] ?? def;
}

function parseTokenMap(raw: string): Record<string, string> {
  const trimmed = (raw ?? "").trim();
  if (!trimmed) return {};
  try {
    const parsed: unknown = JSON.parse(trimmed);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      const out: Record<string, string> = {};
      for (const [k, v] of Object.entries(parsed as Record<string, unknown>)) {
        if (k && v) out[String(k).trim()] = String(v).trim();
      }
      return out;
    }
  } catch {
    /* fall through to empty (fail-closed) */
  }
  return {};
}

export function loadConfig(): Config {
  return {
    port: num("VOICE_RELAY_PORT", 8080),
    // Keep under the assistant's own patience (~5s for Siri).
    fastAckMs: Math.round(num("VOICE_FAST_ACK_SECONDS", 3.5) * 1000),
    agentTimeoutMs: Math.round(num("VOICE_AGENT_TIMEOUT_SECONDS", 300) * 1000),
    honeybotApiUrl: str("HONEYBOT_API_URL", "http://honeybot:8642/v1").replace(/\/+$/, ""),
    honeybotApiKey: str("HONEYBOT_API_KEY"),
    honeybotModel: str("HONEYBOT_MODEL", "honeybot"),
    slackBotToken: str("SLACK_BOT_TOKEN"),
    tokenMap: parseTokenMap(str("VOICE_TOKEN_MAP")),
    ackMessage: str("VOICE_ACK_MESSAGE", "On it — I'll message you in Slack when it's done."),
    tokenStorePath: str("VOICE_TOKEN_STORE_PATH", "/data/tokens.json"),
    adminKey: str("VOICE_ADMIN_KEY"),
    publicUrl: str("VOICE_PUBLIC_URL", "https://voice.honeybot.honeymanenterprises.com").replace(/\/+$/, ""),
    oauthGoogleClientId: str("VOICE_OAUTH_GOOGLE_CLIENT_ID"),
    oauthGoogleClientSecret: str("VOICE_OAUTH_GOOGLE_CLIENT_SECRET"),
    oauthAllowedDomains: new Set(
      str("VOICE_OAUTH_ALLOWED_DOMAINS", "honeymanenterprises.com")
        .split(",")
        .map((d) => d.trim().toLowerCase())
        .filter(Boolean),
    ),
    oauthStorePath: str("VOICE_OAUTH_STORE_PATH", "/data/oauth.json"),
  };
}
