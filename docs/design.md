# Contoso Store — Oracle to Azure Database for PostgreSQL migration lab

## Design contract

**Status:** authoritative. Every other agent and contributor reads this file before writing code.
If your work disagrees with this document, this document wins — raise a change here first.

**Last reviewed:** 2026-09-02

---

## 1. What this lab is for

Contoso Store is a fictional multi-country retail chain. This repo builds a deliberately
*awkward* Oracle schema for it — realistic enough to be believable as a twenty-year-old retail
ERP, and loaded with the specific Oracle constructs that do not have clean PostgreSQL analogues.

We then run it through the only currently supported Microsoft conversion path and study what
comes out.

That path is a feature of the **PostgreSQL extension for Visual Studio Code**
(extension ID `ms-ossdata.vscode-pgsql`, publisher Microsoft). There is no separate
"Oracle to PostgreSQL" extension and no product called "migration copilot". Schema conversion
went **GA in extension v1.23.0 (2026-05-26)**. Application/code conversion — `.sql`, `.ctl`,
`.sh`, `.load`, `.java` — is still **public preview**. Phrase it exactly that way in any doc
you write.

The point of the lab is *not* to prove the tool works. The point is to find the seams. A
converter that handled all 43 hard cases in section 9 cleanly would make a boring lab. We
expect a meaningful fraction to come back as flagged review tasks, and some to need genuine
human rewriting. Saying so honestly is the pedagogy.

### Success criteria

1. `CONTOSO` reaches **at least 1,000 objects** under the counting rule in section 8.
2. Every construct in section 9 exists somewhere in the schema and is exercised by seed data.
3. A conversion run produces a report we can diff against section 9's predictions.
4. The end-to-end story is honest about the gap the tool does not fill (section 10.4: it moves
   schema and code, not rows).

---

## 2. Naming and identity contract

These are fixed. Do not rename, do not "improve", do not parameterise.

| Thing | Value |
| --- | --- |
| Oracle PDB service name | `FREEPDB1` |
| Oracle schema being migrated | `CONTOSO` |
| Oracle admin user for setup | `SYSTEM` |
| Oracle low-privilege reader for the tool | `O2P_READER` |
| Target PostgreSQL database | `contoso_store` |
| Target PostgreSQL schema | `contoso` |
| Azure resource name prefix | `o2p` |

### Conventions

- **Shell:** bash, first line `#!/usr/bin/env bash`, second `set -euo pipefail`, executable bit
  set, must pass `bash -n`. POSIX-ish; no zsh-isms, no GNU-only flags without a macOS fallback.
- **File names:** kebab-case throughout. SQL files carry a two-digit ordinal and a dash:
  `01-types.sql`, `02-tables.sql`.
- **SQL identifiers:** lower-case in the source files, unquoted, so Oracle folds them to
  upper-case and PostgreSQL folds them to lower-case. One table is deliberately quoted and
  mixed-case to exercise the identifier-folding trap (section 10, trap T-07).
- **Passwords:** never in a committed file. Environment variables, or `az keyvault secret show`.
  `.env.example` documents every variable; `.env` is gitignored.
- **Public repo:** no real tenant IDs, subscription IDs, endpoints, or resource names anywhere.
- **Prefixes:** `pkg_` packages, `sp_` standalone procedures, `fn_` standalone functions,
  `trg_` triggers, `v_` views, `mv_` materialised views, `syn_` synonyms, `seq_` sequences,
  `t_` types, `gtt_` global temporary tables, `ix_`/`uq_`/`fbi_`/`bmp_` indexes,
  `pk_`/`fk_`/`ck_` constraints.
- **Generated objects** carry a `gen_` infix (`pkg_gen_rules_007`, `v_gen_sales_042`) so a
  single predicate separates hand-written from generated in any report.

---

## 3. Repository layout and file ownership

Create nothing outside your assigned list. Another agent owns the rest.

```
oracle-to-postgres-migration-lab/
├── README.md
├── LICENSE                       MIT, 2026 Contoso Store Migration Lab contributors
├── .gitignore
├── .env.example                  every variable the lab uses, placeholders + comments
├── docs/
│   ├── design.md                 THIS FILE — the contract
│   ├── 00-prerequisites.md       Azure, Foundry, Copilot, VS Code, network egress
│   ├── 01-deploy-infrastructure.md  deploy.sh, every resource, the extension allowlist
│   ├── 02-seed-oracle.md         standing up FREEPDB1 and loading CONTOSO
│   ├── 03-run-ai-migration.md    the extension walkthrough, GA vs preview scope, and
│   │                             working the flagged items with Copilot agent mode
│   ├── 04-migrate-data.md        the row-copy step the tool does NOT do
│   ├── 05-validate.md            differential testing, and observed vs predicted per section 9
│   ├── architecture.md           why the lab is shaped this way
│   └── troubleshooting.md        symptom -> cause -> fix, across every stage
├── src/oracle/
│   ├── 00-user-tablespace.sql    CONTOSO tablespace, user, grants, quota (runs as SYSTEM)
│   ├── 01-types.sql              object types, VARRAYs, nested tables, type bodies
│   ├── 02-tables.sql             the 45 core tables + operational and global temporary
│   │                             tables, incl. IOT / partitioned / virtual columns
│   ├── 03-constraints.sql        PK/UK/FK/CHECK applied after the tables exist
│   ├── 04-indexes.sql            secondary, function-based, bitmap, reverse-key
│   ├── 05-sequences.sql          incl. the NOCACHE and CYCLE ones
│   ├── 06-views.sql              incl. the INSTEAD OF trigger targets
│   ├── 07-packages.sql           25 package specs and 25 bodies
│   ├── 08-procedures.sql         standalone procedures and functions
│   ├── 09-triggers.sql           every timing, compound, INSTEAD OF
│   ├── 10-mviews.sql             MV logs, fast-refresh MVs, the refresh group
│   ├── 11-jobs-scheduler.sql     DBMS_SCHEDULER programs, schedules, jobs
│   ├── 12-security-context.sql   application context + VPD policies
│   ├── 13-synonyms-grants.sql    the synonym layer and the reporting role
│   └── 99-verify-objects.sql     the object count assertion, always run last
├── tools/
│   ├── generate-objects.py       deterministic generator, ~760 objects -> generated/oracle/
│   ├── generate-data.py          deterministic row data     -> generated/oracle/data/
│   └── ora2pg.conf               config template for the separate data step
├── scripts/                      bash drivers; see conventions above
├── infra/                        Bicep for the Azure side
├── tests/                        assertions run against Oracle, plus the static checks
├── generated/                    gitignored — generator output lands in generated/oracle/
│                                 and generated/oracle/data/; deployment outputs in
│                                 generated/outputs.json
└── out/                          gitignored — logs, converted DDL, reports
```

> **Naming note, recorded rather than hidden.** Earlier drafts of this contract specified `sql/`
> with a 00–15 numbering and a separate `seed/` directory. The repository uses `src/oracle/` with a
> 00–13 numbering and generates row data into `generated/oracle/data/`. The tree above is the
> current contract; `scripts/seed-oracle.sh` still accepts `sql/` and `seed/` as alternative
> locations so that a fork using the older layout keeps working.

---

## 4. Domain model

Contoso Store operates ~1,400 stores across 11 countries, three warehouses per country, a web
and app channel, a loyalty programme, and a single consolidated general ledger. The schema is
normalised to roughly third normal form, with the usual retail pragmatic denormalisations
(stored line totals, a stock snapshot table alongside the movement ledger).

Ten subject areas, 45 core tables:

| # | Subject area | Tables | Anchor entity |
| --- | --- | ---: | --- |
| A | Reference and geography | 6 | `country` |
| B | Party, employees, stores | 3 | `store` |
| C | Product catalogue | 4 | `product` |
| D | Supplier and procurement | 5 | `purchase_order` |
| E | Inventory | 4 | `inventory_stock` |
| F | Customer and loyalty | 5 | `customer` |
| G | Pricing and promotions | 5 | `price_list_item` |
| H | Orders and fulfilment | 6 | `sales_order` |
| I | Returns | 3 | `return_request` |
| J | Finance and general ledger | 4 | `gl_journal` |

Plus 5 operational/audit tables, 3 global temporary tables, 2 nested-table storage tables,
6 materialised view containers and 3 materialised view logs — 64 objects of type `TABLE` in
total (section 8).

### 4.1 Four hierarchies, on purpose

Four separate self-referencing trees exist so `CONNECT BY` shows up in four different shapes
and the converter cannot special-case one of them:

- `region.parent_region_id` — geography, 5 levels (`GLOBAL` → `AREA` → `COUNTRY` → `DISTRICT` → `CLUSTER`)
- `employee.manager_id` — reporting line, ragged depth, used with `LEVEL` and `CONNECT_BY_ROOT`
- `product_category.parent_category_id` — merchandise hierarchy, used with `SYS_CONNECT_BY_PATH`
- `gl_account.parent_account_code` — chart of accounts, used with `ORDER SIBLINGS BY` and a
  bottom-up roll-up

A fifth, `inventory_location.parent_location_id`, exists but is shallow (2 levels) and is only
walked by a recursive PL/SQL routine, not by `CONNECT BY` — deliberately, so the lab can compare
how the tool treats the SQL form versus the procedural form of the same idea.

### 4.2 Circular foreign keys

`region.manager_employee_id → employee` and `employee.store_id → store → region` form a cycle.
Oracle tolerates this because constraints live in `04-constraints.sql`, applied after all tables
exist. PostgreSQL tolerates it too, but the *ordering* of the generated DDL matters, and naive
converters emit it in dependency order and fail. This is a cheap, realistic trap and it stays.

---

## 5. Table catalogue

Column notation: `PK` primary key, `FK→x` foreign key, `UQ` unique, `NN` not null,
`VIRT` virtual column, `NT` nested table column, `VA` VARRAY column, `OBJ` object type column.
`TSLTZ` = `TIMESTAMP WITH LOCAL TIME ZONE`.

### A. Reference and geography (6 tables)

**`currency`** — ISO currency master.
`currency_code CHAR(3) PK` · `currency_name VARCHAR2(60) NN` · `minor_units NUMBER(1) DEFAULT 2 NN`
· `symbol VARCHAR2(5)` · `is_active CHAR(1) DEFAULT 'Y' CHECK IN ('Y','N')`

**`country`** — trading countries.
`country_code CHAR(2) PK` · `country_name VARCHAR2(80) NN UQ` · `iso3_code CHAR(3) NN UQ`
· `currency_code FK→currency NN` · `default_locale VARCHAR2(10)` · `vat_scheme VARCHAR2(20)`
· `tz_name VARCHAR2(64) NN` (IANA zone; pairs with every `TSLTZ` column in the schema)

**`exchange_rate`** — daily FX, composite key.
`rate_date DATE PK` · `from_currency FK→currency PK` · `to_currency FK→currency PK`
· `rate NUMBER(18,8) NN CHECK > 0` · `source_code VARCHAR2(20)`

**`region`** — self-referencing geography tree (hierarchy 1).
`region_id NUMBER(9) PK` · `region_code VARCHAR2(20) NN UQ` · `region_name VARCHAR2(100) NN`
· `country_code FK→country NN` · `parent_region_id FK→region` · `region_level VARCHAR2(20)`
· `manager_employee_id FK→employee` (half of the circular FK, see 4.2)

**`calendar_day`** — fiscal calendar. **`ORGANIZATION INDEX`** (index-organized table).
`day_date DATE PK` · `fiscal_year NUMBER(4) NN` · `fiscal_period NUMBER(2) NN`
· `fiscal_week NUMBER(2) NN` · `day_of_week NUMBER(1) NN` · `is_trading_day CHAR(1) DEFAULT 'Y'`
· `is_public_holiday CHAR(1) DEFAULT 'N'` · `season_code VARCHAR2(10)`

**`tax_rate`** — VAT rates with validity windows.
`tax_rate_id NUMBER(9) PK` · `country_code FK→country NN` · `tax_code VARCHAR2(20) NN`
· `rate_pct NUMBER(5,2) NN` · `valid_from DATE NN` · `valid_to DATE`
· `UQ (country_code, tax_code, valid_from)` · `CHECK (valid_to IS NULL OR valid_to > valid_from)`

### B. Party, employees, stores (3 tables)

**`address`** — shared address book for stores, warehouses, suppliers, customers.
`address_id NUMBER(12) PK` · `line1 VARCHAR2(120) NN` · `line2 VARCHAR2(120)`
· `city VARCHAR2(80) NN` · `state_province VARCHAR2(80)` · `postal_code VARCHAR2(20)`
· `country_code FK→country NN` · `latitude NUMBER(9,6)` · `longitude NUMBER(9,6)`
· `geo_json CLOB`
· `normalised_key VIRT GENERATED ALWAYS AS (UPPER(TRIM(line1))||'|'||UPPER(TRIM(city))||'|'||country_code)`
  — the dedupe key; carries a unique function-based index

