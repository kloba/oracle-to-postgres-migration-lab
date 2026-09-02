--------------------------------------------------------------------------------
-- Contoso Store -- Oracle to Azure Database for PostgreSQL migration lab
-- 00-user-tablespace.sql
--
-- Creates the CONTOSO tablespace, the CONTOSO schema owner, its grants and its
-- quota. Runs as SYSTEM, connected to the FREEPDB1 pluggable database.
--
--   sqlplus -L system/"$ORACLE_PASSWORD"@//localhost:1521/FREEPDB1 \
--           @src/oracle/00-user-tablespace.sql "$CONTOSO_PASSWORD"
--
-- The password is taken from the first positional SQL*Plus argument. It is never
-- written to this file, never echoed, and never logged. See .env.example for the
-- CONTOSO_PASSWORD variable.
--
-- Re-runnable: the drops below are wrapped in PL/SQL blocks that swallow only the
-- specific "does not exist" error and re-raise everything else.
--------------------------------------------------------------------------------

SET SQLBLANKLINES ON
SET DEFINE ON
SET VERIFY OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

DEFINE contoso_password = '&1'

prompt
prompt ================================================================
prompt  00-user-tablespace.sql : CONTOSO tablespace, user, grants, quota
prompt ================================================================

--------------------------------------------------------------------------------
-- Guard: refuse to run in CDB$ROOT. Creating CONTOSO as a common user would
-- require a C## prefix and would break every downstream script.
--------------------------------------------------------------------------------
BEGIN
  IF SYS_CONTEXT('USERENV', 'CON_NAME') = 'CDB$ROOT' THEN
    RAISE_APPLICATION_ERROR(
      -20000,
      'Connect to the FREEPDB1 pluggable database, not CDB$ROOT.');
  END IF;
  DBMS_OUTPUT.PUT_LINE('Container : ' || SYS_CONTEXT('USERENV', 'CON_NAME'));
  DBMS_OUTPUT.PUT_LINE('Connected : ' || SYS_CONTEXT('USERENV', 'SESSION_USER'));
END;
/

--------------------------------------------------------------------------------
-- Disconnect any live CONTOSO session before dropping the user.
--
-- DROP USER ... CASCADE raises ORA-01940 "cannot drop a user who is currently
-- connected" if anything is logged in -- a sqlplus window left open in another
-- terminal, a scheduler job still running from the last build, or the VS Code
-- extension holding a metadata connection. That is the normal state of affairs
-- during a lab, not an edge case, so the rebuild handles it rather than telling
-- the reader to go and find the session.
--
-- Sessions are killed IMMEDIATE and the loop tolerates ORA-00030 / ORA-00031
-- (session marked for kill, or already gone) because a session that died
-- between the query and the kill is exactly the outcome we wanted.
--------------------------------------------------------------------------------
DECLARE
  l_killed PLS_INTEGER := 0;
