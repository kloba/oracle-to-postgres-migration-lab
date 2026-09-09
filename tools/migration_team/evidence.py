"""Offline evidence helpers. Comparing exports does not execute a data migration."""
import csv
from contextlib import closing
import hashlib
import json
import re
import sqlite3
import tempfile
from pathlib import Path


def file_hash(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def compare_exports(source, target, keys):
    """Exact text comparison, independent of row/column order, using bounded RAM.

    Export identical projections at a consistent snapshot. NULL markers, timezones
    and numeric formatting must be explicit in those projections; guessing their
    semantics here would conceal differences. Samples are capped, counts are not.
    """
    if not keys or len(keys) != len(set(keys)):
        raise ValueError('provide distinct comparison key columns')
    before = [file_hash(source), file_hash(target)]
    with tempfile.TemporaryDirectory(prefix='o2p-compare-') as folder:
        with closing(sqlite3.connect(str(Path(folder) / 'rows.sqlite3'))) as c, c:
            counts = []
            expected = None
            for name, path in [('source', source), ('target', target)]:
                c.execute('CREATE TABLE %s (key TEXT PRIMARY KEY, payload TEXT NOT NULL)' % name)
                with Path(path).open(encoding='utf-8-sig', newline='') as stream:
                    reader = csv.DictReader(stream)
                    fields = reader.fieldnames
                    if not fields or len(fields) != len(set(fields)) or any(not f for f in fields):
                        raise ValueError('CSV requires unique, nonempty column names')
                    if not set(keys) <= set(fields):
                        raise ValueError('comparison key absent from CSV: %s' % path)
                    fields = sorted(fields)
                    if expected is not None and fields != expected:
                        raise ValueError('source and target projections have different columns')
                    expected = fields
                    count = 0
                    for row in reader:
                        if None in row or any(v is None for v in row.values()):
                            raise ValueError('malformed export row in %s' % path)
                        if any(not row[k] for k in keys):
                            raise ValueError('empty comparison key in %s' % path)
                        key = json.dumps([row[k] for k in keys], ensure_ascii=False)
                        payload = json.dumps([row[f] for f in fields], ensure_ascii=False)
                        try:
                            c.execute('INSERT INTO %s VALUES (?,?)' % name, (key, payload))
                        except sqlite3.IntegrityError as exc:
                            raise ValueError('duplicate comparison key in %s' % path) from exc
                        count += 1
                    counts.append(count)
            missing = c.execute('SELECT count(*) FROM source s LEFT JOIN target t USING(key) WHERE t.key IS NULL').fetchone()[0]
            extra = c.execute('SELECT count(*) FROM target t LEFT JOIN source s USING(key) WHERE s.key IS NULL').fetchone()[0]
            changed = c.execute('SELECT count(*) FROM source JOIN target USING(key) WHERE source.payload != target.payload').fetchone()[0]
            samples = [json.loads(r[0]) for r in c.execute(
                'SELECT source.key FROM source JOIN target USING(key) WHERE source.payload != target.payload ORDER BY source.key LIMIT 10')]
    if before != [file_hash(source), file_hash(target)]:
        raise ValueError('export changed during comparison; take consistent snapshots and retry')
    if counts == [0, 0]:
        raise ValueError('both exports are empty; no row evidence to validate')
    return {'status': 'passed' if missing + extra + changed == 0 else 'failed',
            'source_rows': counts[0], 'target_rows': counts[1], 'missing_keys': missing,
            'extra_keys': extra, 'changed_rows': changed, 'changed_key_samples': samples,
            'sample_limit': 10, 'source_sha256': before[0], 'target_sha256': before[1],
            'keys': keys, 'columns': expected,
            'scope': 'Exact exported text only; not a live database, business-semantic or cutover certification.'}


def hard_cases(design):
    text = Path(design).read_text(encoding='utf-8')
    # Only actual headings; appearances in predictions and prose are not new cases.
    headings = list(re.finditer(r'^###\s+(H-\d{2})\b[^\n]*', text, re.MULTILINE))
    if not headings:
        raise ValueError('no H-NN headings found in design document')
    result = []
    seen = set()
    for i, match in enumerate(headings):
        case_id = match.group(1)
        if case_id in seen:
            raise ValueError('duplicate hard-case heading: ' + case_id)
        seen.add(case_id)
        end = headings[i + 1].start() if i + 1 < len(headings) else len(text)
        section = text[match.end():end]
        prediction = re.search(r'^.*\*\*Prediction[^\n]*', section, re.MULTILINE)
        result.append({'id': case_id, 'heading': match.group(0).lstrip('# '),
                       'prediction': prediction.group(0).strip() if prediction else None,
                       'status': 'not_tested', 'task_ids': [], 'evidence': None})
    return {'design_sha256': file_hash(design), 'cases': result,
            'scope': 'Predictions are not observed outcomes. Attach source/target behavior evidence per case.'}