**`employee`** — staff, self-referencing management line (hierarchy 2).
`employee_id NUMBER(9) PK` · `employee_number VARCHAR2(20) NN UQ` · `first_name VARCHAR2(60) NN`
· `last_name VARCHAR2(60) NN` · `full_name VIRT AS (first_name||' '||last_name)`
· `email VARCHAR2(150)` · `store_id FK→store` · `manager_id FK→employee`
· `job_title VARCHAR2(60) NN` · `hire_date DATE NN` · `termination_date DATE`
· `salary_amount NUMBER(12,2)` · `salary_currency FK→currency`
· `is_active VIRT AS (CASE WHEN termination_date IS NULL THEN 'Y' ELSE 'N' END)`

**`store`** — the store estate.
`store_id NUMBER(9) PK` · `store_code VARCHAR2(12) NN UQ` · `store_name VARCHAR2(120) NN`
· `region_id FK→region NN` · `address_id FK→address NN`
· `store_format VARCHAR2(20) CHECK IN ('HYPER','SUPER','EXPRESS','OUTLET','ONLINE')`
· `opened_date DATE NN` · `closed_date DATE` · `selling_area_sqm NUMBER(8,2)`
· `opening_offset INTERVAL DAY(0) TO SECOND(0)` · `closing_offset INTERVAL DAY(0) TO SECOND(0)`
  — trading hours as an offset from local midnight, so a 25-hour Sunday during a DST fold is
  representable
· `refit_cycle INTERVAL YEAR(2) TO MONTH` · `created_ts TSLTZ DEFAULT SYSTIMESTAMP`
· `manager_employee_id FK→employee`
· `legacy_migration_notes LONG` — the schema's **only** `LONG` column (Oracle permits one per
  table); free text carried over from the 1990s system

### C. Product catalogue (4 tables)

**`product_category`** — merchandise hierarchy (hierarchy 3).
`category_id NUMBER(9) PK` · `category_code VARCHAR2(30) NN UQ` · `category_name VARCHAR2(120) NN`
· `parent_category_id FK→product_category` · `merch_level NUMBER(2)`
· `is_leaf CHAR(1) DEFAULT 'N'` · `sort_order NUMBER(6)`

**`brand`**
`brand_id NUMBER(9) PK` · `brand_code VARCHAR2(30) NN UQ` · `brand_name VARCHAR2(120) NN`
· `owner_supplier_id FK→supplier` · `is_own_label CHAR(1) DEFAULT 'N'`

**`product`** — the heaviest table in the schema by construct count.
`product_id NUMBER(12) PK` · `sku VARCHAR2(30) NN UQ` · `product_name VARCHAR2(200) NN`
· `category_id FK→product_category NN` · `brand_id FK→brand`
· `long_description CLOB` · `spec_sheet XMLTYPE` · `primary_image BLOB`
· `unit_cost NUMBER(12,4) NN` · `list_price NUMBER(12,4) NN`
· `margin_pct VIRT AS (ROUND((list_price-unit_cost)/NULLIF(list_price,0)*100,2))`
· `base_uom VARCHAR2(10) DEFAULT 'EA'` · `weight_kg NUMBER(9,3)`
· `status VARCHAR2(15) DEFAULT 'ACTIVE' CHECK IN ('DRAFT','ACTIVE','DISCONTINUED','DELETED')`
· `launch_date DATE`
· `attributes NT t_product_attr_tab` — `NESTED TABLE attributes STORE AS product_attr_ntab`
· `channel_availability VA t_channel_varr`
· `created_ts TSLTZ DEFAULT SYSTIMESTAMP`

**`product_variant`** — the sellable unit; everything downstream keys on `variant_id`.
`variant_id NUMBER(12) PK` · `product_id FK→product NN` · `variant_sku VARCHAR2(40) NN UQ`
· `barcode_ean13 VARCHAR2(13) UQ` · `size_code VARCHAR2(20)` · `colour_code VARCHAR2(20)`
· `pack_qty NUMBER(6) DEFAULT 1 NN` · `size_run VA t_size_run_varr`
· `is_active CHAR(1) DEFAULT 'Y'` · `UQ (product_id, size_code, colour_code)`

### D. Supplier and procurement (5 tables)

**`supplier`**
`supplier_id NUMBER(9) PK` · `supplier_code VARCHAR2(20) NN UQ` · `supplier_name VARCHAR2(150) NN`
· `address_id FK→address` · `primary_contact OBJ t_contact` — object column with member methods
· `payment_terms_days NUMBER(4) DEFAULT 30` · `currency_code FK→currency NN`
· `lead_time INTERVAL DAY(3) TO SECOND(0)` · `rating NUMBER(3,1)`
· `is_approved CHAR(1) DEFAULT 'N'` · `onboarded_ts TSLTZ`

**`supplier_product`** — sourcing matrix.
`supplier_id FK→supplier PK` · `variant_id FK→product_variant PK` · `supplier_sku VARCHAR2(40) NN`
· `unit_cost NUMBER(12,4) NN` · `currency_code FK→currency` · `min_order_qty NUMBER(9) DEFAULT 1`
· `lead_time_days NUMBER(4)` · `is_primary_source CHAR(1) DEFAULT 'N'`
· `valid_from DATE` · `valid_to DATE`

**`purchase_order`** — **`PARTITION BY RANGE (order_date) INTERVAL (NUMTOYMINTERVAL(1,'MONTH'))`**.
`po_id NUMBER(12) PK` — deliberately a **global** unique index that does *not* include the
partition key · `po_number VARCHAR2(20) NN` · `supplier_id FK→supplier NN`
· `warehouse_id FK→warehouse NN` · `order_date DATE NN` (partition key) · `expected_date DATE`
· `status VARCHAR2(15) CHECK IN ('DRAFT','SENT','PART_RECV','RECEIVED','CANCELLED')`
· `currency_code FK→currency NN` · `order_total NUMBER(14,2)`
· `created_by VARCHAR2(30) DEFAULT SYS_CONTEXT('USERENV','SESSION_USER')`
· `approved_by_employee_id FK→employee`

**`purchase_order_line`**
`po_id FK→purchase_order PK` · `line_no NUMBER(4) PK` · `variant_id FK→product_variant NN`
· `qty_ordered NUMBER(12,3) NN CHECK > 0` · `qty_received NUMBER(12,3) DEFAULT 0`
· `unit_cost NUMBER(12,4) NN` · `line_total VIRT AS (qty_ordered*unit_cost)`
· `expected_date DATE` · `status VARCHAR2(15)`

**`goods_receipt`** — receipts against PO lines.
`receipt_id NUMBER(12) PK` · `receipt_number VARCHAR2(20) UQ` · `po_id NUMBER(12)`
· `po_line_no NUMBER(4)` · `FK (po_id, po_line_no)→purchase_order_line`
· `warehouse_id FK→warehouse` · `received_ts TSLTZ NN` · `qty_received NUMBER(12,3) NN`
· `qty_rejected NUMBER(12,3) DEFAULT 0` · `received_by_employee_id FK→employee`

### E. Inventory (4 tables)

**`warehouse`**
`warehouse_id NUMBER(9) PK` · `warehouse_code VARCHAR2(12) NN UQ` · `warehouse_name VARCHAR2(120) NN`
· `region_id FK→region NN` · `address_id FK→address NN` · `capacity_pallets NUMBER(9)`
· `is_active CHAR(1) DEFAULT 'Y'`

**`inventory_location`** — bins in warehouses *or* stores; exactly one parent.
`location_id NUMBER(12) PK` · `location_code VARCHAR2(30) NN` · `warehouse_id FK→warehouse`
· `store_id FK→store` · `parent_location_id FK→inventory_location`
· `location_type VARCHAR2(20) CHECK IN ('BACKROOM','SHELF','BULK','PICKFACE','QUARANTINE','TRANSIT')`
· `CHECK ((warehouse_id IS NULL) <> (store_id IS NULL))`
· unique function-based index on `(NVL(warehouse_id,0), NVL(store_id,0), location_code)`

**`inventory_stock`** — current snapshot.
`location_id FK→inventory_location PK` · `variant_id FK→product_variant PK`
· `qty_on_hand NUMBER(14,3) DEFAULT 0 NN` · `qty_reserved NUMBER(14,3) DEFAULT 0 NN`
· `qty_available VIRT AS (qty_on_hand - qty_reserved)` · `reorder_point NUMBER(12,3)`
· `reorder_qty NUMBER(12,3)` · `last_counted_date DATE` · `last_movement_ts TSLTZ`

**`inventory_movement`** — the ledger. **`PARTITION BY RANGE (movement_ts) INTERVAL (1 month)`
`SUBPARTITION BY LIST (movement_type)`** — composite partitioning.
`movement_id NUMBER(18) PK` · `movement_ts TIMESTAMP(6) NN PK` (partition key)
· `variant_id FK→product_variant NN` · `from_location_id FK→inventory_location`
· `to_location_id FK→inventory_location`
· `movement_type VARCHAR2(20) NN CHECK IN ('RECEIPT','SALE','RETURN','TRANSFER','ADJUST','SHRINK','COUNT')`
· `qty NUMBER(14,3) NN` · `reference_type VARCHAR2(20)` · `reference_id NUMBER(18)`
· `created_by VARCHAR2(30)`

### F. Customer and loyalty (5 tables)

**`customer`** — **protected by a VPD policy** (`pkg_vpd_policy.customer_predicate`).
`customer_id NUMBER(12) PK` · `customer_ref VARCHAR2(20) NN UQ` · `first_name VARCHAR2(60)`
· `last_name VARCHAR2(60) NN` · `email VARCHAR2(150)` (unique via FBI on `LOWER(email)`)
· `mobile_phone VARCHAR2(30)` · `birth_date DATE` · `home_country_code FK→country NN`
· `preferred_store_id FK→store` · `primary_address_id FK→address`
· `marketing_optin CHAR(1) DEFAULT 'N'` · `consent_channels VA t_channel_varr`
· `status VARCHAR2(15) DEFAULT 'ACTIVE'` · `created_ts TSLTZ DEFAULT SYSTIMESTAMP NN`
· `last_login_ts TSLTZ` · `gdpr_erasure_ts TSLTZ` · `notes CLOB`

**`customer_address`** — many-to-many with a type.
`customer_id FK→customer PK` · `address_id FK→address PK` · `address_type VARCHAR2(15) PK`
· `is_default CHAR(1) DEFAULT 'N'` · `valid_from DATE` · `valid_to DATE`

**`loyalty_tier`**
`tier_code VARCHAR2(10) PK` · `tier_name VARCHAR2(60) NN` · `min_points NUMBER(9) NN`
· `discount_pct NUMBER(5,2) DEFAULT 0` · `points_multiplier NUMBER(5,2) DEFAULT 1`
· `benefits NT t_benefit_tab` — `NESTED TABLE benefits STORE AS loyalty_benefit_ntab`
· `review_interval INTERVAL YEAR(2) TO MONTH`

**`loyalty_account`**
`loyalty_id NUMBER(12) PK` · `customer_id FK→customer NN UQ` · `card_number VARCHAR2(19) NN UQ`
· `tier_code FK→loyalty_tier NN` · `points_balance NUMBER(12) DEFAULT 0 NN CHECK >= 0`
· `lifetime_points NUMBER(14) DEFAULT 0` · `enrolled_date DATE NN` · `tier_reviewed_date DATE`
· `status VARCHAR2(15) DEFAULT 'ACTIVE'`

**`loyalty_transaction`** — **`PARTITION BY LIST (txn_type)`**.
`loyalty_txn_id NUMBER(18) PK` · `txn_type VARCHAR2(15) NN PK` (partition key,
`'ACCRUE','REDEEM','EXPIRE','ADJUST','TRANSFER'`) · `loyalty_id FK→loyalty_account NN`
· `points_delta NUMBER(12) NN` · `order_id NUMBER(18)` (soft reference — no FK, because the
parent is interval-partitioned; documented deliberately) · `reason_code VARCHAR2(20)`
· `txn_ts TSLTZ DEFAULT SYSTIMESTAMP NN` · `expires_on DATE` · `created_by VARCHAR2(30)`

### G. Pricing and promotions (5 tables)

**`price_list`**
`price_list_id NUMBER(9) PK` · `price_list_code VARCHAR2(30) NN UQ` · `country_code FK→country NN`
· `currency_code FK→currency NN` · `channel_code VARCHAR2(20) NN` · `valid_from DATE NN`
· `valid_to DATE` · `priority NUMBER(3) DEFAULT 100`

**`price_list_item`**
`price_list_id FK→price_list PK` · `variant_id FK→product_variant PK` · `effective_from DATE PK`
· `unit_price NUMBER(12,4) NN CHECK >= 0` · `was_price NUMBER(12,4)` · `tax_rate_id FK→tax_rate`
· `effective_to DATE` · `price_reason_code VARCHAR2(20)`

**`promotion`**
`promotion_id NUMBER(9) PK` · `promo_code VARCHAR2(30) NN UQ` · `promo_name VARCHAR2(150) NN`
· `promo_type VARCHAR2(20) CHECK IN ('PCT_OFF','AMT_OFF','BOGO','BUNDLE','THRESHOLD','LOYALTY_X')`
· `start_ts TSLTZ NN` · `end_ts TSLTZ NN CHECK (end_ts > start_ts)`
· `budget_amount NUMBER(14,2)` · `spent_amount NUMBER(14,2) DEFAULT 0`
· `rule_xml XMLTYPE` — the eligibility rule, parsed with `XMLTABLE` in `pkg_promotion`
· `country_code FK→country` · `status VARCHAR2(15) DEFAULT 'DRAFT'`

