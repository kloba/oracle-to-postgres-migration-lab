-- =====================================================================================
-- Contoso Store -- Oracle source schema
-- 08-procedures.sql : standalone procedures and functions
-- =====================================================================================
-- Owner        : CONTOSO
-- Depends on   : 01-types.sql, core + operational tables, 06-views.sql, 07-packages.sql
-- Exercises    : H-06 CONNECT BY, H-07 MERGE, H-11 dynamic DDL, H-12 DBMS_OUTPUT,
--                H-16 function-based index support, H-23 DETERMINISTIC,
--                H-24 RESULT_CACHE, H-28 RAISE_APPLICATION_ERROR, H-37 TSLTZ,
--                H-42 pipelined functions, T-08 ROWID, T-09 SYSDATE, T-11 INSERT ALL
--
-- Design contract: docs/design.md section 6.3 -- ten procedures, twelve functions.
-- They are standalone rather than packaged on purpose: the synonym layer points at
-- them, and the conversion tool treats standalone and packaged code differently.
--
-- MIGRATION NOTE (structural): a standalone Oracle routine converts to a plain
-- PostgreSQL function -- there is no CREATE PROCEDURE distinction worth preserving,
-- although PostgreSQL 11+ does have one and it matters for transaction control. An
-- Oracle procedure that COMMITs must become a PostgreSQL *procedure* (callable with
-- CALL), not a function, because functions cannot commit. Converters that map every
-- routine to a function silently drop the commit boundary. sp_close_gl_period and
-- sp_purge_audit_log below both depend on theirs.
-- =====================================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET SQLBLANKLINES ON
SET DEFINE OFF
SET FEEDBACK ON

PROMPT
PROMPT ==========================================================================
PROMPT 08-procedures.sql : standalone routines
PROMPT ==========================================================================


-- =====================================================================================
-- FUNCTION 1 : fn_fiscal_period -- DETERMINISTIC, pure arithmetic
-- =====================================================================================
-- MIGRATION NOTE (H-23): DETERMINISTIC and genuinely deterministic -- it touches no
-- table and no SYSDATE, so IMMUTABLE is the correct PostgreSQL target. Contrast
-- fn_tier_for_points below, which carries the same Oracle keyword and must become
-- STABLE. The source text does not distinguish them; only reading the body does.
-- MIGRATION NOTE (T-03/T-09): TO_CHAR with a format mask is NLS-sensitive in Oracle and
-- resolves to the *PostgreSQL* to_char unless you call oracle.to_char explicitly, because
-- pg_catalog is always searched first. Same name, subtly different output.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fiscal_period(p_date IN DATE) RETURN NUMBER DETERMINISTIC IS
  l_month PLS_INTEGER;
BEGIN
  IF p_date IS NULL THEN
    RETURN NULL;
  END IF;

  -- Contoso's fiscal year starts in February, so calendar month 2 is fiscal period 1.
  l_month := TO_NUMBER(TO_CHAR(p_date, 'MM'));
  RETURN CASE WHEN l_month = 1 THEN 12 ELSE l_month - 1 END;
END fn_fiscal_period;
/

-- =====================================================================================
-- FUNCTION 2 : fn_working_days_between -- DETERMINISTIC
-- =====================================================================================
CREATE OR REPLACE FUNCTION fn_working_days_between(p_from IN DATE, p_to IN DATE)
  RETURN NUMBER DETERMINISTIC IS
  l_days  PLS_INTEGER := 0;
  l_cur   DATE;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN
    RETURN NULL;
  END IF;

  l_cur := TRUNC(p_from);
  WHILE l_cur <= TRUNC(p_to) LOOP
    -- MIGRATION NOTE (T-03): TO_CHAR(d, 'D') depends on NLS_TERRITORY -- the same date
    -- returns 1 in one session and 2 in another. The TRUNC(d,'IW') form used here is
    -- NLS-independent and is the only portable way to ask "is this a weekend". A
    -- converter cannot fix an NLS-dependent expression for you; it can only preserve it.
    IF l_cur - TRUNC(l_cur, 'IW') < 5 THEN
      l_days := l_days + 1;
    END IF;
    l_cur := l_cur + 1;
  END LOOP;

  RETURN l_days;
END fn_working_days_between;
/

-- =====================================================================================
-- FUNCTION 3 : fn_convert_amount -- RESULT_CACHE
-- =====================================================================================
-- MIGRATION NOTE (H-24): docs/design.md specifies this as
--     RESULT_CACHE RELIES_ON (exchange_rate)
-- and the RELIES_ON clause has been deprecated since Oracle 11.2 -- retained here as a
-- comment so the lab does not depend on a deprecated parse. Either way PostgreSQL has no
-- server-side result cache at any version. The clause is dropped, the function still
-- compiles, the answers are still right, and the only symptom is that an FX lookup that
-- was served from a shared cache now runs the query every time. That is a load-test
-- finding, not a conversion error, which is exactly why it is dangerous.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_convert_amount(p_amount   IN NUMBER,
                                             p_from_ccy IN VARCHAR2,
                                             p_to_ccy   IN VARCHAR2,
                                             p_on_date  IN DATE DEFAULT SYSDATE)
  RETURN NUMBER RESULT_CACHE IS
  l_rate NUMBER;
BEGIN
  IF p_amount IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_from_ccy = p_to_ccy THEN
    RETURN p_amount;
  END IF;

  -- The fallback-to-prior-day pattern: take the newest rate on or before the date asked
  -- for. ROWNUM = 1 over an ordered inline view (H-30).
  BEGIN
    SELECT rate
      INTO l_rate
      FROM (SELECT er.rate
              FROM exchange_rate er
             WHERE er.from_currency = p_from_ccy
               AND er.to_currency   = p_to_ccy
               AND er.rate_date    <= p_on_date
             ORDER BY er.rate_date DESC)
     WHERE ROWNUM = 1;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      -- Try the inverse pair before giving up.
      BEGIN
        SELECT 1 / rate
          INTO l_rate
          FROM (SELECT er.rate
                  FROM exchange_rate er
                 WHERE er.from_currency = p_to_ccy
                   AND er.to_currency   = p_from_ccy
                   AND er.rate_date    <= p_on_date
                   AND er.rate         <> 0
                 ORDER BY er.rate_date DESC)
         WHERE ROWNUM = 1;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          RAISE_APPLICATION_ERROR(-20801,
            'No FX rate for ' || p_from_ccy || '->' || p_to_ccy
            || ' on or before ' || TO_CHAR(p_on_date, 'YYYY-MM-DD'));
      END;
  END;

  RETURN ROUND(p_amount * l_rate, 6);
