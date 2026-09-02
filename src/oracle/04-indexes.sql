--------------------------------------------------------------------------------
-- Contoso Store -- Oracle to Azure Database for PostgreSQL migration lab
-- 04-indexes.sql
--
-- Secondary indexes: b-tree, composite, unique, function-based, bitmap,
-- descending, local partitioned and global partitioned.
--
-- Runs as CONTOSO, after 03-constraints.sql, before 05-sequences.sql.
--
-- Primary key and unique constraint indexes are NOT here -- Oracle created them
-- implicitly in 02-tables.sql and 03-constraints.sql. This file adds the
-- indexes an application would add: foreign key covers to stop unindexed-FK
-- locking, the reporting access paths, and the deliberately awkward shapes the
-- lab exists to test.
--
-- Hard cases carried:
--   H-16  nine function-based indexes. Expression indexes exist in PostgreSQL
--         and mostly convert, but PostgreSQL will only index an expression it
--         considers IMMUTABLE, and Oracle's DETERMINISTIC is an unverified
--         promise. See the note on fbi_product_sku_norm at the end of this file.
--   H-19  a LOCAL index on a partitioned table and a GLOBAL PARTITIONED index,
--         neither of which has a PostgreSQL analogue in the same shape: PG has
--         only per-partition local indexes and no global index at all.
--   T-06  optimiser hints elsewhere in the schema depend on some of these; a
--         hint referencing an index that did not convert is silently ignored.
--
-- Note on descending indexes: Oracle implements a DESC index as a function-based
-- index internally, so ix_sales_order_ts_desc shows up in USER_INDEXES with
-- INDEX_TYPE = 'FUNCTION-BASED NORMAL'. That is why the verification block at
-- the end counts the nine hand-written FBIs by name rather than by index type.
--------------------------------------------------------------------------------

SET SQLBLANKLINES ON
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

prompt
prompt ================================================================
prompt  04-indexes.sql : secondary, function-based, bitmap, partitioned
prompt ================================================================

--------------------------------------------------------------------------------
-- Re-runnability. Drop only the indexes this file creates -- never the ones
-- backing a constraint, which belong to 03-constraints.sql and cannot be dropped
-- directly anyway. ORA-01418 "specified index does not exist" is swallowed and
-- nothing else is.
--
-- Two exclusions matter once the whole schema is loaded and someone re-runs just
-- this file:
--   * FBI_PRODUCT_SKU_NORM is created by the standalone-routines file, not this
--     one, because it depends on fn_normalise_sku. Dropping it here would delete
--     another file's object and leave it gone.
--   * Indexes on materialised view containers are owned by the materialised view
--     file. Their names can match these patterns, so they are filtered out by
--     table rather than by name.
--------------------------------------------------------------------------------
DECLARE
  l_dropped  PLS_INTEGER := 0;

  e_no_such_index EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_no_such_index, -1418);
