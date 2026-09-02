# Contoso Store — Oracle to Azure Database for PostgreSQL migration lab

A deliberately awkward, ~1,820-object Oracle schema for a fictional multi-country retailer, and a
complete lab for putting it through the only currently supported Microsoft path to Azure Database
for PostgreSQL — the AI-assisted schema and code conversion built into the **PostgreSQL extension
for Visual Studio Code**. The schema is not a demo. It is twenty years of accreted retail ERP
rendered on purpose: autonomous transactions, compound triggers, `CONNECT BY` over four different
hierarchies, VPD policies, interval partitioning with primary keys that do not include the partition
key, and forty more constructs chosen because they have no clean PostgreSQL analogue. The point is
not to prove the tool works. The point is to find the seams, measure them, and write down honestly
what a human still has to do.

---

> ### Scope: what this lab does and does not claim
>
> **The Microsoft conversion tool converts schema and code. It does not copy a single table row.**
>
> That is scope, not a defect — but it means "we ran the migration tool" and "we migrated" are
> different statements. This lab therefore supplies its **own data-movement stage**
> (`ora2pg` by default) and treats it as a first-class step rather than an appendix. See
> [04 — Migrate the data](docs/04-migrate-data.md).
>
> **Schema conversion is generally available** as of extension v1.23.0 (2026-05-26).
> **Application and code conversion** — `.sql`, `.ctl`, `.sh`, `.load`, `.java` — is
> **public preview**. Both are used here; keep the distinction straight in your own notes.
>
> **There is no separate "Oracle to PostgreSQL" extension, and no product called a "migration
> copilot".** The conversion is a feature of the PostgreSQL extension for Visual Studio Code —
> extension ID `ms-ossdata.vscode-pgsql`, publisher Microsoft. It is powered by a **Microsoft
> Foundry** model deployment in your own subscription, plus **GitHub Copilot agent mode** for the
> flagged review tasks, which needs a Copilot **Pro+, Business or Enterprise** seat.
>
> This is a community lab. It is not a Microsoft product, and it is not endorsed by Microsoft or
> Oracle. See the [disclaimer](#disclaimer).

---

## Contents

- [Architecture](#architecture)
- [What you will learn](#what-you-will-learn)
- [What is in the schema](#what-is-in-the-schema)
- [Quickstart](#quickstart)
- [How long it takes](#how-long-it-takes)
- [What it costs](#what-it-costs)
- [Documentation](#documentation)
- [Repository layout](#repository-layout)
- [Contributing](#contributing)
- [Licence](#licence)
- [Disclaimer](#disclaimer)

---

## Architecture

The Oracle source runs on **an Azure VM inside the lab's virtual network, with no public IP,
reachable only through Azure Bastion**. That VM is standing in for the customer's on-premises
Oracle server, which is the entire scenario: migrating from a database on a server you control to a
managed PostgreSQL service.

```text
                  ┌───────────────────────────────────────────────────────┐
                  │  Microsoft Foundry        GitHub Copilot              │
                  │  gpt-5.2 / gpt-5-mini *   agent mode (review tasks)   │
                  │  (FOUNDRY_MODEL_NAME)                                 │
                  └──────────────┬───────────────────┬────────────────────┘
                                 │ https             │ https
   ══════════════════════════════╪═══════════════════╪══════════════════════════════
   Azure VNet  o2p-vnet          │  10.42.0.0/16     │
                                 │                   │
   ┌─────────────────────────────┴───────────────────┴─────────────────────────────┐
   │                                                                               │
   │   10.42.1.0/24                10.42.2.0/24              10.42.3.0/24          │
   │  ┌──────────────────┐       ┌──────────────────┐      ┌────────────────────┐  │
   │  │  o2p-oracle-vm   │       │    o2p-jump      │      │   o2p-pg-<uniq>    │  │
   │  │  ──────────────  │       │  ──────────────  │      │  ────────────────  │  │
   │  │  Ubuntu 22.04    │  read │  Windows x64     │ DDL  │  PostgreSQL 16     │  │
   │  │  Oracle Free     │◀──────│  VS Code +       │─────▶│  flexible server   │  │
   │  │  23ai (docker)   │ meta  │  ms-ossdata.     │      │                    │  │
   │  │  schema CONTOSO  │ data  │  vscode-pgsql    │      │  contoso_store     │  │
   │  │  ~1,820 objects  │       │                  │      │  migration_scratch │  │
   │  │                  │       │                  │      │                    │  │
   │  │  NO PUBLIC IP    │       │  NO PUBLIC IP    │      │  private endpoint  │  │
   │  │  ▲ simulated     │       │                  │      │  no public access  │  │
   │  │  │ on-premises   │       │                  │      │                    │  │
   │  └──┼───────────────┘       └────────┬─────────┘      └────────────────────┘  │
   │     │                                │                                        │
   │     │        ┌───────────────────────┴──────────────────────────┐             │
   │     └────────│  10.42.4.0/26  AzureBastionSubnet → o2p-bastion  │             │
   │              │  SSH to the Oracle VM · RDP to the jumpbox       │             │
   │              └──────────────────────────┬───────────────────────┘             │
   │                                         │                                     │
   │              ┌──────────────────────────┴───────────────────────┐             │
   │              │  NAT gateway + public IP                         │             │
   │              │  the only outbound path — no VM has a public IP  │             │
   │              └──────────────────────────────────────────────────┘             │
   └───────────────────────────────────────────────────────────────────────────────┘
                                         │
                                    ┌────┴─────┐
                                    │   you    │  browser RDP / az network bastion
                                    └──────────┘
```

Two things about that diagram are load-bearing:

<sup>\*</sup> **`gpt-5.2` is verified deployable; the two sources still differ on which model to use.**
The Learn-documented `gpt-5.2` was confirmed real and deployable in Sweden Central on 2026-09-02 —
preflight found free quota for it and the deployment created it at version `2025-12-11`. Microsoft's
own `mslearn-postgresql` lab template still defaults to `gpt-5-mini`, so which model to *use* remains
yours to choose. It is the `FOUNDRY_MODEL_NAME` parameter, defaulting to `gpt-5.2` to follow Learn;
availability varies by region, so `preflight.sh` checks it. See
[the cost note below](#what-it-costs) and [00 — Prerequisites](docs/00-prerequisites.md#4-quota).

**The Oracle VM is the point.** Not a managed Oracle service. You get full control of the instance —
`sessions`, a filesystem `DIRECTORY` for `UTL_FILE`, `DBMS_RLS` policies — and a realistic private
network between client and source. A managed service would refuse half of what the schema needs, and
would not resemble what you are actually migrating away from. The reasoning is in
[architecture.md](docs/architecture.md#2-why-an-oracle-vm-and-not-a-managed-service).

**There are two PostgreSQL databases.** `contoso_store` is the target. `migration_scratch` is where
the tool creates and drops `_mig_scratch_*` schemas to *compile* what it produced and run
`plpgsql_check` over it. Without a scratch database there is no compile step and no validation —
just a language model's guess written to a file.

> **Alternative: local Docker.** `./scripts/seed-oracle.sh --local` runs the same Oracle schema in a
> container on your machine. It is genuinely useful for iterating on SQL and for CI, and it is
> cheap. It also exercises none of the network story — no Bastion, no private endpoint, no NSG, no
> realistic latency between the client and the source. Use it to get the schema right; use the VM
> for the actual lab.

---

## What you will learn

- How the AI-assisted conversion in `ms-ossdata.vscode-pgsql` actually works — hybrid rule-based
  parsing, LLM translation, **compilation in a scratch database**, `plpgsql_check` validation, and an
  automated fix loop — and where each stage stops being able to help.
- Which Oracle constructs convert cleanly, which convert *plausibly but wrongly*, and which come back
  as review tasks needing a human. The lab publishes its predictions up front so you can score them.
- Why `plpgsql_check` being **fail-open** is the most dangerous configuration mistake in this whole
  pipeline: leave it off the extension allowlist and the tool silently skips deep validation, with no
  error and no warning in the report.
- Why `pg_catalog` always winning the search path means `to_char` is quietly *not* orafce's
  `to_char`, and what that does to your formatted output.
- How to configure Azure Database for PostgreSQL flexible server for a migration target: the
  `azure.extensions` allowlist, `shared_preload_libraries`, and the restart that is easy to skip.
- Where the human stays in the loop, and why "the AI said it was fine" is not evidence — including
  Microsoft's own unusually candid caveat about it.
- That the tool does not move data, and what it costs you to close that gap yourself.

---

## What is in the schema

`CONTOSO` is a retail ERP for a chain of ~1,400 stores across 11 countries: product catalogue,
stores, inventory, customers, loyalty, orders, fulfilment, returns, pricing and promotions,
suppliers, purchase orders, and a general ledger.

| Object type | Hand-written | Generated | Total |
| --- | ---: | ---: | ---: |
| `VIEW` | 18 | 180 | 198 |
| `SYNONYM` | 24 | 150 | 174 |
| `FUNCTION` | 12 | 120 | 132 |
| `PROCEDURE` | 10 | 100 | 110 |
| `PACKAGE` | 25 | 60 | 85 |
| `PACKAGE BODY` | 25 | 60 | 85 |
| `INDEX` | 78 | 0 | 78 |
| `SEQUENCE` | 24 | 50 | 74 |
| `TRIGGER` | 26 | 40 | 66 |
| `TABLE` | 64 | 0 | 64 |
| `TYPE` | 18 | 0 | 18 |
| `TYPE BODY` | 8 | 0 | 8 |
| `MATERIALIZED VIEW` | 6 | 0 | 6 |
| `JOB` | 6 | 0 | 6 |
| `PROGRAM` | 3 | 0 | 3 |
| `SCHEDULE` | 3 | 0 | 3 |
| **Total (design minimum)** | **350** | **760** | **1,110** |

Those are the per-type minimums the build guarantees. A loaded `CONTOSO` runs larger — about
**1,820 objects** by the rule the lab asserts, because the real count of nearly every type exceeds
its minimum:

```sql
SELECT COUNT(*) FROM user_objects
 WHERE object_type NOT IN ('LOB','TABLE PARTITION','INDEX PARTITION','LOB PARTITION');
```

About **1,450** of those are non-partition objects; the rest are subpartitions of the
composite-partitioned `inventory_movement`, so that slice of the count drifts with data volume. The
binding requirement is the **1,000-object floor**, cleared with wide headroom.

The 350 hand-written objects form a coherent, believable domain and carry **43 hard migration cases**
plus **14 additional traps**. The 760 generated objects come from a deterministic, seeded generator
(`tools/generate-objects.py`) and exist to prove the converter still behaves at scale — about 15% of
them deliberately embed a hard case, so scale testing stresses the difficult paths rather than 760
copies of an easy template.

A sample of what is in there, and what the lab predicts will happen to it:

| Case | Construct | Prediction |
| --- | --- | --- |
| H-02 | `PRAGMA AUTONOMOUS_TRANSACTION` | Review task — needs `dblink` on the **target**, or a redesign |
| H-19 | Interval range partitioning with a PK that excludes the partition key | Partial — PostgreSQL flatly refuses; the PK must widen and every FK follows |
| H-26 | Compound triggers | Review task — the mutating-table problem they solve does not exist in PostgreSQL |
| H-30 | `ROWNUM` versus `ROW_NUMBER()` | Partial — the naive `LIMIT` conversion returns a *different set of rows* |
| H-38 | Empty string is `NULL` | Review task — nothing fails, rows just quietly move to the other side of `IS NULL` |
| H-15 | Fast-refresh materialised views and a refresh group | Review task — PostgreSQL has no incremental refresh at all |

Overall prediction: **10 clean, 21 partial, 12 review task**. All 43, with the reasoning for each,
are in [`docs/design.md`](docs/design.md) section 9. When observation disagrees with prediction, the
observation wins and the prediction gets corrected.

---

## Quickstart

You need an Azure subscription, a GitHub Copilot **Pro+/Business/Enterprise** seat, and VS Code
1.95.2+. Full list: [00 — Prerequisites](docs/00-prerequisites.md).

```bash
# 1. Clone
git clone https://github.com/<your-fork>/oracle-to-postgres-migration-lab.git
cd oracle-to-postgres-migration-lab

# 2. Configure. Replace every replace-me-* and changeme value.
cp .env.example .env
chmod 600 .env
$EDITOR .env

# 3. Check everything before spending money. Free, ~1 minute.
#    Collects every failure and prints the command that fixes each one.
./scripts/preflight.sh

# 4. Preview the deployment. Creates nothing, costs nothing.
./scripts/deploy.sh --what-if

# 5. Deploy. ~20-30 minutes. THIS STARTS THE METER.
./scripts/deploy.sh

# 6. Build the Oracle source. ~35-50 minutes at the default scale;
#    use --scale 0.01 for a ~7 minute smoke test first.
./scripts/seed-oracle.sh --azure --scale 1

# 7. Run the conversion -> docs/03-run-ai-migration.md

# 8. WHEN YOU STOP FOR THE DAY:
./scripts/destroy.sh
```

Between steps 5 and 6, give the Oracle VM 10 to 20 minutes: cloud-init is pulling a multi-gigabyte
container image and creating the database. `ssh … 'sudo cloud-init status --wait'` tells you when it
is done.

---

## How long it takes

Realistic, assuming things mostly work. First time through, add reading time.

| Stage | Doc | Hands-on | Waiting | Notes |
| --- | --- | --- | --- | --- |
| Prerequisites | [00](docs/00-prerequisites.md) | 20–30 min | 0–24 h | Quota increases and Copilot licensing are the long poles |
| Preflight | [01](docs/01-deploy-infrastructure.md) | 2 min | 1 min | Free. Do not skip it |
| Deploy infrastructure | [01](docs/01-deploy-infrastructure.md) | 5 min | 20–30 min | Bastion and the PostgreSQL restart dominate |
| Oracle first boot | [01](docs/01-deploy-infrastructure.md) | 0 | 10–20 min | cloud-init pulls the image and creates the database |
| Post-deploy config | [01](docs/01-deploy-infrastructure.md) | 10 min | 2 min | Extensions, the Foundry role assignment, outputs into `.env` |
| Seed Oracle (`--scale 0.01`) | [02](docs/02-seed-oracle.md) | 2 min | 6–9 min | Smoke test |
| Seed Oracle (`--scale 1`) | [02](docs/02-seed-oracle.md) | 2 min | 35–50 min | The real thing |
| Client setup | [00](docs/00-prerequisites.md) | 20 min | 10 min | VS Code + extension + Copilot sign-in on the jumpbox |
| Run the conversion | [03](docs/03-run-ai-migration.md) | 15 min | 45–90 min | ~1,450 convertible objects at 500,000 TPM. Much longer on lower quota |
| Work the review tasks | [03](docs/03-run-ai-migration.md) | **3–8 h** | — | The actual lab. Roughly a dozen genuinely hard items |
| Migrate the data | [04](docs/04-migrate-data.md) | 20 min | 30–90 min | `ora2pg` at scale 1. The `LONG` column will cost you some of this |
| Validate | [05](docs/05-validate.md) | 1–2 h | 15 min | Differential testing is where the interesting findings are |

**Realistic total:** a full working day to get through it once at `--scale 1`, and closer to two days
if you actually read the review tasks rather than accepting them. A smoke-test pass at
`--scale 0.01`, skipping the review-task work, is about **three hours**.

---

## What it costs

Approximate **USD, pay-as-you-go, Sweden Central, September 2026**. Your prices will differ by
region, currency, and any agreement you are under. Use the
[Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) for anything you would
put in a budget.

| Resource | SKU | Per hour | **Per day (24 h)** |
| --- | --- | ---: | ---: |
| Oracle VM | `Standard_D4s_v5`, Linux | $0.19 | **$4.61** |
| Windows jumpbox | `Standard_D4s_v5`, Windows (licence included) | $0.37 | **$8.90** |
| PostgreSQL flexible server | `Standard_D4ds_v5`, General Purpose, 4 vCore | $0.27 | **$6.43** |
| Azure Bastion | **Standard** (Basic cannot tunnel — see below) | $0.29 | **$6.96** |
| Managed disks | 3 × Premium SSD, ~320 GiB total | — | **$1.75** |
| PostgreSQL storage | 128 GiB + 7-day backups | — | **$0.60** |
| NAT gateway | Gateway hours + data processing | $0.045 | **$1.08** |
| Public IP addresses | 2 × Standard static (Bastion, NAT) | — | **$0.24** |
| Private DNS zone | 1 zone, low query volume | — | **$0.02** |
| | | | **≈ $31 / day** |

**Why Standard Bastion, and not Basic.** The Basic SKU rejects native client tunneling
(`enableTunneling`), and `az network bastion tunnel` is how `scripts/connect.sh` and
`scripts/seed-oracle.sh --azure` reach the Oracle VM and the VNet-private PostgreSQL server. Basic
would make both unusable, so `deploy.sh` passes `Standard` (`AZ_BASTION_SKU`). It costs $0.10/hour
more than Basic — about $73 over a 30-day month — and it is not optional.

| Also | Basis | Estimate |
| --- | --- | --- |
| Microsoft Foundry tokens | Consumption, **per conversion run** | **$5–30** with `gpt-5.2`; roughly a tenth of that with `gpt-5-mini` |
| GitHub Copilot | Per seat, per month | $19–39, and you probably already pay it |

The Foundry line is the only usage-based one: you pay per token, not per hour, so an idle deployment
costs nothing. Everything else in the first table bills for existing.

| Scenario | Per day | Per 30 days |
| --- | ---: | ---: |
| Lab running 24/7 | ~$31 | **~$920** |
| Paused overnight — VMs deallocated, PostgreSQL stopped | ~$10 | ~$290 |
| Destroyed | **$0** | **$0** |

### Turn it off

> ## `./scripts/destroy.sh`
>
> **Run this whenever you stop working.** It shows you what is in the resource group, makes you type
> the group name to confirm, deletes it, and — with `--purge` — clears the soft-deleted Key Vault and
> Foundry account whose reserved names would otherwise break your next deployment with a confusing
> "name is already in use".
>
> It touches nothing local. Your `.env`, `generated/`, `out/` and any local Docker container all
> survive.

Pausing instead, if you want to keep the seeded database for tomorrow:

```bash
az vm deallocate --resource-group "$AZ_RESOURCE_GROUP" --name o2p-oracle-vm
az vm deallocate --resource-group "$AZ_RESOURCE_GROUP" --name o2p-jump
az postgres flexible-server stop --resource-group "$AZ_RESOURCE_GROUP" \
  --name "$(jq -r .postgresServerName generated/outputs.json)"
```

Three honest caveats: **deallocate**, not shut down from inside the guest (a guest-stopped VM keeps
billing); **Azure Bastion cannot be stopped** and bills ~$6.96/day at the Standard SKU for merely
existing; and a stopped flexible server **auto-starts after 7 days**. If you are pausing for more
than a couple of days, destroying and redeploying is cheaper — redeploy is 20–30 minutes plus a
re-seed.

---

## Documentation

| Document | What it covers |
| --- | --- |
| [00 — Prerequisites](docs/00-prerequisites.md) | Azure subscription, resource providers, quota, permissions, Copilot tiers, VS Code, the OS support matrix and its ARM64 caveat, network egress |
| [01 — Deploy the infrastructure](docs/01-deploy-infrastructure.md) | `preflight.sh` and `deploy.sh` walkthrough, every resource and why it is configured that way, the extension allowlist, `shared_preload_libraries` and the restart, verification, teardown |
| [02 — Seed the Oracle source](docs/02-seed-oracle.md) | The generators, `--scale` and what each costs in time and disk, running the seed, proving the object count crossed 1,000, reset and re-seed |
| [03 — Run the AI migration](docs/03-run-ai-migration.md) | Driving the extension, GA scope versus preview scope, and working the flagged review-task queue with Copilot agent mode |
| [04 — Migrate the data](docs/04-migrate-data.md) | The row-copy step the conversion tool does not do — `ora2pg`, and why one `LONG` column makes it interesting |
| [05 — Validate](docs/05-validate.md) | Differential testing: proving the converted database answers the same questions as the source |
| [Architecture](docs/architecture.md) | Why an Oracle VM, why a separate scratch database, how the conversion pipeline really works, and where the human stays in the loop |
| [Design contract](docs/design.md) | The binding specification: naming, the full table catalogue, all 43 hard cases with predictions, the object budget |
| [Troubleshooting](docs/troubleshooting.md) | Symptom → cause → fix, across every stage |
| [Lab status](docs/lab-status.md) | **Read before spending money.** What has been verified by actual execution versus what is written but untested — the Azure infrastructure has now been deployed for real once and torn down (2026-09-02), but the conversion run itself still never has |

---

## Repository layout

```text
oracle-to-postgres-migration-lab/
├── docs/          this documentation, plus design.md — the binding contract
├── infra/         Bicep: VNet, Oracle VM, PostgreSQL flexible server, Foundry, jumpbox, Bastion
├── scripts/       bash drivers: preflight.sh, deploy.sh, seed-oracle.sh, connect.sh, status.sh, destroy.sh
├── src/oracle/    the hand-written CONTOSO schema, numbered 00 → 13, plus 99-verify-objects.sql
├── tools/         generate-objects.py, generate-data.py — stdlib only, no pip install — and ora2pg.conf
├── tests/         assertions run against Oracle, plus the repository's static checks
├── generated/     gitignored — generator output lands in generated/oracle/ and generated/oracle/data/,
│                  deployment outputs in generated/outputs.json
└── out/           gitignored — logs, converted DDL, conversion reports
```

---

## Contributing

Contributions are welcome, particularly **findings**: a hard case that behaved differently from the
prediction is more valuable than a new feature.

- Read [`docs/design.md`](docs/design.md) first. It is the binding contract; if your change disagrees
  with it, change that document in the same pull request and say why.
- Shell scripts: `bash`, `set -euo pipefail`, executable, must pass `bash -n`. macOS ships bash 3.2,
  so no associative arrays and no GNU-only flags without a fallback.
- File names are kebab-case. SQL files carry a two-digit ordinal and a dash.
- **No secrets, ever.** No real tenant IDs, subscription IDs, endpoints, resource names or passwords
  in any committed file. Every variable belongs in `.env.example` with a placeholder.
- The generators must stay byte-for-byte deterministic and standard-library only. Cross-run diffs of
  the conversion report are the whole point; a dependency that changes its float formatting between
  releases breaks that silently.
- Where Microsoft's own sources contradict each other — and two of them do, on the model name and on
  the RBAC role — record the conflict rather than quietly picking a side.

---

## Licence

MIT. See [LICENSE](LICENSE).

---

## Disclaimer

This is an independent **community lab**. It is **not an official Microsoft product**, is not
supported by Microsoft, and is not affiliated with or endorsed by Microsoft or Oracle. Microsoft,
Azure, Visual Studio Code, GitHub Copilot, Oracle and PL/SQL are trademarks of their respective
owners. "Contoso Store" is fictional; every name, address and row in this repository is synthetic.

Product facts here — extension IDs, GA and preview status, version numbers, supported source
versions, extension allowlists, RBAC role names, model names — were verified on **2026-09-02** and
this area moves quickly. Two of them were, on that date, genuinely contradictory in Microsoft's own
published material (the Foundry model name and the RBAC role), and the lab records both rather than
resolving them for you. Check the primary sources before you rely on anything here for a real
migration:

- [Schema conversion overview](https://learn.microsoft.com/en-us/azure/postgresql/migrate/oracle-conversions-schema/schema-conversions-overview)
- [Oracle migration with the VS Code extension](https://learn.microsoft.com/en-us/azure/postgresql/development/vs-code-extension/oracle-migration)

Running this lab **creates billable Azure resources**. You are responsible for what it costs. Read
[What it costs](#what-it-costs), and run `./scripts/destroy.sh` when you are done.