END fn_convert_amount;
/

-- =====================================================================================
-- FUNCTION 4 : fn_effective_price
-- =====================================================================================
CREATE OR REPLACE FUNCTION fn_effective_price(p_variant_id IN NUMBER,
                                              p_store_id   IN NUMBER,
                                              p_channel    IN VARCHAR2 DEFAULT 'POS',
                                              p_on_date    IN DATE     DEFAULT SYSDATE)
  RETURN NUMBER IS
BEGIN
  -- Named notation on purpose: it is the readable way to call a routine with four
  -- parameters and three defaults, and it converts to PostgreSQL's => notation directly.
  -- The trap is that PostgreSQL matches named arguments by the *converted* parameter
  -- name, so any renaming during conversion breaks every named call site silently.
  RETURN pkg_pricing.effective_price(p_variant_id => p_variant_id,
                                     p_store_id   => p_store_id,
                                     p_channel    => p_channel,
                                     p_on_date    => p_on_date);
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -20401 THEN
      RETURN NULL;
    END IF;
    RAISE;
END fn_effective_price;
/

-- =====================================================================================
-- FUNCTION 5 : fn_tier_for_points -- DETERMINISTIC but reads a table
-- =====================================================================================
-- MIGRATION NOTE (H-23): the case docs/design.md singles out. This is DETERMINISTIC in
-- Oracle -- a promise the database never verifies -- and it reads loyalty_tier. Marking
-- it IMMUTABLE on PostgreSQL lets the planner constant-fold it and cache the result
-- across statements, so changing a tier threshold appears to do nothing until the next
-- hard parse. STABLE is the only correct target. A converter that maps the keyword
-- mechanically introduces a genuine, silent bug. Check every DETERMINISTIC in the schema.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_tier_for_points(p_points IN NUMBER)
  RETURN VARCHAR2 DETERMINISTIC IS
BEGIN
  RETURN pkg_loyalty.tier_for_points(p_points);
END fn_tier_for_points;
/

-- =====================================================================================
-- FUNCTION 6 : fn_category_path -- CONNECT BY
-- =====================================================================================
CREATE OR REPLACE FUNCTION fn_category_path(p_category_id IN NUMBER,
                                            p_separator   IN VARCHAR2 DEFAULT ' > ')
  RETURN VARCHAR2 IS
  l_path VARCHAR2(4000);
BEGIN
  -- MIGRATION NOTE (H-06): SYS_CONNECT_BY_PATH. Two separate hard cases live here.
  --
  -- 1. Oracle requires the separator argument to be a *literal constant*: passing the
  --    p_separator parameter straight through raises ORA-30003 at compile time and the
  --    function never becomes valid. The caller-supplied separator therefore has to be
  --    dispatched over a fixed set of literal-separator queries, which is why the same
  --    CONNECT BY is written out three times below. A PostgreSQL WITH RECURSIVE builds
  --    the path with ordinary string concatenation and happily takes a parameter, so the
  --    converted form collapses back to one query -- an improvement worth calling out.
  --
  -- 2. Oracle raises ORA-30004 at *run* time if any category name contains the
  --    separator; a WITH RECURSIVE rewrite has no such check and produces an ambiguous
  --    path instead of an error. If anything downstream splits this string, add the
  --    guard by hand on the target.
  CASE p_separator
    WHEN '/' THEN
      SELECT LTRIM(SYS_CONNECT_BY_PATH(category_name, '/'), '/')
        INTO l_path
        FROM product_category
       WHERE category_id = p_category_id
       START WITH parent_category_id IS NULL
      CONNECT BY NOCYCLE PRIOR category_id = parent_category_id;
    WHEN ' | ' THEN
      SELECT LTRIM(SYS_CONNECT_BY_PATH(category_name, ' | '), ' | ')
        INTO l_path
        FROM product_category
       WHERE category_id = p_category_id
       START WITH parent_category_id IS NULL
      CONNECT BY NOCYCLE PRIOR category_id = parent_category_id;
    ELSE
      SELECT LTRIM(SYS_CONNECT_BY_PATH(category_name, ' > '), ' > ')
        INTO l_path
        FROM product_category
       WHERE category_id = p_category_id
       START WITH parent_category_id IS NULL
      CONNECT BY NOCYCLE PRIOR category_id = parent_category_id;
  END CASE;

  RETURN l_path;
EXCEPTION
  WHEN NO_DATA_FOUND THEN RETURN NULL;
  WHEN TOO_MANY_ROWS THEN RETURN '(ambiguous)';
END fn_category_path;
/

-- =====================================================================================
-- FUNCTION 7 : fn_manager_chain -- recursive PL/SQL, not CONNECT BY
-- =====================================================================================
-- MIGRATION NOTE (H-06, the procedural half): the same idea as v_employee_reporting_line
-- expressed as recursion rather than as SQL. docs/design.md keeps both shapes on purpose,
-- so the lab can compare how the tool treats them. PL/pgSQL supports recursion, so this
-- converts almost literally -- and that is the finding: the *procedural* form converts
-- more cleanly than the declarative one, which is the opposite of what people expect,
-- and it is also the form that performs worst on both engines.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_manager_chain(p_employee_id IN NUMBER,
                                            p_depth       IN PLS_INTEGER DEFAULT 0)
  RETURN VARCHAR2 IS
  l_manager_id employee.manager_id%TYPE;
  l_number     employee.employee_number%TYPE;
