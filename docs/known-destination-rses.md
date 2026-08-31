# Known destination RSEs

Configs for HPC destination storage (MUSICA, TUBITAK) — useful as concrete
examples when registering RSEs
([admin runbook §5](admin-runbook.md#5-initialize-accounts-rses-quotas)).

Originally seen registered against the shared `fts-egi.cern.ch` instance
(`rucio rse show <RSE>` on dep-dlm-testbed). Below, `fts` is set to this
deployment's **own** FTS (`https://fts:8446`) instead — DEP DLM is meant to
be self-hosted end to end (Rucio + FTS together), not dependent on an
external FTS. See **Prerequisites** before this actually works.

## Prerequisites — do these before wiring up a real transfer
1. **Confirm the issuer.** MUSICA/TUBITAK's storage only trusts tokens from
   whichever issuer *they* configured (probably EGI Check-In, not LS AAI
   dev) — check with ASC/TUBITAK. If it's not the issuer this deployment's
   `idpsecrets.json` uses, none of the below works regardless of resource
   indicators.
2. **Register Resource Indicators** for these three hostnames on this
   deployment's LS AAI client
   ([§1](admin-runbook.md#1-register-the-ls-aai-oidc-client)) — required
   before `resource=` requests for them will succeed.
3. **Validate with a probe before a real rule.** Mint a token scoped to the
   target audience and do a lightweight auth check (`PROPFIND`/`xrdfs ls`,
   same shape as `probe_teapot.py`/`probe_xrootd.py`) rather than assuming
   it works. Worth a CI job (`probe_musica.py`) — keep it out of the
   default `e2e.yml` matrix since it depends on third-party uptime/creds
   outside this repo's control; a separate, non-blocking workflow fits
   better.

## MUSICA_INNSBRUCK

| | |
|---|---|
| Host | `stg-xrootdm-01.musica.inn.asc.ac.at` |
| Scheme / port / prefix | `davs` / `1094` / `/ri-scale` |
| FTS | `https://fts:8446` |
| `lfn2pfn_algorithm` | `hash` (default) |
| `verify_checksum` | `True` |
| WAN TPC | read + write |

## MUSICA_LINZ
Same shape, different site:

| | |
|---|---|
| Host | `stg-xrootdm-01.musica.lnz.asc.ac.at` |
| Scheme / port / prefix | `davs` / `1094` / `/ri-scale` |
| FTS | `https://fts:8446` |
| `lfn2pfn_algorithm` | `hash` (default) |
| `verify_checksum` | `True` |
| WAN TPC | read + write |

## TUBITAK_WEBDAV

| | |
|---|---|
| Host | `riscale-ui.ulakbim.gov.tr` |
| Scheme / port / prefix | `davs` / `8081` / `/default_area` |
| FTS | `https://fts:8446` |
| `lfn2pfn_algorithm` | **`identity`** (flat paths, not hashed — set explicitly) |
| `verify_checksum` | **`False`** (explicitly disabled) |
| `greedyDeletion` | `True` |
| WAN TPC | read + write |

`lfn2pfn_algorithm`/`verify_checksum` aren't covered in the admin runbook's
RSE walkthrough — add them as extra `ra rse set-attribute` calls if your
own target needs the same.

## Registration commands
`ra` = the OIDC-token `rucio-admin` wrapper from
[admin runbook §5](admin-runbook.md#5-initialize-accounts-rses-quotas).

**MUSICA_INNSBRUCK**
```bash
ra rse add MUSICA_INNSBRUCK
ra rse set-attribute --rse MUSICA_INNSBRUCK --key fts --value https://fts:8446
ra rse set-attribute --rse MUSICA_INNSBRUCK --key oidc_support --value True
ra rse set-attribute --rse MUSICA_INNSBRUCK --key auth_type --value OIDC
ra rse add-protocol MUSICA_INNSBRUCK --scheme davs --hostname stg-xrootdm-01.musica.inn.asc.ac.at --port 1094 --prefix /ri-scale \
  --impl rucio.rse.protocols.gfal.Default \
  --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'
```

**MUSICA_LINZ**
```bash
ra rse add MUSICA_LINZ
ra rse set-attribute --rse MUSICA_LINZ --key fts --value https://fts:8446
ra rse set-attribute --rse MUSICA_LINZ --key oidc_support --value True
ra rse set-attribute --rse MUSICA_LINZ --key auth_type --value OIDC
ra rse add-protocol MUSICA_LINZ --scheme davs --hostname stg-xrootdm-01.musica.lnz.asc.ac.at --port 1094 --prefix /ri-scale \
  --impl rucio.rse.protocols.gfal.Default \
  --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'
```

**TUBITAK_WEBDAV** (two extra attributes vs. the MUSICA pair):
```bash
ra rse add TUBITAK_WEBDAV
ra rse set-attribute --rse TUBITAK_WEBDAV --key fts --value https://fts:8446
ra rse set-attribute --rse TUBITAK_WEBDAV --key oidc_support --value True
ra rse set-attribute --rse TUBITAK_WEBDAV --key auth_type --value OIDC
ra rse set-attribute --rse TUBITAK_WEBDAV --key lfn2pfn_algorithm --value identity
ra rse set-attribute --rse TUBITAK_WEBDAV --key verify_checksum --value False
ra rse add-protocol TUBITAK_WEBDAV --scheme davs --hostname riscale-ui.ulakbim.gov.tr --port 8081 --prefix /default_area \
  --impl rucio.rse.protocols.gfal.Default \
  --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'
```

Pair with your own source RSE:
```bash
ra rse add-distance <YOUR_SOURCE_RSE> <ONE_OF_THE_ABOVE> --distance 1
```

## Why this needs Prerequisites 1–2, briefly
Neither XRootD's `scitokens.conf` nor Teapot's storm-webdav policies check
*which* FTS submitted a job — they authorize purely on the token's
`iss`/`aud`. So any FTS holding a correctly issued, correctly audienced
token can submit here — including this deployment's own. What's actually
missing isn't "the right FTS," it's a client at the *right issuer* with
the *right Resource Indicators* — hence Prerequisites 1–2 above, not a
storage-side restriction on which FTS instance is allowed.
