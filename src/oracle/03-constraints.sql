--------------------------------------------------------------------------------
-- Contoso Store -- Oracle to Azure Database for PostgreSQL migration lab
-- 03-constraints.sql
--
-- Runs as CONTOSO, after 02-tables.sql, before 04-indexes.sql.
--
-- Every constraint that could be deferred to this file was deferred to it, for
-- one reason: region.manager_employee_id -> employee.store_id -> store.region_id
-- is a deliberate cycle (design section 4.2). Oracle does not care, because all
-- the tables already exist by the time this file runs. A converter that emits
-- the target DDL in dependency order has nowhere to start and fails. That is a
-- cheap, realistic trap and it stays.
--
-- Five constraints are NOT here, because 02-tables.sql had to declare them
-- inline: pk_calendar_day, pk_return_reason and pk_app_parameter (an
-- ORGANIZATION INDEX has no heap to bolt a primary key onto afterwards),
-- pk_sales_order and fk_sol_order (PARTITION BY REFERENCE needs both at
-- CREATE TABLE time).
--
-- Contents: 47 primary keys here plus the 4 inline ones, 24 unique keys,
-- 97 foreign keys here plus fk_sol_order inline -- 6 of them self-referencing,
-- 1 of them closing the circular pair -- and 56 check constraints.
--
-- Totals in USER_CONSTRAINTS after this file: 51 P, 24 U, 98 R, 56 C.
--------------------------------------------------------------------------------

SET SQLBLANKLINES ON
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

prompt
prompt ================================================================
prompt  03-constraints.sql : primary, unique, foreign and check keys
prompt ================================================================

--------------------------------------------------------------------------------
-- Re-runnability. Drop every user-named constraint except the five that
-- 02-tables.sql declared inline. Foreign keys go first so the keys they point at
-- become droppable. ORA-02443 "cannot drop constraint - nonexistent constraint"
-- is swallowed and nothing else is, because dropping a primary key with CASCADE
-- elsewhere in the loop can take a dependent foreign key with it.
--------------------------------------------------------------------------------
DECLARE
  l_dropped PLS_INTEGER := 0;
BEGIN
  FOR r IN (SELECT table_name, constraint_name
              FROM user_constraints
             WHERE generated = 'USER NAME'
               AND constraint_type IN ('R', 'C', 'U', 'P')
               AND constraint_name NOT IN ('PK_CALENDAR_DAY', 'PK_RETURN_REASON',
                                           'PK_APP_PARAMETER', 'PK_SALES_ORDER',
                                           'FK_SOL_ORDER')
             ORDER BY DECODE(constraint_type, 'R', 1, 'C', 2, 'U', 3, 'P', 4),
                      constraint_name)
  LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE "' || r.table_name
                     || '" DROP CONSTRAINT "' || r.constraint_name || '"';
      l_dropped := l_dropped + 1;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE <> -2443 THEN
          RAISE;
        END IF;
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('Pre-existing constraints dropped: ' || l_dropped);
END;
/

--------------------------------------------------------------------------------
-- 1. Primary keys
--
-- Two of these are worth reading twice.
--
-- pk_purchase_order is on po_id alone and pk_inventory_movement omits the
-- subpartitioning column, so Oracle backs both with a GLOBAL index on a
-- partitioned table. PostgreSQL requires every unique constraint on a
-- partitioned table to include all partition columns and offers no global index
-- at all. There is no conversion that preserves both the key and the
-- partitioning -- see hard case H-19, the most disruptive item in the lab.
--
-- pk_sales_order_line and pk_loyalty_transaction go the other way: their keys do
-- contain the partition key, so they can be LOCAL and they convert cleanly. The
-- contrast is the point.
--------------------------------------------------------------------------------
prompt -- 1. Primary keys

-- A. Reference and geography
ALTER TABLE currency      ADD CONSTRAINT pk_currency      PRIMARY KEY (currency_code);
ALTER TABLE country       ADD CONSTRAINT pk_country       PRIMARY KEY (country_code);
ALTER TABLE exchange_rate ADD CONSTRAINT pk_exchange_rate PRIMARY KEY (rate_date, from_currency, to_currency);
ALTER TABLE region        ADD CONSTRAINT pk_region        PRIMARY KEY (region_id);
ALTER TABLE tax_rate      ADD CONSTRAINT pk_tax_rate      PRIMARY KEY (tax_rate_id);

-- B. Party, employees, stores
ALTER TABLE address  ADD CONSTRAINT pk_address  PRIMARY KEY (address_id);
ALTER TABLE employee ADD CONSTRAINT pk_employee PRIMARY KEY (employee_id);
ALTER TABLE store    ADD CONSTRAINT pk_store    PRIMARY KEY (store_id);

-- C. Product catalogue
ALTER TABLE product_category ADD CONSTRAINT pk_product_category PRIMARY KEY (category_id);
ALTER TABLE brand            ADD CONSTRAINT pk_brand            PRIMARY KEY (brand_id);
ALTER TABLE product          ADD CONSTRAINT pk_product          PRIMARY KEY (product_id);
ALTER TABLE product_variant  ADD CONSTRAINT pk_product_variant  PRIMARY KEY (variant_id);

-- D. Supplier and procurement
ALTER TABLE supplier            ADD CONSTRAINT pk_supplier            PRIMARY KEY (supplier_id);
ALTER TABLE supplier_product    ADD CONSTRAINT pk_supplier_product    PRIMARY KEY (supplier_id, variant_id);
ALTER TABLE purchase_order      ADD CONSTRAINT pk_purchase_order      PRIMARY KEY (po_id);
ALTER TABLE purchase_order_line ADD CONSTRAINT pk_purchase_order_line PRIMARY KEY (po_id, line_no);
ALTER TABLE goods_receipt       ADD CONSTRAINT pk_goods_receipt       PRIMARY KEY (receipt_id);

