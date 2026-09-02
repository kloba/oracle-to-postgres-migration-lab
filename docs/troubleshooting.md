# Troubleshooting

A symptom → cause → fix index for the whole lab, in the order you hit the stages:

0. [Before anything: `.env` and prerequisites](#0-env-and-prerequisites)
1. [Deploy the Azure infrastructure](#1-deploy-the-azure-infrastructure)
2. [Reach the private resources (Bastion, SSH, DNS)](#2-reach-the-private-resources)
3. [Build the Oracle source](#3-build-the-oracle-source)
4. [Run the AI conversion](#4-run-the-ai-conversion)
5. [Move the data](#5-move-the-data)
6. [Validate](#6-validate)

**How to use this file.** Find the message you actually got, not the stage you think you are in — a "firewall" symptom at connect time is usually a deploy-time DNS or Bastion mistake. Every script writes full logs under `$LOG_DIR` (default `./out/logs`); the failing file's log path is printed in the error. Read that log before changing anything.

Two rules that save the most time:

- **`sqlplus` and `az` both exit 0 while leaving a broken result.** A package body that compiles with errors, and a model deployment that lands with the wrong SKU, are both "successes" to the exit code. Trust the report, not `$?`.
- **The scratch database is a second database on the same flexible server**, not a second server — so `SCRATCH_PGHOST` equals `PGHOST`. If you are looking for a separate scratch host, there isn't one.

---

## 0. `.env` and prerequisites

**Symptom:** a script dies immediately with `.env not found`.
**Cause:** you have not created your local env file. `.env` is gitignored and never committed.
**Fix:** `cp .env.example .env && chmod 600 .env`, then fill in the passwords (or set `USE_KEYVAULT=1`).

**Symptom:** `Cannot read .env - unquoted value(s) containing spaces`, or a bare `words: command not found` when a script starts.
**Cause:** the scripts source `.env` with the shell, so `FOUNDRY_RBAC_ROLE=Foundry User` sets `FOUNDRY_RBAC_ROLE=Foundry` and then runs `User`. Any value with a space, `(`, or `#` must be quoted.
**Fix:** single-quote the value: `FOUNDRY_RBAC_ROLE='Foundry User'`. The connect/seed scripts lint for this and name the offending line.

**Symptom:** `no password for Oracle user …` / `PGPASSWORD is not set`.
**Cause:** the matching `*_PASSWORD` is empty in `.env` and Key Vault indirection is off.
**Fix:** set the password in `.env`, or set `USE_KEYVAULT=1` with `AZ_KEYVAULT_NAME` and the `KV_SECRET_*` names populated.

**Symptom:** `az CLI is not logged in` / `docker not installed` / `psql not installed` / `jq is required`.
**Cause:** a client tool is missing. See `docs/00-prerequisites.md`.
**Fix:** `az login`; `brew install azure-cli jq`; `brew install libpq && brew link --force libpq` (or `postgresql@16`) for `psql`; Docker Desktop for the local Oracle path.

---

## 1. Deploy the Azure infrastructure

**Symptom:** deployment rejected — `Subscriptions are restricted from provisioning in this region` on the PostgreSQL flexible server.
**Cause:** flexible-server provisioning is gated per subscription per region. It is **not** an Azure Policy and quota will not show it. Some regions are simply closed to your subscription.
**Fix:** deploy to a region your subscription can actually provision Postgres in. This lab is validated in **swedencentral** (primary) and **uksouth** (fallback). Probe any candidate before committing:
```
az postgres flexible-server list-skus -l <region> --query "[0].reason" -o tsv
```
A non-null "restricted" reason means pick another region.

**Symptom:** VM creation fails with `SkuNotAvailable` / `NotAvailableForSubscription` for `Standard_D4s_v5`, even though `az vm list-usage` shows free cores.
**Cause:** **quota is not availability.** A family can show 100 free cores in a region where the specific SKU is not offered to your subscription at all.
**Fix:** check the SKU's restrictions directly, and move region or size if it is blocked:
```
az vm list-skus -l <region> --size Standard_D4s_v5 \
  --query "[?name=='Standard_D4s_v5'].restrictions[].reasonCode" -o tsv
```
Empty output means available. `D4s_v5` is verified available in swedencentral and uksouth; it was `NotAvailableForSubscription` in westeurope and westus3 during scouting. `preflight.sh` runs this probe for you — run it first.

**Symptom:** `preflight.sh` passes each VM but the deploy still fails on the second VM's cores.
**Cause:** the Oracle VM and the jumpbox both default to `Standard_D4s_v5`, i.e. the **same** `standardDSv5Family` pool. Two 4-vCPU VMs need **8** vCPU in one family; checking them independently reports two passing "4 free" lines and misses it. Per-family limits are the binding constraint, not the regional total.
**Fix:** current `preflight.sh` sums need per family — re-run it. If a family is short, request a quota increase, or set `ORACLE_VM_SIZE` / `JUMPBOX_VM_SIZE` to sizes in different families.

**Symptom:** the model deployment fails, or `az cognitiveservices` rejects the SKU.
**Cause:** on this subscription, **Provisioned / PTU capacity is denied by policy** (`OpenAI_BlockProvisionedCapacity`). A model offered in a region only as `GlobalProvisionedManaged` cannot be deployed here.
**Fix:** deploy the model as **`GlobalStandard`**, which is what `infra/main.bicep` asks for. The recommended 500,000 TPM (`foundryModelCapacity: 500`) fits inside a typical regional GlobalStandard quota with room to spare. If your region offers the model only as Provisioned, change region — do not switch the deployment to Provisioned.

> **Scouted, then deployed — 2026-09-02, one subscription.** On the subscription used to build this lab, Provisioned/PTU capacity was denied by a policy named `OpenAI_BlockProvisionedCapacity`, and `gpt-5.2` (version `2025-12-11`) and `gpt-5-mini` (version `2025-08-07`) were both available as GlobalStandard in swedencentral and uksouth. `gpt-5.2` was then **actually deployed** as GlobalStandard in swedencentral at version `2025-12-11` and reached `provisioningState` Succeeded — for that model in that region it is confirmed deployable, not merely listed. None of this is on either cited Learn page. Policy names are tenant-specific and model version strings churn, so treat the rest as *what one run saw on one date*, not as a specification. Ask your own subscription instead:
> ```
> az cognitiveservices account list-models -g <rg> -n <foundry-account> \
>   --query "[?name=='gpt-5.2'].{v:version, skus:skus[].name}" -o json
> ```

**Symptom:** the deployment succeeds, then the Oracle image pull and the VS Code Marketplace both hang and time out on the VMs.
**Cause:** neither VM has a public IP, and Azure retired **default outbound internet access** for new VNets in September 2025. Without an explicit egress path there is none, and it looks exactly like a firewall.
**Fix:** keep `deployNatGateway = true` (the default). If you set it false to bring your own egress, make sure that egress actually exists before you seed.

**Symptom:** `deploy.sh` sends a parameter and the deployment ignores it (e.g. a value you set never takes effect).
**Cause:** `deploy.sh` only sends parameters the compiled template declares; anything else is silently dropped. This is deliberate (renames degrade instead of erroring) but it hides typos.
**Fix:** confirm the name against `infra/main.bicep`. `az bicep build -f infra/main.bicep` then check the parameter list.

**Symptom:** `--what-if` or the deployment is rejected by RBAC / MFA, not by the template.
**Cause:** the subscription's management-group guardrails (MFA-on-write, deny initiatives) apply to your identity.
**Fix:** this is expected on a governed subscription and is not a template bug — authenticate with the required MFA and the role that can write to the resource group.

---

## 2. Reach the private resources

The flexible server has a delegated subnet and a private DNS zone, so it has **no public endpoint** and its FQDN resolves only inside the VNet. Everything reaches it through Bastion. Two hops for Postgres:

```
laptop --(az network bastion tunnel)--> Oracle VM:22 --(ssh -L)--> <pg fqdn>:5432
```

**Symptom:** `the Bastion tunnel process exited immediately`.
**Cause:** the Bastion host is the **Basic** SKU. Basic rejects native tunneling (`enableTunneling`); only **Standard** supports `az network bastion tunnel`.
**Fix:** deploy with `bastionSkuName = 'Standard'` (`deploy.sh` passes this; a direct `az deployment … main.bicepparam` with `AZ_BASTION_SKU=Basic` does not). To confirm / fix an existing host:
```
az network bastion show   --name <bastion> -g <rg> --query sku.name
az network bastion update --name <bastion> -g <rg> --enable-tunneling true
```

**Symptom:** `the port-forward did not open within 30s` / `the SSH port-forward exited immediately` when connecting to Postgres.
**Cause:** the Oracle VM (the jump host) cannot resolve or reach the flexible server — usually the private DNS zone is not linked to the VNet, so the FQDN resolves to nothing from inside.
**Fix:** open a shell on the VM and check name resolution:
```
scripts/connect.sh oracle-azure --shell
getent hosts <pg fqdn>     # must return a 10.x address
```
If it resolves to nothing, the `…private.postgres.database.azure.com` zone is not linked to the VNet — redeploy the network module (the Postgres module depends on the zone link for exactly this reason).

**Symptom:** `no SSH private key at generated/ssh/o2p-lab_ed25519`.
**Cause:** you are connecting from a machine that did not run `deploy.sh` (it generates the keypair), or your key lives elsewhere.
**Fix:** run `deploy.sh`, or set `SSH_KEY_PATH` in `.env` to your private key. There is no `.env` variable for the public key: `deploy.sh` generates the keypair itself at `generated/ssh/o2p-lab_ed25519` and passes the public half as the `oracleSshPublicKey` template parameter. To use your own key, replace both halves of that keypair before deploying — the VM only ever trusts the one that was passed at create time.

**Symptom:** `cannot find VM '…' in resource group '…'`, or `generated/outputs.json not found`.
**Cause:** the connect/seed scripts read connection details from `generated/outputs.json`, which `deploy.sh` writes at the end of a successful run.
**Fix:** run `deploy.sh` to completion first. If the VM name drifted, the scripts fall back to `az vm show`; check `az vm list -g <rg> -o table`.

**Symptom:** `psql could not connect`, or a certificate error only with `sslmode=verify-full`.
**Cause:** through the port-forward you connect to `127.0.0.1`, but the server certificate's CN is the FQDN — `verify-ca`/`verify-full` cannot match it.
**Fix:** the connect script downgrades to `sslmode=require` for the tunnel automatically (still encrypted, no hostname check). If you drive `psql` yourself through the tunnel, use `require`. If the password is wrong, or the database does not exist yet, connect to the `postgres` database instead and create it.

---

## 3. Build the Oracle source

**Symptom:** `no container named 'o2p-oracle'` / `container is 'exited', not running`.
**Cause:** the local Oracle container is not up. (The Azure path runs the same container **on the Oracle VM**; the local path runs it on your machine — see `docs/architecture.md`.)
**Fix:** start it per `docs/02-seed-oracle.md`; `docker start <name>`; `docker ps -a` to see what you have. The scripts also accept the legacy name `oracle-lab`.

**Symptom:** a `.sql` file "succeeds" but objects are missing or later files fail on a missing dependency.
**Cause:** `sqlplus` exits 0 even when a package body compiles with errors. The seed script reads the log as well as `$?`, but if you run SQL by hand you will miss it.
**Fix:** trust the seed report's `INVALID_OBJECTS` count, not the exit code. Recompile:
```
scripts/connect.sh oracle-local
EXEC UTL_RECOMP.RECOMP_SERIAL('CONTOSO');
```
then re-check `SELECT object_name FROM user_objects WHERE status='INVALID';`.

**Symptom:** the seed stops at one file with an `ORA-`/`PLS-` error.
**Cause:** a genuine DDL error; with error-on-stop (the default), every later file would fail too, so the first error is the real one.
**Fix:** read the named per-file log in full, fix the SQL, then resume without redoing earlier files: `scripts/seed-oracle.sh --<target> --from <failing-file>.sql`.

**Symptom:** VPD is missing and `12-security-context.sql` only warns (hard case H-40 degraded).
**Cause:** `EXECUTE ON SYS.DBMS_RLS` can only be granted by `SYS`; the seed makes that grant best-effort via `/ AS SYSDBA` inside the container and carries on if it cannot.
**Fix:** expected on images where the SYSDBA grant is unavailable — losing one hard case beats refusing to seed. If you need VPD, grant `EXECUTE ON SYS.DBMS_RLS` to `CONTOSO` as SYS and re-run `--from 12-…`.

**Symptom:** final object count is **short of the 1,000 floor** and `src/oracle/99-verify-objects.sql` fails.
**Cause:** most often `--no-generate` was used, or the generator did not run, so the ~792 generated objects are absent; or invalid objects are not counted.
**Fix:** run without `--no-generate` so `tools/generate-objects.py` fills `generated/`; recompile invalids (above). A correct build lands near **~1,855** objects (per-type design budget 1,120, hard floor 1,000) — landing at 1,001 means objects are missing, and it is a lab that fails on someone else's machine.

---

## 4. Run the AI conversion

The conversion is a feature of the **PostgreSQL extension for Visual Studio Code** (`ms-ossdata.vscode-pgsql`, 1.23.0+). Schema conversion is GA; application/code conversion is public preview.

**Symptom:** the conversion report looks clean but you do not trust it.
**Cause:** **`plpgsql_check` is fail-open.** If it is not in the `azure.extensions` allowlist, the tool skips its deeper validation with no error and no warning — a clean-looking report that was never checked.
**Fix:** allowlist it **before the first run**. `scripts/status.sh` reads the live `azure.extensions` parameter and reports `plpgsql_check` in red when it is absent — run it after every deploy and before every conversion. It also needs `shared_preload_libraries` + a server restart. There is no way to retro-fix a report produced without it; the run has to be repeated.

**Symptom:** converted `to_char`/`to_date`/`substr` behave like PostgreSQL, not Oracle, and results drift subtly.
**Cause:** `pg_catalog` is searched first, so the built-ins win over orafce's Oracle-compatible versions.
**Fix:** set the **database-level** `search_path` to include `oracle`, `topology`, `tiger` and the `dbms_*`/`plv*`/`utl_file` schemas (see `PG_SEARCH_PATH`), and call `oracle.to_char(...)` explicitly where Oracle semantics matter.

**Symptom:** partitioning / autonomous-transaction / `pg_partman` objects deploy but do nothing, or error at runtime.
**Cause:** the extension allowlist is incomplete. `pg_partman`, `pg_stat_statements`, `plpgsql_check` need `shared_preload_libraries` **and a restart**; `dblink` is needed on the **target** (CONTOSO uses `PRAGMA AUTONOMOUS_TRANSACTION`, H-02), not only on scratch.
**Fix:** apply the full allowlist from `design.md` §11.3 on **both** the target and the scratch server, then restart. `status.sh` warns when `plpgsql_check`/`dblink`/`orafce`/`pg_partman` are missing.

**Symptom:** the extension cannot find its scratch database, or writes `_mig_scratch_` schemas into the wrong place.
**Cause:** the scratch database was not created, or you pointed the tool at a separate host that does not exist.
**Fix:** the scratch is the `migration_scratch` database on the **same** flexible server — set `SCRATCH_PGHOST = PGHOST` and `SCRATCH_PGDATABASE = migration_scratch`. Azure HorizonDB is not supported as the scratch database (it is fine as a target).

**Symptom:** the Foundry role assignment does not let the tool call the model.
**Cause:** the required role name is unresolved upstream — current Foundry docs say **Foundry User**; DP-300 lab 18 says **Cognitive Services OpenAI User**.
**Fix:** grant whichever your portal offers on the Foundry account, and check both (`FOUNDRY_RBAC_ROLE` / `FOUNDRY_RBAC_ROLE_FALLBACK`).

**Symptom:** the tool throttles hard on the ~1,855-object schema.
**Cause:** model quota below the recommended 500,000 TPM.
**Fix:** deploy the model with `foundryModelCapacity: 500` (GlobalStandard); confirm the region's quota headroom with `az cognitiveservices usage list -l <region>`.

---

## 5. Move the data

**Symptom:** the schema and code converted, but the target tables are empty.
**Cause:** **the tool converts schema and code only — it does not copy rows.** This is by design, not a failure.
**Fix:** run the separate data step (`ora2pg`, `pgloader`, or a CDC tool). This lab uses `ora2pg` (`DATA_MOVE_TOOL`); see `docs/04-migrate-data.md`.

**Symptom:** the `store.legacy_migration_notes` `LONG` column breaks the data copy.
**Cause:** Oracle `LONG` is awkward for every extraction tool and is the reason the data step is not trivial (hard case H-33).
**Fix:** follow the `LONG`→`CLOB`/`text` handling in `docs/04-migrate-data.md`; do not assume a plain bulk copy will carry it.

---

## 6. Validate

**Symptom:** `src/oracle/99-verify-objects.sql` fails on invalid objects even though every file "ran".
**Cause:** invalid objects (compilation errors that `sqlplus` reported as exit 0), or cross-object dependencies compiled out of order.
**Fix:** `EXEC UTL_RECOMP.RECOMP_SERIAL('CONTOSO');` then re-verify. Any object still invalid has a real error in its per-file log.

**Symptom:** the generated object count differs between two machines.
**Cause:** `tools/generate-objects.py` ran with a different `GEN_SEED`, or a partial `generated/` was reused — cross-run diffs are then meaningless.
**Fix:** clear `generated/` and re-run with the fixed `GEN_SEED` (default `20260902`); the output must be byte-identical across machines.

**Symptom:** Oracle vs PostgreSQL business-question checks disagree on row counts or checksums.
**Cause:** a genuine conversion behaviour change — the H-30 / H-32 / H-38 queries are exactly where a conversion looks correct and is not (empty-string-is-NULL, `NULL` sort order, implicit conversion).
**Fix:** this is the finding, not a bug to hide. Record predicted vs observed per `design.md` §12.1, and correct `design.md` §9 where they disagree.

---

## Still stuck?

- Re-run `scripts/preflight.sh` (deploy-time) and `scripts/status.sh` (post-deploy) — between them they catch most quota, region, SKU, Bastion-tunneling and extension-allowlist problems before they become confusing runtime failures.
- The authoritative architecture and the 43 hard cases are in `docs/design.md`; the Azure topology is in `docs/architecture.md`.
- Every run leaves logs under `./out/logs`. The exact failing file and its log are always named in the error.
