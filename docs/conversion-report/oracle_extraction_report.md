# Schema Extraction Readiness Report

_Customer-facing extraction readiness summary._

**Generated:** September 04, 2026 at 05:32 PM UTC  
**Extraction ID:** `145cbfae-fd6b-429d-967a-01588df74fd9`  
**Source:** Oracle AI Database 26ai Free Release 23.26.3.0.0 - Develop, Learn, and Run for Free  
**Schema:** `CONTOSO`

---

## Contents

- [✓ Executive Outcome](#executive-outcome)
- [▦ Source Object Accounting](#source-object-accounting)
- [▦ What Was Extracted](#what-was-extracted)
- [⊘ What Was Not Extracted and Why](#what-was-not-extracted)
- [◇ Items Requiring Customer Review](#items-requiring-customer-review)
- [⇄ Dependency and Scope Findings](#dependency-and-scope-findings)
- [✓ Recommended Customer Actions](#recommended-customer-actions)
- [ℹ Customer Interpretation](#customer-interpretation)

---

<a id="executive-outcome"></a>

## ✓ Executive Outcome

The `CONTOSO` schema extraction completed and produced the raw DDL, dependency graph, typed schema inventory, and review artifacts needed for downstream migration stages.

| Question | Answer |
|---|---|
| ✓ Did extraction complete? | **Yes** |
| ▦ Were schema objects discovered? | **1,877 objects** |
| ▦ Were schema objects extracted? | **1,299 objects extracted** |
| ✕ Did any extraction fail? | **No extraction failures reported** |
| △ Are there source-side objects to review? | **Yes — 399 source-side object(s) need review** |
| ⇄ Are there dependency/scope findings to review? | **Yes — 247 dependency/scope finding(s) need review** |
| ▶ Is this ready for chunking/conversion input? | **Yes, with follow-up review for object or dependency/scope findings** |

---

<a id="source-object-accounting"></a>

## ▦ Source Object Accounting

This reconciles the source-side inventory into clear outcomes. These rows count source objects; dependency references are reported separately later in the report.

| Outcome | Count | What It Means |
|---|---:|---|
| Extracted as DDL | 1,299 | Objects successfully captured and available for conversion. |
| Usually safe/tool-managed exclusions | 179 | Generated/internal objects normally represented by other extracted DDL. |
| Configured scope decisions | 6 | Objects skipped because include/exclude filters or selection rules said so. |
| Unsupported by extractor | 393 | Source objects outside the current automated extraction path. |
| **Total source-side objects accounted for** | **1,877** | Sum of the source-object outcomes above. |

---

<a id="what-was-extracted"></a>

## ▦ What Was Extracted

These objects were emitted as source DDL and are available for downstream chunking and conversion.

| Extracted Category | Count | Includes |
|---|---:|---|
| Data model objects | 136 | tables, constraints, and foreign-key/reference constraints |
| Performance and key-generation objects | 233 | indexes and sequences |
| Query-layer objects | 214 | views and materialized views |
| Business logic objects | 542 | packages, procedures, functions, triggers, and types |
| Reference/name objects | 174 | synonyms and database links |

### Extracted Object Type Detail

| Object Type | Count |
|---|---:|
| Function | 136 |
| Index | 158 |
| Materialized View | 6 |
| Package | 90 |
| Package Body | 90 |
| Procedure | 112 |
| Ref Constraint | 40 |
| Sequence | 75 |
| Synonym | 174 |
| Table | 96 |
| Trigger | 96 |
| Type | 18 |
| View | 208 |

| Overall Total | Count | Meaning |
|---|---:|---|
| **▦ Total extracted** | **1,299** | Objects available for downstream chunking and conversion. |

---

<a id="what-was-not-extracted"></a>

## ⊘ What Was Not Extracted and Why

This section groups non-extracted source-side objects by customer meaning so it is clear which items are expected exclusions and which need a decision or remediation.

| Group | Count | Customer Meaning | Customer Action |
|---|---:|---|---|
| Usually safe/tool-managed exclusions | 179 | Generated/internal objects normally represented by other extracted DDL. | Usually no action; confirm the generated behavior is covered. |
| Configured scope decisions | 6 | Objects matched configured include/exclude filters or selection rules. | Confirm these objects are intentionally out of migration scope. |
| Unsupported by extractor | 393 | Source objects are outside the current automated extraction path. | Plan a manual, application-level, or alternate migration strategy. |
| **Total not extracted as normal DDL** | **578** | All non-extracted source-side objects above. | Use the customer action guidance for each group. |

### Exclusion Reason Detail

| Exclusion Reason | Count | Customer Meaning |
|---|---:|---|
| ▣ Constraint-backing indexes | 117 | Usually no action; confirm constraints are in migration scope. |
| ⌘ System-generated indexes | 48 | Usually no action unless applications depend on implementation details. |
| ⊘ Mview Backing Table | 6 | Confirm whether this exclusion is expected for the migration scope. |
| ⊘ User-configured exclusions | 6 | Confirm these objects are intentionally out of migration scope. |
| # Bitmap indexes | 4 | Review performance strategy after conversion. |
| # Global partitioned indexes | 2 | Review partitioning and indexing strategy after conversion. |
| ⊘ Nested Table Storage | 2 | Confirm whether this exclusion is expected for the migration scope. |

### Configured Scope Decisions

These objects matched configured include/exclude filters and were intentionally skipped.

| Schema | Object Type | Object Name | Detail |
|---|---|---|---|
| CONTOSO | INDEX | I_MLOG$_INVENTORY_STOCK | Configured include/exclude filter |
| CONTOSO | INDEX | I_MLOG$_SALES_ORDER | Configured include/exclude filter |
| CONTOSO | INDEX | I_MLOG$_SALES_ORDER_LINE | Configured include/exclude filter |
| CONTOSO | TABLE | MLOG$_INVENTORY_STOCK | Configured include/exclude filter |
| CONTOSO | TABLE | MLOG$_SALES_ORDER | Configured include/exclude filter |
| CONTOSO | TABLE | MLOG$_SALES_ORDER_LINE | Configured include/exclude filter |

---

<a id="items-requiring-customer-review"></a>

## ◇ Items Requiring Customer Review

These items were not extracted as normal migration-ready objects and need a customer, application-owner, or DBA decision.

| Item | Count | Required Customer Decision |
|---|---:|---|
| ⊘ User-configured exclusions | 6 | Confirm these configured filters are intentional for this scope. |
| ◇ Unsupported `CHAIN` objects | 1 | Define a manual or application-level migration strategy if still required. |
| ◇ Unsupported `EVALUATION CONTEXT` objects | 1 | Define a manual or application-level migration strategy if still required. |
| ◇ Unsupported `INDEX PARTITION` objects | 95 | Define a manual or application-level migration strategy if still required. |
| ◇ Unsupported `INDEX SUBPARTITION` objects | 250 | Define a manual or application-level migration strategy if still required. |
| ◇ Unsupported `LOB` objects | 40 | Confirm LOB data/columns are covered through table migration planning. |
| ◇ Unsupported `RULE` objects | 5 | Define a manual or application-level migration strategy if still required. |
| ◇ Unsupported `RULE SET` objects | 1 | Define a manual or application-level migration strategy if still required. |

---

<a id="dependency-and-scope-findings"></a>

## ⇄ Dependency and Scope Findings

These rows count dependency references or schemas, not source objects. One object can have many dependency references, so these counts can be higher than the source-object totals.

| Finding | Count | Unit | Customer Action |
|---|---:|---|---|
| ⌕ Unresolved outbound dependency references | 247 | references | Decide whether additional schema/object scope is required. |

---

<a id="recommended-customer-actions"></a>

## ✓ Recommended Customer Actions

1. **Confirm the unsupported object strategy** for `CHAIN`, `EVALUATION CONTEXT`, `INDEX PARTITION`, `INDEX SUBPARTITION`, `LOB`, `RULE`, `RULE SET`.
2. **Review unresolved dependencies** to decide whether additional schemas or objects should be included in migration scope.
3. **Proceed to chunk generation and conversion** once the above scope decisions are confirmed.

---

<a id="customer-interpretation"></a>

## ℹ Customer Interpretation

This extraction is a baseline capture of the `CONTOSO` schema. It discovered 1,877 object(s) and extracted 1,299 object(s). It is ready to feed the migration pipeline, but final migration scope approval should wait until user-configured exclusions, unsupported `CHAIN` objects, unsupported `EVALUATION CONTEXT` objects, unsupported `INDEX PARTITION` objects are reviewed with the application/database owners.

---

*Report generated by the source DDL extraction tool*