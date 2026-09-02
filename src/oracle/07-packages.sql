-- =====================================================================================
-- Contoso Store -- Oracle source schema
-- 07-packages.sql : the business-logic layer (package specifications and bodies)
-- =====================================================================================
-- Owner        : CONTOSO
-- Depends on   : 01-types.sql, core + operational tables, 06-views.sql
-- Exercises    : H-01 overloading, H-02 autonomous transactions, H-03 object methods,
--                H-04/H-05 collections, H-06 CONNECT BY, H-07 MERGE, H-08 analytics,
--                H-09 REF CURSOR, H-10 BULK COLLECT / FORALL SAVE EXCEPTIONS,
--                H-11 EXECUTE IMMEDIATE incl. DDL, H-12 DBMS_OUTPUT, H-13 UTL_FILE,
--                H-23 DETERMINISTIC, H-24 RESULT_CACHE, H-28 user-defined exceptions,
--                H-29 PRAGMA EXCEPTION_INIT, H-30 ROWNUM, H-31 NVL/NVL2/DECODE,
--                H-32 (+) joins, H-34 DBMS_LOB, H-35 XMLTABLE, H-42 pipelined functions,
--                H-43 package-level session state, T-05, T-08, T-09, T-11, T-12
--
-- Design contract: docs/design.md section 6.2.
--
-- LAYOUT: every specification first, then every body. Specifications have no
-- interdependencies, so a single pass compiles them all; bodies may then call across
-- package boundaries freely without a forward-declaration dance.
--
-- MIGRATION NOTE (structural, applies to this whole file): an Oracle package is two
-- objects -- a specification that is the contract and a body that is the implementation.
-- PostgreSQL has neither. The standard conversion turns each package into a *schema*
-- containing one function per subprogram, which means: the public/private distinction
-- disappears (everything in a schema is callable, so privacy must be re-expressed as
-- GRANT/REVOKE), the spec/body split disappears (so mutual recursion across bodies needs
-- forward-declared stubs), and package initialisation blocks have nowhere to run. Budget
-- for a naming collision review too: two packages may each have a `validate` procedure,
-- and if the converter flattens them into one schema the second overwrites the first.
-- =====================================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET SQLBLANKLINES ON
SET DEFINE OFF
SET FEEDBACK ON

PROMPT
PROMPT ==========================================================================
PROMPT 07-packages.sql : package specifications
PROMPT ==========================================================================


-- =====================================================================================
-- SPEC 1 : pkg_audit -- the autonomous audit trail
-- =====================================================================================
-- MIGRATION NOTE (H-02): every routine in this package body carries
-- PRAGMA AUTONOMOUS_TRANSACTION, so an audit row survives the rollback of the change it
-- describes. PostgreSQL has no autonomous transactions. The two honest options are a
-- dblink self-connection (which opens a new backend per call -- fine for the odd error,
-- catastrophic for a per-row audit trigger) or accepting that audit rows now roll back
-- with their transaction. That second option is a genuine behaviour change and needs a
-- signed-off decision, not a converter's default. See docs/04-review-tasks.md.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE PACKAGE pkg_audit AS

  -- MIGRATION NOTE (H-01): three overloads of write_audit. The VARCHAR2 and the CLOB
  -- forms are the pair that will trip PostgreSQL overload resolution -- an untyped
  -- literal is a candidate for both and PostgreSQL raises "function is not unique"
  -- where Oracle resolves happily by conversion rank. Expect explicit casts at every
  -- call site.
  PROCEDURE write_audit(p_table_name IN VARCHAR2,
                        p_pk_value   IN VARCHAR2,
                        p_action     IN VARCHAR2);

  PROCEDURE write_audit(p_table_name IN VARCHAR2,
                        p_pk_value   IN VARCHAR2,
                        p_action     IN VARCHAR2,
                        p_old_row    IN VARCHAR2,
                        p_new_row    IN VARCHAR2);

  PROCEDURE write_audit(p_table_name IN VARCHAR2,
                        p_pk_value   IN VARCHAR2,
                        p_action     IN VARCHAR2,
                        p_old_row    IN CLOB,
                        p_new_row    IN CLOB);

  PROCEDURE purge_before(p_cutoff IN DATE, p_rows_deleted OUT NUMBER);

  FUNCTION audit_count(p_table_name IN VARCHAR2) RETURN NUMBER;

END pkg_audit;
/

-- =====================================================================================
-- SPEC 2 : pkg_error -- central error capture and re-raise
-- =====================================================================================
CREATE OR REPLACE PACKAGE pkg_error AS

  -- MIGRATION NOTE (H-29): PRAGMA EXCEPTION_INIT binds an ORA- number to a name so the
  -- handler can be readable. PostgreSQL has named conditions for most of these
  -- (unique_violation, foreign_key_violation, not_null_violation, lock_not_available)
  -- so the *shape* converts. The gap is that ORA-02291 (parent key not found) and
  -- ORA-02292 (child record found) both collapse onto foreign_key_violation, losing the
  -- distinction. This package distinguishes them on purpose -- see classify_sqlcode.
  e_dup_val_on_index EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_dup_val_on_index, -1);

  e_parent_key_missing EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_parent_key_missing, -2291);

  e_child_record_found EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_child_record_found, -2292);

  e_not_null_violated EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_not_null_violated, -1400);

  e_resource_busy EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_resource_busy, -54);

  e_value_too_large EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_value_too_large, -12899);

  PROCEDURE log_error(p_module   IN VARCHAR2,
                      p_routine  IN VARCHAR2,
                      p_bind_ctx IN VARCHAR2 DEFAULT NULL);

  PROCEDURE log_and_reraise(p_module   IN VARCHAR2,
                            p_routine  IN VARCHAR2,
                            p_bind_ctx IN VARCHAR2 DEFAULT NULL);

  FUNCTION classify_sqlcode(p_sqlcode IN NUMBER) RETURN VARCHAR2 DETERMINISTIC;

END pkg_error;
/

-- =====================================================================================
-- SPEC 3 : pkg_utils -- helpers used by everything else
-- =====================================================================================
CREATE OR REPLACE PACKAGE pkg_utils AS

  -- MIGRATION NOTE (H-43): g_nls_numeric is package-level state. It is set once per
  -- session and read by every to_display call thereafter. PostgreSQL functions have no
  -- persistent package state -- every call starts clean. A converter typically emits the
  -- declaration *inside* each function, which compiles and silently reverts to the
  -- default on every call. The faithful conversion is a custom GUC via set_config /
  -- current_setting, which is per-session and therefore behaves correctly.
  g_nls_numeric  VARCHAR2(30) := '.,';
  g_call_count   PLS_INTEGER  := 0;

  -- MIGRATION NOTE (H-01): nine overloads of to_display. The one-argument NUMBER, DATE
  -- and VARCHAR2 forms are the textbook case Oracle resolves by family; PostgreSQL will
  -- resolve to_display(NULL) as ambiguous and to_display('2026-01-01') as text rather
  -- than date. Every call site with a literal needs a cast after conversion.
  FUNCTION to_display(p_value IN NUMBER)                                RETURN VARCHAR2;
  FUNCTION to_display(p_value IN NUMBER, p_decimals IN PLS_INTEGER)     RETURN VARCHAR2;
  FUNCTION to_display(p_value IN NUMBER, p_currency IN VARCHAR2)        RETURN VARCHAR2;
  FUNCTION to_display(p_value IN VARCHAR2)                              RETURN VARCHAR2;
  FUNCTION to_display(p_value IN VARCHAR2, p_max_len IN PLS_INTEGER)    RETURN VARCHAR2;
  FUNCTION to_display(p_value IN DATE)                                  RETURN VARCHAR2;
  FUNCTION to_display(p_value IN DATE, p_format IN VARCHAR2)            RETURN VARCHAR2;
  FUNCTION to_display(p_value IN t_money)                               RETURN VARCHAR2;
  FUNCTION to_display(p_value IN BOOLEAN)                               RETURN VARCHAR2;

  -- MIGRATION NOTE (H-11): next_id builds  SELECT <name>.NEXTVAL FROM dual  as text.
  -- This is the legacy pattern that survives in every twenty-year-old schema. On
  -- PostgreSQL it becomes EXECUTE format('SELECT nextval(%L)', p_sequence_name), and
  -- the identifier MUST go through quote_ident or %I or you have inherited a SQL
  -- injection hole that Oracle's own parser was accidentally shielding you from.
  FUNCTION next_id(p_sequence_name IN VARCHAR2) RETURN NUMBER;

  -- MIGRATION NOTE (H-33): store.legacy_migration_notes is the schema's only LONG.
  -- LONG cannot be used in most SQL expressions and cannot cross a database link, so
  -- this helper exists to lift it into a CLOB before anything else touches it.
  FUNCTION long_notes_to_clob(p_store_id IN NUMBER) RETURN CLOB;

  FUNCTION normalise_text(p_text IN VARCHAR2) RETURN VARCHAR2 DETERMINISTIC;

  -- %TYPE / %ROWTYPE anchors: cheap in Oracle, and they convert to explicit types on
  -- PostgreSQL (which does support %TYPE in PL/pgSQL, but not in a table definition).
  FUNCTION store_label(p_store_id IN store.store_id%TYPE) RETURN VARCHAR2;

  PROCEDURE describe_store(p_store IN store%ROWTYPE);

  PROCEDURE set_numeric_characters(p_chars IN VARCHAR2);

END pkg_utils;
/

-- =====================================================================================
-- SPEC 4 : pkg_catalog -- product and merchandise hierarchy maintenance
-- =====================================================================================
CREATE OR REPLACE PACKAGE pkg_catalog AS

  e_unknown_category EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_unknown_category, -20301);

  e_duplicate_sku EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_duplicate_sku, -20302);

  -- MIGRATION NOTE (H-01): five signatures of add_product, per docs/design.md H-01.
  FUNCTION add_product(p_sku           IN VARCHAR2,
                       p_name          IN VARCHAR2,
                       p_category_code IN VARCHAR2) RETURN NUMBER;

  FUNCTION add_product(p_sku         IN VARCHAR2,
                       p_name        IN VARCHAR2,
                       p_category_id IN NUMBER) RETURN NUMBER;

  FUNCTION add_product(p_sku           IN VARCHAR2,
                       p_name          IN VARCHAR2,
                       p_category_code IN VARCHAR2,
                       p_brand_code    IN VARCHAR2,
                       p_list_price    IN NUMBER,
                       p_unit_cost     IN NUMBER) RETURN NUMBER;

  FUNCTION add_product(p_sku           IN VARCHAR2,
                       p_name          IN VARCHAR2,
                       p_category_code IN VARCHAR2,
                       p_attributes    IN t_product_attr_tab) RETURN NUMBER;

  PROCEDURE add_product(p_sku           IN  VARCHAR2,
                        p_name          IN  VARCHAR2,
                        p_category_code IN  VARCHAR2,
                        p_product_id    OUT NUMBER);

  -- MIGRATION NOTE (H-06 + H-23): category_path walks the merchandise tree with
  -- SYS_CONNECT_BY_PATH; category_depth is marked DETERMINISTIC even though it reads a
  -- table. That is legal and common in Oracle -- DETERMINISTIC is an unverified promise
  -- used for query rewrite. Mapping it mechanically to PostgreSQL IMMUTABLE introduces a
  -- real bug, because IMMUTABLE is constant-folded at plan time. The correct target is
  -- STABLE, and no automated tool can tell the difference from the source text alone.
  FUNCTION category_path(p_category_id IN NUMBER) RETURN VARCHAR2;
  FUNCTION category_depth(p_category_id IN NUMBER) RETURN NUMBER DETERMINISTIC;

  FUNCTION leaf_categories(p_root_category_id IN NUMBER) RETURN t_number_tab;

  -- MIGRATION NOTE (H-35): XMLTABLE over product.spec_sheet.
  FUNCTION spec_attribute(p_product_id IN NUMBER,
                          p_attr_name  IN VARCHAR2) RETURN VARCHAR2;

  PROCEDURE retire_sku(p_sku IN VARCHAR2, p_reason IN VARCHAR2 DEFAULT 'END_OF_LIFE');

END pkg_catalog;
/

-- =====================================================================================
-- SPEC 5 : pkg_pricing -- effective price resolution
-- =====================================================================================
CREATE OR REPLACE PACKAGE pkg_pricing AS

  e_no_price_found EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_no_price_found, -20401);

  -- MIGRATION NOTE (H-43): g_cache_hits / g_cache_misses are public package globals and
  -- the private associative array g_price_cache in the body is worse: PostgreSQL has no
  -- session-scoped map at all. The options are a temp table (which drags in every
  -- problem in H-21) or dropping the cache (which drags in H-24's performance cliff).
  -- Whichever you choose, choose it deliberately -- the default conversion resets the
  -- cache on every call and nobody notices until a load test.
  g_cache_hits    PLS_INTEGER := 0;
  g_cache_misses  PLS_INTEGER := 0;

  -- MIGRATION NOTE (H-24): RESULT_CACHE has no PostgreSQL equivalent at any version.
  -- The clause is simply dropped, the function still compiles, and the answers are still
  -- correct -- so this fails *quietly*, as a performance regression found in load
  -- testing rather than an error at conversion time. The 11g RELIES_ON (price_list_item)
  -- form was deprecated in 11.2 and is retained here only as documentation.
  FUNCTION cached_base_price(p_variant_id IN NUMBER) RETURN NUMBER RESULT_CACHE;

  FUNCTION effective_price(p_variant_id  IN NUMBER,
                           p_store_id    IN NUMBER,
                           p_channel     IN VARCHAR2 DEFAULT 'POS',
                           p_on_date     IN DATE     DEFAULT SYSDATE) RETURN NUMBER;

  FUNCTION pick_winning_price(p_variant_id IN NUMBER,
                              p_country    IN VARCHAR2,
                              p_channel    IN VARCHAR2,
                              p_on_date    IN DATE DEFAULT SYSDATE) RETURN t_price_point;

  PROCEDURE resolve_prices(p_variant_ids IN  t_number_tab,
                           p_store_id    IN  NUMBER,
                           p_channel     IN  VARCHAR2 DEFAULT 'POS',
                           p_prices      OUT t_price_point_tab);

  PROCEDURE reset_cache;

END pkg_pricing;
/

-- =====================================================================================
-- SPEC 6 : pkg_inventory -- stock movements and the snapshot
-- =====================================================================================
CREATE OR REPLACE PACKAGE pkg_inventory AS

  e_negative_stock EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_negative_stock, -20501);

  e_unknown_location EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_unknown_location, -20502);

  TYPE t_movement_rec IS RECORD (
    variant_id       NUMBER,
    from_location_id NUMBER,
    to_location_id   NUMBER,
    movement_type    VARCHAR2(20),
    qty              NUMBER,
    reference_type   VARCHAR2(20),
    reference_id     NUMBER);

  TYPE t_movement_tab IS TABLE OF t_movement_rec INDEX BY PLS_INTEGER;

  PROCEDURE apply_movement(p_variant_id       IN  NUMBER,
                           p_from_location_id IN  NUMBER,
                           p_to_location_id   IN  NUMBER,
                           p_movement_type    IN  VARCHAR2,
                           p_qty              IN  NUMBER,
                           p_reference_type   IN  VARCHAR2 DEFAULT NULL,
                           p_reference_id     IN  NUMBER   DEFAULT NULL,
                           p_movement_id      OUT NUMBER);

  PROCEDURE bulk_apply(p_movements IN t_movement_tab, p_applied OUT NUMBER);

  PROCEDURE resnapshot_location(p_location_id IN NUMBER, p_rows_merged OUT NUMBER);

  FUNCTION available_qty(p_variant_id IN NUMBER, p_location_id IN NUMBER DEFAULT NULL)
    RETURN NUMBER;

  FUNCTION reorder_candidates(p_warehouse_id IN NUMBER DEFAULT NULL) RETURN t_number_tab;

END pkg_inventory;
/

-- =====================================================================================
-- SPEC 7 : pkg_receiving -- goods receipt posting
-- =====================================================================================
CREATE OR REPLACE PACKAGE pkg_receiving AS

  e_over_delivery EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_over_delivery, -20601);

  TYPE t_receipt_rec IS RECORD (
    po_id        NUMBER,
    po_line_no   NUMBER,
    warehouse_id NUMBER,
    qty_received NUMBER,
    qty_rejected NUMBER);

  TYPE t_receipt_tab IS TABLE OF t_receipt_rec;

  -- MIGRATION NOTE (H-10): post_receipts is built on FORALL ... SAVE EXCEPTIONS, which
  -- is the single hardest bulk case. Oracle continues past failing rows and reports them
  -- afterwards in SQL%BULK_EXCEPTIONS. PostgreSQL has nothing equivalent: one failure
  -- aborts the whole statement. The converted version needs an explicit per-row loop
  -- with its own BEGIN ... EXCEPTION block -- slower, and a real behaviour decision,
  -- because this routine exists precisely to quarantine bad receipt lines and keep going.
  PROCEDURE post_receipts(p_receipts IN  t_receipt_tab,
                          p_ok_count OUT NUMBER,
                          p_err_count OUT NUMBER);

  FUNCTION tolerance_pct RETURN NUMBER;

  PROCEDURE close_po_if_complete(p_po_id IN NUMBER);