-- E. Inventory
ALTER TABLE warehouse          ADD CONSTRAINT pk_warehouse          PRIMARY KEY (warehouse_id);
ALTER TABLE inventory_location ADD CONSTRAINT pk_inventory_location PRIMARY KEY (location_id);
ALTER TABLE inventory_stock    ADD CONSTRAINT pk_inventory_stock    PRIMARY KEY (location_id, variant_id);
ALTER TABLE inventory_movement ADD CONSTRAINT pk_inventory_movement PRIMARY KEY (movement_id, movement_ts);

-- F. Customer and loyalty
ALTER TABLE customer         ADD CONSTRAINT pk_customer         PRIMARY KEY (customer_id);
ALTER TABLE customer_address ADD CONSTRAINT pk_customer_address PRIMARY KEY (customer_id, address_id, address_type);
ALTER TABLE loyalty_tier     ADD CONSTRAINT pk_loyalty_tier     PRIMARY KEY (tier_code);
ALTER TABLE loyalty_account  ADD CONSTRAINT pk_loyalty_account  PRIMARY KEY (loyalty_id);

-- Key contains the list partition key, so the backing index can be LOCAL.
ALTER TABLE loyalty_transaction ADD CONSTRAINT pk_loyalty_transaction
  PRIMARY KEY (loyalty_txn_id, txn_type) USING INDEX LOCAL;

-- G. Pricing and promotions
ALTER TABLE price_list        ADD CONSTRAINT pk_price_list        PRIMARY KEY (price_list_id);
ALTER TABLE price_list_item   ADD CONSTRAINT pk_price_list_item   PRIMARY KEY (price_list_id, variant_id, effective_from);
ALTER TABLE promotion         ADD CONSTRAINT pk_promotion         PRIMARY KEY (promotion_id);
ALTER TABLE promotion_product ADD CONSTRAINT pk_promotion_product PRIMARY KEY (promotion_id, variant_id);
ALTER TABLE coupon            ADD CONSTRAINT pk_coupon            PRIMARY KEY (coupon_id);

-- H. Orders and fulfilment (pk_sales_order is inline in 02-tables.sql)
-- Reference partitioning means order_id is the effective partition key here too,
-- so this one is LOCAL while its parent's is global.
ALTER TABLE sales_order_line ADD CONSTRAINT pk_sales_order_line
  PRIMARY KEY (order_id, line_no) USING INDEX LOCAL;

ALTER TABLE order_payment ADD CONSTRAINT pk_order_payment PRIMARY KEY (payment_id);
ALTER TABLE carrier       ADD CONSTRAINT pk_carrier       PRIMARY KEY (carrier_code);
ALTER TABLE shipment      ADD CONSTRAINT pk_shipment      PRIMARY KEY (shipment_id);
ALTER TABLE shipment_line ADD CONSTRAINT pk_shipment_line PRIMARY KEY (shipment_id, line_no);

-- I. Returns (pk_return_reason is inline in 02-tables.sql)
ALTER TABLE return_request ADD CONSTRAINT pk_return_request PRIMARY KEY (return_id);
ALTER TABLE return_line    ADD CONSTRAINT pk_return_line    PRIMARY KEY (return_id, line_no);

-- J. Finance and general ledger
ALTER TABLE gl_account      ADD CONSTRAINT pk_gl_account      PRIMARY KEY (account_code);
ALTER TABLE gl_period       ADD CONSTRAINT pk_gl_period       PRIMARY KEY (period_id);
ALTER TABLE gl_journal      ADD CONSTRAINT pk_gl_journal      PRIMARY KEY (journal_id);
ALTER TABLE gl_journal_line ADD CONSTRAINT pk_gl_journal_line PRIMARY KEY (journal_id, line_no);

-- K. Operational and audit (pk_app_parameter is inline in 02-tables.sql)
ALTER TABLE audit_log          ADD CONSTRAINT pk_audit_log          PRIMARY KEY (audit_id);
ALTER TABLE error_log          ADD CONSTRAINT pk_error_log          PRIMARY KEY (error_id);
ALTER TABLE job_run_log        ADD CONSTRAINT pk_job_run_log        PRIMARY KEY (run_id);
ALTER TABLE data_quality_issue ADD CONSTRAINT pk_data_quality_issue PRIMARY KEY (issue_id);

-- T-07. The quoted mixed-case table needs a quoted mixed-case column in its key.
ALTER TABLE "StoreAudit_Legacy" ADD CONSTRAINT pk_storeaudit_legacy PRIMARY KEY ("AuditId");

--------------------------------------------------------------------------------
-- 2. Unique keys
--------------------------------------------------------------------------------
prompt -- 2. Unique keys

ALTER TABLE country ADD CONSTRAINT uq_country_name UNIQUE (country_name);
ALTER TABLE country ADD CONSTRAINT uq_country_iso3 UNIQUE (iso3_code);
ALTER TABLE region  ADD CONSTRAINT uq_region_code  UNIQUE (region_code);

-- One rate per country, tax code and start date.
ALTER TABLE tax_rate ADD CONSTRAINT uq_tax_rate_code UNIQUE (country_code, tax_code, valid_from);

ALTER TABLE employee ADD CONSTRAINT uq_employee_number UNIQUE (employee_number);
ALTER TABLE store    ADD CONSTRAINT uq_store_code      UNIQUE (store_code);

ALTER TABLE product_category ADD CONSTRAINT uq_category_code UNIQUE (category_code);
ALTER TABLE brand            ADD CONSTRAINT uq_brand_code    UNIQUE (brand_code);
ALTER TABLE product          ADD CONSTRAINT uq_product_sku   UNIQUE (sku);

ALTER TABLE product_variant ADD CONSTRAINT uq_variant_sku     UNIQUE (variant_sku);
ALTER TABLE product_variant ADD CONSTRAINT uq_variant_barcode UNIQUE (barcode_ean13);

-- A product cannot carry the same size and colour twice. Both columns are
-- nullable, and Oracle lets any number of rows share a key containing a NULL, so
-- (99, NULL, NULL) can repeat freely. PostgreSQL behaves the same way by default
-- but offers NULLS NOT DISTINCT (PG 15+), which a converter may or may not reach
-- for. Worth checking after conversion rather than assuming.
ALTER TABLE product_variant ADD CONSTRAINT uq_variant_size_colour
  UNIQUE (product_id, size_code, colour_code);

