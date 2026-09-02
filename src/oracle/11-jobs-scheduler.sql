-- =====================================================================================
-- Contoso Store -- Oracle source schema
-- 11-jobs-scheduler.sql : DBMS_SCHEDULER job classes, schedules, programs, jobs, chain
-- =====================================================================================
-- Owner        : CONTOSO
-- Depends on   : job_run_log, plus the packages and standalone routines the job bodies
--                invoke (referenced by name only -- PLSQL_BLOCK job actions are not
--                validated at create time, so this file survives being run early)
-- Exercises    : H-14 (DBMS_SCHEDULER), H-11 (EXECUTE IMMEDIATE / DDL), H-19 (partition
--                maintenance), H-36 (INTERVAL), H-15 (refresh driving), T-09
--
-- Design contract: docs/design.md section 6.6 -- 6 jobs, 3 programs, 3 schedules.
-- This file adds two further jobs (partition maintenance and a chained month-end job)
-- and three further programs, because a scheduler layer without a chain does not test
-- the hardest part of H-14. The object budget in section 8 has 11% headroom.
--
-- EVERY DBMS_SCHEDULER call here is guarded. CONTOSO needs the CREATE JOB system
-- privilege; job classes additionally need MANAGE SCHEDULER; chains additionally need
-- the rules-engine privileges (CREATE EVALUATION CONTEXT / CREATE RULE / CREATE RULE
-- SET). A lab user who has none of those still gets a clean seed and a clear warning.
-- =====================================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET SQLBLANKLINES ON
SET DEFINE OFF
SET FEEDBACK ON

PROMPT
PROMPT ==========================================================================
PROMPT 11-jobs-scheduler.sql : DBMS_SCHEDULER layer
PROMPT ==========================================================================

VARIABLE g_can_create_job   NUMBER
VARIABLE g_can_manage_sched NUMBER
VARIABLE g_job_class        VARCHAR2(30)

-- -------------------------------------------------------------------------------------
-- 0. Preflight. Decide once what this account is allowed to do.
-- -------------------------------------------------------------------------------------
DECLARE
  l_job   PLS_INTEGER;
  l_mgr   PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_job FROM session_privs WHERE privilege = 'CREATE JOB';
  SELECT COUNT(*) INTO l_mgr FROM session_privs WHERE privilege = 'MANAGE SCHEDULER';

  :g_can_create_job   := l_job;
  :g_can_manage_sched := l_mgr;
  :g_job_class        := 'DEFAULT_JOB_CLASS';

  IF l_job = 0 THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** CONTOSO lacks the CREATE JOB privilege.');
    DBMS_OUTPUT.PUT_LINE('   ***         *** The whole DBMS_SCHEDULER layer will be');
    DBMS_OUTPUT.PUT_LINE('   ***         *** skipped and H-14 will have no evidence.');
    DBMS_OUTPUT.PUT_LINE('   ***         *** Fix: GRANT CREATE JOB TO contoso; as SYSTEM.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('   .. CREATE JOB present');
  END IF;

  IF l_mgr = 0 THEN
    DBMS_OUTPUT.PUT_LINE('   .. MANAGE SCHEDULER absent; job classes will be skipped and');
    DBMS_OUTPUT.PUT_LINE('   .. every job will run under DEFAULT_JOB_CLASS.');
  END IF;
END;
/

-- -------------------------------------------------------------------------------------
-- 0b. Idempotency. Drop anything a previous run left behind.
-- -------------------------------------------------------------------------------------
DECLARE
  TYPE t_names IS TABLE OF VARCHAR2(30);
  l_jobs      t_names := t_names('JOB_MONTH_END_CHAIN',
                                 'JOB_PARTITION_MAINTENANCE',
                                 'JOB_EXPORT_DAILY_SALES',
                                 'JOB_DATA_QUALITY_SCAN',
                                 'JOB_REFRESH_REPORTING',
                                 'JOB_LOYALTY_POINTS_EXPIRY',
                                 'JOB_EXPIRE_PROMOTIONS',
                                 'JOB_NIGHTLY_REPLENISHMENT');
  l_programs  t_names := t_names('PROG_REPLENISHMENT',
                                 'PROG_DQ_SCAN',
                                 'PROG_EXPORT',
                                 'PROG_PARTITION_MAINT',
                                 'PROG_CHAIN_CLOSE_PERIOD',
                                 'PROG_CHAIN_POST_GL');
  l_scheds    t_names := t_names('SCHED_DAILY_0200',
                                 'SCHED_MONTHLY_FIRST',
                                 'SCHED_HOURLY');
BEGIN
  BEGIN
    DBMS_SCHEDULER.DROP_CHAIN(chain_name => 'CHN_MONTH_END', force => TRUE);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  FOR i IN 1 .. l_jobs.COUNT LOOP
    BEGIN
      DBMS_SCHEDULER.DROP_JOB(job_name => l_jobs(i), force => TRUE);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;

  FOR i IN 1 .. l_programs.COUNT LOOP
    BEGIN
      DBMS_SCHEDULER.DROP_PROGRAM(program_name => l_programs(i), force => TRUE);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;

  FOR i IN 1 .. l_scheds.COUNT LOOP
    BEGIN
      DBMS_SCHEDULER.DROP_SCHEDULE(schedule_name => l_scheds(i), force => TRUE);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
END;
/

-- =====================================================================================
-- 1. JOB CLASSES
-- =====================================================================================
-- Job classes bind a group of jobs to a resource consumer group, a service, and a log
-- retention policy. They are created in SYS, hence MANAGE SCHEDULER.
--
-- MIGRATION NOTE (H-14): pg_cron has no concept of a job class. There is no resource
-- consumer group, no per-class logging level, no log_history retention. Everything a
-- job class expressed -- "batch work is capped at this much CPU and its history is kept
-- for 30 days" -- has to move into either PostgreSQL resource controls that do not exist
-- at this granularity, or into the external scheduler you chose instead of pg_cron.
-- Expect this to be dropped silently by any converter and to reappear as an operations
-- gap six months later.
-- -------------------------------------------------------------------------------------
DECLARE
  PROCEDURE make_class(p_name VARCHAR2, p_history PLS_INTEGER, p_comment VARCHAR2) IS
  BEGIN
    BEGIN
      DBMS_SCHEDULER.DROP_JOB_CLASS(job_class_name => p_name, force => TRUE);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    DBMS_SCHEDULER.CREATE_JOB_CLASS(job_class_name  => p_name,
                                    logging_level   => DBMS_SCHEDULER.LOGGING_RUNS,
                                    log_history     => p_history,
                                    comments        => p_comment);
    DBMS_OUTPUT.PUT_LINE('   .. job class ' || p_name || ' created');
  END make_class;
BEGIN
  IF NVL(:g_can_manage_sched, 0) = 0 THEN
    DBMS_OUTPUT.PUT_LINE('   .. job classes skipped (no MANAGE SCHEDULER)');
    RETURN;
  END IF;

  make_class('JC_CONTOSO_BATCH', 30,
             'Contoso overnight batch: replenishment, GL, exports');
  make_class('JC_CONTOSO_REPORTING', 7,
             'Contoso reporting refresh: materialised views and data quality');

  :g_job_class := 'JC_CONTOSO_BATCH';
EXCEPTION
  WHEN OTHERS THEN
    :g_job_class := 'DEFAULT_JOB_CLASS';
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** job classes not created: '
                         || SUBSTR(SQLERRM, 1, 150));
    DBMS_OUTPUT.PUT_LINE('   ***         *** falling back to DEFAULT_JOB_CLASS');
