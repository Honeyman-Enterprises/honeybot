/** Entry point. */

import { loadConfig, oauthEnabled } from "./config.js";
import { buildApp } from "./server.js";

const config = loadConfig();
const app = buildApp(config);

app.listen(config.port, () => {
  console.log(
    `voice-relay listening on :${config.port} ` +
      `(oauth=${oauthEnabled(config) ? "on" : "off"}, ` +
      `tokens=${Object.keys(config.tokenMap).length}, upstream=${config.honeybotApiUrl})`,
  );
});