BEGIN
  -- The depth guard is doing real work: employee.manager_id is a self-referencing FK
  -- with no cycle constraint, and a bad data load really can produce a loop. Oracle's
  -- CONNECT BY NOCYCLE would have caught it declaratively; here it is manual, and on
  -- PostgreSQL WITH RECURSIVE needs the same guard (or the PG 14+ CYCLE clause).
  IF p_employee_id IS NULL OR p_depth > 20 THEN
    RETURN NULL;
  END IF;

  SELECT employee_number, manager_id
    INTO l_number, l_manager_id
    FROM employee
   WHERE employee_id = p_employee_id;

  IF l_manager_id IS NULL THEN
    RETURN l_number;
  END IF;

  RETURN l_number || ' <- ' || fn_manager_chain(l_manager_id, p_depth + 1);
EXCEPTION
  WHEN NO_DATA_FOUND THEN RETURN NULL;
END fn_manager_chain;
/

-- =====================================================================================
-- FUNCTION 8 : fn_location_depth -- the second recursive routine
-- =====================================================================================
-- inventory_location.parent_location_id is the fifth hierarchy in the schema and is
-- deliberately walked only procedurally (docs/design.md section 4.1), never with
-- CONNECT BY, so the lab has a controlled comparison.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_location_depth(p_location_id IN NUMBER)
  RETURN NUMBER IS
  l_parent inventory_location.parent_location_id%TYPE;
BEGIN
  IF p_location_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT parent_location_id INTO l_parent
    FROM inventory_location WHERE location_id = p_location_id;

  IF l_parent IS NULL THEN
    RETURN 1;
  END IF;

  RETURN 1 + fn_location_depth(l_parent);
EXCEPTION
  WHEN NO_DATA_FOUND THEN RETURN 0;
END fn_location_depth;
/

-- =====================================================================================
-- FUNCTION 9 : fn_store_local_time -- TIMESTAMP WITH LOCAL TIME ZONE
-- =====================================================================================
-- MIGRATION NOTE (H-37): the function that makes the time-zone problem concrete. Oracle
-- normalises a TSLTZ to the *database* time zone on storage and renders it in the
-- *session* zone; PostgreSQL stores timestamptz as UTC and renders it in the TimeZone
-- GUC. Getting DBTIMEZONE or SESSIONTIMEZONE wrong during conversion moves every
-- timestamp in the database by hours, silently, with no error and no failed test unless
-- somebody is comparing values across zones. Contoso trades in 11 countries, so this is
-- not hypothetical. Note also that AT TIME ZONE means something different applied to a
-- timestamptz than to a timestamp -- on PostgreSQL it *converts* one way and *attaches*
-- the other, and the two are easy to swap.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_store_local_time(p_store_id IN NUMBER,
                                               p_ts       IN TIMESTAMP WITH LOCAL TIME ZONE
                                                             DEFAULT SYSTIMESTAMP)
  RETURN TIMESTAMP IS
  l_tz    country.tz_name%TYPE;
  l_local TIMESTAMP;
BEGIN
  SELECT cy.tz_name
    INTO l_tz
    FROM store    s
    JOIN region   r  ON r.region_id     = s.region_id
    JOIN country  cy ON cy.country_code = r.country_code
   WHERE s.store_id = p_store_id;

  -- The conversion runs through a SELECT ... FROM dual (T-05) rather than a bare PL/SQL
  -- expression, which is how this was written in 2003 and which keeps the datetime
  -- arithmetic firmly in the SQL engine where its NLS and time-zone rules are defined.
  SELECT CAST(p_ts AT TIME ZONE l_tz AS TIMESTAMP)
    INTO l_local
    FROM dual;

  RETURN l_local;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN CAST(p_ts AS TIMESTAMP);
  WHEN OTHERS THEN
    -- An unrecognised IANA zone name raises ORA-01882. Real tz databases drift between
    -- Oracle versions and between Oracle and PostgreSQL, so this is a live risk.
    RETURN CAST(p_ts AS TIMESTAMP);
END fn_store_local_time;
/

-- =====================================================================================
-- FUNCTION 10 : fn_normalise_sku -- DETERMINISTIC, backs a function-based index
-- =====================================================================================
-- MIGRATION NOTE (H-16 + H-23): this function exists to be indexed --
-- fbi_product_sku_norm is defined on fn_normalise_sku(sku) in 05-indexes.sql.
-- PostgreSQL will only accept a function in an index expression if it is IMMUTABLE, and
-- IMMUTABLE is a promise the planner *enforces*, where Oracle's DETERMINISTIC is one it
-- merely records. This body is genuinely immutable -- no table access, no SYSDATE, no
-- NLS-dependent formatting -- so the mapping is safe here. It is not safe in general,
-- and the converter cannot tell the two apart.
-- MIGRATION NOTE (build order): because 05-indexes.sql runs before this file, the
-- function-based index over fn_normalise_sku must be created after 08-procedures.sql or
-- deferred to a later step. That ordering constraint is invisible in the Oracle DDL and
-- reappears in the converted output.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_normalise_sku(p_sku IN VARCHAR2)
  RETURN VARCHAR2 DETERMINISTIC IS
BEGIN
  RETURN UPPER(REGEXP_REPLACE(TRIM(p_sku), '[^A-Za-z0-9]', ''));
END fn_normalise_sku;
/

-- -------------------------------------------------------------------------------------
-- fbi_product_sku_norm -- the ninth function-based index (H-16)
--
-- 04-indexes.sql deliberately leaves this one to us: it cannot exist before
-- fn_normalise_sku does, and creating it there would fail with ORA-00904. It is created
-- here, immediately after the function, and 04-indexes.sql's cleanup block explicitly
-- skips it so a re-run does not delete it.
--
-- MIGRATION NOTE (H-16 + H-23): Oracle accepts this index because fn_normalise_sku is
-- marked DETERMINISTIC -- a promise Oracle never verifies. PostgreSQL will only index an
-- expression whose function is IMMUTABLE, and it enforces that promise: an IMMUTABLE
-- function is constant-folded at plan time and its results cached across statements. This
-- particular body is genuinely immutable, so the mapping is safe. The next one may not
-- be, and the source text gives the converter no way to tell. Every DETERMINISTIC
-- function backing an index needs a human to read its body.
-- -------------------------------------------------------------------------------------
DECLARE
  l_exists PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_exists
    FROM user_indexes WHERE index_name = 'FBI_PRODUCT_SKU_NORM';

  IF l_exists = 0 THEN
    EXECUTE IMMEDIATE 'CREATE INDEX fbi_product_sku_norm ON product (fn_normalise_sku(sku))';
    DBMS_OUTPUT.PUT_LINE('   .. fbi_product_sku_norm created');
  ELSE
    DBMS_OUTPUT.PUT_LINE('   .. fbi_product_sku_norm already present');
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** fbi_product_sku_norm not created: '
                         || SUBSTR(SQLERRM, 1, 200));
    DBMS_OUTPUT.PUT_LINE('   ***         *** H-16 loses its most interesting case.');