BEGIN
  FOR r IN (SELECT i.index_name
              FROM user_indexes i
             WHERE (i.index_name LIKE 'IX\_%' ESCAPE '\'
                 OR i.index_name LIKE 'FBI\_%' ESCAPE '\'
                 OR i.index_name LIKE 'BMP\_%' ESCAPE '\')
               AND i.constraint_index = 'NO'
               AND i.index_name <> 'FBI_PRODUCT_SKU_NORM'
               AND NOT EXISTS (SELECT 1 FROM user_mviews m
                                WHERE m.mview_name = i.table_name))
  LOOP
    BEGIN
      EXECUTE IMMEDIATE 'DROP INDEX ' || r.index_name;
      l_dropped := l_dropped + 1;
    EXCEPTION
      WHEN e_no_such_index THEN
        NULL;
    END;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('Pre-existing secondary indexes dropped: ' || l_dropped);
END;
/

prompt
prompt -- 1. Foreign key covering indexes (b-tree) ====================

--------------------------------------------------------------------------------
-- An unindexed foreign key makes Oracle take a share lock on the whole child
-- table when the parent key changes. Every real schema of this age has these,
-- and they are the least interesting indexes to convert -- which is exactly why
-- they belong in the sample.
--------------------------------------------------------------------------------
CREATE INDEX ix_region_country       ON region (country_code);
CREATE INDEX ix_region_parent        ON region (parent_region_id);
CREATE INDEX ix_region_manager       ON region (manager_employee_id);

CREATE INDEX ix_address_country      ON address (country_code);
CREATE INDEX ix_employee_store       ON employee (store_id);
CREATE INDEX ix_employee_manager     ON employee (manager_id);
CREATE INDEX ix_store_region         ON store (region_id);
CREATE INDEX ix_store_address        ON store (address_id);
CREATE INDEX ix_store_manager        ON store (manager_employee_id);

CREATE INDEX ix_category_parent      ON product_category (parent_category_id);
CREATE INDEX ix_brand_supplier       ON brand (owner_supplier_id);
CREATE INDEX ix_product_category     ON product (category_id);
CREATE INDEX ix_product_brand        ON product (brand_id);
CREATE INDEX ix_variant_product      ON product_variant (product_id);

CREATE INDEX ix_supplier_address     ON supplier (address_id);
CREATE INDEX ix_sp_variant           ON supplier_product (variant_id);
CREATE INDEX ix_po_supplier          ON purchase_order (supplier_id);
CREATE INDEX ix_po_warehouse         ON purchase_order (warehouse_id);
CREATE INDEX ix_pol_variant          ON purchase_order_line (variant_id);
CREATE INDEX ix_gr_po_line           ON goods_receipt (po_id, po_line_no);
CREATE INDEX ix_gr_warehouse         ON goods_receipt (warehouse_id);

CREATE INDEX ix_warehouse_region     ON warehouse (region_id);
CREATE INDEX ix_invloc_warehouse     ON inventory_location (warehouse_id);
CREATE INDEX ix_invloc_store         ON inventory_location (store_id);
CREATE INDEX ix_invloc_parent        ON inventory_location (parent_location_id);
CREATE INDEX ix_stock_variant        ON inventory_stock (variant_id);

CREATE INDEX ix_customer_country     ON customer (home_country_code);
CREATE INDEX ix_customer_store       ON customer (preferred_store_id);
CREATE INDEX ix_custaddr_address     ON customer_address (address_id);
CREATE INDEX ix_loyalty_tier         ON loyalty_account (tier_code);

CREATE INDEX ix_pricelist_country    ON price_list (country_code);
CREATE INDEX ix_pli_variant          ON price_list_item (variant_id);
CREATE INDEX ix_pli_tax_rate         ON price_list_item (tax_rate_id);
CREATE INDEX ix_promoprod_variant    ON promotion_product (variant_id);
CREATE INDEX ix_coupon_promotion     ON coupon (promotion_id);
CREATE INDEX ix_coupon_customer      ON coupon (customer_id);

CREATE INDEX ix_so_customer          ON sales_order (customer_id);
CREATE INDEX ix_so_store             ON sales_order (store_id);
CREATE INDEX ix_sol_variant          ON sales_order_line (variant_id);
CREATE INDEX ix_payment_order        ON order_payment (order_id);
CREATE INDEX ix_shipment_order       ON shipment (order_id);
CREATE INDEX ix_shipment_carrier     ON shipment (carrier_code);
CREATE INDEX ix_shipline_order_line  ON shipment_line (order_id, order_line_no);

CREATE INDEX ix_return_order         ON return_request (order_id);
CREATE INDEX ix_return_customer      ON return_request (customer_id);
CREATE INDEX ix_retline_order_line   ON return_line (order_id, order_line_no);
CREATE INDEX ix_retline_reason       ON return_line (reason_code);

CREATE INDEX ix_glaccount_parent     ON gl_account (parent_account_code);
CREATE INDEX ix_journal_period       ON gl_journal (period_id);
CREATE INDEX ix_journal_reversal     ON gl_journal (reversal_of_journal_id);
CREATE INDEX ix_glline_account       ON gl_journal_line (account_code);
CREATE INDEX ix_glline_store         ON gl_journal_line (store_id);

prompt -- 2. Composite access-path indexes ===========================

--------------------------------------------------------------------------------
-- Multi-column indexes backing the real query shapes: price resolution, stock
-- lookup, order history, audit search. Column order matters and is the thing a
-- converter cannot check for you.
--------------------------------------------------------------------------------
CREATE INDEX ix_pli_lookup ON price_list_item (variant_id, effective_from, effective_to);

CREATE INDEX ix_price_list_window ON price_list (country_code, channel_code, valid_from, valid_to);

CREATE INDEX ix_stock_reorder ON inventory_stock (variant_id, qty_on_hand, reorder_point);

CREATE INDEX ix_so_store_ts ON sales_order (store_id, order_ts, status);

CREATE INDEX ix_so_customer_ts ON sales_order (customer_id, order_ts);

CREATE INDEX ix_sol_line_lookup ON sales_order_line (variant_id, status);

CREATE INDEX ix_supplier_product_source
  ON supplier_product (variant_id, is_primary_source, valid_from);

CREATE INDEX ix_employee_name ON employee (last_name, first_name);

CREATE INDEX ix_audit_lookup ON audit_log (table_name, pk_value, changed_ts);

CREATE INDEX ix_error_module ON error_log (module_name, routine_name, logged_ts);

CREATE INDEX ix_job_run_lookup ON job_run_log (job_name, started_ts, status);

CREATE INDEX ix_dq_issue_lookup ON data_quality_issue (rule_code, entity_name, detected_ts);

prompt -- 3. Unique secondary indexes =================================

--------------------------------------------------------------------------------
-- Unique indexes that are NOT unique constraints. Oracle treats the two almost
-- identically; the difference shows up in the catalogue and in what a converter
-- emits -- a CREATE UNIQUE INDEX rather than an ALTER TABLE ADD CONSTRAINT.
--------------------------------------------------------------------------------
CREATE UNIQUE INDEX ix_carrier_name ON carrier (carrier_name);

CREATE UNIQUE INDEX ix_gl_account_name ON gl_account (account_name);

prompt -- 4. Function-based indexes (H-16) ============================

--------------------------------------------------------------------------------
-- FBI 1. The dedupe key on address. normalised_key is a virtual column, so this
-- is a plain CREATE UNIQUE INDEX in the source text but Oracle records it as
-- FUNCTION-BASED. It converts to a unique index over a GENERATED ALWAYS AS
-- STORED column, which is the clean case.
--------------------------------------------------------------------------------
CREATE UNIQUE INDEX fbi_address_norm_key ON address (normalised_key);

--------------------------------------------------------------------------------
-- FBI 2. Customer email uniqueness, case-insensitive. There is no unique
-- CONSTRAINT on customer.email precisely so that this index is the only thing
-- enforcing it -- a converter that drops the index silently drops the rule.
--------------------------------------------------------------------------------
CREATE UNIQUE INDEX fbi_customer_email_lower ON customer (LOWER(email));

--------------------------------------------------------------------------------
-- FBI 3. The unique index that makes ck_invloc_owner enforceable. NVL collapses
-- the two mutually exclusive parents into one key. NVL converts to COALESCE,
-- but note that NVL evaluates both arguments and COALESCE short-circuits (H-31).
--------------------------------------------------------------------------------
CREATE UNIQUE INDEX fbi_invloc_owner_code
  ON inventory_location (NVL(warehouse_id, 0), NVL(store_id, 0), location_code);

--------------------------------------------------------------------------------
-- FBI 4. Date truncation for the monthly GL roll-up. TRUNC(date, 'MM') is safe
-- to index because it does not depend on any NLS setting -- TRUNC(date, 'DAY')
-- would, because the first day of the week is territory-dependent, and Oracle
-- would still let you build the index.
--------------------------------------------------------------------------------
CREATE INDEX fbi_gl_journal_month ON gl_journal (TRUNC(journal_date, 'MM'));

--------------------------------------------------------------------------------
-- FBI 5. A DECODE expression (H-31). DECODE treats NULL = NULL as a match, which
-- CASE x WHEN does not, so the correct conversion needs IS NOT DISTINCT FROM or
-- an explicit null branch -- and an index built on the wrong one returns the
-- wrong rows rather than failing.
--------------------------------------------------------------------------------
CREATE INDEX fbi_product_status_rank
  ON product (DECODE(status, 'ACTIVE', 1, 'DRAFT', 2, 'DISCONTINUED', 3, 9), category_id);

--------------------------------------------------------------------------------
-- FBI 6-8. Case-insensitive search keys. The plain shape of H-16, included so
-- the findings can contrast something that converts cleanly with the harder
-- cases above and below.
--------------------------------------------------------------------------------
CREATE INDEX fbi_employee_name_upper ON employee (UPPER(last_name), UPPER(first_name));

CREATE INDEX fbi_supplier_name_upper ON supplier (UPPER(supplier_name));

CREATE INDEX fbi_store_code_upper ON store (UPPER(store_code));

--------------------------------------------------------------------------------
-- FBI 9. A partial index in Oracle clothing. Oracle has no WHERE clause on
-- CREATE INDEX, so the idiom is a CASE expression that evaluates to NULL for
-- rows you do not want -- entirely NULL keys are not stored in a b-tree, so only
-- live promotions are indexed. PostgreSQL has real partial indexes, so the
-- idiomatic conversion is "CREATE INDEX ... WHERE status = 'ACTIVE'", which a
-- mechanical converter will not produce: it will emit the CASE expression and
-- index every row.
--------------------------------------------------------------------------------
CREATE INDEX fbi_promotion_active
  ON promotion (CASE WHEN status = 'ACTIVE' THEN country_code ELSE NULL END);

prompt -- 5. Bitmap indexes ==========================================

--------------------------------------------------------------------------------
-- Low-cardinality status and dimension columns. PostgreSQL has no persistent
-- bitmap index -- it builds bitmaps on the fly during a BitmapAnd scan -- so
-- these convert to plain b-trees and the storage and plan characteristics both
-- change. Bitmap indexes are also serialising for concurrent DML, which is why
-- they are on reference-ish columns here and not on sales_order.status.
--------------------------------------------------------------------------------
CREATE BITMAP INDEX bmp_product_status ON product (status);

-- Not on customer.home_country_code: ix_customer_country above already indexes
-- that exact column list, and Oracle rejects a second index over an identical
-- list with ORA-01408 regardless of index type. customer.status is the better
-- bitmap candidate anyway -- four values across millions of rows.
CREATE BITMAP INDEX bmp_customer_status ON customer (status);

CREATE BITMAP INDEX bmp_store_format ON store (store_format);

CREATE BITMAP INDEX bmp_journal_source ON gl_journal (source_module);

prompt -- 6. Partitioned indexes (H-19) ==============================

--------------------------------------------------------------------------------
-- LOCAL: one index partition per table partition, maintained automatically as
-- interval partitions materialise. This is the shape PostgreSQL does have -- a
-- partitioned index cascading to each partition -- so it converts.
--------------------------------------------------------------------------------
CREATE INDEX ix_move_variant_local
  ON inventory_movement (variant_id, movement_ts) LOCAL;

CREATE INDEX ix_loyaltytxn_account_local
  ON loyalty_transaction (loyalty_id, txn_ts) LOCAL;

--------------------------------------------------------------------------------
-- GLOBAL PARTITIONED: the index is partitioned on its OWN key, independently of
-- how the table is partitioned. PostgreSQL has no equivalent at all -- an index
-- there is either local to a partition or does not exist. Expect this to come
-- back as a plain index, losing the partition-level maintenance, or to be
-- dropped entirely.
--
-- A global partitioned index must have MAXVALUE as its highest bound.
--------------------------------------------------------------------------------
CREATE INDEX ix_move_reference_global
  ON inventory_movement (reference_id, reference_type)
  GLOBAL PARTITION BY RANGE (reference_id) (
    PARTITION p_mrg_1 VALUES LESS THAN (1000000),
    PARTITION p_mrg_2 VALUES LESS THAN (5000000),
    PARTITION p_mrg_max VALUES LESS THAN (MAXVALUE)
  );

CREATE INDEX ix_so_number_global
  ON sales_order (order_number)
  GLOBAL PARTITION BY HASH (order_number) PARTITIONS 4;

prompt -- 7. Descending index ========================================

--------------------------------------------------------------------------------
-- "Most recent orders first" without a sort. Oracle stores a DESC index as a
-- function-based index internally; PostgreSQL supports DESC natively in the
-- index definition, so this converts cleanly -- but see trap T-13: Oracle and
-- PostgreSQL disagree about where NULLs sort under DESC, so the index that
-- satisfies "ORDER BY order_ts DESC" on one may not satisfy it on the other
-- without an explicit NULLS FIRST / NULLS LAST.
--------------------------------------------------------------------------------
CREATE INDEX ix_sales_order_ts_desc ON sales_order (order_ts DESC, store_id);

CREATE INDEX ix_movement_ts_desc ON inventory_movement (movement_ts DESC) LOCAL;

--------------------------------------------------------------------------------
-- Deliberately NOT created here: fbi_product_sku_norm on fn_normalise_sku(sku).
--
-- design.md section 9 H-16 lists it as one of the nine function-based indexes,
-- but fn_normalise_sku is a standalone function created later in the load order,
-- so building the index here would fail with ORA-00904. It belongs in the file
-- that creates the standalone routines, immediately after the function.
--
-- It is the most interesting FBI in the schema and it must not be lost: Oracle
-- indexes it because fn_normalise_sku is marked DETERMINISTIC, which Oracle
-- never verifies. PostgreSQL will only index an expression whose function is
-- IMMUTABLE, which it takes very seriously. Mapping DETERMINISTIC to IMMUTABLE
-- mechanically is how a converter introduces a real bug (H-23).
--
-- The statement to add there is:
--   CREATE INDEX fbi_product_sku_norm ON product (fn_normalise_sku(sku));
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Verification.
--------------------------------------------------------------------------------
DECLARE
  l_total     PLS_INTEGER;
  l_fbi       PLS_INTEGER;
  l_bitmap    PLS_INTEGER;
  l_local     PLS_INTEGER;
  l_global    PLS_INTEGER;
  l_unusable  PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_total FROM user_indexes;

  -- Counted by name, not by INDEX_TYPE: Oracle also reports the two DESC
  -- indexes as FUNCTION-BASED, and they are not part of the H-16 set.
  SELECT COUNT(*) INTO l_fbi
    FROM user_indexes WHERE index_name LIKE 'FBI\_%' ESCAPE '\';

  SELECT COUNT(*) INTO l_bitmap
    FROM user_indexes WHERE index_type = 'BITMAP';

  SELECT COUNT(*) INTO l_local
    FROM user_part_indexes WHERE locality = 'LOCAL';

  SELECT COUNT(*) INTO l_global
    FROM user_part_indexes WHERE locality = 'GLOBAL';

  SELECT COUNT(*) INTO l_unusable
    FROM user_indexes WHERE status = 'UNUSABLE';

  DBMS_OUTPUT.PUT_LINE('Indexes in schema ..: ' || l_total);
  DBMS_OUTPUT.PUT_LINE('Function-based .....: ' || l_fbi    || ' (expected 9, 1 more in the routines file)');
  DBMS_OUTPUT.PUT_LINE('Bitmap .............: ' || l_bitmap || ' (expected 4)');
  DBMS_OUTPUT.PUT_LINE('Local partitioned ..: ' || l_local  || ' (expected 5)');
  DBMS_OUTPUT.PUT_LINE('Global partitioned .: ' || l_global || ' (expected 2)');

  IF l_unusable > 0 THEN
    RAISE_APPLICATION_ERROR(-20040, l_unusable || ' index(es) are UNUSABLE.');
  END IF;

  -- Lower bounds, not equality: the standalone-routines file adds a tenth
  -- function-based index (fbi_product_sku_norm) and the generator may add more
  -- indexes later. This file must not fail because the schema grew around it.
  IF l_fbi < 9 THEN
    RAISE_APPLICATION_ERROR(-20041,
      'Expected at least 9 function-based indexes for H-16, got ' || l_fbi || '.');
  END IF;

  IF l_bitmap < 4 THEN
    RAISE_APPLICATION_ERROR(-20042,
      'Expected at least 4 bitmap indexes, got ' || l_bitmap || '.');
  END IF;

  IF l_local < 1 OR l_global < 1 THEN
    RAISE_APPLICATION_ERROR(-20043,
      'H-19 needs at least one LOCAL and one GLOBAL partitioned index; got local='
      || l_local || ' global=' || l_global || '.');
  END IF;
END;
/

prompt
prompt 04-indexes.sql complete: secondary, composite, function-based, bitmap, partitioned and descending indexes created.
prompt
