"""Offline regression tests: Azure operations are pinned to the lab's
subscription, never the ambient ``az account`` default.

Contoso Store -- Oracle to Azure Database for PostgreSQL migration lab.

Background
----------
During a real end-to-end run the active ``az`` subscription drifted to an
unrelated one (an ``az login`` in another window). ``scripts/connect.sh
postgres`` then failed to find ``o2p-oracle-vm`` in ``o2p-migration-lab-rg`` --
the VM plainly existed, but the name lookup ran against the wrong subscription,
while ``az vm show --ids /subscriptions/<right>/...`` succeeded. The deployment's
``generated/outputs.json`` already records the right subscription inside every
full resource id (``/subscriptions/<guid>/...``).

The fix, across connect.sh / collect-conversion-artifacts.sh / destroy.sh:

* derive the subscription from outputs.json (or an explicitly configured
  AZ_SUBSCRIPTION_ID), refuse when the two disagree;
* pass ``--subscription <that>`` on every az call -- never ``az account set``;
* reuse ``oracleVmId`` directly instead of a name lookup where it is available;
* destroy.sh refuses outright rather than delete in whatever subscription the
  global default happens to point at.

What these tests pin down
-------------------------
They never touch Azure. Each script is copied into an isolated temp repo whose
``az`` (and ``lsof`` / ``docker`` where a path needs them) are mocks on PATH that
record every invocation. The mock reports a *drifted* subscription as the active
default and only "finds" a resource group / VM when handed
``--subscription <right>`` -- so a script that leaned on the default would
visibly fail to act. We then assert on the recorded az calls that:

* connect.sh reaches Bastion pinned to the deployed subscription, and reuses
  oracleVmId (no ``az vm show`` name lookup) for both oracle-azure and postgres;
* collect-conversion-artifacts.sh pins its Bastion tunnel the same way;
* destroy.sh lists, deletes and purges only under the pinned subscription, even
  though the active default is something else entirely;
* a configured AZ_SUBSCRIPTION_ID that conflicts with the deployment fails
  *before* any mutating call;
* destroy.sh refuses when no subscription can be established, rather than using
  the active default;
* the local-only connect path makes no az call at all.

Run with:  python3 -m unittest tests.test_lab_subscription   (repo root)
       or:  python3 tests/test_lab_subscription.py
"""

import json
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import unittest

_REPO = pathlib.Path(__file__).resolve().parents[1]
_SCRIPTS = _REPO / "scripts"

# Synthetic, obviously-fake GUIDs. The real subscription is never hardcoded.
RIGHT_SUB = "11111111-1111-1111-1111-111111111111"   # what the deployment used
DRIFT_SUB = "99999999-9999-9999-9999-999999999999"   # the wrong active default
ENV_SUB = "22222222-2222-2222-2222-222222222222"     # a conflicting AZ_SUBSCRIPTION_ID
PLACEHOLDER_SUB = "00000000-0000-0000-0000-000000000000"
CASE_SUB = "aabbccdd-1122-3344-5566-778899aabbcc"    # has hex letters, to prove case-folding

RG = "o2p-migration-lab-rg"


def _rid(provider_path: str) -> str:
    return f"/subscriptions/{RIGHT_SUB}/resourceGroups/{RG}/providers/{provider_path}"


ORACLE_VM_ID = _rid("Microsoft.Compute/virtualMachines/o2p-oracle-vm")


def _outputs() -> dict:
    """A flat outputs.json whose full resource ids all name RIGHT_SUB."""
    return {
        "resourceGroupName": RG,
        "bastionName": "o2p-bastion",
        "oracleVmName": "o2p-oracle-vm",
        "oracleAdminUsername": "azureuser",
        "oracleVmId": ORACLE_VM_ID,
        "jumpboxVmId": _rid("Microsoft.Compute/virtualMachines/o2p-jumpbox"),
        "foundryAccountId": _rid("Microsoft.CognitiveServices/accounts/o2p-foundry"),
        "postgresFqdn": "o2p-pg-xyz.postgres.database.azure.com",
        "scratchPostgresFqdn": "o2p-pg-xyz.postgres.database.azure.com",
        "postgresScratchDatabaseName": "migration_scratch",
    }


