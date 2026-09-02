-- ===========================================================================
-- tests/verify-schema.sql
--
-- Structural assertions over the CONTOSO schema. Run against Oracle AFTER
-- scripts/seed-oracle.sh has loaded the hand-written schema, the generated
-- objects and the seed data.
--
-- Contoso Store -- Oracle to Azure Database for PostgreSQL migration lab.
-- docs/design.md is the binding contract; sections 8 and 12 define what this
-- file asserts.
--
-- WHAT IT ASSERTS
--   A1  Total object count is at least OBJECT_COUNT_FLOOR (1000), counted by
--       the contract's rule in design.md section 8.
--   A2  Zero objects with status INVALID. Any that are invalid are listed
--       with their compilation errors from user_errors.
--   A3  Every object type in the design.md section 8 budget is present with
--       at least its designed count.
--   A4  Every foreign key is ENABLED and VALIDATED.
--   A5  The generated half of the schema is present (design.md section 7).
--   A6  The headline Oracle constructs the lab exists to exercise are really
--       there -- partitioning, IOTs, MV logs, type bodies, compound and
--       INSTEAD OF triggers, VPD, the scheduler, GTTs, virtual columns,
--       LONG and XMLTYPE (design.md section 12, assertion 2).
--
-- HOW IT SIGNALS FAILURE
--   Every assertion prints one PASS or FAIL line. If any assertion failed,
--   the final block calls RAISE_APPLICATION_ERROR, which with the
--   WHENEVER SQLERROR EXIT FAILURE below makes SQL*Plus exit non-zero. A
--   calling script only has to look at $?.
--
-- HOW TO RUN
--   tests/run-tests.sh --local          (preferred -- handles the connection)
--   or, by hand, connected as CONTOSO:
--       SQL> @tests/verify-schema.sql
--
-- This script is read-only. It creates nothing and changes nothing.
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
PROMPT  verify-schema.sql   structural assertions over CONTOSO
PROMPT ===========================================================================

DECLARE
   -- -------------------------------------------------------------------
   -- Thresholds. All of these come from docs/design.md section 8 and from
   -- .env.example. They live here, once, so a contract change is a one-file
   -- edit rather than a hunt through the script.
   -- -------------------------------------------------------------------
   k_object_floor   CONSTANT PLS_INTEGER := 1000;   -- .env OBJECT_COUNT_FLOOR
   k_object_target  CONSTANT PLS_INTEGER := 1110;   -- design.md section 8 total
   k_generated_min  CONSTANT PLS_INTEGER := 760;    -- .env GEN_OBJECT_TARGET
   k_max_listed     CONSTANT PLS_INTEGER := 25;     -- cap on detail listings

   TYPE t_name_tab IS TABLE OF VARCHAR2(30)  INDEX BY PLS_INTEGER;
   TYPE t_int_tab  IS TABLE OF PLS_INTEGER   INDEX BY PLS_INTEGER;

   v_type      t_name_tab;   -- object_type
   v_min       t_int_tab;    -- designed minimum for that type
   v_n         PLS_INTEGER := 0;

   v_pass      PLS_INTEGER := 0;
   v_fail      PLS_INTEGER := 0;
   v_warn      PLS_INTEGER := 0;

   v_count     PLS_INTEGER;
   v_count2    PLS_INTEGER;
   v_actual    PLS_INTEGER;
   v_gen       PLS_INTEGER;
   v_hand      PLS_INTEGER;
   v_listed    PLS_INTEGER;

   -- ------------------------------------------------------------------
   -- Output helpers
   -- ------------------------------------------------------------------
   PROCEDURE p (p_text IN VARCHAR2) IS
   BEGIN
      DBMS_OUTPUT.PUT_LINE(SUBSTR(p_text, 1, 32000));
   END p;

   PROCEDURE section (p_title IN VARCHAR2) IS
   BEGIN
      p(' ');
      p('-- ' || p_title || ' ' || RPAD('-', GREATEST(3, 68 - LENGTH(p_title)), '-'));
   END section;

   -- assert: the single entry point for a PASS/FAIL line.
   PROCEDURE assert (p_id     IN VARCHAR2,
                     p_label  IN VARCHAR2,
                     p_ok     IN BOOLEAN,
                     p_detail IN VARCHAR2) IS
   BEGIN
      IF p_ok THEN
         v_pass := v_pass + 1;
         p(RPAD('[ PASS ] ' || p_id, 14) || RPAD(p_label, 44) || p_detail);
      ELSE
         v_fail := v_fail + 1;
         p(RPAD('[ FAIL ] ' || p_id, 14) || RPAD(p_label, 44) || p_detail);
      END IF;
   END assert;

   -- warn: something we could not check, rather than something that failed.
   -- A missing privilege on a dictionary view must not masquerade as a pass.
   PROCEDURE warn (p_id     IN VARCHAR2,
                   p_label  IN VARCHAR2,
                   p_detail IN VARCHAR2) IS
   BEGIN
      v_warn := v_warn + 1;
      p(RPAD('[ WARN ] ' || p_id, 14) || RPAD(p_label, 44) || p_detail);
   END warn;

   PROCEDURE want (p_type IN VARCHAR2, p_min IN PLS_INTEGER) IS
   BEGIN
      v_n := v_n + 1;
      v_type(v_n) := p_type;
      v_min(v_n)  := p_min;
   END want;

