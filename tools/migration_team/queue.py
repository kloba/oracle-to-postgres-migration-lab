"""Resumable source-object work queue; no LLM or cloud credentials required.

The conversion CSV is a source-to-target mapping, not a list of unique objects.
Keep every mapping, group by source type AND case-sensitive name, and never turn
queue completion into a claimed migration success percentage.

The queue is schema-agnostic: the target schema(s) a candidate is validated
against are configured explicitly (``init --target-schema`` or ``configure``),
never guessed from the CSV. That configuration, together with the source/target
engine labels, is folded into every validation's evidence so that changing it
invalidates a prior review.
"""
import csv
import hashlib
import io
import json
import sqlite3
import uuid
from contextlib import closing, contextmanager
from datetime import datetime, timezone
from pathlib import Path

from .validator import check_schema_names

COLUMNS = (
    "Source_Object_Type", "Source_Object", "Azure_PostgreSQL_Object_Type",
    "Azure_PostgreSQL_Object", "Status", "Action_Required", "Error_Message",
)
FILES = ("source.sql", "candidate.sql", "checks.sql", "dependencies.sql")

# Lifetime validation attempts allowed for a task with no user-authorized grant.
# A grant raises the ceiling for future attempts; this is the ungranted base.
# Single source of truth for the base cap referenced by validation_budget (the
# per-grant increment maximum in budget_admin is a separate concept).
BASE_LIMIT = 3

# This tool implements exactly one engine pair today. Anything else is rejected
# cleanly rather than pretending to be a universal translator.
SUPPORTED_ENGINE_PAIRS = frozenset({("oracle", "postgresql")})


def check_engines(source_engine, target_engine):
    """Normalise and validate the migration engine pair. Returns the canonical
    (source, target) lowercase tuple, or raises ValueError for an unsupported
    pair with a message that names what is actually implemented."""
    pair = ((source_engine or "").strip().casefold(), (target_engine or "").strip().casefold())
    if pair not in SUPPORTED_ENGINE_PAIRS:
        supported = ", ".join("%s->%s" % p for p in sorted(SUPPORTED_ENGINE_PAIRS))
        raise ValueError("unsupported migration pair %s->%s; implemented: %s" % (pair[0], pair[1], supported))
    return pair


def now():
    return datetime.now(timezone.utc).isoformat()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    path = Path(path)
    if path.is_symlink():
        raise ValueError("refusing a symlink output: %s" % path)
    temp = path.with_suffix(path.suffix + ".tmp")
    # Exclusive creation also refuses a stale/symlink temporary file.
    with temp.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write("\n")
    temp.replace(path)


def parse_report(path):
    raw = Path(path).read_bytes()
    reader = csv.DictReader(io.StringIO(raw.decode("utf-8-sig"), newline=""))
    if reader.fieldnames != list(COLUMNS):
        raise ValueError("unexpected mapping CSV columns; expected %s" % ", ".join(COLUMNS))
    groups = {}
    count = 0
    for row in reader:
        count += 1
        if None in row or any(v is None for v in row.values()):
            raise ValueError("malformed CSV record %d" % count)
        if not row["Source_Object_Type"].strip() or not row["Source_Object"].strip():
            raise ValueError("missing source identity in record %d" % count)
        if row["Status"] not in ("Converted", "Not-Converted"):
            raise ValueError("unknown Status in record %d: %s" % (count, row["Status"]))
        if row["Action_Required"].lower() not in ("yes", "no"):
            raise ValueError("unknown Action_Required in record %d" % count)
        key = (row["Source_Object_Type"], row["Source_Object"])
        groups.setdefault(key, []).append(row)
    if not count:
        raise ValueError("mapping CSV has no records")
    return raw, groups, count


