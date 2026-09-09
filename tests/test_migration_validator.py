"""Unit tests for the isolated PostgreSQL migration validator.

Contoso Store -- Oracle to Azure Database for PostgreSQL migration lab.

These tests never touch a live database or a real Docker daemon: pure helpers
are exercised directly, and :func:`validator.validate` is driven through a fake
``subprocess.run`` that dispatches on the command shape and the SQL fed to psql.
They assert the failure modes, the pass/fail/blocked status logic, CSV parsing,
and that the one uniquely-created container is always torn down.

Run with:  python3 -m unittest tests.test_migration_validator  (from repo root)
       or:  python3 tests/test_migration_validator.py
"""

import importlib.util
import pathlib
import subprocess
import sys
import unittest
from unittest import mock

_REPO = pathlib.Path(__file__).resolve().parents[1]
_MODULE_PATH = _REPO / "tools" / "migration_team" / "validator.py"
_spec = importlib.util.spec_from_file_location("migration_validator", _MODULE_PATH)
validator = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(validator)


def _cp(cmd, returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess(cmd, returncode, stdout, stderr)


class PureHelperTests(unittest.TestCase):
    def test_sha256_matches_hashlib(self):
        import hashlib
        import tempfile

        with tempfile.NamedTemporaryFile("wb", delete=False) as fh:
            fh.write(b"CREATE TABLE t();")
            path = pathlib.Path(fh.name)
        self.addCleanup(path.unlink)
        self.assertEqual(validator._sha256(path), hashlib.sha256(b"CREATE TABLE t();").hexdigest())

    def test_metacommand_detection(self):
        self.assertTrue(validator._has_metacommand("\\quit"))
        self.assertTrue(validator._has_metacommand("SELECT 1;\n   \\q"))   # indented
        self.assertTrue(validator._has_metacommand("\\! rm -rf /"))
        # inline metacommands, not only at line start
        self.assertTrue(validator._has_metacommand("SELECT 1; \\quit"))
        self.assertTrue(validator._has_metacommand("SELECT 1 \\g"))
        self.assertTrue(validator._has_metacommand("SELECT 1; \\set ON_ERROR_STOP 0"))
        # literal backslashes that must NOT be flagged
        self.assertFalse(validator._has_metacommand("SELECT E'\\n' AS nl;"))       # E-string escape
        self.assertFalse(validator._has_metacommand("SELECT 'a\\b' AS s;"))        # standard-string backslash
        self.assertFalse(validator._has_metacommand("SELECT E'a\\'b\\c' AS s;"))   # E-string escaped quote + backslash
        self.assertFalse(validator._has_metacommand("SELECT '; \\quit ;' AS s;"))  # backslash inside a literal
        self.assertFalse(validator._has_metacommand(
            "CREATE FUNCTION f() RETURNS text LANGUAGE plpgsql AS $$ BEGIN RETURN 'a\\b'; END $$;"))
        self.assertFalse(validator._has_metacommand("SELECT 1 /* \\q in a comment */;"))
        self.assertFalse(validator._has_metacommand("CREATE TABLE t(id int);"))

    def test_leading_keyword_skips_comments(self):
        self.assertEqual(validator._leading_keyword("  SELECT 1"), "SELECT")
        self.assertEqual(validator._leading_keyword("-- hi\nWITH x AS (SELECT 1) SELECT * FROM x"), "WITH")
        self.assertEqual(validator._leading_keyword("/* block */\nselect 1"), "SELECT")
        self.assertEqual(validator._leading_keyword("DO $$ BEGIN END $$"), "DO")

    def test_static_check_checks_sql(self):
        self.assertIsNone(validator._static_check_checks_sql("SELECT 'a' AS check_name, true AS passed"))
        self.assertIsNone(validator._static_check_checks_sql("WITH x AS (SELECT 1) SELECT 'a', true"))
        self.assertIsNotNone(validator._static_check_checks_sql("   "))
        self.assertIsNotNone(validator._static_check_checks_sql("DELETE FROM audit_log"))
        self.assertIsNotNone(validator._static_check_checks_sql("SELECT 1;\n\\q"))
        self.assertIsNotNone(validator._static_check_checks_sql("SELECT 1; \\quit"))  # inline
        self.assertIsNotNone(validator._static_check_checks_sql("DO $$ BEGIN END $$"))

    def test_parse_behaviour_csv_variants(self):
        self.assertEqual(validator._parse_behaviour_csv("a,t\nb,t\n")[0], "pass")
        self.assertEqual(len(validator._parse_behaviour_csv("a,t\nb,t\n")[1]), 2)
        self.assertEqual(validator._parse_behaviour_csv("a,t\nb,f\n")[0], "fail")
        self.assertEqual(validator._parse_behaviour_csv("a,t\na,t\n")[0], "block")        # dup name
        self.assertEqual(validator._parse_behaviour_csv("a,%s\n" % validator.NULL_MARKER)[0], "block")  # NULL passed
        self.assertEqual(validator._parse_behaviour_csv("%s,t\n" % validator.NULL_MARKER)[0], "block")  # NULL name
        self.assertEqual(validator._parse_behaviour_csv(",t\n")[0], "block")              # empty name
        self.assertEqual(validator._parse_behaviour_csv("")[0], "block")                  # empty output
        self.assertEqual(validator._parse_behaviour_csv("a,t,extra\n")[0], "block")       # wrong shape
        self.assertEqual(validator._parse_behaviour_csv("a,maybe\n")[0], "block")         # non-boolean

    def test_parse_discovery_and_build_deep_sql(self):
        csv_text = (
            "111,contoso.fn_plain,f,%s\n"
            "222,contoso.trg_fn,t,333\n"
            "444,contoso.orphan_trg,t,%s\n"
        ) % (validator.NULL_MARKER, validator.NULL_MARKER)
        routines = validator._parse_discovery_csv(csv_text)
        self.assertEqual(len(routines), 3)
        self.assertEqual(routines[0]["relids"], [])
        self.assertEqual(routines[1]["relids"], ["333"])

        sql, blocked = validator._build_deep_sql(routines)
        self.assertIn("plpgsql_check_function_tb(111::oid::regprocedure, 0::oid::regclass)", sql)
        self.assertIn("plpgsql_check_function_tb(222::oid::regprocedure, 333::oid::regclass)", sql)
        self.assertEqual(len(blocked), 1)
        self.assertEqual(blocked[0]["fqname"], "contoso.orphan_trg")

    def test_build_deep_sql_empty_and_all_blocked(self):
        self.assertEqual(validator._build_deep_sql([]), (None, []))
        only_orphan = [{"oid": "5", "fqname": "x.t", "is_trigger": True, "relids": []}]
        sql, blocked = validator._build_deep_sql(only_orphan)
        self.assertIsNone(sql)
        self.assertEqual(len(blocked), 1)

    def test_parse_deep_csv(self):
        rows = validator._parse_deep_csv("x.f,error,column c does not exist\nx.f,warning,unused var\n")
        self.assertEqual(rows[0][1], "error")
        self.assertEqual(len(rows), 2)

    def test_combine_status_matrix(self):
        self.assertEqual(validator._combine_status(False, "pass", "pass"), "failed")
        self.assertEqual(validator._combine_status(True, "pass", "pass"), "passed")
        self.assertEqual(validator._combine_status(True, "fail", "pass"), "failed")
        self.assertEqual(validator._combine_status(True, "pass", "block"), "blocked")
        self.assertEqual(validator._combine_status(True, "block", "fail"), "blocked")


# --------------------------------------------------------------------------- #
# validate() driven through a fake docker/psql layer.
# --------------------------------------------------------------------------- #
class FakeDocker:
    """Dispatches subprocess.run calls the way the real docker/psql would.

    Attributes let a test steer specific phases: compile_rc, admin_rc,
    discovery_out, deep_out, behaviour_out, ready_ok.
    """

    def __init__(self, image_present=True, docker_up=True):
        self.image_present = image_present
        self.docker_up = docker_up
        self.ready_ok = True
        self.run_rc = 0                    # docker run exit code
        self.run_raises = False            # simulate a `docker run` timeout
        self.admin_rc = 0
        self.compile_rc = 0
        self.compile_err = "ERROR: syntax error at or near \"CRETE\""
        self.discovery_out = ""            # no candidate routines by default
        self.deep_out = ""                 # no findings
        self.behaviour_out = "chk_alpha,t\nchk_beta,t\n"
        self.behaviour_rc = 0
        self.calls = []
        self.removed = []

    def __call__(self, cmd, input=None, capture_output=None, text=None, timeout=None, **kw):
        self.calls.append((list(cmd), input))
        if cmd[:2] == ["docker", "version"]:
            return _cp(cmd, 0 if self.docker_up else 1, "16.4" if self.docker_up else "",
                       "" if self.docker_up else "Cannot connect to the Docker daemon")
        if cmd[:3] == ["docker", "image", "inspect"]:
            return _cp(cmd, 0 if self.image_present else 1,
                       "sha256:abc" if self.image_present else "", "No such image")
        if cmd[:3] == ["docker", "run", "-d"]:
            if self.run_raises:
                raise subprocess.TimeoutExpired(cmd, timeout or 1)
            name = cmd[cmd.index("--name") + 1]
            return _cp(cmd, self.run_rc, name + "\n" if self.run_rc == 0 else "",
                       "" if self.run_rc == 0 else "docker run failed")
        if cmd[:2] == ["docker", "rm"]:      # rm -fv <name>
            self.removed.append(cmd[-1])
            return _cp(cmd, 0)
        if cmd[:2] == ["docker", "exec"]:
            return self._exec(cmd, input)
        raise AssertionError("unexpected command: %r" % (cmd,))

    def _exec(self, cmd, stdin):
        # readiness probe: docker exec <name> pg_isready -h 127.0.0.1 ...
        if "pg_isready" in cmd:
            return _cp(cmd, 0, "accepting connections\n") if self.ready_ok \
                else _cp(cmd, 2, "", "no response")
        stdin = stdin or ""
        if stdin.strip() == "SELECT version();":
            return _cp(cmd, 0, "PostgreSQL 16.4 (Debian) on x86_64\n")
        if "CREATE ROLE" in stdin:
            return _cp(cmd, self.admin_rc, "", "" if self.admin_rc == 0 else "role setup boom")
        if "--single-transaction" in cmd:  # compile phase
            return _cp(cmd, self.compile_rc, "", "" if self.compile_rc == 0 else self.compile_err)
        if "FROM pg_proc" in stdin:         # discovery
            return _cp(cmd, 0, self.discovery_out)
        if "plpgsql_check_function_tb" in stdin:  # deep
            return _cp(cmd, 0, self.deep_out)
        if "SET TRANSACTION READ ONLY" in stdin:  # behaviour
            return _cp(cmd, self.behaviour_rc, self.behaviour_out,
                       "" if self.behaviour_rc == 0 else "ERROR: column does not exist")
        raise AssertionError("unexpected psql stdin: %r" % (stdin[:80],))


class ValidateTests(unittest.TestCase):
    def setUp(self):
        self._tmp = pathlib.Path(__file__).resolve().parent / "_tmp_validator"
        self._tmp.mkdir(exist_ok=True)
        self.candidate = self._tmp / "candidate.sql"
        self.checks = self._tmp / "checks.sql"
        self.candidate.write_text("CREATE FUNCTION contoso.f() RETURNS int LANGUAGE sql AS 'SELECT 1';")
        self.checks.write_text("SELECT 'exists' AS check_name, true AS passed")

    def tearDown(self):
        import shutil
        shutil.rmtree(self._tmp, ignore_errors=True)

    def _run(self, fake, **kw):
        with mock.patch.object(validator.subprocess, "run", fake), \
             mock.patch.object(validator.time, "sleep", lambda *_: None):
            return validator.validate(self.candidate, self.checks, **kw)

    # ---- file / preflight gates (no container) --------------------------- #
    def test_missing_checks_is_blocked_without_docker(self):
        fake = FakeDocker()
        missing = self._tmp / "nope.sql"
        with mock.patch.object(validator.subprocess, "run", fake):
            result = validator.validate(self.candidate, missing)
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(fake.calls, [])  # never reached docker
        self.assertEqual(result["engine"], validator.ENGINE)

    def test_empty_checks_is_blocked(self):
        self.checks.write_text("   \n")
        result = self._run(FakeDocker())
        self.assertEqual(result["status"], "blocked")

    def test_non_readonly_checks_is_blocked(self):
        self.checks.write_text("DELETE FROM audit_log")
        fake = FakeDocker()
        result = self._run(fake)
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(fake.calls, [])  # rejected before any container work

    def test_docker_daemon_down_is_blocked(self):
        result = self._run(FakeDocker(docker_up=False))
        self.assertEqual(result["status"], "blocked")
        self.assertIn("daemon", result["log"].lower())

    def test_docker_binary_missing_is_blocked(self):
        def boom(*a, **k):
            raise FileNotFoundError("docker")
        with mock.patch.object(validator.subprocess, "run", boom):
            result = validator.validate(self.candidate, self.checks)
        self.assertEqual(result["status"], "blocked")

    def test_missing_image_fails_closed(self):
        fake = FakeDocker(image_present=False)
        result = self._run(fake)
        self.assertEqual(result["status"], "blocked")
        self.assertIn("build", result["log"].lower())
        # fail closed: never attempts run/pull/build of the container
        self.assertFalse(any(c[0][:3] == ["docker", "run", "-d"] for c in fake.calls))
        # preflight failed before allocation -> no pointless teardown
        self.assertEqual(fake.removed, [])

    def test_docker_run_nonzero_still_cleans_up(self):
        fake = FakeDocker()
        fake.run_rc = 1
        result = self._run(fake)
        self.assertEqual(result["status"], "blocked")
        run_name = next(c[0][c[0].index("--name") + 1] for c in fake.calls
                        if c[0][:3] == ["docker", "run", "-d"])
        self.assertEqual(fake.removed, [run_name])  # torn down by known name

    def test_docker_run_timeout_still_cleans_up(self):
        fake = FakeDocker()
        fake.run_raises = True  # docker run created a container then timed out
        result = self._run(fake)
        self.assertEqual(result["status"], "blocked")
        run_name = next(c[0][c[0].index("--name") + 1] for c in fake.calls
                        if c[0][:3] == ["docker", "run", "-d"])
        self.assertEqual(fake.removed, [run_name])  # cleaned up despite no return value

    def test_pgdata_on_tmpfs_no_anonymous_volume(self):
        fake = FakeDocker()
        self._run(fake)
        run_cmd = next(c[0] for c in fake.calls if c[0][:3] == ["docker", "run", "-d"])
        self.assertIn("--tmpfs", run_cmd)
        self.assertIn("/var/lib/postgresql/data", run_cmd)
        # teardown removes volumes too
        self.assertTrue(any(c[0][:2] == ["docker", "rm"] and "-fv" in c[0] for c in fake.calls))

    # ---- full pipeline outcomes ------------------------------------------ #
    def test_happy_path_passes_and_cleans_up(self):
        fake = FakeDocker()
        result = self._run(fake)
        self.assertEqual(result["status"], "passed")
        names = [c[0][cmd_i + 1] for c in fake.calls
                 for cmd_i, tok in enumerate(c[0]) if tok == "--name"]
        self.assertEqual(len(fake.removed), 1)
        self.assertIn(fake.removed[0], names)  # only the container we created
        # password / admin SQL must never leak into the returned artefact
        self.assertNotIn("CREATE ROLE", result["log"])
        self.assertNotIn("PASSWORD", result["log"])
        self.assertEqual(result["candidate_sha256"], validator._sha256(self.candidate))
        self.assertIsNone(result["dependencies_sha256"])
        self.assertIn("16.4", result["log"])  # version reported
        self.assertIn("sha256:abc", result["log"])  # image id recorded for reproducibility

    def test_compile_failure_is_failed_and_skips_downstream(self):
        fake = FakeDocker()
        fake.compile_rc = 1
        result = self._run(fake)
        self.assertEqual(result["status"], "failed")
        compile_entry = next(c for c in result["checks"] if c["name"] == "compile")
        self.assertFalse(compile_entry["passed"])
        # no deep/behaviour entries after a compile failure
        self.assertFalse(any(c["name"] == "deep-check" for c in result["checks"]))
        self.assertEqual(len(fake.removed), 1)

    def test_behaviour_false_is_failed(self):
        fake = FakeDocker()
        fake.behaviour_out = "chk_alpha,t\nchk_beta,f\n"
        result = self._run(fake)
        self.assertEqual(result["status"], "failed")
        self.assertIn("chk_beta", [c["name"] for c in result["checks"]])

    def test_malformed_checks_output_is_blocked(self):
        fake = FakeDocker()
        fake.behaviour_out = "chk_alpha,t\nchk_alpha,t\n"  # duplicate name
        result = self._run(fake)
        self.assertEqual(result["status"], "blocked")

    def test_deep_error_finding_is_failed(self):
        fake = FakeDocker()
        fake.discovery_out = "111,contoso.fn,f,%s\n" % validator.NULL_MARKER
        fake.deep_out = "contoso.fn,error,record \"r\" has no field \"x\"\n"
        result = self._run(fake)
        self.assertEqual(result["status"], "failed")
        self.assertTrue(any(c["name"] == "deep:contoso.fn" and not c["passed"]
                            for c in result["checks"]))

    def test_deep_warning_only_still_passes(self):
        fake = FakeDocker()
        fake.discovery_out = "111,contoso.fn,f,%s\n" % validator.NULL_MARKER
        fake.deep_out = "contoso.fn,warning,unused variable\n"
        result = self._run(fake)
        self.assertEqual(result["status"], "passed")

    def test_deep_advisory_findings_retained_not_hidden(self):
        fake = FakeDocker()
        fake.discovery_out = "111,contoso.fn,f,%s\n" % validator.NULL_MARKER
        fake.deep_out = ("contoso.fn,warning,target row variable is never read\n"
                         "contoso.fn,performance,SELECT INTO with no index\n"
                         "contoso.fn,security,function is SECURITY DEFINER\n")
        result = self._run(fake)
        self.assertEqual(result["status"], "passed")  # advisories do not fail
        details = " | ".join(c["detail"] for c in result["checks"])
        self.assertIn("never read", details)          # warning surfaced
        self.assertIn("no index", details)            # performance surfaced
        self.assertIn("SECURITY DEFINER", details)    # security surfaced
        # advisory entries are non-failing but present
        advisory = [c for c in result["checks"]
                    if c["name"] == "deep:contoso.fn" and c["passed"]]
        self.assertEqual(len(advisory), 3)
        self.assertIn("advisory finding", result["log"])
        self.assertIn("no index", result["log"])      # findings in the log too

    def test_orphan_trigger_routine_is_blocked_not_skipped(self):
        fake = FakeDocker()
        fake.discovery_out = "444,contoso.orphan_trg,t,%s\n" % validator.NULL_MARKER
        result = self._run(fake)
        self.assertEqual(result["status"], "blocked")
        self.assertTrue(any("orphan_trg" in c["name"] for c in result["checks"]))

    def test_infra_failure_still_cleans_up_container(self):
        fake = FakeDocker()
        fake.admin_rc = 1  # admin setup fails -> _Blocked mid-pipeline
        result = self._run(fake)
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(len(fake.removed), 1)  # container torn down despite failure

    def test_dependencies_hash_and_single_transaction(self):
        deps = self._tmp / "deps.sql"
        deps.write_text("CREATE TABLE contoso.dep(id int);")
        fake = FakeDocker()
        result = self._run(fake, dependencies=deps)
        self.assertEqual(result["dependencies_sha256"], validator._sha256(deps))
        # compile stdin carried BOTH deps and candidate in one --single-transaction call
        compile_calls = [c for c in fake.calls if "--single-transaction" in c[0]]
        self.assertEqual(len(compile_calls), 1)
        self.assertIn("contoso.dep", compile_calls[0][1])
        self.assertIn("contoso.f", compile_calls[0][1])

    def test_candidate_metacommand_is_rejected_as_compile_failure(self):
        self.candidate.write_text("CREATE TABLE contoso.x(id int);\n\\! echo pwned")
        fake = FakeDocker()
        result = self._run(fake)
        self.assertEqual(result["status"], "failed")
        # never sent to psql for compilation
        self.assertFalse(any("--single-transaction" in c[0] for c in fake.calls))
        self.assertEqual(len(fake.removed), 1)

    def test_result_has_full_contract_keys(self):
        result = self._run(FakeDocker())
        for key in ("status", "candidate_sha256", "checks_sha256", "dependencies_sha256",
                    "engine", "image", "checks", "log", "started_at"):
            self.assertIn(key, result)
        self.assertEqual(result["image"], validator.DEFAULT_IMAGE)
        self.assertTrue(result["started_at"].endswith("+00:00"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