END;
/

-- =====================================================================================
-- 2. SCHEDULES  (3, per docs/design.md section 6.6)
-- =====================================================================================
-- MIGRATION NOTE (H-14): Oracle calendaring syntax and cron are not interchangeable.
--   FREQ=DAILY;BYHOUR=2;BYMINUTE=0;BYSECOND=0        ->  0 2 * * *
--   FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=3               ->  0 3 1 * *
--   FREQ=HOURLY;INTERVAL=1;BYMINUTE=0                ->  0 * * * *
-- The mechanical cases map. The ones that do not: BYSETPOS (Oracle's "last working day
-- of the month"), INCLUDE/EXCLUDE of a named schedule, and the fact that an Oracle
-- schedule is a *first-class object* several jobs share. In cron the expression is
-- copied into every job, so changing "the overnight window" stops being one edit.
-- Also note start_date carries a time zone; a cron entry has only the server's.
-- -------------------------------------------------------------------------------------
BEGIN
  IF NVL(:g_can_create_job, 0) = 0 THEN
    DBMS_OUTPUT.PUT_LINE('   .. schedules skipped (no CREATE JOB)');
    RETURN;
  END IF;

  DBMS_SCHEDULER.CREATE_SCHEDULE(
    schedule_name   => 'SCHED_DAILY_0200',
    start_date      => TRUNC(SYSTIMESTAMP) + INTERVAL '2' HOUR,
    repeat_interval => 'FREQ=DAILY;BYHOUR=2;BYMINUTE=0;BYSECOND=0',
    comments        => 'Contoso overnight batch window, 02:00 database time');

  DBMS_SCHEDULER.CREATE_SCHEDULE(
    schedule_name   => 'SCHED_MONTHLY_FIRST',
    start_date      => TRUNC(SYSTIMESTAMP) + INTERVAL '3' HOUR,
    repeat_interval => 'FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=3;BYMINUTE=0;BYSECOND=0',
    comments        => 'First of the month, 03:00 -- period roll and loyalty expiry');

  DBMS_SCHEDULER.CREATE_SCHEDULE(
    schedule_name   => 'SCHED_HOURLY',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=HOURLY;INTERVAL=1;BYMINUTE=0;BYSECOND=0',
    comments        => 'Top of every hour -- reporting layer refresh');

  DBMS_OUTPUT.PUT_LINE('   .. 3 schedules created');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** schedules not created: '
                         || SUBSTR(SQLERRM, 1, 200));
