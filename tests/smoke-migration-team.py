#!/usr/bin/env python3
"""Opt-in live smoke test: requires the prebuilt disposable PostgreSQL image.

Unlike unit-test doubles, this executes real SQL through the same queue API the
Copilot CLI uses. It never touches the Oracle source, Azure or host PostgreSQL.
"""
import json
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'tools'))
from migration_team.queue import Queue
from migration_team.validator import validate
from migration_team.evidence import compare_exports


def main():
    fixture = REPO / 'tests/fixtures/migration-team'
    with tempfile.TemporaryDirectory(prefix='o2p-team-smoke-') as temp:
        root = Path(temp)
        q = Queue(root / 'queue')
        q.initialize(fixture / 'mapping.csv', max_workers=2, target_schemas=['contoso'])
        task = q.claim('smoke-repair')
        q.stage(task['id'], 'smoke-repair', fixture / 'source.sql', fixture / 'candidate.sql', fixture / 'checks.sql')
        task = q.validate(task['id'], 'smoke-repair', validate, 'o2p-migration-validator:pg16', 120)
        print(json.dumps(task['evidence'], indent=2))
        if task['status'] != 'pending_review':
            raise AssertionError('valid synthetic candidate did not pass real PostgreSQL validation')
        task = q.review(task['id'], 'smoke-reviewer', 'accept', 'Synthetic smoke assertions checked independently of the repair role')
        assert task['status'] == 'reviewed'

        # A compiling-but-wrong repair must fail the supplied behavior tests.
        wrong = root / 'wrong.sql'
        wrong.write_text((fixture / 'candidate.sql').read_text().replace('* 1.20', '* 1.30'))
        failure = validate(wrong, fixture / 'checks.sql', timeout=120, schemas=['contoso'])
        assert failure['status'] == 'failed', json.dumps(failure)
        assert any(not c['passed'] and c['name'] == 'tax on 100' for c in failure['checks'])
        print('PASS: compiling-but-wrong arithmetic is rejected')

        # PostgreSQL defers some function-body errors: plpgsql_check must catch this
        # even when an unrelated behavioral query returns true.
        invalid_body = root / 'deep.sql'
        invalid_body.write_text('CREATE FUNCTION contoso.bad() RETURNS integer LANGUAGE plpgsql AS $$\n'
                                'BEGIN RETURN missing_column; END; $$;\n')
        unrelated = root / 'checks.sql'
        unrelated.write_text("SELECT 'unrelated constant' AS check_name, true AS passed;\n")
        failure = validate(invalid_body, unrelated, timeout=120, schemas=['contoso'])
        assert failure['status'] == 'failed', json.dumps(failure)
        assert any(c['name'] == 'deep-check' and not c['passed'] for c in failure['checks'])
        print('PASS: plpgsql_check catches deferred body error')

        data = compare_exports(fixture / 'source.csv', fixture / 'target.csv', ['order_id'])
        assert data['status'] == 'passed'
        print('PASS: three-row exports match independent of row/column order')
        changed = root / 'changed.csv'
        changed.write_text((fixture / 'target.csv').read_text().replace('120.00', '130.00'))
        assert compare_exports(fixture / 'source.csv', changed, ['order_id'])['status'] == 'failed'
        print('PASS: mismatched export is rejected')
        print('PASS: full queue → SQL validation → independent review flow')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
