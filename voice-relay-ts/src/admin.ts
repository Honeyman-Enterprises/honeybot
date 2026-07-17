/**
 * Admin API — honeybot's voice-token skill pushes the live token map here.
 * Authenticated by a shared admin key (constant-time). Empty key ⇒ disabled
 * (404, no unauthenticated admin surface). Internal-only (nginx blocks /admin
 * publicly; the skill reaches it over honeynet).
 */

import { Router, type Request, type Response } from "express";
import type { TokenStore } from "./tokenStore.js";
import { bearer, safeEqual } from "./util.js";

export function adminRouter(store: TokenStore, adminKey: string): Router {
  const router = Router();

  const authorize = (req: Request, res: Response): boolean => {
    if (!adminKey) {
      res.status(404).json({ error: "not found" }); // disabled
      return false;
    }
    if (!safeEqual(bearer(req.headers.authorization), adminKey)) {
      res.status(401).json({ error: "unauthorized" });
      return false;
    }
    return true;
  };

  router.put("/admin/tokens", (req: Request, res: Response) => {
    if (!authorize(req, res)) return;
    const body = (req.body ?? {}) as { tokens?: unknown };
    if (!body.tokens || typeof body.tokens !== "object" || Array.isArray(body.tokens)) {
      res.status(400).json({ error: "expected { tokens: {token: uid} }" });
      return;
    }
    const active = store.replace(body.tokens as Record<string, string>);
    res.json({ active });
  });

  router.get("/admin/tokens", (req: Request, res: Response) => {
    if (!authorize(req, res)) return;
    res.json({ active: store.count(), tokens: store.masked() });
  });

  return router;
}