ALTER TABLE supplier      ADD CONSTRAINT uq_supplier_code  UNIQUE (supplier_code);
ALTER TABLE goods_receipt ADD CONSTRAINT uq_receipt_number UNIQUE (receipt_number);
ALTER TABLE warehouse     ADD CONSTRAINT uq_warehouse_code UNIQUE (warehouse_code);

ALTER TABLE customer        ADD CONSTRAINT uq_customer_ref     UNIQUE (customer_ref);
ALTER TABLE loyalty_account ADD CONSTRAINT uq_loyalty_customer UNIQUE (customer_id);
ALTER TABLE loyalty_account ADD CONSTRAINT uq_loyalty_card     UNIQUE (card_number);

ALTER TABLE price_list ADD CONSTRAINT uq_price_list_code UNIQUE (price_list_code);
ALTER TABLE promotion  ADD CONSTRAINT uq_promo_code      UNIQUE (promo_code);
ALTER TABLE coupon     ADD CONSTRAINT uq_coupon_code     UNIQUE (coupon_code);

ALTER TABLE return_request ADD CONSTRAINT uq_rma_number UNIQUE (rma_number);

ALTER TABLE gl_period  ADD CONSTRAINT uq_gl_period_year_no UNIQUE (fiscal_year, period_no);
ALTER TABLE gl_journal ADD CONSTRAINT uq_journal_ref       UNIQUE (journal_ref);

-- Note what is deliberately absent: sales_order.order_number and
-- purchase_order.po_number are business-unique but carry no unique constraint,
-- because a unique index on an interval-partitioned table would have to be
-- global and Oracle already spends one of those on the primary key. Uniqueness
-- is enforced in pkg_order_capture and pkg_purchasing instead -- exactly the
-- kind of "the database used to guarantee this" detail that goes missing in a
-- migration.

--------------------------------------------------------------------------------
-- 3. Foreign keys
--
-- Six are self-referencing -- one per hierarchy in design section 4.1, plus the
-- journal reversal link: fk_region_parent, fk_employee_manager,
-- fk_category_parent, fk_location_parent, fk_gl_account_parent,
-- fk_journal_reversal.
--
-- The circular pair of design section 4.2 is fk_region_manager (region ->
-- employee) closing against fk_employee_store (employee -> store) and
-- fk_store_region (store -> region). Emit those three in dependency order and
-- there is no order to emit them in.
--------------------------------------------------------------------------------
prompt -- 3. Foreign keys

-- A. Reference and geography
ALTER TABLE country ADD CONSTRAINT fk_country_currency
  FOREIGN KEY (currency_code) REFERENCES currency (currency_code);

ALTER TABLE exchange_rate ADD CONSTRAINT fk_rate_from_currency
  FOREIGN KEY (from_currency) REFERENCES currency (currency_code);
ALTER TABLE exchange_rate ADD CONSTRAINT fk_rate_to_currency
  FOREIGN KEY (to_currency) REFERENCES currency (currency_code);

ALTER TABLE region ADD CONSTRAINT fk_region_country
  FOREIGN KEY (country_code) REFERENCES country (country_code);
ALTER TABLE region ADD CONSTRAINT fk_region_parent
  FOREIGN KEY (parent_region_id) REFERENCES region (region_id);

-- Circular foreign key, half 1 of 2.
ALTER TABLE region ADD CONSTRAINT fk_region_manager
  FOREIGN KEY (manager_employee_id) REFERENCES employee (employee_id);

ALTER TABLE tax_rate ADD CONSTRAINT fk_tax_rate_country
  FOREIGN KEY (country_code) REFERENCES country (country_code);

-- B. Party, employees, stores
ALTER TABLE address ADD CONSTRAINT fk_address_country
  FOREIGN KEY (country_code) REFERENCES country (country_code);

-- Circular foreign key, half 2 of 2.
ALTER TABLE employee ADD CONSTRAINT fk_employee_store
  FOREIGN KEY (store_id) REFERENCES store (store_id);
ALTER TABLE employee ADD CONSTRAINT fk_employee_manager
  FOREIGN KEY (manager_id) REFERENCES employee (employee_id);
ALTER TABLE employee ADD CONSTRAINT fk_employee_currency
  FOREIGN KEY (salary_currency) REFERENCES currency (currency_code);

ALTER TABLE store ADD CONSTRAINT fk_store_region
  FOREIGN KEY (region_id) REFERENCES region (region_id);
ALTER TABLE store ADD CONSTRAINT fk_store_address
  FOREIGN KEY (address_id) REFERENCES address (address_id);
ALTER TABLE store ADD CONSTRAINT fk_store_manager
  FOREIGN KEY (manager_employee_id) REFERENCES employee (employee_id);

-- C. Product catalogue
ALTER TABLE product_category ADD CONSTRAINT fk_category_parent
  FOREIGN KEY (parent_category_id) REFERENCES product_category (category_id);

ALTER TABLE brand ADD CONSTRAINT fk_brand_supplier
  FOREIGN KEY (owner_supplier_id) REFERENCES supplier (supplier_id);

ALTER TABLE product ADD CONSTRAINT fk_product_category
  FOREIGN KEY (category_id) REFERENCES product_category (category_id);
ALTER TABLE product ADD CONSTRAINT fk_product_brand
  FOREIGN KEY (brand_id) REFERENCES brand (brand_id);

ALTER TABLE product_variant ADD CONSTRAINT fk_variant_product
  FOREIGN KEY (product_id) REFERENCES product (product_id);

-- D. Supplier and procurement
ALTER TABLE supplier ADD CONSTRAINT fk_supplier_address
  FOREIGN KEY (address_id) REFERENCES address (address_id);
ALTER TABLE supplier ADD CONSTRAINT fk_supplier_currency
  FOREIGN KEY (currency_code) REFERENCES currency (currency_code);

ALTER TABLE supplier_product ADD CONSTRAINT fk_supprod_supplier
  FOREIGN KEY (supplier_id) REFERENCES supplier (supplier_id);
