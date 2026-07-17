# syntax=docker/dockerfile:1.7
#
# voice-relay (TypeScript). Multi-stage: the build stage runs `tsc` (strict),
# so a type error fails the image build — the compile-time gate that motivated
# the port from Python. The runtime stage ships only dist/ + prod deps.
#
# Runs as the stock `node` user (uid 1000). /data is the persisted store
# volume (voice tokens + oauth state); pre-created + chowned so a fresh named
# volume inherits node's ownership.

FROM node:22-slim AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
COPY test ./test
# tsc (strict) is the type gate; the tests run the race/registry logic. A
# failure in either fails the image build — the container IS the CI.
RUN npm run build && npm test

FROM node:22-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /app/dist ./dist
RUN mkdir -p /data && chown -R node:node /app /data
USER node
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8080/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/index.js"]
