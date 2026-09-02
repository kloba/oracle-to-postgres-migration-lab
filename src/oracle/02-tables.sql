--------------------------------------------------------------------------------
-- Contoso Store -- Oracle to Azure Database for PostgreSQL migration lab
-- 02-tables.sql
--
-- The structural layer: 45 core tables (design.md section 5, subject areas A-J),
-- 5 operational/audit tables (section K), 3 global temporary tables (section L),
-- and the one deliberately quoted mixed-case table from trap T-07. The two
-- nested-table storage tables (section M) are created implicitly by the
-- NESTED TABLE ... STORE AS clauses on product and loyalty_tier.
--
-- Runs as CONTOSO, after 01-types.sql, before 03-constraints.sql.
--
-- Deliberate structure, per the design contract:
--   * purchase_order   RANGE + INTERVAL by month on a DATE key            (H-19)
--   * sales_order      RANGE + INTERVAL 30-day on a TSLTZ key             (H-19)
--   * sales_order_line PARTITION BY REFERENCE off sales_order             (H-20)
--   * inventory_movement composite RANGE INTERVAL + LIST subpartition     (H-19/20)
--   * loyalty_transaction LIST partitioned by txn_type                    (H-20)
--   * calendar_day / return_reason / app_parameter ORGANIZATION INDEX     (H-18)
--   * 9 virtual columns                                                   (H-17)
--   * product carries CLOB + BLOB + XMLTYPE + nested table + VARRAY  (H-34/35/04/05)
--   * store carries the schema's only LONG column                         (H-33)
--   * INTERVAL and TIMESTAMP WITH LOCAL TIME ZONE throughout        (H-36/H-37)
--   * audit_log is shaped for the autonomous-transaction writer pkg_audit (H-02)
--
-- Almost every constraint lives in 03-constraints.sql, so the circular foreign
-- key region -> employee -> store -> region can be applied after all tables
-- exist (design section 4.2). Three exceptions are unavoidable and are marked
-- inline below: an index-organized table must declare its primary key in the
-- CREATE TABLE, and PARTITION BY REFERENCE needs both the parent primary key
-- and the child foreign key to exist at child-creation time.
--
-- Sequences load in 05-sequences.sql, AFTER this file, so no column here has a
-- sequence in its DEFAULT. Keys are assigned by triggers and by the PL/SQL layer.
--------------------------------------------------------------------------------

SET SQLBLANKLINES ON
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

prompt
prompt ================================================================
prompt  02-tables.sql : core, operational and temporary tables
prompt ================================================================

--------------------------------------------------------------------------------
-- Re-runnability. Drop in reverse dependency order, children before parents,
-- swallowing ONLY ORA-00942 "table or view does not exist". Every other error
-- still aborts the load. CASCADE CONSTRAINTS clears inbound foreign keys;
-- PURGE keeps the recycle bin out of the object count.
--------------------------------------------------------------------------------
DECLARE
  TYPE t_name_list IS TABLE OF VARCHAR2(128);

  l_tables  t_name_list := t_name_list(
    '"StoreAudit_Legacy"',
    'gtt_price_calc', 'gtt_order_stage', 'gtt_replenishment',
    'data_quality_issue', 'app_parameter', 'job_run_log', 'error_log', 'audit_log',
    'gl_journal_line', 'gl_journal', 'gl_period', 'gl_account',
    'return_line', 'return_request', 'return_reason',
    'shipment_line', 'shipment', 'carrier', 'order_payment',
    'sales_order_line', 'sales_order',
    'coupon', 'promotion_product', 'promotion', 'price_list_item', 'price_list',
    'loyalty_transaction', 'loyalty_account', 'loyalty_tier',
    'customer_address', 'customer',
    'inventory_movement', 'inventory_stock', 'inventory_location', 'warehouse',
    'goods_receipt', 'purchase_order_line', 'purchase_order',
    'supplier_product', 'supplier',
    'product_variant', 'product', 'brand', 'product_category',
    'store', 'employee', 'address',
    'tax_rate', 'calendar_day', 'region', 'exchange_rate', 'country', 'currency');

  e_table_missing EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_table_missing, -942);

  l_dropped  PLS_INTEGER := 0;
BEGIN
  FOR i IN 1 .. l_tables.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE
        'DROP TABLE ' || l_tables(i) || ' CASCADE CONSTRAINTS PURGE';
      l_dropped := l_dropped + 1;
    EXCEPTION
      WHEN e_table_missing THEN
        NULL;
    END;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('Pre-existing tables dropped: ' || l_dropped);
END;
/

prompt
prompt -- A. Reference and geography (6) ==============================

CREATE TABLE currency (
  currency_code   CHAR(3),
  currency_name   VARCHAR2(60)   NOT NULL,
  minor_units     NUMBER(1)      DEFAULT 2 NOT NULL,
  symbol          VARCHAR2(5),
  is_active       CHAR(1)        DEFAULT 'Y'
);

COMMENT ON TABLE currency IS 'ISO 4217 currency master. CHAR(3) on purpose: blank-padding semantics differ after conversion (trap T-04).';

CREATE TABLE country (
  country_code     CHAR(2),
  country_name     VARCHAR2(80)  NOT NULL,
  iso3_code        CHAR(3)       NOT NULL,
  currency_code    CHAR(3)       NOT NULL,
  default_locale   VARCHAR2(10),
  vat_scheme       VARCHAR2(20),
  tz_name          VARCHAR2(64)  NOT NULL
);

COMMENT ON COLUMN country.tz_name IS 'IANA zone name. Pairs with every TIMESTAMP WITH LOCAL TIME ZONE column in the schema (H-37).';

CREATE TABLE exchange_rate (
  rate_date       DATE,
  from_currency   CHAR(3),
  to_currency     CHAR(3),
  rate            NUMBER(18,8)   NOT NULL,
  source_code     VARCHAR2(20)
);

