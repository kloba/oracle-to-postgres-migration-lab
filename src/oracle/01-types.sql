--------------------------------------------------------------------------------
-- Contoso Store -- Oracle to Azure Database for PostgreSQL migration lab
-- 01-types.sql
--
-- Schema-level object types, VARRAYs and nested table types.
-- Runs as CONTOSO. Loads AFTER 00-user-tablespace.sql, BEFORE 02-tables.sql.
--
--   18 TYPE objects, 8 TYPE BODY objects (design.md section 6.1, budget 8).
--
-- Design note that matters for a clean load: this file runs before any table
-- exists, so no type body may reference a table at compile time or it would be
-- created INVALID and fail the section 12 assertion. t_money.converted_to needs
-- exchange_rate, so it reaches it through EXECUTE IMMEDIATE -- which is both the
-- only correct thing to do here and a free extra sample of hard case H-11.
--
-- Hard cases carried: H-03 (member methods, MAP/ORDER, inheritance),
-- H-04 (VARRAY), H-05 (nested tables), H-11 (dynamic SQL), H-31 (NVL/DECODE).
--------------------------------------------------------------------------------

SET SQLBLANKLINES ON
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

prompt
prompt ================================================================
prompt  01-types.sql : object types, VARRAYs, nested tables, bodies
prompt ================================================================

--------------------------------------------------------------------------------
-- Re-runnability. CREATE OR REPLACE TYPE raises ORA-02303 once another type or
-- table depends on the type being replaced, so a second run of this file would
-- fail on t_product_attr, t_loyalty_benefit and t_price_point. Drop the whole
-- set first, dependents included, swallowing ONLY ORA-04043 "object does not
-- exist". Any other error still aborts the load.
--------------------------------------------------------------------------------
DECLARE
  TYPE t_name_list IS TABLE OF VARCHAR2(30);

  -- Collections first, then element types, then the inheritance leaves, then
  -- the roots: reverse dependency order.
  l_types  t_name_list := t_name_list(
             'T_PRODUCT_ATTR_TAB', 'T_BENEFIT_TAB', 'T_PRICE_POINT_TAB',
             'T_NUMBER_TAB',       'T_VARCHAR_TAB',
             'T_CHANNEL_VARR',     'T_SIZE_RUN_VARR',
             'T_SERVICE_VARR',     'T_TAG_VARR',
             'T_CUSTOMER_PARTY',   'T_SUPPLIER_PARTY',  'T_PARTY',
             'T_PRODUCT_ATTR',     'T_LOYALTY_BENEFIT', 'T_PRICE_POINT',
             'T_POSTAL_ADDRESS',   'T_CONTACT',         'T_MONEY');

  e_type_missing EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_type_missing, -4043);

  l_dropped  PLS_INTEGER := 0;
BEGIN
  FOR i IN 1 .. l_types.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE 'DROP TYPE ' || l_types(i) || ' FORCE';
      l_dropped := l_dropped + 1;
    EXCEPTION
      WHEN e_type_missing THEN
        NULL;
    END;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('Pre-existing types dropped: ' || l_dropped);
END;
/

--------------------------------------------------------------------------------
-- 1. t_money -- amount plus currency, with a MAP method so two t_money values
--    can be compared and sorted, and a STATIC constructor for the zero value.
--
--    MAP MEMBER FUNCTION is the interesting one for the converter: PostgreSQL
--    composite types have no comparison contract, so ORDER BY over a t_money
--    column silently changes meaning (H-03).
--------------------------------------------------------------------------------
CREATE OR REPLACE TYPE t_money AS OBJECT (
  amount         NUMBER,
  currency_code  CHAR(3),

  MEMBER FUNCTION converted_to (p_to_currency IN CHAR,
                                p_on_date     IN DATE DEFAULT SYSDATE)
    RETURN t_money,

  MEMBER PROCEDURE add_amount (p_amount IN NUMBER),

  MAP MEMBER FUNCTION to_base RETURN NUMBER,

  STATIC FUNCTION zero (p_currency_code IN CHAR DEFAULT 'GBP') RETURN t_money
) NOT FINAL;
/

