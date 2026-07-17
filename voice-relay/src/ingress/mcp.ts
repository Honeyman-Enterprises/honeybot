/**
 * MCP ingress — Claude/ChatGPT voice, on the Streamable-HTTP transport.
 *
 * Unified auth: /mcp is always protected by requireBearerAuth with a verifier.
 *   - OAuth mode (Google client configured): verifier = the OAuth provider;
 *     mcpAuthRouter adds /authorize /token /register /.well-known at root and
 *     we add the /oauth/callback route. Identity = the validated token.
 *   - Static-bearer mode: verifier resolves the voice token via the TokenStore.
 * Either way the tool reads slackUid from extra.authInfo.extra, so the tool
 * logic is identical.
 */

import { randomUUID } from "node:crypto";
import type { Express, Request, Response } from "express";
import { z } from "zod";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { isInitializeRequest } from "@modelcontextprotocol/sdk/types.js";
import { requireBearerAuth } from "@modelcontextprotocol/sdk/server/auth/middleware/bearerAuth.js";
import { mcpAuthRouter } from "@modelcontextprotocol/sdk/server/auth/router.js";
import { InvalidTokenError } from "@modelcontextprotocol/sdk/server/auth/errors.js";
import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js";
import type { OAuthTokenVerifier } from "@modelcontextprotocol/sdk/server/auth/provider.js";

import { oauthEnabled, type Config } from "../config.js";
import type { Core } from "../core.js";
import { ForbiddenError, HoneybotOAuthProvider } from "../oauth/provider.js";
import { OAuthStore } from "../oauth/store.js";
import { slackUidResolver } from "../slackClient.js";
import type { TokenStore } from "../tokenStore.js";

export function mountMcp(app: Express, deps: { core: Core; tokenStore: TokenStore; config: Config }): void {
  const { core, tokenStore, config } = deps;

  const verifier = oauthEnabled(config)
    ? mountOAuth(app, config)
    : bearerVerifier(tokenStore);

  const auth = requireBearerAuth({ verifier });
  const transports: Record<string, StreamableHTTPServerTransport> = {};

  app.post("/mcp", auth, async (req: Request, res: Response) => {
    const sid = req.headers["mcp-session-id"] as string | undefined;
    let transport = sid ? transports[sid] : undefined;
    if (!transport) {
      if (sid || !isInitializeRequest(req.body)) {
        res
          .status(400)
          .json({ jsonrpc: "2.0", error: { code: -32000, message: "No valid session" }, id: null });
        return;
      }
      transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: () => randomUUID(),
        onsessioninitialized: (id: string) => {
          transports[id] = transport!;
        },
      });
      transport.onclose = () => {
        if (transport!.sessionId) delete transports[transport!.sessionId];
      };
      await buildMcpServer(core).connect(transport);
    }
    await transport.handleRequest(req, res, req.body);
  });

  const sessionRequest = async (req: Request, res: Response): Promise<void> => {
    const sid = req.headers["mcp-session-id"] as string | undefined;
    const transport = sid ? transports[sid] : undefined;
    if (!transport) {
      res.status(400).send("No valid session");
      return;
    }
    await transport.handleRequest(req, res);
  };
  app.get("/mcp", auth, sessionRequest);
  app.delete("/mcp", auth, sessionRequest);
}

function mountOAuth(app: Express, config: Config): OAuthTokenVerifier {
  const provider = new HoneybotOAuthProvider({
    publicUrl: config.publicUrl,
    googleClientId: config.oauthGoogleClientId,
    googleClientSecret: config.oauthGoogleClientSecret,
    allowedDomains: config.oauthAllowedDomains,
    resolveUid: slackUidResolver(config.slackBotToken),
    store: new OAuthStore(config.oauthStorePath),
  });

  app.use(mcpAuthRouter({ provider, issuerUrl: new URL(config.publicUrl) }));

  app.get("/oauth/callback", async (req: Request, res: Response) => {
    const code = String(req.query["code"] ?? "");
    const state = String(req.query["state"] ?? "");
    const err = String(req.query["error"] ?? "");
    if (err || !code || !state) {
      res.status(400).type("text/plain").send(`Sign-in failed: ${err || "missing code/state"}`);
      return;
    }
    try {
      res.redirect(await provider.completeGoogleCallback(code, state));
    } catch (e) {
      if (e instanceof ForbiddenError) {
        res.status(403).type("text/plain").send("Sign-in denied: your Google account isn't allowed here.");
        return;
      }
      res.status(400).type("text/plain").send("Sign-in error.");
    }
  });

  console.log("MCP: OAuth mode (Google upstream)");
  return provider;
}

function bearerVerifier(tokenStore: TokenStore): OAuthTokenVerifier {
  console.log("MCP: static-bearer mode");
  return {
    async verifyAccessToken(token: string): Promise<AuthInfo> {
      try {
        const slackUid = tokenStore.resolve(token);
        return { token, clientId: "voice-token", scopes: [], extra: { slackUid } };
      } catch {
        throw new InvalidTokenError("unknown voice token");
      }
    },
  };
}

function buildMcpServer(core: Core): McpServer {
  const server = new McpServer({ name: "honeybot", version: "0.1.0" });
  server.registerTool(
    "ask_honeybot",
    {
      description:
        "Send a command to honeybot and get its response. Fast answers come " +
        "back inline; slower ones are acknowledged and followed up in your Slack DM.",
      inputSchema: { command: z.string() },
    },
    async ({ command }, extra) => {
      const slackUid = (extra.authInfo?.extra?.["slackUid"] as string | undefined) ?? "";
      if (!slackUid) {
        return { content: [{ type: "text" as const, text: "Your session isn't identity-verified. Sign in again." }] };
      }
      const reply = await core.handle({
        text: (command ?? "").trim(),
        token: "",
        slackUid,
        client: "mcp",
        requestId: `mcp-${randomUUID().slice(0, 12)}`,
      });
      return { content: [{ type: "text" as const, text: reply.speech }] };
    },
  );
  return server;
}