-- Hierarchy 1 of 4: geography, GLOBAL -> AREA -> COUNTRY -> DISTRICT -> CLUSTER.
-- manager_employee_id is half of the deliberate circular foreign key (4.2).
CREATE TABLE region (
  region_id             NUMBER(9),
  region_code           VARCHAR2(20)  NOT NULL,
  region_name           VARCHAR2(100) NOT NULL,
  country_code          CHAR(2)       NOT NULL,
  parent_region_id      NUMBER(9),
  region_level          VARCHAR2(20),
  manager_employee_id   NUMBER(9)
);

-- Index-organized table 1 of 3 (H-18). The primary key must be declared here:
-- an IOT is its own primary key index, so it cannot be added in 03-constraints.
CREATE TABLE calendar_day (
  day_date           DATE,
  fiscal_year        NUMBER(4)   NOT NULL,
  fiscal_period      NUMBER(2)   NOT NULL,
  fiscal_week        NUMBER(2)   NOT NULL,
  day_of_week        NUMBER(1)   NOT NULL,
  is_trading_day     CHAR(1)     DEFAULT 'Y',
  is_public_holiday  CHAR(1)     DEFAULT 'N',
  season_code        VARCHAR2(10),
  CONSTRAINT pk_calendar_day PRIMARY KEY (day_date)
) ORGANIZATION INDEX;

CREATE TABLE tax_rate (
  tax_rate_id    NUMBER(9),
  country_code   CHAR(2)       NOT NULL,
  tax_code       VARCHAR2(20)  NOT NULL,
  rate_pct       NUMBER(5,2)   NOT NULL,
  valid_from     DATE          NOT NULL,
  valid_to       DATE
);

prompt -- B. Party, employees, stores (3) ==============================

-- normalised_key is a virtual column (H-17) and the dedupe key. It references
-- only columns of its own row and calls only built-ins, so it is one of the
-- virtual columns that survives conversion to GENERATED ALWAYS AS ... STORED.
CREATE TABLE address (
  address_id       NUMBER(12),
  line1            VARCHAR2(120)  NOT NULL,
  line2            VARCHAR2(120),
  city             VARCHAR2(80)   NOT NULL,
  state_province   VARCHAR2(80),
  postal_code      VARCHAR2(20),
  country_code     CHAR(2)        NOT NULL,
  latitude         NUMBER(9,6),
  longitude        NUMBER(9,6),
  geo_json         CLOB,
  normalised_key   GENERATED ALWAYS AS
                     (UPPER(TRIM(line1)) || '|' || UPPER(TRIM(city)) || '|' || country_code)
                     VIRTUAL
);

-- Hierarchy 2 of 4: the reporting line. Ragged depth, walked with LEVEL and
-- CONNECT_BY_ROOT (H-06). Two virtual columns (H-17).
CREATE TABLE employee (
  employee_id       NUMBER(9),
  employee_number   VARCHAR2(20)  NOT NULL,
  first_name        VARCHAR2(60)  NOT NULL,
  last_name         VARCHAR2(60)  NOT NULL,
  full_name         GENERATED ALWAYS AS (first_name || ' ' || last_name) VIRTUAL,
  email             VARCHAR2(150),
  store_id          NUMBER(9),
  manager_id        NUMBER(9),
  job_title         VARCHAR2(60)  NOT NULL,
  hire_date         DATE          NOT NULL,
  termination_date  DATE,
  salary_amount     NUMBER(12,2),
  salary_currency   CHAR(3),
  is_active         GENERATED ALWAYS AS
                      (CASE WHEN termination_date IS NULL THEN 'Y' ELSE 'N' END)
                      VIRTUAL
);

-- The schema's only LONG column (H-33). Oracle permits exactly one per table.
-- opening_offset / closing_offset are trading hours as an offset from local
-- midnight, so a 25-hour Sunday during a DST fold stays representable (H-36).
CREATE TABLE store (
  store_id                NUMBER(9),
  store_code              VARCHAR2(12)   NOT NULL,
  store_name              VARCHAR2(120)  NOT NULL,
  region_id               NUMBER(9)      NOT NULL,
  address_id              NUMBER(12)     NOT NULL,
  store_format            VARCHAR2(20),
  opened_date             DATE           NOT NULL,
  closed_date             DATE,
  selling_area_sqm        NUMBER(8,2),
  opening_offset          INTERVAL DAY(0) TO SECOND(0),
  closing_offset          INTERVAL DAY(0) TO SECOND(0),
  refit_cycle             INTERVAL YEAR(2) TO MONTH,
  created_ts              TIMESTAMP WITH LOCAL TIME ZONE DEFAULT SYSTIMESTAMP,
  manager_employee_id     NUMBER(9),
  legacy_migration_notes  LONG
);

COMMENT ON COLUMN store.legacy_migration_notes IS 'Free text carried over from the 1990s system. The only LONG column in CONTOSO (H-33).';

prompt -- C. Product catalogue (4) =====================================

-- Hierarchy 3 of 4: merchandise tree, walked with SYS_CONNECT_BY_PATH (H-06).
CREATE TABLE product_category (
  category_id         NUMBER(9),
  category_code       VARCHAR2(30)   NOT NULL,
  category_name       VARCHAR2(120)  NOT NULL,
  parent_category_id  NUMBER(9),
  merch_level         NUMBER(2),
  is_leaf             CHAR(1)        DEFAULT 'N',
  sort_order          NUMBER(6)
);

CREATE TABLE brand (
  brand_id           NUMBER(9),
  brand_code         VARCHAR2(30)   NOT NULL,
  brand_name         VARCHAR2(120)  NOT NULL,
  owner_supplier_id  NUMBER(9),
  is_own_label       CHAR(1)        DEFAULT 'N'
);

