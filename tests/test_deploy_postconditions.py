"""Regression tests for scripts/deploy.sh's post-deployment config block.

Contoso Store -- Oracle to Azure Database for PostgreSQL migration lab.

Background
----------
scripts/deploy.sh once read the freshly deployed PostgreSQL server name with

    PG_SERVER="$(out postgresServerName 2>/dev/null || true)"

but ``out`` is defined only in seed-oracle.sh and connect.sh, never in
deploy.sh. Under ``set -euo pipefail`` the "out: command not found" was
swallowed by ``2>/dev/null || true``, PG_SERVER came back empty, and the two
blocks guarded on it -- the static-parameter *restart* (which is what makes
plpgsql_check actually load; it fails OPEN otherwise) and the extension
install -- both silently skipped. A real deploy.log showed no restart step at
all.

What these tests pin down
-------------------------
They never call Azure. The post-deployment block is lifted verbatim from
deploy.sh between two ``# --- deploy.sh:postdeploy ... (test anchor) ---``
sentinels and run under a tiny bash harness whose ``az``, ``psql`` and
``install-pg-extensions.sh`` are mocks on PATH / in SCRIPT_DIR, and whose
outputs.json is a fixture. That proves, on the real script text:

* the restart runs when ARM reports a pending restart, and does not when it
  does not;
* a config-check that az cannot answer is surfaced loudly, not skipped;
* a missing postgresServerName output fails visibly (die) instead of silently
  skipping;
* install-pg-extensions.sh is handed the *deployed* PGHOST/PGUSER/PGDATABASE/
  SCRATCH_PGDATABASE/PGPASSWORD, not whatever stale value sits in .env;
* an unreachable server (install-pg-extensions.sh exit 3 -- a pg_isready
  no-response) is reported as the expected private-access case and marked
  UNVERIFIED, while a reached-but-failed step (any other non-zero exit) is fatal
  and the deploy refuses to print success -- the classification is the installer's
  exit *code*, never grepped English log text;
* a missing postgresFqdn output never lets the installer run against a stale
  host: the step is skipped with an explicit UNVERIFIED notice.

Plus static guards: no undefined ``out`` call remains, the block parses
(``bash -n``), it is shellcheck-clean, and the what-if path still returns
before this block runs.

Run with:  python3 -m unittest tests.test_deploy_postconditions   (repo root)
       or:  python3 tests/test_deploy_postconditions.py
"""

import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import unittest

_REPO = pathlib.Path(__file__).resolve().parents[1]
_DEPLOY_SH = _REPO / "scripts" / "deploy.sh"
_INSTALLER_SH = _REPO / "scripts" / "install-pg-extensions.sh"

_BEGIN = "# --- deploy.sh:postdeploy BEGIN (test anchor) ---"
_END = "# --- deploy.sh:postdeploy END (test anchor) ---"


def _deploy_src() -> str:
    return _DEPLOY_SH.read_text()


def _extract_block() -> str:
    """The post-deployment block, verbatim, from deploy.sh."""
    src = _deploy_src()
    assert _BEGIN in src, f"missing begin anchor in {_DEPLOY_SH}"
    assert _END in src, f"missing end anchor in {_DEPLOY_SH}"
    body = src.split(_BEGIN, 1)[1].split(_END, 1)[0]
    assert "outval" in body and "install-pg-extensions.sh" in body, body
    return body


# Distinctive values: nothing here looks like a .env placeholder, so a test
# that sees them proves the block read outputs.json, not .env.
_OUTPUTS = {
    "postgresServerName": "o2p-pg-testsrv",
    "postgresFqdn": "o2p-pg-testsrv.postgres.database.azure.com",
    "postgresAdministratorLogin": "o2padmin_fromoutputs",
    "postgresDatabaseName": "contoso_store_fromoutputs",
    "postgresScratchDatabaseName": "migration_scratch_fromoutputs",
}

