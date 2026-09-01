# dep-dlm-bbmri — User Runbook

For: BBMRI users doing login, upload/download, and transfer checks against
a stack an admin has already stood up. Admin-facing counterpart: [admin-runbook.md](admin-runbook.md).

## You need

- Access to the deployed stack (ask your admin for the repo / host, or just the Rucio host if connecting remotely).
- Your identity in the **Life Science Community - Test Environment** VO:
  https://signup.aai.lifescience-ri.eu/fed/registrar?vo=lifescience_test
  (if `rucio whoami` shows an access-denied org-unit page, you're not in yet — wait a few minutes after registering)
- Your account already provisioned and identity-mapped by your admin ([their runbook §6](admin-runbook.md#6-map-the-users-identity)) — this doesn't work until that's done, whichever way you connect below.
- Nothing installed locally — no gfal2, no `/etc/hosts` edits, no port-forwarding either way.
- This stack's CA cert (`certs/rucio_ca.pem`) and CA bundle (`certs/tls_ca_bundle.pem`) from the repo — needed either way, mounted into the client container below. Every storage endpoint (Teapot, XRootD) uses a self-signed cert from this CA; without it, uploads/downloads fail with `Server certificate verification failed: issuer is not trusted` even though login/catalog calls work fine (those go through Rucio's own trust store, a separate path from `gfal2`'s).

## 1. Log in

Run a standalone client container with your own config mounted in. How you configure it depends on whether you're on the same Docker host as the deployment or connecting from elsewhere:

```bash
docker run -it --rm \
  --network dep-dlm-bbmri \
  -v <path-to-repo>/certs/rucio_ca.pem:/etc/grid-security/certificates/5fca1cb1.0:ro \
  -v <path-to-repo>/certs/tls_ca_bundle.pem:/etc/grid-security/certificates/tls_ca_bundle.pem:ro \
  -v <path-to-your-rucio.cfg>:/opt/rucio/etc/rucio.cfg \
  rucio/rucio-clients:release-41.2.1 bash
```

**Same node as the deployment** (you can run `docker run --network dep-dlm-bbmri` — confirmed working, upload/rule/download all pass end to end):
```ini
[client]
rucio_host = http://host.docker.internal:8090
auth_host = http://host.docker.internal:8090
auth_type = oidc
account = <your-account>
oidc_scope = openid profile eduperson_entitlement offline_access
oidc_issuer = https://login.aai.lifescience-ri.eu/oidc/
oidc_audience = https://fts.example.org/ https://teapot1.example.org/ https://teapot2.example.org/ https://xrd3.example.org/ https://xrd4.example.org/
```

**Off-node / genuinely remote** (no access to `--network dep-dlm-bbmri`, connecting over the network to the deployment host's published port instead):
```ini
[client]
rucio_host = http://<deployment-host>:8090
auth_host = http://<deployment-host>:8090
auth_type = oidc
account = <your-account>
oidc_scope = openid profile eduperson_entitlement offline_access
oidc_issuer = https://login.aai.lifescience-ri.eu/oidc/
oidc_audience = https://fts.example.org/ https://teapot1.example.org/ https://teapot2.example.org/ https://xrd3.example.org/ https://xrd4.example.org/
```
`rucio whoami`, `rule list`, and other catalog operations work fine here — they only need the published `8090` port. **Actual upload/download won't work off-node without extra setup**, though: `gfal2` connects directly to whatever hostname+port is in the RSE's registered PFN (e.g. `davs://teapot2:8081/...`), and Teapot1/Teapot2 both listen internally on `8081`, published externally as *different* ports (`8081`/`8082`). A plain hostname alias can't route "same host, different port" for you — ask your admin whether a reverse proxy or per-service DNS is set up for remote data-plane access before assuming this works from outside the node.

```bash
rucio whoami
```

Open the printed URL, log in with your LS AAI identity, paste the code back at the prompt.
- If the browser can't load it: the URL is printed as `https://` but rucio-server on :8090 is plain HTTP — change to `http://` and retry.
- **First time only:** your admin needs your `sub` claim to finish mapping your identity — if `whoami` fails with an unmapped-identity error, send them the `sub` from your token (decode it, or ask them how) and wait for them to run the mapping step.

**`compose-rucio-client-1` (already running on the deployment host) is for test purposes** — it's what `make test-rucio-transfers` etc. use. Its `rucio.cfg` is pinned to the `ddmlab` service account via userpass, not your own identity:
```ini
[client]
rucio_host = http://rucio-server
auth_host = http://rucio-server
auth_type = userpass
username = ddmlab
password = secret
account = ddmlab
request_retries = 3
```
Use it if you specifically need to run the test suite ([§3](#3-same-thing-in-python)); for your own login, use the standalone container above.

## 2. Smoke test: upload → transfer → download

CLI, quickest path:

```bash
echo "Hello Teapot upload" >> /tmp/hello-teapot.txt
rucio -v upload --rse TEAPOT1 --scope randomaccount /tmp/hello-teapot.txt
rucio add-rule randomaccount:hello-teapot.txt 1 TEAPOT2
rucio rule list --did randomaccount:hello-teapot.txt   # watch REPLICATING -> OK
rucio -v download randomaccount:hello-teapot.txt --rses TEAPOT2
```
`--rses TEAPOT2` matters on the last line — once the rule completes, the file exists on *both* TEAPOT1 and TEAPOT2, so `list_replicas` returns multiple sources. Without pinning `--rses`, download can silently pull from whichever RSE resolves first, not necessarily the destination you meant to verify.

(swap `randomaccount` for your own account/scope)

A rule state of `OK` with a replica on the destination = catalog → FTS → storage all working.

Other pairs, same shape — just swap `--rse`/rule target:
| From | To |
|---|---|
| XRD3 | XRD4 |
| TEAPOT1 | TEAPOT2 |
| XRD3 | TEAPOT1 (cross-protocol) |
| TEAPOT1 | XRD3 (cross-protocol) |

```bash

# XRD3 -> XRD4
echo "Hello XRD upload" >> /tmp/hello-xrd.txt
rucio -v upload --rse XRD3 --scope randomaccount /tmp/hello-xrd.txt
rucio add-rule randomaccount:hello-xrd.txt 1 XRD4
rucio rule list --did randomaccount:hello-xrd.txt
rucio -v download randomaccount:hello-xrd.txt --rses XRD4

# XRD3 -> TEAPOT1 (cross-protocol)
echo "Hello XRD to Teapot" >> /tmp/hello-xrd-to-teapot.txt
rucio -v upload --rse XRD3 --scope randomaccount /tmp/hello-xrd-to-teapot.txt
rucio add-rule randomaccount:hello-xrd-to-teapot.txt 1 TEAPOT1
rucio rule list --did randomaccount:hello-xrd-to-teapot.txt
rucio -v download randomaccount:hello-xrd-to-teapot.txt --rses TEAPOT1

# TEAPOT1 -> XRD3 (cross-protocol)
echo "Hello Teapot to XRD" >> /tmp/hello-teapot-to-xrd.txt
rucio -v upload --rse TEAPOT1 --scope randomaccount /tmp/hello-teapot-to-xrd.txt
rucio add-rule randomaccount:hello-teapot-to-xrd.txt 1 XRD3
rucio rule list --did randomaccount:hello-teapot-to-xrd.txt
rucio -v download randomaccount:hello-teapot-to-xrd.txt --rses XRD3
```
Each is the same shape as the TEAPOT1 → TEAPOT2 example above — upload to the source, `add-rule` to the target, `rule list` to watch it converge, then `download --rses <target>`. Use a fresh filename per pair if running them back to back (`rucio.upload` will complain about a duplicate DID otherwise).

**Rule stuck REPLICATING?** `rucio-daemons` runs continuously in the background and drives this on its own — usually FTS just hasn't finished yet, not actually stuck. Only worry if it doesn't move for 30–60s.

## 3. Same thing in Python
Useful if you're scripting checks rather than typing CLI by hand. These use the
same helpers the test suite (`conftest.py`) is built on.
```python
from conftest import make_client, compute_pfn, seed_xrd, prepare_xrd_dest, \
    register_replica, add_rule, validate_rule

client = make_client()
name = "my-test-file"

src_pfn = compute_pfn(client, "XRD3", "randomaccount", name)
dst_pfn = compute_pfn(client, "XRD4", "randomaccount", name)

size, adler32 = seed_xrd("xrd3", src_pfn, token=xrd3_write_token)  # your write-scoped token
prepare_xrd_dest(dst_pfn, token=xrd4_write_token)

register_replica(client, "XRD3", "randomaccount", name, src_pfn, size, adler32)
rule_id = add_rule(client, "randomaccount", name, "XRD4")

validate_rule(client, rule_id, "XRD3->XRD4 smoke test")  # polls until OK; rucio-daemons drives it in the background
```
For Teapot (WebDAV, no filesystem seed), swap `seed_xrd`/`prepare_xrd_dest` for
`webdav_put`/`webdav_get` against the Teapot URL — see `test_rucio_transfers.py`'s
`TestTeapotOIDC` for the exact pattern.

Run it inside the client container:

```
make test-rucio-transfers
```

## 4. Cleanup

```bash
docker exec compose-rucio-client-1 rucio update-rule --lifetime -1 <rule_id>
```

`rucio-daemons` picks up the expired rule and reclaims storage automatically; check it landed:

```bash
rucio replica list file randomaccount:<name>   # should come up empty once reaped
```

## User-side troubleshooting
| Symptom | Cause | Fix |
|---|---|---|
| Access-denied org-unit page on login | Not yet in the required VO | Register at the `lifescience_test` VO signup link, wait a few minutes |
| "could not finalize your token request" | Redirect URI mismatch or grant not enabled on the client | Admin-side fix — ping them |
| Browser can't reach the URL `rucio whoami` prints | Printed URL is `https://`, rucio-server on :8090 is plain HTTP only | Change to `http://` and retry |
| `Missing dependency: gfal2` | Running `rucio` from the host instead of a client container | Always run via the standalone container or `docker exec compose-rucio-client-1 rucio ...` |
| `Server certificate verification failed: issuer is not trusted` on upload/download | Standalone container missing this stack's self-signed CA — separate trust path from Rucio's own catalog calls | Mount `certs/rucio_ca.pem` (as `5fca1cb1.0`) and `certs/tls_ca_bundle.pem` into `/etc/grid-security/certificates/` (see [§1](#1-log-in)) |
| `Domain name resolution failed` on upload/download, catalog calls work fine | Client not on the `dep-dlm-bbmri` Docker network, so storage hostnames (`teapot1`, `xrd3`, ...) don't resolve | Add `--network dep-dlm-bbmri` if on the same host; if genuinely remote, see the off-node caveat in §1 |
| `No preferred protocol impl in rucio.cfg: No section: 'download'` during download | Informational only — no `[download]` section set, client picks a default | Safe to ignore |
| `"unzip -v" returned with exitcode 127` in verbose download logs | `unzip` isn't installed in the client image | Safe to ignore — falls back to `tar` automatically |
| Rule stuck `REPLICATING`/`STUCK`, no auth error | Storage-side token rejection, not your upload | Flag to admin — likely a `scitokens.conf`/issuer mismatch, not user-fixable |