END;
/
-- =====================================================================================
-- 3. PROGRAMS
-- =====================================================================================
-- MIGRATION NOTE (H-14): a DBMS_SCHEDULER program is a catalogued object carrying typed,
-- positional, defaulted arguments that several jobs share and override individually.
-- pg_cron stores a command string. There is no argument metadata, no default value, no
-- type checking, and no way to ask "which jobs use this program". Converting these means
-- either inlining the argument values into every cron command -- losing the shared
-- definition -- or promoting each program to a real PL/pgSQL procedure with parameters
-- and letting cron call it. The second is right, and it is a design decision the tool
-- cannot make.
--
-- ORACLE RESTRICTION, verified on 23ai and worth knowing before you plan the conversion:
-- a program of type PLSQL_BLOCK cannot have arguments at all. CREATE_PROGRAM accepts
-- number_of_arguments > 0 and then DEFINE_PROGRAM_ARGUMENT fails with
--     ORA-27458: A program of type PLSQL_BLOCK cannot have any arguments.
-- Only STORED_PROCEDURE (and EXECUTABLE) programs carry argument metadata. So the two
-- shapes below are not a stylistic choice:
--   * PLSQL_BLOCK programs take zero arguments and read their configuration from the
--     app_parameter table at run time -- the standard workaround, and a realistic one:
--     legacy schemas are full of it. It also moves the "argument" out of the scheduler
--     catalogue and into ordinary data, which is where a pg_cron conversion would have
--     had to put it anyway.
--   * PROG_EXPORT is built as a STORED_PROCEDURE program so the lab has genuine argument
--     metadata for the converter to deal with. Its argument list is read from
--     USER_ARGUMENTS rather than hardcoded, so this file does not have to guess the
--     signature that 12-procedures-functions.sql gives sp_export_daily_sales.
-- -------------------------------------------------------------------------------------
DECLARE
  l_ok   PLS_INTEGER := 0;
  l_args PLS_INTEGER := 0;

  PROCEDURE make_block(p_name VARCHAR2, p_action VARCHAR2, p_comment VARCHAR2) IS
  BEGIN
    DBMS_SCHEDULER.CREATE_PROGRAM(program_name        => p_name,
                                  program_type        => 'PLSQL_BLOCK',
                                  program_action      => p_action,
                                  number_of_arguments => 0,
                                  enabled             => TRUE,
                                  comments            => p_comment);
    l_ok := l_ok + 1;
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('   .. program ' || p_name || ' failed: '
                           || SUBSTR(SQLERRM, 1, 120));
  END make_block;
BEGIN
  IF NVL(:g_can_create_job, 0) = 0 THEN
    DBMS_OUTPUT.PUT_LINE('   .. programs skipped (no CREATE JOB)');
    RETURN;
  END IF;

  ------------------------------------------------------------------ prog_replenishment
  make_block(
    'PROG_REPLENISHMENT',
    q'[
DECLARE
  l_lookback  NUMBER       := 28;
  l_region    VARCHAR2(20) := 'ALL';
  l_raw       VARCHAR2(500);
  l_run_id    NUMBER;
  l_rows      NUMBER := 0;
BEGIN
  -- Configuration that a DBMS_SCHEDULER program argument would have carried. See the
  -- ORACLE RESTRICTION note above for why it lives in a table instead.
  BEGIN
    SELECT param_value INTO l_raw
      FROM app_parameter WHERE param_name = 'REPLEN_LOOKBACK_DAYS';
    l_lookback := TO_NUMBER(l_raw);
  EXCEPTION WHEN OTHERS THEN l_lookback := 42;
  END;

  BEGIN
    SELECT NVL(MAX(run_id),0) + 1 INTO l_run_id FROM job_run_log;
    INSERT INTO job_run_log (run_id, job_name, started_ts, status)
    VALUES (l_run_id, 'JOB_NIGHTLY_REPLENISHMENT', SYSTIMESTAMP, 'RUNNING');
    COMMIT;
  EXCEPTION WHEN OTHERS THEN l_run_id := NULL;
  END;

  pkg_replenishment.run(p_lookback_days => l_lookback, p_region_code => l_region);
  l_rows := SQL%ROWCOUNT;

  BEGIN
    UPDATE job_run_log
       SET finished_ts    = SYSTIMESTAMP
         , elapsed        = SYSTIMESTAMP - started_ts
         , status         = 'SUCCESS'
         , rows_processed = l_rows
     WHERE run_id = l_run_id;
    COMMIT;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      UPDATE job_run_log
         SET finished_ts = SYSTIMESTAMP
           , status      = 'FAILED'
           , message     = SUBSTR(SQLERRM || ' :: '
                            || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000)
       WHERE run_id = l_run_id;
      COMMIT;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
END;]',
    'Nightly reorder proposal from demand history and reorder points');

  ----------------------------------------------------------------------- prog_dq_scan
  make_block(
    'PROG_DQ_SCAN',
    q'[
DECLARE
  l_floor VARCHAR2(10) := 'WARN';
BEGIN
  BEGIN
    SELECT param_value INTO l_floor
      FROM app_parameter WHERE param_name = 'DQ_SEVERITY_FLOOR';
  EXCEPTION WHEN OTHERS THEN l_floor := 'WARN';
  END;

  pkg_data_quality.run_all_rules(p_severity_floor => l_floor);
EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      pkg_error.log_error(p_module => 'SCHEDULER', p_routine => 'PROG_DQ_SCAN');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
END;]',
    'Runs the stored data-quality rule set and records failures');

  --------------------------------------------------------------- prog_partition_maint
  -- MIGRATION NOTE (H-19 / H-11): partition maintenance written as dynamic DDL inside a
  -- scheduled PL/SQL block. Three separate conversion problems in twenty lines:
  --   1. EXECUTE IMMEDIATE of concatenated DDL -> PL/pgSQL EXECUTE format(%I), or you
  --      inherit an injection hole (H-11).
  --   2. Oracle INTERVAL partitioning materialises partitions on first insert, so the
  --      ADD PARTITION arm is dead code on an interval table and Oracle says so with
  --      ORA-14760. PostgreSQL has no interval partitioning: pg_partman must be
  --      allowlisted, put in shared_preload_libraries, and the server restarted, and
  --      then this job is replaced wholesale by partman's background worker.
  --   3. The ORA- number bound by PRAGMA EXCEPTION_INIT has no PostgreSQL equivalent
  --      (H-28/H-29); there is no condition name for "table is interval partitioned".
  make_block(
    'PROG_PARTITION_MAINT',
    q'[
DECLARE
  l_table   VARCHAR2(30)  := 'INVENTORY_MOVEMENT';
  l_ahead   NUMBER        := 1;
  l_bound   DATE;
  l_pname   VARCHAR2(30);
  l_sql     VARCHAR2(1000);
  l_run_id  NUMBER;
  l_status  VARCHAR2(15)  := 'SUCCESS';
  l_msg     VARCHAR2(4000);
  e_interval_table EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_interval_table, -14760);
