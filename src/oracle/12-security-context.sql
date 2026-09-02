-- =====================================================================================
-- Contoso Store -- Oracle source schema
-- 12-security-context.sql : application context, SYS_CONTEXT, Virtual Private Database
-- =====================================================================================
-- Owner        : CONTOSO
-- Depends on   : customer, sales_order; pkg_security_ctx and pkg_vpd_policy if present
-- Exercises    : H-39 (SYS_CONTEXT / application contexts), H-40 (VPD via DBMS_RLS),
--                H-43 (package-level session state), T-10 (implicit type conversion)
--
-- Design contract: docs/design.md sections 6.2 (#13 pkg_security_ctx, #14 pkg_vpd_policy)
-- and 9 (H-39, H-40). Sections H-39 and H-40 are one security workstream, not two
-- conversion items -- the context supplies the identity that the policy trusts, so
-- weakening either one weakens both.
--
-- PRIVILEGE NOTE. Three things here can fail on a locked-down account:
--   CREATE OR REPLACE CONTEXT  needs CREATE ANY CONTEXT
--   ACCESSED GLOBALLY          needs global application context support
--   DBMS_RLS.ADD_POLICY        needs EXECUTE on SYS.DBMS_RLS
-- All three are guarded. A user without them still gets a clean seed, a clear warning,
-- and every other object in this file.
-- =====================================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET SQLBLANKLINES ON
SET DEFINE OFF
SET FEEDBACK ON

PROMPT
PROMPT ==========================================================================
PROMPT 12-security-context.sql : application context and VPD
PROMPT ==========================================================================

VARIABLE g_has_context NUMBER
VARIABLE g_has_rls     NUMBER

-- =====================================================================================
-- 1. APPLICATION CONTEXT NAMESPACES
-- =====================================================================================
-- CONTOSO_APP_CTX is a *trusted* context: Oracle refuses DBMS_SESSION.SET_CONTEXT on it
-- from anywhere except the body of pkg_security_ctx. That is the entire security model.
-- Section 8 of this file proves the refusal actually happens.
--
-- MIGRATION NOTE (H-39): the nearest PostgreSQL construct is a custom GUC --
-- set_config('contoso.app_store_id', '42', false) read back with
-- current_setting('contoso.app_store_id', true). It is not equivalent, and the
-- difference is the whole point:
--
--   Oracle : only pkg_security_ctx can write the namespace. Application code that has
--            EXECUTE on the package still cannot forge an attribute, because the check
--            is on the calling *unit*, not on a privilege.
--   Postgres: any session can run SET contoso.app_store_id = '99'. There is no trusted
--            writer. A GUC is a suggestion.
--
-- Since the VPD predicates in section 5 read these attributes, a mechanical
-- context -> GUC conversion silently downgrades a security control into a comment.
-- The honest conversions are: put the identity in the connection role and use
-- current_user, or keep the value in a SECURITY DEFINER function's private table keyed
-- by pg_backend_pid(). Both change how connection pooling has to work, which is why
-- this belongs on the project plan and not in a converter's output.
--
-- MIGRATION NOTE (H-43): pkg_security_ctx also caches the current app user in a package
-- global (g_current_app_user) that lives for the session. PostgreSQL functions have no
-- persistent package state; a converter typically re-declares the variable inside the
-- function, which compiles and resets the cache on every single call.
-- -------------------------------------------------------------------------------------
DECLARE
  l_priv PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_priv
    FROM session_privs
   WHERE privilege = 'CREATE ANY CONTEXT';

  IF l_priv = 0 THEN
    :g_has_context := 0;
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** no CREATE ANY CONTEXT privilege.');
    DBMS_OUTPUT.PUT_LINE('   ***         *** CONTOSO_APP_CTX will not be created here.');
    DBMS_OUTPUT.PUT_LINE('   ***         *** If sql/00-schema-setup.sql already created');
    DBMS_OUTPUT.PUT_LINE('   ***         *** it as SYSTEM, everything below still works.');
    DBMS_OUTPUT.PUT_LINE('   ***         *** Otherwise: GRANT CREATE ANY CONTEXT TO contoso;');
  ELSE
    EXECUTE IMMEDIATE
      'CREATE OR REPLACE CONTEXT contoso_app_ctx USING pkg_security_ctx';
    :g_has_context := 1;
    DBMS_OUTPUT.PUT_LINE('   .. context CONTOSO_APP_CTX created, trusted package '
                         || 'PKG_SECURITY_CTX');

    -- A second namespace, ACCESSED GLOBALLY: the attribute survives across sessions for
    -- the same client identifier. Used by the web channel so a pooled connection can
    -- pick the right identity back up. No PostgreSQL analogue whatsoever -- a GUC is
    -- strictly session-local. Optional, so failure is not fatal.
    BEGIN
      EXECUTE IMMEDIATE
        'CREATE OR REPLACE CONTEXT contoso_glb_ctx USING pkg_security_ctx '
        || 'ACCESSED GLOBALLY';
      DBMS_OUTPUT.PUT_LINE('   .. context CONTOSO_GLB_CTX created (ACCESSED GLOBALLY)');
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('   .. CONTOSO_GLB_CTX skipped: ' || SUBSTR(SQLERRM,1,120));
    END;
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    :g_has_context := 0;
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** context not created: '
                         || SUBSTR(SQLERRM, 1, 200));
