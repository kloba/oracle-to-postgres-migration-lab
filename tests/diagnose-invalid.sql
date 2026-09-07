-- ---------------------------------------------------------------------------
-- diagnose-invalid.sql - what is invalid in CONTOSO, and why.
--
-- tests/verify-schema.sql asserts that nothing is INVALID and
-- src/oracle/99-verify-objects.sql asserts the same with one deliberate
-- exception. Neither tells you WHICH objects failed or what the compiler said,
-- and that is the question you actually have when the number is not zero.
--
-- Run it as CONTOSO:
--     sqlplus CONTOSO/<pw>@localhost:1521/FREEPDB1 @tests/diagnose-invalid.sql
--
-- WHY A NON-ZERO COUNT IS USUALLY NOT A BROKEN SCHEMA
--
-- Loading ~25 files in dependency order leaves a handful of objects INVALID
-- that are not broken at all: a trigger created with FOLLOWS, or a package body
-- whose dependency was replaced later in the load. Oracle would revalidate them
-- the first time anything touched them. scripts/seed-oracle.sh runs
-- DBMS_UTILITY.COMPILE_SCHEMA before it counts for exactly this reason, so if
-- you loaded the SQL by hand you will see a small non-zero count that the seed
-- script would have cleared. Section 1 below does that recompile for you.
--
-- Section 2 then separates the one INVALID state this schema creates ON PURPOSE
-- -- the dangling synonyms behind hard case H-41 -- from everything else.
-- Whether a dangling synonym reports INVALID is version dependent: on
-- gvenzl/oracle-free:23-slim both of ours report VALID, because Oracle does not
-- mark a synonym until something references it. On another build they may show
-- up here. Two INVALID synonyms are expected; an INVALID package body is not.
--
-- Section 3 prints the compiler errors, which is the part you need.
--
-- DO NOT RUN THE CONVERSION WITH A GENUINELY INVALID OBJECT IN THE SCHEMA.
-- The tool reads an invalid package body as source text and translates it
-- anyway, and the report cannot tell you it did. You get PostgreSQL that looks
-- converted and is wrong in a way nobody notices until runtime.
-- ---------------------------------------------------------------------------
SET PAGESIZE 200
SET LINESIZE 160
SET FEEDBACK OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT
PROMPT ==== 1. recompiling first, so transient invalidity is not counted ====
BEGIN
  DBMS_UTILITY.COMPILE_SCHEMA(USER, compile_all => FALSE);
END;
/

COLUMN object_type FORMAT A22
COLUMN object_name FORMAT A42
COLUMN verdict     FORMAT A34

PROMPT
PROMPT ==== 2. what is still INVALID, and whether it is expected ====
SELECT o.object_type,
       o.object_name,
       CASE
         WHEN o.object_type = 'SYNONYM'
          AND EXISTS (SELECT 1
                        FROM user_synonyms s
                       WHERE s.synonym_name = o.object_name
                         AND NOT EXISTS (SELECT 1
                                           FROM all_objects t
                                          WHERE t.owner       = NVL(s.table_owner, USER)
                                            AND t.object_name = s.table_name))
         THEN 'expected - dangling, hard case H-41'
         ELSE '*** BUILD ERROR - investigate ***'
       END AS verdict
  FROM user_objects o
 WHERE o.status = 'INVALID'
 ORDER BY 3 DESC, 1, 2;

PROMPT
PROMPT ==== 3. what the compiler actually said ====
COLUMN name     FORMAT A32
COLUMN type     FORMAT A16
COLUMN position FORMAT A10
COLUMN text     FORMAT A78 WORD_WRAPPED
SELECT name, type, TO_CHAR(line) || ':' || TO_CHAR(position) AS position, text
  FROM user_errors
 ORDER BY name, sequence;

PROMPT
PROMPT ==== 4. verdict ====
DECLARE
  v_total    PLS_INTEGER;
  v_expected PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_total FROM user_objects WHERE status = 'INVALID';

  SELECT COUNT(*) INTO v_expected
    FROM user_objects o
   WHERE o.status = 'INVALID'
     AND o.object_type = 'SYNONYM'
     AND EXISTS (SELECT 1
                   FROM user_synonyms s
                  WHERE s.synonym_name = o.object_name
                    AND NOT EXISTS (SELECT 1
                                      FROM all_objects t
                                     WHERE t.owner       = NVL(s.table_owner, USER)
                                       AND t.object_name = s.table_name));

  DBMS_OUTPUT.PUT_LINE('invalid objects        : ' || v_total);
  DBMS_OUTPUT.PUT_LINE('expected (H-41 synonyms): ' || v_expected);
  DBMS_OUTPUT.PUT_LINE('unexplained            : ' || (v_total - v_expected));
  DBMS_OUTPUT.PUT_LINE('');

  IF v_total - v_expected = 0 THEN
    DBMS_OUTPUT.PUT_LINE('Safe to convert.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('DO NOT CONVERT YET. Fix the objects listed above first:');
    DBMS_OUTPUT.PUT_LINE('the conversion tool will translate an invalid body as');
    DBMS_OUTPUT.PUT_LINE('source text and the report will not tell you it did.');
  END IF;
END;
/

SET FEEDBACK ON