BEGIN
  BEGIN
    SELECT param_value INTO l_table
      FROM app_parameter WHERE param_name = 'PARTITION_MAINT_TABLE';
  EXCEPTION WHEN OTHERS THEN l_table := 'INVENTORY_MOVEMENT';
  END;

  l_bound := ADD_MONTHS(TRUNC(SYSDATE, 'MM'), l_ahead + 1);
  l_pname := 'P_' || TO_CHAR(ADD_MONTHS(TRUNC(SYSDATE, 'MM'), l_ahead), 'YYYYMM');

  BEGIN
    SELECT NVL(MAX(run_id),0) + 1 INTO l_run_id FROM job_run_log;
    INSERT INTO job_run_log (run_id, job_name, started_ts, status)
    VALUES (l_run_id, 'JOB_PARTITION_MAINTENANCE', SYSTIMESTAMP, 'RUNNING');
    COMMIT;
  EXCEPTION WHEN OTHERS THEN l_run_id := NULL;
  END;

  l_sql := 'ALTER TABLE ' || DBMS_ASSERT.SIMPLE_SQL_NAME(l_table)
        || ' ADD PARTITION ' || DBMS_ASSERT.SIMPLE_SQL_NAME(l_pname)
        || ' VALUES LESS THAN (TIMESTAMP '''
        || TO_CHAR(l_bound, 'YYYY-MM-DD') || ' 00:00:00'')';

  BEGIN
    EXECUTE IMMEDIATE l_sql;
    l_msg := 'added partition ' || l_pname || ' to ' || l_table;
  EXCEPTION
    WHEN e_interval_table THEN
      l_status := 'SKIPPED';
      l_msg    := l_table || ' is INTERVAL partitioned; Oracle materialises '
               || l_pname || ' on first insert. Nothing to pre-create.';
    WHEN OTHERS THEN
      IF SQLCODE = -14074 THEN
        l_status := 'SKIPPED';
        l_msg    := l_pname || ' already exists or the bound is below the high partition';
      ELSE
        RAISE;
      END IF;
  END;

  BEGIN
    DBMS_STATS.GATHER_TABLE_STATS(ownname => USER, tabname => l_table,
                                  granularity => 'PARTITION', degree => 2,
                                  cascade => TRUE);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    UPDATE job_run_log
       SET finished_ts = SYSTIMESTAMP
         , elapsed     = SYSTIMESTAMP - started_ts
         , status      = l_status
         , message     = l_msg
     WHERE run_id = l_run_id;
    COMMIT;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      UPDATE job_run_log
         SET finished_ts = SYSTIMESTAMP, status = 'FAILED'
           , message     = SUBSTR(SQLERRM, 1, 4000)
       WHERE run_id = l_run_id;
      COMMIT;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
END;]',
    'Pre-creates next month partition and regathers partition statistics');

  ---------------------------------------------------------- prog_chain_close_period
  make_block(
    'PROG_CHAIN_CLOSE_PERIOD',
    q'[
BEGIN
  sp_close_gl_period(p_fiscal_year => EXTRACT(YEAR FROM SYSDATE));
END;]',
    'Chain step 1: close the current general ledger period');

  -------------------------------------------------------------- prog_chain_post_gl
  make_block(
    'PROG_CHAIN_POST_GL',
    q'[
BEGIN
  pkg_finance_gl.post_pending(p_source_module => 'SALES');
END;]',
    'Chain step 2: post pending journals for the SALES source module');

  ------------------------------------------------------------------------ prog_export
  -- MIGRATION NOTE (H-13): this program writes a flat file through UTL_FILE to the
  -- Oracle directory CONTOSO_EXPORT_DIR. Azure Database for PostgreSQL flexible server
  -- has no server filesystem you can write to and no utl_file_dir equivalent. orafce
  -- ships a utl_file shim, so a converter can emit calls that *compile* and then fail
  -- at run time -- the worst outcome available. The real answers are a client-side
  -- COPY ... TO STDOUT or an external job pushing to Blob Storage.
  --
  -- Built as STORED_PROCEDURE so the lab has one program with real argument metadata.
  -- The arguments are mirrored from USER_ARGUMENTS instead of being hardcoded, so this
  -- file never has to guess sp_export_daily_sales's signature.
  DECLARE
    l_exists PLS_INTEGER := 0;
  BEGIN
    SELECT COUNT(*) INTO l_exists
      FROM user_objects
     WHERE object_name = 'SP_EXPORT_DAILY_SALES'
       AND object_type = 'PROCEDURE'
       AND status      = 'VALID';

    IF l_exists = 0 THEN
      DBMS_OUTPUT.PUT_LINE('   .. sp_export_daily_sales not present; PROG_EXPORT '
                           || 'falls back to PLSQL_BLOCK with no arguments');
      make_block(
        'PROG_EXPORT',
        q'[
BEGIN
  sp_export_daily_sales(p_business_date => TRUNC(SYSDATE) - 1,
                        p_directory     => 'CONTOSO_EXPORT_DIR');
EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      pkg_error.log_error(p_module => 'SCHEDULER', p_routine => 'PROG_EXPORT');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
END;]',
        'Daily sales flat-file extract via UTL_FILE (see H-13)');
    ELSE
      SELECT COUNT(*) INTO l_args
        FROM user_arguments
       WHERE object_name = 'SP_EXPORT_DAILY_SALES'
         AND package_name IS NULL
         AND argument_name IS NOT NULL;

      DBMS_SCHEDULER.CREATE_PROGRAM(
        program_name        => 'PROG_EXPORT',
        program_type        => 'STORED_PROCEDURE',
        program_action      => 'SP_EXPORT_DAILY_SALES',
        number_of_arguments => l_args,
        enabled             => FALSE,
        comments            => 'Daily sales flat-file extract via UTL_FILE (see H-13)');

      FOR a IN (SELECT argument_name, data_type, position
                  FROM user_arguments
                 WHERE object_name = 'SP_EXPORT_DAILY_SALES'
                   AND package_name IS NULL
                   AND argument_name IS NOT NULL
                 ORDER BY position)
      LOOP
        DBMS_SCHEDULER.DEFINE_PROGRAM_ARGUMENT(
          program_name      => 'PROG_EXPORT',
          argument_position => a.position,
          argument_name     => a.argument_name,
          argument_type     => a.data_type,
          default_value     => NULL,
          out_argument      => FALSE);
      END LOOP;

      DBMS_SCHEDULER.ENABLE('PROG_EXPORT');
      l_ok := l_ok + 1;
      DBMS_OUTPUT.PUT_LINE('   .. PROG_EXPORT created as STORED_PROCEDURE with '
                           || l_args || ' declared argument(s)');
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('   .. PROG_EXPORT failed: ' || SUBSTR(SQLERRM, 1, 140));
  END;

  DBMS_OUTPUT.PUT_LINE('   .. ' || l_ok || ' scheduler programs created and enabled');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** programs partially created (' || l_ok
                         || ' ok): ' || SUBSTR(SQLERRM, 1, 200));