BEGIN
  FOR s IN (SELECT sid, serial# AS serial_no, inst_id
              FROM gv$session
             WHERE username = 'CONTOSO')
  LOOP
    BEGIN
      EXECUTE IMMEDIATE 'ALTER SYSTEM KILL SESSION '''
                     || s.sid || ',' || s.serial_no || ',@' || s.inst_id
                     || ''' IMMEDIATE';
      l_killed := l_killed + 1;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE NOT IN (-30, -31) THEN
          RAISE;
        END IF;
    END;
  END LOOP;

  IF l_killed > 0 THEN
    DBMS_OUTPUT.PUT_LINE('Disconnected ' || l_killed || ' live CONTOSO session(s).');
    -- PMON needs a moment to release the sessions before DROP USER will pass.
    DBMS_SESSION.SLEEP(3);
  END IF;
END;
/

--------------------------------------------------------------------------------
-- Drop the user first (it holds segments in the tablespace we are about to drop).
-- ORA-01918 = user does not exist.
--------------------------------------------------------------------------------
BEGIN
  EXECUTE IMMEDIATE 'DROP USER contoso CASCADE';
  DBMS_OUTPUT.PUT_LINE('Dropped existing user CONTOSO.');
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -1918 THEN
      DBMS_OUTPUT.PUT_LINE('User CONTOSO did not exist -- nothing to drop.');
    ELSE
      RAISE;
    END IF;
END;
/

--------------------------------------------------------------------------------
-- ORA-00959 = tablespace does not exist.
--------------------------------------------------------------------------------
BEGIN
  EXECUTE IMMEDIATE
    'DROP TABLESPACE contoso_data INCLUDING CONTENTS AND DATAFILES';
  DBMS_OUTPUT.PUT_LINE('Dropped existing tablespace CONTOSO_DATA.');
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -959 THEN
      DBMS_OUTPUT.PUT_LINE('Tablespace CONTOSO_DATA did not exist.');
    ELSE
      RAISE;
    END IF;
END;
/

--------------------------------------------------------------------------------
-- Create the tablespace. The datafile directory is derived from the SYSTEM
-- tablespace so this works both with Oracle Managed Files and without, on any
-- image layout, without hardcoding a path.
--------------------------------------------------------------------------------
DECLARE
  l_dir VARCHAR2(512);
  l_ddl VARCHAR2(2000);
BEGIN
  SELECT SUBSTR(file_name, 1, INSTR(file_name, '/', -1))
    INTO l_dir
    FROM (SELECT file_name
            FROM dba_data_files
           WHERE tablespace_name = 'SYSTEM'
           ORDER BY file_id)
   WHERE ROWNUM = 1;

  l_ddl := 'CREATE TABLESPACE contoso_data'
        || ' DATAFILE ''' || l_dir || 'contoso_data01.dbf'''
        || ' SIZE 256M REUSE AUTOEXTEND ON NEXT 64M MAXSIZE 8G'
        || ' EXTENT MANAGEMENT LOCAL AUTOALLOCATE'
        || ' SEGMENT SPACE MANAGEMENT AUTO';

  EXECUTE IMMEDIATE l_ddl;
  DBMS_OUTPUT.PUT_LINE('Created tablespace CONTOSO_DATA at ' || l_dir);
END;
/

--------------------------------------------------------------------------------
-- The schema owner.
--------------------------------------------------------------------------------
CREATE USER contoso IDENTIFIED BY "&contoso_password"
  DEFAULT TABLESPACE contoso_data
  TEMPORARY TABLESPACE temp
  QUOTA UNLIMITED ON contoso_data
  ACCOUNT UNLOCK;

--------------------------------------------------------------------------------
-- Session and DDL privileges. Granted individually rather than via RESOURCE or
-- DBA so the lab documents exactly what the schema needs -- and so the reader can
-- see that CONTOSO is not a privileged account.
--------------------------------------------------------------------------------
GRANT CREATE SESSION            TO contoso;
GRANT ALTER SESSION             TO contoso;
GRANT CREATE TABLE              TO contoso;
GRANT CREATE VIEW               TO contoso;
GRANT CREATE SEQUENCE           TO contoso;
GRANT CREATE PROCEDURE          TO contoso;
GRANT CREATE TRIGGER            TO contoso;
GRANT CREATE TYPE               TO contoso;
GRANT CREATE SYNONYM            TO contoso;
GRANT CREATE MATERIALIZED VIEW  TO contoso;
GRANT CREATE JOB                TO contoso;