_HARNESS = """\
#!/usr/bin/env bash
set -euo pipefail

# Logging + die helpers, mirroring deploy.sh's real ones without the colour.
hdr()  { printf '== %s ==\\n' "$*"; }
ok()   { printf '[ ok ] %s\\n' "$*"; }
info() { printf '[ .. ] %s\\n' "$*"; }
warn() { printf '[warn] %s\\n' "$*"; }
note() { printf '         %s\\n' "$*"; }
die()  {
    printf 'deploy failed: %s\\n' "$1" >&2
    [[ -n "${2:-}" ]] && printf 'fix: %s\\n' "$2" >&2
    exit 1
}

# The variables the block closes over, supplied from the environment.
REPO_ROOT="${HARNESS_REPO_ROOT:?}"
RG="${HARNESS_RG:?}"
OUTPUTS_JSON="${HARNESS_OUTPUTS_JSON:?}"
SCRIPT_DIR="${HARNESS_SCRIPT_DIR:?}"
TMP_DIR="${HARNESS_TMP_DIR:?}"
PG_PW="${HARNESS_PG_PW-}"
CONTOSO_PW="${HARNESS_CONTOSO_PW-}"

# --- extracted verbatim from scripts/deploy.sh ---
__EXTRACTED_BLOCK__
# --- end extracted block ---
"""

_MOCK_AZ = """\
#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$MOCK_AZ_LOG"
case "$*" in
    *"parameter show"*isConfigPendingRestart*)
        if [[ "${MOCK_PENDING-}" == "ERR" ]]; then exit 3; fi
        printf '%s' "${MOCK_PENDING-}"
        exit 0 ;;
    *"flexible-server restart"*)
        exit "${MOCK_RESTART_RC:-0}" ;;
    *)
        exit 0 ;;
esac
"""

# psql only has to exist so `command -v psql` succeeds; the block calls the
# installer, not psql, directly. pg_isready likewise only has to exist so the
# block's `command -v pg_isready` gate passes -- the real reachability probe
# lives inside install-pg-extensions.sh, which the block runs (mocked here).
_MOCK_PSQL = "#!/usr/bin/env bash\nexit 0\n"
_MOCK_PGISREADY = "#!/usr/bin/env bash\nexit 0\n"

# The mock installer reports the connection env it was handed, then exits with
# the CODE the block classifies on: 0 ready, 3 unreachable (pg_isready
# no-response / private access), any other non-zero = reached but a step failed.
_MOCK_INSTALLER = """\
#!/usr/bin/env bash
{
    printf 'PGHOST=%s\\n'              "${PGHOST-}"
    printf 'PGPORT=%s\\n'              "${PGPORT-}"
    printf 'PGUSER=%s\\n'              "${PGUSER-}"
    printf 'PGDATABASE=%s\\n'          "${PGDATABASE-}"
    printf 'SCRATCH_PGDATABASE=%s\\n'  "${SCRATCH_PGDATABASE-}"
    printf 'PGPASSWORD=%s\\n'          "${PGPASSWORD-}"
    printf 'PGHOSTADDR=%s\\n'          "${PGHOSTADDR-}"
    printf 'PGSERVICE=%s\\n'           "${PGSERVICE-}"
    printf 'PGSERVICEFILE=%s\\n'       "${PGSERVICEFILE-}"
    printf 'O2P_PIN_TARGET=%s\\n'      "${O2P_PIN_TARGET-}"
} > "$MOCK_ENV_DUMP"
case "${MOCK_INSTALLER_MODE:-success}" in
    success)
        echo "Ready."; exit 0 ;;
    unreachable)
        echo "the server did not respond (pg_isready: no response)" >&2
        exit 3 ;;
    reached-failed)
        echo "[FAIL] plpgsql_check is NOT loaded"; exit 1 ;;
    *)
        exit 1 ;;
esac
"""


def _write_exec(path: pathlib.Path, body: str) -> None:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class _HarnessResult:
    def __init__(self, rc, stdout, stderr, az_calls, env_dump):
        self.rc = rc
        self.stdout = stdout
        self.stderr = stderr
        self.combined = stdout + stderr
        self.az_calls = az_calls          # raw text of every az invocation
        self.env_dump = env_dump          # {VAR: value} the installer received