END;
/

-- =====================================================================================
-- 4. JOBS
-- =====================================================================================
-- MIGRATION NOTE (H-14): one-to-one job mapping onto pg_cron is the easy part. What does
-- not survive: restartable, max_failures, max_run_duration, raise_events, the job/program
-- split, argument overrides per job, and the fact that a failing Oracle job disables
-- itself after max_failures. pg_cron reruns forever and records the failure in
-- cron.job_run_details, which nobody is watching. Failure handling is a manual rebuild.
-- -------------------------------------------------------------------------------------
DECLARE
  l_ok PLS_INTEGER := 0;

  PROCEDURE safe(p_label VARCHAR2) IS
  BEGIN
    l_ok := l_ok + 1;
    DBMS_OUTPUT.PUT_LINE('   .. job ' || p_label || ' created');
  END safe;
BEGIN
  IF NVL(:g_can_create_job, 0) = 0 THEN
    DBMS_OUTPUT.PUT_LINE('   .. jobs skipped (no CREATE JOB)');
    RETURN;
  END IF;

  ------------------------------------------------- 1. hourly reporting/mview refresh
  -- Drives the refresh group built in 10-mviews.sql. Design section 6.6 puts this on
  -- SCHED_HOURLY; the nightly full pass is the same body on SCHED_DAILY_0200.
  BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
      job_name      => 'JOB_REFRESH_REPORTING',
      job_type      => 'PLSQL_BLOCK',
      job_action    => q'[
DECLARE
  l_run_id NUMBER;
BEGIN
  BEGIN
    SELECT NVL(MAX(run_id),0) + 1 INTO l_run_id FROM job_run_log;
    INSERT INTO job_run_log (run_id, job_name, started_ts, status)
    VALUES (l_run_id, 'JOB_REFRESH_REPORTING', SYSTIMESTAMP, 'RUNNING');
    COMMIT;
  EXCEPTION WHEN OTHERS THEN l_run_id := NULL;
  END;

  BEGIN
    pkg_mv_refresh.refresh_group(p_group_name => 'RG_REPORTING');
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_REFRESH.REFRESH(USER || '.RG_REPORTING');
  END;

  BEGIN
    DBMS_MVIEW.REFRESH(list => 'MV_SUPPLIER_PERFORMANCE,MV_PROMOTION_UPLIFT',
                       method => 'CC', atomic_refresh => TRUE);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    UPDATE job_run_log
       SET finished_ts = SYSTIMESTAMP
         , elapsed     = SYSTIMESTAMP - started_ts
         , status      = 'SUCCESS'
     WHERE run_id = l_run_id;
    COMMIT;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      UPDATE job_run_log
         SET finished_ts = SYSTIMESTAMP, status = 'FAILED'
           , message     = SUBSTR(SQLERRM, 1, 4000)
       WHERE run_id = l_run_id;
      COMMIT;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
