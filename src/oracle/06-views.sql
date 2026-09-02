-- =====================================================================================
-- Contoso Store -- Oracle source schema
-- 06-views.sql : the reporting and application view layer
-- =====================================================================================
-- Owner        : CONTOSO
-- Depends on   : 01-types.sql, core + operational tables, constraints, indexes
-- Exercises    : H-06 (CONNECT BY, all four hierarchies), H-08 (analytics),
--                H-30 (ROWNUM vs ROW_NUMBER), H-31 (NVL/NVL2/DECODE),
--                H-32 (Oracle (+) outer joins), H-27 (INSTEAD OF trigger targets),
--                H-17 (virtual columns), H-37 (TSLTZ), T-02, T-05, T-06, T-13
--
-- Design contract: docs/design.md sections 6.5 and 9.
--
-- Every view here is a real projection a retail ERP would actually ship. The awkward
-- constructs are load-bearing, not decoration: v_legacy_orders really is the shape a
-- 1990s report was written in, and v_customer_360 really is what a call-centre screen
-- binds to.
--
-- MIGRATION NOTE (reading order): three of these views -- v_customer_360,
-- v_product_sellable and v_open_purchase_orders -- are the INSTEAD OF trigger targets
-- created in 09-triggers.sql. They must exist before that file runs.
-- =====================================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET SQLBLANKLINES ON
SET DEFINE OFF
SET FEEDBACK ON

PROMPT
PROMPT ==========================================================================
PROMPT 06-views.sql : view layer
PROMPT ==========================================================================


-- =====================================================================================
-- 1. v_category_tree -- merchandise hierarchy (hierarchy 3)
-- =====================================================================================
-- MIGRATION NOTE (H-06): this is the densest CONNECT BY in the schema and it uses four
-- pseudo-columns that PostgreSQL's WITH RECURSIVE has no equivalent for.
--   LEVEL                 -> a depth counter you add to the recursive term and increment
--                            by hand.
--   SYS_CONNECT_BY_PATH   -> string concatenation carried through the recursive term.
--                            Note Oracle raises ORA-30004 if a value contains the
--                            separator; PostgreSQL will happily build an ambiguous path.
--   CONNECT_BY_ROOT       -> the root value must be selected in the anchor term and then
--                            passed down untouched at every level.
--   CONNECT_BY_ISLEAF     -> needs a correlated NOT EXISTS or a second pass; there is no
--                            cheap equivalent.
-- ORDER SIBLINGS BY has no analogue at all: you must build an array of sort keys down
-- the path and ORDER BY that array. And Oracle silently guards against cycles here
-- because we would have written NOCYCLE; PostgreSQL loops forever unless you add the
-- PG 14+ CYCLE clause or a visited-path guard of your own.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_category_tree AS
SELECT pc.category_id
     , pc.category_code
     , pc.category_name
     , pc.parent_category_id
     , pc.merch_level
     , LEVEL                                                       AS tree_depth
     , SYS_CONNECT_BY_PATH(pc.category_name, ' > ')                AS category_path
     , SYS_CONNECT_BY_PATH(pc.category_code, '/')                  AS code_path
     , CONNECT_BY_ROOT pc.category_code                            AS root_category_code
     , CONNECT_BY_ROOT pc.category_name                            AS root_category_name
     , CONNECT_BY_ISLEAF                                           AS is_leaf_node
     , LPAD(' ', (LEVEL - 1) * 2, ' ') || pc.category_name         AS indented_name
     , pc.sort_order
  FROM product_category pc
 START WITH pc.parent_category_id IS NULL
CONNECT BY NOCYCLE PRIOR pc.category_id = pc.parent_category_id
 ORDER SIBLINGS BY pc.sort_order, pc.category_code;


-- =====================================================================================
-- 2. v_employee_reporting_line -- management chain (hierarchy 2)
-- =====================================================================================
-- MIGRATION NOTE (H-06): the same construct against a *ragged* tree. Contoso's reporting
-- line is not balanced -- a country manager may be four levels from the CEO in one
-- country and six in another -- so any conversion that hard-codes a depth breaks. Note
-- also employee.full_name and employee.is_active are virtual columns (H-17) selected
-- here as if they were real; on PostgreSQL they become GENERATED ALWAYS ... STORED, and
-- is_active is only convertible because it derives from termination_date alone.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_employee_reporting_line AS
SELECT e.employee_id
     , e.employee_number
     , e.full_name
     , e.job_title
     , e.manager_id
     , e.store_id
     , e.is_active
     , LEVEL                                                       AS reporting_depth
     , CONNECT_BY_ROOT e.employee_id                               AS top_manager_id
     , CONNECT_BY_ROOT e.full_name                                 AS top_manager_name
     , SYS_CONNECT_BY_PATH(e.employee_number, '/')                 AS chain_path
     , SYS_CONNECT_BY_PATH(e.last_name, ' <- ')                    AS chain_names
     , CONNECT_BY_ISLEAF                                           AS is_individual_contributor
     , PRIOR e.employee_number                                     AS direct_manager_number
  FROM employee e
 START WITH e.manager_id IS NULL
CONNECT BY NOCYCLE PRIOR e.employee_id = e.manager_id;


-- =====================================================================================
-- 3. v_region_hierarchy -- geography (hierarchy 1)
-- =====================================================================================
-- MIGRATION NOTE (H-06): a third shape -- CONNECT BY with a *filter in the WHERE clause*.
-- Oracle applies the WHERE after the hierarchy is built, so pruning here removes rows
-- without removing their descendants (the tree keeps its shape and grows holes). In a
-- WITH RECURSIVE conversion the natural place to put the predicate is inside the
-- recursive term, which cuts the whole subtree. Same words, different answer.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_region_hierarchy AS
SELECT r.region_id
     , r.region_code
     , r.region_name
     , r.region_level
     , r.country_code
     , r.parent_region_id
     , r.manager_employee_id
     , LEVEL                                             AS depth
     , CONNECT_BY_ROOT r.region_code                     AS root_region_code
     , SYS_CONNECT_BY_PATH(r.region_code, '.')           AS region_path
  FROM region r
 WHERE r.region_level <> 'RETIRED'
 START WITH r.parent_region_id IS NULL
CONNECT BY NOCYCLE PRIOR r.region_id = r.parent_region_id;


