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

## 1. Log in
Run a standalone client container with your own config mounted in — this is how you connect, whether from your own machine or a jump host:
```bash
docker run -it --rm \
  -v <path-to-your-rucio.cfg>:/opt/rucio/etc/rucio.cfg \
  <rucio-client image> bash
```
```ini
[client]
rucio_host = <this deployment's Rucio host>
auth_host = <this deployment's Rucio host>
auth_type = oidc
account = <your-account>
request_retries = 3
oidc_scope = openid profile offline_access eduperson_entitlement read:/ write:/
```
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
echo "Sample upload" >> /tmp/sample.txt
rucio -v upload --rse TEAPOT1 --scope randomaccount /tmp/sample.txt
rucio add-rule randomaccount:sample.txt 1 TEAPOT2
rucio rule list --did randomaccount:sample.txt   # watch REPLICATING -> OK
rucio -v download randomaccount:sample.txt --rses TEAPOT2
```
(swap `randomaccount` for your own account/scope)

A rule state of `OK` with a replica on the destination = catalog → FTS → storage all working.

Other pairs, same shape — just swap `--rse`/rule target:
| From | To |
|---|---|
| XRD3 | XRD4 |
| TEAPOT1 | TEAPOT2 |
| XRD3 | TEAPOT1 (cross-protocol) |
| TEAPOT1 | XRD3 (cross-protocol) |

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
| Rule stuck `REPLICATING`/`STUCK`, no auth error | Storage-side token rejection, not your upload | Flag to admin — likely a `scitokens.conf`/issuer mismatch, not user-fixable |
