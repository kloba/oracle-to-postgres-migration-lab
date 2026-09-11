"""Shared opt-in / disposable-local guard for the loader integration tests.

Both ``test_migration_data_loader.py`` and ``test_migration_loader_regressions.py``
import this ONE hardened guard, so the "advertised offline" default discovery can
never touch a database, and an opted-in run can only reach an explicit, local,
disposable PostgreSQL -- never the developer's ambient (Azure/oracle-lab) target.

All decisions happen BEFORE importing psycopg or opening a socket:

  * require ``LOADER_IT_DSN``; unset -> skip;
  * parse with psycopg's own ``conninfo_to_dict`` (import only, no socket);
  * reject a service indirection, any unsupported/override key we could not export
    identically to both connect paths, a missing ``dbname`` or ``host``/``hostaddr``
    (never fall through to the default socket + default database, which could be a
    real local DB), and a remote ``host`` OR ``hostaddr`` -- both are checked,
    across every comma member, because ``hostaddr`` wins for the actual TCP
    address, so ``host=localhost hostaddr=<remote>`` would otherwise go remote;
  * bind the validated params into a fully-cleared ``PG*`` environment for the
    whole class, so the loader's own env-only ``psycopg.connect()`` inside
    ``dl.main()`` targets the same local server as the test's own handle.

This module is not a test module (its name does not match the ``test_*`` /
``test_migration*`` discovery patterns) and defines no ``TestCase`` subclass, so
it is never collected on its own.  ``GuardContractMixin`` is a plain mixin: each
integration test module subclasses it together with ``unittest.TestCase`` so the
same DB-free assertions cover both files.
"""
import contextlib
import ipaddress
import os
import sys
import unittest

IT_DSN_ENV = "LOADER_IT_DSN"

_LOCAL_HOSTNAMES = frozenset({"localhost", "localhost.localdomain"})

# libpq env vars all start with "PG"; the WHOLE ambient set is cleared while a
# class is bound so no omitted field can inherit the developer's environment.
_PG_ENV_PREFIX = "PG"

# The only conninfo keys we accept, each with its libpq env var.  A DSN carrying
# any other key is REJECTED rather than connected: we export exactly these, so an
# unexportable/override key would let the loader's env-only connection silently
# differ from the test's explicit connection.
_CONNINFO_TO_PGENV = {
    "host": "PGHOST", "hostaddr": "PGHOSTADDR", "port": "PGPORT",
    "dbname": "PGDATABASE", "user": "PGUSER", "password": "PGPASSWORD",
    "passfile": "PGPASSFILE", "options": "PGOPTIONS", "sslmode": "PGSSLMODE",
    "sslrootcert": "PGSSLROOTCERT", "sslcert": "PGSSLCERT", "sslkey": "PGSSLKEY",
    "connect_timeout": "PGCONNECT_TIMEOUT", "application_name": "PGAPPNAME",
}


def is_local_host(host):
    """True only for loopback addresses, the localhost names, or a unix-socket
    directory path -- never for a resolvable hostname (no DNS is consulted)."""
    if not host:
        return True                       # empty entry defers to the paired field
    if host.startswith("/") or host.startswith("@"):
        return True                       # unix-socket directory / abstract socket
    normalized = host.strip().lower()
    if normalized in _LOCAL_HOSTNAMES:
        return True
    try:
        return ipaddress.ip_address(normalized).is_loopback
    except ValueError:
        return False                      # a real hostname, e.g. *.azure.com


def all_hosts_local(value):
    """Every comma-separated entry of a libpq host/hostaddr list is local."""
    return all(is_local_host(part.strip()) for part in value.split(","))


def resolve_local_it_params():
    """Validated libpq params for the opt-in disposable LOCAL target, or None to
    SKIP.  Fail-closed: no LOADER_IT_DSN returns None BEFORE importing psycopg or
    opening any socket.  Only after opt-in is psycopg imported (to parse, not
    connect); the rejections above all fire before anything connects."""
    dsn = os.environ.get(IT_DSN_ENV)
    if not dsn:
        return None
    try:
        from psycopg import conninfo
    except Exception:
        return None
    try:
        params = conninfo.conninfo_to_dict(dsn)
    except Exception:
        return None
    if any(key not in _CONNINFO_TO_PGENV for key in params):
        return None                       # unsupported/override key (service, ...)
    if not params.get("dbname"):
        return None                       # require an explicit disposable database
    if not (params.get("host") or params.get("hostaddr")):
        return None                       # require an explicit local target, not a socket
    for field in ("host", "hostaddr"):
        value = params.get(field)
        if value and not all_hosts_local(value):
            return None
    return params


def snapshot_pg_env():
    return {k: v for k, v in os.environ.items() if k.startswith(_PG_ENV_PREFIX)}


def apply_pg_env(params):
    """Clear the ENTIRE ambient libpq environment, then export exactly the
    validated params.  Both connect paths then see identical, explicit
    parameters and nothing inherited."""
    for key in [k for k in os.environ if k.startswith(_PG_ENV_PREFIX)]:
        del os.environ[key]
    for key, value in params.items():
        os.environ[_CONNINFO_TO_PGENV[key]] = str(value)