ALTER TABLE supplier_product ADD CONSTRAINT fk_supprod_variant
  FOREIGN KEY (variant_id) REFERENCES product_variant (variant_id);
ALTER TABLE supplier_product ADD CONSTRAINT fk_supprod_currency
  FOREIGN KEY (currency_code) REFERENCES currency (currency_code);

ALTER TABLE purchase_order ADD CONSTRAINT fk_po_supplier
  FOREIGN KEY (supplier_id) REFERENCES supplier (supplier_id);
ALTER TABLE purchase_order ADD CONSTRAINT fk_po_warehouse
  FOREIGN KEY (warehouse_id) REFERENCES warehouse (warehouse_id);
ALTER TABLE purchase_order ADD CONSTRAINT fk_po_currency
  FOREIGN KEY (currency_code) REFERENCES currency (currency_code);
ALTER TABLE purchase_order ADD CONSTRAINT fk_po_approver
  FOREIGN KEY (approved_by_employee_id) REFERENCES employee (employee_id);

-- A foreign key from an ordinary heap table into an interval-partitioned parent.
ALTER TABLE purchase_order_line ADD CONSTRAINT fk_pol_po
  FOREIGN KEY (po_id) REFERENCES purchase_order (po_id);
ALTER TABLE purchase_order_line ADD CONSTRAINT fk_pol_variant
  FOREIGN KEY (variant_id) REFERENCES product_variant (variant_id);

-- Composite foreign key into a composite primary key.
ALTER TABLE goods_receipt ADD CONSTRAINT fk_gr_po_line
  FOREIGN KEY (po_id, po_line_no) REFERENCES purchase_order_line (po_id, line_no);
ALTER TABLE goods_receipt ADD CONSTRAINT fk_gr_warehouse
  FOREIGN KEY (warehouse_id) REFERENCES warehouse (warehouse_id);
ALTER TABLE goods_receipt ADD CONSTRAINT fk_gr_receiver
  FOREIGN KEY (received_by_employee_id) REFERENCES employee (employee_id);

-- E. Inventory
ALTER TABLE warehouse ADD CONSTRAINT fk_warehouse_region
  FOREIGN KEY (region_id) REFERENCES region (region_id);
ALTER TABLE warehouse ADD CONSTRAINT fk_warehouse_address
  FOREIGN KEY (address_id) REFERENCES address (address_id);

ALTER TABLE inventory_location ADD CONSTRAINT fk_location_warehouse
  FOREIGN KEY (warehouse_id) REFERENCES warehouse (warehouse_id);
ALTER TABLE inventory_location ADD CONSTRAINT fk_location_store
  FOREIGN KEY (store_id) REFERENCES store (store_id);

-- Hierarchy 5: shallow, and walked only by a recursive PL/SQL routine, never by
-- CONNECT BY, so the lab can compare the SQL form against the procedural form.
ALTER TABLE inventory_location ADD CONSTRAINT fk_location_parent
  FOREIGN KEY (parent_location_id) REFERENCES inventory_location (location_id);

ALTER TABLE inventory_stock ADD CONSTRAINT fk_stock_location
  FOREIGN KEY (location_id) REFERENCES inventory_location (location_id);
ALTER TABLE inventory_stock ADD CONSTRAINT fk_stock_variant
  FOREIGN KEY (variant_id) REFERENCES product_variant (variant_id);

ALTER TABLE inventory_movement ADD CONSTRAINT fk_movement_variant
  FOREIGN KEY (variant_id) REFERENCES product_variant (variant_id);
ALTER TABLE inventory_movement ADD CONSTRAINT fk_movement_from_loc
  FOREIGN KEY (from_location_id) REFERENCES inventory_location (location_id);
ALTER TABLE inventory_movement ADD CONSTRAINT fk_movement_to_loc
  FOREIGN KEY (to_location_id) REFERENCES inventory_location (location_id);

-- F. Customer and loyalty
ALTER TABLE customer ADD CONSTRAINT fk_customer_country
  FOREIGN KEY (home_country_code) REFERENCES country (country_code);
ALTER TABLE customer ADD CONSTRAINT fk_customer_store
  FOREIGN KEY (preferred_store_id) REFERENCES store (store_id);
ALTER TABLE customer ADD CONSTRAINT fk_customer_address
  FOREIGN KEY (primary_address_id) REFERENCES address (address_id);

ALTER TABLE customer_address ADD CONSTRAINT fk_custaddr_customer
  FOREIGN KEY (customer_id) REFERENCES customer (customer_id);
ALTER TABLE customer_address ADD CONSTRAINT fk_custaddr_address
  FOREIGN KEY (address_id) REFERENCES address (address_id);

ALTER TABLE loyalty_account ADD CONSTRAINT fk_loyalty_customer
  FOREIGN KEY (customer_id) REFERENCES customer (customer_id);
ALTER TABLE loyalty_account ADD CONSTRAINT fk_loyalty_tier
  FOREIGN KEY (tier_code) REFERENCES loyalty_tier (tier_code);

ALTER TABLE loyalty_transaction ADD CONSTRAINT fk_loytxn_account
  FOREIGN KEY (loyalty_id) REFERENCES loyalty_account (loyalty_id);

-- loyalty_transaction.order_id carries NO foreign key, on purpose. sales_order
-- is interval partitioned with a global primary key, and pointing at it from a
-- list-partitioned child adds nothing the application does not already enforce.
-- Recorded here so nobody "fixes" it during conversion (design section 5F).

-- G. Pricing and promotions
ALTER TABLE price_list ADD CONSTRAINT fk_price_list_country
  FOREIGN KEY (country_code) REFERENCES country (country_code);
ALTER TABLE price_list ADD CONSTRAINT fk_price_list_currency
  FOREIGN KEY (currency_code) REFERENCES currency (currency_code);

ALTER TABLE price_list_item ADD CONSTRAINT fk_pli_price_list
  FOREIGN KEY (price_list_id) REFERENCES price_list (price_list_id);
ALTER TABLE price_list_item ADD CONSTRAINT fk_pli_variant
  FOREIGN KEY (variant_id) REFERENCES product_variant (variant_id);
