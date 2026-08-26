# dep-dlm-bbmri

Docker Compose deployment package for BBMRI's on-premises DEP DLM instance — Rucio + FTS3 with LS AAI OIDC integration, for single-site, on-prem/HPC data transfer without requiring Kubernetes expertise.

Adapted from [dep-dlm-testbed](https://github.com/ri-scale/dep-dlm-testbed), the RI-SCALE validation environment for the DEP DLM architecture. See that repo for the fuller multi-environment platform (Kubernetes, GitOps, cloud); this repo is a trimmed, single-deployment subset for BBMRI specifically.

## What this deploys

- **Rucio** — data catalog and orchestration
- **FTS3** — third-party-copy transfer engine
- OIDC integration against **LS AAI** (no local IdP needed)

No cloud control plane. Everything runs via Docker Compose on your own infrastructure.

## Quick start

```bash
# Generate certs (or bring your own CA — see runbook)
make certs

# Configure LS AAI credentials
cp envs/ls-aai.env.example envs/ls-aai.env
# edit envs/ls-aai.env with your registered client ID/secret

source envs/ls-aai.env

# Substitute your credentials into idpsecrets.json
sed -i \
  -e "s|<valid client id>|$OIDC_CLIENT_ID|g" \
  -e "s|<valid client secret>|$OIDC_CLIENT_SECRET|g" \
  config/rucio/egi-dev/idpsecrets.json

# Start the stack
make start

# Rucio E2E transfer test
make test-rucio-transfers

# Rucio E2E deletion test
make test-rucio-deletion
```

See the [Runbook](docs/runbook.md) for full installation, configuration and LS AAI registration steps.

## Make targets

```bash
dep-dlm-bbmri

  DAEMON_MODE = direct (direct | daemons)

Usage:
  make <target> [DAEMON_MODE=direct|daemons] [SERVICES="svc1 svc2"]

  help                 Show this help

Setup
  certs                Generate CA and host certificates
  init                 Init testbed accounts, RSEs, OIDC seed

IdP token verification
  verify-idp-token     Verify OIDC token flow against LS AAI. Needs OIDC_CLIENT_SECRET.

Lifecycle
  start                Start the stack
  stop                 Stop the stack, remove volumes
  restart              Tear down and start again
  ps                   Show running services
  logs                 Tail logs (SERVICES="..." for a subset)

Tests / Demo
  test-rucio-transfers Rucio E2E transfer test
  test-rucio-deletion  Rucio E2E deletion test
  probe-teapot         Teapot WebDAV probe with OIDC tokens
  probe-xrootd         XRootD probe with SciTokens

Cleanup
  clear-artifacts      Remove certs, volumes, Python artifacts
  cleanup              Delete rules/replicas/distances (and RSEs unless KEEP_RSES=1) created by init/tests
```

## Support

For issues specific to this deployment, open an issue in this repository. For questions about the broader DEP DLM platform, see [dep-dlm-testbed](https://github.com/ri-scale/dep-dlm-testbed).