-- =====================================================================================
-- 4. v_gl_trial_balance -- chart of accounts roll-up (hierarchy 4)
-- =====================================================================================
-- MIGRATION NOTE (H-06): a bottom-up walk. The anchor is every postable leaf account and
-- the recursion climbs to the root, which reverses the direction of PRIOR. Converters
-- routinely get the direction wrong because the syntax difference is one word, and the
-- result still runs -- it just returns the wrong side of the tree.
-- MIGRATION NOTE (T-13): the ORDER BY carries an explicit NULLS LAST. Oracle and
-- PostgreSQL agree on ascending NULL placement and disagree on descending; spelling it
-- out is the only portable answer.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_gl_trial_balance AS
SELECT ga.account_code
     , ga.account_name
     , ga.account_type
     , ga.normal_balance
     , ga.parent_account_code
     , LEVEL                                              AS climb_level
     , CONNECT_BY_ROOT ga.account_code                     AS leaf_account_code
     , SYS_CONNECT_BY_PATH(ga.account_code, '|')           AS rollup_path
     , (SELECT NVL(SUM(gjl.debit_amount), 0)
          FROM gl_journal_line gjl
         WHERE gjl.account_code = ga.account_code)         AS debit_total
     , (SELECT NVL(SUM(gjl.credit_amount), 0)
          FROM gl_journal_line gjl
         WHERE gjl.account_code = ga.account_code)         AS credit_total
  FROM gl_account ga
 START WITH ga.is_postable = 'Y'
CONNECT BY NOCYCLE PRIOR ga.parent_account_code = ga.account_code
 ORDER BY ga.account_code NULLS LAST;


-- =====================================================================================
-- 5. v_sales_by_store_day -- the analytics workhorse
-- =====================================================================================
-- MIGRATION NOTE (H-08): RANK, DENSE_RANK, ROW_NUMBER, LAG, LEAD, NTILE and a running
-- SUM ... OVER all appear here and all convert one-for-one. The window *frame* is the
-- part that does not: PostgreSQL's default frame is
--   RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
-- exactly as Oracle's is, but the moment an ORDER BY is absent the two implementations
-- have historically differed on peer handling for RANGE frames. The running total below
-- states ROWS explicitly so the answer cannot drift.
-- MIGRATION NOTE (H-37 / T-02): TRUNC over a TIMESTAMP WITH LOCAL TIME ZONE resolves in
-- the *session* time zone. Two analysts in two countries get two different daily
-- buckets from this view today. Converting to date_trunc('day', order_ts) inherits the
-- same bug in a new dialect; the fix is to join country.tz_name and be explicit.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_sales_by_store_day AS
WITH daily AS (
  SELECT so.store_id
       , TRUNC(CAST(so.order_ts AS DATE))                  AS sales_date
       , so.currency_code
       , COUNT(DISTINCT so.order_id)                       AS order_count
       , SUM(sol.qty)                                      AS units_sold
       , SUM(sol.qty * sol.unit_price - sol.discount_amount) AS net_amount
       , SUM(sol.tax_amount)                               AS tax_amount
    FROM sales_order      so
    JOIN sales_order_line sol ON sol.order_id = so.order_id
   WHERE so.status IN ('PLACED', 'PICKING', 'SHIPPED', 'DELIVERED')
   GROUP BY so.store_id, TRUNC(CAST(so.order_ts AS DATE)), so.currency_code
)
SELECT d.store_id
     , s.store_code
     , s.store_name
     , d.sales_date
     , d.currency_code
     , d.order_count
     , d.units_sold
     , d.net_amount
     , d.tax_amount
     , ROW_NUMBER() OVER (PARTITION BY d.store_id ORDER BY d.sales_date)          AS trading_day_seq
     , RANK()       OVER (PARTITION BY d.sales_date ORDER BY d.net_amount DESC)   AS day_rank_by_value
     , DENSE_RANK() OVER (PARTITION BY d.sales_date ORDER BY d.net_amount DESC)   AS day_dense_rank
     , NTILE(4)     OVER (PARTITION BY d.sales_date ORDER BY d.net_amount DESC)   AS value_quartile
     , LAG(d.net_amount, 1)  OVER (PARTITION BY d.store_id ORDER BY d.sales_date) AS prev_day_amount
     , LEAD(d.net_amount, 1) OVER (PARTITION BY d.store_id ORDER BY d.sales_date) AS next_day_amount
     , d.net_amount
       - LAG(d.net_amount, 1, 0) OVER (PARTITION BY d.store_id ORDER BY d.sales_date)
                                                                                  AS day_on_day_delta
     , SUM(d.net_amount) OVER (PARTITION BY d.store_id, TRUNC(d.sales_date, 'MM')
                               ORDER BY d.sales_date
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)  AS mtd_amount
     , AVG(d.net_amount) OVER (PARTITION BY d.store_id ORDER BY d.sales_date
                               ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)          AS rolling_7d_avg
     , RATIO_TO_REPORT(d.net_amount) OVER (PARTITION BY d.sales_date)             AS share_of_day
     , FIRST_VALUE(d.sales_date) OVER (PARTITION BY d.store_id ORDER BY d.net_amount DESC
                                       ROWS BETWEEN UNBOUNDED PRECEDING
                                                AND UNBOUNDED FOLLOWING)          AS best_day_date
  FROM daily d
  JOIN store s ON s.store_id = d.store_id;


-- =====================================================================================
-- 6. v_product_price_rank -- RANK / DENSE_RANK / percentile within a category
-- =====================================================================================
-- MIGRATION NOTE (H-08): PERCENT_RANK and CUME_DIST exist in both dialects. The Oracle
-- KEEP (DENSE_RANK FIRST ...) aggregate below does not -- it becomes FIRST_VALUE with an
-- explicit UNBOUNDED PRECEDING/FOLLOWING frame, and omitting the frame silently answers
-- a different question because the default frame stops at the current row.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_product_price_rank AS
SELECT p.product_id
     , p.sku
     , p.product_name
     , p.category_id
     , pc.category_name
     , p.list_price
     , p.unit_cost
     , p.margin_pct
     , RANK()         OVER (PARTITION BY p.category_id ORDER BY p.list_price DESC) AS price_rank
     , DENSE_RANK()   OVER (PARTITION BY p.category_id ORDER BY p.list_price DESC) AS price_dense_rank
     , PERCENT_RANK() OVER (PARTITION BY p.category_id ORDER BY p.list_price)      AS price_percentile
     , CUME_DIST()    OVER (PARTITION BY p.category_id ORDER BY p.list_price)      AS price_cume_dist
     , MAX(p.list_price) OVER (PARTITION BY p.category_id)                         AS category_max_price
     , MIN(p.sku) KEEP (DENSE_RANK FIRST ORDER BY p.list_price DESC)
         OVER (PARTITION BY p.category_id)                                         AS priciest_sku
     , NTH_VALUE(p.sku, 2) FROM LAST
         OVER (PARTITION BY p.category_id ORDER BY p.list_price
               ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)           AS second_priciest_sku
  FROM product          p
  JOIN product_category pc ON pc.category_id = p.category_id
 WHERE p.status = 'ACTIVE';