END;
/

-- =====================================================================================
-- FUNCTION 11 : fn_mask_email
-- =====================================================================================
CREATE OR REPLACE FUNCTION fn_mask_email(p_email IN VARCHAR2) RETURN VARCHAR2 IS
  l_at PLS_INTEGER;
BEGIN
  -- MIGRATION NOTE (H-38): p_email = '' arrives here as NULL in Oracle and returns NULL.
  -- On PostgreSQL '' is a distinct value, LENGTH('') is 0 rather than NULL, and the
  -- function returns '' instead. Every downstream IS NULL test on the masked value then
  -- changes answer for that subset of rows. Nothing errors; the counts just move.
  IF p_email IS NULL THEN
    RETURN NULL;
  END IF;

  l_at := INSTR(p_email, '@');
  IF l_at <= 1 THEN
    RETURN '***';
  END IF;

  RETURN SUBSTR(p_email, 1, 1) || RPAD('*', GREATEST(l_at - 2, 1), '*')
         || SUBSTR(p_email, l_at);
END fn_mask_email;
/

-- =====================================================================================
-- FUNCTION 12 : fn_order_line_count -- PIPELINED
-- =====================================================================================
-- MIGRATION NOTE (H-42): PIPE ROW streams; PL/pgSQL's RETURN NEXT materialises. Consumed
-- from SQL as TABLE(fn_order_line_count(...)), which becomes a bare function call in the
-- FROM clause on PostgreSQL -- and needs LATERAL if it is correlated to another table in
-- the same FROM. A converter that misses the LATERAL either fails to parse or, worse,
-- produces a silent cross join that returns plausible but wrong numbers.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_order_line_count(p_store_id IN NUMBER,
                                               p_from     IN DATE DEFAULT NULL,
                                               p_to       IN DATE DEFAULT NULL)
  RETURN t_number_tab PIPELINED IS
BEGIN
  FOR r IN (SELECT COUNT(*) AS line_count
              FROM sales_order      so
              JOIN sales_order_line sol ON sol.order_id = so.order_id
             WHERE so.store_id = p_store_id
               AND (p_from IS NULL OR CAST(so.order_ts AS DATE) >= p_from)
               AND (p_to   IS NULL OR CAST(so.order_ts AS DATE) <  p_to + 1)
             GROUP BY so.order_id
             ORDER BY so.order_id) LOOP
    PIPE ROW (r.line_count);
  END LOOP;
  RETURN;
END fn_order_line_count;
/

-- =====================================================================================
-- FUNCTION 13 : fn_split_csv -- PIPELINED, with a DEFAULT parameter
-- =====================================================================================
CREATE OR REPLACE FUNCTION fn_split_csv(p_text  IN VARCHAR2,
                                        p_delim IN VARCHAR2 DEFAULT ',')
  RETURN t_varchar_tab PIPELINED IS
  l_start PLS_INTEGER := 1;
  l_pos   PLS_INTEGER;
BEGIN
  IF p_text IS NULL THEN
    RETURN;
  END IF;

  LOOP
    l_pos := INSTR(p_text, p_delim, l_start);
    EXIT WHEN l_pos = 0;
    PIPE ROW (SUBSTR(p_text, l_start, l_pos - l_start));
    l_start := l_pos + LENGTH(p_delim);
  END LOOP;

  PIPE ROW (SUBSTR(p_text, l_start));
  RETURN;
END fn_split_csv;
/


-- =====================================================================================
-- PROCEDURE 1 : sp_rebuild_category_paths -- nested recursive subprogram
-- =====================================================================================
-- MIGRATION NOTE: the nested procedure `walk` is private to this one call and recurses
-- into itself. PostgreSQL has no nested subprograms, so `walk` becomes a schema-level
-- function: globally visible, globally named, and callable by anyone with USAGE on the
-- schema. Its closure over the enclosing procedure's state also has to become explicit
-- parameters. Neither change is hard; both change the security surface, which is the
-- part that gets missed in review.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_rebuild_category_paths(p_rows_updated OUT NUMBER) IS
  l_count NUMBER := 0;

  PROCEDURE walk(p_category_id IN NUMBER, p_level IN NUMBER) IS
  BEGIN
    IF p_level > 12 THEN
      -- Defensive: product_category.parent_category_id has no cycle constraint.
      RETURN;
    END IF;

    UPDATE product_category
       SET merch_level = p_level
     WHERE category_id = p_category_id;

    l_count := l_count + SQL%ROWCOUNT;

    FOR c IN (SELECT category_id
                FROM product_category
               WHERE parent_category_id = p_category_id
               ORDER BY sort_order, category_code) LOOP
      walk(c.category_id, p_level + 1);
    END LOOP;
  END walk;

BEGIN
  FOR r IN (SELECT category_id
              FROM product_category
             WHERE parent_category_id IS NULL
             ORDER BY sort_order, category_code) LOOP
    walk(r.category_id, 1);
  END LOOP;

  UPDATE product_category pc
     SET is_leaf = CASE WHEN EXISTS (SELECT 1 FROM product_category ch
                                      WHERE ch.parent_category_id = pc.category_id)
                        THEN 'N' ELSE 'Y' END;

  p_rows_updated := l_count;
  DBMS_OUTPUT.PUT_LINE('sp_rebuild_category_paths: ' || l_count || ' levels stamped');
END sp_rebuild_category_paths;
/