ALTER TABLE price_list_item ADD CONSTRAINT fk_pli_tax_rate
  FOREIGN KEY (tax_rate_id) REFERENCES tax_rate (tax_rate_id);

ALTER TABLE promotion ADD CONSTRAINT fk_promotion_country
  FOREIGN KEY (country_code) REFERENCES country (country_code);

ALTER TABLE promotion_product ADD CONSTRAINT fk_promoprod_promotion
  FOREIGN KEY (promotion_id) REFERENCES promotion (promotion_id);
ALTER TABLE promotion_product ADD CONSTRAINT fk_promoprod_variant
  FOREIGN KEY (variant_id) REFERENCES product_variant (variant_id);

ALTER TABLE coupon ADD CONSTRAINT fk_coupon_promotion
  FOREIGN KEY (promotion_id) REFERENCES promotion (promotion_id);
ALTER TABLE coupon ADD CONSTRAINT fk_coupon_customer
  FOREIGN KEY (customer_id) REFERENCES customer (customer_id);

-- H. Orders and fulfilment (fk_sol_order is inline in 02-tables.sql)
ALTER TABLE sales_order ADD CONSTRAINT fk_so_customer
  FOREIGN KEY (customer_id) REFERENCES customer (customer_id);
ALTER TABLE sales_order ADD CONSTRAINT fk_so_store
  FOREIGN KEY (store_id) REFERENCES store (store_id);
ALTER TABLE sales_order ADD CONSTRAINT fk_so_currency
  FOREIGN KEY (currency_code) REFERENCES currency (currency_code);
ALTER TABLE sales_order ADD CONSTRAINT fk_so_ship_address
  FOREIGN KEY (ship_address_id) REFERENCES address (address_id);
ALTER TABLE sales_order ADD CONSTRAINT fk_so_bill_address
  FOREIGN KEY (bill_address_id) REFERENCES address (address_id);
ALTER TABLE sales_order ADD CONSTRAINT fk_so_promotion
  FOREIGN KEY (promotion_id) REFERENCES promotion (promotion_id);
ALTER TABLE sales_order ADD CONSTRAINT fk_so_coupon
  FOREIGN KEY (coupon_id) REFERENCES coupon (coupon_id);
ALTER TABLE sales_order ADD CONSTRAINT fk_so_employee
  FOREIGN KEY (sales_employee_id) REFERENCES employee (employee_id);

ALTER TABLE sales_order_line ADD CONSTRAINT fk_sol_variant
  FOREIGN KEY (variant_id) REFERENCES product_variant (variant_id);
ALTER TABLE sales_order_line ADD CONSTRAINT fk_sol_tax_rate
  FOREIGN KEY (tax_rate_id) REFERENCES tax_rate (tax_rate_id);
ALTER TABLE sales_order_line ADD CONSTRAINT fk_sol_location
  FOREIGN KEY (fulfil_location_id) REFERENCES inventory_location (location_id);

ALTER TABLE order_payment ADD CONSTRAINT fk_payment_order
  FOREIGN KEY (order_id) REFERENCES sales_order (order_id);
ALTER TABLE order_payment ADD CONSTRAINT fk_payment_currency
  FOREIGN KEY (currency_code) REFERENCES currency (currency_code);

ALTER TABLE shipment ADD CONSTRAINT fk_shipment_order
  FOREIGN KEY (order_id) REFERENCES sales_order (order_id);
ALTER TABLE shipment ADD CONSTRAINT fk_shipment_carrier
  FOREIGN KEY (carrier_code) REFERENCES carrier (carrier_code);
ALTER TABLE shipment ADD CONSTRAINT fk_shipment_location
  FOREIGN KEY (from_location_id) REFERENCES inventory_location (location_id);

ALTER TABLE shipment_line ADD CONSTRAINT fk_shipline_shipment
  FOREIGN KEY (shipment_id) REFERENCES shipment (shipment_id);

-- Into the reference-partitioned child's composite key.
ALTER TABLE shipment_line ADD CONSTRAINT fk_shipline_order_line
  FOREIGN KEY (order_id, order_line_no) REFERENCES sales_order_line (order_id, line_no);

-- I. Returns
ALTER TABLE return_request ADD CONSTRAINT fk_return_order
  FOREIGN KEY (order_id) REFERENCES sales_order (order_id);
ALTER TABLE return_request ADD CONSTRAINT fk_return_customer
  FOREIGN KEY (customer_id) REFERENCES customer (customer_id);
ALTER TABLE return_request ADD CONSTRAINT fk_return_store
  FOREIGN KEY (store_id) REFERENCES store (store_id);
ALTER TABLE return_request ADD CONSTRAINT fk_return_currency
  FOREIGN KEY (currency_code) REFERENCES currency (currency_code);
ALTER TABLE return_request ADD CONSTRAINT fk_return_approver
  FOREIGN KEY (approved_by_employee_id) REFERENCES employee (employee_id);

ALTER TABLE return_line ADD CONSTRAINT fk_retline_return
  FOREIGN KEY (return_id) REFERENCES return_request (return_id);
ALTER TABLE return_line ADD CONSTRAINT fk_retline_order_line
  FOREIGN KEY (order_id, order_line_no) REFERENCES sales_order_line (order_id, line_no);
ALTER TABLE return_line ADD CONSTRAINT fk_retline_variant
  FOREIGN KEY (variant_id) REFERENCES product_variant (variant_id);
ALTER TABLE return_line ADD CONSTRAINT fk_retline_reason
  FOREIGN KEY (reason_code) REFERENCES return_reason (reason_code);

-- J. Finance and general ledger
ALTER TABLE gl_account ADD CONSTRAINT fk_gl_account_parent
  FOREIGN KEY (parent_account_code) REFERENCES gl_account (account_code);
ALTER TABLE gl_account ADD CONSTRAINT fk_gl_account_currency
  FOREIGN KEY (currency_code) REFERENCES currency (currency_code);

ALTER TABLE gl_journal ADD CONSTRAINT fk_journal_period
  FOREIGN KEY (period_id) REFERENCES gl_period (period_id);