class PostdeployBlockTests(unittest.TestCase):
    """Run the real block text against mocked az / psql / installer."""

    def _run(
        self,
        *,
        outputs=None,
        pending="false",
        installer_mode="success",
        restart_rc=0,
        pg_pw="Deployed#Pg#Pw!1",
        contoso_pw="Contoso#Pw!2",
    ) -> _HarnessResult:
        outputs = _OUTPUTS if outputs is None else outputs
        work = pathlib.Path(tempfile.mkdtemp(prefix="o2p-postdeploy-"))
        self.addCleanup(shutil.rmtree, work, ignore_errors=True)

        bindir = work / "bin"
        scriptdir = work / "scripts"
        tmpdir = work / "tmp"
        for d in (bindir, scriptdir, tmpdir):
            d.mkdir(parents=True)

        # outputs.json fixture
        import json

        outputs_json = work / "outputs.json"
        outputs_json.write_text(json.dumps(outputs))

        # mocks
        _write_exec(bindir / "az", _MOCK_AZ)
        _write_exec(bindir / "psql", _MOCK_PSQL)
        _write_exec(bindir / "pg_isready", _MOCK_PGISREADY)
        _write_exec(scriptdir / "install-pg-extensions.sh", _MOCK_INSTALLER)

        harness = work / "harness.sh"
        harness.write_text(_HARNESS.replace("__EXTRACTED_BLOCK__", _extract_block()))

        az_log = work / "az.log"
        az_log.write_text("")
        env_dump = work / "installer-env.txt"

        env = dict(os.environ)
        env["PATH"] = f"{bindir}{os.pathsep}" + env.get("PATH", "")
        # A hostile ambient environment: libpq destination-override channels that
        # must not survive into the installer's connection when deploy pins it.
        env.update(
            PGHOSTADDR="203.0.113.99",
            PGSERVICE="stale-service",
            PGSERVICEFILE="/tmp/stale-pg-service.conf",
        )
        env.update(
            HARNESS_REPO_ROOT=str(work),
            HARNESS_RG="o2p-migration-lab-rg",
            HARNESS_OUTPUTS_JSON=str(outputs_json),
            HARNESS_SCRIPT_DIR=str(scriptdir),
            HARNESS_TMP_DIR=str(tmpdir),
            HARNESS_PG_PW=pg_pw,
            HARNESS_CONTOSO_PW=contoso_pw,
            MOCK_AZ_LOG=str(az_log),
            MOCK_ENV_DUMP=str(env_dump),
            MOCK_PENDING=pending,
            MOCK_RESTART_RC=str(restart_rc),
            MOCK_INSTALLER_MODE=installer_mode,
        )

        proc = subprocess.run(
            ["bash", str(harness)],
            env=env,
            capture_output=True,
            text=True,
        )
        dump = {}
        if env_dump.exists():
            for line in env_dump.read_text().splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    dump[k] = v
        return _HarnessResult(
            proc.returncode, proc.stdout, proc.stderr, az_log.read_text(), dump
        )

    # -- the restart the converter depends on --------------------------------

    def test_restart_runs_when_pending_true(self):
        r = self._run(pending="true")
        self.assertEqual(r.rc, 0, r.combined)
        self.assertIn("flexible-server restart", r.az_calls)
        self.assertIn("restarted; shared_preload_libraries is now in effect", r.stdout)

    def test_no_restart_when_not_pending(self):
        r = self._run(pending="false")
        self.assertEqual(r.rc, 0, r.combined)
        self.assertNotIn("flexible-server restart", r.az_calls)
        self.assertIn("no restart pending", r.stdout)

    def test_restart_failure_is_reported_not_fatal(self):
        r = self._run(pending="true", restart_rc=1)
        self.assertEqual(r.rc, 0, r.combined)
        self.assertIn("flexible-server restart", r.az_calls)
        self.assertIn("restart failed", r.combined)

    def test_failed_config_check_surfaces_visibly(self):
        # az answers nothing: the pre-fix code silently did nothing here.
        r = self._run(pending="")
        self.assertEqual(r.rc, 0, r.combined)
        self.assertIn("could not read isConfigPendingRestart", r.combined)
        self.assertNotIn("flexible-server restart", r.az_calls)
        self.assertNotIn("no restart pending", r.combined)

    def test_config_check_error_exit_surfaces_visibly(self):
        # az exits non-zero rather than printing empty; same visible outcome.
        r = self._run(pending="ERR")
        self.assertEqual(r.rc, 0, r.combined)
        self.assertIn("could not read isConfigPendingRestart", r.combined)
        self.assertNotIn("flexible-server restart", r.az_calls)

    # -- fail visibly on a missing output ------------------------------------

    def test_missing_server_name_dies(self):
        r = self._run(outputs={"foundryEndpoint": "https://example/"})
        self.assertEqual(r.rc, 1, r.combined)
        self.assertIn("no postgresServerName", r.combined)
        # died before any Azure call and before the restart header
        self.assertEqual(r.az_calls.strip(), "")
        self.assertNotIn("Applying the static-parameter restart", r.combined)

    # -- installer gets the DEPLOYED connection details, not stale .env ------

    def test_installer_receives_deployment_values(self):
        r = self._run(pending="false", installer_mode="success")
        self.assertEqual(r.rc, 0, r.combined)
        self.assertEqual(r.env_dump.get("PGHOST"), _OUTPUTS["postgresFqdn"])
        self.assertEqual(r.env_dump.get("PGUSER"), _OUTPUTS["postgresAdministratorLogin"])
        self.assertEqual(r.env_dump.get("PGDATABASE"), _OUTPUTS["postgresDatabaseName"])
        self.assertEqual(
            r.env_dump.get("SCRATCH_PGDATABASE"),
            _OUTPUTS["postgresScratchDatabaseName"],
        )
        # password came from the deploy, never from outputs.json
        self.assertEqual(r.env_dump.get("PGPASSWORD"), "Deployed#Pg#Pw!1")

    def test_installer_password_falls_back_to_contoso(self):
        r = self._run(pending="false", pg_pw="", contoso_pw="Contoso#Only!3")
        self.assertEqual(r.rc, 0, r.combined)
        self.assertEqual(r.env_dump.get("PGPASSWORD"), "Contoso#Only!3")

    def test_postdeploy_pins_target_and_clears_ambient_redirectors(self):
        # deploy must hand the installer the pin flag plus the deployed FQDN/port,
        # and drop the ambient libpq destination-override channels (set in _run)
        # so a stale PGHOSTADDR/PGSERVICE cannot send the connection -- and the
        # fresh admin password -- to another server.
        r = self._run(pending="false", installer_mode="success")
        self.assertEqual(r.rc, 0, r.combined)
        self.assertEqual(r.env_dump.get("O2P_PIN_TARGET"), "1")
        self.assertEqual(r.env_dump.get("PGHOST"), _OUTPUTS["postgresFqdn"])
        self.assertEqual(r.env_dump.get("PGPORT"), "5432")
        self.assertEqual(r.env_dump.get("PGHOSTADDR"), "", "ambient PGHOSTADDR leaked into the installer")
        self.assertEqual(r.env_dump.get("PGSERVICE"), "", "ambient PGSERVICE leaked into the installer")
        self.assertEqual(r.env_dump.get("PGSERVICEFILE"), "", "ambient PGSERVICEFILE leaked into the installer")

    # -- failure classification (by installer exit code, not log text) --------

    def test_unreachable_reads_as_private_access_and_unverified(self):
        # exit 3 == pg_isready no-response == VNet-private from here. Expected
        # laptop case: not a failure, but explicitly UNVERIFIED, never "done".
        r = self._run(installer_mode="unreachable")
        self.assertEqual(r.rc, 0, r.combined)
        self.assertIn("private access, as designed", r.combined)
        self.assertIn("UNVERIFIED", r.combined)
        self.assertNotIn("did not finish clean", r.combined)

    def test_reached_but_failed_is_fatal_and_blocks_success(self):
        # Any other non-zero: the server answered but a step failed. The block
        # must die (rc != 0) so deploy.sh never reaches its "Deployment
        # succeeded." print, and must not mislabel it as private access.
        r = self._run(installer_mode="reached-failed")
        self.assertEqual(r.rc, 1, r.combined)
        self.assertIn("did not finish clean", r.combined)
        self.assertNotIn("private access, as designed", r.combined)
        self.assertNotIn("UNVERIFIED", r.combined)

    def test_missing_fqdn_skips_installer_unverified(self):
        # postgresServerName present (so the restart guard passes) but no
        # postgresFqdn: the installer must NOT run, so it cannot inherit a stale
        # .env host; the step is reported UNVERIFIED and the deploy continues.
        outputs = {k: v for k, v in _OUTPUTS.items() if k != "postgresFqdn"}
        r = self._run(outputs=outputs, pending="false")
        self.assertEqual(r.rc, 0, r.combined)
        self.assertIn("no postgresFqdn output", r.combined)
        self.assertIn("UNVERIFIED", r.combined)
        # the installer never ran, so it dumped no connection env
        self.assertEqual(r.env_dump, {}, "installer ran despite a missing FQDN")


