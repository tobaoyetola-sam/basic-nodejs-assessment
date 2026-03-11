# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 – deps: install ONLY production dependencies
# ─────────────────────────────────────────────────────────────────────────────
FROM node:20-alpine AS deps

WORKDIR /app

# Copy manifests first to leverage Docker layer cache
COPY package.json package-lock.json* ./

RUN npm ci --omit=dev --ignore-scripts && \
    npm cache clean --force

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 – builder: install ALL deps (including devDeps) and run tests/lint
# ─────────────────────────────────────────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci --ignore-scripts

COPY src/ ./src/
COPY tests/ ./tests/

# Run linter + tests in CI/build stage (fails the build if tests fail)
RUN npm test -- --passWithNoTests

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3 – release: lean production image
# ─────────────────────────────────────────────────────────────────────────────
FROM node:20-alpine AS release

# Security hardening
RUN apk add --no-cache dumb-init && \
    addgroup -g 1001 -S appgroup && \
    adduser  -u 1001 -S appuser -G appgroup

WORKDIR /app

# Copy production node_modules from deps stage
COPY --from=deps  --chown=appuser:appgroup /app/node_modules ./node_modules

# Copy application source
COPY --chown=appuser:appgroup src/ ./src/
COPY --chown=appuser:appgroup package.json ./

# Drop to non-root user
USER appuser

EXPOSE 3000

# Health check (Docker-native)
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

# Use dumb-init to handle PID 1 signals correctly
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/app.js"]