def restore_pg_env(saved):
    for key in [k for k in os.environ if k.startswith(_PG_ENV_PREFIX)]:
        del os.environ[key]
    os.environ.update(saved)


def _connect(params):
    try:
        import psycopg
    except Exception:
        return None
    kwargs = dict(params)
    kwargs.setdefault("connect_timeout", "5")
    try:
        return psycopg.connect(autocommit=True, **kwargs)
    except Exception:
        return None


def db_available():
    """An autocommit connection to the opt-in disposable LOCAL target, or None to
    SKIP.  Fail-closed: an unset/invalid LOADER_IT_DSN returns None without opening
    a socket.  Connects with the explicit validated params (not the raw env)."""
    params = resolve_local_it_params()
    if params is None:
        return None
    return _connect(params)


def bind_local_target(testcls):
    """setUpClass helper.  Resolve+validate the opt-in DSN (SkipTest if not opted
    in), snapshot and CLEAR the whole PG* environment, export the validated params
    so the loader's env-only connection targets the LOCAL server too, and register
    the env restore + connection close via addClassCleanup (both BEFORE the caller
    runs any DDL, so every exit path -- including a setUpClass failure -- unwinds).
    Returns a live autocommit connection; the caller registers its own schema-drop
    cleanup AFTER this (LIFO => drop runs before close/restore)."""
    params = resolve_local_it_params()
    if params is None:
        raise unittest.SkipTest(
            "integration tests are opt-in: set %s to a disposable LOCAL "
            "PostgreSQL DSN" % IT_DSN_ENV)
    testcls._saved_pg_env = snapshot_pg_env()
    testcls.addClassCleanup(restore_pg_env, testcls._saved_pg_env)
    apply_pg_env(params)
    conn = _connect(params)
    if conn is None:
        raise unittest.SkipTest(
            "%s did not yield a usable LOCAL connection" % IT_DSN_ENV)
    testcls.addClassCleanup(conn.close)
    return conn


# --------------------------------------------------------------------------- #
# DB-free test doubles + reusable guard-contract assertions                    #
# --------------------------------------------------------------------------- #
@contextlib.contextmanager
def env(**overrides):
    """Set (str value) or unset (None value) environment variables, restoring
    the previous state afterwards."""
    saved = {k: os.environ.get(k) for k in overrides}
    try:
        for key, value in overrides.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        yield
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


@contextlib.contextmanager
def pg_env_sandbox(**initial):
    """Give the body a clean libpq environment: snapshot and remove every PG*
    var, set only `initial`, and restore the snapshot verbatim on exit."""
    saved = {k: v for k, v in os.environ.items() if k.startswith(_PG_ENV_PREFIX)}
    for key in list(saved):
        del os.environ[key]
    try:
        for key, value in initial.items():
            os.environ[key] = value
        yield
    finally:
        for key in [k for k in os.environ if k.startswith(_PG_ENV_PREFIX)]:
            del os.environ[key]
        os.environ.update(saved)


class _FakeConninfo:
    """Stand-in for psycopg.conninfo: returns a preloaded dict per DSN."""

    def __init__(self, mapping):
        self._mapping = mapping

    def conninfo_to_dict(self, dsn):
        return dict(self._mapping[dsn])


class FakePsycopg:
    """Stands in for the psycopg module; connect() must never be reached."""

    def __init__(self, mapping=None):
        self.conninfo = _FakeConninfo(mapping or {})
        self.connect_calls = 0

    def connect(self, *args, **kwargs):
        self.connect_calls += 1
        raise AssertionError("psycopg.connect must not be called by the guard")


@contextlib.contextmanager
def fake_psycopg(fake):
    saved = sys.modules.get("psycopg")
    had = "psycopg" in sys.modules
    sys.modules["psycopg"] = fake
    try:
        yield
    finally:
        if had:
            sys.modules["psycopg"] = saved
        else:
            sys.modules.pop("psycopg", None)