ALTER TABLE gl_journal ADD CONSTRAINT fk_journal_reversal
  FOREIGN KEY (reversal_of_journal_id) REFERENCES gl_journal (journal_id);

ALTER TABLE gl_journal_line ADD CONSTRAINT fk_gljl_journal
  FOREIGN KEY (journal_id) REFERENCES gl_journal (journal_id);
ALTER TABLE gl_journal_line ADD CONSTRAINT fk_gljl_account
  FOREIGN KEY (account_code) REFERENCES gl_account (account_code);
ALTER TABLE gl_journal_line ADD CONSTRAINT fk_gljl_store
  FOREIGN KEY (store_id) REFERENCES store (store_id);
ALTER TABLE gl_journal_line ADD CONSTRAINT fk_gljl_currency
  FOREIGN KEY (currency_code) REFERENCES currency (currency_code);

-- T-07. A foreign key whose child column is quoted mixed-case and whose parent
-- column is not. Both sides have to be spelled correctly after conversion.
ALTER TABLE "StoreAudit_Legacy" ADD CONSTRAINT fk_storeaudit_store
  FOREIGN KEY ("StoreId") REFERENCES store (store_id);

--------------------------------------------------------------------------------
-- 4. Check constraints
--------------------------------------------------------------------------------
prompt -- 4. Check constraints

-- A. Reference and geography
ALTER TABLE currency ADD CONSTRAINT ck_currency_active
  CHECK (is_active IN ('Y', 'N'));
ALTER TABLE currency ADD CONSTRAINT ck_currency_minor_units
  CHECK (minor_units BETWEEN 0 AND 4);

ALTER TABLE exchange_rate ADD CONSTRAINT ck_rate_positive
  CHECK (rate > 0);
ALTER TABLE exchange_rate ADD CONSTRAINT ck_rate_not_self
  CHECK (from_currency <> to_currency);

ALTER TABLE region ADD CONSTRAINT ck_region_level
  CHECK (region_level IN ('GLOBAL', 'AREA', 'COUNTRY', 'DISTRICT', 'CLUSTER'));

ALTER TABLE calendar_day ADD CONSTRAINT ck_calendar_period
  CHECK (fiscal_period BETWEEN 1 AND 12
         AND fiscal_week BETWEEN 1 AND 53
         AND day_of_week BETWEEN 1 AND 7);

ALTER TABLE tax_rate ADD CONSTRAINT ck_tax_rate_window
  CHECK (valid_to IS NULL OR valid_to > valid_from);

-- B. Party, employees, stores
ALTER TABLE store ADD CONSTRAINT ck_store_format
  CHECK (store_format IN ('HYPER', 'SUPER', 'EXPRESS', 'OUTLET', 'ONLINE'));
ALTER TABLE store ADD CONSTRAINT ck_store_dates
  CHECK (closed_date IS NULL OR closed_date >= opened_date);

ALTER TABLE employee ADD CONSTRAINT ck_employee_dates
  CHECK (termination_date IS NULL OR termination_date >= hire_date);

-- C. Product catalogue
ALTER TABLE product ADD CONSTRAINT ck_product_status
  CHECK (status IN ('DRAFT', 'ACTIVE', 'DISCONTINUED', 'DELETED'));
ALTER TABLE product ADD CONSTRAINT ck_product_costs
  CHECK (unit_cost >= 0 AND list_price >= 0);

-- NON-TRIVIAL EXPRESSION 1 of 3, and a genuine conversion trap.
--
-- TRANSLATE(x, 'A0123456789', 'A') keeps the sentinel 'A' and deletes every
-- digit; if what remains is empty, the string was all digits. This is the
-- classic Oracle "is numeric" idiom, and it works only because Oracle returns
-- NULL for a zero-length string. PostgreSQL's translate() returns '', which is
-- not NULL, so a mechanically converted constraint rejects every barcode ever
-- inserted. Hard case H-38 wearing a check constraint's clothes.
ALTER TABLE product_variant ADD CONSTRAINT ck_variant_barcode_numeric
  CHECK (barcode_ean13 IS NULL
         OR (LENGTH(barcode_ean13) = 13
             AND TRANSLATE(barcode_ean13, 'A0123456789', 'A') IS NULL));

ALTER TABLE product_variant ADD CONSTRAINT ck_variant_pack_qty
  CHECK (pack_qty > 0);

-- D. Supplier and procurement
ALTER TABLE supplier ADD CONSTRAINT ck_supplier_rating
  CHECK (rating IS NULL OR rating BETWEEN 0 AND 10);
ALTER TABLE supplier ADD CONSTRAINT ck_supplier_approved
  CHECK (is_approved IN ('Y', 'N'));

ALTER TABLE purchase_order ADD CONSTRAINT ck_po_status
  CHECK (status IN ('DRAFT', 'SENT', 'PART_RECV', 'RECEIVED', 'CANCELLED'));

ALTER TABLE purchase_order_line ADD CONSTRAINT ck_pol_qty
  CHECK (qty_ordered > 0);
ALTER TABLE purchase_order_line ADD CONSTRAINT ck_pol_received
  CHECK (qty_received >= 0);

ALTER TABLE goods_receipt ADD CONSTRAINT ck_gr_quantities
  CHECK (qty_received >= 0 AND qty_rejected >= 0);

-- E. Inventory
ALTER TABLE inventory_location ADD CONSTRAINT ck_location_type
  CHECK (location_type IN ('BACKROOM', 'SHELF', 'BULK', 'PICKFACE', 'QUARANTINE', 'TRANSIT'));

-- NON-TRIVIAL EXPRESSION 2 of 3. A bin belongs to a warehouse or to a store,
-- never both and never neither. The design contract writes this as
-- (warehouse_id IS NULL) <> (store_id IS NULL), which is not legal Oracle SQL --
-- booleans are not first-class outside PL/SQL -- so it is spelled out as an
-- exclusive or. PostgreSQL would accept the shorter form, making this a rare
-- case where the converted constraint could be more readable than the original
-- if a human takes the opportunity.
ALTER TABLE inventory_location ADD CONSTRAINT ck_location_owner
  CHECK ((warehouse_id IS NOT NULL AND store_id IS NULL)
      OR (warehouse_id IS NULL     AND store_id IS NOT NULL));