# A mock `az`. It records every call, reports DRIFT_SUB as the active default,
# and only "finds" resources when handed --subscription <right>. GUIDs come from
# the environment, never baked into this text.
_MOCK_AZ = r"""#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_AZ_LOG"
sub=""
prev=""
for a in "$@"; do
    [ "$prev" = "--subscription" ] && sub="$a"
    prev="$a"
done
case "$*" in
    "account show"*)
        case "$*" in
            *"--query name"*) printf 'Mock Subscription\n' ;;
            *"--query id"*)   printf '%s\n' "$MOCK_DRIFT_SUB" ;;
        esac
        exit 0 ;;
    "network bastion tunnel"*)
        # Never actually opens a port; the caller's wait loop then sees the
        # process exit and bails. The invocation is already recorded above.
        exit 0 ;;
    "vm show"*)
        if [ "$sub" = "$MOCK_RIGHT_SUB" ]; then printf '%s\n' "$MOCK_VM_ID"; exit 0; fi
        exit 3 ;;
    "group show"*)
        if [ "$sub" = "$MOCK_RIGHT_SUB" ]; then
            case "$*" in *"--query location"*) printf 'eastus2\n' ;; esac
            exit 0
        fi
        exit 3 ;;
    "resource list"*)
        if [ "$sub" = "$MOCK_RIGHT_SUB" ]; then
            case "$*" in
                *"-o json"*)   cat "$MOCK_RES_JSON" ;;
                *"length(@)"*) printf '3\n' ;;
            esac
            exit 0
        fi
        printf '[]\n'; exit 0 ;;
    "keyvault show-deleted"*)
        [ "$sub" = "$MOCK_RIGHT_SUB" ] && exit 0 || exit 1 ;;
    "keyvault purge"*|"cognitiveservices account purge"*|"group delete"*)
        exit 0 ;;
    "keyvault list"*|"cognitiveservices account list"*)
        exit 0 ;;
    *) exit 0 ;;
esac
"""

_MOCK_LSOF_SILENT = "#!/usr/bin/env bash\nexit 1\n"          # nothing is listening
_MOCK_DOCKER_DOWN = "#!/usr/bin/env bash\nexit 1\n"          # daemon not responding

_RES_JSON = json.dumps(
    [
        {"name": "o2p-oracle-vm", "type": "Microsoft.Compute/virtualMachines"},
        {"name": "o2p-kv-abc", "type": "Microsoft.KeyVault/vaults"},
        {"name": "o2p-foundry", "type": "Microsoft.CognitiveServices/accounts"},
    ]
)


def _write_exec(path: pathlib.Path, body: str) -> None:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class _Result:
    def __init__(self, rc, stdout, stderr, az_calls):
        self.rc = rc
        self.stdout = stdout
        self.stderr = stderr
        self.combined = stdout + stderr
        self.az_calls = az_calls           # list of recorded az invocations

    def lines_with(self, needle):
        return [c for c in self.az_calls if needle in c]


