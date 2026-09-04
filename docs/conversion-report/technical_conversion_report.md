# 🛠️ Schema Migration Readiness Report — Oracle `CONTOSO` to PostgreSQL 16

_Generated 2026-09-04 20:32 UTC_  ·  _Session `9ca12a0f`_  ·  _Extension `1.30.1`_  ·  _Model `gpt-5.2`_  ·  _Deployment `o2p-schema-conversion`_

## Table of Contents

- [📌 Conversion Snapshot (Top Metrics)](#-conversion-snapshot-top-metrics)
- [📋 Conversion Inventory](#-conversion-inventory)
- [📊 Per-Chunk Performance](#-per-chunk-performance)
- [🚨 Action Required](#-action-required)
- [🚀 Deploy Preparation](#-deploy-preparation)
- [📖 Glossary](#-glossary)

## 📌 Conversion Snapshot (Top Metrics)

| Source DB | Target DB | Schema scope | Session ID | Extension | Duration | Total tokens |
|---|---|---|---|---|---|---|
| Oracle | PostgreSQL 16 | `CONTOSO` | `9ca12a0f` | `1.30.1` | 2h 56m 53s | 7,178,840 |

### Schema Conversion Metrics

| Schema | Objects Extracted | ✅ Converted | 🔴 Not-Converted | Converted % |
|---|---:|---:|---:|---:|
| `CONTOSO` | 1,185 | 947 | 238 | 79.92% |

> *Objects Extracted* includes the **1 schema object(s)** selected for this run and counts each package once -- the 90 package spec(s) are counted with the body that realises them, not separately.

## 📋 Conversion Inventory

### Category Roll-up

| Category | Objects | ✅ Converted | 🔴 Not-Converted | Converted % |
|---|---:|---:|---:|---:|
| 🟦 **Non-Programmable** | 727 | 598 | 129 | 82.26% |
| 🟪 **Programmable** | 368 | 322 | 46 | 87.50% |
| 📦 **Package** | 90 | 27 | 63 | 30.00% |
| **Total** | **1,185** | **947** | **238** | **79.92%** |

> This Total is the same population as *Objects Extracted* above, counted by category. The 📦 Package row scores each package as **one object**; `customer_summary.md` scores the **members inside** them, so its package rate is a different measurement.

> 🔗 **339 object(s) were converted before their dependencies** to break a cycle. A missing-relation failure among them is explained by that relaxation, not by translation quality.

### By Object Type (sorted by issues, then volume)

| Type | Category | Objects | ✅ Converted | 🔴 Not-Converted | Converted % | Risk Indicator |
|---|---|---:|---:|---:|---:|---|
| SYNONYM | 🟦 Non-Programmable | 149 | 82 | 67 | 55.03% | 🔴 67 to review (>5%) |
| PACKAGE_BODY | 📦 Package | 90 | 27 | 63 | 30.00% | 🔴 59 to review (>5%) |
| VIEW | 🟦 Non-Programmable | 208 | 154 | 54 | 74.04% | 🔴 54 to review (>5%) |
| TRIGGER | 🟪 Programmable | 96 | 74 | 22 | 77.08% | 🔴 22 to review (>5%) |
| PROCEDURE | 🟪 Programmable | 112 | 94 | 18 | 83.93% | 🔴 18 to review (>5%) |
| INDEX | 🟦 Non-Programmable | 158 | 153 | 5 | 96.84% | 🔴 5 to review |
| FUNCTION | 🟪 Programmable | 136 | 132 | 4 | 97.06% | 🟠 4 to review |
| REF_CONSTRAINT | 🟦 Non-Programmable | 40 | 37 | 3 | 92.50% | 🔴 3 to review (>5%) |
| MATERIALIZED_VIEW | 🟪 Programmable | 6 | 4 | 2 | 66.67% | 🔴 2 to review (>5%) |
| TABLE | 🟦 Non-Programmable | 96 | 96 | 0 | 100.00% | 🟢 clean |
| PACKAGE | 📦 Package | 0 | 0 | 0 | — | 🟢 clean |
| SEQUENCE | 🟦 Non-Programmable | 75 | 75 | 0 | 100.00% | 🟢 clean |
| TYPE | 🟪 Programmable | 18 | 18 | 0 | 100.00% | 🟢 clean |
| SCHEMA | 🟦 Non-Programmable | 1 | 1 | 0 | 100.00% | 🟢 clean |
| PACKAGE_STATE | 📦 Package | 0 | 0 | 0 | — | 🟢 clean |

## 📊 Per-Chunk Performance

### Wallclock window

| Run start | Run end | Wallclock | Chunks |
|---|---|---|---|
| 2026-09-04 17:32:28 UTC | 2026-09-04 20:29:21 UTC | 2h 56m 53s | 56 |

_All `Start` / `End` values in the table below are offsets (`H:MM:SS`) from **Run start**._

_A 🚩 marks a chunk with at least one Not-Converted object._

|  |  |  | Programmable |  |  |  | Non-Programmable |  |  |  | Chunk Metrics |  |  |  |  |
|:-:|:--|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| Review | Chunk | Total | Obj | ✅ Converted | 🔴 Not-Converted | % | Obj | ✅ Converted | 🔴 Not-Converted | % | Start | End | Time | Tokens | DDL Size |
|  | [`chunk-007`](chunks/chunk-007_report.md) | 3 | 3 | 3 | 0 | 100.0% | 0 | 0 | 0 | — | 0:00:00 | 0:00:22 | 22.5s | 9,290 | 999 B |
|  | [`chunk-000`](chunks/chunk-000_report.md) | 1 | 0 | 0 | 0 | — | 1 | 1 | 0 | 100.0% | 0:00:00 | 0:00:01 | 0.3s | 0 | 70 B |
| 🚩 | **[`chunk-006`](chunks/chunk-006_report.md)** | 24 | 20 | 20 | 0 | 100.0% | 4 | 0 | 4 | 0.0% | 0:00:00 | 0:02:10 | 2m 9s | 41,383 | 10.0 KB |
|  | [`chunk-004`](chunks/chunk-004_report.md) | 30 | 12 | 12 | 0 | 100.0% | 18 | 18 | 0 | 100.0% | 0:00:00 | 0:05:04 | 5m 3s | 75,476 | 25.8 KB |
|  | [`chunk-005`](chunks/chunk-005_report.md) | 30 | 10 | 10 | 0 | 100.0% | 20 | 20 | 0 | 100.0% | 0:00:00 | 0:03:46 | 3m 45s | 66,304 | 17.1 KB |
|  | [`chunk-002`](chunks/chunk-002_report.md) | 30 | 5 | 5 | 0 | 100.0% | 25 | 25 | 0 | 100.0% | 0:00:00 | 0:01:10 | 1m 9s | 16,062 | 5.8 KB |
|  | [`chunk-001`](chunks/chunk-001_report.md) | 30 | 0 | 0 | 0 | — | 30 | 30 | 0 | 100.0% | 0:00:00 | 0:00:01 | 0.6s | 0 | 5.2 KB |
|  | [`chunk-003`](chunks/chunk-003_report.md) | 30 | 8 | 8 | 0 | 100.0% | 22 | 22 | 0 | 100.0% | 0:00:00 | 0:05:56 | 5m 55s | 110,331 | 37.1 KB |
|  | [`chunk-008`](chunks/chunk-008_report.md) | 30 | 0 | 0 | 0 | — | 30 | 30 | 0 | 100.0% | 0:05:04 | 0:05:05 | 0.6s | 0 | 2.8 KB |
|  | [`chunk-017`](chunks/chunk-017_report.md) | 22 | 20 | 20 | 0 | 100.0% | 2 | 2 | 0 | 100.0% | 0:05:56 | 0:32:36 | 26m 39s | 82,225 | 32.2 KB |
| 🚩 | **[`chunk-018`](chunks/chunk-018_report.md)** | 22 | 20 | 7 | 13 | 35.0% | 2 | 2 | 0 | 100.0% | 0:05:56 | 1:39:55 | 1h 33m 58s | 100,169 | 30.5 KB |
| 🚩 | **[`chunk-010`](chunks/chunk-010_report.md)** | 30 | 8 | 8 | 0 | 100.0% | 22 | 10 | 12 | 45.5% | 0:05:57 | 0:15:04 | 9m 7s | 64,249 | 18.2 KB |
| 🚩 | **[`chunk-012`](chunks/chunk-012_report.md)** | 30 | 20 | 11 | 9 | 55.0% | 10 | 10 | 0 | 100.0% | 0:05:57 | 1:39:55 | 1h 33m 58s | 114,146 | 37.2 KB |
| 🚩 | **[`chunk-013`](chunks/chunk-013_report.md)** | 30 | 14 | 0 | 14 | 0.0% | 16 | 3 | 13 | 18.8% | 0:05:57 | 1:15:57 | 1h 10m 0s | 86,390 | 18.5 KB |
| 🚩 | **[`chunk-014`](chunks/chunk-014_report.md)** | 30 | 18 | 17 | 1 | 94.4% | 12 | 11 | 1 | 91.7% | 0:05:57 | 1:28:55 | 1h 22m 57s | 91,602 | 13.7 KB |
| 🚩 | **[`chunk-009`](chunks/chunk-009_report.md)** | 30 | 3 | 3 | 0 | 100.0% | 27 | 17 | 10 | 63.0% | 0:05:57 | 0:11:50 | 5m 53s | 18,046 | 2.9 KB |
| 🚩 | **[`chunk-016`](chunks/chunk-016_report.md)** | 23 | 18 | 16 | 2 | 88.9% | 3 | 2 | 1 | 66.7% | 0:05:57 | 1:21:51 | 1h 15m 53s | 108,565 | 63.4 KB |
| 🚩 | **[`chunk-030`](chunks/chunk-030_report.md)** | 8 | 4 | 0 | 4 | 0.0% | 0 | 0 | 0 | — | 0:05:57 | 1:15:57 | 1h 9m 59s | 196,576 | 38.8 KB |
| 🚩 | **[`chunk-031`](chunks/chunk-031_report.md)** | 6 | 3 | 0 | 3 | 0.0% | 0 | 0 | 0 | — | 0:05:57 | 1:21:44 | 1h 15m 46s | 164,486 | 51.5 KB |
| 🚩 | **[`chunk-025`](chunks/chunk-025_report.md)** | 10 | 5 | 0 | 5 | 0.0% | 0 | 0 | 0 | — | 0:05:57 | 1:21:44 | 1h 15m 46s | 157,861 | 47.1 KB |
|  | [`chunk-024`](chunks/chunk-024_report.md) | 10 | 5 | 5 | 0 | 100.0% | 0 | 0 | 0 | — | 0:05:57 | 0:14:27 | 8m 29s | 160,011 | 49.7 KB |
| 🚩 | **[`chunk-023`](chunks/chunk-023_report.md)** | 12 | 6 | 0 | 6 | 0.0% | 0 | 0 | 0 | — | 0:05:57 | 1:21:43 | 1h 15m 46s | 184,519 | 49.4 KB |
| 🚩 | **[`chunk-026`](chunks/chunk-026_report.md)** | 8 | 4 | 0 | 4 | 0.0% | 0 | 0 | 0 | — | 0:05:57 | 1:15:57 | 1h 10m 0s | 205,619 | 41.0 KB |
| 🚩 | **[`chunk-022`](chunks/chunk-022_report.md)** | 12 | 6 | 0 | 6 | 0.0% | 0 | 0 | 0 | — | 0:05:57 | 1:14:38 | 1h 8m 40s | 179,432 | 53.3 KB |
| 🚩 | **[`chunk-021`](chunks/chunk-021_report.md)** | 16 | 8 | 0 | 8 | 0.0% | 0 | 0 | 0 | — | 0:05:57 | 1:39:54 | 1h 33m 57s | 213,246 | 72.8 KB |
| 🚩 | **[`chunk-020`](chunks/chunk-020_report.md)** | 20 | 10 | 0 | 10 | 0.0% | 0 | 0 | 0 | — | 0:05:57 | 1:39:55 | 1h 33m 58s | 253,841 | 82.6 KB |
| 🚩 | **[`chunk-019`](chunks/chunk-019_report.md)** | 20 | 10 | 0 | 10 | 0.0% | 0 | 0 | 0 | — | 0:05:57 | 1:39:55 | 1h 33m 58s | 260,997 | 87.3 KB |
|  | [`chunk-047`](chunks/chunk-047_report.md) | 20 | 20 | 20 | 0 | 100.0% | 0 | 0 | 0 | — | 1:28:51 | 1:42:47 | 13m 56s | 71,179 | 24.9 KB |
| 🚩 | **[`chunk-045`](chunks/chunk-045_report.md)** | 30 | 14 | 14 | 0 | 100.0% | 16 | 14 | 2 | 87.5% | 1:28:51 | 1:45:51 | 16m 59s | 116,604 | 24.7 KB |
| 🚩 | **[`chunk-038`](chunks/chunk-038_report.md)** | 30 | 5 | 5 | 0 | 100.0% | 25 | 22 | 3 | 88.0% | 1:28:51 | 1:41:39 | 12m 48s | 27,674 | 8.0 KB |
| 🚩 | **[`chunk-037`](chunks/chunk-037_report.md)** | 30 | 4 | 4 | 0 | 100.0% | 26 | 24 | 2 | 92.3% | 1:28:51 | 1:43:19 | 14m 27s | 72,257 | 17.9 KB |
|  | [`chunk-032`](chunks/chunk-032_report.md) | 30 | 0 | 0 | 0 | — | 30 | 30 | 0 | 100.0% | 1:28:51 | 1:40:28 | 11m 36s | 10,655 | 3.8 KB |
|  | [`chunk-033`](chunks/chunk-033_report.md) | 30 | 0 | 0 | 0 | — | 30 | 30 | 0 | 100.0% | 1:28:51 | 1:28:52 | 0.9s | 0 | 3.5 KB |
| 🚩 | **[`chunk-034`](chunks/chunk-034_report.md)** | 30 | 0 | 0 | 0 | — | 30 | 29 | 1 | 96.7% | 1:28:51 | 1:28:56 | 4.7s | 0 | 3.2 KB |
|  | [`chunk-036`](chunks/chunk-036_report.md) | 30 | 0 | 0 | 0 | — | 27 | 27 | 0 | 100.0% | 1:28:51 | 1:40:31 | 11m 39s | 18,878 | 2.9 KB |
| 🚩 | **[`chunk-046`](chunks/chunk-046_report.md)** | 23 | 21 | 20 | 1 | 95.2% | 2 | 2 | 0 | 100.0% | 1:39:55 | 1:46:45 | 6m 49s | 142,081 | 30.7 KB |
| 🚩 | **[`chunk-044`](chunks/chunk-044_report.md)** | 30 | 16 | 16 | 0 | 100.0% | 14 | 5 | 9 | 35.7% | 1:39:55 | 2:00:43 | 20m 47s | 195,506 | 30.7 KB |
| 🚩 | **[`chunk-040`](chunks/chunk-040_report.md)** | 30 | 10 | 10 | 0 | 100.0% | 20 | 12 | 8 | 60.0% | 1:39:55 | 1:59:32 | 19m 36s | 205,704 | 27.0 KB |
|  | [`chunk-041`](chunks/chunk-041_report.md) | 30 | 9 | 9 | 0 | 100.0% | 21 | 21 | 0 | 100.0% | 1:39:55 | 1:47:21 | 7m 25s | 166,301 | 21.9 KB |
|  | [`chunk-039`](chunks/chunk-039_report.md) | 30 | 10 | 10 | 0 | 100.0% | 20 | 20 | 0 | 100.0% | 1:39:55 | 1:44:19 | 4m 23s | 93,924 | 28.0 KB |
| 🚩 | **[`chunk-042`](chunks/chunk-042_report.md)** | 30 | 6 | 2 | 4 | 33.3% | 24 | 23 | 1 | 95.8% | 1:39:56 | 1:46:01 | 6m 5s | 127,877 | 17.9 KB |
| 🚩 | **[`chunk-043`](chunks/chunk-043_report.md)** | 30 | 9 | 9 | 0 | 100.0% | 21 | 20 | 1 | 95.2% | 1:39:56 | 1:42:37 | 2m 41s | 68,735 | 9.4 KB |
| 🚩 | **[`chunk-035`](chunks/chunk-035_report.md)** | 30 | 0 | 0 | 0 | — | 9 | 0 | 9 | 0.0% | 1:39:56 | 1:40:10 | 14.2s | 4,142 | 3.0 KB |
|  | [`chunk-048`](chunks/chunk-048_report.md) | 8 | 4 | 4 | 0 | 100.0% | 0 | 0 | 0 | — | 1:39:56 | 1:43:38 | 3m 41s | 195,437 | 37.3 KB |
| 🚩 | **[`chunk-050`](chunks/chunk-050_report.md)** | 21 | 20 | 19 | 1 | 95.0% | 1 | 0 | 1 | 0.0% | 1:43:38 | 1:58:20 | 14m 42s | 97,572 | 15.5 KB |
| 🚩 | **[`chunk-049`](chunks/chunk-049_report.md)** | 30 | 8 | 8 | 0 | 100.0% | 21 | 17 | 4 | 81.0% | 1:59:32 | 2:03:47 | 4m 15s | 70,194 | 14.3 KB |
| 🚩 | **[`chunk-054`](chunks/chunk-054_report.md)** | 30 | 13 | 12 | 1 | 92.3% | 17 | 12 | 5 | 70.6% | 2:00:43 | 2:08:54 | 8m 11s | 191,286 | 38.8 KB |
| 🚩 | **[`chunk-052`](chunks/chunk-052_report.md)** | 30 | 1 | 1 | 0 | 100.0% | 29 | 25 | 4 | 86.2% | 2:00:43 | 2:06:46 | 6m 2s | 143,130 | 31.9 KB |
| 🚩 | **[`chunk-053`](chunks/chunk-053_report.md)** | 30 | 1 | 1 | 0 | 100.0% | 29 | 23 | 6 | 79.3% | 2:00:43 | 2:01:28 | 44.5s | 16,580 | 3.6 KB |
| 🚩 | **[`chunk-051`](chunks/chunk-051_report.md)** | 30 | 0 | 0 | 0 | — | 30 | 9 | 21 | 30.0% | 2:00:43 | 2:01:08 | 24.6s | 13,721 | 3.1 KB |
| 🚩 | **[`chunk-055`](chunks/chunk-055_report.md)** | 30 | 7 | 6 | 1 | 85.7% | 23 | 12 | 11 | 52.2% | 2:08:54 | 2:12:13 | 3m 19s | 64,312 | 10.7 KB |
|  | [`chunk-011`](chunks/chunk-011_report.md) | 30 | 9 | 9 | 0 | 100.0% | 13 | 13 | 0 | 100.0% | 2:12:13 | 2:20:30 | 8m 16s | 539,144 | 83.5 KB |
|  | [`chunk-015`](chunks/chunk-015_report.md) | 27 | 19 | 18 | 1 | 94.7% | 5 | 5 | 0 | 100.0% | 2:20:30 | 2:30:49 | 10m 18s | 441,789 | 76.5 KB |
|  | [`chunk-027`](chunks/chunk-027_report.md) | 8 | 4 | 4 | 0 | 100.0% | 0 | 0 | 0 | — | 2:20:30 | 2:24:28 | 3m 57s | 416,293 | 38.9 KB |
|  | [`chunk-028`](chunks/chunk-028_report.md) | 8 | 4 | 3 | 1 | 75.0% | 0 | 0 | 0 | — | 2:30:49 | 2:56:03 | 25m 13s | 342,528 | 48.3 KB |
| 🚩 | **[`chunk-029`](chunks/chunk-029_report.md)** | 8 | 4 | 0 | 4 | 0.0% | 0 | 0 | 0 | — | 2:30:49 | 2:55:53 | 25m 4s | 364,511 | 40.9 KB |

## 🚨 Action Required

> **641 object(s)** need a manual touch before the converted schema is production-ready.
> The groups below explain _why_ each issue happened, _what_ it means, and _how_ to resolve it.

---

### 1. Cross-chunk foreign keys — 39 object(s) · 🟠 medium severity

> _Why this happened_ — These foreign-key constraints reference parent tables that were compiled in a different chunk.
>
> _What it means_ — The DDL can be valid, but it must run after the referenced parent tables exist in the deployment target.
>
> _How to resolve right now_ ⏱️ **~5 min, cutover day**
> 1. Run `deploy.sql` end-to-end so deferred FK DDL executes late.
> 2. Spot-check the affected constraints in `pg_constraint`.
> 3. Run referential-integrity validation for the child tables.

<details><summary>📋 Affected objects (39)</summary>

| # | Object | Type | Chunk |
|--:|---|---|---|
| 1 | `CUSTOMER` | REF_CONSTRAINT | [`chunk-010`](chunks/chunk-010_report.md) |
| 2 | `GL_JOURNAL_LINE` | REF_CONSTRAINT | [`chunk-013`](chunks/chunk-013_report.md) |
| 3 | `PURCHASE_ORDER` | REF_CONSTRAINT | [`chunk-013`](chunks/chunk-013_report.md) |
| 4 | `SALES_ORDER_LINE` | REF_CONSTRAINT | [`chunk-013`](chunks/chunk-013_report.md) |
| 5 | `EMPLOYEE` | REF_CONSTRAINT | [`chunk-014`](chunks/chunk-014_report.md) |
| 6 | `GOODS_RECEIPT` | REF_CONSTRAINT | [`chunk-014`](chunks/chunk-014_report.md) |
| 7 | `INVENTORY_LOCATION` | REF_CONSTRAINT | [`chunk-014`](chunks/chunk-014_report.md) |
| 8 | `INVENTORY_MOVEMENT` | REF_CONSTRAINT | [`chunk-014`](chunks/chunk-014_report.md) |
| 9 | `PRICE_LIST_ITEM` | REF_CONSTRAINT | [`chunk-014`](chunks/chunk-014_report.md) |
| 10 | `REGION` | REF_CONSTRAINT | [`chunk-014`](chunks/chunk-014_report.md) |
| 11 | `SHIPMENT` | REF_CONSTRAINT | [`chunk-014`](chunks/chunk-014_report.md) |
| 12 | `STORE` | REF_CONSTRAINT | [`chunk-014`](chunks/chunk-014_report.md) |
| 13 | `SUPPLIER_PRODUCT` | REF_CONSTRAINT | [`chunk-014`](chunks/chunk-014_report.md) |
| 14 | `SALES_ORDER` | REF_CONSTRAINT | [`chunk-018`](chunks/chunk-018_report.md) |
| 15 | `LOYALTY_TRANSACTION` | REF_CONSTRAINT | [`chunk-032`](chunks/chunk-032_report.md) |
| 16 | `PROMOTION` | REF_CONSTRAINT | [`chunk-032`](chunks/chunk-032_report.md) |
| 17 | `TAX_RATE` | REF_CONSTRAINT | [`chunk-032`](chunks/chunk-032_report.md) |
| 18 | `ADDRESS` | REF_CONSTRAINT | [`chunk-043`](chunks/chunk-043_report.md) |
| 19 | `BRAND` | REF_CONSTRAINT | [`chunk-043`](chunks/chunk-043_report.md) |
| 20 | `COUNTRY` | REF_CONSTRAINT | [`chunk-043`](chunks/chunk-043_report.md) |
| 21 | `COUPON` | REF_CONSTRAINT | [`chunk-043`](chunks/chunk-043_report.md) |
| 22 | `CUSTOMER_ADDRESS` | REF_CONSTRAINT | [`chunk-043`](chunks/chunk-043_report.md) |
| 23 | `EXCHANGE_RATE` | REF_CONSTRAINT | [`chunk-043`](chunks/chunk-043_report.md) |
| 24 | `GL_ACCOUNT` | REF_CONSTRAINT | [`chunk-043`](chunks/chunk-043_report.md) |
| 25 | `GL_JOURNAL` | REF_CONSTRAINT | [`chunk-043`](chunks/chunk-043_report.md) |
| 26 | `INVENTORY_STOCK` | REF_CONSTRAINT | [`chunk-043`](chunks/chunk-043_report.md) |
| 27 | `LOYALTY_ACCOUNT` | REF_CONSTRAINT | [`chunk-043`](chunks/chunk-043_report.md) |
| 28 | `ORDER_PAYMENT` | REF_CONSTRAINT | [`chunk-043`](chunks/chunk-043_report.md) |
| 29 | `PRICE_LIST` | REF_CONSTRAINT | [`chunk-043`](chunks/chunk-043_report.md) |
| 30 | `PROMOTION_PRODUCT` | REF_CONSTRAINT | [`chunk-043`](chunks/chunk-043_report.md) |
| 31 | `PURCHASE_ORDER_LINE` | REF_CONSTRAINT | [`chunk-043`](chunks/chunk-043_report.md) |
| 32 | `SHIPMENT_LINE` | REF_CONSTRAINT | [`chunk-043`](chunks/chunk-043_report.md) |
| 33 | `WAREHOUSE` | REF_CONSTRAINT | [`chunk-043`](chunks/chunk-043_report.md) |
| 34 | `PRODUCT` | REF_CONSTRAINT | [`chunk-042`](chunks/chunk-042_report.md) |
| 35 | `RETURN_LINE` | REF_CONSTRAINT | [`chunk-041`](chunks/chunk-041_report.md) |
| 36 | `RETURN_REQUEST` | REF_CONSTRAINT | [`chunk-050`](chunks/chunk-050_report.md) |
| 37 | `PRODUCT_VARIANT` | REF_CONSTRAINT | [`chunk-053`](chunks/chunk-053_report.md) |
| 38 | `SUPPLIER` | REF_CONSTRAINT | [`chunk-053`](chunks/chunk-053_report.md) |
| 39 | `StoreAudit_Legacy` | REF_CONSTRAINT | [`chunk-049`](chunks/chunk-049_report.md) |

</details>

---

### 2. Strict-mode deferred validation — 10 object(s) · 🟠 medium severity

> _Why this happened_ — Strict routine body or guarded-trigger validation could not be completed successfully.
>
> _What it means_ — These objects remain pending, unresolved, or producer-contract failed and are not counted as successful compile output.
>
> _How to resolve right now_ ⏱️ **deferred-handler follow-up**
> 1. Inspect the Deferred / Unverified Producer Objects table under Strict-Mode Validation.
> 2. Resolve the final validation error or producer-contract diagnostic.
> 3. Treat the affected objects as unverified until validation passes.

<details><summary>📋 Affected objects (10)</summary>

| # | Object | Type | Chunk | Detail |
|--:|---|---|---|---|
| 1 | `SYN_GEN_PKG_002` | SYNONYM | [`chunk-009`](chunks/chunk-009_report.md) | 42883: function contoso.pkg_gen_ifc_in_001$batch_ref(timestamp without time zon… |
| 2 | `SYN_GEN_PKG_008` | SYNONYM | [`chunk-009`](chunks/chunk-009_report.md) | 42883: function contoso.pkg_gen_ifc_in_003$batch_ref(timestamp without time zon… |
| 3 | `SYN_GEN_PKG_014` | SYNONYM | [`chunk-009`](chunks/chunk-009_report.md) | 42883: function contoso.pkg_gen_ifc_in_005$batch_ref(timestamp without time zon… |
| 4 | `SYN_GEN_PKG_032` | SYNONYM | [`chunk-009`](chunks/chunk-009_report.md) | 42883: function contoso.pkg_gen_ifc_in_011$batch_ref(timestamp without time zon… |
| 5 | `SYN_GEN_PKG_038` | SYNONYM | [`chunk-009`](chunks/chunk-009_report.md) | 42883: function contoso.pkg_gen_ifc_in_013$batch_ref(timestamp without time zon… |
| 6 | `SYN_GEN_PKG_050` | SYNONYM | [`chunk-009`](chunks/chunk-009_report.md) | 42883: function contoso.pkg_gen_ifc_in_017$batch_ref(timestamp without time zon… |
| 7 | `SYN_GEN_PKG_068` | SYNONYM | [`chunk-009`](chunks/chunk-009_report.md) | 42883: function contoso.pkg_gen_ifc_in_023$batch_ref(timestamp without time zon… |
| 8 | `SYN_GEN_PKG_074` | SYNONYM | [`chunk-009`](chunks/chunk-009_report.md) | 42883: function contoso.pkg_gen_ifc_in_025$batch_ref(timestamp without time zon… |
| 9 | `SYN_GEN_PKG_086` | SYNONYM | [`chunk-009`](chunks/chunk-009_report.md) | 42883: function contoso.pkg_gen_ifc_in_029$batch_ref(timestamp without time zon… |
| 10 | `SYN_GEN_PKG_092` | SYNONYM | [`chunk-009`](chunks/chunk-009_report.md) | 42883: function contoso.pkg_gen_rules_001$applies_to(numeric, numeric, timestam… |

</details>

---

### 3. Manual DDL fixes — 512 object(s) · 🔴 high severity

> _Why this happened_ — The converter exhausted automatic compile/fix handling for these objects.
>
> _What it means_ — The emitted DDL is best-effort or missing and should not be treated as production-ready until reviewed.
>
> _How to resolve right now_ ⏱️ **~10-30 min per pattern**
> 1. Open the per-chunk report and inspect the object details.
> 2. Compare the generated PostgreSQL DDL with the Oracle source.
> 3. Patch and re-run the statement against the target schema.

<details><summary>📋 Affected objects (512)</summary>

| # | Object | Type | Chunk | Fix Attempts |
|--:|---|---|---|--:|
| 1 | `PKG_GEN_IFC_IN_011` | PACKAGE_BODY | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 2 | `pkg_gen_ifc_in_011$__state__` | PACKAGE_STATE | [`chunk-022`](chunks/chunk-022_report.md) | 1 |
| 3 | `pkg_gen_ifc_in_011$batch_ref` | FUNCTION | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 4 | `pkg_gen_ifc_in_011$pending_count` | FUNCTION | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 5 | `pkg_gen_ifc_in_011$import_batch` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 6 | `pkg_gen_ifc_in_011$reconcile` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 7 | `pkg_gen_ifc_in_011$quarantine` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 8 | `PKG_GEN_IFC_OUT_008` | PACKAGE_BODY | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 9 | `pkg_gen_ifc_out_008$__state__` | PACKAGE_STATE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 10 | `pkg_gen_ifc_out_008$batch_ref` | FUNCTION | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 11 | `pkg_gen_ifc_out_008$pending_count` | FUNCTION | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 12 | `pkg_gen_ifc_out_008$reconcile` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 13 | `pkg_gen_ifc_out_008$quarantine` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 14 | `pkg_gen_ifc_out_008$import_batch` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 15 | `PKG_GEN_IFC_OUT_020` | PACKAGE_BODY | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 16 | `pkg_gen_ifc_out_020$__state__` | PACKAGE_STATE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 17 | `pkg_gen_ifc_out_020$batch_ref` | FUNCTION | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 18 | `pkg_gen_ifc_out_020$pending_count` | FUNCTION | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 19 | `pkg_gen_ifc_out_020$reconcile` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 20 | `pkg_gen_ifc_out_020$quarantine` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 21 | `pkg_gen_ifc_out_020$import_batch` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 22 | `PKG_GEN_IFC_OUT_022` | PACKAGE_BODY | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 23 | `pkg_gen_ifc_out_022$__state__` | PACKAGE_STATE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 24 | `pkg_gen_ifc_out_022$batch_ref` | FUNCTION | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 25 | `pkg_gen_ifc_out_022$open_feed` | FUNCTION | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 26 | `pkg_gen_ifc_out_022$pending_count` | FUNCTION | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 27 | `pkg_gen_ifc_out_022$import_batch` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 28 | `pkg_gen_ifc_out_022$reconcile` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 29 | `pkg_gen_ifc_out_022$quarantine` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 30 | `PKG_GEN_IFC_OUT_032` | PACKAGE_BODY | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 31 | `pkg_gen_ifc_out_032$__state__` | PACKAGE_STATE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 32 | `pkg_gen_ifc_out_032$batch_ref` | FUNCTION | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 33 | `pkg_gen_ifc_out_032$pending_count` | FUNCTION | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 34 | `pkg_gen_ifc_out_032$reconcile` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 35 | `pkg_gen_ifc_out_032$quarantine` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 36 | `pkg_gen_ifc_out_032$import_batch` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 37 | `PKG_GEN_IFC_OUT_034` | PACKAGE_BODY | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 38 | `pkg_gen_ifc_out_034$__state__` | PACKAGE_STATE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 39 | `pkg_gen_ifc_out_034$batch_ref` | FUNCTION | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 40 | `pkg_gen_ifc_out_034$open_feed` | FUNCTION | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 41 | `pkg_gen_ifc_out_034$pending_count` | FUNCTION | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 42 | `pkg_gen_ifc_out_034$import_batch` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 43 | `pkg_gen_ifc_out_034$reconcile` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 44 | `pkg_gen_ifc_out_034$quarantine` | PROCEDURE | [`chunk-022`](chunks/chunk-022_report.md) | 0 |
| 45 | `PKG_GEN_RULES_004` | PACKAGE_BODY | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 46 | `pkg_gen_rules_004$__state__` | PACKAGE_STATE | [`chunk-030`](chunks/chunk-030_report.md) | 1 |
| 47 | `pkg_gen_rules_004$applies_to` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 48 | `pkg_gen_rules_004$describe` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 49 | `pkg_gen_rules_004$describe` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 50 | `pkg_gen_rules_004$describe` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 51 | `pkg_gen_rules_004$describe` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 52 | `pkg_gen_rules_004$evaluate` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 53 | `pkg_gen_rules_004$apply_batch` | PROCEDURE | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 54 | `PKG_GEN_RULES_008` | PACKAGE_BODY | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 55 | `pkg_gen_rules_008$__state__` | PACKAGE_STATE | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 56 | `pkg_gen_rules_008$applies_to` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 57 | `pkg_gen_rules_008$describe` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 58 | `pkg_gen_rules_008$describe` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 59 | `pkg_gen_rules_008$describe` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 60 | `pkg_gen_rules_008$describe` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 61 | `pkg_gen_rules_008$evaluate` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 62 | `pkg_gen_rules_008$apply_batch` | PROCEDURE | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 63 | `PKG_GEN_RULES_024` | PACKAGE_BODY | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 64 | `pkg_gen_rules_024$__state__` | PACKAGE_STATE | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 65 | `pkg_gen_rules_024$applies_to` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 66 | `pkg_gen_rules_024$describe` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 67 | `pkg_gen_rules_024$describe` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 68 | `pkg_gen_rules_024$describe` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 69 | `pkg_gen_rules_024$describe` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 70 | `pkg_gen_rules_024$evaluate` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 71 | `pkg_gen_rules_024$apply_batch` | PROCEDURE | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 72 | `PKG_GEN_RULES_028` | PACKAGE_BODY | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 73 | `pkg_gen_rules_028$__state__` | PACKAGE_STATE | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 74 | `pkg_gen_rules_028$applies_to` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 75 | `pkg_gen_rules_028$describe` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 76 | `pkg_gen_rules_028$describe` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 77 | `pkg_gen_rules_028$describe` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 78 | `pkg_gen_rules_028$describe` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 79 | `pkg_gen_rules_028$evaluate` | FUNCTION | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 80 | `pkg_gen_rules_028$apply_batch` | PROCEDURE | [`chunk-030`](chunks/chunk-030_report.md) | 0 |
| 81 | `PKG_GEN_IFC_IN_003` | PACKAGE_BODY | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 82 | `pkg_gen_ifc_in_003$__state__` | PACKAGE_STATE | [`chunk-026`](chunks/chunk-026_report.md) | 1 |
| 83 | `pkg_gen_ifc_in_003$batch_ref` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 84 | `pkg_gen_ifc_in_003$resolve_key` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 85 | `pkg_gen_ifc_in_003$resolve_key` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 86 | `pkg_gen_ifc_in_003$resolve_key` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 87 | `pkg_gen_ifc_in_003$pending_count` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 88 | `pkg_gen_ifc_in_003$import_batch` | PROCEDURE | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 89 | `pkg_gen_ifc_in_003$reconcile` | PROCEDURE | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 90 | `pkg_gen_ifc_in_003$quarantine` | PROCEDURE | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 91 | `PKG_GEN_IFC_OUT_012` | PACKAGE_BODY | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 92 | `pkg_gen_ifc_out_012$__state__` | PACKAGE_STATE | [`chunk-026`](chunks/chunk-026_report.md) | 1 |
| 93 | `pkg_gen_ifc_out_012$batch_ref` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 94 | `pkg_gen_ifc_out_012$resolve_key` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 95 | `pkg_gen_ifc_out_012$resolve_key` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 96 | `pkg_gen_ifc_out_012$resolve_key` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 97 | `pkg_gen_ifc_out_012$pending_count` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 98 | `pkg_gen_ifc_out_012$reconcile` | PROCEDURE | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 99 | `pkg_gen_ifc_out_012$quarantine` | PROCEDURE | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 100 | `pkg_gen_ifc_out_012$import_batch` | PROCEDURE | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 101 | `PKG_GEN_IFC_OUT_024` | PACKAGE_BODY | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 102 | `pkg_gen_ifc_out_024$__state__` | PACKAGE_STATE | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 103 | `pkg_gen_ifc_out_024$batch_ref` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 104 | `pkg_gen_ifc_out_024$resolve_key` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 105 | `pkg_gen_ifc_out_024$resolve_key` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 106 | `pkg_gen_ifc_out_024$resolve_key` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 107 | `pkg_gen_ifc_out_024$pending_count` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 108 | `pkg_gen_ifc_out_024$reconcile` | PROCEDURE | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 109 | `pkg_gen_ifc_out_024$quarantine` | PROCEDURE | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 110 | `pkg_gen_ifc_out_024$import_batch` | PROCEDURE | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 111 | `PKG_GEN_IFC_OUT_036` | PACKAGE_BODY | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 112 | `pkg_gen_ifc_out_036$__state__` | PACKAGE_STATE | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 113 | `pkg_gen_ifc_out_036$batch_ref` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 114 | `pkg_gen_ifc_out_036$resolve_key` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 115 | `pkg_gen_ifc_out_036$resolve_key` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 116 | `pkg_gen_ifc_out_036$resolve_key` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 117 | `pkg_gen_ifc_out_036$pending_count` | FUNCTION | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 118 | `pkg_gen_ifc_out_036$reconcile` | PROCEDURE | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 119 | `pkg_gen_ifc_out_036$quarantine` | PROCEDURE | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 120 | `pkg_gen_ifc_out_036$import_batch` | PROCEDURE | [`chunk-026`](chunks/chunk-026_report.md) | 0 |
| 121 | `V_GEN_KPI_004` | VIEW | [`chunk-013`](chunks/chunk-013_report.md) | 1 |
| 122 | `V_GEN_KPI_008` | VIEW | [`chunk-013`](chunks/chunk-013_report.md) | 2 |
| 123 | `V_GEN_KPI_012` | VIEW | [`chunk-013`](chunks/chunk-013_report.md) | 2 |
| 124 | `V_GEN_KPI_016` | VIEW | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 125 | `V_GEN_KPI_020` | VIEW | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 126 | `V_GEN_KPI_024` | VIEW | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 127 | `V_GEN_KPI_028` | VIEW | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 128 | `V_GEN_LEGACY_014` | VIEW | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 129 | `V_GEN_LEGACY_017` | VIEW | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 130 | `V_GEN_LEGACY_020` | VIEW | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 131 | `V_GEN_LEGACY_023` | VIEW | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 132 | `V_GEN_LEGACY_026` | VIEW | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 133 | `V_GEN_LEGACY_029` | VIEW | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 134 | `FN_GEN_CHK_IMPURE_032` | FUNCTION | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 135 | `FN_GEN_CHK_IMPURE_035` | FUNCTION | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 136 | `FN_GEN_CHK_IMPURE_038` | FUNCTION | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 137 | `FN_SPLIT_CSV` | FUNCTION | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 138 | `TRG_AR_GL_JOURNAL_LINE_B` | TRIGGER | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 139 | `TRG_BI_SALES_ORDER_WEB` | TRIGGER | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 140 | `TRG_GEN_STMT_001` | TRIGGER | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 141 | `TRG_GEN_STMT_002` | TRIGGER | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 142 | `TRG_GEN_STMT_003` | TRIGGER | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 143 | `TRG_GEN_STMT_004` | TRIGGER | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 144 | `TRG_GEN_STMT_005` | TRIGGER | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 145 | `TRG_GEN_STMT_006` | TRIGGER | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 146 | `TRG_GEN_WHEN_001` | TRIGGER | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 147 | `TRG_GEN_WHEN_002` | TRIGGER | [`chunk-013`](chunks/chunk-013_report.md) | 0 |
| 148 | `PKG_GEN_IFC_IN_005` | PACKAGE_BODY | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 149 | `pkg_gen_ifc_in_005$__state__` | PACKAGE_STATE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 150 | `pkg_gen_ifc_in_005$batch_ref` | FUNCTION | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 151 | `pkg_gen_ifc_in_005$pending_count` | FUNCTION | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 152 | `pkg_gen_ifc_in_005$reconcile` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 153 | `pkg_gen_ifc_in_005$quarantine` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 154 | `pkg_gen_ifc_in_005$import_batch` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 155 | `PKG_GEN_IFC_IN_017` | PACKAGE_BODY | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 156 | `pkg_gen_ifc_in_017$__state__` | PACKAGE_STATE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 157 | `pkg_gen_ifc_in_017$batch_ref` | FUNCTION | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 158 | `pkg_gen_ifc_in_017$pending_count` | FUNCTION | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 159 | `pkg_gen_ifc_in_017$reconcile` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 160 | `pkg_gen_ifc_in_017$quarantine` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 161 | `pkg_gen_ifc_in_017$import_batch` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 162 | `PKG_GEN_IFC_IN_023` | PACKAGE_BODY | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 163 | `pkg_gen_ifc_in_023$batch_ref` | FUNCTION | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 164 | `pkg_gen_ifc_in_023$pending_count` | FUNCTION | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 165 | `pkg_gen_ifc_in_023$import_batch` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 166 | `pkg_gen_ifc_in_023$reconcile` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 167 | `pkg_gen_ifc_in_023$quarantine` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 168 | `PKG_GEN_IFC_IN_029` | PACKAGE_BODY | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 169 | `pkg_gen_ifc_in_029$__state__` | PACKAGE_STATE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 170 | `pkg_gen_ifc_in_029$batch_ref` | FUNCTION | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 171 | `pkg_gen_ifc_in_029$pending_count` | FUNCTION | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 172 | `pkg_gen_ifc_in_029$reconcile` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 173 | `pkg_gen_ifc_in_029$quarantine` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 174 | `pkg_gen_ifc_in_029$import_batch` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 175 | `PKG_GEN_IFC_IN_035` | PACKAGE_BODY | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 176 | `pkg_gen_ifc_in_035$__state__` | PACKAGE_STATE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 177 | `pkg_gen_ifc_in_035$batch_ref` | FUNCTION | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 178 | `pkg_gen_ifc_in_035$pending_count` | FUNCTION | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 179 | `pkg_gen_ifc_in_035$import_batch` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 180 | `pkg_gen_ifc_in_035$reconcile` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 181 | `pkg_gen_ifc_in_035$quarantine` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 182 | `PKG_GEN_IFC_OUT_002` | PACKAGE_BODY | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 183 | `pkg_gen_ifc_out_002$__state__` | PACKAGE_STATE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 184 | `pkg_gen_ifc_out_002$batch_ref` | FUNCTION | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 185 | `pkg_gen_ifc_out_002$pending_count` | FUNCTION | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 186 | `pkg_gen_ifc_out_002$import_batch` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 187 | `pkg_gen_ifc_out_002$reconcile` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 188 | `pkg_gen_ifc_out_002$quarantine` | PROCEDURE | [`chunk-023`](chunks/chunk-023_report.md) | 0 |
| 189 | `PKG_FINANCE_GL` | PACKAGE_BODY | [`chunk-031`](chunks/chunk-031_report.md) | 0 |
| 190 | `pkg_finance_gl$__state__` | PACKAGE_STATE | [`chunk-031`](chunks/chunk-031_report.md) | 0 |
| 191 | `pkg_finance_gl$post_journal` | PROCEDURE | [`chunk-031`](chunks/chunk-031_report.md) | 1 |
| 192 | `pkg_finance_gl$post_journal` | PROCEDURE | [`chunk-031`](chunks/chunk-031_report.md) | 0 |
| 193 | `pkg_reporting$open_category_rollup` | FUNCTION | [`chunk-031`](chunks/chunk-031_report.md) | 1 |
| 194 | `pkg_utils$to_display` | FUNCTION | [`chunk-031`](chunks/chunk-031_report.md) | 0 |
| 195 | `pkg_utils$to_display` | FUNCTION | [`chunk-031`](chunks/chunk-031_report.md) | 0 |
| 196 | `pkg_utils$next_id` | FUNCTION | [`chunk-031`](chunks/chunk-031_report.md) | 0 |
| 197 | `pkg_utils$long_notes_to_clob` | FUNCTION | [`chunk-031`](chunks/chunk-031_report.md) | 0 |
| 198 | `pkg_utils$normalise_text` | FUNCTION | [`chunk-031`](chunks/chunk-031_report.md) | 0 |
| 199 | `pkg_utils$store_label` | FUNCTION | [`chunk-031`](chunks/chunk-031_report.md) | 0 |
| 200 | `pkg_utils$set_numeric_characters` | PROCEDURE | [`chunk-031`](chunks/chunk-031_report.md) | 0 |
| 201 | `pkg_utils$describe_store` | PROCEDURE | [`chunk-031`](chunks/chunk-031_report.md) | 0 |
| 202 | `PKG_GEN_IFC_IN_001` | PACKAGE_BODY | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 203 | `pkg_gen_ifc_in_001$__state__` | PACKAGE_STATE | [`chunk-025`](chunks/chunk-025_report.md) | 1 |
| 204 | `pkg_gen_ifc_in_001$batch_ref` | FUNCTION | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 205 | `pkg_gen_ifc_in_001$open_feed` | FUNCTION | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 206 | `pkg_gen_ifc_in_001$pending_count` | FUNCTION | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 207 | `pkg_gen_ifc_in_001$reconcile` | PROCEDURE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 208 | `pkg_gen_ifc_in_001$quarantine` | PROCEDURE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 209 | `pkg_gen_ifc_in_001$import_batch` | PROCEDURE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 210 | `PKG_GEN_IFC_IN_013` | PACKAGE_BODY | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 211 | `pkg_gen_ifc_in_013$__state__` | PACKAGE_STATE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 212 | `pkg_gen_ifc_in_013$batch_ref` | FUNCTION | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 213 | `pkg_gen_ifc_in_013$open_feed` | FUNCTION | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 214 | `pkg_gen_ifc_in_013$pending_count` | FUNCTION | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 215 | `pkg_gen_ifc_in_013$reconcile` | PROCEDURE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 216 | `pkg_gen_ifc_in_013$quarantine` | PROCEDURE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 217 | `pkg_gen_ifc_in_013$import_batch` | PROCEDURE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 218 | `PKG_GEN_IFC_IN_025` | PACKAGE_BODY | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 219 | `pkg_gen_ifc_in_025$__state__` | PACKAGE_STATE | [`chunk-025`](chunks/chunk-025_report.md) | 1 |
| 220 | `pkg_gen_ifc_in_025$batch_ref` | FUNCTION | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 221 | `pkg_gen_ifc_in_025$open_feed` | FUNCTION | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 222 | `pkg_gen_ifc_in_025$pending_count` | FUNCTION | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 223 | `pkg_gen_ifc_in_025$reconcile` | PROCEDURE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 224 | `pkg_gen_ifc_in_025$quarantine` | PROCEDURE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 225 | `pkg_gen_ifc_in_025$import_batch` | PROCEDURE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 226 | `PKG_GEN_IFC_IN_031` | PACKAGE_BODY | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 227 | `pkg_gen_ifc_in_031$__state__` | PACKAGE_STATE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 228 | `pkg_gen_ifc_in_031$batch_ref` | FUNCTION | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 229 | `pkg_gen_ifc_in_031$open_feed` | FUNCTION | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 230 | `pkg_gen_ifc_in_031$pending_count` | FUNCTION | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 231 | `pkg_gen_ifc_in_031$import_batch` | PROCEDURE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 232 | `pkg_gen_ifc_in_031$reconcile` | PROCEDURE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 233 | `pkg_gen_ifc_in_031$quarantine` | PROCEDURE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 234 | `PKG_GEN_IFC_OUT_010` | PACKAGE_BODY | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 235 | `pkg_gen_ifc_out_010$__state__` | PACKAGE_STATE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 236 | `pkg_gen_ifc_out_010$batch_ref` | FUNCTION | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 237 | `pkg_gen_ifc_out_010$open_feed` | FUNCTION | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 238 | `pkg_gen_ifc_out_010$pending_count` | FUNCTION | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 239 | `pkg_gen_ifc_out_010$import_batch` | PROCEDURE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 240 | `pkg_gen_ifc_out_010$reconcile` | PROCEDURE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 241 | `pkg_gen_ifc_out_010$quarantine` | PROCEDURE | [`chunk-025`](chunks/chunk-025_report.md) | 0 |
| 242 | `PKG_INVENTORY` | PACKAGE_BODY | [`chunk-016`](chunks/chunk-016_report.md) | 0 |
| 243 | `pkg_inventory$__state__` | PACKAGE_STATE | [`chunk-016`](chunks/chunk-016_report.md) | 0 |
| 244 | `V_ORDER_FULFILMENT_STATUS` | VIEW | [`chunk-016`](chunks/chunk-016_report.md) | 1 |
| 245 | `TRG_CMP_SALES_ORDER_LINE` | TRIGGER | [`chunk-016`](chunks/chunk-016_report.md) | 0 |
| 246 | `pkg_loyalty$accrue_points` | PROCEDURE | [`chunk-015`](chunks/chunk-015_report.md) | 0 |
| 247 | `pkg_loyalty$tier_for_points` | FUNCTION | [`chunk-015`](chunks/chunk-015_report.md) | 0 |
| 248 | `pkg_purchasing$create_po` | PROCEDURE | [`chunk-028`](chunks/chunk-028_report.md) | 0 |
| 249 | `pkg_purchasing$approve_po` | PROCEDURE | [`chunk-028`](chunks/chunk-028_report.md) | 0 |
| 250 | `pkg_purchasing$send_po` | PROCEDURE | [`chunk-028`](chunks/chunk-028_report.md) | 0 |
| 251 | `TRG_GEN_FOL_B_002` | TRIGGER | [`chunk-014`](chunks/chunk-014_report.md) | 1 |
| 252 | `IX_SOL_LINE_LOOKUP` | INDEX | [`chunk-034`](chunks/chunk-034_report.md) | 1 |
| 253 | `PKG_AUDIT` | PACKAGE_BODY | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 254 | `pkg_audit$write_audit` | PROCEDURE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 255 | `pkg_audit$write_audit` | PROCEDURE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 256 | `pkg_audit$write_audit` | PROCEDURE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 257 | `pkg_audit$purge_before` | PROCEDURE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 258 | `pkg_audit$audit_count` | FUNCTION | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 259 | `PKG_ETL_EXPORT` | PACKAGE_BODY | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 260 | `pkg_etl_export$__state__` | PACKAGE_STATE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 261 | `pkg_etl_export$write_sales_extract` | PROCEDURE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 262 | `pkg_etl_export$build_order_document` | FUNCTION | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 263 | `pkg_etl_export$dump_to_output` | PROCEDURE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 264 | `PKG_GEN_IFC_OUT_014` | PACKAGE_BODY | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 265 | `pkg_gen_ifc_out_014$__state__` | PACKAGE_STATE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 266 | `pkg_gen_ifc_out_014$batch_ref` | FUNCTION | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 267 | `pkg_gen_ifc_out_014$pending_count` | FUNCTION | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 268 | `pkg_gen_ifc_out_014$import_batch` | PROCEDURE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 269 | `pkg_gen_ifc_out_014$reconcile` | PROCEDURE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 270 | `pkg_gen_ifc_out_014$quarantine` | PROCEDURE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 271 | `PKG_GEN_IFC_OUT_026` | PACKAGE_BODY | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 272 | `pkg_gen_ifc_out_026$batch_ref` | FUNCTION | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 273 | `pkg_gen_ifc_out_026$pending_count` | FUNCTION | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 274 | `pkg_gen_ifc_out_026$import_batch` | PROCEDURE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 275 | `pkg_gen_ifc_out_026$reconcile` | PROCEDURE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 276 | `pkg_gen_ifc_out_026$quarantine` | PROCEDURE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 277 | `PKG_GEN_RULES_002` | PACKAGE_BODY | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 278 | `pkg_gen_rules_002$__state__` | PACKAGE_STATE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 279 | `pkg_gen_rules_002$applies_to` | FUNCTION | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 280 | `pkg_gen_rules_002$evaluate` | FUNCTION | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 281 | `pkg_gen_rules_002$apply_batch` | PROCEDURE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 282 | `PKG_GEN_RULES_007` | PACKAGE_BODY | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 283 | `pkg_gen_rules_007$__state__` | PACKAGE_STATE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 284 | `pkg_gen_rules_007$applies_to` | FUNCTION | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 285 | `pkg_gen_rules_007$evaluate` | FUNCTION | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 286 | `pkg_gen_rules_007$apply_batch` | PROCEDURE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 287 | `PKG_GEN_RULES_017` | PACKAGE_BODY | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 288 | `pkg_gen_rules_017$__state__` | PACKAGE_STATE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 289 | `pkg_gen_rules_017$applies_to` | FUNCTION | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 290 | `pkg_gen_rules_017$evaluate` | FUNCTION | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 291 | `pkg_gen_rules_017$apply_batch` | PROCEDURE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 292 | `PKG_RECEIVING` | PACKAGE_BODY | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 293 | `pkg_receiving$__state__` | PACKAGE_STATE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 294 | `pkg_receiving$tolerance_pct` | FUNCTION | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 295 | `pkg_receiving$post_receipts` | PROCEDURE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 296 | `pkg_receiving$close_po_if_complete` | PROCEDURE | [`chunk-021`](chunks/chunk-021_report.md) | 0 |
| 297 | `SP_GEN_RULE_APPLY_005` | PROCEDURE | [`chunk-018`](chunks/chunk-018_report.md) | 0 |
| 298 | `SP_GEN_RULE_APPLY_006` | PROCEDURE | [`chunk-018`](chunks/chunk-018_report.md) | 0 |
| 299 | `SP_GEN_RULE_APPLY_007` | PROCEDURE | [`chunk-018`](chunks/chunk-018_report.md) | 0 |
| 300 | `SP_GEN_RULE_APPLY_009` | PROCEDURE | [`chunk-018`](chunks/chunk-018_report.md) | 0 |
| 301 | `SP_GEN_RULE_APPLY_010` | PROCEDURE | [`chunk-018`](chunks/chunk-018_report.md) | 0 |
| 302 | `SP_GEN_RULE_APPLY_011` | PROCEDURE | [`chunk-018`](chunks/chunk-018_report.md) | 0 |
| 303 | `SP_GEN_RULE_APPLY_013` | PROCEDURE | [`chunk-018`](chunks/chunk-018_report.md) | 0 |
| 304 | `SP_GEN_RULE_APPLY_014` | PROCEDURE | [`chunk-018`](chunks/chunk-018_report.md) | 0 |
| 305 | `SP_GEN_RULE_APPLY_015` | PROCEDURE | [`chunk-018`](chunks/chunk-018_report.md) | 0 |
| 306 | `SP_GEN_RULE_APPLY_017` | PROCEDURE | [`chunk-018`](chunks/chunk-018_report.md) | 0 |
| 307 | `SP_GEN_RULE_APPLY_018` | PROCEDURE | [`chunk-018`](chunks/chunk-018_report.md) | 0 |
| 308 | `SP_GEN_RULE_APPLY_019` | PROCEDURE | [`chunk-018`](chunks/chunk-018_report.md) | 0 |
| 309 | `TRG_AU_ORDER_PAYMENT` | TRIGGER | [`chunk-018`](chunks/chunk-018_report.md) | 0 |
| 310 | `MV_SALES_DAILY_STORE` | MATERIALIZED_VIEW | [`chunk-012`](chunks/chunk-012_report.md) | 1 |
| 311 | `SP_GEN_RULE_APPLY_026` | PROCEDURE | [`chunk-012`](chunks/chunk-012_report.md) | 0 |
| 312 | `SP_GEN_RULE_APPLY_027` | PROCEDURE | [`chunk-012`](chunks/chunk-012_report.md) | 0 |
| 313 | `SP_GEN_RULE_APPLY_029` | PROCEDURE | [`chunk-012`](chunks/chunk-012_report.md) | 0 |
| 314 | `SP_GEN_RULE_APPLY_030` | PROCEDURE | [`chunk-012`](chunks/chunk-012_report.md) | 0 |
| 315 | `SP_PURGE_AUDIT_LOG` | PROCEDURE | [`chunk-012`](chunks/chunk-012_report.md) | 0 |
| 316 | `SP_REBUILD_CATEGORY_PATHS` | PROCEDURE | [`chunk-012`](chunks/chunk-012_report.md) | 0 |
| 317 | `TRG_GEN_AUD_001` | TRIGGER | [`chunk-012`](chunks/chunk-012_report.md) | 0 |
| 318 | `TRG_GEN_AUD_008` | TRIGGER | [`chunk-012`](chunks/chunk-012_report.md) | 0 |
| 319 | `PKG_GEN_RULES_016` | PACKAGE_BODY | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 320 | `pkg_gen_rules_016$__state__` | PACKAGE_STATE | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 321 | `pkg_gen_rules_016$applies_to` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 322 | `pkg_gen_rules_016$describe` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 2 |
| 323 | `pkg_gen_rules_016$describe` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 324 | `pkg_gen_rules_016$describe` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 325 | `pkg_gen_rules_016$describe` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 1 |
| 326 | `pkg_gen_rules_016$evaluate` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 327 | `pkg_gen_rules_016$apply_batch` | PROCEDURE | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 328 | `PKG_GEN_RULES_020` | PACKAGE_BODY | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 329 | `pkg_gen_rules_020$__state__` | PACKAGE_STATE | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 330 | `pkg_gen_rules_020$applies_to` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 331 | `pkg_gen_rules_020$describe` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 332 | `pkg_gen_rules_020$describe` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 1 |
| 333 | `pkg_gen_rules_020$describe` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 334 | `pkg_gen_rules_020$describe` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 335 | `pkg_gen_rules_020$evaluate` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 336 | `pkg_gen_rules_020$apply_batch` | PROCEDURE | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 337 | `PKG_GEN_RULES_036` | PACKAGE_BODY | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 338 | `pkg_gen_rules_036$__state__` | PACKAGE_STATE | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 339 | `pkg_gen_rules_036$applies_to` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 340 | `pkg_gen_rules_036$describe` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 341 | `pkg_gen_rules_036$describe` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 2 |
| 342 | `pkg_gen_rules_036$describe` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 343 | `pkg_gen_rules_036$describe` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 344 | `pkg_gen_rules_036$evaluate` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 345 | `pkg_gen_rules_036$apply_batch` | PROCEDURE | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 346 | `PKG_GEN_RULES_040` | PACKAGE_BODY | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 347 | `pkg_gen_rules_040$__state__` | PACKAGE_STATE | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 348 | `pkg_gen_rules_040$applies_to` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 349 | `pkg_gen_rules_040$describe` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 350 | `pkg_gen_rules_040$describe` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 351 | `pkg_gen_rules_040$describe` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 352 | `pkg_gen_rules_040$describe` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 353 | `pkg_gen_rules_040$evaluate` | FUNCTION | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 354 | `pkg_gen_rules_040$apply_batch` | PROCEDURE | [`chunk-029`](chunks/chunk-029_report.md) | 0 |
| 355 | `PKG_GEN_RULES_003` | PACKAGE_BODY | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 356 | `pkg_gen_rules_003$__state__` | PACKAGE_STATE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 357 | `pkg_gen_rules_003$applies_to` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 358 | `pkg_gen_rules_003$evaluate` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 359 | `pkg_gen_rules_003$apply_batch` | PROCEDURE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 360 | `PKG_GEN_RULES_010` | PACKAGE_BODY | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 361 | `pkg_gen_rules_010$__state__` | PACKAGE_STATE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 362 | `pkg_gen_rules_010$applies_to` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 363 | `pkg_gen_rules_010$evaluate` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 364 | `pkg_gen_rules_010$apply_batch` | PROCEDURE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 365 | `PKG_GEN_RULES_013` | PACKAGE_BODY | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 366 | `pkg_gen_rules_013$__state__` | PACKAGE_STATE | [`chunk-020`](chunks/chunk-020_report.md) | 1 |
| 367 | `pkg_gen_rules_013$applies_to` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 368 | `pkg_gen_rules_013$evaluate` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 369 | `pkg_gen_rules_013$apply_batch` | PROCEDURE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 370 | `PKG_GEN_RULES_015` | PACKAGE_BODY | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 371 | `pkg_gen_rules_015$__state__` | PACKAGE_STATE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 372 | `pkg_gen_rules_015$applies_to` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 373 | `pkg_gen_rules_015$evaluate` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 374 | `pkg_gen_rules_015$apply_batch` | PROCEDURE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 375 | `PKG_GEN_RULES_018` | PACKAGE_BODY | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 376 | `pkg_gen_rules_018$__state__` | PACKAGE_STATE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 377 | `pkg_gen_rules_018$applies_to` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 378 | `pkg_gen_rules_018$evaluate` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 379 | `pkg_gen_rules_018$apply_batch` | PROCEDURE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 380 | `PKG_GEN_RULES_023` | PACKAGE_BODY | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 381 | `pkg_gen_rules_023$__state__` | PACKAGE_STATE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 382 | `pkg_gen_rules_023$applies_to` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 383 | `pkg_gen_rules_023$evaluate` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 384 | `pkg_gen_rules_023$apply_batch` | PROCEDURE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 385 | `PKG_GEN_RULES_025` | PACKAGE_BODY | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 386 | `pkg_gen_rules_025$__state__` | PACKAGE_STATE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 387 | `pkg_gen_rules_025$applies_to` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 388 | `pkg_gen_rules_025$evaluate` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 389 | `pkg_gen_rules_025$apply_batch` | PROCEDURE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 390 | `PKG_GEN_RULES_030` | PACKAGE_BODY | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 391 | `pkg_gen_rules_030$__state__` | PACKAGE_STATE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 392 | `pkg_gen_rules_030$applies_to` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 393 | `pkg_gen_rules_030$evaluate` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 394 | `pkg_gen_rules_030$apply_batch` | PROCEDURE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 395 | `PKG_GEN_RULES_033` | PACKAGE_BODY | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 396 | `pkg_gen_rules_033$__state__` | PACKAGE_STATE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 397 | `pkg_gen_rules_033$applies_to` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 398 | `pkg_gen_rules_033$evaluate` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 399 | `pkg_gen_rules_033$apply_batch` | PROCEDURE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 400 | `PKG_GEN_RULES_035` | PACKAGE_BODY | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 401 | `pkg_gen_rules_035$__state__` | PACKAGE_STATE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 402 | `pkg_gen_rules_035$applies_to` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 403 | `pkg_gen_rules_035$evaluate` | FUNCTION | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 404 | `pkg_gen_rules_035$apply_batch` | PROCEDURE | [`chunk-020`](chunks/chunk-020_report.md) | 0 |
| 405 | `PKG_GEN_RULES_001` | PACKAGE_BODY | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 406 | `pkg_gen_rules_001$__state__` | PACKAGE_STATE | [`chunk-019`](chunks/chunk-019_report.md) | 1 |
| 407 | `pkg_gen_rules_001$applies_to` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 408 | `pkg_gen_rules_001$evaluate` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 409 | `pkg_gen_rules_001$apply_batch` | PROCEDURE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 410 | `PKG_GEN_RULES_005` | PACKAGE_BODY | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 411 | `pkg_gen_rules_005$__state__` | PACKAGE_STATE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 412 | `pkg_gen_rules_005$applies_to` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 413 | `pkg_gen_rules_005$evaluate` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 414 | `pkg_gen_rules_005$apply_batch` | PROCEDURE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 415 | `PKG_GEN_RULES_006` | PACKAGE_BODY | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 416 | `pkg_gen_rules_006$__state__` | PACKAGE_STATE | [`chunk-019`](chunks/chunk-019_report.md) | 1 |
| 417 | `pkg_gen_rules_006$applies_to` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 418 | `pkg_gen_rules_006$evaluate` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 419 | `pkg_gen_rules_006$apply_batch` | PROCEDURE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 420 | `PKG_GEN_RULES_011` | PACKAGE_BODY | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 421 | `pkg_gen_rules_011$__state__` | PACKAGE_STATE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 422 | `pkg_gen_rules_011$applies_to` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 423 | `pkg_gen_rules_011$evaluate` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 424 | `pkg_gen_rules_011$apply_batch` | PROCEDURE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 425 | `PKG_GEN_RULES_021` | PACKAGE_BODY | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 426 | `pkg_gen_rules_021$__state__` | PACKAGE_STATE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 427 | `pkg_gen_rules_021$applies_to` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 428 | `pkg_gen_rules_021$evaluate` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 429 | `pkg_gen_rules_021$apply_batch` | PROCEDURE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 430 | `PKG_GEN_RULES_022` | PACKAGE_BODY | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 431 | `pkg_gen_rules_022$__state__` | PACKAGE_STATE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 432 | `pkg_gen_rules_022$applies_to` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 433 | `pkg_gen_rules_022$evaluate` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 434 | `pkg_gen_rules_022$apply_batch` | PROCEDURE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 435 | `PKG_GEN_RULES_026` | PACKAGE_BODY | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 436 | `pkg_gen_rules_026$__state__` | PACKAGE_STATE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 437 | `pkg_gen_rules_026$applies_to` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 438 | `pkg_gen_rules_026$evaluate` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 439 | `pkg_gen_rules_026$apply_batch` | PROCEDURE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 440 | `PKG_GEN_RULES_027` | PACKAGE_BODY | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 441 | `pkg_gen_rules_027$__state__` | PACKAGE_STATE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 442 | `pkg_gen_rules_027$applies_to` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 443 | `pkg_gen_rules_027$evaluate` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 444 | `pkg_gen_rules_027$apply_batch` | PROCEDURE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 445 | `PKG_GEN_RULES_031` | PACKAGE_BODY | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 446 | `pkg_gen_rules_031$__state__` | PACKAGE_STATE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 447 | `pkg_gen_rules_031$applies_to` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 448 | `pkg_gen_rules_031$evaluate` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 449 | `pkg_gen_rules_031$apply_batch` | PROCEDURE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 450 | `PKG_GEN_RULES_037` | PACKAGE_BODY | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 451 | `pkg_gen_rules_037$__state__` | PACKAGE_STATE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 452 | `pkg_gen_rules_037$applies_to` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 453 | `pkg_gen_rules_037$evaluate` | FUNCTION | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 454 | `pkg_gen_rules_037$apply_batch` | PROCEDURE | [`chunk-019`](chunks/chunk-019_report.md) | 0 |
| 455 | `SYN_GEN_PKG_098` | SYNONYM | [`chunk-035`](chunks/chunk-035_report.md) | 0 |
| 456 | `SYN_GEN_PKG_104` | SYNONYM | [`chunk-035`](chunks/chunk-035_report.md) | 0 |
| 457 | `SYN_GEN_PKG_110` | SYNONYM | [`chunk-035`](chunks/chunk-035_report.md) | 0 |
| 458 | `SYN_GEN_PKG_116` | SYNONYM | [`chunk-035`](chunks/chunk-035_report.md) | 0 |
| 459 | `SYN_GEN_PKG_122` | SYNONYM | [`chunk-035`](chunks/chunk-035_report.md) | 0 |
| 460 | `SYN_GEN_PKG_128` | SYNONYM | [`chunk-035`](chunks/chunk-035_report.md) | 0 |
| 461 | `SYN_GEN_PKG_134` | SYNONYM | [`chunk-035`](chunks/chunk-035_report.md) | 0 |
| 462 | `SYN_GEN_PKG_140` | SYNONYM | [`chunk-035`](chunks/chunk-035_report.md) | 0 |
| 463 | `SYN_GEN_PKG_146` | SYNONYM | [`chunk-035`](chunks/chunk-035_report.md) | 0 |
| 464 | `SYN_STORES` | SYNONYM | [`chunk-038`](chunks/chunk-038_report.md) | 1 |
| 465 | `IX_MOVE_VARIANT_LOCAL` | INDEX | [`chunk-043`](chunks/chunk-043_report.md) | 2 |
| 466 | `SYN_GEN_VIE_105` | SYNONYM | [`chunk-037`](chunks/chunk-037_report.md) | 1 |
| 467 | `V_GEN_IFC_EXT_001` | VIEW | [`chunk-045`](chunks/chunk-045_report.md) | 3 |
| 468 | `V_GEN_IFC_EXT_003` | VIEW | [`chunk-045`](chunks/chunk-045_report.md) | 3 |
| 469 | `FBI_PRODUCT_STATUS_RANK` | INDEX | [`chunk-042`](chunks/chunk-042_report.md) | 1 |
| 470 | `TRG_GEN_IO_001` | TRIGGER | [`chunk-042`](chunks/chunk-042_report.md) | 0 |
| 471 | `TRG_GEN_IO_002` | TRIGGER | [`chunk-042`](chunks/chunk-042_report.md) | 1 |
| 472 | `TRG_GEN_IO_003` | TRIGGER | [`chunk-042`](chunks/chunk-042_report.md) | 1 |
| 473 | `TRG_GEN_IO_004` | TRIGGER | [`chunk-042`](chunks/chunk-042_report.md) | 1 |
| 474 | `TRG_BU_STORE_AREA` | TRIGGER | [`chunk-046`](chunks/chunk-046_report.md) | 0 |
| 475 | `TRG_AS_SALES_ORDER_LINE_STMT` | TRIGGER | [`chunk-050`](chunks/chunk-050_report.md) | 0 |
| 476 | `V_GEN_ARCWIN_001` | VIEW | [`chunk-040`](chunks/chunk-040_report.md) | 1 |
| 477 | `V_GEN_ARCWIN_002` | VIEW | [`chunk-040`](chunks/chunk-040_report.md) | 3 |
| 478 | `V_GEN_ARCWIN_003` | VIEW | [`chunk-040`](chunks/chunk-040_report.md) | 3 |
| 479 | `V_GEN_SALES_REG_013` | VIEW | [`chunk-040`](chunks/chunk-040_report.md) | 3 |
| 480 | `V_GEN_SALES_REG_016` | VIEW | [`chunk-040`](chunks/chunk-040_report.md) | 1 |
| 481 | `V_GEN_SALES_REG_019` | VIEW | [`chunk-040`](chunks/chunk-040_report.md) | 3 |
| 482 | `V_GEN_SALES_REG_022` | VIEW | [`chunk-040`](chunks/chunk-040_report.md) | 3 |
| 483 | `V_GEN_SALES_REG_025` | VIEW | [`chunk-040`](chunks/chunk-040_report.md) | 3 |
| 484 | `V_GEN_KPI_007` | VIEW | [`chunk-044`](chunks/chunk-044_report.md) | 3 |
| 485 | `V_GEN_KPI_019` | VIEW | [`chunk-044`](chunks/chunk-044_report.md) | 3 |
| 486 | `V_GEN_KPI_023` | VIEW | [`chunk-044`](chunks/chunk-044_report.md) | 3 |
| 487 | `V_GEN_KPI_027` | VIEW | [`chunk-044`](chunks/chunk-044_report.md) | 3 |
| 488 | `V_GEN_SALES_REG_001` | VIEW | [`chunk-044`](chunks/chunk-044_report.md) | 3 |
| 489 | `V_GEN_SALES_REG_004` | VIEW | [`chunk-044`](chunks/chunk-044_report.md) | 1 |
| 490 | `V_GEN_SALES_REG_007` | VIEW | [`chunk-044`](chunks/chunk-044_report.md) | 1 |
| 491 | `V_GEN_SALES_REG_010` | VIEW | [`chunk-044`](chunks/chunk-044_report.md) | 3 |
| 492 | `V_SALES_CHANNEL_PIVOT` | VIEW | [`chunk-044`](chunks/chunk-044_report.md) | 1 |
| 493 | `SYN_GEN_VIE_003` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | 0 |
| 494 | `SYN_GEN_VIE_021` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | 0 |
| 495 | `SYN_GEN_VIE_129` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | 0 |
| 496 | `SYN_GEN_VIE_147` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | 0 |
| 497 | `IX_MV_SALES_DAILY_STORE` | INDEX | [`chunk-053`](chunks/chunk-053_report.md) | 1 |
| 498 | `V_GEN_CTRY_TAX_013` | VIEW | [`chunk-052`](chunks/chunk-052_report.md) | 3 |
| 499 | `V_GEN_CTRY_TAX_016` | VIEW | [`chunk-052`](chunks/chunk-052_report.md) | 5 |
| 500 | `V_GEN_CTRY_TAX_017` | VIEW | [`chunk-052`](chunks/chunk-052_report.md) | 1 |
| 501 | `V_GEN_CTRY_TAX_022` | VIEW | [`chunk-052`](chunks/chunk-052_report.md) | 3 |
| 502 | `V_CUSTOMER_LOYALTY_SUMMARY` | VIEW | [`chunk-054`](chunks/chunk-054_report.md) | 1 |
| 503 | `V_GEN_CTRY_TAX_004` | VIEW | [`chunk-054`](chunks/chunk-054_report.md) | 3 |
| 504 | `V_GEN_CTRY_TAX_010` | VIEW | [`chunk-054`](chunks/chunk-054_report.md) | 3 |
| 505 | `V_PRODUCT_PRICE_RANK` | VIEW | [`chunk-054`](chunks/chunk-054_report.md) | 3 |
| 506 | `V_PRODUCT_SELLABLE` | VIEW | [`chunk-054`](chunks/chunk-054_report.md) | 3 |
| 507 | `MV_SALES_MONTHLY_CATEGORY` | MATERIALIZED_VIEW | [`chunk-054`](chunks/chunk-054_report.md) | 3 |
| 508 | `IX_MV_SALES_MONTHLY_CAT` | INDEX | [`chunk-055`](chunks/chunk-055_report.md) | 1 |
| 509 | `SYN_GEN_VIE_033` | SYNONYM | [`chunk-055`](chunks/chunk-055_report.md) | 1 |
| 510 | `SYN_GEN_VIE_063` | SYNONYM | [`chunk-055`](chunks/chunk-055_report.md) | 0 |
| 511 | `SYN_SELLABLE` | SYNONYM | [`chunk-055`](chunks/chunk-055_report.md) | 0 |
| 512 | `TRG_IO_PRODUCT_SELLABLE` | TRIGGER | [`chunk-055`](chunks/chunk-055_report.md) | 1 |

</details>

---

### 4. Skipped source objects — 53 object(s) · 🟡 low severity

> _Why this happened_ — These objects were intentionally excluded by scope or unsupported-source-feature handling.
>
> _What it means_ — No PostgreSQL DDL was generated, so an equivalent workaround or explicit acceptance is required.
>
> _How to resolve right now_ ⏱️ **~5-15 min per object**
> 1. Review the skip reason in the chunk report.
> 2. Decide whether the object is in production cutover scope.
> 3. Create a manual PostgreSQL equivalent when needed.

<details><summary>📋 Affected objects (53)</summary>

| # | Object | Type | Chunk | Reason |
|--:|---|---|---|---|
| 1 | `SYN_GEN_FUN_052` | SYNONYM | [`chunk-006`](chunks/chunk-006_report.md) | Oracle synonym onto a FUNCTION (CONTOSO.FUNCTION.FN_GEN_CHK_IMPURE_033) has no … |
| 2 | `SYN_GEN_FUN_004` | SYNONYM | [`chunk-006`](chunks/chunk-006_report.md) | Oracle synonym onto a FUNCTION (CONTOSO.FUNCTION.FN_GEN_VALID_AMOUNT_001) has n… |
| 3 | `SYN_GEN_FUN_034` | SYNONYM | [`chunk-006`](chunks/chunk-006_report.md) | Oracle synonym onto a FUNCTION (CONTOSO.FUNCTION.FN_GEN_VALID_AMOUNT_021) has n… |
| 4 | `SYN_GEN_FUN_022` | SYNONYM | [`chunk-006`](chunks/chunk-006_report.md) | Oracle synonym onto a FUNCTION (CONTOSO.FUNCTION.FN_GEN_VALID_PCT_013) has no P… |
| 5 | `V_GEN_LEGACY_004` | VIEW | [`chunk-010`](chunks/chunk-010_report.md) | Duplicate of CONTOSO.VIEW.V_GEN_LEGACY_001; merged to avoid redundant identical… |
| 6 | `V_GEN_LEGACY_006` | VIEW | [`chunk-010`](chunks/chunk-010_report.md) | Duplicate of CONTOSO.VIEW.V_GEN_LEGACY_003; merged to avoid redundant identical… |
| 7 | `V_GEN_LEGACY_007` | VIEW | [`chunk-010`](chunks/chunk-010_report.md) | Duplicate of CONTOSO.VIEW.V_GEN_LEGACY_001; merged to avoid redundant identical… |
| 8 | `V_GEN_LEGACY_009` | VIEW | [`chunk-010`](chunks/chunk-010_report.md) | Duplicate of CONTOSO.VIEW.V_GEN_LEGACY_003; merged to avoid redundant identical… |
| 9 | `V_GEN_LEGACY_010` | VIEW | [`chunk-010`](chunks/chunk-010_report.md) | Duplicate of CONTOSO.VIEW.V_GEN_LEGACY_001; merged to avoid redundant identical… |
| 10 | `V_GEN_LEGACY_012` | VIEW | [`chunk-010`](chunks/chunk-010_report.md) | Duplicate of CONTOSO.VIEW.V_GEN_LEGACY_003; merged to avoid redundant identical… |
| 11 | `V_GEN_LEGACY_013` | VIEW | [`chunk-010`](chunks/chunk-010_report.md) | Duplicate of CONTOSO.VIEW.V_GEN_LEGACY_001; merged to avoid redundant identical… |
| 12 | `V_GEN_LEGACY_015` | VIEW | [`chunk-010`](chunks/chunk-010_report.md) | Duplicate of CONTOSO.VIEW.V_GEN_LEGACY_003; merged to avoid redundant identical… |
| 13 | `V_GEN_LEGACY_016` | VIEW | [`chunk-010`](chunks/chunk-010_report.md) | Duplicate of CONTOSO.VIEW.V_GEN_LEGACY_001; merged to avoid redundant identical… |
| 14 | `V_GEN_LEGACY_018` | VIEW | [`chunk-010`](chunks/chunk-010_report.md) | Duplicate of CONTOSO.VIEW.V_GEN_LEGACY_003; merged to avoid redundant identical… |
| 15 | `V_GEN_LEGACY_019` | VIEW | [`chunk-010`](chunks/chunk-010_report.md) | Duplicate of CONTOSO.VIEW.V_GEN_LEGACY_001; merged to avoid redundant identical… |
| 16 | `V_GEN_LEGACY_021` | VIEW | [`chunk-010`](chunks/chunk-010_report.md) | Duplicate of CONTOSO.VIEW.V_GEN_LEGACY_003; merged to avoid redundant identical… |
| 17 | `pkg_loyalty$active_benefits` | FUNCTION | [`chunk-015`](chunks/chunk-015_report.md) | Cannot safely convert: depends on Oracle nested table type t_benefit_tab of obj… |
| 18 | `pkg_order_mgmt$validate_basket` | PROCEDURE | [`chunk-028`](chunks/chunk-028_report.md) | Source for validate_basket is incomplete (only declarative section and start of… |
| 19 | `SYN_ORDER_CAPTURE` | SYNONYM | [`chunk-038`](chunks/chunk-038_report.md) | Oracle synonym targets a PACKAGE (PKG_ORDER_CAPTURE). PostgreSQL has no package… |
| 20 | `SYN_GEN_FUN_040` | SYNONYM | [`chunk-038`](chunks/chunk-038_report.md) | Oracle synonym onto a FUNCTION (CONTOSO.FUNCTION.FN_GEN_VALID_EAN13_025) has no… |
| 21 | `SYN_LOYALTY_API` | SYNONYM | [`chunk-037`](chunks/chunk-037_report.md) | Oracle synonym onto a PACKAGE (CONTOSO.PACKAGE.PKG_LOYALTY) has no PostgreSQL a… |
| 22 | `SYN_GEN_PRO_023` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_REG_REFRESH_013) has … |
| 23 | `SYN_GEN_PRO_029` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_REG_REFRESH_017) has … |
| 24 | `SYN_GEN_PRO_035` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_REG_REFRESH_021) has … |
| 25 | `SYN_GEN_PRO_041` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_REG_REFRESH_025) has … |
| 26 | `SYN_GEN_PRO_047` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_RULE_APPLY_004) has n… |
| 27 | `SYN_GEN_PRO_053` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_RULE_APPLY_008) has n… |
| 28 | `SYN_GEN_PRO_059` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_RULE_APPLY_012) has n… |
| 29 | `SYN_GEN_PRO_065` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_RULE_APPLY_016) has n… |
| 30 | `SYN_GEN_PRO_071` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_RULE_APPLY_020) has n… |
| 31 | `SYN_GEN_PRO_077` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_RULE_APPLY_024) has n… |
| 32 | `SYN_GEN_PRO_083` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_RULE_APPLY_028) has n… |
| 33 | `SYN_GEN_PRO_119` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_IFC_DISP_004) has no … |
| 34 | `SYN_GEN_PRO_125` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_IFC_DISP_008) has no … |
| 35 | `SYN_GEN_PRO_131` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_IFC_DISP_012) has no … |
| 36 | `SYN_GEN_PRO_137` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_ARC_PURGE_001) has no… |
| 37 | `SYN_GEN_PRO_143` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_ARC_PURGE_005) has no… |
| 38 | `SYN_GEN_PRO_149` | SYNONYM | [`chunk-051`](chunks/chunk-051_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_ARC_PURGE_009) has no… |
| 39 | `SYN_GEN_FUN_058` | SYNONYM | [`chunk-053`](chunks/chunk-053_report.md) | Oracle synonym onto a FUNCTION (CONTOSO.FUNCTION.FN_GEN_CHK_IMPURE_037) has no … |
| 40 | `SYN_GEN_FUN_136` | SYNONYM | [`chunk-053`](chunks/chunk-053_report.md) | Oracle synonym onto a FUNCTION (CONTOSO.FUNCTION.FN_GEN_PRICE_009_BE) has no Po… |
| 41 | `SYN_GEN_PRO_005` | SYNONYM | [`chunk-053`](chunks/chunk-053_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_REG_REFRESH_001) has … |
| 42 | `SYN_GEN_PRO_011` | SYNONYM | [`chunk-053`](chunks/chunk-053_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_REG_REFRESH_005) has … |
| 43 | `SYN_GEN_PRO_017` | SYNONYM | [`chunk-053`](chunks/chunk-053_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_REG_REFRESH_009) has … |
| 44 | `SYN_REPORTING` | SYNONYM | [`chunk-049`](chunks/chunk-049_report.md) | Oracle synonym onto a PACKAGE (CONTOSO.PACKAGE.PKG_REPORTING) has no PostgreSQL… |
| 45 | `SYN_GEN_FUN_010` | SYNONYM | [`chunk-049`](chunks/chunk-049_report.md) | Oracle synonym onto a FUNCTION (CONTOSO.FUNCTION.FN_GEN_VALID_EAN13_005) has no… |
| 46 | `SYN_GEN_FUN_016` | SYNONYM | [`chunk-049`](chunks/chunk-049_report.md) | Oracle synonym onto a FUNCTION (CONTOSO.FUNCTION.FN_GEN_VALID_TEXT_009) has no … |
| 47 | `SYN_GEN_PRO_089` | SYNONYM | [`chunk-055`](chunks/chunk-055_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_CAT_STAGE_002) has no… |
| 48 | `SYN_GEN_PRO_095` | SYNONYM | [`chunk-055`](chunks/chunk-055_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_CAT_STAGE_006) has no… |
| 49 | `SYN_GEN_PRO_101` | SYNONYM | [`chunk-055`](chunks/chunk-055_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_CAT_STAGE_010) has no… |
| 50 | `SYN_GEN_PRO_107` | SYNONYM | [`chunk-055`](chunks/chunk-055_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_CAT_STAGE_014) has no… |
| 51 | `SYN_GEN_PRO_113` | SYNONYM | [`chunk-055`](chunks/chunk-055_report.md) | Oracle synonym onto a PROCEDURE (CONTOSO.PROCEDURE.SP_GEN_CAT_STAGE_018) has no… |
| 52 | `SYN_GEN_FUN_028` | SYNONYM | [`chunk-055`](chunks/chunk-055_report.md) | Oracle synonym onto a FUNCTION (CONTOSO.FUNCTION.FN_GEN_VALID_ENUM_017) has no … |
| 53 | `SYN_GEN_FUN_046` | SYNONYM | [`chunk-055`](chunks/chunk-055_report.md) | Oracle synonym onto a FUNCTION (CONTOSO.FUNCTION.FN_GEN_VALID_TEXT_029) has no … |

</details>

---

### 5. PostgreSQL extensions — 27 object(s) · 🟡 low severity

> _Why this happened_ — Converted DDL references PostgreSQL extension-provided features.
>
> _What it means_ — The target database must have these extensions installed or allowlisted before applying the converted DDL.
>
> _How to resolve right now_ ⏱️ **~5 min before deploy**
> 1. Collect the extension names from the affected objects below.
> 2. Run the corresponding `CREATE EXTENSION IF NOT EXISTS` commands.
> 3. Re-run compile validation after extension installation.

<details><summary>📋 Affected objects (27)</summary>

| # | Object | Type | Chunk | Extension |
|--:|---|---|---|---|
| 1 | `FN_GEN_TAX_011_AT` | FUNCTION | [`chunk-004`](chunks/chunk-004_report.md) | `orafce` |
| 2 | `FN_GEN_TAX_017_IS` | FUNCTION | [`chunk-004`](chunks/chunk-004_report.md) | `orafce` |
| 3 | `FN_GEN_TAX_023_BG` | FUNCTION | [`chunk-004`](chunks/chunk-004_report.md) | `orafce` |
| 4 | `FN_GEN_TAX_029_LT` | FUNCTION | [`chunk-004`](chunks/chunk-004_report.md) | `orafce` |
| 5 | `FN_GEN_TAX_035_CL` | FUNCTION | [`chunk-004`](chunks/chunk-004_report.md) | `orafce` |
| 6 | `FN_GEN_TAX_005_ES` | FUNCTION | [`chunk-003`](chunks/chunk-003_report.md) | `orafce` |
| 7 | `SP_RECALC_INVENTORY_SNAPSHOT` | PROCEDURE | [`chunk-010`](chunks/chunk-010_report.md) | `orafce` |
| 8 | `SP_REFRESH_REPORTING_LAYER` | PROCEDURE | [`chunk-010`](chunks/chunk-010_report.md) | `orafce` |
| 9 | `TRG_AD_COUPON_AUDIT` | TRIGGER | [`chunk-017`](chunks/chunk-017_report.md) | `dblink` |
| 10 | `pkg_finance_gl$post_control_total` | PROCEDURE | [`chunk-031`](chunks/chunk-031_report.md) | `dblink` |
| 11 | `pkg_reporting$print_top_stores` | PROCEDURE | [`chunk-031`](chunks/chunk-031_report.md) | `orafce` |
| 12 | `pkg_inventory$bulk_apply` | PROCEDURE | [`chunk-016`](chunks/chunk-016_report.md) | `orafce` |
| 13 | `SP_CLOSE_GL_PERIOD` | PROCEDURE | [`chunk-016`](chunks/chunk-016_report.md) | `orafce` |
| 14 | `pkg_loyalty$expire_points` | PROCEDURE | [`chunk-015`](chunks/chunk-015_report.md) | `orafce` |
| 15 | `pkg_pricing$reset_cache` | PROCEDURE | [`chunk-015`](chunks/chunk-015_report.md) | `orafce` |
| 16 | `MV_CUSTOMER_RFM` | MATERIALIZED_VIEW | [`chunk-015`](chunks/chunk-015_report.md) | `pg_cron` |
| 17 | `MV_SUPPLIER_PERFORMANCE` | MATERIALIZED_VIEW | [`chunk-015`](chunks/chunk-015_report.md) | `pg_cron` |
| 18 | `SP_POST_SALES_JOURNAL` | PROCEDURE | [`chunk-015`](chunks/chunk-015_report.md) | `orafce` |
| 19 | `TRG_CMP_INVENTORY_STOCK` | TRIGGER | [`chunk-015`](chunks/chunk-015_report.md) | `orafce` |
| 20 | `pkg_error$log_error` | PROCEDURE | [`chunk-011`](chunks/chunk-011_report.md) | `dblink` |
| 21 | `pkg_purchasing$rebuild_index` | PROCEDURE | [`chunk-028`](chunks/chunk-028_report.md) | `orafce` |
| 22 | `MV_STOCK_POSITION` | MATERIALIZED_VIEW | [`chunk-012`](chunks/chunk-012_report.md) | `pg_cron` |
| 23 | `SP_EXPIRE_PROMOTIONS` | PROCEDURE | [`chunk-012`](chunks/chunk-012_report.md) | `orafce` |
| 24 | `SP_REINDEX_SEARCH_KEYS` | PROCEDURE | [`chunk-038`](chunks/chunk-038_report.md) | `orafce` |
| 25 | `TRG_BIUS_GL_PERIOD` | TRIGGER | [`chunk-044`](chunks/chunk-044_report.md) | `orafce` |
| 26 | `SP_APPLY_PRICE_CHANGE_BATCH` | PROCEDURE | [`chunk-054`](chunks/chunk-054_report.md) | `orafce` |
| 27 | `SP_SEED_DEMO_DATA` | PROCEDURE | [`chunk-054`](chunks/chunk-054_report.md) | `orafce` |

</details>

## 🚀 Deploy Preparation

| Assembler mode | Generation ID | Plan hash | Coverage trusted |
|---|---|---|---|
| compile-stream | `c38e5907a6d84a688f15ba052c77db04` | `d0a3287c1c45da743a4c69c7203c6c348ef74cc7f9a7ee653365e098061c2a92` | ✅ Yes |

### Disposition Breakdown

| Disposition | Count |
|---|---:|
| Live (stream) | 964 |
| Live (sidecar) | 0 |
| Live with review | 0 |
| Gap — salvage | 32 |
| Gap — manual review | 664 |
| Non-emitting | 206 |
| Legacy unverified | 0 |

> These counts score the **deploy**, not the conversion, and they count every unit `deploy.sql` writes a marker for -- so a package contributes its members individually. That is a different, larger population than the conversion tables above, which count a package once and score only objects with a PostgreSQL target of their own. The two totals are meant to differ; neither is a correction of the other.

### Salvage Metrics

| Metric | Count |
|---|---:|
| Rematerialized (verified) | 0 |
| Salvage-compiled | 0 |
| Gap: no executable DDL | 0 |
| Gap: compile failed | 32 |
| Gap: dependency unresolved | 0 |
| Gap: infrastructure | 0 |
| Gap: budget exhausted | 0 |

## 📖 Glossary

Quick reference for the terminology used throughout this report.

| Term | Definition |
|---|---|
| **Chunk** | A dependency-aware batch of source objects the converter processes together (typically related tables, sequences, packages, etc.). Chunking enables parallelism and keeps each LLM context focused. |
| **Programmable object** 🟪 | Source-code objects whose logic must be translated: `PROCEDURE`, `FUNCTION`, `PACKAGE`, `PACKAGE_BODY`, `TRIGGER`, `TYPE`, `VIEW` (with logic). Higher review effort because semantics matter, not just syntax. |
| **Non-Programmable object** 🟦 | Schema/structural objects with no procedural logic: `TABLE`, `INDEX`, `SEQUENCE`, `CONSTRAINT`, `REF_CONSTRAINT`, `SCHEMA`. Mostly mechanical translation; lower review effort. |
| **Extracted** | Source objects successfully discovered and pulled from Oracle. |
| **Converted** ✅ | The object was translated and compiled successfully against the target PostgreSQL instance, or its content was folded into another object that was. Safe to deploy as-is; test it against your data. |
| **Not-Converted** 🔴 | Something is still owed on this object: it may be absent from the deployment script, only partly there, or present as best-effort code nobody has checked. The error message beside it says which. |
| **Error message** | A plain-language explanation and next action, followed by `Reference: CVT-NNN`. The reference is stable and greppable; the full list is in `docs/status_state_nomenclature/error_code_vocabulary.md`. |
| **Fix loop** | Internal retry mechanism: when initial DDL fails to compile, the converter sends the error back to the LLM with the broken DDL and asks for a corrected version. "Fix attempts = N" means N retry passes were used. |
| **REF_CONSTRAINT** | A foreign-key (referential) constraint. Common source of fallbacks because the parent table may live in a different chunk and not be loaded yet at compile time. |
| **Cross-chunk FK** | A foreign key whose parent table is in a different chunk than the child. Resolved by deferring the `ALTER TABLE … ADD CONSTRAINT` to a post-load phase. |
| **Hint** | A reusable conversion pattern (cause → fix) learned during a chunk and propagated to later chunks to reduce fix-loop attempts. |
| **deploy.sql** | The generated end-to-end deployment script. Run top-to-bottom against the target PostgreSQL instance to recreate the schema. |
| **Convert (LLM)** | Phase where the LLM translates source DDL into PostgreSQL-compatible DDL. |
| **Compile (PG)** | Phase where generated DDL is executed against a scratch PostgreSQL instance to validate it. Pure syntactic + structural check; no data is loaded. |
| **Review (LLM)** | Phase where a second LLM pass critiques the conversion for correctness and idiomatic style. |
| **Wallclock vs. CPU-time** | Wallclock = real elapsed time you waited. CPU-time = sum of all parallel work; on a 15-way run, CPU-time can be ~15× wallclock. |
| **Success rate** | `Converted / (Objects - folded)`. Objects that were folded into another object are excluded from the denominator because they have no PostgreSQL target of their own; everything else is either Converted or Not-Converted, and the two sum to the denominator. |
