# 00 — Prerequisites

Everything you need before `scripts/deploy.sh` spends any money.

Work through the checklist, then run `scripts/preflight.sh`. Preflight checks most of this
automatically and prints the exact command that fixes each failure, so treat this page as the
explanation and preflight as the enforcement.

- [Time and money](#time-and-money)
- [1. The checklist](#1-the-checklist)
- [2. Azure subscription](#2-azure-subscription)
- [3. Resource providers](#3-resource-providers)
- [4. Quota](#4-quota)
- [5. Permissions](#5-permissions)
- [6. GitHub Copilot](#6-github-copilot)
- [7. Visual Studio Code and the extension](#7-visual-studio-code-and-the-extension)
- [8. Client operating system support](#8-client-operating-system-support)
- [9. Network egress](#9-network-egress)
- [10. Local tooling](#10-local-tooling)
- [11. Oracle source facts you should know up front](#11-oracle-source-facts-you-should-know-up-front)
- [12. Configure `.env`](#12-configure-env)
- [13. Run preflight](#13-run-preflight)

---

## Time and money

Reading and satisfying this page takes **30 to 60 minutes** the first time, most of it waiting for
quota or Copilot licensing rather than typing. Nothing on this page is billable except the Copilot
seat, which you probably already have.

The moment you run `scripts/deploy.sh` the meter starts. See the cost table in
[the README](../README.md#what-it-costs) and keep `scripts/destroy.sh` within reach.

---

## 1. The checklist

Tick these off. Everything is expanded below.

**Azure**

- [ ] An Azure subscription you can create resources in, and its ID.
- [ ] Resource providers registered: `Microsoft.Compute`, `Microsoft.Network`,
      `Microsoft.DBforPostgreSQL`, `Microsoft.CognitiveServices`.
- [ ] A region that offers both PostgreSQL flexible server and your chosen Foundry model.
- [ ] 8 vCPUs of `Standard DSv5 Family` quota, plus regional headroom.
- [ ] 4 vCores of Azure Database for PostgreSQL flexible server quota.
- [ ] 500,000 TPM of Microsoft Foundry quota for the model you deploy.
- [ ] Rights to create a role assignment (Owner, or Contributor plus User Access Administrator).

**AI and client**

- [ ] GitHub Copilot **Pro+**, **Business** or **Enterprise**. Free and plain Pro are not enough.
- [ ] Visual Studio Code **1.95.2** or later.
- [ ] The **PostgreSQL extension for Visual Studio Code** (`ms-ossdata.vscode-pgsql`), **v1.23.0**
      or later.
- [ ] A supported client OS — see [the matrix](#8-client-operating-system-support). If you are on
      Apple Silicon or Windows ARM64, plan to use the lab's Windows jumpbox.
- [ ] Outbound network access to four destinations, one of which is easy to miss.

**Local machine**

- [ ] Azure CLI (`az`) 2.60 or later, logged in, with the Bicep tooling installed.
- [ ] `jq`, `ssh-keygen`, `base64`, `bash` 3.2 or later.
- [ ] Python **3.9+** (standard library only — there is nothing to `pip install`).
- [ ] Docker, only if you intend to run the Oracle source locally instead of on the Azure VM.
- [ ] `.env` created from `.env.example`, with every placeholder replaced, mode `0600`.

---

## 2. Azure subscription

Any subscription type works, including Visual Studio credit and pay-as-you-go. A free trial does
**not**, because it caps you at 4 vCPUs total and this lab needs at least 8 plus PostgreSQL vCores.

```bash
az login
az account show --output table
az account set --subscription "<your-subscription-id>"
```

Put the ID in `.env` as `AZ_SUBSCRIPTION_ID`. Preflight refuses to continue if the CLI's selected
subscription is not the one you configured — this is deliberate. `scripts/destroy.sh` deletes an
entire resource group, and it should never be able to delete one in a subscription you did not
name.

> This is a public repository. Do not paste a real subscription ID or tenant ID back into
> `.env.example`, into a doc, or into a commit message. `.env` is gitignored; keep it that way.

### Region

The default is `swedencentral`. Two things constrain the choice:

1. Azure Database for PostgreSQL flexible server must be available with the `Standard_D4ds_v5` SKU.
2. Your Foundry model must be available **and have quota** in the region.

Model availability is the binding constraint far more often than compute is. Check before you
commit to a region:

```bash
# Regions your subscription can use at all
az account list-locations --query "[].name" --output tsv | sort

# PostgreSQL flexible server SKUs in that region
az postgres flexible-server list-skus --location swedencentral --output table

# Models Foundry can deploy in that region
az cognitiveservices model list --location swedencentral \
  --query "[].{model:model.name, version:model.version, format:model.format}" --output table
```

If your preferred model is not listed, you can put the Foundry account in a different region from
the rest of the lab by setting `FOUNDRY_LOCATION`. The extension talks to the Foundry endpoint over
the public internet, so cross-region is fine; you pay a little latency, nothing else.

---

## 3. Resource providers

Four providers must be in state `Registered` on the subscription. Registration is free, takes a
couple of minutes, and only has to be done once per subscription.

| Provider | What the lab uses it for |
| --- | --- |
| `Microsoft.Compute` | The Oracle VM, the Windows jumpbox, their managed disks |
| `Microsoft.Network` | Virtual network, subnets, NSGs, NAT gateway, Azure Bastion, private DNS |
| `Microsoft.DBforPostgreSQL` | The Azure Database for PostgreSQL flexible server |
| `Microsoft.CognitiveServices` | The Microsoft Foundry account and the model deployment |

Check all four:

```bash
for ns in Microsoft.Compute Microsoft.Network Microsoft.DBforPostgreSQL Microsoft.CognitiveServices; do
  printf '%-32s %s\n' "$ns" "$(az provider show --namespace "$ns" --query registrationState -o tsv)"
done
```

Register any that are not `Registered`:

```bash
az provider register --namespace Microsoft.DBforPostgreSQL --wait
```

`scripts/preflight.sh --fix` registers all four for you. It never creates a billable resource, so
`--fix` is safe to run.

> If you set `USE_KEYVAULT=1` in `.env`, you also need `Microsoft.KeyVault` registered. It is not
> in the required four because the lab works fine with passwords held only in your local `.env`.

---

## 4. Quota

Quota failures are the single most common reason a first deployment dies twenty minutes in, with a
`QuotaExceeded` error attached to a half-built resource group that is already billing. Check first.

| What | Quota counter | Needed | How to check |
| --- | --- | ---: | --- |
| Oracle VM (`Standard_D4s_v5`) | Standard DSv5 Family vCPUs | 4 | `az vm list-usage` |
| Windows jumpbox (`Standard_D4s_v5`) | Standard DSv5 Family vCPUs | 4 | `az vm list-usage` |
| Both VMs together | Total Regional vCPUs | 8 | `az vm list-usage` |
| PostgreSQL flexible server (`Standard_D4ds_v5`) | PostgreSQL flexible server vCores | 4 | portal, see below |
| Foundry model deployment | Tokens per minute for the model | 500,000 | `az cognitiveservices usage list` |
| Bastion and NAT gateway addresses | Static Public IP Addresses | 2 | `az network list-usages` |

```bash
# VM vCPU quota, filtered to what matters
az vm list-usage --location swedencentral --output table \
  | grep -Ei 'Total Regional vCPUs|Standard DSv5'

# Public IP quota
az network list-usages --location swedencentral --output table | grep -i 'Public IP'

# Foundry token-per-minute quota, per model family
az cognitiveservices usage list --location swedencentral --output table
```

Azure Database for PostgreSQL vCore quota has no first-class CLI query. Read it in the portal under
**Subscriptions → your subscription → Usage + quotas**, filtered by provider
*Azure Database for PostgreSQL*. If the SKU appears in `az postgres flexible-server list-skus` you
are usually fine; a brand-new subscription occasionally starts at zero vCores for the General
Purpose tier.

### Foundry TPM: why 500,000

The CONTOSO schema is roughly 1,855 objects, several of them 400-line package bodies. Each
convertible object is at least one model round trip, and flagged objects get several. At 500,000 TPM
a full conversion
run is throughput-bound on the tool, not on the model. Below about 100,000 TPM the run spends most
of its time in retry backoff and can take hours instead of tens of minutes — it still finishes, it
is just a miserable way to spend an afternoon.

`FOUNDRY_TPM_QUOTA=500000` in `.env` becomes `foundryModelCapacity = 500` in the Bicep template
(the template counts in thousands). If your subscription cannot get 500, lower it and expect the
run to take proportionally longer.

### Which model

Microsoft's own material names two different models. This is no longer a question of whether the
Learn-documented one is real:

| Source | Model |
| --- | --- |
| Microsoft Learn, schema conversion documentation | `gpt-5.2` |
| Microsoft's own `mslearn-postgresql` lab ARM template | `gpt-5-mini` |

**`gpt-5.2` is verified deployable in `swedencentral` as of 2026-09-02** — preflight found
`OpenAI.GlobalStandard.gpt-5.2: 1000/1000 kTPM free` there, and a real deployment created it at
version `2025-12-11`. What the two sources still disagree on is which to *use*, so the lab makes it a
parameter: `FOUNDRY_MODEL_NAME` defaults to `gpt-5.2`, following Learn. Set it to `gpt-5-mini` if you
want to match the official sample, or if `gpt-5.2` has no quota in your region — **model
availability varies by region, which is exactly why preflight checks it** before you deploy. Write
down which one you used — conversion results are not comparable across models, so the model name
belongs at the top of any results you record in [05 — Validate](05-validate.md).

---

## 5. Permissions

You need enough rights to create resources **and** to create a role assignment, because the reader
account has to be granted access to the Foundry deployment.

| Role | Scope | Why |
| --- | --- | --- |
| Owner | Subscription or resource group | Simplest: covers both needs |
| Contributor **plus** User Access Administrator | Subscription or resource group | Same effect, least privilege |
| Contributor alone | — | Not enough. Creates everything, then fails at the role assignment |

```bash
MY_ID="$(az ad signed-in-user show --query id -o tsv)"
az role assignment list --assignee "$MY_ID" --all \
  --query "[].{role:roleDefinitionName, scope:scope}" --output table
```

### The Foundry data-plane role, and the second unresolved conflict

Creating the Foundry account is a control-plane action. *Using* it from VS Code is a data-plane
action and needs a separate role assignment on the account:

| Source | Role name |
| --- | --- |
| Current Microsoft Foundry documentation | **Foundry User** |
| DP-300 lab 18 | **Cognitive Services OpenAI User** |

Nobody upstream has reconciled these. Grant whichever your portal offers you. If both appear, grant
both — they are additive and neither is expensive.

```bash
FOUNDRY_ID="$(jq -r .foundryAccountId generated/outputs.json)"   # after deploy
az role assignment create \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --role "Foundry User" \
  --scope "$FOUNDRY_ID"
```

If that fails with "role not found", retry with `--role "Cognitive Services OpenAI User"`. Both
names are already in `.env` as `FOUNDRY_RBAC_ROLE` and `FOUNDRY_RBAC_ROLE_FALLBACK` so the scripts
can try them in order.

Role assignments take a minute or two to propagate. A conversion run that fails with a 401 or 403
thirty seconds after you granted the role is usually just early.

---

## 6. GitHub Copilot

The conversion tool uses two AI services, not one:

1. **A Microsoft Foundry model deployment** does the bulk translation. You deploy this yourself, in
   your own subscription, and pay for the tokens.
2. **GitHub Copilot agent mode** resolves the flagged *review tasks* — the items the tool could not
   translate confidently and handed back for interactive work.

Copilot is not optional if you want to finish the lab, because a meaningful fraction of CONTOSO is
designed to come back as review tasks. That is the point of the schema.

| Copilot plan | Works for this lab |
| --- | --- |
| Copilot Free | No |
| Copilot Pro | No |
| **Copilot Pro+** | Yes |
| **Copilot Business** | Yes |
| **Copilot Enterprise** | Yes |

Check your plan at <https://github.com/settings/copilot>. On Business and Enterprise, agent mode
must also be enabled by an organisation administrator in the Copilot policy settings — if agent
mode is missing from the Copilot Chat dropdown in VS Code and your seat is Business, that policy is
the first place to look.

Set `COPILOT_PLAN` in `.env` to the plan you actually hold so the preflight can warn you rather
than letting you discover it in stage 3.

---

## 7. Visual Studio Code and the extension

There is exactly one supported Oracle to Azure Database for PostgreSQL conversion path, and it is a
feature of a general-purpose PostgreSQL extension. There is **no** separate "Oracle to PostgreSQL"
extension, and nothing called a "migration copilot".

| Item | Requirement |
| --- | --- |
| Visual Studio Code | 1.95.2 or later |
| Extension | **PostgreSQL extension for Visual Studio Code** |
| Extension ID | `ms-ossdata.vscode-pgsql` |
| Publisher | Microsoft |
| Minimum version | **1.23.0** |

```bash
code --version
code --install-extension ms-ossdata.vscode-pgsql
code --list-extensions --show-versions | grep ms-ossdata
```

### GA and preview, stated precisely

- **Schema conversion is generally available**, from extension **v1.23.0 (2026-05-26)**.
- **Application and code conversion** — `.sql`, `.ctl`, `.sh`, `.load` and `.java` files — is
  **public preview**.

Both halves are used in this lab. Keep the distinction straight in your own notes: a defect in a
GA feature is a support case, a defect in a preview feature is feedback.

### What is not the answer

Older material will point you at tools that cannot do this job. For the avoidance of doubt:

| Tool | Status for Oracle to Azure PostgreSQL |
| --- | --- |
| Azure Data Studio | Retired 28 February 2026 |
| SQL Server Migration Assistant (SSMA) for Oracle | Targets the SQL Server family only; PostgreSQL is not a target |
| Azure Database Migration Service | Does not support Oracle to PostgreSQL at all |
| In-portal "Migration service in Azure Database for PostgreSQL" | PostgreSQL sources only |

---

## 8. Client operating system support

This matters more than it looks, because the extension's conversion feature includes a native
component.

| Platform | Supported | Note |
| --- | --- | --- |
| Windows x64 | Yes | What the lab's jumpbox runs. The safest choice. |
| Windows ARM64 | **No** | Not supported. |
| Linux x64 | Yes | |
| Linux ARM64 | **No** | Not supported. |
| macOS 13+ (Intel) | Documented as supported | See the caveat below. |
| macOS 13+ (Apple Silicon) | Documented as supported, but risky | See the caveat below. |

**The caveat.** The extension's platform list includes macOS 13+, but the overview page's
description of the thick-client component says "Windows and Linux only". Those two statements
cannot both be complete. Apple Silicon sits exactly on the seam: it is ARM64, and ARM64 is
explicitly unsupported on the two platforms where support is unambiguous.

This lab therefore builds a Windows x64 VM inside the lab VNet and has you drive VS Code from there
over Azure Bastion. It costs about nine dollars a day and removes an entire category of "is it me or
is it the tool" debugging.

**`CLIENT_PLATFORM` does not decide whether that VM gets built.** `scripts/deploy.sh` never reads
the variable, and `infra/main.bicep` declares `module jumpbox` with no `= if (...)` condition — the
jumpbox is deployed on every run. The only consumer is `scripts/preflight.sh`, which uses it to
decide whether to reserve four Standard DSv5 vCPUs for the jumpbox in its quota check:

```bash
grep -c CLIENT_PLATFORM scripts/deploy.sh     # 0 - deploy.sh does not look at it
grep -n CLIENT_PLATFORM scripts/preflight.sh  # the vCPU probe, and nothing else
```

So setting `CLIENT_PLATFORM=local` to save money does the opposite of what it looks like: you get
the VM and its meter anyway, and you lose the quota probe that would otherwise have caught a
`QuotaExceeded` *before* the deployment started. Leave it at `jumpbox` unless you have already
confirmed your DSv5 quota by hand and specifically want that probe skipped.

You are free to run VS Code on your own machine — nothing forces you onto the jumpbox, and section 9
below applies to whichever machine you use. To stop the compute meter on a jumpbox you are not
using, deallocate it after the deployment (its managed disk keeps billing):

```bash
az vm deallocate --ids "$(jq -r .jumpboxVmId generated/outputs.json)"
```

---

## 9. Network egress

Whichever machine runs VS Code needs outbound HTTPS to **four** destinations. The last one is the
one that gets missed, and its failure mode is opaque.

| Destination | Used for |
| --- | --- |
| Your Foundry endpoint — see the note below | The conversion model calls |
| `https://marketplace.visualstudio.com/` | Installing and updating the extension |
| GitHub Copilot services (`https://api.githubcopilot.com/`, plus `github.com` for auth) | Agent mode on review tasks |
| **`https://github.com/microsoft/pgsql-tools/`** | Extension components fetched at first run |

**The Foundry hostname is not one fixed form.** A Foundry account exposes both
`https://<name>.services.ai.azure.com/` and `https://<resource>.openai.azure.com/`; the Learn
walkthrough's connection table uses the second, and this lab's `.env.example` and Bicep output use
the first. Do not allowlist one from memory. Allowlist whatever the deployment actually returns:

```bash
jq -r .foundryEndpoint generated/outputs.json
```

If you are behind a proxy with an explicit allowlist, permit **both** hostname families for your
account. The extension and the CLI do not always pick the same one.

Behind a restrictive proxy, blocking the last row produces a failure that reads like a licensing or
authentication problem rather than a network one. If conversion fails immediately on a machine
where Copilot chat itself works, test that URL first.

```bash
for url in https://marketplace.visualstudio.com/ \
           https://api.githubcopilot.com/ \
           https://github.com/microsoft/pgsql-tools/ \
           "$(jq -r .foundryEndpoint generated/outputs.json 2>/dev/null)" ; do
  [ -n "$url" ] && [ "$url" != null ] || continue
  printf '%-46s %s\n' "$url" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url")"
done
```

**Any HTTP status code at all means you reached the service** — including `404`. You are testing
TCP and TLS reachability, not the endpoint's routing table, and `https://api.githubcopilot.com/`
currently answers a bare `GET /` with `404`. That is a pass.

You have failed to reach it only when you get:

| Result | Meaning |
| --- | --- |
| `000` and a hang until `--max-time` | Blocked or black-holed. No TCP, or TLS never completed |
| `407` | A proxy wants credentials you have not given it |
| A `curl` TLS error rather than a status code | TLS interception with an untrusted certificate |

The lab's own VNet handles this with a NAT gateway. Azure retired default outbound access for new
virtual networks in September 2025, and both lab VMs deliberately have no public IP, so without the
NAT gateway the Oracle container image pull and the Marketplace both hang. `deployNatGateway`
defaults to `true` for that reason; only turn it off if you are providing egress another way.

---

## 10. Local tooling

| Tool | Minimum | Check | Install |
| --- | --- | --- | --- |
| Azure CLI | 2.60 | `az version` | <https://learn.microsoft.com/cli/azure/install-azure-cli> |
| Bicep | bundled | `az bicep version` | `az bicep install` |
| `jq` | 1.6 | `jq --version` | `brew install jq` / `apt install jq` |
| `bash` | 3.2 | `bash --version` | Pre-installed. macOS ships 3.2; the scripts are written for it |
| `ssh-keygen` | any | `ssh-keygen --help` | Part of OpenSSH |
| `base64` | any | `base64 --help` | Coreutils |
| Python | **3.9** | `python3 --version` | <https://www.python.org/downloads/> |
| Docker | 24 | `docker info` | Only for the local Oracle path |

### Python has no dependencies, on purpose

`tools/generate-objects.py` and `tools/generate-data.py` use the standard library only. Do not run
`pip install`; there is nothing to install. `tools/requirements.txt` exists to say so and to explain
why: a third-party library that changes its float formatting or dict ordering between releases would
silently break byte-identical generation across machines, and cross-run diffs of the conversion
report are the entire point of the lab.

```bash
python3 --version
python3 -m py_compile tools/generate-objects.py tools/generate-data.py
```

### Docker is optional

The lab's **primary** path runs Oracle on an Azure VM inside the lab VNet, standing in for an
on-premises Oracle server. Docker on your own machine is a **secondary** convenience path.

| Path | What you get | When to choose it |
| --- | --- | --- |
| **Azure VM** (`--azure`) — *primary* | Oracle Free 23ai in a container on an Ubuntu VM in the lab VNet, no public IP, reached through Bastion | The headline scenario. Private networking, private DNS, and the same network path the conversion tool will actually use |
| **Local Docker** (`--local`) — *secondary* | The same container on your own machine | Iterating on the schema without paying for a VM, and CI. Needs about 12 GB free and a machine that can run the Oracle image |

The local path is genuinely useful while you are developing SQL, but it exercises none of the
network story — no Bastion, no private endpoint, no NSG, no realistic latency between client and
source. Use it to get the schema right, then run the real thing on the VM.

`scripts/preflight.sh --skip-azure` supports the local-only path. Pass `--skip-docker` if you only
intend to use the Azure path, which is the common case.

---

## 11. Oracle source facts you should know up front

You do not need an Oracle licence or an existing Oracle estate — the lab builds its own source
database, on an Azure VM that stands in for an on-premises Oracle server. But two facts should
shape your expectations before you start.

### Supported source versions, and what the lab actually deploys

Microsoft documents these Oracle source versions as supported: **12.1, 12.2, 18c, 19c, 21c**.

Microsoft's own `mslearn-postgresql` lab deploys **Oracle Database Free 23ai**, which is not on that
list. So does this lab, for the same reason: it is free, it pulls as a single container image, and
it needs no licence paperwork.

That is a real discrepancy and the lab will not pretend otherwise. If you need results that sit
strictly inside the supported matrix, set `ORACLE_IMAGE` in `.env` to a 19c or 21c image before you
seed. Everything else in the lab is version-neutral.

### Grants the conversion tool needs

The tool reads Oracle metadata only. It never writes to Oracle, and it never needs access to your
application data. `O2P_READER` is created for it with exactly:

| Grant | Purpose |
| --- | --- |
| `CONNECT` | Log in |
| `SELECT_CATALOG_ROLE` **or** `SELECT ANY DICTIONARY` | Read the data dictionary |
| `SELECT` on `SYS.ARGUMENT$` | Read procedure and function argument metadata |

The Oracle `sessions` initialisation parameter must be **greater than 10** — the extension opens
several connections for parallel metadata reads. `.env` sets `ORACLE_MIN_SESSIONS=50` and the lab's
Oracle setup asserts it.

Being able to hand a security team that exact, minimal grant list is one of the more useful things
to take away from this lab.

---

## 12. Configure `.env`

```bash
cp .env.example .env
chmod 600 .env
$EDITOR .env
```

Replace every value that reads `replace-me-*` or contains `changeme`, and set
`AZ_SUBSCRIPTION_ID`. Preflight treats any surviving placeholder as a failure.

Passwords worth thinking about for ten seconds:

| Variable | Constraints |
| --- | --- |
| `ORACLE_SYSTEM_PASSWORD` | 12+ characters, at least one digit, no leading digit, and no `@` or `/` — SQL\*Plus easy-connect strings choke on both |
| `CONTOSO_PASSWORD` | Same rules. This account owns all ~1,855 objects |
| `ORACLE_MIGRATION_PASSWORD` | Same rules. This is what you type into the VS Code connection dialog |
| `PGPASSWORD` | 8–128 characters, three of four character classes |
| `JUMPBOX_ADMIN_PASSWORD` | 12–123 characters, Windows complexity rules |

`AZ_KEYVAULT_NAME` must be globally unique across all of Azure, so change the `changeme` suffix
even if you leave `USE_KEYVAULT=0`.

For anything you would not be relaxed about leaking, leave the `*_PASSWORD` variables empty, set
`USE_KEYVAULT=1`, and let the scripts read from Key Vault:

```bash
az keyvault secret set --vault-name "$AZ_KEYVAULT_NAME" \
  --name contoso-schema-password --value "$(openssl rand -base64 24)"
```

No password is ever hardcoded in a `.sql`, `.sh`, `.py` or `.bicep` file in this repository, and no
password is ever passed on a command line where `ps` could read it. If you find one, that is a bug
worth reporting.

---

## 13. Run preflight

```bash
./scripts/preflight.sh
```

It checks, in the order it prints them: `.env` existence and permissions; the contract variables;
the credentials; local tooling and the GitHub Copilot tier; Docker; then everything that needs the
network — Azure CLI login, the selected subscription, the four resource providers, region
availability, vCPU quota, and Foundry TPM quota.

The local checks come first on purpose. They are instant and they are the ones most likely to be
wrong on a first run, so you find out about a placeholder password before you spend four ARM round
trips discovering the same thing more slowly.

Every failure is collected rather than being fatal on the spot, so one run tells you everything
that is wrong instead of making you fix problems one at a time.

```text
== Configuration ==
  [ ok ] .env found
  [ ok ] .env permissions are 600
  [ ok ] .env sourced

== Required variables ==
  [ ok ] AZ_LOCATION            swedencentral
  [ ok ] AZ_RESOURCE_GROUP      o2p-migration-lab-rg
  [ ok ] CONTOSO_SCHEMA         CONTOSO
  [ ok ] ORACLE_SERVICE         FREEPDB1
  [ ok ] PGDATABASE             contoso_store
  [ ok ] FOUNDRY_MODEL_NAME     gpt-5.2

== Credentials ==
  [ ok ] ORACLE_SYSTEM_PASSWORD is set
  [ ok ] CONTOSO_PASSWORD is set
  [FAIL] ORACLE_MIGRATION_PASSWORD is still the .env.example placeholder
         fix: set it in .env, or USE_KEYVAULT=1 with KV_SECRET_ORACLE_MIGRATION_PASSWORD

== Local tooling ==
  [ ok ] az 2.64.0
  [ ok ] jq 1.7.1
  [ ok ] python3 3.12.4
  [ ok ] Copilot plan Business covers agent mode

== Docker (local Oracle path) ==
  [ ok ] docker 27.1.1
  [ ok ] docker daemon is responding

== Azure ==
  [ ok ] logged in as user@example.com
  [ ok ] subscription matches AZ_SUBSCRIPTION_ID
  [ ok ] Microsoft.Compute            Registered
  [ ok ] Microsoft.Network            Registered
  [FAIL] Microsoft.DBforPostgreSQL    NotRegistered
         fix: az provider register --namespace Microsoft.DBforPostgreSQL --wait
  [ ok ] Microsoft.CognitiveServices  Registered

== Compute quota in swedencentral ==
  [ ok ] Total Regional vCPUs      12 of 100 used
  [ ok ] Standard DSv5 Family      0 of 32 used  (needs 8: both VMs are in it)

== Microsoft Foundry quota in swedencentral ==
  [warn] gpt-5.2 quota is 300,000 TPM (recommended 500,000)
         fix: request more, or set FOUNDRY_MODEL_NAME=gpt-5-mini
```

| Exit code | Meaning |
| --- | --- |
| 0 | Everything required is in place. Warnings may still have been printed |
| 1 | One or more required checks failed; each is listed with its fix |
| 2 | The script could not run at all (no `.env`, bad arguments) |

Useful flags:

| Flag | Effect |
| --- | --- |
| `--fix` | Register missing providers and switch subscription without prompting. Never creates anything billable |
| `--region <name>` | Check quota against a different region than `AZ_LOCATION` |
| `--skip-azure` | Skip everything needing a logged-in CLI. For the local-Docker-only path |
| `--skip-docker` | Downgrade Docker checks to warnings. For the Azure-only path |
| `--skip-quota` | Skip the vCPU and TPM lookups, the slowest checks |

A warning is a judgement call, not a blocker. Low Foundry quota, an unusual region, an odd Docker
version — the run will work, it may just be slower or stranger than the documented path.

---

Exit 0 from preflight means you are ready.

**Next:** [01 — Deploy the infrastructure](01-deploy-infrastructure.md)