END;
/

-- =====================================================================================
-- 2. SYS_CONTEXT surface
-- =====================================================================================
-- A view rather than an anonymous block on purpose: the conversion tool reads catalogue
-- metadata, so SYS_CONTEXT calls buried in a script are invisible to it while the same
-- calls inside a view definition are not.
--
-- MIGRATION NOTE (H-39): the USERENV mappings that do exist --
--   SESSION_USER           -> session_user
--   CURRENT_SCHEMA         -> current_schema
--   IP_ADDRESS             -> inet_client_addr()
--   HOST                   -> inet_client_addr() (no hostname; Oracle resolves, PG does not)
--   DB_NAME                -> current_database()
--   SERVER_HOST            -> inet_server_addr()
--   CLIENT_IDENTIFIER      -> an application GUC; nothing enforces who sets it
--   SESSIONID              -> pg_backend_pid(), which is NOT stable across a pooled
--                             reconnect the way an Oracle audit session id is
--   AUTHENTICATION_METHOD  -> no equivalent; closest is pg_stat_activity, which needs
--                             a privileged read and is not per-row available
-- ISDBA has no equivalent at all. Anything that branched on it must be rewritten around
-- pg_has_role(), which is a different question with a different answer.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_session_context AS
SELECT SYS_CONTEXT('USERENV', 'SESSION_USER')            AS session_user_name
     , SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')          AS current_schema_name
     , SYS_CONTEXT('USERENV', 'DB_NAME')                 AS db_name
     , SYS_CONTEXT('USERENV', 'SERVER_HOST')             AS server_host
     , SYS_CONTEXT('USERENV', 'HOST')                    AS client_host
     , SYS_CONTEXT('USERENV', 'IP_ADDRESS')              AS client_ip
     , SYS_CONTEXT('USERENV', 'OS_USER')                 AS os_user
     , SYS_CONTEXT('USERENV', 'MODULE')                  AS module_name
     , SYS_CONTEXT('USERENV', 'CLIENT_IDENTIFIER')       AS client_identifier
     , SYS_CONTEXT('USERENV', 'SESSIONID')               AS audit_session_id
     , SYS_CONTEXT('USERENV', 'AUTHENTICATION_METHOD')   AS auth_method
     , SYS_CONTEXT('USERENV', 'ISDBA')                   AS is_dba
     , SYS_CONTEXT('CONTOSO_APP_CTX', 'APP_USER')        AS app_user
     , SYS_CONTEXT('CONTOSO_APP_CTX', 'APP_STORE_ID')    AS app_store_id
     , SYS_CONTEXT('CONTOSO_APP_CTX', 'APP_COUNTRY')     AS app_country
     , SYS_CONTEXT('CONTOSO_APP_CTX', 'APP_ROLE')        AS app_role
     , SYS_CONTEXT('CONTOSO_APP_CTX', 'APP_CHANNEL')     AS app_channel
     , SYS_CONTEXT('CONTOSO_GLB_CTX', 'APP_TENANT')      AS app_tenant
  FROM dual;

