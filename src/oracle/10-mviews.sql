-- =====================================================================================
-- Contoso Store -- Oracle source schema
-- 10-mviews.sql : materialised view logs, materialised views, refresh group
-- =====================================================================================
-- Owner        : CONTOSO
-- Depends on   : core tables (sales_order, sales_order_line, inventory_stock,
--                customer, supplier, purchase_order, product*, promotion)
-- Exercises    : H-15 (MV fast refresh + refresh groups), H-08 (analytics),
--                H-17 (virtual columns), H-19/H-20 (partitioned fact aggregation),
--                H-37 (TIMESTAMP WITH LOCAL TIME ZONE), T-02, T-09
--
-- Design contract: docs/design.md section 6.5 -- six materialised views, three
-- materialised view logs, one refresh group `rg_reporting`.
--
-- Every statement in this file that can fail because of a *privilege* the CONTOSO
-- user might lack degrades to a warning rather than aborting the seed. Statements
-- that can only fail because Oracle refuses a refresh mode cascade down to a weaker
-- refresh mode, which is itself a finding worth printing.
-- =====================================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET SQLBLANKLINES ON
SET DEFINE OFF
SET FEEDBACK ON

PROMPT
PROMPT ==========================================================================
PROMPT 10-mviews.sql : materialised view layer
PROMPT ==========================================================================

-- -------------------------------------------------------------------------------------
-- 0. Idempotency. Drop anything left over from a previous run. Never fatal.
-- -------------------------------------------------------------------------------------
DECLARE
  TYPE t_names IS TABLE OF VARCHAR2(30);
  l_mviews t_names := t_names('MV_SALES_DAILY_STORE',
                              'MV_SALES_MONTHLY_CATEGORY',
                              'MV_STOCK_POSITION',
                              'MV_CUSTOMER_RFM',
                              'MV_SUPPLIER_PERFORMANCE',
                              'MV_PROMOTION_UPLIFT');
  l_logs   t_names := t_names('SALES_ORDER', 'SALES_ORDER_LINE', 'INVENTORY_STOCK');
BEGIN
  BEGIN
    DBMS_REFRESH.DESTROY(name => USER || '.RG_REPORTING');
    DBMS_OUTPUT.PUT_LINE('cleanup: destroyed refresh group RG_REPORTING');
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  FOR i IN 1 .. l_mviews.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE 'DROP MATERIALIZED VIEW ' || l_mviews(i);
      DBMS_OUTPUT.PUT_LINE('cleanup: dropped ' || l_mviews(i));
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;

  FOR i IN 1 .. l_logs.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE 'DROP MATERIALIZED VIEW LOG ON ' || l_logs(i);
      DBMS_OUTPUT.PUT_LINE('cleanup: dropped MV log on ' || l_logs(i));
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
END;
/

-- =====================================================================================
-- 1. MATERIALISED VIEW LOGS
-- =====================================================================================
-- Three logs, per docs/design.md section 8 (they count as TABLE objects: MLOG$_*).
--
-- MIGRATION NOTE (H-15): PostgreSQL has no incremental materialised view refresh of any
-- kind. `REFRESH MATERIALIZED VIEW` is always a full recompute. The MLOG$_ tables that
-- back Oracle's fast refresh therefore convert to nothing useful -- they become dead
-- objects on the target and should be dropped, not translated. A converter that emits
-- three empty tables named MLOG$_SALES_ORDER etc. has produced technically-correct
-- garbage. Expect this as a review task.
--
-- MIGRATION NOTE (H-17): a materialised view log may not list a *virtual* column.
-- sales_order.order_total, sales_order_line.line_total and inventory_stock.qty_available
-- are all virtual, so they are absent below and the MVs recompute them from the base
-- columns instead. On PostgreSQL those same columns become GENERATED ALWAYS ... STORED,
-- which *are* selectable and would have been listed -- so the converted MV definitions
-- can legitimately be simpler than the Oracle originals.
--
-- Executed through EXECUTE IMMEDIATE rather than as bare DDL so that a log Oracle
-- refuses (sales_order_line is PARTITION BY REFERENCE, which some releases restrict)
-- costs the fast-refresh modes below and nothing else. The MVs cascade to COMPLETE and
-- the seed continues.
-- -------------------------------------------------------------------------------------
DECLARE
  TYPE t_ddl IS TABLE OF VARCHAR2(2000);
  l_ddl t_ddl := t_ddl(
q'[CREATE MATERIALIZED VIEW LOG ON sales_order
  WITH ROWID, SEQUENCE (order_id,
                        order_number,
                        customer_id,
                        store_id,
                        channel_code,
                        order_ts,
                        status,
                        currency_code,
                        subtotal_amount,
                        discount_amount,
                        tax_amount,
                        shipping_amount,
                        promotion_id)
  INCLUDING NEW VALUES]',

