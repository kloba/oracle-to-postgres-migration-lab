-- =====================================================================================
-- Contoso Store -- Oracle source schema
-- 13-synonyms-grants.sql : the synonym layer and the read-only reporting role
-- =====================================================================================
-- Owner        : CONTOSO
-- Depends on   : everything. Run this last.
-- Exercises    : H-41 (synonym layer, including one dangling synonym), plus the Oracle
--                privilege model that H-39/H-40 depend on
--
-- Design contract: docs/design.md section 6.5 -- 24 private synonyms in three flavours
-- (table alias, package alias, one deliberately dangling), and explicitly:
-- "No PUBLIC synonyms -- the lab must not pollute a shared database."
--
-- Section 5 of this file therefore emits the classic PUBLIC synonym pattern but leaves
-- it switched OFF. Turn it on with
--     DEFINE create_public_synonyms = "Y"
-- before running, or edit the DEFINE below, and only ever on a database you own.
--
-- The application never references a base object by name. It connects, and every
-- statement it issues goes through a synonym. That indirection is the thing this file
-- exists to make the converter deal with -- see H-41.
-- =====================================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET SQLBLANKLINES ON
SET DEFINE OFF
SET FEEDBACK ON

PROMPT
PROMPT ==========================================================================
PROMPT 13-synonyms-grants.sql : synonyms, reporting role, grants
PROMPT ==========================================================================

VARIABLE g_can_synonym  NUMBER
VARIABLE g_can_pub_syn  NUMBER
VARIABLE g_role_ok      NUMBER

-- -------------------------------------------------------------------------------------
-- 0. Preflight
-- -------------------------------------------------------------------------------------
DECLARE
  l_syn  PLS_INTEGER;
  l_pub  PLS_INTEGER;
  l_role PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_syn  FROM session_privs WHERE privilege = 'CREATE SYNONYM';
  SELECT COUNT(*) INTO l_pub  FROM session_privs WHERE privilege = 'CREATE PUBLIC SYNONYM';
  SELECT COUNT(*) INTO l_role FROM session_privs WHERE privilege = 'CREATE ROLE';

  :g_can_synonym := l_syn;
  :g_can_pub_syn := l_pub;
  :g_role_ok     := 0;

  IF l_syn = 0 THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** no CREATE SYNONYM privilege.');
    DBMS_OUTPUT.PUT_LINE('   ***         *** The whole synonym layer will be skipped and');
    DBMS_OUTPUT.PUT_LINE('   ***         *** H-41 will have no evidence at all.');
    DBMS_OUTPUT.PUT_LINE('   ***         *** Fix: GRANT CREATE SYNONYM TO contoso;');
  ELSE
    DBMS_OUTPUT.PUT_LINE('   .. CREATE SYNONYM present');
  END IF;

  IF l_role = 0 THEN
    DBMS_OUTPUT.PUT_LINE('   .. CREATE ROLE absent; the reporting role will be skipped.');
  END IF;
END;
/

