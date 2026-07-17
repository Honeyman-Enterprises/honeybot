/** Siri ingress — POST /v1/voice/ask (also serves any HTTP-only client). */

import { Router, type Request, type Response } from "express";
import type { Core } from "../core.js";
import { UnknownToken } from "../tokenStore.js";
import { bearer, randomId } from "../util.js";

export function siriRouter(core: Core): Router {
  const router = Router();

  router.post("/v1/voice/ask", async (req: Request, res: Response) => {
    const body = (req.body ?? {}) as { text?: unknown; request_id?: unknown };
    const text = typeof body.text === "string" ? body.text.trim() : "";
    if (!text) {
      res.status(400).json({ error: "missing 'text'" });
      return;
    }
    const requestId =
      typeof body.request_id === "string" && body.request_id.trim()
        ? body.request_id.trim()
        : `siri-${randomId()}`;

    try {
      const reply = await core.handle({
        text,
        token: bearer(req.headers.authorization),
        slackUid: "",
        client: "siri",
        requestId,
      });
      res.json({ speech: reply.speech, status: reply.status, request_id: reply.requestId });
    } catch (err) {
      if (err instanceof UnknownToken) {
        res.status(401).json({ error: "unauthorized" });
        return;
      }
      throw err;
    }
  });

  return router;
}