--------------------------------------------------------------------------------
-- 2. t_contact -- the object column type on supplier.primary_contact.
--------------------------------------------------------------------------------
CREATE OR REPLACE TYPE t_contact AS OBJECT (
  contact_name  VARCHAR2(120),
  email         VARCHAR2(150),
  phone         VARCHAR2(30),
  role_title    VARCHAR2(60),

  MEMBER FUNCTION display_label   RETURN VARCHAR2,
  MEMBER FUNCTION is_valid_email  RETURN VARCHAR2
);
/

--------------------------------------------------------------------------------
-- 3. t_postal_address -- carries an OVERLOADED member function (H-01), and
--    concatenation whose NULL behaviour shifts on the target (T-14 / H-38).
--------------------------------------------------------------------------------
CREATE OR REPLACE TYPE t_postal_address AS OBJECT (
  line1         VARCHAR2(120),
  line2         VARCHAR2(120),
  city          VARCHAR2(80),
  postal_code   VARCHAR2(20),
  country_code  CHAR(2),

  MEMBER FUNCTION format_label RETURN VARCHAR2,
  MEMBER FUNCTION format_label (p_style IN VARCHAR2) RETURN VARCHAR2
);
/

--------------------------------------------------------------------------------
-- 4. t_product_attr -- element type of product.attributes (nested table, H-05).
--------------------------------------------------------------------------------
CREATE OR REPLACE TYPE t_product_attr AS OBJECT (
  attr_name   VARCHAR2(60),
  attr_value  VARCHAR2(400),
  attr_uom    VARCHAR2(20),

  MEMBER FUNCTION as_number RETURN NUMBER
);
/

--------------------------------------------------------------------------------
-- 5. t_loyalty_benefit -- element type of loyalty_tier.benefits (H-05).
--------------------------------------------------------------------------------
CREATE OR REPLACE TYPE t_loyalty_benefit AS OBJECT (
  benefit_code   VARCHAR2(30),
  benefit_desc   VARCHAR2(200),
  benefit_value  NUMBER(12,4),
  valid_from     DATE,
  valid_to       DATE,

  MEMBER FUNCTION is_active (p_on IN DATE DEFAULT SYSDATE) RETURN VARCHAR2
);
/

--------------------------------------------------------------------------------
-- 6. t_price_point -- ORDER MEMBER FUNCTION. A type may have MAP or ORDER but
--    not both, so this one is the ORDER example and t_money is the MAP example.
--------------------------------------------------------------------------------
CREATE OR REPLACE TYPE t_price_point AS OBJECT (
  variant_id     NUMBER(12),
  price          NUMBER(12,4),
  currency_code  CHAR(3),
  source_code    VARCHAR2(20),

  ORDER MEMBER FUNCTION compare (o IN t_price_point) RETURN INTEGER
);
/

--------------------------------------------------------------------------------
-- 7-9. The inheritance chain (H-03). t_party is abstract; the two subtypes
--      override party_label. PostgreSQL has no substitutability at all, so this
--      is the part of H-03 with no mechanical translation whatsoever.
--------------------------------------------------------------------------------
CREATE OR REPLACE TYPE t_party AS OBJECT (
  party_id    NUMBER(12),
  party_name  VARCHAR2(200),
  party_kind  VARCHAR2(20),

  NOT INSTANTIABLE MEMBER FUNCTION party_label RETURN VARCHAR2
) NOT INSTANTIABLE NOT FINAL;
/

CREATE OR REPLACE TYPE t_customer_party UNDER t_party (
  loyalty_card_number  VARCHAR2(19),
  home_country_code    CHAR(2),

  OVERRIDING MEMBER FUNCTION party_label RETURN VARCHAR2
);
/

CREATE OR REPLACE TYPE t_supplier_party UNDER t_party (
  supplier_code   VARCHAR2(20),
  is_approved     CHAR(1),

  OVERRIDING MEMBER FUNCTION party_label RETURN VARCHAR2
);
/

