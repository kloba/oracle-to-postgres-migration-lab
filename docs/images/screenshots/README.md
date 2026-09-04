# Driving the conversion for real — what actually happened

A record of running the VS Code PostgreSQL extension (`ms-ossdata.vscode-pgsql`)
against this lab's Azure deployment on **2026-09-04**. The screenshots referenced
below sit beside this file.

The earlier version of this page described a run that stopped at step 3 of the
wizard and gave a *guess* about why. That guess was wrong, and it is corrected in
§"What the earlier version of this page got wrong". This run went all the way
through: every wizard step validated, a project created, **1,299 objects
extracted from Oracle**, and **the conversion completed** — 2h 56m, 7.2M tokens,
947 of 1,185 objects converted. The reports are in
[docs/conversion-report/](../../conversion-report/README.md).

Four defects in this lab were found by doing it. All four are fixed in the repo;
each is credited to the screenshot that exposed it.

## The setup

| | |
|---|---|
| Client | VS Code 1.136.1 on macOS 15.7.9 arm64, driving a **Remote-SSH** window |
| Where the extension actually ran | the lab's Oracle VM — Ubuntu, x86-64, inside the VNet |
| Extension build | `ms-ossdata.vscode-pgsql-1.30.1-linux-x64` |
| Oracle source | `CONTOSO` on the Azure VM, 1,855 objects, seeded `--scale 0.01` |
| Target | `o2p-pg-<uniq>.postgres.database.azure.com`, PG 16, private access |
| Model | `gpt-5.2`, deployment `o2p-schema-conversion`, 500 kTPM |

**Remote-SSH is the trick worth stealing.** Neither VM has a public IP and the
flexible server is private-access only, so from a laptop everything needs a
tunnel. Open the *Oracle VM* as a Remote-SSH host instead and the extension host
runs inside the VNet: Oracle is `localhost:1521`, the PostgreSQL FQDN resolves
natively to its private address, and the platform question disappears because the
remote is Linux x64. The status bar in every screenshot reads
`SSH: o2p-oracle-vm` for exactly that reason.

The one thing that stays on the Mac is the Microsoft sign-in, which opens the
local browser. That is what you want.

## The run, screenshot by screenshot

### 1. Oracle connects — `01-oracle-connected.png`

`localhost` / `1521` / `FREEPDB1` / `CONTOSO`, then **Load Schemas** →
*Oracle connection successful*. `02-schemas-contoso.png` shows the schema picker
offering `CONTOSO` and `PUBLIC`.

### 2. Verify Extensions fails — `03-extensions-missing.png` → **defect 1**

The scratch-database step has a **Verify Extensions** button. Against a server
whose `azure.extensions` allowlist and `shared_preload_libraries` were both
configured exactly as `docs/01-deploy-infrastructure.md` describes, it said:

> The following recommended Azure Database for PostgreSQL extensions are not
> installed in database "migration_scratch": orafce, pg_partman, pgcrypto,
> postgis, postgis_tiger_geocoder, postgis_topology, tablefunc, uuid-ossp,
> pg_trgm

Two separate faults behind one message:

- **Allowlisting is not installing.** `azure.extensions` decides what you are
  *permitted* to create. Nothing runs `CREATE EXTENSION`, and ARM has no resource
  that does — `SELECT extname FROM pg_extension` returned exactly one row,
  `plpgsql`, in both databases.
- **`tablefunc` was not on the allowlist at all**, so it could not have been
  installed even by hand.

Fixed by `scripts/install-pg-extensions.sh` (new), plus `tablefunc` added to
`infra/modules/postgres-flex.bicep`. `04-extensions-verified.png` is the same
button afterwards: **✓ Extensions Verified**.

A detail that cost a few minutes: `fuzzystrmatch` cannot be allowlisted by name
on Azure — a direct `CREATE EXTENSION fuzzystrmatch` is refused — but `CASCADE`
pulls it in as a dependency of `postgis_tiger_geocoder`, which Azure permits. The
script uses `CASCADE` throughout.

**A third fault the same check exposed.** With extensions installed, the running
server still reported

```text
shared_preload_libraries = pg_cron,pg_stat_statements,azure,pg_qs,…
```

— no `plpgsql_check`, no `pg_partman_bgw`, on a server ARM described as
`isConfigPendingRestart: true`. `deploy.sh` performs that restart and `status.sh`
asserts the ARM flag, and yet the live server had never loaded the library. That
is the lab's own fail-open trap, one level up: **ARM's answer is not the
server's.** `install-pg-extensions.sh` now finishes by asking the server itself,
`SHOW shared_preload_libraries`.

