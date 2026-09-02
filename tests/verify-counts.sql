-- ===========================================================================
-- tests/verify-counts.sql
--
-- Data assertions over the CONTOSO schema. Run against Oracle AFTER
-- scripts/seed-oracle.sh has loaded the schema and the seed data.
--
-- Contoso Store -- Oracle to Azure Database for PostgreSQL migration lab.
-- docs/design.md is the binding contract.
--
-- WHAT IT ASSERTS
--   B1  Every table that the seed layer populates has at least its minimum
--       row count for the current --scale.
--   B2  Referential integrity across the joins that have no foreign key to
--       enforce them, plus the sanity rules a FK cannot express:
--         * no orphan order lines, return lines or shipment lines
--         * no orphan loyalty_transaction.order_id -- a deliberate soft
--           reference with no FK (design.md section 5F)
--         * negative physical inventory only on the deliberate 1-in-40 rows
--         * the employee management line has exactly one root, no cycles,
--           no self-reference, and every employee reachable from the root
--         * every GL journal balances
--         * inventory_location has exactly one parent
--
-- SCALE
--   Row volume does NOT vary continuously with &scale. tools/generate-data.py
--   has exactly three tiers and scripts/seed-oracle.sh snaps the number onto
--   one of them, so the floors are scaled by the TIER FACTOR, not by the raw
--   number. Getting this wrong broke the default: --scale 1 is the medium tier
--   (~96,000 orders) but a raw-&scale floor demanded 195,000 and failed a
--   perfectly good seed.
--
--       --scale        tier     factor   orders    typical use
--       0 .. 0.1       small       x1     2,406    CI smoke test
--       0.5 .. 1.x     medium     x40    96,006    the default
--       2+             large     x200   480,006    the full lab
--
--   The minimums below are FLOORS: a seeder that rounds down, samples, or skews
--   a distribution slightly must not fail the build; a seeder that silently
--   produced nothing must. Most sit at roughly 60% of the .env.example targets.
--   The strongly-scaled operational core -- store, employee, sales_order,
--   sales_order_line, order_payment -- is the exception: its per-scale size is
--   set by tools/generate-data.py's own row plan (which multiplies by 1 / 40 /
--   200 for small / medium / large, i.e. &scale 0.01 / 0.1 / 1), not by the
--   order/customer targets. Those five are floored at ~80% of what the generator
--   actually emits at each scale. They are NOT fixed dimensions -- they scale --
--   so a scale-independent floor was simply wrong: at 0.01 it demanded more rows
--   than a healthy seed contains.
--
--   &scale must be DEFINEd before this file runs. tests/run-tests.sh and
--   scripts/seed-oracle.sh both do that in their SQL*Plus preamble. For a
--   manual run:   SQL> DEFINE scale = 1
--   An empty value is treated as 1.
--
-- HOW IT SIGNALS FAILURE
--   One PASS or FAIL line per assertion, then RAISE_APPLICATION_ERROR if any
--   failed, so SQL*Plus exits non-zero and a script can test $?.
--
-- This script is read-only.
-- ===========================================================================

WHENEVER SQLERROR EXIT FAILURE
WHENEVER OSERROR EXIT FAILURE

SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET FEEDBACK OFF
SET VERIFY OFF
SET HEADING OFF
SET LINESIZE 200
SET PAGESIZE 0
SET TRIMSPOOL ON

PROMPT
PROMPT ===========================================================================
PROMPT  verify-counts.sql   row counts and referential integrity
PROMPT ===========================================================================