-- The heaviest table in the schema by construct count: CLOB (H-34), BLOB (H-34),
-- XMLTYPE (H-35), a virtual column (H-17), a nested table (H-05), a VARRAY
-- (H-04) and a TIMESTAMP WITH LOCAL TIME ZONE (H-37) in one object.
CREATE TABLE product (
  product_id            NUMBER(12),
  sku                   VARCHAR2(30)   NOT NULL,
  product_name          VARCHAR2(200)  NOT NULL,
  category_id           NUMBER(9)      NOT NULL,
  brand_id              NUMBER(9),
  long_description      CLOB,
  spec_sheet            XMLTYPE,
  primary_image         BLOB,
  unit_cost             NUMBER(12,4)   NOT NULL,
  list_price            NUMBER(12,4)   NOT NULL,
  margin_pct            GENERATED ALWAYS AS
                          (ROUND((list_price - unit_cost) / NULLIF(list_price, 0) * 100, 2))
                          VIRTUAL,
  base_uom              VARCHAR2(10)   DEFAULT 'EA',
  weight_kg             NUMBER(9,3),
  status                VARCHAR2(15)   DEFAULT 'ACTIVE',
  launch_date           DATE,
  attributes            t_product_attr_tab,
  channel_availability  t_channel_varr,
  created_ts            TIMESTAMP WITH LOCAL TIME ZONE DEFAULT SYSTIMESTAMP
)
NESTED TABLE attributes STORE AS product_attr_ntab;

COMMENT ON COLUMN product.attributes IS 'Nested table of t_product_attr. Queried by attribute name, so the array-of-composite conversion the tool will propose is the wrong answer (H-05).';

-- The sellable unit. Everything downstream keys on variant_id.
CREATE TABLE product_variant (
  variant_id     NUMBER(12),
  product_id     NUMBER(12)    NOT NULL,
  variant_sku    VARCHAR2(40)  NOT NULL,
  barcode_ean13  VARCHAR2(13),
  size_code      VARCHAR2(20),
  colour_code    VARCHAR2(20),
  pack_qty       NUMBER(6)     DEFAULT 1 NOT NULL,
  size_run       t_size_run_varr,
  is_active      CHAR(1)       DEFAULT 'Y'
);

prompt -- D. Supplier and procurement (5) ==============================

-- primary_contact is an object column with member methods (H-03).
CREATE TABLE supplier (
  supplier_id         NUMBER(9),
  supplier_code       VARCHAR2(20)   NOT NULL,
  supplier_name       VARCHAR2(150)  NOT NULL,
  address_id          NUMBER(12),
  primary_contact     t_contact,
  payment_terms_days  NUMBER(4)      DEFAULT 30,
  currency_code       CHAR(3)        NOT NULL,
  lead_time           INTERVAL DAY(3) TO SECOND(0),
  rating              NUMBER(3,1),
  is_approved         CHAR(1)        DEFAULT 'N',
  onboarded_ts        TIMESTAMP WITH LOCAL TIME ZONE
);

CREATE TABLE supplier_product (
  supplier_id        NUMBER(9),
  variant_id         NUMBER(12),
  supplier_sku       VARCHAR2(40)   NOT NULL,
  unit_cost          NUMBER(12,4)   NOT NULL,
  currency_code      CHAR(3),
  min_order_qty      NUMBER(9)      DEFAULT 1,
  lead_time_days     NUMBER(4),
  is_primary_source  CHAR(1)        DEFAULT 'N',
  valid_from         DATE,
  valid_to           DATE
);

-- H-19. Interval range partitioning by month on a DATE key. The primary key is
-- po_id alone and therefore does NOT contain the partition key: Oracle serves
-- that with a global index, PostgreSQL flatly refuses. See design section 9,
-- H-19 "the sharp edge".
--
-- order_date is a DATE, which in Oracle carries a time component (trap T-02).
CREATE TABLE purchase_order (
  po_id                    NUMBER(12),
  po_number                VARCHAR2(20)  NOT NULL,
  supplier_id              NUMBER(9)     NOT NULL,
  warehouse_id             NUMBER(9)     NOT NULL,
  order_date               DATE          NOT NULL,
  expected_date            DATE,
  status                   VARCHAR2(15),
  currency_code            CHAR(3)       NOT NULL,
  order_total              NUMBER(14,2),
  created_by               VARCHAR2(30)  DEFAULT SYS_CONTEXT('USERENV', 'SESSION_USER'),
  approved_by_employee_id  NUMBER(9)
)
PARTITION BY RANGE (order_date)
INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))
( PARTITION p_po_seed VALUES LESS THAN (DATE '2024-01-01') );

CREATE TABLE purchase_order_line (
  po_id          NUMBER(12),
  line_no        NUMBER(4),
  variant_id     NUMBER(12)    NOT NULL,
  qty_ordered    NUMBER(12,3)  NOT NULL,
  qty_received   NUMBER(12,3)  DEFAULT 0,
  unit_cost      NUMBER(12,4)  NOT NULL,
  line_total     GENERATED ALWAYS AS (qty_ordered * unit_cost) VIRTUAL,
  expected_date  DATE,
  status         VARCHAR2(15)
);

CREATE TABLE goods_receipt (
  receipt_id               NUMBER(12),
  receipt_number           VARCHAR2(20),
  po_id                    NUMBER(12),
  po_line_no               NUMBER(4),
  warehouse_id             NUMBER(9),
  received_ts              TIMESTAMP WITH LOCAL TIME ZONE NOT NULL,
  qty_received             NUMBER(12,3)  NOT NULL,
  qty_rejected             NUMBER(12,3)  DEFAULT 0,
  received_by_employee_id  NUMBER(9)
);

prompt -- E. Inventory (4) =============================================

CREATE TABLE warehouse (
  warehouse_id      NUMBER(9),
  warehouse_code    VARCHAR2(12)   NOT NULL,
  warehouse_name    VARCHAR2(120)  NOT NULL,
  region_id         NUMBER(9)      NOT NULL,
  address_id        NUMBER(12)     NOT NULL,
  capacity_pallets  NUMBER(9),
  is_active         CHAR(1)        DEFAULT 'Y'
);