--------------------------------------------------------------------------------
-- 10-13. VARRAY types (H-04). Each has a declared maximum length that a
--        PostgreSQL array will not enforce -- the residue the converter drops.
--------------------------------------------------------------------------------
CREATE OR REPLACE TYPE t_channel_varr AS VARRAY(8)  OF VARCHAR2(20);
/

CREATE OR REPLACE TYPE t_size_run_varr AS VARRAY(24) OF NUMBER(6);
/

CREATE OR REPLACE TYPE t_service_varr AS VARRAY(10) OF VARCHAR2(30);
/

CREATE OR REPLACE TYPE t_tag_varr AS VARRAY(20) OF VARCHAR2(40);
/

--------------------------------------------------------------------------------
-- 14-18. Nested table types (H-05).
--
--        t_number_tab and t_varchar_tab are schema-level rather than PL/SQL
--        local on purpose: they are the BULK COLLECT targets and the TABLE()
--        unnesting operands, which forces the converter to choose between a
--        PostgreSQL domain, an array type and a composite type (design 6.1).
--------------------------------------------------------------------------------
CREATE OR REPLACE TYPE t_product_attr_tab AS TABLE OF t_product_attr;
/

CREATE OR REPLACE TYPE t_benefit_tab AS TABLE OF t_loyalty_benefit;
/

CREATE OR REPLACE TYPE t_price_point_tab AS TABLE OF t_price_point;
/

CREATE OR REPLACE TYPE t_number_tab AS TABLE OF NUMBER;
/

CREATE OR REPLACE TYPE t_varchar_tab AS TABLE OF VARCHAR2(4000);
/

--------------------------------------------------------------------------------
--                              TYPE BODIES (8)
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Body 1: t_money
--
-- converted_to reaches exchange_rate through EXECUTE IMMEDIATE because this file
-- loads before 02-tables.sql. It also demonstrates the Oracle fallback idiom the
-- lab cares about: take today's rate, else the most recent prior rate.
--------------------------------------------------------------------------------
CREATE OR REPLACE TYPE BODY t_money AS

  MEMBER FUNCTION converted_to (p_to_currency IN CHAR,
                                p_on_date     IN DATE DEFAULT SYSDATE)
    RETURN t_money
  IS
    l_rate    NUMBER;
    l_amount  NUMBER;
  BEGIN
    IF SELF.amount IS NULL THEN
      RETURN t_money(NULL, p_to_currency);
    END IF;

    IF SELF.currency_code = p_to_currency THEN
      RETURN t_money(SELF.amount, p_to_currency);
    END IF;

    -- Dynamic on purpose: exchange_rate does not exist yet at compile time.
    BEGIN
      EXECUTE IMMEDIATE
        'SELECT rate FROM ('
        || '  SELECT rate FROM exchange_rate'
        || '   WHERE from_currency = :1 AND to_currency = :2'
        || '     AND rate_date <= :3'
        || '   ORDER BY rate_date DESC )'
        || ' WHERE ROWNUM = 1'
        INTO l_rate
        USING SELF.currency_code, p_to_currency, TRUNC(p_on_date);
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        l_rate := NULL;
      WHEN OTHERS THEN
        -- exchange_rate not built yet, or unreadable: degrade, do not fail.
        l_rate := NULL;
    END;

    IF l_rate IS NULL THEN
      RETURN t_money(NULL, p_to_currency);
    END IF;

    l_amount := ROUND(SELF.amount * l_rate, 2);
    RETURN t_money(l_amount, p_to_currency);
  END converted_to;

  MEMBER PROCEDURE add_amount (p_amount IN NUMBER)
  IS
  BEGIN
    -- SELF is IN OUT by default for a MEMBER PROCEDURE.
    SELF.amount := NVL(SELF.amount, 0) + NVL(p_amount, 0);
  END add_amount;

  MAP MEMBER FUNCTION to_base RETURN NUMBER
  IS
  BEGIN
    -- Deliberately naive: a MAP function must be deterministic, so it cannot
    -- look up a live FX rate. It ranks by amount with a stable currency tie
    -- break. The ordering contract this establishes is exactly what a
    -- PostgreSQL composite type cannot express (H-03).
    RETURN NVL(SELF.amount, 0);
  END to_base;

  STATIC FUNCTION zero (p_currency_code IN CHAR DEFAULT 'GBP') RETURN t_money
  IS
  BEGIN
    RETURN t_money(0, p_currency_code);
  END zero;