-- Verified against Oracle Free 23ai by executing 11-jobs-scheduler.sql and
-- 13-synonyms-grants.sql: without the three grants below those scripts do not
-- fail outright, they quietly degrade to warnings and the lab loses the
-- evidence for hard cases H-14, H-40 and H-41. Silent degradation is worse than
-- a hard error here, so grant them up front.
--
-- CREATE ROLE            : the read-only reporting role in 13-synonyms-grants.sql
-- MANAGE SCHEDULER       : job classes in 11-jobs-scheduler.sql
-- CREATE EVALUATION      : DBMS_SCHEDULER.DEFINE_CHAIN in 11-jobs-scheduler.sql
--   CONTEXT / RULE /       builds a chain out of rules and an evaluation
--   RULE SET               context; all three privileges are required.
GRANT CREATE ROLE               TO contoso;
GRANT MANAGE SCHEDULER          TO contoso;
GRANT CREATE EVALUATION CONTEXT TO contoso;
GRANT CREATE RULE               TO contoso;
GRANT CREATE RULE SET           TO contoso;

-- CREATE ANY CONTEXT is required for the CONTOSO_APP_CTX application context
-- namespace (design section 6.2, package pkg_security_ctx / hard case H-39).
GRANT CREATE ANY CONTEXT        TO contoso;
GRANT DROP ANY CONTEXT          TO contoso;

-- CREATE ANY DIRECTORY backs the CONTOSO_EXPORT_DIR directory object that
-- pkg_etl_export writes through (hard case H-13).
GRANT CREATE ANY DIRECTORY      TO contoso;
GRANT DROP ANY DIRECTORY        TO contoso;

--------------------------------------------------------------------------------
-- Package execute privileges.
--
-- These SYS packages are already granted to PUBLIC on a stock Oracle Free image,
-- so CONTOSO inherits them and no grant is issued here:
--
--   DBMS_SESSION    application context set/clear from pkg_security_ctx   (H-39)
--   DBMS_SCHEDULER  programs, schedules and jobs                          (H-14)
--   DBMS_SNAPSHOT   materialised view refresh, aliased as DBMS_MVIEW      (H-15)
--   DBMS_REFRESH    the rg_reporting refresh group                        (H-15)
--   DBMS_SQL        the describe-columns path in pkg_data_quality         (H-11)
--   DBMS_UTILITY    FORMAT_ERROR_BACKTRACE in pkg_error                   (H-29)
--   DBMS_LOB        CLOB/BLOB handling in pkg_utils and pkg_etl_export    (H-34)
--   DBMS_OUTPUT     debug output throughout                              (H-12)
--   UTL_FILE        the daily sales extract                              (H-13)
--
-- DBMS_RLS is the exception. It is deliberately NOT granted to PUBLIC, and
-- O7_DICTIONARY_ACCESSIBILITY=FALSE means GRANT ANY OBJECT PRIVILEGE -- which
-- SYSTEM holds through DBA -- does not extend to SYS-owned objects. Only SYS can
-- grant it. A role grant is no help either: roles are disabled inside
-- definer's-rights PL/SQL, and pkg_vpd_policy needs the privilege at run time.
--
-- The block below tries the grant, and if it cannot make it, says exactly what to
-- run and stops the build rather than letting 14-context-and-vpd.sql fail later.
--------------------------------------------------------------------------------
DECLARE
  l_have PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_have
    FROM dba_tab_privs
   WHERE table_name = 'DBMS_RLS'
     AND owner      = 'SYS'
     AND privilege  = 'EXECUTE'
     AND grantee   IN ('CONTOSO', 'PUBLIC');

  IF l_have > 0 THEN
    DBMS_OUTPUT.PUT_LINE('EXECUTE ON SYS.DBMS_RLS already available to CONTOSO.');
    RETURN;
  END IF;

  BEGIN
    EXECUTE IMMEDIATE 'GRANT EXECUTE ON sys.dbms_rls TO contoso';
    DBMS_OUTPUT.PUT_LINE('Granted EXECUTE ON SYS.DBMS_RLS to CONTOSO.');
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE <> -1031 THEN
        RAISE;
      END IF;
      DBMS_OUTPUT.PUT_LINE(RPAD('=', 74, '='));
      DBMS_OUTPUT.PUT_LINE('WARNING - one optional grant could not be made');
      DBMS_OUTPUT.PUT_LINE('');
      DBMS_OUTPUT.PUT_LINE('CONTOSO, its tablespace and its quota are all in place.');
      DBMS_OUTPUT.PUT_LINE('EXECUTE ON SYS.DBMS_RLS can only be granted by SYS, because');
      DBMS_OUTPUT.PUT_LINE('O7_DICTIONARY_ACCESSIBILITY=FALSE stops even DBA reaching SYS');
      DBMS_OUTPUT.PUT_LINE('objects, and a role grant is no help: roles are disabled inside');
      DBMS_OUTPUT.PUT_LINE('definer''s-rights PL/SQL, which is where pkg_vpd_policy needs it.');
      DBMS_OUTPUT.PUT_LINE('');
      DBMS_OUTPUT.PUT_LINE('scripts/seed-oracle.sh makes this grant for you straight after');
      DBMS_OUTPUT.PUT_LINE('this file. If you are running the SQL by hand, do it yourself:');
      DBMS_OUTPUT.PUT_LINE('');
      DBMS_OUTPUT.PUT_LINE('  sqlplus -S -L / as sysdba');
      DBMS_OUTPUT.PUT_LINE('  ALTER SESSION SET CONTAINER = FREEPDB1;');
      DBMS_OUTPUT.PUT_LINE('  GRANT EXECUTE ON sys.dbms_rls TO contoso;');
      DBMS_OUTPUT.PUT_LINE('');
      DBMS_OUTPUT.PUT_LINE('Run it AFTER this file, never before: this script drops and');
      DBMS_OUTPUT.PUT_LINE('recreates CONTOSO, which would discard the grant.');
      DBMS_OUTPUT.PUT_LINE('');
      DBMS_OUTPUT.PUT_LINE('Without it the lab still builds. 12-security-context.sql');
      DBMS_OUTPUT.PUT_LINE('degrades to a warning and you lose the VPD hard case (H-40)');
      DBMS_OUTPUT.PUT_LINE('only. This is deliberately NOT fatal - losing one hard case is');
      DBMS_OUTPUT.PUT_LINE('a far better outcome than refusing to build the schema at all.');
      DBMS_OUTPUT.PUT_LINE(RPAD('=', 74, '='));
  END;
