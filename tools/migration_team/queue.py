"""Resumable source-object work queue; no LLM or cloud credentials required.

The conversion CSV is a source-to-target mapping, not a list of unique objects.
Keep every mapping, group by source type AND case-sensitive name, and never turn
queue completion into a claimed migration success percentage.
"""
import csv
import hashlib
import io
import json
import sqlite3
from contextlib import closing, contextmanager
from datetime import datetime, timezone
from pathlib import Path

COLUMNS = (
    "Source_Object_Type", "Source_Object", "Azure_PostgreSQL_Object_Type",
    "Azure_PostgreSQL_Object", "Status", "Action_Required", "Error_Message",
)
FILES = ("source.sql", "candidate.sql", "checks.sql", "dependencies.sql")


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

    def initialize(self, report, project=None, max_workers=2):
        if not 1 <= max_workers <= 8:
            raise ValueError("max-workers must be between 1 and 8")
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
            """)
            for key, value in {
                "version": 1, "report_sha256": hashlib.sha256(raw).hexdigest(),
                "report_rows": count, "source_groups": len(groups),
                "project": str(Path(project).resolve()) if project else None,
                "max_workers": max_workers,
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

    def show(self, task_id):
        with self.connection() as c:
            task = self.task(c, task_id)
        task["mappings"] = json.loads(task["mappings"])
        task["evidence"] = json.loads(task["evidence"]) if task["evidence"] else None
        task["workdir"] = str(self.workdir(task_id))
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
            c.execute("UPDATE tasks SET status='queued',validation_attempts=0,note=?,updated_at=? WHERE id=?", (reason, now(), task_id))
            self.event(c, task_id, "unblock", "coordinator", reason)
        return self.show(task_id)

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
        return values

    def validate(self, task_id, worker, validator, image, timeout):
        with self.connection() as c:
            task = self.task(c, task_id)
            self.require_owner(task, worker)
            hashes = self.hashes(task_id)
            if task['validation_attempts'] >= 3:
                raise ValueError('three validation attempts used; release --blocked with the remaining issue before a coordinator unblocks it')
            c.execute("UPDATE tasks SET status='validating',validation_attempts=validation_attempts+1,evidence=NULL,updated_at=? WHERE id=?", (now(), task_id))
        folder = self.workdir(task_id)
        try:
            evidence = validator(folder / 'candidate.sql', folder / 'checks.sql',
                                 folder / 'dependencies.sql' if hashes['dependencies.sql'] else None,
                                 image=image, timeout=timeout)
            if hashes != self.hashes(task_id):
                evidence['status'] = 'failed'
                evidence['log'] = 'SQL inputs changed during validation; run it again.'
            evidence['input_sha256'] = hashes
            evidence['task_id'] = task_id
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
            if decision == 'accept' and (evidence['status'] != 'passed' or evidence['input_sha256'] != self.hashes(task_id)):
                raise ValueError("validation evidence is stale; reject and revalidate the changed SQL")
            state = 'reviewed' if decision == 'accept' else 'queued'
            c.execute("UPDATE tasks SET status=?,reviewer=?,note=?,updated_at=? WHERE id=?",
                      (state, reviewer, note, now(), task_id))
            self.event(c, task_id, 'review-' + decision, reviewer, note)
        return self.show(task_id)
