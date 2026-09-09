"""GitHub Copilot calls these deterministic commands; it does not grade itself."""
import argparse
import json
import sys
from pathlib import Path

from .evidence import compare_exports, hard_cases
from .queue import Queue, write_json


def parser():
    p = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    sub = p.add_subparsers(dest='command', required=True)
    init = sub.add_parser('init', help='import an extension mapping CSV into a new queue')
    init.add_argument('--state', required=True, type=Path)
    init.add_argument('--report', required=True, type=Path)
    init.add_argument('--project', type=Path, help='local archived extension project; no auto-download')
    init.add_argument('--max-workers', type=int, default=2)
    for name in ('list', 'show', 'claim', 'stage', 'release', 'unblock', 'validate', 'review', 'report'):
        cmd = sub.add_parser(name)
        cmd.add_argument('--state', required=True, type=Path)
        if name in ('show', 'stage', 'release', 'unblock', 'validate', 'review'):
            cmd.add_argument('--id', required=True)
        if name in ('claim', 'stage', 'release', 'validate'):
            cmd.add_argument('--worker', required=True)
        if name == 'list':
            cmd.add_argument('--status', choices=['queued', 'claimed', 'validating', 'pending_review', 'blocked', 'reviewed'])
        elif name == 'claim':
            cmd.add_argument('--id')
        elif name == 'stage':
            cmd.add_argument('--source', required=True, type=Path, help='original Oracle DDL for review (never executed)')
            cmd.add_argument('--candidate', required=True, type=Path)
            cmd.add_argument('--checks', required=True, type=Path, help='SELECT query returning check_name, passed')
            cmd.add_argument('--dependencies', type=Path)
        elif name in ('release', 'unblock'):
            cmd.add_argument('--reason', required=True)
            if name == 'release':
                cmd.add_argument('--blocked', action='store_true')
        elif name == 'validate':
            cmd.add_argument('--image', default='o2p-migration-validator:pg16')
            cmd.add_argument('--timeout', type=int, default=120)
        elif name == 'review':
            cmd.add_argument('--reviewer', required=True)
            cmd.add_argument('--decision', required=True, choices=['accept', 'reject'])
            cmd.add_argument('--note', required=True)
    compare = sub.add_parser('compare-data', help='compare consistent CSV exports without touching a database')
    compare.add_argument('--source', type=Path, required=True)
    compare.add_argument('--target', type=Path, required=True)
    compare.add_argument('--key', action='append', required=True, help='repeat for composite keys')
    compare.add_argument('--output', type=Path)
    cases = sub.add_parser('cases', help='extract the design hard-case checklist, initially all not_tested')
    cases.add_argument('--design', type=Path, default=Path(__file__).resolve().parents[2] / 'docs/design.md')
    cases.add_argument('--output', type=Path)
    record = sub.add_parser('case-record', help='record a case assessment backed by independently reviewed tasks')
    record.add_argument('--checklist', type=Path, required=True)
    record.add_argument('--state', type=Path, required=True)
    record.add_argument('--id', required=True, help='hard-case ID, e.g. H-01')
    record.add_argument('--task', action='append', required=True)
    record.add_argument('--outcome', choices=['clean', 'partial', 'manual'], required=True)
    record.add_argument('--note', required=True)
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        if args.command == 'compare-data':
            result = compare_exports(args.source, args.target, args.key)
        elif args.command == 'cases':
            result = hard_cases(args.design)
        elif args.command == 'case-record':
            from .cases import record_case
            result = record_case(args.checklist, args.id, Queue(args.state), args.task, args.outcome, args.note)
        else:
            q = Queue(args.state)
            if args.command == 'init':
                result = q.initialize(args.report, args.project, args.max_workers)
            elif args.command == 'list':
                result = q.list(args.status)
            elif args.command == 'show':
                result = q.show(args.id)
            elif args.command == 'claim':
                result = q.claim(args.worker, args.id)
            elif args.command == 'stage':
                result = q.stage(args.id, args.worker, args.source, args.candidate, args.checks, args.dependencies)
            elif args.command == 'release':
                result = q.release(args.id, args.worker, args.reason, args.blocked)
            elif args.command == 'unblock':
                result = q.unblock(args.id, args.reason)
            elif args.command == 'validate':
                if not 1 <= args.timeout <= 1800:
                    raise ValueError('timeout must be between 1 and 1800 seconds')
                from .validator import validate
                result = q.validate(args.id, args.worker, validate, args.image, args.timeout)
            elif args.command == 'review':
                result = q.review(args.id, args.reviewer, args.decision, args.note)
            else:
                result = q.summary()
        output = getattr(args, 'output', None)
        if output:
            if output.exists():
                raise ValueError('output exists; choose a new path to preserve prior evidence')
            write_json(output, result)
        print(json.dumps(result, indent=2, ensure_ascii=False))
        if args.command == 'validate':
            return 0 if result['evidence']['status'] == 'passed' else 1
        return 1 if isinstance(result, dict) and result.get('status') == 'failed' else 0
    except (ValueError, OSError) as exc:
        print('migration-team: %s' % exc, file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