q'[CREATE MATERIALIZED VIEW LOG ON sales_order_line
  WITH ROWID, SEQUENCE (order_id,
                        line_no,
                        variant_id,
                        qty,
                        unit_price,
                        discount_amount,
                        tax_amount,
                        status)
  INCLUDING NEW VALUES]',

q'[CREATE MATERIALIZED VIEW LOG ON inventory_stock
  WITH ROWID, SEQUENCE (location_id,
                        variant_id,
                        qty_on_hand,
                        qty_reserved,
                        reorder_point,
                        reorder_qty,
                        last_movement_ts)
  INCLUDING NEW VALUES]');
  l_ok PLS_INTEGER := 0;
BEGIN
  FOR i IN 1 .. l_ddl.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE l_ddl(i);
      l_ok := l_ok + 1;
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('   *** WARNING *** MV log not created: '
                             || SUBSTR(SQLERRM, 1, 150));
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('   .. ' || l_ok || ' of 3 materialised view logs created');
  IF l_ok < 3 THEN
    DBMS_OUTPUT.PUT_LINE('   .. fast-refresh modes below will cascade to COMPLETE');
  END IF;
END;
/

-- =====================================================================================
-- 2. mv_sales_daily_store -- FAST REFRESH ON COMMIT
-- =====================================================================================
-- The hardest refresh mode Oracle offers and the one with no PostgreSQL analogue at all.
--
-- MIGRATION NOTE (H-15): `REFRESH FAST ON COMMIT` maintains the summary inside the
-- committing transaction. The nearest PostgreSQL construct is a trigger-maintained
-- summary *table* -- an AFTER INSERT/UPDATE/DELETE FOR EACH STATEMENT trigger over
-- transition tables doing an INSERT ... ON CONFLICT DO UPDATE against a real table.
-- That is a rewrite, not a translation, and it changes the locking profile of every
-- order commit. Do not accept a converter's `REFRESH MATERIALIZED VIEW` cron job as
-- equivalent: it is eventually consistent where the original was transactionally
-- consistent.
--
-- MIGRATION NOTE (H-37 / T-02): sales_order.order_ts is TIMESTAMP WITH LOCAL TIME ZONE.
-- TRUNC() on a TSLTZ converts using the *session* time zone, so the same row can land in
-- different daily buckets for two sessions in two countries. Contoso trades in 11
-- countries, so this is a live bug, not a hypothetical one. On PostgreSQL the equivalent
-- is date_trunc('day', order_ts AT TIME ZONE <store zone>) and the store's zone has to be
-- joined in explicitly from country.tz_name -- the implicit session dependency has to
-- become explicit or the numbers move. (Verified on 23ai: TRUNC over a TSLTZ does *not*
-- block fast refresh. It is a correctness problem, not a refresh problem.)
--
-- MIGRATION NOTE (H-17 + H-15, and this one is genuinely obscure): an aggregate over an
-- expression that happens to *match a virtual column's definition* cannot fast refresh.
-- sales_order_line.line_total is VIRTUAL and defined as
--     qty * unit_price - discount_amount + tax_amount
-- so SUM(sol.qty * sol.unit_price - sol.discount_amount + sol.tax_amount) is rewritten
-- internally to SUM(line_total), and a materialised view log may not contain a virtual
-- column. The result is ORA-12033 "cannot use filter columns from materialized view log"
-- at CREATE time, naming the log rather than the expression -- an error message that
-- points nowhere near the cause. SUM(sol.qty * sol.unit_price) is fine; adding the other
-- two terms is not.
--
-- The net figure is therefore *not* stored. Derive it as
--     gross_amount - discount_amount + tax_amount
-- which is identical arithmetic over the three columns that are stored. Worth knowing on
-- the target too: PostgreSQL generated columns are STORED and perfectly selectable, so
-- the converted materialised view can carry the net column that Oracle refused. The
-- conversion is allowed to be *better* than the original here, and a reviewer who does
-- not know why the column was missing will assume it was an oversight and add it back
-- without realising they have also removed the reason the Oracle MV was fast.
--
-- MIGRATION NOTE: the COUNT(expr) columns beside every SUM(expr) are not decoration.
-- Oracle requires them for a fast-refreshable aggregate MV. On PostgreSQL they are
-- dead weight and should be dropped, but only after confirming nothing downstream
-- selects them.
-- -------------------------------------------------------------------------------------
DECLARE
  TYPE t_clauses IS TABLE OF VARCHAR2(200);
  l_clauses t_clauses := t_clauses('REFRESH FAST ON COMMIT',
                                   'REFRESH FAST ON DEMAND',
                                   'REFRESH COMPLETE ON DEMAND');
  l_query   VARCHAR2(4000) := q'[