END;
/

--------------------------------------------------------------------------------
-- Body 2: t_contact
--------------------------------------------------------------------------------
CREATE OR REPLACE TYPE BODY t_contact AS

  MEMBER FUNCTION display_label RETURN VARCHAR2
  IS
  BEGIN
    -- NVL2 (H-31) and NULL-swallowing concatenation (T-14) in four lines.
    RETURN NVL(SELF.contact_name, '(unnamed contact)')
        || NVL2(SELF.role_title, ' (' || SELF.role_title || ')', NULL)
        || NVL2(SELF.email, ' <' || LOWER(SELF.email) || '>', NULL);
  END display_label;

  MEMBER FUNCTION is_valid_email RETURN VARCHAR2
  IS
  BEGIN
    IF SELF.email IS NULL THEN
      RETURN 'N';
    END IF;
    RETURN CASE
             WHEN REGEXP_LIKE(SELF.email, '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
             THEN 'Y'
             ELSE 'N'
           END;
  END is_valid_email;

END;
/

--------------------------------------------------------------------------------
-- Body 3: t_postal_address -- the overload pair (H-01).
--------------------------------------------------------------------------------
CREATE OR REPLACE TYPE BODY t_postal_address AS

  MEMBER FUNCTION format_label RETURN VARCHAR2
  IS
  BEGIN
    RETURN SELF.format_label('SHORT');
  END format_label;

  MEMBER FUNCTION format_label (p_style IN VARCHAR2) RETURN VARCHAR2
  IS
    l_sep  VARCHAR2(4);
  BEGIN
    l_sep := CASE UPPER(p_style) WHEN 'MULTILINE' THEN CHR(10) ELSE ', ' END;

    RETURN RTRIM(
             NVL(SELF.line1, '') || l_sep
             || NVL2(SELF.line2, SELF.line2 || l_sep, '')
             || NVL(SELF.city, '') || l_sep
             || NVL(SELF.postal_code, '') || l_sep
             || NVL(SELF.country_code, ''),
             l_sep || ' ');
  END format_label;

END;
/

--------------------------------------------------------------------------------
-- Body 4: t_product_attr
--------------------------------------------------------------------------------
CREATE OR REPLACE TYPE BODY t_product_attr AS

  MEMBER FUNCTION as_number RETURN NUMBER
  IS
    l_value  NUMBER;
  BEGIN
    -- Oracle converts a non-numeric string silently in some contexts and
    -- raises here; PostgreSQL always raises (T-10). Swallowing it keeps the
    -- nested-table unnest queries in pkg_catalog total.
    l_value := TO_NUMBER(TRIM(SELF.attr_value));
    RETURN l_value;
  EXCEPTION
    WHEN VALUE_ERROR THEN
      RETURN NULL;
    WHEN INVALID_NUMBER THEN
      RETURN NULL;
  END as_number;

END;
/

--------------------------------------------------------------------------------
-- Body 5: t_loyalty_benefit
--------------------------------------------------------------------------------
CREATE OR REPLACE TYPE BODY t_loyalty_benefit AS

  MEMBER FUNCTION is_active (p_on IN DATE DEFAULT SYSDATE) RETURN VARCHAR2
  IS
  BEGIN
    RETURN CASE
             WHEN SELF.valid_from IS NOT NULL AND p_on < SELF.valid_from THEN 'N'
             WHEN SELF.valid_to   IS NOT NULL AND p_on > SELF.valid_to   THEN 'N'
             ELSE 'Y'
           END;
  END is_active;

END;
/

--------------------------------------------------------------------------------
-- Body 6: t_price_point -- ORDER MEMBER FUNCTION.
--
-- Contract: negative if SELF sorts first, zero if equal, positive if last.
-- Nulls sort last, matching Oracle's default ascending behaviour, which is the
-- opposite of PostgreSQL's descending default (T-13).
--------------------------------------------------------------------------------
CREATE OR REPLACE TYPE BODY t_price_point AS

  ORDER MEMBER FUNCTION compare (o IN t_price_point) RETURN INTEGER
  IS
  BEGIN
    IF o IS NULL THEN
      RETURN -1;
    END IF;

    IF SELF.price IS NULL AND o.price IS NULL THEN
      RETURN 0;
    ELSIF SELF.price IS NULL THEN
      RETURN 1;
    ELSIF o.price IS NULL THEN
      RETURN -1;
    END IF;

    RETURN CASE
             WHEN SELF.price < o.price THEN -1
             WHEN SELF.price > o.price THEN  1
             ELSE 0
           END;
  END compare;

END;
/

--------------------------------------------------------------------------------
-- Body 7: t_customer_party -- OVERRIDING member function.
--------------------------------------------------------------------------------
CREATE OR REPLACE TYPE BODY t_customer_party AS

  OVERRIDING MEMBER FUNCTION party_label RETURN VARCHAR2
  IS
  BEGIN
    RETURN 'CUSTOMER:' || NVL(TO_CHAR(SELF.party_id), '?')
        || ':' || NVL(SELF.party_name, '(anonymous)')
        || NVL2(SELF.loyalty_card_number, ' [card ' || SELF.loyalty_card_number || ']', NULL);
  END party_label;

END;
/

--------------------------------------------------------------------------------
-- Body 8: t_supplier_party -- OVERRIDING member function.
--------------------------------------------------------------------------------
CREATE OR REPLACE TYPE BODY t_supplier_party AS

  OVERRIDING MEMBER FUNCTION party_label RETURN VARCHAR2
  IS
  BEGIN
    -- CASE, not DECODE: DECODE is a SQL-only pseudo-function and raises
    -- PLS-00204 inside PL/SQL. The DECODE examples the lab needs live in SQL
    -- statements -- the function-based index in 04-indexes.sql and the views.
    RETURN 'SUPPLIER:' || NVL(SELF.supplier_code, '?')
        || ':' || NVL(SELF.party_name, '(unnamed)')
        || CASE SELF.is_approved
             WHEN 'Y' THEN ' [approved]'
             WHEN 'N' THEN ' [unapproved]'
             ELSE ' [unknown]'
           END;
  END party_label;

END;
/

--------------------------------------------------------------------------------
-- Verification: 18 TYPE + 8 TYPE BODY, none INVALID.
--------------------------------------------------------------------------------
DECLARE
  l_types    PLS_INTEGER;
  l_bodies   PLS_INTEGER;
  l_invalid  PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_types
    FROM user_objects WHERE object_type = 'TYPE';

  SELECT COUNT(*) INTO l_bodies
    FROM user_objects WHERE object_type = 'TYPE BODY';

  SELECT COUNT(*) INTO l_invalid
    FROM user_objects
   WHERE object_type IN ('TYPE', 'TYPE BODY')
     AND status <> 'VALID';

  DBMS_OUTPUT.PUT_LINE('TYPE ......: ' || l_types  || ' (expected 18)');
  DBMS_OUTPUT.PUT_LINE('TYPE BODY .: ' || l_bodies || ' (expected 8)');

  IF l_invalid > 0 THEN
    RAISE_APPLICATION_ERROR(-20010,
      l_invalid || ' type(s) compiled INVALID -- see USER_ERRORS.');
  END IF;

  IF l_types <> 18 OR l_bodies <> 8 THEN
    RAISE_APPLICATION_ERROR(-20011,
      'Type budget drift: expected 18 TYPE and 8 TYPE BODY, got '
      || l_types || ' and ' || l_bodies || '.');
  END IF;
END;
/

prompt
prompt 01-types.sql complete: 18 types, 8 type bodies, all VALID.
prompt