END pkg_receiving;
/

-- =====================================================================================
-- SPEC 8 : pkg_order_mgmt -- basket validation and order placement
-- =====================================================================================
CREATE OR REPLACE PACKAGE pkg_order_mgmt AS

  -- MIGRATION NOTE (H-28): user-defined exceptions in the -20000..-20999 band. Callers
  -- switch on SQLCODE. PostgreSQL uses five-character SQLSTATE strings, so every one of
  -- these needs a stable, documented Oracle-number-to-SQLSTATE mapping -- including
  -- callers outside this repository. Build that table before the first conversion run,
  -- not after; retrofitting it means auditing every EXCEPTION handler twice.
  e_basket_empty EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_basket_empty, -20101);

  e_insufficient_stock EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_insufficient_stock, -20102);

  e_price_expired EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_price_expired, -20103);

  e_invalid_channel EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_invalid_channel, -20104);

  TYPE t_basket_line IS RECORD (
    variant_id NUMBER,
    qty        NUMBER,
    unit_price NUMBER);

  TYPE t_basket IS TABLE OF t_basket_line INDEX BY PLS_INTEGER;

  PROCEDURE validate_basket(p_basket     IN  t_basket,
                            p_store_id   IN  NUMBER,
                            p_channel    IN  VARCHAR2,
                            p_line_count OUT NUMBER);

  PROCEDURE place_order(p_customer_id IN  NUMBER,
                        p_store_id    IN  NUMBER,
                        p_channel     IN  VARCHAR2 DEFAULT 'POS',
                        p_basket      IN  t_basket,
                        p_order_id    OUT NUMBER);

  PROCEDURE cancel_order(p_order_id IN NUMBER, p_reason IN VARCHAR2 DEFAULT 'CUSTOMER');

  FUNCTION order_value(p_order_id IN NUMBER) RETURN NUMBER;

END pkg_order_mgmt;
/

-- =====================================================================================
-- SPEC 9 : pkg_fulfilment -- allocation, picking, shipping
-- =====================================================================================
CREATE OR REPLACE PACKAGE pkg_fulfilment AS

  -- MIGRATION NOTE (H-09): two ref cursor flavours, both returned to a caller.
  --   get_pick_list returns a *weak* SYS_REFCURSOR.
  --   open_order_cursor returns a *strong* cursor bound to sales_order%ROWTYPE.
  -- PostgreSQL refcursors exist but are usable only inside the transaction that opened
  -- them, and most drivers handle them badly. The idiomatic target is RETURNS TABLE,
  -- which changes the function signature and therefore every caller -- including
  -- application code outside this repo. The strong form is worse: the row type must be
  -- spelled out column by column, and it silently drifts the moment someone adds a
  -- column to sales_order.
  TYPE t_order_cur IS REF CURSOR RETURN sales_order%ROWTYPE;

  FUNCTION get_pick_list(p_store_id IN NUMBER, p_limit IN PLS_INTEGER DEFAULT 100)
    RETURN SYS_REFCURSOR;

  FUNCTION open_order_cursor(p_store_id IN NUMBER, p_status IN VARCHAR2 DEFAULT 'PLACED')
    RETURN t_order_cur;

  -- MIGRATION NOTE (T-12): FOR UPDATE SKIP LOCKED exists in both, but Oracle and
  -- PostgreSQL differ in how many rows a concurrent session skips under contention, so
  -- queue throughput and fairness change even though the SQL is identical.
  PROCEDURE claim_next_pick(p_store_id IN NUMBER, p_order_id OUT NUMBER);

  PROCEDURE allocate_order(p_order_id IN NUMBER, p_allocated OUT NUMBER);

  PROCEDURE create_shipment(p_order_id     IN  NUMBER,
                            p_carrier_code IN  VARCHAR2,
                            p_service      IN  VARCHAR2 DEFAULT 'STANDARD',
                            p_shipment_id  OUT NUMBER);

END pkg_fulfilment;
/

-- =====================================================================================
-- SPEC 10 : pkg_loyalty -- points, tiers and benefits
-- =====================================================================================
CREATE OR REPLACE PACKAGE pkg_loyalty AS

  e_insufficient_points EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_insufficient_points, -20701);

  e_account_closed EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_account_closed, -20702);

  PROCEDURE accrue_points(p_loyalty_id IN NUMBER,
                          p_order_id   IN NUMBER,
                          p_amount     IN NUMBER,
                          p_points     OUT NUMBER);

  PROCEDURE redeem_points(p_loyalty_id IN NUMBER,
                          p_points     IN NUMBER,
                          p_order_id   IN NUMBER DEFAULT NULL);

  PROCEDURE expire_points(p_as_of IN DATE DEFAULT TRUNC(SYSDATE), p_expired OUT NUMBER);

  PROCEDURE review_tiers(p_reviewed OUT NUMBER);

  FUNCTION tier_for_points(p_points IN NUMBER) RETURN VARCHAR2 DETERMINISTIC;

  -- MIGRATION NOTE (H-05 + H-03): benefits is a nested table of t_loyalty_benefit, and
  -- t_loyalty_benefit has a member function is_active(). PostgreSQL can express the
  -- array-of-composite but not the method, and an array of composites is unindexable and
  -- unqueryable without unnest. A child table is the right answer and changes every DML
  -- statement that touches it. The tool cannot make that call for you.
  FUNCTION active_benefits(p_tier_code IN VARCHAR2,
                           p_on_date   IN DATE DEFAULT SYSDATE) RETURN t_benefit_tab;

  -- MIGRATION NOTE (H-04): a VARRAY parameter. Oracle VARRAYs are 1-based and dense and
  -- carry a declared maximum; PostgreSQL arrays are none of those things.
  FUNCTION channels_allowed(p_channels IN t_channel_varr) RETURN VARCHAR2;

END pkg_loyalty;
/

-- =====================================================================================
-- SPEC 11 : pkg_purchasing -- purchase order lifecycle
-- =====================================================================================
CREATE OR REPLACE PACKAGE pkg_purchasing AS

  e_po_already_sent EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_po_already_sent, -20201);

  e_po_not_approved EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_po_not_approved, -20202);

  e_supplier_not_approved EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_supplier_not_approved, -20203);

  PROCEDURE create_po(p_supplier_id  IN  NUMBER,
                      p_warehouse_id IN  NUMBER,
                      p_order_date   IN  DATE DEFAULT SYSDATE,
                      p_po_id        OUT NUMBER);

  PROCEDURE add_po_line(p_po_id      IN NUMBER,
                        p_variant_id IN NUMBER,
                        p_qty        IN NUMBER,
                        p_unit_cost  IN NUMBER DEFAULT NULL);

  PROCEDURE approve_po(p_po_id IN NUMBER, p_employee_id IN NUMBER);

  PROCEDURE send_po(p_po_id IN NUMBER);

  PROCEDURE cancel_po(p_po_id IN NUMBER, p_reason IN VARCHAR2 DEFAULT 'BUYER_CANCEL');

  -- MIGRATION NOTE (H-11): rebuild_index issues DDL through EXECUTE IMMEDIATE. Three
  -- things change on PostgreSQL. Bind placeholders go from :1 to $1 (and DDL cannot be
  -- parameterised in either dialect, which is why the index name is concatenated).
  -- Identifier concatenation must move to format('%I') or quote_ident or it becomes an
  -- injection hole. And PL/pgSQL runs DDL inside the caller's transaction, where Oracle
  -- commits around it -- so a failure here rolls back work the Oracle version had
  -- already committed.
  PROCEDURE rebuild_index(p_index_name IN VARCHAR2);

  FUNCTION po_total(p_po_id IN NUMBER) RETURN NUMBER;

END pkg_purchasing;
/

-- =====================================================================================
-- SPEC 12 : pkg_reporting -- cursor factories and the pipelined function
-- =====================================================================================
CREATE OR REPLACE PACKAGE pkg_reporting AS

  TYPE t_store_day_rec IS RECORD (
    store_id     NUMBER,
    store_code   VARCHAR2(12),
    sales_date   DATE,
    order_count  NUMBER,
    net_amount   NUMBER,
    day_rank     NUMBER);

  TYPE t_store_day_tab IS TABLE OF t_store_day_rec;

  -- MIGRATION NOTE (H-42): a pipelined table function. Oracle's PIPE ROW yields
  -- incrementally, so the caller sees row 1 before row 2 is computed. PL/pgSQL's
  -- RETURN NEXT materialises the whole set into a tuplestore first, changing both the
  -- memory profile and the time to first row. TABLE(f(x)) becomes plain f(x) in the FROM
  -- clause, and a correlated TABLE(f(t.col)) needs LATERAL -- which mechanical
  -- converters routinely miss, producing either a parse error or a silent cross join.
  -- The return type is the schema-level t_number_tab rather than a package-local
  -- collection, because only a SQL type can be named in a TABLE() operator from plain
  -- SQL -- a restriction PostgreSQL does not have, so the converted function is usable
  -- in more places than the original.
  FUNCTION busy_store_ids(p_from       IN DATE,
                          p_to         IN DATE,
                          p_min_orders IN NUMBER DEFAULT 1) RETURN t_number_tab PIPELINED;

  -- The same query as a plain bulk return. Contrast with the pipelined form above: this
  -- one materialises, which is what the PostgreSQL conversion of *both* will do.
  FUNCTION store_day_summary(p_from IN DATE, p_to IN DATE) RETURN t_store_day_tab;

  FUNCTION open_sales_cursor(p_from IN DATE, p_to IN DATE) RETURN SYS_REFCURSOR;

  FUNCTION open_category_rollup(p_root_category_id IN NUMBER) RETURN SYS_REFCURSOR;

  -- MIGRATION NOTE (H-32): legacy_customer_orders is written with Oracle (+) syntax
  -- inside PL/SQL, where it is much easier to miss than in a view definition.
  FUNCTION legacy_customer_orders(p_country_code IN VARCHAR2) RETURN SYS_REFCURSOR;

  PROCEDURE print_top_stores(p_limit IN PLS_INTEGER DEFAULT 10);

END pkg_reporting;
/

-- =====================================================================================
-- SPEC 13 : pkg_etl_export -- flat file extracts
-- =====================================================================================
CREATE OR REPLACE PACKAGE pkg_etl_export AS

  e_directory_missing EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_directory_missing, -20801);

  g_directory  CONSTANT VARCHAR2(30) := 'CONTOSO_EXPORT_DIR';

  -- MIGRATION NOTE (H-13): UTL_FILE is an architecture problem wearing a syntax
  -- problem's clothes. orafce supplies a utl_file implementation, so a converter can
  -- emit calls that *compile* -- and then fail at runtime, because Azure Database for
  -- PostgreSQL flexible server has no accessible server filesystem and no utl_file_dir.
  -- A clean compile that fails in production is the worst possible outcome. The honest
  -- answers are a client-side COPY ... TO STDOUT, or pushing to Blob Storage from an
  -- external job.
  PROCEDURE write_sales_extract(p_from IN DATE, p_to IN DATE, p_rows OUT NUMBER);

  -- MIGRATION NOTE (H-34): build_order_document manipulates a CLOB through a locator --
  -- DBMS_LOB.CREATETEMPORARY, WRITEAPPEND, APPEND, GETLENGTH. Oracle LOB locators are
  -- mutable handles; PostgreSQL text values are values. Code that opened a locator and
  -- wrote through it needs restructuring, not translation.
  FUNCTION build_order_document(p_order_id IN NUMBER) RETURN CLOB;

  PROCEDURE dump_to_output(p_text IN CLOB);

END pkg_etl_export;
/

PROMPT   .. 13 package specifications compiled


PROMPT
PROMPT ==========================================================================
PROMPT 07-packages.sql : package bodies
PROMPT ==========================================================================


-- =====================================================================================
-- BODY 1 : pkg_audit
-- =====================================================================================
CREATE OR REPLACE PACKAGE BODY pkg_audit AS

  -- The three-argument form is a thin shim onto the CLOB form. Note the local NULL CLOB
  -- rather than TO_CLOB(NULL): passing an untyped NULL to an overloaded name is exactly
  -- the ambiguity H-01 warns about, and Oracle would reject it here too.
  PROCEDURE write_audit(p_table_name IN VARCHAR2,
                        p_pk_value   IN VARCHAR2,
                        p_action     IN VARCHAR2) IS
    l_null CLOB := NULL;
  BEGIN
    write_audit(p_table_name, p_pk_value, p_action, l_null, l_null);
  END write_audit;

  PROCEDURE write_audit(p_table_name IN VARCHAR2,
                        p_pk_value   IN VARCHAR2,
                        p_action     IN VARCHAR2,
                        p_old_row    IN VARCHAR2,
                        p_new_row    IN VARCHAR2) IS
  BEGIN
    write_audit(p_table_name, p_pk_value, p_action,
                TO_CLOB(p_old_row), TO_CLOB(p_new_row));
  END write_audit;

  -- MIGRATION NOTE (H-02): the pragma below is the whole point of this package. It opens
  -- a nested, independent transaction: the INSERT and its COMMIT are invisible to, and
  -- unaffected by, whatever the caller does next. There is no PostgreSQL equivalent.
  -- MIGRATION NOTE (H-39): changed_by, client_id and app_user are deliberately omitted
  -- from the column list so the table DEFAULTs -- which call SYS_CONTEXT -- populate
  -- them. That indirection is easy to lose in conversion: if the defaults are dropped,
  -- the columns go NULL and nothing errors.
  PROCEDURE write_audit(p_table_name IN VARCHAR2,
                        p_pk_value   IN VARCHAR2,
                        p_action     IN VARCHAR2,
                        p_old_row    IN CLOB,
                        p_new_row    IN CLOB) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO audit_log (audit_id, table_name, pk_value, action_type, old_row, new_row)
    VALUES (seq_audit_id.NEXTVAL,
            SUBSTR(UPPER(p_table_name), 1, 30),
            SUBSTR(p_pk_value, 1, 200),
            SUBSTR(UPPER(p_action), 1, 1),
            p_old_row,
            p_new_row);
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      -- An audit failure must never take down the business transaction. Roll back only
      -- the autonomous unit of work.
      ROLLBACK;
  END write_audit;

  PROCEDURE purge_before(p_cutoff IN DATE, p_rows_deleted OUT NUMBER) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    DELETE FROM audit_log WHERE changed_ts < CAST(p_cutoff AS TIMESTAMP);
    p_rows_deleted := SQL%ROWCOUNT;
    COMMIT;
  END purge_before;

  FUNCTION audit_count(p_table_name IN VARCHAR2) RETURN NUMBER IS
    l_count NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_count
      FROM audit_log
     WHERE table_name = UPPER(p_table_name);
    RETURN l_count;
  END audit_count;

END pkg_audit;
/