SELECT so.store_id                                        AS store_id
     , TRUNC(so.order_ts)                                 AS sales_date
     , so.currency_code                                   AS currency_code
     , COUNT(*)                                           AS line_count
     , SUM(sol.qty)                                       AS total_qty
     , COUNT(sol.qty)                                     AS total_qty_cnt
     , SUM(sol.qty * sol.unit_price)                      AS gross_amount
     , COUNT(sol.qty * sol.unit_price)                    AS gross_amount_cnt
     , SUM(sol.discount_amount)                           AS discount_amount
     , COUNT(sol.discount_amount)                         AS discount_amount_cnt
     , SUM(sol.tax_amount)                                AS tax_amount
     , COUNT(sol.tax_amount)                              AS tax_amount_cnt
  FROM sales_order      so
     , sales_order_line sol
 WHERE sol.order_id = so.order_id
 GROUP BY so.store_id, TRUNC(so.order_ts), so.currency_code]';
  l_created BOOLEAN := FALSE;
BEGIN
  -- MIGRATION NOTE: the join above is written with the Oracle comma/WHERE form rather
  -- than ANSI JOIN on purpose (H-32 lives next door in v_legacy_orders). It is an inner
  -- equijoin, which is what fast refresh requires; an outer join here would disqualify
  -- the MV from ON COMMIT refresh entirely. COUNT(DISTINCT ...) would too, which is why
  -- the distinct order count is absent and has to be derived downstream.
  FOR i IN 1 .. l_clauses.COUNT LOOP
    EXIT WHEN l_created;
    BEGIN
      EXECUTE IMMEDIATE 'CREATE MATERIALIZED VIEW mv_sales_daily_store'
                     || ' BUILD IMMEDIATE ' || l_clauses(i)
                     || ' AS ' || l_query;
      l_created := TRUE;
      DBMS_OUTPUT.PUT_LINE('   .. mv_sales_daily_store created : ' || l_clauses(i));
      IF i > 1 THEN
        DBMS_OUTPUT.PUT_LINE('   ** NOTE ** Oracle refused REFRESH FAST ON COMMIT here.');
        DBMS_OUTPUT.PUT_LINE('   **      ** Run DBMS_MVIEW.EXPLAIN_MVIEW on the query and');
        DBMS_OUTPUT.PUT_LINE('   **      ** read MV_CAPABILITIES_TABLE. On this schema the');
        DBMS_OUTPUT.PUT_LINE('   **      ** cause is an aggregate over an expression that');
        DBMS_OUTPUT.PUT_LINE('   **      ** matches a virtual column definition (ORA-12033).');
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('   .. ' || l_clauses(i) || ' rejected: '
                             || SUBSTR(SQLERRM, 1, 120));
    END;
  END LOOP;

  IF NOT l_created THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** mv_sales_daily_store was NOT created.');
    DBMS_OUTPUT.PUT_LINE('   ***         *** sql/99-verify-objects.sql will fail on this.');
  END IF;
END;
/

-- =====================================================================================
-- 3. mv_sales_monthly_category -- FAST ON DEMAND, aggregates the partitioned sales fact
-- =====================================================================================
-- Rolls the interval-partitioned sales_order / reference-partitioned sales_order_line
-- pair up the merchandise hierarchy. This is the MV that reads the partitioned fact.
--
-- MIGRATION NOTE (H-19/H-20): on the source, the optimiser prunes to the relevant
-- monthly interval partitions of sales_order and, through PARTITION BY REFERENCE, to
-- the matching partitions of sales_order_line. PostgreSQL has no PARTITION BY REFERENCE
-- (H-20), so once sales_order_line is independently partitioned on a *copied* order_ts
-- column, this query must join on that copied column as well as order_id or it will scan
-- every child partition. A converter will not add that predicate for you.
--
-- MIGRATION NOTE (H-15): docs/design.md section 6.5 lists this MV as FAST ON DEMAND.
-- Oracle refuses, with ORA-23413 "table CONTOSO.PRODUCT_CATEGORY does not have a
-- materialized view log", and the block below therefore lands on COMPLETE. That is not a
-- defect in the lab, it is the finding: fast refresh costs a materialised view log on
-- *every* base table including the dimensions, and this MV touches five. Adding three
-- more MLOG$ tables to satisfy the design table would buy a faster refresh and three
-- more dead objects to drop on the target. Left as COMPLETE deliberately so the trade-off
-- is visible rather than papered over -- see the note in the summary at the end of this
-- file, and docs/06-findings.md.
-- -------------------------------------------------------------------------------------
DECLARE
  TYPE t_clauses IS TABLE OF VARCHAR2(200);
  l_clauses t_clauses := t_clauses('REFRESH FAST ON DEMAND',
                                   'REFRESH COMPLETE ON DEMAND');
  l_query   VARCHAR2(4000) := q'[