-- =====================================================================================
-- 7. v_legacy_orders -- Oracle (+) outer-join syntax, end to end
-- =====================================================================================
-- MIGRATION NOTE (H-32): the whole point of this view. Three separate traps live here.
--   (a) c.customer_id = so.customer_id(+) is a plain outer join and converts cleanly.
--   (b) The predicate  a.country_code(+) = 'GB'  is a *filter carried into the join*.
--       Oracle applies it before the outer join, so non-GB addresses come back as NULLs
--       rather than removing the customer row. Move it to a WHERE clause during
--       conversion and rows disappear. It belongs in the ON clause.
--   (c) e.employee_id = so.sales_employee_id(+) chained after (a) means the ANSI join
--       order is not the textual order -- store must be joined before employee or the
--       outer-ness propagates wrongly.
-- MIGRATION NOTE (H-38): the  a.line2 IS NOT NULL  predicate below changes meaning on
-- PostgreSQL. In Oracle an empty line2 was stored as NULL and is excluded; after a
-- migration that preserved '' as a real empty string those rows are suddenly included.
-- Nothing errors. The row count just moves.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_legacy_orders AS
SELECT c.customer_id
     , c.customer_ref
     , c.last_name
     , so.order_id
     , so.order_number
     , so.order_ts
     , so.status                                   AS order_status
     , so.subtotal_amount
     , st.store_code
     , st.store_name
     , e.employee_number                           AS sales_rep_number
     , a.city                                      AS bill_city
     , a.postal_code                               AS bill_postal_code
     , a.line2                                     AS bill_line2
     , cy.country_name
     , NVL(so.discount_amount, 0)                  AS discount_amount
  FROM customer     c
     , sales_order  so
     , store        st
     , employee     e
     , address      a
     , country      cy
 WHERE c.customer_id        = so.customer_id(+)
   AND so.store_id          = st.store_id(+)
   AND so.sales_employee_id = e.employee_id(+)
   AND c.primary_address_id = a.address_id(+)
   AND a.country_code(+)    = 'GB'
   AND c.home_country_code  = cy.country_code
   AND a.line2 IS NOT NULL
   AND c.status <> 'ERASED';


-- =====================================================================================
-- 8. v_top_products_by_store -- ROWNUM, the classic wrapped inline view
-- =====================================================================================
-- MIGRATION NOTE (H-30): both forms of the trap are in this file on purpose. Here the
-- ORDER BY is *inside* the inline view and ROWNUM filters the sorted result, which is
-- the correct idiom and converts to ORDER BY ... FETCH FIRST n ROWS ONLY. Compare with
-- v_recent_orders_unsorted below, where ROWNUM is applied in the same block as the
-- ORDER BY: Oracle assigns ROWNUM *before* sorting, so that view returns an arbitrary
-- 50 rows which are then sorted. The naive conversion of the second form to
-- ORDER BY ... LIMIT 50 returns the top 50 -- a different, entirely plausible-looking
-- result set. Verify row identity, not just row count.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_top_products_by_store AS
SELECT store_id, variant_id, variant_sku, product_name, units_sold, net_amount, rn
  FROM (SELECT so.store_id
             , sol.variant_id
             , pv.variant_sku
             , p.product_name
             , SUM(sol.qty)                                         AS units_sold
             , SUM(sol.qty * sol.unit_price - sol.discount_amount)   AS net_amount
             , ROW_NUMBER() OVER (PARTITION BY so.store_id
                                  ORDER BY SUM(sol.qty) DESC NULLS LAST) AS rn
          FROM sales_order      so
          JOIN sales_order_line sol ON sol.order_id  = so.order_id
          JOIN product_variant  pv  ON pv.variant_id = sol.variant_id
          JOIN product          p   ON p.product_id  = pv.product_id
         WHERE so.status IN ('PLACED', 'SHIPPED', 'DELIVERED')
         GROUP BY so.store_id, sol.variant_id, pv.variant_sku, p.product_name)
 WHERE rn <= 10;


-- =====================================================================================
-- 9. v_recent_orders_unsorted -- the *unwrapped* ROWNUM form (deliberately wrong-ish)
-- =====================================================================================
-- MIGRATION NOTE (H-30): see the note on v_top_products_by_store. This view is what a
-- hurried developer wrote in 2004. It does not return the 50 most recent orders; it
-- returns 50 arbitrary orders sorted by date. Keeping the bug is the point -- a
-- converter that "fixes" it silently has changed behaviour without telling anyone, and
-- a converter that translates it literally to LIMIT 50 has done the same thing.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_recent_orders_unsorted AS
SELECT so.order_id
     , so.order_number
     , so.order_ts
     , so.store_id
     , so.channel_code
     , so.status
     , so.subtotal_amount
     , ROWNUM AS legacy_row_num
  FROM sales_order so
 WHERE ROWNUM <= 50
 ORDER BY so.order_ts DESC;


-- =====================================================================================
-- 10. v_customer_360 -- INSTEAD OF trigger target, six-table join
-- =====================================================================================
-- MIGRATION NOTE (H-27): this view is not inherently updatable -- it joins six tables
-- and none of the outer ones are key-preserved -- so trg_io_customer_360 in
-- 09-triggers.sql supplies the DML. PostgreSQL supports INSTEAD OF triggers on views
-- with the same name and nearly the same semantics, which makes this one of the few
-- trigger cases that converts cleanly. The one difference that bites: a PostgreSQL
-- INSTEAD OF trigger function must RETURN NEW (or OLD for DELETE) or the statement
-- reports zero rows affected and the application decides the update failed.
-- MIGRATION NOTE (H-31): DECODE with a NULL search key appears here. DECODE treats
-- NULL = NULL as a match; CASE ... WHEN NULL never matches. The correct conversion is
-- IS NOT DISTINCT FROM or an explicit null branch, not a mechanical CASE.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_customer_360 AS
SELECT c.customer_id
     , c.customer_ref
     , c.first_name
     , c.last_name
     , c.email
     , c.mobile_phone
     , c.birth_date
     , c.status                                            AS customer_status
     , c.marketing_optin
     , c.created_ts
     , c.last_login_ts
     , c.home_country_code
     , cy.country_name
     , cy.tz_name
     , c.primary_address_id
     , a.line1                                             AS address_line1
     , a.city                                              AS address_city
     , a.postal_code                                       AS address_postal_code
     , c.preferred_store_id
     , s.store_code                                        AS preferred_store_code
     , s.store_name                                        AS preferred_store_name
     , la.loyalty_id
     , la.card_number
     , la.tier_code
     , lt.tier_name
     , lt.discount_pct                                     AS tier_discount_pct
     , la.points_balance
     , la.lifetime_points
     , DECODE(c.mobile_phone, NULL, 'NO_MOBILE', 'HAS_MOBILE')      AS mobile_flag
     , DECODE(c.marketing_optin, 'Y', 'OPTED_IN', 'N', 'OPTED_OUT', 'UNKNOWN')
                                                                    AS marketing_state
     , NVL2(c.gdpr_erasure_ts, 'ERASED', 'LIVE')                    AS gdpr_state
     , NVL2(la.loyalty_id, 'MEMBER', 'GUEST')                       AS loyalty_state
     , NVL(la.points_balance, 0)                                    AS points_or_zero
  FROM customer              c
  JOIN country               cy ON cy.country_code = c.home_country_code
  LEFT JOIN address          a  ON a.address_id    = c.primary_address_id
  LEFT JOIN store            s  ON s.store_id      = c.preferred_store_id
  LEFT JOIN loyalty_account  la ON la.customer_id  = c.customer_id
  LEFT JOIN loyalty_tier     lt ON lt.tier_code    = la.tier_code;