### 3. The API Key box is a trap — `05-apikey-disabled.png` → **defect 2**

The Foundry step offers **API Key** and **Microsoft Entra Id**. API Key looks
easier. It cannot work here:

> Azure OpenAI connection test failed: Key based authentication is disabled for
> this resource.

`infra/modules/foundry.bicep` asks for `disableLocalAuth: false`. The deployed
resource read `true`, and `az resource update --set
properties.disableLocalAuth=false` came straight back as `true` — the write was
accepted and silently reverted. The reason is visible in policy state:

```bash
az policy state list --resource "$FOUNDRY_ID" \
  --query "[].{policy:policyDefinitionName, effect:policyDefinitionAction}" -o table
```

```text
CognitiveServices_LocalAuth_Modify    modify    Compliant
```

A tenant policy with a **`modify`** effect rewrites the property on every write.
Nothing in the deployment output says so. Switching to **Microsoft Entra Id**,
signing in and selecting the tenant turns the same Test button green —
`06-foundry-entra-ok.png` — and that is also the only path that consults the
`Cognitive Services OpenAI User` role the docs tell you to grant. With API Key
the role is never used.

`07-project-created.png` is the project page that follows: **Schema Migration**,
**Schema Review**, **Application Migration (Preview)**, and the project written to
`~/.github/postgres-migrations/contoso-conversion/`.

### 4. Extraction Failed, with nothing on screen to say why — `08-extraction-failed.png` → **defect 3**

Clicking **Migrate** produced a red banner reading, in full, *Extraction Failed*.
No detail, no log link. The reason was in
`artifacts/oracle/CONTOSO/extract/internal/logs/extraction.log`:

```text
ossdbtoolsservice…extractor.oracle.connection_pool, in auto_detect_workers →
get_available_sessions
oracledb.exceptions.DatabaseError: ORA-00942: table or view
"SYS"."V_$RESOURCE_LIMIT" does not exist
Extraction … complete in 0m 0s: 0 extracted, 0 failed, 0 excluded
```

Before it enumerates a single object the extractor sizes its Oracle connection
pool by asking `V$RESOURCE_LIMIT` how many sessions are free. `CONTOSO` could not
read it, so the pool never initialised and the run ended having done nothing.

This is not in Microsoft's prerequisite list, and `src/oracle/00-user-tablespace.sql`
did not grant it. One `SYSDBA` statement fixed it:

```sql
GRANT SELECT ON sys.v_$resource_limit TO contoso;   -- v_$, not v$: no granting on a synonym
```

The same **Migrate** button then produced:

```text
Enumerated 1445 valid, 0 invalid objects
Discovery complete: 1260 extractable, 185 excluded, 0 invalid, 7 unsupported types
Created 27 batches for 1260 objects, workers=5
Extraction … complete in 2m 50s: 1299 extracted, 0 failed, 185 excluded
```

Worth knowing: `V$RESOURCE_LIMIT` returns **zero rows inside a PDB** — it is a
CDB-level view. That is fine. The extractor logs `Auto-detected workers: 5
(sessions: 0/0, available: 0)` and carries on. The missing privilege was fatal;
the empty result is not.

`scripts/seed-oracle.sh` now makes this grant as `SYSDBA` straight after
`00-user-tablespace.sql`, and reports a failure there as a hard error rather than
the skip it uses for the optional `DBMS_RLS` grant — losing this one costs you the
whole conversion, not one hard case.

## What the conversion actually did — `09-migration-complete.png`

It finished. **Migration Complete**, and the extension opens its own Conversion
Summary beside the project page:

```text
Status              COMPLETED
Source DB           Oracle 23.26.3.0.0        Target DB   PostgreSQL 16
Model               gpt-5.2                   Extension   1.30.1
Duration            2h 56m 53s                Tokens      7,178,840
Objects extracted   1,189   Converted 947   Not-Converted 242   79.65%
```

The reports themselves are committed to
[docs/conversion-report/](../../conversion-report/README.md) with the numbers, the
per-type breakdown, and — more useful than the percentage — the tool's own reasons
for its failures. The short version: `TABLE`, `SEQUENCE`, `TYPE` and `SCHEMA`
converted at **100%**, `FUNCTION` at 97%, `PACKAGE_BODY` at 30%, and roughly four
fifths of the stated failure reasons are **`chunk timeout`** or **`lock timeout …
in relation pg_proc`** rather than anything to do with translation quality.

