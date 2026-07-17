/** Express app factory — wires config → core → routes (+ MCP at root). */

import express, { type Express } from "express";

import { adminRouter } from "./admin.js";
import { oauthEnabled, type Config } from "./config.js";
import { Core } from "./core.js";
import { HoneybotClient } from "./honeybotClient.js";
import { mountMcp } from "./ingress/mcp.js";
import { siriRouter } from "./ingress/siri.js";
import { Registry } from "./registry.js";
import { SlackClient } from "./slackClient.js";
import { TokenStore } from "./tokenStore.js";

export function buildApp(config: Config): Express {
  const app = express();
  app.use(express.json({ limit: "1mb" }));

  const registry = new Registry();
  const tokenStore = new TokenStore(config.tokenMap, config.tokenStorePath);
  const core = new Core({
    tokens: tokenStore,
    registry,
    honeybot: new HoneybotClient(
      config.honeybotApiUrl,
      config.honeybotApiKey,
      config.honeybotModel,
      config.agentTimeoutMs,
    ),
    slack: new SlackClient(config.slackBotToken),
    config,
  });

  // Explicit routes are registered before the MCP/OAuth routes so they win.
  app.get("/healthz", (_req, res) => {
    res.json({ ok: true, oauth: oauthEnabled(config) });
  });
  app.get("/status", (_req, res) => {
    res.json({ in_flight: registry.snapshot(), active_tokens: tokenStore.count() });
  });
  app.use(adminRouter(tokenStore, config.adminKey));
  app.use(siriRouter(core));

  // MCP: /mcp + (OAuth mode) /authorize /token /register /.well-known + /oauth/callback.
  mountMcp(app, { core, tokenStore, config });

  return app;
}