-- =====================================================================================
-- PROCEDURE 2 : sp_recalc_inventory_snapshot
-- =====================================================================================
CREATE OR REPLACE PROCEDURE sp_recalc_inventory_snapshot(
    p_warehouse_id IN  NUMBER DEFAULT NULL,
    p_locations    OUT NUMBER) IS
  l_merged NUMBER;
  l_total  NUMBER := 0;
  l_locs   NUMBER := 0;
BEGIN
  FOR r IN (SELECT location_id
              FROM inventory_location
             WHERE p_warehouse_id IS NULL OR warehouse_id = p_warehouse_id) LOOP
    -- Named notation with an OUT parameter, calling into the package layer.
    pkg_inventory.resnapshot_location(p_location_id => r.location_id,
                                      p_rows_merged => l_merged);
    l_total := l_total + NVL(l_merged, 0);
    l_locs  := l_locs + 1;
  END LOOP;

  p_locations := l_locs;
  DBMS_OUTPUT.PUT_LINE('sp_recalc_inventory_snapshot: ' || l_locs
                       || ' locations, ' || l_total || ' stock rows merged');
END sp_recalc_inventory_snapshot;
/

-- =====================================================================================
-- PROCEDURE 3 : sp_expire_promotions
-- =====================================================================================
CREATE OR REPLACE PROCEDURE sp_expire_promotions(p_expired OUT NUMBER) IS
BEGIN
  -- MIGRATION NOTE (T-09 / H-37): SYSTIMESTAMP compared against a TSLTZ column. On
  -- PostgreSQL SYSTIMESTAMP becomes clock_timestamp(), not now() -- now() is transaction
  -- start and does not advance within a statement, while clock_timestamp() does. For a
  -- promotion-expiry sweep the difference is at most milliseconds; for the nightly job
  -- that calls this at 02:00 across 11 countries it is the difference between a promotion
  -- ending at its own local midnight or at the database server's.
  UPDATE promotion
     SET status = 'EXPIRED'
   WHERE status IN ('ACTIVE', 'DRAFT')
     AND end_ts < SYSTIMESTAMP;

  p_expired := SQL%ROWCOUNT;

  FOR r IN (SELECT promotion_id FROM promotion
             WHERE status = 'EXPIRED' AND ROWNUM <= 100) LOOP
    pkg_audit.write_audit('PROMOTION', TO_CHAR(r.promotion_id), 'U',
                          'status=ACTIVE', 'status=EXPIRED');
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('sp_expire_promotions: ' || p_expired || ' promotions expired');
END sp_expire_promotions;
/

-- =====================================================================================
-- PROCEDURE 4 : sp_close_gl_period
-- =====================================================================================
-- MIGRATION NOTE: this procedure COMMITs. On PostgreSQL that forces it to be a
-- PROCEDURE (invoked with CALL), because a FUNCTION cannot commit. A converter that maps
-- every Oracle routine to a PostgreSQL function drops the commit and the period-close
-- becomes part of whatever transaction happened to call it -- which is a correctness
-- problem, not a style one, because the whole point is that the close is durable before
-- the reporting refresh starts.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_close_gl_period(p_period_id IN NUMBER,
                                               p_force     IN VARCHAR2 DEFAULT 'N') IS
  l_status      gl_period.status%TYPE;
  l_unbalanced  NUMBER;
  l_draft       NUMBER;
BEGIN
  SELECT status INTO l_status FROM gl_period WHERE period_id = p_period_id FOR UPDATE;

  IF l_status = 'CLOSED' THEN
    RAISE_APPLICATION_ERROR(-20951, 'GL period ' || p_period_id || ' is already closed');
  END IF;

  SELECT COUNT(*)
    INTO l_unbalanced
    FROM (SELECT gjl.journal_id
            FROM gl_journal_line gjl
            JOIN gl_journal      gj ON gj.journal_id = gjl.journal_id
           WHERE gj.period_id = p_period_id
           GROUP BY gjl.journal_id
          HAVING NVL(SUM(gjl.debit_amount), 0) <> NVL(SUM(gjl.credit_amount), 0));

  SELECT COUNT(*) INTO l_draft
    FROM gl_journal WHERE period_id = p_period_id AND status = 'DRAFT';

  IF (l_unbalanced > 0 OR l_draft > 0) AND NVL(p_force, 'N') <> 'Y' THEN
    RAISE_APPLICATION_ERROR(-20952,
      'Cannot close period ' || p_period_id || ': ' || l_unbalanced
      || ' unbalanced journal(s), ' || l_draft || ' draft journal(s)');
  END IF;

  UPDATE gl_period
     SET status = 'CLOSED', closed_ts = SYSTIMESTAMP
   WHERE period_id = p_period_id;

  pkg_audit.write_audit('GL_PERIOD', TO_CHAR(p_period_id), 'U',
                        'status=' || l_status, 'status=CLOSED');
  COMMIT;

  DBMS_OUTPUT.PUT_LINE('sp_close_gl_period: period ' || p_period_id || ' closed');
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RAISE_APPLICATION_ERROR(-20953, 'Unknown GL period ' || p_period_id);
END sp_close_gl_period;
/

-- =====================================================================================
-- PROCEDURE 5 : sp_purge_audit_log -- deletes by ROWID
-- =====================================================================================
-- MIGRATION NOTE (T-08): ROWID is the physical address of a row and is the fastest
-- possible way to re-find it. PostgreSQL's ctid looks equivalent and is not: it changes
-- on every UPDATE (because PostgreSQL writes a new tuple version) and is rewritten
-- wholesale by VACUUM FULL and CLUSTER. Any code that collects ctids and uses them in a
-- later statement is racing the autovacuum daemon. The conversion must use the real
-- primary key -- here audit_id -- which is slower and correct.
-- MIGRATION NOTE (H-10): BULK COLLECT + FORALL over a UROWID collection. The FORALL
-- collapses to a single DELETE ... WHERE audit_id = ANY(array) on the target.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_purge_audit_log(p_retain_days  IN  NUMBER DEFAULT 365,
                                               p_batch_size   IN  NUMBER DEFAULT 5000,
                                               p_rows_deleted OUT NUMBER) IS
  TYPE t_rid_tab IS TABLE OF UROWID INDEX BY PLS_INTEGER;

  CURSOR c_old IS
    SELECT ROWID
      FROM audit_log
     WHERE changed_ts < SYSTIMESTAMP - NUMTODSINTERVAL(p_retain_days, 'DAY');

  l_rids  t_rid_tab;
  l_total NUMBER := 0;