-- =====================================================================================
-- 11. v_product_sellable -- INSTEAD OF trigger target
-- =====================================================================================
-- MIGRATION NOTE (H-27 / H-04): channel_availability is a VARRAY. Selecting it into a
-- view column is legal in Oracle and the converted PostgreSQL view exposes a text[].
-- The residue is the declared bound: VARRAY(8) becomes an unbounded array, so add
-- CHECK (array_length(channel_availability, 1) <= 8) on the base table or the constraint
-- is silently lost.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_product_sellable AS
SELECT pv.variant_id
     , pv.variant_sku
     , pv.barcode_ean13
     , pv.size_code
     , pv.colour_code
     , pv.pack_qty
     , pv.is_active                              AS variant_active
     , p.product_id
     , p.sku
     , p.product_name
     , p.status                                  AS product_status
     , p.list_price
     , p.unit_cost
     , p.margin_pct
     , p.base_uom
     , p.weight_kg
     , p.launch_date
     , p.category_id
     , pc.category_code
     , pc.category_name
     , p.brand_id
     , b.brand_code
     , b.brand_name
     , b.is_own_label
     , p.channel_availability
     , CASE WHEN p.status = 'ACTIVE'
             AND pv.is_active = 'Y'
             AND (p.launch_date IS NULL OR p.launch_date <= SYSDATE)
            THEN 'Y' ELSE 'N' END                AS is_sellable
  FROM product_variant  pv
  JOIN product          p  ON p.product_id   = pv.product_id
  JOIN product_category pc ON pc.category_id = p.category_id
  LEFT JOIN brand       b  ON b.brand_id     = p.brand_id;


-- =====================================================================================
-- 12. v_open_purchase_orders -- INSTEAD OF trigger target
-- =====================================================================================
-- MIGRATION NOTE (H-19): purchase_order is interval range-partitioned on order_date and
-- its primary key (po_id) does NOT include the partition key. PostgreSQL requires every
-- unique constraint on a partitioned table to include all partition columns, so the
-- converted PK widens to (po_id, order_date) -- and this view, plus every FK pointing at
-- purchase_order, has to be revisited. It is the most disruptive single item in the lab.
-- MIGRATION NOTE (T-02): order_date is an Oracle DATE and therefore carries a time
-- component. Converting it to PostgreSQL `date` truncates it and moves rows between
-- partitions. `timestamp` is the correct target.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_open_purchase_orders AS
SELECT po.po_id
     , po.po_number
     , po.supplier_id
     , sup.supplier_code
     , sup.supplier_name
     , po.warehouse_id
     , w.warehouse_code
     , po.order_date
     , po.expected_date
     , po.status
     , po.currency_code
     , po.order_total
     , po.created_by
     , po.approved_by_employee_id
     , e.employee_number                                     AS approver_number
     , TRUNC(SYSDATE) - TRUNC(po.order_date)                 AS age_days
     , CASE WHEN po.expected_date < SYSDATE THEN 'OVERDUE'
            WHEN po.expected_date < SYSDATE + 7 THEN 'DUE_SOON'
            ELSE 'ON_TRACK' END                              AS delivery_flag
     , (SELECT COUNT(*) FROM purchase_order_line pol
         WHERE pol.po_id = po.po_id)                         AS line_count
     , (SELECT NVL(SUM(pol.qty_ordered - NVL(pol.qty_received, 0)), 0)
          FROM purchase_order_line pol
         WHERE pol.po_id = po.po_id)                         AS qty_outstanding
  FROM purchase_order po
  JOIN supplier       sup ON sup.supplier_id  = po.supplier_id
  JOIN warehouse      w   ON w.warehouse_id   = po.warehouse_id
  LEFT JOIN employee  e   ON e.employee_id    = po.approved_by_employee_id
 WHERE po.status IN ('DRAFT', 'SENT', 'PART_RECV');


-- =====================================================================================
-- 13. v_sales_channel_pivot -- PIVOT
-- =====================================================================================
-- MIGRATION NOTE: Oracle's PIVOT operator has no PostgreSQL equivalent. The mechanical
-- conversion is a set of conditional aggregates --
--   SUM(CASE WHEN channel_code = 'WEB' THEN amount END) AS web_amt
-- -- which is what PIVOT compiles to internally anyway, so the numbers match. Two things
-- are lost. First, the generated column *names*: Oracle derives WEB_AMT from the alias
-- pair and PostgreSQL will not, so downstream consumers binding by name break unless the
-- aliases are reproduced exactly. Second, PIVOT XML (the dynamic form) has no analogue at
-- all; tablefunc's crosstab() is the usual substitute and it requires the column list up
-- front, which defeats the purpose. Stick to conditional aggregates.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_sales_channel_pivot AS
SELECT *
  FROM (SELECT so.store_id
             , TRUNC(CAST(so.order_ts AS DATE), 'MM')       AS month_start
             , so.channel_code
             , so.subtotal_amount
          FROM sales_order so
         WHERE so.status IN ('PLACED', 'SHIPPED', 'DELIVERED'))
 PIVOT (SUM(subtotal_amount) AS amt
      , COUNT(*)             AS cnt
   FOR channel_code IN ('POS'     AS pos
                      , 'WEB'     AS web
                      , 'APP'     AS app
                      , 'CALL'    AS call_centre
                      , 'KIOSK'   AS kiosk
                      , 'PARTNER' AS partner));


