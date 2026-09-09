"""Bounded, isolated, non-LLM validation of a converted PostgreSQL candidate.

Contoso Store -- Oracle to Azure Database for PostgreSQL migration lab.

This is the local, offline analogue of the conversion tool's Stage 4 ("the
compiler is the arbiter") and Stage 5 (plpgsql_check deep validation); see
docs/architecture.md. It answers one question for the Copilot migration team:
does a converted object compile, pass static deep-checking, and satisfy a set
of read-only behavioural assertions -- checked by something that cannot be
argued with, a real PostgreSQL 16 server, not a model.

Each call to :func:`validate` spins up ONE private, disposable Docker container
(``--network none``, no published ports, no host filesystem or docker-socket
mounts, RAM/CPU/PID limits) from a pre-built image, runs three phases against
it, and destroys the container in a ``finally`` block. It fails *closed*: if
Docker is unavailable, the image is missing, the container never comes up, or a
step exceeds the time budget, the result is ``blocked`` -- never a false
``passed``.

Build the image explicitly first (this module never builds or pulls it)::

    docker build -f tools/migration_team/Dockerfile \\
      -t o2p-migration-validator:pg16 tools/migration_team

Threat model, stated honestly: the candidate is raw SQL authored by an LLM,
which may contain arbitrary DDL/DML. The container isolates the *host* (no
network, no mounts, bounded resources) and the *validation harness* (psql
metacommands are rejected so a candidate cannot ``\\quit`` its way to a false
pass; the candidate runs as a non-superuser role that cannot touch the checking
extensions or core roles; behavioural checks run in a READ ONLY transaction and
their output is machine-parsed, so a ``DO`` block cannot fabricate a pass). It
is NOT a claim of a security sandbox against a hostile author inside the
database. Server statement/lock timeouts and a host subprocess deadline bound
runtime.

Public contract::

    validate(candidate, checks, dependencies=None,
             image='o2p-migration-validator:pg16', timeout=120) -> dict

Result keys: ``status`` ('passed'|'failed'|'blocked'), ``candidate_sha256``,
``checks_sha256``, ``dependencies_sha256`` (None when absent), ``engine``
('postgresql-disposable-container'), ``image``, ``checks`` (list of
{name, passed, detail}), ``log`` (str), ``started_at`` (UTC ISO 8601).
"""

from __future__ import annotations

import datetime
import hashlib
import pathlib
import re
import secrets
import subprocess
import time
import uuid
from typing import List, Optional, Tuple

ENGINE = "postgresql-disposable-container"
DEFAULT_IMAGE = "o2p-migration-validator:pg16"

# The candidate and behavioural checks run as this non-superuser role; it can
# CREATE in its schemas but cannot alter the checking extensions or core roles.
CANDIDATE_ROLE = "o2p_candidate"
TARGET_DB = "contoso_store"

# Container resource ceilings. Enough for a PL/pgSQL compile + plpgsql_check,
# small enough that a runaway candidate cannot exhaust the host.
MEM_LIMIT = "768m"
CPU_LIMIT = "1.5"
PIDS_LIMIT = "512"

# Server-side ceilings, set on the candidate role so every candidate/behaviour
# session inherits them. The host subprocess deadline is the real hard bound;
# these keep a single pathological statement from eating the whole budget.
STATEMENT_TIMEOUT_MS = 15000
LOCK_TIMEOUT_MS = 5000
IDLE_TX_TIMEOUT_MS = 20000

# COPY renders NULL as this sentinel so a NULL is distinguishable from '' when
# we machine-parse behavioural output.
NULL_MARKER = "@@NULL@@"

# Leading SQL/C-style comments and whitespace, stripped to find the first token.
_LEADING_NOISE_RE = re.compile(r"^(?:\s+|--[^\n]*\n|/\*.*?\*/)+", re.DOTALL)
# A dollar-quote opener: $$ or $tag$ (tag is an unquoted-identifier, no digits first).
_DOLLAR_OPEN_RE = re.compile(r"\$([A-Za-z_][A-Za-z_0-9]*)?\$")


