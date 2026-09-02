--------------------------------------------------------------------------------
-- Contoso Store -- Oracle to Azure Database for PostgreSQL migration lab
-- 99-verify-objects.sql
--
-- The seed's assertion file. scripts/seed-oracle.sh appends it to the very end
-- of every run (it is the only 99-* file the plan keeps), so a seed that
-- "succeeded" but produced a schema the contract does not accept still exits
-- non-zero.
--
-- Runs as CONTOSO. Read-only apart from the optimiser statistics it gathers.
--
--   scripts/seed-oracle.sh --local          (preferred -- runs this last)
--   or, connected as CONTOSO:  SQL> @src/oracle/99-verify-objects.sql
--
-- WHAT IT ASSERTS  (docs/design.md section 12)
--   1. Object count >= the floor of 1000, counted by the contract's rule.
--   2. Zero INVALID objects, except synonyms that are dangling by design.
--   3. At least one dangling synonym, because H-41 needs one to exist.
--   4. Every foreign key ENABLED and VALIDATED.
--   5. The headline hard-case constructs are really present in the dictionary.
--
-- PRESENCE VERSUS CENSUS
--   Check group 4 asserts that each construct EXISTS and warns when it is
--   below the count docs/design.md section 9 designs for. The split is
--   deliberate. A construct that is gone entirely is a construct the converter
--   is never asked about, which silently flatters the conversion report -- that
--   is a seed failure. A construct that is present but thinner than designed
--   still exercises the converter, so it is a finding to record, not a reason
--   to refuse to build the schema. tests/verify-schema.sql is where the full
--   census is asserted hard.
--
-- WHAT IT DOES NOT DO
--   It is a gate, not the test suite. tests/verify-schema.sql carries the full
--   per-object-type budget and the exhaustive H-01..H-43 checks; this file
--   covers the structural subset that is visible in the data dictionary and
--   that a broken seed would plausibly lose. Anything asserted here failing
--   means the seed is wrong, not that a prediction was wrong.
--
-- HOW IT SIGNALS FAILURE
--   Each check prints one PASS / FAIL / warn line. If any hard check failed,
--   the final block raises ORA-20990, which SQL*Plus turns into a non-zero
--   exit under the WHENEVER SQLERROR EXIT FAILURE below -- and which the seed
--   script's log scanner also catches on the 'ORA-' prefix. The directive is
--   repeated here rather than relied on from the seed script's preamble so
--   that a human running the file by hand gets the same exit code.
--------------------------------------------------------------------------------

WHENEVER SQLERROR EXIT FAILURE
WHENEVER OSERROR EXIT FAILURE

SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET FEEDBACK OFF
SET VERIFY OFF
SET LINESIZE 200
SET PAGESIZE 5000

PROMPT
PROMPT ================================================================
PROMPT  99-verify-objects.sql : the contract's assertions over CONTOSO
PROMPT ================================================================