-- =====================================================================================
-- 14. v_stock_position -- current stock with an optimiser hint
-- =====================================================================================
-- MIGRATION NOTE (T-06): the hint below is a comment to PostgreSQL. It is not rejected,
-- not warned about, and not honoured -- the plan simply changes. Hints are the quietest
-- performance regression in a migration because the SQL text is byte-identical and the
-- diff is clean. Search converted output for /*+ and treat every hit as a plan-review
-- task, then delete them so nobody thinks they still do something.
-- MIGRATION NOTE (H-17): qty_available is a virtual column on inventory_stock, computed
-- on read in Oracle and STORED on write in PostgreSQL. Same value, different write cost.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_stock_position AS
SELECT /*+ INDEX(ist ix_inventory_stock_variant) PARALLEL(4) */
       ist.location_id
     , il.location_code
     , il.location_type
     , il.warehouse_id
     , il.store_id
     , ist.variant_id
     , pv.variant_sku
     , p.product_id
     , p.product_name
     , ist.qty_on_hand
     , ist.qty_reserved
     , ist.qty_available
     , ist.reorder_point
     , ist.reorder_qty
     , ist.last_counted_date
     , ist.last_movement_ts
     , NVL2(ist.reorder_point,
            CASE WHEN ist.qty_available < ist.reorder_point THEN 'BELOW' ELSE 'OK' END,
            'UNMANAGED')                                       AS reorder_state
     , DECODE(SIGN(ist.qty_available), -1, 'NEGATIVE',
                                        0, 'EMPTY',
                                        1, 'IN_STOCK',
                                           'UNKNOWN')          AS availability_band
  FROM inventory_stock    ist
  JOIN inventory_location il ON il.location_id = ist.location_id
  JOIN product_variant    pv ON pv.variant_id  = ist.variant_id
  JOIN product            p  ON p.product_id   = pv.product_id;


-- =====================================================================================
-- 15. v_inventory_reorder -- replenishment candidates
-- =====================================================================================
CREATE OR REPLACE VIEW v_inventory_reorder AS
SELECT ist.location_id
     , ist.variant_id
     , il.warehouse_id
     , il.store_id
     , ist.qty_on_hand
     , ist.qty_reserved
     , ist.qty_available
     , ist.reorder_point
     , NVL(ist.reorder_qty, 0)                                  AS reorder_qty
     , GREATEST(NVL(ist.reorder_qty, 0),
                NVL(ist.reorder_point, 0) - ist.qty_available)   AS suggested_qty
     , sp.supplier_id
     , sp.supplier_sku
     , sp.unit_cost                                             AS supplier_unit_cost
     , sp.lead_time_days
     , sp.min_order_qty
  FROM inventory_stock    ist
  JOIN inventory_location il ON il.location_id = ist.location_id
  LEFT JOIN supplier_product sp
         ON sp.variant_id       = ist.variant_id
        AND sp.is_primary_source = 'Y'
        AND (sp.valid_to IS NULL OR sp.valid_to >= TRUNC(SYSDATE))
 WHERE ist.reorder_point IS NOT NULL
   AND ist.qty_available < ist.reorder_point;


-- =====================================================================================
-- 16. v_promotion_effectiveness
-- =====================================================================================
-- MIGRATION NOTE (H-37): start_ts and end_ts are TIMESTAMP WITH LOCAL TIME ZONE. The
-- comparison against SYSTIMESTAMP below is evaluated in the session zone; Contoso runs
-- promotions that start at local midnight in 11 countries, so "is this promotion live"
-- has 11 answers. On PostgreSQL SYSTIMESTAMP becomes clock_timestamp() -- not now(),
-- which is transaction start -- and the session TimeZone setting takes over the role the
-- Oracle session zone played. Getting that wrong shifts every promotion window.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_promotion_effectiveness AS
SELECT pr.promotion_id
     , pr.promo_code
     , pr.promo_name
     , pr.promo_type
     , pr.country_code
     , pr.status
     , pr.start_ts
     , pr.end_ts
     , pr.budget_amount
     , pr.spent_amount
     , NVL(pr.budget_amount, 0) - NVL(pr.spent_amount, 0)        AS budget_remaining
     , CASE WHEN SYSTIMESTAMP BETWEEN pr.start_ts AND pr.end_ts THEN 'LIVE'
            WHEN SYSTIMESTAMP < pr.start_ts                     THEN 'PENDING'
            ELSE 'ENDED' END                                     AS live_state
     , COUNT(DISTINCT so.order_id)                               AS attributed_orders
     , NVL(SUM(so.subtotal_amount), 0)                           AS attributed_subtotal
     , NVL(SUM(so.discount_amount), 0)                           AS attributed_discount
     , ROUND(NVL(SUM(so.discount_amount), 0)
             / NULLIF(NVL(SUM(so.subtotal_amount), 0), 0) * 100, 2) AS discount_rate_pct
     , COUNT(DISTINCT cp.coupon_id)                              AS coupon_count
     , NVL(SUM(cp.redemption_count), 0)                          AS coupon_redemptions
  FROM promotion pr
  LEFT JOIN sales_order so ON so.promotion_id = pr.promotion_id
  LEFT JOIN coupon      cp ON cp.promotion_id = pr.promotion_id
 GROUP BY pr.promotion_id, pr.promo_code, pr.promo_name, pr.promo_type
        , pr.country_code, pr.status, pr.start_ts, pr.end_ts
        , pr.budget_amount, pr.spent_amount;