END;]',
      schedule_name => 'SCHED_HOURLY',
      job_class     => NVL(:g_job_class, 'DEFAULT_JOB_CLASS'),
      enabled       => TRUE,
      auto_drop     => FALSE,
      comments      => 'Refreshes refresh group RG_REPORTING and the two standalone MVs');
    safe('JOB_REFRESH_REPORTING');
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   .. JOB_REFRESH_REPORTING failed: ' || SUBSTR(SQLERRM,1,150));
  END;

  ---------------------------------------------------- 2. nightly inventory reorder run
  BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
      job_name      => 'JOB_NIGHTLY_REPLENISHMENT',
      program_name  => 'PROG_REPLENISHMENT',
      schedule_name => 'SCHED_DAILY_0200',
      job_class     => NVL(:g_job_class, 'DEFAULT_JOB_CLASS'),
      enabled       => TRUE,
      auto_drop     => FALSE,
      comments      => 'Nightly reorder proposal (pkg_replenishment.run)');
    safe('JOB_NIGHTLY_REPLENISHMENT');
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   .. JOB_NIGHTLY_REPLENISHMENT failed: '
                         || SUBSTR(SQLERRM,1,150));
  END;

  --------------------------------------------------------- 3. loyalty points expiry
  BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
      job_name      => 'JOB_LOYALTY_POINTS_EXPIRY',
      job_type      => 'PLSQL_BLOCK',
      job_action    => q'[
DECLARE
  l_run_id  NUMBER;
  l_expired NUMBER := 0;
BEGIN
  BEGIN
    SELECT NVL(MAX(run_id),0) + 1 INTO l_run_id FROM job_run_log;
    INSERT INTO job_run_log (run_id, job_name, started_ts, status)
    VALUES (l_run_id, 'JOB_LOYALTY_POINTS_EXPIRY', SYSTIMESTAMP, 'RUNNING');
    COMMIT;
  EXCEPTION WHEN OTHERS THEN l_run_id := NULL;
  END;

  l_expired := pkg_loyalty.expire_points(p_as_of => TRUNC(SYSDATE));

  BEGIN
    UPDATE job_run_log
       SET finished_ts    = SYSTIMESTAMP
         , elapsed        = SYSTIMESTAMP - started_ts
         , status         = 'SUCCESS'
         , rows_processed = l_expired
     WHERE run_id = l_run_id;
    COMMIT;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      UPDATE job_run_log
         SET finished_ts = SYSTIMESTAMP, status = 'FAILED'
           , message     = SUBSTR(SQLERRM, 1, 4000)
       WHERE run_id = l_run_id;
      COMMIT;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
END;]',
      schedule_name => 'SCHED_MONTHLY_FIRST',
      job_class     => NVL(:g_job_class, 'DEFAULT_JOB_CLASS'),
      enabled       => TRUE,
      auto_drop     => FALSE,
      comments      => 'Expires unredeemed loyalty points past loyalty_transaction.expires_on');
    safe('JOB_LOYALTY_POINTS_EXPIRY');
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   .. JOB_LOYALTY_POINTS_EXPIRY failed: '
                         || SUBSTR(SQLERRM,1,150));
  END;

  ----------------------------------------------------------- 4. expire promotions
  BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
      job_name      => 'JOB_EXPIRE_PROMOTIONS',
      job_type      => 'PLSQL_BLOCK',
      job_action    => 'BEGIN sp_expire_promotions; END;',
      schedule_name => 'SCHED_DAILY_0200',
      job_class     => NVL(:g_job_class, 'DEFAULT_JOB_CLASS'),
      enabled       => TRUE,
      auto_drop     => FALSE,
      comments      => 'Moves promotions past end_ts to status EXPIRED');
    safe('JOB_EXPIRE_PROMOTIONS');
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   .. JOB_EXPIRE_PROMOTIONS failed: ' || SUBSTR(SQLERRM,1,150));
  END;

  ----------------------------------------------------------- 5. data quality scan
  BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
      job_name      => 'JOB_DATA_QUALITY_SCAN',
      program_name  => 'PROG_DQ_SCAN',
      schedule_name => 'SCHED_DAILY_0200',
      job_class     => NVL(:g_job_class, 'DEFAULT_JOB_CLASS'),
      enabled       => TRUE,
      auto_drop     => FALSE,
      comments      => 'Runs the stored data-quality rule set (pkg_data_quality)');
    safe('JOB_DATA_QUALITY_SCAN');
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   .. JOB_DATA_QUALITY_SCAN failed: ' || SUBSTR(SQLERRM,1,150));
  END;

  -------------------------------------------------------- 6. daily sales extract
  BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
      job_name      => 'JOB_EXPORT_DAILY_SALES',
      program_name  => 'PROG_EXPORT',
      schedule_name => 'SCHED_DAILY_0200',
      job_class     => NVL(:g_job_class, 'DEFAULT_JOB_CLASS'),
      enabled       => FALSE,
      auto_drop     => FALSE,
      comments      => 'UTL_FILE extract of yesterday sales (H-13)');
    -- Only PROG_EXPORT carries argument metadata, and only when
    -- sp_export_daily_sales was present when section 3 ran. Setting a job argument
    -- against a program without arguments raises ORA-27484, so this is guarded
    -- separately: a missing override must not stop the job being enabled.
    BEGIN
      DBMS_SCHEDULER.SET_JOB_ARGUMENT_VALUE(
        job_name => 'JOB_EXPORT_DAILY_SALES',
        argument_name => 'P_DIRECTORY', argument_value => 'CONTOSO_EXPORT_DIR');
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('   .. P_DIRECTORY override skipped: '
                             || SUBSTR(SQLERRM, 1, 90));
    END;
    DBMS_SCHEDULER.ENABLE('JOB_EXPORT_DAILY_SALES');
    safe('JOB_EXPORT_DAILY_SALES');
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   .. JOB_EXPORT_DAILY_SALES failed: ' || SUBSTR(SQLERRM,1,150));
  END;

  ----------------------------------------------------- 7. partition maintenance
  -- Inline repeat_interval rather than a named schedule, on purpose: the converter has
  -- to handle both forms, and the 25th-of-the-month pre-create is the realistic pattern.
  BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
      job_name        => 'JOB_PARTITION_MAINTENANCE',
      program_name    => 'PROG_PARTITION_MAINT',
      start_date      => TRUNC(SYSTIMESTAMP) + INTERVAL '23' HOUR,
      repeat_interval => 'FREQ=MONTHLY;BYMONTHDAY=25;BYHOUR=23;BYMINUTE=30;BYSECOND=0',
      end_date        => NULL,
      job_class       => NVL(:g_job_class, 'DEFAULT_JOB_CLASS'),
      enabled         => TRUE,
      auto_drop       => FALSE,
      comments        => 'Pre-creates next month partition; regathers partition stats');
    safe('JOB_PARTITION_MAINTENANCE');
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   .. JOB_PARTITION_MAINTENANCE failed: '
                         || SUBSTR(SQLERRM,1,150));
  END;

  DBMS_OUTPUT.PUT_LINE('   .. ' || l_ok || ' jobs created');