**`promotion_product`**
`promotion_id FK→promotion PK` · `variant_id FK→product_variant PK` · `discount_pct NUMBER(5,2)`
· `discount_amount NUMBER(12,4)` · `max_qty_per_order NUMBER(6)`
· `CHECK (discount_pct IS NOT NULL OR discount_amount IS NOT NULL)`

**`coupon`**
`coupon_id NUMBER(12) PK` · `coupon_code VARCHAR2(40) NN UQ` · `promotion_id FK→promotion NN`
· `customer_id FK→customer` (NULL = bearer coupon) · `issued_ts TSLTZ` · `expires_ts TSLTZ`
· `max_redemptions NUMBER(6) DEFAULT 1` · `redemption_count NUMBER(6) DEFAULT 0`
· `redeemed_ts TSLTZ` · `CHECK (redemption_count <= max_redemptions)`

### H. Orders and fulfilment (6 tables)

**`sales_order`** — **`PARTITION BY RANGE (order_ts) INTERVAL (NUMTODSINTERVAL(30,'DAY'))`**,
`PK (order_id)` as a **global** unique index.
`order_id NUMBER(18) PK` · `order_number VARCHAR2(24) NN` · `customer_id FK→customer`
· `store_id FK→store NN`
· `channel_code VARCHAR2(20) NN CHECK IN ('POS','WEB','APP','CALL','KIOSK','PARTNER')`
· `order_ts TSLTZ NN` (partition key)
· `status VARCHAR2(20) CHECK IN ('CART','PLACED','PICKING','SHIPPED','DELIVERED','CANCELLED','RETURNED')`
· `currency_code FK→currency NN` · `subtotal_amount NUMBER(14,2)`
· `discount_amount NUMBER(14,2) DEFAULT 0` · `tax_amount NUMBER(14,2) DEFAULT 0`
· `shipping_amount NUMBER(14,2) DEFAULT 0`
· `order_total VIRT AS (subtotal_amount - discount_amount + tax_amount + shipping_amount)`
· `ship_address_id FK→address` · `bill_address_id FK→address` · `promotion_id FK→promotion`
· `coupon_id FK→coupon` · `sales_employee_id FK→employee` · `source_ip VARCHAR2(45)`

**`sales_order_line`** — **`PARTITION BY REFERENCE (fk_sol_order)`**, inheriting the parent's
partitioning.
`order_id FK→sales_order PK NN` · `line_no NUMBER(4) PK` · `variant_id FK→product_variant NN`
· `qty NUMBER(12,3) NN CHECK > 0` · `unit_price NUMBER(12,4) NN`
· `discount_amount NUMBER(12,4) DEFAULT 0` · `tax_rate_id FK→tax_rate`
· `tax_amount NUMBER(12,4) DEFAULT 0`
· `line_total VIRT AS (qty*unit_price - discount_amount + tax_amount)`
· `fulfil_location_id FK→inventory_location` · `status VARCHAR2(20)`

**`order_payment`**
`payment_id NUMBER(18) PK` · `order_id FK→sales_order NN`
· `payment_method VARCHAR2(20) CHECK IN ('CARD','CASH','VOUCHER','LOYALTY','GIFTCARD','BNPL','ACCOUNT')`
· `amount NUMBER(14,2) NN` · `currency_code FK→currency NN` · `auth_code VARCHAR2(30)`
· `card_token VARCHAR2(64)` — an opaque token, never a PAN; becomes a `pgcrypto` demo on the
  target · `authorised_ts TSLTZ` · `captured_ts TSLTZ` · `refunded_ts TSLTZ`
· `status VARCHAR2(15)`

**`carrier`**
`carrier_code VARCHAR2(12) PK` · `carrier_name VARCHAR2(120) NN`
· `service_levels VA t_service_varr` · `tracking_url_template VARCHAR2(300)`
· `cutoff_offset INTERVAL DAY(0) TO SECOND(0)` · `is_active CHAR(1) DEFAULT 'Y'`

**`shipment`**
`shipment_id NUMBER(18) PK` · `order_id FK→sales_order NN` · `carrier_code FK→carrier NN`
· `service_level VARCHAR2(30)` · `tracking_ref VARCHAR2(60)`
· `from_location_id FK→inventory_location` · `shipped_ts TSLTZ` · `delivered_ts TSLTZ`
· `transit_time INTERVAL DAY(3) TO SECOND(0)` · `weight_kg NUMBER(9,3)` · `status VARCHAR2(20)`

**`shipment_line`** — supports partial shipment of an order line.
`shipment_id FK→shipment PK` · `line_no NUMBER(4) PK` · `order_id NUMBER(18)`
· `order_line_no NUMBER(4)` · `FK (order_id, order_line_no)→sales_order_line`
· `qty_shipped NUMBER(12,3) NN`

### I. Returns (3 tables)

**`return_reason`** — **`ORGANIZATION INDEX`** (second IOT).
`reason_code VARCHAR2(20) PK` · `reason_desc VARCHAR2(150) NN` · `reason_group VARCHAR2(30)`
· `is_restockable CHAR(1) DEFAULT 'Y'` · `requires_approval CHAR(1) DEFAULT 'N'`

**`return_request`**
`return_id NUMBER(18) PK` · `rma_number VARCHAR2(24) NN UQ` · `order_id FK→sales_order NN`
· `customer_id FK→customer` · `store_id FK→store` · `requested_ts TSLTZ NN`
· `status VARCHAR2(20) CHECK IN ('REQUESTED','APPROVED','REJECTED','RECEIVED','REFUNDED','CLOSED')`
· `refund_amount NUMBER(14,2)` · `currency_code FK→currency`
· `approved_by_employee_id FK→employee` · `closed_ts TSLTZ`

**`return_line`**
`return_id FK→return_request PK` · `line_no NUMBER(4) PK` · `order_id NUMBER(18)`
· `order_line_no NUMBER(4)` · `FK (order_id, order_line_no)→sales_order_line`
· `variant_id FK→product_variant` · `qty_returned NUMBER(12,3) NN`
· `reason_code FK→return_reason NN`
· `disposition_code VARCHAR2(20) CHECK IN ('RESTOCK','SCRAP','REPAIR','SUPPLIER','DONATE')`
· `refund_amount NUMBER(12,4)`

### J. Finance and general ledger (4 tables)

**`gl_account`** — chart of accounts (hierarchy 4).
`account_code VARCHAR2(20) PK` · `account_name VARCHAR2(150) NN`
· `account_type VARCHAR2(15) CHECK IN ('ASSET','LIABILITY','EQUITY','REVENUE','EXPENSE')`
· `parent_account_code FK→gl_account` · `is_postable CHAR(1) DEFAULT 'Y'`
· `normal_balance CHAR(1) CHECK IN ('D','C')` · `currency_code FK→currency`

**`gl_period`**
`period_id NUMBER(9) PK` · `fiscal_year NUMBER(4) NN` · `period_no NUMBER(2) NN`
· `period_start DATE NN` · `period_end DATE NN`
· `status VARCHAR2(10) CHECK IN ('FUTURE','OPEN','CLOSING','CLOSED')` · `closed_ts TSLTZ`
· `UQ (fiscal_year, period_no)`

**`gl_journal`**
`journal_id NUMBER(18) PK` · `journal_ref VARCHAR2(30) NN UQ` · `period_id FK→gl_period NN`
· `source_module VARCHAR2(20) CHECK IN ('SALES','RETURNS','PURCHASING','INVENTORY','PAYROLL','MANUAL')`
· `journal_date DATE NN` · `description VARCHAR2(300)` · `posted_ts TSLTZ`
· `posted_by VARCHAR2(30)` · `status VARCHAR2(15) CHECK IN ('DRAFT','POSTED','REVERSED')`
· `reversal_of_journal_id FK→gl_journal`

**`gl_journal_line`**
`journal_id FK→gl_journal PK` · `line_no NUMBER(5) PK` · `account_code FK→gl_account NN`
· `store_id FK→store` · `cost_centre VARCHAR2(20)`
· `debit_amount NUMBER(16,2) DEFAULT 0 NN` · `credit_amount NUMBER(16,2) DEFAULT 0 NN`
· `currency_code FK→currency NN` · `fx_rate NUMBER(18,8)`
· `base_amount VIRT AS ((debit_amount - credit_amount) * fx_rate)`
· `line_description VARCHAR2(300)` · `CHECK (debit_amount = 0 OR credit_amount = 0)`

### K. Operational and audit (5 tables)

**`audit_log`** — written only by `pkg_audit`, which is `PRAGMA AUTONOMOUS_TRANSACTION`.
`audit_id NUMBER(18) PK` (from `seq_audit_id`, `NOCACHE`) · `table_name VARCHAR2(30) NN`
· `pk_value VARCHAR2(200)` · `action_type CHAR(1) CHECK IN ('I','U','D')`
· `changed_by VARCHAR2(30) DEFAULT SYS_CONTEXT('USERENV','SESSION_USER')`
· `client_id VARCHAR2(64) DEFAULT SYS_CONTEXT('USERENV','CLIENT_IDENTIFIER')`
· `app_user VARCHAR2(64) DEFAULT SYS_CONTEXT('CONTOSO_APP_CTX','APP_USER')`
· `changed_ts TSLTZ DEFAULT SYSTIMESTAMP` · `old_row CLOB` · `new_row CLOB`

**`error_log`** — written by `pkg_error`, also autonomous, so it survives a rollback.
`error_id NUMBER(18) PK` (`seq_error_id`, `NOCACHE`) · `module_name VARCHAR2(80)`
· `routine_name VARCHAR2(80)` · `error_code NUMBER` · `error_message VARCHAR2(4000)`
· `error_backtrace CLOB` · `call_stack CLOB` · `bind_context VARCHAR2(4000)`
· `logged_ts TSLTZ DEFAULT SYSTIMESTAMP` · `db_user VARCHAR2(30)` · `app_user VARCHAR2(64)`

**`job_run_log`** — one row per `DBMS_SCHEDULER` execution.
`run_id NUMBER(18) PK` · `job_name VARCHAR2(80) NN` · `started_ts TSLTZ` · `finished_ts TSLTZ`
· `elapsed INTERVAL DAY(2) TO SECOND(3)`
· `status VARCHAR2(15) CHECK IN ('RUNNING','SUCCESS','FAILED','SKIPPED')`
· `rows_processed NUMBER(12)` · `message VARCHAR2(4000)`

**`app_parameter`** — **`ORGANIZATION INDEX`** (third IOT); runtime configuration.
`param_name VARCHAR2(60) PK` · `param_value VARCHAR2(500)`
· `param_type VARCHAR2(15) CHECK IN ('STRING','NUMBER','DATE','BOOLEAN')`
· `description VARCHAR2(300)` · `is_encrypted CHAR(1) DEFAULT 'N'` · `updated_ts TSLTZ`
· `updated_by VARCHAR2(30)`

**`data_quality_issue`** — output of `pkg_data_quality`'s dynamic rule engine.
`issue_id NUMBER(18) PK` · `rule_code VARCHAR2(30) NN` · `entity_name VARCHAR2(30) NN`
· `entity_key VARCHAR2(200)` · `severity VARCHAR2(10) CHECK IN ('INFO','WARN','ERROR','FATAL')`
· `detail VARCHAR2(4000)` · `detected_ts TSLTZ DEFAULT SYSTIMESTAMP` · `resolved_ts TSLTZ`

### L. Global temporary tables (3)

| Table | Commit behaviour | Used by |
| --- | --- | --- |
| `gtt_price_calc` | `ON COMMIT DELETE ROWS` | `pkg_pricing.resolve_prices` — stages candidate prices before picking the winner |
| `gtt_replenishment` | `ON COMMIT PRESERVE ROWS` | `pkg_replenishment` — survives the intermediate commits inside the nightly job |
| `gtt_order_stage` | `ON COMMIT DELETE ROWS` | `pkg_order_capture` — `BULK COLLECT` target for basket validation |

### M. Nested-table storage tables (2)

`product_attr_ntab` and `loyalty_benefit_ntab` are created implicitly by the `NESTED TABLE …
STORE AS` clauses. They appear in `user_objects` as `TABLE` and count toward the budget. We
never reference them by name in application code.

---

## 6. Types, packages and the rest of the object graph

### 6.1 Object types, VARRAYs and nested tables (`src/oracle/01-types.sql`)

18 `TYPE` objects, 8 `TYPE BODY` objects.

**Object types with member methods (6, each with a body):**

