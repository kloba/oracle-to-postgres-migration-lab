#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Deterministic seed-data generator for the CONTOSO Oracle schema.

Contoso Store -- Oracle to Azure Database for PostgreSQL migration lab.
See docs/design.md; that document is the binding contract.

WHAT THIS EMITS
---------------
SQL*Plus-loadable files in <out>/oracle/data/ that populate every core table in
referentially consistent order:

    currency -> country -> exchange_rate -> calendar_day -> tax_rate
    -> region (5-level tree) -> address -> warehouse -> store
    -> employee (real manager hierarchy) -> circular-FK back-fill
    -> product_category (4-level tree) -> brand -> product -> product_variant
    -> supplier -> supplier_product
    -> customer -> customer_address -> loyalty_account -> loyalty_transaction
    -> price_list -> price_list_item -> promotion -> promotion_product -> coupon
    -> inventory_location -> inventory_stock -> inventory_movement
    -> sales_order -> sales_order_line -> order_payment -> shipment -> shipment_line
    -> purchase_order -> purchase_order_line -> goods_receipt
    -> return_request -> return_line
    -> gl_journal -> gl_journal_line
    -> the deliberate mess (see below)

HOW IT LOADS AT VOLUME
----------------------
One INSERT statement per row is unusable past a few thousand rows, so:

  * small, fixed reference tables use `INSERT ALL ... SELECT 1 FROM dual`
    batches, with every row spelled out so the values are auditable;
  * every high-volume table is loaded by an anonymous PL/SQL block that fills
    PL/SQL collections and writes them with `FORALL`, committing per batch.