class _Blocked(Exception):
    """Raised for infrastructure failures that make a verdict impossible."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


class _Deadline:
    """A shared wall-clock budget; every subprocess gets what remains of it."""

    def __init__(self, seconds: int):
        self._end = time.monotonic() + max(1, seconds)

    def remaining(self) -> float:
        return self._end - time.monotonic()

    def expired(self) -> bool:
        return self.remaining() <= 0


# --------------------------------------------------------------------------- #
# Pure helpers (unit-testable without Docker).
# --------------------------------------------------------------------------- #
def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _has_metacommand(sql: str) -> bool:
    """True if the SQL contains a psql backslash metacommand.

    psql treats a backslash as a metacommand wherever it is NOT inside a string
    literal, dollar-quoted body, quoted identifier, or comment -- including
    inline, e.g. ``SELECT 1; \\quit`` or ``SELECT 1 \\g``, not only at line
    start. A backslash is never legal SQL outside those contexts (it is not a
    valid operator character), so flagging every such backslash catches the
    bypass without rejecting legitimate literal backslashes like ``E'\\n'``.
    """
    i, n = 0, len(sql)
    while i < n:
        c = sql[i]
        if c == "\\":
            return True
        if c == "'":
            estr = i > 0 and sql[i - 1] in ("E", "e")
            i = _skip_quote(sql, i, "'", backslash_escapes=estr)
        elif c == '"':
            i = _skip_quote(sql, i, '"', backslash_escapes=False)
        elif c == "$":
            j = _skip_dollar_quote(sql, i)
            i = j if j is not None else i + 1
        elif c == "-" and sql[i:i + 2] == "--":
            nl = sql.find("\n", i)
            i = n if nl == -1 else nl + 1
        elif c == "/" and sql[i:i + 2] == "/*":
            i = _skip_block_comment(sql, i)
        else:
            i += 1
    return False


def _skip_quote(sql: str, i: int, q: str, backslash_escapes: bool) -> int:
    """Return the index just past a string/identifier opened by ``q`` at ``i``.
    Doubled quotes escape; in E'' strings a backslash also escapes the next char.
    """
    i += 1
    n = len(sql)
    while i < n:
        c = sql[i]
        if backslash_escapes and c == "\\":
            i += 2
            continue
        if c == q:
            if i + 1 < n and sql[i + 1] == q:  # doubled quote -> literal
                i += 2
                continue
            return i + 1
        i += 1
    return n


def _skip_dollar_quote(sql: str, i: int) -> Optional[int]:
    """If a dollar-quote opens at ``i``, return the index past its close; else
    None (the ``$`` is something else, e.g. a ``$1`` parameter)."""
    m = _DOLLAR_OPEN_RE.match(sql, i)
    if not m:
        return None
    tag = m.group(0)
    close = sql.find(tag, m.end())
    return len(sql) if close == -1 else close + len(tag)


def _skip_block_comment(sql: str, i: int) -> int:
    """Return the index past a (possibly nested) ``/* ... */`` block comment."""
    depth = 0
    n = len(sql)
    while i < n:
        if sql[i:i + 2] == "/*":
            depth += 1
            i += 2
        elif sql[i:i + 2] == "*/":
            depth -= 1
            i += 2
            if depth == 0:
                return i
        else:
            i += 1
    return n


def _leading_keyword(sql: str) -> str:
    """First SQL keyword, upper-cased, after stripping leading comments/space."""
    stripped = _LEADING_NOISE_RE.sub("", sql, count=1).lstrip()
    match = re.match(r"[A-Za-z]+", stripped)
    return match.group(0).upper() if match else ""


def _static_check_checks_sql(sql: str) -> Optional[str]:
    """Reject a checks query we will not run. Returns a reason, or None if ok."""
    if not sql.strip():
        return "checks file is empty"
    if _has_metacommand(sql):
        return "checks file contains a psql metacommand (backslash)"
    if _leading_keyword(sql) not in ("SELECT", "WITH"):
        return "checks query must be a single read-only SELECT/WITH query"
    return None


def _parse_behaviour_csv(text: str) -> Tuple[str, List[dict], str]:
    """Parse ``check_name,passed`` CSV. Returns (result, entries, detail).

    result is 'pass' | 'fail' | 'block'. Malformed output (empty, NULL,
    duplicate names, non-boolean) is 'block' -- we cannot assert correctness.
    """
    import csv
    import io

    entries: List[dict] = []
    rows = list(csv.reader(io.StringIO(text)))
    rows = [r for r in rows if r != []]
    if not rows:
        return "block", entries, "behavioural query returned no rows"

    seen = set()
    result = "pass"
    for row in rows:
        if len(row) != 2:
            return "block", entries, f"expected 2 columns per row, got {len(row)}"
        name, passed = row[0], row[1]
        if name == NULL_MARKER or name == "":
            return "block", entries, "a check has a NULL or empty name"
        if name in seen:
            return "block", entries, f"duplicate check name: {name!r}"
        seen.add(name)
        if passed == "t":
            entries.append({"name": name, "passed": True, "detail": ""})
        elif passed == "f":
            entries.append({"name": name, "passed": False, "detail": "assertion is false"})
            result = "fail"
        else:  # NULL_MARKER or anything non-boolean
            return "block", entries, f"check {name!r} did not return a boolean"
    return result, entries, f"{len(entries)} behavioural assertion(s)"


def _parse_discovery_csv(text: str) -> List[dict]:
    """Parse discovered candidate PL/pgSQL routines into dicts."""
    import csv
    import io

    routines = []
    for row in csv.reader(io.StringIO(text)):
        if not row:
            continue
        oid, fqname, is_trigger, relids = row
        rels = [] if relids in ("", NULL_MARKER) else relids.split(",")
        routines.append(
            {
                "oid": oid,
                "fqname": fqname,
                "is_trigger": is_trigger == "t",
                "relids": rels,
            }
        )
    return routines


def _build_deep_sql(routines: List[dict]) -> Tuple[Optional[str], List[dict]]:
    """Build the plpgsql_check query, and list trigger routines we cannot check.

    A trigger function with no attached trigger has no row context, so
    plpgsql_check cannot validate it -- that is a blocker, not a skip.
    """
    blocked: List[dict] = []
    selects: List[str] = []
    for r in routines:
        if r["is_trigger"]:
            if not r["relids"]:
                blocked.append(r)
                continue
            for relid in r["relids"]:
                selects.append(_deep_select(r["fqname"], r["oid"], relid))
        else:
            selects.append(_deep_select(r["fqname"], r["oid"], "0"))
    if not selects:
        return None, blocked
    body = "\n    UNION ALL\n    ".join(selects)
    sql = (
        "COPY (\n  SELECT fn, level, message FROM (\n    "
        + body
        + "\n  ) q\n) TO STDOUT WITH (FORMAT csv, NULL '" + NULL_MARKER + "');\n"
    )
    return sql, blocked


def _deep_select(fqname: str, oid: str, relid: str) -> str:
    literal = fqname.replace("'", "''")
    return (
        f"SELECT '{literal}' AS fn, level, message "
        f"FROM plpgsql_check_function_tb({oid}::oid::regprocedure, {relid}::oid::regclass)"
    )


def _parse_deep_csv(text: str) -> List[Tuple[str, str, str]]:
    import csv
    import io

    findings = []
    for row in csv.reader(io.StringIO(text)):
        if len(row) >= 3:
            findings.append((row[0], row[1], row[2]))
    return findings


def _combine_status(compile_ok: bool, deep_result: str, beh_result: str) -> str:
    if not compile_ok:
        return "failed"
    if "block" in (deep_result, beh_result):
        return "blocked"
    if "fail" in (deep_result, beh_result):
        return "failed"
    return "passed"


# --------------------------------------------------------------------------- #
# Subprocess / Docker glue.
# --------------------------------------------------------------------------- #
def _run(cmd: List[str], deadline: _Deadline, stdin: Optional[str] = None) -> subprocess.CompletedProcess:
    """Run a command within the remaining budget. Raises _Blocked on timeout or
    a missing docker binary; otherwise returns the completed process."""
    if deadline.expired():
        raise _Blocked("time budget exhausted before running: " + " ".join(cmd[:3]))
    try:
        return subprocess.run(
            cmd,
            input=stdin,
            capture_output=True,
            text=True,
            timeout=max(1.0, deadline.remaining()),
        )
    except subprocess.TimeoutExpired:
        raise _Blocked("timed out running: " + " ".join(cmd[:3]))
    except FileNotFoundError:
        raise _Blocked("docker executable not found on PATH")


def _preflight_docker(image: str, deadline: _Deadline) -> str:
    """Confirm Docker is up and the image exists. Returns the image ID (digest)
    for reproducibility logging. Fails closed: never pulls or builds."""
    ver = _run(["docker", "version", "--format", "{{.Server.Version}}"], deadline)
    if ver.returncode != 0:
        raise _Blocked("Docker daemon is not available: " + ver.stderr.strip())
    got = _run(["docker", "image", "inspect", image, "--format", "{{.Id}}"], deadline)
    if got.returncode != 0:
        raise _Blocked(
            f"image {image!r} is not present; build it first with: "
            f"docker build -f tools/migration_team/Dockerfile -t {image} "
            "tools/migration_team"
        )
    return got.stdout.strip()


def _container_name() -> str:
    return "o2p-mig-val-" + uuid.uuid4().hex[:16]


def _start_container(name: str, image: str, deadline: _Deadline) -> None:
    password = secrets.token_urlsafe(24)  # internal only; never logged/returned
    cmd = [
        "docker", "run", "-d", "--name", name,
        "--network", "none",
        # PGDATA on tmpfs: the postgres image declares a VOLUME there, so a plain
        # bind-less run would leave an anonymous volume behind on every call.
        # tmpfs means no volume is ever created (and the data never touches disk).
        "--tmpfs", "/var/lib/postgresql/data",
        "--memory", MEM_LIMIT, "--memory-swap", MEM_LIMIT,
        "--cpus", CPU_LIMIT, "--pids-limit", PIDS_LIMIT,
        "--security-opt", "no-new-privileges",
        "-e", "POSTGRES_PASSWORD=" + password,
        "-e", "POSTGRES_DB=" + TARGET_DB,
        image,
        "-c", "shared_preload_libraries=plpgsql_check",
    ]
    started = _run(cmd, deadline)
    if started.returncode != 0:
        raise _Blocked("could not start container: " + started.stderr.strip())


def _await_ready(name: str, deadline: _Deadline) -> None:
    """Wait until the *final* server accepts connections.

    The official image runs a throwaway init server first that listens on the
    Unix socket ONLY (``listen_addresses=''``); the final server also listens on
    TCP. So we probe TCP with ``pg_isready -h 127.0.0.1`` -- which the init
    server cannot answer -- to be sure init has finished before we run any SQL.
    (127.0.0.1 is reachable via the loopback interface even under
    ``--network none``.)"""
    cap = min(deadline.remaining(), 90.0)
    stop = time.monotonic() + cap
    while time.monotonic() < stop:
        probe = _run(
            ["docker", "exec", name, "pg_isready",
             "-h", "127.0.0.1", "-p", "5432", "-U", "postgres"],
            deadline,
        )
        if probe.returncode == 0:
            return
        time.sleep(0.5)
    raise _Blocked("container did not become ready within the time budget")


def _psql(name: str, user: str, db: str, sql: str, deadline: _Deadline,
          extra: Tuple[str, ...] = ()) -> subprocess.CompletedProcess:
    cmd = ["docker", "exec", "-i", name, "psql", "-X", "-q",
           "-v", "ON_ERROR_STOP=1", "-U", user, "-d", db, *extra]
    return _run(cmd, deadline, stdin=sql)


def _admin_setup(name: str, password_role: str, deadline: _Deadline) -> str:
    """Create extensions and the non-superuser candidate role. Returns the
    server version string. Runs as the postgres superuser; the candidate never
    sees this SQL (it carries the role password, so it is never logged)."""
    sql = f"""