class GuardContractMixin:
    """Reusable DB-free proof that the shared opt-in guard is fail-closed and
    binds only an explicit LOCAL target.  Subclass together with unittest.TestCase
    in each integration test module so both are covered by the same assertions.
    A fake psycopg (fake conninfo + a connect() that raises) is installed, so the
    suite runs even without psycopg installed and any real connection attempt
    would fail loudly -- the guard must decide before reaching it."""

    def _assert_rejected(self, dsn, parsed):
        fake = FakePsycopg({dsn: parsed})
        with fake_psycopg(fake), env(**{IT_DSN_ENV: dsn}):
            self.assertIsNone(resolve_local_it_params())
            self.assertIsNone(db_available())
        self.assertEqual(fake.connect_calls, 0)

    def test_no_opt_in_returns_none_before_import_or_connect(self):
        fake = FakePsycopg()
        with fake_psycopg(fake), env(**{
                IT_DSN_ENV: None,
                "PGHOST": "contoso.postgres.database.azure.com",
                "PGDATABASE": "prod", "PGUSER": "admin"}):
            self.assertIsNone(resolve_local_it_params())
            self.assertIsNone(db_available())
        self.assertEqual(fake.connect_calls, 0)

    def test_remote_host_refused(self):
        self._assert_rejected(
            "host=contoso.postgres.database.azure.com dbname=prod user=admin",
            {"host": "contoso.postgres.database.azure.com",
             "dbname": "prod", "user": "admin"})

    def test_local_host_but_remote_hostaddr_refused(self):
        # hostaddr wins for the actual TCP address: a local host= must not smuggle
        # a remote hostaddr= past the guard.
        self._assert_rejected(
            "host=localhost hostaddr=192.0.2.1 dbname=loader_it",
            {"host": "localhost", "hostaddr": "192.0.2.1", "dbname": "loader_it"})

    def test_multi_host_with_remote_member_refused(self):
        self._assert_rejected(
            "host=localhost,10.0.0.4 dbname=loader_it",
            {"host": "localhost,10.0.0.4", "dbname": "loader_it"})

    def test_multi_hostaddr_with_remote_member_refused(self):
        self._assert_rejected(
            "hostaddr=127.0.0.1,192.0.2.1 dbname=loader_it",
            {"hostaddr": "127.0.0.1,192.0.2.1", "dbname": "loader_it"})

    def test_service_indirection_refused(self):
        self._assert_rejected("service=prod dbname=x",
                              {"service": "prod", "dbname": "x"})

    def test_unsupported_override_key_refused(self):
        self._assert_rejected(
            "host=127.0.0.1 dbname=loader_it target_session_attrs=read-write",
            {"host": "127.0.0.1", "dbname": "loader_it",
             "target_session_attrs": "read-write"})

    def test_missing_dbname_refused(self):
        self._assert_rejected("host=127.0.0.1", {"host": "127.0.0.1"})

    def test_missing_host_and_hostaddr_refused(self):
        self._assert_rejected("dbname=loader_it", {"dbname": "loader_it"})

    def test_local_dsn_accepted_and_exports_consistent_pg_env(self):
        dsn = ("host=127.0.0.1 port=55432 dbname=loader_it user=me "
               "sslmode=disable")
        parsed = {"host": "127.0.0.1", "port": "55432", "dbname": "loader_it",
                  "user": "me", "sslmode": "disable"}
        fake = FakePsycopg({dsn: parsed})
        with fake_psycopg(fake), env(**{IT_DSN_ENV: dsn}), pg_env_sandbox(
                PGHOST="azure.example.com", PGPORT="5432", PGDATABASE="prod",
                PGUSER="admin", PGOPTIONS="-c x=y"):
            params = resolve_local_it_params()
            self.assertIsNotNone(params)
            apply_pg_env(params)
            self.assertEqual(os.environ["PGHOST"], "127.0.0.1")
            self.assertEqual(os.environ["PGPORT"], "55432")
            self.assertEqual(os.environ["PGDATABASE"], "loader_it")
            self.assertEqual(os.environ["PGUSER"], "me")
            self.assertEqual(os.environ["PGSSLMODE"], "disable")
            self.assertNotIn("PGOPTIONS", os.environ)   # omitted => no ambient inherit
        self.assertEqual(fake.connect_calls, 0)

    def test_locality_classification(self):
        for local in ("localhost", "127.0.0.1", "127.0.0.5", "::1",
                      "/var/run/postgresql", "", None):
            self.assertTrue(is_local_host(local), local)
        for remote in ("contoso.postgres.database.azure.com", "10.0.0.4",
                       "192.168.1.9", "db.internal"):
            self.assertFalse(is_local_host(remote), remote)

    def test_apply_clears_all_pg_and_omitted_do_not_inherit(self):
        with pg_env_sandbox(PGHOST="azure.example.com", PGPORT="5432",
                            PGDATABASE="prod", PGUSER="admin",
                            PGOPTIONS="-c x=y", PGSSLMODE="require",
                            PGHOSTADDR="10.0.0.4"):
            apply_pg_env({"host": "127.0.0.1", "dbname": "loader_it",
                          "user": "me"})
            self.assertEqual(os.environ["PGHOST"], "127.0.0.1")
            self.assertEqual(os.environ["PGDATABASE"], "loader_it")
            self.assertEqual(os.environ["PGUSER"], "me")
            for absent in ("PGPORT", "PGOPTIONS", "PGSSLMODE", "PGHOSTADDR"):
                self.assertNotIn(absent, os.environ)

    def test_snapshot_restore_round_trips_full_pg_env(self):
        with pg_env_sandbox(PGHOST="azure.example.com", PGSERVICE="prod"):
            snapshot = snapshot_pg_env()
            apply_pg_env({"host": "127.0.0.1", "dbname": "loader_it"})
            self.assertEqual(os.environ["PGHOST"], "127.0.0.1")
            self.assertNotIn("PGSERVICE", os.environ)
            restore_pg_env(snapshot)
            self.assertEqual(os.environ.get("PGHOST"), "azure.example.com")
            self.assertEqual(os.environ.get("PGSERVICE"), "prod")
            self.assertNotIn("PGDATABASE", os.environ)