-- Hierarchy 5: shallow, and walked ONLY by a recursive PL/SQL routine, never by
-- CONNECT BY, so the lab can compare the SQL and procedural forms of the same
-- idea (design section 4.1).
CREATE TABLE inventory_location (
  location_id         NUMBER(12),
  location_code       VARCHAR2(30)  NOT NULL,
  warehouse_id        NUMBER(9),
  store_id            NUMBER(9),
  parent_location_id  NUMBER(12),
  location_type       VARCHAR2(20)
);

CREATE TABLE inventory_stock (
  location_id        NUMBER(12),
  variant_id         NUMBER(12),
  qty_on_hand        NUMBER(14,3)  DEFAULT 0 NOT NULL,
  qty_reserved       NUMBER(14,3)  DEFAULT 0 NOT NULL,
  qty_available      GENERATED ALWAYS AS (qty_on_hand - qty_reserved) VIRTUAL,
  reorder_point      NUMBER(12,3),
  reorder_qty        NUMBER(12,3),
  last_counted_date  DATE,
  last_movement_ts   TIMESTAMP WITH LOCAL TIME ZONE
);

-- H-19 + H-20 in one object: interval range partitioning by month, list
-- subpartitioning by movement_type. Composite partitioning becomes nested
-- partitioning on PostgreSQL, which doubles the object count on the target.
CREATE TABLE inventory_movement (
  movement_id       NUMBER(18),
  movement_ts       TIMESTAMP(6)  NOT NULL,
  variant_id        NUMBER(12)    NOT NULL,
  from_location_id  NUMBER(12),
  to_location_id    NUMBER(12),
  movement_type     VARCHAR2(20)  NOT NULL,
  qty               NUMBER(14,3)  NOT NULL,
  reference_type    VARCHAR2(20),
  reference_id      NUMBER(18),
  created_by        VARCHAR2(30)
)
PARTITION BY RANGE (movement_ts)
INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))
SUBPARTITION BY LIST (movement_type)
SUBPARTITION TEMPLATE (
  SUBPARTITION sp_receipt  VALUES ('RECEIPT'),
  SUBPARTITION sp_sale     VALUES ('SALE'),
  SUBPARTITION sp_return   VALUES ('RETURN'),
  SUBPARTITION sp_transfer VALUES ('TRANSFER'),
  SUBPARTITION sp_other    VALUES (DEFAULT)
)
( PARTITION p_im_seed VALUES LESS THAN (TIMESTAMP '2024-01-01 00:00:00') );

prompt -- F. Customer and loyalty (5) ==================================

-- Protected by a VPD policy in 14-context-and-vpd.sql (H-40). consent_channels
-- is a VARRAY (H-04); notes is a CLOB (H-34); five TSLTZ columns (H-37).
CREATE TABLE customer (
  customer_id         NUMBER(12),
  customer_ref        VARCHAR2(20)   NOT NULL,
  first_name          VARCHAR2(60),
  last_name           VARCHAR2(60)   NOT NULL,
  email               VARCHAR2(150),
  mobile_phone        VARCHAR2(30),
  birth_date          DATE,
  home_country_code   CHAR(2)        NOT NULL,
  preferred_store_id  NUMBER(9),
  primary_address_id  NUMBER(12),
  marketing_optin     CHAR(1)        DEFAULT 'N',
  consent_channels    t_channel_varr,
  status              VARCHAR2(15)   DEFAULT 'ACTIVE',
  created_ts          TIMESTAMP WITH LOCAL TIME ZONE DEFAULT SYSTIMESTAMP NOT NULL,
  last_login_ts       TIMESTAMP WITH LOCAL TIME ZONE,
  gdpr_erasure_ts     TIMESTAMP WITH LOCAL TIME ZONE,
  notes               CLOB
);

COMMENT ON COLUMN customer.email IS 'Uniqueness is enforced by the function-based index fbi_customer_email_lower on LOWER(email), not by a unique constraint (H-16).';

CREATE TABLE customer_address (
  customer_id   NUMBER(12),
  address_id    NUMBER(12),
  address_type  VARCHAR2(15),
  is_default    CHAR(1)  DEFAULT 'N',
  valid_from    DATE,
  valid_to      DATE
);

CREATE TABLE loyalty_tier (
  tier_code          VARCHAR2(10),
  tier_name          VARCHAR2(60)  NOT NULL,
  min_points         NUMBER(9)     NOT NULL,
  discount_pct       NUMBER(5,2)   DEFAULT 0,
  points_multiplier  NUMBER(5,2)   DEFAULT 1,
  benefits           t_benefit_tab,
  review_interval    INTERVAL YEAR(2) TO MONTH
)
NESTED TABLE benefits STORE AS loyalty_benefit_ntab;

CREATE TABLE loyalty_account (
  loyalty_id          NUMBER(12),
  customer_id         NUMBER(12)    NOT NULL,
  card_number         VARCHAR2(19)  NOT NULL,
  tier_code           VARCHAR2(10)  NOT NULL,
  points_balance      NUMBER(12)    DEFAULT 0 NOT NULL,
  lifetime_points     NUMBER(14)    DEFAULT 0,
  enrolled_date       DATE          NOT NULL,
  tier_reviewed_date  DATE,
  status              VARCHAR2(15)  DEFAULT 'ACTIVE'
);

-- H-20. List partitioned by txn_type, with a DEFAULT partition so an unexpected
-- type does not fail the insert.
--
-- order_id is a soft reference with no foreign key, because the parent
-- sales_order is interval-partitioned and the reference would pin partition
-- maintenance. Documented deliberately (design section 5 F).
CREATE TABLE loyalty_transaction (
  loyalty_txn_id  NUMBER(18),
  txn_type        VARCHAR2(15)  NOT NULL,
  loyalty_id      NUMBER(12)    NOT NULL,
  points_delta    NUMBER(12)    NOT NULL,
  order_id        NUMBER(18),
  reason_code     VARCHAR2(20),
  txn_ts          TIMESTAMP WITH LOCAL TIME ZONE DEFAULT SYSTIMESTAMP NOT NULL,
  expires_on      DATE,
  created_by      VARCHAR2(30)
)
PARTITION BY LIST (txn_type) (
  PARTITION p_lt_accrue   VALUES ('ACCRUE'),
  PARTITION p_lt_redeem   VALUES ('REDEEM'),
  PARTITION p_lt_expire   VALUES ('EXPIRE'),
  PARTITION p_lt_adjust   VALUES ('ADJUST'),
  PARTITION p_lt_transfer VALUES ('TRANSFER'),
  PARTITION p_lt_other    VALUES (DEFAULT)
);