CREATE EXTENSION IF NOT EXISTS plpgsql_check;
DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS orafce;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'orafce unavailable: %', SQLERRM;
END $$;
DROP ROLE IF EXISTS {CANDIDATE_ROLE};
CREATE ROLE {CANDIDATE_ROLE} LOGIN PASSWORD '{password_role}'
  NOSUPERUSER NOCREATEDB NOCREATEROLE;
ALTER ROLE {CANDIDATE_ROLE} SET statement_timeout = '{STATEMENT_TIMEOUT_MS}ms';
ALTER ROLE {CANDIDATE_ROLE} SET lock_timeout = '{LOCK_TIMEOUT_MS}ms';
ALTER ROLE {CANDIDATE_ROLE} SET idle_in_transaction_session_timeout = '{IDLE_TX_TIMEOUT_MS}ms';
CREATE SCHEMA IF NOT EXISTS contoso AUTHORIZATION {CANDIDATE_ROLE};
GRANT USAGE, CREATE ON SCHEMA public TO {CANDIDATE_ROLE};
ALTER DATABASE {TARGET_DB} SET search_path = "$user", public, contoso, oracle;
"""
    res = _psql(name, "postgres", TARGET_DB, sql, deadline)
    if res.returncode != 0:
        raise _Blocked("admin setup failed: " + res.stderr.strip())
    ver = _psql(name, "postgres", TARGET_DB, "SELECT version();", deadline, extra=("-tA",))
    version = ver.stdout.strip().splitlines()[0] if ver.stdout.strip() else "unknown"
    return version


# --------------------------------------------------------------------------- #
# Validation phases.
# --------------------------------------------------------------------------- #
def _compile(name: str, dependencies_sql: str, candidate_sql: str,
             deadline: _Deadline) -> Tuple[bool, str]:
    """Compile dependencies then candidate in ONE transaction as the candidate
    role. Metacommands are rejected first so a candidate cannot fake success."""
    combined = (dependencies_sql + "\n" + candidate_sql) if dependencies_sql else candidate_sql
    if _has_metacommand(combined):
        return False, "rejected: candidate or dependencies contain a psql metacommand"
    res = _psql(name, CANDIDATE_ROLE, TARGET_DB, combined, deadline, extra=("--single-transaction",))
    if res.returncode == 0:
        return True, "candidate and dependencies compiled in one transaction"
    return False, "compile error: " + (res.stderr.strip() or "unknown error")


def _deep_check(name: str, deadline: _Deadline) -> Tuple[str, List[dict], str]:
    """Run plpgsql_check over every candidate-owned PL/pgSQL routine."""
    discovery = f"""
