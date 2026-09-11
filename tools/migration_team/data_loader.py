"""Bounded, metadata-driven loader for a typed Oracle snapshot into PostgreSQL.

This module loads the private, typed JSONL snapshot produced by
``export-oracle-snapshot.py`` into an *already-created* PostgreSQL target
schema.  It is evidence-first and safety-first:

* It never reads source credentials and never mutates the source.
* It validates every manifest file's sha256 and row count and rejects any
  path traversal / symlink / out-of-manifest file *before* touching the target.
* It refuses to load into any destination table that already holds rows and
  never truncates or deletes existing data.
* It plans from the live ``pg_catalog`` (generated columns, identity, real
  types) rather than guessing, and blocks -- loudly -- on anything it cannot
  map losslessly instead of silently coercing Oracle objects to text/JSON.

Default is a dry-run *plan*; ``--apply`` performs the load inside a single
transaction with full rollback on any error.

CLI::

    python -m migration_team.data_loader \
        --manifest FILE --target-schema NAME --database NAME \
        [--mapping FILE] [--apply] --report FILE

The connection is taken entirely from the standard libpq environment
(``PGHOST``/``PGPORT``/``PGUSER``/``PGPASSWORD``/``PGSSLMODE``); the password is
never accepted on the command line and never logged.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import datetime
import hashlib
import json
import math
import os
from dataclasses import dataclass, field
from decimal import Decimal
from pathlib import Path
from typing import Any, Callable, Iterator, Optional

BATCH_ROWS = 500

# Bounded wait for the per-run target-table locks that serialise concurrent
# applies.  A later/competing run waits at most this long for a conflicting run
# to finish; on timeout it refuses cleanly rather than blocking indefinitely.
APPLY_LOCK_TIMEOUT_MS = 30000


# --------------------------------------------------------------------------- #
# Errors                                                                       #
# --------------------------------------------------------------------------- #
class LoaderError(Exception):
    """Fatal, user-facing loader error (aborts before or during work)."""


class MappingBlocker(Exception):
    """A value/type that cannot be mapped losslessly; surfaced as a blocker."""


# --------------------------------------------------------------------------- #
# Decoded intermediate representations of the source typed tags                #
# --------------------------------------------------------------------------- #
@dataclass(frozen=True)
class IntervalYM:
    years: int
    months: int


@dataclass(frozen=True)
class OracleObject:
    type_name: str
    attributes: dict  # name -> decoded value (order preserved)


@dataclass(frozen=True)
class OracleCollection:
    type_name: str
    values: list  # list of decoded values


def decode_tag(v: Any) -> Any:
    """Losslessly decode one encoded source value into a Python intermediate.

    Mirrors ``export-oracle-snapshot.py``'s ``encode``.  Scalars pass through;
    tagged dicts become Decimal/float/bytes/datetime/timedelta/IntervalYM or a
    nested OracleObject/OracleCollection.
    """
    if v is None or isinstance(v, (bool, int, float, str)):
        return v
    if isinstance(v, dict):
        if "$decimal" in v:
            return Decimal(v["$decimal"])
        if "$float" in v:
            return float(v["$float"])
        if "$bytes" in v:
            return base64.b64decode(v["$bytes"])
        if "$datetime" in v:
            return datetime.datetime.fromisoformat(v["$datetime"])
        if "$interval_ds" in v:
            d = v["$interval_ds"]
            return datetime.timedelta(
                days=d["days"], seconds=d["seconds"], microseconds=d["microseconds"]
            )
        if "$interval_ym" in v:
            d = v["$interval_ym"]
            return IntervalYM(int(d["years"]), int(d["months"]))
        if "$oracle_collection" in v:
            return OracleCollection(v["$oracle_collection"], [decode_tag(x) for x in v["values"]])
        if "$oracle_object" in v:
            return OracleObject(
                v["$oracle_object"], {k: decode_tag(x) for k, x in v["attributes"].items()}
            )
        raise LoaderError(f"Unknown source tag: {sorted(v)!r}")
    raise LoaderError(f"Unexpected source value shape: {type(v).__name__}")


# --------------------------------------------------------------------------- #
# Identifier matching                                                          #
# --------------------------------------------------------------------------- #
def fold_identifier(name: str) -> str:
    """Fold an all-uppercase (unquoted-in-Oracle) identifier to lowercase.

    Mixed/lowercase names are quoted-mixed-case and are preserved verbatim, so
    they only ever match a target of the *identical* spelling.
    """
    return name.lower() if name.isupper() else name


def _matches(source_name: str, target_name: str) -> bool:
    # Exact spelling, or the documented all-uppercase fold -- reusing
    # fold_identifier so the rule has a single home and cannot drift.
    return source_name == target_name or fold_identifier(source_name) == target_name


def resolve_name(target_name: str, source_names, explicit: Optional[str] = None) -> str:
    """Return the single source name matching ``target_name``.

    Matching is *exact* or *lowercase-fold of an all-uppercase* source name.
    ``explicit`` (from a mapping file) overrides the search but must exist.
    Raises LoaderError on ambiguity or when no candidate matches.
    """
    if explicit is not None:
        if explicit not in source_names:
            raise LoaderError(f"mapping names source {explicit!r} which is not in the snapshot")
        return explicit
    candidates = [s for s in source_names if _matches(s, target_name)]
    if len(candidates) == 1:
        return candidates[0]
    if not candidates:
        raise LoaderError(f"no source matches target {target_name!r}")
    raise LoaderError(
        f"target {target_name!r} ambiguously matches sources {sorted(candidates)!r}; add an explicit mapping"
    )


# --------------------------------------------------------------------------- #
# Manifest / file validation                                                   #
# --------------------------------------------------------------------------- #
@dataclass
class ManifestCheck:
    manifest: dict
    snapshot_dir: Path
    files: dict  # source table name -> validated absolute Path
    errors: list
    excluded: list  # non-derived excluded objects
    materialized_views: list  # excluded objects needing later REFRESH


def _safe_member_path(snapshot_dir: Path, filename: str) -> Path:
    """Resolve ``filename`` under ``snapshot_dir``, rejecting traversal/symlinks."""
    if filename != os.path.basename(filename) or filename in ("", ".", ".."):
        raise LoaderError(f"unsafe manifest filename {filename!r}")
    if os.sep in filename or (os.altsep and os.altsep in filename) or "\x00" in filename:
        raise LoaderError(f"unsafe manifest filename {filename!r}")
    full = snapshot_dir / filename
    if full.is_symlink():
        raise LoaderError(f"manifest file is a symlink: {filename!r}")
    real = full.resolve(strict=True)
    if real.parent != snapshot_dir.resolve(strict=True):
        raise LoaderError(f"manifest file escapes snapshot dir: {filename!r}")
    if not real.is_file():
        raise LoaderError(f"manifest file is not a regular file: {filename!r}")
    return full


def validate_manifest(manifest_path: Path) -> ManifestCheck:
    """Load the manifest and validate every listed file's hash, count and path.

    Refuses when the export recorded any blocker (the snapshot is incomplete).
    """
    manifest_path = Path(manifest_path)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    snapshot_dir = manifest_path.parent
    errors: list = []
    files: dict = {}

    export_blockers = manifest.get("blockers") or []
    if export_blockers:
        errors.append({"kind": "export_blocker", "detail": export_blockers})

    for entry in manifest.get("tables", []):
        try:
            name = entry["table"]
            full = _safe_member_path(snapshot_dir, entry["file"])
            raw = full.read_bytes()
            digest = hashlib.sha256(raw).hexdigest()
            if digest != entry["sha256"]:
                raise LoaderError(f"sha256 mismatch for {name}: {digest} != {entry['sha256']}")
            line_count = raw.count(b"\n")
            if raw and not raw.endswith(b"\n"):
                line_count += 1  # tolerate a missing final newline
            if line_count != entry["rows"]:
                raise LoaderError(f"row count mismatch for {name}: {line_count} != {entry['rows']}")
            files[name] = full
        except (LoaderError, OSError, KeyError) as exc:
            # A malformed entry (missing 'table'/'file'/'sha256'/'rows') becomes a
            # structured file_validation blocker, never an uncaught KeyError.
            errors.append({"kind": "file_validation",
                           "table": entry.get("table", "<unknown>"), "detail": str(exc)})

    excluded, mviews = [], []
    for ex in manifest.get("excluded", []):
        reasons = " ".join(ex.get("reasons", []))
        (mviews if "materialized view" in reasons else excluded).append(ex)

    return ManifestCheck(manifest, snapshot_dir, files, errors, excluded, mviews)


def iter_rows(path: Path) -> Iterator[list]:
    """Stream a JSONL file, yielding each row as a list of decoded values."""
    with open(path, "r", encoding="utf-8") as stream:
        for line in stream:
            line = line.strip()
            if not line:
                continue
            yield [decode_tag(v) for v in json.loads(line)]


# --------------------------------------------------------------------------- #
# Target type model (built from pg_catalog, or by hand in unit tests)          #
# --------------------------------------------------------------------------- #
@dataclass
class TypeInfo:
    kind: str  # 'scalar' | 'array' | 'composite' | 'domain'
    typname: str = ""
    typcategory: str = ""
    sqltype: str = ""                                # format_type(oid,-1) for casts
    element: Optional["TypeInfo"] = None            # for array
    fields: list = field(default_factory=list)      # for composite: [(name, TypeInfo)]
    base: Optional["TypeInfo"] = None               # for domain


def _bytea_hex(b: bytes) -> str:
    return "\\x" + binascii.hexlify(b).decode("ascii")


# Key under which a json/jsonb column value is transported to the server so a
# JSON ``null`` VALUE survives json_populate_recordset -- which otherwise maps a
# top-level JSON null to SQL NULL, erasing the json-null vs SQL-NULL distinction.
# _insert_table wraps each json value as ``{_JSON_WRAP_KEY: value}`` and the
# INSERT ... SELECT unwraps it with ``-> _JSON_WRAP_KEY``.
_JSON_WRAP_KEY = "__loader_json_wrap__"


class _JsonNull:
    """Sentinel for the JSON ``null`` VALUE, distinct from a SQL NULL.

    encode_field returns this for a json/jsonb target whose source text is the
    JSON literal ``null``; _insert_table then transports it as jsonb ``null``
    (``jsonb_typeof`` = ``'null'``) rather than collapsing it to SQL NULL.
    """

    __slots__ = ()

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return "JSON_NULL"


JSON_NULL = _JsonNull()


def _to_plain_json(value: Any) -> Any:
    """Best-effort conversion of a decoded intermediate into JSON-native data.

    Used only when the *target* column is json/jsonb and the source value is not
    already JSON text (e.g. an Oracle object mapped into a json column).
    """
    if value is None or isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else str(value)
    if isinstance(value, Decimal):
        # Keep the exact Decimal; _dumps_batch renders it as an exact JSON number
        # (never a lossy float, never a quoted string).
        return value
    if isinstance(value, bytes):
        return base64.b64encode(value).decode("ascii")
    if isinstance(value, (datetime.datetime, datetime.date)):
        return value.isoformat()
    if isinstance(value, datetime.timedelta):
        return {"days": value.days, "seconds": value.seconds, "microseconds": value.microseconds}
    if isinstance(value, IntervalYM):
        return {"years": value.years, "months": value.months}
    if isinstance(value, OracleCollection):
        return [_to_plain_json(v) for v in value.values]
    if isinstance(value, OracleObject):
        return {k: _to_plain_json(v) for k, v in value.attributes.items()}
    raise MappingBlocker(f"cannot represent {type(value).__name__} as JSON")


def encode_field(value: Any, tinfo: TypeInfo) -> Any:
    """Shape a decoded source value into JSON suitable for ``json_populate_record``.

    The output is always JSON-native (str/num/bool/None/list/dict); PostgreSQL's
    per-field input functions then cast it to the real column type.  Raises
    MappingBlocker when the source value cannot be mapped to the target type.
    """
    if value is None:
        return None
    if tinfo.kind == "domain":
        return encode_field(value, tinfo.base)
    if tinfo.kind == "array":
        if not isinstance(value, OracleCollection):
            raise MappingBlocker(f"target array needs an Oracle collection, got {type(value).__name__}")
        return [encode_field(v, tinfo.element) for v in value.values]
    if tinfo.kind == "composite":
        if not isinstance(value, OracleObject):
            raise MappingBlocker(f"target composite needs an Oracle object, got {type(value).__name__}")
        out = {}
        attr_names = list(value.attributes)
        for fname, ftype in tinfo.fields:
            try:
                src = resolve_name(fname, attr_names)
            except LoaderError as exc:
                raise MappingBlocker(f"composite field {fname!r}: {exc}") from None
            out[fname] = encode_field(value.attributes[src], ftype)
        return out

    # scalar
    name = tinfo.typname
    if name in ("json", "jsonb"):
        if isinstance(value, str):
            try:
                # parse_float=Decimal keeps wide source numbers exact; a bare JSON
                # `null` is the JSON null VALUE (kept distinct from SQL NULL), not
                # a null column.
                parsed = json.loads(value, parse_float=Decimal)
            except json.JSONDecodeError as exc:
                raise MappingBlocker(f"target {name} but source text is not valid JSON: {exc}") from None
            return JSON_NULL if parsed is None else parsed
        return _to_plain_json(value)
    if isinstance(value, (OracleObject, OracleCollection)):
        raise MappingBlocker(f"target {name or tinfo.kind} cannot hold an Oracle {('object' if isinstance(value, OracleObject) else 'collection')}")
    if name == "bytea":
        if not isinstance(value, (bytes, bytearray)):
            raise MappingBlocker("target bytea needs source bytes")
        return _bytea_hex(bytes(value))
    if name == "bool":
        if isinstance(value, bool):
            return "true" if value else "false"
        if isinstance(value, (int, float, Decimal)):
            # Oracle boolean flags are 0 = false / non-zero = true.  Compare the
            # value itself -- never int(value), which would truncate a fractional
            # NUMBER like 0.5 toward zero and silently store "false".
            return "true" if value != 0 else "false"
        return str(value)
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, float):
        return value if math.isfinite(value) else ("NaN" if math.isnan(value) else ("Infinity" if value > 0 else "-Infinity"))
    if isinstance(value, (datetime.datetime, datetime.date)):
        return value.isoformat()
    if isinstance(value, datetime.timedelta):
        return f"{value.days} days {value.seconds} seconds {value.microseconds} microseconds"
    if isinstance(value, IntervalYM):
        return f"{value.years} years {value.months} months"
    # int / str already JSON-native
    return value


# --------------------------------------------------------------------------- #
# pg_catalog introspection                                                     #
# --------------------------------------------------------------------------- #
@dataclass
class TargetColumn:
    name: str
    typinfo: TypeInfo
    attnum: int
    generated: bool          # attgenerated != ''
    identity: str            # '' | 'a' | 'd'
    notnull: bool
    has_default: bool


@dataclass
class TargetTable:
    schema: str
    name: str
    oid: int
    columns: list  # TargetColumn


class Introspector:
    """Reads type/column/constraint metadata from a live target connection."""

    def __init__(self, conn, schema: str):
        self.conn = conn
        self.schema = schema
        self._type_cache: dict = {}

    def resolve_type(self, oid: int) -> TypeInfo:
        if oid in self._type_cache:
            return self._type_cache[oid]
        # placeholder guards against composite self-reference cycles
        self._type_cache[oid] = TypeInfo(kind="scalar", typname="", typcategory="")
        with self.conn.cursor() as cur:
            cur.execute(
                "SELECT typname, typtype, typcategory, typbasetype, typelem, typrelid, "
                "       format_type(oid, -1) "
                "FROM pg_type WHERE oid = %s",
                (oid,),
            )
            typname, typtype, typcat, typbase, typelem, typrelid, sqltype = cur.fetchone()
            if typtype == "d":
                ti = TypeInfo("domain", typname, typcat, sqltype, base=self.resolve_type(typbase))
            elif typtype == "c":
                cur.execute(
                    "SELECT a.attname, a.atttypid FROM pg_attribute a "
                    "WHERE a.attrelid = %s AND a.attnum > 0 AND NOT a.attisdropped "
                    "ORDER BY a.attnum",
                    (typrelid,),
                )
                fields = cur.fetchall()
                ti = TypeInfo("composite", typname, typcat, sqltype, fields=[])
                self._type_cache[oid] = ti
                ti.fields = [(fn, self.resolve_type(ft)) for fn, ft in fields]
            elif typcat == "A" and typelem:
                ti = TypeInfo("array", typname, typcat, sqltype, element=self.resolve_type(typelem))
            else:
                ti = TypeInfo("scalar", typname, typcat, sqltype)
        self._type_cache[oid] = ti
        return ti

    def table_oids(self) -> dict:
        """Return {table_name: oid} for ordinary tables in the target schema."""
        with self.conn.cursor() as cur:
            cur.execute(
                "SELECT c.relname, c.oid FROM pg_class c "
                "JOIN pg_namespace n ON n.oid = c.relnamespace "
                "WHERE n.nspname = %s AND c.relkind IN ('r','p')",
                (self.schema,),
            )
            return {r[0]: r[1] for r in cur.fetchall()}

    def columns(self, oid: int) -> list:
        with self.conn.cursor() as cur:
            cur.execute(
                "SELECT a.attname, a.attnum, a.attgenerated, a.attidentity, a.attnotnull, "
                "       a.atttypid, (ad.adbin IS NOT NULL) AS has_default "
                "FROM pg_attribute a "
                "LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum "
                "WHERE a.attrelid = %s AND a.attnum > 0 AND NOT a.attisdropped "
                "ORDER BY a.attnum",
                (oid,),
            )
            out = []
            for name, attnum, gen, ident, notnull, typid, has_default in cur.fetchall():
                out.append(
                    TargetColumn(
                        name=name,
                        typinfo=self.resolve_type(typid),
                        attnum=attnum,
                        generated=(gen or "") != "",
                        identity=ident or "",
                        notnull=notnull,
                        has_default=has_default,
                    )
                )
            return out


# psycopg.sql is imported lazily so the pure-Python core has no hard dependency.
sqlmod: Any = None


def _load_psycopg():
    global sqlmod
    import psycopg
    from psycopg import sql as _sql

    sqlmod = _sql
    return psycopg


# --------------------------------------------------------------------------- #
# Planning                                                                     #
# --------------------------------------------------------------------------- #
@dataclass
class ColumnPlan:
    target: str
    source: str
    source_index: int
    typinfo: TypeInfo
    identity: str


@dataclass
class TablePlan:
    source_table: str
    target_table: str
    oid: int
    source_columns: list          # ordered source column dicts from manifest
    insert_columns: list          # ColumnPlan
    generated_columns: list       # names
    auto_filled: list             # target cols with no source (default/identity)
    dropped_source: list          # non-virtual source cols with no target
    source_rows: int
    file: Path


def build_plan(introspector: Introspector, check: ManifestCheck, mapping: dict) -> tuple:
    """Return (list[TablePlan], blockers).  Never mutates anything."""
    blockers: list = []
    plans: list = []
    table_oids = introspector.table_oids()
    target_names = list(table_oids)
    tmap = mapping.get("tables", {})

    for entry in check.manifest.get("tables", []):
        src_table = entry["table"]
        if src_table not in check.files:
            continue  # already reported as a validation error
        # find the target table for this source table
        explicit_tt = None
        for tt, spec in tmap.items():
            if spec.get("source") == src_table:
                explicit_tt = tt
        try:
            if explicit_tt is not None:
                if explicit_tt not in table_oids:
                    raise LoaderError(f"mapping target table {explicit_tt!r} not found in schema")
                target_table = explicit_tt
            else:
                # resolve target name from source name via the same fold rule
                cands = [t for t in target_names if _matches(src_table, t)]
                if len(cands) != 1:
                    raise LoaderError(
                        f"source table {src_table!r} matches targets {sorted(cands)!r}; add a mapping"
                        if cands else f"source table {src_table!r} has no target table"
                    )
                target_table = cands[0]
        except LoaderError as exc:
            blockers.append({"kind": "table_match", "table": src_table, "detail": str(exc)})
            continue

        oid = table_oids[target_table]
        tcols = introspector.columns(oid)
        col_map = (tmap.get(target_table, {}) or {}).get("columns", {}) or {}
        src_cols = entry["columns"]
        src_names = [c["name"] for c in src_cols]
        src_index = {c["name"]: i for i, c in enumerate(src_cols)}

        insert_cols: list = []
        generated: list = []
        auto_filled: list = []
        matched_source: set = set()      # source cols feeding an inserted target col
        generated_source: set = set()    # source cols represented by a target generated col
        table_blocked = False

        for tc in tcols:
            if tc.generated:
                generated.append(tc.name)
                # A target generated column recomputes its own value and is never
                # inserted, but it can still *represent* a source column (usually
                # an Oracle GENERATED/VIRTUAL column of the same name), which then
                # is not counted as dropped.  Resolve that representation without
                # hiding operator mistakes:
                #   * an explicit mapping that fails to resolve is a real error --
                #     surface it even if every source column is represented else-
                #     where (otherwise a typo'd mapping passes silently);
                #   * an ambiguous (multiple) source match must be surfaced too;
                #   * a genuinely target-only generated column (no source match and
                #     no explicit mapping) is fine and simply represents nothing.
                explicit = col_map.get(tc.name)
                if explicit is not None:
                    try:
                        generated_source.add(resolve_name(tc.name, src_names, explicit))
                    except LoaderError as exc:
                        blockers.append({"kind": "invalid_generated_mapping",
                                         "table": target_table, "column": tc.name,
                                         "detail": str(exc)})
                        table_blocked = True
                    continue
                gmatches = [s for s in src_names if _matches(s, tc.name)]
                if len(gmatches) == 1:
                    generated_source.add(gmatches[0])
                elif len(gmatches) > 1:
                    blockers.append({"kind": "ambiguous_generated_source",
                                     "table": target_table, "column": tc.name,
                                     "detail": f"target generated column {tc.name!r} "
                                     f"ambiguously matches sources {sorted(gmatches)!r}; "
                                     f"add an explicit mapping"})
                    table_blocked = True
                continue
            try:
                src = resolve_name(tc.name, src_names, col_map.get(tc.name))
            except LoaderError as exc:
                # no source column: let the DB fill identity / defaults, else block
                if tc.identity or tc.has_default:
                    auto_filled.append(tc.name)
                    continue
                blockers.append({"kind": "missing_source_column", "table": target_table,
                                 "column": tc.name, "detail": str(exc)})
                table_blocked = True
                continue
            matched_source.add(src)
            _plan_check_encoding(src_cols[src_index[src]], tc, blockers, target_table)
            insert_cols.append(ColumnPlan(tc.name, src, src_index[src], tc.typinfo, tc.identity))

        # Every source column that reaches no target column -- neither an inserted
        # column nor a target generated column -- is silent data loss.  The
        # source's own virtual=YES flag is deliberately NOT trusted here: Oracle
        # reports XMLTYPE and object/nested-table columns as virtual even though
        # they store real data, so dropping on that flag alone loses real columns.
        dropped = [n for n in src_names
                   if n not in matched_source and n not in generated_source]
        for n in dropped:
            blockers.append({"kind": "dropped_source_column", "table": src_table,
                             "column": n, "detail": "source column maps to no target column"})

        if table_blocked or dropped:
            continue
        plans.append(TablePlan(
            source_table=src_table, target_table=target_table, oid=oid,
            source_columns=src_cols, insert_columns=insert_cols,
            generated_columns=generated, auto_filled=auto_filled, dropped_source=dropped,
            source_rows=entry["rows"], file=check.files[src_table],
        ))
    return plans, blockers


# Oracle types that carry a type_owner but serialise to plain text/bytes, so
# they are NOT user-defined object/collection values.
_BUILTIN_TYPED_SOURCES = {"XMLTYPE"}


def _source_is_udt(src_col: dict) -> bool:
    """True when the source column holds an Oracle object or collection value."""
    src_type = src_col.get("type", "")
    if src_type in _BUILTIN_TYPED_SOURCES:
        return False
    return bool(src_col.get("type_owner")) or src_type.startswith("T_")


def _plan_check_encoding(src_col: dict, tc: TargetColumn, blockers: list, table: str) -> None:
    """Static compatibility check between an Oracle source column and target type."""
    base = tc.typinfo
    while base.kind == "domain":
        base = base.base
    src_is_object = _source_is_udt(src_col)
    if base.kind in ("composite", "array"):
        if not src_is_object:
            blockers.append({"kind": "type_mismatch", "table": table, "column": tc.name,
                             "detail": f"target {base.kind} but source {src_col.get('type')} is scalar"})
    elif base.kind == "scalar":
        if base.typname in ("json", "jsonb", "xml"):
            return  # xml/json accept serialised text; runtime encode_field still guards shape
        if src_is_object:
            blockers.append({"kind": "type_mismatch", "table": table, "column": tc.name,
                             "detail": f"target scalar {base.typname} cannot hold Oracle {src_col.get('type')}"})


# --------------------------------------------------------------------------- #
# Report helpers                                                               #
# --------------------------------------------------------------------------- #
def _plan_to_report(check: ManifestCheck, plans: list, blockers: list, mode: str,
                    database: str, schema: str, existing: dict, extra: dict) -> dict:
    m = check.manifest
    report = {
        "mode": mode,
        "database": database,
        "target_schema": schema,
        "source": {"schema": m.get("schema"), "observed_scn": m.get("observed_scn"),
                   "rows_expected": m.get("rows_exported")},
        "manifest_validation": {"ok": not check.errors,
                                "files_checked": len(check.files),
                                "errors": check.errors},
        "tables": [
            {
                "source_table": p.source_table,
                "target_table": p.target_table,
                "source_rows": p.source_rows,
                "target_rows_existing": existing.get(p.target_table),
                "insert_columns": [
                    {"target": c.target, "source": c.source, "type": c.typinfo.typname or c.typinfo.kind,
                     "kind": c.typinfo.kind, "identity": c.identity or None}
                    for c in p.insert_columns
                ],
                "generated_columns": p.generated_columns,
                "auto_filled_columns": p.auto_filled,
            }
            for p in plans
        ],
        "blockers": (check.errors if check.errors else []) + blockers,
        "excluded_source_objects": check.excluded,
        "materialized_views_need_refresh": [e.get("table") for e in check.materialized_views],
    }
    report.update(extra)
    return report


# --------------------------------------------------------------------------- #
# Apply (single transaction)                                                   #
# --------------------------------------------------------------------------- #
def _qual(schema: str, name: str):
    return sqlmod.Identifier(schema, name)


def _save_and_drop_fks(conn, schema: str, oids: list) -> list:
    saved = []
    with conn.cursor() as cur:
        cur.execute(
            "SELECT c.conname, c.conrelid::regclass::text, pg_get_constraintdef(c.oid) "
            "FROM pg_constraint c WHERE c.contype = 'f' AND c.conrelid = ANY(%s)",
            (oids,),
        )
        for conname, relident, condef in cur.fetchall():
            saved.append({"conname": conname, "table": relident, "def": condef})
    with conn.cursor() as cur:
        for fk in saved:
            cur.execute(sqlmod.SQL("ALTER TABLE {} DROP CONSTRAINT {}").format(
                sqlmod.SQL(fk["table"]), sqlmod.Identifier(fk["conname"])))
    return saved


def _recreate_and_validate_fks(conn, saved: list) -> None:
    with conn.cursor() as cur:
        for fk in saved:
            cur.execute(sqlmod.SQL("ALTER TABLE {} ADD CONSTRAINT {} {} NOT VALID").format(
                sqlmod.SQL(fk["table"]), sqlmod.Identifier(fk["conname"]), sqlmod.SQL(fk["def"])))
        for fk in saved:
            cur.execute(sqlmod.SQL("ALTER TABLE {} VALIDATE CONSTRAINT {}").format(
                sqlmod.SQL(fk["table"]), sqlmod.Identifier(fk["conname"])))


def _save_and_disable_triggers(conn, schema: str, oids: list) -> list:
    saved = []
    with conn.cursor() as cur:
        cur.execute(
            "SELECT t.tgrelid::regclass::text, t.tgname, t.tgenabled "
            "FROM pg_trigger t WHERE t.tgrelid = ANY(%s) AND NOT t.tgisinternal",
            (oids,),
        )
        for relident, tgname, tgenabled in cur.fetchall():
            saved.append({"table": relident, "tgname": tgname, "tgenabled": tgenabled})
    tables = sorted({s["table"] for s in saved})
    with conn.cursor() as cur:
        for tbl in tables:
            cur.execute(sqlmod.SQL("ALTER TABLE {} DISABLE TRIGGER USER").format(sqlmod.SQL(tbl)))
    return saved


def _restore_triggers(conn, saved: list) -> None:
    verb = {"O": "ENABLE TRIGGER", "D": "DISABLE TRIGGER",
            "R": "ENABLE REPLICA TRIGGER", "A": "ENABLE ALWAYS TRIGGER"}
    with conn.cursor() as cur:
        for tg in saved:
            cur.execute(sqlmod.SQL("ALTER TABLE {} " + verb[tg["tgenabled"]] + " {}").format(
                sqlmod.SQL(tg["table"]), sqlmod.Identifier(tg["tgname"])))


def _contains_json(tinfo: TypeInfo, _seen: Optional[set] = None) -> bool:
    """True if the target type is, or transitively contains, a json/jsonb leaf.

    Such columns need the faithful raw-json transport + SQL projection so a JSON
    ``null`` VALUE at any leaf survives distinct from SQL NULL; columns with no
    json leaf use the plain typed cast (json_to_recordset AS <realtype>).
    """
    if _seen is None:
        _seen = set()
    if id(tinfo) in _seen:
        return False                     # break composite self-reference cycles
    _seen.add(id(tinfo))
    if tinfo.kind == "scalar":
        return tinfo.typname in ("json", "jsonb")
    if tinfo.kind == "domain":
        return tinfo.base is not None and _contains_json(tinfo.base, _seen)
    if tinfo.kind == "composite":
        return any(_contains_json(ft, _seen) for _, ft in tinfo.fields)
    if tinfo.kind == "array":
        return tinfo.element is not None and _contains_json(tinfo.element, _seen)
    return False


def _transport(encoded: Any, tinfo: TypeInfo) -> Any:
    """Shape an encode_field result into the faithful raw-json transport tree.

    Every json/jsonb leaf is wrapped ``{_JSON_WRAP_KEY: value}`` so the SQL
    projector can tell a source SQL NULL (transported as a bare JSON null ->
    SQL NULL) from the JSON null VALUE (``{_JSON_WRAP_KEY: null}`` -> jsonb
    'null').  Composite/array structure is preserved so the projector rebuilds
    the real type field-by-field / element-by-element; non-json scalars pass
    through and are cast from text by the projector.
    """
    if tinfo.kind == "domain":
        return _transport(encoded, tinfo.base)
    if tinfo.kind == "scalar" and tinfo.typname in ("json", "jsonb"):
        if encoded is None:
            return None                                  # source SQL NULL
        return {_JSON_WRAP_KEY: (None if encoded is JSON_NULL else encoded)}
    if tinfo.kind == "composite":
        if encoded is None:
            return None                                  # SQL NULL composite
        # a non-null composite stays a JSON object (even if all fields null),
        # which the projector distinguishes from a SQL NULL composite
        return {fname: _transport(encoded.get(fname), ftype) for fname, ftype in tinfo.fields}
    if tinfo.kind == "array":
        if encoded is None:
            return None                                  # SQL NULL array
        return [_transport(e, tinfo.element) for e in encoded]
    return encoded                                       # non-json scalar leaf


def _project_sql(col_expr, tinfo: TypeInfo, depth: int = 0):
    """Build the SQL that projects a raw ``json`` expression into ``tinfo``'s type.

    Mirrors _transport.  json leaf -> unwrap ``-> _JSON_WRAP_KEY`` then cast;
    domain -> project the base then cast to the domain (so its CHECK sees the
    real value); composite -> typed NULL for SQL/JSON null else ROW(project each
    field)::type; array -> typed NULL else ARRAY(project each element)::type;
    non-json scalar -> ``#>> '{}'`` text then cast to the exact type.
    """
    if tinfo.kind == "domain":
        return sqlmod.SQL("({})::{}").format(
            _project_sql(col_expr, tinfo.base, depth), sqlmod.SQL(tinfo.sqltype))
    if tinfo.kind == "scalar":
        if tinfo.typname in ("json", "jsonb"):
            return sqlmod.SQL("(({} -> {})::{})").format(
                col_expr, sqlmod.Literal(_JSON_WRAP_KEY), sqlmod.SQL(tinfo.typname))
        return sqlmod.SQL("(({} #>> {})::{})").format(
            col_expr, sqlmod.Literal("{}"), sqlmod.SQL(tinfo.sqltype))
    if tinfo.kind == "composite":
        parts = sqlmod.SQL(", ").join(
            _project_sql(sqlmod.SQL("({} -> {})").format(col_expr, sqlmod.Literal(fname)),
                         ftype, depth + 1)
            for fname, ftype in tinfo.fields)
        return sqlmod.SQL(
            "(CASE WHEN {c} IS NULL OR json_typeof({c}) = 'null' "
            "THEN NULL::{t} ELSE ROW({parts})::{t} END)"
        ).format(c=col_expr, t=sqlmod.SQL(tinfo.sqltype), parts=parts)
    if tinfo.kind == "array":
        elem_alias = sqlmod.Identifier("_e%d" % depth)
        elem_val = sqlmod.SQL("{}.value").format(elem_alias)
        return sqlmod.SQL(
            "(CASE WHEN {c} IS NULL OR json_typeof({c}) = 'null' THEN NULL::{t} "
            "ELSE ARRAY(SELECT {proj} FROM json_array_elements({c}) "
            "WITH ORDINALITY AS {alias}(value, ord) ORDER BY {alias}.ord)::{t} END)"
        ).format(c=col_expr, t=sqlmod.SQL(tinfo.sqltype),
                 proj=_project_sql(elem_val, tinfo.element, depth + 1), alias=elem_alias)
    raise LoaderError(f"cannot project json into target kind {tinfo.kind!r}")


def _json_encode(o: Any) -> str:
    """Serialize one decoded json value to JSON text (linear in output size).

    Reuses json.dumps for strings, ints and finite floats (correct escaping and
    number formatting); renders each finite Decimal as its EXACT string form -- a
    valid JSON number, never a lossy float, never quoted, and str() keeps a valid
    scientific form without format('f') exponent blow-up; and folds the JSON_NULL
    sentinel (which can arrive nested inside a composite/array value) back to a
    bare ``null`` so it never escapes to json.dumps as an unserializable object.
    """
    if o is None or o is JSON_NULL:
        return "null"
    if isinstance(o, bool):
        return "true" if o else "false"
    if isinstance(o, Decimal):
        if not o.is_finite():
            raise MappingBlocker(f"cannot store non-finite decimal {o!r} in json")
        return str(o)
    if isinstance(o, float):
        if not math.isfinite(o):
            raise MappingBlocker(f"cannot store non-finite float {o!r} in json")
        return json.dumps(o)
    if isinstance(o, (int, str)):
        return json.dumps(o)
    if isinstance(o, dict):
        return "{" + ",".join(json.dumps(str(k)) + ":" + _json_encode(v)
                              for k, v in o.items()) + "}"
    if isinstance(o, list):
        return "[" + ",".join(_json_encode(v) for v in o) + "]"
    raise MappingBlocker(f"cannot serialize {type(o).__name__} as json")


def _dumps_batch(batch: list) -> str:
    """JSON text for a batch of row dicts, with exact-Decimal number fidelity."""
    return _json_encode(batch)


def _insert_table(conn, schema: str, plan: TablePlan) -> list:
    """Stream-insert one table in batches; return per-insert-column non-null counts."""
    cols = plan.insert_columns
    nonnull = [0] * len(cols)
    contains_json = [_contains_json(c.typinfo) for c in cols]
    has_identity = any(c.identity == "a" for c in cols)
    tbl = _qual(schema, plan.target_table)
    collist = sqlmod.SQL(", ").join(sqlmod.Identifier(c.target) for c in cols)
    # Rows are fed through json_to_recordset with an explicit column list.  A
    # column whose type contains a json/jsonb leaf is received RAW (typed
    # ``json``) and projected into its real type by _project_sql, so a JSON
    # ``null`` VALUE survives at every leaf (distinct from SQL NULL) and every
    # number stays exact; all other columns are received already cast to their
    # real type (identical to the previous json_populate_recordset behaviour).
    as_items, select_items = [], []
    for c, cj in zip(cols, contains_json):
        ident = sqlmod.Identifier(c.target)
        if cj:
            as_items.append(sqlmod.SQL("{} json").format(ident))
            select_items.append(_project_sql(ident, c.typinfo))
        else:
            as_items.append(sqlmod.SQL("{} {}").format(ident, sqlmod.SQL(c.typinfo.sqltype)))
            select_items.append(ident)
    aslist = sqlmod.SQL(", ").join(as_items)
    sellist = sqlmod.SQL(", ").join(select_items)
    overriding = sqlmod.SQL(" OVERRIDING SYSTEM VALUE ") if has_identity else sqlmod.SQL(" ")
    query = sqlmod.SQL(
        "INSERT INTO {tbl} ({cols}){ov}SELECT {sel} "
        "FROM json_to_recordset({p}::json) AS r({aslist})"
    ).format(tbl=tbl, cols=collist, sel=sellist, ov=overriding,
             p=sqlmod.Placeholder(), aslist=aslist)

    batch: list = []

    def flush():
        if not batch:
            return
        with conn.cursor() as cur:
            cur.execute(query, [_dumps_batch(batch)])
        batch.clear()

    for row in iter_rows(plan.file):
        obj = {}
        for i, c in enumerate(cols):
            val = row[c.source_index]
            if val is not None:
                nonnull[i] += 1
            enc = encode_field(val, c.typinfo)
            obj[c.target] = _transport(enc, c.typinfo) if contains_json[i] else enc
        batch.append(obj)
        if len(batch) >= BATCH_ROWS:
            flush()
    flush()
    return nonnull


def _verify_table(conn, schema: str, plan: TablePlan, source_nonnull: list) -> dict:
    """Verify row count and per-column non-null counts; raise on any mismatch."""
    cols = plan.insert_columns
    tbl = _qual(schema, plan.target_table)
    selects = [sqlmod.SQL("count(*)")]
    for c in cols:
        selects.append(sqlmod.SQL("count({})").format(sqlmod.Identifier(c.target)))
    with conn.cursor() as cur:
        cur.execute(sqlmod.SQL("SELECT {} FROM {}").format(sqlmod.SQL(", ").join(selects), tbl))
        row = cur.fetchone()
    total, col_counts = row[0], list(row[1:])
    if total != plan.source_rows:
        raise LoaderError(f"{plan.target_table}: loaded {total} rows, expected {plan.source_rows}")
    for c, got, want in zip(cols, col_counts, source_nonnull):
        if got != want:
            raise LoaderError(
                f"{plan.target_table}.{c.target}: {got} non-null values loaded, expected {want}"
            )
    return {"table": plan.target_table, "rows": total,
            "columns_verified": len(cols)}


def _first_line(exc: Exception) -> str:
    """A short, single-line description of an exception for a receipt/blocker."""
    text = str(exc).strip()
    return text.splitlines()[0] if text else exc.__class__.__name__


def _is_lost_commit_ack(exc: Exception, conn) -> bool:
    """True when a ``commit()`` error leaves the outcome genuinely UNKNOWN.

    A connection-class failure (SQLSTATE class ``08``) or an already-closed
    connection means the acknowledgement was lost: the server may or may not have
    committed, so we must NOT claim a rollback.  Any other error (e.g. a deferred
    constraint violation, class ``23``) is a definite server-side abort -- the
    transaction really did roll back.
    """
    sqlstate = getattr(exc, "sqlstate", None) or ""
    return bool(getattr(conn, "closed", False)) or sqlstate.startswith("08")


def _finalize_sequences(conn, schema: str, plans: list) -> dict:
    """After commit: setval owned identity/serial sequences to the source max.

    This runs non-transactionally, *after* the rows are already durably committed.
    It is best-effort and fail-safe, and it NEVER raises: both the per-table
    sequence *discovery* and each *setval* are guarded, so a post-commit failure
    (connection drop, revoked privilege) is recorded as an ``error`` receipt
    rather than escaping to be mistaken for a rollback.  Every owned sequence gets
    a receipt (``pending`` -> ``completed`` / ``skipped`` / ``error``); a discovery
    failure yields a table-level ``error`` receipt.  It never rolls back or
    reloads -- resume/repair is the full-run owner's job.

    Returns ``{"status": "ok"|"failed", "errors": int, "receipts": [...]}``.
    """
    receipts: list = []
    pending: list = []  # (receipt, plan, seq_ident, colname) for each owned sequence
    errors = 0
    discovery_complete = True  # False once any table's owned sequences went unlisted
    for plan in plans:
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT s.oid::regclass::text, a.attname, ns.nspname, s.relname "
                    "FROM pg_depend d "
                    "JOIN pg_class s ON s.oid = d.objid AND s.relkind = 'S' "
                    "JOIN pg_namespace ns ON ns.oid = s.relnamespace "
                    "JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid "
                    "WHERE d.refobjid = %s AND d.deptype IN ('a', 'i')",
                    (plan.oid,),
                )
                owned = cur.fetchall()
        except Exception as exc:  # noqa: BLE001 -- discovery failed after commit
            errors += 1
            discovery_complete = False  # this table's sequences were never enumerated
            receipts.append({"table": plan.target_table, "status": "error",
                             "detail": "sequence discovery failed: " + _first_line(exc)})
            continue
        for seq_ident, colname, seq_schema, seq_name in owned:
            # sequence_schema/sequence_name are the search_path-INDEPENDENT
            # identity a resume consumer needs to build a fully-qualified
            # setval(); ``sequence`` (regclass text) is kept for provenance but is
            # search_path-dependent, so must not be the sole recovery handle.
            receipt = {"sequence": seq_ident, "sequence_schema": seq_schema,
                       "sequence_name": seq_name, "column": colname,
                       "table": plan.target_table, "status": "pending"}
            receipts.append(receipt)
            pending.append((receipt, plan, seq_ident, colname))

    for receipt, plan, seq_ident, colname in pending:
        try:
            with conn.cursor() as cur:
                cur.execute(sqlmod.SQL("SELECT max({}) FROM {}").format(
                    sqlmod.Identifier(colname), _qual(schema, plan.target_table)))
                maxval = cur.fetchone()[0]
                if maxval is None:
                    receipt.update(status="skipped", detail="no rows")
                    continue
                cur.execute("SELECT setval(%s::regclass, %s, true)", (seq_ident, maxval))
            receipt.update(status="completed", set_to=str(maxval),
                           provenance=f"max({plan.target_table}.{colname})")
        except Exception as exc:  # noqa: BLE001 -- recorded as a per-sequence receipt
            errors += 1
            receipt.update(status="error", detail=_first_line(exc))
    return {"status": "ok" if errors == 0 else "failed", "errors": errors,
            "receipts": receipts, "discovery_complete": discovery_complete}


# --------------------------------------------------------------------------- #
# Orchestration                                                                #
# --------------------------------------------------------------------------- #
def run(manifest: Path, schema: str, database: str, mapping_path: Optional[Path],
        apply: bool) -> tuple:
    """Validate, connect, plan and (optionally) apply.  Returns (report, exit_code)."""
    check = validate_manifest(manifest)
    mapping = json.loads(Path(mapping_path).read_text(encoding="utf-8")) if mapping_path else {}

    psycopg = _load_psycopg()
    # Connection comes entirely from libpq PG* env vars; password never touched here.
    conn = psycopg.connect(autocommit=False)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT current_database()")
            actual_db = cur.fetchone()[0]
        if actual_db != database:
            raise LoaderError(f"connected to database {actual_db!r} but --database is {database!r}")
        with conn.cursor() as cur:
            cur.execute("SET TIME ZONE 'UTC'")

        intro = Introspector(conn, schema)
        plans, blockers = build_plan(intro, check, mapping)

        if not apply:
            # dry-run: read each destination's row count for the report.  Reads
            # only; the plan path never takes a write lock.
            existing = {p.target_table: _existing_count(conn, schema, p.target_table)
                        for p in plans}
            preexisting = sorted(t for t, c in existing.items() if c > 0)
            if preexisting:
                blockers.append({"kind": "target_not_empty", "tables": preexisting,
                                 "detail": "destination already holds rows; refusing to load"})
            fatal = bool(check.errors) or bool(blockers)
            report = _plan_to_report(check, plans, blockers, "plan", database, schema, existing, {})
            conn.rollback()
            return report, (1 if fatal else 0)

        if bool(check.errors) or bool(blockers):
            report = _plan_to_report(check, plans, blockers, "apply", database, schema, {},
                                     {"applied": False, "reason": "blockers present; nothing applied"})
            conn.rollback()
            return report, 1

        # Apply path: do NOT read the user target tables here -- that would hold an
        # ACCESS SHARE lock that deadlocks the ACCESS EXCLUSIVE a competing run
        # takes for DROP CONSTRAINT / DISABLE TRIGGER.  The authoritative
        # empty-target check runs under lock inside _apply.
        extra = _apply(conn, schema, plans)
        existing = extra.pop("existing", {})
        code = extra.pop("exit_code", 0)
        if extra.get("applied") is not True:
            # refused under lock (exit 1) or unknown commit outcome (exit 4);
            # surface its blockers, nothing was (knowably) written.
            refusal = extra.pop("blockers", [])
            report = _plan_to_report(check, plans, blockers + refusal, "apply",
                                     database, schema, existing, extra)
            return report, code
        report = _plan_to_report(check, plans, blockers, "apply", database, schema, existing, extra)
        return report, code
    finally:
        conn.close()


def _existing_count(conn, schema: str, table: str) -> int:
    with conn.cursor() as cur:
        cur.execute(sqlmod.SQL("SELECT count(*) FROM {}").format(_qual(schema, table)))
        return cur.fetchone()[0]


def _lock_and_recheck_empty(conn, schema: str, plans: list):
    """Serialise competing applies and re-verify empty targets *under lock*.

    Called as the first action of the apply transaction, before any row is
    written and before any catalog/user read has touched a target table:

    * Acquires ``ACCESS EXCLUSIVE`` on every target in a deterministic
      (name-sorted) order.  This is the strongest table lock, so it is taken
      exactly once up front and every later ``DROP CONSTRAINT`` / ``DISABLE
      TRIGGER`` / insert already holds it -- there is no lock *upgrade* mid-load,
      which is what would otherwise deadlock two concurrent applies (one waiting
      on the other's SHARE while the other needs ACCESS EXCLUSIVE against the
      first's lingering ACCESS SHARE).  A competing run holds no target lock
      while it waits here, so it simply blocks then refuses -- never deadlocks.
      The wait is bounded by ``lock_timeout``.
    * Re-counts every target under the locks in this same connection, closing the
      plan-time/apply-time race so a late run refuses instead of double-loading.

    Returns ``(existing_counts, refusal_blockers_or_None)``.  The caller rolls
    back on a refusal.
    """
    with conn.cursor() as cur:
        cur.execute(sqlmod.SQL("SET LOCAL lock_timeout = {}").format(
            sqlmod.Literal(APPLY_LOCK_TIMEOUT_MS)))
    for p in sorted(plans, key=lambda plan: plan.target_table):
        try:
            with conn.cursor() as cur:
                cur.execute(sqlmod.SQL("LOCK TABLE {} IN ACCESS EXCLUSIVE MODE").format(
                    _qual(schema, p.target_table)))
        except Exception as exc:  # noqa: BLE001 -- classify by SQLSTATE below
            if getattr(exc, "sqlstate", None) == "55P03":  # lock_not_available (timeout)
                return {}, [{"kind": "target_lock_unavailable", "table": p.target_table,
                             "detail": "another load holds a conflicting lock on this target; "
                                       "refusing to load"}]
            raise
    existing = {p.target_table: _existing_count(conn, schema, p.target_table) for p in plans}
    nonempty = sorted(t for t, c in existing.items() if c > 0)
    if nonempty:
        return existing, [{"kind": "target_not_empty", "tables": nonempty,
                           "detail": "destination already holds rows (verified under lock); "
                                     "refusing to load"}]
    return existing, None


def _apply(conn, schema: str, plans: list) -> dict:
    """Perform the load in one transaction; finalize sequences only after commit.

    Ordering matters for safety:

    * The FIRST action takes ACCESS EXCLUSIVE on every target and re-verifies
      emptiness under the lock, before any other read/write touches a target --
      so competing runs serialise without deadlocking and a late run refuses
      instead of double-loading.
    * The commit is classified three ways: success; a *definite* server-side
      failure (transaction aborted, no rows) -> LoaderError/rolled back; or a
      *lost acknowledgement* (connection-class error) where we cannot know
      whether the server committed -> outcome ``unknown`` for inspection, never a
      blind rollback claim.
    * Everything after a successful commit is best-effort and fully guarded: a
      failure there (autocommit switch, sequence discovery/setval) keeps the data
      and reports ``applied=true`` with an honest, possibly non-enumerated
      finalization receipt and a non-zero exit -- never a rollback, never a reload.
    """
    existing, refusal = _lock_and_recheck_empty(conn, schema, plans)
    if refusal is not None:
        conn.rollback()
        return {"applied": False, "existing": existing, "blockers": refusal,
                "exit_code": 1, "reason": "refused under target locks; nothing applied"}

    oids = [p.oid for p in plans]
    saved_fks: list = []
    saved_triggers: list = []
    try:
        saved_fks = _save_and_drop_fks(conn, schema, oids)
        saved_triggers = _save_and_disable_triggers(conn, schema, oids)
        nonnull = {}
        for p in plans:
            nonnull[p.target_table] = _insert_table(conn, schema, p)
        _restore_triggers(conn, saved_triggers)
        _recreate_and_validate_fks(conn, saved_fks)
        verification = [_verify_table(conn, schema, p, nonnull[p.target_table]) for p in plans]
    except Exception as exc:
        conn.rollback()
        raise LoaderError(f"apply failed and was rolled back: {exc}") from exc

    # Commit boundary.  A connection-class failure here means the acknowledgement
    # was lost and we CANNOT prove whether the server committed -- never claim a
    # rollback; surface an inspect-the-target outcome.  Any other error means the
    # server definitively aborted the transaction (no rows), which is a true
    # rollback.
    try:
        conn.commit()
    except Exception as exc:  # noqa: BLE001
        if _is_lost_commit_ack(exc, conn):
            return {"applied": "unknown", "existing": existing, "exit_code": 4,
                    "commit_outcome": "unknown",
                    "blockers": [{"kind": "commit_ack_unknown", "detail":
                                  "commit acknowledgement lost; the target may or may not hold "
                                  "the rows -- inspect it before any retry: " + _first_line(exc)}],
                    "reason": "commit outcome unknown; target must be inspected"}
        try:
            conn.rollback()
        except Exception:  # noqa: BLE001 -- connection already unusable
            pass
        raise LoaderError(f"apply failed and was rolled back: {exc}") from exc

    # Rows are durably committed and verified.  The entire post-commit phase is
    # guarded so nothing here can be mistaken for a rollback or trigger a reload.
    result = {
        "applied": True,
        "existing": existing,
        "foreign_keys_recreated": [f["conname"] for f in saved_fks],
        "triggers_restored": [t["tgname"] for t in saved_triggers],
        "verification": verification,
        "rows_loaded": sum(v["rows"] for v in verification),
    }
    try:
        conn.autocommit = True
        seqfin = _finalize_sequences(conn, schema, plans)
        result["sequences_reset"] = seqfin["receipts"]
        # enumerated=True only when every table's owned sequences were discovered;
        # a swallowed per-table discovery failure yields enumerated=False so a
        # consumer re-enumerates from the catalog instead of trusting a partial
        # receipt list (the data is already durable regardless).
        result["sequence_finalization"] = {"status": seqfin["status"],
                                            "errors": seqfin["errors"],
                                            "enumerated": seqfin["discovery_complete"]}
        if seqfin["status"] != "ok":
            result["finalization_failed"] = True
            result["exit_code"] = 3
    except Exception as exc:  # noqa: BLE001 -- post-commit; data is already durable
        result["sequences_reset"] = []
        result["sequence_finalization"] = {
            "status": "failed", "errors": 1, "enumerated": False,
            "detail": "post-commit finalization could not run (data is retained): "
                      + _first_line(exc)}
        result["finalization_failed"] = True
        result["exit_code"] = 3
    return result


# --------------------------------------------------------------------------- #
# CLI                                                                          #
# --------------------------------------------------------------------------- #
def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m migration_team.data_loader",
        description="Load a typed Oracle snapshot into a PostgreSQL target schema.",
    )
    parser.add_argument("--manifest", required=True, type=Path, help="snapshot manifest.json")
    parser.add_argument("--target-schema", required=True, help="destination schema name")
    parser.add_argument("--database", required=True,
                        help="expected database name (must equal current_database())")
    parser.add_argument("--mapping", type=Path, default=None,
                        help="optional JSON mapping for ambiguous table/column names")
    parser.add_argument("--apply", action="store_true",
                        help="perform the load (default is a dry-run plan)")
    parser.add_argument("--report", required=True, type=Path, help="write the JSON report here")
    args = parser.parse_args(argv)

    if os.environ.get("PGPASSWORD") is None and os.environ.get("PGPASSFILE") is None:
        # not fatal, but warn early so failures are legible (never print the value)
        print("warning: no PGPASSWORD/PGPASSFILE in environment", flush=True)

    try:
        report, code = run(args.manifest, args.target_schema, args.database,
                           args.mapping, args.apply)
    except LoaderError as exc:
        report = {"mode": "apply" if args.apply else "plan", "fatal_error": str(exc)}
        code = 2
    args.report.write_text(json.dumps(report, indent=2, default=str), encoding="utf-8")
    summary = report.get("fatal_error") or (
        f"{report.get('mode')}: {len(report.get('tables', []))} tables, "
        f"{len(report.get('blockers', []))} blockers, applied={report.get('applied', False)}"
    )
    if report.get("commit_outcome") == "unknown":
        summary += f", COMMIT OUTCOME UNKNOWN -- inspect target before retry (exit {code})"
    seqfin = report.get("sequence_finalization")
    if seqfin and seqfin.get("status") != "ok":
        summary += (f", sequence_finalization={seqfin.get('status')} "
                    f"({seqfin.get('errors')} error(s), data retained, exit {code})")
    print(summary, flush=True)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
