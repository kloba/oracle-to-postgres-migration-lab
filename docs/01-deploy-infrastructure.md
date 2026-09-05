# 01 — Deploy the infrastructure

One `deploy.sh` run stands up the whole Azure side: the Oracle source VM, the PostgreSQL target,
the Foundry model deployment, a Windows jumpbox and the network that joins them.

This page explains what each resource is for, why it is configured the way it is, how long each
piece takes, how to prove it worked, and how to make it stop costing money.

- [What gets built](#what-gets-built)
- [1. Preflight, again](#1-preflight-again)
- [2. Dry run with `--what-if`](#2-dry-run-with---what-if)
- [3. Deploy](#3-deploy)
- [4. What the deployment is doing, and for how long](#4-what-the-deployment-is-doing-and-for-how-long)
- [5. Why PostgreSQL is configured the way it is](#5-why-postgresql-is-configured-the-way-it-is)
- [6. Post-deploy: three things the template cannot do](#6-post-deploy-three-things-the-template-cannot-do)
- [7. Verify](#7-verify)
- [8. Getting in](#8-getting-in)
- [9. Troubleshooting](#9-troubleshooting)
- [10. Tear it down](#10-tear-it-down)

---

## What gets built

Everything lands in a single resource group, `AZ_RESOURCE_GROUP` (default
`o2p-migration-lab-rg`), so teardown is one operation.

![One resource group, o2p-migration-lab-rg, holding a 10.42.0.0/16 virtual network with three workload subnets: the Oracle VM on 10.42.1.10, the PostgreSQL flexible server in a delegated subnet, and the Windows jumpbox on 10.42.2.10. Azure Bastion is the only way in, a NAT gateway is the only way out, and the Microsoft Foundry account sits outside the VNet, reached over its public endpoint.](images/network-topology.png)

<sub>Source: [`images/network-topology.dot`](images/network-topology.dot). Regenerate with `./docs/images/render.sh` — edit the `.dot`, never the `.png`.</sub>

| Resource | Name | Purpose | Why this configuration |
| --- | --- | --- | --- |
| Virtual network | `o2p-vnet` | One private network for everything | `10.42.0.0/16` is unlikely to collide with a corporate range you might peer to later |
| Oracle subnet | `10.42.1.0/24` | The source database | Static private IP `10.42.1.10` becomes `ORACLE_HOST`, so nothing depends on DHCP |
| Jumpbox subnet | `10.42.2.0/24` | The VS Code client | Separate subnet so you can apply different NSG rules to the client than to the database |
| PostgreSQL subnet | `10.42.3.0/24` | Delegated to the flexible server | VNet integration means the server has **no public endpoint at all** |
| Bastion subnet | `10.42.4.0/26` | Azure Bastion | Must be named `AzureBastionSubnet` and be /26 or larger. Azure's rule, not ours |
| NAT gateway + public IP | `o2p-natgw` | Outbound internet for both VMs | Azure retired default outbound access in September 2025. Without this the Oracle image pull and the VS Code Marketplace both hang |
| Oracle VM | `o2p-oracle-vm` | **The simulated on-premises source.** Runs Oracle Database Free 23ai in a container | Ubuntu 22.04, `Standard_D4s_v5`, 128 GiB Premium SSD data disk for the datafiles. A VM, not a managed service, because the point is to migrate *from a server you control* — see [architecture.md](architecture.md#2-why-an-oracle-vm-and-not-a-managed-service) |
| PostgreSQL flexible server | `o2p-pg-<uniq>` | Conversion target and scratch host | PostgreSQL 16. Fifteen is the floor; see below |
| Target database | `contoso_store` | Where the converted schema lands | Schema `contoso` inside it |
| Scratch database | `migration_scratch` | Where the tool test-compiles and validates | Same server, so one extension allowlist covers both |
| Microsoft Foundry account | `o2p-foundry-<uniq>` | The LLM behind the conversion | Model and capacity are parameters — the model choice is contested upstream |
| Windows jumpbox | `o2p-jump` | Runs VS Code and the extension | Windows x64 is the least ambiguous supported client platform |
| Azure Bastion | `o2p-bastion` | Browser RDP and SSH without public IPs | **Standard SKU.** Basic rejects native tunneling (`enableTunneling`), and `az network bastion tunnel` is exactly how `scripts/connect.sh` and `scripts/seed-oracle.sh --azure` reach the Oracle VM and the VNet-private PostgreSQL server. `infra/modules/bastion.bicep` defaults to Basic; `deploy.sh` overrides it with `AZ_BASTION_SKU` (default `Standard`). Standard costs materially more — see [What it costs](../README.md#what-it-costs) |

`<uniq>` is a deterministic hash of your subscription ID and resource group name, because
PostgreSQL server names and Foundry account names must be globally unique.

---

## 1. Preflight, again

`deploy.sh` runs `preflight.sh` for you unless you pass `--skip-preflight`. Run it yourself first
anyway — it is free and takes under a minute:

```bash
./scripts/preflight.sh
```

Do not skip preflight to "save time". Most deployment failures are preflight failures that surfaced
twenty minutes late, after the resource group already contains billable half-built resources.

---

## 2. Dry run with `--what-if`

Always do this first. It creates nothing, costs nothing, and catches template and parameter
problems in about a minute.

```bash
./scripts/deploy.sh --what-if
```

You will see the standard ARM what-if colour output: `+` for resources that will be created, `~`
for modified, `-` for deleted. On a clean subscription everything is `+`.

Two failure modes worth recognising here:

| What-if says | Means |
| --- | --- |
| `InvalidTemplateDeployment ... requires parameter X` | The template wants a parameter `deploy.sh` does not send. The script also checks this itself and names the parameter |
| `SkuNotAvailable` / `LocationNotAvailable` | Your region cannot give you that SKU. Change `AZ_LOCATION` or the SKU variable, not the template |

---

## 3. Deploy

```bash
./scripts/deploy.sh
```

Before anything is created you get a confirmation prompt naming the region. Answer `y`. Use `--yes`
only for unattended runs.

What the script does, in order:

1. Sources `.env`, resolving any Key Vault indirection.
2. Runs preflight.
3. Creates an SSH keypair at `generated/ssh/o2p-lab_ed25519` if one does not exist. This is the only
   way into the Oracle VM — password authentication is disabled on it.
4. Reads `scripts/cloud-init/oracle-vm.yaml`, substitutes the Oracle passwords and the schema,
   container, image, service, port and reader-account names into its nine `__TOKEN__` placeholders,
   base64-encodes the result, and warns if any placeholder survived substitution.
5. Writes every parameter, including secrets, into a `0600` file in a private temp directory that is
   removed on exit — including on failure. Nothing sensitive appears on an `az` command line where
   `ps` could read it.
6. Starts a subscription-scoped deployment and streams per-resource progress.
7. On success, writes the non-secret outputs to `generated/outputs.json` and prints a connection
   table.

Expected output, abridged. The `[ ok ]`/`[ .. ]` prefixes, the `%-30s` column widths and the
wording are what the script really prints — if your run does not look like this, the difference is
the interesting part:

```text
== SSH key ==
  [ ok ] created generated/ssh/o2p-lab_ed25519.pub
         generated/ is gitignored; this key never reaches the public repo

== cloud-init ==
  [ ok ] scripts/cloud-init/oracle-vm.yaml rendered, gzipped and base64-encoded
         104264 chars raw -> 28756 gzipped (Azure limit 87380)

== Template parameters ==
  postgresAdministratorPassword <redacted>
  jumpboxAdminPassword          <redacted>
  oracleSystemPassword          <redacted>
  contosoPassword               <redacted>
  scratchAdminPassword          <redacted>
  [ ok ] sending 22 parameter(s)
         location resourceGroupName namePrefix oracleVmSize oracleAdminUsername
         oracleSshPublicKey postgresDatabaseName postgresScratchDatabaseName
         postgresAdministratorLogin foundryDeploymentName foundryModelName
         foundryModelVersion foundryModelCapacity jumpboxVmSize jumpboxAdminUsername
         bastionSkuName oracleCloudInitBase64

  This creates billable Azure resources in swedencentral.
  Run scripts/destroy.sh when you are done for the day.

  Continue? [y/N] y

== Deploying ==
  [ .. ] starting o2p-deploy-20260902-114233
  [ ok ] Resources/deployments                              deploy-network
  [ ok ] Network/virtualNetworks                            o2p-vnet
  [ ok ] Network/natGateways                                o2p-natgw
  [ .. ] DBforPostgreSQL/flexibleServers                    o2p-pg-h7k2mq4xw3abc
  [ ok ] Compute/virtualMachines                            o2p-oracle-vm
  [ ok ] CognitiveServices/accounts                         o2p-foundry-h7k2mq4xw3abc
  [ ok ] CognitiveServices/accounts/deployments             o2p-schema-conversion
  [ ok ] Compute/virtualMachines                            o2p-jump
  [ ok ] DBforPostgreSQL/flexibleServers                    o2p-pg-h7k2mq4xw3abc
  [ ok ] Network/bastionHosts                               o2p-bastion

  elapsed: 24m 07s

== Connection details ==
  SETTING                        VALUE
  ------------------------------ --------------------------------------------------
  resourceGroup                  o2p-migration-lab-rg
  location                       swedencentral
  bastionName                    o2p-bastion
  foundryAccountName             o2p-foundry-h7k2mq4xw3abc
  foundryDeploymentName          o2p-schema-conversion
  foundryEndpoint                https://o2p-foundry-h7k2mq4xw3abc.services.ai.azure.com/
  jumpboxName                    o2p-jump
  oracleVmPrivateIp              10.42.1.10
  postgresDatabaseName           contoso_store
  postgresFqdn                   o2p-pg-h7k2mq4xw3abc.postgres.database.azure.com
  postgresScratchDatabaseName    migration_scratch
  postgresServerName             o2p-pg-h7k2mq4xw3abc
  sshPrivateKey                  generated/ssh/o2p-lab_ed25519

Deployment succeeded. Written to generated/outputs.json
```

The output list is alphabetical and longer than the extract above — `generated/outputs.json` holds
every non-secret output, and the rest of this page reads values out of it with `jq` rather than
asking you to keep them in your head.

Ctrl-C stops you watching; it does not stop the deployment. Re-attach with:

```bash
az deployment sub show --name <deployment-name> --query properties.provisioningState -o tsv
```

### Options

| Flag | Effect |
| --- | --- |
| `--what-if` | Preview only. Creates nothing |
| `--region <name>` | Deploy somewhere other than `AZ_LOCATION` |
| `--name <name>` | Deployment name. Default `<prefix>-deploy-<timestamp>` |
| `--template <path>` | Use a different Bicep or ARM template |
| `--skip-preflight` | Do not run preflight first. You are on your own |
| `-y`, `--yes` | No confirmation prompt |

---

## 4. What the deployment is doing, and for how long

Resources are created in parallel where dependencies allow, so wall-clock time is set by the
slowest chain, not by the sum.

| Resource | Typical | Notes |
| --- | --- | ---: |
| Resource group | 5 s | |
| VNet, subnets, NSGs, private DNS zone | 1–2 min | |
| NAT gateway and public IP | 1–2 min | |
| Oracle VM (provisioning only) | 2–4 min | The VM is *created* here; Oracle is not running yet |
| Windows jumpbox | 3–6 min | Windows images take longer than Linux |
| Foundry account | 1–2 min | |
| Foundry model deployment | 1–3 min | Fails fast if you have no quota for the model |
| PostgreSQL flexible server | 8–14 min | Usually one of the two long poles |
| PostgreSQL parameter changes and **restart** | 2–5 min | `shared_preload_libraries` is a static parameter |
| Azure Bastion | 6–12 min | The other long pole |
| **Total ARM wall clock** | **20–30 min** | |

Then, invisibly, the work continues:

| After ARM finishes | Typical | What |
| --- | --- | ---: |
| Oracle VM cloud-init | 10–20 min | Installs Docker, pulls the Oracle Free 23ai image (2–3 GB), creates and opens `FREEPDB1` |

**The Oracle VM is not ready when the deployment says "Succeeded".** Trying to seed immediately
gives you a connection refused on port 1521 that looks like a networking problem and is not. Watch
cloud-init finish:

```bash
./scripts/connect.sh oracle-azure --shell        # or SSH through the Bastion tunnel
sudo cloud-init status --wait
sudo docker logs -f o2p-oracle | tail -20
```

You are waiting for `DATABASE IS READY TO USE!` in the container log.

---

## 5. Why PostgreSQL is configured the way it is

This is the part of the deployment most worth understanding, because getting it wrong does not
produce an error — it produces a conversion report you cannot trust.

### PostgreSQL 16, and why 15 is the floor

Two independent reasons:

1. The conversion tool requires **PostgreSQL 15 or later** for its scratch database.
2. The converted schema uses `MERGE`, which arrived in PostgreSQL 15. Four places in CONTOSO use
   Oracle `MERGE` and the conversion of those depends on it existing on the target.

The template deploys 16. Anything from 15 up works.

### The extension allowlist

Azure Database for PostgreSQL will not let you `CREATE EXTENSION` for anything that is not named in
the **`azure.extensions`** server parameter. The template sets it to exactly what this lab needs:

| Extension | Why the lab needs it |
| --- | --- |
| `orafce` | Oracle compatibility functions: `dual`, `decode`, `nvl`, `dbms_output`, `utl_file` and more |
| `uuid-ossp` | Identifier generation in converted code |
| `pgcrypto` | The `order_payment.card_token` column becomes a pgcrypto demonstration |
| `pg_trgm` | Trigram indexes replacing some Oracle text search |
| `postgis`, `postgis_topology`, `postgis_tiger_geocoder` | `address` carries latitude/longitude and GeoJSON |
| `pg_partman` | Oracle `INTERVAL` partitioning has no PostgreSQL equivalent; pg_partman is the answer |
| `pg_stat_statements` | Measuring the performance regressions the conversion introduces |
| **`plpgsql_check`** | Deep validation of converted PL/pgSQL. **Read the next section** |
| `dblink` | The only route for `PRAGMA AUTONOMOUS_TRANSACTION`, and it is needed on the **target**, not just scratch |

The parameter is set at the **server** level, so it applies to every database on that server —
both `contoso_store` and `migration_scratch`. Configure it once, get it everywhere.

### The gotcha that silently ruins a run: `plpgsql_check` is fail-open

If `plpgsql_check` is not allowlisted, the conversion tool **skips its deeper validation
silently**. No error. No warning in the report. You get a clean-looking result that was never
actually checked, and you find out weeks later.

This is why the extension list is applied by the deployment template rather than left as a manual
step, and why it must be in place **before your first conversion run** — a report produced without
it is worthless and cannot be retro-fixed.

If a conversion run comes back dramatically cleaner than [`docs/design.md`](design.md) section 9
predicts, your first hypothesis should be that validation never ran.

### `shared_preload_libraries` and the restart

Three of those extensions load into the server process and cannot be enabled by
`CREATE EXTENSION` alone:

```text
shared_preload_libraries = pg_partman_bgw,pg_stat_statements,plpgsql_check
```

`shared_preload_libraries` is a **static** parameter. Changing it requires a server **restart**, and
the template's ordering matters:

1. `azure.extensions` is set first — it is dynamic and takes effect immediately.
2. `shared_preload_libraries` is set second, which triggers the restart.
3. Everything else follows.

Two details that cost people an hour:

- The background worker library is **`pg_partman_bgw`**, not `pg_partman`. The extension and its
  worker have different names, and using the extension name in `shared_preload_libraries` fails
  quietly.
- `pg_partman_bgw.dbname` is set to `contoso_store`. The background worker only manages partitions
  in the database you name.

If you ever change these by hand, the restart is yours to trigger. The server name is a deployment
output, not an `.env` variable — read it out of `generated/outputs.json` the way every other command
on this page does:

```bash
PG_SERVER="$(jq -r .postgresServerName generated/outputs.json)"

az postgres flexible-server restart \
  --resource-group "$AZ_RESOURCE_GROUP" --name "$(jq -r .postgresServerName generated/outputs.json)"
```

### The other gotcha: `pg_catalog` always wins

Not a deployment setting, but decide it now because it shapes every converted line.

PostgreSQL searches `pg_catalog` first, always, regardless of `search_path`. So `to_char`,
`to_date` and `substr` resolve to the **PostgreSQL** builtins, never to orafce's Oracle-compatible
versions. The failure mode is not an error — it is subtly different formatted output.

Where Oracle semantics matter, call them explicitly:

```sql
SELECT oracle.to_char(order_ts, 'DD-MON-YYYY') FROM contoso.sales_order;
```

And set the **database-level** search path so the orafce companion schemas resolve:

```sql
ALTER DATABASE contoso_store
  SET search_path = contoso, public, oracle, topology, tiger,
                    dbms_output, dbms_lob, dbms_random, plvstr, plvsubst, utl_file;
```

That value is `PG_SEARCH_PATH` in `.env`. Database-level, not session-level: a session `SET`
evaporates and the next connection quietly gets different behaviour.

### Two databases on one server

The template creates **two** databases on the flexible server, and the second one is not optional.

| Database | Role |
| --- | --- |
| `contoso_store` | The **target**. The converted CONTOSO schema lands here, in schema `contoso` |
| `migration_scratch` | The **scratch database**. The tool creates and drops schemas prefixed `_mig_scratch_` in here while it test-compiles converted code |

The scratch database is where the conversion actually gets *checked*. The tool compiles each
converted object into a throwaway schema, runs `plpgsql_check` over it, and uses the result to
decide whether an object is done or needs a review task. Without it there is no compile step and no
validation — just a language-model guess written to a file.

Microsoft's requirement is that scratch is Azure Database for PostgreSQL **flexible server,
PostgreSQL 15+**. Azure HorizonDB is explicitly **not** supported for this role, though it *is*
supported as a conversion target from extension v1.27.x.

The requirement is a separate *database*, not a separate *server*. Two databases on one server is
the correct and cheapest answer, and it means the `azure.extensions` allowlist and
`shared_preload_libraries` — both server-level — are configured once and apply to both.

Point `.env` at it. **Same host**, different database — it is one flexible server with two
databases, not two servers:

```bash
SCRATCH_PGHOST=o2p-pg-<uniq>.postgres.database.azure.com     # identical to PGHOST
SCRATCH_PGDATABASE=migration_scratch
SCRATCH_PGUSER=o2padmin
```

One case justifies a second server: several people sharing one lab. The tool drops schemas in
scratch, and two simultaneous runs against the same scratch database will interfere. If you deploy
a second server, give it the **same** allowlist and the **same** `shared_preload_libraries` —
especially `plpgsql_check`, because scratch is where validation runs.

### Private access only

The server is deployed into a delegated subnet with a private DNS zone. It has **no public
endpoint**. `psql` from your laptop will fail to resolve `o2p-pg-<uniq>.postgres.database.azure.com`
and that is correct, not broken.

Connect from inside the VNet — the jumpbox, the Oracle VM, or an SSH tunnel through Bastion.

---

## 6. Post-deploy: three things the template cannot do

### 6.1 Create the extensions in the target database

The template allowlists the extensions and restarts the server. It does not run `CREATE EXTENSION`
for you, because extensions are per-database objects and creating them is the job of whoever owns
the schema.

Run this against the **target**, from the jumpbox or the Oracle VM:

```bash
psql "host=$PGHOST port=5432 dbname=$PGDATABASE user=$PGUSER sslmode=require" <<'SQL'
CREATE EXTENSION IF NOT EXISTS orafce;
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE EXTENSION IF NOT EXISTS pg_partman;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
SELECT extname FROM pg_extension ORDER BY 1;
SQL
```

**`plpgsql_check` is deliberately not in that list.** Per the Learn overview page, the check runs
entirely on the scratch database, the tool installs the extension there itself, and the target does
not need it at run time — it is a conversion-time quality gate, not a runtime dependency. What the
target *does* need is `dblink`, because `PRAGMA AUTONOMOUS_TRANSACTION` (H-02) converts into a
`dblink` call that executes on the target every time the converted code runs.

None of that softens the allowlist requirement. `plpgsql_check` must still be in `azure.extensions`
and in `shared_preload_libraries` **before your first conversion run** — that is a *server*-level
setting and it is what the scratch database's own `CREATE EXTENSION` depends on. Get it wrong and
you get the silent skip described above. `./scripts/status.sh` exits non-zero if it is missing:

```bash
./scripts/status.sh
```

**Now install them, because the allowlist has not.** `azure.extensions` says what you are
*permitted* to create. Nothing in the template runs `CREATE EXTENSION`, and ARM has no resource that
does, so both databases still contain nothing but `plpgsql`. Run:

```bash
./scripts/install-pg-extensions.sh                                  # from the jumpbox
PGHOST=127.0.0.1 PGPORT=15432 ./scripts/install-pg-extensions.sh    # over a tunnel
```

`deploy.sh` attempts this for you and reports it as a step to do later when it cannot reach the
server, which from a laptop is the normal case: the flexible server is private-access only.

Two details worth knowing before you run it. `fuzzystrmatch` cannot be allowlisted by name on Azure
— a direct `CREATE EXTENSION fuzzystrmatch` is refused — but `CASCADE` pulls it in as a dependency
of `postgis_tiger_geocoder`, which Azure does permit, so the script uses `CASCADE` throughout. And
the script finishes by asking the *running server* `SHOW shared_preload_libraries` rather than asking
ARM whether a restart is pending, because ARM is the control plane's opinion and `plpgsql_check`
fails open.

On a real run of this lab, the wizard's **Verify Extensions** button reported nine missing —
`orafce, pg_partman, pgcrypto, postgis, postgis_tiger_geocoder, postgis_topology, tablefunc,
uuid-ossp, pg_trgm` — against a server whose allowlist and preload libraries were both configured
exactly as this page describes. `tablefunc` was not even on the allowlist, so it could not have been
installed by hand either; it is on it now. Note that `plpgsql_check` was *not* in that list even
though it was not installed at the time, which is consistent with the Learn page's claim that the
tool installs it on the scratch database itself.

### 6.2 Grant yourself the Foundry data-plane role

Creating a Foundry account does not give you permission to call it.

```bash
FOUNDRY_ID="$(jq -r .foundryAccountId generated/outputs.json)"
MY_ID="$(az ad signed-in-user show --query id -o tsv)"

az role assignment create --assignee "$MY_ID" --role "Foundry User" --scope "$FOUNDRY_ID" \
  || az role assignment create --assignee "$MY_ID" \
       --role "Cognitive Services OpenAI User" --scope "$FOUNDRY_ID"
```

The two role names are the unresolved upstream conflict described in
[00 — Prerequisites](00-prerequisites.md#5-permissions). Grant whichever your tenant offers; grant
both if both exist. Allow a minute or two for propagation.

**This is not optional, even though the wizard offers an API Key box.** On a governed tenant the
key path cannot work at all — the model step fails with *"Key based authentication is disabled for
this resource"* — because a policy assignment rewrites `disableLocalAuth` to `true` on every write,
whatever `infra/modules/foundry.bicep` asks for. Check yours:

```bash
az policy state list --resource "$FOUNDRY_ID" \
  --query "[].{policy:policyDefinitionName, effect:policyDefinitionAction}" --output table
```

On the tenant this lab was built against that lists `CognitiveServices_LocalAuth_Modify` with a
`modify` effect. Choose **Microsoft Entra Id** in the wizard instead — which is the only path that
consults the role you just granted. See
[03 — Run the AI migration](03-run-ai-migration.md#31-foundry).

### 6.3 Copy the deployment outputs into `.env`

```bash
jq -r '"PGHOST=\(.postgresFqdn)\nORACLE_HOST=\(.oracleVmPrivateIp)\nFOUNDRY_ENDPOINT=\(.foundryEndpoint)\nFOUNDRY_DEPLOYMENT_NAME=\(.foundryDeploymentName)"' \
  generated/outputs.json
```

Paste those four into `.env`. `generated/outputs.json` is gitignored, written `0600`, and has every
credential-looking key filtered out before it is written — but do not commit it anyway.

---

## 7. Verify

Six checks. All of them should pass before you move on.

Checks 1 to 4 read the resource names out of `generated/outputs.json` — the Bicep output names, not
`.env` variables, because `.env` never learns what `<uniq>` resolved to:

```bash
PG_SERVER="$(jq -r .postgresServerName generated/outputs.json)"
FOUNDRY_ACCOUNT="$(jq -r .foundryAccountName generated/outputs.json)"
```

**Run from anywhere** (these only talk to the Azure control plane):

```bash
# 1. Everything exists
az resource list --resource-group "$AZ_RESOURCE_GROUP" \
  --query "[].{name:name, type:type}" --output table

# 2. The extension allowlist is what we asked for
az postgres flexible-server parameter show \
  --resource-group "$AZ_RESOURCE_GROUP" --server-name "$(jq -r .postgresServerName generated/outputs.json)" \
  --name azure.extensions --query value --output tsv

# 3. The preload libraries are set (and therefore the restart happened)
az postgres flexible-server parameter show \
  --resource-group "$AZ_RESOURCE_GROUP" --server-name "$(jq -r .postgresServerName generated/outputs.json)" \
  --name shared_preload_libraries --query value --output tsv

# 4. The model deployment exists and has the capacity you expect
az cognitiveservices account deployment list \
  --resource-group "$AZ_RESOURCE_GROUP" --name "$(jq -r .foundryAccountName generated/outputs.json)" \
  --query "[].{name:name, model:properties.model.name, capacity:sku.capacity}" --output table
```

**Run from inside the VNet.** Neither of the next two can work from your laptop: the flexible
server's FQDN does not resolve outside the VNet, and `10.42.1.10` is a private address with no
route to it. Open a shell on the Oracle VM first — `connect.sh` builds the Bastion tunnel and tears
it down again on exit:

```bash
./scripts/connect.sh oracle-azure --shell
```

```bash
# 5. Both databases exist, and the preload libraries really loaded
psql "host=$PGHOST dbname=$PGDATABASE user=$PGUSER sslmode=require" \
  -c 'SHOW shared_preload_libraries;' \
  -c "SELECT datname FROM pg_database WHERE datname IN ('$PGDATABASE','$SCRATCH_PGDATABASE');" \
  -c "SELECT extname FROM pg_extension ORDER BY 1;"

# 6. Oracle is actually running (you are already on the VM)
sudo docker exec o2p-oracle bash -lc \
  'sqlplus -s -L system/"$ORACLE_PWD"@localhost/FREEPDB1 <<< "SELECT 1 FROM dual;"'
```

Check 5 deliberately does not `CREATE EXTENSION plpgsql_check` on the target. `SHOW
shared_preload_libraries` is the check that matters — it proves the server-level setting took and
the restart happened, which is what the scratch database needs. If it comes back empty, stop:
`plpgsql_check` will not load, and your first conversion report will be silently unvalidated.

That, and check 3, are the two people skip.

---

## 8. Getting in

Neither VM has a public IP. Everything goes through Azure Bastion.

**Jumpbox (RDP in a browser)** — portal, or:

```bash
az network bastion rdp \
  --name "$(jq -r .bastionName generated/outputs.json)" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --target-resource-id "$(jq -r .jumpboxVmId generated/outputs.json)"
```

Sign in as `o2padmin` with `JUMPBOX_ADMIN_PASSWORD`. Install VS Code, then
`ms-ossdata.vscode-pgsql`, then sign in to GitHub Copilot.

**Oracle VM (SSH through a tunnel)**:

```bash
az network bastion tunnel \
  --name "$(jq -r .bastionName generated/outputs.json)" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --target-resource-id "$(az vm show -g "$AZ_RESOURCE_GROUP" -n o2p-oracle-vm --query id -o tsv)" \
  --resource-port 22 --port 2222 &

ssh -i generated/ssh/o2p-lab_ed25519 -p 2222 azureuser@127.0.0.1
```

`scripts/seed-oracle.sh --azure` does exactly this for you, on a port it picks itself, and tears the
tunnel down on exit.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `QuotaExceeded` partway through | Quota check skipped or region changed after preflight | `./scripts/preflight.sh --region <region>`, then request quota or resize |
| `SkuNotAvailable` on the PostgreSQL server | That SKU is not offered in your region | `az postgres flexible-server list-skus --location <region> -o table`, then set `PG_SKU_NAME` (and `PG_SKU_TIER`) in `.env` — `deploy.sh` forwards both to the template when they are non-empty |
| Model deployment fails with a capacity error | No TPM quota for that model in that region | Lower `FOUNDRY_TPM_QUOTA`, switch to `gpt-5-mini`, or set `FOUNDRY_LOCATION` |
| `name is already in use` with nothing visible in the portal | Key Vault and Foundry accounts are **soft-deleted**, not deleted | `./scripts/destroy.sh --purge`, or purge by hand |
| `AzureBastionSubnet` invalid | Subnet too small or misnamed | It must be exactly that name and /26 or larger. The template already does this |
| Oracle connection refused on 1521 after a successful deploy | cloud-init is still running | `sudo cloud-init status --wait` on the VM. 10–20 minutes |
| `psql` cannot resolve the PostgreSQL FQDN from your laptop | Private access only, by design | Connect from the jumpbox or the Oracle VM |
| `CREATE EXTENSION plpgsql_check` says not allow-listed | `azure.extensions` did not apply | Re-apply the parameter and restart the server |
| `SHOW shared_preload_libraries` is empty | The restart did not happen | `az postgres flexible-server restart` |
| Marketplace or GitHub times out on the jumpbox | NAT gateway missing or `deployNatGateway=false` | Redeploy with it enabled, or provide egress another way |
| Deployment "Failed" but resources exist | Partial deployment. **Still billing** | Read the errors, fix, redeploy — or `./scripts/destroy.sh` |

Re-running `deploy.sh` is safe. ARM deployments are declarative: existing resources that already
match are left alone.

A fuller symptom-to-cause-to-fix index for the whole lab lives in
[troubleshooting.md](troubleshooting.md).

---

## 10. Tear it down

**This lab costs real money every hour it exists.** Run `destroy.sh` whenever you stop working. A
lab left running over a long weekend is not a rounding error.

```bash
./scripts/destroy.sh
```

The script shows you the group's contents, makes you **type the resource group name** to confirm,
then deletes it. It remembers the Key Vault and Foundry account names first, because both are
soft-deleted rather than removed and their names stay reserved for 7 to 90 days — which is how the
next deployment fails with a confusing "name is already in use" that has no visible resource behind
it.

```text
  DESTROY - this permanently deletes an Azure resource group

  subscription     Contoso Lab Subscription
  resource group   o2p-migration-lab-rg

  Contents:
      6 x Network/networkInterfaces
      4 x Compute/disks
      2 x Compute/virtualMachines
      1 x DBforPostgreSQL/flexibleServers
      1 x CognitiveServices/accounts
      1 x Network/bastionHosts

  Type the resource group name to confirm:
```

| Flag | Effect |
| --- | --- |
| `-y`, `--yes` | Skip the typed confirmation. For CI and for the very sure |
| `--resource-group <name>` | Delete a different group than `AZ_RESOURCE_GROUP` |
| `--no-wait` | Start the delete and stop watching. It still completes |
| `--purge` | Also purge the soft-deleted Key Vault and Foundry account. Use this if you will redeploy with the same names |

It touches nothing local: your Docker container, `generated/`, `out/` and `.env` all survive.

### Pausing instead of destroying

If you want to continue tomorrow and keep the seeded Oracle database, stop the expensive compute
without deleting anything:

```bash
PG_SERVER="$(jq -r .postgresServerName generated/outputs.json)"

az vm deallocate --resource-group "$AZ_RESOURCE_GROUP" --name o2p-oracle-vm
az vm deallocate --resource-group "$AZ_RESOURCE_GROUP" --name o2p-jump
az postgres flexible-server stop --resource-group "$AZ_RESOURCE_GROUP" --name "$(jq -r .postgresServerName generated/outputs.json)"
```

Honest caveats:

- **Deallocate**, not "stop from inside the guest". A VM stopped from the guest OS keeps billing.
- Disks, public IPs and the private DNS zone keep billing. Expect roughly a third of the running
  cost, and Bastion is most of what is left.
- **Azure Bastion cannot be stopped.** It bills for existence, and this lab runs the **Standard**
  SKU because Basic cannot serve `az network bastion tunnel` — about **$7 a day**, not the ~$4.50
  the Basic SKU would cost. To stop paying for it you must delete it, and re-adding it takes 6–12
  minutes.
- A stopped flexible server **auto-starts after 7 days**. Set a reminder or you will pay for a week
  you did not use.

If you are pausing for more than a couple of days, destroying and redeploying is cheaper than
pausing. Redeploy is 20–30 minutes plus a re-seed.

---

**Next:** [02 — Seed the Oracle source](02-seed-oracle.md)