SELECT TRUNC(so.order_ts, 'MM')                           AS month_start
     , pc.category_id                                     AS category_id
     , pc.category_code                                   AS category_code
     , so.currency_code                                   AS currency_code
     , so.channel_code                                    AS channel_code
     , COUNT(*)                                           AS line_count
     , SUM(sol.qty)                                       AS total_qty
     , COUNT(sol.qty)                                     AS total_qty_cnt
     , SUM(sol.qty * sol.unit_price - sol.discount_amount) AS net_amount
     , COUNT(sol.qty * sol.unit_price - sol.discount_amount) AS net_amount_cnt
     , SUM(sol.tax_amount)                                AS tax_amount
     , COUNT(sol.tax_amount)                              AS tax_amount_cnt
  FROM sales_order      so
  JOIN sales_order_line sol ON sol.order_id   = so.order_id
  JOIN product_variant  pv  ON pv.variant_id  = sol.variant_id
  JOIN product          p   ON p.product_id   = pv.product_id
  JOIN product_category pc  ON pc.category_id = p.category_id
 GROUP BY TRUNC(so.order_ts, 'MM')
        , pc.category_id
        , pc.category_code
        , so.currency_code
        , so.channel_code]';
  l_created BOOLEAN := FALSE;
BEGIN
  FOR i IN 1 .. l_clauses.COUNT LOOP
    EXIT WHEN l_created;
    BEGIN
      EXECUTE IMMEDIATE 'CREATE MATERIALIZED VIEW mv_sales_monthly_category'
                     || ' BUILD IMMEDIATE ' || l_clauses(i)
                     || ' AS ' || l_query;
      l_created := TRUE;
      DBMS_OUTPUT.PUT_LINE('   .. mv_sales_monthly_category created : ' || l_clauses(i));
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('   .. ' || l_clauses(i) || ' rejected: '
                             || SUBSTR(SQLERRM, 1, 120));
    END;
  END LOOP;

  IF NOT l_created THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** mv_sales_monthly_category was NOT created.');
  END IF;
END;
/

-- =====================================================================================
-- 4. mv_stock_position -- FAST ON DEMAND, single-table aggregate
-- =====================================================================================
-- Single base table, its own MV log, no expression colliding with a virtual column: this
-- is the one MV in the schema that genuinely satisfies every fast-refresh restriction.
-- Keep it that way -- the lab needs a control case that Oracle does *not* downgrade.
--
-- MIGRATION NOTE (H-17): qty_available is a VIRTUAL column defined as
-- (qty_on_hand - qty_reserved), so SUM(qty_on_hand - qty_reserved) would be rewritten to
-- SUM(qty_available) and fail with ORA-12033 exactly as described above section 2. Two
-- consequences visible in the SQL below:
--   * available stock is not stored; derive it as qty_on_hand - qty_reserved from the
--     two sums that are.
--   * the reorder test is spelled `qty_on_hand < reorder_point + qty_reserved` rather
--     than the natural `qty_on_hand - qty_reserved < reorder_point`. Same arithmetic,
--     but the natural form contains the virtual column's expression and would silently
--     cost this MV its fast refresh. Anyone "tidying" that predicate during conversion
--     review will not notice what they broke, because on PostgreSQL both forms work and
--     the refresh is a full recompute either way.
--
-- MIGRATION NOTE (H-15): on PostgreSQL this becomes an ordinary materialised view
-- refreshed with REFRESH MATERIALIZED VIEW CONCURRENTLY. CONCURRENTLY needs a UNIQUE
-- index on the MV -- uq_mv_stock_position below supplies it -- and still performs a
-- full scan. Without CONCURRENTLY the refresh takes an ACCESS EXCLUSIVE lock and every
-- reader blocks for the duration, which on a stock-position view read by the store
-- estate is an outage.
-- -------------------------------------------------------------------------------------
DECLARE
  TYPE t_clauses IS TABLE OF VARCHAR2(200);
  l_clauses t_clauses := t_clauses('REFRESH FAST ON DEMAND',
                                   'REFRESH COMPLETE ON DEMAND');
  l_query   VARCHAR2(4000) := q'[
SELECT ist.variant_id                                     AS variant_id
     , COUNT(*)                                           AS location_count
     , SUM(ist.qty_on_hand)                               AS qty_on_hand
     , COUNT(ist.qty_on_hand)                             AS qty_on_hand_cnt
     , SUM(ist.qty_reserved)                              AS qty_reserved
     , COUNT(ist.qty_reserved)                            AS qty_reserved_cnt
     , SUM(CASE WHEN ist.reorder_point IS NOT NULL
                 AND ist.qty_on_hand < ist.reorder_point + ist.qty_reserved
                THEN 1 ELSE 0 END)                        AS below_reorder_count
     , COUNT(CASE WHEN ist.reorder_point IS NOT NULL
                   AND ist.qty_on_hand < ist.reorder_point + ist.qty_reserved
                  THEN 1 ELSE 0 END)                      AS below_reorder_cnt
  FROM inventory_stock ist
 GROUP BY ist.variant_id]';
  l_created BOOLEAN := FALSE;
