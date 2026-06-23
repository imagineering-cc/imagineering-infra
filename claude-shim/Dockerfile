# claude-shim — Max-plan headless Claude Code behind a tiny HTTP endpoint.
# Mirrors the claudius container's claude-install + non-root pattern, minus the
# email/Playwright machinery — this image only needs the `claude` CLI and Node.

FROM node:20-slim

# git + ca-certificates: claude's npm install and runtime expect them present.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI globally.
RUN npm install -g @anthropic-ai/claude-code

# Run as a dedicated non-root user (defense-in-depth — the server only ever
# spawns `claude -p` for text, never with tool permissions, but least-privilege
# is cheap insurance for a network-reachable process).
RUN useradd -m -s /bin/bash shim \
    && mkdir -p /home/shim/.claude \
    && chown -R shim:shim /home/shim

WORKDIR /app
COPY src/package.json ./
COPY src/server.js ./
RUN chown -R shim:shim /app

USER shim

# CLAUDE_CODE_OAUTH_TOKEN is supplied at runtime via the compose environment
# block (generated from the SOPS-encrypted secrets.yaml at deploy time).
EXPOSE 8088
CMD ["node", "server.js"]
