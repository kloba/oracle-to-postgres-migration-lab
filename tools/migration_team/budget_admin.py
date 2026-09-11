"""Operator-only recording of a specifically user-approved validation revision.

This command is intentionally NOT exposed by migration-team.py or agent wrappers.
The operator must obtain actual user consent first. A JSON receipt is an audit
record, not authentication and not permission for an agent to authorize itself.
Default is a read-only proposal; --apply appends a one-shot grant without deleting
attempts or historical violations. Linked queue attempts debit the canonical unit.
"""
import argparse
import hashlib
import json
import os
import stat
from pathlib import Path

from .queue import Queue, now, write_json


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def read_approval(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError('approval must be a regular operator-owned file')
    info = path.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError('approval must be private (mode 600) and owned by the operator')
    raw = path.read_bytes()
    approval = json.loads(raw)
    if approval.get('authority') != 'actual-user-decision' or not approval.get('decision_reference'):
        raise ValueError('a specific actual user-decision reference is required')
    aid = approval.get('approval_id', '')
    if len(aid) != 32 or any(c not in '0123456789abcdef' for c in aid):
        raise ValueError('approval_id must be a unique 32-character hex identifier')
    extra = approval.get('additional_attempts')
    if type(extra) is not int or not 1 <= extra <= 3:
        raise ValueError('a revision may authorize only one to three new attempts')
    if not isinstance(approval.get('reason'), str) or not approval['reason'].strip():
        raise ValueError('a concrete revision reason is required')
    required = approval.get('required_changed_inputs', [])
    if not isinstance(required, list) or any(n not in ('source.sql', 'candidate.sql', 'checks.sql', 'dependencies.sql') for n in required):
        raise ValueError('required_changed_inputs contains an unsupported artifact')
    return approval, raw, hashlib.sha256(raw).hexdigest()


def verified_audit(record):
    q = Queue(record['queue'])
    result = q.audit(record['task_id'])
    if result['source_name'] != record['source_name'] or result['source_type'] != record['source_type']:
        raise ValueError('approval source identity does not match the queue')
    if canonical_hash(result) != record['audit_sha256']:
        raise ValueError('queue history changed since approval receipt was prepared')
    if result['validation_budget']['used'] != record['expected_used']:
        raise ValueError('approval attempt count does not match current history')
    return q, result


def run(path, apply=False):
    approval, raw, receipt_hash = read_approval(path)
    q, audit = verified_audit(approval['task'])
    if audit['task_status'] != 'blocked':
        raise ValueError('only a blocked canonical task can receive this scoped revision')
    if q.hashes(audit['task_id']) != approval['previous_input_sha256']:
        raise ValueError('staged inputs changed since approval receipt was prepared')
    linked = []
    seen = {(str(q.root), audit['task_id'])}
    for record in approval.get('linked_prior_attempts', []):
        other, prior = verified_audit(record)
        key = (str(other.root), prior['task_id'])
        if key in seen:
            raise ValueError('duplicate or self-referential linked lineage')
        seen.add(key)
        if not prior['validation_budget']['quarantined'] or prior['validation_budget'].get('active_authorization'):
            raise ValueError('linked aliases must remain quarantined without a separate budget grant')
        linked.append(dict(record, queue=str(other.root)))
    debit = sum(r['expected_used'] for r in linked)
    used = audit['validation_budget']['used'] + debit
    grant = {
        'approval_id': approval['approval_id'], 'approval_sha256': receipt_hash,
        'decision_reference': approval['decision_reference'], 'authority': approval['authority'],
        'reason': approval['reason'], 'used_before': audit['validation_budget']['used'],
        'lineage_debit': debit, 'used_at_grant': used,
        'additional_attempts': approval['additional_attempts'],
        'limit': used + approval['additional_attempts'],
        'required_changed_inputs': approval.get('required_changed_inputs', []),
        'previous_input_sha256': approval['previous_input_sha256'],
        'linked_prior_attempts': linked,
        'scope': 'Future attempts only; old violations and all historical attempts remain recorded. Fresh validation and independent review are mandatory.',
    }
    with q.connection() as c:
        current = q.task(c, audit['task_id'])
        last = c.execute('SELECT coalesce(max(seq),0) FROM events WHERE task_id=?', (audit['task_id'],)).fetchone()[0]
        expected_last = audit['events'][-1]['seq'] if audit['events'] else 0
        if current['status'] != 'blocked' or last != expected_last:
            raise ValueError('task state changed while preparing the revision')
        existing = [json.loads(r[0]) for r in c.execute(
            "SELECT detail FROM events WHERE action='user-authorized-revision'")]
        if any(g['approval_id'] == grant['approval_id'] for g in existing):
            raise ValueError('approval has already been consumed')
        for previous in existing:
            prior_keys = {(r['queue'], r['task_id']) for r in previous.get('linked_prior_attempts', [])}
            if any((r['queue'], r['task_id']) in prior_keys for r in linked):
                raise ValueError('linked lineage was already debited by a prior revision')
        if apply:
            q._ensure_budget_baseline(c, current)
            history = q.workdir(audit['task_id']) / 'history'
            if history.is_symlink() or (history.exists() and not history.is_dir()):
                raise ValueError('history must be a real directory')
            history.mkdir(exist_ok=True)
            archive = history / ('authorization-' + grant['approval_id'])
            archive.mkdir(mode=0o700)
            with (archive / 'approval.json').open('xb') as stream:
                stream.write(raw)
            write_json(archive / 'before.json', {'task': current, 'audit': audit})
            grant['archive'] = str(archive.relative_to(q.root))
            q.event(c, audit['task_id'], 'user-authorized-revision', 'operator', json.dumps(grant))
            c.execute("UPDATE tasks SET status='queued',worker=NULL,reviewer=NULL,evidence=NULL,"
                      "validation_attempts=?,note=?,updated_at=? WHERE id=?",
                      (used, approval['reason'], now(), audit['task_id']))
    result = {'applied': apply, 'task_id': audit['task_id'], 'source_name': audit['source_name'],
              'queue': str(q.root), 'grant': grant}
    if apply:
        result['task'] = q.show(audit['task_id'])
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--approval', type=Path, required=True)
    parser.add_argument('--apply', action='store_true', help='record the specifically approved revision; default is read-only')
    args = parser.parse_args(argv)
    try:
        result = run(args.approval, args.apply)
    except (ValueError, OSError, KeyError, TypeError) as exc:
        print(json.dumps({'applied': False, 'error': str(exc)}, indent=2))
        return 2
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
