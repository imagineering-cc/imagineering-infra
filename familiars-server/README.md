# familiars-server

Deployment unit for the familiars agent control surface.

- **Public URL**: `https://familiars.imagineering.cc`
- **Loopback port**: `3019`
- **Source**: `~/git/experiments/familiars`
- **Design docs**: see `ARCHITECTURE.md`, `MILESTONES.md`, `PRINCIPLES.md` in the source repo

## First deploy

```bash
# 1. Generate the OAuth token (once, on a workstation with `claude` logged in)
claude setup-token  # paste output into secrets.yaml as claude_code_oauth_token

# 2. Encrypt secrets
sops -e -i familiars-server/secrets.yaml

# 3. Deploy
./scripts/deploy-to.sh 149.118.69.221 familiars-server
```

The deploy will fail until Phase 0 is built (no `Dockerfile` or `pubspec.yaml` in the source repo yet). The infra is provisioned in advance so the route returns 502 cleanly while we wait.