| Type | Attributes | Methods |
| --- | --- | --- |
| `t_money` | `amount NUMBER`, `currency_code CHAR(3)` | `MEMBER FUNCTION converted_to(p_ccy, p_on_date) RETURN t_money`; `MEMBER PROCEDURE add_amount(p_amount)`; `MAP MEMBER FUNCTION to_base RETURN NUMBER`; `STATIC FUNCTION zero(p_ccy) RETURN t_money` |
| `t_contact` | `contact_name`, `email`, `phone`, `role_title` | `MEMBER FUNCTION display_label RETURN VARCHAR2`; `MEMBER FUNCTION is_valid_email RETURN VARCHAR2` |
| `t_postal_address` | `line1`, `line2`, `city`, `postal_code`, `country_code` | `MEMBER FUNCTION format_label RETURN VARCHAR2` and an **overloaded** `format_label(p_style VARCHAR2)` |
| `t_product_attr` | `attr_name`, `attr_value`, `attr_uom` | `MEMBER FUNCTION as_number RETURN NUMBER` |
| `t_loyalty_benefit` | `benefit_code`, `benefit_desc`, `benefit_value`, `valid_from`, `valid_to` | `MEMBER FUNCTION is_active(p_on DATE) RETURN VARCHAR2` |
| `t_price_point` | `variant_id`, `price`, `currency_code`, `source_code` | `ORDER MEMBER FUNCTION compare(o t_price_point) RETURN INTEGER` |

**Type inheritance (3 types, 2 bodies):** `t_party` is `NOT INSTANTIABLE NOT FINAL` with a
`NOT INSTANTIABLE MEMBER FUNCTION party_label`. `t_customer_party` and `t_supplier_party` are
`UNDER t_party` with `OVERRIDING MEMBER FUNCTION party_label`. Substitutability has no
PostgreSQL analogue at all — see hard case H-03.

**VARRAY types (4):** `t_channel_varr VARRAY(8) OF VARCHAR2(20)`,
`t_size_run_varr VARRAY(24) OF NUMBER(6)`, `t_service_varr VARRAY(10) OF VARCHAR2(30)`,
`t_tag_varr VARRAY(20) OF VARCHAR2(40)`.

**Nested table types (5):** `t_product_attr_tab TABLE OF t_product_attr`,
`t_benefit_tab TABLE OF t_loyalty_benefit`, `t_price_point_tab TABLE OF t_price_point`,
`t_number_tab TABLE OF NUMBER`, `t_varchar_tab TABLE OF VARCHAR2(4000)`.

The last two are SQL-level (not PL/SQL-local) on purpose — they are the `BULK COLLECT` targets
and the `TABLE()` unnesting operands, and being schema-level types means the converter must
decide between a PostgreSQL domain, an array type, and a composite type.

### 6.2 Packages (`src/oracle/07-packages.sql`)

25 packages, 25 bodies. "Carries" lists the hard cases each one is responsible for exercising.

| # | Package | Purpose | Carries |
| --- | --- | --- | --- |
| 1 | `pkg_catalog` | Product and category maintenance; walks the merchandise tree; publishes and retires SKUs | overloading (5 signatures of `add_product`), `CONNECT BY` + `SYS_CONNECT_BY_PATH`, `DETERMINISTIC` |
| 2 | `pkg_pricing` | Resolves the effective price for a variant/store/channel/date, honouring price list priority | `RESULT_CACHE`, GTT, `DECODE`/`NVL2`, `ROWNUM` vs `ROW_NUMBER`, Oracle `(+)` join |
| 3 | `pkg_promotion` | Promotion eligibility and discount calculation; parses `promotion.rule_xml` | `XMLTYPE`/`XMLTABLE`, nested tables, `MERGE` |
| 4 | `pkg_inventory` | Applies stock movements and keeps `inventory_stock` in step | `MERGE`, `FORALL`, `BULK COLLECT`, `RETURNING INTO` |
| 5 | `pkg_replenishment` | Nightly reorder proposal from demand history and reorder points | analytic functions, `GTT` with `ON COMMIT PRESERVE`, scheduler-driven |
| 6 | `pkg_purchasing` | Purchase order lifecycle: draft, approve, send, cancel | `EXECUTE IMMEDIATE`, autonomous audit calls, user-defined exceptions |
| 7 | `pkg_receiving` | Goods receipt posting, over/under-delivery tolerance | compound trigger interplay, `FORALL … SAVE EXCEPTIONS` |
| 8 | `pkg_order_capture` | Basket validation and order placement | user-defined exceptions, `RAISE_APPLICATION_ERROR`, `PRAGMA EXCEPTION_INIT`, `BULK COLLECT` into a GTT |
| 9 | `pkg_fulfilment` | Allocates stock to order lines and creates shipments | `REF CURSOR` returns, `FOR UPDATE SKIP LOCKED` |
| 10 | `pkg_returns` | RMA creation, approval, refund and disposition | `MERGE`, `INSTEAD OF` trigger target view |
| 11 | `pkg_customer` | Customer CRUD and GDPR erasure | empty-string-is-NULL semantics, `SYS_CONTEXT`, `NVL` chains |
| 12 | `pkg_loyalty` | Points accrual, redemption, expiry and tier review | object types with member methods, VARRAY, nested table of benefits |
| 13 | `pkg_security_ctx` | The only package allowed to set `CONTOSO_APP_CTX`; a trusted context package | application context, `DBMS_SESSION.SET_CONTEXT` |
| 14 | `pkg_vpd_policy` | Row-level predicate functions registered with `DBMS_RLS` | Virtual Private Database, `SYS_CONTEXT` |
| 15 | `pkg_finance_gl` | Posts journals from sales, returns, purchasing and inventory | `PRAGMA AUTONOMOUS_TRANSACTION`, `INSERT ALL`, `ROWNUM` |
| 16 | `pkg_fx` | Currency conversion and rate lookup with fallback to the prior day | `DETERMINISTIC`, `RESULT_CACHE`, scalar subquery |
| 17 | `pkg_reporting` | Cursor factories for the reporting layer | `REF CURSOR` (weak and strong), analytic functions, `CONNECT BY` roll-up |
| 18 | `pkg_etl_export` | Writes flat extracts for downstream systems | `UTL_FILE`, `DBMS_LOB`, `DBMS_OUTPUT` |
| 19 | `pkg_audit` | Row-change audit trail | `PRAGMA AUTONOMOUS_TRANSACTION`, `SYS_CONTEXT` defaults |
| 20 | `pkg_error` | Central error capture and re-raise | autonomous transaction, `DBMS_UTILITY.FORMAT_ERROR_BACKTRACE`, `PRAGMA EXCEPTION_INIT` |
| 21 | `pkg_job_control` | Creates, enables, disables and reports on scheduler jobs | `DBMS_SCHEDULER`, dynamic SQL |
| 22 | `pkg_data_quality` | Runs the rule set stored as SQL text and records failures | `EXECUTE IMMEDIATE` with bind variables, `DBMS_SQL` for one dynamic-column case |
| 23 | `pkg_mv_refresh` | Drives the materialised view refresh group | `DBMS_MVIEW.REFRESH`, refresh group management |
| 24 | `pkg_utils` | String, date and number helpers used everywhere | heavy overloading (9 `to_display` signatures), `LONG`→`CLOB` conversion, `%TYPE`/`%ROWTYPE` anchors |
| 25 | `pkg_store_ops` | Store and staffing hierarchy queries, trading-hours arithmetic | `CONNECT BY` on two trees, `INTERVAL` arithmetic, `TSLTZ` |

Three packages hold **package-level state** — `pkg_security_ctx.g_current_app_user`,
`pkg_pricing.g_price_cache` (an associative array), and `pkg_utils.g_nls_numeric` — which
persists for the life of the session. PostgreSQL has no equivalent; see hard case H-43.

### 6.3 Standalone routines (`src/oracle/08-procedures.sql`)

10 `PROCEDURE`, 12 `FUNCTION`. These exist as standalone objects (not package members) because
the synonym layer points at them and because the converter treats standalone and packaged code
differently.

Procedures: `sp_rebuild_category_paths`, `sp_recalc_inventory_snapshot`, `sp_expire_promotions`,
`sp_close_gl_period`, `sp_purge_audit_log`, `sp_refresh_reporting_layer`,
`sp_apply_price_change_batch`, `sp_reindex_search_keys`, `sp_export_daily_sales`,
`sp_seed_demo_data`.

Functions: `fn_fiscal_period` (`DETERMINISTIC`), `fn_working_days_between` (`DETERMINISTIC`),
`fn_convert_amount` (`RESULT_CACHE RELIES_ON (exchange_rate)`), `fn_effective_price`,
`fn_tier_for_points` (`DETERMINISTIC`), `fn_category_path`, `fn_manager_chain`,
`fn_store_local_time` (`TSLTZ`), `fn_normalise_sku` (`DETERMINISTIC`, backs a function-based
index), `fn_mask_email`, `fn_order_line_count` (a **pipelined** table function returning
`t_number_tab`), `fn_split_csv` (pipelined, returns `t_varchar_tab`).

### 6.4 Triggers (`src/oracle/09-triggers.sql`)

26 triggers, covering every timing Oracle offers:

- `BEFORE INSERT … FOR EACH ROW` — surrogate key assignment on 6 tables (`trg_bi_*`)
- `BEFORE UPDATE … FOR EACH ROW` — audit stamping on `product`, `customer`, `app_parameter`
- `AFTER INSERT OR UPDATE OR DELETE … FOR EACH ROW` — audit trail on `customer`,
  `loyalty_account`, `gl_journal_line`
- `BEFORE INSERT OR UPDATE … (statement level)` — `gl_period` open/closed gate
- `AFTER DELETE (statement level)` — `trg_as_price_list_item_reprice`
- **Compound triggers** (3) — `trg_cmp_inventory_stock`, `trg_cmp_sales_order_line`,
  `trg_cmp_loyalty_txn`. Each uses `BEFORE STATEMENT` to initialise a collection,
  `AFTER EACH ROW` to accumulate into it, and `AFTER STATEMENT` to flush with `FORALL`.
  This is the classic mutating-table workaround and it is the single hardest trigger shape.
- **`INSTEAD OF` triggers** (3) — on `v_customer_360`, `v_product_sellable`, `v_open_purchase_orders`
- **`FOLLOWS`** ordering — `trg_ar_gl_journal_line_b FOLLOWS trg_ar_gl_journal_line_a`, to prove
  the converter notices deterministic firing order
- One `BEFORE INSERT` trigger uses `WHEN (NEW.channel_code = 'WEB')` to exercise the `WHEN` clause

### 6.5 Views, materialised views, synonyms (`src/oracle/06-views.sql`, `10-mviews.sql`, `13-synonyms-grants.sql`)

**18 views.** Notable ones: `v_customer_360` (INSTEAD OF target, joins 6 tables),
`v_product_sellable`, `v_open_purchase_orders`, `v_stock_position`,
`v_sales_by_store_day` (window functions), `v_category_tree` (`CONNECT BY` with `LEVEL` and
`SYS_CONNECT_BY_PATH`), `v_gl_trial_balance` (bottom-up `CONNECT BY` roll-up),
`v_employee_reporting_line`, `v_legacy_orders` (uses Oracle `(+)` outer-join syntax throughout,
on purpose), `v_promotion_effectiveness`.

**6 materialised views** with **3 materialised view logs** and **one refresh group**:

| MV | Refresh | Notes |
| --- | --- | --- |
| `mv_sales_daily_store` | `FAST ON COMMIT` | needs `mlog$_sales_order`, `mlog$_sales_order_line` |
| `mv_sales_monthly_category` | `FAST ON DEMAND` | in refresh group `rg_reporting` |
| `mv_stock_position` | `FAST ON DEMAND` | needs `mlog$_inventory_stock`; in `rg_reporting` |
| `mv_customer_rfm` | `COMPLETE ON DEMAND` | in `rg_reporting` |
| `mv_supplier_performance` | `COMPLETE ON DEMAND` | |
| `mv_promotion_uplift` | `COMPLETE ON DEMAND` | query rewrite enabled |

Each materialised view contributes **two** rows to `user_objects` — one `MATERIALIZED VIEW` and
one `TABLE` for the container — plus its indexes. The three `MLOG$_` tables count as `TABLE`.

**24 private synonyms** in `CONTOSO`, in three deliberate flavours: simple aliases for tables
(`syn_orders → sales_order`), aliases for packages (`syn_pricing → pkg_pricing`), and one
**dangling** synonym pointing at a dropped object, to see whether the converter reports it or
silently drops it. No `PUBLIC` synonyms — the lab must not pollute a shared database.

### 6.6 Scheduler (`src/oracle/11-jobs-scheduler.sql`)

6 `JOB`, 3 `PROGRAM`, 3 `SCHEDULE`.

| Job | Schedule | Calls |
| --- | --- | --- |
| `job_nightly_replenishment` | `sched_daily_0200` | `pkg_replenishment.run` |
| `job_expire_promotions` | `sched_daily_0200` | `sp_expire_promotions` |
| `job_loyalty_points_expiry` | `sched_monthly_first` | `pkg_loyalty.expire_points` |
| `job_refresh_reporting` | `sched_hourly` | `pkg_mv_refresh.refresh_group` |
| `job_data_quality_scan` | `sched_daily_0200` | `pkg_data_quality.run_all_rules` |
| `job_export_daily_sales` | `sched_daily_0200` | `sp_export_daily_sales` (writes via `UTL_FILE`) |

Programs `prog_replenishment`, `prog_dq_scan` and `prog_export` are `PLSQL_BLOCK` type with
declared arguments, so the converter has to deal with argument metadata as well as the job body.

---

## 7. The deterministic generator

`tools/generate-objects.py` emits **760** objects into `generated/`. Requirements:

- Seeded from `GEN_SEED` (default `20260902`). Two runs on two machines must produce
  byte-identical output — the lab diffs conversion results across runs, so drift is fatal.
- Every generated object carries the `gen_` infix and a zero-padded ordinal.
- Generated code is *plausible*, not noise: each `pkg_gen_rules_NNN` is a pricing or eligibility
  rule package over the real tables, each `v_gen_*` view is a real projection. The converter must
  be doing real work, not pattern-matching a template.
- Roughly 15% of generated objects deliberately include a hard case from section 9, so scale
  testing also stresses the difficult paths.

| Object type | Generated |
| --- | ---: |
| `VIEW` | 180 |
| `SYNONYM` | 150 |
| `FUNCTION` | 120 |
| `PROCEDURE` | 100 |
| `PACKAGE` | 60 |
| `PACKAGE BODY` | 60 |
| `SEQUENCE` | 50 |
| `TRIGGER` | 40 |
| **Total** | **760** |

---

## 8. Object budget

The counting rule, which `src/oracle/99-verify-objects.sql` asserts:

```sql
SELECT COUNT(*) FROM user_objects
 WHERE object_type NOT IN ('LOB','TABLE PARTITION','INDEX PARTITION','LOB PARTITION');
```

| Object type | Hand-written | Generated | Total |
| --- | ---: | ---: | ---: |
| `VIEW` | 18 | 180 | 198 |
| `SYNONYM` | 24 | 150 | 174 |
| `FUNCTION` | 12 | 120 | 132 |
| `PROCEDURE` | 10 | 100 | 110 |
| `PACKAGE` | 25 | 60 | 85 |
| `PACKAGE BODY` | 25 | 60 | 85 |
| `INDEX` | 78 | 0 | 78 |
| `SEQUENCE` | 24 | 50 | 74 |
| `TRIGGER` | 26 | 40 | 66 |
| `TABLE` | 64 | 0 | 64 |
| `TYPE` | 18 | 0 | 18 |
| `TYPE BODY` | 8 | 0 | 8 |
| `MATERIALIZED VIEW` | 6 | 0 | 6 |
| `JOB` | 6 | 0 | 6 |
| `PROGRAM` | 3 | 0 | 3 |
| `SCHEDULE` | 3 | 0 | 3 |
| **Total (design minimum)** | **350** | **760** | **1,110** |

Those are per-type design minimums, not a census. A loaded schema runs well above them — about
**1,820 objects** by the rule above, because the real count of nearly every type exceeds its
minimum. Roughly **1,450** are non-partition objects; the remainder are subpartitions of
composite-partitioned `inventory_movement`, so that slice of the count drifts with data volume and
with the seed date. The binding requirement is the **1,000-object floor**; the budget's job is to
guarantee that floor by construction, not to pile on partitions — which is why the counting rule
excludes them. A lab that only just cleared 1,000 would be one that fails on someone else's machine.

The 64 `TABLE` rows break down as: 45 core + 5 operational + 3 global temporary + 2 nested-table
storage + 6 materialised view containers + 3 materialised view logs.