-- Negative on-hand is legal here ON PURPOSE, and that is why this constraint does
-- not say qty_on_hand >= 0 AND qty_reserved <= qty_on_hand. An unrecorded shrink,
-- or a receipt booked after the sale that consumed it, leaves real retail systems
-- with negative stock every day. More importantly for this lab: qty_available is a
-- VIRTUAL column (qty_on_hand - qty_reserved), and it can only ever go negative if
-- this constraint permits it. trg_cmp_inventory_stock and the NEGATIVE_AVAILABLE
-- data-quality rule exist solely to detect that case -- tighten the constraint and
-- both become unreachable code that still converts perfectly cleanly. Silent loss
-- of a whole code path, with a green report, is exactly what this lab is for.
-- What is still enforced: reservations are never negative, and the reorder pair is
-- sane. The two NULL-guarded implications are the interesting half for a converter,
-- because PostgreSQL evaluates a CHECK that is UNKNOWN as satisfied just like
-- Oracle does -- but only if the NULL guards survive the rewrite intact.
ALTER TABLE inventory_stock ADD CONSTRAINT ck_stock_quantities
  CHECK (qty_reserved >= 0
         AND (reorder_point IS NULL OR reorder_point >= 0)
         AND (reorder_qty   IS NULL OR reorder_qty   > 0));

ALTER TABLE inventory_movement ADD CONSTRAINT ck_movement_type
  CHECK (movement_type IN ('RECEIPT', 'SALE', 'RETURN', 'TRANSFER', 'ADJUST', 'SHRINK', 'COUNT'));
-- A movement of exactly zero is only meaningful for a stock count: the count that
-- confirmed the book figure still has to be recorded, because "we looked and it was
-- right" is an audit fact. Everything else has to move something. Written as an
-- implication over two columns rather than the flat qty <> 0 it replaces -- partly
-- because that is the truthful rule, and partly because the zero-quantity COUNT rows
-- in the seed data are deliberate: they are what make an average or a ratio divide
-- by zero downstream once someone "simplifies" a NULLIF away.
ALTER TABLE inventory_movement ADD CONSTRAINT ck_movement_qty
  CHECK (qty <> 0 OR movement_type = 'COUNT');

-- F. Customer and loyalty
ALTER TABLE customer ADD CONSTRAINT ck_customer_status
  CHECK (status IN ('ACTIVE', 'DORMANT', 'CLOSED', 'ERASED'));
ALTER TABLE customer ADD CONSTRAINT ck_customer_optin
  CHECK (marketing_optin IN ('Y', 'N'));

ALTER TABLE customer_address ADD CONSTRAINT ck_custaddr_type
  CHECK (address_type IN ('HOME', 'WORK', 'BILLING', 'SHIPPING', 'OTHER'));

ALTER TABLE loyalty_account ADD CONSTRAINT ck_loyalty_points
  CHECK (points_balance >= 0);

ALTER TABLE loyalty_transaction ADD CONSTRAINT ck_loytxn_type
  CHECK (txn_type IN ('ACCRUE', 'REDEEM', 'EXPIRE', 'ADJUST', 'TRANSFER'));

-- G. Pricing and promotions
-- NON-TRIVIAL EXPRESSION 3 of 3. A markdown must quote a higher previous price,
-- and a previous price is only meaningful alongside a reason code. Four columns,
-- three interacting rules, two of them implications rather than range tests --
-- the shape that converters render plausibly and reviewers stop reading halfway
-- through.
ALTER TABLE price_list_item ADD CONSTRAINT ck_pli_markdown
  CHECK (unit_price >= 0
         AND (effective_to IS NULL OR effective_to > effective_from)
         AND (price_reason_code IS NULL
              OR price_reason_code <> 'MARKDOWN'
              OR (was_price IS NOT NULL AND was_price > unit_price))
         AND (was_price IS NULL OR price_reason_code IS NOT NULL));

ALTER TABLE promotion ADD CONSTRAINT ck_promo_type
  CHECK (promo_type IN ('PCT_OFF', 'AMT_OFF', 'BOGO', 'BUNDLE', 'THRESHOLD', 'LOYALTY_X'));

-- A check constraint over two TIMESTAMP WITH LOCAL TIME ZONE columns. Both are
-- normalised to the database time zone on storage, so the comparison is stable;
-- after conversion both are timestamptz in UTC and it still is. One of the few
-- H-37 constructs that genuinely carries over unchanged.
ALTER TABLE promotion ADD CONSTRAINT ck_promotion_window
  CHECK (end_ts > start_ts);

ALTER TABLE promotion ADD CONSTRAINT ck_promotion_budget
  CHECK (budget_amount IS NULL OR budget_amount >= 0);

ALTER TABLE promotion_product ADD CONSTRAINT ck_promoprod_discount
  CHECK (discount_pct IS NOT NULL OR discount_amount IS NOT NULL);

ALTER TABLE coupon ADD CONSTRAINT ck_coupon_redemptions
  CHECK (redemption_count <= max_redemptions);

-- H. Orders and fulfilment
ALTER TABLE sales_order ADD CONSTRAINT ck_so_channel
  CHECK (channel_code IN ('POS', 'WEB', 'APP', 'CALL', 'KIOSK', 'PARTNER'));
ALTER TABLE sales_order ADD CONSTRAINT ck_so_status
  CHECK (status IN ('CART', 'PLACED', 'PICKING', 'SHIPPED', 'DELIVERED', 'CANCELLED', 'RETURNED'));

ALTER TABLE sales_order_line ADD CONSTRAINT ck_sol_qty
  CHECK (qty > 0);

ALTER TABLE order_payment ADD CONSTRAINT ck_payment_method
  CHECK (payment_method IN ('CARD', 'CASH', 'VOUCHER', 'LOYALTY', 'GIFTCARD', 'BNPL', 'ACCOUNT'));

ALTER TABLE shipment_line ADD CONSTRAINT ck_shipline_qty
  CHECK (qty_shipped > 0);

