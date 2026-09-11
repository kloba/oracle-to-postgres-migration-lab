"""Whole-migration data-validation module (public, reusable) for the Oracle ->
PostgreSQL lab.  Independently proves that a loaded PostgreSQL target equals the
frozen Oracle snapshot for EVERY base table and column, and emits receipts against
the approved acceptance gates.

Design contract (see out/full-migration-plan-.../acceptance-gates.json):

* Source projections are built from the typed JSONL snapshot with a canonical
  projector that is INDEPENDENT of the loader's encoder -- so a loader bug shows
  up as a difference, never hidden.  No generic JSON flattening.
* Numeric values are exact Decimals (no rounding of 38-digit numbers).  Intervals
  keep YEAR-TO-MONTH (months) distinct from DAY-TO-SECOND (days/seconds) on both
  sides (PostgreSQL months would otherwise be coerced to days by the driver, so
  the target side extracts months/days/seconds via SQL).  TIMESTAMP WITH LOCAL
  TIME ZONE is compared as a UTC instant.  CHAR blank-pad, NULL-vs-empty, XML
  (C14N), BLOB (hex), LOB (exact) all handled per the source contract.
* Non-empty tables are compared with the PUBLIC ``migration-team.py compare-data``
  CLI, keyed on the observed-unique primary key.  Empty tables are NOT run through
  compare-data (it refuses two empty exports); they pass only on real
  count==0 AND target-schema-present checks.
* The run is NEVER marked passed unless every referenced gate was actually
  executed with a pass.

CLI::

    python -m migration_team.full_validation \
        --manifest snapshot/manifest.json --ddl <oracle DDL/CONTOSO dir> \
        --gates acceptance-gates.json --target-schema contoso --database DB \
        --out <dir> [--tables T ...] [--source-only]

Target connection is taken from the standard libpq PG* environment.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import subprocess
import sys
from decimal import Decimal, getcontext
from datetime import datetime, date, timezone
from pathlib import Path

getcontext().prec = 80  # never round wide Decimals

NULL_TOKEN = '\x00NULL\x00'          # distinct from '' (Oracle '' IS NULL)
UNIT, GRP = '\x1f', '\x1e'           # field / group separators for composite renders
HERE = Path(__file__).resolve().parent
PUBLIC_CLI = HERE.parent / 'migration-team.py'

# Cells above this many UTF-8 bytes are replaced by a length+sha256 wrapper,
# applied IDENTICALLY on both sides. This keeps every CSV field well under the
# csv module's 131072 field-size limit (which compare-data's reader enforces),
# and still detects any difference for large LONG/CLOB/BLOB/XML/collection values
# (length + content hash satisfies the DATA-LONG-LOB gate).
BIG_CELL_BYTES = 32768


def bound_cell(s: str) -> str:
    b = s.encode('utf-8')
    if len(b) > BIG_CELL_BYTES:
        return 'BIG:len=%d:sha256=%s' % (len(b), hashlib.sha256(b).hexdigest())
    return s


# --------------------------------------------------------------------------- #
# Canonical projector -- one function used on BOTH sides.                      #
# --------------------------------------------------------------------------- #
class Projector:
    """Render a decoded scalar/complex value to canonical text per its rule."""

    def __init__(self, type_registry):
        self.reg = type_registry  # udt name -> {kind, ordered, element_type, attributes, under}

    def decimal_canon(self, d: Decimal) -> str:
        s = format(d, 'f')          # fixed-point, exact, no rounding
        if '.' in s:
            s = s.rstrip('0').rstrip('.')
        return s if s not in ('', '-', '-0') else '0'

    def dt_canon(self, v, utc=False) -> str:
        # A bare `date` (a PostgreSQL `date`-typed target, which the schema gate accepts for source
        # rule 'date') has no time/tzinfo/microsecond. Normalise it to MIDNIGHT of that day and fall
        # through to the common timestamp format, so the SAME calendar day compares EQUAL to an
        # Oracle DATE at 00:00:00, a non-midnight Oracle DATE (time dropped by a date target) still
        # DIFFERS, and .tzinfo is never touched (no AttributeError / no crash).
        if isinstance(v, date) and not isinstance(v, datetime):
            v = datetime(v.year, v.month, v.day)
        if utc and v.tzinfo is not None:
            v = v.astimezone(timezone.utc).replace(tzinfo=None)
        elif v.tzinfo is not None:
            v = v.replace(tzinfo=None)
        spec = 'seconds' if v.microsecond == 0 else 'microseconds'
        return v.isoformat(timespec=spec)

    def scalar(self, v, rule):
        if v is None:
            return NULL_TOKEN
        if rule == 'numeric':
            return self.decimal_canon(v if isinstance(v, Decimal) else Decimal(str(v)))
        if rule == 'char':
            # EXACT byte/pad fidelity: Oracle CHAR is blank-padded to n and the reviewed TEXT
            # target keeps octet_length=n (byte-canonical), so compare byte-for-byte. Do NOT
            # rtrim -- trimming would hide a pad-fidelity gap. (Any semantic trim belongs to
            # KEY derivation, kept separate from value fidelity.)
            return str(v)
        if rule in ('varchar', 'lob_text'):
            return str(v)
        if rule == 'date':
            return self.dt_canon(v) if isinstance(v, (datetime, date)) else str(v)
        if rule == 'timestamp':
            return self.dt_canon(v)
        if rule == 'timestamp_ltz':
            return self.dt_canon(v, utc=True)
        if rule == 'binary':
            b = bytes(v) if isinstance(v, (bytes, bytearray, memoryview)) else v
            return b.hex() if isinstance(b, bytes) else str(b)
        raise ValueError('scalar rule %r cannot render %r' % (rule, type(v).__name__))

    def interval(self, months, days, seconds) -> str:
        """Canonical interval triple; months kept distinct from days (never conflated)."""
        m = Decimal(months or 0)
        d = Decimal(days or 0)
        s = Decimal(seconds or 0)
        return '%s|%s|%s' % (self.decimal_canon(m), self.decimal_canon(d), self.decimal_canon(s))

    def xml_c14n(self, text):
        if text is None:
            return NULL_TOKEN
        import xml.etree.ElementTree as ET
        try:
            return ET.canonicalize(text)          # logical XML equality
        except Exception:
            return 'XML_UNPARSEABLE:' + hashlib.sha256(text.encode('utf-8')).hexdigest()

    def object(self, triples, udt_name):
        # triples: (folded_attr_name, rule, decoded_value) in declared order
        parts = [name + '=' + self.render(av, arule) for (name, arule, av) in triples]
        return 'OBJ<%s>(' % udt_name + UNIT.join(parts) + ')'

    def collection(self, elements, ordered):
        # elements: list of already-rendered canonical strings
        if ordered:
            return 'VARR[' + UNIT.join(elements) + ']'
        return 'MSET{' + UNIT.join(sorted(elements)) + '}'   # nested table = multiset

    def render(self, value, rule):
        """Dispatch a decoded source value (scalars + Oracle object/collection dicts)."""
        if value is None and rule not in ('object', 'collection_varray', 'collection_nested'):
            return NULL_TOKEN
        if rule in ('numeric', 'char', 'varchar', 'lob_text', 'date', 'timestamp',
                    'timestamp_ltz', 'binary'):
            return self.scalar(value, rule)
        if rule == 'xml':
            return self.xml_c14n(value)
        if rule == 'interval_ym':
            if value is None:
                return NULL_TOKEN
            return self.interval(value['years'] * 12 + value['months'], 0, 0)
        if rule == 'interval_ds':
            if value is None:
                return NULL_TOKEN
            secs = Decimal(value['seconds']) + Decimal(value['microseconds']) / Decimal(1_000_000)
            return self.interval(0, value['days'], secs)
        if rule in ('object', 'collection_varray', 'collection_nested'):
            return self._complex_source(value, rule)
        raise ValueError('unknown rule %r' % rule)

    def _complex_source(self, value, rule):
        if value is None:
            return NULL_TOKEN
        if rule == 'object':
            udt = value['$oracle_object']
            info = self.reg.get(udt.strip('"'), {})
            attrs = value['attributes']
            ci = {k.upper(): k for k in attrs}      # Oracle returns UPPER attribute keys
            triples, used = [], set()
            for a in info.get('attributes', []):
                key = ci.get(a['name'].upper())
                used.add(key)
                av = decode_tag(attrs[key]) if key is not None else None
                triples.append((fold(a['name']), self._rule_for_type(a['type']), av))
            for k in sorted(k for k in attrs if k not in used):   # attrs the registry didn't list
                triples.append((fold(k), self._guess_rule(attrs[k]), decode_tag(attrs[k])))
            return self.object(triples, udt)
        udt = value['$oracle_collection']
        info = self.reg.get(udt.strip('"'), {})
        elem_rule = self._rule_for_type(info.get('element_type'))
        rendered = [self.render(decode_tag(e), elem_rule) for e in value['values']]
        return self.collection(rendered, ordered=bool(info.get('ordered')))

    def _rule_for_type(self, t):
        if not t:
            return 'varchar'
        u = t.upper().strip().strip('"')
        if u.startswith('T_') or u in self.reg:
            k = self.reg.get(u, {}).get('kind')
            return {'object': 'object', 'varray': 'collection_varray',
                    'table': 'collection_nested'}.get(k, 'object')
        if u.startswith('NUMBER') or u in ('FLOAT',):
            return 'numeric'
        if u.startswith('CHAR') or u.startswith('NCHAR'):
            return 'char'
        if u.startswith('DATE'):
            return 'date'
        if 'LOCAL TIME ZONE' in u:
            return 'timestamp_ltz'
        if u.startswith('TIMESTAMP'):
            return 'timestamp'
        return 'varchar'

    def _guess_rule(self, v):
        d = decode_tag(v)
        if isinstance(d, Decimal):
            return 'numeric'
        if isinstance(d, datetime):
            return 'timestamp'
        return 'varchar'


# --------------------------------------------------------------------------- #
# Source decoding (independent of the loader's encoder).                       #
# --------------------------------------------------------------------------- #
def decode_tag(v):
    if v is None or isinstance(v, (bool, int, float, str)):
        return v
    if isinstance(v, dict):
        if '$decimal' in v:
            return Decimal(v['$decimal'])
        if '$float' in v:
            return float(v['$float'])
        if '$datetime' in v:
            return datetime.fromisoformat(v['$datetime'])
        if '$bytes' in v:
            import base64
            return base64.b64decode(v['$bytes'])
        if '$interval_ds' in v:
            return v['$interval_ds']            # keep dict; projector handles
        if '$interval_ym' in v:
            return v['$interval_ym']
        return v                                # $oracle_object / $oracle_collection dict
    return v


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


# --------------------------------------------------------------------------- #
# Path containment + safe artifact naming (untrusted manifest/table names).    #
# --------------------------------------------------------------------------- #
def _contained_path(base, rel) -> Path:
    """Resolve ``base/rel`` and REQUIRE the result stays within ``base``: no absolute rel, no ``..``
    escape, and no symlink that resolves outside base (``.resolve()`` follows links). Raises
    ValueError on any violation. Used for every UNTRUSTED input path (manifest ``file`` entries,
    per-table DDL) so a crafted name like ``../x`` or ``/etc/passwd`` is refused before any read."""
    if rel is None or rel == '':
        raise ValueError('empty input path')
    p = Path(rel)
    if p.is_absolute() or p.drive or p.anchor:
        raise ValueError('absolute input path not permitted: %r' % (rel,))
    base_r = Path(base).resolve()
    full = (base_r / p).resolve()
    if full != base_r and base_r not in full.parents:
        raise ValueError('input path escapes %s: %r' % (base_r, rel))
    return full


def _artifact_stem(name: str) -> str:
    """Deterministic filesystem-SAFE per-table artifact stem for an arbitrary (possibly quoted /
    mixed-case / traversal-shaped) source table name. A readable sanitized prefix plus a stable
    content hash: distinct names never collide, and no path separators or ``..`` can appear -- so
    the SOURCE and TARGET CSVs live at genuinely distinct in-tree paths (a name like ``../P`` can no
    longer make ``source-csv/../P.csv`` and ``target-csv/../P.csv`` resolve to the SAME file and
    self-compare to a false PASS)."""
    safe = re.sub(r'[^A-Za-z0-9_]+', '_', name).strip('_')[:40]
    h = hashlib.sha1(name.encode('utf-8')).hexdigest()[:16]
    return '%s-%s' % (safe or 't', h)


def _function_body_pin(fndef):
    """Security pin over a trigger function body: the EXACT pg_get_functiondef bytes (every comment
    and all whitespace significant), never a whitespace-collapsed form. Two bodies that differ only
    by a comment or reformatting therefore produce DIFFERENT pins and cannot be accepted against
    each other -- and any manifest carrying an OLD whitespace-normalized hash fails closed until it
    is rebound to the exact reviewed artifact. Returns (sha256_hex, exact_text)."""
    raw = fndef or ''
    return hashlib.sha256(raw.encode('utf-8')).hexdigest(), raw


# --------------------------------------------------------------------------- #
# Source-side inventory parsed from manifest + genuine DDL (reusable).         #
# --------------------------------------------------------------------------- #
IDENT = re.compile(r'"([^"]+)"')


def _matching_paren(s, i):
    depth = 0
    for j in range(i, len(s)):
        if s[j] == '(':
            depth += 1
        elif s[j] == ')':
            depth -= 1
            if depth == 0:
                return j
    return -1


# OBJECT-type body keywords that begin the method section; attribute parsing stops here.
_METHOD_KEYWORDS = ('MEMBER', 'CONSTRUCTOR', 'STATIC', 'MAP', 'ORDER', 'FINAL', 'OVERRIDING', 'NOT')


def parse_type_registry(typedir: Path):
    reg = {}
    for f in sorted(typedir.glob('*.sql')):
        text = f.read_text()
        head = re.search(r'TYPE\s+"[^"]+"\."([^"]+)"(?:\s+UNDER\s+(\w+))?\s+(?:AS|IS)\s+(OBJECT|VARRAY|TABLE)',
                         text, re.I)
        if not head:
            continue
        tname, under, kind = head.group(1), head.group(2), head.group(3).upper()
        e = {'kind': kind.lower(), 'under': under}
        if kind == 'VARRAY':
            mv = re.search(r'VARRAY\s*\(\s*(\d+)\s*\)\s+OF\s+(.+?)[;\n]', text, re.I)
            e['ordered'] = True
            e['element_type'] = mv.group(2).strip() if mv else None
        elif kind == 'TABLE':
            mt = re.search(r'TABLE\s+OF\s+(.+?)[;\n]', text, re.I)
            e['ordered'] = False
            e['element_type'] = mt.group(1).strip() if mt else None
        else:
            oi = text.find('(', head.end())
            ci = _matching_paren(text, oi)
            attrs = []
            for line in text[oi + 1:ci].split('\n'):
                s = line.strip().rstrip(',').strip()
                if not s:
                    continue
                if s.upper().startswith(_METHOD_KEYWORDS):
                    break                       # method section begins: attribute list is done
                tok = s.split()
                attrs.append({'name': tok[0].strip('"'), 'type': ' '.join(tok[1:]) or None})
            e['attributes'] = attrs
        reg[tname] = e
    return reg


def category(c, reg):
    t = (c.get('type') or '').upper()
    if t == 'XMLTYPE':
        return 'xml'
    # A column is a user-defined object/collection iff its declared type is present in the
    # source TYPE registry parsed from the genuine DDL (the same mechanism Projector._rule_for_type
    # uses).  This derives object/collection-ness from explicit SOURCE metadata rather than a
    # hardcoded owner literal, so the module stays schema/owner-agnostic (never conflating the
    # source owner with a target schema name).
    tn = t.strip('"')
    if tn in reg:
        k = reg.get(tn, {}).get('kind')
        return {'varray': 'collection_varray', 'table': 'collection_nested'}.get(k, 'object')
    if t in ('BLOB', 'RAW', 'LONG RAW', 'BFILE'):
        return 'binary'
    if t in ('CLOB', 'NCLOB', 'LONG'):
        return 'lob_text'
    if t.startswith('INTERVAL'):
        return 'interval_ym' if 'YEAR' in t else 'interval_ds'
    if t in ('NUMBER', 'FLOAT', 'BINARY_FLOAT', 'BINARY_DOUBLE'):
        return 'numeric'
    if 'LOCAL TIME ZONE' in t:
        return 'timestamp_ltz'
    if t.startswith('TIMESTAMP'):
        return 'timestamp'
    if t == 'DATE':
        return 'date'
    if t in ('CHAR', 'NCHAR'):
        return 'char'
    return 'varchar'


def parse_keys_and_gen(ddl_text, colmeta):
    def constraints(kind):
        out, seen = [], set()
        for m in re.finditer(r'CONSTRAINT\s+"([^"]+)"\s+' + kind.replace(' ', r'\s+') + r'\s*\(([^)]*)\)',
                             ddl_text):
            if m.group(1) in seen:
                continue
            seen.add(m.group(1))
            out.append({'name': m.group(1), 'columns': IDENT.findall(m.group(2))})
        return out
    pks = constraints('PRIMARY KEY')
    uniq = constraints('UNIQUE')
    # generated columns from CREATE TABLE column list
    generated = []
    mt = re.search(r'CREATE TABLE\s+"[^"]+"\."[^"]+"\s*', ddl_text)
    if mt:
        oi = ddl_text.find('(', mt.end())
        ci = _matching_paren(ddl_text, oi)
        inner = ddl_text[oi + 1:ci]
        depth, start, segs = 0, 0, []
        for i, ch in enumerate(inner):
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
            elif ch == ',' and depth == 0:
                segs.append(inner[start:i])
                start = i + 1
        segs.append(inner[start:])
        for seg in segs:
            s = seg.strip()
            if s.startswith('"') and 'GENERATED ALWAYS AS' in s.upper() and 'IDENTITY' not in s.upper():
                generated.append(IDENT.search(s).group(1))
    pk = pks[0] if pks else None
    usable = None
    if pk and all(colmeta.get(c, {}).get('nullable') == 'N' and c not in generated for c in pk['columns']):
        usable = pk
    else:
        for u in uniq:
            if all(colmeta.get(c, {}).get('nullable') == 'N' and c not in generated for c in u['columns']):
                usable = u
                break
    check_count = len(set(re.findall(r'CONSTRAINT\s+"([^"]+)"\s+CHECK\s*\(', ddl_text)))
    return {'primary_key': pk, 'unique': uniq, 'generated': generated, 'usable_key': usable,
            'check_count': check_count}


def parse_triggers(trigdir: Path):
    by_table = {}
    for f in sorted(trigdir.glob('*.sql')):
        text = f.read_text()
        mt = re.search(r'\bON\s+"CONTOSO"\."([^"]+)"', text, re.I)
        mn = re.search(r'TRIGGER\s+"CONTOSO"\."([^"]+)"', text, re.I)
        if mt and mn:
            by_table.setdefault(mt.group(1), []).append(mn.group(1))
    return by_table


def parse_foreign_keys(refdir: Path, tabledir: Path):
    fks = []
    pat = re.compile(r'CONSTRAINT\s+"([^"]+)"\s+FOREIGN KEY\s*\(([^)]*)\)\s*REFERENCES\s+'
                     r'"CONTOSO"\."([^"]+)"\s*\(([^)]*)\)', re.I)
    sources = list(refdir.glob('*.sql')) if refdir.exists() else []
    sources += list(tabledir.glob('*.sql'))
    seen = set()
    for f in sources:
        text = f.read_text()
        owner = re.search(r'ALTER TABLE\s+"CONTOSO"\."([^"]+)"', text)
        for m in pat.finditer(text):
            key = m.group(1)
            if key in seen:
                continue
            seen.add(key)
            fks.append({'name': key, 'table': owner.group(1) if owner else None,
                        'columns': IDENT.findall(m.group(2)),
                        'ref_table': m.group(3), 'ref_columns': IDENT.findall(m.group(4))})
    return fks


# --------------------------------------------------------------------------- #
# Inventory assembly.                                                          #
# --------------------------------------------------------------------------- #
def fold(name):
    return name.lower() if name.isupper() else name


def build_inventory(manifest_path: Path, ddl_root: Path):
    m = json.loads(Path(manifest_path).read_text())
    snapdir = Path(manifest_path).resolve().parent
    tabledir, typedir = ddl_root / 'TABLE', ddl_root / 'TYPE'
    trigdir, refdir = ddl_root / 'TRIGGER', ddl_root / 'REF_CONSTRAINT'
    reg = parse_type_registry(typedir)
    triggers = parse_triggers(trigdir)
    fks = parse_foreign_keys(refdir, tabledir)
    per_table = {}
    for tb in m['tables']:
        name = tb['table']
        colmeta = {c['name']: c for c in tb['columns']}
        # Containment guard on UNTRUSTED input paths (crafted table name / manifest file entry):
        # reject any absolute or ``..``/symlink path BEFORE reading -- and before any target connect.
        ddl_path = _contained_path(tabledir, name + '.sql')
        _contained_path(snapdir, tb['file'])          # validate source JSONL path (read at project time)
        kg = parse_keys_and_gen(ddl_path.read_text(), colmeta)
        cols = [{'name': c['name'], 'target': fold(c['name']), 'rule': category(c, reg),
                 'oracle_type': (c.get('type') or '').upper(),
                 'precision': c.get('precision'), 'scale': c.get('scale'),
                 'nullable': c.get('nullable'), 'generated': c['name'] in kg['generated']}
                for c in tb['columns']]
        per_table[name] = {
            'rows': tb['rows'], 'file': tb['file'], 'sha256': tb['sha256'],
            'columns': cols, 'usable_key': kg['usable_key'], 'generated': kg['generated'],
            'primary_key': kg['primary_key'], 'unique_constraints': kg['unique'],
            'check_count': kg['check_count'],
            'triggers': triggers.get(name, []),
            'foreign_keys': [f for f in fks if f['table'] == name],
            'complex_columns': [c['name'] for c in cols
                                if c['rule'] in ('object', 'collection_varray', 'collection_nested', 'xml')],
        }
    return m, {'schema': m.get('schema'), 'observed_scn': m.get('observed_scn'),
               'type_registry': reg, 'foreign_keys': fks, 'triggers': triggers,
               'excluded': m.get('excluded', []), 'per_table': per_table}


# --------------------------------------------------------------------------- #
# Source projection (JSONL -> canonical CSV).                                  #
# --------------------------------------------------------------------------- #
def project_source(snapdir: Path, entry, proj: Projector, out_csv: Path):
    cols = entry['columns']
    header = [c['target'] for c in cols]
    n = 0
    src_path = _contained_path(snapdir, entry['file'])       # reject ../ / absolute / symlink escape
    # Verify the source JSONL is the GENUINE snapshot bytes pinned in the manifest BEFORE projecting,
    # and re-verify AFTER, so tampered content (even with a matching row count) is refused and a
    # mid-read modification is detected. The pinned digest is the manifest's per-member sha256.
    expected = entry.get('sha256')
    if not expected:
        raise ValueError('manifest entry for %r has no sha256 pin' % (entry.get('file'),))
    before = sha256_file(src_path)
    if before != expected:
        raise ValueError('source %r sha256 %s != manifest pin %s (not the genuine snapshot bytes)'
                         % (entry['file'], before, expected))
    with open(out_csv, 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh)
        w.writerow(header)
        with src_path.open(encoding='utf-8') as src:
            for line in src:
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                w.writerow([bound_cell(proj.render(decode_tag(row[i]), cols[i]['rule']))
                            for i in range(len(cols))])
                n += 1
    if sha256_file(src_path) != before:
        raise ValueError('source %r changed during projection; take a consistent snapshot and retry'
                         % (entry['file'],))
    return n


# --------------------------------------------------------------------------- #
# Target export (PostgreSQL -> canonical CSV), lossless per column type.       #
# --------------------------------------------------------------------------- #
COMPLEX_RULES = ('object', 'collection_varray', 'collection_nested')


def register_target_composites(conn, reg, schema):
    """Register every reviewed OBJECT type as a psycopg composite so composite
    columns come back as named tuples and arrays-of-composite as lists of them.
    Fetches from the SAME target schema the rest of the run is parameterized on (not a
    hardcoded owner), and returns the set of registered (UPPERCASE) type names.  A type
    absent on the target simply is not registered (CompositeInfo.fetch returns None) and
    its columns then fail closed as blocked_complex_target_render in export_target; genuine
    fetch/registration errors are NOT swallowed."""
    from psycopg.types.composite import CompositeInfo, register_composite
    registered = set()
    for tname, info in reg.items():
        if info.get('kind') != 'object':
            continue
        ci = CompositeInfo.fetch(conn, '%s.%s' % (schema, tname.lower()))
        if ci is not None:
            register_composite(ci, conn)
            registered.add(tname.upper())
    return registered


def _pg_to_source_shape(value, oracle_type, reg):
    """Convert a PG composite (named tuple) / array (list) into the source-encoded
    {$oracle_object | $oracle_collection} shape, so the SAME Projector renders the
    target identically to the source (labels use the Oracle type name upper-cased)."""
    if value is None:
        return None
    info = reg.get(oracle_type.upper(), {})
    kind = info.get('kind')
    if kind == 'object':
        reg_attrs = info.get('attributes', [])
        # If the live composite carries a DIFFERENT number of fields than the parsed source type
        # registry lists, the registry under-parsed this OBJECT (e.g. a method clause truncated the
        # attribute list) or the target type is structurally different. Rendering only the parsed
        # attributes would silently DROP the extras and desync from the source projection (a false
        # parity_fail); instead fail CLOSED clearly so the column is reported blocked, not mis-passed.
        n_fields = len(getattr(value, '_fields', None) or value)
        if n_fields != len(reg_attrs):
            raise NotImplementedError(
                'composite %s: target tuple has %d fields but source type registry parsed %d '
                'attributes (registry under-parse or structural mismatch); cannot render faithfully'
                % (oracle_type.upper(), n_fields, len(reg_attrs)))
        out = {}
        for i, a in enumerate(reg_attrs):
            fld = fold(a['name'])
            fv = getattr(value, fld, None) if hasattr(value, '_fields') else value[i]
            nested = (a.get('type') or '').upper().strip().strip('"')
            out[a['name'].upper()] = _pg_to_source_shape(fv, nested, reg) if nested in reg else fv
        return {'$oracle_object': oracle_type.upper(), 'attributes': out}
    if kind in ('varray', 'table'):
        enorm = (info.get('element_type') or '').upper().strip().strip('"')
        vals = [(_pg_to_source_shape(e, enorm, reg) if enorm in reg else e) for e in value]
        return {'$oracle_collection': oracle_type.upper(), 'values': vals}
    return value


def _needed_composite(c, reg):
    """The composite type name a complex column needs registered (or None)."""
    if c['rule'] == 'object':
        return c['oracle_type']
    info = reg.get(c['oracle_type'], {})
    elem = (info.get('element_type') or '').upper().strip().strip('"')
    return elem if reg.get(elem, {}).get('kind') == 'object' else None


def _target_select(qcol, rule):
    """Per-column SELECT expression(s) as psycopg sql.Composed (identifier-safe)."""
    from psycopg import sql
    if rule == 'binary':
        return [sql.SQL("encode({c},'hex')").format(c=qcol)]
    if rule == 'xml':
        return [sql.SQL("xmlserialize(document {c} as text)").format(c=qcol)]
    if rule == 'interval_ym':
        return [sql.SQL("(EXTRACT(YEAR FROM {c})*12+EXTRACT(MONTH FROM {c}))").format(c=qcol)]
    if rule == 'interval_ds':
        return [sql.SQL("EXTRACT(DAY FROM {c})").format(c=qcol),
                sql.SQL("(EXTRACT(HOUR FROM {c})*3600+EXTRACT(MINUTE FROM {c})*60"
                        "+EXTRACT(SECOND FROM {c}))").format(c=qcol)]
    return [sql.SQL("{c}").format(c=qcol)]   # scalar, xml/binary handled above, and complex (adapted)


def export_target(conn, schema, entry, proj: Projector, out_csv: Path, registered=frozenset()):
    from psycopg import sql
    cols = entry['columns']
    reg = proj.reg
    blocked = [c['name'] for c in cols
               if c['rule'] in COMPLEX_RULES and (_needed_composite(c, reg) or '') not in registered
               and _needed_composite(c, reg) is not None]
    if blocked:
        raise NotImplementedError('target composite type(s) not present/registered for columns: %r' % blocked)
    exprs, plan = [], []
    for c in cols:
        pieces = _target_select(sql.Identifier(c['target']), c['rule'])
        idxs = []
        for expr in pieces:
            idxs.append(len(exprs))
            exprs.append(expr)
        plan.append((c, idxs))
    query = sql.SQL("SELECT {cols} FROM {tbl}").format(
        cols=sql.SQL(', ').join(exprs), tbl=sql.Identifier(schema, entry['target_table']))
    with conn.cursor() as cur:
        cur.execute("SET TIME ZONE 'UTC'")
        cur.execute(query)
        rows = cur.fetchall()
    header = [c['target'] for c in cols]
    with open(out_csv, 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh)
        w.writerow(header)
        for r in rows:
            out = []
            for c, idxs in plan:
                out.append(bound_cell(_render_target_cell(proj, c, [r[i] for i in idxs])))
            w.writerow(out)
    return len(rows)


def _render_target_cell(proj: Projector, c, vals):
    rule = c['rule']
    if rule == 'interval_ym':
        return NULL_TOKEN if vals[0] is None else proj.interval(vals[0], 0, 0)
    if rule == 'interval_ds':
        return NULL_TOKEN if (vals[0] is None and vals[1] is None) else proj.interval(0, vals[0], vals[1])
    v = vals[0]
    if rule == 'xml':
        return proj.xml_c14n(v)
    if rule == 'binary':
        return NULL_TOKEN if v is None else str(v)          # already hex text
    if rule in COMPLEX_RULES:
        return proj.render(_pg_to_source_shape(v, c['oracle_type'], proj.reg), rule)
    return proj.scalar(v, rule)


# --------------------------------------------------------------------------- #
# Public compare-data invocation.                                             #
# --------------------------------------------------------------------------- #
def compare_data(python, source_csv, target_csv, keys, out_json):
    out_json = Path(out_json)
    # The public CLI refuses to overwrite an existing --output (to preserve prior
    # evidence). full_validation owns this evidence tree and regenerates it every
    # run, so clear any stale file first -- otherwise a re-run would read the OLD
    # comparison and mask a changed result.
    if out_json.exists():
        out_json.unlink()
    argv = [str(python), str(PUBLIC_CLI), 'compare-data',
            '--source', str(source_csv), '--target', str(target_csv), '--output', str(out_json)]
    for k in keys:
        argv += ['--key', k]
    proc = subprocess.run(argv, capture_output=True, text=True)
    result = json.loads(out_json.read_text()) if out_json.exists() else {'status': 'error',
                                                                          'stderr': proc.stderr}
    result['_exit'] = proc.returncode
    return result


# --------------------------------------------------------------------------- #
# Target schema + per-table validation.                                       #
# --------------------------------------------------------------------------- #
# Acceptable target data_type/udt families per source rule (structural gate; the
# exact converted type is verified against the reviewed assembly manifest when
# supplied, but this catches gross conversions e.g. a numeric column made text).
TYPE_FAMILY = {
    'numeric': {'numeric', 'integer', 'bigint', 'smallint', 'real', 'double precision'},
    'char': {'character'},
    'varchar': {'character varying', 'text'},
    'lob_text': {'text'},
    'date': {'timestamp without time zone', 'timestamp with time zone', 'date'},
    'timestamp': {'timestamp without time zone', 'timestamp with time zone'},
    'timestamp_ltz': {'timestamp with time zone', 'timestamp without time zone'},
    'binary': {'bytea'},
    'xml': {'xml'},
    'interval_ym': {'interval'},
    'interval_ds': {'interval'},
    'object': {'USER-DEFINED', 'jsonb'},
    'collection_varray': {'ARRAY', 'USER-DEFINED', 'jsonb'},
    'collection_nested': {'ARRAY', 'USER-DEFINED', 'jsonb'},
}


def _norm_sql(s):
    """Collapse whitespace for stable expression/predicate comparison + hashing."""
    return ' '.join(s.split()) if s is not None else None


# --------------------------------------------------------------------------- #
# Byte-length (octet_length) CHECK guard -- conservative WHOLE-predicate grammar #
# --------------------------------------------------------------------------- #
# We must not credit a column from a substring or a fragment inside a larger predicate. A guard is
# accepted ONLY if the ENTIRE CHECK predicate is exactly a byte-length constraint on ONE column:
#   octet_length(<col>) <op> <N>                         (op is '<=' for VARCHAR2(n BYTE)->TEXT,
#   <col> IS NULL OR octet_length(<col>) <op> <N>         '=' for the fixed CHAR(n BYTE)->TEXT)
# where <col> is a bare or "quoted" identifier with an OPTIONAL ::text cast only (a cast to any
# other type is rejected), <N> is a bare non-negative integer, and the nullable wrapper's column
# equals the guarded column. This rejects OR TRUE / extra disjuncts, arithmetic bounds (20*1000),
# non-text casts (::name), string literals, wrong columns, and wrong operators.
_IDENT_RE = r'(?:"[^"]+"|[A-Za-z_][A-Za-z0-9_$]*)'
_OCTET_ARG = r'octet_length\(\s*\(?\s*(' + _IDENT_RE + r')\s*\)?\s*(?:::\s*text\b\s*)?\)'
_GUARD_SIMPLE = re.compile(r'(?i)^' + _OCTET_ARG + r'\s*(<=|=)\s*(\d+)$')
_GUARD_NULLABLE = re.compile(
    r'(?i)^\(?\s*(' + _IDENT_RE + r')\s+is\s+null\s*\)?\s+or\s+\(?\s*'
    + _OCTET_ARG + r'\s*(<=|=)\s*(\d+)\s*\)?$')


def _ident_name(tok):
    """Canonical identifier name: a "quoted" token keeps its exact case; an unquoted token folds to
    lowercase (PostgreSQL's rule), matching this module's fold() of the target column name."""
    tok = tok.strip()
    if len(tok) >= 2 and tok[0] == '"' and tok[-1] == '"':
        return tok[1:-1]
    return tok.lower()


def _strip_wrapping_parens(s):
    s = s.strip()
    while len(s) >= 2 and s[0] == '(' and s[-1] == ')':
        depth, wraps = 0, True
        for i, ch in enumerate(s):
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
                if depth == 0 and i != len(s) - 1:
                    wraps = False
                    break
        if not wraps:
            break
        s = s[1:-1].strip()
    return s


def _parse_octet_guard(defstr):
    """Parse a WHOLE CHECK predicate that is exactly a byte-length guard on one column.
    Returns (canonical_column_name, op, bound) or None."""
    s = _norm_sql(defstr) or ''
    m = re.match(r'(?i)^check\s*\((.*)\)$', s)
    inner = _strip_wrapping_parens(m.group(1) if m else s)
    g = _GUARD_SIMPLE.match(inner)
    if g:
        return _ident_name(g.group(1)), g.group(2), int(g.group(3))
    g = _GUARD_NULLABLE.match(inner)
    if g and _ident_name(g.group(1)) == _ident_name(g.group(2)):
        return _ident_name(g.group(2)), g.group(3), int(g.group(4))
    return None


def _octet_guard_for(defs, col):
    """Return (op, bound) of the whole-predicate octet_length guard bound to EXACTLY ``col``, or
    None. ``col`` is the canonical target column name (fold() of the source name): unquoted names
    are already lowercase, quoted mixed-case names keep their case -- both equal _parse_octet_guard's
    _ident_name() of the identifier in the constraint."""
    for d in defs:
        parsed = _parse_octet_guard(d)
        if parsed and parsed[0] == col:
            return parsed[1], parsed[2]
    return None


def _primary_key_ok(pk_columns, unique_col_sets, usable_key, source_pk):
    """Decide whether the target key constraints satisfy the source key contract, and report
    whether the usable_key is the source PRIMARY KEY.

    * usable_key IS the source PRIMARY KEY (normal case): the target PRIMARY KEY must match it
      exactly and IN ORDER (column order backs the unique index / FK match).
    * usable_key is a FALLBACK UNIQUE (source PK unusable/absent): the row-comparison key must
      exist on the target as a PK or UNIQUE by COLUMN SET; the target's own PRIMARY KEY may
      legitimately differ (e.g. a surrogate), so PK equality is NOT forced.
    * no usable key at all: require the target to declare some PRIMARY KEY.
    """
    uk_cols = [fold(c) for c in usable_key['columns']] if usable_key else []
    uk_is_source_pk = bool(usable_key and source_pk and usable_key.get('name') == source_pk.get('name'))
    if uk_is_source_pk:
        return list(pk_columns) == uk_cols, uk_is_source_pk
    if uk_cols:
        target_key_sets = {frozenset(pk_columns)} | {frozenset(u) for u in unique_col_sets}
        return frozenset(uk_cols) in target_key_sets, uk_is_source_pk
    return bool(pk_columns), uk_is_source_pk


def _target_columns(conn, schema, table):
    with conn.cursor() as cur:
        cur.execute("SELECT column_name, data_type, udt_name, is_nullable, "
                    "COALESCE(is_generated,'NEVER'), numeric_precision, numeric_scale, "
                    "character_maximum_length, datetime_precision, column_default, "
                    "generation_expression "
                    "FROM information_schema.columns "
                    "WHERE table_schema=%s AND table_name=%s ORDER BY ordinal_position",
                    (schema, table))
        return [{'name': r[0], 'data_type': r[1], 'udt_name': r[2],
                 'nullable': r[3] == 'YES', 'generated': r[4] != 'NEVER',
                 'numeric_precision': r[5], 'numeric_scale': r[6],
                 'char_max_length': r[7], 'datetime_precision': r[8],
                 'default': _norm_sql(r[9]), 'generation_expr': _norm_sql(r[10]),
                 'with_tz': 'with time zone' in (r[1] or '')} for r in cur.fetchall()]


def _target_check_defs(conn, schema, table):
    """Normalized CHECK-constraint definitions on the live target (order-independent
    set), e.g. 'CHECK ((valid_to IS NULL) OR (valid_to > valid_from))' and any
    byte-length guard 'CHECK (octet_length((tax_code)::text) <= 20)'."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT pg_get_constraintdef(c.oid, true) FROM pg_constraint c "
            "JOIN pg_class r ON r.oid=c.conrelid JOIN pg_namespace n ON n.oid=r.relnamespace "
            "WHERE n.nspname=%s AND r.relname=%s AND c.contype='c'", (schema, table))
        defs = {_norm_sql(r[0]) for r in cur.fetchall()}
    shas = {hashlib.sha256(d.encode('utf-8')).hexdigest() for d in defs}
    return defs, shas