COMMENT ON TABLE v_session_context IS
  'Everything the VPD predicates can see. SYS_CONTEXT on an unknown namespace returns NULL rather than raising, so this view compiles even when the context was not created.';

-- =====================================================================================
-- 3. VPD PREDICATE FUNCTIONS
-- =====================================================================================
-- docs/design.md puts the predicate logic in pkg_vpd_policy. These standalone functions
-- are the always-present fallback: section 5 prefers the package when its body is VALID
-- and drops back to these otherwise, so the lab exercises H-40 even if the package layer
-- has not been loaded yet.
--
-- MIGRATION NOTE (H-40): the shape of these functions is the problem, not the content.
-- A VPD predicate function returns a WHERE *fragment as text*, re-evaluated per
-- statement, and can therefore return a different predicate depending on who is asking.
-- A PostgreSQL RLS policy is a fixed boolean expression fixed at CREATE POLICY time.
-- The conversion is:
--
--     ALTER TABLE contoso.sales_order ENABLE ROW LEVEL SECURITY;
--     ALTER TABLE contoso.sales_order FORCE  ROW LEVEL SECURITY;   -- see below
--     CREATE POLICY sales_by_store ON contoso.sales_order FOR SELECT
--       USING (contoso.rls_sales_visible(store_id));
--
-- where rls_sales_visible is a STABLE function collapsing all the branching below into
-- one boolean. Two traps:
--   * FORCE ROW LEVEL SECURITY is NOT the default. Without it the table owner bypasses
--     every policy, and since the migration runs as the owner, the policies look like
--     they work and protect nothing.
--   * Policy types -- STATIC, SHARED_STATIC, CONTEXT_SENSITIVE, SHARED_CONTEXT_SENSITIVE
--     -- have no analogue. They are caching hints that changed the number of times the
--     predicate function ran. Dropping them is correct but changes performance, and
--     CONTEXT_SENSITIVE dropping to per-row evaluation on a large table is noticeable.
--
-- MIGRATION NOTE: both functions fail *open* for the schema owner and for a DBA, and
-- fail *closed* for everyone else. That asymmetry is deliberate -- it is exactly the
-- owner-bypass behaviour PostgreSQL RLS has by default, so the converted system starts
-- out matching, and only diverges once someone adds FORCE ROW LEVEL SECURITY.
-- -------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_vpd_sales_predicate (
    p_schema IN VARCHAR2,
    p_object IN VARCHAR2
) RETURN VARCHAR2
AS
  l_role  VARCHAR2(64);
  l_store VARCHAR2(64);
BEGIN
  -- Owner and DBA see everything: seeding, materialised view refresh and ora2pg all
  -- run in one of those two identities.
  IF SYS_CONTEXT('USERENV', 'SESSION_USER') = p_schema
     OR SYS_CONTEXT('USERENV', 'ISDBA') = 'TRUE'
  THEN
    RETURN NULL;
  END IF;

  l_role := SYS_CONTEXT('CONTOSO_APP_CTX', 'APP_ROLE');
  IF l_role IN ('HQ_FINANCE', 'HQ_MERCH', 'BATCH') THEN
    RETURN NULL;
  END IF;

  l_store := SYS_CONTEXT('CONTOSO_APP_CTX', 'APP_STORE_ID');
  IF l_store IS NULL THEN
    RETURN '1 = 0';
  END IF;

  -- MIGRATION NOTE (T-10): store_id is NUMBER(9) and SYS_CONTEXT returns VARCHAR2.
  -- Oracle converts implicitly and silently -- and, worse, the implicit TO_NUMBER on
  -- the *context* side means the index on store_id is still usable. PostgreSQL refuses
  -- the comparison outright, so this one at least fails loudly. Left unconverted on
  -- purpose: it is a two-line fix that a converter should be expected to spot.
  RETURN 'store_id = SYS_CONTEXT(''CONTOSO_APP_CTX'',''APP_STORE_ID'')';