COPY (
  SELECT p.oid::text,
         quote_ident(n.nspname) || '.' || quote_ident(p.proname),
         -- uncast so COPY renders 't'/'f' (not 'true'/'false') to match the parser
         (p.prorettype = 'pg_catalog.trigger'::regtype),
         (SELECT string_agg(DISTINCT tg.tgrelid::text, ',')
            FROM pg_trigger tg
           WHERE tg.tgfoid = p.oid AND NOT tg.tgisinternal)
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
  WHERE l.lanname = 'plpgsql'
    AND p.proowner = (SELECT oid FROM pg_roles WHERE rolname = '{CANDIDATE_ROLE}')
    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND NOT EXISTS (SELECT 1 FROM pg_depend d
                     WHERE d.classid = 'pg_proc'::regclass
                       AND d.objid = p.oid AND d.deptype = 'e')
) TO STDOUT WITH (FORMAT csv, NULL '{NULL_MARKER}');
"""
    disc = _psql(name, "postgres", TARGET_DB, discovery, deadline)
    if disc.returncode != 0:
        raise _Blocked("deep-check discovery failed: " + disc.stderr.strip())
    routines = _parse_discovery_csv(disc.stdout)

    deep_sql, blocked = _build_deep_sql(routines)
    entries: List[dict] = []
    for r in blocked:
        entries.append(
            {"name": "deep:" + r["fqname"], "passed": False,
             "detail": "trigger function has no attached trigger; cannot deep-check"}
        )

    findings: List[Tuple[str, str, str]] = []
    if deep_sql is not None:
        chk = _psql(name, "postgres", TARGET_DB, deep_sql, deadline)
        if chk.returncode != 0:
            raise _Blocked("plpgsql_check failed to run: " + chk.stderr.strip())
        findings = _parse_deep_csv(chk.stdout)

    # Only 'error'-level findings fail the phase, but every other finding
    # (warning / warning extra / performance / security) is retained as a
    # non-failing diagnostic so the reviewer sees it -- never silently dropped.
    errors = 0
    advisories = 0
    for fn, level, message in findings:
        if level == "error":
            errors += 1
            entries.append({"name": "deep:" + fn, "passed": False,
                            "detail": f"{level}: {message}"})
        else:
            advisories += 1
            entries.append({"name": "deep:" + fn, "passed": True,
                            "detail": f"{level}: {message}"})

    checked = len(routines) - len(blocked)
    detail = (f"{checked} routine(s) deep-checked, {errors} error finding(s), "
              f"{advisories} advisory finding(s), "
              f"{len(blocked)} uncheckable trigger routine(s)")
    if blocked:
        return "block", entries, detail
    if errors:
        return "fail", entries, detail
    return "pass", entries, detail


def _behaviour(name: str, checks_sql: str, deadline: _Deadline) -> Tuple[str, List[dict], str]:
    """Run the behavioural assertions as the non-superuser role inside a READ
    ONLY transaction, forcing exactly the two contracted columns and machine-
    parsing the CSV so a DO block or extra columns cannot fabricate a pass."""
    inner = checks_sql.strip().rstrip(";")
    wrapped = f"""