DECLARE
   -- ---------------------------------------------------------------------
   -- Thresholds. These mirror .env.example (OBJECT_COUNT_FLOOR,
   -- GEN_OBJECT_TARGET) and docs/design.md section 8. They are constants
   -- rather than SQL*Plus substitution variables so that the file also runs
   -- correctly when a human executes it by hand, with no DEFINEs set.
   -- ---------------------------------------------------------------------
   c_object_floor  CONSTANT PLS_INTEGER := 1000;   -- OBJECT_COUNT_FLOOR
   c_object_target CONSTANT PLS_INTEGER := 1110;   -- reported, not asserted

   v_failures      PLS_INTEGER := 0;
   v_count         PLS_INTEGER;
   v_total         PLS_INTEGER;
   v_dangling      PLS_INTEGER;

   -- check <id> <what> <ok?> <detail> -- one line per assertion, and a
   -- failure count rather than an immediate raise, so one run reports
   -- everything that is wrong instead of only the first thing.
   PROCEDURE check_that (p_id     IN VARCHAR2,
                         p_what   IN VARCHAR2,
                         p_ok     IN BOOLEAN,
                         p_detail IN VARCHAR2 DEFAULT NULL) IS
   BEGIN
      IF p_ok THEN
         DBMS_OUTPUT.PUT_LINE('  PASS  ' || RPAD(p_id, 6) || RPAD(p_what, 52)
                              || NVL(p_detail, ''));
      ELSE
         v_failures := v_failures + 1;
         DBMS_OUTPUT.PUT_LINE('  FAIL  ' || RPAD(p_id, 6) || RPAD(p_what, 52)
                              || NVL(p_detail, ''));
      END IF;
   END check_that;

   -- Some checks depend on a privilege the image may not have granted (VPD
   -- needs EXECUTE ON SYS.DBMS_RLS, which only SYS can grant). Losing one
   -- hard case is not a reason to fail the seed -- see the same reasoning in
   -- 00-user-tablespace.sql -- so those degrade to a warning.
   PROCEDURE warn_that (p_id   IN VARCHAR2,
                        p_what IN VARCHAR2,
                        p_why  IN VARCHAR2) IS
   BEGIN
      DBMS_OUTPUT.PUT_LINE('  warn  ' || RPAD(p_id, 6) || RPAD(p_what, 52)
                           || p_why);
   END warn_that;

   -- present <id> <what> <actual> <designed> -- the presence-versus-census
   -- rule from the header. Absent is a FAIL; thin is a warn; at or above the
   -- designed count is a PASS.
   PROCEDURE present (p_id       IN VARCHAR2,
                      p_what     IN VARCHAR2,
                      p_actual   IN PLS_INTEGER,
                      p_designed IN PLS_INTEGER,
                      p_unit     IN VARCHAR2 DEFAULT 'objects') IS
   BEGIN
      IF p_actual < 1 THEN
         check_that(p_id, p_what, FALSE, 'ABSENT - the converter is never asked about it');
      ELSIF p_actual < p_designed THEN
         warn_that(p_id, p_what,
                   p_actual || ' ' || p_unit || ', design.md expects ' || p_designed);
      ELSE
         check_that(p_id, p_what, TRUE, p_actual || ' ' || p_unit);
      END IF;
   END present;