END;
/

-- -------------------------------------------------------------------------------------
-- 4b. Per-job attributes. Each of these is a capability pg_cron does not have.
-- -------------------------------------------------------------------------------------
DECLARE
  TYPE t_names IS TABLE OF VARCHAR2(30);
  l_jobs t_names := t_names('JOB_NIGHTLY_REPLENISHMENT',
                            'JOB_DATA_QUALITY_SCAN',
                            'JOB_EXPORT_DAILY_SALES',
                            'JOB_PARTITION_MAINTENANCE');
BEGIN
  IF NVL(:g_can_create_job, 0) = 0 THEN
    RETURN;
  END IF;

  FOR i IN 1 .. l_jobs.COUNT LOOP
    BEGIN
      -- MIGRATION NOTE (H-36): max_run_duration is an INTERVAL DAY TO SECOND. Oracle's
      -- two interval families collapse into PostgreSQL's single `interval`, which makes
      -- expressions that Oracle rejected suddenly legal. Nothing checks them for you.
      DBMS_SCHEDULER.SET_ATTRIBUTE(l_jobs(i), 'max_run_duration',
                                   INTERVAL '2' HOUR);
      DBMS_SCHEDULER.SET_ATTRIBUTE(l_jobs(i), 'max_failures', 3);
      DBMS_SCHEDULER.SET_ATTRIBUTE(l_jobs(i), 'restartable', TRUE);
      -- raise_events is a bitmask capped at DBMS_SCHEDULER.JOB_ALL_EVENTS, which is 511.
      -- JOB_OVER_MAX_DUR is 512 and therefore *outside* the range this attribute accepts:
      -- SET_ATTRIBUTE rejects 4 + 512 with ORA-27465 "invalid value 516". A worked
      -- example of Oracle constants that look composable and are not.
      DBMS_SCHEDULER.SET_ATTRIBUTE(l_jobs(i), 'raise_events',
                                   DBMS_SCHEDULER.JOB_FAILED
                                   + DBMS_SCHEDULER.JOB_BROKEN);
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('   .. attributes skipped for ' || l_jobs(i) || ': '
                             || SUBSTR(SQLERRM, 1, 100));
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('   .. job attributes applied '
                       || '(max_run_duration, max_failures, restartable, raise_events)');
END;
/

-- =====================================================================================
-- 5. JOB CHAIN chn_month_end  (CREATE_CHAIN / DEFINE_CHAIN_STEP / DEFINE_CHAIN_RULE)
-- =====================================================================================
-- Month end: close the GL period, then post pending journals, then export. Each step
-- only starts if the previous one succeeded.
--
-- MIGRATION NOTE (H-14): chains are the single largest gap in the scheduler layer.
-- A chain is a rules-engine program -- steps, boolean start conditions over step state,
-- explicit END rules with a return code, and the ability to pause/skip a step at run
-- time. pg_cron has no dependency model whatsoever: every entry is an independent
-- timer. Reproducing this needs either an orchestrator outside the database (Azure Data
-- Factory, Logic Apps, Airflow) or a hand-written state table with a driver job that
-- polls it. Neither is a "conversion"; both are new systems that need their own
-- monitoring. Budget for it explicitly rather than discovering it during cutover.
--
-- Note also that chains create rules-engine objects (EVALUATION CONTEXT, RULE, RULE SET)
-- which appear in user_objects and therefore move the object count in section 8.
-- -------------------------------------------------------------------------------------
DECLARE
  l_have_rules PLS_INTEGER := 0;