BEGIN;
SET TRANSACTION READ ONLY;
COPY (
  SELECT check_name, passed::boolean AS passed
  FROM ( {inner} ) AS _checks
) TO STDOUT WITH (FORMAT csv, NULL '{NULL_MARKER}');
COMMIT;
"""
    res = _psql(name, CANDIDATE_ROLE, TARGET_DB, wrapped, deadline)
    if res.returncode != 0:
        return "block", [], "behavioural query is invalid: " + (res.stderr.strip() or "unknown")
    return _parse_behaviour_csv(res.stdout)


# --------------------------------------------------------------------------- #
# Orchestration.
# --------------------------------------------------------------------------- #
def _remove_container(name: str) -> None:
    """Best-effort teardown of the one container we created. Never raises.

    ``-v`` also removes the anonymous volume the postgres image would otherwise
    leave behind; harmless if the container was never created."""
    try:
        subprocess.run(["docker", "rm", "-fv", name], capture_output=True,
                       text=True, timeout=30)
    except Exception:
        pass


def _read_required(path: pathlib.Path, label: str) -> str:
    if not path.exists() or not path.is_file():
        raise _Blocked(f"{label} file does not exist: {path}")
    text = path.read_text(encoding="utf-8", errors="replace")
    if not text.strip():
        raise _Blocked(f"{label} file is empty: {path}")
    return text


def _result(status: str, candidate_sha: Optional[str], checks_sha: Optional[str],
            deps_sha: Optional[str], image: str, checks: List[dict], log: List[str],
            started_at: str) -> dict:
    return {
        "status": status,
        "candidate_sha256": candidate_sha,
        "checks_sha256": checks_sha,
        "dependencies_sha256": deps_sha,
        "engine": ENGINE,
        "image": image,
        "checks": checks,
        "log": "\n".join(log),
        "started_at": started_at,
    }


def validate(candidate: pathlib.Path, checks: pathlib.Path,
             dependencies: Optional[pathlib.Path] = None,
             image: str = DEFAULT_IMAGE, timeout: int = 120) -> dict:
    """Validate a converted PostgreSQL candidate in a disposable container.

    See the module docstring for the full contract. Never raises for a normal
    validation failure -- those return status 'failed'. Infrastructure problems
    (Docker/image/container/timeout) and un-assertable checks return 'blocked'.
    """
    candidate = pathlib.Path(candidate)
    checks = pathlib.Path(checks)
    dependencies = pathlib.Path(dependencies) if dependencies is not None else None

    started_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
    deadline = _Deadline(timeout)
    log: List[str] = []

    candidate_sha = _sha256(candidate) if candidate.is_file() else None
    checks_sha = _sha256(checks) if checks.is_file() else None
    deps_sha = _sha256(dependencies) if (dependencies and dependencies.is_file()) else None

    def blocked(reason: str) -> dict:
        log.append("BLOCKED: " + reason)
        return _result("blocked", candidate_sha, checks_sha, deps_sha, image,
                       [{"name": "validation", "passed": False, "detail": reason}],
                       log, started_at)

    # File-level gates before we pay for a container.
    try:
        candidate_sql = _read_required(candidate, "candidate")
        checks_sql = _read_required(checks, "checks")
    except _Blocked as b:
        return blocked(b.reason)
    if dependencies is not None and not (dependencies.exists() and dependencies.is_file()):
        return blocked(f"dependencies file does not exist: {dependencies}")
    dependencies_sql = dependencies.read_text(encoding="utf-8", errors="replace") if deps_sha else ""

    static_reason = _static_check_checks_sql(checks_sql)
    if static_reason:
        return blocked(static_reason)

    # Preflight before we allocate/attempt a container, so a down daemon or a
    # missing image fails closed without a pointless teardown.
    try:
        image_id = _preflight_docker(image, deadline)
    except _Blocked as b:
        return blocked(b.reason)

    # Allocate the unique name up front and flip `attempted` BEFORE the run, so a
    # `docker run` that creates a container and then times out is still torn down
    # by known name in the finally block.
    name = _container_name()
    attempted = False
    try:
        container_password = secrets.token_urlsafe(24)  # for the candidate role
        attempted = True
        _start_container(name, image, deadline)
        log.append(f"container: {name} (image {image_id})")
        _await_ready(name, deadline)
        version = _admin_setup(name, container_password, deadline)
        log.append("server: " + version)

        compile_ok, compile_detail = _compile(name, dependencies_sql, candidate_sql, deadline)
        result_checks: List[dict] = [
            {"name": "compile", "passed": compile_ok, "detail": compile_detail}
        ]
        log.append("compile: " + ("ok" if compile_ok else "FAILED -- " + compile_detail))

        deep_result, beh_result = "pass", "pass"
        if compile_ok:
            deep_result, deep_entries, deep_detail = _deep_check(name, deadline)
            result_checks.append(
                {"name": "deep-check", "passed": deep_result == "pass", "detail": deep_detail}
            )
            result_checks.extend(deep_entries)
            log.append(f"deep-check ({version}): {deep_result} -- {deep_detail}")
            for entry in deep_entries:  # keep all findings (incl. advisories) in the log
                log.append("  " + entry["name"] + " -- " + entry["detail"])

            beh_result, beh_entries, beh_detail = _behaviour(name, checks_sql, deadline)
            if beh_result == "block":
                result_checks.append(
                    {"name": "behaviour", "passed": False, "detail": "blocked: " + beh_detail}
                )
            else:
                result_checks.extend(beh_entries)
            log.append("behaviour: " + beh_result + " -- " + beh_detail)
        else:
            log.append("deep-check and behaviour skipped: candidate did not compile")

        status = _combine_status(compile_ok, deep_result, beh_result)
        log.append("status: " + status)
        return _result(status, candidate_sha, checks_sha, deps_sha, image,
                       result_checks, log, started_at)
    except _Blocked as b:
        return blocked(b.reason)
    finally:
        if attempted:
            _remove_container(name)


if __name__ == "__main__":  # pragma: no cover -- debug aid; the team CLI is separate
    import argparse
    import json

    parser = argparse.ArgumentParser(description="Isolated PostgreSQL candidate validator")
    parser.add_argument("candidate", type=pathlib.Path)
    parser.add_argument("checks", type=pathlib.Path)
    parser.add_argument("--dependencies", type=pathlib.Path, default=None)
    parser.add_argument("--image", default=DEFAULT_IMAGE)
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    print(json.dumps(validate(args.candidate, args.checks, args.dependencies,
                              args.image, args.timeout), indent=2))
