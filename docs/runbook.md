# Runbook — dep-dlm-bbmri

Single-site, on-prem/HPC Docker Compose deployment of Rucio + FTS3 against
LS AAI. Trimmed, compose-only, single-IdP version of
[dep-dlm-testbed](https://github.com/ri-scale/dep-dlm-testbed)'s runbooks —
no Kubernetes, no GitOps, no dev container, one IdP (LS AAI).

## Preconditions

- Docker Engine + Compose plugin (`docker compose version` succeeds). No
  Kubernetes/Helm needed.
- `make`, `bash`, `openssl`, `curl` on the host.
- Free local ports for the services in `docker-compose.yml` (Rucio, FTS
  REST `8446`, storage endpoints).
- Outbound HTTPS to `https://login.aai.lifescience-ri.eu/`.
- An **LS AAI OIDC client** registered for this deployment (§1) —
  `client_id`/`client_secret` + resource indicators are required before
  `make init` works.
- Your identity must belong to the `Life Science Community - Test
  Environment` VO — register at
  `https://signup.aai.lifescience-ri.eu/fed/registrar?vo=lifescience_test`
  if `rucio whoami` shows an access-denied org-unit page.

No `/etc/hosts` edits or port-forwarding needed — everything, including
interactive `upload`/`download`, runs via `docker exec
compose-rucio-client-1 ...` (§10), so the host never needs `gfal2` or
`rucio-clients` installed.

## 1. Registering the LS AAI client

Not self-service — contact `support@aai.lifescience-ri.eu` or use your
Federation Registry access.

1. Grant types: `client_credentials` (required) + `authorization_code`
   (interactive login) + `token-exchange` (for `TOKEN_MODE=managed`).
2. Register **Resource Indicators (RFC 8707)** for every RSE/service:
   `https://xrd3.example.org/`, `.../xrd4.example.org/`,
   `.../teapot1.example.org/`, `.../teapot2.example.org/`,
   `.../fts.example.org/`. `resource=` requests fail without these.
3. Enable "Issue refresh tokens" if using `token-exchange`.
4. Scope set is fixed by LS AAI (`openid profile email offline_access
   eduperson_entitlement`, no `read:/`/`write:/`) — already handled via
   `configs/rucio/idpsecrets.json`'s `capabilities` block.
5. `client_id`/`client_secret` go into `idpsecrets.json` (§3) — never
   commit real values, only the `<valid client id>`/`<valid client
   secret>` placeholders.

## 2. Generate certificates

```bash
make certs
```
LS AAI is system-CA-trusted — no combined CA bundle needed (unlike
EGI-dev). `rucio_ca.pem` still drives `[conveyor] cacert` for this
stack's own self-signed storage endpoints.

## 3. Configure LS AAI credentials

```bash
cp envs/ls-aai.env.example envs/ls-aai.env   # fill in client ID/secret
source envs/ls-aai.env

sed -i \
  -e "s|<valid client id>|${OIDC_CLIENT_ID}|g" \
  -e "s|<valid client secret>|${OIDC_CLIENT_SECRET}|g" \
  configs/rucio/idpsecrets.json
```
**Don't commit the substituted file** — `git checkout --
configs/rucio/idpsecrets.json` once done testing.

## 4. Start the stack

```bash
make start
make ps   # confirm everything is up
```

## 5. Initialize the testbed

```bash
source envs/ls-aai.env
make init
```
Provisions `ddmlab` (service account), `randomaccount`, RSEs
(`XRD3`/`XRD4`, `TEAPOT1`/`TEAPOT2`), distances, quotas, and — in managed
token mode — token-exchange seeding.

**Map your identity to `randomaccount`** for interactive use (automated
tests use `ddmlab` and don't need this):
```bash
docker exec -it compose-rucio-server-1 rucio-admin identity add --type OIDC \
  --id "SUB=<your-sub>@lifescience-ri.eu, ISS=https://login.aai.lifescience-ri.eu/oidc/" \
  --account randomaccount --email you@example.org
```
Get `<your-sub>` from your own LS AAI identity, not a `client_credentials`
token — that sub belongs to the *client*, not you, and mapping it won't
work for interactive login.

## 6. Verify the OIDC token flow

```bash
make verify-idp-token
```
Or by hand — substitute on the **host** shell, not inside the quoted
`bash -c` string, or the container sees empty vars:
```bash
source envs/ls-aai.env
docker exec compose-rucio-client-1 bash -c "
  curl -s -u '${OIDC_CLIENT_ID}:${OIDC_CLIENT_SECRET}' \
    -d 'grant_type=client_credentials' -d 'scope=openid' \
    https://login.aai.lifescience-ri.eu/oidc/token
"
```
Expect `200` + `access_token`. A `401` means the client credentials or
resource-indicator registration are wrong — fix before debugging FTS.

## 7. Run the tests

```bash
make probe-teapot
make probe-xrootd
make test-rucio-transfers
make test-rucio-deletion
```
Expect every rule to reach `state=OK` and every pytest case `PASSED`. A
rule stuck `REPLICATING`/`STUCK` with `Failed to procure a token` in the
conveyor logs points back at §3 (untemplated `idpsecrets.json`) or §1
(missing resource indicators).

## 8. Watching a transfer manually

Test suite drives the conveyor as one-shot `--run-once` calls
(`DAEMON_MODE=direct`, the default):
```bash
docker exec compose-rucio-server-1 rucio-judge-evaluator --run-once
docker exec compose-rucio-server-1 rucio-conveyor-submitter --run-once
docker exec compose-rucio-server-1 rucio-conveyor-poller --run-once --older-than 0
docker exec compose-rucio-server-1 rucio-conveyor-finisher --run-once

docker exec compose-rucio-client-1 rucio rule list --did ddmlab:<name>
```
- **submitter**: `Submit job <uuid> to https://fts:8446` = reached FTS.
  `exchange returned no token aud=<rse>` = managed token path not seeded
  — re-run `make init` with `TOKEN_MODE=managed`.
- **poller**: `state(RequestState.DONE)` = success. `[TokenExchange] ...
  HTTP 400` = resource-indicator/audience issue, not storage.
- **finisher**: rule lock flips to `OK`.

`DAEMON_MODE=daemons` runs these as long-lived containers instead — tail
with `docker logs -f compose-rucio-daemons-conveyor-<stage>-1`.

## 9. Deletion lifecycle

```bash
docker exec compose-rucio-client-1 rucio update-rule --lifetime -1 <rule_id>
docker exec compose-rucio-server-1 rucio-judge-cleaner --run-once
docker exec compose-rucio-server-1 rucio-reaper --run-once --greedy

docker exec compose-rucio-client-1 rucio replica list file ddmlab:<name>  # gone
```
`make test-rucio-deletion` exercises this end to end.

## 10. Interactive login + upload/download

**Use the `rucio-client` container, not a host-installed `rucio` CLI.**
`rucio upload`/`download` need `gfal2`, which isn't packaged for every
host OS/arch — the container already has it, so this works everywhere
without any local `gfal2`/`rucio-clients` install.

The container's default `/opt/rucio/etc/rucio.cfg` is pinned to
`userpass-client.cfg` (the `ddmlab` service account the automated tests
use) — **don't replace that mount**, or `make test-rucio-transfers`
breaks. Instead, the `oidc-client.cfg` is mounted alongside it and select it
per-command via `RUCIO_CONFIG`.

```bash
docker exec -it compose-rucio-client-1 bash

# within the container
export RUCIO_CONFIG=/opt/rucio/etc/oidc-client.cfg
rucio whoami

# open the printed URL in a browser, log in as your LS AAI identity,
# paste the code back at the prompt

echo "Sample upload" >> /tmp/sample.txt
rucio -v upload --rse TEAPOT1 --scope randomaccount /tmp/sample.txt
rucio -v download randomaccount:sample.txt --rses TEAPOT1
```
To upload a file from the host, drop it under a directory already
bind-mounted into `compose-rucio-client-1` (`./tests:/tests:ro` above),
or `docker cp` it in first.

A rule created afterwards (`rucio add-rule ...`) is moved server-side by
FTS, not the client — same as `upload`/`download` above running inside
the container rather than the storage.

### Full transfer matrix

Everything below runs inside the same `rucio-client` shell as above
(`RUCIO_CONFIG` already exported). Unlike a Kubernetes deployment, no
port-forwarding is needed anywhere here — `rucio-client`, the RSEs, and
FTS all sit on the same Compose network, so a rule's destination and any
verification `download` are reachable directly, no juggling forwards
between RSE pairs that share a port.

**1. XRootD → XRootD**
```bash
echo "Hello XRD upload" >> /tmp/hello-xrd.txt
rucio -v upload --rse XRD3 --scope randomaccount /tmp/hello-xrd.txt

rucio add-rule randomaccount:hello-xrd.txt 1 XRD4
rucio rule list --did randomaccount:hello-xrd.txt   # XRD3 OK[1/0/0], XRD4 REPLICATING -> OK

rucio rule show <rule_id>                            # REPLICATING -> OK
rucio replica list file randomaccount:hello-xrd.txt  # replica on XRD4
rucio -v download randomaccount:hello-xrd.txt --rses XRD4
```

**2. Teapot → Teapot**
```bash
echo "Hello Teapot upload" >> /tmp/hello-teapot.txt
rucio -v upload --rse TEAPOT1 --scope randomaccount /tmp/hello-teapot.txt

rucio add-rule randomaccount:hello-teapot.txt 1 TEAPOT2
rucio rule list --did randomaccount:hello-teapot.txt   # TEAPOT1 OK, TEAPOT2 -> OK

rucio rule show <rule_id>                              # REPLICATING -> OK
rucio replica list file randomaccount:hello-teapot.txt # replica on TEAPOT2
rucio -v download randomaccount:hello-teapot.txt --rses TEAPOT2
```

**3. Cross-protocol: XRootD → Teapot**
```bash
echo "Hello XRD to Teapot" >> /tmp/hello-xrd-to-teapot.txt
rucio -v upload --rse XRD3 --scope randomaccount /tmp/hello-xrd-to-teapot.txt

rucio add-rule randomaccount:hello-xrd-to-teapot.txt 1 TEAPOT1
rucio rule list --did randomaccount:hello-xrd-to-teapot.txt   # XRD3 OK, TEAPOT1 -> OK
```

**4. Cross-protocol: Teapot → XRootD**
```bash
echo "Hello Teapot to XRD" >> /tmp/hello-teapot-to-xrd.txt
rucio -v upload --rse TEAPOT1 --scope randomaccount /tmp/hello-teapot-to-xrd.txt

rucio add-rule randomaccount:hello-teapot-to-xrd.txt 1 XRD3
rucio rule list --did randomaccount:hello-teapot-to-xrd.txt   # TEAPOT1 OK, XRD3 -> OK
```

**5. Dataset — register two files, replicate as a group**
```bash
echo "file one" >> /tmp/ds-file1.txt
echo "file two" >> /tmp/ds-file2.txt
rucio -v upload --rse XRD3 --scope randomaccount /tmp/ds-file1.txt
rucio -v upload --rse XRD3 --scope randomaccount /tmp/ds-file2.txt

rucio did add --type dataset randomaccount:manual-test-dataset
rucio attach randomaccount:manual-test-dataset randomaccount:ds-file1.txt randomaccount:ds-file2.txt

rucio add-rule randomaccount:manual-test-dataset 1 XRD4
rucio rule list --did randomaccount:manual-test-dataset   # both files -> OK on XRD4
```

A rule state of `OK` with a replica on the destination confirms catalog →
FTS → storage works end to end for any RSE pair or dataset above — this
mirrors exactly what `TestXRootDOIDC`, `TestTeapotOIDC`,
`TestCrossProtocolOIDC`, and `TestDatasetOIDC` do in `make
test-rucio-transfers`, just driven by hand.

## Teardown

```bash
make stop
make clear-artifacts
```