prompt -- G. Pricing and promotions (5) ================================

CREATE TABLE price_list (
  price_list_id    NUMBER(9),
  price_list_code  VARCHAR2(30)  NOT NULL,
  country_code     CHAR(2)       NOT NULL,
  currency_code    CHAR(3)       NOT NULL,
  channel_code     VARCHAR2(20)  NOT NULL,
  valid_from       DATE          NOT NULL,
  valid_to         DATE,
  priority         NUMBER(3)     DEFAULT 100
);

CREATE TABLE price_list_item (
  price_list_id      NUMBER(9),
  variant_id         NUMBER(12),
  effective_from     DATE,
  unit_price         NUMBER(12,4)  NOT NULL,
  was_price          NUMBER(12,4),
  tax_rate_id        NUMBER(9),
  effective_to       DATE,
  price_reason_code  VARCHAR2(20)
);

-- rule_xml is parsed with XMLTABLE and XMLQUERY ... RETURNING CONTENT in
-- pkg_promotion (H-35).
CREATE TABLE promotion (
  promotion_id    NUMBER(9),
  promo_code      VARCHAR2(30)   NOT NULL,
  promo_name      VARCHAR2(150)  NOT NULL,
  promo_type      VARCHAR2(20),
  start_ts        TIMESTAMP WITH LOCAL TIME ZONE NOT NULL,
  end_ts          TIMESTAMP WITH LOCAL TIME ZONE NOT NULL,
  budget_amount   NUMBER(14,2),
  spent_amount    NUMBER(14,2)   DEFAULT 0,
  rule_xml        XMLTYPE,
  country_code    CHAR(2),
  status          VARCHAR2(15)   DEFAULT 'DRAFT'
);

CREATE TABLE promotion_product (
  promotion_id       NUMBER(9),
  variant_id         NUMBER(12),
  discount_pct       NUMBER(5,2),
  discount_amount    NUMBER(12,4),
  max_qty_per_order  NUMBER(6)
);

CREATE TABLE coupon (
  coupon_id         NUMBER(12),
  coupon_code       VARCHAR2(40)  NOT NULL,
  promotion_id      NUMBER(9)     NOT NULL,
  customer_id       NUMBER(12),
  issued_ts         TIMESTAMP WITH LOCAL TIME ZONE,
  expires_ts        TIMESTAMP WITH LOCAL TIME ZONE,
  max_redemptions   NUMBER(6)     DEFAULT 1,
  redemption_count  NUMBER(6)     DEFAULT 0,
  redeemed_ts       TIMESTAMP WITH LOCAL TIME ZONE
);

COMMENT ON COLUMN coupon.customer_id IS 'NULL means a bearer coupon, redeemable by anyone.';

prompt -- H. Orders and fulfilment (6) =================================

-- H-19. Interval range partitioning on a TIMESTAMP WITH LOCAL TIME ZONE key.
--
-- Two things here are load-bearing and easy to get wrong:
--   1. A TSLTZ partition bound must be written as a TIMESTAMP WITH TIME ZONE
--      literal or Oracle raises ORA-30078. Hence the explicit +00:00.
--   2. The primary key is declared INLINE, not in 03-constraints.sql, because
--      sales_order_line uses PARTITION BY REFERENCE and needs the parent key
--      to exist at child-creation time.
--
-- PK (order_id) does not contain the partition key order_ts. Oracle serves that
-- with a global unique index; PostgreSQL requires every unique constraint on a
-- partitioned table to include all partition columns, so the key has to widen
-- to (order_id, order_ts) and every referencing foreign key has to follow.
-- This is the single most disruptive item in the lab and it sits on the busiest
-- table on purpose.
CREATE TABLE sales_order (
  order_id           NUMBER(18)    NOT NULL,
  order_number       VARCHAR2(24)  NOT NULL,
  customer_id        NUMBER(12),
  store_id           NUMBER(9)     NOT NULL,
  channel_code       VARCHAR2(20)  NOT NULL,
  order_ts           TIMESTAMP WITH LOCAL TIME ZONE NOT NULL,
  status             VARCHAR2(20),
  currency_code      CHAR(3)       NOT NULL,
  subtotal_amount    NUMBER(14,2),
  discount_amount    NUMBER(14,2)  DEFAULT 0,
  tax_amount         NUMBER(14,2)  DEFAULT 0,
  shipping_amount    NUMBER(14,2)  DEFAULT 0,
  order_total        GENERATED ALWAYS AS
                       (subtotal_amount - discount_amount + tax_amount + shipping_amount)
                       VIRTUAL,
  ship_address_id    NUMBER(12),
  bill_address_id    NUMBER(12),
  promotion_id       NUMBER(9),
  coupon_id          NUMBER(12),
  sales_employee_id  NUMBER(9),
  source_ip          VARCHAR2(45),
  CONSTRAINT pk_sales_order PRIMARY KEY (order_id)
)
PARTITION BY RANGE (order_ts)
INTERVAL (NUMTODSINTERVAL(30, 'DAY'))
( PARTITION p_so_seed VALUES LESS THAN (TIMESTAMP '2024-01-01 00:00:00 +00:00') );