def _target_triggers(conn, schema, table):
    """Live triggers on the target table with the FULL binding needed to prove a
    normalizer actually runs for normal application writes: timing (BEFORE), level
    (ROW vs STATEMENT), events (INSERT/UPDATE), enable-mode (O/A fire for origin
    sessions; R is replica-only; D disabled), any WHEN condition, UPDATE OF column
    restriction, arg count, and the normalized+hashed function body."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT t.tgname, t.tgenabled, t.tgtype, n.nspname||'.'||p.proname, pg_get_functiondef(p.oid), "
            "  pg_get_triggerdef(t.oid), t.tgnargs, "
            "  (SELECT array_agg(a.attname ORDER BY k.ord) "
            "     FROM unnest(t.tgattr::int2[]) WITH ORDINALITY k(attnum,ord) "
            "     JOIN pg_attribute a ON a.attrelid=t.tgrelid AND a.attnum=k.attnum) "
            "FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid "
            "JOIN pg_namespace cn ON cn.oid=c.relnamespace "
            "JOIN pg_proc p ON p.oid=t.tgfoid JOIN pg_namespace n ON n.oid=p.pronamespace "
            "WHERE cn.nspname=%s AND c.relname=%s AND NOT t.tgisinternal", (schema, table))
        out = []
        for name, en, tgtype, fnident, fndef, tdef, nargs, upof in cur.fetchall():
            def_sha, def_exact = _function_body_pin(fndef)   # EXACT bytes; NOT whitespace-collapsed
            m = re.search(r'\bWHEN\s*\((.*)\)\s+EXECUTE\b', tdef or '', re.I | re.S)   # robust WHEN detect
            am = re.search(r'EXECUTE\s+(?:FUNCTION|PROCEDURE)\s+[^(]*\((.*)\)\s*$', tdef or '', re.I | re.S)
            out.append({'name': name, 'tgenabled': en, 'fires_origin': en in ('O', 'A'),
                        'before': bool(tgtype & 2), 'row': bool(tgtype & 1),
                        'insert': bool(tgtype & 4), 'update': bool(tgtype & 16),
                        'function': fnident, 'when': m.group(1).strip() if m else None,
                        'update_of': list(upof) if upof else [], 'nargs': nargs,
                        'args': _norm_sql(am.group(1)) if am else '',   # exact TG_ARGV values, not just count
                        'def_sha256': def_sha, 'def_exact': def_exact})
        return out


def load_adaptation(path):
    """Load the REVIEWED adaptation manifest of EXPECTED TARGET expressions/hashes,
    keyed by folded table name. This is the ONLY sanctioned source for CHECK
    predicates, DEFAULT expressions, GENERATED expressions, byte-length guards, and
    timestamp semantics -- we do not attempt generic cross-dialect string identity.
    Per-table expected shape:
      {"checks": ["CHECK (...)" | "sha256:<hex>", ...],   # extra expected target predicates
       "source_checks": {"<SRC_CONSTRAINT_ID>": "CHECK (...)" | ["..."] | "sha256:<hex>"
                          | {"replacement": "...", "reason": "..."}, ...},  # EVERY source
                         # business CHECK id must appear (mapped predicate must be on target;
                         # a reviewed semantic replacement is accounted but not target-matched)
       "defaults": {"<col>": "<expr>"|null, ...},
       "generated": {"<col>": "<generation expr>", ...},
       "datetime": {"<col>": {"data_type": "...", "precision": <int>|null}, ...},
       "representation": {"<col>": {"kind": "char_as_text"}                # CHAR(n BYTE)->TEXT
                          | {"kind": "varchar_as_text", "octet_max": <N>}  # VARCHAR2(n BYTE)->TEXT
                          | {"kind": "date_as_timestamp", "datetime_precision": <int>}, ...},
       "normalizer": {"definition_sha256": "<hex>" | "definition": "<normalized body>",
                      "function": "<schema.func>"?,       # BODY pin REQUIRED; name optional/additional
                      "when": "<expr>"?, "update_of": [<cols>]?, "nargs": <int>?,
                      "tgargs": [<arg values>] | "<rendered args>"?}}  # if nargs>0, EXACT arg
                      # values must be pinned (count alone is not identity) or the gate fails closed
       # representation overrides the generic family/declared-length/precision rules for the
       # reviewed scalar adapters. char_as_text REQUIRES an octet_length guard; varchar_as_text
       # REQUIRES the EXACT octet_length(col)<=octet_max guard (octet_max == source DATA_LENGTH)
       # AND a HARD live-gated normalizer: a BEFORE ROW INSERT+UPDATE trigger that fires for
       # ORIGIN sessions (tgenabled O/A), is UNCONDITIONAL (no WHEN unless pinned), fires for ALL
       # columns (no UPDATE OF unless pinned), has the expected arg count (default 0), and whose
       # function BODY matches the pinned definition[_sha256]. Never blanket TEXT.
    """
    doc = json.loads(Path(path).read_text())
    tables = doc.get('tables', doc)          # allow {"tables": {...}} or a bare map
    return {fold(k): v for k, v in tables.items()}


def _catalog_int(v):
    if isinstance(v, dict) and '$decimal' in v:
        return int(v['$decimal'])
    return int(v) if v is not None and v != '' else None


def load_source_catalog(catalog_dir):
    """Load per-column declared length + user UNIQUE column-sets + per-table full-scope
    REQUIREMENTS from the READ-ONLY source catalog (columns.json +
    constraints-full.json) for the empty-table schema gate. System uniques on hidden
    SYS_NC$ nested-table columns are excluded (no PG equivalent).

    'requirements' drives completeness: an EMPTY expected list in the adaptation is NOT
    a waiver when the SOURCE actually carries that requirement. Per folded table:
      checks   -> bool: table has >=1 USER-NAMED CHECK (business predicate; system
                  NOT-NULL checks 'GENERATED NAME' are excluded, already covered by NOT NULL)
      check_ids-> {CONSTRAINT_NAME}: EVERY source business CHECK id -- the adaptation must
                  map each one to an expected PG predicate or a reviewed semantic replacement
                  (not merely provide one arbitrary non-empty check)
      defaults -> {folded col}: columns with a real DATA_DEFAULT (non-virtual)
      generated-> {folded col}: VIRTUAL_COLUMN='YES' AND a real DATA_DEFAULT expression
                  (genuine GENERATED ALWAYS AS); the 4 STORED-mislabeled-virtual columns
                  with NULL DATA_DEFAULT are loaded DATA, NOT a generation requirement
      byte     -> {folded col}: VARCHAR2 columns with CHAR_USED='B' (need an octet_length guard)
      datetime -> {folded col}: TIMESTAMP-family columns (precision / WITH [LOCAL] TIME ZONE)
    """
    cd = Path(catalog_dir)
    cols = json.loads((cd / 'columns.json').read_text())['rows']
    length = {(r['TABLE_NAME'], r['COLUMN_NAME']): _catalog_int(r.get('DATA_LENGTH')) for r in cols}
    req = {}

    def rq(tbl):
        return req.setdefault(fold(tbl), {'checks': False, 'check_ids': set(), 'defaults': set(),
                                          'generated': set(), 'byte': set(), 'datetime': set()})
    for r in cols:
        col = fold(r['COLUMN_NAME'])
        virtual = r.get('VIRTUAL_COLUMN') == 'YES'
        has_default = r.get('DATA_DEFAULT') not in (None, '')
        if virtual and has_default:
            # GENUINE generated: VIRTUAL with a real generation expression (DATA_DEFAULT).
            rq(r['TABLE_NAME'])['generated'].add(col)
        elif not virtual and has_default:
            # real column DEFAULT.
            rq(r['TABLE_NAME'])['defaults'].add(col)
        # else: VIRTUAL with NULL DATA_DEFAULT = STORED-mislabeled-virtual (the 4 complex
        # columns: PRODUCT.SPEC_SHEET/ATTRIBUTES, LOYALTY_TIER.BENEFITS, PROMOTION.RULE_XML).
        # These carry real data -> loaded + value-compared as normal columns; NOT a
        # generation requirement (forcing a generated manifest entry regresses the loader trap).
        if r['DATA_TYPE'] == 'VARCHAR2' and r.get('CHAR_USED') == 'B':
            rq(r['TABLE_NAME'])['byte'].add(col)
        if str(r['DATA_TYPE']).startswith('TIMESTAMP'):
            rq(r['TABLE_NAME'])['datetime'].add(col)
    con = json.loads((cd / 'constraints-full.json').read_text())
    concols = con['columns']['rows'] if isinstance(con['columns'], dict) else con['columns']
    by_con = {}
    for r in concols:
        by_con.setdefault(r['CONSTRAINT_NAME'], []).append((_catalog_int(r.get('POSITION')) or 0, r['COLUMN_NAME']))
    unique_sets = {}
    for c in con['constraints']:
        if c.get('CONSTRAINT_TYPE') == 'C' and c.get('GENERATED') != 'GENERATED NAME':
            # user-named business CHECK (verified for this snapshot vs actual predicates:
            # all 255 GENERATED-NAME checks are exactly "col IS NOT NULL", all 206 USER-NAME
            # are non-NOT-NULL business predicates). Track the exact ID so the adaptation
            # must map EVERY one, not merely be non-empty.
            e = rq(c['TABLE_NAME'])
            e['checks'] = True
            e['check_ids'].add(c['CONSTRAINT_NAME'])
        if c.get('CONSTRAINT_TYPE') != 'U':
            continue
        names = [cn for _, cn in sorted(by_con.get(c['CONSTRAINT_NAME'], []))]
        if any(cn.startswith('SYS_NC') for cn in names):     # nested-table storage internal
            continue
        unique_sets.setdefault(c['TABLE_NAME'], set()).add(frozenset(fold(cn) for cn in names))
    return {'length': length, 'unique_sets': unique_sets, 'requirements': req}


def _target_constraints(conn, schema, table):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT c.contype, "
            "  (SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(c.conkey) WITH ORDINALITY k(attnum,ord) "
            "     JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum) "
            "FROM pg_constraint c JOIN pg_class r ON r.oid=c.conrelid "
            "JOIN pg_namespace n ON n.oid=r.relnamespace WHERE n.nspname=%s AND r.relname=%s",
            (schema, table))
        pk, uq, chk = [], [], 0
        for contype, colnames in cur.fetchall():
            if contype == 'p':
                pk = list(colnames or [])
            elif contype == 'u':
                uq.append(list(colnames or []))
            elif contype == 'c':
                chk += 1
        return {'pk_columns': pk, 'unique': uq, 'check_count': chk}


def _check_target_schema(conn, schema, name, entry, catalog=None, adaptation=None):
    """Strict schema gate. Names/type-family/nullability/generated-FLAG/PK are always
    checked. With a SOURCE CATALOG it adds QUANTITATIVE contracts: numeric
    precision+scale, char/varchar declared length, UNIQUE COLUMN-SET identity, and
    ORDERED primary-key column identity (order matters for the backing index / FKs).
    With a REVIEWED ADAPTATION manifest it adds the FULL-SCOPE required checks against
    the LIVE target: CHECK predicates (incl. byte-length octet_length guards), DEFAULT
    expressions, GENERATED expressions (not just the flag), and timestamp semantics --
    compared to explicit reviewed EXPECTED TARGET expressions/hashes (no generic
    cross-dialect string identity). Empty acceptance is NOT granted until BOTH inputs
    resolve every required check: catalog absent -> reason 'catalog_required';
    adaptation absent -> reason 'adaptation_required' (both surface as
    empty_schema_unverified / reviewed_pass=false, never a pass on family/count/flags
    alone)."""
    tbl = entry['target_table']
    tcols = {c['name']: c for c in _target_columns(conn, schema, tbl)}
    checks = {}
    checks['present'] = bool(tcols)
    if not tcols:
        return {'ok': False, 'reason': 'missing', 'checks': checks}
    expected = entry['columns']
    checks['columns_match'] = sorted(tcols) == sorted(c['target'] for c in expected)
    # Reviewed per-column REPRESENTATION contract (only from the adaptation manifest). Lets the
    # reviewed CHAR(n BYTE)->canonical TEXT + octet_length CHECK and DATE->timestamp(p)+trigger
    # representations pass without the generic family/declared-length/precision rules forcing a
    # known-wrong char(n)/timestamp(0). NOT a blanket TEXT allowance: char_as_text additionally
    # REQUIRES the octet_length guard on the live target (verified in the adaptation block).
    exp = adaptation.get(fold(name), {}) if adaptation is not None else {}
    reps = exp.get('representation', {}) or {}
    type_bad, null_bad, gen_bad, quant_bad = [], [], [], []
    for c in expected:
        t = tcols.get(c['target'])
        if t is None:
            continue
        rep = reps.get(c['target']) or {}
        kind = rep.get('kind')
        if kind in ('char_as_text', 'varchar_as_text'):
            # CHAR(n BYTE)->TEXT (fixed, octet=N) or VARCHAR2(n BYTE)->TEXT (variable, octet<=N).
            # Both are raw TEXT; the declared-length check is skipped, byte guard + (varchar)
            # normalizer are enforced as representation evidence in the adaptation block.
            if t['data_type'] != 'text':
                type_bad.append('%s: %s expects text, got %s' % (c['target'], kind, t['data_type']))
        elif kind == 'date_as_timestamp':
            if t['data_type'] != 'timestamp without time zone':
                type_bad.append('%s: date_as_timestamp expects timestamp without time zone, got %s'
                                % (c['target'], t['data_type']))
            ep = rep.get('datetime_precision')
            if ep is not None and t['datetime_precision'] != ep:
                quant_bad.append('%s datetime_precision %s!=%s' % (c['target'], t['datetime_precision'], ep))
        else:
            fam = TYPE_FAMILY.get(c['rule'], set())
            if fam and t['data_type'] not in fam:
                type_bad.append('%s: %s not in %s' % (c['target'], t['data_type'], sorted(fam)))
            if c['rule'] in ('char', 'varchar') and catalog is not None:
                el = catalog['length'].get((name, c['name']))
                if el is not None and t['char_max_length'] != el:
                    quant_bad.append('%s length %s!=%s' % (c['target'], t['char_max_length'], el))
        if c.get('nullable') == 'N' and t['nullable']:
            null_bad.append(c['target'])
        if c['generated'] and not t['generated']:
            gen_bad.append(c['target'])
        # QUANTITATIVE numeric precision/scale (from manifest) always applies.
        if c['rule'] == 'numeric':
            enp, es = _catalog_int(c.get('precision')), _catalog_int(c.get('scale'))
            if enp is not None and t['numeric_precision'] != enp:
                quant_bad.append('%s numeric_precision %s!=%s' % (c['target'], t['numeric_precision'], enp))
            if es is not None and t['numeric_scale'] != es:
                quant_bad.append('%s numeric_scale %s!=%s' % (c['target'], t['numeric_scale'], es))
    checks['type_family_ok'] = not type_bad
    checks['type_family_issues'] = type_bad
    checks['not_null_ok'] = not null_bad
    checks['not_null_issues'] = null_bad
    checks['generated_ok'] = not gen_bad
    checks['generated_issues'] = gen_bad
    checks['quantitative_ok'] = not quant_bad
    checks['quantitative_issues'] = quant_bad
    con = _target_constraints(conn, schema, tbl)
    # PRIMARY KEY / comparison-key identity: when usable_key IS the source PK the target PK must
    # match it exactly and in order; when usable_key is a fallback UNIQUE the comparison key must
    # exist on the target as a PK-or-UNIQUE column set (the target PK itself may legitimately differ).
    exp_pk = [fold(c) for c in entry['usable_key']['columns']] if entry['usable_key'] else []
    pk_ok, uk_is_source_pk = _primary_key_ok(con['pk_columns'], con['unique'],
                                             entry['usable_key'], entry.get('primary_key'))
    checks['primary_key_ok'] = pk_ok
    checks['primary_key'] = {'target': con['pk_columns'], 'expected': exp_pk,
                             'usable_key_is_source_pk': uk_is_source_pk}
    tgt_uq = {frozenset(u) for u in con['unique']}
    # UNIQUE: set membership is the uniqueness semantics; ordered metadata preserved for FK/index review.
    checks['unique_ordered_target'] = [list(u) for u in con['unique']]
    if catalog is not None:
        exp_uq = catalog['unique_sets'].get(name, set())
        checks['unique_identity_ok'] = exp_uq <= tgt_uq           # each source user-unique present by COLUMN SET
        checks['unique_sets'] = {'target': [sorted(u) for u in tgt_uq], 'expected': [sorted(u) for u in exp_uq]}
    else:
        checks['unique_identity_ok'] = None
        checks['unique_count_only'] = len(con['unique']) >= len(entry.get('unique_constraints', []))
    # FULL-SCOPE required checks: CHECK predicates (+byte-length guards), DEFAULT +
    # GENERATED expressions, timestamp semantics -- only against the reviewed adaptation.
    full_scope = ['check_predicates', 'defaults', 'generated_expressions', 'timestamp_semantics']
    if adaptation is not None:
        entry_present = fold(name) in adaptation
        tgt_defs, tgt_shas = _target_check_defs(conn, schema, tbl)
        # REPRESENTATION evidence (no blanket TEXT allowance):
        #  - char_as_text: an octet_length guard on the live target.
        #  - varchar_as_text: the EXACT byte guard octet_length(col) <= N with N == source
        #    DATA_LENGTH, PLUS a HARD live-gated empty->NULL normalizer trigger (BEFORE
        #    INSERT/UPDATE, enabled, function body/identity matching the reviewed spec).
        rep_bad = []
        tgt2src = {c['target']: c['name'] for c in expected}
        has_varchar_text = False
        for col, rep in reps.items():
            kind = (rep or {}).get('kind')
            if kind == 'char_as_text':
                # CHAR(n BYTE)->TEXT is blank-padded to EXACTLY n bytes: require octet_length(col)=n
                # (fixed), bound to this exact column, and (when the source length is known) equal to
                # it. A '<=' guard is too weak for the fixed pad and is rejected.
                el = catalog['length'].get((name, tgt2src.get(col))) if catalog else None
                g = _octet_guard_for(tgt_defs, col)
                if g is None or g[0] != '=' or (el is not None and g[1] != el):
                    rep_bad.append('char_as_text %s requires octet_length(%s) = %s guard on target (got %r)'
                                   % (col, col, el, g))
            elif kind == 'varchar_as_text':
                has_varchar_text = True
                N = rep.get('octet_max')
                el = catalog['length'].get((name, tgt2src.get(col))) if catalog else None
                if N is None or el is None or N != el:
                    rep_bad.append('varchar_as_text %s octet_max %r != source DATA_LENGTH %r' % (col, N, el))
                else:
                    g = _octet_guard_for(tgt_defs, col)   # EXACT column binding + '<=' N (variable length)
                    if g is None or g[0] != '<=' or g[1] != N:
                        rep_bad.append('varchar_as_text %s requires exact byte guard octet_length(%s) <= %d '
                                       'on target (got %r)' % (col, fold(col), N, g))
        if has_varchar_text:
            norm = exp.get('normalizer') or {}
            trig = _target_triggers(conn, schema, tbl)
            # NAME alone is NOT an immutable pin (CREATE OR REPLACE no-op keeps the name); the
            # manifest MUST pin the BODY (definition/definition_sha256). Function identity is optional.
            body_pinned = bool(norm.get('definition_sha256') or norm.get('definition'))
            want_when = norm.get('when')                    # None => must be UNCONDITIONAL (no WHEN)
            want_upof = norm.get('update_of')               # None => must fire for ALL columns
            want_nargs = norm.get('nargs', 0)               # default: no args
            # arg VALUE identity (not just count): with nargs>0 the manifest MUST pin exact
            # tgargs values; same body with different TG_ARGV must fail closed.
            want_args = None
            if want_nargs:
                wa = norm.get('tgargs')
                want_args = _norm_sql(wa if isinstance(wa, str)
                                      else ', '.join("'%s'" % a for a in wa)) if wa is not None else None
            match = None
            for tg in trig:
                # must be BEFORE, ROW-level (not STATEMENT), INSERT+UPDATE, and fire for ORIGIN
                # sessions ('O'/'A'; 'R' is replica-only and won't run app writes, 'D' disabled).
                if not (tg['before'] and tg['row'] and tg['insert'] and tg['update'] and tg['fires_origin']):
                    continue
                if want_when is None:
                    if tg['when'] is not None:
                        continue
                elif _norm_sql(tg['when']) != _norm_sql(want_when):
                    continue
                if want_upof is None:
                    if tg['update_of']:                      # any UPDATE OF restriction is disqualifying
                        continue
                elif sorted(fold(c) for c in tg['update_of']) != sorted(fold(c) for c in want_upof):
                    continue
                if tg['nargs'] != want_nargs:
                    continue
                if want_nargs and (want_args is None or tg['args'] != want_args):
                    continue                                 # nargs>0 unpinned or value-mismatch -> fail closed
                if norm.get('function') and tg['function'].lower() != norm['function'].lower():
                    continue
                if norm.get('definition_sha256') and tg['def_sha256'] != norm['definition_sha256']:
                    continue
                if norm.get('definition') and norm['definition'] != tg['def_exact']:
                    continue                                 # EXACT-byte body match (no whitespace/comment collapse)
                match = tg
                break
            if not body_pinned:
                rep_bad.append('varchar_as_text normalizer must PIN the function BODY '
                               '(definition/definition_sha256); name alone is not immutable')
            elif match is None:
                biu = [t for t in trig if t['before'] and t['insert'] and t['update']]
                rowbiu = [t for t in biu if t['row']]
                origin = [t for t in rowbiu if t['fires_origin']]
                if not biu:
                    rep_bad.append('normalizer trigger MISSING (no BEFORE INSERT/UPDATE trigger)')
                elif not rowbiu:
                    rep_bad.append('normalizer trigger is STATEMENT-level, not ROW-level')
                elif not origin:
                    rep_bad.append('normalizer trigger does not fire for origin sessions '
                                   '(tgenabled not O/A: replica-only or disabled)')
                elif want_when is None and any(t['when'] is not None for t in origin):
                    rep_bad.append('normalizer trigger has a WHEN condition (expected unconditional)')
                elif want_upof is None and any(t['update_of'] for t in origin):
                    rep_bad.append('normalizer trigger restricted with UPDATE OF (expected all columns)')
                elif any(t['nargs'] != want_nargs for t in origin):
                    rep_bad.append('normalizer trigger arg count != expected')
                elif want_nargs and want_args is None:
                    rep_bad.append('normalizer has args (nargs>0) but manifest did not pin exact tgargs values')
                elif want_nargs and all(t['args'] != want_args for t in origin):
                    rep_bad.append('normalizer trigger TG_ARGV values != pinned tgargs')
                else:
                    rep_bad.append('normalizer trigger body/identity MISMATCH vs reviewed spec')
            checks['normalizer'] = {
                'matched': bool(match), 'body_pinned': body_pinned,
                'target_triggers': [{k: t[k] for k in ('name', 'tgenabled', 'fires_origin', 'before',
                                                       'row', 'insert', 'update', 'when', 'update_of',
                                                       'nargs', 'args', 'function', 'def_sha256')} for t in trig]}
        checks['representation_evidence_ok'] = not rep_bad
        checks['representation_issues'] = rep_bad
        chk_bad = []
        for want in exp.get('checks', []):
            if want.startswith('sha256:'):
                ok = want.split(':', 1)[1] in tgt_shas
            else:
                ok = _norm_sql(want) in tgt_defs
            if not ok:
                chk_bad.append(want)
        # source_checks: map EACH source business CHECK id -> expected PG predicate(s) OR a
        # reviewed semantic replacement {"replacement":..., "reason":...}. A mapped literal
        # predicate must be present on the target; a replacement is accounted (reviewed) but
        # not matched to a target predicate. mapped ids drive completeness below.
        mapped_check_ids, replacements = set(), {}
        for cid, want in (exp.get('source_checks') or {}).items():
            mapped_check_ids.add(cid)
            if isinstance(want, dict):
                replacements[cid] = want.get('reason') or 'reviewed semantic replacement'
                continue
            for p in (want if isinstance(want, list) else [want]):
                if p.startswith('sha256:'):
                    ok = p.split(':', 1)[1] in tgt_shas
                else:
                    ok = _norm_sql(p) in tgt_defs
                if not ok:
                    chk_bad.append('source_check %s expected %r not on target' % (cid, p))
        def_bad, genx_bad, dt_bad = [], [], []
        for col, want in exp.get('defaults', {}).items():
            t = tcols.get(col)
            got = t['default'] if t else None
            if _norm_sql(want) != got:
                def_bad.append('%s default %r!=%r' % (col, got, want))
        for col, want in exp.get('generated', {}).items():
            t = tcols.get(col)
            got = t['generation_expr'] if t else None
            if _norm_sql(want) != got:
                genx_bad.append('%s generation %r!=%r' % (col, got, want))
        for col, want in exp.get('datetime', {}).items():
            t = tcols.get(col)
            got = {'data_type': t['data_type'], 'precision': t['datetime_precision']} if t else None
            if got is None or got['data_type'] != want.get('data_type') or \
                    (want.get('precision') is not None and got['precision'] != want.get('precision')):
                dt_bad.append('%s datetime %r!=%r' % (col, got, want))
        checks['check_predicates_ok'] = not chk_bad
        checks['check_predicates_issues'] = chk_bad
        checks['check_target_defs'] = sorted(tgt_defs)
        checks['defaults_ok'] = not def_bad
        checks['defaults_issues'] = def_bad
        checks['generated_expressions_ok'] = not genx_bad
        checks['generated_expressions_issues'] = genx_bad
        checks['timestamp_semantics_ok'] = not dt_bad
        checks['timestamp_semantics_issues'] = dt_bad
        # COMPLETENESS: an empty/omitted expected list is NOT a waiver when the SOURCE
        # carries that requirement (checks/defaults/generated/byte/datetime). Cross-
        # referenced against the source catalog so the manifest must ACCOUNT for all.
        cover_bad = []
        if not entry_present:
            cover_bad.append('no manifest entry for this table (all tables must be accounted)')
        srcreq = (catalog or {}).get('requirements', {}).get(fold(name)) if catalog else None
        if srcreq is not None:
            # EVERY source business CHECK id must be mapped (to an expected PG predicate or a
            # reviewed semantic replacement) -- not merely "some non-empty check per table".
            for cid in sorted(srcreq.get('check_ids', set()) - mapped_check_ids):
                cover_bad.append('source CHECK not mapped: ' + cid)
            have_def = {fold(k) for k in exp.get('defaults', {})}
            for c in sorted(srcreq['defaults'] - have_def):
                cover_bad.append('default not accounted: ' + c)
            have_gen = {fold(k) for k in exp.get('generated', {})}
            for c in sorted(srcreq['generated'] - have_gen):
                cover_bad.append('generated not accounted: ' + c)
            have_dt = {fold(k) for k in exp.get('datetime', {})}
            for c in sorted(srcreq['datetime'] - have_dt):
                cover_bad.append('datetime not accounted: ' + c)
            # BYTE coverage: each source byte(octet) column must be ACCOUNTED for -- either by a
            # representation adapter for that column (whose exact target guard is verified above) or
            # by an octet_length guard BOUND to that exact column among the adaptation's declared
            # checks. Bind the specific column (never a substring): a guard on parent_account_code
            # must NOT credit account_code.
            src2tgt = {fold(col['name']): col['target'] for col in expected}
            adapt_checks = [_norm_sql(w) or '' for w in exp.get('checks', [])]
            for c in sorted(srcreq['byte']):
                tcol = src2tgt.get(c, c)
                rep_kind = (reps.get(tcol) or {}).get('kind')
                accounted = (rep_kind in ('char_as_text', 'varchar_as_text')
                             or _octet_guard_for(adapt_checks, tcol) is not None)
                if not accounted:
                    cover_bad.append('byte-length guard missing for: ' + c)
            checks['source_check_ids_required'] = sorted(srcreq.get('check_ids', set()))
            checks['source_check_ids_mapped'] = sorted(mapped_check_ids)
            checks['source_check_replacements'] = replacements
        checks['coverage_ok'] = not cover_bad
        checks['coverage_missing'] = cover_bad
    else:
        checks['full_scope_pending'] = full_scope
    quant_gate = ['quantitative_ok', 'unique_identity_ok'] if catalog is not None else []
    scope_gate = (['check_predicates_ok', 'defaults_ok', 'generated_expressions_ok',
                   'timestamp_semantics_ok', 'representation_evidence_ok'] if adaptation is not None else [])
    hard = ['columns_match', 'type_family_ok', 'not_null_ok', 'generated_ok',
            'primary_key_ok'] + quant_gate + scope_gate
    real_fail = not all(checks[k] for k in hard)
    if real_fail:
        return {'ok': False, 'reason': None, 'checks': checks}       # genuine mismatch -> schema_mismatch
    if catalog is None:
        return {'ok': False, 'reason': 'catalog_required', 'checks': checks}
    if adaptation is None:
        return {'ok': False, 'reason': 'adaptation_required', 'checks': checks}
    if not checks.get('coverage_ok', True):
        # manifest is present + matches what it lists, but omits source-required items
        return {'ok': False, 'reason': 'adaptation_incomplete', 'checks': checks}
    return {'ok': True, 'reason': None, 'checks': checks}


def _validate_target(conn, schema, name, entry, proj, out_dir, src_csv, python, res,
                     registered=frozenset(), catalog=None, adaptation=None):
    from psycopg import sql
    entry['target_table'] = fold(name)
    tbl = entry['target_table']
    res['target_table'] = '%s.%s' % (schema, tbl)
    schema_res = _check_target_schema(conn, schema, name, entry, catalog, adaptation)
    res['target_present'] = schema_res['checks'].get('present', False)
    res['schema_ok'] = schema_res['ok']
    res['schema_reason'] = schema_res.get('reason')
    res['schema_checks'] = schema_res['checks']
    if not res['target_present']:
        res['result'] = 'target_table_missing'
        if entry['rows'] == 0:
            res['empty_verified'] = False
        return
    with conn.cursor() as cur:
        cur.execute(sql.SQL("SELECT count(*) FROM {}").format(sql.Identifier(schema, tbl)))
        res['target_rows'] = cur.fetchone()[0]
    if not schema_res['ok'] and schema_res.get('reason') in ('catalog_required', 'adaptation_required',
                                                              'adaptation_incomplete'):
        # A required schema input is missing/incomplete, so the FULL-SCOPE contract is unresolved.
        reason = schema_res['reason']
        detail = {'catalog_required': 'empty-table quantitative schema gate requires --source-catalog',
                  'adaptation_required': 'empty-table full-scope gate (CHECK/default/generated-expr/byte/'
                                         'timestamp) requires --adaptation reviewed expected-target manifest',
                  'adaptation_incomplete': 'adaptation manifest omits source-required items: '
                                           + '; '.join(schema_res['checks'].get('coverage_missing', []))}[reason]
        if entry['rows'] == 0:
            res['result'] = 'empty_schema_unverified'   # NOT a pass on family/count/flags alone
            res['empty_verified'] = False
            res['detail'] = detail
            return
        # non-empty: value parity still runs below; record the schema gate as pending.
        res['schema_quantitative'] = {'catalog_required': 'pending_no_catalog',
                                      'adaptation_required': 'pending_no_adaptation',
                                      'adaptation_incomplete': 'pending_incomplete_adaptation'}[reason]
    elif not schema_res['ok']:
        # real mismatch: wrong precision/scale/length/type/nullability/keys/checks/defaults/
        # generated-expr/timestamp => never a pass
        res['result'] = 'schema_mismatch'
        if entry['rows'] == 0:
            res['empty_verified'] = False
        return
    if entry['rows'] == 0:
        # empty tables are NOT run through compare-data (it refuses empty/empty);
        # they pass only on real zero rows AND the full-scope schema gate resolving.
        res['empty_verified'] = res['target_rows'] == 0
        res['result'] = 'empty_verified' if res['empty_verified'] else 'empty_mismatch'
        return
    tgt_csv = out_dir / 'target-csv' / (_artifact_stem(name) + '.csv')
    try:
        res['rows_target_exported'] = export_target(conn, schema, entry, proj, tgt_csv, registered)
    except NotImplementedError as exc:
        res['result'] = 'blocked_complex_target_render'
        res['detail'] = str(exc)
        return
    keys = [fold(c) for c in entry['usable_key']['columns']] if entry['usable_key'] else []
    if not keys:
        # A non-empty table with no usable primary/unique key cannot be row-keyed for the public
        # compare-data CLI (which requires --key). Emit a DISTINCT structured blocked disposition
        # instead of invoking compare-data with an empty key list (which exits 2 and masquerades as
        # a data parity_fail carrying an argparse-usage stderr). Fail-closed: never a reviewed_pass.
        res['result'] = 'blocked_no_comparable_key'
        res['detail'] = ('non-empty table has no usable primary/unique key; row-keyed parity '
                         'comparison is not possible')
        return
    cmp = compare_data(python, src_csv, tgt_csv, keys, out_dir / 'compare' / (_artifact_stem(name) + '.json'))
    res['parity'] = {k: cmp.get(k) for k in ('status', 'source_rows', 'target_rows',
                                             'missing_keys', 'extra_keys', 'changed_rows', '_exit')}
    res['result'] = ('parity_pass' if (cmp.get('_exit') == 0 and cmp.get('status') == 'passed'
                     and cmp.get('missing_keys') == 0 and cmp.get('extra_keys') == 0
                     and cmp.get('changed_rows') == 0 and cmp.get('target_rows') == entry['rows'])
                     else 'parity_fail')


# --------------------------------------------------------------------------- #
# Gate receipts.                                                              #
# --------------------------------------------------------------------------- #
def build_receipts(gates_doc, table_results, source_only, selected_count, total_tables):
    """Receipts derived from ACTUAL per-table evidence (never capability booleans)."""
    results = list(table_results.values())
    target_ran = not source_only
    reviewed = lambda r: r.get('result') in ('parity_pass', 'empty_verified')  # noqa: E731
    definitive = [r for r in results if r.get('result')]
    n = len(results)
    all_definitive = target_ran and n > 0 and len(definitive) == n
    all_pass = target_ran and n > 0 and all(reviewed(r) for r in results)
    failed = [name for name, r in table_results.items() if r.get('result') and not reviewed(r)]

    value_gates = {'DATA-COUNTS', 'DATA-KEYS', 'DATA-COLUMNS', 'DATA-TIME', 'DATA-STRING',
                   'DATA-LONG-LOB', 'DATA-CONTENT'}
    receipts = {'gates': {}, 'data_gates': {}, 'done_criteria': {}, 'hard_cases': {}}
    for g in gates_doc.get('data_consistency_gates', []):
        gid = g['id']
        if gid in value_gates:
            executed = all_definitive          # executed only when every selected table has real evidence
            result = ('passed' if (executed and all_pass)
                      else 'failed' if (target_ran and definitive) else 'not_executed')
        else:
            executed, result = False, 'not_executed_needs_target_ops_or_other_lane'
        receipts['data_gates'][gid] = {'executed': bool(executed), 'result': result}
    for g in gates_doc.get('gates', []):
        receipts['gates'][g['gate_id']] = {'executed': False,
                                           'note': 'contributes evidence; closed by orchestrator across lanes'}
    for d in gates_doc.get('done_criteria', []):
        receipts['done_criteria'][d['criterion_id']] = {'required_gates': d.get('required_gates'),
                                                         'executed': False}
    for h in gates_doc.get('hard_case_observations', []):
        receipts['hard_cases'][h['case_id']] = {'status': h.get('status', 'not_tested'),
                                                 'owned_by': 'hard-case lane'}
    if source_only:
        dv = 'prepared'
    elif n == 0:
        dv = 'no_tables'
    elif all_definitive and all_pass:
        dv = 'passed'
    else:
        dv = 'failed'
    receipts['data_validation'] = {
        'status': dv, 'selected_tables': selected_count, 'total_tables': total_tables,
        'coverage': 'all' if selected_count == total_tables else 'subset',
        'tables_reviewed_pass': sum(1 for r in results if reviewed(r)),
        'tables_failed_or_blocked': failed}
    receipts['overall'] = {'passed': 'PASS', 'failed': 'FAIL',
                           'prepared': 'INCOMPLETE', 'no_tables': 'INCOMPLETE'}[dv]
    return receipts


# --------------------------------------------------------------------------- #
# CLI.                                                                         #
# --------------------------------------------------------------------------- #
def run(manifest, ddl, gates, out_dir, schema, database, tables, source_only,
        source_catalog=None, adaptation_manifest=None):
    out_dir = Path(out_dir)
    (out_dir / 'source-csv').mkdir(parents=True, exist_ok=True)
    m, inv = build_inventory(Path(manifest), Path(ddl))
    proj = Projector(inv['type_registry'])
    gates_doc = json.loads(Path(gates).read_text()) if gates else {}
    python = sys.executable

    selected = tables or list(inv['per_table'])
    conn = None
    if not source_only:
        # Target-run identity is FAIL-CLOSED: --database is REQUIRED and asserted to equal the
        # connected database, matching data_loader.py's invariant. Without it, credentials naming
        # multiple databases (application/compiler) could silently validate the WRONG database and
        # emit a false PASS/FAIL. Checked BEFORE importing/connecting the driver. (Source-only
        # projection never connects, so it is unaffected.)
        if not database:
            raise ValueError('--database is required for a target run; the connected database is '
                             'asserted to equal it (identity fail-closed)')
        import psycopg
        conn = psycopg.connect(autocommit=True)
        with conn.cursor() as cur:
            cur.execute("SELECT current_database()")
            actual = cur.fetchone()[0]
        if actual != database:
            conn.close()
            raise ValueError('connected to %r but --database is %r' % (actual, database))
        (out_dir / 'target-csv').mkdir(exist_ok=True)
        (out_dir / 'compare').mkdir(exist_ok=True)
        registered = register_target_composites(conn, inv['type_registry'], schema)
    else:
        registered = frozenset()
    catalog = load_source_catalog(source_catalog) if source_catalog else None
    adaptation = load_adaptation(adaptation_manifest) if adaptation_manifest else None
    # Provenance of the reviewed expected-target manifest for the INDEPENDENT match
    # (the expected expressions must be canonicalized from the independently-compiled
    # REVIEWED candidate bundle, NOT from the app-under-test acting as its own oracle).
    adaptation_meta = None
    if adaptation_manifest:
        raw = json.loads(Path(adaptation_manifest).read_text())
        adaptation_meta = {'manifest_sha256': sha256_file(adaptation_manifest),
                           'provenance': raw.get('provenance'),
                           'tables_in_manifest': sorted(adaptation.keys()),
                           'source_catalog_sha256_seen': sha256_file(
                               str(Path(source_catalog) / 'constraints-full.json')) if source_catalog else None,
                           # This validator attests only that the LIVE TARGET matches the SUPPLIED
                           # expected manifest. It does NOT and CANNOT certify that the manifest is a
                           # genuinely HUMAN-APPROVED reviewed artifact -- a "reviewed" label is not
                           # proof of approval. Audit the manifest's review_receipts/approval provenance
                           # out-of-band BEFORE granting any full-run acceptance credit.
                           'review_approval': 'NOT_VERIFIED_BY_VALIDATOR: audit review_receipts out-of-band'}
    try:
        table_results = {}
        for name in selected:
            entry = inv['per_table'][name]
            entry['_name_lower'] = fold(name)
            res = {'rows_source_expected': entry['rows'], 'key': entry['usable_key'],
                   'complex_columns': entry['complex_columns']}
            src_csv = out_dir / 'source-csv' / (_artifact_stem(name) + '.csv')
            if entry['rows'] > 0:
                res['rows_source_projected'] = project_source(Path(manifest).parent, entry, proj, src_csv)
                res['source_csv_sha256'] = sha256_file(src_csv)
                res['source_rows_match'] = res['rows_source_projected'] == entry['rows']
            else:
                res['empty'] = True
            if conn is not None:
                _validate_target(conn, schema, name, entry, proj, out_dir, src_csv, python, res,
                                 registered, catalog, adaptation)
            table_results[name] = res
    finally:
        if conn is not None:
            conn.close()

    receipts = build_receipts(gates_doc, table_results, source_only, len(selected), len(inv['per_table']))
    # Flat, stable per-table contract for downstream ingesters (keyed by exact
    # source table name). status is an explicit enum; reviewed_pass is only ever
    # True on an executed passing signal -- blocked/missing/unknown never pass.
    table_status = {}
    for name, r in table_results.items():
        st = r.get('result') or ('source_projected' if source_only else 'unknown')
        table_status[name] = {
            'status': st,                                   # parity_pass|parity_fail|empty_verified|
                                                            # empty_mismatch|blocked_complex_target_render|
                                                            # blocked_no_comparable_key|
                                                            # target_table_missing|source_projected|unknown
            'reviewed_pass': st in ('parity_pass', 'empty_verified'),
            'empty': bool(r.get('empty')),
            'rows_source': r.get('rows_source_expected'),
            'rows_target': r.get('target_rows'),
            'parity': r.get('parity'),                      # compare-data summary (non-empty) or null
            'compare_json': ('compare/%s.json' % _artifact_stem(name)) if r.get('parity') is not None else None,
            'blocked_reason': r.get('detail') if st in ('blocked_complex_target_render',
                                                        'blocked_no_comparable_key') else None,
        }
    report = {
        'run': {'schema': schema, 'database': database, 'source_only': source_only,
                'manifest': str(manifest), 'manifest_sha256': sha256_file(manifest),
                'observed_scn': inv['observed_scn'],
                'ddl_root': str(ddl), 'gates_sha256': sha256_file(gates) if gates else None},
        'inventory_summary': {
            'tables': len(inv['per_table']),
            'selected_tables': len(selected),
            'coverage': 'all' if len(selected) == len(inv['per_table']) else 'subset',
            'total_rows': sum(v['rows'] for v in inv['per_table'].values()),
            'empty_tables': sorted(n for n, v in inv['per_table'].items() if v['rows'] == 0),
            'foreign_keys': len(inv['foreign_keys']),
            'trigger_tables': len(inv['triggers']),
            'tables_with_complex_columns': sorted(n for n, v in inv['per_table'].items()
                                                  if v['complex_columns']),
            'usable_key_tables': sum(1 for v in inv['per_table'].values() if v['usable_key']),
        },
        'table_status': table_status,
        'table_results': table_results,
        'adaptation_provenance': adaptation_meta,
        'receipts': receipts,
        'scope_caveat': 'DATA-validation scope: source projection + target export/parity (public compare-data) '
                        '+ strict empty-table schema checks. overall/exit reflect this module''s data gates '
                        'only; the full 17-gate/DONE/43-case acceptance is closed by the orchestrator across '
                        'lanes. Coverage=subset means only --tables were checked, not all inventory tables.',
    }
    (out_dir / 'full-validation-report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps({'overall': receipts['overall'],
                      'data_validation': receipts['data_validation'],
                      'inventory_tables': report['inventory_summary']['tables'],
                      'selected_tables': len(selected),
                      'coverage': report['inventory_summary']['coverage'],
                      'source_projections_ok': all(r.get('source_rows_match', True)
                                                   for r in table_results.values())}, indent=2))
    return report


def load_target_credentials(path):
    """Read a private target-credentials JSON and set libpq PG* env in-process.

    The password is NEVER returned, printed, or placed on a command line -- it is
    only written into this process's environment for psycopg to consume."""
    data = json.loads(Path(path).read_text())
    mapping = {'host': 'PGHOST', 'port': 'PGPORT', 'user': 'PGUSER',
               'password': 'PGPASSWORD', 'sslmode': 'PGSSLMODE'}
    for src, env in mapping.items():
        if data.get(src) is not None:
            os.environ[env] = str(data[src])
    # Routing hygiene: PGHOSTADDR (a numeric address that OVERRIDES PGHOST) and PGSERVICE (a service
    # file that can set host/port/db) left in the ambient environment would silently redirect the
    # connection to the WRONG cluster that happens to share the target database name. Clear them so
    # the connection routes to THIS credential file's host -- preserving ONLY an explicit hostaddr
    # from the file (an intentional bastion/tunnel address).
    if data.get('hostaddr') is not None:
        os.environ['PGHOSTADDR'] = str(data['hostaddr'])
    else:
        os.environ.pop('PGHOSTADDR', None)
    os.environ.pop('PGSERVICE', None)
    return {'host': data.get('host'), 'port': data.get('port'), 'user': data.get('user'),
            'sslmode': data.get('sslmode'), 'schema': data.get('schema'),
            'hostaddr_present': data.get('hostaddr') is not None,
            'application_database': data.get('application_database'),
            'compiler_database': data.get('compiler_database'),
            'password_present': data.get('password') is not None}  # never the value