BEGIN
  OPEN c_old;
  LOOP
    FETCH c_old BULK COLLECT INTO l_rids LIMIT p_batch_size;
    EXIT WHEN l_rids.COUNT = 0;

    FORALL i IN 1 .. l_rids.COUNT
      DELETE FROM audit_log WHERE ROWID = l_rids(i);

    l_total := l_total + SQL%ROWCOUNT;

    -- The intermediate commit is why this is a procedure and not a function, and why the
    -- ROWIDs are re-fetched in batches rather than collected up front.
    COMMIT;

    EXIT WHEN l_rids.COUNT < p_batch_size;
  END LOOP;
  CLOSE c_old;

  p_rows_deleted := l_total;
  DBMS_OUTPUT.PUT_LINE('sp_purge_audit_log: ' || l_total || ' rows purged');
EXCEPTION
  WHEN OTHERS THEN
    IF c_old%ISOPEN THEN
      CLOSE c_old;
    END IF;
    pkg_error.log_and_reraise('SP_PURGE_AUDIT_LOG', 'MAIN',
                              'retain_days=' || p_retain_days);
END sp_purge_audit_log;
/

-- =====================================================================================
-- PROCEDURE 6 : sp_refresh_reporting_layer
-- =====================================================================================
-- MIGRATION NOTE (H-15): DBMS_MVIEW.REFRESH with a comma-separated list refreshes every
-- named materialised view to one consistent point in time. PostgreSQL has no refresh
-- groups and no incremental refresh -- the equivalent is an explicit transaction wrapping
-- several REFRESH MATERIALIZED VIEW statements, and CONCURRENTLY cannot be used inside a
-- transaction block. So you choose between consistency across the set and availability
-- during the refresh. Oracle gave you both. That is a capability loss, not a syntax
-- difference, and it belongs in the findings document.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_refresh_reporting_layer(
    p_method IN VARCHAR2 DEFAULT 'C') IS
BEGIN
  BEGIN
    DBMS_MVIEW.REFRESH(
      list                 => 'MV_SALES_MONTHLY_CATEGORY,MV_STOCK_POSITION,MV_CUSTOMER_RFM',
      method               => p_method,
      atomic_refresh       => TRUE);
    DBMS_OUTPUT.PUT_LINE('sp_refresh_reporting_layer: refreshed with method ' || p_method);
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('sp_refresh_reporting_layer: refresh skipped -- '
                           || SUBSTR(SQLERRM, 1, 150));
  END;

  INSERT INTO job_run_log (run_id, job_name, started_ts, finished_ts, status, message)
  VALUES (pkg_utils.next_id('SEQ_JOB_RUN_ID'), 'REFRESH_REPORTING',
          SYSTIMESTAMP, SYSTIMESTAMP, 'SUCCESS',
          'method=' || p_method);
END sp_refresh_reporting_layer;
/

-- =====================================================================================
-- PROCEDURE 7 : sp_apply_price_change_batch -- MERGE over a collection parameter
-- =====================================================================================
-- MIGRATION NOTE (H-05 + H-07 + H-42): three at once. The parameter is a schema-level
-- nested table of an object type; TABLE(p_points) unnests it inside SQL; and the result
-- drives a MERGE. On PostgreSQL the collection becomes an array of composite, TABLE()
-- becomes unnest(), and MERGE survives on 15+. The one that needs care is the ON clause:
-- Oracle allows the merge key to reference a bind variable (p_price_list_id here) and
-- PostgreSQL does too, but the columns named in ON still cannot be updated in either.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_apply_price_change_batch(
    p_price_list_id   IN  NUMBER,
    p_points          IN  t_price_point_tab,
    p_effective_from  IN  DATE DEFAULT SYSDATE,
    p_rows_affected   OUT NUMBER) IS
  l_from DATE := TRUNC(NVL(p_effective_from, SYSDATE));
BEGIN
  IF p_points IS NULL OR p_points.COUNT = 0 THEN
    p_rows_affected := 0;
    RETURN;
  END IF;

  MERGE INTO price_list_item tgt
  USING (SELECT pp.variant_id AS variant_id
              , pp.price      AS unit_price
           FROM TABLE(p_points) pp
          WHERE pp.price IS NOT NULL) src
     ON (    tgt.price_list_id  = p_price_list_id
         AND tgt.variant_id     = src.variant_id
         AND tgt.effective_from = l_from)
  WHEN MATCHED THEN
    UPDATE SET unit_price        = src.unit_price
             , price_reason_code = 'BATCH_REPRICE'
  WHEN NOT MATCHED THEN
    INSERT (price_list_id, variant_id, effective_from, unit_price, price_reason_code)
    VALUES (p_price_list_id, src.variant_id, l_from, src.unit_price, 'BATCH_REPRICE');

  p_rows_affected := SQL%ROWCOUNT;

  -- The package cache now holds prices that are no longer true. H-43 in one line: on
  -- PostgreSQL there is no cache to clear, so this call has nothing to convert into and
  -- its absence is invisible.
  pkg_pricing.reset_cache;

  DBMS_OUTPUT.PUT_LINE('sp_apply_price_change_batch: ' || p_rows_affected
                       || ' price rows merged');
END sp_apply_price_change_batch;
/

-- =====================================================================================
-- PROCEDURE 8 : sp_reindex_search_keys -- dynamic DDL
-- =====================================================================================
CREATE OR REPLACE PROCEDURE sp_reindex_search_keys(p_prefix   IN  VARCHAR2 DEFAULT 'FBI_',
                                                   p_rebuilt  OUT NUMBER) IS
  l_count NUMBER := 0;