DECLARE
   -- TRIM('') is NULL in Oracle, so an empty DEFINE falls back to 1 rather
   -- than blowing up in TO_NUMBER. This is H-38 (empty string is NULL) being
   -- useful for once. The text is converted in the body, not here, so that a
   -- bad value is caught by an exception handler instead of failing the whole
   -- block before it starts.
   v_scale_txt   VARCHAR2(40) := NVL(TRIM('&scale'), '1');
   v_scale       NUMBER;
   v_factor      PLS_INTEGER;   -- generator tier factor: 1, 40 or 200
   v_eff_scale   NUMBER;        -- v_factor/100, the scale the floors are calibrated in
   -- TO_CHAR(0.01) renders as '.01' and TO_CHAR with a decimal mask leaves
   -- a trailing '.' on whole numbers. Neither reads well in a report.
   v_scale_disp  VARCHAR2(40);

   k_max_listed  CONSTANT PLS_INTEGER := 15;

   TYPE t_name_tab IS TABLE OF VARCHAR2(30)  INDEX BY PLS_INTEGER;
   TYPE t_int_tab  IS TABLE OF PLS_INTEGER   INDEX BY PLS_INTEGER;

   v_tab    t_name_tab;   -- table name
   v_fixed  t_int_tab;    -- rows that do not scale (reference data)
   v_scaled t_int_tab;    -- rows at scale 1.0, multiplied by v_scale
   v_n      PLS_INTEGER := 0;

   v_pass   PLS_INTEGER := 0;
   v_fail   PLS_INTEGER := 0;
   v_warn   PLS_INTEGER := 0;

   v_level  VARCHAR2(10);
   v_rows   NUMBER;
   v_min    PLS_INTEGER;
   v_count  PLS_INTEGER;
   v_count2 PLS_INTEGER;
   v_total  NUMBER := 0;

   -- Detail listings run through a weak REF CURSOR rather than a static
   -- cursor FOR loop. PL/SQL resolves static SQL at compile time, so one
   -- table that the seed layer has not created yet would stop this whole
   -- block from compiling and we would report nothing at all instead of
   -- reporting the missing table. (It also exercises H-09 in passing.)
   v_cur    SYS_REFCURSOR;
   v_id     VARCHAR2(60);
   v_txt1   VARCHAR2(200);
   v_txt2   VARCHAR2(200);
   v_num1   NUMBER;
   v_num2   NUMBER;

   PROCEDURE p (p_text IN VARCHAR2) IS
   BEGIN
      DBMS_OUTPUT.PUT_LINE(SUBSTR(p_text, 1, 32000));
   END p;

   PROCEDURE section (p_title IN VARCHAR2) IS
   BEGIN
      p(' ');
      p('-- ' || p_title || ' ' || RPAD('-', GREATEST(3, 68 - LENGTH(p_title)), '-'));
   END section;

   PROCEDURE assert (p_id     IN VARCHAR2,
                     p_label  IN VARCHAR2,
                     p_ok     IN BOOLEAN,
                     p_detail IN VARCHAR2) IS
   BEGIN
      IF p_ok THEN
         v_pass := v_pass + 1;
         p(RPAD('[ PASS ] ' || p_id, 14) || RPAD(p_label, 42) || p_detail);
      ELSE
         v_fail := v_fail + 1;
         p(RPAD('[ FAIL ] ' || p_id, 14) || RPAD(p_label, 42) || p_detail);
      END IF;
   END assert;

   PROCEDURE warn (p_id IN VARCHAR2, p_label IN VARCHAR2, p_detail IN VARCHAR2) IS
   BEGIN
      v_warn := v_warn + 1;
      p(RPAD('[ WARN ] ' || p_id, 14) || RPAD(p_label, 42) || p_detail);
   END warn;

   -- want(table, fixed_rows, rows_at_scale_1)
   --   fixed_rows      reference data that is the same at every scale
   --   rows_at_scale_1 transactional volume, multiplied by &scale
   PROCEDURE want (p_table  IN VARCHAR2,
                   p_fixed  IN PLS_INTEGER,
                   p_scaled IN PLS_INTEGER DEFAULT 0) IS
   BEGIN
      v_n := v_n + 1;
      v_tab(v_n)    := p_table;
      v_fixed(v_n)  := p_fixed;
      v_scaled(v_n) := p_scaled;
   END want;

   -- Row count for one table. The names come from the literal list below,
   -- never from user input, so the concatenation is not an injection surface.
   -- A missing table is reported rather than raised: this file is also useful
   -- while the schema is half-built.
   FUNCTION row_count (p_table IN VARCHAR2) RETURN NUMBER IS
      v_out NUMBER;
   BEGIN
      EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM "' || p_table || '"' INTO v_out;
      RETURN v_out;
   EXCEPTION
      WHEN OTHERS THEN
         RETURN -1;
   END row_count;

   -- Count for a scalar integrity query, or -1 if the query cannot run.
   FUNCTION probe (p_sql IN VARCHAR2) RETURN NUMBER IS
      v_out NUMBER;
   BEGIN
      EXECUTE IMMEDIATE p_sql INTO v_out;
      RETURN v_out;
   EXCEPTION
      WHEN OTHERS THEN
         RETURN -1;
   END probe;