-- =====================================================================================
-- 17. v_customer_loyalty_summary
-- =====================================================================================
-- MIGRATION NOTE (H-36): loyalty_tier.review_interval is an INTERVAL YEAR TO MONTH and
-- is added to a DATE below. Oracle has two mutually incompatible interval types and
-- refuses to mix them; PostgreSQL has exactly one, so the converted expression *permits*
-- combinations Oracle rejected. That turns a compile-time error into a runtime surprise.
-- NUMTOYMINTERVAL / NUMTODSINTERVAL become make_interval() or plain multiplication.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_customer_loyalty_summary AS
SELECT la.loyalty_id
     , la.customer_id
     , c.customer_ref
     , c.last_name
     , c.home_country_code
     , la.card_number
     , la.tier_code
     , lt.tier_name
     , lt.min_points
     , lt.points_multiplier
     , la.points_balance
     , la.lifetime_points
     , la.enrolled_date
     , la.tier_reviewed_date
     , la.tier_reviewed_date + lt.review_interval                AS next_review_date
     , la.status                                                 AS account_status
     , (SELECT NVL(SUM(ltx.points_delta), 0)
          FROM loyalty_transaction ltx
         WHERE ltx.loyalty_id = la.loyalty_id
           AND ltx.txn_type   = 'ACCRUE')                        AS points_accrued
     , (SELECT NVL(ABS(SUM(ltx.points_delta)), 0)
          FROM loyalty_transaction ltx
         WHERE ltx.loyalty_id = la.loyalty_id
           AND ltx.txn_type   = 'REDEEM')                        AS points_redeemed
     , (SELECT MAX(ltx.txn_ts)
          FROM loyalty_transaction ltx
         WHERE ltx.loyalty_id = la.loyalty_id)                   AS last_activity_ts
  FROM loyalty_account la
  JOIN customer        c  ON c.customer_id = la.customer_id
  JOIN loyalty_tier    lt ON lt.tier_code  = la.tier_code;


-- =====================================================================================
-- 18. v_supplier_scorecard
-- =====================================================================================
-- MIGRATION NOTE (H-03): supplier.primary_contact is an object column of type t_contact
-- and the expression below calls one of its member functions. PostgreSQL composite types
-- carry no methods -- the conversion is a standalone function taking the composite as its
-- first argument, which then reads as t_contact.display_label(s.primary_contact) via
-- functional notation. That works, but only if the converter emits the function; if it
-- emits only the composite type, this view fails to compile on the target and the failure
-- is at the *view*, a long way from the type definition that caused it.
-- -------------------------------------------------------------------------------------
-- MIGRATION NOTE (H-03, second half): the aggregate is pushed into an inline view rather
-- than written as a GROUP BY over the supplier row. That is not style -- Oracle refuses to
-- GROUP BY an object column unless the type declares a MAP or ORDER method, and t_contact
-- declares neither. PostgreSQL will happily group by a composite, so the converted query
-- has *fewer* restrictions than the original. Latent differences in that direction are the
-- ones nobody tests for.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_supplier_scorecard AS
SELECT s.supplier_id
     , s.supplier_code
     , s.supplier_name
     , s.currency_code
     , s.payment_terms_days
     , s.rating
     , s.is_approved
     , s.lead_time
     , s.primary_contact.display_label()                          AS contact_label
     , s.primary_contact.email                                    AS contact_email
     , NVL(agg.po_count, 0)                                       AS po_count
     , NVL(agg.ordered_value, 0)                                  AS ordered_value
     , NVL(agg.received_count, 0)                                 AS received_count
     , NVL(agg.cancelled_count, 0)                                AS cancelled_count
     , agg.avg_promised_days
     , DECODE(s.is_approved, 'Y', 'APPROVED', 'N', 'PENDING', 'UNKNOWN') AS approval_state
  FROM supplier s
  LEFT JOIN (SELECT po.supplier_id
                  , COUNT(DISTINCT po.po_id)                                 AS po_count
                  , SUM(po.order_total)                                      AS ordered_value
                  , SUM(CASE WHEN po.status = 'RECEIVED'  THEN 1 ELSE 0 END) AS received_count
                  , SUM(CASE WHEN po.status = 'CANCELLED' THEN 1 ELSE 0 END) AS cancelled_count
                  , ROUND(AVG(po.expected_date - po.order_date), 2)          AS avg_promised_days
               FROM purchase_order po
              GROUP BY po.supplier_id) agg
         ON agg.supplier_id = s.supplier_id;


-- =====================================================================================
-- 19. v_returns_analysis
-- =====================================================================================
CREATE OR REPLACE VIEW v_returns_analysis AS
SELECT rr.return_id
     , rr.rma_number
     , rr.order_id
     , rr.customer_id
     , rr.store_id
     , rr.status                                            AS return_status
     , rr.requested_ts
     , rr.closed_ts
     , rr.refund_amount
     , rr.currency_code
     , rl.line_no
     , rl.variant_id
     , rl.qty_returned
     , rl.disposition_code
     , rl.reason_code
     , rn.reason_desc
     , rn.reason_group
     , rn.is_restockable
     , so.order_ts
     , ROUND(CAST(rr.requested_ts AS DATE) - CAST(so.order_ts AS DATE), 1) AS days_to_return
     , RANK() OVER (PARTITION BY rl.reason_code
                    ORDER BY rl.qty_returned DESC NULLS LAST)   AS reason_volume_rank
     , SUM(rl.qty_returned) OVER (PARTITION BY rl.variant_id)   AS variant_total_returned
  FROM return_request rr
  JOIN return_line    rl ON rl.return_id   = rr.return_id
  JOIN return_reason  rn ON rn.reason_code = rl.reason_code
  JOIN sales_order    so ON so.order_id    = rr.order_id;


-- =====================================================================================
-- 20. v_shipment_sla
-- =====================================================================================
-- MIGRATION NOTE (H-36): EXTRACT over an INTERVAL DAY TO SECOND converts, but Oracle and
-- PostgreSQL normalise intervals differently -- PostgreSQL's justify_interval() rolls 36
-- hours into 1 day 12 hours where Oracle keeps the day and hour fields as stored. Two
-- intervals that compare equal can therefore format differently, which matters the
-- moment somebody reports on the string rather than the value.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_shipment_sla AS
SELECT sh.shipment_id
     , sh.order_id
     , sh.carrier_code
     , ca.carrier_name
     , sh.service_level
     , sh.tracking_ref
     , sh.status                                                     AS shipment_status
     , sh.shipped_ts
     , sh.delivered_ts
     , sh.transit_time
     , EXTRACT(DAY  FROM sh.transit_time)                            AS transit_days
     , EXTRACT(HOUR FROM sh.transit_time)                            AS transit_hours
     , ca.cutoff_offset
     , sh.weight_kg
     , CASE WHEN sh.delivered_ts IS NULL             THEN 'IN_TRANSIT'
            WHEN sh.delivered_ts <= sh.shipped_ts + INTERVAL '2' DAY THEN 'ON_TIME'
            ELSE 'LATE' END                                          AS sla_state
     , ROUND(CAST(sh.delivered_ts AS DATE) - CAST(sh.shipped_ts AS DATE), 2)
                                                                     AS actual_days
  FROM shipment sh
  JOIN carrier  ca ON ca.carrier_code = sh.carrier_code;