BEGIN
  IF NVL(:g_can_create_job, 0) = 0 THEN
    DBMS_OUTPUT.PUT_LINE('   .. chain skipped (no CREATE JOB)');
    RETURN;
  END IF;

  SELECT COUNT(*) INTO l_have_rules
    FROM session_privs
   WHERE privilege IN ('CREATE EVALUATION CONTEXT', 'CREATE RULE', 'CREATE RULE SET');

  IF l_have_rules < 3 THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** chain chn_month_end skipped.');
    DBMS_OUTPUT.PUT_LINE('   ***         *** DBMS_SCHEDULER chains need all three of');
    DBMS_OUTPUT.PUT_LINE('   ***         *** CREATE EVALUATION CONTEXT, CREATE RULE and');
    DBMS_OUTPUT.PUT_LINE('   ***         *** CREATE RULE SET. Found ' || l_have_rules
                         || ' of 3.');
    DBMS_OUTPUT.PUT_LINE('   ***         *** Grant them from SYSTEM to exercise H-14 fully.');
    RETURN;
  END IF;

  DBMS_SCHEDULER.CREATE_CHAIN(
    chain_name          => 'CHN_MONTH_END',
    rule_set_name       => NULL,
    evaluation_interval => NULL,
    comments            => 'Contoso month end: close period -> post GL -> export');

  DBMS_SCHEDULER.DEFINE_CHAIN_STEP('CHN_MONTH_END', 'S_CLOSE_PERIOD',
                                   'PROG_CHAIN_CLOSE_PERIOD');
  DBMS_SCHEDULER.DEFINE_CHAIN_STEP('CHN_MONTH_END', 'S_POST_GL',
                                   'PROG_CHAIN_POST_GL');
  DBMS_SCHEDULER.DEFINE_CHAIN_STEP('CHN_MONTH_END', 'S_EXPORT',
                                   'PROG_EXPORT');

  DBMS_SCHEDULER.DEFINE_CHAIN_RULE('CHN_MONTH_END',
    condition => 'TRUE',
    action    => 'START S_CLOSE_PERIOD',
    rule_name => 'R_START',
    comments  => 'Entry point');

  DBMS_SCHEDULER.DEFINE_CHAIN_RULE('CHN_MONTH_END',
    condition => 'S_CLOSE_PERIOD SUCCEEDED',
    action    => 'START S_POST_GL',
    rule_name => 'R_POST_GL',
    comments  => 'Only post journals into a period that actually closed');

  DBMS_SCHEDULER.DEFINE_CHAIN_RULE('CHN_MONTH_END',
    condition => 'S_POST_GL SUCCEEDED',
    action    => 'START S_EXPORT',
    rule_name => 'R_EXPORT',
    comments  => 'Extract only reflects posted journals');

  DBMS_SCHEDULER.DEFINE_CHAIN_RULE('CHN_MONTH_END',
    condition => 'S_EXPORT COMPLETED',
    action    => 'END 0',
    rule_name => 'R_END_OK',
    comments  => 'Normal termination');

  DBMS_SCHEDULER.DEFINE_CHAIN_RULE('CHN_MONTH_END',
    condition => 'S_CLOSE_PERIOD FAILED OR S_POST_GL FAILED',
    action    => 'END 1',
    rule_name => 'R_END_FAIL',
    comments  => 'Abort the chain and leave a non-zero completion code');

  DBMS_SCHEDULER.ENABLE('CHN_MONTH_END');
  DBMS_OUTPUT.PUT_LINE('   .. chain CHN_MONTH_END created: 3 steps, 5 rules');

  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_MONTH_END_CHAIN',
    job_type        => 'CHAIN',
    job_action      => 'CHN_MONTH_END',
    start_date      => TRUNC(SYSTIMESTAMP) + INTERVAL '4' HOUR,
    repeat_interval => 'FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=4;BYMINUTE=0;BYSECOND=0',
    end_date        => NULL,
    job_class       => NVL(:g_job_class, 'DEFAULT_JOB_CLASS'),
    enabled         => TRUE,
    auto_drop       => FALSE,
    comments        => 'Runs chain CHN_MONTH_END on the first of the month at 04:00');

  DBMS_OUTPUT.PUT_LINE('   .. job JOB_MONTH_END_CHAIN created (job_type => CHAIN)');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** chain layer not fully created: '
                         || SUBSTR(SQLERRM, 1, 250));
    DBMS_OUTPUT.PUT_LINE('   ***         *** The rest of the scheduler layer is unaffected.');
END;
/

-- =====================================================================================
-- 6. Summary
-- =====================================================================================
DECLARE
  l_jobs   PLS_INTEGER := 0;
  l_progs  PLS_INTEGER := 0;
  l_scheds PLS_INTEGER := 0;
  l_chains PLS_INTEGER := 0;
BEGIN
  BEGIN
    SELECT COUNT(*) INTO l_jobs   FROM user_scheduler_jobs;
    SELECT COUNT(*) INTO l_progs  FROM user_scheduler_programs;
    SELECT COUNT(*) INTO l_scheds FROM user_scheduler_schedules;
    SELECT COUNT(*) INTO l_chains FROM user_scheduler_chains;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------------');
  DBMS_OUTPUT.PUT_LINE('11-jobs-scheduler.sql summary');
  DBMS_OUTPUT.PUT_LINE('  jobs      : ' || l_jobs   || ' (this file creates 8; the count');
  DBMS_OUTPUT.PUT_LINE('              also includes the auto-refresh jobs that');
  DBMS_OUTPUT.PUT_LINE('              10-mviews.sql created behind START WITH/NEXT and');
  DBMS_OUTPUT.PUT_LINE('              behind DBMS_REFRESH.MAKE -- two more scheduler');
  DBMS_OUTPUT.PUT_LINE('              objects nobody declared, which is worth knowing');
  DBMS_OUTPUT.PUT_LINE('              before you count jobs on the target)');
  DBMS_OUTPUT.PUT_LINE('  programs  : ' || l_progs  || ' (design target 3, this file 6)');
  DBMS_OUTPUT.PUT_LINE('  schedules : ' || l_scheds || ' (design target 3)');
  DBMS_OUTPUT.PUT_LINE('  chains    : ' || l_chains || ' (needs the rules-engine privs)');
  DBMS_OUTPUT.PUT_LINE('  job class : ' || NVL(:g_job_class, 'DEFAULT_JOB_CLASS'));
  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------------');
END;
/

PROMPT 11-jobs-scheduler.sql complete.