-- H-20's review task. PARTITION BY REFERENCE inherits the parent's partitioning
-- through the foreign key and has no PostgreSQL equivalent at all: the child
-- must be independently partitioned on a copied order_ts, which means
-- denormalising the partition key onto the line table.
--
-- fk_sol_order is declared inline because reference partitioning names it.
-- The remaining foreign keys on this table live in 03-constraints.sql.
CREATE TABLE sales_order_line (
  order_id           NUMBER(18)    NOT NULL,
  line_no            NUMBER(4)     NOT NULL,
  variant_id         NUMBER(12)    NOT NULL,
  qty                NUMBER(12,3)  NOT NULL,
  unit_price         NUMBER(12,4)  NOT NULL,
  discount_amount    NUMBER(12,4)  DEFAULT 0,
  tax_rate_id        NUMBER(9),
  tax_amount         NUMBER(12,4)  DEFAULT 0,
  line_total         GENERATED ALWAYS AS
                       (qty * unit_price - discount_amount + tax_amount) VIRTUAL,
  fulfil_location_id NUMBER(12),
  status             VARCHAR2(20),
  CONSTRAINT fk_sol_order FOREIGN KEY (order_id) REFERENCES sales_order
)
PARTITION BY REFERENCE (fk_sol_order);

-- card_token is an opaque token and never a PAN. It becomes the pgcrypto demo
-- on the target.
CREATE TABLE order_payment (
  payment_id      NUMBER(18),
  order_id        NUMBER(18)    NOT NULL,
  payment_method  VARCHAR2(20),
  amount          NUMBER(14,2)  NOT NULL,
  currency_code   CHAR(3)       NOT NULL,
  auth_code       VARCHAR2(30),
  card_token      VARCHAR2(64),
  authorised_ts   TIMESTAMP WITH LOCAL TIME ZONE,
  captured_ts     TIMESTAMP WITH LOCAL TIME ZONE,
  refunded_ts     TIMESTAMP WITH LOCAL TIME ZONE,
  status          VARCHAR2(15)
);

CREATE TABLE carrier (
  carrier_code           VARCHAR2(12),
  carrier_name           VARCHAR2(120)  NOT NULL,
  service_levels         t_service_varr,
  tracking_url_template  VARCHAR2(300),
  cutoff_offset          INTERVAL DAY(0) TO SECOND(0),
  is_active              CHAR(1)        DEFAULT 'Y'
);

CREATE TABLE shipment (
  shipment_id       NUMBER(18),
  order_id          NUMBER(18)    NOT NULL,
  carrier_code      VARCHAR2(12)  NOT NULL,
  service_level     VARCHAR2(30),
  tracking_ref      VARCHAR2(60),
  from_location_id  NUMBER(12),
  shipped_ts        TIMESTAMP WITH LOCAL TIME ZONE,
  delivered_ts      TIMESTAMP WITH LOCAL TIME ZONE,
  transit_time      INTERVAL DAY(3) TO SECOND(0),
  weight_kg         NUMBER(9,3),
  status            VARCHAR2(20)
);

CREATE TABLE shipment_line (
  shipment_id    NUMBER(18),
  line_no        NUMBER(4),
  order_id       NUMBER(18),
  order_line_no  NUMBER(4),
  qty_shipped    NUMBER(12,3)  NOT NULL
);

prompt -- I. Returns (3) ===============================================

-- Index-organized table 2 of 3 (H-18). Primary key declared inline.
CREATE TABLE return_reason (
  reason_code       VARCHAR2(20),
  reason_desc       VARCHAR2(150)  NOT NULL,
  reason_group      VARCHAR2(30),
  is_restockable    CHAR(1)        DEFAULT 'Y',
  requires_approval CHAR(1)        DEFAULT 'N',
  CONSTRAINT pk_return_reason PRIMARY KEY (reason_code)
) ORGANIZATION INDEX;

CREATE TABLE return_request (
  return_id                NUMBER(18),
  rma_number               VARCHAR2(24)  NOT NULL,
  order_id                 NUMBER(18)    NOT NULL,
  customer_id              NUMBER(12),
  store_id                 NUMBER(9),
  requested_ts             TIMESTAMP WITH LOCAL TIME ZONE NOT NULL,
  status                   VARCHAR2(20),
  refund_amount            NUMBER(14,2),
  currency_code            CHAR(3),
  approved_by_employee_id  NUMBER(9),
  closed_ts                TIMESTAMP WITH LOCAL TIME ZONE
);

CREATE TABLE return_line (
  return_id         NUMBER(18),
  line_no           NUMBER(4),
  order_id          NUMBER(18),
  order_line_no     NUMBER(4),
  variant_id        NUMBER(12),
  qty_returned      NUMBER(12,3)  NOT NULL,
  reason_code       VARCHAR2(20)  NOT NULL,
  disposition_code  VARCHAR2(20),
  refund_amount     NUMBER(12,4)
);

prompt -- J. Finance and general ledger (4) =============================

-- Hierarchy 4 of 4: chart of accounts, walked with ORDER SIBLINGS BY and a
-- bottom-up roll-up (H-06).
CREATE TABLE gl_account (
  account_code         VARCHAR2(20),
  account_name         VARCHAR2(150)  NOT NULL,
  account_type         VARCHAR2(15),
  parent_account_code  VARCHAR2(20),
  is_postable          CHAR(1)        DEFAULT 'Y',
  normal_balance       CHAR(1),
  currency_code        CHAR(3)
);

CREATE TABLE gl_period (
  period_id     NUMBER(9),
  fiscal_year   NUMBER(4)  NOT NULL,
  period_no     NUMBER(2)  NOT NULL,
  period_start  DATE       NOT NULL,
  period_end    DATE       NOT NULL,
  status        VARCHAR2(10),
  closed_ts     TIMESTAMP WITH LOCAL TIME ZONE
);

CREATE TABLE gl_journal (
  journal_id               NUMBER(18),
  journal_ref              VARCHAR2(30)   NOT NULL,
  period_id                NUMBER(9)      NOT NULL,
  source_module            VARCHAR2(20),
  journal_date             DATE           NOT NULL,
  description              VARCHAR2(300),
  posted_ts                TIMESTAMP WITH LOCAL TIME ZONE,
  posted_by                VARCHAR2(30),
  status                   VARCHAR2(15),
  reversal_of_journal_id   NUMBER(18)
);