BEGIN
  -- MIGRATION NOTE (H-11 + H-16): dynamic DDL again, this time driven by a catalogue
  -- query. On PostgreSQL: the catalogue is pg_class/pg_index rather than user_indexes,
  -- ALTER INDEX ... REBUILD becomes REINDEX INDEX (or REINDEX INDEX CONCURRENTLY, which
  -- cannot run inside a transaction block), and the identifier must go through
  -- format('%I'). Note the ONLINE keyword has no equivalent -- CONCURRENTLY is close but
  -- has different failure modes and can leave an invalid index behind.
  FOR r IN (SELECT index_name
              FROM user_indexes
             WHERE index_name LIKE p_prefix || '%'
               AND index_type <> 'LOB') LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER INDEX ' || r.index_name || ' REBUILD ONLINE';
      l_count := l_count + 1;
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('  .. ' || r.index_name || ' skipped: '
                             || SUBSTR(SQLERRM, 1, 100));
    END;
  END LOOP;

  p_rebuilt := l_count;
  DBMS_OUTPUT.PUT_LINE('sp_reindex_search_keys: ' || l_count || ' indexes rebuilt');
END sp_reindex_search_keys;
/

-- =====================================================================================
-- PROCEDURE 9 : sp_export_daily_sales
-- =====================================================================================
CREATE OR REPLACE PROCEDURE sp_export_daily_sales(p_for_date IN DATE DEFAULT TRUNC(SYSDATE) - 1) IS
  l_rows   NUMBER;
  l_run_id NUMBER;
  l_err    VARCHAR2(4000);
BEGIN
  l_run_id := pkg_utils.next_id('SEQ_JOB_RUN_ID');

  INSERT INTO job_run_log (run_id, job_name, started_ts, status)
  VALUES (l_run_id, 'EXPORT_DAILY_SALES', SYSTIMESTAMP, 'RUNNING');

  -- Named notation, all three parameters. See H-13 for why this whole call is an
  -- architecture review task rather than a syntax one.
  pkg_etl_export.write_sales_extract(p_from => p_for_date,
                                     p_to   => p_for_date,
                                     p_rows => l_rows);

  UPDATE job_run_log
     SET finished_ts    = SYSTIMESTAMP
       , status         = 'SUCCESS'
       , rows_processed = l_rows
       , elapsed        = SYSTIMESTAMP - started_ts
   WHERE run_id = l_run_id;
EXCEPTION
  WHEN OTHERS THEN
    -- MIGRATION NOTE: SQLERRM is a PL/SQL built-in and cannot be named inside a SQL
    -- statement, so it has to be captured into a local first. It must also be the very
    -- first thing the handler does -- any statement in between can reset it. PL/pgSQL's
    -- equivalent, SQLERRM, *is* usable in the converted UPDATE, so a converter will
    -- usually inline it again; that is safe here but is worth flagging, because the
    -- Oracle text ('ORA-01403: no data found') and the PostgreSQL text differ, and
    -- anything that pattern-matches job_run_log.message will stop matching.
    l_err := SUBSTR(SQLERRM, 1, 4000);
    UPDATE job_run_log
       SET finished_ts = SYSTIMESTAMP
         , status      = 'FAILED'
         , message     = l_err
     WHERE run_id = l_run_id;
    pkg_error.log_error('SP_EXPORT_DAILY_SALES', 'MAIN',
                        'for_date=' || TO_CHAR(p_for_date, 'YYYY-MM-DD'));
END sp_export_daily_sales;
/

-- =====================================================================================
-- PROCEDURE 10 : sp_post_sales_journal -- INSERT ALL
-- =====================================================================================
-- MIGRATION NOTE (T-11): INSERT ALL has no PostgreSQL equivalent. The conversion is a
-- writable CTE with one INSERT per branch, or simply several statements. The conditional
-- form (INSERT FIRST ... WHEN) is worse -- the CTE version evaluates every branch, so the
-- WHEN conditions have to be pushed into each branch's WHERE clause and the "first match
-- wins" semantics reconstructed by hand with negated predicates. Get that wrong and rows
-- land in two tables instead of one.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_post_sales_journal(p_order_id   IN  NUMBER,
                                                  p_journal_id OUT NUMBER) IS
  l_journal_id NUMBER;
  l_period_id  NUMBER;
  l_ccy        sales_order.currency_code%TYPE;
  l_net        NUMBER;
  l_tax        NUMBER;
BEGIN
  SELECT so.currency_code
       , NVL(so.subtotal_amount, 0) - NVL(so.discount_amount, 0)
       , NVL(so.tax_amount, 0)
    INTO l_ccy, l_net, l_tax
    FROM sales_order so
   WHERE so.order_id = p_order_id;

  BEGIN
    SELECT period_id INTO l_period_id
      FROM (SELECT period_id FROM gl_period
             WHERE status = 'OPEN' ORDER BY fiscal_year DESC, period_no DESC)
     WHERE ROWNUM = 1;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20954, 'No OPEN GL period to post order '
                                      || p_order_id || ' into');
  END;

  l_journal_id := pkg_utils.next_id('SEQ_JOURNAL_ID');

  INSERT INTO gl_journal (journal_id, journal_ref, period_id, source_module,
                          journal_date, description, status)
  VALUES (l_journal_id, 'SAL' || LPAD(TO_CHAR(l_journal_id), 12, '0'), l_period_id,
          'SALES', TRUNC(SYSDATE), 'Sales order ' || p_order_id, 'DRAFT');

  -- base_amount is a virtual column and is absent from every column list below.
  INSERT ALL
    INTO gl_journal_line (journal_id, line_no, account_code, debit_amount,
                          credit_amount, currency_code, fx_rate, line_description)
      VALUES (l_journal_id, 1, '1100', net_amount, 0, ccy, 1, 'Debtors')
    INTO gl_journal_line (journal_id, line_no, account_code, debit_amount,
                          credit_amount, currency_code, fx_rate, line_description)
      VALUES (l_journal_id, 2, '4000', 0, net_amount, ccy, 1, 'Sales revenue')
    INTO gl_journal_line (journal_id, line_no, account_code, debit_amount,
                          credit_amount, currency_code, fx_rate, line_description)
      VALUES (l_journal_id, 3, '2200', 0, tax_amount, ccy, 1, 'Output VAT')
  SELECT l_net AS net_amount, l_tax AS tax_amount, l_ccy AS ccy FROM dual;

  p_journal_id := l_journal_id;
  DBMS_OUTPUT.PUT_LINE('sp_post_sales_journal: journal ' || l_journal_id || ' created');
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RAISE_APPLICATION_ERROR(-20955, 'Unknown order ' || p_order_id);
END sp_post_sales_journal;
/