BEGIN
   ---------------------------------------------------------------------------
   DBMS_OUTPUT.PUT_LINE('---- 1. object count ----');
   ---------------------------------------------------------------------------
   -- The counting rule is fixed by the contract. LOB segments and partition
   -- objects are storage artefacts, not schema objects a converter has to
   -- reason about, and counting them would let the lab hit its target by
   -- adding partitions rather than by adding constructs.
   SELECT COUNT(*) INTO v_total
     FROM user_objects
    WHERE object_type NOT IN ('LOB','TABLE PARTITION','INDEX PARTITION','LOB PARTITION');

   check_that('C1', 'object count at or above the floor of ' || c_object_floor,
              v_total >= c_object_floor,
              v_total || ' objects (target ' || c_object_target || ')');

   ---------------------------------------------------------------------------
   DBMS_OUTPUT.PUT_LINE('---- 2. compilation state ----');
   ---------------------------------------------------------------------------
   -- A dangling synonym is INVALID and is supposed to be: H-41 exists to see
   -- whether the converter reports it or silently drops it. Every OTHER
   -- invalid object is a build error. An invalid package body is worse than a
   -- missing one, because the conversion tool reads it as source text and
   -- translates it anyway, producing a converted object that is wrong in a way
   -- nobody notices until runtime.
   SELECT COUNT(*) INTO v_dangling
     FROM user_synonyms s
    WHERE NOT EXISTS (SELECT 1
                        FROM all_objects t
                       WHERE t.owner       = NVL(s.table_owner, USER)
                         AND t.object_name = s.table_name);

   SELECT COUNT(*) INTO v_count
     FROM user_objects o
    WHERE o.status = 'INVALID'
      AND NOT (o.object_type = 'SYNONYM'
               AND EXISTS (SELECT 1
                             FROM user_synonyms s
                            WHERE s.synonym_name = o.object_name
                              AND NOT EXISTS (SELECT 1
                                                FROM all_objects t
                                               WHERE t.owner       = NVL(s.table_owner, USER)
                                                 AND t.object_name = s.table_name)));

   check_that('C2', 'no INVALID objects (dangling synonyms excepted)',
              v_count = 0,
              v_count || ' invalid');

   check_that('C3', 'at least one dangling synonym survives (H-41)',
              v_dangling >= 1,
              v_dangling || ' dangling');

   ---------------------------------------------------------------------------
   DBMS_OUTPUT.PUT_LINE('---- 3. referential integrity ----');
   ---------------------------------------------------------------------------
   -- A converted database that disagrees with the source on row counts is
   -- impossible to debug if the source was already inconsistent. The circular
   -- pair (region.manager_employee_id -> employee, employee.store_id -> store
   -- -> region) is exactly why constraints live in their own file, so prove
   -- they all came back ENABLED and VALIDATED afterwards.
   SELECT COUNT(*) INTO v_count
     FROM user_constraints
    WHERE constraint_type = 'R'
      AND (status <> 'ENABLED' OR validated <> 'VALIDATED');

   check_that('C4', 'every foreign key ENABLED and VALIDATED',
              v_count = 0,
              v_count || ' not validated');

   ---------------------------------------------------------------------------
   DBMS_OUTPUT.PUT_LINE('---- 4. the hard cases are actually present ----');
   ---------------------------------------------------------------------------
   -- A construct nobody can find is a construct the converter was never asked
   -- about, and a lab that quietly lost one produces a flattering report.

   -- H-19 / H-20  range, interval and composite partitioning
   BEGIN
      SELECT COUNT(*) INTO v_count FROM user_part_tables;
      present('H-19', 'partitioned tables', v_count, 4, 'tables');
   EXCEPTION
      WHEN OTHERS THEN warn_that('H-19', 'partitioned tables', SQLERRM);
   END;

   -- H-18  index-organized tables
   SELECT COUNT(*) INTO v_count FROM user_tables WHERE iot_type IS NOT NULL;
   present('H-18', 'index-organized tables', v_count, 3, 'tables');

   -- H-21  global temporary tables
   SELECT COUNT(*) INTO v_count FROM user_tables WHERE temporary = 'Y';
   present('H-21', 'global temporary tables', v_count, 3, 'tables');

   -- H-15  materialised views and the MV logs that make FAST refresh possible
   BEGIN
      SELECT (SELECT COUNT(*) FROM user_mviews)
           + (SELECT COUNT(*) FROM user_mview_logs)
        INTO v_count FROM dual;
      present('H-15', 'materialised views + MV logs', v_count, 8);
   EXCEPTION
      WHEN OTHERS THEN warn_that('H-15', 'materialised views + MV logs', SQLERRM);
   END;

   -- H-03 / H-04 / H-05  object types with bodies, VARRAYs, nested tables
   SELECT COUNT(*) INTO v_count FROM user_types;
   present('H-03', 'object types', v_count, 15, 'types');

   SELECT COUNT(*) INTO v_count FROM user_types WHERE typecode = 'COLLECTION';
   present('H-04', 'collection types (VARRAY, nested table)', v_count, 4, 'types');

   -- H-26 / H-27  compound and INSTEAD OF triggers
   SELECT COUNT(*) INTO v_count FROM user_triggers WHERE trigger_type LIKE 'COMPOUND%';
   present('H-26', 'compound triggers', v_count, 3, 'triggers');

   SELECT COUNT(*) INTO v_count FROM user_triggers WHERE trigger_type LIKE 'INSTEAD OF%';
   present('H-27', 'INSTEAD OF triggers', v_count, 3, 'triggers');

   -- H-17  virtual columns, H-16 function-based indexes
   SELECT COUNT(*) INTO v_count FROM user_tab_cols WHERE virtual_column = 'YES';
   present('H-17', 'virtual columns', v_count, 9, 'columns');

   SELECT COUNT(*) INTO v_count FROM user_indexes WHERE index_type LIKE 'FUNCTION-BASED%';
   present('H-16', 'function-based indexes', v_count, 9, 'indexes');

   -- H-33  the single LONG column. One is deliberate: it is the reason the
   -- separate data-movement step in docs/04-migrate-data.md is not trivial.
   SELECT COUNT(*) INTO v_count FROM user_tab_columns WHERE data_type = 'LONG';
   present('H-33', 'the one LONG column', v_count, 1, 'columns');

   -- H-35  XMLTYPE, H-37 TIMESTAMP WITH LOCAL TIME ZONE
   SELECT COUNT(*) INTO v_count FROM user_tab_columns WHERE data_type = 'XMLTYPE';
   present('H-35', 'XMLTYPE columns', v_count, 2, 'columns');

   SELECT COUNT(*) INTO v_count
     FROM user_tab_columns WHERE data_type LIKE 'TIMESTAMP%LOCAL TIME ZONE';
   present('H-37', 'TIMESTAMP WITH LOCAL TIME ZONE columns', v_count, 10, 'columns');

   -- H-14  the scheduler
   BEGIN
      SELECT COUNT(*) INTO v_count FROM user_scheduler_jobs;
      present('H-14', 'scheduler jobs', v_count, 6, 'jobs');
   EXCEPTION
      WHEN OTHERS THEN warn_that('H-14', 'scheduler jobs', SQLERRM);
   END;

   -- H-40  Virtual Private Database. user_policies needs EXECUTE on DBMS_RLS,
   -- which only SYS can grant -- see 00-user-tablespace.sql. Degrades to a
   -- warning rather than failing the whole seed for one hard case.
   BEGIN
      EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM user_policies' INTO v_count;
      IF v_count >= 2 THEN
         check_that('H-40', 'VPD policies', TRUE, v_count || ' policies');
      ELSE
         warn_that('H-40', 'VPD policies',
                   v_count || ' found; needs GRANT EXECUTE ON SYS.DBMS_RLS');
      END IF;
   EXCEPTION
      WHEN OTHERS THEN
         warn_that('H-40', 'VPD policies', 'not readable: ' || SQLERRM);
   END;

   -- H-02 / H-06 / H-24  source-level constructs.
   --
   -- user_source is the right place to look: from 12c it carries TRIGGER rows
   -- as well as packages, types and standalone routines, so a trigger that
   -- carries the pragma is counted here too. Do NOT be tempted to search
   -- user_triggers.trigger_body instead -- it is a LONG, and
   --    WHERE UPPER(trigger_body) LIKE '%...%'
   -- fails with ORA-00932 "expression is of data type LONG". That is hard case
   -- H-33 biting inside the lab's own verification file, which is a fair
   -- preview of what it does to a data-movement tool.
   SELECT COUNT(DISTINCT name) INTO v_count
     FROM user_source WHERE UPPER(text) LIKE '%AUTONOMOUS_TRANSACTION%';
   present('H-02', 'PRAGMA AUTONOMOUS_TRANSACTION', v_count, 3, 'units');

   SELECT COUNT(DISTINCT name) INTO v_count
     FROM user_source WHERE UPPER(text) LIKE '%CONNECT BY%';
   present('H-06', 'CONNECT BY in PL/SQL', v_count, 3, 'units');

   SELECT COUNT(DISTINCT name) INTO v_count
     FROM user_source WHERE UPPER(text) LIKE '%RESULT_CACHE%';
   present('H-24', 'RESULT_CACHE', v_count, 2, 'units');

   ---------------------------------------------------------------------------
   DBMS_OUTPUT.PUT_LINE('---- result ----');
   ---------------------------------------------------------------------------
   IF v_failures > 0 THEN
      DBMS_OUTPUT.PUT_LINE('  ' || v_failures || ' assertion(s) failed.');
      DBMS_OUTPUT.PUT_LINE('  A seed that fails here produced a schema the');
      DBMS_OUTPUT.PUT_LINE('  contract does not accept. Do not convert it: an');
      DBMS_OUTPUT.PUT_LINE('  invalid package body is translated anyway, and a');
      DBMS_OUTPUT.PUT_LINE('  missing construct is one the converter is never');
      DBMS_OUTPUT.PUT_LINE('  asked about. See docs/02-seed-oracle.md section 7.');
      RAISE_APPLICATION_ERROR(-20990,
         '99-verify-objects.sql: ' || v_failures || ' assertion(s) failed'
         || ' (object count ' || v_total || ')');
   END IF;

   DBMS_OUTPUT.PUT_LINE('  All assertions passed. ' || v_total
                        || ' objects, 0 invalid.');
END;
/

PROMPT
PROMPT 99-verify-objects.sql complete.
PROMPT