BEGIN
  FOR i IN 1 .. l_clauses.COUNT LOOP
    EXIT WHEN l_created;
    BEGIN
      EXECUTE IMMEDIATE 'CREATE MATERIALIZED VIEW mv_stock_position'
                     || ' BUILD IMMEDIATE ' || l_clauses(i)
                     || ' AS ' || l_query;
      l_created := TRUE;
      DBMS_OUTPUT.PUT_LINE('   .. mv_stock_position created : ' || l_clauses(i));
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('   .. ' || l_clauses(i) || ' rejected: '
                             || SUBSTR(SQLERRM, 1, 120));
    END;
  END LOOP;

  IF NOT l_created THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** mv_stock_position was NOT created.');
  END IF;
END;
/

-- =====================================================================================
-- 5. mv_customer_rfm -- COMPLETE ON DEMAND, analytic functions
-- =====================================================================================
-- Recency / frequency / monetary scoring. Carries H-08.
--
-- MIGRATION NOTE (H-08): NTILE, RATIO_TO_REPORT and the KEEP (DENSE_RANK ...) form all
-- appear here. NTILE and the window syntax convert one-for-one. RATIO_TO_REPORT has no
-- PostgreSQL equivalent and must become x / SUM(x) OVER () -- note the division-by-zero
-- exposure that Oracle's version hides. MAX(...) KEEP (DENSE_RANK LAST ORDER BY ...)
-- becomes a LAST_VALUE with an explicit
--   ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
-- frame; forgetting the frame is silent and wrong, because the default frame stops at
-- the current row.
--
-- MIGRATION NOTE (T-09): SYSDATE is the database *host* clock with no time zone, and it
-- does not advance within a statement. now() is transaction start in the session zone
-- and clock_timestamp() does advance. Recency computed with the wrong one drifts by the
-- host-to-session offset -- for Contoso that is up to 13 hours, i.e. a whole RFM bucket.
--
-- MIGRATION NOTE (H-40): `customer` acquires a VPD policy in 12-security-context.sql.
-- The predicate function returns NULL for the schema owner, so this refresh sees every
-- row. On PostgreSQL, RLS is bypassed by the table owner *by default* -- the equivalent
-- accident. If anyone later sets FORCE ROW LEVEL SECURITY on contoso.customer, this
-- materialised view starts silently refreshing from a filtered subset.
-- -------------------------------------------------------------------------------------
DECLARE
  l_query VARCHAR2(4000) := q'[
WITH base AS (
  SELECT c.customer_id                                    AS customer_id
       , c.customer_ref                                   AS customer_ref
       , c.home_country_code                              AS home_country_code
       , c.preferred_store_id                             AS preferred_store_id
       , COUNT(so.order_id)                               AS frequency_orders
       , MAX(so.order_ts)                                 AS last_order_ts
       , ROUND(SYSDATE - MAX(CAST(so.order_ts AS DATE)))  AS recency_days
       , NVL(SUM(so.subtotal_amount - so.discount_amount
                 + so.tax_amount + so.shipping_amount), 0) AS monetary_amount
       , MAX(so.channel_code) KEEP (DENSE_RANK LAST ORDER BY so.order_ts)
                                                          AS last_channel_code
    FROM customer     c
    LEFT JOIN sales_order so
      ON  so.customer_id = c.customer_id
      AND so.status     IN ('PLACED','SHIPPED','DELIVERED')
   GROUP BY c.customer_id
          , c.customer_ref
          , c.home_country_code
          , c.preferred_store_id
)
SELECT b.customer_id
     , b.customer_ref
     , b.home_country_code
     , b.preferred_store_id
     , b.frequency_orders
     , b.last_order_ts
     , b.recency_days
     , b.monetary_amount
     , b.last_channel_code
     , NTILE(5) OVER (ORDER BY b.recency_days DESC NULLS LAST)   AS r_score
     , NTILE(5) OVER (ORDER BY b.frequency_orders NULLS FIRST)   AS f_score
     , NTILE(5) OVER (ORDER BY b.monetary_amount NULLS FIRST)    AS m_score
     , RATIO_TO_REPORT(b.monetary_amount)
         OVER (PARTITION BY b.home_country_code)                 AS country_value_share
  FROM base b]';
BEGIN
  EXECUTE IMMEDIATE 'CREATE MATERIALIZED VIEW mv_customer_rfm'
                 || ' BUILD IMMEDIATE REFRESH COMPLETE ON DEMAND'
                 || ' AS ' || l_query;
  DBMS_OUTPUT.PUT_LINE('   .. mv_customer_rfm created : REFRESH COMPLETE ON DEMAND');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** mv_customer_rfm not created: '
                         || SUBSTR(SQLERRM, 1, 200));