-- =====================================================================================
-- 21. v_active_price_list_item -- a genuinely updatable, key-preserved view
-- =====================================================================================
-- MIGRATION NOTE: this one needs no INSTEAD OF trigger. It projects a single table with
-- a WHERE clause, so Oracle marks it key-preserved and updatable, and PostgreSQL applies
-- its own automatically-updatable-view rules and reaches the same conclusion. Included as
-- the control case: when a converted view stops being updatable, the difference is the
-- view, not the dialect. WITH CHECK OPTION is deliberately absent so that an UPDATE can
-- push a row out of the view's own predicate -- both dialects allow that, and both
-- surprise people.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_active_price_list_item AS
SELECT pli.price_list_id
     , pli.variant_id
     , pli.effective_from
     , pli.effective_to
     , pli.unit_price
     , pli.was_price
     , pli.tax_rate_id
     , pli.price_reason_code
  FROM price_list_item pli
 WHERE pli.effective_from <= SYSDATE
   AND (pli.effective_to IS NULL OR pli.effective_to > SYSDATE);


-- =====================================================================================
-- 22. v_gl_journal_balance
-- =====================================================================================
-- MIGRATION NOTE (H-17): gl_journal_line.base_amount is a virtual column defined as
-- (debit_amount - credit_amount) * fx_rate. PostgreSQL generated columns must be
-- IMMUTABLE and reference only columns of the same row -- this one qualifies, so it
-- survives as GENERATED ALWAYS ... STORED. Contrast product.margin_pct, which divides by
-- NULLIF(list_price, 0): also fine. The ones that do not survive are any virtual column
-- calling a user function or SYSDATE, and those become view columns or trigger-maintained
-- real columns. Check each one; do not assume the class converts.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_gl_journal_balance AS
SELECT gj.journal_id
     , gj.journal_ref
     , gj.source_module
     , gj.journal_date
     , gj.status                                          AS journal_status
     , gj.posted_ts
     , gj.posted_by
     , gp.fiscal_year
     , gp.period_no
     , gp.status                                          AS period_status
     , COUNT(gjl.line_no)                                 AS line_count
     , NVL(SUM(gjl.debit_amount), 0)                      AS total_debit
     , NVL(SUM(gjl.credit_amount), 0)                     AS total_credit
     , NVL(SUM(gjl.debit_amount), 0) - NVL(SUM(gjl.credit_amount), 0) AS out_of_balance
     , NVL(SUM(gjl.base_amount), 0)                       AS total_base_amount
     , CASE WHEN NVL(SUM(gjl.debit_amount), 0) = NVL(SUM(gjl.credit_amount), 0)
            THEN 'BALANCED' ELSE 'UNBALANCED' END         AS balance_state
  FROM gl_journal      gj
  JOIN gl_period       gp  ON gp.period_id  = gj.period_id
  LEFT JOIN gl_journal_line gjl ON gjl.journal_id = gj.journal_id
 GROUP BY gj.journal_id, gj.journal_ref, gj.source_module, gj.journal_date
        , gj.status, gj.posted_ts, gj.posted_by
        , gp.fiscal_year, gp.period_no, gp.status;


-- =====================================================================================
-- 23. v_store_estate -- DECODE, NVL2, INTERVAL arithmetic, TSLTZ
-- =====================================================================================
-- MIGRATION NOTE (H-31): three flavours of Oracle null handling in one projection.
--   NVL   -> COALESCE, but NVL evaluates both arguments and COALESCE short-circuits.
--            An improvement, unless the second argument had a side effect.
--   NVL2  -> CASE WHEN x IS NOT NULL THEN a ELSE b END. Clean.
--   DECODE-> orafce provides decode(); the native CASE conversion is only equivalent when
--            no search key is NULL. The DECODE on closed_date below has exactly that
--            problem and must become IS NOT DISTINCT FROM.
-- MIGRATION NOTE (H-36): opening_offset and closing_offset are INTERVAL DAY TO SECOND
-- offsets from local midnight, deliberately so a 25-hour Sunday during a DST fold is
-- representable. A conversion that stores them as TIME loses that; interval is correct.
-- MIGRATION NOTE (H-33): store.legacy_migration_notes is the schema's only LONG column
-- and is deliberately NOT selected here. LONG cannot appear in most SQL expressions and
-- many drivers cannot read it at all -- see docs/05-data-movement.md.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_store_estate AS
SELECT s.store_id
     , s.store_code
     , s.store_name
     , s.store_format
     , s.region_id
     , r.region_code
     , r.region_name
     , r.country_code
     , cy.country_name
     , cy.tz_name
     , s.address_id
     , a.city
     , a.postal_code
     , s.opened_date
     , s.closed_date
     , s.selling_area_sqm
     , s.opening_offset
     , s.closing_offset
     , s.closing_offset - s.opening_offset                  AS trading_window
     , s.refit_cycle
     , s.opened_date + s.refit_cycle                        AS next_refit_due
     , s.created_ts
     , s.manager_employee_id
     , e.full_name                                          AS manager_name
     , DECODE(s.closed_date, NULL, 'TRADING', 'CLOSED')     AS trading_state
     , DECODE(s.store_format, 'HYPER',   'LARGE'
                            , 'SUPER',   'LARGE'
                            , 'EXPRESS', 'SMALL'
                            , 'OUTLET',  'SMALL'
                            , 'ONLINE',  'VIRTUAL'
                            ,            'OTHER')           AS format_band
     , NVL2(s.selling_area_sqm,
            ROUND(s.selling_area_sqm / 100, 1),
            NULL)                                           AS area_units
     , NVL(s.selling_area_sqm, 0)                           AS area_or_zero
  FROM store       s
  JOIN region      r  ON r.region_id     = s.region_id
  JOIN country     cy ON cy.country_code = r.country_code
  JOIN address     a  ON a.address_id    = s.address_id
  LEFT JOIN employee e ON e.employee_id  = s.manager_employee_id;