END fn_vpd_sales_predicate;
/

CREATE OR REPLACE FUNCTION fn_vpd_customer_predicate (
    p_schema IN VARCHAR2,
    p_object IN VARCHAR2
) RETURN VARCHAR2
AS
  l_role    VARCHAR2(64);
  l_country VARCHAR2(64);
BEGIN
  IF SYS_CONTEXT('USERENV', 'SESSION_USER') = p_schema
     OR SYS_CONTEXT('USERENV', 'ISDBA') = 'TRUE'
  THEN
    RETURN NULL;
  END IF;

  l_role := SYS_CONTEXT('CONTOSO_APP_CTX', 'APP_ROLE');
  IF l_role IN ('HQ_FINANCE', 'HQ_MERCH', 'BATCH') THEN
    RETURN NULL;
  END IF;

  l_country := SYS_CONTEXT('CONTOSO_APP_CTX', 'APP_COUNTRY');
  IF l_country IS NULL THEN
    RETURN '1 = 0';
  END IF;

  -- GDPR erasure is honoured in the predicate, not by deleting rows: an erased customer
  -- becomes invisible to the application while the row survives for the finance audit
  -- trail. Converting this to RLS is straightforward; noticing that the *reason* it
  -- exists is a legal requirement, and that dropping the second conjunct is therefore a
  -- compliance incident rather than a performance tweak, is the part that needs a human.
  RETURN 'home_country_code = SYS_CONTEXT(''CONTOSO_APP_CTX'',''APP_COUNTRY'')'
      || ' AND gdpr_erasure_ts IS NULL';
END fn_vpd_customer_predicate;
/

CREATE OR REPLACE FUNCTION fn_vpd_pii_predicate (
    p_schema IN VARCHAR2,
    p_object IN VARCHAR2
) RETURN VARCHAR2
AS
  l_role VARCHAR2(64);
BEGIN
  IF SYS_CONTEXT('USERENV', 'SESSION_USER') = p_schema
     OR SYS_CONTEXT('USERENV', 'ISDBA') = 'TRUE'
  THEN
    RETURN NULL;
  END IF;

  l_role := SYS_CONTEXT('CONTOSO_APP_CTX', 'APP_ROLE');
  IF l_role IN ('HQ_FINANCE', 'CS_AGENT', 'DPO') THEN
    RETURN NULL;
  END IF;

  -- Column-masking policy: rows still come back, the three PII columns come back NULL.
  --
  -- MIGRATION NOTE (H-40): PostgreSQL RLS filters *rows*. It has no column masking at
  -- all. Reproducing this needs either a masking view that the role is granted instead
  -- of the table, or column-level GRANTs plus a rewritten application. Neither preserves
  -- the current behaviour, where one query returns full rows to a DPO and redacted rows
  -- to a store assistant with no change to the SQL. This is the single least convertible
  -- construct in the security layer.
  RETURN '1 = 0';
END fn_vpd_pii_predicate;
/

-- =====================================================================================
-- 4. Can we talk to DBMS_RLS at all?
-- =====================================================================================
DECLARE
  l_cnt PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_cnt
    FROM all_objects
   WHERE owner = 'SYS' AND object_name = 'DBMS_RLS' AND object_type = 'PACKAGE';
  :g_has_rls := CASE WHEN l_cnt > 0 THEN 1 ELSE 0 END;
EXCEPTION
  WHEN OTHERS THEN
    :g_has_rls := 0;
END;
/