class Queue:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.db = self.root / "queue.sqlite3"

    @contextmanager
    def connection(self):
        if not self.db.is_file() or self.db.is_symlink():
            raise ValueError("queue not initialized; run init first")
        connection = sqlite3.connect(str(self.db), timeout=30)
        connection.row_factory = sqlite3.Row
        try:
            # Claim/check/update is atomic even when separate Copilot terminals race.
            connection.execute("BEGIN IMMEDIATE")
            yield connection
            connection.commit()
        except BaseException:
            connection.rollback()
            raise
        finally:
            connection.close()

    def initialize(self, report, project=None, max_workers=2, target_schemas=None,
                   source_engine="oracle", target_engine="postgresql"):
        if not 1 <= max_workers <= 8:
            raise ValueError("max-workers must be between 1 and 8")
        source_engine, target_engine = check_engines(source_engine, target_engine)
        if target_schemas is not None:
            target_schemas = list(check_schema_names(target_schemas))
        raw, groups, count = parse_report(report)
        if project is not None and not Path(project).is_dir():
            raise ValueError("project directory does not exist")
        self.root.mkdir(parents=True, exist_ok=True)
        # Never overwrite an existing queue or unrelated files.
        if any(self.root.iterdir()):
            raise ValueError("state directory must be empty; existing queues are resumed, not re-imported")
        self.root.chmod(0o700)
        with closing(sqlite3.connect(str(self.db))) as c, c:
            c.executescript("""
                CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE tasks (
                    id TEXT PRIMARY KEY, source_type TEXT NOT NULL, source_name TEXT NOT NULL,
                    mappings TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'queued',
                    worker TEXT, reviewer TEXT, attempts INTEGER NOT NULL DEFAULT 0,
                    validation_attempts INTEGER NOT NULL DEFAULT 0,
                    note TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL,
                    evidence TEXT
                );
                CREATE TABLE events (
                    seq INTEGER PRIMARY KEY, task_id TEXT, action TEXT NOT NULL,
                    actor TEXT NOT NULL, detail TEXT NOT NULL, created_at TEXT NOT NULL
                );
                CREATE INDEX events_task_seq ON events(task_id, seq);
            """)
            for key, value in {
                "version": 2, "report_sha256": hashlib.sha256(raw).hexdigest(),
                "report_rows": count, "source_groups": len(groups),
                "project": str(Path(project).resolve()) if project else None,
                "max_workers": max_workers,
                "source_engine": source_engine, "target_engine": target_engine,
                "target_schemas": target_schemas,
            }.items():
                c.execute("INSERT INTO metadata VALUES (?, ?)", (key, json.dumps(value)))
            for (kind, name), mappings in groups.items():
                if not any(r["Status"] != "Converted" or r["Action_Required"].lower() == "yes"
                           for r in mappings):
                    continue
                task_id = hashlib.sha256(json.dumps([kind, name]).encode()).hexdigest()[:20]
                c.execute("INSERT INTO tasks (id,source_type,source_name,mappings,updated_at) VALUES (?,?,?,?,?)",
                          (task_id, kind, name, json.dumps(mappings), now()))
        self.db.chmod(0o600)
        (self.root / "input.csv").write_bytes(raw)
        (self.root / "work").mkdir()
        return self.summary()

    @staticmethod
    def event(c, task_id, action, actor, detail):
        c.execute("INSERT INTO events (task_id,action,actor,detail,created_at) VALUES (?,?,?,?,?)",
                  (task_id, action, actor, detail, now()))

    @staticmethod
    def task(c, task_id):
        row = c.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone()
        if row is None:
            raise ValueError("unknown task: %s" % task_id)
        return dict(row)

    def workdir(self, task_id):
        if len(task_id) != 20 or any(ch not in "0123456789abcdef" for ch in task_id):
            raise ValueError("invalid task id")
        work = self.root / "work" / task_id
        if work.is_symlink() or work.parent.is_symlink():
            raise ValueError("work directories cannot be symlinks")
        return work

    @staticmethod
    def validation_budget(c, task):
        """Audit lifetime attempts, including legacy counters that were reset.

        A baseline is recorded on the first governed mutation, never on reads.
        New start events count attempts even if validation is interrupted.
        """
        events = [dict(r) for r in c.execute(
            "SELECT seq,action,detail FROM events WHERE task_id=? ORDER BY seq", (task['id'],))]
        def legacy_floor(history, counter):
            # The current counter belongs to the LAST reset period, not the whole
            # history. Earlier completed attempts must be added, not max'ed away.
            resets = [e['seq'] for e in history if e['action'] == 'unblock']
            boundary = max(resets, default=0)
            before = sum(e['action'] == 'validate' and e['seq'] <= boundary for e in history)
            after = sum(e['action'] == 'validate' and e['seq'] > boundary for e in history)
            return before + max(counter, after)

        baselines = [e for e in events if e['action'] == 'validation-budget-baseline']
        if baselines:
            baseline = baselines[0]
            saved = json.loads(baseline['detail'])
            prior = max(saved['used'], legacy_floor(
                [e for e in events if e['seq'] < baseline['seq']],
                saved['counter_at_capture']))
            starts = sum(e['action'] == 'validate-start' and e['seq'] > baseline['seq']
                         for e in events)
        else:
            used = legacy_floor(events, task['validation_attempts'])
        grants = [(e, json.loads(e['detail'])) for e in events
                  if e['action'] == 'user-authorized-revision']
        # Cross-queue attempts are debited into the canonical lineage, never erased.
        debit = sum(g.get('lineage_debit', 0) for _, g in grants)
        if baselines:
            used = max(task['validation_attempts'], prior + starts + debit)
        else:
            used = max(task['validation_attempts'], used + debit)
        latest_event, grant = grants[-1] if grants else (None, None)
        limit = grant['limit'] if grant else BASE_LIMIT
        release_seq = latest_event['seq'] if latest_event else 0
        held = any(e['action'] == 'quarantine-review' and e['seq'] > release_seq for e in events)
        evidence = json.loads(task['evidence']) if task.get('evidence') else {}
        fresh = (not grant or (evidence.get('validation_authorization_id') == grant['approval_id']
                              and evidence.get('validation_attempt', 0) > grant['used_at_grant']))
        issues = []
        if used > limit:
            issues.append('validation_limit_exceeded')
        if held:
            issues.append('review_quarantined')
        if grant and not fresh:
            issues.append('fresh_authorized_validation_required')
        return {'policy': 'lifetime-three-no-reset-v1', 'base_limit': BASE_LIMIT,
                'limit': limit, 'used': used, 'remaining': max(0, limit - used),
                'within_limit': used <= limit, 'quarantined': held,
                'can_validate': used < limit and not held,
                'review_eligible': not issues, 'issues': issues,
                'active_authorization': grant, 'lineage_attempts_debited': debit,
                'legacy_unblock_events': sum(e['action'] == 'unblock' for e in events)}

    def _ensure_budget_baseline(self, c, task):
        budget = self.validation_budget(c, task)
        if not c.execute("SELECT 1 FROM events WHERE task_id=? AND action='validation-budget-baseline'",
                         (task['id'],)).fetchone():
            self.event(c, task['id'], 'validation-budget-baseline', 'queue', json.dumps({
                'used': budget['used'], 'counter_at_capture': task['validation_attempts'],
                'policy': budget['policy'],
            }))
        return budget

    def audit(self, task_id):
        with self.connection() as c:
            task = self.task(c, task_id)
            budget = self.validation_budget(c, task)
            events = [dict(r) for r in c.execute(
                'SELECT * FROM events WHERE task_id=? ORDER BY seq', (task_id,))]
        return {'task_id': task_id, 'source_type': task['source_type'],
                'source_name': task['source_name'], 'task_status': task['status'],
                'validation_budget': budget, 'events': events,
                'status': 'passed' if budget['review_eligible'] else 'failed',
                'scope': 'Local queue history only; cross-queue lineage and user authorization require separate audit.'}

    def show(self, task_id):
        with self.connection() as c:
            task = self.task(c, task_id)
            task['validation_budget'] = self.validation_budget(c, task)
        task["mappings"] = json.loads(task["mappings"])
        task["evidence"] = json.loads(task["evidence"]) if task["evidence"] else None
        task["workdir"] = str(self.workdir(task_id))
        # Authoritative CURRENT fingerprint of the on-disk artifacts plus the
        # schema/engine config (:config), so a consumer -- e.g. the controller
        # crediting reviewed units -- can tell whether a recorded review still
        # matches what is staged and configured right now, without re-deriving
        # the rule. Computed best-effort and read-only: an unstaged task (missing
        # SQL) or an unconfigured queue (no target schema) reports no current
        # fingerprint and evidence_fresh=False rather than raising. This never
        # relaxes the review/source/budget guards -- validate()/review()/
        # record_case still hash-check and fail closed on their own. Consumers
        # fail closed on a None fingerprint, so this catch is intentionally broad
        # (a missing SQL file, an unconfigured queue, or any read failure yields
        # None rather than propagating out of a read-only show).
        try:
            current = self.hashes(task_id)
        except Exception:
            current = None
        task["current_input_sha256"] = current
        task["evidence_fresh"] = bool(
            current is not None and task["evidence"] is not None
            and task["evidence"].get("input_sha256") == current)
        return task

    def list(self, status=None):
        with self.connection() as c:
            return [dict(r) for r in c.execute(
                "SELECT id,source_type,source_name,status,worker,attempts,note FROM tasks "
                "WHERE (? IS NULL OR status=?) ORDER BY source_type,source_name", (status, status))]

    def summary(self):
        with self.connection() as c:
            meta = {r["key"]: json.loads(r["value"]) for r in c.execute("SELECT * FROM metadata")}
            states = {r[0]: r[1] for r in c.execute("SELECT status,count(*) FROM tasks GROUP BY status")}
        return {"input": meta, "tasks": sum(states.values()), "states": states,
                "meaning": "Task review states only; not a conversion success rate or production approval."}

    def _read_meta(self):
        """Read the metadata table on a short read-only connection. Safe to call
        while another connection holds this queue's write transaction."""
        if not self.db.is_file() or self.db.is_symlink():
            raise ValueError("queue not initialized; run init first")
        connection = sqlite3.connect(str(self.db), timeout=30)
        try:
            connection.row_factory = sqlite3.Row
            return {r["key"]: json.loads(r["value"]) for r in connection.execute("SELECT * FROM metadata")}
        finally:
            connection.close()

    def target_schemas(self):
        """The configured target schemas as a tuple. Raises an actionable error
        (never a traceback) when the queue was created or migrated without an
        explicit configuration -- schemas are configured, not guessed."""
        meta = self._read_meta()
        if "target_schemas" not in meta or meta["target_schemas"] is None:
            raise ValueError(
                "no target schema configured; set it before validating, e.g. "
                "configure --state <dir> --target-schema <name> (repeat for several)")
        return check_schema_names(meta["target_schemas"])

    def config_digest(self):
        """Fingerprint of the schema + engine configuration, folded into every
        validation's evidence so a later reconfigure invalidates prior reviews."""
        meta = self._read_meta()
        payload = json.dumps({
            "target_schemas": list(self.target_schemas()),
            "source_engine": meta.get("source_engine", "oracle"),
            "target_engine": meta.get("target_engine", "postgresql"),
        }, ensure_ascii=False, sort_keys=True)
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()

    def configure(self, target_schemas=None, source_engine=None, target_engine=None):
        """Set (or migrate in) the target schema(s) and engine labels for an
        existing queue. Never touches the task rows -- a legacy queue is upgraded
        in place, and reconfiguring only changes metadata. Because the config is
        part of validation evidence, changing it makes prior reviews stale."""
        meta = self._read_meta()
        source_engine, target_engine = check_engines(
            source_engine or meta.get("source_engine") or "oracle",
            target_engine or meta.get("target_engine") or "postgresql")
        if target_schemas is not None:
            schemas = list(check_schema_names(target_schemas))
        elif meta.get("target_schemas") is not None:
            schemas = list(check_schema_names(meta["target_schemas"]))
        else:
            schemas = None
        updates = {"version": 2, "source_engine": source_engine,
                   "target_engine": target_engine, "target_schemas": schemas}
        with self.connection() as c:
            for key, value in updates.items():
                c.execute("INSERT INTO metadata(key,value) VALUES(?,?) "
                          "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                          (key, json.dumps(value)))
            self.event(c, None, "configure", "coordinator",
                       "schemas=%s engines=%s->%s" % (schemas, source_engine, target_engine))
        return self.summary()

    def claim(self, worker, task_id=None):
        if not worker.strip():
            raise ValueError("worker name is required")
        with self.connection() as c:
            limit = json.loads(c.execute("SELECT value FROM metadata WHERE key='max_workers'").fetchone()[0])
            active = c.execute("SELECT count(*) FROM tasks WHERE status IN ('claimed','validating')").fetchone()[0]
            if active >= limit:
                raise ValueError("worker limit reached; finish or release a task before claiming another")
            if task_id is None:
                row = c.execute("SELECT id FROM tasks WHERE status='queued' ORDER BY source_type,source_name LIMIT 1").fetchone()
                if row is None:
                    raise ValueError("no queued tasks")
                task_id = row[0]
            task = self.task(c, task_id)
            if task["status"] != "queued":
                raise ValueError("task is not queued")
            if not self.validation_budget(c, task)['can_validate']:
                raise ValueError("task has no authorized validation budget or is quarantined")
            c.execute("UPDATE tasks SET status='claimed',worker=?,reviewer=NULL,evidence=NULL,"
                      "attempts=attempts+1,updated_at=? WHERE id=?", (worker, now(), task_id))
            self.workdir(task_id).mkdir(exist_ok=True)
            self.event(c, task_id, "claim", worker, "")
        return self.show(task_id)

    @staticmethod
    def require_owner(task, worker):
        if task["worker"] != worker or task["status"] != "claimed":
            raise ValueError("task must be claimed by this worker")

    def stage(self, task_id, worker, source, candidate, checks, dependencies=None):
        inputs = dict(zip(FILES, (source, candidate, checks, dependencies)))
        contents = {}
        for name, path in inputs.items():
            if path is not None:
                content = Path(path).read_bytes()
                if not content.strip():
                    raise ValueError("empty %s" % name)
                contents[name] = content
        with self.connection() as c:
            task = self.task(c, task_id)
            self.require_owner(task, worker)
            folder = self.workdir(task_id)
            for name in FILES:
                target = folder / name
                if target.is_symlink():
                    raise ValueError("task SQL files cannot be symlinks")
                if name in contents:
                    target.write_bytes(contents[name])
                elif name == "dependencies.sql" and target.exists():
                    target.unlink()  # the previous attempt's generated dependency bundle
            c.execute("UPDATE tasks SET evidence=NULL,updated_at=? WHERE id=?", (now(), task_id))
            self.event(c, task_id, "stage", worker, "Original Oracle DDL and candidate/check SQL attached")
        return self.show(task_id)

    def release(self, task_id, worker, reason, blocked=False):
        if not reason.strip():
            raise ValueError("a reason is required")
        with self.connection() as c:
            task = self.task(c, task_id)
            self.require_owner(task, worker)
            state = "blocked" if blocked else "queued"
            c.execute("UPDATE tasks SET status=?,worker=NULL,evidence=NULL,note=?,updated_at=? WHERE id=?",
                      (state, reason, now(), task_id))
            self.event(c, task_id, state, worker, reason)
        return self.show(task_id)

    def unblock(self, task_id, reason):
        if not reason.strip():
            raise ValueError("record how the blocker was resolved")
        with self.connection() as c:
            task = self.task(c, task_id)
            if task["status"] != "blocked":
                raise ValueError("only blocked tasks can be unblocked")
            budget = self._ensure_budget_baseline(c, task)
            if budget['quarantined']:
                raise ValueError("review is quarantined; ordinary unblock cannot release an authorization hold")
            if not budget['can_validate']:
                raise ValueError("validation budget exhausted; unblock does not reset attempts; a specific user-authorized disposition is required")
            c.execute("UPDATE tasks SET status='queued',validation_attempts=?,note=?,updated_at=? WHERE id=?",
                      (budget['used'], reason, now(), task_id))
            self.event(c, task_id, "unblock-preserving-budget", "coordinator", json.dumps({
                'reason': reason, 'validation_attempts_retained': budget['used'],
            }))
        return self.show(task_id)

    def reopen(self, task_id, actor, reason, quarantine=False):
        """Invalidate a reviewed task without erasing evidence or retry history."""
        if not actor.strip() or not reason.strip():
            raise ValueError("actor and a concrete reason are required to reopen a review")
        with self.connection() as c:
            task = self.task(c, task_id)
            if task['status'] != 'reviewed':
                raise ValueError("only reviewed tasks can be reopened; reject pending reviews normally")
            if actor.casefold().strip() == (task['worker'] or '').casefold().strip():
                raise ValueError("the repair author cannot invalidate their own accepted review")
            budget = self._ensure_budget_baseline(c, task)
            folder = self.workdir(task_id)
            history = folder / 'history'
            if history.is_symlink() or (history.exists() and not history.is_dir()):
                raise ValueError("review history must be a real directory")
            history.mkdir(exist_ok=True)
            archive = history / ('review-' + uuid.uuid4().hex)
            archive.mkdir(mode=0o700)
            captured = {}
            for name in FILES + ('validation.json',):
                source = folder / name
                if source.is_symlink() or (source.exists() and not source.is_file()):
                    raise ValueError("review artifacts must be regular files: " + name)
                if source.exists():
                    content = source.read_bytes()
                    with (archive / name).open('xb') as stream:
                        stream.write(content)
                    captured[name] = hashlib.sha256(content).hexdigest()
            metadata = {r['key']: json.loads(r['value']) for r in c.execute('SELECT * FROM metadata')}
            write_json(archive / 'review.json', {
                'task': task, 'metadata': metadata, 'actor': actor,
                'reason': reason, 'archived_at': now(), 'captured_sha256': captured,
                'validation_budget': budget,
                'scope': 'Prior recorded review and current on-disk artifacts; retry history is retained.',
            })
            # Reconcile legacy resets upwards; never manufacture unused attempts.
            state = 'queued' if budget['can_validate'] and not quarantine else 'blocked'
            c.execute("UPDATE tasks SET status=?,worker=NULL,reviewer=NULL,evidence=NULL,"
                      "validation_attempts=?,note=?,updated_at=? WHERE id=?",
                      (state, budget['used'], reason, now(), task_id))
            self.event(c, task_id, 'quarantine-review' if quarantine else 'reopen-review', actor, json.dumps({
                'reason': reason, 'archive': str(archive.relative_to(self.root)),
                'counter_before': task['validation_attempts'],
                'validation_attempts_retained': budget['used'],
                'next_status': state,
            }))
        result = self.show(task_id)
        result['review_archive'] = str(archive)
        return result

    def hashes(self, task_id):
        folder = self.workdir(task_id)
        values = {}
        for name in FILES:
            path = folder / name
            if path.is_symlink():
                raise ValueError("task SQL files cannot be symlinks")
            if name != "dependencies.sql" and (not path.is_file() or not path.read_bytes().strip()):
                raise ValueError("missing %s; the historical CSV alone is not enough to validate a repair" % name)
            values[name] = digest(path) if path.exists() else None
        # The schema/engine configuration is part of what was validated, so a
        # reconfigure shows up here and makes any prior evidence stale.
        values[":config"] = self.config_digest()
        return values

    def validate(self, task_id, worker, validator, image, timeout):
        schemas = self.target_schemas()  # actionable error, before any state change
        with self.connection() as c:
            task = self.task(c, task_id)
            self.require_owner(task, worker)
            hashes = self.hashes(task_id)
            budget = self._ensure_budget_baseline(c, task)
            if not budget['can_validate']:
                raise ValueError('validation budget exhausted or review quarantined; ordinary unblock cannot grant more attempts')
            grant = budget.get('active_authorization')
            if grant:
                for name in grant.get('required_changed_inputs', []):
                    if hashes.get(name) == grant['previous_input_sha256'].get(name):
                        raise ValueError('authorized revision requires a fresh ' + name)
            attempt = budget['used'] + 1
            c.execute("UPDATE tasks SET status='validating',validation_attempts=?,evidence=NULL,updated_at=? WHERE id=?",
                      (attempt, now(), task_id))
            self.event(c, task_id, 'validate-start', worker, json.dumps({
                'attempt': attempt, 'policy': budget['policy'], 'input_sha256': hashes,
            }))
        folder = self.workdir(task_id)
        try:
            evidence = validator(folder / 'candidate.sql', folder / 'checks.sql',
                                 folder / 'dependencies.sql' if hashes['dependencies.sql'] else None,
                                 image=image, timeout=timeout, schemas=schemas)
            if hashes != self.hashes(task_id):
                evidence['status'] = 'failed'
                evidence['log'] = 'SQL inputs changed during validation; run it again.'
            evidence['input_sha256'] = hashes
            evidence['task_id'] = task_id
            evidence['validation_attempt'] = attempt
            evidence['validation_budget_policy'] = budget['policy']
            evidence['validation_authorization_id'] = grant['approval_id'] if grant else None
            evidence['recorded_at'] = now()
            state = 'pending_review' if evidence['status'] == 'passed' else 'claimed'
        except BaseException:
            with self.connection() as c:
                c.execute("UPDATE tasks SET status='claimed',updated_at=? WHERE id=?", (now(), task_id))
            raise
        with self.connection() as c:
            c.execute("UPDATE tasks SET status=?,evidence=?,updated_at=? WHERE id=?",
                      (state, json.dumps(evidence), now(), task_id))
            self.event(c, task_id, 'validate', worker, evidence['status'])
        write_json(folder / 'validation.json', evidence)
        return self.show(task_id)

    def review(self, task_id, reviewer, decision, note):
        if not reviewer.strip() or not note.strip():
            raise ValueError("reviewer and review rationale are required")
        if decision not in ('accept', 'reject'):
            raise ValueError("decision must be accept or reject")
        with self.connection() as c:
            task = self.task(c, task_id)
            if task['status'] != 'pending_review':
                raise ValueError("a passing scratch validation is required before review")
            if reviewer.casefold().strip() == task['worker'].casefold().strip():
                raise ValueError("the repair author cannot approve their own work")
            evidence = json.loads(task['evidence'])
            budget = self.validation_budget(c, task)
            if decision == 'accept' and not budget['review_eligible']:
                raise ValueError("review cannot be accepted: validation budget history is invalid or quarantined")
            if decision == 'accept' and (evidence['status'] != 'passed' or evidence['input_sha256'] != self.hashes(task_id)):
                raise ValueError("validation evidence is stale; reject and revalidate the changed SQL")
            state = ('reviewed' if decision == 'accept' else
                     'queued' if budget['can_validate'] else 'blocked')
            c.execute("UPDATE tasks SET status=?,reviewer=?,note=?,updated_at=? WHERE id=?",
                      (state, reviewer, note, now(), task_id))
            self.event(c, task_id, 'review-' + decision, reviewer, note)
        return self.show(task_id)