-- =====================================================================================
-- 24. v_fx_latest_rates -- correlated scalar subqueries and a KEEP aggregate
-- =====================================================================================
-- MIGRATION NOTE (H-08): "give me the newest row" written as
-- MAX(x) KEEP (DENSE_RANK LAST ORDER BY d) rather than as a ROWNUM = 1 inline view --
-- because Oracle refuses to correlate an inline view to an outer query (no LATERAL here),
-- which is itself worth knowing: PostgreSQL would have accepted the inline-view form with
-- LATERAL, so the converted query can be written more naturally than the original.
-- The KEEP aggregate becomes FIRST_VALUE/LAST_VALUE with an explicit
--   ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
-- frame; omit the frame and the default stops at the current row and answers a different
-- question, silently. DISTINCT ON (from_currency, to_currency) is the idiomatic and
-- fastest PostgreSQL rewrite.
-- MIGRATION NOTE (T-04): currency_code is CHAR(3). Oracle blank-pads and compares with
-- blank-padding semantics. PostgreSQL char(n) does too, but the moment one side is
-- converted to text the join stops matching on padded values. Convert both sides or
-- neither.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_fx_latest_rates AS
SELECT c1.currency_code                                       AS from_currency
     , c2.currency_code                                       AS to_currency
     , (SELECT MAX(er.rate) KEEP (DENSE_RANK LAST ORDER BY er.rate_date)
          FROM exchange_rate er
         WHERE er.from_currency = c1.currency_code
           AND er.to_currency   = c2.currency_code)           AS latest_rate
     , (SELECT MAX(er.rate_date)
          FROM exchange_rate er
         WHERE er.from_currency = c1.currency_code
           AND er.to_currency   = c2.currency_code)           AS latest_rate_date
     , c1.minor_units                                         AS from_minor_units
     , c2.minor_units                                         AS to_minor_units
  FROM currency c1
     , currency c2
 WHERE c1.currency_code <> c2.currency_code
   AND c1.is_active = 'Y'
   AND c2.is_active = 'Y';


-- =====================================================================================
-- 25. v_order_fulfilment_status
-- =====================================================================================
CREATE OR REPLACE VIEW v_order_fulfilment_status AS
SELECT so.order_id
     , so.order_number
     , so.order_ts
     , so.store_id
     , so.channel_code
     , so.status                                            AS order_status
     , so.currency_code
     , so.order_total
     , COUNT(sol.line_no)                                   AS line_count
     , NVL(SUM(sol.qty), 0)                                 AS qty_ordered
     , NVL(SUM(shipped.qty_shipped), 0)                     AS qty_shipped
     , NVL(SUM(sol.qty), 0) - NVL(SUM(shipped.qty_shipped), 0) AS qty_outstanding
     , CASE WHEN NVL(SUM(shipped.qty_shipped), 0) = 0                  THEN 'UNSHIPPED'
            WHEN NVL(SUM(shipped.qty_shipped), 0) < NVL(SUM(sol.qty), 0) THEN 'PARTIAL'
            ELSE 'COMPLETE' END                             AS fulfilment_state
     , (SELECT NVL(SUM(op.amount), 0)
          FROM order_payment op
         WHERE op.order_id = so.order_id
           AND op.status   = 'CAPTURED')                    AS amount_captured
  FROM sales_order      so
  LEFT JOIN sales_order_line sol ON sol.order_id = so.order_id
  LEFT JOIN (SELECT sl.order_id, sl.order_line_no, SUM(sl.qty_shipped) AS qty_shipped
               FROM shipment_line sl
              GROUP BY sl.order_id, sl.order_line_no) shipped
         ON shipped.order_id      = sol.order_id
        AND shipped.order_line_no = sol.line_no
 GROUP BY so.order_id, so.order_number, so.order_ts, so.store_id, so.channel_code
        , so.status, so.currency_code, so.order_total;


-- =====================================================================================
-- 26. v_data_quality_open
-- =====================================================================================
CREATE OR REPLACE VIEW v_data_quality_open AS
SELECT dqi.issue_id
     , dqi.rule_code
     , dqi.entity_name
     , dqi.entity_key
     , dqi.severity
     , dqi.detail
     , dqi.detected_ts
     , DECODE(dqi.severity, 'FATAL', 1, 'ERROR', 2, 'WARN', 3, 'INFO', 4, 9) AS severity_order
     , COUNT(*)   OVER (PARTITION BY dqi.rule_code)             AS rule_hit_count
     , DENSE_RANK() OVER (ORDER BY dqi.rule_code)               AS rule_seq
     , ROUND(CAST(SYSTIMESTAMP AS DATE) - CAST(dqi.detected_ts AS DATE), 2) AS age_days
  FROM data_quality_issue dqi
 WHERE dqi.resolved_ts IS NULL;


-- =====================================================================================
-- 27. v_audit_recent
-- =====================================================================================
-- MIGRATION NOTE (H-34): old_row and new_row are CLOBs. DBMS_LOB.SUBSTR is partially
-- covered by orafce; the plain PostgreSQL answer is substr() over text, because text is a
-- *value* rather than a mutable locator. Any code that opened a locator and wrote through
-- it needs restructuring -- see pkg_etl_export in 07-packages.sql for the write side.
-- MIGRATION NOTE (H-39): changed_by / client_id / app_user are populated from column
-- DEFAULTs that call SYS_CONTEXT. Those defaults convert to current_setting('...', true)
-- calls, and the trusted-context guarantee is lost in the process -- any session can SET
-- a GUC, where only pkg_security_ctx could set CONTOSO_APP_CTX.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_audit_recent AS
SELECT al.audit_id
     , al.table_name
     , al.pk_value
     , al.action_type
     , DECODE(al.action_type, 'I', 'INSERT', 'U', 'UPDATE', 'D', 'DELETE', 'OTHER')
                                                              AS action_label
     , al.changed_by
     , al.client_id
     , al.app_user
     , al.changed_ts
     , DBMS_LOB.SUBSTR(al.old_row, 400, 1)                    AS old_row_head
     , DBMS_LOB.SUBSTR(al.new_row, 400, 1)                    AS new_row_head
     , NVL2(al.old_row, DBMS_LOB.GETLENGTH(al.old_row), 0)    AS old_row_bytes
     , NVL2(al.new_row, DBMS_LOB.GETLENGTH(al.new_row), 0)    AS new_row_bytes
     , ROW_NUMBER() OVER (PARTITION BY al.table_name ORDER BY al.changed_ts DESC)
                                                              AS recency_seq
  FROM audit_log al
 WHERE al.changed_ts > SYSTIMESTAMP - INTERVAL '30' DAY;


-- =====================================================================================
-- Summary
-- =====================================================================================
DECLARE
  l_views   PLS_INTEGER;
  l_invalid PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_views
    FROM user_objects
   WHERE object_type = 'VIEW' AND object_name NOT LIKE 'V_GEN%';

  SELECT COUNT(*) INTO l_invalid
    FROM user_objects
   WHERE object_type = 'VIEW' AND status = 'INVALID';

  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------------');
  DBMS_OUTPUT.PUT_LINE('06-views.sql summary');
  DBMS_OUTPUT.PUT_LINE('  hand-written views : ' || l_views);
  DBMS_OUTPUT.PUT_LINE('  INVALID views      : ' || l_invalid || ' (must be 0)');
  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------------');
END;
/

PROMPT 06-views.sql complete.