The 78 `INDEX` rows: 45 primary key indexes (3 of which are the IOTs' own structures) +
14 unique constraint indexes + 9 function-based + 4 bitmap + 6 materialised view indexes.

---

## 9. Hard cases — the heart of the lab

Every construct below exists in `CONTOSO` and is exercised by seed data. For each: where it
lives, the PostgreSQL equivalent in one line, and our **prediction** of how the conversion tool
handles it — `clean`, `partial`, or `review task`.

These are predictions, not measurements. `docs/05-validate.md` section 6 records what actually happened.
Where we were wrong, the finding wins and this table gets corrected.

> Definitions. **Clean:** compiles and behaves identically with no human edit.
> **Partial:** compiles, but semantics drift in an edge case, or performance changes materially.
> **Review task:** the tool flags it and hands it to GitHub Copilot agent mode, or emits nothing.

### H-01 · Packages with overloaded procedures
- **Where:** `pkg_utils.to_display` (9 signatures), `pkg_catalog.add_product` (5), `t_postal_address.format_label` (2)
- **PostgreSQL:** package becomes a schema; PostgreSQL supports function overloading natively.
- **Prediction:** **partial**
- **Why hard:** overload resolution rules differ. Oracle picks by implicit conversion rank;
  PostgreSQL raises `function is not unique` for calls Oracle resolves happily — notably
  `NUMBER` vs `VARCHAR2` pairs, which both become candidates for an untyped literal. Expect the
  numeric/text overload pairs to need explicit casts at every call site.

### H-02 · `PRAGMA AUTONOMOUS_TRANSACTION`
- **Where:** `pkg_audit.write_audit`, `pkg_error.log_error`, `pkg_finance_gl.post_control_total`
- **PostgreSQL:** no native equivalent. Either a `dblink` self-connection, or restructure so the
  logging happens outside the transaction.
- **Prediction:** **review task**
- **Why hard:** this is the case that forces `dblink` onto the **target** server, not just
  scratch — easy to miss when allowlisting extensions. The `dblink` rewrite also opens a new
  connection per call, which is fine for error logging and catastrophic for the per-row audit
  trigger. Expect to redesign `pkg_audit` around a table-level `AFTER` trigger writing in the
  same transaction, and accept that audit rows now roll back with the change they describe —
  a genuine behaviour change the team must sign off.

### H-03 · Object types with member methods (and inheritance)
- **Where:** `t_money`, `t_contact`, `t_postal_address`, `t_product_attr`, `t_loyalty_benefit`,
  `t_price_point`; inheritance via `t_party` / `t_customer_party` / `t_supplier_party`;
  `supplier.primary_contact` is an object column
- **PostgreSQL:** composite type for the attributes, plus standalone functions taking the
  composite as the first argument (which then reads as `mytype.func(x)` via functional notation).
- **Prediction:** **review task**
- **Why hard:** composite types carry no methods, no `MAP`/`ORDER` comparison semantics, and no
  substitutability. `ORDER MEMBER FUNCTION compare` on `t_price_point` silently loses its
  ordering contract, so any `ORDER BY` over that column changes results. The `UNDER` hierarchy
  has no analogue at all — expect a manual flattening into one composite plus a discriminator.

### H-04 · VARRAY collections
- **Where:** `product.channel_availability`, `product_variant.size_run`,
  `carrier.service_levels`, `customer.consent_channels`
- **PostgreSQL:** a native array type (`text[]`, `numeric[]`).
- **Prediction:** **clean**
- **Why hard:** mostly it is not — this is the one collection case that maps well. The residue:
  VARRAY has a declared maximum length that PostgreSQL arrays do not enforce (`VARRAY(8)` becomes
  an unbounded `text[]`), and Oracle arrays are 1-based and dense while application code that
  used `.COUNT`, `.LIMIT` and `.EXTEND` needs rewriting. Add a `CHECK (array_length(...) <= 8)`
  to preserve the constraint.

### H-05 · Nested table collections
- **Where:** `product.attributes` (`t_product_attr_tab`), `loyalty_tier.benefits`
  (`t_benefit_tab`), storage tables `product_attr_ntab` / `loyalty_benefit_ntab`
- **PostgreSQL:** either an array of composite type, or — usually better — a proper child table.
- **Prediction:** **review task**
- **Why hard:** the mapping is a design decision, not a translation. An array of composites keeps
  the shape but makes the data unindexable and unqueryable without `unnest`. A child table is the
  right answer but changes every DML statement touching it and every `TABLE(...)` unnest in the
  PL/SQL. The tool cannot make that call for you; expect it to propose the array and expect to
  override it for `product.attributes`, which is queried by attribute name.

### H-06 · `CONNECT BY` hierarchical queries
- **Where:** `v_category_tree`, `v_employee_reporting_line`, `v_gl_trial_balance`,
  `pkg_catalog.category_path`, `pkg_store_ops.region_rollup`, `fn_manager_chain`
- **PostgreSQL:** `WITH RECURSIVE`.
- **Prediction:** **partial**
- **Why hard:** the basic shape converts mechanically, but the pseudo-columns do not. `LEVEL`
  becomes a hand-maintained depth counter. `SYS_CONNECT_BY_PATH` becomes string concatenation in
  the recursive term. `CONNECT_BY_ROOT` needs the root value carried through every level.
  `ORDER SIBLINGS BY` has no equivalent and needs a path array to sort on. `CONNECT_BY_ISLEAF`
  requires a second pass or a correlated `EXISTS`. Oracle also silently detects loops with
  `NOCYCLE`; PostgreSQL runs forever unless you add `CYCLE` (PG 14+) or a visited-path guard.
  We have four hierarchies precisely so this is tested four different ways.

### H-07 · `MERGE` statements
- **Where:** `pkg_inventory.apply_movement`, `pkg_promotion.sync_promo_products`,
  `pkg_returns.post_disposition`, `sp_apply_price_change_batch`
- **PostgreSQL:** `MERGE` (PG 15+) or `INSERT … ON CONFLICT DO UPDATE`.
- **Prediction:** **clean**
- **Why hard:** PostgreSQL 15 added `MERGE`, so the syntax survives — which is exactly why the
  target must be PG 15+. Two residues: Oracle's `WHERE` clause on the `UPDATE` branch and its
  `DELETE` clause are spelled differently, and Oracle permits `MERGE` on a view that PostgreSQL
  will not accept. `pkg_returns.post_disposition` merges into a view on purpose.

### H-08 · Analytic and window functions
- **Where:** `v_sales_by_store_day`, `mv_customer_rfm`, `pkg_replenishment.demand_forecast`,
  `pkg_reporting.*`
- **PostgreSQL:** the same window functions, with the same `OVER` syntax.
- **Prediction:** **clean**
- **Why hard:** largely not. Watch for `RATIO_TO_REPORT` (no PostgreSQL equivalent — becomes
  `x / SUM(x) OVER ()`), `KEEP (DENSE_RANK FIRST/LAST)` (becomes `FIRST_VALUE`/`LAST_VALUE` with
  a frame), and `NTH_VALUE … FROM LAST` (needs a reversed `ORDER BY`). `pkg_reporting` uses all
  three so they are actually tested.

### H-09 · `REF CURSOR` returns
- **Where:** `pkg_fulfilment.get_pick_list` (weak `SYS_REFCURSOR`),
  `pkg_reporting.open_sales_cursor` (strong, `RETURN sales_order%ROWTYPE`)
- **PostgreSQL:** `REFCURSOR`, or better, a set-returning function (`RETURNS SETOF`/`TABLE`).
- **Prediction:** **partial**
- **Why hard:** PostgreSQL refcursors are only usable inside the transaction that opened them and
  most client drivers handle them badly. The idiomatic answer is `RETURNS TABLE`, which changes
  the function signature and therefore every caller — including application code outside this
  repo. Strong ref cursors bound to `%ROWTYPE` are worse: the return type must be spelled out
  explicitly, and it drifts the moment someone adds a column.

### H-10 · `BULK COLLECT` and `FORALL`
- **Where:** `pkg_inventory.bulk_apply`, `pkg_order_capture.validate_basket`,
  `pkg_receiving.post_receipts` (`FORALL … SAVE EXCEPTIONS`), all three compound triggers
- **PostgreSQL:** plain set-based SQL, or arrays with `unnest`.
- **Prediction:** **partial**
- **Why hard:** the *translation* is easy — PL/pgSQL has no row-at-a-time overhead to avoid, so
  `FORALL` usually collapses into a single statement. The trap is `SAVE EXCEPTIONS`: Oracle
  continues past failing rows and reports them in `SQL%BULK_EXCEPTIONS`. PostgreSQL has no
  equivalent; a single failure aborts the statement. `pkg_receiving` relies on this to quarantine
  bad receipt lines and keep going, so the converted version needs an explicit per-row loop with
  a `BEGIN … EXCEPTION` block — slower, and a real behaviour decision.

### H-11 · Native dynamic SQL (`EXECUTE IMMEDIATE`)
- **Where:** `pkg_data_quality.run_rule` (rule text from a table), `pkg_purchasing.rebuild_index`
  (DDL), `pkg_job_control` (scheduler DDL), one `DBMS_SQL` path in `pkg_data_quality` for
  unknown column counts
- **PostgreSQL:** `EXECUTE … USING` in PL/pgSQL; `DBMS_SQL` has no analogue.
- **Prediction:** **partial** for `EXECUTE IMMEDIATE`, **review task** for `DBMS_SQL`
- **Why hard:** `EXECUTE IMMEDIATE` maps closely, but bind placeholders change from `:1` to `$1`,
  `INTO` becomes `INTO STRICT` if you want Oracle's `NO_DATA_FOUND` behaviour, and identifier
  quoting must move to `quote_ident`/`format(%I)` or you inherit an injection hole. The
  `DBMS_SQL` describe-columns path needs a full rewrite, probably to `RETURNS SETOF record` with
  a caller-supplied column list.

### H-12 · `DBMS_OUTPUT`
- **Where:** `pkg_etl_export`, `sp_seed_demo_data`, scattered debug lines in 11 packages
- **PostgreSQL:** `RAISE NOTICE`, or orafce's `dbms_output` shim.
- **Prediction:** **clean**
- **Why hard:** it is not, provided orafce is allowlisted and the `dbms_output` schema is on the
  database `search_path` (see the `PG_SEARCH_PATH` variable in `.env.example`). The one real
  difference: Oracle buffers until the client fetches, PostgreSQL emits immediately, so
  interleaving with other output changes. Harmless here, occasionally not in production.

### H-13 · `UTL_FILE`
- **Where:** `pkg_etl_export.write_sales_extract`, driven by `job_export_daily_sales`; writes to
  Oracle directory `CONTOSO_EXPORT_DIR`
- **PostgreSQL:** orafce provides a `utl_file` implementation, but Azure Database for PostgreSQL
  flexible server gives you no server filesystem to write to.
- **Prediction:** **review task**
- **Why hard:** this is an architecture problem wearing a syntax problem's clothes. Managed
  PostgreSQL has no accessible local disk and no `utl_file_dir`. The honest answers are: move the
  extract to a client-side `COPY … TO STDOUT`, or push to Blob Storage from an external job. The
  tool may well emit orafce `utl_file` calls that compile and then fail at runtime — the worst
  possible outcome, and a good lesson.

### H-14 · `DBMS_SCHEDULER` jobs
- **Where:** 6 jobs, 3 programs, 3 schedules in `src/oracle/11-jobs-scheduler.sql`
- **PostgreSQL:** `pg_cron` on Azure Database for PostgreSQL flexible server, or an external
  scheduler (Azure Functions, Logic Apps, a container job).
- **Prediction:** **review task**
- **Why hard:** `pg_cron` is a different model — no programs, no argument metadata, no job
  classes, no chains, and it runs in the `postgres` database by default with a `cron.database_name`
  setting to point elsewhere. Calendaring syntax differs (`FREQ=MONTHLY;BYMONTHDAY=1` versus a
  cron expression). Expect one-to-one job mapping to be straightforward and everything about
  arguments, dependencies and failure handling to be manual.

### H-15 · Materialised views with fast refresh and a refresh group
- **Where:** 6 MVs, 3 MV logs, refresh group `rg_reporting`; `mv_sales_daily_store` is
  `FAST ON COMMIT`
- **PostgreSQL:** `MATERIALIZED VIEW` with `REFRESH MATERIALIZED VIEW [CONCURRENTLY]`.
- **Prediction:** **review task**
- **Why hard:** PostgreSQL has **no incremental refresh at all** and **no refresh groups**. Every
  refresh is a full recompute. `FAST ON COMMIT` has no analogue whatsoever — the closest thing is
  a trigger-maintained summary table, which is a rewrite, not a conversion. `CONCURRENTLY`
  requires a unique index on the MV and still costs a full scan. The transactional consistency a
  refresh group guarantees across several MVs must be rebuilt as a single transaction wrapping
  several `REFRESH` statements. The MV logs (`MLOG$_*`) become dead objects to be dropped.

### H-16 · Function-based indexes
- **Where:** 9 of them, including `fbi_customer_email_lower` on `LOWER(email)`,
  `fbi_product_sku_norm` on `fn_normalise_sku(sku)`, and the unique FBI on
  `inventory_location (NVL(warehouse_id,0), NVL(store_id,0), location_code)`
- **PostgreSQL:** expression indexes — same idea, same syntax shape.
- **Prediction:** **partial**
- **Why hard:** the built-in expressions convert cleanly. The one over `fn_normalise_sku` does
  not, because PostgreSQL requires the function to be marked `IMMUTABLE` to be indexable, and the
  converter must decide whether the Oracle `DETERMINISTIC` marking justifies that — Oracle's
  `DETERMINISTIC` is a promise the database does not verify, and PostgreSQL's `IMMUTABLE` is one
  it takes very seriously. Any function touching `SYSDATE`, `NLS` settings, or another table
  cannot be `IMMUTABLE`, and the index must be redesigned.

### H-17 · Virtual columns
- **Where:** `product.margin_pct`, `address.normalised_key`, `employee.full_name`,
  `employee.is_active`, `inventory_stock.qty_available`, `sales_order.order_total`,
  `sales_order_line.line_total`, `purchase_order_line.line_total`, `gl_journal_line.base_amount`
- **PostgreSQL:** `GENERATED ALWAYS AS (…) STORED`.
- **Prediction:** **partial**
- **Why hard:** Oracle virtual columns are computed on read; PostgreSQL generated columns are
  `STORED` only (no `VIRTUAL` before PG 18), so they consume disk and are computed on write.
  More importantly, PostgreSQL requires the expression to be immutable and to reference only
  columns of the same row — `address.normalised_key` is fine, but any virtual column calling a
  user function or referencing `SYSDATE` must become a view column or a trigger-maintained real
  column. `employee.is_active` derives from `termination_date` only, so it survives.

### H-18 · Index-organized tables
- **Where:** `calendar_day`, `return_reason`, `app_parameter`
- **PostgreSQL:** an ordinary heap table with a primary key; optionally `CLUSTER` on that index.
- **Prediction:** **clean**
- **Why hard:** the DDL converts trivially — `ORGANIZATION INDEX` is simply dropped. What is lost
  is the physical guarantee: `CLUSTER` in PostgreSQL is a one-time reorganisation that decays as
  rows are updated, not a permanent structure. For three small lookup tables this is irrelevant,
  which is why they were chosen. Flag it in the report anyway so the reader learns the difference
  before applying the same reasoning to a large IOT.

### H-19 · Range-partitioned tables
- **Where:** `purchase_order` (`INTERVAL` monthly), `sales_order` (`INTERVAL` 30-day),
  `inventory_movement` (range + list subpartition)
- **PostgreSQL:** declarative range partitioning, with `pg_partman` for automatic partition
  creation.
- **Prediction:** **partial**
- **Why hard:** the shape converts. Oracle's `INTERVAL` clause — partitions materialising on
  demand at first insert — does not exist in PostgreSQL and is what `pg_partman` is for, which
  means `pg_partman` must be allowlisted *and* in `shared_preload_libraries` *and* the server
  restarted, plus a background-worker configuration. Composite range+list subpartitioning becomes
  nested partitioning, which works but doubles the object count on the target.
  **The sharp edge:** `sales_order` and `purchase_order` have primary keys that do **not** include
  the partition key. Oracle supports this with a global index; PostgreSQL flatly requires every
  unique constraint on a partitioned table to include all partition columns. There is no
  workaround that preserves both the key and the partitioning — expect to widen the PK to
  `(order_id, order_ts)` and fix every foreign key that referenced it. This is the single most
  disruptive item in the entire lab, and it is deliberately placed on the two busiest tables.

### H-20 · List-partitioned tables
- **Where:** `loyalty_transaction` (by `txn_type`), and the subpartitioning on
  `inventory_movement`
- **PostgreSQL:** declarative list partitioning.
- **Prediction:** **clean**
- **Why hard:** it mostly is not. Two residues: Oracle's `DEFAULT` partition becomes PostgreSQL's
  `DEFAULT` partition (fine), and `PARTITION BY REFERENCE` on `sales_order_line` — inheriting the
  parent's partitioning through the foreign key — has no PostgreSQL equivalent at all. That one
  is a **review task**: the child must be independently partitioned on a copied `order_ts`
  column, which means denormalising the partition key onto the line table.

### H-21 · Global temporary tables
- **Where:** `gtt_price_calc`, `gtt_order_stage` (`ON COMMIT DELETE ROWS`),
  `gtt_replenishment` (`ON COMMIT PRESERVE ROWS`)
- **PostgreSQL:** `CREATE TEMPORARY TABLE … ON COMMIT DELETE ROWS / PRESERVE ROWS`.
- **Prediction:** **partial**
- **Why hard:** the semantics differ in a way that bites. An Oracle GTT is a permanent object
  whose *data* is session-private; a PostgreSQL temp table is created per session at runtime.
  That means every function using one must create it first (or the application must, at connect
  time), the object vanishes from the catalogue so views over it break, and repeated
  create/drop churns `pg_catalog` and can bloat it under high connection turnover. The usual
  production answer is an unlogged permanent table keyed by session id, which is a redesign.
  `pg_catalog` bloat from temp-table churn is a real operational surprise worth showing.

### H-22 · Sequences with `NOCACHE` and `CYCLE`
- **Where:** `seq_audit_id` and `seq_error_id` are `NOCACHE` (gap-free-ish audit numbering);
  `seq_rma_cycle` is `CYCLE MAXVALUE 999999 NOCACHE`; the other 21 are ordinary `CACHE 20`
- **PostgreSQL:** `CREATE SEQUENCE … CACHE 1 / CYCLE MAXVALUE …`.
- **Prediction:** **clean**
- **Why hard:** syntax maps one-to-one. The operational difference matters though: PostgreSQL
  sequence cache is *per session*, so `CACHE 20` scatters values across concurrent sessions far
  more visibly than Oracle's shared cache. `NOCACHE` is the safe conversion for anything where
  ordering is assumed, at a throughput cost. Also worth noting for the reader: an Oracle sequence
  used in a column `DEFAULT` is best converted to `GENERATED BY DEFAULT AS IDENTITY`, but doing so
  changes `INSERT` behaviour for explicit values — we keep explicit sequences to avoid muddying
  the comparison.

### H-23 · `DETERMINISTIC` functions
- **Where:** `fn_fiscal_period`, `fn_working_days_between`, `fn_tier_for_points`,
  `fn_normalise_sku`, `pkg_catalog.category_depth`
- **PostgreSQL:** `IMMUTABLE` (or `STABLE` where the function reads tables).
- **Prediction:** **partial**
- **Why hard:** the words look equivalent and are not. Oracle's `DETERMINISTIC` is an unverified
  promise used for query rewrite and function-based indexes. PostgreSQL's `IMMUTABLE` is enforced
  by the planner in ways that silently produce wrong answers if you lie — constant-folded at plan
  time, cached across statements. `fn_tier_for_points` reads `loyalty_tier`, so it is
  `DETERMINISTIC` in Oracle but must be `STABLE`, never `IMMUTABLE`, in PostgreSQL. A converter
  that maps `DETERMINISTIC → IMMUTABLE` mechanically introduces a real bug. Check every one.

### H-24 · `RESULT_CACHE` functions
- **Where:** `fn_convert_amount` (`RESULT_CACHE RELIES_ON (exchange_rate)`),
  `pkg_pricing.cached_base_price`, `pkg_fx.rate_for`
- **PostgreSQL:** nothing. No server-side result cache exists.
- **Prediction:** **review task**
- **Why hard:** the clause is simply dropped, and the function still compiles and returns correct
  answers — so this fails *quietly*, as a performance regression discovered in load testing rather
  than an error at conversion time. `RELIES_ON` dependency invalidation has no analogue at all.
  Options: mark `STABLE` and rely on per-statement caching, add an application cache, or
  materialise the lookup. Predicting "clean compile, worse performance" is exactly the kind of
  finding the lab should surface.

### H-25 · Triggers of every timing
- **Where:** 26 triggers — `BEFORE`/`AFTER`, row and statement level, `INSERT`/`UPDATE`/`DELETE`
  and combinations, one with a `WHEN` clause, one pair using `FOLLOWS`
- **PostgreSQL:** `CREATE TRIGGER` plus a separate `CREATE FUNCTION … RETURNS TRIGGER`.
- **Prediction:** **partial**
- **Why hard:** every Oracle trigger becomes *two* PostgreSQL objects, so the object count grows.
  Statement-level triggers cannot see `NEW`/`OLD` in PostgreSQL without transition tables
  (`REFERENCING NEW TABLE AS …`). `:NEW`/`:OLD` become `NEW`/`OLD`. A `BEFORE` row trigger must
  `RETURN NEW` or the row silently vanishes — the most common conversion bug in this whole
  category. `FOLLOWS` has no equivalent; PostgreSQL fires triggers in *name* order, so
  `trg_ar_gl_journal_line_a`/`_b` happen to work by luck, which is worth pointing out loudly.

### H-26 · Compound triggers
- **Where:** `trg_cmp_inventory_stock`, `trg_cmp_sales_order_line`, `trg_cmp_loyalty_txn`
- **PostgreSQL:** a `FOR EACH STATEMENT` trigger using transition tables, or a pair of triggers
  sharing state.
- **Prediction:** **review task**
- **Why hard:** the hardest trigger shape in the lab. Oracle's compound trigger exists to dodge
  the mutating-table error by buffering rows across the four timing points in shared state.
  PostgreSQL has no mutating-table restriction, so the entire *reason* for the pattern is gone —
  the right conversion is usually to collapse it into one statement-level `AFTER` trigger over a
  transition table, which is a rewrite the tool cannot infer. A mechanical conversion into three
  separate triggers loses the shared collection and is simply broken.

### H-27 · `INSTEAD OF` triggers
- **Where:** on `v_customer_360`, `v_product_sellable`, `v_open_purchase_orders`
- **PostgreSQL:** `INSTEAD OF` triggers on views — same concept, same name.
- **Prediction:** **clean**
- **Why hard:** genuinely close to a one-to-one mapping, with the same `RETURN NEW` requirement
  as H-25. Included because the reader needs at least one trigger case that works, and because it
  contrasts nicely with H-26 firing in the same schema.

### H-28 · User-defined exceptions and `RAISE_APPLICATION_ERROR`
- **Where:** `pkg_order_capture` (`e_basket_empty`, `e_insufficient_stock`, `e_price_expired`),
  `pkg_purchasing` (`e_po_already_sent`), `pkg_finance_gl` (`e_period_closed`)
- **PostgreSQL:** `RAISE EXCEPTION … USING ERRCODE = 'P0001'` and custom `SQLSTATE` values.
- **Prediction:** **partial**
- **Why hard:** the raise converts. What does not is the *number*: Oracle application errors live
  in `-20000..-20999` and callers switch on `SQLCODE`. PostgreSQL uses five-character `SQLSTATE`
  strings. Every caller — including code outside this repo — needs remapping, and you need a
  documented, stable Oracle-number-to-SQLSTATE table or you will lose the mapping halfway through
  the project. Build that table early; `docs/03-run-ai-migration.md` section 8 should include it.

### H-29 · `PRAGMA EXCEPTION_INIT`
- **Where:** `pkg_error` binds `-1` (`dup_val_on_index` variants), `-2291`/`-2292` (FK violations),
  `-1400` (NOT NULL), `-54` (resource busy) to named exceptions
- **PostgreSQL:** catch the equivalent condition names — `unique_violation`,
  `foreign_key_violation`, `not_null_violation`, `lock_not_available`.
- **Prediction:** **partial**
- **Why hard:** the named conditions exist and are readable, so this converts better than it
  looks. The gap is coverage: not every `ORA-` number has a PostgreSQL condition, several Oracle
  numbers collapse onto one PostgreSQL condition (losing the distinction between parent-key and
  child-key FK violations, `-2291` vs `-2292`), and code that re-raised by number needs rework.
  `pkg_error` distinguishes those two on purpose.

### H-30 · `ROWNUM` versus `ROW_NUMBER()`
- **Where:** `pkg_pricing.pick_winning_price` (classic `WHERE ROWNUM = 1` after an `ORDER BY` in
  an inline view), `pkg_finance_gl.next_batch` (`ROWNUM <= :n`), `v_sales_by_store_day`
  (`ROW_NUMBER() OVER (…)`)
- **PostgreSQL:** `LIMIT`/`FETCH FIRST n ROWS ONLY` for `ROWNUM`; `ROW_NUMBER()` is identical.
- **Prediction:** **partial**
- **Why hard:** the two look alike and behave differently, which is the whole point of putting
  both in. `ROWNUM` is assigned *before* `ORDER BY`, so `SELECT … WHERE ROWNUM <= 10 ORDER BY x`
  returns an arbitrary ten rows sorted — while the naive conversion to `ORDER BY x LIMIT 10`
  returns the *top* ten. Those are different result sets and both are plausible-looking. A
  converter that gets this right on the wrapped-inline-view form may still get it wrong on the
  unwrapped form. We include both forms.

### H-31 · `NVL`, `NVL2`, `DECODE`
- **Where:** throughout; concentrated in `pkg_customer`, `pkg_pricing`, `v_legacy_orders`, and
  the unique FBI on `inventory_location`
- **PostgreSQL:** `COALESCE`, `CASE WHEN … IS NOT NULL THEN … ELSE … END`, `CASE`/`DECODE` via
  orafce.
- **Prediction:** **clean**
- **Why hard:** mechanically easy, with two footguns. `NVL` evaluates both arguments; `COALESCE`
  short-circuits — usually an improvement, occasionally a behaviour change if the second argument
  had side effects or raised. And `DECODE` treats `NULL = NULL` as a match, which `CASE x WHEN`
  does not; the correct conversion needs `IS NOT DISTINCT FROM` or an explicit null branch.
  `pkg_customer` has a `DECODE` with a `NULL` search key precisely to catch this.

### H-32 · Oracle outer-join `(+)` syntax
- **Where:** `v_legacy_orders` end to end, plus three queries in `pkg_reporting` and roughly 30
  generated views
- **PostgreSQL:** ANSI `LEFT OUTER JOIN` / `RIGHT OUTER JOIN`.
- **Prediction:** **partial**
- **Why hard:** simple cases convert reliably. The hard ones are where `(+)` appears on some but
  not all predicates for the same table, where it appears in a `WHERE` clause mixed with
  non-join filters (Oracle applies the filter *before* the outer join if `(+)` is on it and
  *after* if not — the classic source of "why did my rows disappear"), and where three or more
  tables chain outer joins whose ANSI ordering is not the textual ordering. `v_legacy_orders`
  contains one of each. Verify converted row counts, do not eyeball the SQL.

### H-33 · `LONG` columns
- **Where:** `store.legacy_migration_notes` — the schema's only `LONG`
- **PostgreSQL:** `text`.
- **Prediction:** **partial**
- **Why hard:** the target type is obvious; getting the data out is not. `LONG` cannot be used in
  most SQL expressions, cannot be selected across a database link, and is unreadable by many
  drivers — which is why Oracle deprecated it decades ago. Data movement tools frequently choke.
  `pkg_utils` includes a `TO_LOB` conversion helper for exactly this reason, and
  `docs/04-migrate-data.md` must call out that the `LONG` column may need a pre-migration
  `ALTER TABLE … MODIFY … CLOB` on the source. One column, disproportionate pain — realistic.

### H-34 · `CLOB` and `BLOB` columns
- **Where:** `product.long_description`, `product.primary_image`, `customer.notes`,
  `address.geo_json`, `audit_log.old_row`/`new_row`, `error_log.error_backtrace`/`call_stack`
- **PostgreSQL:** `text` for CLOB, `bytea` for BLOB.
- **Prediction:** **clean**
- **Why hard:** the type mapping is trivial. The residue is `DBMS_LOB` calls — `GETLENGTH`,
  `SUBSTR`, `INSTR`, `APPEND`, `WRITEAPPEND` — which orafce covers partially, and locator
  semantics, which it does not: Oracle LOB locators are mutable handles, PostgreSQL `text`/`bytea`
  are values. Code that opened a locator and wrote through it needs restructuring. Also note
  `bytea` has a 1 GB hard limit versus BLOB's 128 TB — irrelevant for product images, worth
  stating.

### H-35 · `XMLTYPE` columns
- **Where:** `product.spec_sheet`, `promotion.rule_xml`; queried with `XMLTABLE` and `XMLQUERY`
  in `pkg_promotion.evaluate_rule` and `pkg_catalog.spec_attribute`
- **PostgreSQL:** the `xml` type, with `xpath()`, `xmltable()` and `xpath_exists()`.
- **Prediction:** **partial**
- **Why hard:** `XMLTABLE` exists in both and the basic shape survives. Oracle's XML support is
  far deeper: `XMLQUERY` with `PASSING`/`RETURNING CONTENT`, XML schema registration, structured
  storage, `XMLIndex`, and `.extract()`/`.getStringVal()` method syntax on the type all lack
  equivalents. `pkg_promotion` uses `XMLQUERY … RETURNING CONTENT` and method-call syntax on
  purpose. A pragmatic alternative worth discussing in the findings: convert to `jsonb`, which is
  what a greenfield PostgreSQL design would use, at the cost of changing every consumer.

### H-36 · `INTERVAL` types
- **Where:** `store.opening_offset`/`closing_offset`/`refit_cycle`, `supplier.lead_time`,
  `carrier.cutoff_offset`, `loyalty_tier.review_interval`, `shipment.transit_time`,
  `job_run_log.elapsed`; arithmetic in `pkg_store_ops`
- **PostgreSQL:** `interval`.
- **Prediction:** **partial**
- **Why hard:** PostgreSQL has one `interval` type; Oracle has two incompatible ones
  (`YEAR TO MONTH` and `DAY TO SECOND`) that cannot be mixed. Converting both to `interval`
  *permits* expressions Oracle rejected, so latent bugs become possible rather than impossible.
  Precision qualifiers (`DAY(3) TO SECOND(0)`) are not enforceable in PostgreSQL the same way.
  `NUMTODSINTERVAL`/`NUMTOYMINTERVAL` become `make_interval` or multiplication. And PostgreSQL's
  `justify_interval` normalisation differs from Oracle's, so `elapsed` values may format
  differently even when they compare equal.

### H-37 · `TIMESTAMP WITH LOCAL TIME ZONE`
- **Where:** 24 columns across `customer`, `sales_order`, `promotion`, `loyalty_transaction`,
  `audit_log`, `error_log`, `job_run_log` and others; `fn_store_local_time` converts to store
  local time using `country.tz_name`
- **PostgreSQL:** `timestamptz`.
- **Prediction:** **partial**
- **Why hard:** superficially a clean mapping — both store UTC internally and render in the
  session zone. The differences bite in a multi-country retailer. Oracle normalises to the
  *database* time zone on storage and renders in the *session* zone; PostgreSQL stores UTC and
  renders in `TimeZone`. `TIMESTAMP WITH TIME ZONE` in Oracle preserves the original offset,
  which `timestamptz` does not — if any column ever needs the *original* offset back, it must
  become two columns. `SYSTIMESTAMP` → `clock_timestamp()`, `CURRENT_TIMESTAMP` →
  `transaction_timestamp()`, and Oracle's `SYSDATE` is *not* `now()` — it is the server host
  time in the server zone with no zone attached. Getting `DBTIMEZONE`/`SESSIONTIMEZONE` wrong
  moves every timestamp in the database by hours, silently.

### H-38 · Empty string is NULL
- **Where:** `pkg_customer.upsert_customer` relies on it (`''` assigned to `mobile_phone` becomes
  `NULL` and satisfies a `NOT NULL`-adjacent check differently); `v_legacy_orders` has
  `WHERE line2 IS NOT NULL` predicates whose meaning changes
- **PostgreSQL:** `''` and `NULL` are distinct values. There is no setting to change this.
- **Prediction:** **review task**
- **Why hard:** this is the most insidious item on the list because *nothing fails*. Every
  statement compiles, every function runs, and a subset of rows quietly lands on the other side
  of a `IS NULL` test. `COUNT(col)`, unique constraints, `COALESCE` chains and `||` concatenation
  all shift. There is no automated fix — the only honest approaches are to normalise `''` to
  `NULL` on load and add `CHECK (col <> '')` constraints, or to audit every predicate. The lab
  should show a concrete row-count divergence, not just describe one.

### H-39 · `SYS_CONTEXT` and application contexts
- **Where:** namespace `CONTOSO_APP_CTX` created in `src/oracle/12-security-context.sql`, set only by
  `pkg_security_ctx`; read in `audit_log` column defaults, `purchase_order.created_by`, and every
  VPD predicate
- **PostgreSQL:** session-level `SET`/`current_setting('app.user', true)` custom GUCs, or
  `set_config()`.
- **Prediction:** **partial**
- **Why hard:** `SYS_CONTEXT('USERENV', …)` mostly maps — `SESSION_USER` → `session_user`,
  `CLIENT_IDENTIFIER` → an application GUC, `IP_ADDRESS` → `inet_client_addr()`. Custom
  namespaces are the problem: Oracle contexts are *trusted*, settable only by a named package,
  so application code cannot forge them. A PostgreSQL GUC can be set by anyone in the session
  with a plain `SET`. Since these values drive the VPD predicates (H-40), converting them to
  ordinary GUCs converts a security control into a suggestion. The honest conversion pushes the
  identity into the connection role and uses `current_user`, which means connection pooling has
  to change too.

### H-40 · Virtual Private Database policies
- **Where:** `DBMS_RLS.ADD_POLICY` on `customer` (and on `sales_order` for `SELECT` only), with
  predicates from `pkg_vpd_policy` keyed on `CONTOSO_APP_CTX`
- **PostgreSQL:** Row-Level Security — `ALTER TABLE … ENABLE ROW LEVEL SECURITY` plus `CREATE POLICY`.
- **Prediction:** **review task**
- **Why hard:** the concepts align but the mechanisms do not. VPD predicates are generated by a
  PL/SQL function returning a `WHERE` fragment as *text*, evaluated per statement; RLS policies
  are fixed boolean expressions. Dynamic predicate construction has to become a static expression
  calling a `STABLE` function. Policy types (`STATIC`, `SHARED_STATIC`, `CONTEXT_SENSITIVE`) have
  no analogue. RLS is bypassed by the table owner and by `BYPASSRLS` roles unless you set
  `FORCE ROW LEVEL SECURITY` — a default that has burned people. And per H-39, the identity the
  policy trusts is now forgeable unless the role model changes. Treat the whole of H-39 plus
  H-40 as one security workstream, not two conversion items.

### H-41 · The synonym layer
- **Where:** 24 hand-written private synonyms plus 150 generated ones; three flavours (table
  alias, package alias, and one deliberately dangling)
- **PostgreSQL:** no synonyms. Use `search_path`, a view, or a wrapper function.
- **Prediction:** **partial**
- **Why hard:** table synonyms become views or are absorbed into `search_path`. Package synonyms
  have no equivalent because the package became a schema — you would need a schema alias, which
  does not exist. The dangling synonym is the interesting one: Oracle happily holds a synonym to
  a dropped object and fails only at use, so the converter must decide between emitting a broken
  view, skipping it silently, or reporting it. Which of those three it does tells you a lot about
  how it will behave on a real legacy schema, where dangling synonyms are common.

### H-42 · Pipelined table functions
- **Where:** `fn_order_line_count`, `fn_split_csv`; consumed via `TABLE(...)` in views and PL/SQL
- **PostgreSQL:** `RETURNS SETOF` / `RETURNS TABLE` with `RETURN QUERY` or `RETURN NEXT`.
- **Prediction:** **partial**
- **Why hard:** the shape maps well but the streaming does not. Oracle `PIPE ROW` yields
  incrementally; PL/pgSQL `RETURN NEXT` materialises the whole set in a tuplestore before the
  caller sees anything, so memory profile and time-to-first-row both change. `TABLE(f(x))`
  becomes a plain `f(x)` in the `FROM` clause, and correlated `TABLE(f(t.col))` needs
  `LATERAL` — which a mechanical converter often misses, producing a query that either fails to
  parse or, worse, silently cross-joins.

### H-43 · Package-level session state
- **Where:** `pkg_security_ctx.g_current_app_user`, `pkg_pricing.g_price_cache` (an associative
  array), `pkg_utils.g_nls_numeric`
- **PostgreSQL:** custom GUCs via `set_config`, a temporary table, or a session-keyed unlogged
  table.
- **Prediction:** **review task**
- **Why hard:** PostgreSQL functions have no persistent package state — every call starts clean.
  Oracle package globals live for the session and are a common (if unwise) caching idiom. The
  associative array in `pkg_pricing` is the awkward one: there is no session-scoped map, so it
  becomes a temp table (bringing H-21's problems) or the cache is dropped entirely (bringing
  H-24's performance problem). Converters typically emit the variable declaration inside the
  function, which compiles and quietly resets the cache on every call.

### 9.1 Prediction summary

| Prediction | Count | Cases |
| --- | ---: | --- |
| **Clean** | 10 | H-04, H-07, H-08, H-12, H-18, H-20, H-22, H-27, H-31, H-34 |
| **Partial** | 21 | H-01, H-06, H-09, H-10, H-11, H-16, H-17, H-19, H-21, H-23, H-25, H-28, H-29, H-30, H-32, H-33, H-35, H-36, H-37, H-41, H-42 |
| **Review task** | 12 | H-02, H-03, H-05, H-13, H-14, H-15, H-24, H-26, H-38, H-39, H-40, H-43 |

Roughly a quarter clean, half needing verification, a quarter needing a human. If a run comes
back dramatically better than that, check whether `plpgsql_check` was actually allowlisted before
celebrating (section 11.2) — a fail-open validator makes everything look easy.

---

## 10. Additional traps

Not on the mandated list, cheap to include, and each has cost somebody a weekend.

| ID | Trap | Where | Note |
| --- | --- | --- | --- |
| T-01 | `NUMBER` without precision | `audit_log.error_code`, several generated columns | Becomes `numeric` with no bound — correct but slow. `NUMBER(9)` should become `integer`, not `numeric(9)`, and only a human knows which. |
| T-02 | `DATE` carries a time component | `purchase_order.order_date`, `gl_journal.journal_date` | Oracle `DATE` is a timestamp to the second. Converting to PostgreSQL `date` silently truncates; `timestamp` is usually right. |
| T-03 | `VARCHAR2` semantics | everywhere | `VARCHAR2(30)` is bytes by default, `CHAR(30 CHAR)` is characters. Multi-byte country names overflow after conversion if the length was byte-sized. |
| T-04 | `CHAR` blank padding | `country_code CHAR(2)`, `currency_code CHAR(3)` | Oracle blank-pads and compares with blank-padding semantics; PostgreSQL `char(n)` does too but `text` comparison does not. Joins can stop matching. |
| T-05 | `DUAL` | ~40 places | `SELECT … FROM dual` — orafce provides `dual`, otherwise drop the `FROM`. |
| T-06 | Optimiser hints | `pkg_replenishment`, `v_stock_position` | `/*+ INDEX(...) */`, `/*+ PARALLEL(4) */` are comments to PostgreSQL — silently ignored, no error, different plan. |
| T-07 | Quoted mixed-case identifier | one table, `"StoreAudit_Legacy"` | Oracle folds unquoted to upper, PostgreSQL to lower. A quoted identifier survives conversion as `"StoreAudit_Legacy"` and every unquoted reference then fails. |
| T-08 | `ROWID` | `sp_purge_audit_log` deletes by `ROWID` | `ctid` is not stable across `UPDATE` or `VACUUM FULL`. Must become a real key. |
| T-09 | `SYSDATE` vs `now()` | throughout | `SYSDATE` is host time with no zone; `now()` is transaction start in the session zone. Also `SYSDATE` does not advance within a statement, `clock_timestamp()` does. |
| T-10 | Implicit type conversion | `pkg_data_quality` compares a `VARCHAR2` to a `NUMBER` | Oracle converts silently; PostgreSQL errors. This one at least fails loudly. |
| T-11 | `INSERT ALL` / `INSERT FIRST` | `pkg_finance_gl.post_journal` | No PostgreSQL equivalent; becomes a CTE with multiple `INSERT`s, or separate statements. |
| T-12 | `FOR UPDATE SKIP LOCKED` | `pkg_fulfilment.claim_next_pick` | Supported in both, but Oracle and PostgreSQL differ on how many rows are skipped under contention — throughput characteristics change. |
| T-13 | `NULL` sort order | ordering in `pkg_reporting` | Oracle sorts `NULL` last ascending; PostgreSQL sorts `NULL` last ascending too, but *first* descending in Oracle and last in PostgreSQL is reversed. Add explicit `NULLS FIRST`/`NULLS LAST`. |
| T-14 | String concatenation with `NULL` | `t_postal_address.format_label` | Both treat `'a' \|\| NULL` as `NULL`, but Oracle's `''` being `NULL` (H-38) changes which operands are null. |

---

## 11. Tooling facts, conflicts and gotchas

Everything in this section was verified on 2026-09-02. Where upstream Microsoft sources
contradict each other, the conflict is recorded rather than resolved — do not quietly pick a side.

### 11.1 The supported path

The conversion is a feature of the **PostgreSQL extension for Visual Studio Code**,
`ms-ossdata.vscode-pgsql`, publisher Microsoft. Schema conversion **GA from v1.23.0
(2026-05-26)**. Application/code conversion (`.sql`, `.ctl`, `.sh`, `.load`, `.java`) is
**public preview**. It is powered by a **Microsoft Foundry** LLM deployment plus **GitHub Copilot
agent mode** for resolving flagged review tasks, and needs a Copilot **Pro+, Business or
Enterprise** seat.

**Do not mention as current** anywhere in this repo: Azure Data Studio (retired 28 Feb 2026);
SSMA for Oracle (SQL Server family only, PostgreSQL is not a target); Azure DMS (does not support
Oracle → PostgreSQL at all); the in-portal "Migration service in Azure Database for PostgreSQL"
(PostgreSQL sources only). Do not deep-link the learn.microsoft.com ora2pg how-to page — it now
301-redirects.

### 11.2 The two gotchas that will silently ruin a run

**`plpgsql_check` is fail-open.** If it is not allowlisted via `azure.extensions`, the tool skips
its deeper validation with no error and no warning in the report. You get a clean-looking result
that was never checked. `scripts/status.sh` must report it in red when it is absent, and the
lab must allowlist it *before* the first run — not after, or the first report is worthless.

**`pg_catalog` is always searched first.** `to_char`, `to_date` and `substr` resolve to the
PostgreSQL builtins, not to orafce's Oracle-compatible versions. Call `oracle.to_char(...)`
explicitly where Oracle semantics matter, and set the **database-level** `search_path` to include
`oracle`, `topology`, `tiger` and the `dbms_*`/`plv*`/`utl_file` schemas — see `PG_SEARCH_PATH`
in `.env.example`. This one produces subtly wrong formatted output rather than an error.

### 11.3 Extensions to allowlist

Via the `azure.extensions` server parameter, on **both** the target and the scratch server:
`orafce`, `uuid-ossp`, `pgcrypto`, `pg_trgm`, `postgis` (+ `postgis_topology`,
`postgis_tiger_geocoder`), `pg_partman`, `pg_stat_statements`, `plpgsql_check`, and `dblink`.

`dblink` is only needed if the source uses `PRAGMA AUTONOMOUS_TRANSACTION` — **CONTOSO does**
(H-02) — and it is needed on the **target**, not just scratch. `pg_partman`,
`pg_stat_statements` and `plpgsql_check` additionally need `shared_preload_libraries` and a
server **restart**.

### 11.4 Scratch and target databases

The scratch database **must** be Azure Database for PostgreSQL **flexible server, PostgreSQL 15+**.
**Azure HorizonDB is explicitly not supported as the scratch database** (it *is* supported as a
target from v1.27.x). The tool creates and drops schemas prefixed `_mig_scratch_`, so give it its
own database. PG 15 is also our floor for `MERGE` (H-07).

### 11.5 Oracle source prerequisites

Documented supported versions: **12.1, 12.2, 18c, 19c, 21c**. **Discrepancy:** Microsoft's own
`mslearn-postgresql` lab deploys **Oracle Database Free 23ai**, which is not on that list. This
lab defaults to 23ai for convenience and makes `ORACLE_IMAGE` a variable so you can pin 19c/21c
to stay inside the supported matrix. Say this plainly in `docs/02-seed-oracle.md`;
do not pretend 23ai is supported.

Grants for the reader account (`O2P_READER`): `CONNECT`, plus `SELECT_CATALOG_ROLE` **or**
`SELECT ANY DICTIONARY`, plus `SELECT` on `SYS.ARGUMENT$`. The Oracle `sessions` parameter must
be **> 10**. The tool reads metadata only — it never writes to Oracle and needs no access to
application tables.

### 11.6 Model and RBAC conflicts

**Model.** Learn docs state the Foundry deployment must be **`gpt-5.2`**. Microsoft's own lab ARM
template defaults to **`gpt-5-mini`**. We make it the `FOUNDRY_MODEL_NAME` parameter, default to
`gpt-5.2` per Learn, and document `gpt-5-mini` as what the official sample actually deploys.
`gpt-5.2` is **verified deployable in `swedencentral`** — the 2026-09-02 deployment created it at
version `2025-12-11` — so the remaining disagreement is only which model to *use*, not whether the
Learn-documented one exists. Availability still varies by region, so `preflight.sh` checks it.
Recommended quota: **500,000 TPM** — below that, a ~1,820-object schema throttles badly.

**RBAC.** Current Microsoft Foundry docs name the role **"Foundry User"**. DP-300 lab 18 says
**"Cognitive Services OpenAI User"**. This conflict is unresolved. Tell the reader to grant
whichever their portal offers, and mention both.

### 11.7 Client and network

VS Code **1.95.2+**. Windows x64, Linux x64, macOS 13+. **ARM64 is not supported on Windows or
Linux.** The overview page's thick-client section also claims "Windows and Linux only", so Apple
Silicon is risky — `CLIENT_PLATFORM=jumpbox` is the default and builds a Windows x64 VM.

Outbound egress required: the Foundry endpoint, the VS Code Marketplace, GitHub Copilot services,
and **`https://github.com/microsoft/pgsql-tools/`**. That last one is easy to miss and produces a
confusing failure behind a restrictive firewall.

### 11.8 The gap the tool does not fill

**The tool converts schema and code only. It does not copy table rows.** Any end-to-end story
needs a separate data step — `ora2pg`, `pgloader`, or a partner CDC tool — and
`docs/04-migrate-data.md` must say so in its first paragraph. This lab uses `ora2pg`
(`DATA_MOVE_TOOL`), and H-33's `LONG` column is the reason that step is not trivial either.

---

## 12. Verification

`src/oracle/99-verify-objects.sql` asserts the object floor:

```sql
SELECT COUNT(*) AS object_count
  FROM user_objects
 WHERE object_type NOT IN ('LOB','TABLE PARTITION','INDEX PARTITION','LOB PARTITION');
-- must be >= 1000 (the floor); 1110 is the per-type design budget; a loaded schema runs ~1,820
```

It also asserts, and fails the build on any of these:

1. Zero objects with `status = 'INVALID'` in `user_objects`.
2. Every hard case H-01..H-43 present, via a checklist query over `user_source`,
   `user_tab_columns`, `user_part_tables`, `user_triggers`, `user_types`, `user_policies`,
   `user_scheduler_jobs` and `user_mviews`. A construct nobody can find is a construct the
   converter was never asked about.
3. The generated object count matches `GEN_OBJECT_TARGET` exactly — drift means the generator
   is non-deterministic and cross-run diffs are meaningless.
4. Referential integrity: no orphan rows across all foreign keys after seeding.

`tests/` then runs the same business questions against Oracle and against converted PostgreSQL
and diffs the answers. Row-count and checksum equality on the H-30, H-32 and H-38 queries is the
real test — those three are where a conversion looks correct and is not.

### 12.1 Recording results

`docs/05-validate.md` section 6 carries one row per hard case: predicted outcome, observed outcome,
whether the tool flagged it, whether Copilot agent mode fixed it, and how long the human fix
took. Where prediction and observation disagree, correct section 9 in the same pull request.
The lab is worth more as an honest record than as a demo.