def verify_identity(schema):
    """Read-only target identity/catalog check (no writes, no secrets in output)."""
    import psycopg
    conn = psycopg.connect(autocommit=True)
    try:
        with conn.cursor() as cur:
            cur.execute("SET default_transaction_read_only = on")
            cur.execute("SELECT current_database(), current_user, current_setting('search_path'), version()")
            db, user, sp, ver = cur.fetchone()
            cur.execute("SELECT extname, extversion FROM pg_extension ORDER BY extname")
            exts = [{'name': n, 'version': v} for n, v in cur.fetchall()]
            cur.execute("SELECT count(*) FROM information_schema.schemata WHERE schema_name=%s", (schema,))
            schema_present = cur.fetchone()[0] > 0
            cur.execute("SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
                        "WHERE n.nspname=%s AND c.relkind='r'", (schema,))
            rels = cur.fetchone()[0]
    finally:
        conn.close()
    return {'database': db, 'user': user, 'search_path': sp, 'server_version': ver.split(' on ')[0],
            'extensions': exts, 'schema': schema, 'schema_present': schema_present,
            'relations_in_schema': rels, 'read_only_check': True}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    p.add_argument('--manifest', help='snapshot manifest.json (required unless --verify-identity)')
    p.add_argument('--ddl', help='Oracle DDL root …/extract/ddl/CONTOSO (required unless --verify-identity)')
    p.add_argument('--gates', help='acceptance-gates.json (for receipts)')
    p.add_argument('--out', required=True)
    p.add_argument('--target-schema', default='contoso')
    p.add_argument('--database', default=None)
    p.add_argument('--tables', nargs='*')
    p.add_argument('--source-only', action='store_true',
                   help='project source + inventory without a live target')
    p.add_argument('--source-catalog',
                   help='dir with columns.json + constraints-full.json for the quantitative '
                        'empty-table schema gate (length + UNIQUE column-set identity)')
    p.add_argument('--adaptation',
                   help='reviewed adaptation manifest of EXPECTED TARGET expressions/hashes '
                        '(CHECK predicates incl. byte-length guards, DEFAULT + GENERATED '
                        'expressions, timestamp semantics) for full-scope empty acceptance')
    p.add_argument('--target-credentials',
                   help='JSON file with host/port/user/password/sslmode; loaded programmatically, '
                        'never logged. PGPASSWORD etc. are set in-process.')
    p.add_argument('--verify-identity', action='store_true',
                   help='read-only: report target database/schema/extensions/relation count and exit')
    a = p.parse_args(argv)
    if a.target_credentials:
        meta = load_target_credentials(a.target_credentials)
        print(json.dumps({'target_credentials_loaded': meta}, indent=2))  # NO password in meta
    if a.database:
        os.environ['PGDATABASE'] = a.database   # which of the credential's DBs to use
    if a.verify_identity:
        ident = verify_identity(a.target_schema)
        Path(a.out).mkdir(parents=True, exist_ok=True)
        (Path(a.out) / 'target-identity.json').write_text(json.dumps(ident, indent=2))
        print(json.dumps(ident, indent=2))
        return 0
    if not a.manifest or not a.ddl:
        p.error('--manifest and --ddl are required unless --verify-identity')
    report = run(a.manifest, a.ddl, a.gates, a.out, a.target_schema, a.database, a.tables, a.source_only,
                 a.source_catalog, a.adaptation)
    dv = report['receipts']['data_validation']['status']
    # Exit semantics: source-only preparation succeeds with 0; a target run exits
    # nonzero unless every selected table passed its data-validation (missing /
    # failed / blocked / schema-mismatch / no-tables all => nonzero).
    if a.source_only:
        return 0
    return 0 if dv == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