-- =====================================================================================
-- 5. VIRTUAL PRIVATE DATABASE POLICIES
-- =====================================================================================
-- Guarded end to end. EXECUTE on SYS.DBMS_RLS is not granted by default, and a lab user
-- on a hosted Oracle may never get it. Losing this section costs H-40 its evidence and
-- nothing else.
-- -------------------------------------------------------------------------------------
DECLARE
  l_cust_fn  VARCHAR2(61) := 'FN_VPD_CUSTOMER_PREDICATE';
  l_pkg_cnt  PLS_INTEGER  := 0;
  l_added    PLS_INTEGER  := 0;
  l_bad      PLS_INTEGER  := 0;

  PROCEDURE drop_policy(p_object VARCHAR2, p_policy VARCHAR2) IS
  BEGIN
    DBMS_RLS.DROP_POLICY(object_schema => USER,
                         object_name   => p_object,
                         policy_name   => p_policy);
  EXCEPTION
    WHEN OTHERS THEN NULL;
  END drop_policy;
BEGIN
  IF NVL(:g_has_rls, 0) = 0 THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** DBMS_RLS is not visible to CONTOSO.');
    DBMS_OUTPUT.PUT_LINE('   ***         *** VPD policies skipped; H-40 has no evidence.');
    DBMS_OUTPUT.PUT_LINE('   ***         *** Fix: GRANT EXECUTE ON SYS.DBMS_RLS TO contoso;');
    RETURN;
  END IF;

  -- Refuse to register a policy whose predicate function did not compile. An INVALID
  -- policy function does not fail at ADD_POLICY time -- it fails with ORA-28110 on every
  -- subsequent SELECT against the protected table, which would take out the seed, the
  -- materialised view refresh and every later script. Cheap check, expensive omission.
  SELECT COUNT(*) INTO l_bad
    FROM user_objects
   WHERE object_type = 'FUNCTION'
     AND object_name IN ('FN_VPD_SALES_PREDICATE',
                         'FN_VPD_CUSTOMER_PREDICATE',
                         'FN_VPD_PII_PREDICATE')
     AND status <> 'VALID';

  IF l_bad > 0 THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** ' || l_bad || ' VPD predicate function(s) '
                         || 'are INVALID.');
    DBMS_OUTPUT.PUT_LINE('   ***         *** Registering a policy against one would make');
    DBMS_OUTPUT.PUT_LINE('   ***         *** every SELECT on the table raise ORA-28110.');
    DBMS_OUTPUT.PUT_LINE('   ***         *** Skipping all policies. Check USER_ERRORS.');
    RETURN;
  END IF;

  -- Prefer the packaged predicate named in docs/design.md section 6.2 when the package
  -- layer has already been loaded and compiled clean.
  SELECT COUNT(*) INTO l_pkg_cnt
    FROM user_procedures p
    JOIN user_objects o
      ON  o.object_name = p.object_name
      AND o.object_type = 'PACKAGE BODY'
      AND o.status      = 'VALID'
   WHERE p.object_name    = 'PKG_VPD_POLICY'
     AND p.procedure_name = 'CUSTOMER_PREDICATE';

  IF l_pkg_cnt > 0 THEN
    l_cust_fn := 'PKG_VPD_POLICY.CUSTOMER_PREDICATE';
    DBMS_OUTPUT.PUT_LINE('   .. using packaged predicate PKG_VPD_POLICY.CUSTOMER_PREDICATE');
  ELSE
    DBMS_OUTPUT.PUT_LINE('   .. PKG_VPD_POLICY.CUSTOMER_PREDICATE not available; '
                         || 'using FN_VPD_CUSTOMER_PREDICATE');
  END IF;

  drop_policy('SALES_ORDER', 'VPD_SALES_ORDER_BY_STORE');
  drop_policy('CUSTOMER',    'VPD_CUSTOMER_BY_COUNTRY');
  drop_policy('CUSTOMER',    'VPD_CUSTOMER_PII_MASK');

  ----------------------------------------------------------------- sales_order, SELECT
  -- CONTEXT_SENSITIVE: Oracle re-runs the predicate function only when a context
  -- attribute changed, not once per statement. Pure caching, no PostgreSQL analogue.
  BEGIN
    DBMS_RLS.ADD_POLICY(
      object_schema   => USER,
      object_name     => 'SALES_ORDER',
      policy_name     => 'VPD_SALES_ORDER_BY_STORE',
      function_schema => USER,
      policy_function => 'FN_VPD_SALES_PREDICATE',
      statement_types => 'SELECT',
      update_check    => FALSE,
      enable          => TRUE,
      policy_type     => DBMS_RLS.CONTEXT_SENSITIVE);
    l_added := l_added + 1;
    DBMS_OUTPUT.PUT_LINE('   .. policy VPD_SALES_ORDER_BY_STORE added '
                         || '(SELECT, CONTEXT_SENSITIVE)');
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('   .. VPD_SALES_ORDER_BY_STORE failed: '
                           || SUBSTR(SQLERRM, 1, 150));
  END;

  ------------------------------------------------------- customer, all statement types
  -- update_check => TRUE is the VPD equivalent of PostgreSQL's WITH CHECK clause: it
  -- stops a session writing a row it would not then be allowed to read. A converter
  -- that emits only USING and omits WITH CHECK creates a write-only escape hatch.
  BEGIN
    DBMS_RLS.ADD_POLICY(
      object_schema   => USER,
      object_name     => 'CUSTOMER',
      policy_name     => 'VPD_CUSTOMER_BY_COUNTRY',
      function_schema => USER,
      policy_function => l_cust_fn,
      statement_types => 'SELECT,INSERT,UPDATE,DELETE',
      update_check    => TRUE,
      enable          => TRUE,
      policy_type     => DBMS_RLS.DYNAMIC);
    l_added := l_added + 1;
    DBMS_OUTPUT.PUT_LINE('   .. policy VPD_CUSTOMER_BY_COUNTRY added '
                         || '(S/I/U/D, DYNAMIC, update_check)');
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('   .. VPD_CUSTOMER_BY_COUNTRY failed: '
                           || SUBSTR(SQLERRM, 1, 150));
  END;

  ------------------------------------------------ customer, column masking on PII cols
  BEGIN
    DBMS_RLS.ADD_POLICY(
      object_schema         => USER,
      object_name           => 'CUSTOMER',
      policy_name           => 'VPD_CUSTOMER_PII_MASK',
      function_schema       => USER,
      policy_function       => 'FN_VPD_PII_PREDICATE',
      statement_types       => 'SELECT',
      enable                => TRUE,
      sec_relevant_cols     => 'EMAIL,MOBILE_PHONE,BIRTH_DATE',
      sec_relevant_cols_opt => DBMS_RLS.ALL_ROWS,
      policy_type           => DBMS_RLS.CONTEXT_SENSITIVE);
    l_added := l_added + 1;
    DBMS_OUTPUT.PUT_LINE('   .. policy VPD_CUSTOMER_PII_MASK added '
                         || '(column masking on EMAIL, MOBILE_PHONE, BIRTH_DATE)');
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('   .. VPD_CUSTOMER_PII_MASK failed: '
                           || SUBSTR(SQLERRM, 1, 150));
  END;

  DBMS_OUTPUT.PUT_LINE('   .. ' || l_added || ' of 3 VPD policies registered');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** VPD layer not created: '
                         || SUBSTR(SQLERRM, 1, 250));
    DBMS_OUTPUT.PUT_LINE('   ***         *** The seed continues; H-40 loses its evidence.');