CREATE TABLE gl_journal_line (
  journal_id        NUMBER(18),
  line_no           NUMBER(5),
  account_code      VARCHAR2(20)  NOT NULL,
  store_id          NUMBER(9),
  cost_centre       VARCHAR2(20),
  debit_amount      NUMBER(16,2)  DEFAULT 0 NOT NULL,
  credit_amount     NUMBER(16,2)  DEFAULT 0 NOT NULL,
  currency_code     CHAR(3)       NOT NULL,
  fx_rate           NUMBER(18,8),
  base_amount       GENERATED ALWAYS AS
                      ((debit_amount - credit_amount) * fx_rate) VIRTUAL,
  line_description  VARCHAR2(300)
);

prompt -- K. Operational and audit (5) ==================================

-- H-02. Written only by pkg_audit, which is PRAGMA AUTONOMOUS_TRANSACTION, so
-- audit rows survive a rollback of the change they describe. The three
-- SYS_CONTEXT defaults are H-39: CONTOSO_APP_CTX is a trusted namespace that
-- only pkg_security_ctx may set, which an ordinary PostgreSQL GUC cannot be.
--
-- audit_id is populated from seq_audit_id (NOCACHE) by pkg_audit, not by a
-- column default: sequences load after this file.
CREATE TABLE audit_log (
  audit_id     NUMBER(18),
  table_name   VARCHAR2(30)  NOT NULL,
  pk_value     VARCHAR2(200),
  action_type  CHAR(1),
  changed_by   VARCHAR2(30)  DEFAULT SYS_CONTEXT('USERENV', 'SESSION_USER'),
  client_id    VARCHAR2(64)  DEFAULT SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER'),
  app_user     VARCHAR2(64)  DEFAULT SYS_CONTEXT('CONTOSO_APP_CTX', 'APP_USER'),
  changed_ts   TIMESTAMP WITH LOCAL TIME ZONE DEFAULT SYSTIMESTAMP,
  old_row      CLOB,
  new_row      CLOB
);

COMMENT ON TABLE audit_log IS 'Autonomous-transaction target for pkg_audit (H-02). On PostgreSQL this becomes an in-transaction AFTER trigger, so audit rows start rolling back with the change - a real behaviour change the team must sign off.';

-- error_code is NUMBER with no precision on purpose (trap T-01): it becomes an
-- unbounded numeric on the target, which is correct and slow.
CREATE TABLE error_log (
  error_id         NUMBER(18),
  module_name      VARCHAR2(80),
  routine_name     VARCHAR2(80),
  error_code       NUMBER,
  error_message    VARCHAR2(4000),
  error_backtrace  CLOB,
  call_stack       CLOB,
  bind_context     VARCHAR2(4000),
  logged_ts        TIMESTAMP WITH LOCAL TIME ZONE DEFAULT SYSTIMESTAMP,
  db_user          VARCHAR2(30),
  app_user         VARCHAR2(64)
);

CREATE TABLE job_run_log (
  run_id          NUMBER(18),
  job_name        VARCHAR2(80)  NOT NULL,
  started_ts      TIMESTAMP WITH LOCAL TIME ZONE,
  finished_ts     TIMESTAMP WITH LOCAL TIME ZONE,
  elapsed         INTERVAL DAY(2) TO SECOND(3),
  status          VARCHAR2(15),
  rows_processed  NUMBER(12),
  message         VARCHAR2(4000)
);

-- Index-organized table 3 of 3 (H-18). Runtime configuration, and the store for
-- the pkg_data_quality rule set: rows with param_name LIKE 'DQ_RULE_%' hold the
-- SQL text that pkg_data_quality executes with EXECUTE IMMEDIATE (H-11), so
-- param_value has to be wide enough for a small SQL snippet.
--
-- INCLUDING param_name pushes everything after the key into the overflow
-- segment, which keeps the index leaf blocks small despite param_value being
-- VARCHAR2(4000).
CREATE TABLE app_parameter (
  param_name   VARCHAR2(100),
  param_value  VARCHAR2(4000),
  param_type   VARCHAR2(15),
  description  VARCHAR2(400),
  is_encrypted CHAR(1)  DEFAULT 'N',
  updated_ts   TIMESTAMP WITH LOCAL TIME ZONE,
  updated_by   VARCHAR2(30),
  CONSTRAINT pk_app_parameter PRIMARY KEY (param_name)
) ORGANIZATION INDEX
  PCTTHRESHOLD 20
  INCLUDING param_name OVERFLOW;

CREATE TABLE data_quality_issue (
  issue_id      NUMBER(18),
  rule_code     VARCHAR2(30)  NOT NULL,
  entity_name   VARCHAR2(30)  NOT NULL,
  entity_key    VARCHAR2(200),
  severity      VARCHAR2(10),
  detail        VARCHAR2(4000),
  detected_ts   TIMESTAMP WITH LOCAL TIME ZONE DEFAULT SYSTIMESTAMP,
  resolved_ts   TIMESTAMP WITH LOCAL TIME ZONE
);

prompt -- L. Global temporary tables (3) ================================

-- H-21. An Oracle GTT is a permanent catalogue object whose DATA is session
-- private. A PostgreSQL temporary table is created per session at runtime, so
-- every function using one has to create it first, it vanishes from the
-- catalogue, and the create/drop churn bloats pg_catalog under connection
-- turnover. Two commit behaviours are represented so both paths are tested.

-- Staging for pkg_pricing.resolve_prices: candidate prices before the winner
-- is picked. Rows are scoped to the statement's transaction.
CREATE GLOBAL TEMPORARY TABLE gtt_price_calc (
  variant_id      NUMBER(12),
  price_list_id   NUMBER(9),
  unit_price      NUMBER(12,4),
  currency_code   CHAR(3),
  priority        NUMBER(3),
  effective_from  DATE,
  source_code     VARCHAR2(20)
) ON COMMIT DELETE ROWS;

