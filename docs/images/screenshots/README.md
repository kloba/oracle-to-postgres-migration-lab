# Driving the conversion from a macOS client — what actually happened

A record of running the VS Code PostgreSQL extension against this lab's Azure
deployment on **2026-09-04**, from an Apple Silicon Mac. The screenshots referenced below sit
beside this file.

It exists because `docs/lab-status.md` had two open questions that only doing it
could answer: whether the extension works on ARM64 at all, and what the
conversion actually asks for. Both are now answered. The conversion itself is
still not finished, and this page says exactly where it stops.

## The machine

| | |
|---|---|
| Host | macOS 15.7.9, **arm64** (Apple Silicon) |
| VS Code | 1.136.1 |
| Extension | `ms-ossdata.vscode-pgsql` **1.30.0** |
| Oracle source | the lab's Azure VM, `CONTOSO`, 1,855 objects, seeded at `--scale 0.01` |

## ARM64 is not the blocker the docs feared

`docs/00-prerequisites.md` carries Microsoft's warning that the thick client is
Windows and Linux x64 only, and that ARM64 is unsupported. Taken literally that
reads as "do not try this on an Apple Silicon Mac".

What actually happens:

- The marketplace serves a **`darwin-arm64`-specific build**. The extension
  installs as `ms-ossdata.vscode-pgsql-1.30.0-darwin-arm64` and ships a native
  macOS `pgsqltoolsservice`.
- All **7 migration commands** and the `pg-migrations` view are present in that
  build. Nothing is gated out.
- The **Migrations** panel renders, `+ Create Migration Project` works, and the
  wizard runs — screenshots 01, 02, 05.
- The extension **connected to the Azure Oracle VM and enumerated its schemas**
  — screenshot 03, "Oracle connection successful", with `CONTOSO` listed.

So the platform warning did not stop the client running. That is not the same as
Microsoft supporting it, and this is one machine on one day — but "ARM64 is
risky" was doing more work in our docs than the evidence justifies.

## Reaching a private lab from a laptop

Both targets are deliberately unreachable from the internet: neither VM has a
public IP, and PostgreSQL is private-access only. A laptop client therefore
needs tunnels, which the jumpbox would not:

```bash
# Bastion to the Oracle VM's SSH, then forward Oracle and PostgreSQL out of the VNet
az network bastion tunnel --name o2p-bastion --resource-group o2p-migration-lab-rg \
  --target-resource-id "$(jq -r .oracleVmId generated/outputs.json)" \
  --resource-port 22 --port 2222 &

ssh -i generated/ssh/o2p-lab_ed25519 -p 2222 -N \
  -L 15210:localhost:1521 \
  -L 15432:"$(jq -r .postgresFqdn generated/outputs.json)":5432 \
  azureuser@127.0.0.1 &
```

The wizard then takes `127.0.0.1` / `15210` for Oracle. That is the whole reason
`CLIENT_PLATFORM=jumpbox` is the documented default: on the jumpbox, inside the
VNet, none of this is necessary.

## What the wizard asks for

Step 1 states its own prerequisites (screenshot 01):

- connection details for the source database
- name of the schema(s) to convert
- **endpoint URL and key for a Microsoft Foundry resource**
- **connection name for an existing Azure Database for PostgreSQL instance**

Step 2, *Connect to Oracle* (02, 03): hostname, port, SID/service, username,
password, schemas, plus a **Load Schemas** button that performs a real
connection.

Step 3, *Choose an Azure Database for PostgreSQL scratch database* (04), is
where a laptop run gets interesting. It says plainly:

> Only Azure Database for PostgreSQL is supported for this step. Select an
> existing Azure Database for PostgreSQL connection to continue.

It wants a **saved connection profile**, not a host and port, and it offers a
**Verify Extensions** button — the check that decides whether `plpgsql_check` is
actually usable. `Next: Microsoft Foundry Model Configuration` stays disabled
until a connection and database are chosen.

That Verify Extensions button is worth pausing on. `plpgsql_check` fails **open**:
if it is not loaded, the converter skips its deeper validation and the report
still looks clean. The infrastructure audit found the template was leaving it
allowlisted but *not loaded*, because `shared_preload_libraries` is a static
parameter and ARM cannot restart the server — `scripts/deploy.sh` now performs
that restart and `scripts/status.sh` asserts it. Run Verify Extensions before
trusting any conversion report.

## Where this stops, and why — diagnosed, not assumed

**Not done: the conversion itself.** The run reaches step 3 and stops there. The
first write-up of this guessed at the reason; here is what actually blocks it.

A tunnelled PostgreSQL connection **does work**. A profile pointing at
`postgresql://o2padmin@127.0.0.1:15432/migration_scratch?sslmode=require` passes
the extension's own **Test Connection**, saves, connects, and browses — the
sidebar lists its Databases, Roles and Tablespaces against the real Azure server.
So "the tunnel is not good enough" was wrong.

The wizard still will not offer it. `POSTGRESQL CONNECTION` stays empty and
`Refresh Profiles` spins on *Loading…* indefinitely. The reason is in the
extension's own bundle: `dist/extension.js` references `listFlexibleServers`,
`armEndpoint`, `subscriptionId`, `getSubscriptions`, `azureResourceService` and
`azureAccount`. **That step enumerates Azure Database for PostgreSQL flexible
servers through Azure Resource Manager** — it lists *subscription resources*, not
local connection profiles. A profile you typed in by hand has no ARM identity, so
it can never appear there however well it connects.

Which makes the gate an **interactive Azure sign-in inside VS Code**, consistent
with the AZURE DEPLOYMENTS panel reading "No Azure Deployments" and with no Azure
auth in VS Code's global storage. The same applies to GitHub Copilot (Pro+,
Business or Enterprise) for the review queue. Both are browser OAuth flows.

The practical consequence for this lab: **sign in to Azure in VS Code before
opening the wizard**, and prefer the jumpbox, where the servers are ARM-visible
and no tunnelling is involved at all.

So every prediction in `docs/design.md` about which of the 44 hard cases survive
conversion **remains a prediction**. Nothing here changes that.

## Reproducing this

1. `./scripts/deploy.sh` then `./scripts/seed-oracle.sh --azure --scale 0.01`.
2. Install VS Code and `ms-ossdata.vscode-pgsql`.
3. Open the tunnels above, or better, do the whole thing from the jumpbox.
4. `PostgreSQL: Focus on Migrations View` → `+ Create Migration Project`.
5. Oracle: `127.0.0.1`, `15210`, `FREEPDB1`, `CONTOSO`, schema `CONTOSO`.
6. Foundry endpoint and key:
   ```bash
   jq -r .foundryEndpoint generated/outputs.json
   az cognitiveservices account keys list -g o2p-migration-lab-rg \
     -n "$(jq -r .foundryAccountName generated/outputs.json)" --query key1 -o tsv
   ```

## A note on the screenshots

Cropped to the VS Code window to keep the macOS menu bar and Dock — meeting
reminders, notification badges, installed apps — out of a public repository. The
shell prompt showing a hostname survives in two of them. Check any screenshot you
add here the same way before committing it.