-- =====================================================================================
-- PROCEDURE 11 : sp_apply_contact_update -- object type parameter
-- =====================================================================================
-- MIGRATION NOTE (H-03): an object type as a parameter, with a member function called on
-- it, assigned into an object column. PostgreSQL gets the composite type and the column;
-- it does not get the method, so is_valid_email becomes a standalone function and the
-- call site changes from p_contact.is_valid_email() to is_valid_email(p_contact) -- or to
-- the functional-notation form t_contact.is_valid_email(p_contact), which reads similarly
-- and resolves differently. Neither is automatic.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_apply_contact_update(p_supplier_id IN NUMBER,
                                                    p_contact     IN t_contact,
                                                    p_validate    IN BOOLEAN DEFAULT TRUE) IS
  -- A typed NULL, not a bare one. pkg_audit.write_audit is overloaded on VARCHAR2 and
  -- CLOB, and an untyped NULL matches both -- the H-01 ambiguity, in Oracle, today.
  l_old_value VARCHAR2(200) := NULL;
BEGIN
  IF p_contact IS NULL THEN
    RAISE_APPLICATION_ERROR(-20956, 'Contact must not be null');
  END IF;

  IF p_validate AND p_contact.is_valid_email() <> 'Y' THEN
    RAISE_APPLICATION_ERROR(-20957,
      'Invalid contact email for supplier ' || p_supplier_id);
  END IF;

  UPDATE supplier
     SET primary_contact = p_contact
   WHERE supplier_id = p_supplier_id;

  IF SQL%ROWCOUNT = 0 THEN
    RAISE_APPLICATION_ERROR(-20958, 'Unknown supplier ' || p_supplier_id);
  END IF;

  pkg_audit.write_audit('SUPPLIER', TO_CHAR(p_supplier_id), 'U',
                        l_old_value, p_contact.display_label());
END sp_apply_contact_update;
/

-- =====================================================================================
-- PROCEDURE 12 : sp_seed_demo_data -- default parameters and named notation throughout
-- =====================================================================================
-- MIGRATION NOTE (H-12): DBMS_OUTPUT everywhere, which is the point -- this is the
-- routine a lab participant runs first, so it is the first place the orafce/search_path
-- configuration shows up as either working output or silence. If PG_SEARCH_PATH does not
-- include the dbms_output schema, this procedure runs correctly and prints nothing, which
-- reads exactly like a failure.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_seed_demo_data(p_products   IN NUMBER  DEFAULT 5,
                                              p_verbose    IN VARCHAR2 DEFAULT 'Y',
                                              p_category   IN VARCHAR2 DEFAULT NULL) IS
  l_product_id NUMBER;
  l_category   VARCHAR2(30) := p_category;
  l_made       PLS_INTEGER  := 0;
BEGIN
  IF l_category IS NULL THEN
    BEGIN
      SELECT category_code INTO l_category
        FROM (SELECT category_code FROM product_category
               WHERE NVL(is_leaf, 'N') = 'Y' ORDER BY category_code)
       WHERE ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('sp_seed_demo_data: no categories exist yet -- nothing to do');
        RETURN;
    END;
  END IF;

  FOR i IN 1 .. p_products LOOP
    BEGIN
      -- Named notation against an overloaded routine. This is the call H-01 predicts
      -- will need help on PostgreSQL: named arguments narrow the candidate set in
      -- Oracle, and PostgreSQL resolves named arguments only after the candidate set is
      -- already narrowed by type -- so an overload that Oracle disambiguates by name may
      -- still be ambiguous after conversion.
      l_product_id := pkg_catalog.add_product(
                        p_sku           => 'DEMO-' || TO_CHAR(SYSDATE, 'YYYYMMDD')
                                           || '-' || LPAD(TO_CHAR(i), 3, '0'),
                        p_name          => 'Demo product ' || i,
                        p_category_code => l_category,
                        p_brand_code    => 'CONTOSO',
                        p_list_price    => 9.99 + i,
                        p_unit_cost     => 4.50 + i);
      l_made := l_made + 1;

      IF p_verbose = 'Y' THEN
        DBMS_OUTPUT.PUT_LINE('  created product ' || l_product_id
                             || ' in category ' || l_category);
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('  product ' || i || ' skipped: '
                             || SUBSTR(SQLERRM, 1, 120));
    END;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('sp_seed_demo_data: ' || l_made || ' of ' || p_products
                       || ' demo products created');
  DBMS_OUTPUT.PUT_LINE('  pkg_utils.to_display call count this session: '
                       || pkg_utils.g_call_count);
END sp_seed_demo_data;
/


-- =====================================================================================
-- Summary
-- =====================================================================================
DECLARE
  l_proc    PLS_INTEGER;
  l_func    PLS_INTEGER;
  l_invalid PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_proc
    FROM user_objects
   WHERE object_type = 'PROCEDURE' AND object_name NOT LIKE '%GEN%';

  SELECT COUNT(*) INTO l_func
    FROM user_objects
   WHERE object_type = 'FUNCTION' AND object_name NOT LIKE '%GEN%';

  SELECT COUNT(*) INTO l_invalid
    FROM user_objects
   WHERE object_type IN ('PROCEDURE', 'FUNCTION') AND status = 'INVALID';

  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------------');
  DBMS_OUTPUT.PUT_LINE('08-procedures.sql summary');
  DBMS_OUTPUT.PUT_LINE('  procedures : ' || l_proc);
  DBMS_OUTPUT.PUT_LINE('  functions  : ' || l_func);
  DBMS_OUTPUT.PUT_LINE('  INVALID    : ' || l_invalid || ' (must be 0)');
  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------------');
END;
/

PROMPT 08-procedures.sql complete.