**It is far slower than this lab's docs claim.** `docs/design.md` predicts 45–90
minutes; this took just under three hours, and it stalled twice hard enough to need
manual intervention. Where the time goes is visible in `pg_stat_activity` on the
scratch database:

```text
state                 wait_event        count   longest
idle in transaction   Client/ClientRead    17   00:36:14
active                Lock/transactionid    1   00:20:14
```

Seventeen workers each holding a transaction open while their LLM call is in
flight, one blocked behind a peer on a catalog lock, and `lock_timeout` set to `0`
by the tool — so PostgreSQL cannot break it and nothing times out. The cycle runs
through the client, which is exactly the shape PostgreSQL's deadlock detector
cannot see. Terminating the blocking backend released it each time; four
terminations were needed across the run.

That intervention has a cost, and the report carries it: some of the 238
not-converted objects are collateral from those terminations, and they cannot be
told apart from genuine failures. **Read the report as a lower bound.**

**One caveat, stated rather than buried:** `install-pg-extensions.sh` was run
against `migration_scratch` *while the conversion was live*, and the first
`canceling statement due to lock … in relation "pg_proc"` appears about four
minutes later. Creating thirteen extensions under a running converter is a
plausible contributor to the early contention. Install the extensions before you
start the wizard, which is what `deploy.sh` now does.

## What the earlier version of this page got wrong

Worth recording, because both errors were confident and both were wrong.

**"A tunnelled PostgreSQL profile will never be offered."** The claim was that
the scratch step enumerates flexible servers through Azure Resource Manager, so a
hand-entered profile could not appear. It cited `listFlexibleServers`,
`getSubscriptions` and `azureResourceService` in the extension bundle. Those
strings are real; the conclusion was not. The step lists **saved connection
profiles**, and the test it applies is a hostname suffix:

```js
function tm(r){return r?.trim().toLowerCase().endsWith(".postgres.database.azure.com")===!0}
```

A profile created through `PGSQL: Connect` with the real FQDN — reachable because
the remote sits inside the VNet — appeared in the dropdown immediately, and the
dialog even grew an **AZURE METADATA** panel recognising it as an Azure resource.
What defeated the earlier attempt was pointing a profile at `127.0.0.1:15432`:
that connects fine, and can never satisfy the suffix test.

**"The gate is an interactive Azure sign-in."** Half right, for the wrong reason.
No Azure sign-in is needed to *select the scratch database*. One is needed for the
**Foundry** step, and only because key-based auth is policy-disabled (defect 2).

## Reproducing this

1. `./scripts/deploy.sh` then `./scripts/seed-oracle.sh --azure --scale 0.01`.
2. `./scripts/install-pg-extensions.sh` — before opening the wizard.
3. Grant yourself `Cognitive Services OpenAI User` on the Foundry account.
4. Add the Oracle VM as a Remote-SSH host and install the extension **in the
   remote**, or use the Windows jumpbox, which is the documented path.
5. `PostgreSQL: Focus on Migrations View` → `+ Create Migration Project`.
6. Oracle `localhost` / `1521` / `FREEPDB1` / `CONTOSO`, schema `CONTOSO`.
7. `PGSQL: Connect` to the **real** `*.postgres.database.azure.com` FQDN, database
   `migration_scratch`, then **Refresh Profiles** in the wizard.
8. Foundry: endpoint from `generated/outputs.json`, **Microsoft Entra Id**, your
   account and tenant.

## The two macOS screenshots

`macos-arm64-01-wizard-step-1.png` and `macos-arm64-02-migrations-view.png` are
from a separate session on the Mac itself, kept as the evidence for
`docs/lab-status.md` §3.9: the marketplace serves a **`darwin-arm64`** build, it
installs and activates, all 7 migration commands and the `pg-migrations` view are
present, and the wizard runs. That answers "does it launch on Apple Silicon". It
is not a support statement, and it is not how this conversion was run.

## A note on the screenshots

All are cropped to the VS Code window, which keeps the macOS menu bar, the Dock,
notification badges and meeting reminders out of a public repository. One earlier
screenshot leaked a machine hostname in a terminal prompt and had to be recropped.
Check anything you add here the same way before committing it.