class _Base(unittest.TestCase):
    """Copy a real script into an isolated temp repo and run it with mock az."""

    def _make_repo(self, script_name, *, env_text=None, outputs=None, ssh_key=True):
        work = pathlib.Path(tempfile.mkdtemp(prefix="o2p-labsub-"))
        self.addCleanup(shutil.rmtree, work, ignore_errors=True)

        (work / "scripts").mkdir()
        (work / "generated").mkdir()
        (work / "generated" / "ssh").mkdir()
        (work / "bin").mkdir()

        shutil.copy2(_SCRIPTS / script_name, work / "scripts" / script_name)

        if env_text is not None:
            (work / ".env").write_text(env_text)
        if outputs is not None:
            (work / "generated" / "outputs.json").write_text(json.dumps(outputs))
        if ssh_key:
            key = work / "generated" / "ssh" / "o2p-lab_ed25519"
            key.write_text("not-a-real-key\n")
            key.chmod(0o600)

        _write_exec(work / "bin" / "az", _MOCK_AZ)
        (work / "res.json").write_text(_RES_JSON)
        return work

    def _run(self, work, script_name, args, *, extra_mocks=None, timeout=60):
        for name, body in (extra_mocks or {}).items():
            _write_exec(work / "bin" / name, body)

        az_log = work / "az.log"
        az_log.write_text("")

        env = dict(os.environ)
        env["PATH"] = f"{work / 'bin'}{os.pathsep}" + env.get("PATH", "")
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env.update(
            MOCK_AZ_LOG=str(az_log),
            MOCK_RIGHT_SUB=RIGHT_SUB,
            MOCK_DRIFT_SUB=DRIFT_SUB,
            MOCK_VM_ID=ORACLE_VM_ID,
            MOCK_RES_JSON=str(work / "res.json"),
        )
        # A clean, non-interactive input so any stray read() returns EOF.
        proc = subprocess.run(
            ["bash", str(work / "scripts" / script_name), *args],
            env=env,
            cwd=str(work),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        calls = [ln for ln in az_log.read_text().splitlines() if ln.strip()]
        return _Result(proc.returncode, proc.stdout, proc.stderr, calls)

    # -- shared assertions ---------------------------------------------------

    def assert_pinned(self, result, needle):
        """Every recorded az call containing `needle` names RIGHT_SUB, and there
        is at least one such call."""
        hits = result.lines_with(needle)
        self.assertTrue(hits, f"no az call matched {needle!r}\n{result.az_calls}")
        for line in hits:
            self.assertIn(
                f"--subscription {RIGHT_SUB}",
                line,
                f"az call not pinned to the deployed subscription: {line!r}",
            )

    def assert_no_drift(self, result):
        for line in result.az_calls:
            self.assertNotIn(
                DRIFT_SUB, line, f"the drifted default leaked into an az call: {line!r}"
            )


# ---------------------------------------------------------------------------
# connect.sh
# ---------------------------------------------------------------------------
_CONNECT_ENV = "\n".join(
    [
        "AZ_PREFIX=o2p",
        "AZ_RESOURCE_GROUP=o2p-migration-lab-rg",
        "PGHOST=o2p-pg-xyz.postgres.database.azure.com",
        "PGUSER=o2padmin",
        "PGPASSWORD=placeholder",
        "USE_KEYVAULT=0",
        "",
    ]
)


class ConnectTests(_Base):
    def test_oracle_azure_pins_bastion_and_reuses_vm_id(self):
        work = self._make_repo("connect.sh", env_text=_CONNECT_ENV, outputs=_outputs())
        r = self._run(work, "connect.sh", ["oracle-azure"])
        # It dies once the mock tunnel exits; that is fine -- the az calls are
        # already recorded.
        self.assertNotEqual(r.rc, 0, r.combined)
        self.assert_pinned(r, "network bastion tunnel")
        self.assertEqual(
            r.lines_with("vm show"), [], "oracleVmId should be reused, not looked up by name"
        )
        self.assert_no_drift(r)

    def test_postgres_pins_bastion_and_reuses_vm_id(self):
        work = self._make_repo("connect.sh", env_text=_CONNECT_ENV, outputs=_outputs())
        r = self._run(work, "connect.sh", ["postgres"])
        self.assertNotEqual(r.rc, 0, r.combined)
        # This is the exact call that failed in the field: the jump-host lookup.
        self.assert_pinned(r, "network bastion tunnel")
        self.assertEqual(
            r.lines_with("vm show"), [], "postgres must reuse oracleVmId, not run `az vm show`"
        )
        self.assert_no_drift(r)

    def test_conflicting_configured_subscription_fails_before_tunnel(self):
        env = _CONNECT_ENV + f"AZ_SUBSCRIPTION_ID={ENV_SUB}\n"
        work = self._make_repo("connect.sh", env_text=env, outputs=_outputs())
        r = self._run(work, "connect.sh", ["oracle-azure"])
        self.assertNotEqual(r.rc, 0, r.combined)
        self.assertIn("AZ_SUBSCRIPTION_ID", r.combined)
        self.assertEqual(
            r.lines_with("network bastion tunnel"), [], "died conflict must precede any tunnel"
        )

    def test_local_target_makes_no_azure_call(self):
        # oracle-local with USE_KEYVAULT=0 must never touch az. Docker is down,
        # so it dies at the docker check -- but the az log stays empty.
        work = self._make_repo("connect.sh", env_text=_CONNECT_ENV, outputs=_outputs())
        r = self._run(
            work, "connect.sh", ["oracle-local"], extra_mocks={"docker": _MOCK_DOCKER_DOWN}
        )
        self.assertNotEqual(r.rc, 0, r.combined)
        self.assertEqual(r.az_calls, [], "the local path pulled in Azure state")


# ---------------------------------------------------------------------------
# collect-conversion-artifacts.sh
# ---------------------------------------------------------------------------
class CollectTests(_Base):
    def test_bastion_tunnel_is_pinned(self):
        work = self._make_repo("collect-conversion-artifacts.sh", outputs=_outputs())
        r = self._run(
            work,
            "collect-conversion-artifacts.sh",
            [],
            extra_mocks={"lsof": _MOCK_LSOF_SILENT},
        )
        # Dies once the mock tunnel exits; the pinned call is already recorded.
        self.assertNotEqual(r.rc, 0, r.combined)
        self.assert_pinned(r, "network bastion tunnel")
        self.assert_no_drift(r)


# ---------------------------------------------------------------------------
# destroy.sh
# ---------------------------------------------------------------------------
_DESTROY_ENV_BASE = [
    "AZ_PREFIX=o2p",
    "AZ_RESOURCE_GROUP=o2p-migration-lab-rg",
    "AZ_KEYVAULT_NAME=o2p-kv-abc",
    "FOUNDRY_RESOURCE_NAME=o2p-foundry",
    "USE_KEYVAULT=0",
]


def _destroy_env(*extra):
    return "\n".join(_DESTROY_ENV_BASE + list(extra) + [""])


class DestroyTests(_Base):
    def test_delete_and_purge_pinned_despite_drifted_default(self):
        work = self._make_repo("destroy.sh", env_text=_destroy_env(), outputs=_outputs())
        r = self._run(work, "destroy.sh", ["--yes"])
        self.assertEqual(r.rc, 0, r.combined)
        # The group is "found" and deleted only because it was pinned to RIGHT.
        self.assert_pinned(r, "group delete")
        self.assert_pinned(r, "group show")
        self.assert_pinned(r, "resource list")
        self.assert_pinned(r, "keyvault purge")
        self.assert_pinned(r, "cognitiveservices account purge")
        self.assert_no_drift(r)

    def test_placeholder_subscription_is_ignored(self):
        # The all-zeros .env placeholder must not be treated as a real id; the
        # deployment's own subscription still wins.
        env = _destroy_env(f"AZ_SUBSCRIPTION_ID={PLACEHOLDER_SUB}")
        work = self._make_repo("destroy.sh", env_text=env, outputs=_outputs())
        r = self._run(work, "destroy.sh", ["--yes"])
        self.assertEqual(r.rc, 0, r.combined)
        self.assert_pinned(r, "group delete")

    def test_conflicting_configured_subscription_fails_before_any_mutation(self):
        env = _destroy_env(f"AZ_SUBSCRIPTION_ID={ENV_SUB}")
        work = self._make_repo("destroy.sh", env_text=env, outputs=_outputs())
        r = self._run(work, "destroy.sh", ["--yes"])
        self.assertNotEqual(r.rc, 0, r.combined)
        self.assertIn("AZ_SUBSCRIPTION_ID", r.combined)
        self.assertEqual(r.lines_with("group delete"), [], "must die before deleting")
        self.assertEqual(r.lines_with("group show"), [], "must die before inventory")

    def test_refuses_when_no_subscription_can_be_established(self):
        # RG configured, but nothing names a subscription: no outputs.json and
        # only the placeholder in .env. Must refuse, not use the active default.
        env = _destroy_env(f"AZ_SUBSCRIPTION_ID={PLACEHOLDER_SUB}")
        work = self._make_repo("destroy.sh", env_text=env, outputs=None)
        r = self._run(work, "destroy.sh", ["--yes"])
        self.assertNotEqual(r.rc, 0, r.combined)
        self.assertIn("cannot establish which subscription", r.combined)
        self.assertEqual(r.lines_with("group delete"), [], "refusal must not delete")

    def test_explicit_subscription_flag_overrides_conflict(self):
        # --subscription is the escape hatch: it wins over a conflicting
        # AZ_SUBSCRIPTION_ID and drives the delete against the id given.
        env = _destroy_env(f"AZ_SUBSCRIPTION_ID={ENV_SUB}")
        work = self._make_repo("destroy.sh", env_text=env, outputs=_outputs())
        r = self._run(work, "destroy.sh", ["--yes", "--subscription", RIGHT_SUB])
        self.assertEqual(r.rc, 0, r.combined)
        self.assert_pinned(r, "group delete")

    # -- fail-closed on an outputs.json we cannot verify -----------------------

    def test_subscription_anchored_from_any_resource_id(self):
        # The subscription must be scanned out of ANY /subscriptions/<id>/ string,
        # not three hand-picked keys. Here only a postgres server id (never in the
        # old three) names it; the delete must still pin to RIGHT.
        outs = {
            "resourceGroupName": RG,
            "postgresServerName": "o2p-pg-xyz",
            "postgresServerId": _rid("Microsoft.DBforPostgreSQL/flexibleServers/o2p-pg-xyz"),
            "postgresFqdn": "o2p-pg-xyz.postgres.database.azure.com",
        }
        work = self._make_repo("destroy.sh", env_text=_destroy_env(), outputs=outs)
        r = self._run(work, "destroy.sh", ["--yes"])
        self.assertEqual(r.rc, 0, r.combined)
        self.assert_pinned(r, "group delete")
        self.assert_no_drift(r)

    def test_refuses_when_outputs_present_but_have_no_resource_id(self):
        # outputs.json exists but carries only names/fqdns (a partial or renamed
        # template): nothing anchors the subscription, so refuse -- never fall
        # through to a configured/ambient id.
        outs = {"resourceGroupName": RG, "postgresServerName": "srv", "postgresFqdn": "h"}
        env = _destroy_env(f"AZ_SUBSCRIPTION_ID={ENV_SUB}")
        work = self._make_repo("destroy.sh", env_text=env, outputs=outs)
        r = self._run(work, "destroy.sh", ["--yes"])
        self.assertNotEqual(r.rc, 0, r.combined)
        self.assertIn("no /subscriptions/", r.combined)
        self.assertEqual(r.lines_with("group delete"), [], "refusal must not delete")
        self.assertEqual(r.lines_with("group show"), [], "refusal must precede inventory")

    def test_refuses_when_outputs_present_but_unreadable(self):
        if getattr(os, "geteuid", lambda: 1)() == 0:
            self.skipTest("root can read 0000 files, so the -r guard cannot be exercised")
        env = _destroy_env(f"AZ_SUBSCRIPTION_ID={ENV_SUB}")
        work = self._make_repo("destroy.sh", env_text=env, outputs=_outputs())
        oj = work / "generated" / "outputs.json"
        oj.chmod(0o000)
        self.addCleanup(oj.chmod, 0o600)
        r = self._run(work, "destroy.sh", ["--yes"])
        self.assertNotEqual(r.rc, 0, r.combined)
        self.assertIn("not readable", r.combined)
        self.assertEqual(r.lines_with("group delete"), [], "refusal must not delete")

    def test_refuses_when_outputs_present_but_jq_missing(self):
        # jq is optional for destroy.sh's inventory, so a jq-less host can reach
        # the delete. With outputs.json present we must NOT silently skip the
        # subscription cross-check: refuse, do not fall back to AZ_SUBSCRIPTION_ID.
        env = _destroy_env(f"AZ_SUBSCRIPTION_ID={ENV_SUB}")
        work = self._make_repo("destroy.sh", env_text=env, outputs=_outputs())
        bindir = self._curated_bin_without_jq(work)

        az_log = work / "az.log"
        az_log.write_text("")
        environ = dict(os.environ)
        environ["PATH"] = str(bindir)          # ONLY this dir: jq is genuinely absent
        environ["NO_COLOR"] = "1"
        environ["TERM"] = "dumb"
        environ.update(
            MOCK_AZ_LOG=str(az_log),
            MOCK_RIGHT_SUB=RIGHT_SUB,
            MOCK_DRIFT_SUB=DRIFT_SUB,
            MOCK_VM_ID=ORACLE_VM_ID,
            MOCK_RES_JSON=str(work / "res.json"),
        )
        bash = shutil.which("bash") or "/bin/bash"
        proc = subprocess.run(
            [bash, str(work / "scripts" / "destroy.sh"), "--yes"],
            env=environ,
            cwd=str(work),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=60,
        )
        combined = proc.stdout + proc.stderr
        # sanity: jq really is unreachable on this PATH
        self.assertIsNone(shutil.which("jq", path=str(bindir)), "jq leaked into the curated PATH")
        self.assertNotEqual(proc.returncode, 0, combined)
        self.assertIn("jq is not installed", combined)
        calls = [ln for ln in az_log.read_text().splitlines() if ln.strip()]
        self.assertEqual([c for c in calls if "group delete" in c], [], "must refuse before deleting")
        self.assertEqual([c for c in calls if "group show" in c], [], "must refuse before inventory")

    def test_explicit_flag_differing_from_outputs_warns_but_uses_the_flag(self):
        # --subscription remains the deliberate escape hatch even when it differs
        # from outputs.json: it warns, then drives every call under the id given
        # (never the deployed one).
        work = self._make_repo("destroy.sh", env_text=_destroy_env(), outputs=_outputs())
        r = self._run(work, "destroy.sh", ["--yes", "--subscription", ENV_SUB])
        self.assertIn("differs from the deployed subscription", r.combined)
        for line in r.lines_with("--subscription"):
            self.assertIn(f"--subscription {ENV_SUB}", line)
        self.assert_no_drift(r)

    # -- ambiguous / malformed recorded identity ------------------------------

    def _sub_id(self, sub, leaf="Microsoft.Compute/virtualMachines/x"):
        return f"/subscriptions/{sub}/resourceGroups/{RG}/providers/{leaf}"

    def test_refuses_when_outputs_record_two_subscriptions(self):
        # outputs names BOTH RIGHT and DRIFT (a partial/rebuilt or merged file).
        # No single id is authoritative -- refuse, even when AZ_SUBSCRIPTION_ID
        # happens to match one of them (the case that used to pass on first-id).
        outs = {
            "resourceGroupName": RG,
            "oracleVmId": ORACLE_VM_ID,  # RIGHT
            "jumpboxVmId": self._sub_id(DRIFT_SUB, "Microsoft.Compute/virtualMachines/jb"),
        }
        env = _destroy_env(f"AZ_SUBSCRIPTION_ID={RIGHT_SUB}")
        work = self._make_repo("destroy.sh", env_text=env, outputs=outs)
        r = self._run(work, "destroy.sh", ["--yes"])
        self.assertNotEqual(r.rc, 0, r.combined)
        self.assertIn("more than one subscription", r.combined)
        self.assertEqual(r.lines_with("group delete"), [], "ambiguity must not delete")
        self.assertEqual(r.lines_with("group show"), [], "ambiguity must precede inventory")

    def test_same_subscription_repeated_is_accepted(self):
        # Several ids, all the same subscription: unambiguous -> proceed.
        outs = {
            "resourceGroupName": RG,
            "oracleVmId": ORACLE_VM_ID,
            "jumpboxVmId": self._sub_id(RIGHT_SUB, "Microsoft.Compute/virtualMachines/jb"),
            "foundryAccountId": self._sub_id(RIGHT_SUB, "Microsoft.CognitiveServices/accounts/f"),
        }
        work = self._make_repo("destroy.sh", env_text=_destroy_env(), outputs=outs)
        r = self._run(work, "destroy.sh", ["--yes"])
        self.assertEqual(r.rc, 0, r.combined)
        self.assert_pinned(r, "group delete")

    def test_same_subscription_mixed_case_is_folded_not_conflicting(self):
        # The same GUID in different letter-case must fold to one, not read as a
        # conflict. The mock does not "find" CASE_SUB, so this ends at
        # "does not exist" -- the point is it was NOT refused as ambiguous and it
        # pinned every call to the case-folded id.
        outs = {
            "resourceGroupName": RG,
            "oracleVmId": self._sub_id(CASE_SUB.lower(), "Microsoft.Compute/virtualMachines/x"),
            "jumpboxVmId": self._sub_id(CASE_SUB.upper(), "Microsoft.Compute/virtualMachines/jb"),
        }
        env = _destroy_env(f"AZ_SUBSCRIPTION_ID={CASE_SUB.upper()}")
        work = self._make_repo("destroy.sh", env_text=env, outputs=outs)
        r = self._run(work, "destroy.sh", ["--yes"])
        self.assertEqual(r.rc, 0, r.combined)
        self.assertNotIn("more than one subscription", r.combined)
        self.assertNotIn("not AZ_SUBSCRIPTION_ID", r.combined)  # env folds to the same id
        self.assertTrue(r.lines_with("group show"), "classification refused a same-but-mixed-case id")
        for line in r.lines_with("--subscription"):
            self.assertIn(f"--subscription {CASE_SUB.lower()}", line)

    def test_refuses_when_recorded_subscription_is_malformed(self):
        outs = {"resourceGroupName": RG, "oracleVmId": self._sub_id("not-a-real-guid")}
        env = _destroy_env(f"AZ_SUBSCRIPTION_ID={RIGHT_SUB}")
        work = self._make_repo("destroy.sh", env_text=env, outputs=outs)
        r = self._run(work, "destroy.sh", ["--yes"])
        self.assertNotEqual(r.rc, 0, r.combined)
        self.assertIn("malformed", r.combined)
        self.assertEqual(r.lines_with("group delete"), [], "malformed id must not delete")

    def test_explicit_flag_escapes_ambiguous_outputs_with_a_warning(self):
        # The documented escape must actually work: with ambiguous outputs that
        # would otherwise refuse, --subscription proceeds -- but warns, never
        # silently -- and pins to the id given.
        outs = {
            "resourceGroupName": RG,
            "oracleVmId": ORACLE_VM_ID,  # RIGHT
            "jumpboxVmId": self._sub_id(DRIFT_SUB, "Microsoft.Compute/virtualMachines/jb"),
        }
        work = self._make_repo("destroy.sh", env_text=_destroy_env(), outputs=outs)
        r = self._run(work, "destroy.sh", ["--yes", "--subscription", RIGHT_SUB])
        self.assertEqual(r.rc, 0, r.combined)
        self.assertIn("more than one subscription", r.combined)  # warned, not silent
        self.assert_pinned(r, "group delete")  # RIGHT is found by the mock and deleted
        self.assert_no_drift(r)

    def _curated_bin_without_jq(self, work):
        """A PATH dir holding symlinks to every tool destroy.sh needs, MINUS jq,
        plus the mock az. Running with PATH set to only this dir reproduces a host
        where jq is not installed, without disturbing the real environment."""
        bindir = work / "nojqbin"
        bindir.mkdir()
        for tool in (
            "bash", "env", "sed", "date", "tr", "sort", "mv", "grep",
            "dirname", "cat", "basename", "head", "tail", "rm", "mkdir",
            "chmod", "ls", "wc", "awk", "sleep", "printf",
        ):
            real = shutil.which(tool)
            if real:
                os.symlink(real, bindir / tool)
        _write_exec(bindir / "az", _MOCK_AZ)
        return bindir


# ---------------------------------------------------------------------------
# Static guards on the script text itself
# ---------------------------------------------------------------------------
class SourceGuards(unittest.TestCase):
    def _src(self, name):
        return (_SCRIPTS / name).read_text()

    def test_scripts_parse(self):
        for name in ("connect.sh", "collect-conversion-artifacts.sh", "destroy.sh"):
            proc = subprocess.run(
                ["bash", "-n", str(_SCRIPTS / name)], capture_output=True, text=True
            )
            self.assertEqual(proc.returncode, 0, f"{name}: {proc.stderr}")

    def test_shellcheck_clean(self):
        if shutil.which("shellcheck") is None:
            self.skipTest("shellcheck not installed")
        for name in ("connect.sh", "collect-conversion-artifacts.sh", "destroy.sh"):
            proc = subprocess.run(
                [
                    "shellcheck",
                    "--severity=style",
                    "--shell=bash",
                    "--external-sources",
                    "--exclude=SC1091",
                    str(_SCRIPTS / name),
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(proc.returncode, 0, f"{name}: {proc.stdout}{proc.stderr}")

    def test_connect_postgres_reuses_oracle_vm_id(self):
        src = self._src("connect.sh")
        # The postgres/scratch jump-host must read the id from outputs, not run a
        # name lookup unconditionally.
        branch = src.split("postgres|scratch)", 1)[1]
        self.assertIn('VM_ID="$(out oracleVmId)"', branch)

    def test_destroy_does_not_change_the_global_account(self):
        src = self._src("destroy.sh")
        # `az account set` may appear in an explanatory comment (it is exactly
        # what we avoid), but must never be an actual command.
        for line in src.splitlines():
            if line.lstrip().startswith("#"):
                continue
            self.assertNotIn(
                "az account set",
                line,
                "destroy.sh must pin --subscription, not switch the default",
            )
        self.assertIn("--subscription", src)

    def test_each_script_derives_subscription_from_resource_id(self):
        for name in ("connect.sh", "collect-conversion-artifacts.sh", "destroy.sh"):
            self.assertIn("/subscriptions/", self._src(name), name)

    def test_destroy_scans_all_resource_ids_not_three_keys(self):
        src = self._src("destroy.sh")
        self.assertNotIn(
            ".oracleVmId // .foundryAccountId // .jumpboxVmId",
            src,
            "destroy.sh still anchors the subscription on only three output keys",
        )
        self.assertIn(
            'select(startswith("/subscriptions/"))',
            src,
            "destroy.sh no longer scans all resource-id strings for the subscription",
        )

    def test_destroy_fails_closed_when_outputs_unverifiable(self):
        src = self._src("destroy.sh")
        # An outputs.json we cannot verify (unreadable / no jq / no resource id /
        # a malformed id / two different subscriptions) must refuse, never fall
        # through to a configured or ambient id, and never guess a first-id winner.
        for needle in (
            "is not readable",
            "jq is not installed",
            "no /subscriptions/",
            "malformed",
            "more than one subscription",
        ):
            self.assertIn(needle, src, f"destroy.sh missing fail-closed guard: {needle!r}")
        # a real GUID shape check, not just a substring anchor
        self.assertIn("is_guid", src, "destroy.sh no longer validates the recorded id is a GUID")


if __name__ == "__main__":
    unittest.main()