-- =====================================================================================
-- 1. PRIVATE SYNONYMS  (24, per docs/design.md section 6.5)
-- =====================================================================================
-- MIGRATION NOTE (H-41): PostgreSQL has no synonyms, at any version, in any form. The
-- three flavours below convert three different ways and only one of them is mechanical.
--
--   Table / view / materialised view aliases
--       -> either a view (`CREATE VIEW syn_orders AS SELECT * FROM sales_order`) or
--          absorbed into search_path if the alias name happens to match the target.
--          A view works but is not transparent: it is read-only unless you add an
--          INSTEAD OF trigger or the view is simple enough to be auto-updatable, and
--          `SELECT *` freezes the column list at creation time, so a later ALTER TABLE
--          ADD COLUMN does not appear through the alias. Oracle synonyms have neither
--          problem because they are name indirection, not a query.
--
--   Package aliases
--       -> nothing. The package became a schema, and PostgreSQL has no schema alias.
--          Every caller of syn_pricing.resolve(...) must be edited to say
--          pkg_pricing.resolve(...), or you write one wrapper function per entry point
--          and maintain two signatures forever. This is the flavour that turns a
--          "rename" into an application change.
--
--   The dangling synonym
--       -> see section 2.
--
-- MIGRATION NOTE: Oracle resolves a synonym at *statement execution* time, so dropping
-- and recreating the target under it is invisible to callers -- the standard trick for
-- a zero-downtime table swap. A PostgreSQL view is bound to its target's OID at
-- creation, so the same swap invalidates the view. Any deployment process that relied
-- on synonym repointing needs redesigning, and nothing in the DDL says it did.
-- -------------------------------------------------------------------------------------
DECLARE
  TYPE t_ddl IS TABLE OF VARCHAR2(200);

  -- Flavour 1: aliases over tables.
  l_tables t_ddl := t_ddl(
    'CREATE OR REPLACE SYNONYM syn_orders          FOR sales_order',
    'CREATE OR REPLACE SYNONYM syn_order_lines     FOR sales_order_line',
    'CREATE OR REPLACE SYNONYM syn_customers       FOR customer',
    'CREATE OR REPLACE SYNONYM syn_products        FOR product',
    'CREATE OR REPLACE SYNONYM syn_variants        FOR product_variant',
    'CREATE OR REPLACE SYNONYM syn_stock           FOR inventory_stock',
    'CREATE OR REPLACE SYNONYM syn_movements       FOR inventory_movement',
    'CREATE OR REPLACE SYNONYM syn_suppliers       FOR supplier',
    'CREATE OR REPLACE SYNONYM syn_purchase_orders FOR purchase_order',
    'CREATE OR REPLACE SYNONYM syn_stores          FOR store',
    'CREATE OR REPLACE SYNONYM syn_gl_journals     FOR gl_journal');

  -- Flavour 1b: aliases over views and materialised views. Worth separating, because a
  -- synonym over a materialised view converts to a view over a materialised view -- two
  -- layers of indirection where Oracle had one, and the extra layer defeats
  -- REFRESH MATERIALIZED VIEW CONCURRENTLY planning if anyone queries through it.
  l_views t_ddl := t_ddl(
    'CREATE OR REPLACE SYNONYM syn_customer_360    FOR v_customer_360',
    'CREATE OR REPLACE SYNONYM syn_stock_position  FOR v_stock_position',
    'CREATE OR REPLACE SYNONYM syn_sellable        FOR v_product_sellable',
    'CREATE OR REPLACE SYNONYM syn_trial_balance   FOR v_gl_trial_balance',
    'CREATE OR REPLACE SYNONYM syn_sales_daily     FOR mv_sales_daily_store',
    'CREATE OR REPLACE SYNONYM syn_customer_rfm    FOR mv_customer_rfm');

  -- Flavour 2: aliases over packages and standalone routines. No PostgreSQL analogue.
  l_code t_ddl := t_ddl(
    'CREATE OR REPLACE SYNONYM syn_pricing         FOR pkg_pricing',
    'CREATE OR REPLACE SYNONYM syn_inventory       FOR pkg_inventory',
    'CREATE OR REPLACE SYNONYM syn_reporting       FOR pkg_reporting',
    'CREATE OR REPLACE SYNONYM syn_loyalty_api     FOR pkg_loyalty',
    'CREATE OR REPLACE SYNONYM syn_order_capture   FOR pkg_order_capture',
    'CREATE OR REPLACE SYNONYM syn_effective_price FOR fn_effective_price');

  l_ok   PLS_INTEGER := 0;
  l_fail PLS_INTEGER := 0;

  PROCEDURE run_all(p_ddl t_ddl, p_label VARCHAR2) IS
  BEGIN
    FOR i IN 1 .. p_ddl.COUNT LOOP
      BEGIN
        EXECUTE IMMEDIATE p_ddl(i);
        l_ok := l_ok + 1;
      EXCEPTION
        WHEN OTHERS THEN
          l_fail := l_fail + 1;
          DBMS_OUTPUT.PUT_LINE('   .. failed: ' || SUBSTR(p_ddl(i), 27, 40)
                               || ' -> ' || SUBSTR(SQLERRM, 1, 70));
      END;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('   .. ' || p_label || ': ' || p_ddl.COUNT || ' attempted');
  END run_all;