END;
/

-- =====================================================================================
-- 6. mv_supplier_performance -- COMPLETE, with a START WITH / NEXT refresh schedule
-- =====================================================================================
-- MIGRATION NOTE (H-14/H-15): `START WITH ... NEXT ...` quietly creates a refresh *job*
-- behind the materialised view. It needs the CREATE JOB privilege, which is why this
-- block is guarded and falls back to a plain ON DEMAND view. On PostgreSQL the schedule
-- has to be lifted out into pg_cron (or an external scheduler) as a separate object --
-- the coupling between "this view" and "this schedule" disappears entirely, and nothing
-- in the converted DDL records that the view was ever refreshed automatically. That is
-- the classic way a converted reporting layer goes stale in production without anyone
-- getting an error.
--
-- MIGRATION NOTE (T-02): purchase_order.order_date is an Oracle DATE, which carries a
-- time component. Converting it to PostgreSQL `date` truncates it and changes the
-- lead-time arithmetic below; `timestamp` is the correct target.
-- -------------------------------------------------------------------------------------
DECLARE
  l_query VARCHAR2(4000) := q'[
SELECT s.supplier_id                                      AS supplier_id
     , s.supplier_code                                    AS supplier_code
     , s.supplier_name                                    AS supplier_name
     , s.currency_code                                    AS currency_code
     , COUNT(po.po_id)                                    AS po_count
     , NVL(SUM(po.order_total), 0)                        AS ordered_value
     , ROUND(AVG(po.expected_date - po.order_date), 2)    AS avg_promised_days
     , SUM(CASE WHEN po.status = 'RECEIVED'  THEN 1 ELSE 0 END) AS received_count
     , SUM(CASE WHEN po.status = 'CANCELLED' THEN 1 ELSE 0 END) AS cancelled_count
     , SUM(CASE WHEN po.status = 'PART_RECV' THEN 1 ELSE 0 END) AS partial_count
     , ROUND(100 * SUM(CASE WHEN po.status = 'RECEIVED' THEN 1 ELSE 0 END)
             / NULLIF(COUNT(po.po_id), 0), 2)             AS fill_rate_pct
     , s.rating                                           AS supplier_rating
  FROM supplier s
  LEFT JOIN purchase_order po ON po.supplier_id = s.supplier_id
 GROUP BY s.supplier_id
        , s.supplier_code
        , s.supplier_name
        , s.currency_code
        , s.rating]';
BEGIN
  BEGIN
    EXECUTE IMMEDIATE 'CREATE MATERIALIZED VIEW mv_supplier_performance'
                   || ' BUILD IMMEDIATE'
                   || ' REFRESH COMPLETE'
                   || '   START WITH SYSDATE + 1/24'
                   || '   NEXT       SYSDATE + 1'
                   || ' AS ' || l_query;
    DBMS_OUTPUT.PUT_LINE('   .. mv_supplier_performance created : COMPLETE, '
                         || 'START WITH SYSDATE+1/24 NEXT SYSDATE+1');
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('   .. START WITH/NEXT rejected (CREATE JOB privilege?): '
                           || SUBSTR(SQLERRM, 1, 120));
      DBMS_OUTPUT.PUT_LINE('   .. falling back to REFRESH COMPLETE ON DEMAND');
      EXECUTE IMMEDIATE 'CREATE MATERIALIZED VIEW mv_supplier_performance'
                     || ' BUILD IMMEDIATE REFRESH COMPLETE ON DEMAND'
                     || ' AS ' || l_query;
      DBMS_OUTPUT.PUT_LINE('   .. mv_supplier_performance created : '
                           || 'REFRESH COMPLETE ON DEMAND (unscheduled)');
  END;
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** mv_supplier_performance not created: '
                         || SUBSTR(SQLERRM, 1, 200));
END;
/

-- =====================================================================================
-- 7. mv_promotion_uplift -- COMPLETE ON DEMAND, ENABLE QUERY REWRITE
-- =====================================================================================
-- MIGRATION NOTE (H-15): query rewrite is the feature with the widest gap of all. Oracle
-- transparently rewrites a query against the *base tables* to hit this summary instead;
-- PostgreSQL has nothing equivalent, at any version. Every query that benefited from the
-- rewrite must be found and rewritten by hand to reference the materialised view by name.
-- They are not findable from the DDL -- they live in application code -- so the honest
-- answer is a plan-regression exercise on the target, not a conversion task.
--
-- Deliberately free of SYSDATE and of any TSLTZ expression: Oracle refuses ENABLE QUERY
-- REWRITE on a non-deterministic query, so this MV doubles as the control that proves
-- the privilege is present when the other blocks warn.
-- -------------------------------------------------------------------------------------
DECLARE
  l_query VARCHAR2(4000) := q'[