END;
/

-- =====================================================================================
-- 6. Sanity check: the owner must still see every row
-- =====================================================================================
-- If a predicate ever starts filtering the schema owner, every later seed step and every
-- materialised view refresh silently loses rows. Cheaper to catch it here than in
-- docs/06-findings.md.
-- -------------------------------------------------------------------------------------
DECLARE
  l_cust  PLS_INTEGER;
  l_sales PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_cust  FROM customer;
  SELECT COUNT(*) INTO l_sales FROM sales_order;
  DBMS_OUTPUT.PUT_LINE('   .. owner visibility check: customer=' || l_cust
                       || ' rows, sales_order=' || l_sales || ' rows');
  DBMS_OUTPUT.PUT_LINE('   .. (both counts must match the unfiltered totals; if they '
                       || 'read 0 after seeding, a predicate is filtering the owner)');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   .. owner visibility check skipped: '
                         || SUBSTR(SQLERRM, 1, 150));
END;
/

-- =====================================================================================
-- 7. Demonstrate that the context is genuinely trusted
-- =====================================================================================
-- This block MUST fail with ORA-01031. It is not a mistake in the script -- it is the
-- proof that CONTOSO_APP_CTX cannot be forged from outside pkg_security_ctx, which is
-- the property that has no PostgreSQL equivalent (H-39). Anyone converting this schema
-- should run the same experiment against the target and watch a plain SET succeed.
-- -------------------------------------------------------------------------------------
BEGIN
  DBMS_SESSION.SET_CONTEXT('CONTOSO_APP_CTX', 'APP_STORE_ID', '999999');
  DBMS_OUTPUT.PUT_LINE('   *** WARNING *** CONTOSO_APP_CTX was writable from an');
  DBMS_OUTPUT.PUT_LINE('   ***         *** anonymous block. The namespace is NOT bound');
  DBMS_OUTPUT.PUT_LINE('   ***         *** to pkg_security_ctx and the VPD predicates');
  DBMS_OUTPUT.PUT_LINE('   ***         *** can be forged. Recreate it with USING.');
  DBMS_SESSION.CLEAR_CONTEXT('CONTOSO_APP_CTX', NULL, 'APP_STORE_ID');
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -1031 THEN
      DBMS_OUTPUT.PUT_LINE('   .. trusted-context check PASSED: ORA-01031 as expected.');
      DBMS_OUTPUT.PUT_LINE('   .. only PKG_SECURITY_CTX may write CONTOSO_APP_CTX.');
    ELSE
      DBMS_OUTPUT.PUT_LINE('   .. trusted-context check inconclusive: '
                           || SUBSTR(SQLERRM, 1, 150));
    END IF;