BEGIN
  IF NVL(:g_can_synonym, 0) = 0 THEN
    DBMS_OUTPUT.PUT_LINE('   .. private synonyms skipped (no CREATE SYNONYM)');
    RETURN;
  END IF;

  run_all(l_tables, 'table aliases');
  run_all(l_views,  'view and materialised view aliases');
  run_all(l_code,   'package and routine aliases');

  DBMS_OUTPUT.PUT_LINE('   .. ' || l_ok || ' synonyms created, ' || l_fail || ' failed');
  IF l_fail > 0 THEN
    DBMS_OUTPUT.PUT_LINE('   .. (a failure here means the target object does not exist '
                         || 'yet -- run this file last)');
  END IF;
END;
/

-- =====================================================================================
-- 2. THE DANGLING SYNONYM
-- =====================================================================================
-- CREATE SYNONYM succeeds against an object that has never existed. Oracle only
-- complains when someone uses it, and then with ORA-00980 "synonym translation is no
-- longer valid". Legacy schemas accumulate these by the dozen.
--
-- legacy_pricebook was dropped in the 2011 pricing rewrite. The synonym was not.
--
-- MIGRATION NOTE (H-41): this single object is the most informative thing in the file.
-- The converter has exactly three options and each says something different about how
-- it will behave on a real legacy schema:
--   1. Emit a broken view over a non-existent table -- the target DDL then fails to
--      apply, which is loud and therefore fine.
--   2. Skip it silently -- the conversion looks clean and an object has vanished. This
--      is the dangerous outcome, because the same logic silently drops synonyms whose
--      targets exist but were not in the conversion scope.
--   3. Report it as a review task -- correct.
-- Record which one happened in docs/06-findings.md. It generalises.
-- -------------------------------------------------------------------------------------
BEGIN
  IF NVL(:g_can_synonym, 0) = 0 THEN
    RETURN;
  END IF;
  EXECUTE IMMEDIATE 'CREATE OR REPLACE SYNONYM syn_legacy_pricebook FOR legacy_pricebook';
  DBMS_OUTPUT.PUT_LINE('   .. syn_legacy_pricebook created (deliberately dangling)');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   .. syn_legacy_pricebook failed: ' || SUBSTR(SQLERRM, 1, 120));
END;
/

-- Prove it is dangling rather than merely unused.
DECLARE
  l_dummy PLS_INTEGER;
BEGIN
  EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM syn_legacy_pricebook' INTO l_dummy;
  DBMS_OUTPUT.PUT_LINE('   *** WARNING *** syn_legacy_pricebook resolved. Something '
                       || 'called LEGACY_PRICEBOOK exists; H-41 needs it gone.');
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -980 THEN
      DBMS_OUTPUT.PUT_LINE('   .. confirmed dangling: ORA-00980 on first use, exactly '
                           || 'as a real abandoned synonym behaves');
    ELSE
      DBMS_OUTPUT.PUT_LINE('   .. confirmed unusable: ' || SUBSTR(SQLERRM, 1, 90));
    END IF;
END;
/