SELECT pr.promotion_id                                    AS promotion_id
     , pr.promo_code                                      AS promo_code
     , pr.promo_type                                      AS promo_type
     , pr.country_code                                    AS country_code
     , pr.status                                          AS promo_status
     , COUNT(*)                                           AS order_count
     , COUNT(so.order_id)                                 AS order_count_chk
     , SUM(so.subtotal_amount)                            AS subtotal_amount
     , COUNT(so.subtotal_amount)                          AS subtotal_amount_cnt
     , SUM(so.discount_amount)                            AS discount_amount
     , COUNT(so.discount_amount)                          AS discount_amount_cnt
     , SUM(NVL(pr.budget_amount, 0) - NVL(pr.spent_amount, 0)) AS budget_remaining
     , COUNT(NVL(pr.budget_amount, 0) - NVL(pr.spent_amount, 0)) AS budget_remaining_cnt
  FROM promotion   pr
  JOIN sales_order so ON so.promotion_id = pr.promotion_id
 GROUP BY pr.promotion_id
        , pr.promo_code
        , pr.promo_type
        , pr.country_code
        , pr.status]';
BEGIN
  BEGIN
    EXECUTE IMMEDIATE 'CREATE MATERIALIZED VIEW mv_promotion_uplift'
                   || ' BUILD IMMEDIATE REFRESH COMPLETE ON DEMAND'
                   || ' ENABLE QUERY REWRITE'
                   || ' AS ' || l_query;
    DBMS_OUTPUT.PUT_LINE('   .. mv_promotion_uplift created : COMPLETE ON DEMAND, '
                         || 'ENABLE QUERY REWRITE');
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('   .. ENABLE QUERY REWRITE rejected '
                           || '(QUERY REWRITE privilege?): ' || SUBSTR(SQLERRM, 1, 120));
      EXECUTE IMMEDIATE 'CREATE MATERIALIZED VIEW mv_promotion_uplift'
                     || ' BUILD IMMEDIATE REFRESH COMPLETE ON DEMAND'
                     || ' AS ' || l_query;
      DBMS_OUTPUT.PUT_LINE('   .. mv_promotion_uplift created : '
                           || 'COMPLETE ON DEMAND (rewrite DISABLED)');
  END;
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** mv_promotion_uplift not created: '
                         || SUBSTR(SQLERRM, 1, 200));
END;
/

-- =====================================================================================
-- 8. MATERIALISED VIEW INDEXES  (6, per docs/design.md section 8)
-- =====================================================================================
-- These live here rather than in the index file because CREATE INDEX needs the MV
-- container table to exist first, and the containers are created above.
--
-- MIGRATION NOTE (H-15): the two UNIQUE ones are load bearing on the target. PostgreSQL
-- refuses REFRESH MATERIALIZED VIEW CONCURRENTLY without a unique index over a
-- non-nullable column set, and non-concurrent refresh locks readers out. A converter
-- that drops "redundant" unique indexes on materialised views removes the only thing
-- making online refresh possible.
-- -------------------------------------------------------------------------------------
DECLARE
  TYPE t_ddl IS TABLE OF VARCHAR2(500);
  l_ddl t_ddl := t_ddl(
    'CREATE INDEX ix_mv_sales_daily_store ON mv_sales_daily_store (sales_date, store_id)',
    'CREATE INDEX ix_mv_sales_monthly_cat ON mv_sales_monthly_category (month_start, category_id)',
    'CREATE UNIQUE INDEX uq_mv_stock_position ON mv_stock_position (variant_id)',
    'CREATE UNIQUE INDEX uq_mv_customer_rfm ON mv_customer_rfm (customer_id)',
    'CREATE INDEX ix_mv_supplier_perf ON mv_supplier_performance (supplier_id)',
    'CREATE INDEX ix_mv_promotion_uplift ON mv_promotion_uplift (promotion_id, country_code)');
  l_ok  PLS_INTEGER := 0;
BEGIN
  FOR i IN 1 .. l_ddl.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE l_ddl(i);
      l_ok := l_ok + 1;
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('   .. index skipped: ' || SUBSTR(l_ddl(i), 1, 60)
                             || ' -> ' || SUBSTR(SQLERRM, 1, 80));
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('   .. ' || l_ok || ' of ' || l_ddl.COUNT
                       || ' materialised view indexes created');
END;
/

