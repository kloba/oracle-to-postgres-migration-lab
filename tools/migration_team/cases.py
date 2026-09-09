"""Record human/Copilot case classifications backed by independently reviewed work."""
import json
from pathlib import Path

from .queue import now, write_json


def record_case(checklist, case_id, queue, task_ids, outcome, note):
    checklist = Path(checklist)
    if checklist.is_symlink():
        raise ValueError('case checklist cannot be a symlink')
    document = json.loads(checklist.read_text(encoding='utf-8'))
    if (not isinstance(document, dict) or not isinstance(document.get('cases'), list)
            or any(not isinstance(c, dict) or not isinstance(c.get('id'), str)
                   for c in document['cases'])):
        raise ValueError('not a valid hard-case checklist; regenerate with the cases command')
    if outcome not in ('clean', 'partial', 'manual') or not note.strip():
        raise ValueError('a classification and explanation are required')
    if not task_ids or len(task_ids) != len(set(task_ids)):
        raise ValueError('provide one or more distinct reviewed task ids')
    matches = [c for c in document['cases'] if c['id'] == case_id]
    if len(matches) != 1:
        raise ValueError('unknown or duplicate hard case: ' + case_id)
    evidence = []
    for task_id in task_ids:
        task = queue.show(task_id)
        if task['status'] != 'reviewed' or not task['evidence']:
            raise ValueError('case classifications require independently reviewed tasks')
        if task['evidence']['input_sha256'] != queue.hashes(task_id):
            raise ValueError('reviewed task evidence is stale: ' + task_id)
        evidence.append({'task_id': task_id, 'reviewer': task['reviewer'],
                         'input_sha256': task['evidence']['input_sha256'],
                         'validated_at': task['evidence']['recorded_at']})
    matches[0].update(status='reviewed_candidate', task_ids=task_ids, evidence=evidence,
                      observed_classification=outcome, note=note, recorded_at=now())
    write_json(checklist, document)
    return matches[0]