class DeploySourceGuards(unittest.TestCase):
    """Static guards on the script text itself."""

    def test_no_undefined_out_call_remains(self):
        src = _deploy_src()
        import re

        self.assertIsNone(
            re.search(r"\bout\s+postgresServerName", src),
            "the undefined `out postgresServerName` call is back",
        )
        self.assertRegex(src, r"(?m)^outval\(\)\s*\{", "outval helper not defined")
        self.assertIn('PG_SERVER="$(outval postgresServerName)"', src)

    def test_block_anchors_present(self):
        src = _deploy_src()
        self.assertIn(_BEGIN, src)
        self.assertIn(_END, src)

    def test_whatif_returns_before_postdeploy(self):
        src = _deploy_src()
        # The what-if branch exits before the post-deployment block is reached,
        # so preview runs never restart or touch the server.
        self.assertLess(
            src.index("What-if complete"),
            src.index(_BEGIN),
            "post-deploy block moved ahead of the what-if early exit",
        )

    def test_classification_is_by_exit_code_not_log_grep(self):
        # The old code grepped install-pg-extensions.sh's log for English
        # connection phrases; a reached-but-failed run whose text happened to
        # match was mislabelled private-access. The classification must now be
        # the installer's exit code.
        block = _extract_block()
        self.assertNotIn(
            "could not translate host name",
            block,
            "English-token grep is back in the extension classification",
        )
        self.assertNotRegex(
            block,
            r"grep -qiE '.*connection",
            "extension failure is being classified by grepping log text again",
        )
        self.assertIn("ext_rc", block, "extension step no longer captures an exit code")
        self.assertRegex(
            block, r'ext_rc"?\s*-eq\s*3', "the unreachable exit code (3) branch is gone"
        )

    def test_missing_fqdn_is_guarded_in_source(self):
        block = _extract_block()
        self.assertIn(
            "no postgresFqdn output",
            block,
            "the FQDN guard that stops the installer inheriting a stale host is gone",
        )

    def test_outputs_are_not_poisoned_with_empty_document(self):
        src = _deploy_src()
        # A failed `az deployment ... show` must not overwrite good outputs.json
        # with "{}". The old `|| echo '{}'` piped straight into the writer.
        self.assertNotIn(
            "|| echo '{}'",
            src,
            "a suppressed output-read failure still writes {} over known outputs",
        )
        self.assertIn(
            "not overwriting",
            src,
            "no guard that refuses to overwrite outputs.json with an empty document",
        )

    def test_deploy_pins_target_and_drops_ambient_redirectors(self):
        block = _extract_block()
        self.assertIn("O2P_PIN_TARGET=1", block, "deploy no longer signals pinned-target mode")
        self.assertRegex(
            block,
            r"unset PGHOSTADDR PGSERVICE PGSERVICEFILE",
            "deploy no longer drops the ambient libpq destination redirectors",
        )

    def test_installer_clears_redirectors_only_in_pinned_mode(self):
        src = _INSTALLER_SH.read_text()
        self.assertIn("O2P_PIN_TARGET", src, "installer no longer honours pinned-target mode")
        self.assertRegex(
            src,
            r"unset PGHOSTADDR PGSERVICE PGSERVICEFILE",
            "installer no longer clears the redirectors after sourcing .env",
        )
        # No environment opt-out may disable the pin -- naming a flag "trusted"
        # is not approval.
        self.assertNotIn(
            "O2P_TRUSTED_TUNNEL",
            src,
            "an environment opt-out that can disable the deploy pin is present",
        )
        # The pin flag must be captured BEFORE .env is sourced, so a hostile
        # .env (O2P_PIN_TARGET=0) cannot switch it off.
        self.assertLess(
            src.index('PIN_TARGET="${O2P_PIN_TARGET'),
            src.index('. "$ENV_FILE"'),
            "the pin flag is captured after .env, so a hostile .env could switch it off",
        )

    def test_bash_parses(self):
        proc = subprocess.run(
            ["bash", "-n", str(_DEPLOY_SH)], capture_output=True, text=True
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_shellcheck_clean(self):
        if shutil.which("shellcheck") is None:
            self.skipTest("shellcheck not installed")
        proc = subprocess.run(
            [
                "shellcheck",
                "--severity=style",
                "--shell=bash",
                "--external-sources",
                "--exclude=SC1091",
                str(_DEPLOY_SH),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)


class InstallerReachabilityTests(unittest.TestCase):
    """Run the REAL scripts/install-pg-extensions.sh against fake pg_isready /
    psql and assert its EXIT CODE contract, which deploy.sh branches on:
    0 ready, 3 unreachable (pg_isready no-response), any other non-zero =
    reached but a step failed. No Azure, no real Postgres."""

    _INSTALLER = _REPO / "scripts" / "install-pg-extensions.sh"

    _ENV = "\n".join(
        [
            "PGHOST=o2p-pg-testsrv.example",
            "PGPORT=5432",
            "PGUSER=o2padmin",
            "PGPASSWORD=Deployed#Pg#Pw!1",
            "PGDATABASE=contoso_store",
            "SCRATCH_PGDATABASE=migration_scratch",
            "PGSSLMODE=disable",
            "",
        ]
    )

    # pg_isready runs first (the reachability probe), AFTER the installer has
    # pinned/cleared the connection, so it captures the EFFECTIVE destination env
    # the installer would hand to libpq. It records that, then exits with the
    # requested code (0 accepting, 2 no response).
    _PGISREADY = r"""#!/usr/bin/env bash
{
    printf 'PGHOST=%s\n'        "${PGHOST-}"
    printf 'PGHOSTADDR=%s\n'    "${PGHOSTADDR-}"
    printf 'PGPORT=%s\n'        "${PGPORT-}"
    printf 'PGSERVICE=%s\n'     "${PGSERVICE-}"
    printf 'PGSERVICEFILE=%s\n' "${PGSERVICEFILE-}"
    printf 'PGUSER=%s\n'        "${PGUSER-}"
    printf 'PGDATABASE=%s\n'    "${PGDATABASE-}"
} > "$MOCK_CONN_DUMP"
exit "${MOCK_PGISREADY_RC:-0}"
"""

    # psql: answers the three query shapes the installer issues; a marker file
    # records that it was called at all, so we can prove the unreachable path
    # never reaches psql.
    _PSQL = r"""#!/usr/bin/env bash
q=""; prev=""
for a in "$@"; do [ "$prev" = "-c" ] && q="$a"; prev="$a"; done
printf '%s\n' "$q" >> "$MOCK_PSQL_LOG"
case "$q" in
    *"count(*)"*)
        if [ "${MOCK_COUNT_RC:-0}" != "0" ]; then exit "${MOCK_COUNT_RC}"; fi
        printf '0\n'; exit 0 ;;
    *"CREATE EXTENSION"*) exit "${MOCK_CREATE_RC:-0}" ;;
    *"SHOW shared_preload_libraries"*)
        printf '%s\n' "${MOCK_PRELOAD-plpgsql_check,pg_stat_statements}"; exit 0 ;;
    *) exit 0 ;;
esac
"""

    def _run(self, *, env_text=None, extra_env=None, **mock_env):
        work = pathlib.Path(tempfile.mkdtemp(prefix="o2p-installer-"))
        self.addCleanup(shutil.rmtree, work, ignore_errors=True)
        (work / "scripts").mkdir()
        (work / "bin").mkdir()
        shutil.copy2(self._INSTALLER, work / "scripts" / "install-pg-extensions.sh")
        (work / ".env").write_text(env_text if env_text is not None else self._ENV)
        _write_exec(work / "bin" / "pg_isready", self._PGISREADY)
        _write_exec(work / "bin" / "psql", self._PSQL)
        psql_log = work / "psql.log"
        psql_log.write_text("")
        conn_dump = work / "conn.txt"

        env = dict(os.environ)
        env["PATH"] = f"{work / 'bin'}{os.pathsep}" + env.get("PATH", "")
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["MOCK_PSQL_LOG"] = str(psql_log)
        env["MOCK_CONN_DUMP"] = str(conn_dump)
        env.update({k: str(v) for k, v in mock_env.items()})
        if extra_env:
            env.update({k: str(v) for k, v in extra_env.items()})

        proc = subprocess.run(
            ["bash", str(work / "scripts" / "install-pg-extensions.sh")],
            env=env,
            cwd=str(work),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=60,
        )
        conn = {}
        if conn_dump.exists():
            for line in conn_dump.read_text().splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    conn[k] = v
        return proc, psql_log.read_text(), conn

    def test_ready_exits_zero(self):
        proc, _, _ = self._run()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_unreachable_exits_three_without_touching_psql(self):
        proc, psql_log, _ = self._run(MOCK_PGISREADY_RC=2)
        self.assertEqual(proc.returncode, 3, proc.stdout + proc.stderr)
        self.assertEqual(psql_log.strip(), "", "psql ran despite an unreachable server")

    def test_reached_but_query_fails_is_nonzero_and_not_three(self):
        # server answers (pg_isready ok) but the first probe query fails: auth /
        # missing db / permission. Fatal, and NOT the unreachable code.
        proc, psql_log, _ = self._run(MOCK_COUNT_RC=2)
        self.assertNotIn(proc.returncode, (0, 3), proc.stdout + proc.stderr)
        self.assertNotEqual(psql_log.strip(), "", "the reached path should have run psql")

    def test_plpgsql_not_loaded_is_nonzero_and_not_three(self):
        # reachable, extensions create fine, but shared_preload_libraries lacks
        # plpgsql_check: a real, non-network failure, not code 3.
        proc, _, _ = self._run(MOCK_PRELOAD="pg_stat_statements")
        self.assertNotIn(proc.returncode, (0, 3), proc.stdout + proc.stderr)
        self.assertIn("plpgsql_check is NOT loaded", proc.stdout + proc.stderr)

    def test_pinned_mode_clears_redirectors_from_env_and_dotenv(self):
        # Hostile setup: .env RESTORES stale destination redirectors, and the
        # ambient env carries different stale ones alongside the deployed override
        # values (as scripts/deploy.sh passes them). In pin mode the effective
        # connection must be exactly the deployed FQDN/port, every redirector gone
        # -- so libpq (and the fresh admin password) cannot reach another server.
        env_text = "\n".join(
            [
                "PGHOST=stale.old.host.example",
                "PGPORT=15432",
                "PGUSER=olduser",
                "PGPASSWORD=old",
                "PGDATABASE=olddb",
                "SCRATCH_PGDATABASE=oldscratch",
                "PGSSLMODE=disable",
                "PGHOSTADDR=198.51.100.7",       # .env-restored redirector
                "PGSERVICE=dotenv-service",
                "PGSERVICEFILE=/tmp/dotenv.conf",
                "",
            ]
        )
        extra_env = {
            # what scripts/deploy.sh exports/pins into the installer's subshell
            "O2P_PIN_TARGET": "1",
            "PGHOST": "o2p-pg-deployed.postgres.database.azure.com",
            "PGPORT": "5432",
            "PGUSER": "o2padmin_deployed",
            "PGDATABASE": "contoso_deployed",
            "SCRATCH_PGDATABASE": "scratch_deployed",
            "PGPASSWORD": "Deployed#Pg#Pw!1",
            # a hostile ambient redirector the installer must clear too
            "PGHOSTADDR": "203.0.113.9",
            "PGSERVICE": "ambient-service",
        }
        proc, _, conn = self._run(env_text=env_text, extra_env=extra_env)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(conn.get("PGHOST"), "o2p-pg-deployed.postgres.database.azure.com")
        self.assertEqual(conn.get("PGPORT"), "5432")
        self.assertEqual(conn.get("PGUSER"), "o2padmin_deployed")
        self.assertEqual(conn.get("PGDATABASE"), "contoso_deployed")
        self.assertEqual(conn.get("PGHOSTADDR"), "", "PGHOSTADDR redirector survived the pin")
        self.assertEqual(conn.get("PGSERVICE"), "", "PGSERVICE redirector survived the pin")
        self.assertEqual(conn.get("PGSERVICEFILE"), "", "PGSERVICEFILE redirector survived the pin")

    def test_standalone_preserves_redirectors_for_tunnel_use(self):
        # No pin flag: a tunnelled standalone run legitimately sets PGHOSTADDR
        # itself, so the installer must NOT clear it.
        proc, _, conn = self._run(extra_env={"PGHOSTADDR": "127.0.0.9"})
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(
            conn.get("PGHOSTADDR"), "127.0.0.9", "standalone tunnel redirector was cleared"
        )

    def test_dotenv_pin_zero_cannot_switch_off_the_deploy_pin(self):
        # A hostile .env sets O2P_PIN_TARGET=0 and restores redirectors. The pin
        # the deploy turned ON is captured BEFORE .env, so it must still win.
        env_text = "\n".join(
            [
                "PGHOST=stale.old.host.example",
                "PGPORT=15432",
                "PGUSER=olduser",
                "PGPASSWORD=old",
                "PGDATABASE=olddb",
                "SCRATCH_PGDATABASE=oldscratch",
                "PGSSLMODE=disable",
                "O2P_PIN_TARGET=0",              # .env tries to disable the pin
                "PGHOSTADDR=198.51.100.7",
                "PGSERVICE=dotenv-service",
                "",
            ]
        )
        extra_env = {
            "O2P_PIN_TARGET": "1",              # deploy pinned it
            "PGHOST": "o2p-pg-deployed.postgres.database.azure.com",
            "PGPORT": "5432",
            "PGUSER": "o2padmin_deployed",
            "PGDATABASE": "contoso_deployed",
            "SCRATCH_PGDATABASE": "scratch_deployed",
            "PGPASSWORD": "Deployed#Pg#Pw!1",
        }
        proc, _, conn = self._run(env_text=env_text, extra_env=extra_env)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(conn.get("PGHOST"), "o2p-pg-deployed.postgres.database.azure.com")
        self.assertEqual(conn.get("PGHOSTADDR"), "", "an .env O2P_PIN_TARGET=0 undid the pin")
        self.assertEqual(conn.get("PGSERVICE"), "", "an .env O2P_PIN_TARGET=0 undid the pin")

    def test_trusted_tunnel_flag_cannot_disable_the_deploy_pin(self):
        # Naming a flag "trusted" is not approval: neither an ambient nor an .env
        # O2P_TRUSTED_TUNNEL=1 may switch off a deploy pin (the opt-out was removed).
        env_text = "\n".join(
            [
                "PGHOST=stale.old.host.example",
                "PGPORT=15432",
                "PGUSER=olduser",
                "PGPASSWORD=old",
                "PGDATABASE=olddb",
                "SCRATCH_PGDATABASE=oldscratch",
                "PGSSLMODE=disable",
                "O2P_TRUSTED_TUNNEL=1",          # .env tries to opt out
                "PGHOSTADDR=198.51.100.7",
                "",
            ]
        )
        extra_env = {
            "O2P_PIN_TARGET": "1",
            "O2P_TRUSTED_TUNNEL": "1",           # ambient tries to opt out too
            "PGHOST": "o2p-pg-deployed.postgres.database.azure.com",
            "PGPORT": "5432",
            "PGUSER": "o2padmin_deployed",
            "PGDATABASE": "contoso_deployed",
            "SCRATCH_PGDATABASE": "scratch_deployed",
            "PGPASSWORD": "Deployed#Pg#Pw!1",
            "PGHOSTADDR": "203.0.113.9",
        }
        proc, _, conn = self._run(env_text=env_text, extra_env=extra_env)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(conn.get("PGHOSTADDR"), "", "O2P_TRUSTED_TUNNEL disabled the deploy pin")
        self.assertEqual(conn.get("PGHOST"), "o2p-pg-deployed.postgres.database.azure.com")


if __name__ == "__main__":
    unittest.main()