-- BULK COLLECT target for pkg_order_capture basket validation. Rows must
-- outlive the intermediate commits inside the capture flow.
CREATE GLOBAL TEMPORARY TABLE gtt_order_stage (
  order_id    NUMBER(18),
  line_no     NUMBER(4),
  variant_id  NUMBER(12),
  qty         NUMBER(12,3),
  unit_price  NUMBER(12,4),
  status      VARCHAR2(20),
  message     VARCHAR2(400)
) ON COMMIT PRESERVE ROWS;

-- Working set for pkg_replenishment's nightly reorder proposal.
CREATE GLOBAL TEMPORARY TABLE gtt_replenishment (
  warehouse_id   NUMBER(9),
  variant_id     NUMBER(12),
  qty_on_hand    NUMBER(14,3),
  reorder_point  NUMBER(12,3),
  suggested_qty  NUMBER(12,3),
  supplier_id    NUMBER(9),
  run_ts         TIMESTAMP(6)
) ON COMMIT DELETE ROWS;

prompt -- Trap T-07: the quoted mixed-case identifier ==================

-- Oracle folds unquoted identifiers to upper case, PostgreSQL folds them to
-- lower case. A quoted identifier survives conversion verbatim as
-- "StoreAudit_Legacy", and every unquoted reference to it then fails on the
-- target. One table, two columns, a whole class of migration bug.
CREATE TABLE "StoreAudit_Legacy" (
  "AuditId"    NUMBER(18),
  "StoreId"    NUMBER(9),
  action_type  CHAR(1),
  changed_ts   TIMESTAMP WITH LOCAL TIME ZONE DEFAULT SYSTIMESTAMP,
  note         VARCHAR2(400)
);

COMMENT ON TABLE "StoreAudit_Legacy" IS 'Deliberately quoted and mixed case to exercise the identifier-folding trap T-07. Do not rename.';

--------------------------------------------------------------------------------
-- Verification.
--
-- Expected TABLE objects from THIS file: 45 core + 5 operational + 3 global
-- temporary + 1 quoted legacy + 2 nested-table storage = 56, plus one more for
-- the SYS_IOT_OVER_nnnnn overflow segment that app_parameter's OVERFLOW clause
-- creates. Oracle counts that segment as a TABLE in USER_OBJECTS, so the honest
-- number is 57.
--
-- The count deliberately EXCLUDES materialised view containers, the MLOG$_ view
-- logs and MV_CAPABILITIES_TABLE. Those are TABLE objects too, and design
-- section 8's figure of 64 includes them -- but they are created by the
-- materialised view file, which loads later. Counting every TABLE here would
-- make this assertion pass on a fresh schema and fail on a full one, which is
-- the worst possible behaviour for a build check.
--
-- There is deliberately NO schema-wide INVALID check here either. Re-running
-- this file drops and recreates every core table, which legitimately invalidates
-- the views, packages and materialised views that sit on top of them until they
-- recompile. Asserting zero INVALID objects is the job of 99-verify-objects.sql,
-- at the end of the load, not the middle of it.
--
-- The virtual-column count filters on scalar data types on purpose: Oracle also
-- reports nested-table columns (product.attributes, loyalty_tier.benefits) and
-- XMLTYPE columns (product.spec_sheet, promotion.rule_xml) as VIRTUAL_COLUMN =
-- 'YES', which would inflate the figure from 9 to 13 and hide a real drift.
--------------------------------------------------------------------------------
DECLARE
  l_tables     PLS_INTEGER;
  l_partition  PLS_INTEGER;
  l_iot        PLS_INTEGER;
  l_gtt        PLS_INTEGER;
  l_virtual    PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_tables
    FROM user_objects o
   WHERE o.object_type = 'TABLE'
     AND o.object_name NOT LIKE 'MLOG$%'
     AND o.object_name <> 'MV_CAPABILITIES_TABLE'
     AND NOT EXISTS (SELECT 1 FROM user_mviews m
                      WHERE m.mview_name = o.object_name);

  SELECT COUNT(*) INTO l_partition FROM user_part_tables;

  SELECT COUNT(*) INTO l_iot
    FROM user_tables WHERE iot_type = 'IOT';

  SELECT COUNT(*) INTO l_gtt
    FROM user_tables WHERE temporary = 'Y';

  SELECT COUNT(*) INTO l_virtual
    FROM user_tab_cols
   WHERE virtual_column = 'YES'
     AND hidden_column  = 'NO'
     AND data_type IN ('NUMBER', 'VARCHAR2', 'CHAR');

  DBMS_OUTPUT.PUT_LINE('TABLE objects ......: ' || l_tables    || ' (expected 57)');
  DBMS_OUTPUT.PUT_LINE('Partitioned tables .: ' || l_partition || ' (expected 5)');
  DBMS_OUTPUT.PUT_LINE('Index-organized ....: ' || l_iot       || ' (expected 3)');
  DBMS_OUTPUT.PUT_LINE('Global temporary ...: ' || l_gtt       || ' (expected 3)');
  DBMS_OUTPUT.PUT_LINE('Virtual columns ....: ' || l_virtual   || ' (expected 9)');

  IF l_tables <> 57 THEN
    RAISE_APPLICATION_ERROR(-20021,
      'Table budget drift: expected 57 TABLE objects from this file, got '
      || l_tables || '.');
  END IF;

  IF l_partition <> 5 OR l_iot <> 3 OR l_gtt <> 3 OR l_virtual <> 9 THEN
    RAISE_APPLICATION_ERROR(-20022,
      'Structural drift: partitioned=' || l_partition
      || ' iot=' || l_iot || ' gtt=' || l_gtt || ' virtual=' || l_virtual
      || ' (expected 5/3/3/9).');
  END IF;
END;
/

prompt
prompt 02-tables.sql complete: 57 tables, 5 partitioned, 3 IOT, 3 GTT, 9 virtual columns.
prompt
