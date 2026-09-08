# The research dashboard (KanKyouKen/frontend), built and run on the VM.
#
# Why this exists rather than a static bundle in www/:
# the app is not exportable. It uses server actions (register, projects,
# studies, invites, consent), @supabase/ssr with cookie-backed sessions, and
# proxy.ts — Next 16's renamed middleware — to refresh those sessions on every
# request. `output: "export"` fails on any one of those. So unlike the two
# participant clients, this one needs a Node process.
#
# Built HERE, on the VM, and not on the laptop: node_modules carries platform
# native binaries (SWC, and the same rollup problem that stops the Vite clients
# building under WSL). Building inside a linux/amd64 image sidesteps the whole
# question. The source arrives via scripts/push.sh, without node_modules.
#
# The box has 3.8 GB of RAM and 2 GB of swap, with Postgres and four other
# containers already resident. --max-old-space-size is set below to keep the
# build inside that budget rather than discovering the limit through the OOM
# killer picking off a database.

# syntax=docker/dockerfile:1

# --- dependencies ------------------------------------------------------------
FROM node:22-alpine AS deps
WORKDIR /app
# Only the manifests, so this layer is reused whenever dependencies are unchanged
# — which is most pushes, and it is by far the slowest step.
COPY package.json package-lock.json ./
RUN npm ci

# --- build -------------------------------------------------------------------
FROM node:22-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# NEXT_PUBLIC_* are inlined into the client bundle at build time, so they have to
# be build args, not runtime env. The anon key belongs in a public bundle — that
# is what it is for; RLS is the control. SUPABASE_SERVICE_ROLE_KEY is NOT here:
# it is server-only and arrives as runtime env in the runner stage.
ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY
ARG NEXT_PUBLIC_BASE_PATH
ARG NEXT_PUBLIC_APP_URL
ARG NEXT_OUTPUT

ENV NEXT_PUBLIC_SUPABASE_URL=$NEXT_PUBLIC_SUPABASE_URL \
    NEXT_PUBLIC_SUPABASE_ANON_KEY=$NEXT_PUBLIC_SUPABASE_ANON_KEY \
    NEXT_PUBLIC_BASE_PATH=$NEXT_PUBLIC_BASE_PATH \
    NEXT_PUBLIC_APP_URL=$NEXT_PUBLIC_APP_URL \
    NEXT_OUTPUT=$NEXT_OUTPUT \
    NEXT_TELEMETRY_DISABLED=1 \
    NODE_OPTIONS=--max-old-space-size=2048

RUN npm run build

# --- runtime -----------------------------------------------------------------
# `output: "standalone"` emits a pruned server plus only the node_modules it
# actually reaches, so the runtime image carries no build toolchain and no dev
# dependencies. That matters here for more than size: this container holds
# SUPABASE_SERVICE_ROLE_KEY, so its attack surface is worth keeping small.
FROM node:22-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

RUN addgroup -g 1001 -S nodejs && adduser -S nextjs -u 1001

COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs
EXPOSE 3000

# No published port in docker-compose.yml. Caddy reaches this over the internal
# network, exactly as it reaches Kong — Sven's allocation is 80 and 443 only.
CMD ["node", "server.js"]