The row values are computed inside PL/SQL by a 32-bit LCG seeded from a
constant, so the data is deterministic on the Oracle side too: two loads of the
same generated file produce the same rows, byte for byte, on any Oracle build.
The LCG is deliberately small (max intermediate 2.4e18, well inside Oracle
NUMBER's 38 significant digits) so no platform can round it differently.

Scale is a flag, not a rewrite: `--scale` changes a handful of row-count
constants and nothing else, so the emitted SQL stays comparable across scales.

    small   ~55,000 rows     CI, laptop, a few minutes
    medium  ~1,970,000 rows  the default; a realistic demo
    large   ~9,810,000 rows  partition and index behaviour under load

REALISTIC MESSINESS
-------------------
A migration that only has to survive clean data proves nothing. The load
includes, and 14-data-messy-edge-cases.sql concentrates and labels:

  * NULLs in every nullable column, at a plausible rate
  * empty strings -- which ORACLE STORES AS NULL. This is design.md H-38 and
    it is the single most insidious item in the lab, because nothing fails.
  * unicode names in Latin-1 supplement, Greek, Cyrillic, Arabic, CJK and
    Hangul, which stress VARCHAR2 byte semantics (trap T-03)
  * very long CLOBs built with DBMS_LOB.WRITEAPPEND (H-34)
  * negative and zero quantities -- shrink, write-off and stock-count rows
  * timestamps sitting exactly on DST transitions, including one that does not
    exist and one that happens twice (H-37)
  * blank-padded CHAR keys (trap T-04) and DATEs carrying a time (trap T-02)

Standard library only, Python 3.9+. See tools/requirements.txt.

USAGE
-----
    python3 tools/generate-data.py
    python3 tools/generate-data.py --scale small
    python3 tools/generate-data.py --scale large --out ./generated
"""

from __future__ import annotations

import argparse
import os
import sys
from collections import OrderedDict
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

DEFAULT_SEED = 20260902

# Two full trading years, so every 30-day interval partition on sales_order and
# every monthly interval partition on purchase_order materialises.
FACT_START = "2024-01-01"
FACT_END = "2026-01-01"
FACT_DAYS = 731            # 2024 is a leap year
CALENDAR_START = "2024-01-01"
CALENDAR_DAYS = 1096       # 2024-01-01 .. 2026-12-31

# --------------------------------------------------------------------------
# Row-count plan
# --------------------------------------------------------------------------

# Reference data that must NOT grow with --scale: its size is a property of the
# business, not of the demo.
FIXED_ROWS: "OrderedDict[str, int]" = OrderedDict([
    ("currency", 24),
    ("country", 40),
    ("exchange_rate", 2920),        # 730 days x 4 currency pairs
    ("calendar_day", CALENDAR_DAYS),
    ("tax_rate", 160),              # 40 countries x 4 tax codes
    ("region", 525),                # 1 + 4 + 40 + 120 + 360, five levels
    ("warehouse", 120),             # three per country
    ("product_category", 246),      # 6 + 24 + 72 + 144, four levels
    ("loyalty_tier", 5),
    ("carrier", 12),
    ("return_reason", 24),
    ("gl_account", 180),
    ("gl_period", 36),
    ("app_parameter", 40),
    ("price_list", 48),
    ("promotion", 60),
])

# Everything below is multiplied by the scale factor.
SCALABLE_ROWS: "OrderedDict[str, int]" = OrderedDict([
    ("address", 1200),
    ("store", 140),
    ("employee", 420),
    ("brand", 60),
    ("product", 1100),
    ("product_variant", 2400),
    ("supplier", 120),
    ("supplier_product", 1600),
    ("customer", 2000),
    ("customer_address", 2400),
    ("loyalty_account", 1400),
    ("loyalty_transaction", 2800),
    ("price_list_item", 2000),
    ("promotion_product", 300),
    ("coupon", 600),
    ("sales_order", 2400),
    ("sales_order_line", 5600),
    ("order_payment", 2600),
    ("shipment", 1600),
    ("shipment_line", 2800),
    ("inventory_location", 800),
    ("inventory_stock", 3200),
    ("inventory_movement", 4000),
    ("purchase_order", 600),
    ("purchase_order_line", 1800),
    ("goods_receipt", 1200),
    ("return_request", 280),
    ("return_line", 400),
    ("gl_journal", 800),
    ("gl_journal_line", 2400),
])

SCALE_FACTORS: "OrderedDict[str, int]" = OrderedDict([
    ("small", 1),
    ("medium", 40),
    ("large", 200),
])


def scale_arg(value: str) -> str:
    """Accept either a tier name or a bare numeric factor.

    Callers disagree about what --scale means. scripts/seed-oracle.sh and the
    CI workflows think in numeric factors (0.01 for a smoke run), while this
    generator thinks in tiers. Rejecting the number is technically correct and
    practically useless: it turned into a CI failure reading
        argument --scale: invalid choice: '0.01' (choose from small, medium, large)
    Accept both and map a number to the nearest tier by factor, so no caller has
    to know which vocabulary this particular script prefers.
    """
    if value in SCALE_FACTORS:
        return value
    try:
        factor = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError(
            "expected one of %s, or a number; got %r"
            % (", ".join(SCALE_FACTORS), value))
    if factor <= 0:
        raise argparse.ArgumentTypeError("scale must be greater than zero")
    return min(SCALE_FACTORS, key=lambda tier: abs(SCALE_FACTORS[tier] - factor))


def build_row_plan(scale: str) -> "OrderedDict[str, int]":
    factor = SCALE_FACTORS[scale]
    plan: "OrderedDict[str, int]" = OrderedDict()
    for table, n in FIXED_ROWS.items():
        plan[table] = n
    for table, n in SCALABLE_ROWS.items():
        plan[table] = n * factor
    return plan


def batch_size_for(scale: str) -> int:
    return {"small": 2000, "medium": 5000, "large": 10000}[scale]


# --------------------------------------------------------------------------
# Literal helpers
# --------------------------------------------------------------------------

def q(text: str) -> str:
    """Quote a Python string as an Oracle SQL literal."""
    return "'" + text.replace("'", "''") + "'"


def dt(datestr: str) -> str:
    return "DATE '%s'" % datestr


def ts(tsstr: str) -> str:
    return "TIMESTAMP '%s'" % tsstr


# --------------------------------------------------------------------------
# The PL/SQL bulk-load block
# --------------------------------------------------------------------------

LCG_FUNCTION = [
    "   -- Deterministic 32-bit LCG. Max intermediate is 2.4e18, comfortably",
    "   -- inside Oracle NUMBER's 38 significant digits, so no Oracle build can",
    "   -- round this differently. Same file, same rows, every time.",
    "   FUNCTION nxt(p_mod IN PLS_INTEGER) RETURN PLS_INTEGER IS",
    "   BEGIN",
    "      g_seed := MOD(g_seed * 1103515245 + 12345, 2147483648);",
    "      RETURN MOD(TRUNC(g_seed / 65536), GREATEST(NVL(p_mod, 1), 1));",
    "   END nxt;",
    "",
    "   FUNCTION pick(p_list IN t_str_varr) RETURN VARCHAR2 IS",
    "   BEGIN",
    "      RETURN p_list(1 + nxt(p_list.COUNT));",
    "   END pick;",
    "",
    "   -- Returns NULL one time in p_odds. Every nullable column in the schema",
    "   -- gets some of these, because a migration that only meets populated",
    "   -- columns has not met the schema.",
    "   FUNCTION maybe(p_value IN VARCHAR2, p_odds IN PLS_INTEGER) RETURN VARCHAR2 IS",
    "   BEGIN",
    "      RETURN CASE WHEN nxt(p_odds) = 0 THEN NULL ELSE p_value END;",
    "   END maybe;",
    "",
    "   FUNCTION maybe_n(p_value IN NUMBER, p_odds IN PLS_INTEGER) RETURN NUMBER IS",
    "   BEGIN",
    "      RETURN CASE WHEN nxt(p_odds) = 0 THEN NULL ELSE p_value END;",
    "   END maybe_n;",
    "",
    "   FUNCTION maybe_d(p_value IN DATE, p_odds IN PLS_INTEGER) RETURN DATE IS",
    "   BEGIN",
    "      RETURN CASE WHEN nxt(p_odds) = 0 THEN NULL ELSE p_value END;",
    "   END maybe_d;",
    "",
]


def bulk_block(
    *,
    table: str,
    rows: int,
    seed: int,
    columns: Sequence[str],
    values: Sequence[str],
    arrays: Sequence[Tuple[str, str]],
    fill: Sequence[str],
    batch: int,
    decls: Sequence[str] = (),
    prologue: Sequence[str] = (),
    epilogue: Sequence[str] = (),
    varrays: Sequence[Tuple[str, Sequence[str]]] = (),
    comment: Sequence[str] = (),
) -> str:
    """Emit one anonymous PL/SQL block that FORALL-loads `rows` into `table`.

    `fill` runs once per row with `i` as the array subscript and `v_r` as the
    global row number (1-based), which is what makes the surrogate keys dense
    and lets child tables reference parents by modular arithmetic.
    """
    out: List[str] = []
    out.append("-- " + "-" * 71)
    out.extend("-- " + c for c in comment)
    out.append("--   rows: %s" % "{:,}".format(rows))
    out.append("-- " + "-" * 71)
    out.append("DECLARE")
    out.append("   c_rows  CONSTANT PLS_INTEGER := %d;" % rows)
    out.append("   c_batch CONSTANT PLS_INTEGER := %d;" % batch)
    out.append("   g_seed  NUMBER := %d;" % seed)
    out.append("   v_n     PLS_INTEGER;")
    out.append("   v_r     PLS_INTEGER;")
    out.append("")
    out.append("   TYPE t_str_varr IS VARRAY(64) OF VARCHAR2(200);")
    for vname, items in varrays:
        out.append("   %s t_str_varr := t_str_varr(" % vname)
        chunk: List[str] = []
        line = "      "
        for n, item in enumerate(items):
            piece = q(item) + ("," if n < len(items) - 1 else "")
            if len(line) + len(piece) > 76:
                chunk.append(line.rstrip())
                line = "      "
            line += piece + " "
        chunk.append(line.rstrip())
        out.extend(chunk)
        out.append("   );")
    out.append("")
    for aname, atype in arrays:
        out.append("   TYPE ty_%s IS TABLE OF %s INDEX BY PLS_INTEGER;" % (aname, atype))
        out.append("   %s ty_%s;" % (aname, aname))
    out.extend("   " + d for d in decls)
    out.append("")
    out.extend(LCG_FUNCTION)
    out.append("BEGIN")
    out.extend("   " + p for p in prologue)
    out.append("   FOR b IN 0 .. TRUNC((c_rows - 1) / c_batch) LOOP")
    out.append("      v_n := LEAST(c_batch, c_rows - b * c_batch);")
    out.append("      FOR i IN 1 .. v_n LOOP")
    out.append("         v_r := b * c_batch + i;")
    out.extend("         " + f for f in fill)
    out.append("      END LOOP;")
    out.append("")
    out.append("      FORALL i IN 1 .. v_n")
    out.append("         INSERT INTO %s" % table)
    col_lines = _wrap_list(columns, "                (", ")")
    out.extend(col_lines)
    val_lines = _wrap_list(values, "         VALUES (", ");")
    out.extend(val_lines)
    out.append("")
    out.append("      COMMIT;")
    out.append("   END LOOP;")
    out.extend("   " + e for e in epilogue)
    out.append("   DBMS_OUTPUT.PUT_LINE('%s: ' || c_rows || ' rows');" % table)
    out.append("END;")
    out.append("/")
    return "\n".join(out)


def _wrap_list(items: Sequence[str], prefix: str, suffix: str) -> List[str]:
    lines: List[str] = []
    indent = " " * len(prefix)
    line = prefix
    for n, item in enumerate(items):
        piece = item + ("," if n < len(items) - 1 else suffix)
        if len(line) + len(piece) > 88 and line.strip() not in ("(", prefix.strip()):
            lines.append(line.rstrip())
            line = indent
        line += piece + " "
    lines.append(line.rstrip())
    return lines


def insert_all(table: str, columns: Sequence[str],
               rows: Sequence[Sequence[str]], chunk: int = 100) -> List[str]:
    """Emit INSERT ALL batches. Used for the small, auditable reference tables.

    Chunked at 100 because an Oracle multi-table insert is capped at 127 INTO
    clauses. Exceeding it fails with ORA-00913 at load time, not at generation
    time, which is the worst place to find out.
    """
    blocks: List[str] = []
    collist = ", ".join(columns)
    for start in range(0, len(rows), chunk):
        part = rows[start:start + chunk]
        lines = ["INSERT ALL"]
        for r in part:
            lines.append("   INTO %s (%s)" % (table, collist))
            lines.extend(_wrap_list(list(r), "        VALUES (", ")"))
        lines.append("SELECT 1 FROM dual;")
        lines.append("COMMIT;")
        blocks.append("\n".join(lines))
    return blocks


# --------------------------------------------------------------------------
# Reference data. Duplicated from tools/generate-objects.py on purpose: these
# two scripts must be runnable independently, and a shared module would have to
# be importable under a name with a dash in it.
# --------------------------------------------------------------------------

# (code, name, minor units, symbol)
CURRENCIES: Sequence[Tuple[str, str, int, str]] = (
    ("GBP", "Pound Sterling", 2, "GBP"), ("EUR", "Euro", 2, "EUR"),
    ("USD", "US Dollar", 2, "USD"), ("CHF", "Swiss Franc", 2, "CHF"),
    ("DKK", "Danish Krone", 2, "kr"), ("SEK", "Swedish Krona", 2, "kr"),
    ("NOK", "Norwegian Krone", 2, "kr"), ("ISK", "Icelandic Krona", 0, "kr"),
    ("PLN", "Polish Zloty", 2, "zl"), ("CZK", "Czech Koruna", 2, "Kc"),
    ("HUF", "Hungarian Forint", 0, "Ft"), ("RON", "Romanian Leu", 2, "lei"),
    ("BGN", "Bulgarian Lev", 2, "lv"), ("CAD", "Canadian Dollar", 2, "CAD"),
    ("MXN", "Mexican Peso", 2, "MXN"), ("BRL", "Brazilian Real", 2, "BRL"),
    ("ARS", "Argentine Peso", 2, "ARS"), ("CLP", "Chilean Peso", 0, "CLP"),
    ("AUD", "Australian Dollar", 2, "AUD"), ("NZD", "New Zealand Dollar", 2, "NZD"),
    ("JPY", "Japanese Yen", 0, "JPY"), ("SGD", "Singapore Dollar", 2, "SGD"),
    ("ZAR", "South African Rand", 2, "R"), ("CNY", "Chinese Yuan", 2, "CNY"),
)

# (iso2, iso3, name, currency, std vat, reduced vat, iana tz, locale, vat scheme)
COUNTRIES: Sequence[Tuple[str, str, str, str, str, str, str, str, str]] = (
    ("GB", "GBR", "United Kingdom", "GBP", "20", "5", "Europe/London", "en_GB", "UK_VAT"),
    ("IE", "IRL", "Ireland", "EUR", "23", "13.5", "Europe/Dublin", "en_IE", "EU_VAT"),
    ("FR", "FRA", "France", "EUR", "20", "5.5", "Europe/Paris", "fr_FR", "EU_VAT"),
    ("DE", "DEU", "Deutschland", "EUR", "19", "7", "Europe/Berlin", "de_DE", "EU_VAT"),
    ("ES", "ESP", "Espana", "EUR", "21", "10", "Europe/Madrid", "es_ES", "EU_VAT"),
    ("IT", "ITA", "Italia", "EUR", "22", "10", "Europe/Rome", "it_IT", "EU_VAT"),
    ("PT", "PRT", "Portugal", "EUR", "23", "6", "Europe/Lisbon", "pt_PT", "EU_VAT"),
    ("NL", "NLD", "Nederland", "EUR", "21", "9", "Europe/Amsterdam", "nl_NL", "EU_VAT"),
    ("BE", "BEL", "Belgie", "EUR", "21", "6", "Europe/Brussels", "nl_BE", "EU_VAT"),
    ("LU", "LUX", "Luxembourg", "EUR", "17", "8", "Europe/Luxembourg", "fr_LU", "EU_VAT"),
    ("AT", "AUT", "Osterreich", "EUR", "20", "10", "Europe/Vienna", "de_AT", "EU_VAT"),
    ("CH", "CHE", "Schweiz", "CHF", "8.1", "2.6", "Europe/Zurich", "de_CH", "CH_MWST"),
    ("DK", "DNK", "Danmark", "DKK", "25", "25", "Europe/Copenhagen", "da_DK", "EU_VAT"),
    ("SE", "SWE", "Sverige", "SEK", "25", "12", "Europe/Stockholm", "sv_SE", "EU_VAT"),
    ("NO", "NOR", "Norge", "NOK", "25", "15", "Europe/Oslo", "nb_NO", "NO_MVA"),
    ("FI", "FIN", "Suomi", "EUR", "25.5", "14", "Europe/Helsinki", "fi_FI", "EU_VAT"),
    ("IS", "ISL", "Island", "ISK", "24", "11", "Atlantic/Reykjavik", "is_IS", "IS_VSK"),
    ("PL", "POL", "Polska", "PLN", "23", "8", "Europe/Warsaw", "pl_PL", "EU_VAT"),
    ("CZ", "CZE", "Cesko", "CZK", "21", "12", "Europe/Prague", "cs_CZ", "EU_VAT"),
    ("SK", "SVK", "Slovensko", "EUR", "20", "10", "Europe/Bratislava", "sk_SK", "EU_VAT"),
    ("HU", "HUN", "Magyarorszag", "HUF", "27", "5", "Europe/Budapest", "hu_HU", "EU_VAT"),
    ("RO", "ROU", "Romania", "RON", "19", "9", "Europe/Bucharest", "ro_RO", "EU_VAT"),
    ("BG", "BGR", "Bulgaria", "BGN", "20", "9", "Europe/Sofia", "bg_BG", "EU_VAT"),
    ("GR", "GRC", "Ellada", "EUR", "24", "13", "Europe/Athens", "el_GR", "EU_VAT"),
    ("HR", "HRV", "Hrvatska", "EUR", "25", "13", "Europe/Zagreb", "hr_HR", "EU_VAT"),
    ("SI", "SVN", "Slovenija", "EUR", "22", "9.5", "Europe/Ljubljana", "sl_SI", "EU_VAT"),
    ("EE", "EST", "Eesti", "EUR", "22", "9", "Europe/Tallinn", "et_EE", "EU_VAT"),
    ("LV", "LVA", "Latvija", "EUR", "21", "12", "Europe/Riga", "lv_LV", "EU_VAT"),
    ("LT", "LTU", "Lietuva", "EUR", "21", "9", "Europe/Vilnius", "lt_LT", "EU_VAT"),
    ("US", "USA", "United States", "USD", "0", "0", "America/New_York", "en_US", "US_SALES"),
    ("CA", "CAN", "Canada", "CAD", "5", "5", "America/Toronto", "en_CA", "CA_GST"),
    ("MX", "MEX", "Mexico", "MXN", "16", "8", "America/Mexico_City", "es_MX", "MX_IVA"),
    ("BR", "BRA", "Brasil", "BRL", "17", "12", "America/Sao_Paulo", "pt_BR", "BR_ICMS"),
    ("AR", "ARG", "Argentina", "ARS", "21", "10.5",
     "America/Argentina/Buenos_Aires", "es_AR", "AR_IVA"),
    ("CL", "CHL", "Chile", "CLP", "19", "19", "America/Santiago", "es_CL", "CL_IVA"),
    ("AU", "AUS", "Australia", "AUD", "10", "10", "Australia/Sydney", "en_AU", "AU_GST"),
    ("NZ", "NZL", "New Zealand", "NZD", "15", "15", "Pacific/Auckland", "en_NZ", "NZ_GST"),
    ("JP", "JPN", "Nippon", "JPY", "10", "8", "Asia/Tokyo", "ja_JP", "JP_CT"),
    ("SG", "SGP", "Singapore", "SGD", "9", "9", "Asia/Singapore", "en_SG", "SG_GST"),
    ("ZA", "ZAF", "South Africa", "ZAR", "15", "15", "Africa/Johannesburg", "en_ZA", "ZA_VAT"),
)

SYSTEM_CODES: Sequence[str] = (
    "POS", "WMS", "TMS", "ERP_LEGACY", "CRM", "PIM", "FIN_SAP", "PAYGW",
    "LOYALTY_HUB", "MKTG_CLOUD", "SUPPLIER_EDI", "TAX_ENGINE", "BI_WAREHOUSE",
    "ECOM", "MOBILE_APP",
)

RULE_THEME_CODES: Sequence[str] = (
    "VOLUME_BREAK", "LOYALTY_TIER", "CLEARANCE", "BUNDLE", "CHANNEL_PARITY",
    "MARGIN_FLOOR", "COMPETITOR", "SEASONAL", "SUPPLIER_FUND", "BASKET_THRESHOLD",
)

# Unicode given and family names. These are the point, not decoration: VARCHAR2
# is byte-semantic by default (trap T-03), so a 60-byte column holds far fewer
# than 60 of these characters, and the overflow only shows up on real data.
FIRST_NAMES: Sequence[str] = (
    "Aisha", "Bjorn", "Chloe", "Dmitri", "Elena", "Farhan", "Gabriela", "Hiroshi",
    "Ingrid", "Jarek", "Katarzyna", "Liam", "Mateusz", "Nadia", "Oluwaseun",
    "Priya", "Quentin", "Rosa", "Sofia", "Tomasz", "Ursula", "Valentina",
    "Wojciech", "Xiulan", "Yusuf", "Zofia",
    "José", "Renée", "Björk", "Ásdís", "François",
    "Müller", "Ólafur", "Šimun", "Łukasz", "Nguyễn",
    "Ελένη", "Иван",
    "محمد", "山田", "陈伟",
    "김민준", "Ñuñez", "Åkerman",
    "Þóra", "Zoë",
)

LAST_NAMES: Sequence[str] = (
    "Adeyemi", "Bergstrom", "Costa", "Duarte", "Esposito", "Fischer", "Gallagher",
    "Horvath", "Ivanova", "Jensen", "Kowalski", "Lindqvist", "Moreau", "Novak",
    "OConnor", "Petrov", "Quintana", "Rossi", "Svensson", "Tanaka", "Ustinov",
    "Vargas", "Wagner", "Xu", "Yilmaz", "Zielinski",
    "Müller", "Schröder", "Ólafsdóttir", "Šimunović",
    "Nguyễn", "Петров",
    "العلي", "鈴木", "박서준",
    "Çelik", "Łukasiewicz", "Þorsteinsson",
)

CITIES: Sequence[str] = (
    "Manchester", "Dublin", "Lyon", "München", "Sevilla", "Milano", "Porto",
    "Utrecht", "Gent", "Graz", "Zürich", "Aarhus", "Göteborg", "Bergen",
    "Tampere", "Reykjavík", "Kraków", "Brno", "Košice", "Debrecen",
    "Cluj-Napoca", "Plovdiv", "Thessaloniki", "Split", "Maribor", "Tartu",
    "Liepāja", "Kaunas", "Austin", "Calgary", "Guadalajara", "Curitiba",
    "Rosario", "Valparaíso", "Adelaide", "Wellington", "京都",
    "Jurong", "Durban",
)

STREETS: Sequence[str] = (
    "High Street", "Market Square", "Station Road", "Rue de la Gare",
    "Bahnhofstrasse", "Calle Mayor", "Via Roma", "Kerkstraat", "Storgatan",
    "Hovedgaten", "Ulica Dluga", "Namesti Miru", "Fo utca", "Strada Mare",
    "Leoforos Athinon", "Trg Slobode", "Main Street", "Elm Avenue",
    "Avenida Central", "Rua das Flores",
)


def scenario_note(*lines: str) -> List[str]:
    """Comment lines for bulk_block, which supplies the leading '-- ' itself."""
    return list(lines)


# --------------------------------------------------------------------------
# 01 -- session preparation
# --------------------------------------------------------------------------

def file_session_prep(plan: Dict[str, int], scale: str) -> str:
    return "\n".join([
        "PROMPT === session preparation ===",
        "",
        "-- NLS is pinned so the emitted DATE and NUMBER literals parse identically on",
        "-- any client. TRAP T-09 and trap T-13 both depend on session settings, and a",
        "-- load that inherits the operator's locale is not reproducible.",
        "ALTER SESSION SET NLS_DATE_FORMAT       = 'YYYY-MM-DD HH24:MI:SS';",
        "ALTER SESSION SET NLS_TIMESTAMP_FORMAT  = 'YYYY-MM-DD HH24:MI:SS.FF';",
        "ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';",
        "ALTER SESSION SET NLS_SORT              = 'BINARY';",
        "ALTER SESSION SET NLS_COMP              = 'BINARY';",
        "",
        "-- The database time zone decides how TIMESTAMP WITH LOCAL TIME ZONE is stored.",
        "-- Pin the SESSION zone to UTC so the DST rows in 14-data-messy-edge-cases.sql",
        "-- land where the comments say they do (design.md H-37).",
        "ALTER SESSION SET TIME_ZONE = 'UTC';",
        "",
        "-- Triggers are disabled for the bulk load and restored by",
        "-- 98-data-session-restore.sql. Two reasons, both real:",
        "--   1. The hand-written trg_bi_* triggers assign surrogate keys from",
        "--      sequences. This loader supplies dense, explicit ids so that children",
        "--      can reference parents by arithmetic; letting a trigger overwrite them",
        "--      would break every foreign key in the load.",
        "--   2. The generated per-row audit triggers would multiply the row count and",
        "--      the load time by three at --scale large.",
        "-- Disabling triggers for a bulk load is what a real migration does too, and it",
        "-- is worth the reader seeing it stated rather than discovered.",
        "DECLARE",
        "   v_count PLS_INTEGER := 0;",
        "BEGIN",
        "   FOR t IN (SELECT trigger_name",
        "               FROM user_triggers",
        "              WHERE status = 'ENABLED'",
        "              ORDER BY trigger_name) LOOP",
        "      BEGIN",
        "         EXECUTE IMMEDIATE 'ALTER TRIGGER ' || t.trigger_name || ' DISABLE';",
        "         v_count := v_count + 1;",
        "      EXCEPTION",
        "         WHEN OTHERS THEN",
        "            DBMS_OUTPUT.PUT_LINE('could not disable ' || t.trigger_name);",
        "      END;",
        "   END LOOP;",
        "   DBMS_OUTPUT.PUT_LINE('triggers disabled: ' || v_count);",
        "END;",
        "/",
        "",
        "PROMPT scale=%s  planned rows=%s" % (scale, "{:,}".format(sum(plan.values()))),
    ])


def file_session_restore() -> str:
    return "\n".join([
        "PROMPT === session restore ===",
        "",
        "DECLARE",
        "   v_count PLS_INTEGER := 0;",
        "BEGIN",
        "   FOR t IN (SELECT trigger_name",
        "               FROM user_triggers",
        "              WHERE status = 'DISABLED'",
        "              ORDER BY trigger_name) LOOP",
        "      BEGIN",
        "         EXECUTE IMMEDIATE 'ALTER TRIGGER ' || t.trigger_name || ' ENABLE';",
        "         v_count := v_count + 1;",
        "      EXCEPTION",
        "         WHEN OTHERS THEN",
        "            DBMS_OUTPUT.PUT_LINE('could not enable ' || t.trigger_name);",
        "      END;",
        "   END LOOP;",
        "   DBMS_OUTPUT.PUT_LINE('triggers enabled: ' || v_count);",
        "END;",
        "/",
        "",
        "-- REVALIDATION AFTER THE TRIGGER SWEEP.",
        "-- Disabling a trigger that another trigger FOLLOWS breaks the ordering",
        "-- dependency and marks the *follower* INVALID -- trg_ar_gl_journal_line_b and",
        "-- the generated trg_gen_fol_b_* pairs, in this schema. Re-ENABLE does not",
        "-- undo that: the follower stays INVALID until something recompiles it or it",
        "-- fires for the first time. A load that ends with invalid objects is a load",
        "-- that fails 99-verify-objects.sql assertion C2 for a reason that has nothing",
        "-- to do with the data, so the sweep is undone properly here.",
        "-- COMPILE_SCHEMA with compile_all => FALSE touches only objects already marked",
        "-- INVALID, and it cannot hide a genuine compilation error: anything with real",
        "-- errors is still INVALID afterwards and still fails the assertion.",
        "BEGIN",
        "   DBMS_UTILITY.COMPILE_SCHEMA(schema => USER, compile_all => FALSE);",
        "EXCEPTION",
        "   WHEN OTHERS THEN",
        "      DBMS_OUTPUT.PUT_LINE('schema recompile skipped: ' || SQLERRM);",
        "END;",
        "/",
        "",
        "-- COMPILE_SCHEMA does not reach materialized views, which go NEEDS_COMPILE",
        "-- whenever a base table or one of its MV logs is touched by DDL during the",
        "-- load. Compile them explicitly; this does NOT refresh them, so a stale MV",
        "-- stays stale and stays visible to the staleness checks in 99-data-verify.sql.",
        "DECLARE",
        "   v_count PLS_INTEGER := 0;",
        "BEGIN",
        "   FOR m IN (SELECT object_name",
        "               FROM user_objects",
        "              WHERE object_type = 'MATERIALIZED VIEW'",
        "                AND status      = 'INVALID'",
        "              ORDER BY object_name) LOOP",
        "      BEGIN",
        "         EXECUTE IMMEDIATE 'ALTER MATERIALIZED VIEW \"'",
        "                           || m.object_name || '\" COMPILE';",
        "         v_count := v_count + 1;",
        "      EXCEPTION",
        "         WHEN OTHERS THEN",
        "            DBMS_OUTPUT.PUT_LINE('could not compile ' || m.object_name",
        "                                 || ': ' || SQLERRM);",
        "      END;",
        "   END LOOP;",
        "   DBMS_OUTPUT.PUT_LINE('materialized views recompiled: ' || v_count);",
        "END;",
        "/",
        "",
        "-- SEQUENCE HIGH-WATER MARKS.",
        "-- This loader inserts explicit, dense surrogate keys, so every sequence that",
        "-- feeds a loaded table is now behind the data. src/oracle/05-sequences.sql owns the",
        "-- sequence names, so re-syncing them is deliberately NOT done here -- guessing",
        "-- at names and silently skipping the ones that do not match would be worse",
        "-- than saying so. Re-sync before running the application against seeded data.",
        "PROMPT NOTE: re-sync sequence high-water marks before using the application.",
        "",
        "-- Statistics matter for the partitioned facts; without them the first query",
        "-- against sales_order picks a plan based on nothing.",
        "BEGIN",
        "   DBMS_STATS.GATHER_SCHEMA_STATS(",
        "      ownname          => USER,",
        "      estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,",
        "      method_opt       => 'FOR ALL COLUMNS SIZE AUTO',",
        "      degree           => DBMS_STATS.AUTO_DEGREE,",
        "      cascade          => TRUE);",
        "EXCEPTION",
        "   WHEN OTHERS THEN",
        "      -- Missing privilege or a locked table must not fail a load that has",
        "      -- already committed every row. Report and move on.",
        "      DBMS_OUTPUT.PUT_LINE('statistics not gathered: ' || SQLERRM);",
        "END;",
        "/",
    ])


# --------------------------------------------------------------------------
# 02 -- reference data
# --------------------------------------------------------------------------

def _plsql_country_varrays() -> List[str]:
    """PL/SQL VARRAY declarations for the 40 trading countries."""
    codes = [c[0] for c in COUNTRIES]
    ccys = [c[3] for c in COUNTRIES]
    tzs = [c[6] for c in COUNTRIES]
    out: List[str] = []
    for vname, items in (("v_cc", codes), ("v_ccy", ccys), ("v_tz", tzs)):
        out.append("   %s t_str_varr := t_str_varr(" % vname)
        line = "      "
        for n, item in enumerate(items):
            piece = q(item) + ("," if n < len(items) - 1 else "")
            if len(line) + len(piece) > 76:
                out.append(line.rstrip())
                line = "      "
            line += piece + " "
        out.append(line.rstrip())
        out.append("   );")
    return out


def file_reference(plan: Dict[str, int], seed: int, batch: int) -> str:
    parts: List[str] = ["PROMPT === reference data ==="]

    # ---- currency -------------------------------------------------------
    parts.append("\nPROMPT currency")
    rows = [
        (q(code), q(name), str(minor), q(sym), q("Y"))
        for code, name, minor, sym in CURRENCIES
    ]
    parts.extend(insert_all(
        "currency",
        ("currency_code", "currency_name", "minor_units", "symbol", "is_active"),
        rows))

    # ---- country --------------------------------------------------------
    parts.append("\nPROMPT country")
    rows = [
        (q(cc), q(name), q(iso3), q(ccy), q(locale), q(scheme), q(tz))
        for cc, iso3, name, ccy, std, red, tz, locale, scheme in COUNTRIES
    ]
    parts.extend(insert_all(
        "country",
        ("country_code", "country_name", "iso3_code", "currency_code",
         "default_locale", "vat_scheme", "tz_name"),
        rows))

    # ---- exchange_rate ---------------------------------------------------
    parts.append("\nPROMPT exchange_rate")
    parts.append(bulk_block(
        table="exchange_rate", rows=plan["exchange_rate"], seed=seed + 1,
        batch=batch,
        comment=scenario_note(
            "Daily FX for four currency pairs over the two trading years.",
            "Composite primary key (rate_date, from_currency, to_currency), so the",
            "row number has to decompose into a day and a pair or the load collides.",
            "CHECK (rate > 0) is respected: the walk is multiplicative, never additive."),
        varrays=(
            ("v_from", ("EUR", "USD", "EUR", "GBP")),
            ("v_to", ("GBP", "GBP", "USD", "USD")),
        ),
        arrays=(
            ("a_date", "DATE"), ("a_from", "VARCHAR2(3)"), ("a_to", "VARCHAR2(3)"),
            ("a_rate", "NUMBER"), ("a_src", "VARCHAR2(20)"),
        ),
        decls=("v_pair PLS_INTEGER;", "v_day PLS_INTEGER;"),
        fill=(
            "v_pair := MOD(v_r - 1, 4) + 1;",
            "v_day  := TRUNC((v_r - 1) / 4);",
            "a_date(i) := %s + v_day;" % dt(FACT_START),
            "a_from(i) := v_from(v_pair);",
            "a_to(i)   := v_to(v_pair);",
            "-- Deterministic random walk around a per-pair base, always positive.",
            "a_rate(i) := ROUND(",
            "   CASE v_pair WHEN 1 THEN 0.85 WHEN 2 THEN 0.79 WHEN 3 THEN 1.08",
            "               ELSE 1.27 END",
            "   * (1 + (nxt(400) - 200) / 10000), 8);",
            "a_src(i)  := CASE WHEN MOD(v_r, 17) = 0 THEN 'MANUAL' ELSE 'ECB_DAILY' END;",
        ),
        columns=("rate_date", "from_currency", "to_currency", "rate", "source_code"),
        values=("a_date(i)", "a_from(i)", "a_to(i)", "a_rate(i)", "a_src(i)"),
    ))

    # ---- calendar_day ----------------------------------------------------
    parts.append("\nPROMPT calendar_day (index-organized table)")
    parts.append(bulk_block(
        table="calendar_day", rows=plan["calendar_day"], seed=seed + 2, batch=batch,
        comment=scenario_note(
            "Fiscal calendar, three years. This is one of the three IOTs (H-18):",
            "ORGANIZATION INDEX simply disappears on conversion and the physical",
            "guarantee goes with it. Small lookup tables, so it does not matter here",
            "-- which is exactly why these three were chosen."),
        arrays=(
            ("a_day", "DATE"), ("a_fy", "NUMBER"), ("a_fp", "NUMBER"),
            ("a_fw", "NUMBER"), ("a_dow", "NUMBER"), ("a_trade", "VARCHAR2(1)"),
            ("a_hol", "VARCHAR2(1)"), ("a_season", "VARCHAR2(10)"),
        ),
        decls=("v_d DATE;",),
        fill=(
            "v_d := %s + (v_r - 1);" % dt(CALENDAR_START),
            "a_day(i)  := v_d;",
            "a_fy(i)   := EXTRACT(YEAR FROM v_d);",
            "a_fp(i)   := EXTRACT(MONTH FROM v_d);",
            "a_fw(i)   := TO_NUMBER(TO_CHAR(v_d, 'IW'));",
            "-- TO_CHAR(d,'D') is NLS_TERRITORY dependent; the arithmetic form is not.",
            "a_dow(i)  := 1 + MOD(TRUNC(v_d) - TRUNC(%s), 7);" % dt("2024-01-01"),
            "a_hol(i)  := CASE WHEN TO_CHAR(v_d, 'MM-DD') IN ('01-01','12-25','12-26')",
            "                  THEN 'Y' ELSE 'N' END;",
            "a_trade(i):= CASE WHEN a_hol(i) = 'Y' THEN 'N' ELSE 'Y' END;",
            "a_season(i) := CASE",
            "                  WHEN EXTRACT(MONTH FROM v_d) IN (11, 12) THEN 'PEAK'",
            "                  WHEN EXTRACT(MONTH FROM v_d) IN (1, 2)   THEN 'CLEARANCE'",
            "                  WHEN EXTRACT(MONTH FROM v_d) IN (6, 7, 8) THEN 'SUMMER'",
            "                  ELSE 'CORE'",
            "               END;",
        ),
        columns=("day_date", "fiscal_year", "fiscal_period", "fiscal_week",
                 "day_of_week", "is_trading_day", "is_public_holiday", "season_code"),
        values=("a_day(i)", "a_fy(i)", "a_fp(i)", "a_fw(i)", "a_dow(i)",
                "a_trade(i)", "a_hol(i)", "a_season(i)"),
    ))

    # ---- tax_rate --------------------------------------------------------
    parts.append("\nPROMPT tax_rate")
    parts.append(bulk_block(
        table="tax_rate", rows=plan["tax_rate"], seed=seed + 3, batch=batch,
        comment=scenario_note(
            "Four tax codes per country, each with one validity window, so the",
            "UNIQUE (country_code, tax_code, valid_from) holds and the",
            "CHECK (valid_to IS NULL OR valid_to > valid_from) is satisfied.",
            "Half the rows have an open-ended valid_to, which is what the",
            "per-country tax functions fall back on."),
        varrays=(("v_code", ("STD", "RED", "ZER", "EXE")),),
        arrays=(
            ("a_id", "NUMBER"), ("a_cc", "VARCHAR2(2)"), ("a_code", "VARCHAR2(20)"),
            ("a_pct", "NUMBER"), ("a_from", "DATE"), ("a_to", "DATE"),
        ),
        decls=_plsql_country_varrays() + ["v_ci PLS_INTEGER;", "v_ki PLS_INTEGER;"],
        fill=(
            "v_ci := MOD(v_r - 1, 40) + 1;",
            "v_ki := TRUNC((v_r - 1) / 40) + 1;",
            "a_id(i)   := v_r;",
            "a_cc(i)   := v_cc(v_ci);",
            "a_code(i) := v_code(v_ki);",
            "a_pct(i)  := CASE v_ki WHEN 1 THEN 15 + MOD(v_ci, 13)",
            "                       WHEN 2 THEN 5 + MOD(v_ci, 8)",
            "                       ELSE 0 END;",
            "a_from(i) := %s;" % dt("2019-01-01"),
            "-- Open-ended on the odd rows. A NULL valid_to is 'still in force', and",
            "-- every rate-lookup query in the schema has to cope with it.",
            "a_to(i)   := CASE WHEN MOD(v_r, 2) = 0 THEN %s ELSE NULL END;"
            % dt("2031-01-01"),
        ),
        columns=("tax_rate_id", "country_code", "tax_code", "rate_pct",
                 "valid_from", "valid_to"),
        values=("a_id(i)", "a_cc(i)", "a_code(i)", "a_pct(i)", "a_from(i)", "a_to(i)"),
    ))

    # ---- loyalty_tier (nested table column) ------------------------------
    parts.append("\nPROMPT loyalty_tier (nested table column, H-05)")
    tiers = (
        ("BRONZE", "Bronze", 0, "0", "1", 12),
        ("SILVER", "Silver", 2500, "2.5", "1.25", 12),
        ("GOLD", "Gold", 10000, "5", "1.5", 12),
        ("PLATINUM", "Platinum", 40000, "7.5", "2", 24),
        ("BLACK", "Contoso Black", 150000, "10", "3", 24),
    )
    tier_sql = [
        "-- HARD CASE H-05: benefits is a NESTED TABLE of t_loyalty_benefit stored in",
        "-- loyalty_benefit_ntab. An array of composites keeps the shape but makes the",
        "-- data unqueryable without unnest; a child table is the right answer and",
        "-- changes every statement that touches it. The tool cannot make that call.",
    ]
    for code, tname, minp, disc, mult, months in tiers:
        tier_sql.append("INSERT INTO loyalty_tier")
        tier_sql.append("       (tier_code, tier_name, min_points, discount_pct,")
        tier_sql.append("        points_multiplier, benefits, review_interval)")
        tier_sql.append("VALUES (%s, %s, %d, %s, %s," % (q(code), q(tname), minp, disc, mult))
        tier_sql.append("        t_benefit_tab(")
        tier_sql.append("           t_loyalty_benefit('FREE_DELIV', 'Free delivery',")
        tier_sql.append("                             %s, DATE '2024-01-01', NULL)," % mult)
        tier_sql.append("           t_loyalty_benefit('BIRTHDAY', 'Birthday reward',")
        tier_sql.append("                             %s, DATE '2024-01-01', DATE '2027-01-01')," % disc)
        tier_sql.append("           t_loyalty_benefit('EARLY_SALE', 'Early sale access',")
        tier_sql.append("                             1, DATE '2024-01-01', NULL)),")
        tier_sql.append("        INTERVAL '%d' MONTH);" % months)
    tier_sql.append("COMMIT;")
    parts.append("\n".join(tier_sql))

    # ---- carrier (VARRAY column) -----------------------------------------
    parts.append("\nPROMPT carrier (VARRAY column, H-04)")
    carriers = (
        ("DPD", "DPD Group", "0 18:00:00"), ("DHL", "DHL Express", "0 17:30:00"),
        ("UPS", "United Parcel Service", "0 19:00:00"), ("FEDEX", "FedEx", "0 18:30:00"),
        ("ROYALMAIL", "Royal Mail", "0 16:00:00"), ("ANPOST", "An Post", "0 16:30:00"),
        ("COLISSIMO", "Colissimo", "0 17:00:00"), ("DHLDE", "DHL Paket", "0 18:00:00"),
        ("CORREOS", "Correos", "0 15:30:00"), ("POSTNORD", "PostNord", "0 16:45:00"),
        ("CONTOSOVAN", "Contoso own fleet", "0 20:00:00"),
        ("LOCALCOUR", "Local courier pool", "0 21:30:00"),
    )
    car_sql = [
        "-- HARD CASE H-04: service_levels is a VARRAY(10). PostgreSQL arrays are",
        "-- unbounded, so the declared maximum is lost unless a CHECK on",
        "-- array_length() is added. Oracle collections are also 1-based and dense,",
        "-- and any code using .COUNT / .LIMIT / .EXTEND needs rewriting.",
    ]
    for code, cname, cutoff in carriers:
        car_sql.append("INSERT INTO carrier")
        car_sql.append("       (carrier_code, carrier_name, service_levels,")
        car_sql.append("        tracking_url_template, cutoff_offset, is_active)")
        car_sql.append("VALUES (%s, %s," % (q(code), q(cname)))
        car_sql.append("        t_service_varr('NEXT_DAY', 'STANDARD', 'ECONOMY', 'SAME_DAY'),")
        car_sql.append("        %s," % q("https://track.example.invalid/" + code.lower() + "/{ref}"))
        car_sql.append("        INTERVAL '%s' DAY TO SECOND, 'Y');" % cutoff)
    car_sql.append("COMMIT;")
    parts.append("\n".join(car_sql))

    # ---- return_reason ---------------------------------------------------
    parts.append("\nPROMPT return_reason (index-organized table)")
    reasons = (
        ("DAMAGED", "Arrived damaged", "QUALITY", "N", "Y"),
        ("FAULTY", "Faulty in use", "QUALITY", "N", "Y"),
        ("WRONG_ITEM", "Wrong item shipped", "FULFILMENT", "Y", "N"),
        ("WRONG_SIZE", "Wrong size", "FIT", "Y", "N"),
        ("TOO_SMALL", "Too small", "FIT", "Y", "N"),
        ("TOO_LARGE", "Too large", "FIT", "Y", "N"),
        ("NOT_AS_DESC", "Not as described", "EXPECTATION", "Y", "N"),
        ("CHANGED_MIND", "Changed mind", "EXPECTATION", "Y", "N"),
        ("LATE", "Arrived too late", "FULFILMENT", "Y", "N"),
        ("DUPLICATE", "Duplicate order", "ORDERING", "Y", "N"),
        ("PRICE_MATCH", "Found cheaper elsewhere", "PRICING", "Y", "N"),
        ("GIFT_RETURN", "Unwanted gift", "EXPECTATION", "Y", "N"),
        ("MISSING_PART", "Parts missing", "QUALITY", "N", "Y"),
        ("EXPIRED", "Past best before", "QUALITY", "N", "Y"),
        ("RECALL", "Product recall", "SAFETY", "N", "Y"),
        ("ALLERGEN", "Allergen labelling", "SAFETY", "N", "Y"),
        ("COLOUR", "Colour not as shown", "EXPECTATION", "Y", "N"),
        ("QUALITY_LOW", "Quality below expectation", "QUALITY", "Y", "N"),
        ("DELIVERY_DMG", "Damaged in transit", "FULFILMENT", "N", "Y"),
        ("NEVER_ARRIVED", "Never arrived", "FULFILMENT", "N", "Y"),
        ("WARRANTY", "Warranty claim", "QUALITY", "N", "Y"),
        ("TRADE_IN", "Trade-in return", "COMMERCIAL", "Y", "Y"),
        ("BULK_REJECT", "Bulk order rejected", "COMMERCIAL", "Y", "Y"),
        ("OTHER", "Other", "OTHER", "Y", "Y"),
    )
    parts.extend(insert_all(
        "return_reason",
        ("reason_code", "reason_desc", "reason_group", "is_restockable",
         "requires_approval"),
        [(q(a), q(b), q(c), q(d), q(e)) for a, b, c, d, e in reasons]))

    # ---- app_parameter ---------------------------------------------------
    parts.append("\nPROMPT app_parameter (index-organized table)")
    params: List[Tuple[str, str, str, str]] = [
        ("BASE_CURRENCY", "GBP", "STRING", "Reporting currency for the group ledger"),
        ("FISCAL_YEAR_START", "2024-01-01", "DATE", "First day of the fiscal calendar"),
        ("POINTS_PER_UNIT", "1", "NUMBER", "Loyalty points accrued per currency unit"),
        ("POINTS_EXPIRY_MONTHS", "24", "NUMBER", "Months before unused points expire"),
        ("RECEIPT_TOLERANCE_PCT", "5", "NUMBER", "Goods receipt over-delivery tolerance"),
        ("PRICE_ROUNDING", "0.05", "NUMBER", "Shelf-edge rounding increment"),
        ("VPD_ENABLED", "TRUE", "BOOLEAN", "Row-level security master switch"),
        ("AUDIT_RETENTION_DAYS", "2555", "NUMBER", "Seven years of audit trail"),
        ("EXPORT_DIR", "CONTOSO_EXPORT_DIR", "STRING", "UTL_FILE directory object (H-13)"),
        ("DQ_SEVERITY_FLOOR", "WARN", "STRING", "Lowest severity recorded by the scanner"),
        ("REPLEN_LOOKBACK_DAYS", "56", "NUMBER", "Demand history window for replenishment"),
        ("PICK_BATCH_SIZE", "250", "NUMBER", "Rows claimed per FOR UPDATE SKIP LOCKED pass"),
    ]
    for sysc in SYSTEM_CODES:
        params.append((sysc + "_SOURCE_TABLE", "product_variant", "STRING",
                       "Dynamic SQL source for the " + sysc + " bridge (H-11)"))
    for theme in RULE_THEME_CODES:
        params.append(("RULE_PRED_" + theme, "unit_price > 0", "STRING",
                       "Rule predicate text executed with EXECUTE IMMEDIATE (H-11)"))
    params.append(("EMPTY_STRING_PROBE", "", "STRING",
                   "Deliberately '' -- Oracle stores NULL here (H-38)"))
    params.append(("UNICODE_PROBE", "Ünïcödé — 山田 — Ελένη", "STRING",
                   "Multi-byte probe for VARCHAR2 byte semantics (T-03)"))
    params.append(("NULL_PROBE", None, "STRING",
                   "Explicit NULL, to sit beside EMPTY_STRING_PROBE"))
    params = params[:plan["app_parameter"]]
    parts.extend(insert_all(
        "app_parameter",
        ("param_name", "param_value", "param_type", "description",
         "is_encrypted", "updated_ts", "updated_by"),
        [(q(n), ("NULL" if v is None else q(v)), q(t), q(d), q("N"),
          "SYSTIMESTAMP", q("SEED_LOAD"))
         for n, v, t, d in params]))

    # ---- gl_account ------------------------------------------------------
    parts.append("\nPROMPT gl_account (chart of accounts, hierarchy 4)")
    parts.append("\n".join([
        "-- HARD CASE H-06: this is the fourth self-referencing tree in the schema.",
        "-- v_gl_trial_balance walks it bottom-up with ORDER SIBLINGS BY, which is the",
        "-- CONNECT BY pseudo-column with no PostgreSQL equivalent at all.",
        "-- Four levels: 5 roots -> 25 -> 50 -> 100 postable leaves = 180 accounts.",
        "--",
        "-- code_of and bal_of are declared local to this anonymous block, and PL/SQL",
        "-- refuses (PLS-00231) to resolve a locally declared function from inside a SQL",
        "-- statement -- so every call has to be made in PL/SQL and land in a local",
        "-- before the INSERT can use it. That is the same restriction pkg_catalog runs",
        "-- into in 07-packages.sql, and it is worth seeing twice: PostgreSQL has no",
        "-- local functions at all, so a converter has to promote both of these to",
        "-- schema-level functions, at which point the inlining becomes legal again.",
        "DECLARE",
        "   TYPE t_str_varr IS VARRAY(8) OF VARCHAR2(20);",
        "   v_type t_str_varr := t_str_varr('ASSET','LIABILITY','EQUITY',",
        "                                   'REVENUE','EXPENSE');",
        "   v_r PLS_INTEGER; v_s PLS_INTEGER; v_t PLS_INTEGER; v_u PLS_INTEGER;",
        "   v_code   VARCHAR2(20);",
        "   v_parent VARCHAR2(20);",
        "   v_bal    VARCHAR2(1);",
        "   FUNCTION code_of(p_r PLS_INTEGER, p_s PLS_INTEGER,",
        "                    p_t PLS_INTEGER, p_u PLS_INTEGER) RETURN VARCHAR2 IS",
        "   BEGIN",
        "      RETURN TO_CHAR(p_r * 10000 + NVL(p_s,0) * 1000",
        "                     + NVL(p_t,0) * 100 + NVL(p_u,0) * 10);",
        "   END code_of;",
        "   FUNCTION bal_of(p_r PLS_INTEGER) RETURN VARCHAR2 IS",
        "   BEGIN",
        "      RETURN CASE WHEN p_r IN (1, 5) THEN 'D' ELSE 'C' END;",
        "   END bal_of;",
        "BEGIN",
        "   FOR r IN 1 .. 5 LOOP",
        "      v_code := code_of(r, NULL, NULL, NULL);",
        "      v_bal  := bal_of(r);",
        "      INSERT INTO gl_account (account_code, account_name, account_type,",
        "                              parent_account_code, is_postable,",
        "                              normal_balance, currency_code)",
        "      VALUES (v_code,",
        "              INITCAP(v_type(r)) || ' control',",
        "              v_type(r), NULL, 'N', v_bal, 'GBP');",
        "   END LOOP;",
        "",
        "   FOR j IN 1 .. 25 LOOP",
        "      v_r := 1 + MOD(j - 1, 5);",
        "      v_s := 1 + TRUNC((j - 1) / 5);",
        "      v_code   := code_of(v_r, v_s, NULL, NULL);",
        "      v_parent := code_of(v_r, NULL, NULL, NULL);",
        "      v_bal    := bal_of(v_r);",
        "      INSERT INTO gl_account (account_code, account_name, account_type,",
        "                              parent_account_code, is_postable,",
        "                              normal_balance, currency_code)",
        "      VALUES (v_code,",
        "              INITCAP(v_type(v_r)) || ' group ' || v_s,",
        "              v_type(v_r), v_parent,",
        "              'N', v_bal, 'GBP');",
        "   END LOOP;",
        "",
        "   FOR k IN 1 .. 50 LOOP",
        "      v_r := 1 + MOD(k - 1, 5);",
        "      v_s := 1 + TRUNC(MOD(k - 1, 25) / 5);",
        "      v_t := 1 + TRUNC((k - 1) / 25);",
        "      v_code   := code_of(v_r, v_s, v_t, NULL);",
        "      v_parent := code_of(v_r, v_s, NULL, NULL);",
        "      v_bal    := bal_of(v_r);",
        "      INSERT INTO gl_account (account_code, account_name, account_type,",
        "                              parent_account_code, is_postable,",
        "                              normal_balance, currency_code)",
        "      VALUES (v_code,",
        "              INITCAP(v_type(v_r)) || ' class ' || v_s || '.' || v_t,",
        "              v_type(v_r), v_parent,",
        "              'N', v_bal, 'GBP');",
        "   END LOOP;",
        "",
        "   FOR m IN 1 .. 100 LOOP",
        "      v_r := 1 + MOD(m - 1, 5);",
        "      v_s := 1 + MOD(TRUNC((m - 1) / 5), 5);",
        "      v_t := 1 + MOD(TRUNC((m - 1) / 25), 2);",
        "      v_u := 1 + MOD(TRUNC((m - 1) / 50), 2);",
        "      v_code   := code_of(v_r, v_s, v_t, v_u);",
        "      v_parent := code_of(v_r, v_s, v_t, NULL);",
        "      v_bal    := bal_of(v_r);",
        "      INSERT INTO gl_account (account_code, account_name, account_type,",
        "                              parent_account_code, is_postable,",
        "                              normal_balance, currency_code)",
        "      VALUES (v_code,",
        "              INITCAP(v_type(v_r)) || ' account '",
        "              || v_s || '.' || v_t || '.' || v_u,",
        "              v_type(v_r), v_parent,",
        "              'Y', v_bal, 'GBP');",
        "   END LOOP;",
        "",
        "   COMMIT;",
        "   DBMS_OUTPUT.PUT_LINE('gl_account: 180 rows');",
        "END;",
        "/",
    ]))

    # ---- gl_period -------------------------------------------------------
    parts.append("\nPROMPT gl_period")
    parts.append("\n".join([
        "DECLARE",
        "   v_year  PLS_INTEGER;",
        "   v_pno   PLS_INTEGER;",
        "   v_start DATE;",
        "BEGIN",
        "   FOR p IN 1 .. %d LOOP" % plan["gl_period"],
        "      v_year  := 2024 + TRUNC((p - 1) / 12);",
        "      v_pno   := 1 + MOD(p - 1, 12);",
        "      v_start := TO_DATE(TO_CHAR(v_year) || LPAD(TO_CHAR(v_pno), 2, '0')",
        "                         || '01', 'YYYYMMDD');",
        "      INSERT INTO gl_period (period_id, fiscal_year, period_no,",
        "                             period_start, period_end, status, closed_ts)",
        "      VALUES (p, v_year, v_pno, v_start,",
        "              LAST_DAY(v_start),",
        "              CASE WHEN v_start < ADD_MONTHS(TRUNC(SYSDATE, 'MM'), -1)",
        "                   THEN 'CLOSED'",
        "                   WHEN v_start < TRUNC(SYSDATE, 'MM') THEN 'CLOSING'",
        "                   WHEN v_start = TRUNC(SYSDATE, 'MM') THEN 'OPEN'",
        "                   ELSE 'FUTURE' END,",
        "              CASE WHEN v_start < ADD_MONTHS(TRUNC(SYSDATE, 'MM'), -1)",
        "                   THEN CAST(LAST_DAY(v_start) AS TIMESTAMP) END);",
        "   END LOOP;",
        "   COMMIT;",
        "   DBMS_OUTPUT.PUT_LINE('gl_period: %d rows');" % plan["gl_period"],
        "END;",
        "/",
    ]))

    return "\n\n".join(parts)


# --------------------------------------------------------------------------
# 03 -- geography: region tree, addresses, warehouses, stores
# --------------------------------------------------------------------------

def file_geography(plan: Dict[str, int], seed: int, batch: int) -> str:
    parts: List[str] = ["PROMPT === geography ==="]

    parts.append("\nPROMPT region (5-level self-referencing tree, hierarchy 1)")
    parts.append(bulk_block(
        table="region", rows=plan["region"], seed=seed + 10, batch=batch,
        comment=scenario_note(
            "GLOBAL -> AREA -> COUNTRY -> DISTRICT -> CLUSTER, 1 + 4 + 40 + 120 + 360.",
            "Parents are always emitted before children because parent_region_id is",
            "always a smaller region_id, which is what lets a single FORALL load a",
            "self-referencing tree without deferring the constraint.",
            "manager_employee_id is left NULL here and back-filled in 04 -- that is the",
            "circular foreign key from design.md 4.2."),
        arrays=(
            ("a_id", "NUMBER"), ("a_code", "VARCHAR2(20)"), ("a_name", "VARCHAR2(100)"),
            ("a_cc", "VARCHAR2(2)"), ("a_parent", "NUMBER"), ("a_level", "VARCHAR2(20)"),
        ),
        decls=_plsql_country_varrays() + ["v_ci PLS_INTEGER;", "v_p PLS_INTEGER;"],
        fill=(
            "a_id(i) := v_r;",
            "IF v_r = 1 THEN",
            "   a_level(i) := 'GLOBAL'; a_parent(i) := NULL; v_ci := 1;",
            "ELSIF v_r <= 5 THEN",
            "   a_level(i) := 'AREA';    a_parent(i) := 1;",
            "   v_ci := 1 + MOD(v_r - 2, 40);",
            "ELSIF v_r <= 45 THEN",
            "   a_level(i) := 'COUNTRY'; a_parent(i) := 2 + MOD(v_r - 6, 4);",
            "   v_ci := v_r - 5;",
            "ELSIF v_r <= 165 THEN",
            "   v_p := MOD(v_r - 46, 40);",
            "   a_level(i) := 'DISTRICT'; a_parent(i) := 6 + v_p;",
            "   v_ci := v_p + 1;",
            "ELSE",
            "   v_p := MOD(v_r - 166, 120);",
            "   a_level(i) := 'CLUSTER';  a_parent(i) := 46 + v_p;",
            "   v_ci := 1 + MOD(v_p, 40);",
            "END IF;",
            "a_cc(i)   := v_cc(v_ci);",
            "a_code(i) := 'RG' || LPAD(TO_CHAR(v_r), 6, '0');",
            "a_name(i) := INITCAP(a_level(i)) || ' ' || a_cc(i) || ' ' || v_r;",
        ),
        columns=("region_id", "region_code", "region_name", "country_code",
                 "parent_region_id", "region_level"),
        values=("a_id(i)", "a_code(i)", "a_name(i)", "a_cc(i)",
                "a_parent(i)", "a_level(i)"),
    ))

    parts.append("\nPROMPT address")
    parts.append(bulk_block(
        table="address", rows=plan["address"], seed=seed + 11, batch=batch,
        comment=scenario_note(
            "The shared address book for stores, warehouses, suppliers and customers.",
            "normalised_key is a VIRTUAL column (H-17) and carries a unique",
            "function-based index, so line1/city/country_code must not collide -- the",
            "row number is folded into line1 to guarantee that.",
            "line2 is empty one row in nine. In Oracle that lands as NULL (H-38);",
            "after conversion it is a zero-length string and every IS NULL predicate",
            "over it changes answer without raising anything.",
            "geo_json is a CLOB (H-34)."),
        varrays=(("v_city", CITIES), ("v_street", STREETS)),
        arrays=(
            ("a_id", "NUMBER"), ("a_l1", "VARCHAR2(120)"), ("a_l2", "VARCHAR2(120)"),
            ("a_city", "VARCHAR2(80)"), ("a_state", "VARCHAR2(80)"),
            ("a_post", "VARCHAR2(20)"), ("a_cc", "VARCHAR2(2)"),
            ("a_lat", "NUMBER"), ("a_lon", "NUMBER"), ("a_geo", "VARCHAR2(400)"),
        ),
        decls=_plsql_country_varrays(),
        fill=(
            "a_id(i)   := v_r;",
            "a_l1(i)   := TO_CHAR(1 + nxt(240)) || ' ' || pick(v_street)",
            "             || ' #' || TO_CHAR(v_r);",
            "-- MIGRATION HAZARD H-38: '' is NULL in Oracle, a value in PostgreSQL.",
            "a_l2(i)   := CASE MOD(v_r, 9)",
            "                WHEN 0 THEN ''",
            "                WHEN 3 THEN NULL",
            "                ELSE 'Floor ' || TO_CHAR(1 + MOD(v_r, 12))",
            "             END;",
            "a_city(i) := pick(v_city);",
            "a_state(i):= maybe('Region ' || TO_CHAR(1 + nxt(20)), 4);",
            "a_post(i) := maybe(UPPER(SUBSTR(a_city(i), 1, 2))",
            "                   || TO_CHAR(10000 + nxt(89999)), 12);",
            "a_cc(i)   := v_cc(1 + MOD(v_r - 1, 40));",
            "a_lat(i)  := ROUND(-56 + nxt(1200) / 10, 6);",
            "a_lon(i)  := ROUND(-120 + nxt(2400) / 10, 6);",
            "a_geo(i)  := '{\"type\":\"Point\",\"coordinates\":['",
            "             || TO_CHAR(a_lon(i)) || ',' || TO_CHAR(a_lat(i)) || ']}';",
        ),
        columns=("address_id", "line1", "line2", "city", "state_province",
                 "postal_code", "country_code", "latitude", "longitude", "geo_json"),
        values=("a_id(i)", "a_l1(i)", "a_l2(i)", "a_city(i)", "a_state(i)",
                "a_post(i)", "a_cc(i)", "a_lat(i)", "a_lon(i)", "a_geo(i)"),
    ))

    parts.append("\nPROMPT warehouse")
    parts.append(bulk_block(
        table="warehouse", rows=plan["warehouse"], seed=seed + 12, batch=batch,
        comment=scenario_note(
            "Three warehouses per trading country (design.md section 4).",
            "region_id points at the COUNTRY level of the tree, ids 6..45."),
        arrays=(
            ("a_id", "NUMBER"), ("a_code", "VARCHAR2(12)"), ("a_name", "VARCHAR2(120)"),
            ("a_region", "NUMBER"), ("a_addr", "NUMBER"), ("a_cap", "NUMBER"),
        ),
        decls=_plsql_country_varrays() + ["v_ci PLS_INTEGER;"],
        fill=(
            "v_ci := 1 + MOD(v_r - 1, 40);",
            "a_id(i)     := v_r;",
            "a_code(i)   := 'WH' || v_cc(v_ci) || LPAD(TO_CHAR(v_r), 6, '0');",
            "a_name(i)   := v_cc(v_ci) || ' distribution centre '",
            "               || TO_CHAR(1 + TRUNC((v_r - 1) / 40));",
            "a_region(i) := 5 + v_ci;",
            "a_addr(i)   := 1 + MOD(v_r - 1, %d);" % plan["address"],
            "a_cap(i)    := 4000 + nxt(46000);",
        ),
        columns=("warehouse_id", "warehouse_code", "warehouse_name", "region_id",
                 "address_id", "capacity_pallets", "is_active"),
        values=("a_id(i)", "a_code(i)", "a_name(i)", "a_region(i)", "a_addr(i)",
                "a_cap(i)", "'Y'"),
    ))

    parts.append("\nPROMPT store")
    parts.append(bulk_block(
        table="store", rows=plan["store"], seed=seed + 13, batch=batch,
        comment=scenario_note(
            "The store estate, hung off the CLUSTER level of the region tree.",
            "opening_offset / closing_offset are INTERVAL DAY TO SECOND and",
            "refit_cycle is INTERVAL YEAR TO MONTH -- two Oracle interval families that",
            "cannot be mixed, collapsing to one PostgreSQL interval type (H-36).",
            "closing_offset exceeds 24 hours on some rows on purpose, so a 25-hour",
            "Sunday during a DST fold stays representable.",
            "legacy_migration_notes is the schema's only LONG column and is NOT loaded",
            "here: LONG cannot be bulk-bound. 14-data-messy-edge-cases.sql fills a few",
            "rows with single-row UPDATEs, which is the only thing that works (H-33).",
            "manager_employee_id is back-filled in 04 (circular FK, design.md 4.2)."),
        varrays=(("v_fmt", ("HYPER", "SUPER", "EXPRESS", "OUTLET", "ONLINE")),),
        arrays=(
            ("a_id", "NUMBER"), ("a_code", "VARCHAR2(12)"), ("a_name", "VARCHAR2(120)"),
            ("a_region", "NUMBER"), ("a_addr", "NUMBER"), ("a_fmt", "VARCHAR2(20)"),
            ("a_open", "DATE"), ("a_closed", "DATE"), ("a_area", "NUMBER"),
            ("a_openoff", "INTERVAL DAY(0) TO SECOND(0)"),
            ("a_closeoff", "INTERVAL DAY(0) TO SECOND(0)"),
            ("a_refit", "INTERVAL YEAR(2) TO MONTH"),
        ),
        decls=("v_open_h PLS_INTEGER;", "v_close_h PLS_INTEGER;"),
        fill=(
            "a_id(i)     := v_r;",
            "a_code(i)   := 'ST' || LPAD(TO_CHAR(v_r), 8, '0');",
            "a_name(i)   := 'Contoso ' || pick(v_fmt) || ' ' || TO_CHAR(v_r);",
            "a_region(i) := 166 + MOD(v_r - 1, 360);",
            "a_addr(i)   := 1 + MOD(v_r * 7 - 1, %d);" % plan["address"],
            "a_fmt(i)    := pick(v_fmt);",
            "a_open(i)   := %s + nxt(9000);" % dt("1996-01-01"),
            "-- One store in twenty-five is closed, so is_active-style predicates and",
            "-- LEFT JOINs against the estate have something to exclude.",
            "a_closed(i) := CASE WHEN MOD(v_r, 25) = 0",
            "                    THEN a_open(i) + 3000 + nxt(2000) END;",
            "a_area(i)   := ROUND(120 + nxt(11000) + nxt(100) / 100, 2);",
            "v_open_h    := 6 + nxt(4);",
            "v_close_h   := 19 + nxt(4);",
            "a_openoff(i)  := NUMTODSINTERVAL(v_open_h * 3600, 'SECOND');",
            "-- Kept strictly under 24 hours. INTERVAL DAY(0) TO SECOND(0) has ZERO",
            "-- digits of day precision, so Oracle normalising 25 hours into",
            "-- \'1 day 1 hour\' would raise ORA-01873. The 25-hour DST Sunday shows up",
            "-- as (closing_offset - opening_offset) being shorter than the wall-clock",
            "-- elapsed time, not as an offset past midnight.",
            "a_closeoff(i) := NUMTODSINTERVAL(",
            "                    LEAST(v_close_h + CASE WHEN MOD(v_r, 11) = 0 THEN 1",
            "                                           ELSE 0 END, 23) * 3600, 'SECOND');",
            "a_refit(i)    := NUMTOYMINTERVAL(3 + MOD(v_r, 6), 'YEAR');",
        ),
        columns=("store_id", "store_code", "store_name", "region_id", "address_id",
                 "store_format", "opened_date", "closed_date", "selling_area_sqm",
                 "opening_offset", "closing_offset", "refit_cycle", "created_ts"),
        values=("a_id(i)", "a_code(i)", "a_name(i)", "a_region(i)", "a_addr(i)",
                "a_fmt(i)", "a_open(i)", "a_closed(i)", "a_area(i)",
                "a_openoff(i)", "a_closeoff(i)", "a_refit(i)", "SYSTIMESTAMP"),
    ))

    return "\n\n".join(parts)


# --------------------------------------------------------------------------
# 04 -- employees and the circular foreign keys
# --------------------------------------------------------------------------

def file_employees(plan: Dict[str, int], seed: int, batch: int) -> str:
    parts: List[str] = ["PROMPT === employees ==="]

    parts.append("\nPROMPT employee (self-referencing management line, hierarchy 2)")
    parts.append(bulk_block(
        table="employee", rows=plan["employee"], seed=seed + 20, batch=batch,
        comment=scenario_note(
            "A real reporting line, not a flat list. employee 1 is the chief executive",
            "with a NULL manager; everyone else reports to TRUNC(id / fanout) where the",
            "fanout varies by id, which gives a RAGGED tree of depth ~5 to ~8 depending",
            "on scale. Ragged matters: LEVEL and CONNECT_BY_ROOT are only interesting",
            "when the depth is not uniform (H-06).",
            "manager_id is always strictly less than employee_id, so one FORALL loads",
            "the whole tree without a deferred constraint.",
            "full_name and is_active are VIRTUAL columns (H-17) and are not loaded."),
        varrays=(
            ("v_first", FIRST_NAMES[:46]),
            ("v_last", LAST_NAMES[:38]),
            ("v_job", ("Store manager", "Assistant manager", "Team leader",
                       "Sales assistant", "Stock controller", "Buyer",
                       "Merchandiser", "Finance analyst", "Warehouse operative",
                       "Regional director", "Data engineer", "Chief executive")),
        ),
        arrays=(
            ("a_id", "NUMBER"), ("a_num", "VARCHAR2(20)"), ("a_first", "VARCHAR2(60)"),
            ("a_last", "VARCHAR2(60)"), ("a_email", "VARCHAR2(150)"),
            ("a_store", "NUMBER"), ("a_mgr", "NUMBER"), ("a_job", "VARCHAR2(60)"),
            ("a_hire", "DATE"), ("a_term", "DATE"), ("a_sal", "NUMBER"),
            ("a_ccy", "VARCHAR2(3)"),
        ),
        decls=("v_fanout PLS_INTEGER;",),
        fill=(
            "a_id(i)    := v_r;",
            "a_num(i)   := 'EMP' || LPAD(TO_CHAR(v_r), 9, '0');",
            "a_first(i) := pick(v_first);",
            "a_last(i)  := pick(v_last);",
            "-- Unicode in the name, ASCII in the email: exactly what a real HR feed",
            "-- looks like, and what makes LOWER(email) safe to index but not the name.",
            "a_email(i) := maybe('emp' || TO_CHAR(v_r) || '@contoso.invalid', 15);",
            "a_store(i) := CASE WHEN MOD(v_r, 7) = 0 THEN NULL",
            "                   ELSE 1 + MOD(v_r - 1, %d) END;" % plan["store"],
            "v_fanout   := 3 + MOD(v_r, 3);",
            "a_mgr(i)   := CASE WHEN v_r = 1 THEN NULL",
            "                   ELSE GREATEST(1, TRUNC(v_r / v_fanout)) END;",
            "a_job(i)   := CASE WHEN v_r = 1 THEN 'Chief executive' ELSE pick(v_job) END;",
            "a_hire(i)  := %s + nxt(9000);" % dt("1999-01-01"),
            "-- One in twelve has left. termination_date drives the is_active virtual",
            "-- column, which is the one virtual column that survives conversion intact.",
            "a_term(i)  := CASE WHEN MOD(v_r, 12) = 0",
            "                   THEN a_hire(i) + 400 + nxt(4000) END;",
            "a_sal(i)   := maybe_n(ROUND(21000 + nxt(90000) + nxt(100) / 100, 2), 20);",
            "a_ccy(i)   := CASE WHEN a_sal(i) IS NULL THEN NULL ELSE 'GBP' END;",
        ),
        columns=("employee_id", "employee_number", "first_name", "last_name", "email",
                 "store_id", "manager_id", "job_title", "hire_date",
                 "termination_date", "salary_amount", "salary_currency"),
        values=("a_id(i)", "a_num(i)", "a_first(i)", "a_last(i)", "a_email(i)",
                "a_store(i)", "a_mgr(i)", "a_job(i)", "a_hire(i)", "a_term(i)",
                "a_sal(i)", "a_ccy(i)"),
    ))

    parts.append("\n".join([
        "",
        "PROMPT circular foreign keys (design.md 4.2)",
        "-- region.manager_employee_id -> employee, and employee.store_id -> store ->",
        "-- region, form a cycle. Oracle tolerates it because src/oracle/03-constraints.sql",
        "-- applies the constraints after every table exists, and this loader closes",
        "-- the loop after both sides are populated. PostgreSQL tolerates the cycle too,",
        "-- but naive converters emit the DDL in dependency order and deadlock on it.",
        "UPDATE region",
        "   SET manager_employee_id = 1 + MOD(region_id * 3, %d)" % plan["employee"],
        " WHERE region_level IN ('COUNTRY', 'DISTRICT', 'CLUSTER');",
        "COMMIT;",
        "",
        "-- Some stores genuinely have no manager. Note the comment sits above the",
        "-- statement: an inline '--' placed after the terminating semicolon does not",
        "-- end the statement in SQL*Plus, it leaves the buffer open and swallows the",
        "-- following line (the COMMIT), and the whole buffer then fails to parse.",
        "UPDATE store",
        "   SET manager_employee_id = 1 + MOD(store_id * 5, %d)" % plan["employee"],
        " WHERE MOD(store_id, 8) <> 0;",
        "COMMIT;",
    ]))

    return "\n\n".join(parts)


# --------------------------------------------------------------------------
# 05 -- product catalogue
# --------------------------------------------------------------------------

def file_catalog(plan: Dict[str, int], seed: int, batch: int) -> str:
    n_prod = plan["product"]
    n_brand = plan["brand"]
    parts: List[str] = ["PROMPT === product catalogue ==="]

    parts.append("\nPROMPT product_category (4-level merchandise tree, hierarchy 3)")
    parts.append(bulk_block(
        table="product_category", rows=plan["product_category"], seed=seed + 30,
        batch=batch,
        comment=scenario_note(
            "Division -> department -> class -> subclass: 6 + 24 + 72 + 144 = 246.",
            "Only level 4 is a leaf, and products hang off leaves only, which is what",
            "makes SYS_CONNECT_BY_PATH over this tree produce a full merchandise path",
            "rather than a stump (H-06)."),
        varrays=(("v_div", ("APPAREL", "FOOD", "DRINK", "HOME", "GENMDSE", "TECH")),),
        arrays=(
            ("a_id", "NUMBER"), ("a_code", "VARCHAR2(30)"), ("a_name", "VARCHAR2(120)"),
            ("a_parent", "NUMBER"), ("a_level", "NUMBER"), ("a_leaf", "VARCHAR2(1)"),
            ("a_sort", "NUMBER"),
        ),
        fill=(
            "a_id(i) := v_r;",
            "IF v_r <= 6 THEN",
            "   a_level(i) := 1; a_parent(i) := NULL;",
            "   a_name(i) := INITCAP(v_div(v_r)) || ' division';",
            "ELSIF v_r <= 30 THEN",
            "   a_level(i) := 2; a_parent(i) := 1 + MOD(v_r - 7, 6);",
            "   a_name(i) := 'Department ' || TO_CHAR(v_r - 6);",
            "ELSIF v_r <= 102 THEN",
            "   a_level(i) := 3; a_parent(i) := 7 + MOD(v_r - 31, 24);",
            "   a_name(i) := 'Class ' || TO_CHAR(v_r - 30);",
            "ELSE",
            "   a_level(i) := 4; a_parent(i) := 31 + MOD(v_r - 103, 72);",
            "   a_name(i) := 'Subclass ' || TO_CHAR(v_r - 102);",
            "END IF;",
            "a_leaf(i) := CASE WHEN a_level(i) = 4 THEN 'Y' ELSE 'N' END;",
            "a_code(i) := 'CAT' || LPAD(TO_CHAR(v_r), 6, '0');",
            "a_sort(i) := v_r * 10;",
        ),
        columns=("category_id", "category_code", "category_name",
                 "parent_category_id", "merch_level", "is_leaf", "sort_order"),
        values=("a_id(i)", "a_code(i)", "a_name(i)", "a_parent(i)",
                "a_level(i)", "a_leaf(i)", "a_sort(i)"),
    ))

    parts.append("\nPROMPT brand")
    parts.append(bulk_block(
        table="brand", rows=n_brand, seed=seed + 31, batch=batch,
        comment=scenario_note(
            "owner_supplier_id is left NULL and back-filled in 06, because supplier",
            "loads after brand. brand -> supplier -> address -> country is the longest",
            "non-circular chain in the schema."),
        varrays=(("v_word", ("Northwind", "Fabrikam", "Litware", "Proseware",
                             "Adventure", "Tailspin", "Wingtip", "Coho", "Lucerne",
                             "Trey", "Alpine", "Blue Yonder")),),
        arrays=(
            ("a_id", "NUMBER"), ("a_code", "VARCHAR2(30)"), ("a_name", "VARCHAR2(120)"),
            ("a_own", "VARCHAR2(1)"),
        ),
        fill=(
            "a_id(i)   := v_r;",
            "a_code(i) := 'BR' || LPAD(TO_CHAR(v_r), 8, '0');",
            "a_name(i) := pick(v_word) || ' ' || TO_CHAR(v_r);",
            "-- One brand in four is own-label, which is what makes the",
            "-- brand -> supplier link nullable in the first place.",
            "a_own(i)  := CASE WHEN MOD(v_r, 4) = 0 THEN 'Y' ELSE 'N' END;",
        ),
        columns=("brand_id", "brand_code", "brand_name", "is_own_label"),
        values=("a_id(i)", "a_code(i)", "a_name(i)", "a_own(i)"),
    ))

    parts.append("\nPROMPT product (CLOB, BLOB, XMLTYPE, nested table, VARRAY)")
    parts.append(bulk_block(
        table="product", rows=n_prod, seed=seed + 32, batch=batch,
        comment=scenario_note(
            "The heaviest table in the schema by construct count.",
            "  long_description  CLOB      (H-34)",
            "  primary_image     BLOB      (H-34; bytea caps at 1 GB, BLOB at 128 TB)",
            "  spec_sheet        XMLTYPE   (H-35; XMLQUERY and method-call syntax have",
            "                               no PostgreSQL equivalent)",
            "  attributes        NESTED TABLE of t_product_attr (H-05)",
            "  channel_availability VARRAY(8) (H-04)",
            "  margin_pct        VIRTUAL, computed from list_price (H-17) -- NOT loaded",
            "list_price is zero on a handful of rows so the NULLIF(list_price, 0) guard",
            "inside the margin_pct expression is actually exercised."),
        varrays=(
            ("v_uom", ("EA", "KG", "L", "PK", "M", "BOX")),
            ("v_status", ("ACTIVE", "ACTIVE", "ACTIVE", "DRAFT",
                          "DISCONTINUED", "DELETED")),
            ("v_noun", ("jacket", "trainers", "kettle", "cushion", "notebook",
                        "monitor", "coffee", "yoghurt", "shampoo", "dog food",
                        "planter", "headphones")),
        ),
        arrays=(
            ("a_id", "NUMBER"), ("a_sku", "VARCHAR2(30)"), ("a_name", "VARCHAR2(200)"),
            ("a_cat", "NUMBER"), ("a_brand", "NUMBER"), ("a_desc", "VARCHAR2(4000)"),
            ("a_xml", "VARCHAR2(1000)"), ("a_hex", "VARCHAR2(200)"),
            ("a_cost", "NUMBER"), ("a_price", "NUMBER"), ("a_uom", "VARCHAR2(10)"),
            ("a_wt", "NUMBER"), ("a_status", "VARCHAR2(15)"), ("a_launch", "DATE"),
            ("a_attrs", "t_product_attr_tab"), ("a_chan", "t_channel_varr"),
        ),
        fill=(
            "a_id(i)     := v_r;",
            "a_sku(i)    := 'SKU' || LPAD(TO_CHAR(v_r), 9, '0');",
            "a_name(i)   := INITCAP(pick(v_noun)) || ' ' || TO_CHAR(v_r);",
            "-- Products hang off leaf categories only (ids 103..246).",
            "a_cat(i)    := 103 + MOD(v_r - 1, 144);",
            "a_brand(i)  := maybe_n(1 + MOD(v_r - 1, %d), 11);" % n_brand,
            "a_desc(i)   := 'Contoso ' || a_name(i) || '. '",
            "               || RPAD('Product copy for the web storefront. ', 200, '.');",
            "a_xml(i)    := '<spec sku=\"' || a_sku(i) || '\">'",
            "               || '<attr name=\"colour\">' || pick(v_noun) || '</attr>'",
            "               || '<attr name=\"weight_kg\">' || TO_CHAR(1 + nxt(20))",
            "               || '</attr>'",
            "               || '<attr name=\"origin\">' || pick(v_uom) || '</attr>'",
            "               || '</spec>';",
            "-- A PNG signature plus a few bytes. Small on purpose: the lab is about",
            "-- the type mapping and the DBMS_LOB calls, not about storage volume.",
            "a_hex(i)    := '89504E470D0A1A0A0000000D49484452'",
            "               || LPAD(TO_CHAR(MOD(v_r, 65536), 'FM0XXX'), 4, '0');",
            "a_cost(i)   := ROUND(0.5 + nxt(40000) / 100, 4);",
            "-- One product in 137 is priced at zero: a genuine retail case (giveaway,",
            "-- component, price-on-application) and the reason margin_pct guards with",
            "-- NULLIF. It is also a division-by-zero waiting to happen after conversion.",
            "a_price(i)  := CASE WHEN MOD(v_r, 137) = 0 THEN 0",
            "                    ELSE ROUND(a_cost(i) * (1.15 + nxt(120) / 100), 4) END;",
            "a_uom(i)    := pick(v_uom);",
            "a_wt(i)     := maybe_n(ROUND(nxt(30000) / 1000, 3), 9);",
            "a_status(i) := pick(v_status);",
            "a_launch(i) := maybe_d(%s + nxt(2200), 8);" % dt("2020-01-01"),
            "a_attrs(i)  := t_product_attr_tab(",
            "                  t_product_attr('COLOUR', pick(v_noun), NULL),",
            "                  t_product_attr('WEIGHT', TO_CHAR(NVL(a_wt(i), 0)), 'kg'),",
            "                  t_product_attr('ORIGIN', pick(v_uom), NULL));",
            "a_chan(i)   := CASE MOD(v_r, 4)",
            "                  WHEN 0 THEN t_channel_varr('POS')",
            "                  WHEN 1 THEN t_channel_varr('POS', 'WEB')",
            "                  WHEN 2 THEN t_channel_varr('POS', 'WEB', 'APP')",
            "                  ELSE        t_channel_varr('WEB', 'APP', 'PARTNER')",
            "               END;",
        ),
        columns=("product_id", "sku", "product_name", "category_id", "brand_id",
                 "long_description", "spec_sheet", "primary_image", "unit_cost",
                 "list_price", "base_uom", "weight_kg", "status", "launch_date",
                 "attributes", "channel_availability", "created_ts"),
        values=("a_id(i)", "a_sku(i)", "a_name(i)", "a_cat(i)", "a_brand(i)",
                "TO_CLOB(a_desc(i))", "XMLTYPE(a_xml(i))",
                "TO_BLOB(HEXTORAW(a_hex(i)))", "a_cost(i)", "a_price(i)",
                "a_uom(i)", "a_wt(i)", "a_status(i)", "a_launch(i)",
                "a_attrs(i)", "a_chan(i)", "SYSTIMESTAMP"),
    ))

    parts.append("\nPROMPT product_variant")
    parts.append(bulk_block(
        table="product_variant", rows=plan["product_variant"], seed=seed + 33,
        batch=batch,
        comment=scenario_note(
            "The sellable unit; everything downstream keys on variant_id.",
            "UNIQUE (product_id, size_code, colour_code) is satisfied by deriving both",
            "codes from the variant's ordinal WITHIN its product, so no two variants of",
            "a product ever collide.",
            "barcode_ean13 is unique but the check digits are deliberately wrong on",
            "most rows -- fn_gen_valid_ean13_* exists precisely to find them, and a",
            "real barcode file is exactly this untrustworthy."),
        varrays=(("v_colour", ("BLACK", "WHITE", "NAVY", "OLIVE", "RUST", "SAND",
                               "TEAL", "PLUM", "GREY", "CORAL")),),
        arrays=(
            ("a_id", "NUMBER"), ("a_prod", "NUMBER"), ("a_sku", "VARCHAR2(40)"),
            ("a_ean", "VARCHAR2(13)"), ("a_size", "VARCHAR2(20)"),
            ("a_colour", "VARCHAR2(20)"), ("a_pack", "NUMBER"),
            ("a_run", "t_size_run_varr"), ("a_active", "VARCHAR2(1)"),
        ),
        decls=("v_seq PLS_INTEGER;",),
        fill=(
            "a_id(i)   := v_r;",
            "a_prod(i) := 1 + MOD(v_r - 1, %d);" % n_prod,
            "v_seq     := TRUNC((v_r - 1) / %d);   -- ordinal within the product" % n_prod,
            "a_sku(i)  := 'VAR' || LPAD(TO_CHAR(v_r), 12, '0');",
            "a_ean(i)  := maybe(TO_CHAR(5000000000000 + v_r), 23);",
            "a_size(i) := 'SZ' || LPAD(TO_CHAR(v_seq), 4, '0');",
            "a_colour(i) := 'C' || LPAD(TO_CHAR(v_seq), 4, '0') || '_'",
            "               || SUBSTR(pick(v_colour), 1, 6);",
            "a_pack(i) := 1 + MOD(v_seq, 12);",
            "a_run(i)  := t_size_run_varr(1 + MOD(v_seq, 4), 2 + MOD(v_seq, 6),",
            "                             3 + MOD(v_seq, 8), 4 + MOD(v_seq, 10));",
            "a_active(i) := CASE WHEN MOD(v_r, 19) = 0 THEN 'N' ELSE 'Y' END;",
        ),
        columns=("variant_id", "product_id", "variant_sku", "barcode_ean13",
                 "size_code", "colour_code", "pack_qty", "size_run", "is_active"),
        values=("a_id(i)", "a_prod(i)", "a_sku(i)", "a_ean(i)", "a_size(i)",
                "a_colour(i)", "a_pack(i)", "a_run(i)", "a_active(i)"),
    ))

    return "\n\n".join(parts)


# --------------------------------------------------------------------------
# 06 -- suppliers and sourcing
# --------------------------------------------------------------------------

def file_suppliers(plan: Dict[str, int], seed: int, batch: int) -> str:
    n_sup = plan["supplier"]
    parts: List[str] = ["PROMPT === suppliers ==="]

    parts.append("\nPROMPT supplier (object-type column, H-03)")
    parts.append(bulk_block(
        table="supplier", rows=n_sup, seed=seed + 40, batch=batch,
        comment=scenario_note(
            "primary_contact is a t_contact OBJECT column with member methods.",
            "HARD CASE H-03: a PostgreSQL composite type carries the attributes and",
            "none of the methods -- no MAP, no ORDER, no substitutability. Every",
            "contact.display_label() call becomes a standalone function taking the",
            "composite, and the UNDER hierarchy has no analogue at all.",
            "lead_time is INTERVAL DAY(3) TO SECOND(0) (H-36)."),
        varrays=(
            ("v_first", FIRST_NAMES[:46]),
            ("v_last", LAST_NAMES[:38]),
            ("v_role", ("Account manager", "Key account director", "Sales lead",
                        "Logistics coordinator", "Category manager")),
        ),
        arrays=(
            ("a_id", "NUMBER"), ("a_code", "VARCHAR2(20)"), ("a_name", "VARCHAR2(150)"),
            ("a_addr", "NUMBER"), ("a_cname", "VARCHAR2(120)"),
            ("a_cmail", "VARCHAR2(150)"), ("a_cphone", "VARCHAR2(40)"),
            ("a_crole", "VARCHAR2(60)"), ("a_terms", "NUMBER"),
            ("a_ccy", "VARCHAR2(3)"), ("a_lead", "INTERVAL DAY(3) TO SECOND(0)"),
            ("a_rating", "NUMBER"), ("a_appr", "VARCHAR2(1)"),
        ),
        decls=_plsql_country_varrays(),
        fill=(
            "a_id(i)     := v_r;",
            "a_code(i)   := 'SUP' || LPAD(TO_CHAR(v_r), 9, '0');",
            "a_name(i)   := pick(v_last) || ' Trading ' || TO_CHAR(v_r);",
            "a_addr(i)   := maybe_n(1 + MOD(v_r * 3 - 1, %d), 17);" % plan["address"],
            "a_cname(i)  := pick(v_first) || ' ' || pick(v_last);",
            "-- Empty-string contact e-mail on one row in six. In Oracle that column",
            "-- reads back NULL; after conversion it reads back ''. t_contact's",
            "-- is_valid_email member function returns a different answer for each.",
            "a_cmail(i)  := CASE MOD(v_r, 6)",
            "                  WHEN 0 THEN ''",
            "                  ELSE 'supplier' || TO_CHAR(v_r) || '@vendor.invalid'",
            "               END;",
            "a_cphone(i) := maybe('+' || TO_CHAR(30 + nxt(60)) || ' '",
            "                     || TO_CHAR(100000000 + nxt(899999999)), 8);",
            "a_crole(i)  := pick(v_role);",
            "a_terms(i)  := CASE MOD(v_r, 5) WHEN 0 THEN 14 WHEN 1 THEN 30",
            "                                WHEN 2 THEN 45 WHEN 3 THEN 60 ELSE 90 END;",
            "a_ccy(i)    := v_ccy(1 + MOD(v_r - 1, 40));",
            "a_lead(i)   := NUMTODSINTERVAL(1 + nxt(45), 'DAY');",
            "a_rating(i) := maybe_n(ROUND(1 + nxt(90) / 10, 1), 7);",
            "a_appr(i)   := CASE WHEN MOD(v_r, 9) = 0 THEN 'N' ELSE 'Y' END;",
        ),
        columns=("supplier_id", "supplier_code", "supplier_name", "address_id",
                 "primary_contact", "payment_terms_days", "currency_code",
                 "lead_time", "rating", "is_approved", "onboarded_ts"),
        values=("a_id(i)", "a_code(i)", "a_name(i)", "a_addr(i)",
                "t_contact(a_cname(i), a_cmail(i), a_cphone(i), a_crole(i))",
                "a_terms(i)", "a_ccy(i)", "a_lead(i)", "a_rating(i)", "a_appr(i)",
                "SYSTIMESTAMP"),
    ))

    parts.append("\n".join([
        "",
        "PROMPT brand.owner_supplier_id back-fill",
        "UPDATE brand",
        "   SET owner_supplier_id = 1 + MOD(brand_id * 3, %d)" % n_sup,
        " WHERE is_own_label = 'N';",
        "COMMIT;",
    ]))

    parts.append("\nPROMPT supplier_product (sourcing matrix)")
    parts.append(bulk_block(
        table="supplier_product", rows=plan["supplier_product"], seed=seed + 41,
        batch=batch,
        comment=scenario_note(
            "PRIMARY KEY (supplier_id, variant_id). The supplier index cycles fastest",
            "and the variant index advances once per full supplier cycle, so the pairs",
            "are unique by construction rather than by hope."),
        arrays=(
            ("a_sup", "NUMBER"), ("a_var", "NUMBER"), ("a_sku", "VARCHAR2(40)"),
            ("a_cost", "NUMBER"), ("a_ccy", "VARCHAR2(3)"), ("a_moq", "NUMBER"),
            ("a_lead", "NUMBER"), ("a_primary", "VARCHAR2(1)"),
            ("a_from", "DATE"), ("a_to", "DATE"),
        ),
        decls=_plsql_country_varrays() + ["v_k PLS_INTEGER;"],
        fill=(
            "v_k := v_r - 1;",
            "a_sup(i)  := 1 + MOD(v_k, %d);" % n_sup,
            "a_var(i)  := 1 + MOD(TRUNC(v_k / %d), %d);"
            % (n_sup, plan["product_variant"]),
            "a_sku(i)  := 'VSKU' || LPAD(TO_CHAR(a_sup(i)), 6, '0') || '-'",
            "             || LPAD(TO_CHAR(a_var(i)), 10, '0');",
            "a_cost(i) := ROUND(0.4 + nxt(30000) / 100, 4);",
            "a_ccy(i)  := v_ccy(1 + MOD(a_sup(i) - 1, 40));",
            "a_moq(i)  := CASE MOD(v_r, 6) WHEN 0 THEN 1 ELSE 6 * (1 + nxt(20)) END;",
            "a_lead(i) := maybe_n(1 + nxt(60), 10);",
            "-- Exactly one primary source per variant: the supplier whose index is",
            "-- congruent to the variant index. Everything else is a secondary source.",
            "a_primary(i) := CASE WHEN MOD(a_var(i), %d) = MOD(a_sup(i), %d)"
            % (n_sup, n_sup),
            "                     THEN 'Y' ELSE 'N' END;",
            "a_from(i) := %s + nxt(600);" % dt("2023-01-01"),
            "a_to(i)   := maybe_d(a_from(i) + 365 + nxt(700), 3);",
        ),
        columns=("supplier_id", "variant_id", "supplier_sku", "unit_cost",
                 "currency_code", "min_order_qty", "lead_time_days",
                 "is_primary_source", "valid_from", "valid_to"),
        values=("a_sup(i)", "a_var(i)", "a_sku(i)", "a_cost(i)", "a_ccy(i)",
                "a_moq(i)", "a_lead(i)", "a_primary(i)", "a_from(i)", "a_to(i)"),
    ))

    return "\n\n".join(parts)


# --------------------------------------------------------------------------
# 07 -- customers and loyalty
# --------------------------------------------------------------------------

def file_customers(plan: Dict[str, int], seed: int, batch: int) -> str:
    n_cust = plan["customer"]
    parts: List[str] = ["PROMPT === customers and loyalty ==="]

    parts.append("\nPROMPT customer (VPD-protected, unicode, empty strings)")
    parts.append(bulk_block(
        table="customer", rows=n_cust, seed=seed + 50, batch=batch,
        comment=scenario_note(
            "This table is protected by a VPD policy (H-40) and carries the schema's",
            "unique function-based index on LOWER(email) (H-16), so e-mail must be",
            "case-insensitively unique wherever it is not NULL -- the row number",
            "guarantees that.",
            "first_name is empty on one row in seven and NULL on one in eleven. In",
            "Oracle those are the SAME THING; after conversion they are not, and",
            "COUNT(first_name) returns two different numbers on the two databases.",
            "That divergence is the whole of H-38 and it is meant to be measured.",
            "Names are deliberately multi-byte: Greek, Cyrillic, Arabic, CJK, Hangul",
            "and Latin-1. VARCHAR2(60) is SIXTY BYTES by default (trap T-03)."),
        varrays=(
            ("v_first", FIRST_NAMES[:46]),
            ("v_last", LAST_NAMES[:38]),
            ("v_status", ("ACTIVE", "ACTIVE", "ACTIVE", "DORMANT", "CLOSED")),
        ),
        arrays=(
            ("a_id", "NUMBER"), ("a_ref", "VARCHAR2(20)"), ("a_first", "VARCHAR2(60)"),
            ("a_last", "VARCHAR2(60)"), ("a_email", "VARCHAR2(150)"),
            ("a_mob", "VARCHAR2(30)"), ("a_dob", "DATE"), ("a_cc", "VARCHAR2(2)"),
            ("a_store", "NUMBER"), ("a_addr", "NUMBER"), ("a_optin", "VARCHAR2(1)"),
            ("a_chan", "t_channel_varr"), ("a_status", "VARCHAR2(15)"),
            ("a_created", "TIMESTAMP WITH LOCAL TIME ZONE"),
            ("a_login", "TIMESTAMP WITH LOCAL TIME ZONE"),
            ("a_erasure", "TIMESTAMP WITH LOCAL TIME ZONE"),
            ("a_notes", "VARCHAR2(4000)"),
        ),
        decls=_plsql_country_varrays(),
        fill=(
            "a_id(i)    := v_r;",
            "a_ref(i)   := 'CUST' || LPAD(TO_CHAR(v_r), 12, '0');",
            "-- H-38 probes, at a rate a real customer master would show.",
            "a_first(i) := CASE",
            "                 WHEN MOD(v_r, 7) = 0  THEN ''",
            "                 WHEN MOD(v_r, 11) = 0 THEN NULL",
            "                 ELSE pick(v_first)",
            "              END;",
            "a_last(i)  := pick(v_last);   -- NOT NULL in the schema",
            "a_email(i) := maybe(LOWER('cust' || TO_CHAR(v_r) || '@shopper.invalid'), 13);",
            "-- Empty mobile on one row in nine: pkg_customer.upsert_customer relies on",
            "-- Oracle turning that into NULL.",
            "a_mob(i)   := CASE WHEN MOD(v_r, 9) = 0 THEN ''",
            "                   ELSE '+' || TO_CHAR(30 + nxt(60))",
            "                        || TO_CHAR(100000000 + nxt(899999999)) END;",
            "a_dob(i)   := maybe_d(%s + nxt(19000), 6);" % dt("1945-01-01"),
            "a_cc(i)    := v_cc(1 + MOD(v_r - 1, 40));",
            "a_store(i) := maybe_n(1 + MOD(v_r - 1, %d), 5);" % plan["store"],
            "a_addr(i)  := maybe_n(1 + MOD(v_r * 5 - 1, %d), 7);" % plan["address"],
            "a_optin(i) := CASE WHEN MOD(v_r, 3) = 0 THEN 'Y' ELSE 'N' END;",
            "a_chan(i)  := CASE MOD(v_r, 3)",
            "                 WHEN 0 THEN t_channel_varr('WEB')",
            "                 WHEN 1 THEN t_channel_varr('WEB', 'APP')",
            "                 ELSE        t_channel_varr('WEB', 'APP', 'CALL')",
            "              END;",
            "a_status(i)  := pick(v_status);",
            "a_created(i) := CAST(%s AS TIMESTAMP)" % dt("2021-01-01"),
            "                + NUMTODSINTERVAL(MOD(v_r, 1800) * 86400 + nxt(86400),",
            "                                  'SECOND');",
            "a_login(i)   := CASE WHEN MOD(v_r, 4) <> 0 THEN",
            "                   a_created(i) + NUMTODSINTERVAL(nxt(2000000), 'SECOND')",
            "                END;",
            "-- GDPR erasure on one row in 61. Those rows keep the key and lose the",
            "-- personal data, which is exactly the shape that breaks naive row counts.",
            "a_erasure(i) := CASE WHEN MOD(v_r, 61) = 0",
            "                     THEN a_created(i)",
            "                          + NUMTODSINTERVAL(4000000, 'SECOND') END;",
            "a_notes(i)   := maybe('Contact preference noted by ' || pick(v_first)",
            "                      || '. ' || RPAD('Free-text CRM note. ', 300, '.'), 4);",
        ),
        columns=("customer_id", "customer_ref", "first_name", "last_name", "email",
                 "mobile_phone", "birth_date", "home_country_code",
                 "preferred_store_id", "primary_address_id", "marketing_optin",
                 "consent_channels", "status", "created_ts", "last_login_ts",
                 "gdpr_erasure_ts", "notes"),
        values=("a_id(i)", "a_ref(i)", "a_first(i)", "a_last(i)", "a_email(i)",
                "a_mob(i)", "a_dob(i)", "a_cc(i)", "a_store(i)", "a_addr(i)",
                "a_optin(i)", "a_chan(i)", "a_status(i)", "a_created(i)",
                "a_login(i)", "a_erasure(i)", "TO_CLOB(a_notes(i))"),
    ))

    parts.append("\nPROMPT customer_address")
    parts.append(bulk_block(
        table="customer_address", rows=plan["customer_address"], seed=seed + 51,
        batch=batch,
        comment=scenario_note(
            "PRIMARY KEY (customer_id, address_id, address_type). The customer index",
            "cycles fastest and the address_type advances with it, so the key is unique",
            "even when two rows happen to point at the same address."),
        arrays=(
            ("a_cust", "NUMBER"), ("a_addr", "NUMBER"), ("a_type", "VARCHAR2(15)"),
            ("a_def", "VARCHAR2(1)"), ("a_from", "DATE"), ("a_to", "DATE"),
        ),
        decls=("v_k PLS_INTEGER;", "v_seq PLS_INTEGER;"),
        fill=(
            "v_k    := v_r - 1;",
            "v_seq  := TRUNC(v_k / %d);" % n_cust,
            "a_cust(i) := 1 + MOD(v_k, %d);" % n_cust,
            "a_addr(i) := 1 + MOD(a_cust(i) * 3 + v_seq * 11, %d);" % plan["address"],
            "a_type(i) := CASE v_seq WHEN 0 THEN 'HOME' WHEN 1 THEN 'WORK'",
            "                        WHEN 2 THEN 'BILLING' ELSE 'OTHER' END;",
            "a_def(i)  := CASE WHEN v_seq = 0 THEN 'Y' ELSE 'N' END;",
            "a_from(i) := %s + nxt(1400);" % dt("2021-01-01"),
            "a_to(i)   := maybe_d(a_from(i) + 400 + nxt(900), 4);",
        ),
        columns=("customer_id", "address_id", "address_type", "is_default",
                 "valid_from", "valid_to"),
        values=("a_cust(i)", "a_addr(i)", "a_type(i)", "a_def(i)",
                "a_from(i)", "a_to(i)"),
    ))

    parts.append("\nPROMPT loyalty_account")
    parts.append(bulk_block(
        table="loyalty_account", rows=plan["loyalty_account"], seed=seed + 52,
        batch=batch,
        comment=scenario_note(
            "customer_id is UNIQUE and NOT NULL, so loyalty_id maps one-to-one onto the",
            "first N customers. points_balance has CHECK (>= 0) and the generator",
            "respects it -- the negative movements live in loyalty_transaction, which is",
            "where a points ledger actually puts them."),
        varrays=(("v_tier", ("BRONZE", "BRONZE", "SILVER", "GOLD",
                             "PLATINUM", "BLACK")),),
        arrays=(
            ("a_id", "NUMBER"), ("a_cust", "NUMBER"), ("a_card", "VARCHAR2(19)"),
            ("a_tier", "VARCHAR2(10)"), ("a_bal", "NUMBER"), ("a_life", "NUMBER"),
            ("a_enrol", "DATE"), ("a_review", "DATE"), ("a_status", "VARCHAR2(15)"),
        ),
        fill=(
            "a_id(i)     := v_r;",
            "a_cust(i)   := v_r;   -- UNIQUE customer_id; loyalty_account <= customer",
            "a_card(i)   := '6011' || LPAD(TO_CHAR(v_r), 12, '0');",
            "a_tier(i)   := pick(v_tier);",
            "a_bal(i)    := nxt(90000);",
            "a_life(i)   := a_bal(i) + nxt(400000);",
            "a_enrol(i)  := %s + nxt(1700);" % dt("2021-01-01"),
            "a_review(i) := maybe_d(a_enrol(i) + 365, 5);",
            "a_status(i) := CASE WHEN MOD(v_r, 23) = 0 THEN 'SUSPENDED' ELSE 'ACTIVE' END;",
        ),
        columns=("loyalty_id", "customer_id", "card_number", "tier_code",
                 "points_balance", "lifetime_points", "enrolled_date",
                 "tier_reviewed_date", "status"),
        values=("a_id(i)", "a_cust(i)", "a_card(i)", "a_tier(i)", "a_bal(i)",
                "a_life(i)", "a_enrol(i)", "a_review(i)", "a_status(i)"),
    ))

    parts.append("\nPROMPT loyalty_transaction (LIST partitioned by txn_type)")
    parts.append(bulk_block(
        table="loyalty_transaction", rows=plan["loyalty_transaction"], seed=seed + 53,
        batch=batch,
        comment=scenario_note(
            "PARTITION BY LIST (txn_type), so every one of the five partitions must",
            "receive rows or the list partitioning is untested (H-20). The row number",
            "is taken modulo five to guarantee that.",
            "points_delta is NEGATIVE for REDEEM and EXPIRE. A ledger with only",
            "positive numbers proves nothing.",
            "order_id is a soft reference with no foreign key, because the parent is",
            "interval-partitioned -- design.md documents that decision deliberately."),
        varrays=(
            ("v_type", ("ACCRUE", "REDEEM", "EXPIRE", "ADJUST", "TRANSFER")),
            ("v_reason", ("PURCHASE", "BONUS", "GOODWILL", "CORRECTION",
                          "CAMPAIGN", "EXPIRY_RUN")),
        ),
        arrays=(
            ("a_id", "NUMBER"), ("a_type", "VARCHAR2(15)"), ("a_loy", "NUMBER"),
            ("a_delta", "NUMBER"), ("a_order", "NUMBER"), ("a_reason", "VARCHAR2(20)"),
            ("a_ts", "TIMESTAMP WITH LOCAL TIME ZONE"), ("a_exp", "DATE"),
        ),
        decls=("v_ti PLS_INTEGER;",),
        fill=(
            "v_ti := 1 + MOD(v_r - 1, 5);",
            "a_id(i)     := v_r;",
            "a_type(i)   := v_type(v_ti);",
            "a_loy(i)    := 1 + MOD(v_r - 1, %d);" % plan["loyalty_account"],
            "a_delta(i)  := CASE v_ti",
            "                  WHEN 2 THEN -1 * (50 + nxt(2000))",
            "                  WHEN 3 THEN -1 * (10 + nxt(500))",
            "                  WHEN 4 THEN (nxt(400) - 200)",
            "                  ELSE 10 + nxt(3000)",
            "               END;",
            "a_order(i)  := maybe_n(1 + MOD(v_r - 1, %d), 3);" % plan["sales_order"],
            "a_reason(i) := pick(v_reason);",
            "a_ts(i)     := CAST(%s AS TIMESTAMP)" % dt(FACT_START),
            "               + NUMTODSINTERVAL(MOD(v_r - 1, %d) * 86400" % FACT_DAYS,
            "                                 + nxt(86400), 'SECOND');",
            "a_exp(i)    := maybe_d(CAST(a_ts(i) AS DATE) + 730, 4);",
        ),
        columns=("loyalty_txn_id", "txn_type", "loyalty_id", "points_delta",
                 "order_id", "reason_code", "txn_ts", "expires_on", "created_by"),
        values=("a_id(i)", "a_type(i)", "a_loy(i)", "a_delta(i)", "a_order(i)",
                "a_reason(i)", "a_ts(i)", "a_exp(i)", "'SEED_LOAD'"),
    ))

    return "\n\n".join(parts)


# --------------------------------------------------------------------------
# 08 -- pricing and promotions
# --------------------------------------------------------------------------

def file_pricing(plan: Dict[str, int], seed: int, batch: int) -> str:
    n_pl = plan["price_list"]
    n_promo = plan["promotion"]
    n_var = plan["product_variant"]
    parts: List[str] = ["PROMPT === pricing and promotions ==="]

    parts.append("\nPROMPT price_list")
    parts.append(bulk_block(
        table="price_list", rows=n_pl, seed=seed + 60, batch=batch,
        comment=scenario_note(
            "One list per country per channel, with overlapping validity windows and",
            "a priority column -- which is the whole reason pkg_pricing needs a",
            "tie-break and therefore the reason ROWNUM = 1 shows up (H-30)."),
        varrays=(("v_chan", ("POS", "WEB", "APP", "PARTNER")),),
        arrays=(
            ("a_id", "NUMBER"), ("a_code", "VARCHAR2(30)"), ("a_cc", "VARCHAR2(2)"),
            ("a_ccy", "VARCHAR2(3)"), ("a_chan", "VARCHAR2(20)"),
            ("a_from", "DATE"), ("a_to", "DATE"), ("a_prio", "NUMBER"),
        ),
        decls=_plsql_country_varrays() + ["v_ci PLS_INTEGER;"],
        fill=(
            "v_ci := 1 + MOD(v_r - 1, 40);",
            "a_id(i)   := v_r;",
            "a_code(i) := 'PL' || v_cc(v_ci) || '-' || LPAD(TO_CHAR(v_r), 5, '0');",
            "a_cc(i)   := v_cc(v_ci);",
            "a_ccy(i)  := v_ccy(v_ci);",
            "a_chan(i) := v_chan(1 + MOD(v_r - 1, 4));",
            "a_from(i) := %s;" % dt("2023-06-01"),
            "a_to(i)   := CASE WHEN MOD(v_r, 6) = 0 THEN %s END;" % dt("2027-01-01"),
            "a_prio(i) := 10 * (1 + MOD(v_r, 9));",
        ),
        columns=("price_list_id", "price_list_code", "country_code", "currency_code",
                 "channel_code", "valid_from", "valid_to", "priority"),
        values=("a_id(i)", "a_code(i)", "a_cc(i)", "a_ccy(i)", "a_chan(i)",
                "a_from(i)", "a_to(i)", "a_prio(i)"),
    ))

    parts.append("\nPROMPT promotion (XMLTYPE rule, H-35)")
    parts.append(bulk_block(
        table="promotion", rows=n_promo, seed=seed + 61, batch=batch,
        comment=scenario_note(
            "rule_xml is the eligibility rule, parsed with XMLTABLE and XMLQUERY in",
            "pkg_promotion (H-35). Oracle's XMLQUERY ... RETURNING CONTENT and the",
            "method-call syntax on the type have no PostgreSQL equivalent; xpath() and",
            "xmltable() cover the basic shape and nothing else.",
            "CHECK (end_ts > start_ts) is respected by construction."),
        varrays=(
            ("v_type", ("PCT_OFF", "AMT_OFF", "BOGO", "BUNDLE",
                        "THRESHOLD", "LOYALTY_X")),
            ("v_status", ("DRAFT", "ACTIVE", "ACTIVE", "EXPIRED")),
        ),
        arrays=(
            ("a_id", "NUMBER"), ("a_code", "VARCHAR2(30)"), ("a_name", "VARCHAR2(150)"),
            ("a_type", "VARCHAR2(20)"),
            ("a_start", "TIMESTAMP WITH LOCAL TIME ZONE"),
            ("a_end", "TIMESTAMP WITH LOCAL TIME ZONE"),
            ("a_budget", "NUMBER"), ("a_spent", "NUMBER"),
            ("a_xml", "VARCHAR2(1000)"), ("a_cc", "VARCHAR2(2)"),
            ("a_status", "VARCHAR2(15)"),
        ),
        decls=_plsql_country_varrays(),
        fill=(
            "a_id(i)     := v_r;",
            "a_code(i)   := 'PROMO' || LPAD(TO_CHAR(v_r), 8, '0');",
            "a_type(i)   := v_type(1 + MOD(v_r - 1, 6));",
            "a_name(i)   := INITCAP(REPLACE(a_type(i), '_', ' ')) || ' campaign '",
            "               || TO_CHAR(v_r);",
            "a_start(i)  := CAST(%s AS TIMESTAMP)" % dt(FACT_START),
            "               + NUMTODSINTERVAL(MOD(v_r - 1, %d) * 86400, 'SECOND');"
            % FACT_DAYS,
            "a_end(i)    := a_start(i) + NUMTODSINTERVAL((7 + nxt(60)) * 86400,",
            "                                            'SECOND');",
            "a_budget(i) := maybe_n(ROUND(5000 + nxt(200000), 2), 7);",
            "a_spent(i)  := ROUND(NVL(a_budget(i), 10000) * nxt(90) / 100, 2);",
            "a_xml(i)    := '<rule type=\"' || a_type(i) || '\">'",
            "               || '<threshold>' || TO_CHAR(10 + nxt(90)) || '</threshold>'",
            "               || '<discount unit=\"PCT\">' || TO_CHAR(5 + nxt(40))",
            "               || '</discount>'",
            "               || '<channels><channel>WEB</channel>'",
            "               || '<channel>POS</channel></channels>'",
            "               || '</rule>';",
            "a_cc(i)     := maybe(v_cc(1 + MOD(v_r - 1, 40)), 5);",
            "a_status(i) := pick(v_status);",
        ),
        columns=("promotion_id", "promo_code", "promo_name", "promo_type",
                 "start_ts", "end_ts", "budget_amount", "spent_amount",
                 "rule_xml", "country_code", "status"),
        values=("a_id(i)", "a_code(i)", "a_name(i)", "a_type(i)", "a_start(i)",
                "a_end(i)", "a_budget(i)", "a_spent(i)", "XMLTYPE(a_xml(i))",
                "a_cc(i)", "a_status(i)"),
    ))

    parts.append("\nPROMPT price_list_item")
    parts.append(bulk_block(
        table="price_list_item", rows=plan["price_list_item"], seed=seed + 62,
        batch=batch,
        comment=scenario_note(
            "PRIMARY KEY (price_list_id, variant_id, effective_from).",
            "unit_price has CHECK (>= 0) and some rows are exactly zero -- a legitimate",
            "'free with purchase' line, and a divide-by-zero for anyone computing a",
            "margin without a guard.",
            "was_price is NULL unless the item is on markdown, which is what makes the",
            "NVL/DECODE chains in the rule packages meaningful.",
            "ck_pli_markdown correlates three of these columns at once, so they cannot",
            "be drawn independently: a was_price must be strictly greater than",
            "unit_price, a was_price always needs a reason code, and only a row that",
            "carries a was_price may claim reason 'MARKDOWN'."),
        varrays=(("v_reason_down", ("MARKDOWN", "CLEARANCE", "PROMO")),
                 ("v_reason_flat", ("BASE", "COMPETITOR", "COST_UP")),),
        arrays=(
            ("a_pl", "NUMBER"), ("a_var", "NUMBER"), ("a_from", "DATE"),
            ("a_price", "NUMBER"), ("a_was", "NUMBER"), ("a_tax", "NUMBER"),
            ("a_to", "DATE"), ("a_reason", "VARCHAR2(20)"),
        ),
        decls=("v_k PLS_INTEGER;",),
        fill=(
            "v_k := v_r - 1;",
            "a_pl(i)   := 1 + MOD(v_k, %d);" % n_pl,
            "a_var(i)  := 1 + MOD(TRUNC(v_k / %d), %d);" % (n_pl, n_var),
            "a_from(i) := %s;" % dt("2024-01-01"),
            "a_price(i) := CASE WHEN MOD(v_r, 211) = 0 THEN 0",
            "                   ELSE ROUND(0.5 + nxt(50000) / 100, 4) END;",
            "-- The + 0.5 is load-bearing: without it the zero-unit_price rows would",
            "-- get was_price = 0 * 1.25 = 0, which is not strictly greater and fails",
            "-- ck_pli_markdown on exactly the rows that are most interesting.",
            "a_was(i)   := CASE WHEN MOD(v_r, 5) = 0",
            "                   THEN ROUND(a_price(i) * 1.25 + 0.5, 4) END;",
            "IF a_was(i) IS NULL THEN",
            "   -- No previous price, so the reason may never be 'MARKDOWN'. NULL one",
            "   -- time in four, to exercise the IS NULL branch of the constraint.",
            "   a_reason(i) := maybe(pick(v_reason_flat), 4);",
            "ELSE",
            "   a_reason(i) := pick(v_reason_down);",
            "END IF;",
            "a_tax(i)   := maybe_n(1 + MOD(v_r - 1, %d), 6);" % plan["tax_rate"],
            "a_to(i)    := maybe_d(%s, 3);" % dt("2026-12-31"),
        ),
        columns=("price_list_id", "variant_id", "effective_from", "unit_price",
                 "was_price", "tax_rate_id", "effective_to", "price_reason_code"),
        values=("a_pl(i)", "a_var(i)", "a_from(i)", "a_price(i)", "a_was(i)",
                "a_tax(i)", "a_to(i)", "a_reason(i)"),
    ))

    parts.append("\nPROMPT promotion_product")
    parts.append(bulk_block(
        table="promotion_product", rows=plan["promotion_product"], seed=seed + 63,
        batch=batch,
        comment=scenario_note(
            "CHECK (discount_pct IS NOT NULL OR discount_amount IS NOT NULL): exactly",
            "one of the two is populated per row, alternating, so both branches of the",
            "constraint and both branches of every COALESCE over them are exercised."),
        arrays=(
            ("a_promo", "NUMBER"), ("a_var", "NUMBER"), ("a_pct", "NUMBER"),
            ("a_amt", "NUMBER"), ("a_max", "NUMBER"),
        ),
        decls=("v_k PLS_INTEGER;",),
        fill=(
            "v_k := v_r - 1;",
            "a_promo(i) := 1 + MOD(v_k, %d);" % n_promo,
            "a_var(i)   := 1 + MOD(TRUNC(v_k / %d), %d);" % (n_promo, n_var),
            "IF MOD(v_r, 2) = 0 THEN",
            "   a_pct(i) := ROUND(5 + nxt(45) + nxt(100) / 100, 2);",
            "   a_amt(i) := NULL;",
            "ELSE",
            "   a_pct(i) := NULL;",
            "   a_amt(i) := ROUND(0.5 + nxt(3000) / 100, 4);",
            "END IF;",
            "a_max(i)   := maybe_n(1 + nxt(12), 4);",
        ),
        columns=("promotion_id", "variant_id", "discount_pct", "discount_amount",
                 "max_qty_per_order"),
        values=("a_promo(i)", "a_var(i)", "a_pct(i)", "a_amt(i)", "a_max(i)"),
    ))

    parts.append("\nPROMPT coupon")
    parts.append(bulk_block(
        table="coupon", rows=plan["coupon"], seed=seed + 64, batch=batch,
        comment=scenario_note(
            "CHECK (redemption_count <= max_redemptions) is honoured, including the",
            "boundary case where they are equal -- a fully redeemed coupon.",
            "customer_id NULL means a bearer coupon, which is a third of them."),
        arrays=(
            ("a_id", "NUMBER"), ("a_code", "VARCHAR2(40)"), ("a_promo", "NUMBER"),
            ("a_cust", "NUMBER"), ("a_issued", "TIMESTAMP WITH LOCAL TIME ZONE"),
            ("a_exp", "TIMESTAMP WITH LOCAL TIME ZONE"), ("a_max", "NUMBER"),
            ("a_count", "NUMBER"), ("a_redeemed", "TIMESTAMP WITH LOCAL TIME ZONE"),
        ),
        fill=(
            "a_id(i)     := v_r;",
            "a_code(i)   := 'CPN-' || LPAD(TO_CHAR(v_r), 10, '0') || '-'",
            "               || TO_CHAR(1000 + nxt(8999));",
            "a_promo(i)  := 1 + MOD(v_r - 1, %d);" % n_promo,
            "a_cust(i)   := CASE WHEN MOD(v_r, 3) = 0 THEN NULL",
            "                    ELSE 1 + MOD(v_r - 1, %d) END;" % plan["customer"],
            "a_issued(i) := CAST(%s AS TIMESTAMP)" % dt(FACT_START),
            "               + NUMTODSINTERVAL(MOD(v_r - 1, %d) * 86400, 'SECOND');"
            % FACT_DAYS,
            "a_exp(i)    := a_issued(i) + NUMTODSINTERVAL(90 * 86400, 'SECOND');",
            "a_max(i)    := 1 + MOD(v_r, 5);",
            "a_count(i)  := CASE WHEN MOD(v_r, 4) = 0 THEN a_max(i)",
            "                    ELSE MOD(v_r, a_max(i) + 1) END;",
            "a_redeemed(i) := CASE WHEN a_count(i) > 0",
            "                      THEN a_issued(i)",
            "                           + NUMTODSINTERVAL(nxt(7000000), 'SECOND') END;",
        ),
        columns=("coupon_id", "coupon_code", "promotion_id", "customer_id",
                 "issued_ts", "expires_ts", "max_redemptions", "redemption_count",
                 "redeemed_ts"),
        values=("a_id(i)", "a_code(i)", "a_promo(i)", "a_cust(i)", "a_issued(i)",
                "a_exp(i)", "a_max(i)", "a_count(i)", "a_redeemed(i)"),
    ))

    return "\n\n".join(parts)


# --------------------------------------------------------------------------
# 09 -- inventory. Loaded BEFORE orders, because sales_order_line and shipment
#       both carry a foreign key to inventory_location.
# --------------------------------------------------------------------------

def file_inventory(plan: Dict[str, int], seed: int, batch: int) -> str:
    n_loc = plan["inventory_location"]
    n_var = plan["product_variant"]
    roots = max(1, n_loc // 4)
    parts: List[str] = ["PROMPT === inventory ==="]

    parts.append("\nPROMPT inventory_location (shallow 2-level tree, hierarchy 5)")
    parts.append(bulk_block(
        table="inventory_location", rows=n_loc, seed=seed + 70, batch=batch,
        comment=scenario_note(
            "CHECK ((warehouse_id IS NULL) <> (store_id IS NULL)): exactly one parent,",
            "never both, never neither. Odd rows are store bins, even rows are",
            "warehouse bins.",
            "This is the fifth hierarchy and it is only two levels deep on purpose: it",
            "is walked by a recursive PL/SQL routine rather than CONNECT BY, so the lab",
            "can compare how the tool treats the SQL form and the procedural form of",
            "the same idea (design.md 4.1).",
            "The first quarter of the rows are roots, so every child's parent already",
            "exists by the time FORALL reaches it."),
        varrays=(("v_type", ("BACKROOM", "SHELF", "BULK", "PICKFACE",
                             "QUARANTINE", "TRANSIT")),),
        arrays=(
            ("a_id", "NUMBER"), ("a_code", "VARCHAR2(30)"), ("a_wh", "NUMBER"),
            ("a_store", "NUMBER"), ("a_parent", "NUMBER"), ("a_type", "VARCHAR2(20)"),
        ),
        fill=(
            "a_id(i)   := v_r;",
            "a_code(i) := 'LOC' || LPAD(TO_CHAR(v_r), 12, '0');",
            "IF MOD(v_r, 2) = 0 THEN",
            "   a_wh(i)    := 1 + MOD(v_r - 1, %d);" % plan["warehouse"],
            "   a_store(i) := NULL;",
            "ELSE",
            "   a_wh(i)    := NULL;",
            "   a_store(i) := 1 + MOD(v_r - 1, %d);" % plan["store"],
            "END IF;",
            "a_parent(i) := CASE WHEN v_r <= %d THEN NULL" % roots,
            "                    ELSE 1 + MOD(v_r, %d) END;" % roots,
            "a_type(i)   := pick(v_type);",
        ),
        columns=("location_id", "location_code", "warehouse_id", "store_id",
                 "parent_location_id", "location_type"),
        values=("a_id(i)", "a_code(i)", "a_wh(i)", "a_store(i)", "a_parent(i)",
                "a_type(i)"),
    ))

    parts.append("\nPROMPT inventory_stock")
    parts.append(bulk_block(
        table="inventory_stock", rows=plan["inventory_stock"], seed=seed + 71,
        batch=batch,
        comment=scenario_note(
            "PRIMARY KEY (location_id, variant_id). qty_available is VIRTUAL",
            "(qty_on_hand - qty_reserved) and is not loaded (H-17).",
            "qty_on_hand is NEGATIVE on roughly one row in forty. That is not a bug:",
            "an unrecorded shrink or a receipt booked after the sale leaves real",
            "retail systems with negative on-hand every single day, and any converted",
            "report that assumes non-negative stock is wrong before it starts."),
        arrays=(
            ("a_loc", "NUMBER"), ("a_var", "NUMBER"), ("a_onhand", "NUMBER"),
            ("a_res", "NUMBER"), ("a_rp", "NUMBER"), ("a_rq", "NUMBER"),
            ("a_counted", "DATE"), ("a_moved", "TIMESTAMP WITH LOCAL TIME ZONE"),
        ),
        decls=("v_k PLS_INTEGER;",),
        fill=(
            "v_k := v_r - 1;",
            "a_loc(i) := 1 + MOD(v_k, %d);" % n_loc,
            "a_var(i) := 1 + MOD(TRUNC(v_k / %d), %d);" % (n_loc, n_var),
            "a_onhand(i) := CASE",
            "                  WHEN MOD(v_r, 40) = 0 THEN -1 * (1 + nxt(30))",
            "                  WHEN MOD(v_r, 17) = 0 THEN 0",
            "                  ELSE ROUND(nxt(4000) + nxt(1000) / 1000, 3)",
            "               END;",
            "a_res(i)     := ROUND(nxt(40) + nxt(1000) / 1000, 3);",
            "a_rp(i)      := maybe_n(5 + nxt(200), 6);",
            "a_rq(i)      := maybe_n(10 + nxt(500), 6);",
            "a_counted(i) := maybe_d(%s + nxt(%d), 5);" % (dt(FACT_START), FACT_DAYS),
            "a_moved(i)   := CAST(%s AS TIMESTAMP)" % dt(FACT_START),
            "                + NUMTODSINTERVAL(MOD(v_r - 1, %d) * 86400" % FACT_DAYS,
            "                                  + nxt(86400), 'SECOND');",
        ),
        columns=("location_id", "variant_id", "qty_on_hand", "qty_reserved",
                 "reorder_point", "reorder_qty", "last_counted_date",
                 "last_movement_ts"),
        values=("a_loc(i)", "a_var(i)", "a_onhand(i)", "a_res(i)", "a_rp(i)",
                "a_rq(i)", "a_counted(i)", "a_moved(i)"),
    ))

    parts.append("\nPROMPT inventory_movement (range + list composite partitioning)")
    parts.append(bulk_block(
        table="inventory_movement", rows=plan["inventory_movement"], seed=seed + 72,
        batch=batch,
        comment=scenario_note(
            "PARTITION BY RANGE (movement_ts) INTERVAL (1 month) SUBPARTITION BY LIST",
            "(movement_type). Both dimensions have to be populated or the composite",
            "partitioning is untested (H-19, H-20): movement_ts walks the full two",
            "years and movement_type cycles through all seven values.",
            "qty is signed by movement type. SALE, SHRINK and TRANSFER-out are",
            "negative; COUNT adjustments are frequently exactly zero, which is the",
            "one movement type ck_movement_qty lets through at zero. A ledger of",
            "positive numbers would not exercise a single SUM() sign convention."),
        varrays=(("v_type", ("RECEIPT", "SALE", "RETURN", "TRANSFER",
                             "ADJUST", "SHRINK", "COUNT")),
                 ("v_ref", ("SALES_ORDER", "PURCHASE_ORDER", "RETURN_REQUEST",
                            "STOCK_COUNT", "MANUAL")),),
        arrays=(
            ("a_id", "NUMBER"), ("a_ts", "TIMESTAMP(6)"), ("a_var", "NUMBER"),
            ("a_from", "NUMBER"), ("a_to", "NUMBER"), ("a_type", "VARCHAR2(20)"),
            ("a_qty", "NUMBER"), ("a_reftype", "VARCHAR2(20)"), ("a_refid", "NUMBER"),
        ),
        decls=("v_ti PLS_INTEGER;",),
        fill=(
            "v_ti := 1 + MOD(v_r - 1, 7);",
            "a_id(i)   := v_r;",
            "a_ts(i)   := CAST(%s AS TIMESTAMP)" % dt(FACT_START),
            "             + NUMTODSINTERVAL(MOD(v_r - 1, %d) * 86400" % FACT_DAYS,
            "                               + nxt(86400), 'SECOND');",
            "a_var(i)  := 1 + MOD(v_r - 1, %d);" % n_var,
            "a_type(i) := v_type(v_ti);",
            "-- from/to depend on direction, and one of them is NULL for the",
            "-- endpoints of the ledger (a receipt has no source, a sale no target).",
            "a_from(i) := CASE WHEN v_ti IN (2, 4, 6) THEN 1 + MOD(v_r - 1, %d) END;"
            % n_loc,
            "a_to(i)   := CASE WHEN v_ti IN (1, 3, 4, 5) THEN",
            "                     1 + MOD(v_r * 3 - 1, %d) END;" % n_loc,
            "a_qty(i)  := CASE v_ti",
            "                WHEN 2 THEN -1 * ROUND(1 + nxt(20) + nxt(1000) / 1000, 3)",
            "                WHEN 6 THEN -1 * ROUND(1 + nxt(5), 3)",
            "                WHEN 7 THEN CASE WHEN MOD(v_r, 3) = 0 THEN 0",
            "                                 ELSE ROUND(nxt(20) - 10, 3) END",
            "                -- TRANSFER is signed both ways but never exactly zero:",
            "                -- ck_movement_qty allows a zero only for a COUNT.",
            "                WHEN 4 THEN CASE WHEN MOD(v_r, 2) = 0",
            "                                 THEN  ROUND(1 + nxt(30) + nxt(1000) / 1000, 3)",
            "                                 ELSE -ROUND(1 + nxt(30) + nxt(1000) / 1000, 3)",
            "                            END",
            "                ELSE ROUND(1 + nxt(200) + nxt(1000) / 1000, 3)",
            "             END;",
            "a_reftype(i) := pick(v_ref);",
            "a_refid(i)   := maybe_n(1 + MOD(v_r - 1, %d), 9);" % plan["sales_order"],
        ),
        columns=("movement_id", "movement_ts", "variant_id", "from_location_id",
                 "to_location_id", "movement_type", "qty", "reference_type",
                 "reference_id", "created_by"),
        values=("a_id(i)", "a_ts(i)", "a_var(i)", "a_from(i)", "a_to(i)",
                "a_type(i)", "a_qty(i)", "a_reftype(i)", "a_refid(i)", "'SEED_LOAD'"),
    ))

    return "\n\n".join(parts)


CARRIER_CODES: Sequence[str] = (
    "DPD", "DHL", "UPS", "FEDEX", "ROYALMAIL", "ANPOST", "COLISSIMO", "DHLDE",
    "CORREOS", "POSTNORD", "CONTOSOVAN", "LOCALCOUR",
)

REASON_CODES: Sequence[str] = (
    "DAMAGED", "FAULTY", "WRONG_ITEM", "WRONG_SIZE", "TOO_SMALL", "TOO_LARGE",
    "NOT_AS_DESC", "CHANGED_MIND", "LATE", "DUPLICATE", "PRICE_MATCH",
    "GIFT_RETURN", "MISSING_PART", "EXPIRED", "RECALL", "ALLERGEN", "COLOUR",
    "QUALITY_LOW", "DELIVERY_DMG", "NEVER_ARRIVED", "WARRANTY", "TRADE_IN",
    "BULK_REJECT", "OTHER",
)


# --------------------------------------------------------------------------
# 10 -- orders and fulfilment
# --------------------------------------------------------------------------

def file_orders(plan: Dict[str, int], seed: int, batch: int) -> str:
    n_so = plan["sales_order"]
    n_ship = plan["shipment"]
    parts: List[str] = ["PROMPT === orders and fulfilment ==="]

    parts.append("\nPROMPT sales_order (RANGE INTERVAL partitioned, 30 days)")
    parts.append(bulk_block(
        table="sales_order", rows=n_so, seed=seed + 80, batch=batch,
        comment=scenario_note(
            "PARTITION BY RANGE (order_ts) INTERVAL (NUMTODSINTERVAL(30,'DAY')).",
            "order_ts walks all %d days of the two trading years, so every 30-day"
            % FACT_DAYS,
            "interval partition materialises -- roughly 25 of them. An interval",
            "partitioned table with data in one partition tests nothing (H-19).",
            "THE SHARP EDGE: the primary key is (order_id) alone, a GLOBAL unique index",
            "that does NOT include the partition key. PostgreSQL flatly requires every",
            "unique constraint on a partitioned table to include all partition columns,",
            "and there is no workaround that keeps both. Widening the key to",
            "(order_id, order_ts) breaks every foreign key that referenced it. This is",
            "the single most disruptive item in the lab and it sits on the busiest",
            "table on purpose.",
            "order_total is VIRTUAL and is not loaded (H-17).",
            "order_ts is TIMESTAMP WITH LOCAL TIME ZONE (H-37)."),
        varrays=(
            ("v_chan", ("POS", "POS", "WEB", "WEB", "APP", "CALL", "KIOSK", "PARTNER")),
            ("v_status", ("PLACED", "PICKING", "SHIPPED", "DELIVERED",
                          "DELIVERED", "CANCELLED", "RETURNED", "CART")),
        ),
        arrays=(
            ("a_id", "NUMBER"), ("a_num", "VARCHAR2(24)"), ("a_cust", "NUMBER"),
            ("a_store", "NUMBER"), ("a_chan", "VARCHAR2(20)"),
            ("a_ts", "TIMESTAMP WITH LOCAL TIME ZONE"), ("a_status", "VARCHAR2(20)"),
            ("a_ccy", "VARCHAR2(3)"), ("a_sub", "NUMBER"), ("a_disc", "NUMBER"),
            ("a_tax", "NUMBER"), ("a_ship", "NUMBER"), ("a_shipaddr", "NUMBER"),
            ("a_billaddr", "NUMBER"), ("a_promo", "NUMBER"), ("a_coupon", "NUMBER"),
            ("a_emp", "NUMBER"), ("a_ip", "VARCHAR2(45)"),
        ),
        decls=_plsql_country_varrays(),
        fill=(
            "a_id(i)     := v_r;",
            "a_num(i)    := 'SO' || LPAD(TO_CHAR(v_r), 14, '0');",
            "-- One order in eleven is a guest checkout with no customer at all.",
            "a_cust(i)   := maybe_n(1 + MOD(v_r - 1, %d), 11);" % plan["customer"],
            "a_store(i)  := 1 + MOD(v_r - 1, %d);" % plan["store"],
            "a_chan(i)   := pick(v_chan);",
            "a_ts(i)     := CAST(%s AS TIMESTAMP)" % dt(FACT_START),
            "               + NUMTODSINTERVAL(MOD(v_r - 1, %d) * 86400" % FACT_DAYS,
            "                                 + nxt(86400), 'SECOND');",
            "a_status(i) := pick(v_status);",
            "a_ccy(i)    := v_ccy(1 + MOD(a_store(i) - 1, 40));",
            "a_sub(i)    := ROUND(2 + nxt(80000) / 100, 2);",
            "a_disc(i)   := ROUND(a_sub(i) * nxt(30) / 100, 2);",
            "a_tax(i)    := ROUND((a_sub(i) - a_disc(i)) * 0.2, 2);",
            "a_ship(i)   := CASE WHEN a_chan(i) IN ('WEB', 'APP', 'PARTNER')",
            "                    THEN ROUND(nxt(1200) / 100, 2) ELSE 0 END;",
            "a_shipaddr(i) := maybe_n(1 + MOD(v_r * 3 - 1, %d), 6);" % plan["address"],
            "a_billaddr(i) := maybe_n(1 + MOD(v_r * 7 - 1, %d), 8);" % plan["address"],
            "a_promo(i)  := maybe_n(1 + MOD(v_r - 1, %d), 4);" % plan["promotion"],
            "a_coupon(i) := maybe_n(1 + MOD(v_r - 1, %d), 6);" % plan["coupon"],
            "a_emp(i)    := maybe_n(1 + MOD(v_r - 1, %d), 3);" % plan["employee"],
            "-- IPv4 for most, IPv6 for some. VARCHAR2(45) exists for the IPv6 case and",
            "-- PostgreSQL's inet type is the obvious better target -- which changes",
            "-- every comparison written against it.",
            "a_ip(i)     := CASE WHEN MOD(v_r, 13) = 0",
            "                    THEN '2001:0db8:85a3:0000:0000:8a2e:'",
            "                         || TO_CHAR(1000 + nxt(8999)) || ':7334'",
            "                    ELSE TO_CHAR(10 + nxt(240)) || '.'",
            "                         || TO_CHAR(nxt(256)) || '.'",
            "                         || TO_CHAR(nxt(256)) || '.'",
            "                         || TO_CHAR(1 + nxt(254)) END;",
        ),
        columns=("order_id", "order_number", "customer_id", "store_id", "channel_code",
                 "order_ts", "status", "currency_code", "subtotal_amount",
                 "discount_amount", "tax_amount", "shipping_amount", "ship_address_id",
                 "bill_address_id", "promotion_id", "coupon_id", "sales_employee_id",
                 "source_ip"),
        values=("a_id(i)", "a_num(i)", "a_cust(i)", "a_store(i)", "a_chan(i)",
                "a_ts(i)", "a_status(i)", "a_ccy(i)", "a_sub(i)", "a_disc(i)",
                "a_tax(i)", "a_ship(i)", "a_shipaddr(i)", "a_billaddr(i)",
                "a_promo(i)", "a_coupon(i)", "a_emp(i)", "a_ip(i)"),
    ))

    parts.append("\nPROMPT sales_order_line (PARTITION BY REFERENCE)")
    parts.append(bulk_block(
        table="sales_order_line", rows=plan["sales_order_line"], seed=seed + 81,
        batch=batch,
        comment=scenario_note(
            "PARTITION BY REFERENCE (fk_sol_order): the child inherits the parent's",
            "partitioning through the foreign key. PostgreSQL has NO equivalent (H-20).",
            "The child has to be partitioned independently on a copied order_ts column,",
            "which means denormalising the partition key onto every line.",
            "qty has CHECK (> 0), so this table cannot carry the zero and negative",
            "quantities -- those live in inventory_movement, where they belong.",
            "line_total is VIRTUAL and is not loaded."),
        varrays=(("v_status", ("ALLOCATED", "PICKED", "SHIPPED", "CANCELLED",
                               "BACKORDER")),),
        arrays=(
            ("a_order", "NUMBER"), ("a_line", "NUMBER"), ("a_var", "NUMBER"),
            ("a_qty", "NUMBER"), ("a_price", "NUMBER"), ("a_disc", "NUMBER"),
            ("a_tax", "NUMBER"), ("a_taxamt", "NUMBER"), ("a_loc", "NUMBER"),
            ("a_status", "VARCHAR2(20)"),
        ),
        decls=("v_k PLS_INTEGER;",),
        fill=(
            "v_k := v_r - 1;",
            "a_order(i) := 1 + MOD(v_k, %d);" % n_so,
            "a_line(i)  := 1 + TRUNC(v_k / %d);" % n_so,
            "a_var(i)   := 1 + MOD(v_r * 13 - 1, %d);" % plan["product_variant"],
            "a_qty(i)   := 1 + nxt(9) + nxt(1000) / 1000;   -- CHECK (qty > 0)",
            "a_price(i) := ROUND(0.5 + nxt(40000) / 100, 4);",
            "a_disc(i)  := ROUND(a_price(i) * nxt(25) / 100, 4);",
            "a_tax(i)   := maybe_n(1 + MOD(v_r - 1, %d), 5);" % plan["tax_rate"],
            "a_taxamt(i) := ROUND((a_price(i) * a_qty(i) - a_disc(i)) * 0.2, 4);",
            "a_loc(i)   := maybe_n(1 + MOD(v_r - 1, %d), 4);"
            % plan["inventory_location"],
            "a_status(i) := pick(v_status);",
        ),
        columns=("order_id", "line_no", "variant_id", "qty", "unit_price",
                 "discount_amount", "tax_rate_id", "tax_amount",
                 "fulfil_location_id", "status"),
        values=("a_order(i)", "a_line(i)", "a_var(i)", "a_qty(i)", "a_price(i)",
                "a_disc(i)", "a_tax(i)", "a_taxamt(i)", "a_loc(i)", "a_status(i)"),
    ))

    parts.append("\nPROMPT order_payment")
    parts.append(bulk_block(
        table="order_payment", rows=plan["order_payment"], seed=seed + 82, batch=batch,
        comment=scenario_note(
            "card_token is an opaque token, never a PAN. It becomes the pgcrypto demo",
            "on the target. Nothing here is or resembles a real card number.",
            "refunded_ts is populated on a minority of rows so the refund path has",
            "something to find."),
        varrays=(("v_method", ("CARD", "CARD", "CARD", "CASH", "VOUCHER",
                               "LOYALTY", "GIFTCARD", "BNPL", "ACCOUNT")),
                 ("v_status", ("AUTHORISED", "CAPTURED", "CAPTURED", "REFUNDED",
                               "DECLINED")),),
        arrays=(
            ("a_id", "NUMBER"), ("a_order", "NUMBER"), ("a_method", "VARCHAR2(20)"),
            ("a_amt", "NUMBER"), ("a_ccy", "VARCHAR2(3)"), ("a_auth", "VARCHAR2(30)"),
            ("a_token", "VARCHAR2(64)"),
            ("a_authts", "TIMESTAMP WITH LOCAL TIME ZONE"),
            ("a_capts", "TIMESTAMP WITH LOCAL TIME ZONE"),
            ("a_refts", "TIMESTAMP WITH LOCAL TIME ZONE"),
            ("a_status", "VARCHAR2(15)"),
        ),
        decls=_plsql_country_varrays(),
        fill=(
            "a_id(i)     := v_r;",
            "a_order(i)  := 1 + MOD(v_r - 1, %d);" % n_so,
            "a_method(i) := pick(v_method);",
            "a_amt(i)    := ROUND(2 + nxt(90000) / 100, 2);",
            "a_ccy(i)    := v_ccy(1 + MOD(a_order(i) - 1, 40));",
            "a_auth(i)   := maybe(UPPER(TO_CHAR(v_r, 'FMXXXXXXXX'))",
            "                     || LPAD(TO_CHAR(nxt(999999)), 6, '0'), 9);",
            "a_token(i)  := CASE WHEN a_method(i) = 'CARD'",
            "                    THEN 'tok_' || LPAD(TO_CHAR(v_r), 20, '0')",
            "                         || '_' || TO_CHAR(100000 + nxt(899999)) END;",
            "a_authts(i) := CAST(%s AS TIMESTAMP)" % dt(FACT_START),
            "               + NUMTODSINTERVAL(MOD(v_r - 1, %d) * 86400" % FACT_DAYS,
            "                                 + nxt(86400), 'SECOND');",
            "a_capts(i)  := CASE WHEN MOD(v_r, 9) <> 0",
            "                    THEN a_authts(i)",
            "                         + NUMTODSINTERVAL(nxt(90000), 'SECOND') END;",
            "a_refts(i)  := CASE WHEN MOD(v_r, 23) = 0",
            "                    THEN a_authts(i)",
            "                         + NUMTODSINTERVAL(nxt(3000000), 'SECOND') END;",
            "a_status(i) := CASE WHEN a_refts(i) IS NOT NULL THEN 'REFUNDED'",
            "                    ELSE pick(v_status) END;",
        ),
        columns=("payment_id", "order_id", "payment_method", "amount",
                 "currency_code", "auth_code", "card_token", "authorised_ts",
                 "captured_ts", "refunded_ts", "status"),
        values=("a_id(i)", "a_order(i)", "a_method(i)", "a_amt(i)", "a_ccy(i)",
                "a_auth(i)", "a_token(i)", "a_authts(i)", "a_capts(i)",
                "a_refts(i)", "a_status(i)"),
    ))

    parts.append("\nPROMPT shipment")
    parts.append(bulk_block(
        table="shipment", rows=n_ship, seed=seed + 83, batch=batch,
        comment=scenario_note(
            "transit_time is INTERVAL DAY(3) TO SECOND(0), computed as the difference",
            "between two TIMESTAMP WITH LOCAL TIME ZONE values. PostgreSQL's",
            "justify_interval normalisation differs from Oracle's, so these may FORMAT",
            "differently after conversion even when they compare equal (H-36)."),
        varrays=(("v_carrier", CARRIER_CODES),
                 ("v_service", ("NEXT_DAY", "STANDARD", "ECONOMY", "SAME_DAY")),
                 ("v_status", ("BOOKED", "IN_TRANSIT", "DELIVERED", "DELIVERED",
                               "EXCEPTION")),),
        arrays=(
            ("a_id", "NUMBER"), ("a_order", "NUMBER"), ("a_carrier", "VARCHAR2(12)"),
            ("a_service", "VARCHAR2(30)"), ("a_track", "VARCHAR2(60)"),
            ("a_loc", "NUMBER"),
            ("a_shipped", "TIMESTAMP WITH LOCAL TIME ZONE"),
            ("a_delivered", "TIMESTAMP WITH LOCAL TIME ZONE"),
            ("a_transit", "INTERVAL DAY(3) TO SECOND(0)"),
            ("a_wt", "NUMBER"), ("a_status", "VARCHAR2(20)"),
        ),
        fill=(
            "a_id(i)      := v_r;",
            "a_order(i)   := 1 + MOD(v_r - 1, %d);" % n_so,
            "a_carrier(i) := pick(v_carrier);",
            "a_service(i) := pick(v_service);",
            "a_track(i)   := maybe(a_carrier(i) || LPAD(TO_CHAR(v_r), 14, '0'), 12);",
            "a_loc(i)     := maybe_n(1 + MOD(v_r * 2 - 1, %d), 7);"
            % plan["inventory_location"],
            "a_shipped(i) := CAST(%s AS TIMESTAMP)" % dt(FACT_START),
            "                + NUMTODSINTERVAL(MOD(v_r - 1, %d) * 86400" % FACT_DAYS,
            "                                  + nxt(86400), 'SECOND');",
            "a_delivered(i) := CASE WHEN MOD(v_r, 7) <> 0",
            "                       THEN a_shipped(i)",
            "                            + NUMTODSINTERVAL(3600 + nxt(400000),",
            "                                              'SECOND') END;",
            "a_transit(i) := CASE WHEN a_delivered(i) IS NOT NULL",
            "                     THEN (a_delivered(i) - a_shipped(i))",
            "                          DAY(3) TO SECOND(0) END;",
            "a_wt(i)      := maybe_n(ROUND(nxt(40000) / 1000, 3), 8);",
            "a_status(i)  := CASE WHEN a_delivered(i) IS NOT NULL THEN 'DELIVERED'",
            "                     ELSE pick(v_status) END;",
        ),
        columns=("shipment_id", "order_id", "carrier_code", "service_level",
                 "tracking_ref", "from_location_id", "shipped_ts", "delivered_ts",
                 "transit_time", "weight_kg", "status"),
        values=("a_id(i)", "a_order(i)", "a_carrier(i)", "a_service(i)",
                "a_track(i)", "a_loc(i)", "a_shipped(i)", "a_delivered(i)",
                "a_transit(i)", "a_wt(i)", "a_status(i)"),
    ))

    parts.append("\nPROMPT shipment_line")
    parts.append(bulk_block(
        table="shipment_line", rows=plan["shipment_line"], seed=seed + 84, batch=batch,
        comment=scenario_note(
            "Supports partial shipment of an order line. order_line_no is limited to",
            "1 and 2 because every order is guaranteed at least two lines, so the",
            "composite foreign key to sales_order_line always resolves."),
        arrays=(
            ("a_ship", "NUMBER"), ("a_line", "NUMBER"), ("a_order", "NUMBER"),
            ("a_oline", "NUMBER"), ("a_qty", "NUMBER"),
        ),
        decls=("v_k PLS_INTEGER;",),
        fill=(
            "v_k := v_r - 1;",
            "a_ship(i)  := 1 + MOD(v_k, %d);" % n_ship,
            "a_line(i)  := 1 + TRUNC(v_k / %d);" % n_ship,
            "-- The shipment's own order, so the line really belongs to the shipment.",
            "a_order(i) := 1 + MOD(a_ship(i) - 1, %d);" % n_so,
            "a_oline(i) := 1 + MOD(v_k, 2);",
            "a_qty(i)   := 1 + nxt(6) + nxt(1000) / 1000;",
        ),
        columns=("shipment_id", "line_no", "order_id", "order_line_no", "qty_shipped"),
        values=("a_ship(i)", "a_line(i)", "a_order(i)", "a_oline(i)", "a_qty(i)"),
    ))

    return "\n\n".join(parts)


# --------------------------------------------------------------------------
# 11 -- procurement
# --------------------------------------------------------------------------

def file_procurement(plan: Dict[str, int], seed: int, batch: int) -> str:
    n_po = plan["purchase_order"]
    parts: List[str] = ["PROMPT === procurement ==="]

    parts.append("\nPROMPT purchase_order (RANGE INTERVAL partitioned, monthly)")
    parts.append(bulk_block(
        table="purchase_order", rows=n_po, seed=seed + 90, batch=batch,
        comment=scenario_note(
            "PARTITION BY RANGE (order_date) INTERVAL (NUMTOYMINTERVAL(1,'MONTH')).",
            "order_date walks two full years so all 24 monthly partitions materialise.",
            "TRAP T-02: order_date is an Oracle DATE and therefore carries a time to",
            "the second. Converting it to a PostgreSQL date silently truncates that;",
            "timestamp is almost always the right target. The loader puts a real time",
            "component on every row so the truncation is measurable, not theoretical.",
            "Like sales_order, the primary key is po_id alone -- a global index that",
            "excludes the partition key (H-19)."),
        varrays=(("v_status", ("DRAFT", "SENT", "SENT", "PART_RECV",
                               "RECEIVED", "RECEIVED", "CANCELLED")),),
        arrays=(
            ("a_id", "NUMBER"), ("a_num", "VARCHAR2(20)"), ("a_sup", "NUMBER"),
            ("a_wh", "NUMBER"), ("a_date", "DATE"), ("a_exp", "DATE"),
            ("a_status", "VARCHAR2(15)"), ("a_ccy", "VARCHAR2(3)"),
            ("a_total", "NUMBER"), ("a_appr", "NUMBER"),
        ),
        decls=_plsql_country_varrays(),
        fill=(
            "a_id(i)     := v_r;",
            "a_num(i)    := 'PO' || LPAD(TO_CHAR(v_r), 14, '0');",
            "a_sup(i)    := 1 + MOD(v_r - 1, %d);" % plan["supplier"],
            "a_wh(i)     := 1 + MOD(v_r - 1, %d);" % plan["warehouse"],
            "-- DATE with a genuine time component (trap T-02).",
            "a_date(i)   := %s + MOD(v_r - 1, %d)" % (dt(FACT_START), FACT_DAYS),
            "               + (nxt(86400) / 86400);",
            "a_exp(i)    := a_date(i) + 3 + nxt(40);",
            "a_status(i) := pick(v_status);",
            "a_ccy(i)    := v_ccy(1 + MOD(a_sup(i) - 1, 40));",
            "a_total(i)  := maybe_n(ROUND(100 + nxt(500000) / 10, 2), 12);",
            "a_appr(i)   := CASE WHEN a_status(i) <> 'DRAFT'",
            "                    THEN 1 + MOD(v_r - 1, %d) END;" % plan["employee"],
        ),
        columns=("po_id", "po_number", "supplier_id", "warehouse_id", "order_date",
                 "expected_date", "status", "currency_code", "order_total",
                 "created_by", "approved_by_employee_id"),
        values=("a_id(i)", "a_num(i)", "a_sup(i)", "a_wh(i)", "a_date(i)",
                "a_exp(i)", "a_status(i)", "a_ccy(i)", "a_total(i)",
                "'SEED_LOAD'", "a_appr(i)"),
    ))

    parts.append("\nPROMPT purchase_order_line")
    parts.append(bulk_block(
        table="purchase_order_line", rows=plan["purchase_order_line"], seed=seed + 91,
        batch=batch,
        comment=scenario_note(
            "Exactly three lines per purchase order, which is what lets goods_receipt",
            "reference (po_id, po_line_no) with no risk of a dangling composite key.",
            "qty_ordered has CHECK (> 0). qty_received is deliberately allowed to",
            "exceed it on some rows: over-delivery inside tolerance is a real thing and",
            "pkg_receiving exists to handle it.",
            "line_total is VIRTUAL and is not loaded."),
        varrays=(("v_status", ("OPEN", "PART_RECV", "RECEIVED", "CANCELLED")),),
        arrays=(
            ("a_po", "NUMBER"), ("a_line", "NUMBER"), ("a_var", "NUMBER"),
            ("a_ord", "NUMBER"), ("a_recv", "NUMBER"), ("a_cost", "NUMBER"),
            ("a_exp", "DATE"), ("a_status", "VARCHAR2(15)"),
        ),
        decls=("v_k PLS_INTEGER;",),
        fill=(
            "v_k := v_r - 1;",
            "a_po(i)   := 1 + MOD(v_k, %d);" % n_po,
            "a_line(i) := 1 + TRUNC(v_k / %d);" % n_po,
            "a_var(i)  := 1 + MOD(v_r * 11 - 1, %d);" % plan["product_variant"],
            "a_ord(i)  := 6 * (1 + nxt(40));   -- CHECK (qty_ordered > 0)",
            "a_recv(i) := CASE MOD(v_r, 7)",
            "                WHEN 0 THEN 0",
            "                WHEN 1 THEN a_ord(i) + 6      -- over-delivery",
            "                WHEN 2 THEN ROUND(a_ord(i) / 2, 3)",
            "                ELSE a_ord(i)",
            "             END;",
            "a_cost(i) := ROUND(0.4 + nxt(30000) / 100, 4);",
            "a_exp(i)  := maybe_d(%s + MOD(v_r - 1, %d) + 7, 6);"
            % (dt(FACT_START), FACT_DAYS),
            "a_status(i) := pick(v_status);",
        ),
        columns=("po_id", "line_no", "variant_id", "qty_ordered", "qty_received",
                 "unit_cost", "expected_date", "status"),
        values=("a_po(i)", "a_line(i)", "a_var(i)", "a_ord(i)", "a_recv(i)",
                "a_cost(i)", "a_exp(i)", "a_status(i)"),
    ))

    parts.append("\nPROMPT goods_receipt")
    parts.append(bulk_block(
        table="goods_receipt", rows=plan["goods_receipt"], seed=seed + 92, batch=batch,
        comment=scenario_note(
            "Composite foreign key (po_id, po_line_no) -> purchase_order_line.",
            "qty_rejected is zero on most rows and non-zero on the quality failures,",
            "which is what pkg_receiving's FORALL ... SAVE EXCEPTIONS quarantines."),
        arrays=(
            ("a_id", "NUMBER"), ("a_num", "VARCHAR2(20)"), ("a_po", "NUMBER"),
            ("a_line", "NUMBER"), ("a_wh", "NUMBER"),
            ("a_ts", "TIMESTAMP WITH LOCAL TIME ZONE"),
            ("a_recv", "NUMBER"), ("a_rej", "NUMBER"), ("a_emp", "NUMBER"),
        ),
        fill=(
            "a_id(i)   := v_r;",
            "a_num(i)  := 'GR' || LPAD(TO_CHAR(v_r), 14, '0');",
            "a_po(i)   := 1 + MOD(v_r - 1, %d);" % n_po,
            "a_line(i) := 1 + MOD(v_r - 1, 3);",
            "a_wh(i)   := 1 + MOD(a_po(i) - 1, %d);   -- the PO's own warehouse"
            % plan["warehouse"],
            "a_ts(i)   := CAST(%s AS TIMESTAMP)" % dt(FACT_START),
            "            + NUMTODSINTERVAL(MOD(v_r - 1, %d) * 86400" % FACT_DAYS,
            "                              + nxt(86400), 'SECOND');",
            "a_recv(i) := 6 * (1 + nxt(30));",
            "a_rej(i)  := CASE WHEN MOD(v_r, 11) = 0 THEN ROUND(a_recv(i) / 6, 3)",
            "                  ELSE 0 END;",
            "a_emp(i)  := maybe_n(1 + MOD(v_r - 1, %d), 10);" % plan["employee"],
        ),
        columns=("receipt_id", "receipt_number", "po_id", "po_line_no", "warehouse_id",
                 "received_ts", "qty_received", "qty_rejected",
                 "received_by_employee_id"),
        values=("a_id(i)", "a_num(i)", "a_po(i)", "a_line(i)", "a_wh(i)", "a_ts(i)",
                "a_recv(i)", "a_rej(i)", "a_emp(i)"),
    ))

    return "\n\n".join(parts)


# --------------------------------------------------------------------------
# 12 -- returns
# --------------------------------------------------------------------------

def file_returns(plan: Dict[str, int], seed: int, batch: int) -> str:
    n_rr = plan["return_request"]
    n_so = plan["sales_order"]
    parts: List[str] = ["PROMPT === returns ==="]

    parts.append("\nPROMPT return_request")
    parts.append(bulk_block(
        table="return_request", rows=n_rr, seed=seed + 100, batch=batch,
        comment=scenario_note(
            "return_id maps onto an order deterministically, so return_line can derive",
            "the same order without a lookup and the composite foreign key to",
            "sales_order_line always resolves."),
        varrays=(("v_status", ("REQUESTED", "APPROVED", "REJECTED", "RECEIVED",
                               "REFUNDED", "REFUNDED", "CLOSED")),),
        arrays=(
            ("a_id", "NUMBER"), ("a_rma", "VARCHAR2(24)"), ("a_order", "NUMBER"),
            ("a_cust", "NUMBER"), ("a_store", "NUMBER"),
            ("a_ts", "TIMESTAMP WITH LOCAL TIME ZONE"), ("a_status", "VARCHAR2(20)"),
            ("a_refund", "NUMBER"), ("a_ccy", "VARCHAR2(3)"), ("a_appr", "NUMBER"),
            ("a_closed", "TIMESTAMP WITH LOCAL TIME ZONE"),
        ),
        decls=_plsql_country_varrays(),
        fill=(
            "a_id(i)     := v_r;",
            "a_rma(i)    := 'RMA' || LPAD(TO_CHAR(v_r), 12, '0');",
            "a_order(i)  := 1 + MOD(v_r - 1, %d);" % n_so,
            "a_cust(i)   := maybe_n(1 + MOD(v_r - 1, %d), 8);" % plan["customer"],
            "a_store(i)  := maybe_n(1 + MOD(v_r - 1, %d), 6);" % plan["store"],
            "a_ts(i)     := CAST(%s AS TIMESTAMP)" % dt(FACT_START),
            "               + NUMTODSINTERVAL(MOD(v_r - 1, %d) * 86400" % FACT_DAYS,
            "                                 + nxt(86400), 'SECOND');",
            "a_status(i) := pick(v_status);",
            "a_refund(i) := maybe_n(ROUND(1 + nxt(40000) / 100, 2), 5);",
            "a_ccy(i)    := v_ccy(1 + MOD(a_order(i) - 1, 40));",
            "a_appr(i)   := CASE WHEN a_status(i) IN ('APPROVED', 'REFUNDED', 'CLOSED')",
            "                    THEN 1 + MOD(v_r - 1, %d) END;" % plan["employee"],
            "a_closed(i) := CASE WHEN a_status(i) = 'CLOSED'",
            "                    THEN a_ts(i)",
            "                         + NUMTODSINTERVAL(nxt(2000000), 'SECOND') END;",
        ),
        columns=("return_id", "rma_number", "order_id", "customer_id", "store_id",
                 "requested_ts", "status", "refund_amount", "currency_code",
                 "approved_by_employee_id", "closed_ts"),
        values=("a_id(i)", "a_rma(i)", "a_order(i)", "a_cust(i)", "a_store(i)",
                "a_ts(i)", "a_status(i)", "a_refund(i)", "a_ccy(i)", "a_appr(i)",
                "a_closed(i)"),
    ))

    parts.append("\nPROMPT return_line")
    parts.append(bulk_block(
        table="return_line", rows=plan["return_line"], seed=seed + 101, batch=batch,
        comment=scenario_note(
            "order_id is derived from the return's own order, so the composite foreign",
            "key (order_id, order_line_no) -> sales_order_line always resolves.",
            "Every disposition code is used, because pkg_returns.post_disposition",
            "branches on all five."),
        varrays=(("v_reason", REASON_CODES),
                 ("v_disp", ("RESTOCK", "RESTOCK", "SCRAP", "REPAIR",
                             "SUPPLIER", "DONATE")),),
        arrays=(
            ("a_ret", "NUMBER"), ("a_line", "NUMBER"), ("a_order", "NUMBER"),
            ("a_oline", "NUMBER"), ("a_var", "NUMBER"), ("a_qty", "NUMBER"),
            ("a_reason", "VARCHAR2(20)"), ("a_disp", "VARCHAR2(20)"),
            ("a_refund", "NUMBER"),
        ),
        decls=("v_k PLS_INTEGER;",),
        fill=(
            "v_k := v_r - 1;",
            "a_ret(i)   := 1 + MOD(v_k, %d);" % n_rr,
            "a_line(i)  := 1 + TRUNC(v_k / %d);" % n_rr,
            "a_order(i) := 1 + MOD(a_ret(i) - 1, %d);" % n_so,
            "a_oline(i) := 1 + MOD(v_k, 2);",
            "a_var(i)   := maybe_n(1 + MOD(v_r * 17 - 1, %d), 12);"
            % plan["product_variant"],
            "a_qty(i)   := 1 + nxt(3);",
            "a_reason(i) := pick(v_reason);",
            "a_disp(i)   := pick(v_disp);",
            "a_refund(i) := maybe_n(ROUND(1 + nxt(20000) / 100, 4), 6);",
        ),
        columns=("return_id", "line_no", "order_id", "order_line_no", "variant_id",
                 "qty_returned", "reason_code", "disposition_code", "refund_amount"),
        values=("a_ret(i)", "a_line(i)", "a_order(i)", "a_oline(i)", "a_var(i)",
                "a_qty(i)", "a_reason(i)", "a_disp(i)", "a_refund(i)"),
    ))

    return "\n\n".join(parts)


# --------------------------------------------------------------------------
# 13 -- finance and the general ledger
# --------------------------------------------------------------------------

def file_finance(plan: Dict[str, int], seed: int, batch: int) -> str:
    n_gj  = plan["gl_journal"]
    n_gjl = plan["gl_journal_line"]
    # Every journal must balance, and the balancing scheme below (the final line
    # of a journal offsets the sum of the others) needs every journal to have
    # the same, known number of lines. That holds only when the line count is a
    # whole multiple of the journal count. It is at every --scale (2400/800 = 3,
    # and the factor cancels), so guard the invariant rather than silently
    # emitting journals that cannot balance.
    if n_gjl % n_gj != 0:
        raise ValueError(
            "gl_journal_line (%d) must be a whole multiple of gl_journal (%d) so "
            "every journal has the same line count and can be balanced; got "
            "remainder %d. Fix the SCALABLE_ROWS ratio." % (n_gjl, n_gj, n_gjl % n_gj))
    lines_per_journal = n_gjl // n_gj
    parts: List[str] = ["PROMPT === finance and general ledger ==="]

    parts.append("\nPROMPT gl_journal")
    parts.append(bulk_block(
        table="gl_journal", rows=n_gj, seed=seed + 110, batch=batch,
        comment=scenario_note(
            "reversal_of_journal_id is a self-referencing foreign key pointing at an",
            "EARLIER journal, so one FORALL loads it without deferring anything.",
            "journal_date is an Oracle DATE with a time component (trap T-02)."),
        varrays=(("v_module", ("SALES", "SALES", "RETURNS", "PURCHASING",
                               "INVENTORY", "PAYROLL", "MANUAL")),
                 ("v_status", ("DRAFT", "POSTED", "POSTED", "POSTED", "REVERSED")),),
        arrays=(
            ("a_id", "NUMBER"), ("a_ref", "VARCHAR2(30)"), ("a_period", "NUMBER"),
            ("a_module", "VARCHAR2(20)"), ("a_date", "DATE"),
            ("a_desc", "VARCHAR2(300)"),
            ("a_posted", "TIMESTAMP WITH LOCAL TIME ZONE"),
            ("a_by", "VARCHAR2(30)"), ("a_status", "VARCHAR2(15)"),
            ("a_rev", "NUMBER"),
        ),
        fill=(
            "a_id(i)     := v_r;",
            "a_ref(i)    := 'GJ' || LPAD(TO_CHAR(v_r), 14, '0');",
            "a_period(i) := 1 + MOD(v_r - 1, %d);" % plan["gl_period"],
            "a_module(i) := pick(v_module);",
            "a_date(i)   := %s + MOD(v_r - 1, %d) + (nxt(86400) / 86400);"
            % (dt(FACT_START), FACT_DAYS),
            "a_desc(i)   := a_module(i) || ' posting for '",
            "               || TO_CHAR(a_date(i), 'YYYY-MM-DD');",
            "a_status(i) := pick(v_status);",
            "a_posted(i) := CASE WHEN a_status(i) <> 'DRAFT'",
            "                    THEN CAST(a_date(i) AS TIMESTAMP)",
            "                         + NUMTODSINTERVAL(nxt(86400), 'SECOND') END;",
            "a_by(i)     := CASE WHEN a_status(i) <> 'DRAFT' THEN 'SEED_LOAD' END;",
            "-- A reversal always points at a journal already inserted in this run.",
            "a_rev(i)    := CASE WHEN a_status(i) = 'REVERSED' AND v_r > 10",
            "                    THEN v_r - 5 END;",
        ),
        columns=("journal_id", "journal_ref", "period_id", "source_module",
                 "journal_date", "description", "posted_ts", "posted_by",
                 "status", "reversal_of_journal_id"),
        values=("a_id(i)", "a_ref(i)", "a_period(i)", "a_module(i)", "a_date(i)",
                "a_desc(i)", "a_posted(i)", "a_by(i)", "a_status(i)", "a_rev(i)"),
    ))

    parts.append("\nPROMPT gl_journal_line")
    parts.append(bulk_block(
        table="gl_journal_line", rows=plan["gl_journal_line"], seed=seed + 111,
        batch=batch,
        comment=scenario_note(
            "CHECK (debit_amount = 0 OR credit_amount = 0): a line is a debit or a",
            "credit, never both. Each journal's final line offsets the sum of the",
            "others, so SUM(debit_amount) = SUM(credit_amount) for every journal.",
            "account_code resolves to one of the 100 POSTABLE leaf accounts, recomputed",
            "from the same arithmetic that created them in 02-data-reference.sql.",
            "base_amount is VIRTUAL ((debit - credit) * fx_rate) and is not loaded."),
        arrays=(
            ("a_j", "NUMBER"), ("a_line", "NUMBER"), ("a_acct", "VARCHAR2(20)"),
            ("a_store", "NUMBER"), ("a_cc", "VARCHAR2(20)"), ("a_dr", "NUMBER"),
            ("a_cr", "NUMBER"), ("a_ccy", "VARCHAR2(3)"), ("a_fx", "NUMBER"),
            ("a_desc", "VARCHAR2(300)"),
        ),
        decls=("v_k PLS_INTEGER;", "v_x PLS_INTEGER;", "v_amt NUMBER;",
               "v_r1 PLS_INTEGER;", "v_s1 PLS_INTEGER;",
               "v_t1 PLS_INTEGER;", "v_u1 PLS_INTEGER;"),
        fill=(
            "v_k := v_r - 1;",
            "a_j(i)    := 1 + MOD(v_k, %d);" % n_gj,
            "a_line(i) := 1 + TRUNC(v_k / %d);" % n_gj,
            "-- Rebuild a postable leaf account code with the same arithmetic that",
            "-- generated the chart of accounts, so this never dangles.",
            "v_x  := MOD(v_r * 7, 100);",
            "v_r1 := 1 + MOD(v_x, 5);",
            "v_s1 := 1 + MOD(TRUNC(v_x / 5), 5);",
            "v_t1 := 1 + MOD(TRUNC(v_x / 25), 2);",
            "v_u1 := 1 + MOD(TRUNC(v_x / 50), 2);",
            "a_acct(i) := TO_CHAR(v_r1 * 10000 + v_s1 * 1000 + v_t1 * 100 + v_u1 * 10);",
            "a_store(i) := maybe_n(1 + MOD(v_r - 1, %d), 4);" % plan["store"],
            "a_cc(i)    := maybe('CC' || LPAD(TO_CHAR(1 + MOD(v_r, 40)), 4, '0'), 6);",
            "-- Double-entry: every journal must balance. Its %d lines sit %d rows"
            % (lines_per_journal, n_gj),
            "-- apart and land in different FORALL batches, so a line's amount is",
            "-- derived from (journal_id, line_no) by pure arithmetic, not the shared",
            "-- LCG. That lets the final line carry the exact offsetting total without",
            "-- the earlier lines' values in hand: SUM(debit) = SUM(credit) per journal.",
            "IF a_line(i) = %d THEN" % lines_per_journal,
            "   v_amt := 0;",
            "   FOR v_l IN 1 .. %d LOOP" % (lines_per_journal - 1),
            "      v_amt := v_amt",
            "               + ROUND(1 + MOD(a_j(i) * 2654435761 + v_l * 40503,",
            "                               900000) / 100, 2);",
            "   END LOOP;",
            "ELSE",
            "   v_amt := ROUND(1 + MOD(a_j(i) * 2654435761 + a_line(i) * 40503,",
            "                          900000) / 100, 2);",
            "END IF;",
            "-- Flip which side is the compound side per journal, so the ledger holds",
            "-- both many-debit and many-credit entries rather than all one shape.",
            "IF MOD(a_j(i), 2) = 1 THEN",
            "   IF a_line(i) = %d THEN a_dr(i) := 0;     a_cr(i) := v_amt;"
            % lines_per_journal,
            "   ELSE                   a_dr(i) := v_amt; a_cr(i) := 0; END IF;",
            "ELSE",
            "   IF a_line(i) = %d THEN a_dr(i) := v_amt; a_cr(i) := 0;"
            % lines_per_journal,
            "   ELSE                   a_dr(i) := 0;     a_cr(i) := v_amt; END IF;",
            "END IF;",
            "a_ccy(i)  := 'GBP';",
            "a_fx(i)   := ROUND(0.8 + nxt(6000) / 10000, 8);",
            "a_desc(i) := 'Line ' || TO_CHAR(a_line(i)) || ' of journal '",
            "             || TO_CHAR(a_j(i));",
        ),
        columns=("journal_id", "line_no", "account_code", "store_id", "cost_centre",
                 "debit_amount", "credit_amount", "currency_code", "fx_rate",
                 "line_description"),
        values=("a_j(i)", "a_line(i)", "a_acct(i)", "a_store(i)", "a_cc(i)",
                "a_dr(i)", "a_cr(i)", "a_ccy(i)", "a_fx(i)", "a_desc(i)"),
    ))

    return "\n\n".join(parts)


# --------------------------------------------------------------------------
# 14 -- the deliberate mess
# --------------------------------------------------------------------------

# Surrogate keys for these rows sit far above the dense range the bulk loader
# uses, so they can never collide with it at any --scale.
MESS_BASE = 900000000


def file_messy(plan: Dict[str, int], seed: int) -> str:
    b = MESS_BASE
    parts: List[str] = [
        "PROMPT === deliberate mess: the rows the conversion has to survive ===",
        "",
        "-- Every row below is labelled with the hard case or trap it exists to",
        "-- exercise. Surrogate keys start at %s, far above the dense range the"
        % "{:,}".format(b),
        "-- bulk loader uses, so they cannot collide at any --scale.",
        "--",
        "-- Nothing in this file is decorative. Each row is a real shape that has",
        "-- broken a real migration.",
    ]

    # ---- H-38: empty string vs NULL -------------------------------------
    parts.append("\n".join([
        "",
        "PROMPT H-38  empty string is NULL",
        "-- ---------------------------------------------------------------------",
        "-- THE MOST INSIDIOUS ITEM IN THE LAB. Nothing fails. Every statement",
        "-- compiles, every function runs, and a subset of rows quietly lands on the",
        "-- other side of an IS NULL test.",
        "--",
        "-- Six addresses: two with line2 = '', two with line2 = NULL, two with a real",
        "-- value. In Oracle the first four are indistinguishable. In PostgreSQL the",
        "-- first two are a zero-length string and the next two are NULL, so",
        "--     SELECT COUNT(line2)         returns 4 instead of 2",
        "--     SELECT ... WHERE line2 IS NOT NULL   returns 4 rows instead of 2",
        "--     SELECT ... WHERE line2 = ''          returns 2 rows instead of 0",
        "-- Run tests/ against both databases and diff those three numbers.",
        "-- ---------------------------------------------------------------------",
        "INSERT INTO address (address_id, line1, line2, city, country_code)",
        "VALUES (%d, 'Empty-string probe A', '', 'Oslo', 'NO');" % (b + 1),
        "INSERT INTO address (address_id, line1, line2, city, country_code)",
        "VALUES (%d, 'Empty-string probe B', '', 'Oslo', 'NO');" % (b + 2),
        "INSERT INTO address (address_id, line1, line2, city, country_code)",
        "VALUES (%d, 'Explicit-NULL probe A', NULL, 'Oslo', 'NO');" % (b + 3),
        "INSERT INTO address (address_id, line1, line2, city, country_code)",
        "VALUES (%d, 'Explicit-NULL probe B', NULL, 'Oslo', 'NO');" % (b + 4),
        "INSERT INTO address (address_id, line1, line2, city, country_code)",
        "VALUES (%d, 'Populated probe A', 'Flat 3', 'Oslo', 'NO');" % (b + 5),
        "INSERT INTO address (address_id, line1, line2, city, country_code)",
        "VALUES (%d, 'Populated probe B', 'Flat 4', 'Oslo', 'NO');" % (b + 6),
        "",
        "-- The same divergence on a column that a NOT NULL-adjacent check reads.",
        "INSERT INTO customer (customer_id, customer_ref, first_name, last_name,",
        "                      email, mobile_phone, home_country_code, created_ts)",
        "VALUES (%d, 'CUST-EMPTY-0001', '', 'Empty-first-name'," % (b + 1),
        "        'probe.empty@shopper.invalid', '', 'GB', SYSTIMESTAMP);",
        "INSERT INTO customer (customer_id, customer_ref, first_name, last_name,",
        "                      email, mobile_phone, home_country_code, created_ts)",
        "VALUES (%d, 'CUST-NULL-0001', NULL, 'Null-first-name'," % (b + 2),
        "        'probe.null@shopper.invalid', NULL, 'GB', SYSTIMESTAMP);",
        "COMMIT;",
        "",
        "PROMPT   the divergence, measured on Oracle (run the same query on PostgreSQL)",
        "SELECT COUNT(*)          AS probe_rows,",
        "       COUNT(line2)      AS non_null_line2,",
        "       SUM(CASE WHEN line2 IS NULL THEN 1 ELSE 0 END) AS null_line2",
        "  FROM address",
        " WHERE address_id BETWEEN %d AND %d;" % (b + 1, b + 6),
    ]))

    # ---- T-03 / unicode --------------------------------------------------
    parts.append("\n".join([
        "",
        "PROMPT T-03  unicode and VARCHAR2 byte semantics",
        "-- ---------------------------------------------------------------------",
        "-- VARCHAR2(60) is SIXTY BYTES unless the column was declared with CHAR",
        "-- semantics. A 60-character Greek or CJK name needs 120 to 180 bytes and",
        "-- will not fit. These rows are near the boundary on purpose: if the",
        "-- migration re-creates the column as varchar(60) in PostgreSQL, where the",
        "-- limit is CHARACTERS, the data fits -- and the reverse direction does not.",
        "-- The file is UTF-8. Load it with NLS_LANG set to a UTF-8 charset",
        "-- (for example AMERICAN_AMERICA.AL32UTF8) or these arrive as mojibake.",
        "-- ---------------------------------------------------------------------",
    ] + [
        line
        for n, (first, last, cc) in enumerate((
            ("Ελένη", "Παπαδοπούλου", "GR"),
            ("Иван", "Петров", "BG"),
            ("محمد", "العلي", "ZA"),
            ("山田", "太郎", "JP"),
            ("김민준", "박서준", "SG"),
            ("Þórunn", "Þorsteinsdóttir", "IS"),
            ("Šimun", "Šimunović", "HR"),
            ("Łukasz", "Łukasiewicz", "PL"),
            ("François", "Müller-Schröder", "CH"),
            ("Ñuño", "Núñez de la Peña", "ES"),
        ))
        for line in (
            "INSERT INTO customer (customer_id, customer_ref, first_name, last_name,",
            "                      email, home_country_code, created_ts, notes)",
            "VALUES (%d, 'CUST-UNI-%04d', %s, %s," % (b + 100 + n, n, q(first), q(last)),
            "        'unicode%d@shopper.invalid', %s, SYSTIMESTAMP," % (n, q(cc)),
            "        TO_CLOB(%s));" % q(
                "Name in native script: " + first + " " + last
                + " — mixed with an em dash, a non-breaking space and a zero-width"
                  " joiner‍, all of which survive Oracle and surprise somebody"
                  " downstream."),
        )
    ] + ["COMMIT;"]))

    # ---- H-34 / H-33: big CLOB and the LONG column -----------------------
    parts.append("\n".join([
        "",
        "PROMPT H-34  very long CLOBs, built with DBMS_LOB",
        "-- ---------------------------------------------------------------------",
        "-- The type mapping (CLOB -> text) is trivial. The residue is the DBMS_LOB",
        "-- call surface and LOB LOCATOR SEMANTICS: an Oracle locator is a mutable",
        "-- handle you write through, a PostgreSQL text value is a value. Code that",
        "-- opened a locator and appended to it needs restructuring, not translating.",
        "-- These CLOBs are around half a megabyte, which is enough to make a data",
        "-- movement tool show its true streaming behaviour.",
        "-- ---------------------------------------------------------------------",
        "DECLARE",
        "   v_lob   CLOB;",
        "   v_chunk VARCHAR2(4000);",
        "BEGIN",
        "   v_chunk := RPAD('Contoso long-form product copy. ', 400, '.')",
        "              || ' Multi-byte tail: naïve café — 山田. ';",
        "",
        "   FOR p IN (SELECT product_id FROM product",
        "              WHERE MOD(product_id, 499) = 1 AND ROWNUM <= 12) LOOP",
        "      DBMS_LOB.CREATETEMPORARY(v_lob, TRUE);",
        "      FOR n IN 1 .. 1200 LOOP",
        "         DBMS_LOB.WRITEAPPEND(v_lob, LENGTH(v_chunk), v_chunk);",
        "      END LOOP;",
        "      UPDATE product SET long_description = v_lob",
        "       WHERE product_id = p.product_id;",
        "      DBMS_LOB.FREETEMPORARY(v_lob);",
        "   END LOOP;",
        "   COMMIT;",
        "   DBMS_OUTPUT.PUT_LINE('long CLOBs written');",
        "END;",
        "/",
        "",
        "PROMPT H-33  the schema's only LONG column",
        "-- ---------------------------------------------------------------------",
        "-- store.legacy_migration_notes is LONG. Oracle permits one per table and",
        "-- deprecated the type decades ago for good reason: it cannot be used in most",
        "-- SQL expressions, cannot cross a database link, cannot be bulk-bound, and",
        "-- is unreadable by many drivers. That is why the bulk loader skips it and",
        "-- this file uses single-row UPDATEs -- the only thing that reliably works.",
        "--",
        "-- The target type is obvious (text). Getting the DATA out is not. Consider",
        "-- ALTER TABLE store MODIFY (legacy_migration_notes CLOB) on the SOURCE",
        "-- before the data movement step; pkg_utils ships a TO_LOB helper for it.",
        "-- ---------------------------------------------------------------------",
        "UPDATE store SET legacy_migration_notes =",
        "   'Migrated from AS/400 in 1997. Store number in the old system was '",
        "   || TO_CHAR(store_id * 3)",
        "   || '. Trading hours were held as two SMALLINT columns and the overnight'",
        "   || ' close was represented as 2400, which the 2004 conversion turned into'",
        "   || ' midnight of the WRONG DAY for eleven stores. Not all of them were'",
        "   || ' found. Do not assume opening_offset < closing_offset.'",
        " WHERE MOD(store_id, 37) = 1;",
        "COMMIT;",
    ]))

    # ---- H-37: DST boundaries -------------------------------------------
    parts.append("\n".join([
        "",
        "PROMPT H-37  timestamps on DST boundaries",
        "-- ---------------------------------------------------------------------",
        "-- Four kinds of awkward instant, in a schema whose stores are in eleven",
        "-- countries and whose columns are TIMESTAMP WITH LOCAL TIME ZONE:",
        "--   * 2025-03-30 01:30 Europe/London  -- DOES NOT EXIST (spring forward)",
        "--   * 2025-10-26 01:30 Europe/London  -- HAPPENS TWICE (autumn fold)",
        "--   * 2025-03-09 02:30 America/New_York -- does not exist",
        "--   * 2025-11-02 01:30 America/New_York -- happens twice",
        "--",
        "-- These are inserted as unambiguous UTC instants, because the session zone",
        "-- was pinned to UTC in 01-data-session-prep.sql. The hazard is what happens",
        "-- when they are RENDERED in the store's local zone, which is what",
        "-- fn_store_local_time does and what every regional report does.",
        "--",
        "-- Oracle normalises TSLTZ to the DATABASE time zone on storage and renders",
        "-- in the SESSION zone. PostgreSQL stores UTC and renders in TimeZone. Get",
        "-- DBTIMEZONE wrong during migration and every one of these rows -- and every",
        "-- other timestamp in the database -- moves by hours, silently.",
        "-- ---------------------------------------------------------------------",
    ] + [
        line
        for n, (label, instant) in enumerate((
            ("london-spring-gap", "2025-03-30 01:30:00"),
            ("london-autumn-fold", "2025-10-26 01:30:00"),
            ("newyork-spring-gap", "2025-03-09 07:30:00"),
            ("newyork-autumn-fold", "2025-11-02 05:30:00"),
            ("utc-midnight-newyear", "2025-01-01 00:00:00"),
            ("leap-day", "2024-02-29 12:00:00"),
        ))
        for line in (
            "INSERT INTO sales_order (order_id, order_number, store_id, channel_code,",
            "                         order_ts, status, currency_code,",
            "                         subtotal_amount, discount_amount, tax_amount,",
            "                         shipping_amount)",
            "VALUES (%d, 'SO-DST-%s'," % (b + 200 + n, label.upper()[:12]),
            "        1, 'WEB', %s," % ts(instant),
            "        'PLACED', 'GBP', 100, 0, 20, 0);",
        )
    ] + [
        "COMMIT;",
        "",
        "PROMPT   the same instants rendered in three zones",
        "SELECT order_number,",
        "       order_ts                                                AS as_session,",
        "       FROM_TZ(CAST(order_ts AS TIMESTAMP), 'UTC')",
        "          AT TIME ZONE 'Europe/London'                         AS in_london,",
        "       FROM_TZ(CAST(order_ts AS TIMESTAMP), 'UTC')",
        "          AT TIME ZONE 'America/New_York'                      AS in_new_york",
        "  FROM sales_order",
        " WHERE order_id BETWEEN %d AND %d" % (b + 200, b + 205),
        " ORDER BY order_id;",
    ]))

    # ---- negative / zero quantities --------------------------------------
    parts.append("\n".join([
        "",
        "PROMPT negative, zero and extreme quantities",
        "-- ---------------------------------------------------------------------",
        "-- Retail books negative stock every day: shrink, write-off, reversal, and",
        "-- receipts entered after the sale that consumed them. Any converted report",
        "-- that assumes non-negative quantities is wrong before it runs.",
        "-- The zero rows matter separately: they are the ones that make an average",
        "-- or a ratio divide by zero after someone 'simplifies' a NULLIF away.",
        "-- ---------------------------------------------------------------------",
        "INSERT INTO inventory_movement (movement_id, movement_ts, variant_id,",
        "                                movement_type, qty, reference_type, created_by)",
        "VALUES (%d, TIMESTAMP '2025-06-15 09:00:00', 1, 'SHRINK', -9999.999," % (b + 1),
        "        'MANUAL', 'SEED_MESS');",
        "INSERT INTO inventory_movement (movement_id, movement_ts, variant_id,",
        "                                movement_type, qty, reference_type, created_by)",
        "VALUES (%d, TIMESTAMP '2025-06-15 09:00:01', 1, 'COUNT', 0," % (b + 2),
        "        'STOCK_COUNT', 'SEED_MESS');",
        "INSERT INTO inventory_movement (movement_id, movement_ts, variant_id,",
        "                                movement_type, qty, reference_type, created_by)",
        "VALUES (%d, TIMESTAMP '2025-06-15 09:00:02', 1, 'ADJUST', 0.001," % (b + 3),
        "        'MANUAL', 'SEED_MESS');",
        "INSERT INTO inventory_movement (movement_id, movement_ts, variant_id,",
        "                                movement_type, qty, reference_type, created_by)",
        "VALUES (%d, TIMESTAMP '2025-06-15 09:00:03', 1, 'RECEIPT', 99999999.999,"
        % (b + 4),
        "        'PURCHASE_ORDER', 'SEED_MESS');",
        "",
        "-- A negative points movement large enough to matter, and a zero-delta row",
        "-- that a naive SUM ... HAVING <> 0 filter will drop.",
        "INSERT INTO loyalty_transaction (loyalty_txn_id, txn_type, loyalty_id,",
        "                                 points_delta, reason_code, txn_ts, created_by)",
        "VALUES (%d, 'REDEEM', 1, -250000, 'CORRECTION'," % (b + 1),
        "        TIMESTAMP '2025-06-15 09:00:00', 'SEED_MESS');",
        "INSERT INTO loyalty_transaction (loyalty_txn_id, txn_type, loyalty_id,",
        "                                 points_delta, reason_code, txn_ts, created_by)",
        "VALUES (%d, 'ADJUST', 1, 0, 'CORRECTION'," % (b + 2),
        "        TIMESTAMP '2025-06-15 09:00:01', 'SEED_MESS');",
        "COMMIT;",
    ]))

    # ---- T-04 / T-02 -----------------------------------------------------
    parts.append("\n".join([
        "",
        "PROMPT T-04 and T-02  blank-padded CHAR keys and DATEs that carry a time",
        "-- ---------------------------------------------------------------------",
        "-- T-04: country_code is CHAR(2) and currency_code is CHAR(3). Oracle",
        "-- blank-pads them and compares with blank-padding semantics. PostgreSQL",
        "-- char(n) does too -- but the moment a converter chooses text or varchar",
        "-- instead, 'GB ' stops equalling 'GB' and joins silently stop matching.",
        "-- The row below stores a code that was written WITH a trailing blank.",
        "--",
        "-- T-02: journal_date is an Oracle DATE, which is a timestamp to the second.",
        "-- Converting it to a PostgreSQL date truncates 14:37:22 to 00:00:00 and no",
        "-- error is raised. The row below has a time component precisely so the",
        "-- truncation is visible in a diff.",
        "-- ---------------------------------------------------------------------",
        "INSERT INTO address (address_id, line1, city, country_code)",
        "VALUES (%d, 'Blank-padded country code probe', 'Cardiff', 'GB');" % (b + 7),
        "",
        "INSERT INTO gl_journal (journal_id, journal_ref, period_id, source_module,",
        "                        journal_date, description, status)",
        "VALUES (%d, 'GJ-TIME-COMPONENT-01', 1, 'MANUAL'," % (b + 1),
        "        TO_DATE('2025-07-04 14:37:22', 'YYYY-MM-DD HH24:MI:SS'),",
        "        'DATE with a time component -- trap T-02', 'POSTED');",
        "COMMIT;",
        "",
        "PROMPT   blank-padding comparison on Oracle",
        "SELECT COUNT(*) AS matches_unpadded",
        "  FROM address WHERE address_id = %d AND country_code = 'GB';" % (b + 7),
        "SELECT COUNT(*) AS matches_padded",
        "  FROM address WHERE address_id = %d AND country_code = 'GB ';" % (b + 7),
        "",
        "PROMPT   the time component that a PostgreSQL date would discard",
        "SELECT journal_ref,",
        "       TO_CHAR(journal_date, 'YYYY-MM-DD HH24:MI:SS') AS journal_date_full",
        "  FROM gl_journal WHERE journal_id = %d;" % (b + 1),
    ]))

    return "\n\n".join(parts)


# --------------------------------------------------------------------------
# 99 -- verification
# --------------------------------------------------------------------------

ORPHAN_CHECKS: Sequence[Tuple[str, str, str, str]] = (
    ("region", "country", "country_code", "country_code"),
    ("store", "region", "region_id", "region_id"),
    ("store", "address", "address_id", "address_id"),
    ("employee", "store", "store_id", "store_id"),
    ("employee", "employee", "manager_id", "employee_id"),
    ("product", "product_category", "category_id", "category_id"),
    ("product_variant", "product", "product_id", "product_id"),
    ("supplier_product", "product_variant", "variant_id", "variant_id"),
    ("customer", "country", "home_country_code", "country_code"),
    ("loyalty_account", "customer", "customer_id", "customer_id"),
    ("loyalty_transaction", "loyalty_account", "loyalty_id", "loyalty_id"),
    ("price_list_item", "price_list", "price_list_id", "price_list_id"),
    ("promotion_product", "promotion", "promotion_id", "promotion_id"),
    ("coupon", "promotion", "promotion_id", "promotion_id"),
    ("sales_order", "store", "store_id", "store_id"),
    ("sales_order_line", "sales_order", "order_id", "order_id"),
    ("order_payment", "sales_order", "order_id", "order_id"),
    ("shipment", "carrier", "carrier_code", "carrier_code"),
    ("inventory_stock", "inventory_location", "location_id", "location_id"),
    ("inventory_movement", "product_variant", "variant_id", "variant_id"),
    ("purchase_order", "supplier", "supplier_id", "supplier_id"),
    ("purchase_order_line", "purchase_order", "po_id", "po_id"),
    ("return_request", "sales_order", "order_id", "order_id"),
    ("return_line", "return_reason", "reason_code", "reason_code"),
    ("gl_journal", "gl_period", "period_id", "period_id"),
    ("gl_journal_line", "gl_account", "account_code", "account_code"),
)


def file_verify(plan: Dict[str, int], scale: str) -> str:
    lines = [
        "PROMPT === verification ===",
        "SET SERVEROUTPUT ON SIZE UNLIMITED",
        "",
        "-- design.md section 12 assertion 4: no orphan rows across any foreign key",
        "-- after seeding. The database enforces this already; asserting it here",
        "-- catches a load that ran with constraints disabled by mistake, which is",
        "-- exactly how a 'successful' migration ends up with silent data loss.",
        "",
        "PROMPT === row counts ===",
    ]
    for table in plan:
        lines.append("SELECT '%s' AS table_name, COUNT(*) AS row_count FROM %s;"
                     % (table, table))
    lines += [
        "",
        "PROMPT === expected row counts for --scale %s ===" % scale,
        "-- (the deliberate-mess rows in 14 add a few dozen on top of these)",
    ]
    for table, n in plan.items():
        lines.append("--   %-22s %s" % (table, "{:,}".format(n)))

    lines += [
        "",
        "PROMPT === orphan check ===",
        "DECLARE",
        "   v_orphans PLS_INTEGER;",
        "   v_total   PLS_INTEGER := 0;",
        "   PROCEDURE chk(p_child VARCHAR2, p_parent VARCHAR2,",
        "                 p_fk VARCHAR2, p_pk VARCHAR2) IS",
        "      v_n PLS_INTEGER;",
        "   BEGIN",
        "      EXECUTE IMMEDIATE",
        "         'SELECT COUNT(*) FROM ' || p_child || ' c'",
        "         || ' WHERE c.' || p_fk || ' IS NOT NULL'",
        "         || '   AND NOT EXISTS (SELECT 1 FROM ' || p_parent || ' p'",
        "         || '                    WHERE p.' || p_pk || ' = c.' || p_fk || ')'",
        "         INTO v_n;",
        "      IF v_n > 0 THEN",
        "         DBMS_OUTPUT.PUT_LINE('ORPHANS ' || p_child || '.' || p_fk",
        "                              || ' -> ' || p_parent || '.' || p_pk",
        "                              || ' : ' || v_n);",
        "         v_orphans := v_orphans + v_n;",
        "      END IF;",
        "   EXCEPTION",
        "      WHEN OTHERS THEN",
        "         DBMS_OUTPUT.PUT_LINE('CHECK FAILED ' || p_child || '.' || p_fk",
        "                              || ' : ' || SQLERRM);",
        "   END chk;",
        "BEGIN",
        "   v_orphans := 0;",
    ]
    for child, parent, fk, pk in ORPHAN_CHECKS:
        lines.append("   chk(%s, %s, %s, %s);"
                     % (q(child), q(parent), q(fk), q(pk)))
    lines += [
        "   IF v_orphans > 0 THEN",
        "      RAISE_APPLICATION_ERROR(-20910,",
        "         'referential integrity broken: ' || v_orphans || ' orphan rows');",
        "   END IF;",
        "   DBMS_OUTPUT.PUT_LINE('orphan check: clean');",
        "END;",
        "/",
        "",
        "PROMPT === the three queries that decide whether the conversion is honest ===",
        "-- Run each of these against Oracle and against the converted PostgreSQL and",
        "-- diff the numbers. A conversion that looks correct and is not will differ",
        "-- here and nowhere else (design.md section 12).",
        "",
        "PROMPT H-38: empty string versus NULL",
        "SELECT COUNT(*)     AS all_rows,",
        "       COUNT(line2) AS non_null_line2,",
        "       COUNT(DISTINCT NVL(line2, '<null>')) AS distinct_line2",
        "  FROM address;",
        "",
        "PROMPT H-30: ROWNUM assigned before ORDER BY versus after",
        "SELECT SUM(order_id) AS rownum_form_checksum",
        "  FROM (SELECT order_id FROM sales_order",
        "         WHERE ROWNUM <= 100 ORDER BY order_ts DESC);",
        "SELECT SUM(order_id) AS limit_form_checksum",
        "  FROM (SELECT order_id FROM sales_order",
        "         ORDER BY order_ts DESC FETCH FIRST 100 ROWS ONLY);",
        "",
        "PROMPT H-32: Oracle (+) outer join row count",
        "SELECT COUNT(*) AS legacy_join_rows",
        "  FROM sales_order so, customer cu, shipment sh",
        " WHERE cu.customer_id(+) = so.customer_id",
        "   AND sh.order_id(+)    = so.order_id",
        "   AND sh.status(+)      = 'DELIVERED';",
    ]
    return "\n".join(lines)


# --------------------------------------------------------------------------
# File assembly and entry point
# --------------------------------------------------------------------------

DATA_FILES: Sequence[Tuple[str, str]] = (
    ("01-data-session-prep.sql", "NLS, time zone and trigger state for the load"),
    ("02-data-reference.sql", "Currency, country, FX, calendar, tax, GL chart"),
    ("03-data-geography.sql", "Region tree, addresses, warehouses, stores"),
    ("04-data-employees.sql", "Employees and the circular foreign keys"),
    ("05-data-catalog.sql", "Category tree, brands, products, variants"),
    ("06-data-suppliers.sql", "Suppliers and the sourcing matrix"),
    ("07-data-customers.sql", "Customers, addresses, loyalty"),
    ("08-data-pricing.sql", "Price lists, promotions, coupons"),
    ("09-data-inventory.sql", "Locations, stock snapshot, movement ledger"),
    ("10-data-orders.sql", "Orders, lines, payments, shipments"),
    ("11-data-procurement.sql", "Purchase orders, lines, goods receipts"),
    ("12-data-returns.sql", "Return requests and lines"),
    ("13-data-finance.sql", "GL journals and journal lines"),
    ("14-data-messy-edge-cases.sql", "The rows the conversion has to survive"),
    ("98-data-session-restore.sql", "Re-enable triggers, gather statistics"),
    ("99-data-verify.sql", "Row counts, orphan check, the three honesty queries"),
)


def data_header(filename: str, title: str, scale: str, seed: int,
                total_rows: int) -> str:
    return "\n".join([
        "-- =========================================================================",
        "-- Contoso Store -- Oracle to Azure Database for PostgreSQL migration lab",
        "-- generated/oracle/data/%s" % filename,
        "-- %s" % title,
        "--",
        "-- GENERATED FILE. Do not edit: tools/generate-data.py owns it and",
        "-- generated/ is gitignored. Regenerate with",
        "--    python3 tools/generate-data.py --scale %s" % scale,
        "--",
        "-- scale=%s  seed=%d  planned rows across the whole load=%s"
        % (scale, seed, "{:,}".format(total_rows)),
        "--",
        "-- ENCODING: this file is UTF-8 and contains Greek, Cyrillic, Arabic, CJK",
        "-- and Hangul text. Set NLS_LANG to a UTF-8 charset before loading, e.g.",
        "--    export NLS_LANG=AMERICAN_AMERICA.AL32UTF8",
        "-- or the multi-byte names arrive as mojibake and every H-38/T-03 finding",
        "-- in the lab is measuring the wrong thing.",
        "--",
        "-- Run 00-data-load-all.sql, or these files in ordinal order, as CONTOSO,",
        "-- after every file in src/oracle/ and generated/oracle/ has been applied.",
        "-- =========================================================================",
        "",
        "SET DEFINE OFF",
        "SET SCAN OFF",
        "SET SERVEROUTPUT ON SIZE UNLIMITED",
        "WHENEVER SQLERROR EXIT FAILURE",
        "",
    ])


def build_files(plan: Dict[str, int], scale: str, seed: int) -> "OrderedDict[str, str]":
    batch = batch_size_for(scale)
    return OrderedDict([
        ("01-data-session-prep.sql", file_session_prep(plan, scale)),
        ("02-data-reference.sql", file_reference(plan, seed, batch)),
        ("03-data-geography.sql", file_geography(plan, seed, batch)),
        ("04-data-employees.sql", file_employees(plan, seed, batch)),
        ("05-data-catalog.sql", file_catalog(plan, seed, batch)),
        ("06-data-suppliers.sql", file_suppliers(plan, seed, batch)),
        ("07-data-customers.sql", file_customers(plan, seed, batch)),
        ("08-data-pricing.sql", file_pricing(plan, seed, batch)),
        ("09-data-inventory.sql", file_inventory(plan, seed, batch)),
        ("10-data-orders.sql", file_orders(plan, seed, batch)),
        ("11-data-procurement.sql", file_procurement(plan, seed, batch)),
        ("12-data-returns.sql", file_returns(plan, seed, batch)),
        ("13-data-finance.sql", file_finance(plan, seed, batch)),
        ("14-data-messy-edge-cases.sql", file_messy(plan, seed)),
        ("98-data-session-restore.sql", file_session_restore()),
        ("99-data-verify.sql", file_verify(plan, scale)),
    ])


def write_output(bodies: "OrderedDict[str, str]", outdir: Path, scale: str,
                 seed: int, total_rows: int) -> List[Path]:
    data_dir = outdir / "oracle" / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    written: List[Path] = []
    titles = dict(DATA_FILES)

    for filename, body in bodies.items():
        text = data_header(filename, titles.get(filename, ""), scale, seed,
                           total_rows) + body.rstrip() + "\n"
        path = data_dir / filename
        # Path.write_text(newline=...) is Python 3.10+; the floor here is 3.9.
        with path.open("w", encoding="utf-8", newline="\n") as _fh:
            _fh.write(text)
        written.append(path)

    driver = [
        "-- =========================================================================",
        "-- generated/oracle/data/00-data-load-all.sql",
        "-- SQL*Plus driver. Run from this directory as CONTOSO.",
        "--",
        "--    export NLS_LANG=AMERICAN_AMERICA.AL32UTF8",
        "--    sqlplus contoso/\"$CONTOSO_PASSWORD\"@//localhost:1521/FREEPDB1 \\",
        "--        @00-data-load-all.sql",
        "--",
        "-- scale=%s  planned rows=%s" % (scale, "{:,}".format(total_rows)),
        "-- =========================================================================",
        "",
        "SET DEFINE OFF",
        "SET SCAN OFF",
        "SET SERVEROUTPUT ON SIZE UNLIMITED",
        "SET TIMING ON",
        "WHENEVER SQLERROR EXIT FAILURE",
        "",
        "PROMPT === Contoso seed data: start ===",
        "",
    ]
    for filename, _title in bodies.items():
        driver.append("@@%s" % filename)
    driver += ["", "PROMPT === Contoso seed data: done ===", ""]
    path = data_dir / "00-data-load-all.sql"
    # Path.write_text(newline=...) is Python 3.10+; the floor here is 3.9.
    with path.open("w", encoding="utf-8", newline="\n") as _fh:
        _fh.write("\n".join(driver))
    written.insert(0, path)
    return written


def summarise(plan: Dict[str, int], scale: str, seed: int, written: Sequence[Path],
              outdir: Path) -> int:
    total = sum(plan.values())
    print("")
    print("Contoso Store deterministic seed-data generator")
    print("  scale      : %s (factor %d)" % (scale, SCALE_FACTORS[scale]))
    print("  seed       : %d" % seed)
    print("  output     : %s" % (outdir / "oracle" / "data"))
    print("  batch size : %s rows per FORALL" % "{:,}".format(batch_size_for(scale)))
    print("")
    print("Planned rows by table")
    fixed_total = 0
    scal_total = 0
    for table, n in plan.items():
        kind = "fixed" if table in FIXED_ROWS else "scaled"
        if kind == "fixed":
            fixed_total += n
        else:
            scal_total += n
        print("  %-22s %14s  %s" % (table, "{:,}".format(n), kind))
    print("  %s" % ("-" * 48))
    print("  %-22s %14s" % ("reference (fixed)", "{:,}".format(fixed_total)))
    print("  %-22s %14s" % ("transactional (scaled)", "{:,}".format(scal_total)))
    print("  %-22s %14s" % ("TOTAL", "{:,}".format(total)))
    print("")
    print("Deliberate hazards carried by this load")
    for label in (
        "H-38 empty string is NULL      : address.line2, customer.first_name,",
        "                                 customer.mobile_phone, supplier contact email",
        "H-37 TSLTZ and DST boundaries  : 6 orders on gap and fold instants",
        "H-34 CLOB / BLOB               : ~0.5 MB CLOBs via DBMS_LOB.WRITEAPPEND",
        "H-33 LONG column               : store.legacy_migration_notes, UPDATE-only",
        "H-35 XMLTYPE                   : product.spec_sheet, promotion.rule_xml",
        "H-05 nested tables             : product.attributes, loyalty_tier.benefits",
        "H-04 VARRAYs                   : channel_availability, size_run, consent",
        "H-17 virtual columns           : never loaded, always derived",
        "H-19 range partitioning        : order_ts and order_date span 731 days",
        "H-20 list partitioning         : all 5 loyalty txn_type partitions filled",
        "T-02 DATE carries a time       : purchase_order.order_date, gl_journal",
        "T-03 multi-byte names          : Greek, Cyrillic, Arabic, CJK, Hangul",
        "T-04 blank-padded CHAR keys    : country_code / currency_code probes",
        "     negative and zero qty     : inventory_movement, inventory_stock,",
        "                                 loyalty_transaction.points_delta",
    ):
        print("  %s" % label)
    print("")
    print("Files written (%d)" % len(written))
    for p in written:
        print("  %s" % p)
    print("")
    print("Load with:")
    print("  export NLS_LANG=AMERICAN_AMERICA.AL32UTF8")
    print("  cd %s && sqlplus -S contoso/\"$CONTOSO_PASSWORD\"@//localhost:1521/FREEPDB1"
          " @00-data-load-all.sql" % (outdir / "oracle" / "data"))
    return 0


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(
        prog="generate-data.py",
        description=(
            "Deterministically generate referentially consistent seed data for the "
            "CONTOSO Oracle schema. Writes SQL*Plus-loadable files into "
            "<out>/oracle/data/."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Volume is loaded with PL/SQL FORALL blocks, never one INSERT per row.\n"
            "--scale changes row-count constants only, so the emitted SQL stays\n"
            "comparable across scales and across runs.\n"
        ),
    )
    parser.add_argument(
        "--out", default=os.environ.get("GEN_OUTPUT_DIR", str(repo_root / "generated")),
        help="output root; files land in <out>/oracle/data/ (default: %(default)s)")
    parser.add_argument(
        "--scale", type=scale_arg, default="medium", metavar="TIER|FACTOR",
        help="small ~55k rows, medium ~2M, large ~10M. A bare number is also "
             "accepted and mapped to the nearest tier, so --scale 0.01 works "
             "the same as --scale small (default: %(default)s)")
    parser.add_argument(
        "--seed", type=int, default=int(os.environ.get("GEN_SEED", DEFAULT_SEED)),
        help="deterministic seed (default: %(default)s)")
    parser.add_argument(
        "--quiet", action="store_true", help="suppress the summary")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    plan = build_row_plan(args.scale)
    total = sum(plan.values())
    bodies = build_files(plan, args.scale, args.seed)
    outdir = Path(args.out).expanduser().resolve()
    written = write_output(bodies, outdir, args.scale, args.seed, total)

    if args.quiet:
        print("generated %s planned rows into %s"
              % ("{:,}".format(total), outdir / "oracle" / "data"))
        return 0
    return summarise(plan, args.scale, args.seed, written, outdir)


if __name__ == "__main__":
    sys.exit(main())
