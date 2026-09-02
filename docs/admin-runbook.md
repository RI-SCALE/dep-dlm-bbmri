# dep-dlm-bbmri — Admin Runbook

For: standing up the stack and provisioning Rucio for BBMRI users.
User-facing counterpart: [user-runbook.md](user-runbook.md).

## You need
- Docker Engine + Compose plugin, `make`, `bash`, `openssl`, `curl`.
- Outbound HTTPS to `login.aai.lifescience-ri.eu`.
- Federation Registry access (or `support@aai.lifescience-ri.eu`) to register the LS AAI client — approval by LS AAI required, do this first, it blocks everything else.
- Later: the **user's own LS AAI `sub`** (step 6) — you can't finish identity mapping without it.

## 1. Register the LS AAI OIDC client
Request via Federation Registry (https://services.aai.lifescience-ri.eu/spreg/) or support@aai.lifescience-ri.eu.

Grant types: `client_credentials` (required) + `authorization_code` (interactive login) + `token-exchange` (required — this deployment's `rucio.cfg` pins `token_strategy = exchange`, there's no unmanaged alternative to fall back to).

Register a **Resource Indicator (RFC 8707)** for every RSE/service — requests fail without these:
```
https://xrd3.example.org/
https://xrd4.example.org/
https://teapot1.example.org/
https://teapot2.example.org/
https://fts.example.org/
```
Scope set is fixed by LS AAI (`openid profile email offline_access eduperson_entitlement`) — already handled by `idpsecrets.json`'s capabilities block. Enable "Issue refresh tokens" — required for token-exchange, which this deployment always uses.

## 2. Certs
```
make certs
```
LS AAI is system-CA-trusted, no bundle needed. `rucio_ca.pem` still covers this stack's own self-signed storage endpoints.

## 3. Wire in credentials
```bash
cp envs/ls-aai.env.example envs/ls-aai.env   # fill in client ID/secret
source envs/ls-aai.env

cp configs/rucio/idpsecrets.json.example configs/rucio/idpsecrets.json
sed -i \
  -e "s|<valid client id>|${OIDC_CLIENT_ID}|g" \
  -e "s|<valid client secret>|${OIDC_CLIENT_SECRET}|g" \
  configs/rucio/idpsecrets.json
```
Substitute on the host shell, not inside a quoted `docker exec ... bash -c "..."` string — the container sees empty vars otherwise. Never commit the substituted file: `git checkout -- configs/rucio/idpsecrets.json` when done.

## 4. Start the stack
```
make start
make ps   # everything up?
```

## 5. Initialize (accounts, RSEs, quotas)
```bash
source envs/ls-aai.env
make init
```
This deployment always runs **FTS managed token mode** (token-exchange) — `rucio.cfg` pins `token_strategy = exchange`, there's no `TOKEN_MODE` flag or unmanaged fallback in this repo. Provisioning always includes the subject-token seeding step below.

`make init` provisions the test fixtures:
- accounts `ddmlab` (service), `randomaccount`
- RSEs `XRD3`/`XRD4` (SciTokens) and `TEAPOT1`/`TEAPOT2` (WebDAV bearer)
- distances between them, quotas, and token-exchange seeding

`make init` runs `init-testbed.sh`, which waits for Rucio/FTS, then does the above. If you need to run or re-run a piece by hand — e.g. registering your own storage, or debugging a step — here's the manual equivalent per phase. Treat `init-testbed.sh` as the reference implementation to copy and adapt, not as fixed to XRD3/Teapot.

**Admin auth for these commands**

Prefer the LS AAI client's own OIDC identity over a shared userpass credential — you already mint this token for subject-token seeding below, so there's no new credential to manage, it rotates with the client secret instead of separately, and it's non-interactive (`client_credentials`, no browser step):
```bash
tok=$(curl -s -u "${OIDC_CLIENT_ID}:${OIDC_CLIENT_SECRET}" \
  -d 'grant_type=client_credentials' -d "scope=${OIDC_EXPECTED_SCOPE:-openid}" \
  "${OIDC_TOKEN_URL}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

ra() { docker exec -e RUCIO_AUTH_TOKEN="$tok" compose-rucio-server-1 rucio-admin "$@"; }
```
Tokens are short-lived — re-run the `tok=...` line if `ra` starts failing auth partway through a long provisioning session.

`init-testbed.sh` itself still uses a userpass identity (`rucio-admin -S userpass -u <service_account> --password secret`) for its own automated fixture setup and pytest fixtures — that's a reasonable CI/bootstrap fallback where a stable, non-interactive credential independent of OIDC token lifetimes is genuinely useful, but it shouldn't be the account a human admin reaches for by default, and the password shouldn't be hardcoded if you keep it (pull from a secret store).

**Accounts**
```bash
ra account add --type SERVICE --email <service-account>@rucio <service-account>
ra account add --type USER --email <user-account>@rucio <user-account>
```
The test fixtures use `ddmlab` (service) and `randomaccount` (user) — same shape for any names you pick. Password-grant/userpass identity registration is skipped for the OIDC-driven account (this deployment uses `client_credentials`) — its OIDC identity comes from subject-token seeding below; individual users' identities are mapped separately, per user, in [§6](#6-map-the-users-identity).

**RSEs — registering real storage, not just the test fixtures**

`init-testbed.sh`'s `configure_rses()` only wires up the built-in XRD3/XRD4/TEAPOT1/TEAPOT2 test containers. For an actual BBMRI deployment you'll register your own endpoints instead — typically:
- a **source RSE** on your own on-premises infra (decoupled from this compose stack — reachable over the network, not a sibling container), and
- a **destination RSE** on the target HPC storage (e.g. TUBITAK's WebDAV endpoint, or MUSICA), which the on-prem source replicates to via FTS.

The registration shape is the same regardless of which storage you're pointing at — only the hostname, port, scheme, and third-party-copy direction change:
```bash
ra rse add <RSE_NAME>
ra rse set-attribute --rse <RSE_NAME> --key fts --value https://fts:8446
ra rse set-attribute --rse <RSE_NAME> --key oidc_support --value True
ra rse set-attribute --rse <RSE_NAME> --key auth_type --value OIDC
ra rse set-attribute --rse <RSE_NAME> --key audience --value <audience>   # bare name or https://<host>/ — depends on whether your LS AAI client uses resource=
ra rse add-protocol <RSE_NAME> --scheme <davs|https> --hostname <hostname> --port <port> --prefix <path> \
  --impl rucio.rse.protocols.gfal.Default \
  --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":<0|1>,"third_party_copy_write":<0|1>},"lan":{"read":1,"write":1,"delete":1}}'
ra rse add-distance <SOURCE_RSE> <DEST_RSE> --distance 1
```
A few things that differ by role, worth checking against the target's own docs before registering:
- **Scheme/port**: WebDAV-fronted storage (Teapot, and likely TUBITAK/MUSICA) uses `davs`/`https`; XRootD-native storage uses `davs` on the XRootD HTTP listener port (1094 in the test fixtures) — confirm the actual port with whoever operates the endpoint.
- **`third_party_copy_read`/`write`**: set based on the RSE's role — a pure source only needs `third_party_copy_read`, a pure destination only `third_party_copy_write`; set both if it can be either.
- **Distance**: only add it in the direction(s) you actually intend to transfer — `add-distance <source> <dest>` (and the reverse, if bidirectional).
- **Audience/Resource Indicator**: whatever hostname you register here must also be registered as a Resource Indicator on the LS AAI client ([§1](#1-register-the-ls-aai-oidc-client)) — `resource=` requests for storage you haven't registered will fail regardless of how the RSE itself is configured.

**Scopes & quotas**
```bash
ra scope add --account root --scope test
ra scope add --account <service-account> --scope <service-account>
ra scope add --account <user-account> --scope <user-account>

for rse in <RSE_NAME> <RSE_NAME_2> ...; do
  ra account set-limits root "$rse" -1
  ra account set-limits <user-account> "$rse" -1
  ra account set-limits <service-account> "$rse" -1
done
```

**FTS OIDC token provider** — register both slash and no-slash issuer forms; both are required, not redundant (submit-time lookup matches the raw JWT `iss` verbatim, while FTS's `t_token` foreign key requires the slashed form):
```bash
docker exec compose-fts-1 curl -skS --cert /etc/grid-security/hostcert.pem --key /etc/grid-security/hostkey.pem \
  -X POST -H "Content-Type: application/json" \
  -d "{\"name\":\"ls-aai-dev\",\"issuer\":\"https://login.aai.lifescience-ri.eu/oidc\",\"client_id\":\"${OIDC_CLIENT_ID}\",\"client_secret\":\"${OIDC_CLIENT_SECRET}\"}" \
  https://localhost:8446/config/token_providers

docker exec compose-fts-1 curl -skS --cert /etc/grid-security/hostcert.pem --key /etc/grid-security/hostkey.pem \
  -X POST -H "Content-Type: application/json" \
  -d "{\"name\":\"ls-aai-dev-slash\",\"issuer\":\"https://login.aai.lifescience-ri.eu/oidc/\",\"client_id\":\"${OIDC_CLIENT_ID}\",\"client_secret\":\"${OIDC_CLIENT_SECRET}\"}" \
  https://localhost:8446/config/token_providers

docker compose -f docker-compose.yml restart fts
```
This is one-time per deployment (not per RSE) — you don't need to re-run it when adding a new source/destination RSE, only when the LS AAI issuer or client credentials change.

**Subject-token seeding** (always required in this deployment — see above) — mints a `client_credentials` token per seed account and stores it via Rucio's OIDC core (`oidc.save_subject_token`) so token-exchange has something to exchange against. This one's Python-API-only (no `rucio-admin` equivalent) — see `init-testbed.sh`'s `seed_subject_tokens()` if you need to run it by hand.

## 6. Map the user's identity
This is the one step that needs input **from** the user, not just for them. Get their `sub` from their own LS AAI login (not a client_credentials token — that `sub` belongs to the client). Easiest: have them log in once per [the user runbook's §1](user-runbook.md#1-log-in) and paste back the `sub` from their token.

Map it to the `<user-account>` you created in [§5](#5-initialize-accounts-rses-quotas) (`randomaccount` in the test fixtures) — not necessarily the same account for every user; each user gets their own identity mapped to their own account:
```bash
docker exec -it compose-rucio-server-1 rucio-admin identity add --type OIDC \
  --id "SUB=<their-sub>@lifescience-ri.eu, ISS=https://login.aai.lifescience-ri.eu/oidc/" \
  --account <user-account> --email <their-email>

# Example
docker exec -it compose-rucio-server-1 rucio-admin identity add --type OIDC \
  --id "SUB=28f7bc3a2d32a4a722f6eb24f77f7fbe42eb6471@lifescience-ri.eu, ISS=https://login.aai.lifescience-ri.eu/oidc/" \
  --account randomaccount --email marvin.gajek@cern.ch
```

## Sanity check before handing off
```
make verify-idp-token
make probe-teapot
make probe-xrootd
```
All green → send the [user runbook](user-runbook.md). A 401 here means client credentials or resource-indicator registration ([§1](#1-register-the-ls-aai-oidc-client)) are wrong — fix before anyone touches storage.

Optionally run the full suite too:
```
make test-rucio-transfers
make test-rucio-deletion
```
Every rule should reach `state=OK`; every pytest case `PASSED`.

## Advanced: watching a transfer
`rucio-daemons` runs unconditionally with `make start` — one container (`compose-rucio-daemons-1`) running the full daemon set (judge-evaluator, conveyor submitter/poller/finisher, judge-cleaner, reaper) continuously in the background. Nothing to advance manually — a rule created via upload/`add-rule` converges on its own. Watch it:
```bash
docker logs -f compose-rucio-daemons-1
docker exec compose-rucio-client-1 rucio rule list --did ddmlab:<name>
```
If a rule sits in `REPLICATING`/`STUCK` longer than a cycle or two, check the FTS job directly rather than guessing:
```
docker exec compose-fts-1 curl -sk https://localhost:8446/jobs/<job-uuid>
```
its `reason` field (if `FAILED`) points at the actual cause.

## Deletion
Expiring a rule (`rucio update-rule --lifetime -1`) is enough — `rucio-daemons` picks it up (judge-cleaner + reaper) and reclaims storage automatically, no manual invocation needed. `make test-rucio-deletion` exercises this end to end.

## Admin-side troubleshooting
| Symptom | Cause | Fix |
|---|---|---|
| 401 on token fetch, `419 No delegation found for "/CN=fts"` | `idpsecrets.json` still has literal placeholders | Re-run [§3](#3-wire-in-credentials) sed; `grep -c "valid client" configs/rucio/idpsecrets.json` → 0 |
| `Client id must not be empty!` from a manual curl check | `$OIDC_CLIENT_ID` escaped inside `docker exec ... bash -c "..."` | Substitute on the host shell before the `docker exec` |
| `[TokenExchange] ... HTTP 400` | Resource Indicator missing for that RSE/service | Add `https://<rse>.example.org/` to the LS AAI client ([§1](#1-register-the-ls-aai-oidc-client)) |
| "could not finalize your token request" | Redirect URI mismatch, or `authorization_code` grant not enabled | Confirm redirect URIs registered exactly; confirm grant is enabled |
| `local user for sub claim ... does not exist` from Teapot | client's own client_credentials `sub` missing from mapping | Decode a client_credentials token, add `sub` to `configs/teapot/user-mapping.csv` |
| Rule stuck `REPLICATING`/`STUCK`, no auth error | storage rejecting token shape | Confirm Teapot/StoRM-WebDAV supports RFC 9068 `at+jwt`; check `scitokens.conf` issuer matches LS AAI `iss` exactly (trailing slash) |
| User hits access-denied org-unit page | not yet in required VO | Point them at the `lifescience_test` VO signup |
| `ra` commands start failing auth partway through [§5](#5-initialize-accounts-rses-quotas) | OIDC `client_credentials` token in `$tok` expired mid-session | Re-run the `tok=...` line to mint a fresh one |

## Teardown
```
make stop
make clear-artifacts
```