-- =====================================================================================
-- 9. REFRESH GROUP rg_reporting  (DBMS_REFRESH)
-- =====================================================================================
-- A refresh group refreshes several materialised views to a *single consistent point in
-- time*. Members must not be ON COMMIT, so mv_sales_daily_store is excluded.
--
-- MIGRATION NOTE (H-15): PostgreSQL has no refresh groups. The transactional consistency
-- guarantee has to be rebuilt by hand as one explicit transaction wrapping several
-- REFRESH MATERIALIZED VIEW statements:
--
--     BEGIN;
--       REFRESH MATERIALIZED VIEW contoso.mv_sales_monthly_category;
--       REFRESH MATERIALIZED VIEW contoso.mv_stock_position;
--       REFRESH MATERIALIZED VIEW contoso.mv_customer_rfm;
--     COMMIT;
--
-- and note that CONCURRENTLY cannot be used inside a transaction block, so you must
-- choose between consistency across the group and availability during the refresh.
-- Oracle gave you both. This is a genuine capability loss, not a syntax difference.
--
-- DBMS_REFRESH.MAKE creates a scheduler job, so it needs CREATE JOB. Guarded.
-- -------------------------------------------------------------------------------------
DECLARE
  l_list VARCHAR2(500);
  l_cnt  PLS_INTEGER;
BEGIN
  SELECT LISTAGG(USER || '.' || mview_name, ',') WITHIN GROUP (ORDER BY mview_name)
       , COUNT(*)
    INTO l_list, l_cnt
    FROM user_mviews
   WHERE mview_name IN ('MV_SALES_MONTHLY_CATEGORY',
                        'MV_STOCK_POSITION',
                        'MV_CUSTOMER_RFM');

  IF l_cnt = 0 THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** no member MVs exist; rg_reporting skipped');
  ELSE
    DBMS_REFRESH.MAKE(name                 => USER || '.RG_REPORTING',
                      list                 => l_list,
                      next_date            => SYSDATE + 1/24,
                      interval             => 'SYSDATE + 1/24',
                      implicit_destroy     => FALSE,
                      lax                  => TRUE,
                      job                  => 0,
                      rollback_seg         => NULL,
                      push_deferred_rpc    => TRUE,
                      refresh_after_errors => TRUE,
                      purge_option         => NULL,
                      parallelism          => NULL,
                      heap_size            => NULL);
    DBMS_OUTPUT.PUT_LINE('   .. refresh group RG_REPORTING created with '
                         || l_cnt || ' members: ' || l_list);
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** refresh group RG_REPORTING not created.');
    DBMS_OUTPUT.PUT_LINE('   ***         *** ' || SUBSTR(SQLERRM, 1, 200));
    DBMS_OUTPUT.PUT_LINE('   ***         *** Needs EXECUTE on SYS.DBMS_REFRESH and '
                         || 'CREATE JOB. Grant both from SYSTEM and re-run.');
    DBMS_OUTPUT.PUT_LINE('   ***         *** The lab still works; H-15 loses its '
                         || 'refresh-group evidence.');
END;
/

-- -------------------------------------------------------------------------------------
-- 9b. Prove the group refreshes. Non-fatal; on an empty schema this is a no-op.
-- -------------------------------------------------------------------------------------
BEGIN
  DBMS_REFRESH.REFRESH(USER || '.RG_REPORTING');
  DBMS_OUTPUT.PUT_LINE('   .. RG_REPORTING refreshed once to prove the group works');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   .. RG_REPORTING trial refresh skipped: '
                         || SUBSTR(SQLERRM, 1, 120));
END;
/

-- =====================================================================================
-- 10. Summary
-- =====================================================================================
DECLARE
  l_mv   PLS_INTEGER;
  l_log  PLS_INTEGER;
  l_fast PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_mv  FROM user_mviews;
  SELECT COUNT(*) INTO l_log FROM user_objects
   WHERE object_type = 'TABLE' AND object_name LIKE 'MLOG$%';
  SELECT COUNT(*) INTO l_fast FROM user_mviews WHERE refresh_method = 'FAST';

  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------------');
  DBMS_OUTPUT.PUT_LINE('10-mviews.sql summary');
  DBMS_OUTPUT.PUT_LINE('  materialised views : ' || l_mv  || ' (design target 6)');
  DBMS_OUTPUT.PUT_LINE('  MV logs (MLOG$_)   : ' || l_log || ' (design target 3)');
  DBMS_OUTPUT.PUT_LINE('  fast-refreshable   : ' || l_fast || ' (expect 2)');
  DBMS_OUTPUT.PUT_LINE('     mv_sales_daily_store  FAST ON COMMIT');
  DBMS_OUTPUT.PUT_LINE('     mv_stock_position     FAST ON DEMAND');
  DBMS_OUTPUT.PUT_LINE('  mv_sales_monthly_category is COMPLETE, not FAST as design 6.5');
  DBMS_OUTPUT.PUT_LINE('  says: it joins three dimension tables that carry no MV log.');
  DBMS_OUTPUT.PUT_LINE('  each MV also contributes one TABLE container to user_objects');
  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------------');
END;
/

PROMPT 10-mviews.sql complete.