-- =====================================================================================
-- BODY 2 : pkg_error
-- =====================================================================================
CREATE OR REPLACE PACKAGE BODY pkg_error AS

  PROCEDURE log_error(p_module   IN VARCHAR2,
                      p_routine  IN VARCHAR2,
                      p_bind_ctx IN VARCHAR2 DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_code NUMBER        := SQLCODE;
    l_msg  VARCHAR2(4000) := SQLERRM;
  BEGIN
    -- MIGRATION NOTE (H-02): autonomous again, and here the reason is unambiguous -- an
    -- error log that rolls back with the failure it recorded is worthless. This is the
    -- one place where the dblink rewrite is genuinely the right answer, because errors
    -- are rare and the per-call connection cost does not matter.
    INSERT INTO error_log (error_id, module_name, routine_name, error_code,
                           error_message, error_backtrace, call_stack,
                           bind_context, db_user)
    VALUES (seq_error_id.NEXTVAL,
            SUBSTR(p_module, 1, 80),
            SUBSTR(p_routine, 1, 80),
            l_code,
            SUBSTR(l_msg, 1, 4000),
            TO_CLOB(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE),
            TO_CLOB(DBMS_UTILITY.FORMAT_CALL_STACK),
            SUBSTR(p_bind_ctx, 1, 4000),
            SUBSTR(SYS_CONTEXT('USERENV', 'SESSION_USER'), 1, 30));
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
  END log_error;

  PROCEDURE log_and_reraise(p_module   IN VARCHAR2,
                            p_routine  IN VARCHAR2,
                            p_bind_ctx IN VARCHAR2 DEFAULT NULL) IS
    l_code NUMBER        := SQLCODE;
    l_msg  VARCHAR2(4000) := SQLERRM;
  BEGIN
    log_error(p_module, p_routine, p_bind_ctx);

    -- MIGRATION NOTE (H-28): re-raising by *number* is the pattern that does not survive.
    -- Oracle application errors are integers in -20000..-20999 and callers switch on
    -- SQLCODE; PostgreSQL raises with a five-character SQLSTATE. The mapping table is a
    -- project deliverable, not an implementation detail.
    IF l_code BETWEEN -20999 AND -20000 THEN
      RAISE_APPLICATION_ERROR(l_code, SUBSTR(l_msg, 1, 1800), TRUE);
    ELSIF l_code <> 0 THEN
      RAISE_APPLICATION_ERROR(-20999,
        'Re-raised from ' || p_module || '.' || p_routine || ': '
        || SUBSTR(l_msg, 1, 1500), TRUE);
    END IF;
  END log_and_reraise;

  -- MIGRATION NOTE (H-29): -2291 and -2292 are both foreign key violations and both map
  -- to the single PostgreSQL condition foreign_key_violation. Splitting them here proves
  -- the information loss is real: after conversion, this function cannot tell a missing
  -- parent from a surviving child without parsing the message text.
  FUNCTION classify_sqlcode(p_sqlcode IN NUMBER) RETURN VARCHAR2 DETERMINISTIC IS
  BEGIN
    RETURN CASE p_sqlcode
             WHEN     -1 THEN 'UNIQUE_VIOLATION'
             WHEN  -2291 THEN 'FK_PARENT_MISSING'
             WHEN  -2292 THEN 'FK_CHILD_EXISTS'
             WHEN  -1400 THEN 'NOT_NULL_VIOLATION'
             WHEN    -54 THEN 'RESOURCE_BUSY'
             WHEN -12899 THEN 'VALUE_TOO_LARGE'
             WHEN  -1403 THEN 'NO_DATA_FOUND'
             WHEN  -1422 THEN 'TOO_MANY_ROWS'
             ELSE CASE WHEN p_sqlcode BETWEEN -20999 AND -20000
                       THEN 'APPLICATION_ERROR'
                       ELSE 'UNCLASSIFIED' END
           END;
  END classify_sqlcode;

END pkg_error;
/

-- =====================================================================================
-- BODY 3 : pkg_utils
-- =====================================================================================
CREATE OR REPLACE PACKAGE BODY pkg_utils AS

  -- Private package state. See H-43: these two live for the session in Oracle and have
  -- nowhere to live at all in PostgreSQL.
  g_fallback_base NUMBER      := NULL;
  g_fallback_seq  PLS_INTEGER := 0;

  FUNCTION to_display(p_value IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    g_call_count := g_call_count + 1;
    RETURN TO_CHAR(p_value, 'FM999G999G999G990D00',
                   'NLS_NUMERIC_CHARACTERS = ''' || g_nls_numeric || '''');
  END to_display;

  FUNCTION to_display(p_value IN NUMBER, p_decimals IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    g_call_count := g_call_count + 1;
    RETURN TO_CHAR(ROUND(p_value, p_decimals));
  END to_display;

  FUNCTION to_display(p_value IN NUMBER, p_currency IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    g_call_count := g_call_count + 1;
    RETURN p_currency || ' ' || TO_CHAR(p_value, 'FM999G999G990D00');
  END to_display;

  FUNCTION to_display(p_value IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    g_call_count := g_call_count + 1;
    -- MIGRATION NOTE (H-38): in Oracle an empty string IS NULL, so this returns the
    -- placeholder for both '' and NULL. On PostgreSQL '' is a real value and falls
    -- through to the TRIM branch, returning an empty string. Nothing errors; the output
    -- just changes for a subset of rows.
    RETURN NVL(TRIM(p_value), '(none)');
  END to_display;

  FUNCTION to_display(p_value IN VARCHAR2, p_max_len IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    g_call_count := g_call_count + 1;
    RETURN CASE WHEN LENGTH(p_value) > p_max_len
                THEN SUBSTR(p_value, 1, GREATEST(p_max_len - 3, 1)) || '...'
                ELSE p_value END;
  END to_display;

  FUNCTION to_display(p_value IN DATE) RETURN VARCHAR2 IS
  BEGIN
    g_call_count := g_call_count + 1;
    RETURN TO_CHAR(p_value, 'DD-MON-YYYY');
  END to_display;

  FUNCTION to_display(p_value IN DATE, p_format IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    g_call_count := g_call_count + 1;
    RETURN TO_CHAR(p_value, p_format);
  END to_display;

  -- MIGRATION NOTE (H-03): t_money carries a MAP MEMBER FUNCTION to_base. PostgreSQL
  -- composite types have no methods and no MAP/ORDER comparison semantics, so this call
  -- becomes a standalone function and any ORDER BY over a t_money column loses its
  -- ordering contract entirely.
  FUNCTION to_display(p_value IN t_money) RETURN VARCHAR2 IS
  BEGIN
    g_call_count := g_call_count + 1;
    IF p_value IS NULL THEN
      RETURN '(no amount)';
    END IF;
    RETURN p_value.currency_code || ' ' || TO_CHAR(p_value.amount, 'FM999G999G990D00');
  END to_display;

  -- MIGRATION NOTE: PL/SQL BOOLEAN is not a SQL type -- this overload cannot be called
  -- from SQL, only from PL/SQL. PostgreSQL's boolean is a first-class SQL type, so the
  -- converted function is callable from SQL and the overload set changes shape, which
  -- can create new ambiguities that did not exist on the source.
  FUNCTION to_display(p_value IN BOOLEAN) RETURN VARCHAR2 IS
  BEGIN
    g_call_count := g_call_count + 1;
    RETURN CASE WHEN p_value IS NULL THEN 'UNKNOWN'
                WHEN p_value         THEN 'YES'
                ELSE                      'NO' END;
  END to_display;

  FUNCTION next_id(p_sequence_name IN VARCHAR2) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    -- MIGRATION NOTE (H-11 / T-05): the identifier is concatenated straight into SQL
    -- text after a hand-rolled regexp check -- which is precisely what twenty-year-old
    -- schemas do. On PostgreSQL this must become
    --     EXECUTE format('SELECT nextval(%L)', p_sequence_name)
    -- because a converted EXECUTE with plain concatenation inherits an injection hole
    -- that Oracle's own parser was accidentally narrowing. FROM dual needs orafce, or
    -- drop the FROM clause entirely.
    IF NOT REGEXP_LIKE(p_sequence_name, '^[A-Za-z][A-Za-z0-9_$#]{0,127}$') THEN
      RAISE_APPLICATION_ERROR(-20901, 'Illegal sequence name: ' || p_sequence_name);
    END IF;

    EXECUTE IMMEDIATE 'SELECT ' || p_sequence_name || '.NEXTVAL FROM dual' INTO l_id;
    RETURN l_id;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = -20901 THEN
        RAISE;
      END IF;
      -- Legacy safety net: twenty-year-old schemas are full of these. It keeps the
      -- application running when a sequence is missing after a refresh from production,
      -- at the cost of a key that is unique-ish rather than unique.
      IF g_fallback_base IS NULL THEN
        g_fallback_base := TO_NUMBER(TO_CHAR(SYSTIMESTAMP, 'DDHH24MISS')) * 10000;
      END IF;
      g_fallback_seq := g_fallback_seq + 1;
      RETURN g_fallback_base + g_fallback_seq;
  END next_id;

  FUNCTION long_notes_to_clob(p_store_id IN NUMBER) RETURN CLOB IS
    -- A LONG can be fetched into a VARCHAR2 in PL/SQL up to 32767 bytes. Beyond that it
    -- needs DBMS_SQL or an ALTER TABLE ... MODIFY ... CLOB on the source first. See
    -- docs/05-data-movement.md.
    l_notes VARCHAR2(32767);
  BEGIN
    SELECT legacy_migration_notes INTO l_notes FROM store WHERE store_id = p_store_id;
    RETURN TO_CLOB(l_notes);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
    WHEN OTHERS        THEN RETURN TO_CLOB('<<LONG unreadable: ' || SQLERRM || '>>');
  END long_notes_to_clob;

  FUNCTION normalise_text(p_text IN VARCHAR2) RETURN VARCHAR2 DETERMINISTIC IS
  BEGIN
    RETURN UPPER(TRIM(REGEXP_REPLACE(p_text, '[[:space:]]+', ' ')));
  END normalise_text;

  FUNCTION store_label(p_store_id IN store.store_id%TYPE) RETURN VARCHAR2 IS
    l_label VARCHAR2(200);
  BEGIN
    SELECT store_code || ' - ' || store_name INTO l_label
      FROM store WHERE store_id = p_store_id;
    RETURN l_label;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN 'STORE?' || TO_CHAR(p_store_id);
  END store_label;

  PROCEDURE describe_store(p_store IN store%ROWTYPE) IS
  BEGIN
    -- MIGRATION NOTE (H-12): DBMS_OUTPUT becomes RAISE NOTICE, or orafce's shim provided
    -- the dbms_output schema is on the database search_path. The behavioural difference:
    -- Oracle buffers until the client fetches, PostgreSQL emits immediately, so the
    -- interleaving of this output with anything else changes.
    DBMS_OUTPUT.PUT_LINE('store ' || p_store.store_code || ' / ' || p_store.store_name);
    DBMS_OUTPUT.PUT_LINE('  format  : ' || p_store.store_format);
    DBMS_OUTPUT.PUT_LINE('  opened  : ' || to_display(p_store.opened_date));
    DBMS_OUTPUT.PUT_LINE('  area    : ' || to_display(p_store.selling_area_sqm));
    DBMS_OUTPUT.PUT_LINE('  trading : ' || to_display(p_store.closed_date IS NULL));
  END describe_store;

  PROCEDURE set_numeric_characters(p_chars IN VARCHAR2) IS
  BEGIN
    -- MIGRATION NOTE (H-43 + H-11): two session-scoped things at once -- a package global
    -- and an ALTER SESSION. PostgreSQL's equivalent of the second is SET lc_numeric or a
    -- custom GUC, and the equivalent of the first is nothing at all.
    g_nls_numeric := p_chars;
    EXECUTE IMMEDIATE 'ALTER SESSION SET NLS_NUMERIC_CHARACTERS = ''' || p_chars || '''';
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('set_numeric_characters ignored: ' || SUBSTR(SQLERRM, 1, 120));
  END set_numeric_characters;

END pkg_utils;
/

-- =====================================================================================
-- BODY 4 : pkg_catalog
-- =====================================================================================
CREATE OR REPLACE PACKAGE BODY pkg_catalog AS

  FUNCTION category_id_for(p_category_code IN VARCHAR2) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    SELECT category_id INTO l_id
      FROM product_category WHERE category_code = p_category_code;
    RETURN l_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20301, 'Unknown category code: ' || p_category_code);
  END category_id_for;

  FUNCTION add_product(p_sku           IN VARCHAR2,
                       p_name          IN VARCHAR2,
                       p_category_code IN VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN add_product(p_sku, p_name, category_id_for(p_category_code));
  END add_product;

  FUNCTION add_product(p_sku         IN VARCHAR2,
                       p_name        IN VARCHAR2,
                       p_category_id IN NUMBER) RETURN NUMBER IS
    l_product_id NUMBER;
  BEGIN
    l_product_id := pkg_utils.next_id('SEQ_PRODUCT_ID');
    INSERT INTO product (product_id, sku, product_name, category_id,
                         unit_cost, list_price, status)
    VALUES (l_product_id, p_sku, p_name, p_category_id, 0, 0, 'DRAFT');
    pkg_audit.write_audit('PRODUCT', TO_CHAR(l_product_id), 'I');
    RETURN l_product_id;
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      RAISE_APPLICATION_ERROR(-20302, 'Duplicate SKU: ' || p_sku);
  END add_product;

  FUNCTION add_product(p_sku           IN VARCHAR2,
                       p_name          IN VARCHAR2,
                       p_category_code IN VARCHAR2,
                       p_brand_code    IN VARCHAR2,
                       p_list_price    IN NUMBER,
                       p_unit_cost     IN NUMBER) RETURN NUMBER IS
    l_product_id NUMBER;
    l_brand_id   NUMBER;
    l_category_id NUMBER;
  BEGIN
    BEGIN
      SELECT brand_id INTO l_brand_id FROM brand WHERE brand_code = p_brand_code;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN l_brand_id := NULL;
    END;

    -- MIGRATION NOTE: category_id_for is private to this package body, and Oracle refuses
    -- (PLS-00231) to resolve a body-private function from inside a SQL statement, so the
    -- lookup has to happen in PL/SQL and land in a local first. PostgreSQL has no
    -- spec/body split -- every function in the converted schema is callable from SQL --
    -- so a converter is free to inline the call back into the INSERT. That is a silent
    -- behaviour change: category_id_for raises -20301 for an unknown code, and inlining it
    -- moves that RAISE from before the INSERT to inside it.
    l_category_id := category_id_for(p_category_code);

    l_product_id := pkg_utils.next_id('SEQ_PRODUCT_ID');
    INSERT INTO product (product_id, sku, product_name, category_id, brand_id,
                         unit_cost, list_price, status, launch_date)
    VALUES (l_product_id, p_sku, p_name, l_category_id, l_brand_id,
            p_unit_cost, p_list_price, 'ACTIVE', TRUNC(SYSDATE));
    pkg_audit.write_audit('PRODUCT', TO_CHAR(l_product_id), 'I');
    RETURN l_product_id;
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      RAISE_APPLICATION_ERROR(-20302, 'Duplicate SKU: ' || p_sku);
  END add_product;

  -- MIGRATION NOTE (H-05): a nested table passed as a parameter and stored straight into
  -- a nested table column. PostgreSQL can hold an array of composite, but product
  -- attributes are queried *by attribute name*, and an array of composite is unindexable
  -- without unnest. This is the one in the schema that should become a child table, and
  -- that decision changes every statement below.
  FUNCTION add_product(p_sku           IN VARCHAR2,
                       p_name          IN VARCHAR2,
                       p_category_code IN VARCHAR2,
                       p_attributes    IN t_product_attr_tab) RETURN NUMBER IS
    l_product_id  NUMBER;
    l_category_id NUMBER;
  BEGIN
    -- Same PLS-00231 hoist as the overload above: a body-private function cannot be
    -- named inside a SQL statement.
    l_category_id := category_id_for(p_category_code);

    l_product_id := pkg_utils.next_id('SEQ_PRODUCT_ID');
    INSERT INTO product (product_id, sku, product_name, category_id,
                         unit_cost, list_price, status, attributes)
    VALUES (l_product_id, p_sku, p_name, l_category_id,
            0, 0, 'DRAFT', p_attributes);
    pkg_audit.write_audit('PRODUCT', TO_CHAR(l_product_id), 'I');
    RETURN l_product_id;
  END add_product;

  PROCEDURE add_product(p_sku           IN  VARCHAR2,
                        p_name          IN  VARCHAR2,
                        p_category_code IN  VARCHAR2,
                        p_product_id    OUT NUMBER) IS
  BEGIN
    p_product_id := add_product(p_sku, p_name, p_category_code);
  END add_product;

  -- MIGRATION NOTE (H-06): SYS_CONNECT_BY_PATH inside PL/SQL. The WITH RECURSIVE
  -- rewrite must build the path string in the recursive term and carry it down. Watch
  -- the LTRIM: Oracle's path always starts with the separator, so a converted query that
  -- forgets it produces ' > Home > Kitchen' where the original produced 'Home > Kitchen'
  -- -- a one-character difference that fails string equality tests downstream.
  FUNCTION category_path(p_category_id IN NUMBER) RETURN VARCHAR2 IS
    l_path VARCHAR2(4000);
  BEGIN
    SELECT LTRIM(SYS_CONNECT_BY_PATH(category_name, ' > '), ' > ')
      INTO l_path
      FROM product_category
     WHERE category_id = p_category_id
     START WITH parent_category_id IS NULL
    CONNECT BY NOCYCLE PRIOR category_id = parent_category_id;
    RETURN l_path;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
    WHEN TOO_MANY_ROWS THEN RETURN '(ambiguous path)';
  END category_path;

  -- MIGRATION NOTE (H-23): DETERMINISTIC, and it reads a table. That is legal and common
  -- in Oracle. Converting it to IMMUTABLE would let the PostgreSQL planner constant-fold
  -- it at plan time and cache the result across statements -- correct until somebody
  -- reparents a category, then silently wrong. STABLE is the only safe target.
  FUNCTION category_depth(p_category_id IN NUMBER) RETURN NUMBER DETERMINISTIC IS
    l_depth NUMBER;
  BEGIN
    SELECT MAX(LEVEL) INTO l_depth
      FROM product_category
     START WITH category_id = p_category_id
    CONNECT BY NOCYCLE PRIOR parent_category_id = category_id;
    RETURN NVL(l_depth, 0);
  END category_depth;

  FUNCTION leaf_categories(p_root_category_id IN NUMBER) RETURN t_number_tab IS
    l_ids t_number_tab;
  BEGIN
    SELECT category_id
      BULK COLLECT INTO l_ids
      FROM product_category
     WHERE CONNECT_BY_ISLEAF = 1
     START WITH category_id = p_root_category_id
    CONNECT BY NOCYCLE PRIOR category_id = parent_category_id;
    RETURN l_ids;
  END leaf_categories;

  -- MIGRATION NOTE (H-35): XMLTABLE converts in shape; XMLQUERY ... RETURNING CONTENT
  -- and the .getStringVal() method-call syntax below do not. Oracle's XML support is far
  -- deeper than PostgreSQL's -- no schema registration, no structured storage, no
  -- XMLIndex, no method syntax on the type. A greenfield PostgreSQL design would use
  -- jsonb, at the cost of changing every consumer.
  FUNCTION spec_attribute(p_product_id IN NUMBER,
                          p_attr_name  IN VARCHAR2) RETURN VARCHAR2 IS
    l_value VARCHAR2(4000);
    l_xml   XMLTYPE;
  BEGIN
    SELECT x.attr_value
      INTO l_value
      FROM product p,
           XMLTABLE('/spec/attribute' PASSING p.spec_sheet
                    COLUMNS attr_name  VARCHAR2(100)  PATH '@name',
                            attr_value VARCHAR2(4000) PATH '.') x
     WHERE p.product_id = p_product_id
       AND x.attr_name  = p_attr_name
       AND ROWNUM = 1;
    RETURN l_value;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      BEGIN
        SELECT XMLQUERY('/spec/summary' PASSING p.spec_sheet RETURNING CONTENT)
          INTO l_xml
          FROM product p
         WHERE p.product_id = p_product_id;
        IF l_xml IS NULL THEN
          RETURN NULL;
        END IF;
        RETURN SUBSTR(l_xml.getStringVal(), 1, 4000);
      EXCEPTION
        WHEN OTHERS THEN RETURN NULL;
      END;
  END spec_attribute;

  PROCEDURE retire_sku(p_sku IN VARCHAR2, p_reason IN VARCHAR2 DEFAULT 'END_OF_LIFE') IS
    l_product_id NUMBER;
  BEGIN
    UPDATE product
       SET status = 'DISCONTINUED'
     WHERE sku = p_sku
     RETURNING product_id INTO l_product_id;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20304, 'Unknown SKU: ' || p_sku);
    END IF;

    UPDATE product_variant SET is_active = 'N' WHERE product_id = l_product_id;

    pkg_audit.write_audit('PRODUCT', TO_CHAR(l_product_id), 'U',
                          'status=ACTIVE', 'status=DISCONTINUED reason=' || p_reason);
  END retire_sku;

END pkg_catalog;
/

-- =====================================================================================
-- BODY 5 : pkg_pricing
-- =====================================================================================
CREATE OR REPLACE PACKAGE BODY pkg_pricing AS

  -- MIGRATION NOTE (H-43): an associative array held as package state. It persists for
  -- the life of the session and is shared by every call in that session. PostgreSQL has
  -- no session-scoped map at all. The three candidate targets -- a temp table (H-21), an
  -- unlogged session-keyed table, or dropping the cache (H-24) -- have different
  -- correctness and performance profiles, and the default converter output (declaring
  -- the variable inside the function) silently picks the fourth option: a cache that is
  -- empty on every call and therefore pure overhead.
  TYPE t_price_map IS TABLE OF NUMBER INDEX BY VARCHAR2(100);
  g_price_cache t_price_map;

  FUNCTION country_for_store(p_store_id IN NUMBER) RETURN VARCHAR2 IS
    l_country country.country_code%TYPE;
  BEGIN
    SELECT r.country_code
      INTO l_country
      FROM store s
      JOIN region r ON r.region_id = s.region_id
     WHERE s.store_id = p_store_id;
    RETURN l_country;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END country_for_store;

  -- MIGRATION NOTE (H-24): RESULT_CACHE must be repeated in the body or the package will
  -- not compile -- a detail worth knowing because it means the clause appears twice in
  -- the source and a converter that strips it from only one place leaves a mismatch.
  FUNCTION cached_base_price(p_variant_id IN NUMBER) RETURN NUMBER RESULT_CACHE IS
    l_price NUMBER;
  BEGIN
    SELECT p.list_price
      INTO l_price
      FROM product_variant pv
      JOIN product p ON p.product_id = pv.product_id
     WHERE pv.variant_id = p_variant_id;
    RETURN l_price;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END cached_base_price;

  -- MIGRATION NOTE (H-30 + H-32 + H-31): three hard cases in one statement, which is
  -- realistic and awkward on purpose.
  --   ROWNUM = 1 over an ordered inline view -> ORDER BY ... FETCH FIRST 1 ROW ONLY.
  --   tr.tax_rate_id(+) is an Oracle outer join inside PL/SQL, much easier to miss here
  --     than in a view definition.
  --   NVL(pl.valid_to, p_on_date) evaluates both arguments; COALESCE short-circuits.
  FUNCTION effective_price(p_variant_id  IN NUMBER,
                           p_store_id    IN NUMBER,
                           p_channel     IN VARCHAR2 DEFAULT 'POS',
                           p_on_date     IN DATE     DEFAULT SYSDATE) RETURN NUMBER IS
    l_price   NUMBER;
    l_country country.country_code%TYPE;
    l_key     VARCHAR2(100);
  BEGIN
    l_country := country_for_store(p_store_id);
    l_key     := p_variant_id || '|' || l_country || '|' || p_channel
                 || '|' || TO_CHAR(p_on_date, 'YYYYMMDD');

    IF g_price_cache.EXISTS(l_key) THEN
      g_cache_hits := g_cache_hits + 1;
      RETURN g_price_cache(l_key);
    END IF;
    g_cache_misses := g_cache_misses + 1;

    BEGIN
      SELECT unit_price
        INTO l_price
        FROM (SELECT pli.unit_price
                FROM price_list      pl
                   , price_list_item pli
                   , tax_rate        tr
               WHERE pli.price_list_id  = pl.price_list_id
                 AND pli.tax_rate_id    = tr.tax_rate_id(+)
                 AND pli.variant_id     = p_variant_id
                 AND pl.country_code    = l_country
                 AND pl.channel_code    = p_channel
                 AND pl.valid_from     <= p_on_date
                 AND NVL(pl.valid_to, p_on_date)          >= p_on_date
                 AND pli.effective_from <= p_on_date
                 AND NVL(pli.effective_to, p_on_date + 1)  > p_on_date
               ORDER BY pl.priority ASC NULLS LAST
                      , pli.effective_from DESC NULLS LAST)
       WHERE ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        l_price := cached_base_price(p_variant_id);
    END;

    IF l_price IS NULL THEN
      RAISE_APPLICATION_ERROR(-20401,
        'No price for variant ' || p_variant_id || ' in ' || NVL(l_country, '?'));
    END IF;

    g_price_cache(l_key) := l_price;
    RETURN l_price;
  END effective_price;

  FUNCTION pick_winning_price(p_variant_id IN NUMBER,
                              p_country    IN VARCHAR2,
                              p_channel    IN VARCHAR2,
                              p_on_date    IN DATE DEFAULT SYSDATE) RETURN t_price_point IS
    l_price  NUMBER;
    l_ccy    VARCHAR2(3);
    l_source VARCHAR2(20);
  BEGIN
    SELECT unit_price, currency_code, price_source
      INTO l_price, l_ccy, l_source
      FROM (SELECT pli.unit_price
                 , pl.currency_code
                 -- MIGRATION NOTE (H-31): DECODE with a NULL search key. DECODE treats
                 -- NULL = NULL as a match; CASE ... WHEN NULL never matches. Converting
                 -- this to a plain CASE silently relabels every row whose reason code is
                 -- NULL. IS NOT DISTINCT FROM is the correct target.
                 , DECODE(pli.price_reason_code, NULL, 'LIST', 'PROMO') AS price_source
                 , ROW_NUMBER() OVER (ORDER BY pl.priority ASC NULLS LAST,
                                               pli.effective_from DESC NULLS LAST) AS rn
              FROM price_list pl
              JOIN price_list_item pli ON pli.price_list_id = pl.price_list_id
             WHERE pli.variant_id  = p_variant_id
               AND pl.country_code = p_country
               AND pl.channel_code = p_channel
               AND pli.effective_from <= p_on_date)
     WHERE rn = 1;

    RETURN t_price_point(p_variant_id, l_price, l_ccy, l_source);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN t_price_point(p_variant_id, NULL, NULL, 'NONE');
  END pick_winning_price;

  PROCEDURE resolve_prices(p_variant_ids IN  t_number_tab,
                           p_store_id    IN  NUMBER,
                           p_channel     IN  VARCHAR2 DEFAULT 'POS',
                           p_prices      OUT t_price_point_tab) IS
    l_country country.country_code%TYPE;
  BEGIN
    l_country := country_for_store(p_store_id);
    p_prices  := t_price_point_tab();

    IF p_variant_ids IS NULL OR p_variant_ids.COUNT = 0 THEN
      RETURN;
    END IF;

    FOR i IN 1 .. p_variant_ids.COUNT LOOP
      p_prices.EXTEND;
      p_prices(p_prices.LAST) :=
        pick_winning_price(p_variant_ids(i), l_country, p_channel, SYSDATE);
    END LOOP;
  END resolve_prices;

  PROCEDURE reset_cache IS
  BEGIN
    g_price_cache.DELETE;
    g_cache_hits   := 0;
    g_cache_misses := 0;
    DBMS_OUTPUT.PUT_LINE('pkg_pricing: session price cache cleared');
  END reset_cache;

END pkg_pricing;
/

-- =====================================================================================
-- BODY 6 : pkg_inventory
-- =====================================================================================
CREATE OR REPLACE PACKAGE BODY pkg_inventory AS

  PROCEDURE apply_movement(p_variant_id       IN  NUMBER,
                           p_from_location_id IN  NUMBER,
                           p_to_location_id   IN  NUMBER,
                           p_movement_type    IN  VARCHAR2,
                           p_qty              IN  NUMBER,
                           p_reference_type   IN  VARCHAR2 DEFAULT NULL,
                           p_reference_id     IN  NUMBER   DEFAULT NULL,
                           p_movement_id      OUT NUMBER) IS
    l_id NUMBER;
  BEGIN
    IF p_qty IS NULL OR p_qty = 0 THEN
      RAISE_APPLICATION_ERROR(-20503, 'Movement quantity must be non-zero');
    END IF;

    l_id := pkg_utils.next_id('SEQ_MOVEMENT_ID');

    -- MIGRATION NOTE: RETURNING ... INTO exists in PostgreSQL as RETURNING with an
    -- INTO in PL/pgSQL, so this converts. What does not convert quietly is the
    -- partitioning underneath: inventory_movement is range-partitioned on movement_ts
    -- with a LIST subpartition on movement_type, and its primary key is
    -- (movement_id, movement_ts) -- already widened to include the partition key, which
    -- is why this table survives H-19 where sales_order does not.
    INSERT INTO inventory_movement (movement_id, movement_ts, variant_id,
                                    from_location_id, to_location_id, movement_type,
                                    qty, reference_type, reference_id, created_by)
    VALUES (l_id, SYSTIMESTAMP, p_variant_id,
            p_from_location_id, p_to_location_id, p_movement_type,
            p_qty, p_reference_type, p_reference_id,
            SYS_CONTEXT('USERENV', 'SESSION_USER'))
    RETURNING movement_id INTO p_movement_id;

    -- MIGRATION NOTE (H-07): MERGE survives on PostgreSQL 15+, which is why PG 15 is the
    -- floor for this lab. Two residues: Oracle allows a WHERE clause on the UPDATE
    -- branch (used here) and a DELETE clause, both spelled differently in PostgreSQL;
    -- and Oracle permits MERGE into a view, which PostgreSQL refuses.
    IF p_to_location_id IS NOT NULL THEN
      MERGE INTO inventory_stock tgt
      USING (SELECT p_to_location_id AS location_id,
                    p_variant_id     AS variant_id,
                    ABS(p_qty)       AS qty
               FROM dual) src
         ON (tgt.location_id = src.location_id AND tgt.variant_id = src.variant_id)
      WHEN MATCHED THEN
        UPDATE SET qty_on_hand      = tgt.qty_on_hand + src.qty
                 , last_movement_ts = SYSTIMESTAMP
              WHERE tgt.qty_on_hand + src.qty >= 0
      WHEN NOT MATCHED THEN
        INSERT (location_id, variant_id, qty_on_hand, qty_reserved, last_movement_ts)
        VALUES (src.location_id, src.variant_id, src.qty, 0, SYSTIMESTAMP);
    END IF;

    IF p_from_location_id IS NOT NULL THEN
      UPDATE inventory_stock
         SET qty_on_hand      = qty_on_hand - ABS(p_qty)
           , last_movement_ts = SYSTIMESTAMP
       WHERE location_id = p_from_location_id
         AND variant_id  = p_variant_id;

      IF SQL%ROWCOUNT = 0 THEN
        RAISE_APPLICATION_ERROR(-20502,
          'No stock record at location ' || p_from_location_id);
      END IF;
    END IF;
  END apply_movement;

  -- MIGRATION NOTE (H-10): the record collection is exploded into parallel scalar
  -- collections before the FORALL. That is not tidiness -- Oracle restricts what a FORALL
  -- bind may reference, and the pattern is everywhere in production code. On PostgreSQL
  -- the whole shape collapses into one INSERT ... SELECT over unnest(), because PL/pgSQL
  -- has no row-at-a-time overhead to avoid in the first place. The conversion is usually
  -- a simplification; the risk is that the simplification changes error granularity.
  PROCEDURE bulk_apply(p_movements IN t_movement_tab, p_applied OUT NUMBER) IS
    TYPE t_num IS TABLE OF NUMBER        INDEX BY PLS_INTEGER;
    TYPE t_vc  IS TABLE OF VARCHAR2(20)  INDEX BY PLS_INTEGER;

    l_ids    t_num;
    l_var    t_num;
    l_from   t_num;
    l_to     t_num;
    l_type   t_vc;
    l_qty    t_num;
    l_n      PLS_INTEGER := 0;
    l_idx    PLS_INTEGER;
  BEGIN
    p_applied := 0;
    IF p_movements.COUNT = 0 THEN
      RETURN;
    END IF;

    l_idx := p_movements.FIRST;
    WHILE l_idx IS NOT NULL LOOP
      l_n         := l_n + 1;
      l_ids(l_n)  := pkg_utils.next_id('SEQ_MOVEMENT_ID');
      l_var(l_n)  := p_movements(l_idx).variant_id;
      l_from(l_n) := p_movements(l_idx).from_location_id;
      l_to(l_n)   := p_movements(l_idx).to_location_id;
      l_type(l_n) := p_movements(l_idx).movement_type;
      l_qty(l_n)  := p_movements(l_idx).qty;
      l_idx       := p_movements.NEXT(l_idx);
    END LOOP;

    FORALL i IN 1 .. l_n
      INSERT INTO inventory_movement (movement_id, movement_ts, variant_id,
                                      from_location_id, to_location_id,
                                      movement_type, qty, created_by)
      VALUES (l_ids(i), SYSTIMESTAMP, l_var(i),
              l_from(i), l_to(i), l_type(i), l_qty(i),
              SYS_CONTEXT('USERENV', 'SESSION_USER'));

    p_applied := SQL%ROWCOUNT;

    FORALL i IN 1 .. l_n
      UPDATE inventory_stock
         SET qty_on_hand      = qty_on_hand + l_qty(i)
           , last_movement_ts = SYSTIMESTAMP
       WHERE location_id = l_to(i)
         AND variant_id  = l_var(i);

    DBMS_OUTPUT.PUT_LINE('pkg_inventory.bulk_apply: ' || p_applied || ' movements');
  EXCEPTION
    WHEN OTHERS THEN
      pkg_error.log_and_reraise('PKG_INVENTORY', 'BULK_APPLY',
                                'count=' || p_movements.COUNT);
  END bulk_apply;

  -- MIGRATION NOTE (H-10): BULK COLLECT with a LIMIT, the canonical way to walk a large
  -- result set in Oracle without exhausting the PGA. PL/pgSQL has no BULK COLLECT and
  -- does not need one -- a plain FOR ... IN (SELECT ...) cursor loop streams. The
  -- conversion is a simplification, but the LIMIT was also acting as an implicit commit
  -- boundary in some legacy jobs; check for that before deleting the batching.
  PROCEDURE resnapshot_location(p_location_id IN NUMBER, p_rows_merged OUT NUMBER) IS
    CURSOR c_moves IS
      SELECT variant_id, SUM(qty) AS net_qty
        FROM inventory_movement
       WHERE to_location_id = p_location_id
       GROUP BY variant_id;

    TYPE t_move_tab IS TABLE OF c_moves%ROWTYPE;
    l_batch   t_move_tab;
    l_total   NUMBER := 0;
    l_variant NUMBER;
    l_netqty  NUMBER;
  BEGIN
    OPEN c_moves;
    LOOP
      FETCH c_moves BULK COLLECT INTO l_batch LIMIT 500;
      EXIT WHEN l_batch.COUNT = 0;

      FOR i IN 1 .. l_batch.COUNT LOOP
        -- Copied into scalars before the MERGE: referencing a record field of a
        -- collection element directly inside SQL is a place where PL/SQL's rules and
        -- PL/pgSQL's differ, and the workaround costs nothing.
        l_variant := l_batch(i).variant_id;
        l_netqty  := l_batch(i).net_qty;

        MERGE INTO inventory_stock tgt
        USING (SELECT p_location_id AS location_id,
                      l_variant     AS variant_id,
                      l_netqty      AS qty
                 FROM dual) src
           ON (tgt.location_id = src.location_id AND tgt.variant_id = src.variant_id)
        WHEN MATCHED THEN
          UPDATE SET qty_on_hand = src.qty, last_movement_ts = SYSTIMESTAMP
        WHEN NOT MATCHED THEN
          INSERT (location_id, variant_id, qty_on_hand, qty_reserved)
          VALUES (src.location_id, src.variant_id, src.qty, 0);
        l_total := l_total + SQL%ROWCOUNT;
      END LOOP;

      EXIT WHEN l_batch.COUNT < 500;
    END LOOP;
    CLOSE c_moves;

    p_rows_merged := l_total;
  EXCEPTION
    WHEN OTHERS THEN
      IF c_moves%ISOPEN THEN
        CLOSE c_moves;
      END IF;
      pkg_error.log_and_reraise('PKG_INVENTORY', 'RESNAPSHOT_LOCATION',
                                'location=' || p_location_id);
  END resnapshot_location;

  FUNCTION available_qty(p_variant_id IN NUMBER, p_location_id IN NUMBER DEFAULT NULL)
    RETURN NUMBER IS
    l_qty NUMBER;
  BEGIN
    SELECT NVL(SUM(qty_available), 0)
      INTO l_qty
      FROM inventory_stock
     WHERE variant_id = p_variant_id
       AND (p_location_id IS NULL OR location_id = p_location_id);
    RETURN l_qty;
  END available_qty;

  FUNCTION reorder_candidates(p_warehouse_id IN NUMBER DEFAULT NULL) RETURN t_number_tab IS
    l_ids t_number_tab;
  BEGIN
    SELECT DISTINCT ist.variant_id
      BULK COLLECT INTO l_ids
      FROM inventory_stock    ist
      JOIN inventory_location il ON il.location_id = ist.location_id
     WHERE ist.reorder_point IS NOT NULL
       AND ist.qty_available < ist.reorder_point
       AND (p_warehouse_id IS NULL OR il.warehouse_id = p_warehouse_id);
    RETURN l_ids;
  END reorder_candidates;

END pkg_inventory;
/

-- =====================================================================================
-- BODY 7 : pkg_receiving
-- =====================================================================================
CREATE OR REPLACE PACKAGE BODY pkg_receiving AS

  -- ORA-24381 is what a FORALL ... SAVE EXCEPTIONS raises when at least one row failed.
  e_bulk_errors EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_bulk_errors, -24381);

  FUNCTION tolerance_pct RETURN NUMBER IS
    l_value app_parameter.param_value%TYPE;
  BEGIN
    SELECT param_value INTO l_value
      FROM app_parameter WHERE param_name = 'RECEIPT_TOLERANCE_PCT';
    RETURN TO_NUMBER(l_value);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN 5;
    WHEN VALUE_ERROR   THEN RETURN 5;
    -- MIGRATION NOTE (T-10): app_parameter.param_value is VARCHAR2 and TO_NUMBER on it
    -- is an implicit-conversion landmine. Oracle raises a catchable VALUE_ERROR;
    -- PostgreSQL raises invalid_text_representation. At least this one fails loudly --
    -- the comparison forms of the same mistake do not.
    WHEN OTHERS        THEN RETURN 5;
  END tolerance_pct;

  PROCEDURE post_receipts(p_receipts  IN  t_receipt_tab,
                          p_ok_count  OUT NUMBER,
                          p_err_count OUT NUMBER) IS
    TYPE t_num IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

    l_rid   t_num;
    l_po    t_num;
    l_line  t_num;
    l_wh    t_num;
    l_qty   t_num;
    l_rej   t_num;
    l_n     PLS_INTEGER := 0;
    l_bad_idx  PLS_INTEGER;
    l_bad_code PLS_INTEGER;
  BEGIN
    p_ok_count  := 0;
    p_err_count := 0;

    IF p_receipts IS NULL OR p_receipts.COUNT = 0 THEN
      RETURN;
    END IF;

    FOR i IN 1 .. p_receipts.COUNT LOOP
      l_n        := l_n + 1;
      l_rid(l_n) := pkg_utils.next_id('SEQ_RECEIPT_ID');
      l_po(l_n)  := p_receipts(i).po_id;
      l_line(l_n):= p_receipts(i).po_line_no;
      l_wh(l_n)  := p_receipts(i).warehouse_id;
      l_qty(l_n) := p_receipts(i).qty_received;
      l_rej(l_n) := NVL(p_receipts(i).qty_rejected, 0);
    END LOOP;

    -- MIGRATION NOTE (H-10): this is the hardest bulk case in the schema. SAVE
    -- EXCEPTIONS tells Oracle to keep going past failing rows and report them
    -- afterwards through SQL%BULK_EXCEPTIONS. PostgreSQL has no equivalent: the first
    -- failure aborts the statement and the whole batch is lost. The faithful conversion
    -- is a per-row loop wrapped in its own BEGIN ... EXCEPTION block, which is slower and
    -- changes the transaction shape. Do not let a converter drop the clause silently --
    -- the *business* behaviour here is "quarantine the bad lines and post the rest",
    -- and losing that means a nightly receipt run now fails entirely on one bad row.
    BEGIN
      FORALL i IN 1 .. l_n SAVE EXCEPTIONS
        INSERT INTO goods_receipt (receipt_id, po_id, po_line_no, warehouse_id,
                                   received_ts, qty_received, qty_rejected)
        VALUES (l_rid(i), l_po(i), l_line(i), l_wh(i),
                SYSTIMESTAMP, l_qty(i), l_rej(i));

      p_ok_count := l_n;
    EXCEPTION
      WHEN e_bulk_errors THEN
        p_err_count := SQL%BULK_EXCEPTIONS.COUNT;
        p_ok_count  := l_n - p_err_count;
        FOR i IN 1 .. SQL%BULK_EXCEPTIONS.COUNT LOOP
          l_bad_idx  := SQL%BULK_EXCEPTIONS(i).ERROR_INDEX;
          l_bad_code := SQL%BULK_EXCEPTIONS(i).ERROR_CODE;

          DBMS_OUTPUT.PUT_LINE(
            'post_receipts: row ' || l_bad_idx
            || ' rejected -- ORA' || l_bad_code
            || ' (' || pkg_error.classify_sqlcode(-l_bad_code) || ')');

          INSERT INTO data_quality_issue (issue_id, rule_code, entity_name,
                                          entity_key, severity, detail)
          VALUES (pkg_utils.next_id('SEQ_DQ_ISSUE_ID'),
                  'RECEIPT_BULK_REJECT',
                  'GOODS_RECEIPT',
                  TO_CHAR(l_po(l_bad_idx)) || '/' || TO_CHAR(l_line(l_bad_idx)),
                  'ERROR',
                  'FORALL SAVE EXCEPTIONS quarantined this receipt line (ORA'
                    || l_bad_code || ')');
        END LOOP;
    END;

    FOR i IN 1 .. l_n LOOP
      UPDATE purchase_order_line
         SET qty_received = NVL(qty_received, 0) + l_qty(i)
           , status       = CASE WHEN NVL(qty_received, 0) + l_qty(i) >= qty_ordered
                                 THEN 'RECEIVED' ELSE 'PART_RECV' END
       WHERE po_id   = l_po(i)
         AND line_no = l_line(i);
    END LOOP;
  END post_receipts;

  PROCEDURE close_po_if_complete(p_po_id IN NUMBER) IS
    l_open NUMBER;
    l_tol  NUMBER;
  BEGIN
    -- Called without parentheses: PL/SQL rejects empty parentheses on a call to a
    -- parameterless subprogram. PostgreSQL requires them -- tolerance_pct() -- so every
    -- no-argument call in the schema changes shape during conversion, and a converter
    -- that only rewrites calls it can see will miss the ones built by dynamic SQL.
    l_tol := tolerance_pct;

    SELECT COUNT(*)
      INTO l_open
      FROM purchase_order_line
     WHERE po_id = p_po_id
       AND NVL(qty_received, 0) < qty_ordered * (1 - l_tol / 100);

    IF l_open = 0 THEN
      UPDATE purchase_order SET status = 'RECEIVED' WHERE po_id = p_po_id;
      pkg_audit.write_audit('PURCHASE_ORDER', TO_CHAR(p_po_id), 'U',
                            'status=PART_RECV', 'status=RECEIVED');
    END IF;
  END close_po_if_complete;

END pkg_receiving;
/

-- =====================================================================================
-- BODY 8 : pkg_order_mgmt
-- =====================================================================================
CREATE OR REPLACE PACKAGE BODY pkg_order_mgmt AS

  g_valid_channels CONSTANT VARCHAR2(100) := 'POS,WEB,APP,CALL,KIOSK,PARTNER';

  PROCEDURE validate_basket(p_basket     IN  t_basket,
                            p_store_id   IN  NUMBER,
                            p_channel    IN  VARCHAR2,
                            p_line_count OUT NUMBER) IS

    -- MIGRATION NOTE: nested subprograms. PL/SQL lets a procedure declare private
    -- helpers in its own declarative section, scoped to that one call. PostgreSQL has no
    -- nested functions at all -- each helper becomes a schema-level function, which
    -- means it becomes callable by anyone, its name must be made globally unique, and
    -- the closure over the enclosing procedure's variables (p_store_id here) has to be
    -- turned into explicit parameters.
    l_errors PLS_INTEGER := 0;
    -- PL/SQL requires every variable declaration to precede every subprogram declaration
    -- in the same declarative section, so these two scalars have to sit up here with
    -- l_errors rather than next to the nested helpers that use them.
    l_idx    PLS_INTEGER;
    l_price  NUMBER;

    PROCEDURE check_channel IS
    BEGIN
      IF INSTR(',' || g_valid_channels || ',', ',' || p_channel || ',') = 0 THEN
        RAISE_APPLICATION_ERROR(-20104, 'Invalid channel: ' || p_channel);
      END IF;
    END check_channel;

    PROCEDURE check_stock(p_variant_id IN NUMBER, p_qty IN NUMBER) IS
      l_available NUMBER;
    BEGIN
      l_available := pkg_inventory.available_qty(p_variant_id);
      IF l_available < p_qty THEN
        l_errors := l_errors + 1;
        RAISE_APPLICATION_ERROR(-20102,
          'Insufficient stock for variant ' || p_variant_id
          || ': wanted ' || p_qty || ', available ' || l_available);
      END IF;
    END check_stock;

    FUNCTION line_price(p_variant_id IN NUMBER) RETURN NUMBER IS
    BEGIN
      RETURN pkg_pricing.effective_price(p_variant_id => p_variant_id,
                                         p_store_id   => p_store_id,
                                         p_channel    => p_channel);
    END line_price;
  BEGIN
    -- MIGRATION NOTE (H-28): RAISE_APPLICATION_ERROR with an application-specific number
    -- that callers switch on. On PostgreSQL this becomes
    --     RAISE EXCEPTION '...' USING ERRCODE = 'CT101';
    -- and every caller's WHEN clause has to change with it.
    IF p_basket.COUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20101, 'Basket is empty');
    END IF;

    check_channel;

    p_line_count := 0;
    l_idx := p_basket.FIRST;
    WHILE l_idx IS NOT NULL LOOP
      check_stock(p_basket(l_idx).variant_id, p_basket(l_idx).qty);
      l_price := line_price(p_basket(l_idx).variant_id);

      IF p_basket(l_idx).unit_price IS NOT NULL
         AND ABS(p_basket(l_idx).unit_price - l_price) > 0.01 THEN
        RAISE_APPLICATION_ERROR(-20103,
          'Price changed for variant ' || p_basket(l_idx).variant_id
          || ': basket ' || p_basket(l_idx).unit_price || ', current ' || l_price);
      END IF;

      p_line_count := p_line_count + 1;
      l_idx := p_basket.NEXT(l_idx);
    END LOOP;
  END validate_basket;

  PROCEDURE place_order(p_customer_id IN  NUMBER,
                        p_store_id    IN  NUMBER,
                        p_channel     IN  VARCHAR2 DEFAULT 'POS',
                        p_basket      IN  t_basket,
                        p_order_id    OUT NUMBER) IS
    l_order_id  NUMBER;
    l_lines     NUMBER;
    l_ccy       currency.currency_code%TYPE;
    l_subtotal  NUMBER := 0;
    l_tax       NUMBER := 0;
    l_price     NUMBER;
    l_idx       PLS_INTEGER;
    l_line_no   PLS_INTEGER := 0;
  BEGIN
    validate_basket(p_basket, p_store_id, p_channel, l_lines);

    SELECT cy.currency_code
      INTO l_ccy
      FROM store s
      JOIN region  r  ON r.region_id     = s.region_id
      JOIN country cy ON cy.country_code = r.country_code
     WHERE s.store_id = p_store_id;

    l_order_id := pkg_utils.next_id('SEQ_ORDER_ID');

    INSERT INTO sales_order (order_id, order_number, customer_id, store_id,
                             channel_code, order_ts, status, currency_code,
                             subtotal_amount, discount_amount, tax_amount,
                             shipping_amount)
    VALUES (l_order_id,
            'SO' || LPAD(TO_CHAR(l_order_id), 12, '0'),
            p_customer_id, p_store_id, p_channel, SYSTIMESTAMP, 'PLACED', l_ccy,
            0, 0, 0, 0);

    l_idx := p_basket.FIRST;
    WHILE l_idx IS NOT NULL LOOP
      l_line_no := l_line_no + 1;
      l_price   := NVL(p_basket(l_idx).unit_price,
                       pkg_pricing.effective_price(p_basket(l_idx).variant_id,
                                                   p_store_id, p_channel));

      INSERT INTO sales_order_line (order_id, line_no, variant_id, qty, unit_price,
                                    discount_amount, tax_amount, status)
      VALUES (l_order_id, l_line_no, p_basket(l_idx).variant_id,
              p_basket(l_idx).qty, l_price, 0,
              ROUND(p_basket(l_idx).qty * l_price * 0.2, 2), 'PLACED');

      l_subtotal := l_subtotal + p_basket(l_idx).qty * l_price;
      l_tax      := l_tax      + ROUND(p_basket(l_idx).qty * l_price * 0.2, 2);
      l_idx      := p_basket.NEXT(l_idx);
    END LOOP;

    -- order_total is a virtual column and therefore absent from both DML statements.
    UPDATE sales_order
       SET subtotal_amount = l_subtotal
         , tax_amount      = l_tax
     WHERE order_id = l_order_id;

    pkg_audit.write_audit('SALES_ORDER', TO_CHAR(l_order_id), 'I');
    p_order_id := l_order_id;
  EXCEPTION
    WHEN OTHERS THEN
      pkg_error.log_and_reraise('PKG_ORDER_MGMT', 'PLACE_ORDER',
                                'customer=' || p_customer_id
                                || ' store=' || p_store_id);
  END place_order;

  PROCEDURE cancel_order(p_order_id IN NUMBER, p_reason IN VARCHAR2 DEFAULT 'CUSTOMER') IS
    l_status sales_order.status%TYPE;
  BEGIN
    SELECT status INTO l_status FROM sales_order WHERE order_id = p_order_id FOR UPDATE;

    IF l_status IN ('SHIPPED', 'DELIVERED', 'RETURNED') THEN
      RAISE_APPLICATION_ERROR(-20105,
        'Cannot cancel an order in status ' || l_status);
    END IF;

    UPDATE sales_order      SET status = 'CANCELLED' WHERE order_id = p_order_id;
    UPDATE sales_order_line SET status = 'CANCELLED' WHERE order_id = p_order_id;

    pkg_audit.write_audit('SALES_ORDER', TO_CHAR(p_order_id), 'U',
                          'status=' || l_status, 'status=CANCELLED reason=' || p_reason);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20106, 'Unknown order ' || p_order_id);
  END cancel_order;

  FUNCTION order_value(p_order_id IN NUMBER) RETURN NUMBER IS
    l_value NUMBER;
  BEGIN
    SELECT NVL(SUM(line_total), 0) INTO l_value
      FROM sales_order_line WHERE order_id = p_order_id;
    RETURN l_value;
  END order_value;

END pkg_order_mgmt;
/

-- =====================================================================================
-- BODY 9 : pkg_fulfilment
-- =====================================================================================
CREATE OR REPLACE PACKAGE BODY pkg_fulfilment AS

  -- MIGRATION NOTE (H-09): a weak SYS_REFCURSOR handed back to the caller. On PostgreSQL
  -- a refcursor is only usable inside the transaction that opened it and most drivers
  -- fetch from it awkwardly, so the idiomatic target is RETURNS TABLE(...). That changes
  -- the signature, which changes every caller -- including application code outside this
  -- repository. Decide the calling convention before converting, not after.
  FUNCTION get_pick_list(p_store_id IN NUMBER, p_limit IN PLS_INTEGER DEFAULT 100)
    RETURN SYS_REFCURSOR IS
    l_cur SYS_REFCURSOR;
  BEGIN
    OPEN l_cur FOR
      SELECT so.order_id
           , so.order_number
           , sol.line_no
           , sol.variant_id
           , pv.variant_sku
           , p.product_name
           , sol.qty
           , sol.fulfil_location_id
           , il.location_code
        FROM sales_order      so
        JOIN sales_order_line sol ON sol.order_id  = so.order_id
        JOIN product_variant  pv  ON pv.variant_id = sol.variant_id
        JOIN product          p   ON p.product_id  = pv.product_id
        LEFT JOIN inventory_location il ON il.location_id = sol.fulfil_location_id
       WHERE so.store_id = p_store_id
         AND so.status   = 'PICKING'
         AND ROWNUM     <= p_limit
       ORDER BY so.order_ts, sol.line_no;
    RETURN l_cur;
  END get_pick_list;

  -- MIGRATION NOTE (H-09, the worse half): a *strong* ref cursor bound to
  -- sales_order%ROWTYPE. The return type must be spelled out column by column on
  -- PostgreSQL, and it drifts silently the moment someone adds a column to sales_order.
  -- SELECT * is what makes the Oracle version tolerate schema change; the converted
  -- version cannot.
  FUNCTION open_order_cursor(p_store_id IN NUMBER, p_status IN VARCHAR2 DEFAULT 'PLACED')
    RETURN t_order_cur IS
    l_cur t_order_cur;
  BEGIN
    OPEN l_cur FOR
      SELECT * FROM sales_order
       WHERE store_id = p_store_id
         AND status   = p_status;
    RETURN l_cur;
  END open_order_cursor;

  PROCEDURE claim_next_pick(p_store_id IN NUMBER, p_order_id OUT NUMBER) IS
    -- MIGRATION NOTE (T-12): FOR UPDATE SKIP LOCKED exists in both dialects with the
    -- same spelling, so this looks like a clean conversion. The behaviour under
    -- contention is not identical -- the two engines skip different numbers of rows when
    -- many pickers poll at once, so queue fairness and throughput change even though the
    -- SQL text does not. Load-test the queue, do not diff the syntax.
    CURSOR c_next IS
      SELECT order_id
        FROM sales_order
       WHERE store_id = p_store_id
         AND status   = 'PLACED'
       ORDER BY order_ts
         FOR UPDATE SKIP LOCKED;
    l_order_id NUMBER;
  BEGIN
    OPEN c_next;
    FETCH c_next INTO l_order_id;
    IF c_next%NOTFOUND THEN
      l_order_id := NULL;
    ELSE
      UPDATE sales_order SET status = 'PICKING' WHERE order_id = l_order_id;
    END IF;
    CLOSE c_next;
    p_order_id := l_order_id;
  EXCEPTION
    WHEN OTHERS THEN
      IF c_next%ISOPEN THEN
        CLOSE c_next;
      END IF;
      pkg_error.log_and_reraise('PKG_FULFILMENT', 'CLAIM_NEXT_PICK',
                                'store=' || p_store_id);
  END claim_next_pick;

  PROCEDURE allocate_order(p_order_id IN NUMBER, p_allocated OUT NUMBER) IS
  BEGIN
    UPDATE sales_order_line sol
       SET sol.fulfil_location_id =
             (SELECT MIN(ist.location_id)
                FROM inventory_stock    ist
                JOIN inventory_location il ON il.location_id = ist.location_id
               WHERE ist.variant_id    = sol.variant_id
                 AND ist.qty_available >= sol.qty
                 AND il.location_type IN ('PICKFACE', 'SHELF', 'BULK'))
     WHERE sol.order_id = p_order_id
       AND sol.fulfil_location_id IS NULL;

    p_allocated := SQL%ROWCOUNT;

    UPDATE sales_order_line
       SET status = 'ALLOCATED'
     WHERE order_id = p_order_id
       AND fulfil_location_id IS NOT NULL;
  END allocate_order;

  PROCEDURE create_shipment(p_order_id     IN  NUMBER,
                            p_carrier_code IN  VARCHAR2,
                            p_service      IN  VARCHAR2 DEFAULT 'STANDARD',
                            p_shipment_id  OUT NUMBER) IS
    l_shipment_id NUMBER;
    l_line_no     PLS_INTEGER := 0;
  BEGIN
    l_shipment_id := pkg_utils.next_id('SEQ_SHIPMENT_ID');

    INSERT INTO shipment (shipment_id, order_id, carrier_code, service_level,
                          tracking_ref, shipped_ts, status)
    VALUES (l_shipment_id, p_order_id, p_carrier_code, p_service,
            'TRK' || LPAD(TO_CHAR(l_shipment_id), 12, '0'),
            SYSTIMESTAMP, 'SHIPPED');

    FOR r IN (SELECT line_no, qty FROM sales_order_line WHERE order_id = p_order_id) LOOP
      l_line_no := l_line_no + 1;
      INSERT INTO shipment_line (shipment_id, line_no, order_id, order_line_no,
                                 qty_shipped)
      VALUES (l_shipment_id, l_line_no, p_order_id, r.line_no, r.qty);
    END LOOP;

    UPDATE sales_order SET status = 'SHIPPED' WHERE order_id = p_order_id;

    pkg_audit.write_audit('SHIPMENT', TO_CHAR(l_shipment_id), 'I');
    p_shipment_id := l_shipment_id;
  END create_shipment;

END pkg_fulfilment;
/

-- =====================================================================================
-- BODY 10 : pkg_loyalty
-- =====================================================================================
CREATE OR REPLACE PACKAGE BODY pkg_loyalty AS

  PROCEDURE accrue_points(p_loyalty_id IN NUMBER,
                          p_order_id   IN NUMBER,
                          p_amount     IN NUMBER,
                          p_points     OUT NUMBER) IS
    l_multiplier NUMBER;
    l_status     loyalty_account.status%TYPE;
  BEGIN
    SELECT la.status, NVL(lt.points_multiplier, 1)
      INTO l_status, l_multiplier
      FROM loyalty_account la
      JOIN loyalty_tier    lt ON lt.tier_code = la.tier_code
     WHERE la.loyalty_id = p_loyalty_id;

    IF l_status <> 'ACTIVE' THEN
      RAISE_APPLICATION_ERROR(-20702, 'Loyalty account ' || p_loyalty_id
                                      || ' is ' || l_status);
    END IF;

    p_points := FLOOR(NVL(p_amount, 0) * l_multiplier);

    -- loyalty_transaction is LIST-partitioned on txn_type, which converts cleanly to
    -- PostgreSQL declarative list partitioning (H-20). Note order_id is a *soft*
    -- reference with no foreign key, because the parent is interval-partitioned -- a
    -- deliberate modelling compromise documented in docs/design.md section 5F.
    INSERT INTO loyalty_transaction (loyalty_txn_id, txn_type, loyalty_id, points_delta,
                                     order_id, reason_code, txn_ts, expires_on,
                                     created_by)
    VALUES (pkg_utils.next_id('SEQ_LOYALTY_TXN_ID'), 'ACCRUE', p_loyalty_id, p_points,
            p_order_id, 'ORDER_ACCRUAL', SYSTIMESTAMP, ADD_MONTHS(TRUNC(SYSDATE), 24),
            SYS_CONTEXT('USERENV', 'SESSION_USER'));

    UPDATE loyalty_account
       SET points_balance  = points_balance + p_points
         , lifetime_points = NVL(lifetime_points, 0) + p_points
     WHERE loyalty_id = p_loyalty_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20703, 'Unknown loyalty account ' || p_loyalty_id);
  END accrue_points;

  PROCEDURE redeem_points(p_loyalty_id IN NUMBER,
                          p_points     IN NUMBER,
                          p_order_id   IN NUMBER DEFAULT NULL) IS
    l_balance NUMBER;
  BEGIN
    SELECT points_balance INTO l_balance
      FROM loyalty_account WHERE loyalty_id = p_loyalty_id FOR UPDATE;

    IF l_balance < p_points THEN
      RAISE_APPLICATION_ERROR(-20701,
        'Insufficient points: balance ' || l_balance || ', requested ' || p_points);
    END IF;

    INSERT INTO loyalty_transaction (loyalty_txn_id, txn_type, loyalty_id, points_delta,
                                     order_id, reason_code, txn_ts, created_by)
    VALUES (pkg_utils.next_id('SEQ_LOYALTY_TXN_ID'), 'REDEEM', p_loyalty_id, -p_points,
            p_order_id, 'REDEMPTION', SYSTIMESTAMP,
            SYS_CONTEXT('USERENV', 'SESSION_USER'));

    UPDATE loyalty_account
       SET points_balance = points_balance - p_points
     WHERE loyalty_id = p_loyalty_id;
  END redeem_points;

  PROCEDURE expire_points(p_as_of IN DATE DEFAULT TRUNC(SYSDATE), p_expired OUT NUMBER) IS
    l_count NUMBER := 0;
  BEGIN
    FOR r IN (SELECT ltx.loyalty_id, SUM(ltx.points_delta) AS points
                FROM loyalty_transaction ltx
               WHERE ltx.txn_type   = 'ACCRUE'
                 AND ltx.expires_on IS NOT NULL
                 AND ltx.expires_on < p_as_of
               GROUP BY ltx.loyalty_id
              HAVING SUM(ltx.points_delta) > 0) LOOP

      INSERT INTO loyalty_transaction (loyalty_txn_id, txn_type, loyalty_id,
                                       points_delta, reason_code, txn_ts, created_by)
      VALUES (pkg_utils.next_id('SEQ_LOYALTY_TXN_ID'), 'EXPIRE', r.loyalty_id,
              -r.points, 'AGE_EXPIRY', SYSTIMESTAMP, 'BATCH');

      UPDATE loyalty_account
         SET points_balance = GREATEST(points_balance - r.points, 0)
       WHERE loyalty_id = r.loyalty_id;

      l_count := l_count + 1;
    END LOOP;

    p_expired := l_count;
    DBMS_OUTPUT.PUT_LINE('pkg_loyalty.expire_points: ' || l_count || ' accounts aged');
  END expire_points;

  -- MIGRATION NOTE (H-07): MERGE with a WHERE clause on the UPDATE branch, so only
  -- accounts whose tier actually changed are touched. PostgreSQL 15's MERGE spells that
  -- differently (the condition goes on the WHEN, not after the SET) and a converter that
  -- drops it turns a targeted update into a full-table rewrite -- correct results, very
  -- different I/O, and every row's audit trigger fires.
  PROCEDURE review_tiers(p_reviewed OUT NUMBER) IS
  BEGIN
    MERGE INTO loyalty_account tgt
    USING (SELECT loyalty_id
                , points_balance
                , tier_for_points(points_balance) AS new_tier
             FROM loyalty_account
            WHERE status = 'ACTIVE') src
       ON (tgt.loyalty_id = src.loyalty_id)
    WHEN MATCHED THEN
      UPDATE SET tier_code          = src.new_tier
               , tier_reviewed_date = TRUNC(SYSDATE)
            WHERE tgt.tier_code <> src.new_tier;

    p_reviewed := SQL%ROWCOUNT;
  END review_tiers;

  -- MIGRATION NOTE (H-23): DETERMINISTIC and it reads loyalty_tier. docs/design.md calls
  -- this one out by name: it must become STABLE on PostgreSQL, never IMMUTABLE. A
  -- converter that maps DETERMINISTIC -> IMMUTABLE mechanically produces a function the
  -- planner constant-folds, so a tier threshold change stops taking effect until the
  -- next hard parse. That is a real bug, introduced silently, by a correct-looking rule.
  FUNCTION tier_for_points(p_points IN NUMBER) RETURN VARCHAR2 DETERMINISTIC IS
    l_tier loyalty_tier.tier_code%TYPE;
  BEGIN
    SELECT tier_code
      INTO l_tier
      FROM (SELECT tier_code
              FROM loyalty_tier
             WHERE min_points <= NVL(p_points, 0)
             ORDER BY min_points DESC)
     WHERE ROWNUM = 1;
    RETURN l_tier;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END tier_for_points;

  FUNCTION active_benefits(p_tier_code IN VARCHAR2,
                           p_on_date   IN DATE DEFAULT SYSDATE) RETURN t_benefit_tab IS
    l_all t_benefit_tab;
    l_out t_benefit_tab := t_benefit_tab();
  BEGIN
    SELECT benefits INTO l_all FROM loyalty_tier WHERE tier_code = p_tier_code;

    IF l_all IS NULL THEN
      RETURN l_out;
    END IF;

    FOR i IN 1 .. l_all.COUNT LOOP
      -- The member function call is the H-03 problem in miniature: PostgreSQL composite
      -- types have no methods, so is_active becomes a standalone function and this loop
      -- becomes a query over unnest(). Neither is hard; both are rewrites.
      IF l_all(i).is_active(p_on_date) = 'Y' THEN
        l_out.EXTEND;
        l_out(l_out.LAST) := l_all(i);
      END IF;
    END LOOP;
    RETURN l_out;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN l_out;
  END active_benefits;

  FUNCTION channels_allowed(p_channels IN t_channel_varr) RETURN VARCHAR2 IS
    l_out VARCHAR2(4000);
  BEGIN
    IF p_channels IS NULL THEN
      RETURN NULL;
    END IF;

    -- MIGRATION NOTE (H-04): .COUNT, .LIMIT and 1-based dense indexing. PostgreSQL
    -- arrays are 1-based by default but not required to be, have no declared maximum,
    -- and use array_length() rather than .COUNT. Rewrite the loop; do not transliterate.
    FOR i IN 1 .. p_channels.COUNT LOOP
      l_out := l_out || CASE WHEN i > 1 THEN ',' END || p_channels(i);
    END LOOP;

    RETURN l_out || ' (max ' || p_channels.LIMIT || ')';
  END channels_allowed;

END pkg_loyalty;
/

-- =====================================================================================
-- BODY 11 : pkg_purchasing
-- =====================================================================================
CREATE OR REPLACE PACKAGE BODY pkg_purchasing AS

  PROCEDURE create_po(p_supplier_id  IN  NUMBER,
                      p_warehouse_id IN  NUMBER,
                      p_order_date   IN  DATE DEFAULT SYSDATE,
                      p_po_id        OUT NUMBER) IS
    l_po_id    NUMBER;
    l_approved supplier.is_approved%TYPE;
    l_ccy      supplier.currency_code%TYPE;
  BEGIN
    SELECT is_approved, currency_code
      INTO l_approved, l_ccy
      FROM supplier WHERE supplier_id = p_supplier_id;

    IF l_approved <> 'Y' THEN
      RAISE_APPLICATION_ERROR(-20203,
        'Supplier ' || p_supplier_id || ' is not approved for purchasing');
    END IF;

    l_po_id := pkg_utils.next_id('SEQ_PO_ID');

    -- created_by is omitted so the column DEFAULT -- SYS_CONTEXT('USERENV',
    -- 'SESSION_USER') -- populates it. See H-39.
    INSERT INTO purchase_order (po_id, po_number, supplier_id, warehouse_id,
                                order_date, expected_date, status, currency_code,
                                order_total)
    VALUES (l_po_id, 'PO' || LPAD(TO_CHAR(l_po_id), 12, '0'), p_supplier_id,
            p_warehouse_id, p_order_date, p_order_date + 14, 'DRAFT', l_ccy, 0);

    pkg_audit.write_audit('PURCHASE_ORDER', TO_CHAR(l_po_id), 'I');
    p_po_id := l_po_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20204, 'Unknown supplier ' || p_supplier_id);
  END create_po;

  PROCEDURE add_po_line(p_po_id      IN NUMBER,
                        p_variant_id IN NUMBER,
                        p_qty        IN NUMBER,
                        p_unit_cost  IN NUMBER DEFAULT NULL) IS
    l_line_no NUMBER;
    l_cost    NUMBER := p_unit_cost;
  BEGIN
    SELECT NVL(MAX(line_no), 0) + 1 INTO l_line_no
      FROM purchase_order_line WHERE po_id = p_po_id;

    IF l_cost IS NULL THEN
      BEGIN
        SELECT sp.unit_cost
          INTO l_cost
          FROM supplier_product sp
          JOIN purchase_order   po ON po.supplier_id = sp.supplier_id
         WHERE po.po_id      = p_po_id
           AND sp.variant_id = p_variant_id
           AND sp.is_primary_source = 'Y'
           AND ROWNUM = 1;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN l_cost := 0;
      END;
    END IF;

    -- line_total is a virtual column: never in the column list.
    INSERT INTO purchase_order_line (po_id, line_no, variant_id, qty_ordered,
                                     qty_received, unit_cost, status)
    VALUES (p_po_id, l_line_no, p_variant_id, p_qty, 0, l_cost, 'OPEN');

    UPDATE purchase_order SET order_total = po_total(p_po_id) WHERE po_id = p_po_id;
  END add_po_line;

  PROCEDURE approve_po(p_po_id IN NUMBER, p_employee_id IN NUMBER) IS
    l_status purchase_order.status%TYPE;
  BEGIN
    SELECT status INTO l_status FROM purchase_order WHERE po_id = p_po_id FOR UPDATE;

    IF l_status <> 'DRAFT' THEN
      RAISE_APPLICATION_ERROR(-20201,
        'Purchase order ' || p_po_id || ' has already left DRAFT (status ' || l_status
        || ')');
    END IF;

    UPDATE purchase_order
       SET approved_by_employee_id = p_employee_id
     WHERE po_id = p_po_id;

    pkg_audit.write_audit('PURCHASE_ORDER', TO_CHAR(p_po_id), 'U',
                          'approved_by=NULL', 'approved_by=' || p_employee_id);
  END approve_po;

  PROCEDURE send_po(p_po_id IN NUMBER) IS
    l_status   purchase_order.status%TYPE;
    l_approver purchase_order.approved_by_employee_id%TYPE;
  BEGIN
    SELECT status, approved_by_employee_id
      INTO l_status, l_approver
      FROM purchase_order WHERE po_id = p_po_id FOR UPDATE;

    IF l_status = 'SENT' THEN
      RAISE_APPLICATION_ERROR(-20201, 'Purchase order ' || p_po_id || ' already sent');
    END IF;

    IF l_approver IS NULL THEN
      RAISE_APPLICATION_ERROR(-20202,
        'Purchase order ' || p_po_id || ' is not approved');
    END IF;

    UPDATE purchase_order SET status = 'SENT' WHERE po_id = p_po_id;
    pkg_audit.write_audit('PURCHASE_ORDER', TO_CHAR(p_po_id), 'U',
                          'status=' || l_status, 'status=SENT');
  END send_po;

  PROCEDURE cancel_po(p_po_id IN NUMBER, p_reason IN VARCHAR2 DEFAULT 'BUYER_CANCEL') IS
  BEGIN
    UPDATE purchase_order
       SET status = 'CANCELLED'
     WHERE po_id = p_po_id
       AND status IN ('DRAFT', 'SENT');

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20205,
        'Purchase order ' || p_po_id || ' cannot be cancelled in its current status');
    END IF;

    UPDATE purchase_order_line SET status = 'CANCELLED' WHERE po_id = p_po_id;
    pkg_audit.write_audit('PURCHASE_ORDER', TO_CHAR(p_po_id), 'U',
                          'status=OPEN', 'status=CANCELLED reason=' || p_reason);
  END cancel_po;

  -- MIGRATION NOTE (H-11): dynamic DDL. Three separate conversion problems live in these
  -- four lines. (1) The identifier is concatenated, so on PostgreSQL it must go through
  -- format('%I') or quote_ident. (2) Oracle issues an implicit COMMIT either side of
  -- DDL, so the caller's transaction is already durable when this runs; PL/pgSQL runs
  -- DDL inside the caller's transaction and a later failure rolls it back. (3) ALTER
  -- INDEX ... REBUILD has no direct PostgreSQL equivalent -- REINDEX INDEX is close, and
  -- REINDEX CONCURRENTLY is what you actually want in production.
  PROCEDURE rebuild_index(p_index_name IN VARCHAR2) IS
    l_ddl VARCHAR2(400);
  BEGIN
    IF NOT REGEXP_LIKE(p_index_name, '^[A-Za-z][A-Za-z0-9_$#]{0,127}$') THEN
      RAISE_APPLICATION_ERROR(-20206, 'Illegal index name: ' || p_index_name);
    END IF;

    l_ddl := 'ALTER INDEX ' || p_index_name || ' REBUILD ONLINE';
    DBMS_OUTPUT.PUT_LINE('pkg_purchasing.rebuild_index: ' || l_ddl);
    EXECUTE IMMEDIATE l_ddl;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = -20206 THEN
        RAISE;
      END IF;
      pkg_error.log_error('PKG_PURCHASING', 'REBUILD_INDEX', p_index_name);
  END rebuild_index;

  FUNCTION po_total(p_po_id IN NUMBER) RETURN NUMBER IS
    l_total NUMBER;
  BEGIN
    SELECT NVL(SUM(line_total), 0) INTO l_total
      FROM purchase_order_line
     WHERE po_id = p_po_id
       AND NVL(status, 'OPEN') <> 'CANCELLED';
    RETURN l_total;
  END po_total;

END pkg_purchasing;
/

-- =====================================================================================
-- BODY 12 : pkg_reporting
-- =====================================================================================
CREATE OR REPLACE PACKAGE BODY pkg_reporting AS

  FUNCTION busy_store_ids(p_from       IN DATE,
                          p_to         IN DATE,
                          p_min_orders IN NUMBER DEFAULT 1) RETURN t_number_tab PIPELINED IS
  BEGIN
    FOR r IN (SELECT so.store_id, COUNT(DISTINCT so.order_id) AS order_count
                FROM sales_order so
               WHERE CAST(so.order_ts AS DATE) >= p_from
                 AND CAST(so.order_ts AS DATE) <  p_to + 1
               GROUP BY so.store_id
              HAVING COUNT(DISTINCT so.order_id) >= p_min_orders
               ORDER BY COUNT(DISTINCT so.order_id) DESC) LOOP
      -- PIPE ROW hands this value to the consumer immediately. RETURN NEXT would not.
      PIPE ROW (r.store_id);
    END LOOP;
    RETURN;
  END busy_store_ids;

  FUNCTION store_day_summary(p_from IN DATE, p_to IN DATE) RETURN t_store_day_tab IS
    l_out t_store_day_tab := t_store_day_tab();
    l_rec t_store_day_rec;
  BEGIN
    -- MIGRATION NOTE (H-08): RANK() OVER as a projected column. Converts one-for-one.
    -- The NULLS LAST is deliberate (T-13): Oracle and PostgreSQL agree on ascending
    -- placement and disagree on descending, so leaving it implicit reorders the report.
    FOR r IN (SELECT so.store_id
                   , s.store_code
                   , TRUNC(CAST(so.order_ts AS DATE))          AS sales_date
                   , COUNT(DISTINCT so.order_id)               AS order_count
                   , SUM(so.subtotal_amount)                   AS net_amount
                   , RANK() OVER (PARTITION BY TRUNC(CAST(so.order_ts AS DATE))
                                  ORDER BY SUM(so.subtotal_amount) DESC NULLS LAST)
                                                               AS day_rank
                FROM sales_order so
                JOIN store       s ON s.store_id = so.store_id
               WHERE CAST(so.order_ts AS DATE) >= p_from
                 AND CAST(so.order_ts AS DATE) <  p_to + 1
               GROUP BY so.store_id, s.store_code, TRUNC(CAST(so.order_ts AS DATE)))
    LOOP
      l_rec.store_id    := r.store_id;
      l_rec.store_code  := r.store_code;
      l_rec.sales_date  := r.sales_date;
      l_rec.order_count := r.order_count;
      l_rec.net_amount  := r.net_amount;
      l_rec.day_rank    := r.day_rank;

      l_out.EXTEND;
      l_out(l_out.LAST) := l_rec;
    END LOOP;
    RETURN l_out;
  END store_day_summary;

  FUNCTION open_sales_cursor(p_from IN DATE, p_to IN DATE) RETURN SYS_REFCURSOR IS
    l_cur SYS_REFCURSOR;
  BEGIN
    -- MIGRATION NOTE (H-08): three analytic forms that do NOT convert mechanically.
    --   RATIO_TO_REPORT           -> x / SUM(x) OVER (), with a new divide-by-zero risk.
    --   KEEP (DENSE_RANK LAST ..) -> LAST_VALUE with an explicit UNBOUNDED frame.
    --   NTH_VALUE ... FROM LAST   -> NTH_VALUE over a reversed ORDER BY.
    -- All three are here so the converter is actually asked the question.
    OPEN l_cur FOR
      SELECT so.store_id
           , s.store_code
           , so.channel_code
           , COUNT(DISTINCT so.order_id)                          AS order_count
           , SUM(so.subtotal_amount)                              AS net_amount
           , RATIO_TO_REPORT(SUM(so.subtotal_amount)) OVER ()      AS share_of_total
           , MAX(so.order_number) KEEP (DENSE_RANK LAST ORDER BY so.order_ts)
                                                                   AS last_order_number
           , NTH_VALUE(s.store_code, 2) FROM LAST
               OVER (ORDER BY SUM(so.subtotal_amount)
                     ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
                                                                   AS runner_up_store
        FROM sales_order so
        JOIN store       s ON s.store_id = so.store_id
       WHERE CAST(so.order_ts AS DATE) >= p_from
         AND CAST(so.order_ts AS DATE) <  p_to + 1
       GROUP BY so.store_id, s.store_code, so.channel_code
       ORDER BY net_amount DESC NULLS LAST;
    RETURN l_cur;
  END open_sales_cursor;

  FUNCTION open_category_rollup(p_root_category_id IN NUMBER) RETURN SYS_REFCURSOR IS
    l_cur SYS_REFCURSOR;
  BEGIN
    -- MIGRATION NOTE (H-06): a CONNECT BY roll-up returned through a cursor, so the
    -- WITH RECURSIVE rewrite has to happen inside a function whose result shape is
    -- already fixed. ORDER SIBLINGS BY needs a path array on the target.
    OPEN l_cur FOR
      SELECT pc.category_id
           , pc.category_code
           , pc.category_name
           , LEVEL                                        AS depth
           , SYS_CONNECT_BY_PATH(pc.category_code, '/')   AS path
           , CONNECT_BY_ROOT pc.category_code             AS root_code
           , CONNECT_BY_ISLEAF                            AS is_leaf
           , (SELECT COUNT(*) FROM product p
               WHERE p.category_id = pc.category_id)      AS product_count
        FROM product_category pc
       START WITH pc.category_id = p_root_category_id
      CONNECT BY NOCYCLE PRIOR pc.category_id = pc.parent_category_id
       ORDER SIBLINGS BY pc.sort_order, pc.category_code;
    RETURN l_cur;
  END open_category_rollup;

  FUNCTION legacy_customer_orders(p_country_code IN VARCHAR2) RETURN SYS_REFCURSOR IS
    l_cur SYS_REFCURSOR;
  BEGIN
    -- MIGRATION NOTE (H-32): Oracle (+) outer joins inside PL/SQL, where a reviewer
    -- skimming for view definitions will not find them. Note st.store_id(+) and
    -- e.employee_id(+) chain: the ANSI ordering is not the textual ordering, so store
    -- must be joined before employee. Verify converted row counts; do not eyeball it.
    OPEN l_cur FOR
      SELECT c.customer_id
           , c.customer_ref
           , c.last_name
           , so.order_id
           , so.order_number
           , st.store_code
           , e.employee_number
        FROM customer    c
           , sales_order so
           , store       st
           , employee    e
       WHERE c.customer_id        = so.customer_id(+)
         AND so.store_id          = st.store_id(+)
         AND so.sales_employee_id = e.employee_id(+)
         AND c.home_country_code  = p_country_code
       ORDER BY c.customer_id, so.order_id NULLS FIRST;
    RETURN l_cur;
  END legacy_customer_orders;

  PROCEDURE print_top_stores(p_limit IN PLS_INTEGER DEFAULT 10) IS
    l_rows t_store_day_tab;
  BEGIN
    l_rows := store_day_summary(TRUNC(SYSDATE) - 30, TRUNC(SYSDATE));

    DBMS_OUTPUT.PUT_LINE('Top stores, last 30 days');
    DBMS_OUTPUT.PUT_LINE('------------------------');

    FOR i IN 1 .. LEAST(l_rows.COUNT, p_limit) LOOP
      DBMS_OUTPUT.PUT_LINE(
        RPAD(NVL(l_rows(i).store_code, '?'), 14)
        || ' ' || pkg_utils.to_display(l_rows(i).sales_date)
        || ' ' || LPAD(TO_CHAR(NVL(l_rows(i).order_count, 0)), 6)
        || ' ' || pkg_utils.to_display(l_rows(i).net_amount));
    END LOOP;
  END print_top_stores;

END pkg_reporting;
/

-- =====================================================================================
-- BODY 13 : pkg_etl_export
-- =====================================================================================
CREATE OR REPLACE PACKAGE BODY pkg_etl_export AS

  PROCEDURE write_sales_extract(p_from IN DATE, p_to IN DATE, p_rows OUT NUMBER) IS
    l_file  UTL_FILE.FILE_TYPE;
    l_name  VARCHAR2(120);
    l_count NUMBER := 0;
  BEGIN
    l_name := 'contoso_sales_' || TO_CHAR(p_from, 'YYYYMMDD') || '_'
              || TO_CHAR(p_to, 'YYYYMMDD') || '.csv';

    -- MIGRATION NOTE (H-13): FOPEN against an Oracle DIRECTORY object. Azure Database
    -- for PostgreSQL flexible server has no server filesystem you can write to and no
    -- utl_file_dir equivalent. orafce ships a utl_file implementation, so a converter can
    -- emit calls that compile and then fail at runtime -- a clean report and a broken
    -- nightly job. The two honest targets are a client-driven COPY ... TO STDOUT, or an
    -- external job that reads the query and writes to Blob Storage.
    l_file := UTL_FILE.FOPEN(g_directory, l_name, 'W', 32767);

    UTL_FILE.PUT_LINE(l_file,
      'order_id,order_number,order_ts,store_code,channel,currency,net_amount');

    FOR r IN (SELECT so.order_id
                   , so.order_number
                   , so.order_ts
                   , s.store_code
                   , so.channel_code
                   , so.currency_code
                   , NVL(so.subtotal_amount, 0) - NVL(so.discount_amount, 0) AS net_amount
                FROM sales_order so
                JOIN store       s ON s.store_id = so.store_id
               WHERE CAST(so.order_ts AS DATE) >= p_from
                 AND CAST(so.order_ts AS DATE) <  p_to + 1
               ORDER BY so.order_id) LOOP

      UTL_FILE.PUT_LINE(l_file,
        r.order_id || ',' || r.order_number || ','
        -- MIGRATION NOTE (H-37): order_ts is TSLTZ. TO_CHAR renders it in the *session*
        -- time zone, so the same job run from two countries writes two different files
        -- from identical data. On PostgreSQL the session TimeZone GUC takes that role.
        -- Pin the zone explicitly in any extract that crosses a border.
        || TO_CHAR(r.order_ts, 'YYYY-MM-DD"T"HH24:MI:SS') || ','
        || r.store_code || ',' || r.channel_code || ',' || r.currency_code || ','
        || TO_CHAR(r.net_amount, 'FM99999999990.00'));

      l_count := l_count + 1;
    END LOOP;

    UTL_FILE.FCLOSE(l_file);
    p_rows := l_count;

    DBMS_OUTPUT.PUT_LINE('pkg_etl_export: wrote ' || l_count || ' rows to ' || l_name);
  EXCEPTION
    WHEN UTL_FILE.INVALID_PATH THEN
      p_rows := 0;
      RAISE_APPLICATION_ERROR(-20801,
        'Directory ' || g_directory || ' is not readable by CONTOSO. '
        || 'See sql/00-schema-setup.sql.');
    WHEN OTHERS THEN
      IF UTL_FILE.IS_OPEN(l_file) THEN
        UTL_FILE.FCLOSE(l_file);
      END IF;
      p_rows := 0;
      pkg_error.log_and_reraise('PKG_ETL_EXPORT', 'WRITE_SALES_EXTRACT', l_name);
  END write_sales_extract;

  -- MIGRATION NOTE (H-34): every DBMS_LOB call below operates through a *locator* -- a
  -- mutable handle into LOB storage. PostgreSQL text is a value: you cannot open it,
  -- append through it, or hold a handle to it across statements. CREATETEMPORARY has no
  -- analogue (a local variable is the answer), WRITEAPPEND becomes ||, GETLENGTH becomes
  -- length(). The code converts; the *idiom* does not, and any routine that passed a
  -- locator between subprograms needs restructuring. Note also bytea's 1 GB ceiling
  -- versus BLOB's 128 TB, which is irrelevant here and occasionally is not.
  FUNCTION build_order_document(p_order_id IN NUMBER) RETURN CLOB IS
    l_doc     CLOB;
    l_chunk   VARCHAR2(32767);
    l_notes   CLOB;
    l_header  VARCHAR2(4000);
  BEGIN
    DBMS_LOB.CREATETEMPORARY(l_doc, TRUE, DBMS_LOB.CALL);

    SELECT 'ORDER ' || so.order_number || ' / ' || s.store_code
           || ' / ' || so.channel_code || CHR(10)
           || 'Placed: ' || TO_CHAR(so.order_ts, 'YYYY-MM-DD HH24:MI:SS') || CHR(10)
           || 'Status: ' || so.status || CHR(10)
           || '----------------------------------------' || CHR(10)
      INTO l_header
      FROM sales_order so
      JOIN store       s ON s.store_id = so.store_id
     WHERE so.order_id = p_order_id;

    DBMS_LOB.WRITEAPPEND(l_doc, LENGTH(l_header), l_header);

    FOR r IN (SELECT sol.line_no, pv.variant_sku, p.product_name,
                     sol.qty, sol.unit_price, sol.line_total
                FROM sales_order_line sol
                JOIN product_variant  pv ON pv.variant_id = sol.variant_id
                JOIN product          p  ON p.product_id  = pv.product_id
               WHERE sol.order_id = p_order_id
               ORDER BY sol.line_no) LOOP

      l_chunk := LPAD(TO_CHAR(r.line_no), 4) || '  '
                 || RPAD(SUBSTR(r.variant_sku, 1, 20), 22)
                 || RPAD(SUBSTR(r.product_name, 1, 40), 42)
                 || LPAD(TO_CHAR(r.qty, 'FM99990.000'), 12)
                 || LPAD(TO_CHAR(r.unit_price, 'FM999990.0000'), 14)
                 || LPAD(TO_CHAR(r.line_total, 'FM9999990.00'), 14)
                 || CHR(10);

      IF l_chunk IS NOT NULL THEN
        DBMS_LOB.WRITEAPPEND(l_doc, LENGTH(l_chunk), l_chunk);
      END IF;
    END LOOP;

    -- Appending one LOB onto another: the operation that has no value-semantics
    -- equivalent, because both operands are handles.
    l_notes := TO_CLOB('-- generated ' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS')
                       || ' by ' || SYS_CONTEXT('USERENV', 'SESSION_USER') || CHR(10));
    DBMS_LOB.APPEND(l_doc, l_notes);

    DBMS_OUTPUT.PUT_LINE('build_order_document: '
                         || DBMS_LOB.GETLENGTH(l_doc) || ' characters');
    RETURN l_doc;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN TO_CLOB('ORDER ' || p_order_id || ' NOT FOUND');
  END build_order_document;

  PROCEDURE dump_to_output(p_text IN CLOB) IS
    l_len    INTEGER;
    l_offset INTEGER := 1;
    l_step   CONSTANT INTEGER := 200;
  BEGIN
    IF p_text IS NULL THEN
      DBMS_OUTPUT.PUT_LINE('(empty document)');
      RETURN;
    END IF;

    l_len := DBMS_LOB.GETLENGTH(p_text);

    -- MIGRATION NOTE (H-12): DBMS_OUTPUT.PUT_LINE has a per-line limit of 32767 bytes
    -- and, historically, a total buffer limit that made chunking mandatory. RAISE NOTICE
    -- has neither, so the chunking loop becomes pointless -- but harmless. Leave it or
    -- remove it; just do not let it be *half* removed, which produces overlapping output.
    WHILE l_offset <= l_len LOOP
      DBMS_OUTPUT.PUT_LINE(DBMS_LOB.SUBSTR(p_text, l_step, l_offset));
      l_offset := l_offset + l_step;
    END LOOP;
  END dump_to_output;

END pkg_etl_export;
/


-- =====================================================================================
-- Summary
-- =====================================================================================
DECLARE
  l_spec    PLS_INTEGER;
  l_body    PLS_INTEGER;
  l_invalid PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_spec
    FROM user_objects
   WHERE object_type = 'PACKAGE' AND object_name NOT LIKE 'PKG_GEN%';

  SELECT COUNT(*) INTO l_body
    FROM user_objects
   WHERE object_type = 'PACKAGE BODY' AND object_name NOT LIKE 'PKG_GEN%';

  SELECT COUNT(*) INTO l_invalid
    FROM user_objects
   WHERE object_type IN ('PACKAGE', 'PACKAGE BODY') AND status = 'INVALID';

  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------------');
  DBMS_OUTPUT.PUT_LINE('07-packages.sql summary');
  DBMS_OUTPUT.PUT_LINE('  package specs   : ' || l_spec);
  DBMS_OUTPUT.PUT_LINE('  package bodies  : ' || l_body);
  DBMS_OUTPUT.PUT_LINE('  INVALID         : ' || l_invalid || ' (must be 0)');
  DBMS_OUTPUT.PUT_LINE('--------------------------------------------------------------');
END;
/

PROMPT 07-packages.sql complete.





-- =====================================================================================
-- SPEC 14 : pkg_finance_gl -- posts journals to the general ledger
-- =====================================================================================
-- Owner        : CONTOSO
-- Depends on   : gl_account, gl_period, gl_journal, gl_journal_line (02-tables.sql),
--                seq_journal_id (05-sequences.sql), pkg_audit, pkg_error, t_number_tab
-- Exercises    : H-02 PRAGMA AUTONOMOUS_TRANSACTION, T-11 INSERT ALL, H-30 ROWNUM,
--                H-28 user-defined exception + RAISE_APPLICATION_ERROR, H-01 overloading.
--
-- Design contract: docs/design.md section 6.2 (package 15) and the hard-case tables
-- (H-02 line 806, H-28 line 1112, H-30 line 1135, T-11 line 1344).
-- =====================================================================================
CREATE OR REPLACE PACKAGE pkg_finance_gl AS

  -- MIGRATION NOTE (H-28): a user-defined exception bound to an application error number
  -- with PRAGMA EXCEPTION_INIT. Callers switch on SQLCODE = -20950. PostgreSQL raises a
  -- five-character SQLSTATE instead, so the number has no home -- the raise becomes
  --   RAISE EXCEPTION '...' USING ERRCODE = 'GL950';
  -- and every WHEN clause that tested this number, here and in callers outside this repo,
  -- has to move to the mapped SQLSTATE. The Oracle-number-to-SQLSTATE table is a project
  -- deliverable, not an implementation detail (see docs/03-run-ai-migration.md).
  e_period_closed EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_period_closed, -20950);

  e_unbalanced_journal EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_unbalanced_journal, -20951);

  e_unknown_period EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_unknown_period, -20952);

  -- One leg of a double-entry posting. A schema-level nested table would be the SQL-usable
  -- form; this record is PL/SQL-local because the legs are only ever passed between the
  -- overloads below, never named in a SQL statement.
  TYPE t_leg IS RECORD (
    account_code   VARCHAR2(20),
    store_id       NUMBER,
    cost_centre    VARCHAR2(20),
    amount         NUMBER,          -- always >= 0; the debit/credit side is positional
    currency_code  VARCHAR2(3),
    fx_rate        NUMBER,
    description    VARCHAR2(300));

  -- MIGRATION NOTE (H-01): two overloads of post_journal. Oracle resolves the call by
  -- argument shape -- the scalar form (two account codes and an amount) versus the record
  -- form (two t_leg records). PostgreSQL supports overloading too, but t_leg becomes a
  -- composite type and the scalar overload's untyped literals (the VARCHAR2 account codes
  -- against a NUMBER amount) are exactly the pair that can make a call ambiguous where
  -- Oracle resolved it by conversion rank. Expect explicit casts at some call sites.
  PROCEDURE post_journal(p_period_id      IN  NUMBER,
                         p_source_module  IN  VARCHAR2,
                         p_journal_date   IN  DATE,
                         p_description    IN  VARCHAR2,
                         p_debit_account  IN  VARCHAR2,
                         p_credit_account IN  VARCHAR2,
                         p_amount         IN  NUMBER,
                         p_currency_code  IN  VARCHAR2 DEFAULT 'USD',
                         p_store_id       IN  NUMBER   DEFAULT NULL,
                         p_journal_id     OUT NUMBER);

  PROCEDURE post_journal(p_period_id      IN  NUMBER,
                         p_source_module  IN  VARCHAR2,
                         p_journal_date   IN  DATE,
                         p_description    IN  VARCHAR2,
                         p_debit_leg      IN  t_leg,
                         p_credit_leg     IN  t_leg,
                         p_journal_id     OUT NUMBER);

  -- MIGRATION NOTE (H-02): post_control_total carries PRAGMA AUTONOMOUS_TRANSACTION in the
  -- body, so the control-total row it writes is committed in a nested, independent
  -- transaction and survives a rollback of the caller. PostgreSQL has no autonomous
  -- transactions: the honest options are a dblink self-connection or accepting that the
  -- control total rolls back with the posting it was meant to reconcile -- which defeats
  -- its purpose. This is one of the three program units the lab requires to carry the
  -- pragma (with pkg_audit and pkg_error); see docs/design.md H-02.
  PROCEDURE post_control_total(p_journal_ref  IN VARCHAR2,
                               p_debit_total  IN NUMBER,
                               p_credit_total IN NUMBER,
                               p_line_count   IN NUMBER);

  -- MIGRATION NOTE (H-30): next_batch selects a batch of unposted journals with the
  -- UNWRAPPED  ROWNUM <= :n  form -- the ROWNUM predicate is applied *before* the ORDER BY,
  -- so this returns an arbitrary p_limit rows and then sorts them. The naive PostgreSQL
  -- conversion  ORDER BY ... LIMIT :n  returns the *top* p_limit rows, a different result
  -- set. Contrast pkg_pricing.pick_winning_price, which wraps the ORDER BY in an inline
  -- view before applying ROWNUM and therefore does convert to FETCH FIRST cleanly. Both
  -- forms are in the schema on purpose.
  FUNCTION next_batch(p_limit IN PLS_INTEGER DEFAULT 50) RETURN t_number_tab;

END pkg_finance_gl;
/

-- =====================================================================================
-- BODY 14 : pkg_finance_gl
-- =====================================================================================
CREATE OR REPLACE PACKAGE BODY pkg_finance_gl AS

  -- Private helper: the journal_ref is unique and derived from the source module and id.
  FUNCTION make_ref(p_source_module IN VARCHAR2, p_journal_id IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN SUBSTR(UPPER(p_source_module), 1, 3) || '-' || TO_CHAR(p_journal_id);
  END make_ref;

  -- Private helper: refuse a closed period by RAISEing the named exception. Kept separate
  -- so both overloads share one gate.
  PROCEDURE assert_period_open(p_period_id IN NUMBER) IS
    l_status gl_period.status%TYPE;
  BEGIN
    SELECT status INTO l_status FROM gl_period WHERE period_id = p_period_id;
    IF l_status = 'CLOSED' THEN
      RAISE e_period_closed;                       -- bound to -20950 in the spec
    END IF;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20952, 'Unknown GL period: ' || p_period_id);
  END assert_period_open;

  -- The record form is the real worker. It carries the INSERT ALL.
  PROCEDURE post_journal(p_period_id      IN  NUMBER,
                         p_source_module  IN  VARCHAR2,
                         p_journal_date   IN  DATE,
                         p_description    IN  VARCHAR2,
                         p_debit_leg      IN  t_leg,
                         p_credit_leg     IN  t_leg,
                         p_journal_id     OUT NUMBER) IS
    l_base NUMBER;
    l_jid  NUMBER;
    l_ref  gl_journal.journal_ref%TYPE;
  BEGIN
    -- H-28: this RAISEs e_period_closed, which the handler below turns into -20950.
    assert_period_open(p_period_id);

    IF NVL(p_debit_leg.amount, -1) < 0 OR NVL(p_credit_leg.amount, -1) < 0 THEN
      RAISE_APPLICATION_ERROR(-20951, 'Journal amounts must be non-negative');
    END IF;

    IF p_debit_leg.amount <> p_credit_leg.amount THEN
      RAISE e_unbalanced_journal;                  -- bound to -20951 in the spec
    END IF;

    -- The block-of-ten reservation described in 05-sequences.sql: one NEXTVAL yields a
    -- base (INCREMENT BY 10), and the journal and any adjacent control artefacts are
    -- handed out from that block locally, so they stay numerically close. INCREMENT BY 10
    -- converts literally to PostgreSQL; the shared-vs-per-session cache behaviour does not.
    l_base := seq_journal_id.NEXTVAL;
    l_jid  := l_base;
    l_ref  := make_ref(p_source_module, l_jid);

    INSERT INTO gl_journal (journal_id, journal_ref, period_id, source_module,
                            journal_date, description, posted_ts, posted_by, status)
    VALUES (l_jid, l_ref, p_period_id, p_source_module,
            p_journal_date, p_description, SYSTIMESTAMP,
            SUBSTR(SYS_CONTEXT('USERENV', 'SESSION_USER'), 1, 30), 'POSTED');

    -- MIGRATION NOTE (T-11): INSERT ALL writes both legs of the double entry in one
    -- statement. PostgreSQL has no INSERT ALL; the faithful conversion is a data-modifying
    -- CTE  ( WITH d AS (INSERT ... RETURNING ...) INSERT ... )  or two separate INSERTs in
    -- the function body. The trailing  SELECT 1 FROM dual  is the mandatory driving query
    -- of an unconditional INSERT ALL -- dual needs orafce, or drop the FROM clause. Note
    -- base_amount is a virtual column and so is absent from both column lists (H-17).
    INSERT ALL
      INTO gl_journal_line (journal_id, line_no, account_code, store_id, cost_centre,
                            debit_amount, credit_amount, currency_code, fx_rate,
                            line_description)
        VALUES (l_jid, 1, p_debit_leg.account_code, p_debit_leg.store_id,
                p_debit_leg.cost_centre, p_debit_leg.amount, 0,
                NVL(p_debit_leg.currency_code, 'USD'), NVL(p_debit_leg.fx_rate, 1),
                p_debit_leg.description)
      INTO gl_journal_line (journal_id, line_no, account_code, store_id, cost_centre,
                            debit_amount, credit_amount, currency_code, fx_rate,
                            line_description)
        VALUES (l_jid, 2, p_credit_leg.account_code, p_credit_leg.store_id,
                p_credit_leg.cost_centre, 0, p_credit_leg.amount,
                NVL(p_credit_leg.currency_code, 'USD'), NVL(p_credit_leg.fx_rate, 1),
                p_credit_leg.description)
    SELECT 1 FROM dual;

    -- H-02: record the control total autonomously, keyed by journal_ref. The autonomous
    -- transaction cannot see the caller's still-uncommitted gl_journal row, which is
    -- exactly why the total lives in an independent table rather than as a child line --
    -- and why it survives if the caller later rolls the posting back.
    post_control_total(l_ref, p_debit_leg.amount, p_credit_leg.amount, 2);

    pkg_audit.write_audit('GL_JOURNAL', TO_CHAR(l_jid), 'I');
    p_journal_id := l_jid;
  EXCEPTION
    WHEN e_period_closed THEN
      RAISE_APPLICATION_ERROR(-20950,
        'GL period ' || p_period_id || ' is closed; journal not posted');
    WHEN e_unbalanced_journal THEN
      RAISE_APPLICATION_ERROR(-20951,
        'Unbalanced journal: debit ' || p_debit_leg.amount
        || ' <> credit ' || p_credit_leg.amount);
  END post_journal;

  -- Scalar overload (H-01): the convenience form. Builds a balanced pair of legs and
  -- delegates to the record form, the way pkg_audit.write_audit shims onto its CLOB form.
  PROCEDURE post_journal(p_period_id      IN  NUMBER,
                         p_source_module  IN  VARCHAR2,
                         p_journal_date   IN  DATE,
                         p_description    IN  VARCHAR2,
                         p_debit_account  IN  VARCHAR2,
                         p_credit_account IN  VARCHAR2,
                         p_amount         IN  NUMBER,
                         p_currency_code  IN  VARCHAR2 DEFAULT 'USD',
                         p_store_id       IN  NUMBER   DEFAULT NULL,
                         p_journal_id     OUT NUMBER) IS
    l_dr t_leg;
    l_cr t_leg;
  BEGIN
    l_dr.account_code  := p_debit_account;
    l_dr.store_id      := p_store_id;
    l_dr.amount        := p_amount;
    l_dr.currency_code := p_currency_code;
    l_dr.fx_rate       := 1;
    l_dr.description    := p_description;

    l_cr.account_code  := p_credit_account;
    l_cr.store_id      := p_store_id;
    l_cr.amount        := p_amount;
    l_cr.currency_code := p_currency_code;
    l_cr.fx_rate       := 1;
    l_cr.description    := p_description;

    post_journal(p_period_id, p_source_module, p_journal_date, p_description,
                 l_dr, l_cr, p_journal_id);
  END post_journal;

  -- H-02: the autonomous unit. See the spec note.
  PROCEDURE post_control_total(p_journal_ref  IN VARCHAR2,
                               p_debit_total  IN NUMBER,
                               p_credit_total IN NUMBER,
                               p_line_count   IN NUMBER) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO audit_log (audit_id, table_name, pk_value, action_type, old_row, new_row)
    VALUES (seq_audit_id.NEXTVAL,
            'GL_CONTROL_TOTAL',
            SUBSTR(p_journal_ref, 1, 200),
            'I',
            NULL,
            TO_CLOB('DR=' || TO_CHAR(p_debit_total)
                    || ' CR=' || TO_CHAR(p_credit_total)
                    || ' LINES=' || TO_CHAR(p_line_count)));
    COMMIT;                                          -- commits the nested transaction only
  EXCEPTION
    WHEN OTHERS THEN
      -- A control-total failure must never take down the posting. Roll back only the
      -- autonomous unit of work, exactly as pkg_audit and pkg_error do.
      ROLLBACK;
  END post_control_total;

  -- H-30: the unwrapped ROWNUM batch selector. See the spec note.
  FUNCTION next_batch(p_limit IN PLS_INTEGER DEFAULT 50) RETURN t_number_tab IS
    l_ids t_number_tab;
  BEGIN
    SELECT journal_id
      BULK COLLECT INTO l_ids
      FROM gl_journal
     WHERE status = 'DRAFT'
       AND ROWNUM <= p_limit
     ORDER BY journal_date, journal_id;
    RETURN l_ids;
  END next_batch;

END pkg_finance_gl;
/