END;
/

-- =====================================================================================
-- 8. Summary
-- =====================================================================================
DECLARE
  l_pol PLS_INTEGER := 0;
  l_ctx VARCHAR2(64) := 'n/a (no DBA_CONTEXT read)';
BEGIN
  BEGIN
    SELECT COUNT(*) INTO l_pol FROM user_policies;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  -- Context *definitions* live in DBA_CONTEXT. ALL_CONTEXT lists only namespaces that
  -- are active in this session, which is zero until pkg_security_ctx sets an attribute,
  -- so it is the wrong view to count with here.
  BEGIN
    EXECUTE IMMEDIATE
      'SELECT TO_CHAR(COUNT(*)) FROM dba_context '
      || 'WHERE namespace IN (''CONTOSO_APP_CTX'', ''CONTOSO_GLB_CTX'')'
      INTO l_ctx;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------------');
  DBMS_OUTPUT.PUT_LINE('12-security-context.sql summary');
  DBMS_OUTPUT.PUT_LINE('  context namespaces : ' || l_ctx || ' (target 2)');
  DBMS_OUTPUT.PUT_LINE('  VPD policies       : ' || l_pol || ' (target 3)');
  DBMS_OUTPUT.PUT_LINE('  predicate functions: 3 standalone + pkg_vpd_policy if loaded');
  DBMS_OUTPUT.PUT_LINE('  view               : v_session_context');
  DBMS_OUTPUT.PUT_LINE('  H-39 and H-40 are one workstream. Convert them together.');
  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------------');
END;
/

PROMPT 12-security-context.sql complete.