BEGIN
   p(' ');
   p('schema          : ' || SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'));
   p('database        : ' || SYS_CONTEXT('USERENV', 'DB_NAME')
                          || ' / ' || SYS_CONTEXT('USERENV', 'SERVICE_NAME'));
   p('checked at      : ' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS TZR'));

   -- ==================================================================
   -- A1  Object count floor
   -- ==================================================================
   section('A1  object count');

   SELECT COUNT(*)
     INTO v_actual
     FROM user_objects
    WHERE object_type NOT IN ('LOB', 'TABLE PARTITION', 'INDEX PARTITION', 'LOB PARTITION');

   assert('A1',
          'object count >= ' || k_object_floor,
          v_actual >= k_object_floor,
          v_actual || ' objects (design target ' || k_object_target || ')');

   -- Informational, not an assertion. The contract's counting rule in
   -- design.md section 8 excludes TABLE/INDEX/LOB PARTITION but not the
   -- SUBPARTITION types, and inventory_movement is composite-partitioned.
   -- A schema that clears 1000 only because of subpartitions would be
   -- misleading, so show the stricter number next to the contract one.
   SELECT COUNT(*)
     INTO v_count
     FROM user_objects
    WHERE object_type NOT IN ('LOB', 'TABLE PARTITION', 'INDEX PARTITION', 'LOB PARTITION',
                              'TABLE SUBPARTITION', 'INDEX SUBPARTITION', 'LOB SUBPARTITION');
   p(RPAD('[ info ]', 14) || RPAD('excluding subpartitions too', 44)
     || v_count || ' objects');

   -- ==================================================================
   -- A2  No INVALID objects
   -- ==================================================================
   section('A2  invalid objects');

   SELECT COUNT(*) INTO v_count FROM user_objects WHERE status = 'INVALID';

   assert('A2',
          'objects with status INVALID',
          v_count = 0,
          v_count || ' invalid');

   IF v_count > 0 THEN
      p(' ');
      p('  The invalid objects, with the first errors reported by user_errors.');
      p('  Recompile the schema first -- an object can be invalid merely because');
      p('  a dependency was rebuilt:  EXEC UTL_RECOMP.RECOMP_SERIAL(USER);');
      p(' ');
      v_listed := 0;
      FOR r IN (SELECT object_type, object_name
                  FROM user_objects
                 WHERE status = 'INVALID'
                 ORDER BY object_type, object_name)
      LOOP
         v_listed := v_listed + 1;
         EXIT WHEN v_listed > k_max_listed;
         p('    ' || RPAD(r.object_type, 18) || r.object_name);

         FOR e IN (SELECT line, position, text
                     FROM user_errors
                    WHERE name = r.object_name
                      AND type = r.object_type
                    ORDER BY sequence
                    FETCH FIRST 5 ROWS ONLY)
         LOOP
            p('        line ' || LPAD(e.line, 5) || ' col ' || LPAD(e.position, 4)
              || '  ' || SUBSTR(TRIM(e.text), 1, 120));
         END LOOP;
      END LOOP;

      IF v_count > k_max_listed THEN
         p('    ... and ' || (v_count - k_max_listed) || ' more. Full list:');
         p('      SELECT object_type, object_name FROM user_objects WHERE status = ''INVALID'';');
      END IF;
      p(' ');
   END IF;

   -- ==================================================================
   -- A3  Per-type minimums (design.md section 8)
   -- ==================================================================
   section('A3  object types present at the designed count');

   want('VIEW',              198);
   want('SYNONYM',           174);
   want('FUNCTION',          132);
   want('PROCEDURE',         110);
   want('PACKAGE',            85);
   want('PACKAGE BODY',       85);
   want('INDEX',              78);
   want('SEQUENCE',           74);
   want('TRIGGER',            66);
   want('TABLE',              64);
   want('TYPE',               18);
   want('TYPE BODY',           8);
   want('MATERIALIZED VIEW',   6);
   want('JOB',                 6);
   want('PROGRAM',             3);
   want('SCHEDULE',            3);

   p('    ' || RPAD('OBJECT TYPE', 20) || LPAD('ACTUAL', 8) || LPAD('MIN', 8)
     || LPAD('HAND', 8) || LPAD('GEN', 8) || '  RESULT');
   p('    ' || RPAD('-', 19, '-') || ' ' || LPAD('-', 7, '-') || ' '
     || LPAD('-', 7, '-') || ' ' || LPAD('-', 7, '-') || ' '
     || LPAD('-', 7, '-') || '  ------');

   FOR i IN 1 .. v_n LOOP
      -- The gen_ infix is the contract's single predicate for telling
      -- generated objects from hand-written ones (design.md section 2).
      SELECT COUNT(*),
             SUM(CASE WHEN LOWER(object_name) LIKE '%gen\_%' ESCAPE '\' THEN 1 ELSE 0 END)
        INTO v_actual, v_gen
        FROM user_objects
       WHERE object_type = v_type(i);

      v_gen  := NVL(v_gen, 0);
      v_hand := v_actual - v_gen;

      p('    ' || RPAD(v_type(i), 20) || LPAD(v_actual, 8) || LPAD(v_min(i), 8)
        || LPAD(v_hand, 8) || LPAD(v_gen, 8) || '  '
        || CASE WHEN v_actual >= v_min(i) THEN 'ok' ELSE 'SHORT' END);

      IF v_actual < v_min(i) THEN
         v_fail := v_fail + 1;
      ELSE
         v_pass := v_pass + 1;
      END IF;
   END LOOP;

   SELECT COUNT(*)
     INTO v_count
     FROM user_objects
    WHERE object_type IN ('VIEW', 'SYNONYM', 'FUNCTION', 'PROCEDURE', 'PACKAGE',
                          'PACKAGE BODY', 'INDEX', 'SEQUENCE', 'TRIGGER', 'TABLE',
                          'TYPE', 'TYPE BODY', 'MATERIALIZED VIEW', 'JOB',
                          'PROGRAM', 'SCHEDULE');

   -- Each type was scored individually in the loop above, so this is a
   -- summary line rather than a further assertion.
   p(' ');
   p(RPAD('[ info ]', 14) || RPAD('total across the budgeted types', 44)
     || v_count || ' objects');

   -- Any object type we did not budget for is worth seeing, not failing on.
   FOR r IN (SELECT object_type, COUNT(*) AS n
               FROM user_objects
              WHERE object_type NOT IN ('VIEW', 'SYNONYM', 'FUNCTION', 'PROCEDURE',
                                        'PACKAGE', 'PACKAGE BODY', 'INDEX', 'SEQUENCE',
                                        'TRIGGER', 'TABLE', 'TYPE', 'TYPE BODY',
                                        'MATERIALIZED VIEW', 'JOB', 'PROGRAM', 'SCHEDULE',
                                        'LOB', 'TABLE PARTITION', 'INDEX PARTITION',
                                        'LOB PARTITION', 'TABLE SUBPARTITION',
                                        'INDEX SUBPARTITION', 'LOB SUBPARTITION')
              GROUP BY object_type
              ORDER BY object_type)
   LOOP
      p(RPAD('[ info ]', 14) || RPAD('unbudgeted type ' || r.object_type, 44)
        || r.n || ' objects');
   END LOOP;

   -- ==================================================================
   -- A4  Foreign keys ENABLED and VALIDATED
   -- ==================================================================
   section('A4  foreign keys');

   SELECT COUNT(*) INTO v_count
     FROM user_constraints
    WHERE constraint_type = 'R';

   assert('A4a',
          'foreign keys exist',
          v_count > 0,
          v_count || ' foreign keys');

   SELECT COUNT(*) INTO v_count2
     FROM user_constraints
    WHERE constraint_type = 'R'
      AND (status <> 'ENABLED' OR validated <> 'VALIDATED');

   assert('A4b',
          'all foreign keys ENABLED+VALIDATED',
          v_count2 = 0,
          v_count2 || ' not enabled/validated (of ' || v_count || ')');

   IF v_count2 > 0 THEN
      p(' ');
      p('  A foreign key that is DISABLED or NOT VALIDATED does not prove');
      p('  referential integrity, so design.md section 12 assertion 4 cannot');
      p('  be trusted for these tables:');
      p(' ');
      p('    ' || RPAD('CONSTRAINT', 32) || RPAD('TABLE', 26)
        || RPAD('STATUS', 10) || 'VALIDATED');
      v_listed := 0;
      FOR r IN (SELECT constraint_name, table_name, status, validated
                  FROM user_constraints
                 WHERE constraint_type = 'R'
                   AND (status <> 'ENABLED' OR validated <> 'VALIDATED')
                 ORDER BY table_name, constraint_name)
      LOOP
         v_listed := v_listed + 1;
         EXIT WHEN v_listed > k_max_listed;
         p('    ' || RPAD(r.constraint_name, 32) || RPAD(r.table_name, 26)
           || RPAD(r.status, 10) || r.validated);
      END LOOP;
      p(' ');
   END IF;

   -- Constraints of every other type should also be trustworthy. Not part of
   -- the brief's four assertions, but a NOVALIDATE check constraint is the
   -- same class of lie and costs one query to catch.
   SELECT COUNT(*) INTO v_count
     FROM user_constraints
    WHERE constraint_type IN ('P', 'U', 'C')
      AND (status <> 'ENABLED' OR validated <> 'VALIDATED')
      AND generated = 'USER NAME';

   assert('A4c',
          'PK/UK/CHECK enabled+validated',
          v_count = 0,
          v_count || ' not enabled/validated');

   -- ==================================================================
   -- A5  The generated half is present
   -- ==================================================================
   section('A5  generated objects');

   SELECT COUNT(*) INTO v_gen
     FROM user_objects
    WHERE LOWER(object_name) LIKE '%gen\_%' ESCAPE '\'
      AND object_type NOT IN ('LOB', 'TABLE PARTITION', 'INDEX PARTITION', 'LOB PARTITION');

   assert('A5',
          'generated objects >= ' || k_generated_min,
          v_gen >= k_generated_min,
          v_gen || ' carry the gen_ infix');

   -- ==================================================================
   -- A6  The constructs the lab exists to exercise
   --     design.md section 12 assertion 2, in its structural form. A
   --     construct nobody can find is a construct the converter was never
   --     asked about.
   -- ==================================================================
   section('A6  hard-case constructs present');

   -- H-19 / H-20  partitioning
   BEGIN
      SELECT COUNT(*) INTO v_count FROM user_part_tables;
      assert('A6-a', 'partitioned tables (H-19, H-20)', v_count >= 4,
             v_count || ' partitioned tables');
   EXCEPTION WHEN OTHERS THEN
      warn('A6-a', 'partitioned tables (H-19, H-20)', SQLERRM);
   END;

   -- H-18  index-organized tables
   SELECT COUNT(*) INTO v_count FROM user_tables WHERE iot_type IS NOT NULL;
   assert('A6-b', 'index-organized tables (H-18)', v_count >= 3,
          v_count || ' IOTs');

   -- H-21  global temporary tables
   SELECT COUNT(*) INTO v_count FROM user_tables WHERE temporary = 'Y';
   assert('A6-c', 'global temporary tables (H-21)', v_count >= 3,
          v_count || ' GTTs');

   -- H-15  materialised views and their logs
   BEGIN
      SELECT COUNT(*) INTO v_count  FROM user_mviews;
      SELECT COUNT(*) INTO v_count2 FROM user_mview_logs;
      assert('A6-d', 'materialised views + logs (H-15)',
             v_count >= 6 AND v_count2 >= 3,
             v_count || ' MVs, ' || v_count2 || ' MV logs');
   EXCEPTION WHEN OTHERS THEN
      warn('A6-d', 'materialised views + logs (H-15)', SQLERRM);
   END;

   -- H-03  object types with bodies, and the inheritance hierarchy
   SELECT COUNT(*) INTO v_count  FROM user_types WHERE typecode = 'OBJECT';
   SELECT COUNT(*) INTO v_count2 FROM user_types WHERE supertype_name IS NOT NULL;
   assert('A6-e', 'object types + inheritance (H-03)',
          v_count >= 6 AND v_count2 >= 2,
          v_count || ' object types, ' || v_count2 || ' subtypes');

   -- H-04 / H-05  collections
   SELECT COUNT(*) INTO v_count  FROM user_coll_types WHERE coll_type = 'VARYING ARRAY';
   SELECT COUNT(*) INTO v_count2 FROM user_coll_types WHERE coll_type = 'TABLE';
   assert('A6-f', 'VARRAY + nested table types (H-04, H-05)',
          v_count >= 4 AND v_count2 >= 5,
          v_count || ' VARRAYs, ' || v_count2 || ' nested tables');

   -- H-26  compound triggers, H-27 INSTEAD OF triggers
   SELECT COUNT(*) INTO v_count
     FROM user_triggers WHERE trigger_type = 'COMPOUND';
   assert('A6-g', 'compound triggers (H-26)', v_count >= 3,
          v_count || ' compound triggers');

   SELECT COUNT(*) INTO v_count
     FROM user_triggers WHERE trigger_type LIKE 'INSTEAD OF%';
   assert('A6-h', 'INSTEAD OF triggers (H-27)', v_count >= 3,
          v_count || ' INSTEAD OF triggers');

   -- H-17  virtual columns
   SELECT COUNT(*) INTO v_count
     FROM user_tab_cols WHERE virtual_column = 'YES' AND hidden_column = 'NO';
   assert('A6-i', 'virtual columns (H-17)', v_count >= 9,
          v_count || ' virtual columns');

   -- H-33  the single LONG column, H-35 XMLTYPE, H-34 LOBs
   SELECT COUNT(*) INTO v_count FROM user_tab_columns WHERE data_type = 'LONG';
   assert('A6-j', 'the one LONG column (H-33)', v_count >= 1,
          v_count || ' LONG columns');

   SELECT COUNT(*) INTO v_count
     FROM user_tab_columns WHERE data_type IN ('XMLTYPE', 'OPAQUE/XMLTYPE');
   assert('A6-k', 'XMLTYPE columns (H-35)', v_count >= 2,
          v_count || ' XMLTYPE columns');

   -- H-37  TIMESTAMP WITH LOCAL TIME ZONE
   SELECT COUNT(*) INTO v_count
     FROM user_tab_columns WHERE data_type LIKE 'TIMESTAMP%LOCAL TIME ZONE';
   assert('A6-l', 'TSLTZ columns (H-37)', v_count >= 20,
          v_count || ' TSLTZ columns');

   -- H-16  function-based indexes
   SELECT COUNT(*) INTO v_count
     FROM user_indexes WHERE index_type LIKE 'FUNCTION-BASED%';
   assert('A6-m', 'function-based indexes (H-16)', v_count >= 9,
          v_count || ' FBIs');

   -- H-14  the scheduler
   BEGIN
      SELECT COUNT(*) INTO v_count FROM user_scheduler_jobs;
      assert('A6-n', 'scheduler jobs (H-14)', v_count >= 6,
             v_count || ' jobs');
   EXCEPTION WHEN OTHERS THEN
      warn('A6-n', 'scheduler jobs (H-14)', SQLERRM);
   END;

   -- H-40  Virtual Private Database. user_policies needs EXECUTE on DBMS_RLS
   -- and the policies to have been added; a privilege error here is a WARN,
   -- because "I could not look" is not "it is not there".
   BEGIN
      EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM user_policies' INTO v_count;
      assert('A6-o', 'VPD policies (H-40)', v_count >= 2,
             v_count || ' policies');
   EXCEPTION WHEN OTHERS THEN
      warn('A6-o', 'VPD policies (H-40)', SQLERRM);
   END;

   -- H-02  autonomous transactions, H-06 CONNECT BY, H-24 RESULT_CACHE.
   -- These live in source text rather than in a structural dictionary view.
   SELECT COUNT(DISTINCT name) INTO v_count
     FROM user_source
    WHERE UPPER(text) LIKE '%AUTONOMOUS_TRANSACTION%';
   assert('A6-p', 'PRAGMA AUTONOMOUS_TRANSACTION (H-02)', v_count >= 3,
          v_count || ' program units');

   SELECT COUNT(DISTINCT name) INTO v_count
     FROM user_source
    WHERE UPPER(text) LIKE '%CONNECT BY%';
   assert('A6-q', 'CONNECT BY in PL/SQL (H-06)', v_count >= 3,
          v_count || ' program units');

   SELECT COUNT(DISTINCT name) INTO v_count
     FROM user_source
    WHERE UPPER(text) LIKE '%RESULT\_CACHE%' ESCAPE '\';
   assert('A6-r', 'RESULT_CACHE (H-24)', v_count >= 2,
          v_count || ' program units');

   -- T-07  the deliberately quoted, mixed-case table
   SELECT COUNT(*) INTO v_count
     FROM user_tables WHERE table_name = 'StoreAudit_Legacy';
   assert('A6-s', 'quoted mixed-case table (T-07)', v_count = 1,
          v_count || ' found');

   -- ==================================================================
   -- Verdict
   -- ==================================================================
   p(' ');
   p('===========================================================================');
   p(' verify-schema.sql   ' || v_pass || ' passed, ' || v_fail || ' failed, '
     || v_warn || ' not checked');
   p('===========================================================================');
   p(' ');

   IF v_fail > 0 THEN
      RAISE_APPLICATION_ERROR(
         -20101,
         'verify-schema.sql: ' || v_fail || ' assertion(s) failed. '
         || 'Read the FAIL lines above. The schema does not meet docs/design.md.');
   END IF;

   IF v_warn > 0 THEN
      p('Note: ' || v_warn || ' check(s) could not run. They are not failures,');
      p('but they are not passes either -- see the WARN lines above.');
      p(' ');
   END IF;
END;
/

PROMPT verify-schema.sql: all assertions passed.
PROMPT