-- I. Returns
ALTER TABLE return_request ADD CONSTRAINT ck_return_status
  CHECK (status IN ('REQUESTED', 'APPROVED', 'REJECTED', 'RECEIVED', 'REFUNDED', 'CLOSED'));

ALTER TABLE return_line ADD CONSTRAINT ck_retline_disposition
  CHECK (disposition_code IN ('RESTOCK', 'SCRAP', 'REPAIR', 'SUPPLIER', 'DONATE'));
ALTER TABLE return_line ADD CONSTRAINT ck_retline_qty
  CHECK (qty_returned > 0);

-- J. Finance and general ledger
ALTER TABLE gl_account ADD CONSTRAINT ck_gl_account_type
  CHECK (account_type IN ('ASSET', 'LIABILITY', 'EQUITY', 'REVENUE', 'EXPENSE'));
ALTER TABLE gl_account ADD CONSTRAINT ck_gl_normal_balance
  CHECK (normal_balance IN ('D', 'C'));

ALTER TABLE gl_period ADD CONSTRAINT ck_gl_period_status
  CHECK (status IN ('FUTURE', 'OPEN', 'CLOSING', 'CLOSED'));
ALTER TABLE gl_period ADD CONSTRAINT ck_gl_period_dates
  CHECK (period_end >= period_start);

ALTER TABLE gl_journal ADD CONSTRAINT ck_journal_source
  CHECK (source_module IN ('SALES', 'RETURNS', 'PURCHASING', 'INVENTORY', 'PAYROLL', 'MANUAL'));
ALTER TABLE gl_journal ADD CONSTRAINT ck_journal_status
  CHECK (status IN ('DRAFT', 'POSTED', 'REVERSED'));

-- A line is a debit or a credit, never both.
ALTER TABLE gl_journal_line ADD CONSTRAINT ck_gljl_debit_or_credit
  CHECK (debit_amount = 0 OR credit_amount = 0);
ALTER TABLE gl_journal_line ADD CONSTRAINT ck_gljl_signs
  CHECK (debit_amount >= 0 AND credit_amount >= 0);

-- K. Operational and audit
ALTER TABLE audit_log ADD CONSTRAINT ck_audit_action
  CHECK (action_type IN ('I', 'U', 'D'));

ALTER TABLE job_run_log ADD CONSTRAINT ck_job_run_status
  CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED', 'SKIPPED'));

ALTER TABLE app_parameter ADD CONSTRAINT ck_app_param_type
  CHECK (param_type IN ('STRING', 'NUMBER', 'DATE', 'BOOLEAN'));

ALTER TABLE data_quality_issue ADD CONSTRAINT ck_dq_severity
  CHECK (severity IN ('INFO', 'WARN', 'ERROR', 'FATAL'));

--------------------------------------------------------------------------------
-- Verification.
--
-- Counts are over generated = 'USER NAME' only, so the system-generated NOT NULL
-- check constraints that Oracle creates behind every NOT NULL column do not
-- inflate the check total.
--------------------------------------------------------------------------------
DECLARE
  l_pk      PLS_INTEGER;
  l_uk      PLS_INTEGER;
  l_fk      PLS_INTEGER;
  l_ck      PLS_INTEGER;
  l_selfref PLS_INTEGER;
  l_notenab PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_pk FROM user_constraints
   WHERE constraint_type = 'P' AND generated = 'USER NAME';

  SELECT COUNT(*) INTO l_uk FROM user_constraints
   WHERE constraint_type = 'U' AND generated = 'USER NAME';

  SELECT COUNT(*) INTO l_fk FROM user_constraints
   WHERE constraint_type = 'R' AND generated = 'USER NAME';

  SELECT COUNT(*) INTO l_ck FROM user_constraints
   WHERE constraint_type = 'C' AND generated = 'USER NAME';

  -- A foreign key is self-referencing when the key it points at lives on the
  -- same table.
  SELECT COUNT(*) INTO l_selfref
    FROM user_constraints c
    JOIN user_constraints p ON p.constraint_name = c.r_constraint_name
   WHERE c.constraint_type = 'R'
     AND c.generated = 'USER NAME'
     AND p.table_name = c.table_name;

  SELECT COUNT(*) INTO l_notenab FROM user_constraints
   WHERE generated = 'USER NAME' AND status <> 'ENABLED';

  DBMS_OUTPUT.PUT_LINE('Primary keys .......: ' || l_pk);
  DBMS_OUTPUT.PUT_LINE('Unique keys ........: ' || l_uk);
  DBMS_OUTPUT.PUT_LINE('Foreign keys .......: ' || l_fk);
  DBMS_OUTPUT.PUT_LINE('  self-referencing .: ' || l_selfref || ' (expected 6)');
  DBMS_OUTPUT.PUT_LINE('Check constraints ..: ' || l_ck);

  IF l_notenab > 0 THEN
    RAISE_APPLICATION_ERROR(-20030,
      l_notenab || ' constraint(s) are not ENABLED after 03-constraints.sql.');
  END IF;

  IF l_selfref <> 6 THEN
    RAISE_APPLICATION_ERROR(-20031,
      'Expected 6 self-referencing foreign keys (design section 4.1), found '
      || l_selfref || '.');
  END IF;

  -- The circular pair of design section 4.2 must all three be present, or the
  -- ordering trap the lab depends on does not exist.
  FOR c IN (SELECT column_value AS cname
              FROM TABLE(SYS.ODCIVARCHAR2LIST('FK_REGION_MANAGER',
                                              'FK_EMPLOYEE_STORE',
                                              'FK_STORE_REGION')))
  LOOP
    DECLARE
      l_n PLS_INTEGER;
    BEGIN
      SELECT COUNT(*) INTO l_n FROM user_constraints
       WHERE constraint_name = c.cname AND constraint_type = 'R';
      IF l_n <> 1 THEN
        RAISE_APPLICATION_ERROR(-20032,
          'Circular foreign key ' || c.cname || ' is missing (design section 4.2).');
      END IF;
    END;
  END LOOP;
END;
/

prompt
prompt 03-constraints.sql complete: primary, unique, foreign and check constraints applied.
prompt