-- =====================================================================================
-- 3. THE READ-ONLY REPORTING ROLE
-- =====================================================================================
-- MIGRATION NOTE: Oracle roles and PostgreSQL roles are spelled the same and behave
-- differently in one way that breaks code rather than DDL.
--
--   *Oracle disables role privileges inside definer-rights PL/SQL.*
--
-- A package compiled with the default AUTHID DEFINER cannot see anything granted to it
-- through a role -- only direct grants count. That is why production Oracle schemas are
-- full of direct object grants that look redundant next to the roles. PostgreSQL has no
-- such rule: a SECURITY DEFINER function sees every privilege the definer holds,
-- role-inherited or not. So a converted schema is *more* permissive than the original,
-- silently, and the direct grants that look like clutter are the only record of what the
-- code actually needed. Do not tidy them away during conversion.
--
-- Two smaller ones:
--   * Oracle has no equivalent of ALTER DEFAULT PRIVILEGES. Every new object needs an
--     explicit grant, which is why section 5 loops over the catalogue. On PostgreSQL,
--     replace that loop with GRANT ... ON ALL TABLES IN SCHEMA contoso plus an
--     ALTER DEFAULT PRIVILEGES so future objects are covered.
--   * A PostgreSQL role is also potentially a login. Oracle roles cannot connect.
--     Converting a role to a role with LOGIN by accident creates an account.
-- -------------------------------------------------------------------------------------
DECLARE
  l_priv PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_priv FROM session_privs WHERE privilege = 'CREATE ROLE';

  IF l_priv = 0 THEN
    :g_role_ok := 0;
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** cannot create CONTOSO_REPORTING_RO.');
    DBMS_OUTPUT.PUT_LINE('   ***         *** Fix: GRANT CREATE ROLE TO contoso; as SYSTEM,');
    DBMS_OUTPUT.PUT_LINE('   ***         *** or create the role from SYSTEM directly.');
    RETURN;
  END IF;

  BEGIN
    EXECUTE IMMEDIATE 'DROP ROLE contoso_reporting_ro';
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  EXECUTE IMMEDIATE 'CREATE ROLE contoso_reporting_ro';
  :g_role_ok := 1;
  DBMS_OUTPUT.PUT_LINE('   .. role CONTOSO_REPORTING_RO created');
EXCEPTION
  WHEN OTHERS THEN
    :g_role_ok := 0;
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** role not created: '
                         || SUBSTR(SQLERRM, 1, 200));
END;
/