END;
/

--------------------------------------------------------------------------------
-- Verification. Fails the script if anything above did not land.
--------------------------------------------------------------------------------
DECLARE
  l_user_cnt  PLS_INTEGER;
  l_quota     dba_ts_quotas.max_bytes%TYPE;
  l_priv_cnt  PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_user_cnt
    FROM dba_users
   WHERE username = 'CONTOSO' AND account_status = 'OPEN';

  IF l_user_cnt <> 1 THEN
    RAISE_APPLICATION_ERROR(-20001, 'User CONTOSO was not created or is locked.');
  END IF;

  SELECT max_bytes INTO l_quota
    FROM dba_ts_quotas
   WHERE username = 'CONTOSO' AND tablespace_name = 'CONTOSO_DATA';

  IF l_quota <> -1 THEN
    RAISE_APPLICATION_ERROR(-20002, 'CONTOSO does not hold an unlimited quota.');
  END IF;

  SELECT COUNT(*) INTO l_priv_cnt
    FROM dba_sys_privs
   WHERE grantee = 'CONTOSO';

  DBMS_OUTPUT.PUT_LINE('CONTOSO created. System privileges granted: ' || l_priv_cnt);
  DBMS_OUTPUT.PUT_LINE('Quota on CONTOSO_DATA: UNLIMITED');
END;
/

UNDEFINE contoso_password
UNDEFINE 1

prompt
prompt 00-user-tablespace.sql complete: tablespace CONTOSO_DATA, user CONTOSO, grants and quota in place.
prompt
