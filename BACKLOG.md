# Backlog

Open points for the BBMRI deployment, tracked here rather than only in
status reports. Not yet prioritized/scheduled unless noted.

## Reverse proxy / TLS

Everything currently runs plain HTTP internally (self-signed certs only
on storage endpoints). Needs a reverse proxy in front exposing a clean
HTTPS interface, plus a decision on the PKI approach for certificate
retrieval — private PKI vs. another option — not yet decided.

## Observability

No monitoring/logging stack defined yet for this deployment.

## Authorization

Open — needs definition beyond the current OIDC authentication flow.

## HPC destination validation

`docs/known-destination-rses.md`'s MUSICA/TUBITAK configs are prepared
but not yet validated against the real HPC storage endpoints — only
against the local xrootd/teapot test containers. Need to loop in Andrea
(configured XRootD/Teapot on those HPC destinations) to check whether
further config adjustments are needed for the LS AAI federation hub.

## Deployment topology

Docs currently assume single-node (everything — rucio-server, fts,
daemons, DBs — on one host; see `docs/deployment-view.md`). Need to
confirm with BBMRI whether they plan single-node or multi-node, and if
multi-node, what changes (inter-container network references, cert
SANs, etc.).