-- =====================================================================================
-- 4. GRANTS TO THE REPORTING ROLE
-- =====================================================================================
-- Least privilege, expressed the way Oracle forces you to express it: object by object.
-- Three tables are withheld deliberately -- reporting reaches customer, order_payment
-- and employee only through views, so that the VPD column-masking policy in
-- 12-security-context.sql and the PII redaction in v_customer_360 cannot be bypassed by
-- selecting the base table.
-- -------------------------------------------------------------------------------------
DECLARE
  l_sel  PLS_INTEGER := 0;
  l_exe  PLS_INTEGER := 0;
  l_skip PLS_INTEGER := 0;

  TYPE t_names IS TABLE OF VARCHAR2(30);

  -- Base tables the reporting role must NOT read directly.
  l_denied t_names := t_names('CUSTOMER', 'ORDER_PAYMENT', 'EMPLOYEE');

  -- Reporting-oriented code the role is allowed to execute. A read-only role with
  -- EXECUTE on everything is not read-only: pkg_inventory would let it move stock.
  l_exec_ok t_names := t_names('PKG_REPORTING', 'PKG_FX', 'PKG_UTILS',
                               'FN_EFFECTIVE_PRICE', 'FN_FISCAL_PERIOD',
                               'FN_CATEGORY_PATH', 'FN_MANAGER_CHAIN',
                               'FN_ORDER_LINE_COUNT', 'FN_SPLIT_CSV',
                               'FN_MASK_EMAIL', 'FN_WORKING_DAYS_BETWEEN');

  FUNCTION is_denied(p_name VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    FOR i IN 1 .. l_denied.COUNT LOOP
      IF l_denied(i) = p_name THEN
        RETURN TRUE;
      END IF;
    END LOOP;
    RETURN FALSE;
  END is_denied;
BEGIN
  IF NVL(:g_role_ok, 0) = 0 THEN
    DBMS_OUTPUT.PUT_LINE('   .. grants skipped (no reporting role)');
    RETURN;
  END IF;

  ------------------------------------------------------------------- SELECT on data
  FOR r IN (SELECT object_name, object_type
              FROM user_objects
             WHERE object_type IN ('TABLE', 'VIEW', 'MATERIALIZED VIEW')
               AND object_name NOT LIKE 'MLOG$%'
               AND object_name NOT LIKE 'RUPD$%'
               AND object_name NOT LIKE 'SYS_%'
               AND object_name NOT LIKE '%_NTAB'
               AND object_name NOT LIKE 'GTT_%'
             ORDER BY object_type, object_name)
  LOOP
    IF is_denied(r.object_name) THEN
      l_skip := l_skip + 1;
    ELSE
      BEGIN
        EXECUTE IMMEDIATE 'GRANT SELECT ON "' || r.object_name
                          || '" TO contoso_reporting_ro';
        l_sel := l_sel + 1;
      EXCEPTION
        WHEN OTHERS THEN
          l_skip := l_skip + 1;
      END;
    END IF;
  END LOOP;

  ------------------------------------------------------------------ EXECUTE on code
  FOR i IN 1 .. l_exec_ok.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE 'GRANT EXECUTE ON ' || l_exec_ok(i)
                        || ' TO contoso_reporting_ro';
      l_exe := l_exe + 1;
    EXCEPTION
      WHEN OTHERS THEN NULL;
    END;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('   .. SELECT granted on ' || l_sel || ' objects');
  DBMS_OUTPUT.PUT_LINE('   .. EXECUTE granted on ' || l_exe || ' of '
                       || l_exec_ok.COUNT || ' reporting routines');
  DBMS_OUTPUT.PUT_LINE('   .. ' || l_skip || ' objects withheld (deny-list, '
                       || 'temporary tables, nested-table stores, MV logs)');
END;
/

-- -------------------------------------------------------------------------------------
-- 4b. Hand the role to the low-privilege reader if it exists.
--     docs/design.md section 2 names O2P_READER as the account the conversion tool uses.
--     It needs dictionary access, not application data -- this grant is a convenience for
--     humans validating the lab, not a requirement of the tool.
-- -------------------------------------------------------------------------------------
DECLARE
  l_user PLS_INTEGER := 0;
BEGIN
  IF NVL(:g_role_ok, 0) = 0 THEN
    RETURN;
  END IF;

  SELECT COUNT(*) INTO l_user FROM all_users WHERE username = 'O2P_READER';

  IF l_user = 0 THEN
    DBMS_OUTPUT.PUT_LINE('   .. O2P_READER does not exist; role not assigned');
  ELSE
    EXECUTE IMMEDIATE 'GRANT contoso_reporting_ro TO o2p_reader';
    DBMS_OUTPUT.PUT_LINE('   .. CONTOSO_REPORTING_RO granted to O2P_READER');
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('   .. could not grant role to O2P_READER: '
                         || SUBSTR(SQLERRM, 1, 150));
END;
/

-- =====================================================================================
-- 5. PUBLIC SYNONYMS -- present, documented, and switched OFF
-- =====================================================================================
-- docs/design.md section 6.5 forbids PUBLIC synonyms outright: "the lab must not pollute
-- a shared database". A PUBLIC synonym is visible to every user in the instance, is not
-- owned by CONTOSO, and survives DROP USER contoso CASCADE -- so a lab that creates them
-- leaves litter behind that only a DBA can clear.
--
-- The classic "application connects through synonyms" deployment nevertheless uses them:
-- one PUBLIC synonym per entry point, so any schema can call CONTOSO's API without
-- qualifying it. The DDL is therefore written out below and gated behind an opt-in flag.
--
-- To exercise it on a database you own:
--     SET DEFINE ON
--     DEFINE create_public_synonyms = "Y"
--     @13-synonyms-grants.sql
--
-- MIGRATION NOTE (H-41): a PUBLIC synonym converts *worse* than a private one. A private
-- synonym can become a view in the same schema. A PUBLIC synonym's whole purpose is to
-- be resolvable from every schema without qualification, and the PostgreSQL equivalent
-- is to add contoso to the *database-level* search_path for every role -- which is a
-- server configuration change, not a DDL statement, and interacts badly with the
-- search_path that orafce already needs (see PG_SEARCH_PATH in .env.example and
-- section 11.2 of the design doc). Converters do not emit server configuration.
-- -------------------------------------------------------------------------------------
SET DEFINE ON
SET VERIFY OFF
DEFINE create_public_synonyms = "N"

DECLARE
  l_opt_in VARCHAR2(1) := UPPER(SUBSTR('&create_public_synonyms', 1, 1));

  TYPE t_ddl IS TABLE OF VARCHAR2(200);
  l_ddl t_ddl := t_ddl(
    'CREATE OR REPLACE PUBLIC SYNONYM contoso_orders   FOR contoso.sales_order',
    'CREATE OR REPLACE PUBLIC SYNONYM contoso_products FOR contoso.product',
    'CREATE OR REPLACE PUBLIC SYNONYM contoso_stock    FOR contoso.v_stock_position',
    'CREATE OR REPLACE PUBLIC SYNONYM contoso_pricing  FOR contoso.pkg_pricing',
    'CREATE OR REPLACE PUBLIC SYNONYM contoso_ordering FOR contoso.pkg_order_capture');
  l_ok PLS_INTEGER := 0;
BEGIN
  IF l_opt_in <> 'Y' THEN
    DBMS_OUTPUT.PUT_LINE('   .. PUBLIC synonyms NOT created (design.md 6.5 forbids them '
                         || 'by default)');
    DBMS_OUTPUT.PUT_LINE('   .. ' || l_ddl.COUNT || ' statements are written out in this '
                         || 'file for reference only');
    RETURN;
  END IF;

  IF NVL(:g_can_pub_syn, 0) = 0 THEN
    DBMS_OUTPUT.PUT_LINE('   *** WARNING *** opted in, but no CREATE PUBLIC SYNONYM '
                         || 'privilege. Skipping.');
    RETURN;
  END IF;

  DBMS_OUTPUT.PUT_LINE('   ** opted in: creating PUBLIC synonyms. These are INSTANCE '
                       || 'wide and are **');
  DBMS_OUTPUT.PUT_LINE('   ** not removed by DROP USER contoso CASCADE. Clean them up '
                       || 'by hand.       **');

  FOR i IN 1 .. l_ddl.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE l_ddl(i);
      l_ok := l_ok + 1;
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('   .. failed: ' || SUBSTR(SQLERRM, 1, 100));
    END;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('   .. ' || l_ok || ' PUBLIC synonyms created');
  DBMS_OUTPUT.PUT_LINE('   .. remember to DROP PUBLIC SYNONYM each of these when the '
                       || 'lab is torn down');
END;
/

SET DEFINE OFF

-- =====================================================================================
-- 6. Summary
-- =====================================================================================
DECLARE
  l_syn  PLS_INTEGER := 0;
  l_pub  PLS_INTEGER := 0;
  l_gr   PLS_INTEGER := 0;
BEGIN
  BEGIN
    SELECT COUNT(*) INTO l_syn FROM user_synonyms;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  BEGIN
    SELECT COUNT(*) INTO l_pub FROM all_synonyms
     WHERE owner = 'PUBLIC' AND table_owner = 'CONTOSO';
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  BEGIN
    SELECT COUNT(*) INTO l_gr FROM user_tab_privs
     WHERE grantee = 'CONTOSO_REPORTING_RO';
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------------');
  DBMS_OUTPUT.PUT_LINE('13-synonyms-grants.sql summary');
  DBMS_OUTPUT.PUT_LINE('  private synonyms      : ' || l_syn || ' (design target 24, '
                       || 'one of them dangling)');
  DBMS_OUTPUT.PUT_LINE('  PUBLIC synonyms       : ' || l_pub || ' (design target 0)');
  DBMS_OUTPUT.PUT_LINE('  reporting role        : '
                       || CASE WHEN NVL(:g_role_ok,0) = 1
                               THEN 'CONTOSO_REPORTING_RO'
                               ELSE 'not created' END);
  DBMS_OUTPUT.PUT_LINE('  grants to that role   : ' || l_gr);
  DBMS_OUTPUT.PUT_LINE('  H-41: check docs/06-findings.md for what the converter did');
  DBMS_OUTPUT.PUT_LINE('        with syn_legacy_pricebook. That answer generalises.');
  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------------');
END;
/

PROMPT 13-synonyms-grants.sql complete.