BEGIN
   -- A session whose NLS_NUMERIC_CHARACTERS uses a comma would reject '0.01'.
   -- Try the plain conversion, then the explicit one, then give up and use 1.
   BEGIN
      v_scale := TO_NUMBER(v_scale_txt);
   EXCEPTION
      WHEN OTHERS THEN
         BEGIN
            v_scale := TO_NUMBER(v_scale_txt, '999999999D999999999',
                                 'NLS_NUMERIC_CHARACTERS=''.,''');
         EXCEPTION
            WHEN OTHERS THEN
               v_scale := 1;
         END;
   END;

   IF v_scale IS NULL OR v_scale <= 0 THEN
      v_scale := 1;
   END IF;

   v_scale_disp := RTRIM(TO_CHAR(v_scale, 'FM99990.999999'), '.');

   -- Row volume does NOT vary continuously with &scale. tools/generate-data.py
   -- only has three tiers, and scripts/seed-oracle.sh snaps the number onto one
   -- of them before calling it:
   --
   --     --scale 0 .. 0.1   -> small   (factor   1)
   --     --scale 0.5 .. 1.x -> medium  (factor  40)
   --     --scale 2+         -> large   (factor 200)
   --
   -- Multiplying the floors by the raw &scale therefore asks for the wrong
   -- number everywhere the two disagree, and they disagree badly at the
   -- DEFAULT. `seed-oracle.sh --local` with no --scale is scale 1, which is the
   -- medium tier: ~96,000 orders emitted, but a raw-&scale floor demands
   -- 195,000 and the check fails on a perfectly good seed.
   --
   -- So derive the tier the way seed-oracle.sh does, and express it as the
   -- equivalent scale the floors were calibrated in (small = 0.01), which keeps
   -- every want() number below unchanged and correct at all three tiers.
   v_factor := CASE
                  WHEN v_scale <= 0.1 THEN 1      -- small
                  WHEN v_scale <  2   THEN 40     -- medium
                  ELSE                     200    -- large
               END;
   v_eff_scale := v_factor / 100;

   v_level := CASE v_factor
                 WHEN 1   THEN 'small'
                 WHEN 40  THEN 'medium'
                 ELSE          'large'
              END;

   p(' ');
   p('schema          : ' || SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'));
   p('scale           : ' || v_scale_disp || '   (tier: ' || v_level
     || ', generator factor x' || v_factor || ')');
   p('checked at      : ' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS TZR'));

   -- ==================================================================
   -- B1  Row counts
   -- ==================================================================
   section('B1  row counts vs the minimum for this scale');

   --      table                    fixed   at scale 1.0
   -- A. Reference and geography -- fixed; a fiscal calendar and an ISO
   -- currency list are the same size whatever the order volume.
   want('CURRENCY',                    12);
   want('COUNTRY',                     11);
   want('EXCHANGE_RATE',              200);
   want('REGION',                      30);
   want('CALENDAR_DAY',               730);
   want('TAX_RATE',                    11);

   -- B. Party, employees, stores
   want('ADDRESS',                    900,     18000);
   want('EMPLOYEE',                     0,     34000);
   want('STORE',                        0,     11500);

   -- C. Product catalogue
   want('PRODUCT_CATEGORY',            60);
   want('BRAND',                       40);
   want('PRODUCT',                    600,      3000);
   want('PRODUCT_VARIANT',           1200,      9000);

   -- D. Supplier and procurement
   want('SUPPLIER',                    60,       300);
   want('SUPPLIER_PRODUCT',           600,      6000);
   want('PURCHASE_ORDER',              60,      6000);
   want('PURCHASE_ORDER_LINE',        200,     24000);
   want('GOODS_RECEIPT',               60,     12000);

   -- E. Inventory
   want('WAREHOUSE',                   30);
   want('INVENTORY_LOCATION',         600,      3000);
   want('INVENTORY_STOCK',           1200,     30000);
   want('INVENTORY_MOVEMENT',        1000,    150000);

   -- F. Customer and loyalty
   want('CUSTOMER',                   300,     30000);
   want('CUSTOMER_ADDRESS',           300,     30000);
   want('LOYALTY_TIER',                 4);
   want('LOYALTY_ACCOUNT',            150,     15000);
   want('LOYALTY_TRANSACTION',        300,     60000);

   -- G. Pricing and promotions
   want('PRICE_LIST',                  20);
   want('PRICE_LIST_ITEM',           1200,     30000);
   want('PROMOTION',                   20);
   want('PROMOTION_PRODUCT',          100,      1200);
   want('COUPON',                     100,      6000);

   -- H. Orders and fulfilment
   want('SALES_ORDER',                  0,    195000);
   want('SALES_ORDER_LINE',             0,    450000);
   want('ORDER_PAYMENT',                0,    210000);
   want('CARRIER',                      5);
   want('SHIPMENT',                   600,     60000);
   want('SHIPMENT_LINE',             1000,    120000);

   -- I. Returns
   want('RETURN_REASON',               10);
   want('RETURN_REQUEST',             100,      6000);
   want('RETURN_LINE',                150,      9000);

   -- J. Finance and general ledger
   want('GL_ACCOUNT',                  60);
   want('GL_PERIOD',                   24);
   want('GL_JOURNAL',                 300,     18000);
   want('GL_JOURNAL_LINE',            900,     60000);

   -- K. Operational
   want('APP_PARAMETER',               15);

   p('    ' || RPAD('TABLE', 26) || LPAD('ROWS', 12) || LPAD('MIN', 12) || '  RESULT');
   p('    ' || RPAD('-', 25, '-') || ' ' || LPAD('-', 11, '-') || ' '
     || LPAD('-', 11, '-') || '  ------');

   FOR i IN 1 .. v_n LOOP
      v_rows := row_count(v_tab(i));
      v_min  := v_fixed(i) + CEIL(v_scaled(i) * v_eff_scale);

      IF v_rows < 0 THEN
         p('    ' || RPAD(v_tab(i), 26) || LPAD('-', 12) || LPAD(v_min, 12)
           || '  MISSING');
         v_fail := v_fail + 1;
      ELSE
         v_total := v_total + v_rows;
         p('    ' || RPAD(v_tab(i), 26) || LPAD(TO_CHAR(v_rows, 'FM999999999999'), 12)
           || LPAD(v_min, 12) || '  '
           || CASE WHEN v_rows >= v_min THEN 'ok' ELSE 'SHORT' END);
         IF v_rows >= v_min THEN
            v_pass := v_pass + 1;
         ELSE
            v_fail := v_fail + 1;
         END IF;
      END IF;
   END LOOP;

   p(' ');
   p(RPAD('[ info ]', 14) || RPAD('rows across the seeded tables', 42)
     || TO_CHAR(v_total, 'FM999,999,999,999'));

   -- The three global temporary tables are session-scoped and must be empty
   -- in a fresh session. A GTT with rows here means someone left a
   -- transaction open, or ON COMMIT PRESERVE ROWS is doing something
   -- unexpected -- which is exactly H-21's failure mode.
   v_count  := probe('SELECT COUNT(*) FROM gtt_price_calc');
   v_count2 := probe('SELECT COUNT(*) FROM gtt_order_stage');
   IF v_count < 0 OR v_count2 < 0 THEN
      warn('B1-gtt', 'ON COMMIT DELETE ROWS GTTs empty', 'could not read the GTTs');
   ELSE
      assert('B1-gtt', 'ON COMMIT DELETE ROWS GTTs empty', v_count + v_count2 = 0,
             (v_count + v_count2) || ' rows in a fresh session');
   END IF;

   -- ==================================================================
   -- B2  Referential integrity
   -- ==================================================================
   section('B2  referential integrity');

   -- Every FK is VALIDATED (verify-schema.sql A4 proves that), so Oracle
   -- already guarantees no orphans across a declared FK. These checks target
   -- the joins where that guarantee does NOT apply, plus the invariants a
   -- foreign key cannot express.

   -- --- orphan order lines (FK-backed; cheap insurance, and the single
   -- --- most load-bearing join in the schema)
   v_count := probe('SELECT COUNT(*) FROM sales_order_line l '
                 || 'WHERE NOT EXISTS (SELECT 1 FROM sales_order o '
                 || 'WHERE o.order_id = l.order_id)');
   IF v_count < 0 THEN
      warn('B2-a', 'no orphan sales_order_line', 'query failed');
   ELSE
      assert('B2-a', 'no orphan sales_order_line', v_count = 0,
             v_count || ' orphans');
   END IF;

   -- --- orphan return lines against the order line they refund
   v_count := probe('SELECT COUNT(*) FROM return_line r '
                 || 'WHERE r.order_id IS NOT NULL AND r.order_line_no IS NOT NULL '
                 || 'AND NOT EXISTS (SELECT 1 FROM sales_order_line l '
                 || 'WHERE l.order_id = r.order_id AND l.line_no = r.order_line_no)');
   IF v_count < 0 THEN
      warn('B2-b', 'no orphan return_line', 'query failed');
   ELSE
      assert('B2-b', 'no orphan return_line', v_count = 0, v_count || ' orphans');
   END IF;

   -- --- orphan shipment lines
   v_count := probe('SELECT COUNT(*) FROM shipment_line s '
                 || 'WHERE s.order_id IS NOT NULL AND s.order_line_no IS NOT NULL '
                 || 'AND NOT EXISTS (SELECT 1 FROM sales_order_line l '
                 || 'WHERE l.order_id = s.order_id AND l.line_no = s.order_line_no)');
   IF v_count < 0 THEN
      warn('B2-c', 'no orphan shipment_line', 'query failed');
   ELSE
      assert('B2-c', 'no orphan shipment_line', v_count = 0, v_count || ' orphans');
   END IF;

   -- --- loyalty_transaction.order_id is a SOFT reference. design.md section
   -- --- 5F drops the FK deliberately because sales_order is interval
   -- --- partitioned. Nothing but this test enforces it.
   v_count := probe('SELECT COUNT(*) FROM loyalty_transaction t '
                 || 'WHERE t.order_id IS NOT NULL '
                 || 'AND NOT EXISTS (SELECT 1 FROM sales_order o '
                 || 'WHERE o.order_id = t.order_id)');
   IF v_count < 0 THEN
      warn('B2-d', 'no orphan loyalty_transaction.order_id', 'query failed');
   ELSE
      assert('B2-d', 'no orphan loyalty_transaction.order_id (soft ref)',
             v_count = 0, v_count || ' orphans');
   END IF;

   -- --- negative inventory.
   -- qty_on_hand < 0 is DELIBERATE seed data, not corruption, so B2-e does NOT
   -- assert zero. The inventory generator sets qty_on_hand negative on exactly
   -- every 40th row -- an unrecorded shrink, or a receipt booked after the sale
   -- that consumed the stock -- which real retail systems carry every day. It is
   -- produced and documented in tools/generate-data.py (file_inventory) ->
   -- generated/oracle/data/09-data-inventory.sql: "qty_on_hand is NEGATIVE on
   -- roughly one row in forty. That is not a bug ... any converted report that
   -- assumes non-negative stock is wrong before it starts."
   --
   -- So this is a BOUNDED assertion: the negatives must be EXACTLY that known
   -- population -- one row in forty (FLOOR(rows/40)), and none past the
   -- generator's -30 floor. A seeder that silently produced none, an extra
   -- negative row, or a wild -1e9 all still FAIL. qty_available (= on_hand -
   -- reserved) legitimately goes negative too and is reported below, not failed.
   v_count  := probe('SELECT COUNT(*) FROM inventory_stock WHERE qty_on_hand < 0');
   v_count2 := probe('SELECT COUNT(*) FROM inventory_stock');
   v_num1   := probe('SELECT COUNT(*) FROM inventory_stock WHERE qty_on_hand < -30');
   IF v_count < 0 OR v_count2 < 0 OR v_num1 < 0 THEN
      warn('B2-e', 'negative qty_on_hand: only deliberate rows', 'query failed');
   ELSE
      assert('B2-e', 'negative qty_on_hand: only deliberate rows',
             v_count = FLOOR(v_count2 / 40) AND v_num1 = 0,
             v_count || ' of ' || v_count2 || ' negative (expect '
             || FLOOR(v_count2 / 40) || '), ' || v_num1 || ' past -30');
   END IF;

   v_count := probe('SELECT COUNT(*) FROM inventory_stock '
                 || 'WHERE qty_on_hand - qty_reserved < 0');
   IF v_count >= 0 THEN
      p(RPAD('[ info ]', 14) || RPAD('over-reserved locations (deliberate)', 42)
        || v_count || ' rows with qty_available < 0');
   END IF;

   v_count := probe('SELECT COUNT(*) FROM inventory_stock WHERE qty_reserved < 0');
   IF v_count < 0 THEN
      warn('B2-f', 'no negative qty_reserved', 'query failed');
   ELSE
      assert('B2-f', 'no negative qty_reserved', v_count = 0,
             v_count || ' rows below zero');
   END IF;

   -- --- inventory_location has exactly one parent: a warehouse or a store,
   -- --- never both and never neither (design.md section 5E). Oracle has no
   -- --- boolean in SQL, so the XOR is spelled out.
   v_count := probe('SELECT COUNT(*) FROM inventory_location '
                 || 'WHERE (warehouse_id IS NULL AND store_id IS NULL) '
                 || 'OR (warehouse_id IS NOT NULL AND store_id IS NOT NULL)');
   IF v_count < 0 THEN
      warn('B2-g', 'inventory_location has exactly one parent', 'query failed');
   ELSE
      assert('B2-g', 'inventory_location has exactly one parent', v_count = 0,
             v_count || ' with none or both');
   END IF;

   -- --- the employee management line (hierarchy 2, design.md section 4.1)
   section('B2  employee hierarchy');

   v_count := probe('SELECT COUNT(*) FROM employee WHERE manager_id IS NULL');
   IF v_count < 0 THEN
      warn('B2-h', 'employee tree has exactly one root', 'query failed');
   ELSE
      assert('B2-h', 'employee tree has exactly one root', v_count = 1,
             v_count || ' employees with no manager');
      IF v_count > 1 THEN
         p(' ');
         p('  The rows with no manager:');
         BEGIN
            OPEN v_cur FOR
               'SELECT * FROM ('
            || '  SELECT TO_CHAR(employee_id) AS a, employee_number AS b, '
            || '         job_title AS c '
            || '    FROM employee WHERE manager_id IS NULL '
            || '   ORDER BY employee_id) WHERE ROWNUM <= ' || k_max_listed;
            LOOP
               FETCH v_cur INTO v_id, v_txt1, v_txt2;
               EXIT WHEN v_cur%NOTFOUND;
               p('    ' || LPAD(v_id, 10) || '  ' || RPAD(v_txt1, 22) || v_txt2);
            END LOOP;
            CLOSE v_cur;
         EXCEPTION
            WHEN OTHERS THEN
               IF v_cur%ISOPEN THEN CLOSE v_cur; END IF;
               p('    (could not list them: ' || SQLERRM || ')');
         END;
         p(' ');
      END IF;
   END IF;

   -- No employee is their own manager.
   v_count := probe('SELECT COUNT(*) FROM employee WHERE manager_id = employee_id');
   IF v_count < 0 THEN
      warn('B2-i', 'no employee manages themselves', 'query failed');
   ELSE
      assert('B2-i', 'no employee manages themselves', v_count = 0,
             v_count || ' self-referencing rows');
   END IF;

   -- No cycles anywhere in the tree. Deliberately NO start-with clause:
   -- Oracle then walks from every row, so a cycle that is disconnected from
   -- the root is still found. CONNECT_BY_ISCYCLE needs NOCYCLE to be legal.
   v_count := probe('SELECT COUNT(*) FROM ('
                 || 'SELECT employee_id FROM employee '
                 || 'WHERE CONNECT_BY_ISCYCLE = 1 '
                 || 'CONNECT BY NOCYCLE PRIOR employee_id = manager_id)');
   IF v_count < 0 THEN
      warn('B2-j', 'employee tree has no cycles', 'query failed');
   ELSE
      assert('B2-j', 'employee tree has no cycles', v_count = 0,
             v_count || ' rows on a cycle');
   END IF;

   -- Every employee is reachable from the single root. This catches the
   -- disconnected-subtree case that a root count and a cycle check both miss.
   v_count  := probe('SELECT COUNT(*) FROM ('
                  || 'SELECT employee_id FROM employee '
                  || 'START WITH manager_id IS NULL '
                  || 'CONNECT BY NOCYCLE PRIOR employee_id = manager_id)');
   v_count2 := probe('SELECT COUNT(*) FROM employee');
   IF v_count < 0 OR v_count2 < 0 THEN
      warn('B2-k', 'every employee reachable from the root', 'query failed');
   ELSE
      assert('B2-k', 'every employee reachable from the root',
             v_count = v_count2,
             v_count || ' reachable of ' || v_count2);
   END IF;

   -- The other three hierarchies get the cycle check too. They are cheaper
   -- and a cycle in any of them breaks the CONNECT BY views (H-06).
   v_count := probe('SELECT COUNT(*) FROM ('
                 || 'SELECT category_id FROM product_category '
                 || 'WHERE CONNECT_BY_ISCYCLE = 1 '
                 || 'CONNECT BY NOCYCLE PRIOR category_id = parent_category_id)');
   IF v_count < 0 THEN
      warn('B2-l', 'product_category tree has no cycles', 'query failed');
   ELSE
      assert('B2-l', 'product_category tree has no cycles', v_count = 0,
             v_count || ' rows on a cycle');
   END IF;

   v_count := probe('SELECT COUNT(*) FROM ('
                 || 'SELECT region_id FROM region '
                 || 'WHERE CONNECT_BY_ISCYCLE = 1 '
                 || 'CONNECT BY NOCYCLE PRIOR region_id = parent_region_id)');
   IF v_count < 0 THEN
      warn('B2-m', 'region tree has no cycles', 'query failed');
   ELSE
      assert('B2-m', 'region tree has no cycles', v_count = 0,
             v_count || ' rows on a cycle');
   END IF;

   v_count := probe('SELECT COUNT(*) FROM ('
                 || 'SELECT account_code FROM gl_account '
                 || 'WHERE CONNECT_BY_ISCYCLE = 1 '
                 || 'CONNECT BY NOCYCLE PRIOR account_code = parent_account_code)');
   IF v_count < 0 THEN
      warn('B2-n', 'gl_account tree has no cycles', 'query failed');
   ELSE
      assert('B2-n', 'gl_account tree has no cycles', v_count = 0,
             v_count || ' rows on a cycle');
   END IF;

   -- --- finance
   section('B2  finance');

   -- Every posted journal balances. This is the one business invariant in
   -- the schema that no constraint can express, and it is the query the
   -- converted PostgreSQL side has to reproduce exactly.
   v_count := probe('SELECT COUNT(*) FROM ('
                 || 'SELECT journal_id FROM gl_journal_line '
                 || 'GROUP BY journal_id '
                 || 'HAVING SUM(debit_amount) <> SUM(credit_amount))');
   IF v_count < 0 THEN
      warn('B2-o', 'every GL journal balances', 'query failed');
   ELSE
      assert('B2-o', 'every GL journal balances', v_count = 0,
             v_count || ' unbalanced journals');
      IF v_count > 0 THEN
         p(' ');
         p('  The unbalanced journals:');
         BEGIN
            OPEN v_cur FOR
               'SELECT * FROM ('
            || '  SELECT TO_CHAR(journal_id) AS a, SUM(debit_amount) AS b, '
            || '         SUM(credit_amount) AS c '
            || '    FROM gl_journal_line GROUP BY journal_id '
            || '  HAVING SUM(debit_amount) <> SUM(credit_amount) '
            || '   ORDER BY journal_id) WHERE ROWNUM <= ' || k_max_listed;
            LOOP
               FETCH v_cur INTO v_id, v_num1, v_num2;
               EXIT WHEN v_cur%NOTFOUND;
               p('    journal ' || LPAD(v_id, 12)
                 || '  debit ' || TO_CHAR(v_num1, 'FM999999999990.00')
                 || '  credit ' || TO_CHAR(v_num2, 'FM999999999990.00'));
            END LOOP;
            CLOSE v_cur;
         EXCEPTION
            WHEN OTHERS THEN
               IF v_cur%ISOPEN THEN CLOSE v_cur; END IF;
               p('    (could not list them: ' || SQLERRM || ')');
         END;
         p(' ');
      END IF;
   END IF;

   -- A GL line is a debit or a credit, never both. There is a CHECK for this;
   -- the test proves the CHECK was actually created and validated.
   v_count := probe('SELECT COUNT(*) FROM gl_journal_line '
                 || 'WHERE debit_amount <> 0 AND credit_amount <> 0');
   IF v_count < 0 THEN
      warn('B2-p', 'no GL line is both debit and credit', 'query failed');
   ELSE
      assert('B2-p', 'no GL line is both debit and credit', v_count = 0,
             v_count || ' rows');
   END IF;

   -- Loyalty balances cannot go negative (there is a CHECK; same reasoning).
   v_count := probe('SELECT COUNT(*) FROM loyalty_account WHERE points_balance < 0');
   IF v_count < 0 THEN
      warn('B2-q', 'no negative loyalty balance', 'query failed');
   ELSE
      assert('B2-q', 'no negative loyalty balance', v_count = 0,
             v_count || ' negative balances');
   END IF;

   -- --- H-38 canary. Oracle cannot store '' at all, so this must be zero
   -- --- here and the same query on the converted PostgreSQL side is what
   -- --- shows the divergence. See design.md H-38.
   v_count := probe('SELECT COUNT(*) FROM customer WHERE mobile_phone IS NULL');
   IF v_count >= 0 THEN
      p(RPAD('[ info ]', 14) || RPAD('H-38 canary: customer.mobile_phone NULL', 42)
        || v_count || ' rows -- compare after conversion');
   END IF;

   -- ==================================================================
   -- Verdict
   -- ==================================================================
   p(' ');
   p('===========================================================================');
   p(' verify-counts.sql   ' || v_pass || ' passed, ' || v_fail || ' failed, '
     || v_warn || ' not checked   (scale ' || v_scale_disp || ')');
   p('===========================================================================');
   p(' ');

   IF v_fail > 0 THEN
      RAISE_APPLICATION_ERROR(
         -20102,
         'verify-counts.sql: ' || v_fail || ' assertion(s) failed at scale '
         || v_scale_disp || '. Read the FAIL lines above.');
   END IF;

   IF v_warn > 0 THEN
      p('Note: ' || v_warn || ' check(s) could not run -- usually a table that');
      p('does not exist yet. They are not failures, but they are not passes.');
      p(' ');
   END IF;
END;
/

PROMPT verify-counts.sql: all assertions passed.
PROMPT
